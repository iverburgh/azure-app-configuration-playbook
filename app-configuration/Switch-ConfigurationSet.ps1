#Requires -Version 7.2
<#
.SYNOPSIS
    Activates a configuration set by swapping the staging slot into production.

.DESCRIPTION
    Does nothing when production already uses -Label. Fails when staging does not use -Label.
    After the swap, production runs the new code with the new configuration set, and staging
    holds the previous code with the previous set: the rollback target. Use -WhatIf to preview.

.EXAMPLE
    ./Switch-ConfigurationSet.ps1 -ResourceGroup rg-orders-test -WebAppName app-orders-test -Label 2024.06.01.3
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $WebAppName,
    [Parameter(Mandatory)] [string] $Label,
    [string] $SettingName = 'AppConfiguration__Label'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/AppConfiguration.ps1')

Assert-AzCliLogin
Invoke-ConfigurationSwitch -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Label $Label -SettingName $SettingName -DryRun:$WhatIfPreference
