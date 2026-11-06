#Requires -Version 7.2
<#
.SYNOPSIS
    Rolls back a failed deployment: production returns to the previous code and configuration set.

.DESCRIPTION
    Run this when the tests after Switch-ConfigurationSet.ps1 fail. It only acts when production
    still uses -Label (the failed deployment); otherwise it warns and does nothing, so a later
    deployment is never undone by mistake. It removes the swap warm-up settings from staging and
    swaps back. The whole configuration set returns at once, because the label setting moves
    with the swap. Use -WhatIf to preview.

.EXAMPLE
    ./Undo-ConfigurationSet.ps1 -ResourceGroup rg-orders-test -WebAppName app-orders-test `
        -StoreEndpoint https://appcs-orders-test.azconfig.io -AppName orders-api -Label 2024.06.01.3
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $WebAppName,
    [Parameter(Mandatory)] [string] $StoreEndpoint,
    [Parameter(Mandatory)] [string] $AppName,
    [Parameter(Mandatory)] [string] $Label,
    [string] $SettingName = 'AppConfiguration__Label'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/AppConfiguration.ps1')

Assert-AzCliLogin
Invoke-ConfigurationRollback -ResourceGroup $ResourceGroup -WebAppName $WebAppName -StoreEndpoint $StoreEndpoint `
    -AppName $AppName -Label $Label -SettingName $SettingName -DryRun:$WhatIfPreference
