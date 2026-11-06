#Requires -Version 7.2
<#
.SYNOPSIS
    Imports a resolved app into Azure App Configuration as a configuration set.

.DESCRIPTION
    Reads the output of Build-AppConfiguration.ps1 and writes every setting and Key Vault
    reference under '<app>:' with -Label (use a value that identifies the deployment, such
    as the build number). Feature flags and circuit breakers keep their enabled state.
    Only differences are written, so rerunning the same deployment changes nothing.
    Use -WhatIf to see the changes without writing.

.EXAMPLE
    ./Import-AppConfiguration.ps1 -StoreEndpoint https://appcs-orders-test.azconfig.io -Path ./out/orders-api -Label 2024.06.01.3
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $StoreEndpoint,
    [Parameter(Mandatory)] [string] $Path,
    [Parameter(Mandatory)] [string] $Label,
    [string] $SchemaPath = (Join-Path $PSScriptRoot 'schemas')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/AppConfiguration.ps1')

$errors = @(Test-AppConfigurationSource -AppPath $Path -SchemaPath $SchemaPath)
if ($errors.Count -eq 0) {
    # An empty variable set makes any token left in the files an error.
    $noVariables = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    try {
        $resolved = Resolve-AppConfiguration -AppPath $Path -Variables $noVariables
        $errors = @(Test-ResolvedAppConfiguration -Resolved $resolved)
    }
    catch {
        $errors = @($_.Exception.Message)
    }
}
if ($errors.Count -gt 0) {
    throw ("'{0}' is not a valid resolved configuration:`n  {1}" -f $Path, ($errors -join "`n  "))
}

Assert-AzCliLogin
Invoke-ConfigurationImport -StoreEndpoint $StoreEndpoint -Resolved $resolved -Label $Label -DryRun:$WhatIfPreference
