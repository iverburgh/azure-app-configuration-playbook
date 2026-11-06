#Requires -Version 7.2
<#
.SYNOPSIS
    Validates the configuration of every app against every environment, offline.

.DESCRIPTION
    For each app folder and each environment file it checks JSON syntax, duplicate keys,
    the JSON schemas, token replacement (unknown, empty or malformed tokens), reserved keys,
    key collisions, Key Vault reference URIs and feature flag filters. No Azure access needed.
    Exits with code 1 when anything is wrong.

.EXAMPLE
    ./Test-AppConfiguration.ps1

.EXAMPLE
    ./Test-AppConfiguration.ps1 -AppName orders-api -Environment prod
#>
[CmdletBinding()]
param(
    [string] $AppName,
    [string] $Environment,
    [string] $AppsPath = (Join-Path $PSScriptRoot 'apps'),
    [string] $VariablesPath = (Join-Path $PSScriptRoot 'variables'),
    [string] $SchemaPath = (Join-Path $PSScriptRoot 'schemas')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/AppConfiguration.ps1')

$results = @(Get-AppConfigurationValidationResult -AppsPath $AppsPath -VariablesPath $VariablesPath -SchemaPath $SchemaPath -AppName $AppName -Environment $Environment)
$failed = 0
foreach ($result in $results) {
    $errors = @($result.Errors)
    if ($errors.Count -eq 0) {
        Write-Host "OK    $($result.AppName) [$($result.Environment)]"
        continue
    }
    $failed++
    Write-Host "FAIL  $($result.AppName) [$($result.Environment)]"
    foreach ($message in $errors) {
        Write-Host "      - $message"
    }
}

Write-Host ''
Write-Host ('{0} of {1} app/environment combinations are valid.' -f ($results.Count - $failed), $results.Count)
if ($failed -gt 0) {
    exit 1
}
exit 0
