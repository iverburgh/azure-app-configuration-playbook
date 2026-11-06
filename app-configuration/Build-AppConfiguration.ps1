#Requires -Version 7.2
<#
.SYNOPSIS
    Replaces the tokens of one app for one environment and writes the resolved files.

.DESCRIPTION
    Validates the app first and fails on any problem, including unknown or empty tokens.
    The output folder <OutputPath>/<AppName>/ is what Import-AppConfiguration.ps1 imports;
    publish it as a pipeline artifact so the imported values can be inspected later.

.EXAMPLE
    ./Build-AppConfiguration.ps1 -AppName orders-api -Environment test -OutputPath ./out
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $AppName,
    [Parameter(Mandatory)] [string] $Environment,
    [Parameter(Mandatory)] [string] $OutputPath,
    [string] $AppsPath = (Join-Path $PSScriptRoot 'apps'),
    [string] $VariablesPath = (Join-Path $PSScriptRoot 'variables'),
    [string] $SchemaPath = (Join-Path $PSScriptRoot 'schemas')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/AppConfiguration.ps1')

$appPath = Join-Path $AppsPath $AppName
if (-not (Test-Path -LiteralPath $appPath -PathType Container)) {
    throw "App '$AppName' does not exist in '$AppsPath'."
}

$errors = @(Test-AppConfigurationSet -AppPath $appPath -VariablesPath $VariablesPath -Environment $Environment -SchemaPath $SchemaPath)
if ($errors.Count -gt 0) {
    throw ("Configuration of '{0}' for '{1}' is not valid:`n  {2}" -f $AppName, $Environment, ($errors -join "`n  "))
}

$variables = Get-DeploymentVariables -VariablesPath $VariablesPath -Environment $Environment
$resolved = Resolve-AppConfiguration -AppPath $appPath -Variables $variables
$target = Join-Path $OutputPath $AppName
if ($PSCmdlet.ShouldProcess($target, "Write resolved configuration for '$Environment'")) {
    Export-ResolvedAppConfiguration -Resolved $resolved -Path $OutputPath
}
