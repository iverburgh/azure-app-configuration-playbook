#Requires -Version 7.2
<#
.SYNOPSIS
    Schedules a new value for an application parameter, without a deployment.

.DESCRIPTION
    Appends a value with a start date in the future to '<app>:Parameters:<name>' (label
    'app-parameter') and then changes '<app>:ParameterSentinel', so running apps reload the
    parameters. The app picks the value whose start date is the latest one that has passed.
    Values that already took effect never change; the history stays in the store, with who
    made each change and when.
    The same value with the same start date changes nothing. Another value for a start date
    that is still in the future replaces the planned value.
    Use -WhatIf to see the change without writing.

.EXAMPLE
    ./Set-ApplicationParameter.ps1 -StoreEndpoint https://appcs-orders-prod.azconfig.io -AppName orders-api -Name MaxOrderLines -StartDate 2026-01-01T00:00:00+01:00 -Value 300
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $StoreEndpoint,
    [Parameter(Mandatory)] [string] $AppName,
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [DateTimeOffset] $StartDate,
    [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
    # Defaults to the signed-in Azure CLI account.
    [string] $ChangedBy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/AppConfiguration.ps1')

Assert-AzCliLogin
$parameters = @{
    StoreEndpoint = $StoreEndpoint
    AppName       = $AppName
    Name          = $Name
    StartDate     = $StartDate
    Value         = $Value
    DryRun        = $WhatIfPreference
}
if ($ChangedBy) {
    $parameters.ChangedBy = $ChangedBy
}
Set-ApplicationParameterValue @parameters
