BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    # $PSBoundParameters is empty inside a mock body, so the parameters are passed on by name.
    # The entry scripts dot-source the library again; the mock still wins because Pester
    # puts it in front of the function.
    Mock Invoke-AzCli { Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }

    $script:Target = @{ ResourceGroup = $TestResourceGroup; WebAppName = $TestWebApp; StoreEndpoint = $TestStore; AppName = 'orders-api' }
    $script:WebApp = @{ ResourceGroup = $TestResourceGroup; WebAppName = $TestWebApp }

    function Invoke-EntryScript {
        param([string] $Name, [hashtable] $Parameters)
        & (Join-Path $PlaybookRoot $Name) @Parameters
    }

    function Build-TestApp {
        param([string] $Environment = 'test')
        $output = Join-Path $TestDrive "out-$Environment"
        Invoke-EntryScript 'Build-AppConfiguration.ps1' @{ AppName = 'orders-api'; Environment = $Environment; OutputPath = $output } | Out-Null
        Join-Path $output 'orders-api'
    }

    function Invoke-TestPipeline {
        <# The deployment steps of the pipeline, through the entry scripts. #>
        param([string] $Label, [string] $ResolvedPath, [switch] $WhatIf)
        $changes = [System.Collections.Generic.List[object]]::new()
        foreach ($change in @(Invoke-EntryScript 'Import-AppConfiguration.ps1' @{ StoreEndpoint = $TestStore; Path = $ResolvedPath; Label = $Label; WhatIf = [bool]$WhatIf })) { $changes.Add($change) }
        foreach ($change in @(Invoke-EntryScript 'Set-SlotConfigurationLabel.ps1' ($Target + @{ Label = $Label; HealthCheckPath = '/health'; WhatIf = [bool]$WhatIf }))) { $changes.Add($change) }
        foreach ($change in @(Invoke-EntryScript 'Switch-ConfigurationSet.ps1' ($WebApp + @{ Label = $Label; WhatIf = [bool]$WhatIf }))) { $changes.Add($change) }
        foreach ($change in @(Invoke-EntryScript 'Remove-ObsoleteConfigurationSets.ps1' ($Target + @{ CurrentLabel = $Label; WhatIf = [bool]$WhatIf }))) { $changes.Add($change) }
        $changes.ToArray()
    }
}

Describe 'Build-AppConfiguration.ps1' {
    It 'writes the four resolved files' {
        $path = Build-TestApp -Environment 'prod'
        @(Get-ChildItem -LiteralPath $path -File | ForEach-Object Name | Sort-Object) | Should -Be @(
            'AppConfiguration.CircuitBreakerFlags.json'
            'AppConfiguration.FeatureFlags.json'
            'AppConfiguration.json'
            'AppConfiguration.KeyVault.json'
        )
        (Get-Content -LiteralPath (Join-Path $path 'AppConfiguration.json') -Raw) | Should -Not -Match '#\{'
        (Get-Content -LiteralPath (Join-Path $path 'AppConfiguration.json') -Raw | ConvertFrom-Json).Payments.TimeoutSeconds | Should -BeExactly '10'
    }

    It 'keeps a flag file with one flag as an array' {
        $root = Join-Path $TestDrive 'one-flag'
        New-TestApp -Root $root -Files @{ 'AppConfiguration.FeatureFlags.json' = '[ { "name": "NewCheckout" } ]' } | Out-Null
        $output = Join-Path $root 'out'
        Invoke-EntryScript 'Build-AppConfiguration.ps1' @{ AppName = 'orders-api'; Environment = 'test'; OutputPath = $output; AppsPath = (Join-Path $root 'apps') } | Out-Null
        (Get-Content -LiteralPath (Join-Path $output 'orders-api/AppConfiguration.FeatureFlags.json') -Raw).TrimStart() | Should -Match '^\['
    }

    It 'writes nothing with -WhatIf' {
        $output = Join-Path $TestDrive 'whatif'
        Invoke-EntryScript 'Build-AppConfiguration.ps1' @{ AppName = 'orders-api'; Environment = 'test'; OutputPath = $output; WhatIf = $true } | Out-Null
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'fails on an invalid app' {
        $root = Join-Path $TestDrive 'invalid'
        New-TestApp -Root $root -Files @{ 'AppConfiguration.json' = '{ "Region": "#{Region}#" }' } | Out-Null
        { Invoke-EntryScript 'Build-AppConfiguration.ps1' @{ AppName = 'orders-api'; Environment = 'test'; OutputPath = (Join-Path $root 'out'); AppsPath = (Join-Path $root 'apps') } } |
            Should -Throw "*unknown token '#{Region}#'*"
    }

    It 'fails on an unknown app' {
        { Invoke-EntryScript 'Build-AppConfiguration.ps1' @{ AppName = 'billing-api'; Environment = 'test'; OutputPath = (Join-Path $TestDrive 'x') } } |
            Should -Throw "*'billing-api' does not exist*"
    }
}

Describe 'Import-AppConfiguration.ps1' {
    BeforeAll {
        $script:Resolved = Build-TestApp
    }

    BeforeEach {
        Initialize-TestEnvironment
    }

    It 'imports the resolved files' {
        @(Invoke-EntryScript 'Import-AppConfiguration.ps1' @{ StoreEndpoint = $TestStore; Path = $Resolved; Label = 'build-1' }).Count | Should -Be 18
        (Get-FakeItem -Key 'orders-api:Payments:BaseUrl' -Label 'build-1').value | Should -BeExactly 'https://payments-test.example.com/api/'
    }

    It 'refuses files that still contain tokens' {
        { Invoke-EntryScript 'Import-AppConfiguration.ps1' @{ StoreEndpoint = $TestStore; Path = $ExampleAppPath; Label = 'build-1' } } |
            Should -Throw '*not a valid resolved configuration*unknown token*'
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'refuses to run when the Azure CLI is not logged in' {
        $Fake.LoggedIn = $false
        { Invoke-EntryScript 'Import-AppConfiguration.ps1' @{ StoreEndpoint = $TestStore; Path = $Resolved; Label = 'build-1' } } |
            Should -Throw '*not logged in*'
        $Fake.Writes | Should -BeNullOrEmpty
    }
}

Describe 'The pipeline steps with -WhatIf' {
    BeforeAll {
        $script:Resolved = Build-TestApp
    }

    It 'write nothing on an empty environment' {
        Initialize-TestEnvironment
        Invoke-EntryScript 'Import-AppConfiguration.ps1' @{ StoreEndpoint = $TestStore; Path = $Resolved; Label = 'build-1'; WhatIf = $true } | Out-Null
        $Fake.Writes | Should -BeNullOrEmpty
        $Fake.Items | Should -BeNullOrEmpty
    }

    It 'report the same changes as a real run' {
        Initialize-TestEnvironment
        $preview = @(Invoke-EntryScript 'Import-AppConfiguration.ps1' @{ StoreEndpoint = $TestStore; Path = $Resolved; Label = 'build-1'; WhatIf = $true })
        $real = @(Invoke-EntryScript 'Import-AppConfiguration.ps1' @{ StoreEndpoint = $TestStore; Path = $Resolved; Label = 'build-1' })
        @(foreach ($change in $preview) { '{0} {1}' -f $change.Action, $change.Name }) |
            Should -Be @(foreach ($change in $real) { '{0} {1}' -f $change.Action, $change.Name })
    }

    It 'report no changes when the set is already imported' {
        Initialize-TestEnvironment
        Invoke-EntryScript 'Import-AppConfiguration.ps1' @{ StoreEndpoint = $TestStore; Path = $Resolved; Label = 'build-1' } | Out-Null
        @(Invoke-EntryScript 'Import-AppConfiguration.ps1' @{ StoreEndpoint = $TestStore; Path = $Resolved; Label = 'build-1'; WhatIf = $true }).Count |
            Should -Be 0
    }

    It 'write nothing on a running environment: <Name>' -ForEach @(
        @{ Name = 'Import-AppConfiguration.ps1'; Extra = @{ StoreEndpoint = 'https://appcs-example.azconfig.io'; Label = 'build-3' }; UsesPath = $true }
        @{ Name = 'Set-SlotConfigurationLabel.ps1'; Extra = @{ Label = 'build-2'; HealthCheckPath = '/health' }; UsesTarget = $true }
        @{ Name = 'Switch-ConfigurationSet.ps1'; Extra = @{ Label = 'build-2' }; UsesWebApp = $true }
        @{ Name = 'Undo-ConfigurationSet.ps1'; Extra = @{ Label = 'build-1' }; UsesTarget = $true }
        @{ Name = 'Remove-ObsoleteConfigurationSets.ps1'; Extra = @{ CurrentLabel = 'build-1' }; UsesTarget = $true }
    ) {
        # Production runs build-1, staging points at build-2, and build-0 is an older set.
        Initialize-TestEnvironment
        Invoke-TestDeployment -Label 'build-0'
        Invoke-TestDeployment -Label 'build-1'
        Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved (Get-ExampleResolved) -Label 'build-2' | Out-Null
        Invoke-SlotLabelUpdate @Target -Label 'build-2' | Out-Null
        $arguments = $Extra.Clone()
        if ($_.ContainsKey('UsesPath')) { $arguments.Path = $Resolved }
        if ($_.ContainsKey('UsesTarget')) { $arguments += $Target }
        if ($_.ContainsKey('UsesWebApp')) { $arguments += $WebApp }
        $before = ConvertTo-Json -InputObject @{ Items = $Fake.Items; Sites = $Fake.Sites } -Depth 10
        $Fake.Writes.Clear()

        $changes = @(Invoke-EntryScript $Name ($arguments + @{ WhatIf = $true }))

        $changes | Should -Not -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
        ConvertTo-Json -InputObject @{ Items = $Fake.Items; Sites = $Fake.Sites } -Depth 10 | Should -BeExactly $before
    }
}

Describe 'A full deployment through the entry scripts' {
    BeforeAll {
        $script:Resolved = Build-TestApp
        Initialize-TestEnvironment
        Invoke-TestPipeline -Label 'build-1' -ResolvedPath $Resolved | Out-Null
        Invoke-TestPipeline -Label 'build-2' -ResolvedPath $Resolved | Out-Null
        $script:ThirdRun = Invoke-TestPipeline -Label 'build-3' -ResolvedPath $Resolved
        $script:State = ConvertTo-Json -InputObject @{ Items = $Fake.Items; Sites = $Fake.Sites } -Depth 10
    }

    It 'ends with the new set live, the previous one on staging and older ones removed' {
        Get-TestLabel 'production' | Should -BeExactly 'build-3'
        Get-TestLabel 'staging' | Should -BeExactly 'build-2'
        Get-FakeLabels | Should -Be @('build-2', 'build-3')
        @($ThirdRun | Where-Object { $_.Action -eq 'Delete' -and $_.Label -eq 'build-1' }).Count | Should -Be 14
    }

    It 'changes nothing when the same deployment runs again' {
        $Fake.Writes.Clear()
        Invoke-TestPipeline -Label 'build-3' -ResolvedPath $Resolved | Should -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
        ConvertTo-Json -InputObject @{ Items = $Fake.Items; Sites = $Fake.Sites } -Depth 10 | Should -BeExactly $State
    }

    It 'rolls back to the previous set with Undo-ConfigurationSet.ps1' {
        Invoke-EntryScript 'Undo-ConfigurationSet.ps1' ($Target + @{ Label = 'build-3' }) | Out-Null
        Get-TestLabel 'production' | Should -BeExactly 'build-2'
    }
}
