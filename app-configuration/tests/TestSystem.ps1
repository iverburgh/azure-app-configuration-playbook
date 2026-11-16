Set-StrictMode -Version Latest

<#
    Shared setup for the Pester tests: paths to the example, the fake Azure, and helpers that
    write variant apps and variables into a temporary folder.
#>

$global:PlaybookRoot = Split-Path -Parent $PSScriptRoot
$global:ExampleAppsPath = Join-Path $global:PlaybookRoot 'apps'
$global:ExampleAppPath = Join-Path $global:ExampleAppsPath 'orders-api'
$global:ExampleVariablesPath = Join-Path $global:PlaybookRoot 'variables'
$global:SchemaPath = Join-Path $global:PlaybookRoot 'schemas'

$global:TestStore = 'https://appcs-example.azconfig.io'
$global:TestResourceGroup = 'rg-orders'
$global:TestWebApp = 'app-orders'

. (Join-Path $global:PlaybookRoot 'lib/AppConfiguration.ps1')
. (Join-Path $PSScriptRoot 'FakeAzure.ps1')

function New-TestApp {
    <#
    .SYNOPSIS
        Copies the example app to <Root>/apps/<Name> and replaces or removes files.
    .PARAMETER Files
        File name to JSON text; a $null value removes the file.
    #>
    param(
        [Parameter(Mandatory)] [string] $Root,
        [string] $Name = 'orders-api',
        [hashtable] $Files = @{}
    )
    $target = Join-Path (Join-Path $Root 'apps') $Name
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $global:ExampleAppPath '*') -Destination $target -Force
    foreach ($fileName in $Files.Keys) {
        $file = Join-Path $target $fileName
        if ($null -eq $Files[$fileName]) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
        else {
            Set-Content -LiteralPath $file -Value $Files[$fileName] -Encoding utf8NoBOM
        }
    }
    return $target
}

function New-TestVariables {
    <#
    .SYNOPSIS
        Copies the example variables to <Root>/variables and replaces or removes files.
    #>
    param(
        [Parameter(Mandatory)] [string] $Root,
        [hashtable] $Files = @{}
    )
    $target = Join-Path $Root 'variables'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $global:ExampleVariablesPath '*') -Destination $target -Force
    foreach ($fileName in $Files.Keys) {
        $file = Join-Path $target $fileName
        if ($null -eq $Files[$fileName]) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
        else {
            Set-Content -LiteralPath $file -Value $Files[$fileName] -Encoding utf8NoBOM
        }
    }
    return $target
}

function Get-TestVariables {
    param([string] $Environment = 'test', [string] $VariablesPath = $global:ExampleVariablesPath)
    Get-DeploymentVariables -VariablesPath $VariablesPath -Environment $Environment
}

function Get-ExampleResolved {
    param([string] $Environment = 'test', [string] $AppPath = $global:ExampleAppPath)
    Resolve-AppConfiguration -AppPath $AppPath -Variables (Get-TestVariables -Environment $Environment)
}

function Get-ValidationErrors {
    param(
        [Parameter(Mandatory)] [string] $AppPath,
        [string] $VariablesPath = $global:ExampleVariablesPath,
        [string] $Environment = 'test'
    )
    Test-AppConfigurationSet -AppPath $AppPath -VariablesPath $VariablesPath -Environment $Environment -SchemaPath $global:SchemaPath
}

function Initialize-TestEnvironment {
    <# Resets the fake and creates the example web app with an empty production and staging slot. #>
    Reset-FakeAzure
    Add-FakeWebApp -ResourceGroup $global:TestResourceGroup -Name $global:TestWebApp
}

function Get-TestLabel {
    param([ValidateSet('production', 'staging')] [string] $Slot)
    Get-SlotConfigurationLabel -ResourceGroup $global:TestResourceGroup -WebAppName $global:TestWebApp -Slot $Slot
}

function Get-TestSlot {
    param([ValidateSet('production', 'staging')] [string] $Slot)
    Get-FakeSlot -ResourceGroup $global:TestResourceGroup -Name $global:TestWebApp -Slot $Slot
}

function Get-FakeLabels {
    <# The distinct deployment labels of the app's settings in the fake store, sorted. Application parameters are left out. #>
    param([string] $AppName = 'orders-api')
    @($global:Fake.Items |
            Where-Object { $_.key.StartsWith("${AppName}:", [StringComparison]::Ordinal) -and $_.label -cne 'app-parameter' } |
            ForEach-Object { if ($null -eq $_.label) { '<null>' } else { $_.label } } |
            Sort-Object -Unique)
}

function Invoke-TestDeployment {
    <#
    .SYNOPSIS
        Runs the pipeline steps for one deployment against the fake: import, point staging at the
        label, deploy the code to staging, swap. -Unhealthy makes the warm-up check fail.
    #>
    param(
        [Parameter(Mandatory)] [string] $Label,
        $Resolved = (Get-ExampleResolved),
        [string] $HealthCheckPath,
        [switch] $Unhealthy
    )
    Invoke-ConfigurationImport -StoreEndpoint $global:TestStore -Resolved $Resolved -Label $Label | Out-Null
    $slotParameters = @{
        ResourceGroup = $global:TestResourceGroup
        WebAppName    = $global:TestWebApp
        StoreEndpoint = $global:TestStore
        AppName       = $Resolved.AppName
        Label         = $Label
    }
    if ($HealthCheckPath) {
        $slotParameters.HealthCheckPath = $HealthCheckPath
    }
    Invoke-SlotLabelUpdate @slotParameters | Out-Null
    # Stands in for deploying the application code to the staging slot.
    $staging = Get-FakeSlot -ResourceGroup $global:TestResourceGroup -Name $global:TestWebApp -Slot 'staging'
    $staging.Code = $Label
    $staging.Healthy = -not $Unhealthy
    Invoke-ConfigurationSwitch -ResourceGroup $global:TestResourceGroup -WebAppName $global:TestWebApp -Label $Label | Out-Null
}
