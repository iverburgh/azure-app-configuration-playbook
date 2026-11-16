BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    # $PSBoundParameters is empty inside a mock body, so the parameters are passed on by name.
    Mock Invoke-AzCli { Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }

    $script:ParameterKey = 'orders-api:Parameters:MaxOrderLines'
    $script:ParameterSentinelKey = 'orders-api:ParameterSentinel'
    $script:Now = [DateTimeOffset]'2025-06-01T00:00:00Z'

    function Get-VariantErrors {
        param([string] $Name, [hashtable] $Files)
        $app = New-TestApp -Root (Join-Path $TestDrive $Name) -Files $Files
        @(Get-ValidationErrors -AppPath $app)
    }

    function New-ParameterJson {
        <# One parameter 'Limit' with the given data type and values (start date to value). #>
        param([string] $DataType, [System.Collections.Specialized.OrderedDictionary] $Values)
        $entries = @(foreach ($start in $Values.Keys) { [ordered]@{ startDate = $start; value = $Values[$start] } })
        ConvertTo-Json -Depth 5 -InputObject ([ordered]@{ Limit = [ordered]@{ dataType = $DataType; values = $entries } })
    }

    function Get-StoredParameter {
        param([string] $Key = $ParameterKey)
        ConvertFrom-JsonText -Json (Get-FakeItem -Key $Key -Label 'app-parameter').value
    }

    function Invoke-ImportWithWarnings {
        <# Imports and returns the warnings; the change records go to $script:ImportChanges. #>
        param([string] $Label, $Resolved = (Get-ExampleResolved))
        $output = @(Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved $Resolved -Label $Label 3>&1)
        $script:ImportChanges = @($output | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] })
        @($output | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object Message)
    }

    function Set-TestParameter {
        param([string] $Name = 'MaxOrderLines', [DateTimeOffset] $StartDate, [string] $Value, [switch] $DryRun)
        @(Set-ApplicationParameterValue -StoreEndpoint $TestStore -AppName 'orders-api' -Name $Name -StartDate $StartDate -Value $Value -Now $Now -DryRun:$DryRun)
    }
}

Describe 'Validating application parameters' {
    It 'accepts <Value> as <DataType>' -ForEach @(
        @{ DataType = 'String'; Value = '' }
        @{ DataType = 'Integer'; Value = '-3' }
        @{ DataType = 'Decimal'; Value = '12.50' }
        @{ DataType = 'Percentage'; Value = '12.5' }
        @{ DataType = 'TimeSpan'; Value = '1.00:00:00' }
        @{ DataType = 'Email'; Value = 'support@example.com' }
    ) {
        $json = New-ParameterJson -DataType $DataType -Values ([ordered]@{ '2024-01-01T00:00:00+01:00' = $Value })
        Get-VariantErrors "ok-$DataType" @{ 'AppConfiguration.ApplicationParameters.json' = $json } | Should -BeNullOrEmpty
    }

    It 'rejects <Value> as <DataType>' -ForEach @(
        @{ DataType = 'Integer'; Value = '1.5' }
        @{ DataType = 'Decimal'; Value = '1,5' }
        @{ DataType = 'Percentage'; Value = '101' }
        @{ DataType = 'TimeSpan'; Value = '5 minutes' }
        @{ DataType = 'Email'; Value = 'support' }
    ) {
        $json = New-ParameterJson -DataType $DataType -Values ([ordered]@{ '2024-01-01T00:00:00Z' = $Value })
        Get-VariantErrors "bad-$DataType" @{ 'AppConfiguration.ApplicationParameters.json' = $json } |
            Should -Match "parameter 'Limit' value 0 \('$([regex]::Escape($Value))'\)"
    }

    It 'rejects an unknown data type' {
        $json = New-ParameterJson -DataType 'Money' -Values ([ordered]@{ '2024-01-01T00:00:00Z' = '1' })
        Get-VariantErrors 'type' @{ 'AppConfiguration.ApplicationParameters.json' = $json } | Should -Match 'AppConfiguration.ApplicationParameters.json'
    }

    It 'rejects a parameter without values' {
        Get-VariantErrors 'empty' @{ 'AppConfiguration.ApplicationParameters.json' = '{ "Limit": { "dataType": "Integer", "values": [] } }' } |
            Should -Match 'AppConfiguration.ApplicationParameters.json'
    }

    It 'rejects a start date without an offset' {
        $json = New-ParameterJson -DataType 'Integer' -Values ([ordered]@{ '2024-01-01T00:00:00' = '1' })
        Get-VariantErrors 'offset' @{ 'AppConfiguration.ApplicationParameters.json' = $json } | Should -Match 'use ISO 8601 with seconds and an offset'
    }

    It 'rejects start dates that do not ascend' {
        $json = New-ParameterJson -DataType 'Integer' -Values ([ordered]@{ '2025-01-01T00:00:00Z' = '1'; '2024-01-01T00:00:00Z' = '2' })
        Get-VariantErrors 'order' @{ 'AppConfiguration.ApplicationParameters.json' = $json } | Should -Match 'not later than the value before it'
    }

    It 'reserves the top-level key Parameters when the app has parameters' {
        Get-VariantErrors 'reserved' @{ 'AppConfiguration.json' = '{ "Parameters": { "Limit": 1 } }' } |
            Should -Match 'reserved for the application parameters'
    }

    It 'allows the top-level key Parameters when the app has no parameters' {
        Get-VariantErrors 'free' @{ 'AppConfiguration.json' = '{ "Parameters": { "Limit": 1 } }'; 'AppConfiguration.ApplicationParameters.json' = $null } |
            Should -BeNullOrEmpty
    }

    It 'reserves the top-level key ParameterSentinel' {
        Get-VariantErrors 'sentinel' @{ 'AppConfiguration.json' = '{ "ParameterSentinel": "x" }' } | Should -Match 'reserved for the change sentinel'
    }

    It 'replaces tokens in parameter values' {
        $resolved = Get-ExampleResolved
        $resolved.ApplicationParameters.FreeShippingThreshold.values[0].value | Should -BeExactly '50.00'
    }

    It 'reports an unknown token in a parameter value' {
        $json = New-ParameterJson -DataType 'Integer' -Values ([ordered]@{ '2024-01-01T00:00:00Z' = '#{Limit}#' })
        Get-VariantErrors 'token' @{ 'AppConfiguration.ApplicationParameters.json' = $json } | Should -Match "unknown token '#\{Limit\}#'"
    }
}

Describe 'A first import with application parameters' {
    BeforeAll {
        Initialize-TestEnvironment
        $script:Changes = @(Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved (Get-ExampleResolved) -Label 'build-1')
    }

    It 'writes each parameter with the fixed label and the JSON content type' {
        $item = Get-FakeItem -Key $ParameterKey -Label 'app-parameter'
        $item.contentType | Should -BeExactly 'application/json'
        $stored = Get-StoredParameter
        $stored.dataType | Should -BeExactly 'Integer'
        @($stored.values | ForEach-Object value) | Should -Be @('100', '250')
        $stored.values[1].startDate | Should -BeExactly '2025-01-01T00:00:00Z'
    }

    It 'writes the resolved token values' {
        (Get-StoredParameter -Key 'orders-api:Parameters:FreeShippingThreshold').values[0].value | Should -BeExactly '50.00'
    }

    It 'writes the parameters and then the parameter sentinel before the configuration set' {
        $Fake.Writes[0] | Should -BeExactly 'kv import: orders-api:Parameters:MaxOrderLines, orders-api:Parameters:FreeShippingThreshold, orders-api:Parameters:SupportEmail'
        $Fake.Writes[1] | Should -BeExactly "kv import: $ParameterSentinelKey"
        (Get-FakeItem -Key $ParameterSentinelKey -Label 'app-parameter').value | Should -BeExactly 'build-1'
    }

    It 'reports where the values came from' {
        @($Changes | Where-Object { $_.Target -eq 'parameter' -and $_.Detail -eq 'values from the file' }).Count | Should -Be 3
    }
}

Describe 'A new deployment and application parameters' {
    BeforeEach {
        Initialize-TestEnvironment
        Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved (Get-ExampleResolved) -Label 'build-1' | Out-Null
        $Fake.Writes.Clear()
    }

    It 'rewrites no parameter' {
        $changes = @(Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved (Get-ExampleResolved) -Label 'build-2')
        @($changes | Where-Object Target -EQ 'parameter') | Should -BeNullOrEmpty
        @($Fake.Writes | Where-Object { $_ -match 'Parameter' }) | Should -BeNullOrEmpty
        (Get-FakeItem -Key $ParameterKey -Label 'app-parameter').tags.deployment | Should -BeExactly 'build-1'
    }

    It 'keeps the values from the store' {
        Set-TestParameter -StartDate '2026-01-01T00:00:00Z' -Value '300' | Out-Null
        Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved (Get-ExampleResolved) -Label 'build-2' | Out-Null
        @((Get-StoredParameter).values | ForEach-Object value) | Should -Be @('100', '250', '300')
    }

    It 'takes a new description from the file and keeps the values' {
        Set-TestParameter -StartDate '2026-01-01T00:00:00Z' -Value '300' | Out-Null
        $resolved = Get-ExampleResolved
        $resolved.ApplicationParameters.MaxOrderLines.description = 'Changed.'
        $changes = @(Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved $resolved -Label 'build-2')
        $change = @($changes | Where-Object Name -EQ $ParameterKey)
        $change.Count | Should -Be 1
        $change[0].Action | Should -BeExactly 'Update'
        $change[0].Detail | Should -BeExactly 'values kept from the store'
        (Get-StoredParameter).description | Should -BeExactly 'Changed.'
        @((Get-StoredParameter).values).Count | Should -Be 3
    }

    It 'changes the data type when every stored value fits' {
        $resolved = Get-ExampleResolved
        $resolved.ApplicationParameters.MaxOrderLines.dataType = 'Decimal'
        Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved $resolved -Label 'build-2' | Out-Null
        (Get-StoredParameter).dataType | Should -BeExactly 'Decimal'
    }

    It 'refuses a data type that a stored value does not fit, and writes nothing' {
        $resolved = Get-ExampleResolved
        $resolved.ApplicationParameters.MaxOrderLines.dataType = 'Email'
        { Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved $resolved -Label 'build-2' } | Should -Throw '*cannot change to data type Email*'
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'leaves an unreadable stored value alone with a warning' {
        $item = Get-FakeItem -Key 'orders-api:Parameters:SupportEmail' -Label 'app-parameter'
        $item.value = 'not json'
        $warnings = Invoke-ImportWithWarnings -Label 'build-2'
        $warnings | Should -Match 'SupportEmail'
        (Get-FakeItem -Key 'orders-api:Parameters:SupportEmail' -Label 'app-parameter').value | Should -BeExactly 'not json'
    }

    It 'keeps a parameter that is no longer in the file, with a warning' {
        Add-FakeItem -Key 'orders-api:Parameters:Retired' -Label 'app-parameter' -Value '{}' -ContentType 'application/json'
        $warnings = Invoke-ImportWithWarnings -Label 'build-2'
        $warnings | Should -Match 'Retired.*is kept'
        Get-FakeItem -Key 'orders-api:Parameters:Retired' -Label 'app-parameter' | Should -Not -BeNullOrEmpty
        @($ImportChanges | Where-Object Action -EQ 'Delete') | Should -BeNullOrEmpty
    }

    It 'adds a parameter that is new in the file' {
        $resolved = Get-ExampleResolved
        $resolved.ApplicationParameters | Add-Member -NotePropertyName 'RetryWindow' -NotePropertyValue ([pscustomobject]@{
                dataType = 'TimeSpan'; description = ''; values = @([pscustomobject]@{ startDate = '2024-01-01T00:00:00Z'; value = '00:05:00' })
            })
        $changes = @(Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved $resolved -Label 'build-2')
        @($changes | Where-Object Target -EQ 'parameter' | ForEach-Object Name) | Should -Be @('orders-api:Parameters:RetryWindow')
    }
}

Describe 'An app without application parameters' {
    It 'writes no parameter sentinel' {
        Initialize-TestEnvironment
        $app = New-TestApp -Root (Join-Path $TestDrive 'no-parameters') -Files @{ 'AppConfiguration.ApplicationParameters.json' = $null }
        Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved (Get-ExampleResolved -AppPath $app) -Label 'build-1' | Out-Null
        @($Fake.Items | Where-Object label -EQ 'app-parameter') | Should -BeNullOrEmpty
    }
}

Describe 'Cleaning up and application parameters' {
    It 'keeps every parameter and the parameter sentinel' {
        Initialize-TestEnvironment
        foreach ($label in 'build-1', 'build-2', 'build-3') {
            Invoke-TestDeployment -Label $label
        }
        $changes = @(Invoke-ConfigurationCleanup -StoreEndpoint $TestStore -AppName 'orders-api' -ResourceGroup $TestResourceGroup -WebAppName $TestWebApp -CurrentLabel 'build-3')
        @($changes | Where-Object Label -EQ 'app-parameter') | Should -BeNullOrEmpty
        @($Fake.Items | Where-Object label -EQ 'app-parameter').Count | Should -Be 4
    }
}

Describe 'Scheduling a parameter value' {
    BeforeEach {
        Initialize-TestEnvironment
        Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved (Get-ExampleResolved) -Label 'build-1' | Out-Null
        $Fake.Writes.Clear()
        $script:SentinelBefore = (Get-FakeItem -Key $ParameterSentinelKey -Label 'app-parameter').value
    }

    It 'appends the value with who made the change and when' {
        $changes = Set-TestParameter -StartDate '2026-01-01T00:00:00+01:00' -Value '300'
        $values = @((Get-StoredParameter).values)
        $values.Count | Should -Be 3
        $values[2].startDate | Should -BeExactly '2026-01-01T00:00:00+01:00'
        $values[2].value | Should -BeExactly '300'
        $values[2].changedBy | Should -BeExactly 'pipeline@example.com'
        $values[2].changedAt | Should -BeExactly '2025-06-01T00:00:00+00:00'
        $changes[0].Detail | Should -BeExactly 'from 2026-01-01T00:00:00+01:00: 300'
    }

    It 'keeps the content type and tags' {
        Set-TestParameter -StartDate '2026-01-01T00:00:00Z' -Value '300' | Out-Null
        $item = Get-FakeItem -Key $ParameterKey -Label 'app-parameter'
        $item.contentType | Should -BeExactly 'application/json'
        $item.tags.deployment | Should -BeExactly 'build-1'
    }

    It 'changes the parameter sentinel after the value' {
        Set-TestParameter -StartDate '2026-01-01T00:00:00Z' -Value '300' | Out-Null
        $Fake.Writes | Should -Be @("kv import: $ParameterKey", "kv import: $ParameterSentinelKey")
        $after = (Get-FakeItem -Key $ParameterSentinelKey -Label 'app-parameter').value
        $after | Should -Match '^[0-9a-f]{32}$'
        $after | Should -Not -Be $SentinelBefore
    }

    It 'changes nothing when run again' {
        Set-TestParameter -StartDate '2026-01-01T00:00:00Z' -Value '300' | Out-Null
        $Fake.Writes.Clear()
        Set-TestParameter -StartDate '2026-01-01T00:00:00Z' -Value '300' | Should -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'replaces a planned value with the same start date' {
        Set-TestParameter -StartDate '2026-01-01T00:00:00Z' -Value '300' | Out-Null
        $changes = Set-TestParameter -StartDate '2026-01-01T00:00:00Z' -Value '350'
        @((Get-StoredParameter).values | ForEach-Object value) | Should -Be @('100', '250', '350')
        $changes[0].Detail | Should -Match "replaces the planned value '300'"
    }

    It 'refuses a start date that is not in the future' {
        { Set-TestParameter -StartDate '2025-05-01T00:00:00Z' -Value '300' } | Should -Throw '*not in the future*'
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'refuses a start date before the last planned one' {
        Set-TestParameter -StartDate '2027-01-01T00:00:00Z' -Value '300' | Out-Null
        { Set-TestParameter -StartDate '2026-01-01T00:00:00Z' -Value '275' } | Should -Throw '*earlier than the last planned start date*'
    }

    It 'refuses a value that does not fit the data type' {
        { Set-TestParameter -StartDate '2026-01-01T00:00:00Z' -Value 'many' } | Should -Throw '*not a whole number*'
    }

    It 'refuses a parameter that is not in the store' {
        { Set-TestParameter -Name 'Unknown' -StartDate '2026-01-01T00:00:00Z' -Value '1' } | Should -Throw '*does not exist*deploy*'
    }

    It 'writes nothing in a dry run' {
        @(Set-TestParameter -StartDate '2026-01-01T00:00:00Z' -Value '300' -DryRun).Count | Should -Be 2
        $Fake.Writes | Should -BeNullOrEmpty
    }
}

Describe 'Set-ApplicationParameter.ps1' {
    BeforeAll {
        $script:Script = Join-Path $PlaybookRoot 'Set-ApplicationParameter.ps1'
        $script:ScriptParameters = @{ StoreEndpoint = $TestStore; AppName = 'orders-api'; Name = 'MaxOrderLines'; StartDate = '2099-01-01T00:00:00Z'; Value = '300' }
    }

    BeforeEach {
        Initialize-TestEnvironment
        Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved (Get-ExampleResolved) -Label 'build-1' | Out-Null
        $Fake.Writes.Clear()
    }

    It 'writes nothing with -WhatIf' {
        @(& $Script @ScriptParameters -WhatIf).Count | Should -Be 2
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'records the given -ChangedBy' {
        & $Script @ScriptParameters -ChangedBy 'jane@example.com' | Out-Null
        (Get-StoredParameter).values[2].changedBy | Should -BeExactly 'jane@example.com'
    }
}
