BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"

    function Invoke-Expand {
        param([string] $Text, [hashtable] $Values = @{})
        $variables = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
        foreach ($name in $Values.Keys) {
            $variables[$name] = $Values[$name]
        }
        $errors = [System.Collections.Generic.List[string]]::new()
        $result = Expand-TokenString -Text $Text -Variables $variables -Path 'test' -Errors $errors
        [pscustomobject]@{ Result = $result; Errors = [string[]]$errors.ToArray() }
    }
}

Describe 'Variables per environment' {
    It 'lets the environment file override common.json' {
        (Get-TestVariables -Environment 'dev')['LogLevel'] | Should -BeExactly 'Debug'
        (Get-TestVariables -Environment 'test')['LogLevel'] | Should -BeExactly 'Information'
        (Get-TestVariables -Environment 'prod')['LogLevel'] | Should -BeExactly 'Warning'
    }

    It 'resolves variables that refer to other variables' {
        (Get-TestVariables -Environment 'test')['KeyVaultUri'] | Should -BeExactly 'https://kv-orders-test.vault.azure.net'
        (Get-TestVariables -Environment 'dev')['PaymentsBaseUrl'] | Should -BeExactly 'https://payments-dev.example.com/api/'
    }

    It 'writes numbers and booleans as invariant strings' {
        $root = Join-Path $TestDrive 'numbers'
        $path = New-TestVariables -Root $root -Files @{ 'test.json' = '{ "variables": { "EnvironmentName": "test", "Ratio": 0.5, "Enabled": true, "ExpressShippingPercentage": 50 } }' }
        $variables = Get-DeploymentVariables -VariablesPath $path -Environment 'test'
        $variables['Ratio'] | Should -BeExactly '0.5'
        $variables['Enabled'] | Should -BeExactly 'true'
        $variables['PaymentsTimeoutSeconds'] | Should -BeExactly '30'
    }

    It 'treats variable names as case-sensitive' {
        $variables = Get-TestVariables
        $variables.ContainsKey('loglevel') | Should -BeFalse
    }

    It 'fails on an unknown environment' {
        { Get-TestVariables -Environment 'staging' } | Should -Throw "*Unknown environment 'staging'*"
    }

    It 'rejects common as an environment name' {
        { Get-TestVariables -Environment 'common' } | Should -Throw '*not valid*'
    }

    It 'fails on a circular reference' {
        $root = Join-Path $TestDrive 'cycle'
        $path = New-TestVariables -Root $root -Files @{ 'test.json' = '{ "variables": { "A": "#{B}#", "B": "x-#{A}#" } }' }
        { Get-DeploymentVariables -VariablesPath $path -Environment 'test' } | Should -Throw '*circular reference*'
    }

    It 'fails on a reference to an unknown variable' {
        $root = Join-Path $TestDrive 'unknown'
        $path = New-TestVariables -Root $root -Files @{ 'test.json' = '{ "variables": { "A": "#{Missing}#" } }' }
        { Get-DeploymentVariables -VariablesPath $path -Environment 'test' } | Should -Throw "*unknown token '#{Missing}#'*"
    }

    It 'fails on an invalid variable name' {
        $root = Join-Path $TestDrive 'name'
        $path = New-TestVariables -Root $root -Files @{ 'test.json' = '{ "variables": { "1st": "x" } }' }
        { Get-DeploymentVariables -VariablesPath $path -Environment 'test' } | Should -Throw "*Variable name '1st'*"
    }

    It 'fails when the variables object is missing' {
        $root = Join-Path $TestDrive 'missing'
        $path = New-TestVariables -Root $root -Files @{ 'test.json' = '{ "values": {} }' }
        { Get-DeploymentVariables -VariablesPath $path -Environment 'test' } | Should -Throw "*object named 'variables'*"
    }

    It 'fails on a null value' {
        $root = Join-Path $TestDrive 'null'
        $path = New-TestVariables -Root $root -Files @{ 'test.json' = '{ "variables": { "A": null } }' }
        { Get-DeploymentVariables -VariablesPath $path -Environment 'test' } | Should -Throw '*Null values*'
    }
}

Describe 'Token replacement in a string' {
    It 'replaces every token' {
        $result = Invoke-Expand -Text 'https://#{Name}#.example.com/#{Path}#' -Values @{ Name = 'orders'; Path = 'api' }
        $result.Result | Should -BeExactly 'https://orders.example.com/api'
        $result.Errors | Should -BeNullOrEmpty
    }

    It 'leaves text without tokens alone' {
        (Invoke-Expand -Text 'plain {text} #not a token#').Result | Should -BeExactly 'plain {text} #not a token#'
    }

    It 'reports an unknown token' {
        (Invoke-Expand -Text '#{Missing}#').Errors | Should -Match "unknown token '#\{Missing\}#'"
    }

    It 'reports a token with an empty value' {
        (Invoke-Expand -Text '#{Empty}#' -Values @{ Empty = '' }).Errors | Should -Match 'empty value'
    }

    It 'reports an unterminated token' {
        (Invoke-Expand -Text 'x-#{Name' -Values @{ Name = 'a' }).Errors | Should -Match 'unterminated token'
    }

    It 'reports a malformed token' {
        (Invoke-Expand -Text '#{not valid}#').Errors | Should -Match "malformed token"
    }

    It 'matches names case-sensitively' {
        (Invoke-Expand -Text '#{name}#' -Values @{ Name = 'a' }).Errors | Should -Match 'unknown token'
    }
}

Describe 'Token replacement in an app' {
    BeforeAll {
        $script:Resolved = Get-ExampleResolved -Environment 'prod'
    }

    It 'replaces tokens in nested values' {
        $Resolved.Settings.Logging.LogLevel.Default | Should -BeExactly 'Warning'
        $Resolved.Settings.Orders.PublicBaseUrl | Should -BeExactly 'https://orders-prod.example.com/'
        $Resolved.Settings.Payments.TimeoutSeconds | Should -BeExactly '10'
    }

    It 'replaces tokens in Key Vault references' {
        $Resolved.KeyVault.Payments.ApiKey.uri | Should -BeExactly 'https://kv-orders-prod.vault.azure.net/secrets/payments-api-key'
    }

    It 'replaces tokens in feature flag parameters' {
        $flag = @($Resolved.FeatureFlags | Where-Object name -EQ 'ExpressShipping')[0]
        $flag.conditions.client_filters[0].parameters.Value | Should -BeExactly '10'
    }

    It 'keeps arrays and non-string values' {
        $Resolved.Settings.Orders.RetryDelays | Should -Be @('00:00:01', '00:00:05', '00:00:30')
        $Resolved.Settings.Orders.PageSize | Should -Be 50
        $Resolved.Settings.Orders.AllowGuestCheckout | Should -BeTrue
    }

    It 'replaces tokens in array elements' {
        $root = Join-Path $TestDrive 'array'
        $app = New-TestApp -Root $root -Files @{ 'AppConfiguration.json' = '{ "Hosts": [ "a-#{EnvironmentName}#", "b" ] }' }
        (Resolve-AppConfiguration -AppPath $app -Variables (Get-TestVariables)).Settings.Hosts | Should -Be @('a-test', 'b')
    }

    It 'fails on an unknown token and names the file and path' {
        $root = Join-Path $TestDrive 'unknown-app'
        $app = New-TestApp -Root $root -Files @{ 'AppConfiguration.json' = '{ "Orders": { "Region": "#{Region}#" } }' }
        { Resolve-AppConfiguration -AppPath $app -Variables (Get-TestVariables) } |
            Should -Throw "*AppConfiguration.json.Orders.Region: unknown token '#{Region}#'*"
    }

    It 'fails on a token in a key' {
        $root = Join-Path $TestDrive 'key-token'
        $app = New-TestApp -Root $root -Files @{ 'AppConfiguration.json' = '{ "#{EnvironmentName}#": "x" }' }
        { Resolve-AppConfiguration -AppPath $app -Variables (Get-TestVariables) } | Should -Throw '*tokens are not allowed in keys*'
    }

    It 'treats missing optional files as empty' {
        $root = Join-Path $TestDrive 'minimal'
        $app = New-TestApp -Root $root -Files @{
            'AppConfiguration.KeyVault.json'            = $null
            'AppConfiguration.FeatureFlags.json'        = $null
            'AppConfiguration.CircuitBreakerFlags.json' = $null
        }
        $resolved = Resolve-AppConfiguration -AppPath $app -Variables (Get-TestVariables)
        @($resolved.KeyVault.PSObject.Properties).Count | Should -Be 0
        @($resolved.FeatureFlags).Count | Should -Be 0
    }

    It 'fails when AppConfiguration.json is missing' {
        $root = Join-Path $TestDrive 'no-settings'
        $app = New-TestApp -Root $root -Files @{ 'AppConfiguration.json' = $null }
        { Resolve-AppConfiguration -AppPath $app -Variables (Get-TestVariables) } | Should -Throw '*does not exist*'
    }
}
