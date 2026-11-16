BeforeAll {
    . "$PSScriptRoot/TestSystem.ps1"
    . (Join-Path $PlaybookRoot 'lib/PipelineVariables.ps1')

    $script:Generator = Join-Path $PlaybookRoot 'New-PipelineVariables.ps1'
    $script:AppTokens = @('EnvironmentName', 'ExpressShippingPercentage', 'FreeShippingThreshold', 'KeyVaultUri', 'LogLevel', 'PaymentsBaseUrl', 'PaymentsTimeoutSeconds')

    function New-TestRepository {
        <#
        .SYNOPSIS
            Creates a repository in TestDrive: the example app and variables, plus the given
            pipelines (name to YAML), settings (name to JSON) and templates (path under
            pipelines/ to YAML). Returns the parameters for the generator.
        #>
        param(
            [hashtable] $Pipelines = @{},
            [hashtable] $Settings = @{},
            [hashtable] $Templates = @{},
            [hashtable] $Variables = @{}
        )
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $configuration = Join-Path $root 'app-configuration'
        $pipelinesPath = Join-Path $root 'pipelines'
        New-Item -ItemType Directory -Path $pipelinesPath -Force | Out-Null
        New-TestApp -Root $configuration | Out-Null
        $variablesPath = New-TestVariables -Root $configuration -Files $Variables
        foreach ($name in $Pipelines.Keys) {
            Set-Content -LiteralPath (Join-Path $pipelinesPath "$name.yml") -Value $Pipelines[$name] -Encoding utf8NoBOM
        }
        foreach ($name in $Settings.Keys) {
            Set-Content -LiteralPath (Join-Path $pipelinesPath "$name.variables.json") -Value $Settings[$name] -Encoding utf8NoBOM
        }
        foreach ($path in $Templates.Keys) {
            $file = Join-Path $pipelinesPath $path
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            Set-Content -LiteralPath $file -Value $Templates[$path] -Encoding utf8NoBOM
        }
        @{
            RepositoryRoot = $root
            PipelinesPath  = $pipelinesPath
            AppsPath       = Join-Path $configuration 'apps'
            VariablesPath  = $variablesPath
            SchemaPath     = $SchemaPath
        }
    }

    function Invoke-Generator {
        <# Runs the generator; returns its objects, with warnings as WarningRecord objects. #>
        param([hashtable] $Repository, [hashtable] $Parameters = @{})
        $all = $Repository + $Parameters
        & $script:Generator @all 3>&1 6>$null
    }

    function Get-GeneratedPath {
        param([hashtable] $Repository, [string] $Pipeline, [string] $Environment)
        Join-Path $Repository.PipelinesPath "variables/$Pipeline/$Environment.yml"
    }

    function Get-GeneratedVariables {
        <# Parses a generated file into an ordered name-to-value dictionary. #>
        param([hashtable] $Repository, [string] $Pipeline, [string] $Environment)
        $result = [ordered]@{}
        foreach ($line in [System.IO.File]::ReadAllLines((Get-GeneratedPath $Repository $Pipeline $Environment))) {
            if ($line -match "^  ([^:]+): '(.*)'$") {
                $result[$Matches[1]] = $Matches[2].Replace("''", "'")
            }
        }
        $result
    }

    function Get-Warnings {
        param([object[]] $Output)
        @(foreach ($item in $Output) { if ($item -is [System.Management.Automation.WarningRecord]) { $item.Message } })
    }

    $script:ToolsYaml = @'
steps:
- pwsh: Write-Host '$(LogLevel)' '$(Build.BuildNumber)' '$(NotDefinedAnywhere)'
- pwsh: Write-Host '${{ variables.PaymentsBaseUrl }}'
  condition: ne(variables['KeyVaultUri'], '')
# - pwsh: Write-Host '$(FreeShippingThreshold)'
'@
}

Describe 'New-PipelineVariables.ps1' {
    It 'writes only the variables the pipeline uses' {
        $repository = New-TestRepository -Pipelines @{ tools = $ToolsYaml }
        Invoke-Generator $repository | Out-Null
        foreach ($environment in 'dev', 'prod', 'test') {
            @((Get-GeneratedVariables $repository 'tools' $environment).Keys) | Should -Be @('KeyVaultUri', 'LogLevel', 'PaymentsBaseUrl')
        }
        (Get-GeneratedVariables $repository 'tools' 'prod').LogLevel | Should -Be 'Warning'
    }

    It 'adds the tokens of the apps the pipeline deploys and follows local templates' {
        $repository = New-TestRepository -Pipelines @{ 'orders-api' = "steps:`n- template: templates/steps.yml`n- template: variables/orders-api/`${{ parameters.environment }}.yml" } -Templates @{
            'templates/steps.yml' = "steps:`n- template: nested.yml"
            'templates/nested.yml' = "steps:`n- pwsh: Write-Host '`$(ResourceGroupName)'"
        } -Variables @{ 'common.json' = '{ "variables": { "LogLevel": "Information", "KeyVaultUri": "https://kv-#{EnvironmentName}#.vault.azure.net", "PaymentsBaseUrl": "https://payments.example.com/", "PaymentsTimeoutSeconds": 30, "FreeShippingThreshold": "50.00", "ResourceGroupName": "rg-#{EnvironmentName}#", "Unused": "x" } }' }
        $output = @(Invoke-Generator $repository)
        Get-Warnings $output | Should -BeNullOrEmpty
        $variables = Get-GeneratedVariables $repository 'orders-api' 'test'
        @($variables.Keys) | Should -Be (@($AppTokens) + 'ResourceGroupName' | Sort-Object)
        $variables.ResourceGroupName | Should -Be 'rg-test'
    }

    It 'lets an environment override win over a common override, and both over the variables files' {
        $repository = New-TestRepository -Pipelines @{ tools = $ToolsYaml } -Settings @{
            tools = '{ "overrides": { "common": { "LogLevel": "Error", "WebAppName": "app-#{EnvironmentName}#" }, "prod": { "LogLevel": "Critical" } } }'
        }
        Invoke-Generator $repository | Out-Null
        $dev = Get-GeneratedVariables $repository 'tools' 'dev'
        $prod = Get-GeneratedVariables $repository 'tools' 'prod'
        $dev.LogLevel | Should -Be 'Error'
        $prod.LogLevel | Should -Be 'Critical'
        $dev.WebAppName | Should -Be 'app-dev'
        $prod.WebAppName | Should -Be 'app-prod'
    }

    It 'ignores overrides for an environment without a variables file, with a warning' {
        $repository = New-TestRepository -Pipelines @{ tools = $ToolsYaml } -Settings @{
            tools = '{ "overrides": { "staging": { "LogLevel": "Trace" } } }'
        }
        $output = @(Invoke-Generator $repository)
        Get-Warnings $output | Should -Match "overrides for environment 'staging' are ignored"
        @(Get-ChildItem -LiteralPath (Join-Path $repository.PipelinesPath 'variables/tools') | ForEach-Object Name | Sort-Object) | Should -Be @('dev.yml', 'prod.yml', 'test.yml')
        (Get-GeneratedVariables $repository 'tools' 'dev').LogLevel | Should -Be 'Debug'
    }

    It 'adds extra keys, with an empty value for one the environment does not define' {
        $repository = New-TestRepository -Pipelines @{ tools = $ToolsYaml } -Settings @{
            tools = '{ "extraKeys": [ "FreeShippingThreshold", "NotDefined" ] }'
        }
        $output = @(Invoke-Generator $repository)
        Get-Warnings $output | Should -Match "extra key 'NotDefined' is not defined"
        $variables = Get-GeneratedVariables $repository 'tools' 'test'
        $variables.FreeShippingThreshold | Should -Be '50.00'
        $variables.Contains('NotDefined') | Should -BeTrue
        $variables.NotDefined | Should -Be ''
    }

    It 'adds every variable for the extra key *' {
        $repository = New-TestRepository -Pipelines @{ tools = 'steps: []' } -Settings @{ tools = '{ "extraKeys": [ "*" ] }' }
        Invoke-Generator $repository | Out-Null
        $expected = @((Get-DeploymentVariables -VariablesPath $repository.VariablesPath -Environment 'prod').Keys | Sort-Object)
        @((Get-GeneratedVariables $repository 'tools' 'prod').Keys) | Should -Be $expected
    }

    It 'writes the header, sorted names, quoted culture-invariant values and LF line endings' {
        $repository = New-TestRepository -Pipelines @{ tools = $ToolsYaml } -Settings @{
            tools = '{ "overrides": { "common": { "Ratio": 1.5, "Quote": "it''s", "apiVersion": "2" } } }'
        }
        $culture = [System.Globalization.CultureInfo]::CurrentCulture
        try {
            [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
            Invoke-Generator $repository | Out-Null
        }
        finally {
            [System.Globalization.CultureInfo]::CurrentCulture = $culture
        }
        $text = [System.IO.File]::ReadAllText((Get-GeneratedPath $repository 'tools' 'dev'))
        $text | Should -BeLike '# AUTO-GENERATED by app-configuration/New-PipelineVariables.ps1. Do not edit this file.*'
        $text.Contains("`r") | Should -BeFalse
        $text.EndsWith("`n") | Should -BeTrue
        $text | Should -Match "(?m)^  Quote: 'it''s'$"
        $text | Should -Match "(?m)^  Ratio: '1.5'$"
        @((Get-GeneratedVariables $repository 'tools' 'dev').Keys) | Should -Be @('apiVersion', 'KeyVaultUri', 'LogLevel', 'PaymentsBaseUrl', 'Quote', 'Ratio')
    }

    It 'writes an empty variables block when the pipeline uses no variable' {
        $repository = New-TestRepository -Pipelines @{ tools = 'steps: []' }
        Invoke-Generator $repository | Out-Null
        [System.IO.File]::ReadAllLines((Get-GeneratedPath $repository 'tools' 'dev'))[-1] | Should -Be 'variables: {}'
    }

    It 'is deterministic: a second run changes nothing' {
        $repository = New-TestRepository -Pipelines @{ tools = $ToolsYaml; 'orders-api' = 'steps: []' }
        Invoke-Generator $repository | Out-Null
        $path = Get-GeneratedPath $repository 'tools' 'prod'
        $first = [System.IO.File]::ReadAllText($path)
        $written = (Get-Item -LiteralPath $path).LastWriteTimeUtc
        Start-Sleep -Milliseconds 50

        $second = @(Invoke-Generator $repository @{ PassThru = $true })

        @($second | ForEach-Object Action | Sort-Object -Unique) | Should -Be @('Unchanged')
        $second.Count | Should -Be 6
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $first
        (Get-Item -LiteralPath $path).LastWriteTimeUtc | Should -Be $written
    }

    It '-Check passes when up to date, reports drift with exit code 1 and writes nothing' {
        $repository = New-TestRepository -Pipelines @{ tools = $ToolsYaml }
        Invoke-Generator $repository | Out-Null
        Invoke-Generator $repository @{ Check = $true } | Out-Null
        $LASTEXITCODE | Should -Be 0

        $path = Get-GeneratedPath $repository 'tools' 'dev'
        $before = [System.IO.File]::ReadAllText($path)
        Set-Content -LiteralPath (Join-Path $repository.VariablesPath 'dev.json') -Value '{ "variables": { "EnvironmentName": "dev", "LogLevel": "Trace", "ExpressShippingPercentage": 1 } }' -Encoding utf8NoBOM
        Invoke-Generator $repository @{ Check = $true } | Out-Null
        $LASTEXITCODE | Should -Be 1
        [System.IO.File]::ReadAllText($path) | Should -BeExactly $before
    }

    It '-Check accepts a file checked out with CRLF line endings' {
        $repository = New-TestRepository -Pipelines @{ tools = $ToolsYaml }
        Invoke-Generator $repository | Out-Null
        $path = Get-GeneratedPath $repository 'tools' 'dev'
        [System.IO.File]::WriteAllText($path, ([System.IO.File]::ReadAllText($path) -replace "`n", "`r`n"))
        Invoke-Generator $repository @{ Check = $true } | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It '-WhatIf writes nothing' {
        $repository = New-TestRepository -Pipelines @{ tools = $ToolsYaml }
        $output = @(Invoke-Generator $repository @{ WhatIf = $true; PassThru = $true })
        @($output | ForEach-Object Action | Sort-Object -Unique) | Should -Be @('Create')
        Test-Path -LiteralPath (Join-Path $repository.PipelinesPath 'variables') | Should -BeFalse
    }

    It 'deletes generated files nobody needs any more, but never a file without the header' {
        $repository = New-TestRepository -Pipelines @{ tools = $ToolsYaml }
        Invoke-Generator $repository | Out-Null
        $folder = Join-Path $repository.PipelinesPath 'variables/tools'
        Set-Content -LiteralPath (Join-Path $folder 'manual.yml') -Value "variables:`n  Keep: 'me'" -Encoding utf8NoBOM
        Remove-Item -LiteralPath (Join-Path $repository.VariablesPath 'test.json')

        Invoke-Generator $repository | Out-Null

        @(Get-ChildItem -LiteralPath $folder | ForEach-Object Name | Sort-Object) | Should -Be @('dev.yml', 'manual.yml', 'prod.yml')
    }

    It 'rejects variable names that differ only in case' {
        $repository = New-TestRepository -Pipelines @{ tools = $ToolsYaml } -Settings @{ tools = '{ "overrides": { "common": { "loglevel": "Error" } } }' }
        { Invoke-Generator $repository } | Should -Throw '*differ only in case*'
    }

    It 'rejects <Name>, which cannot be a pipeline variable' -TestCases @(
        @{ Name = 'secretToken'; Message = '*prefix Azure Pipelines reserves*' }
        @{ Name = 'Endpoint.Url'; Message = '*prefix Azure Pipelines reserves*' }
        @{ Name = 'Base-Url'; Message = "*letters, digits, '.' and '_' only*" }
    ) {
        $repository = New-TestRepository -Pipelines @{ tools = 'steps: []' } -Settings @{ tools = "{ `"overrides`": { `"common`": { `"$Name`": `"x`" } } }" }
        { Invoke-Generator $repository } | Should -Throw $Message
    }

    It 'rejects a value with a line break' {
        $repository = New-TestRepository -Pipelines @{ tools = 'steps: []' } -Settings @{ tools = '{ "overrides": { "common": { "Text": "line 1\nline 2" } } }' }
        { Invoke-Generator $repository } | Should -Throw '*line break*'
    }

    It 'rejects a settings file that does not match the schema' {
        $repository = New-TestRepository -Pipelines @{ tools = 'steps: []' } -Settings @{ tools = '{ "extraKey": [ "LogLevel" ] }' }
        { Invoke-Generator $repository } | Should -Throw '*Pipeline settings are not valid*'
    }

    It 'rejects a settings file that lists an app that does not exist' {
        $repository = New-TestRepository -Pipelines @{ tools = 'steps: []' } -Settings @{ tools = '{ "apps": [ "missing-api" ] }' }
        { Invoke-Generator $repository } | Should -Throw "*lists app 'missing-api'*"
    }
}

Describe 'Selective regeneration' {
    BeforeAll {
        $script:Repository = New-TestRepository -Pipelines @{
            'orders-api' = "steps:`n- template: templates/deploy.yml"
            tools        = "steps:`n- template: templates/tools.yml"
        } -Templates @{
            'templates/deploy.yml' = 'steps: []'
            'templates/tools.yml'  = "steps:`n- pwsh: Write-Host '`$(LogLevel)'"
        }

        function Get-SelectedPipelines {
            param([string[]] $StagedFiles)
            $output = @(Invoke-Generator $script:Repository @{ StagedFiles = $StagedFiles; WhatIf = $true; PassThru = $true })
            @(foreach ($item in $output) { if ($item -isnot [System.Management.Automation.WarningRecord]) { $item.Pipeline } }) | Sort-Object -Unique
        }
    }

    It 'maps <StagedFiles> to <Expected>' -TestCases @(
        @{ StagedFiles = @('pipelines/tools.yml'); Expected = @('tools') }
        @{ StagedFiles = @('pipelines/templates/tools.yml'); Expected = @('tools') }
        @{ StagedFiles = @('pipelines/orders-api.variables.json'); Expected = @('orders-api') }
        @{ StagedFiles = @('pipelines/variables/tools/dev.yml'); Expected = @('tools') }
        @{ StagedFiles = @('app-configuration/apps/orders-api/AppConfiguration.Settings.json'); Expected = @('orders-api') }
        @{ StagedFiles = @('app-configuration/variables/common.json'); Expected = @('orders-api', 'tools') }
        @{ StagedFiles = @('pipelines/tools.yml,pipelines\templates\deploy.yml'); Expected = @('orders-api', 'tools') }
        @{ StagedFiles = @("./pipelines/tools.yml`nREADME.md"); Expected = @('tools') }
    ) {
        @(Get-SelectedPipelines -StagedFiles $StagedFiles) | Should -Be $Expected
    }

    It 'regenerates nothing for a file no pipeline depends on' {
        @(Get-SelectedPipelines -StagedFiles @('README.md', 'docs/pitfalls.md')) | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }

    It 'regenerates everything when the generator or its library changes' {
        $definitions = @(Get-PipelineDefinitions -PipelinesPath $Repository.PipelinesPath -OutputPath (Join-Path $Repository.PipelinesPath 'variables') -AppsPath $Repository.AppsPath -SchemaPath $SchemaPath -RepositoryRoot $Repository.RepositoryRoot)
        $parameters = @{
            Definitions    = $definitions
            RepositoryRoot = $Repository.RepositoryRoot
            PipelinesPath  = $Repository.PipelinesPath
            OutputPath     = Join-Path $Repository.PipelinesPath 'variables'
            AppsPath       = $Repository.AppsPath
            SharedInputs   = @((Join-Path $Repository.RepositoryRoot 'app-configuration/lib/PipelineVariables.ps1'))
        }
        (Select-PipelinesForStagedFiles @parameters -StagedFiles @('app-configuration/lib/PipelineVariables.ps1')).All | Should -BeTrue
        (Select-PipelinesForStagedFiles @parameters -StagedFiles @('app-configuration/lib/Other.ps1')).All | Should -BeFalse
    }

    It 'removes the output of a deleted pipeline and leaves the others alone' {
        $repository = New-TestRepository -Pipelines @{ 'orders-api' = 'steps: []'; tools = $ToolsYaml }
        Invoke-Generator $repository | Out-Null
        $ordersFile = Get-GeneratedPath $repository 'orders-api' 'dev'
        $written = (Get-Item -LiteralPath $ordersFile).LastWriteTimeUtc
        Remove-Item -LiteralPath (Join-Path $repository.PipelinesPath 'tools.yml')

        Invoke-Generator $repository @{ StagedFiles = @('pipelines/tools.yml') } | Out-Null

        Test-Path -LiteralPath (Join-Path $repository.PipelinesPath 'variables/tools') | Should -BeFalse
        (Get-Item -LiteralPath $ordersFile).LastWriteTimeUtc | Should -Be $written
    }

    It 'regenerates only the selected pipelines with -Pipeline' {
        $repository = New-TestRepository -Pipelines @{ 'orders-api' = 'steps: []'; tools = $ToolsYaml }
        $output = @(Invoke-Generator $repository @{ Pipeline = @('tools'); PassThru = $true })
        @($output | ForEach-Object Pipeline | Sort-Object -Unique) | Should -Be @('tools')
        Test-Path -LiteralPath (Join-Path $repository.PipelinesPath 'variables/orders-api') | Should -BeFalse
    }
}

Describe 'The committed sample' {
    It 'has generated pipeline variables that are up to date' {
        & $Generator -Check 6>$null | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}
