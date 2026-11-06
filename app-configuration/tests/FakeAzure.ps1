Set-StrictMode -Version Latest

<#
    An in-memory stand-in for the parts of Azure that the playbook uses: one App Configuration
    store and App Service web apps with a production and a staging slot. Tests mock
    Invoke-AzCli with Invoke-FakeAzCli. Every call that changes state is recorded in
    $global:Fake.Writes, so tests can assert that a run wrote nothing.
#>

function Reset-FakeAzure {
    $global:Fake = @{
        LoggedIn    = $true
        Items       = [System.Collections.Generic.List[object]]::new()
        Sites       = @{}
        Writes      = [System.Collections.Generic.List[string]]::new()
        Calls       = [System.Collections.Generic.List[string]]::new()
        SwapFailure = $null
    }
}

function New-FakeSlot {
    @{
        Settings = [System.Collections.Generic.List[object]]::new()
        Code     = $null
        Healthy  = $true
    }
}

function Add-FakeWebApp {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Name
    )
    $global:Fake.Sites["$ResourceGroup/$Name"] = @{
        production = New-FakeSlot
        staging    = New-FakeSlot
    }
}

function Get-FakeSlot {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Slot
    )
    $siteKey = "$ResourceGroup/$Name"
    if (-not $global:Fake.Sites.ContainsKey($siteKey)) {
        throw "ResourceNotFound: web app '$siteKey' does not exist."
    }
    $site = $global:Fake.Sites[$siteKey]
    if (-not $site.ContainsKey($Slot)) {
        throw "ResourceNotFound: slot '$Slot' of '$siteKey' does not exist."
    }
    return $site[$Slot]
}

function Set-FakeAppSetting {
    <# Arranges a setting directly, without recording a write. #>
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Slot,
        [Parameter(Mandatory)] [string] $SettingName,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [switch] $SlotSetting
    )
    $settings = (Get-FakeSlot -ResourceGroup $ResourceGroup -Name $Name -Slot $Slot).Settings
    Set-FakeSettingEntry -Settings $settings -Name $SettingName -Value $Value -SlotSetting ([bool]$SlotSetting)
}

function Get-FakeAppSetting {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Slot,
        [Parameter(Mandatory)] [string] $SettingName
    )
    foreach ($setting in (Get-FakeSlot -ResourceGroup $ResourceGroup -Name $Name -Slot $Slot).Settings) {
        if ($setting.name -eq $SettingName) {
            return $setting
        }
    }
    return $null
}

function Set-FakeSettingEntry {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[object]] $Settings,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [string] $Value,
        [bool] $SlotSetting
    )
    for ($index = 0; $index -lt $Settings.Count; $index++) {
        if ($Settings[$index].name -eq $Name) {
            $Settings[$index] = [pscustomobject]@{ name = $Name; value = $Value; slotSetting = $SlotSetting }
            return
        }
    }
    $Settings.Add([pscustomobject]@{ name = $Name; value = $Value; slotSetting = $SlotSetting })
}

function Add-FakeItem {
    <# Arranges a key-value directly, without recording a write. #>
    param(
        [Parameter(Mandatory)] [string] $Key,
        [AllowNull()] [string] $Label,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [AllowNull()] [string] $ContentType,
        [hashtable] $Tags = @{}
    )
    $global:Fake.Items.Add([pscustomobject]@{
            key         = $Key
            label       = if ([string]::IsNullOrEmpty($Label)) { $null } else { $Label }
            value       = $Value
            contentType = if ([string]::IsNullOrEmpty($ContentType)) { $null } else { $ContentType }
            tags        = [pscustomobject]$Tags
        })
}

function Get-FakeItem {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [AllowNull()] [string] $Label
    )
    foreach ($item in $global:Fake.Items) {
        if ($item.key -ceq $Key -and (Test-FakeLabelEqual -Left $item.label -Right $Label)) {
            return $item
        }
    }
    return $null
}

function Test-FakeLabelEqual {
    param([AllowNull()] [string] $Left, [AllowNull()] [string] $Right)
    if ([string]::IsNullOrEmpty($Left)) {
        return [string]::IsNullOrEmpty($Right)
    }
    return ($Left -ceq $Right)
}

function Copy-FakeObject {
    param([Parameter(Mandatory)] $InputObject)
    ConvertTo-Json -InputObject $InputObject -Depth 20 | ConvertFrom-Json
}

function ConvertTo-FakeArguments {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $words = [System.Collections.Generic.List[string]]::new()
    $options = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $current = $null
    foreach ($argument in $Arguments) {
        if ($argument.StartsWith('--')) {
            $current = $argument.Substring(2)
            if (-not $options.ContainsKey($current)) {
                $options[$current] = [System.Collections.Generic.List[string]]::new()
            }
            continue
        }
        if ($null -eq $current) {
            $words.Add($argument)
        }
        else {
            $options[$current].Add($argument)
        }
    }
    [pscustomobject]@{ Command = ($words -join ' '); Options = $options }
}

function Get-FakeOption {
    param([Parameter(Mandatory)] $Parsed, [Parameter(Mandatory)] [string] $Name)
    if (-not $Parsed.Options.ContainsKey($Name) -or $Parsed.Options[$Name].Count -eq 0) {
        return $null
    }
    return $Parsed.Options[$Name][0]
}

function Test-FakeKeyMatch {
    param([Parameter(Mandatory)] [string] $Key, [Parameter(Mandatory)] [string] $Pattern)
    if ($Pattern.EndsWith('*')) {
        return $Key.StartsWith($Pattern.Substring(0, $Pattern.Length - 1), [StringComparison]::Ordinal)
    }
    return ($Key -ceq $Pattern)
}

function Invoke-FakeAzCli {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $AllowFailure
    )

    $global:Fake.Calls.Add($Arguments -join ' ')
    try {
        Invoke-FakeAzCommand -Arguments $Arguments
    }
    catch {
        if ($AllowFailure) {
            return
        }
        throw
    }
}

function Invoke-FakeAzCommand {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $parsed = ConvertTo-FakeArguments -Arguments $Arguments
    switch ($parsed.Command) {
        'account show' {
            if (-not $global:Fake.LoggedIn) {
                throw "Please run 'az login' to setup account."
            }
            [pscustomobject]@{ name = 'Example Subscription'; user = [pscustomobject]@{ name = 'pipeline@example.com' } }
        }
        'appconfig kv list' {
            $keyPattern = Get-FakeOption $parsed 'key'
            $labelOption = Get-FakeOption $parsed 'label'
            $labels = if ($null -eq $labelOption) { $null } else { @($labelOption -split ',') }
            foreach ($item in @($global:Fake.Items)) {
                if ($null -ne $keyPattern -and -not (Test-FakeKeyMatch -Key $item.key -Pattern $keyPattern)) {
                    continue
                }
                if ($null -ne $labels) {
                    $wanted = if ([string]::IsNullOrEmpty($item.label)) { '\0' } else { $item.label }
                    if ($labels -cnotcontains $wanted) {
                        continue
                    }
                }
                Copy-FakeObject -InputObject $item
            }
        }
        'appconfig kv import' {
            if ((Get-FakeOption $parsed 'profile') -ne 'appconfig/kvset') {
                throw 'The fake only supports --profile appconfig/kvset.'
            }
            $document = Get-Content -LiteralPath (Get-FakeOption $parsed 'path') -Raw | ConvertFrom-Json
            foreach ($entry in @($document.items)) {
                $label = $entry.PSObject.Properties['label']
                $labelValue = if ($null -eq $label) { $null } else { [string]$label.Value }
                $existing = Get-FakeItem -Key $entry.key -Label $labelValue
                if ($null -ne $existing) {
                    [void]$global:Fake.Items.Remove($existing)
                }
                $global:Fake.Items.Add([pscustomobject]@{
                        key         = [string]$entry.key
                        label       = if ([string]::IsNullOrEmpty($labelValue)) { $null } else { $labelValue }
                        value       = [string]$entry.value
                        contentType = $entry.content_type
                        tags        = $entry.tags
                    })
            }
            $global:Fake.Writes.Add('kv import: ' + (@($document.items | ForEach-Object key) -join ', '))
        }
        'appconfig kv delete' {
            $key = Get-FakeOption $parsed 'key'
            $label = Get-FakeOption $parsed 'label'
            $existing = Get-FakeItem -Key $key -Label $label
            if ($null -eq $existing) {
                throw "Key '$key' with label '$label' does not exist."
            }
            [void]$global:Fake.Items.Remove($existing)
            $global:Fake.Writes.Add("kv delete: $key [$label]")
            Copy-FakeObject -InputObject $existing
        }
        'webapp config appsettings list' {
            $slot = Get-FakeSlot -ResourceGroup (Get-FakeOption $parsed 'resource-group') -Name (Get-FakeOption $parsed 'name') -Slot ((Get-FakeOption $parsed 'slot') ?? 'production')
            foreach ($setting in $slot.Settings) {
                Copy-FakeObject -InputObject $setting
            }
        }
        'webapp config appsettings set' {
            $slotName = (Get-FakeOption $parsed 'slot') ?? 'production'
            $slot = Get-FakeSlot -ResourceGroup (Get-FakeOption $parsed 'resource-group') -Name (Get-FakeOption $parsed 'name') -Slot $slotName
            $source = Get-FakeOption $parsed 'settings'
            if (-not $source.StartsWith('@')) {
                throw 'The fake only supports --settings @file.json.'
            }
            $entries = @(Get-Content -LiteralPath $source.Substring(1) -Raw | ConvertFrom-Json)
            foreach ($entry in $entries) {
                Set-FakeSettingEntry -Settings $slot.Settings -Name $entry.name -Value $entry.value -SlotSetting ([bool]$entry.slotSetting)
            }
            $global:Fake.Writes.Add("appsettings set [$slotName]: " + (@($entries | ForEach-Object name) -join ', '))
        }
        'webapp config appsettings delete' {
            $slotName = (Get-FakeOption $parsed 'slot') ?? 'production'
            $slot = Get-FakeSlot -ResourceGroup (Get-FakeOption $parsed 'resource-group') -Name (Get-FakeOption $parsed 'name') -Slot $slotName
            $names = @($parsed.Options['setting-names'])
            foreach ($setting in @($slot.Settings)) {
                if ($names -contains $setting.name) {
                    [void]$slot.Settings.Remove($setting)
                }
            }
            $global:Fake.Writes.Add("appsettings delete [$slotName]: " + ($names -join ', '))
        }
        'webapp deployment slot swap' {
            $resourceGroup = Get-FakeOption $parsed 'resource-group'
            $name = Get-FakeOption $parsed 'name'
            $sourceName = Get-FakeOption $parsed 'slot'
            $targetName = (Get-FakeOption $parsed 'target-slot') ?? 'production'
            $source = Get-FakeSlot -ResourceGroup $resourceGroup -Name $name -Slot $sourceName
            $target = Get-FakeSlot -ResourceGroup $resourceGroup -Name $name -Slot $targetName
            if ($null -ne $global:Fake.SwapFailure) {
                throw $global:Fake.SwapFailure
            }
            $warmup = @($source.Settings | Where-Object name -EQ 'WEBSITE_SWAP_WARMUP_PING_PATH')
            if ($warmup.Count -gt 0 -and -not $source.Healthy) {
                throw "Swap failed: the warm-up request to '$($warmup[0].value)' on slot '$sourceName' did not return a healthy status."
            }

            $sourceMoving = @($source.Settings | Where-Object { -not $_.slotSetting })
            $targetMoving = @($target.Settings | Where-Object { -not $_.slotSetting })
            foreach ($setting in $sourceMoving) { [void]$source.Settings.Remove($setting) }
            foreach ($setting in $targetMoving) { [void]$target.Settings.Remove($setting) }
            foreach ($setting in $targetMoving) { $source.Settings.Add($setting) }
            foreach ($setting in $sourceMoving) { $target.Settings.Add($setting) }
            $source.Code, $target.Code = $target.Code, $source.Code
            $source.Healthy, $target.Healthy = $target.Healthy, $source.Healthy
            $global:Fake.Writes.Add("slot swap: $sourceName -> $targetName")
        }
        default {
            throw "The fake does not support 'az $($parsed.Command)'."
        }
    }
}
