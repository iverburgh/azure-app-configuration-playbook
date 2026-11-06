BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    # $PSBoundParameters is empty inside a mock body, so the parameters are passed on by name.
    Mock Invoke-AzCli { Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }

    function Invoke-TestImport {
        param([string] $Label, $Resolved = (Get-ExampleResolved), [switch] $DryRun)
        @(Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved $Resolved -Label $Label -DryRun:$DryRun)
    }

    function Get-FlagState {
        param([string] $Name, [string] $Label)
        $item = Get-FakeItem -Key ".appconfig.featureflag/orders-api.$Name" -Label $Label
        $item.value | ConvertFrom-Json
    }
}

Describe 'A first import' {
    BeforeAll {
        Initialize-TestEnvironment
        $script:Changes = Invoke-TestImport -Label 'build-1'
    }

    It 'writes every setting under the app prefix with the deployment label' {
        (Get-FakeItem -Key 'orders-api:Orders:PageSize' -Label 'build-1').value | Should -BeExactly '50'
        (Get-FakeItem -Key 'orders-api:Orders:RetryDelays:1' -Label 'build-1').value | Should -BeExactly '00:00:05'
        (Get-FakeItem -Key 'orders-api:Logging:LogLevel:Default' -Label 'build-1').value | Should -BeExactly 'Information'
        (Get-FakeItem -Key 'orders-api:Orders:AllowGuestCheckout' -Label 'build-1').value | Should -BeExactly 'true'
    }

    It 'writes Key Vault references with the Key Vault content type' {
        $item = Get-FakeItem -Key 'orders-api:Payments:ApiKey' -Label 'build-1'
        $item.contentType | Should -BeExactly 'application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8'
        ($item.value | ConvertFrom-Json).uri | Should -BeExactly 'https://kv-orders-test.vault.azure.net/secrets/payments-api-key'
    }

    It 'tags every item with the deployment' {
        $Fake.Items | ForEach-Object { $_.tags.deployment | Should -BeExactly 'build-1' }
    }

    It 'writes the sentinel last, in a separate import' {
        $Fake.Writes[-1] | Should -BeExactly 'kv import: orders-api:Sentinel'
        (Get-FakeItem -Key 'orders-api:Sentinel' -Label 'build-1').value | Should -Match '^[0-9a-f]{64}$'
        Test-ConfigurationSetExists -StoreEndpoint $TestStore -AppName 'orders-api' -Label 'build-1' | Should -BeTrue
    }

    It 'writes feature flags with a fixed label, off by default' {
        $flag = Get-FlagState -Name 'NewCheckout' -Label 'feature-flag'
        $flag.id | Should -BeExactly 'orders-api.NewCheckout'
        $flag.enabled | Should -BeFalse
        (Get-FakeItem -Key '.appconfig.featureflag/orders-api.NewCheckout' -Label 'feature-flag').contentType |
            Should -BeExactly 'application/vnd.microsoft.appconfig.ff+json;charset=utf-8'
    }

    It 'writes the resolved filter parameters of a flag' {
        $flag = Get-FlagState -Name 'ExpressShipping' -Label 'feature-flag'
        $flag.conditions.client_filters[0].name | Should -BeExactly 'Microsoft.Percentage'
        $flag.conditions.client_filters[0].parameters.Value | Should -BeExactly '50'
    }

    It 'writes circuit breakers with their own label, on by default' {
        (Get-FlagState -Name 'PaymentProvider' -Label 'circuit-breaker').enabled | Should -BeTrue
        (Get-FlagState -Name 'OrderEmails' -Label 'circuit-breaker').enabled | Should -BeTrue
    }

    It 'reports every change' {
        @($Changes | Where-Object Target -EQ 'setting').Count | Should -Be 14
        @($Changes | Where-Object Target -EQ 'flag').Count | Should -Be 4
        @($Changes | Where-Object Action -NE 'Add') | Should -BeNullOrEmpty
    }
}

Describe 'Importing the same deployment again' {
    BeforeAll {
        Initialize-TestEnvironment
        Invoke-TestImport -Label 'build-1' | Out-Null
        $script:Before = ConvertTo-Json -InputObject @($Fake.Items) -Depth 10
        $Fake.Writes.Clear()
        $script:Changes = Invoke-TestImport -Label 'build-1'
    }

    It 'writes nothing' {
        $Fake.Writes | Should -BeNullOrEmpty
        $Changes | Should -BeNullOrEmpty
    }

    It 'leaves the store unchanged' {
        ConvertTo-Json -InputObject @($Fake.Items) -Depth 10 | Should -BeExactly $Before
    }
}

Describe 'Importing a new deployment' {
    BeforeAll {
        Initialize-TestEnvironment
        Invoke-TestImport -Label 'build-1' | Out-Null
        $script:Build1 = ConvertTo-Json -InputObject @($Fake.Items | Where-Object label -EQ 'build-1') -Depth 10
        $resolved = Get-ExampleResolved
        $resolved.Settings.Orders.PageSize = 25
        $script:Changes = Invoke-TestImport -Label 'build-2' -Resolved $resolved
    }

    It 'adds a complete second set' {
        (Get-FakeItem -Key 'orders-api:Orders:PageSize' -Label 'build-2').value | Should -BeExactly '25'
        Test-ConfigurationSetExists -StoreEndpoint $TestStore -AppName 'orders-api' -Label 'build-2' | Should -BeTrue
        @($Changes | Where-Object { $_.Target -eq 'setting' -and $_.Action -eq 'Add' }).Count | Should -Be 14
    }

    It 'leaves the previous set untouched' {
        ConvertTo-Json -InputObject @($Fake.Items | Where-Object label -EQ 'build-1') -Depth 10 | Should -BeExactly $Build1
    }

    It 'gives each set its own sentinel' {
        (Get-FakeItem -Key 'orders-api:Sentinel' -Label 'build-2').value |
            Should -Not -Be (Get-FakeItem -Key 'orders-api:Sentinel' -Label 'build-1').value
    }

    It 're-tags the flags with the new deployment' {
        (Get-FakeItem -Key '.appconfig.featureflag/orders-api.NewCheckout' -Label 'feature-flag').tags.deployment | Should -BeExactly 'build-2'
    }
}

Describe 'Importing changed content under the same label' {
    BeforeAll {
        Initialize-TestEnvironment
        Invoke-TestImport -Label 'build-1' | Out-Null
        Invoke-TestImport -Label 'build-2' | Out-Null
        $script:OldSentinel = (Get-FakeItem -Key 'orders-api:Sentinel' -Label 'build-2').value
        $resolved = Get-ExampleResolved
        $resolved.Settings.Orders.PageSize = 25
        $resolved.Settings.ServiceBus.PSObject.Properties.Remove('QueueName')
        $Fake.Writes.Clear()
        $script:Changes = Invoke-TestImport -Label 'build-2' -Resolved $resolved
    }

    It 'updates the changed key and the sentinel' {
        @($Changes | Where-Object Action -EQ 'Update' | ForEach-Object Name) |
            Should -Be @('orders-api:Orders:PageSize', 'orders-api:Sentinel')
        (Get-FakeItem -Key 'orders-api:Sentinel' -Label 'build-2').value | Should -Not -Be $OldSentinel
    }

    It 'deletes the removed key from that label only' {
        Get-FakeItem -Key 'orders-api:ServiceBus:QueueName' -Label 'build-2' | Should -BeNullOrEmpty
        Get-FakeItem -Key 'orders-api:ServiceBus:QueueName' -Label 'build-1' | Should -Not -BeNullOrEmpty
    }

    It 'still writes the sentinel last' {
        $Fake.Writes[-1] | Should -BeExactly 'kv import: orders-api:Sentinel'
    }
}

Describe 'The enabled state of a flag' {
    BeforeAll {
        Initialize-TestEnvironment
        Invoke-TestImport -Label 'build-1' | Out-Null
        foreach ($entry in @(
                @{ Key = '.appconfig.featureflag/orders-api.NewCheckout'; Label = 'feature-flag'; Enabled = $true },
                @{ Key = '.appconfig.featureflag/orders-api.PaymentProvider'; Label = 'circuit-breaker'; Enabled = $false })) {
            $item = Get-FakeItem -Key $entry.Key -Label $entry.Label
            $value = $item.value | ConvertFrom-Json
            $value.enabled = $entry.Enabled
            $item.value = $value | ConvertTo-Json -Depth 10 -Compress
        }
        Invoke-TestImport -Label 'build-2' | Out-Null
    }

    It 'is kept from the store when a flag already exists' {
        (Get-FlagState -Name 'NewCheckout' -Label 'feature-flag').enabled | Should -BeTrue
        (Get-FlagState -Name 'PaymentProvider' -Label 'circuit-breaker').enabled | Should -BeFalse
    }

    It 'comes from the file for a new flag' {
        Initialize-TestEnvironment
        $root = Join-Path $TestDrive 'enabled'
        $app = New-TestApp -Root $root -Files @{ 'AppConfiguration.FeatureFlags.json' = '[ { "name": "NewCheckout", "enabled": true } ]' }
        Invoke-TestImport -Label 'build-1' -Resolved (Get-ExampleResolved -AppPath $app) | Out-Null
        (Get-FlagState -Name 'NewCheckout' -Label 'feature-flag').enabled | Should -BeTrue
    }
}

Describe 'A dry run' {
    BeforeAll {
        Initialize-TestEnvironment
        $script:Changes = Invoke-TestImport -Label 'build-1' -DryRun
    }

    It 'reports the changes' {
        $Changes.Count | Should -Be 18
    }

    It 'writes nothing' {
        $Fake.Writes | Should -BeNullOrEmpty
        $Fake.Items | Should -BeNullOrEmpty
    }
}

Describe 'Other apps in the same store' {
    It 'are left alone' {
        Initialize-TestEnvironment
        Add-FakeItem -Key 'billing-api:PageSize' -Label 'build-1' -Value '10'
        Add-FakeItem -Key 'orders-api-legacy:PageSize' -Label 'build-1' -Value '10'
        Invoke-TestImport -Label 'build-1' | Out-Null
        Get-FakeItem -Key 'billing-api:PageSize' -Label 'build-1' | Should -Not -BeNullOrEmpty
        Get-FakeItem -Key 'orders-api-legacy:PageSize' -Label 'build-1' | Should -Not -BeNullOrEmpty
    }
}

Describe 'The deployment label' {
    BeforeAll {
        Initialize-TestEnvironment
    }

    It 'rejects <_>' -ForEach @('has space', 'a,b', '*', '-leading', ('x' * 129)) {
        { Invoke-TestImport -Label $_ } | Should -Throw '*not valid*'
    }

    It 'rejects the flag label <_>' -ForEach @('feature-flag', 'circuit-breaker') {
        { Invoke-TestImport -Label $_ } | Should -Throw '*reserved*'
    }
}
