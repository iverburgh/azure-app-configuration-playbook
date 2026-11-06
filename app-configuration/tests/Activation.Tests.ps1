BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    # $PSBoundParameters is empty inside a mock body, so the parameters are passed on by name.
    Mock Invoke-AzCli { Invoke-FakeAzCli -Arguments $Arguments -AllowFailure:$AllowFailure }

    $script:WebApp = @{ ResourceGroup = $TestResourceGroup; WebAppName = $TestWebApp }
    $script:Target = @{ ResourceGroup = $TestResourceGroup; WebAppName = $TestWebApp; StoreEndpoint = $TestStore; AppName = 'orders-api' }

    function Import-TestSet {
        param([string] $Label)
        Invoke-ConfigurationImport -StoreEndpoint $TestStore -Resolved (Get-ExampleResolved) -Label $Label | Out-Null
    }

    function Get-StagingSetting {
        param([string] $Name)
        Get-FakeAppSetting -ResourceGroup $TestResourceGroup -Name $TestWebApp -Slot 'staging' -SettingName $Name
    }

    function Invoke-TestRollback {
        param([string] $Label, [switch] $DryRun)
        @(Invoke-ConfigurationRollback @Target -Label $Label -DryRun:$DryRun -WarningVariable script:RollbackWarnings -WarningAction SilentlyContinue)
    }
}

Describe 'Pointing the staging slot at a configuration set' {
    BeforeAll {
        Initialize-TestEnvironment
        Import-TestSet -Label 'build-1'
        $reference = '@Microsoft.AppConfiguration(Endpoint={0}; Key=orders-api:Orders:PageSize; Label=build-0)' -f $TestStore
        Set-FakeAppSetting -ResourceGroup $TestResourceGroup -Name $TestWebApp -Slot 'staging' -SettingName 'Orders__PageSize' -Value $reference
        $unlabelled = '@Microsoft.AppConfiguration(Endpoint={0}; Key=orders-api:Payments:ApiKey)' -f $TestStore
        Set-FakeAppSetting -ResourceGroup $TestResourceGroup -Name $TestWebApp -Slot 'staging' -SettingName 'Payments__ApiKey' -Value $unlabelled -SlotSetting
        $other = '@Microsoft.AppConfiguration(Endpoint={0}; Key=billing-api:PageSize; Label=v7)' -f $TestStore
        Set-FakeAppSetting -ResourceGroup $TestResourceGroup -Name $TestWebApp -Slot 'staging' -SettingName 'Billing__PageSize' -Value $other
        $script:Changes = @(Invoke-SlotLabelUpdate @Target -Label 'build-1' -HealthCheckPath '/health')
    }

    It 'sets the label setting, not sticky so it moves with the swap' {
        $setting = Get-StagingSetting 'AppConfiguration__Label'
        $setting.value | Should -BeExactly 'build-1'
        $setting.slotSetting | Should -BeFalse
    }

    It 'rewrites the label in references to keys of the app' {
        (Get-StagingSetting 'Orders__PageSize').value | Should -BeExactly ('@Microsoft.AppConfiguration(Endpoint={0}; Key=orders-api:Orders:PageSize; Label=build-1)' -f $TestStore)
    }

    It 'adds a label to a reference without one and keeps it sticky' {
        $setting = Get-StagingSetting 'Payments__ApiKey'
        $setting.value | Should -BeExactly ('@Microsoft.AppConfiguration(Endpoint={0}; Key=orders-api:Payments:ApiKey; Label=build-1)' -f $TestStore)
        $setting.slotSetting | Should -BeTrue
    }

    It 'leaves references to other apps alone' {
        (Get-StagingSetting 'Billing__PageSize').value | Should -Match 'Label=v7\)$'
    }

    It 'sets the warm-up settings, sticky to the staging slot' {
        (Get-StagingSetting 'WEBSITE_SWAP_WARMUP_PING_PATH').value | Should -BeExactly '/health'
        (Get-StagingSetting 'WEBSITE_SWAP_WARMUP_PING_PATH').slotSetting | Should -BeTrue
        (Get-StagingSetting 'WEBSITE_SWAP_WARMUP_PING_STATUSES').value | Should -BeExactly '200'
    }

    It 'does not touch the production slot' {
        @((Get-TestSlot 'production').Settings) | Should -BeNullOrEmpty
    }

    It 'writes nothing the second time' {
        $Fake.Writes.Clear()
        @(Invoke-SlotLabelUpdate @Target -Label 'build-1' -HealthCheckPath '/health') | Should -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'removes the warm-up settings when no health check path is given' {
        Invoke-SlotLabelUpdate @Target -Label 'build-1' | Out-Null
        Get-StagingSetting 'WEBSITE_SWAP_WARMUP_PING_PATH' | Should -BeNullOrEmpty
        Get-StagingSetting 'WEBSITE_SWAP_WARMUP_PING_STATUSES' | Should -BeNullOrEmpty
    }

    It 'writes nothing in a dry run' {
        Import-TestSet -Label 'build-2'
        $Fake.Writes.Clear()
        @(Invoke-SlotLabelUpdate @Target -Label 'build-2' -DryRun) | Should -Not -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
        (Get-StagingSetting 'AppConfiguration__Label').value | Should -BeExactly 'build-1'
    }

    It 'refuses a set that was not imported' {
        { Invoke-SlotLabelUpdate @Target -Label 'build-9' } | Should -Throw "*'build-9'*does not exist*"
    }
}

Describe 'Pointing staging at the set that production already uses' {
    It 'leaves staging alone, so a rerun keeps the rollback target' {
        Initialize-TestEnvironment
        Invoke-TestDeployment -Label 'build-1'
        Invoke-TestDeployment -Label 'build-2'
        $Fake.Writes.Clear()
        @(Invoke-SlotLabelUpdate @Target -Label 'build-2' -HealthCheckPath '/health') | Should -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
        Get-TestLabel 'staging' | Should -BeExactly 'build-1'
    }
}

Describe 'Switching to a configuration set' {
    BeforeEach {
        Initialize-TestEnvironment
        Invoke-TestDeployment -Label 'build-1'
        Import-TestSet -Label 'build-2'
        Invoke-SlotLabelUpdate @Target -Label 'build-2' | Out-Null
        $Fake.Writes.Clear()
    }

    It 'swaps staging into production' {
        $change = Invoke-ConfigurationSwitch @WebApp -Label 'build-2'
        Get-TestLabel 'production' | Should -BeExactly 'build-2'
        Get-TestLabel 'staging' | Should -BeExactly 'build-1'
        $change.Detail | Should -BeExactly 'previous=build-1'
        $Fake.Writes | Should -Be @('slot swap: staging -> production')
    }

    It 'does nothing when production already uses the set' {
        Invoke-ConfigurationSwitch @WebApp -Label 'build-2' | Out-Null
        $Fake.Writes.Clear()
        Invoke-ConfigurationSwitch @WebApp -Label 'build-2' | Should -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'refuses when staging uses another set' {
        { Invoke-ConfigurationSwitch @WebApp -Label 'build-3' } | Should -Throw "*staging slot uses configuration set 'build-2'*"
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'writes nothing in a dry run' {
        Invoke-ConfigurationSwitch @WebApp -Label 'build-2' -DryRun | Should -Not -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
        Get-TestLabel 'production' | Should -BeExactly 'build-1'
    }
}

Describe 'A deployment that fails after the swap' {
    BeforeAll {
        Initialize-TestEnvironment
        Invoke-TestDeployment -Label 'build-1'
        Invoke-TestDeployment -Label 'build-2'
        Invoke-TestDeployment -Label 'build-3' -HealthCheckPath '/health'
        $script:BeforeRollback = @{ Production = Get-TestLabel 'production'; Staging = Get-TestLabel 'staging' }
        # A smoke test after the swap fails, so the pipeline rolls back build-3.
        $script:Changes = Invoke-TestRollback -Label 'build-3'
    }

    It 'had build-3 live and build-2 on staging before the rollback' {
        $BeforeRollback.Production | Should -BeExactly 'build-3'
        $BeforeRollback.Staging | Should -BeExactly 'build-2'
    }

    It 'puts the previous configuration set back in production' {
        Get-TestLabel 'production' | Should -BeExactly 'build-2'
        Get-TestLabel 'staging' | Should -BeExactly 'build-3'
    }

    It 'puts the previous code back in production' {
        (Get-TestSlot 'production').Code | Should -BeExactly 'build-2'
    }

    It 'removes the warm-up settings from staging first' {
        Get-StagingSetting 'WEBSITE_SWAP_WARMUP_PING_PATH' | Should -BeNullOrEmpty
        @($Changes | ForEach-Object Action) | Should -Be @('Delete', 'Delete', 'Swap')
        $Changes[-1].Label | Should -BeExactly 'build-2'
    }

    It 'keeps every configuration set in the store' {
        Get-FakeLabels | Should -Be @('build-1', 'build-2', 'build-3')
    }

    It 'does nothing when run again' {
        $Fake.Writes.Clear()
        Invoke-TestRollback -Label 'build-3' | Should -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
        $RollbackWarnings | Should -Match "uses configuration set 'build-2', not 'build-3'"
    }
}

Describe 'A deployment whose swap fails the warm-up check' {
    BeforeAll {
        Initialize-TestEnvironment
        Invoke-TestDeployment -Label 'build-1'
        Invoke-TestDeployment -Label 'build-2'
        $script:SwapError = $null
        try {
            Invoke-TestDeployment -Label 'build-3' -HealthCheckPath '/health' -Unhealthy
        }
        catch {
            $script:SwapError = $_.Exception.Message
        }
        $Fake.Writes.Clear()
        $script:Changes = Invoke-TestRollback -Label 'build-3'
    }

    It 'fails the swap' {
        $SwapError | Should -Match 'warm-up request'
    }

    It 'leaves production on the previous set and code' {
        Get-TestLabel 'production' | Should -BeExactly 'build-2'
        (Get-TestSlot 'production').Code | Should -BeExactly 'build-2'
    }

    It 'makes the rollback a no-op with a warning' {
        $Changes | Should -BeNullOrEmpty
        $Fake.Writes | Should -BeNullOrEmpty
        $RollbackWarnings | Should -Match 'Nothing to roll back'
    }
}

Describe 'A rollback that cannot be done' {
    BeforeEach {
        Initialize-TestEnvironment
    }

    It 'refuses when there is no previous set' {
        Invoke-TestDeployment -Label 'build-1'
        { Invoke-TestRollback -Label 'build-1' } | Should -Throw '*no previous configuration set*'
        Get-TestLabel 'production' | Should -BeExactly 'build-1'
    }

    It 'refuses when both slots use the failed set' {
        Invoke-TestDeployment -Label 'build-1'
        Set-FakeAppSetting -ResourceGroup $TestResourceGroup -Name $TestWebApp -Slot 'staging' -SettingName 'AppConfiguration__Label' -Value 'build-1'
        { Invoke-TestRollback -Label 'build-1' } | Should -Throw '*also uses*'
    }

    It 'refuses when the previous set is gone from the store' {
        Invoke-TestDeployment -Label 'build-1'
        Invoke-TestDeployment -Label 'build-2'
        Remove-StoreItem -StoreEndpoint $TestStore -Key 'orders-api:Sentinel' -Label 'build-1'
        $Fake.Writes.Clear()
        { Invoke-TestRollback -Label 'build-2' } | Should -Throw "*'build-1' no longer exists*"
        $Fake.Writes | Should -BeNullOrEmpty
    }

    It 'writes nothing in a dry run' {
        Invoke-TestDeployment -Label 'build-1'
        Invoke-TestDeployment -Label 'build-2'
        $Fake.Writes.Clear()
        @(Invoke-TestRollback -Label 'build-2' -DryRun).Count | Should -Be 1
        $Fake.Writes | Should -BeNullOrEmpty
        Get-TestLabel 'production' | Should -BeExactly 'build-2'
    }
}
