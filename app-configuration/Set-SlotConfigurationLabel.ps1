#Requires -Version 7.2
<#
.SYNOPSIS
    Points a deployment slot (default: staging) at an imported configuration set.

.DESCRIPTION
    Sets the app setting -SettingName (not slot-sticky, so it moves with the swap) to -Label,
    rewrites @Microsoft.AppConfiguration(...) references to keys of the app to the same label,
    and sets the swap warm-up settings when -HealthCheckPath is given (removes them otherwise).
    Fails when the configuration set does not exist in the store. Does nothing when production
    already uses -Label, so rerunning a live deployment keeps the rollback target on staging.
    Use -WhatIf to preview.

.EXAMPLE
    ./Set-SlotConfigurationLabel.ps1 -ResourceGroup rg-orders-test -WebAppName app-orders-test `
        -StoreEndpoint https://appcs-orders-test.azconfig.io -AppName orders-api -Label 2024.06.01.3 -HealthCheckPath /health
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $WebAppName,
    [Parameter(Mandatory)] [string] $StoreEndpoint,
    [Parameter(Mandatory)] [string] $AppName,
    [Parameter(Mandatory)] [string] $Label,
    [string] $Slot = 'staging',
    [string] $SettingName = 'AppConfiguration__Label',
    [string] $HealthCheckPath,
    [string] $HealthCheckStatuses = '200'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/AppConfiguration.ps1')

Assert-AzCliLogin
Invoke-SlotLabelUpdate -ResourceGroup $ResourceGroup -WebAppName $WebAppName -StoreEndpoint $StoreEndpoint `
    -AppName $AppName -Label $Label -Slot $Slot -SettingName $SettingName `
    -HealthCheckPath $HealthCheckPath -HealthCheckStatuses $HealthCheckStatuses -DryRun:$WhatIfPreference
