BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"

    function Get-VariantErrors {
        param([string] $Name, [hashtable] $Files, [string] $AppName = 'orders-api')
        $app = New-TestApp -Root (Join-Path $TestDrive $Name) -Name $AppName -Files $Files
        @(Get-ValidationErrors -AppPath $app)
    }
}

Describe 'The example app' {
    It 'is valid for <_>' -ForEach @('dev', 'test', 'prod') {
        @(Get-ValidationErrors -AppPath $ExampleAppPath -Environment $_) | Should -BeNullOrEmpty
    }

    It 'is reported as valid for every app and environment' {
        $results = @(Get-AppConfigurationValidationResult -AppsPath $ExampleAppsPath -VariablesPath $ExampleVariablesPath -SchemaPath $SchemaPath)
        $results.Count | Should -Be 3
        @($results | Where-Object { $_.Errors.Count -gt 0 }) | Should -BeNullOrEmpty
    }
}

Describe 'JSON structure' {
    It 'rejects a duplicate key' {
        Get-VariantErrors 'dup' @{ 'AppConfiguration.json' = '{ "Orders": { "PageSize": 1, "PageSize": 2 } }' } |
            Should -Match "duplicate key '\$\.Orders\.PageSize'"
    }

    It 'rejects keys that differ only in case' {
        Get-VariantErrors 'case' @{ 'AppConfiguration.json' = '{ "Orders": { "PageSize": 1, "pagesize": 2 } }' } |
            Should -Match 'pagesize'
    }

    It 'rejects invalid JSON' {
        Get-VariantErrors 'syntax' @{ 'AppConfiguration.json' = '{ "Orders": ' } | Should -Match 'AppConfiguration.json'
    }

    It 'rejects a null value' {
        Get-VariantErrors 'null' @{ 'AppConfiguration.json' = '{ "Orders": { "Region": null } }' } | Should -Match 'null values are not supported'
    }

    It 'rejects a key that contains a colon' {
        Get-VariantErrors 'colon' @{ 'AppConfiguration.json' = '{ "Orders": { "A:B": "x" } }' } | Should -Match "must not be empty or contain ':'"
    }

    It 'rejects a top-level key that contains a colon' {
        Get-VariantErrors 'colon-top' @{ 'AppConfiguration.json' = '{ "A:B": "x" }' } | Should -Not -BeNullOrEmpty
    }

    It 'rejects an invalid app folder name' {
        Get-VariantErrors 'name' @{} -AppName 'Orders_API' | Should -Match 'App folder name'
    }

    It 'requires AppConfiguration.json' {
        Get-VariantErrors 'missing' @{ 'AppConfiguration.json' = $null } | Should -Match 'AppConfiguration.json is missing'
    }

    It 'rejects an invalid variables file' {
        $root = Join-Path $TestDrive 'variables'
        $variables = New-TestVariables -Root $root -Files @{ 'test.json' = '{ "variables": { "A": { "nested": true } } }' }
        @(Get-ValidationErrors -AppPath $ExampleAppPath -VariablesPath $variables) | Should -Match 'test.json'
    }
}

Describe 'Key Vault references' {
    It 'rejects a value that is not a reference object' {
        Get-VariantErrors 'kv-string' @{ 'AppConfiguration.KeyVault.json' = '{ "Payments": { "ApiKey": "secret" } }' } |
            Should -Match "must be a Key Vault reference"
    }

    It 'rejects a reference with extra properties' {
        Get-VariantErrors 'kv-extra' @{ 'AppConfiguration.KeyVault.json' = '{ "ApiKey": { "uri": "https://kv-orders.vault.azure.net/secrets/a", "version": "1" } }' } |
            Should -Match 'must be exactly'
    }

    It 'rejects a URI that does not point to a secret' {
        Get-VariantErrors 'kv-uri' @{ 'AppConfiguration.KeyVault.json' = '{ "ApiKey": { "uri": "https://example.com/secrets/a" } }' } |
            Should -Match "expected https://<vault>.vault.azure.net"
    }

    It 'accepts a versioned secret URI' {
        Get-VariantErrors 'kv-version' @{ 'AppConfiguration.KeyVault.json' = '{ "ApiKey": { "uri": "https://kv-orders.vault.azure.net/secrets/api-key/0123456789abcdef0123456789abcdef" } }' } |
            Should -BeNullOrEmpty
    }

    It 'rejects a key that is also a setting' {
        Get-VariantErrors 'kv-collision' @{ 'AppConfiguration.KeyVault.json' = '{ "Payments": { "BaseUrl": { "uri": "#{KeyVaultUri}#/secrets/base-url" } } }' } |
            Should -Match 'is also defined in AppConfiguration.json'
    }
}

Describe 'Feature flags and circuit breakers' {
    It 'rejects a flag without a name' {
        Get-VariantErrors 'ff-noname' @{ 'AppConfiguration.FeatureFlags.json' = '[ { "description": "x" } ]' } |
            Should -Match 'AppConfiguration.FeatureFlags.json'
    }

    It 'rejects a flag name in the wrong format' {
        Get-VariantErrors 'ff-name' @{ 'AppConfiguration.FeatureFlags.json' = '[ { "name": "new-checkout" } ]' } |
            Should -Match 'AppConfiguration.FeatureFlags.json'
    }

    It 'rejects unknown properties' {
        Get-VariantErrors 'ff-extra' @{ 'AppConfiguration.CircuitBreakerFlags.json' = '[ { "name": "Payments", "owner": "x" } ]' } |
            Should -Match 'AppConfiguration.CircuitBreakerFlags.json'
    }

    It 'rejects a flag file that is not an array' {
        Get-VariantErrors 'ff-object' @{ 'AppConfiguration.FeatureFlags.json' = '{ "name": "NewCheckout" }' } |
            Should -Match 'AppConfiguration.FeatureFlags.json'
    }

    It 'rejects the same flag in both files' {
        Get-VariantErrors 'ff-dup' @{ 'AppConfiguration.CircuitBreakerFlags.json' = '[ { "name": "NewCheckout" } ]' } |
            Should -Match "flag 'NewCheckout' is already defined"
    }

    It 'rejects a percentage outside 0..100' {
        Get-VariantErrors 'ff-pct' @{ 'AppConfiguration.FeatureFlags.json' = '[ { "name": "Rollout", "conditions": { "client_filters": [ { "name": "Microsoft.Percentage", "parameters": { "Value": 150 } } ] } } ]' } |
            Should -Match 'between 0 and 100'
    }
}

Describe 'Other rules' {
    It 'reserves the top-level key Sentinel' {
        Get-VariantErrors 'sentinel' @{ 'AppConfiguration.json' = '{ "Sentinel": "x" }' } | Should -Match 'reserved for the change sentinel'
    }

    It 'reports an unknown token as an error' {
        Get-VariantErrors 'token' @{ 'AppConfiguration.json' = '{ "Region": "#{Region}#" }' } | Should -Match "unknown token '#\{Region\}#'"
    }

    It 'reports a token with an empty value' {
        $root = Join-Path $TestDrive 'empty-variable'
        $variables = New-TestVariables -Root $root -Files @{ 'test.json' = '{ "variables": { "EnvironmentName": "test", "LogLevel": "", "ExpressShippingPercentage": 50 } }' }
        @(Get-ValidationErrors -AppPath $ExampleAppPath -VariablesPath $variables) | Should -Match 'empty value'
    }
}

Describe 'Test-AppConfiguration.ps1' {
    It 'exits with 0 on the example' {
        $output = & pwsh -NoProfile -File (Join-Path $PlaybookRoot 'Test-AppConfiguration.ps1') 2>&1
        $LASTEXITCODE | Should -Be 0
        ($output -join "`n") | Should -Match '3 of 3'
    }

    It 'exits with 1 on a broken app' {
        $root = Join-Path $TestDrive 'script'
        New-TestApp -Root $root -Files @{ 'AppConfiguration.json' = '{ "Region": "#{Region}#" }' } | Out-Null
        $output = & pwsh -NoProfile -File (Join-Path $PlaybookRoot 'Test-AppConfiguration.ps1') -AppsPath (Join-Path $root 'apps') -Environment 'test' 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'FAIL'
    }
}
