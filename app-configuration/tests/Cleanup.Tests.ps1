BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    # $PSBoundParameters is empty inside a mock body, so the parameters are passed on by name.
    Mock Invoke-AzCli { Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }

    $script:Target = @{ ResourceGroup = $TestResourceGroup; WebAppName = $TestWebApp; StoreEndpoint = $TestStore; AppName = 'orders-api' }

    function Invoke-TestCleanup {
        param([string] $CurrentLabel, [switch] $DryRun)
        @(Invoke-ConfigurationCleanup @Target -CurrentLabel $CurrentLabel -DryRun:$DryRun)
    }

    function Initialize-ThreeDeployments {
        Initialize-TestEnvironment
        Invoke-TestDeployment -Label 'build-1'
        Invoke-TestDeployment -Label 'build-2'
        Invoke-TestDeployment -Label 'build-3'
        Add-FakeItem -Key 'orders-api:Legacy:Setting' -Label $null -Value 'x'
        Add-FakeItem -Key '.appconfig.featureflag/orders-api.RetiredFlag' -Label 'feature-flag' -Value '{"id":"orders-api.RetiredFlag","enabled":false}' -Tags @{ deployment = 'build-1' }
        Add-FakeItem -Key 'billing-api:PageSize' -Label 'build-1' -Value '10'
        Add-FakeItem -Key '.appconfig.featureflag/billing-api.Retired' -Label 'feature-flag' -Value '{}' -Tags @{ deployment = 'build-1' }
    }
}

Describe 'Cleaning up after a successful deployment' {
    BeforeAll {
        Initialize-ThreeDeployments
        $Fake.Writes.Clear()
        $script:Changes = Invoke-TestCleanup -CurrentLabel 'build-3'
    }

    It 'keeps the live set and the set on staging, which is the rollback target' {
        Get-FakeLabels | Should -Be @('build-2', 'build-3')
        Test-ConfigurationSetExists -StoreEndpoint $TestStore -AppName 'orders-api' -Label 'build-2' | Should -BeTrue
        Test-ConfigurationSetExists -StoreEndpoint $TestStore -AppName 'orders-api' -Label 'build-3' | Should -BeTrue
    }

    It 'deletes older sets completely, including the sentinel' {
        @($Fake.Items | Where-Object { $_.label -eq 'build-1' -and $_.key.StartsWith('orders-api:') }) | Should -BeNullOrEmpty
        @($Changes | Where-Object { $_.Label -eq 'build-1' -and $_.Target -eq 'setting' }).Count | Should -Be 14
    }

    It 'deletes unlabelled keys of the app' {
        Get-FakeItem -Key 'orders-api:Legacy:Setting' -Label $null | Should -BeNullOrEmpty
    }

    It 'deletes flags that no kept deployment wrote' {
        Get-FakeItem -Key '.appconfig.featureflag/orders-api.RetiredFlag' -Label 'feature-flag' | Should -BeNullOrEmpty
    }

    It 'keeps the current flags' {
        Get-FakeItem -Key '.appconfig.featureflag/orders-api.NewCheckout' -Label 'feature-flag' | Should -Not -BeNullOrEmpty
        Get-FakeItem -Key '.appconfig.featureflag/orders-api.PaymentProvider' -Label 'circuit-breaker' | Should -Not -BeNullOrEmpty
    }

    It 'leaves other apps alone' {
        Get-FakeItem -Key 'billing-api:PageSize' -Label 'build-1' | Should -Not -BeNullOrEmpty
        Get-FakeItem -Key '.appconfig.featureflag/billing-api.Retired' -Label 'feature-flag' | Should -Not -BeNullOrEmpty
    }

    It 'still allows a rollback' {
        Invoke-ConfigurationRollback @Target -Label 'build-3' | Out-Null
        Get-TestLabel 'production' | Should -BeExactly 'build-2'
    }
}

Describe 'Cleaning up a second time' {
    It 'writes nothing' {
        Initialize-ThreeDeployments
        Invoke-TestCleanup -CurrentLabel 'build-3' | Out-Null
        $Fake.Writes.Clear()
        Invoke-TestCleanup -CurrentLabel 'build-3' | Should -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
    }
}

Describe 'Cleaning up in a dry run' {
    It 'reports the deletes and writes nothing' {
        Initialize-ThreeDeployments
        $before = $Fake.Items.Count
        $Fake.Writes.Clear()
        @(Invoke-TestCleanup -CurrentLabel 'build-3' -DryRun).Count | Should -Be 16
        $Fake.Writes | Should -BeNullOrEmpty
        $Fake.Items.Count | Should -Be $before
    }
}

Describe 'Cleaning up after a swap that failed' {
    BeforeAll {
        Initialize-TestEnvironment
        Invoke-TestDeployment -Label 'build-1'
        Invoke-TestDeployment -Label 'build-2'
        try {
            Invoke-TestDeployment -Label 'build-3' -HealthCheckPath '/health' -Unhealthy
        }
        catch {
            Write-Verbose "Expected: $($_.Exception.Message)"
        }
        Invoke-TestCleanup -CurrentLabel 'build-3' | Out-Null
    }

    It 'keeps the set that production still uses' {
        Get-TestLabel 'production' | Should -BeExactly 'build-2'
        Get-FakeLabels | Should -Be @('build-2', 'build-3')
    }
}

Describe 'Cleaning up with a label that no slot uses' {
    It 'refuses and writes nothing' {
        Initialize-ThreeDeployments
        $Fake.Writes.Clear()
        { Invoke-TestCleanup -CurrentLabel 'build-9' } | Should -Throw '*Refusing to clean up*'
        $Fake.Writes | Should -BeNullOrEmpty
    }
}
