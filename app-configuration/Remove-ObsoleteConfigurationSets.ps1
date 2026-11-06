#Requires -Version 7.2
<#
.SYNOPSIS
    Deletes configuration sets of an app that no slot uses any more.

.DESCRIPTION
    Keeps -CurrentLabel and the labels used by the production and staging slots, so the
    rollback target always survives. Deletes all other labels under '<app>:', unlabelled keys
    under '<app>:', and flags whose deployment tag is not kept. Refuses to run when neither
    slot uses -CurrentLabel. Use -WhatIf to preview.

.EXAMPLE
    ./Remove-ObsoleteConfigurationSets.ps1 -StoreEndpoint https://appcs-orders-test.azconfig.io -AppName orders-api `
        -ResourceGroup rg-orders-test -WebAppName app-orders-test -CurrentLabel 2024.06.01.3
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $StoreEndpoint,
    [Parameter(Mandatory)] [string] $AppName,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $WebAppName,
    [Parameter(Mandatory)] [string] $CurrentLabel,
    [string] $SettingName = 'AppConfiguration__Label'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/AppConfiguration.ps1')

Assert-AzCliLogin
Invoke-ConfigurationCleanup -StoreEndpoint $StoreEndpoint -AppName $AppName -ResourceGroup $ResourceGroup `
    -WebAppName $WebAppName -CurrentLabel $CurrentLabel -SettingName $SettingName -DryRun:$WhatIfPreference
