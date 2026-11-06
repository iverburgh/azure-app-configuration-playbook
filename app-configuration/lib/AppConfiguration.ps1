Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'AzureCli.ps1')

#region Constants and helpers

function Get-AppConfigurationConstants {
    @{
        Files                  = [ordered]@{
            Settings            = 'AppConfiguration.json'
            KeyVault            = 'AppConfiguration.KeyVault.json'
            FeatureFlags        = 'AppConfiguration.FeatureFlags.json'
            CircuitBreakerFlags = 'AppConfiguration.CircuitBreakerFlags.json'
        }
        Schemas                = @{
            Settings            = 'appconfiguration.schema.json'
            KeyVault            = 'keyvault.schema.json'
            FeatureFlags        = 'featureflags.schema.json'
            CircuitBreakerFlags = 'featureflags.schema.json'
            Variables           = 'variables.schema.json'
        }
        FlagLabels             = [ordered]@{
            FeatureFlags        = 'feature-flag'
            CircuitBreakerFlags = 'circuit-breaker'
        }
        KeyVaultContentType    = 'application/vnd.microsoft.appconfig.keyvaultref+json;charset=utf-8'
        FeatureFlagContentType = 'application/vnd.microsoft.appconfig.ff+json;charset=utf-8'
        FeatureFlagKeyPrefix   = '.appconfig.featureflag/'
        SentinelName           = 'Sentinel'
        DeploymentTag          = 'deployment'
        LabelSettingName       = 'AppConfiguration__Label'
        WarmupPathSetting      = 'WEBSITE_SWAP_WARMUP_PING_PATH'
        WarmupStatusesSetting  = 'WEBSITE_SWAP_WARMUP_PING_STATUSES'
        LabelPattern           = '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
        VariableNamePattern    = '^[A-Za-z][A-Za-z0-9_.-]*$'
        AppNamePattern         = '^[a-z][a-z0-9-]{0,62}$'
        KeyVaultUriPattern     = '^https://[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]\.vault\.(azure\.net|azure\.cn|usgovcloudapi\.net)/secrets/[A-Za-z0-9-]{1,127}(/[0-9a-fA-F]{32})?$'
    }
}

# Functions that may return an array use $PSCmdlet.WriteObject($value, $false): it writes the
# value as one object. Write-Output -NoEnumerate would wrap a single object in a list.

function Get-OptionalProperty {
    [CmdletBinding()]
    param(
        [AllowNull()] $InputObject,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] $Default = $null
    )

    $value = $Default
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            $value = $InputObject[$Name]
        }
    }
    elseif ($null -ne $InputObject) {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property) {
            $value = $property.Value
        }
    }
    $PSCmdlet.WriteObject($value, $false)
}

function Get-OptionalArray {
    [CmdletBinding()]
    param([AllowNull()] $Value)

    if ($null -eq $Value) {
        return
    }
    foreach ($item in @($Value)) {
        if ($null -ne $item) {
            $PSCmdlet.WriteObject($item, $false)
        }
    }
}

function Test-IsJsonObject {
    param([AllowNull()] $Value)
    return ($Value -is [System.Management.Automation.PSCustomObject])
}

function ConvertFrom-JsonText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Json)

    $convertParameters = @{ Depth = 64; NoEnumerate = $true }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $convertParameters.DateKind = 'String'
    }
    $parsed = ConvertFrom-Json -InputObject $Json @convertParameters
    $PSCmdlet.WriteObject($parsed, $false)
}

function Read-JsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $parsed = ConvertFrom-JsonText -Json (Get-Content -LiteralPath $Path -Raw)
    $PSCmdlet.WriteObject($parsed, $false)
}

function ConvertTo-CanonicalValue {
    [CmdletBinding()]
    param([AllowNull()] $Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary] -or (Test-IsJsonObject $Value)) {
        $names = if ($Value -is [System.Collections.IDictionary]) { [string[]]@($Value.Keys) } else { [string[]]@($Value.PSObject.Properties.Name) }
        [Array]::Sort($names, [StringComparer]::Ordinal)
        $result = [ordered]@{}
        foreach ($name in $names) {
            $result[$name] = ConvertTo-CanonicalValue -Value (Get-OptionalProperty -InputObject $Value -Name $name)
        }
        $PSCmdlet.WriteObject($result, $false)
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((ConvertTo-CanonicalValue -Value $item))
        }
        $PSCmdlet.WriteObject($items.ToArray(), $false)
        return
    }
    return $Value
}

function ConvertTo-CanonicalJson {
    param([AllowNull()] $InputObject)
    ConvertTo-Json -InputObject (ConvertTo-CanonicalValue -Value $InputObject) -Depth 64 -Compress
}

function New-ChangeRecord {
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [string] $Label,
        [AllowNull()] [string] $Detail
    )
    [pscustomobject][ordered]@{
        Action = $Action
        Target = $Target
        Name   = $Name
        Label  = $Label
        Detail = $Detail
    }
}

function Assert-DeploymentLabel {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Label)

    $constants = Get-AppConfigurationConstants
    if ($Label -cnotmatch $constants.LabelPattern) {
        throw "Label '$Label' is not valid. Use letters, digits, '.', '_' or '-' (max 128 characters), starting with a letter or digit."
    }
    if (@($constants.FlagLabels.Values) -contains $Label) {
        throw "Label '$Label' is reserved for feature flags and cannot identify a deployment."
    }
}

function Assert-AzCliLogin {
    $account = Invoke-AzCli -Arguments @('account', 'show') -AllowFailure
    if ($null -eq $account) {
        throw "The Azure CLI is not logged in. Run 'az login' first."
    }
}

#endregion

#region Variables and tokens

function ConvertTo-TokenString {
    param([AllowNull()] $Value)

    if ($null -eq $Value) {
        throw 'Null values are not supported.'
    }
    if ($Value -is [string]) {
        return $Value
    }
    if ($Value -is [bool]) {
        return $Value.ToString().ToLowerInvariant()
    }
    if ($Value -is [System.IFormattable]) {
        return $Value.ToString($null, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    throw "Values of type '$($Value.GetType().Name)' are not supported."
}

function Expand-TokenString {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.Dictionary[string, string]] $Variables,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[string]] $Errors
    )

    $namePattern = (Get-AppConfigurationConstants).VariableNamePattern
    $builder = [System.Text.StringBuilder]::new()
    $position = 0
    while ($true) {
        $start = $Text.IndexOf('#{', $position, [StringComparison]::Ordinal)
        if ($start -lt 0) {
            [void]$builder.Append($Text.Substring($position))
            break
        }
        [void]$builder.Append($Text.Substring($position, $start - $position))
        $end = $Text.IndexOf('}#', $start + 2, [StringComparison]::Ordinal)
        if ($end -lt 0) {
            $Errors.Add("${Path}: unterminated token in '$Text'.")
            [void]$builder.Append($Text.Substring($start))
            break
        }
        $name = $Text.Substring($start + 2, $end - $start - 2)
        $token = $Text.Substring($start, $end - $start + 2)
        if ($name -cnotmatch $namePattern) {
            $Errors.Add("${Path}: malformed token '$token'.")
            [void]$builder.Append($token)
        }
        elseif (-not $Variables.ContainsKey($name)) {
            $Errors.Add("${Path}: unknown token '$token'; no variable '$name' is defined for this environment.")
            [void]$builder.Append($token)
        }
        elseif ([string]::IsNullOrEmpty($Variables[$name])) {
            $Errors.Add("${Path}: token '$token' has an empty value.")
            [void]$builder.Append($token)
        }
        else {
            [void]$builder.Append($Variables[$name])
        }
        $position = $end + 2
    }
    return $builder.ToString()
}

function Expand-JsonTokens {
    <#
    .SYNOPSIS
        Replaces #{Token}# placeholders in all string values of a parsed JSON document, in place.
    #>
    param(
        [AllowNull()] $Node,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.Dictionary[string, string]] $Variables,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[string]] $Errors
    )

    if (Test-IsJsonObject $Node) {
        foreach ($property in @($Node.PSObject.Properties)) {
            $childPath = '{0}.{1}' -f $Path, $property.Name
            if ($property.Name.Contains('#{')) {
                $Errors.Add("${childPath}: tokens are not allowed in keys.")
                continue
            }
            if ($property.Value -is [string]) {
                $property.Value = Expand-TokenString -Text $property.Value -Variables $Variables -Path $childPath -Errors $Errors
            }
            else {
                Expand-JsonTokens -Node $property.Value -Variables $Variables -Path $childPath -Errors $Errors
            }
        }
    }
    elseif ($Node -is [System.Array]) {
        for ($index = 0; $index -lt $Node.Count; $index++) {
            $childPath = '{0}[{1}]' -f $Path, $index
            if ($Node[$index] -is [string]) {
                $Node[$index] = Expand-TokenString -Text $Node[$index] -Variables $Variables -Path $childPath -Errors $Errors
            }
            else {
                Expand-JsonTokens -Node $Node[$index] -Variables $Variables -Path $childPath -Errors $Errors
            }
        }
    }
}

function Resolve-VariableValue {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.Dictionary[string, string]] $Raw,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.Dictionary[string, string]] $Resolved,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[string]] $Stack,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.List[string]] $Errors
    )

    if ($Resolved.ContainsKey($Name)) {
        return
    }
    if ($Stack.Contains($Name)) {
        $Errors.Add("Variable '$Name' has a circular reference: $(@($Stack) -join ' -> ') -> $Name.")
        $Resolved[$Name] = ''
        return
    }

    $Stack.Add($Name)
    $value = $Raw[$Name]
    foreach ($match in [regex]::Matches($value, '#\{([^{}#]*)\}#')) {
        $reference = $match.Groups[1].Value
        if ($Raw.ContainsKey($reference)) {
            Resolve-VariableValue -Name $reference -Raw $Raw -Resolved $Resolved -Stack $Stack -Errors $Errors
        }
    }
    $Stack.RemoveAt($Stack.Count - 1)

    if (-not $Resolved.ContainsKey($Name)) {
        $Resolved[$Name] = Expand-TokenString -Text $value -Variables $Resolved -Path "variable '$Name'" -Errors $Errors
    }
}

function Get-DeploymentVariables {
    <#
    .SYNOPSIS
        Reads common.json and <Environment>.json and returns the resolved variables.
    .OUTPUTS
        System.Collections.Generic.Dictionary[string, string] (case-sensitive names).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $VariablesPath,
        [Parameter(Mandatory)] [string] $Environment
    )

    $constants = Get-AppConfigurationConstants
    if ($Environment -cnotmatch '^[A-Za-z0-9-]+$' -or $Environment -eq 'common') {
        throw "Environment name '$Environment' is not valid."
    }
    $environmentFile = Join-Path $VariablesPath "$Environment.json"
    if (-not (Test-Path -LiteralPath $environmentFile)) {
        throw "Unknown environment '$Environment': '$environmentFile' does not exist."
    }

    $raw = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($file in @((Join-Path $VariablesPath 'common.json'), $environmentFile)) {
        if (-not (Test-Path -LiteralPath $file)) {
            continue
        }
        $document = Read-JsonFile -Path $file
        $variables = Get-OptionalProperty -InputObject $document -Name 'variables'
        if (-not (Test-IsJsonObject $variables)) {
            throw "'$file' must contain an object named 'variables'."
        }
        foreach ($property in $variables.PSObject.Properties) {
            if ($property.Name -cnotmatch $constants.VariableNamePattern) {
                throw "Variable name '$($property.Name)' in '$file' is not valid."
            }
            try {
                $raw[$property.Name] = ConvertTo-TokenString -Value $property.Value
            }
            catch {
                throw "Variable '$($property.Name)' in '${file}': $($_.Exception.Message)"
            }
        }
    }

    $resolved = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($raw.Keys)) {
        Resolve-VariableValue -Name $name -Raw $raw -Resolved $resolved -Stack ([System.Collections.Generic.List[string]]::new()) -Errors $errors
    }
    if ($errors.Count -gt 0) {
        throw ("Variables for environment '{0}' cannot be resolved:`n  {1}" -f $Environment, ($errors -join "`n  "))
    }
    $PSCmdlet.WriteObject($resolved, $false)
}

function Resolve-AppConfiguration {
    <#
    .SYNOPSIS
        Reads the four files of one app and replaces all tokens. Throws on any token problem.
    .PARAMETER Variables
        Resolved variables. Pass an empty dictionary to read files that must not contain tokens.
    #>
    param(
        [Parameter(Mandatory)] [string] $AppPath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.Dictionary[string, string]] $Variables
    )

    $constants = Get-AppConfigurationConstants
    $settingsFile = Join-Path $AppPath $constants.Files.Settings
    if (-not (Test-Path -LiteralPath $settingsFile)) {
        throw "'$settingsFile' does not exist; every app needs an $($constants.Files.Settings)."
    }

    $result = [ordered]@{ AppName = (Split-Path -Leaf $AppPath) }
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $constants.Files.Keys) {
        $fileName = $constants.Files[$part]
        $file = Join-Path $AppPath $fileName
        if (Test-Path -LiteralPath $file) {
            $document = Read-JsonFile -Path $file
        }
        elseif ($part -like '*Flags') {
            $document = @()
        }
        else {
            $document = [pscustomobject]@{}
        }
        Expand-JsonTokens -Node $document -Variables $Variables -Path $fileName -Errors $errors
        $result[$part] = $document
    }

    if ($errors.Count -gt 0) {
        throw ("Token replacement failed for app '{0}':`n  {1}" -f $result.AppName, ($errors -join "`n  "))
    }
    [pscustomobject]$result
}

function Export-ResolvedAppConfiguration {
    <#
    .SYNOPSIS
        Writes a resolved app to <Path>/<AppName>/ with the same four file names.
    #>
    param(
        [Parameter(Mandatory)] $Resolved,
        [Parameter(Mandatory)] [string] $Path
    )

    $constants = Get-AppConfigurationConstants
    $target = Join-Path $Path $Resolved.AppName
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    foreach ($part in $constants.Files.Keys) {
        $file = Join-Path $target $constants.Files[$part]
        $json = ConvertTo-Json -InputObject $Resolved.$part -Depth 64
        Set-Content -LiteralPath $file -Value $json -Encoding utf8NoBOM
        Write-Output $file
    }
}

#endregion

#region Flattening and validation

function ConvertTo-FlatSettings {
    param(
        [AllowNull()] $Node,
        [string] $Prefix = ''
    )

    if (Test-IsJsonObject $Node) {
        foreach ($property in $Node.PSObject.Properties) {
            $key = if ($Prefix) { '{0}:{1}' -f $Prefix, $property.Name } else { $property.Name }
            ConvertTo-FlatSettings -Node $property.Value -Prefix $key
        }
    }
    elseif ($Node -is [System.Array]) {
        for ($index = 0; $index -lt $Node.Count; $index++) {
            ConvertTo-FlatSettings -Node $Node[$index] -Prefix ('{0}:{1}' -f $Prefix, $index)
        }
    }
    else {
        [pscustomobject]@{ Key = $Prefix; Value = (ConvertTo-TokenString -Value $Node) }
    }
}

function ConvertTo-FlatKeyVault {
    param(
        [AllowNull()] $Node,
        [string] $Prefix = ''
    )

    if (-not (Test-IsJsonObject $Node)) {
        return
    }
    foreach ($property in $Node.PSObject.Properties) {
        $key = if ($Prefix) { '{0}:{1}' -f $Prefix, $property.Name } else { $property.Name }
        $uri = Get-OptionalProperty -InputObject $property.Value -Name 'uri'
        if ((Test-IsJsonObject $property.Value) -and $uri -is [string]) {
            [pscustomobject]@{ Key = $key; Uri = $uri }
        }
        elseif (Test-IsJsonObject $property.Value) {
            ConvertTo-FlatKeyVault -Node $property.Value -Prefix $key
        }
        else {
            [pscustomobject]@{ Key = $key; Uri = $null }
        }
    }
}

function Find-JsonElementDuplicates {
    param(
        [Parameter(Mandatory)] [System.Text.Json.JsonElement] $Element,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Source
    )

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $seen = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            $childPath = '{0}.{1}' -f $Path, $property.Name
            if ($seen.ContainsKey($property.Name)) {
                if ($seen[$property.Name] -ceq $property.Name) {
                    "${Source}: duplicate key '$childPath'."
                }
                else {
                    "${Source}: keys '$($seen[$property.Name])' and '$($property.Name)' under '$Path' differ only in case."
                }
            }
            else {
                $seen[$property.Name] = $property.Name
            }
            Find-JsonElementDuplicates -Element $property.Value -Path $childPath -Source $Source
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Find-JsonElementDuplicates -Element $item -Path ('{0}[{1}]' -f $Path, $index) -Source $Source
            $index++
        }
    }
}

function Find-JsonDuplicateKeys {
    <#
    .SYNOPSIS
        Reports invalid JSON and duplicate keys (exact or differing only in case).
        ConvertFrom-Json silently keeps the last duplicate, so this uses System.Text.Json.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Json,
        [Parameter(Mandatory)] [string] $Source
    )

    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception.InnerException) {
            $exception = $exception.InnerException
        }
        "${Source}: invalid JSON: $($exception.Message)"
        return
    }
    try {
        Find-JsonElementDuplicates -Element $document.RootElement -Path '$' -Source $Source
    }
    finally {
        $document.Dispose()
    }
}

function Test-JsonFile {
    <#
    .SYNOPSIS
        Checks one JSON file for syntax errors, duplicate keys and schema violations.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $SchemaFile,
        [Parameter(Mandatory)] [string] $Source
    )

    $json = Get-Content -LiteralPath $Path -Raw
    if ($null -eq $json) {
        $json = ''
    }
    $structureErrors = @(Find-JsonDuplicateKeys -Json $json -Source $Source)
    if ($structureErrors.Count -gt 0) {
        $structureErrors
        return
    }

    $schemaErrors = $null
    $valid = Test-Json -Json $json -SchemaFile $SchemaFile -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
    if (-not $valid) {
        $messages = @(Get-OptionalArray $schemaErrors | ForEach-Object { $_.Exception.Message -replace '^The JSON is not valid with the schema: ', '' })
        if ($messages.Count -eq 0) {
            $messages = @('does not match the schema.')
        }
        foreach ($message in $messages) {
            "${Source}: $message"
        }
    }
}

function Find-SettingsTreeErrors {
    <#
    .SYNOPSIS
        Checks the nested levels of a settings file: no null values, no empty keys, no ':' in keys.
    #>
    param(
        [AllowNull()] $Node,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Source
    )

    if (Test-IsJsonObject $Node) {
        foreach ($property in $Node.PSObject.Properties) {
            $childPath = '{0}.{1}' -f $Path, $property.Name
            if ([string]::IsNullOrEmpty($property.Name) -or $property.Name.Contains(':')) {
                "${Source}: key '$childPath' must not be empty or contain ':'."
            }
            if ($null -eq $property.Value) {
                "${Source}: '$childPath' is null; null values are not supported."
            }
            else {
                Find-SettingsTreeErrors -Node $property.Value -Path $childPath -Source $Source
            }
        }
    }
    elseif ($Node -is [System.Array]) {
        for ($index = 0; $index -lt $Node.Count; $index++) {
            $childPath = '{0}[{1}]' -f $Path, $index
            if ($null -eq $Node[$index]) {
                "${Source}: '$childPath' is null; null values are not supported."
            }
            else {
                Find-SettingsTreeErrors -Node $Node[$index] -Path $childPath -Source $Source
            }
        }
    }
}

function Find-KeyVaultTreeErrors {
    <#
    .SYNOPSIS
        Checks that every leaf of a Key Vault file is { "uri": "<non-empty string>" }.
    #>
    param(
        [Parameter(Mandatory)] $Node,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Source
    )

    foreach ($property in $Node.PSObject.Properties) {
        $childPath = '{0}.{1}' -f $Path, $property.Name
        $value = $property.Value
        if ([string]::IsNullOrEmpty($property.Name) -or $property.Name.Contains(':')) {
            "${Source}: key '$childPath' must not be empty or contain ':'."
        }
        if (-not (Test-IsJsonObject $value) -or @($value.PSObject.Properties).Count -eq 0) {
            "${Source}: '$childPath' must be a Key Vault reference { `"uri`": `"...`" } or a non-empty nested object."
            continue
        }
        if ($null -ne $value.PSObject.Properties['uri']) {
            $names = @($value.PSObject.Properties.Name)
            if ($names.Count -ne 1 -or $value.uri -isnot [string] -or [string]::IsNullOrWhiteSpace($value.uri)) {
                "${Source}: '$childPath' must be exactly { `"uri`": `"<secret URI>`" }."
            }
            continue
        }
        Find-KeyVaultTreeErrors -Node $value -Path $childPath -Source $Source
    }
}

function Test-AppConfigurationSource {
    <#
    .SYNOPSIS
        Offline checks on the unresolved files of one app: JSON syntax, duplicate keys, schemas and nesting.
    #>
    param(
        [Parameter(Mandatory)] [string] $AppPath,
        [Parameter(Mandatory)] [string] $SchemaPath
    )

    $constants = Get-AppConfigurationConstants
    $appName = Split-Path -Leaf $AppPath
    if ($appName -cnotmatch $constants.AppNamePattern) {
        "App folder name '$appName' is not valid; use lowercase letters, digits and '-'."
    }
    foreach ($part in $constants.Files.Keys) {
        $fileName = $constants.Files[$part]
        $file = Join-Path $AppPath $fileName
        if (-not (Test-Path -LiteralPath $file)) {
            if ($part -eq 'Settings') {
                "$fileName is missing."
            }
            continue
        }
        $fileErrors = @(Test-JsonFile -Path $file -SchemaFile (Join-Path $SchemaPath $constants.Schemas[$part]) -Source $fileName)
        if ($fileErrors.Count -gt 0) {
            $fileErrors
            continue
        }
        if ($part -eq 'Settings') {
            Find-SettingsTreeErrors -Node (Read-JsonFile -Path $file) -Path '$' -Source $fileName
        }
        elseif ($part -eq 'KeyVault') {
            Find-KeyVaultTreeErrors -Node (Read-JsonFile -Path $file) -Path '$' -Source $fileName
        }
    }
}

function Test-ResolvedAppConfiguration {
    <#
    .SYNOPSIS
        Checks a resolved app: reserved keys, key collisions, Key Vault reference URIs and flags.
    #>
    param([Parameter(Mandatory)] $Resolved)

    $constants = Get-AppConfigurationConstants
    $files = $constants.Files

    foreach ($part in 'Settings', 'KeyVault') {
        foreach ($property in $Resolved.$part.PSObject.Properties) {
            if ($property.Name -eq $constants.SentinelName) {
                "$($files[$part]): top-level key '$($property.Name)' is reserved for the change sentinel."
            }
        }
    }

    $seen = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($setting in @(ConvertTo-FlatSettings -Node $Resolved.Settings)) {
        if ($seen.ContainsKey($setting.Key)) {
            "$($files.Settings): key '$($setting.Key)' collides with '$($seen[$setting.Key])'."
        }
        else {
            $seen[$setting.Key] = $setting.Key
        }
    }
    foreach ($reference in @(ConvertTo-FlatKeyVault -Node $Resolved.KeyVault)) {
        if ($seen.ContainsKey($reference.Key)) {
            "$($files.KeyVault): key '$($reference.Key)' is also defined in $($files.Settings) as '$($seen[$reference.Key])'."
        }
        else {
            $seen[$reference.Key] = $reference.Key
        }
        if ($null -eq $reference.Uri) {
            "$($files.KeyVault): '$($reference.Key)' must be an object with a 'uri' property."
        }
        elseif ($reference.Uri -cnotmatch $constants.KeyVaultUriPattern) {
            "$($files.KeyVault): '$($reference.Key)' has URI '$($reference.Uri)'; expected https://<vault>.vault.azure.net/secrets/<name>[/<version>]."
        }
    }

    $flagNames = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($part in 'FeatureFlags', 'CircuitBreakerFlags') {
        foreach ($flag in @(Get-OptionalArray $Resolved.$part)) {
            $name = [string](Get-OptionalProperty -InputObject $flag -Name 'name' -Default '')
            if ($flagNames.ContainsKey($name)) {
                "$($files[$part]): flag '$name' is already defined in $($flagNames[$name])."
            }
            else {
                $flagNames[$name] = $files[$part]
            }
            $conditions = Get-OptionalProperty -InputObject $flag -Name 'conditions'
            foreach ($filter in @(Get-OptionalArray (Get-OptionalProperty -InputObject $conditions -Name 'client_filters'))) {
                if ((Get-OptionalProperty -InputObject $filter -Name 'name') -ne 'Microsoft.Percentage') {
                    continue
                }
                $value = Get-OptionalProperty -InputObject (Get-OptionalProperty -InputObject $filter -Name 'parameters') -Name 'Value'
                $number = 0.0
                $parsed = $null -ne $value -and [double]::TryParse((ConvertTo-TokenString -Value $value), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)
                if (-not $parsed -or $number -lt 0 -or $number -gt 100) {
                    "$($files[$part]): flag '$name' needs a Microsoft.Percentage parameter 'Value' between 0 and 100."
                }
            }
        }
    }
}

function Test-AppConfigurationSet {
    <#
    .SYNOPSIS
        Full offline validation of one app for one environment. Writes error messages; nothing means valid.
    #>
    param(
        [Parameter(Mandatory)] [string] $AppPath,
        [Parameter(Mandatory)] [string] $VariablesPath,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [string] $SchemaPath
    )

    $constants = Get-AppConfigurationConstants
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @((Join-Path $VariablesPath 'common.json'), (Join-Path $VariablesPath "$Environment.json"))) {
        if (Test-Path -LiteralPath $file) {
            foreach ($message in @(Test-JsonFile -Path $file -SchemaFile (Join-Path $SchemaPath $constants.Schemas.Variables) -Source (Split-Path -Leaf $file))) {
                $errors.Add($message)
            }
        }
    }
    foreach ($message in @(Test-AppConfigurationSource -AppPath $AppPath -SchemaPath $SchemaPath)) {
        $errors.Add($message)
    }
    if ($errors.Count -gt 0) {
        $errors
        return
    }

    try {
        $variables = Get-DeploymentVariables -VariablesPath $VariablesPath -Environment $Environment
        $resolved = Resolve-AppConfiguration -AppPath $AppPath -Variables $variables
    }
    catch {
        $_.Exception.Message
        return
    }
    Test-ResolvedAppConfiguration -Resolved $resolved
}

function Get-AppConfigurationValidationResult {
    <#
    .SYNOPSIS
        Validates every app (or one) against every environment (or one).
    .OUTPUTS
        One object per app and environment with AppName, Environment and Errors.
    #>
    param(
        [Parameter(Mandatory)] [string] $AppsPath,
        [Parameter(Mandatory)] [string] $VariablesPath,
        [Parameter(Mandatory)] [string] $SchemaPath,
        [string] $AppName,
        [string] $Environment
    )

    $apps = @(Get-ChildItem -LiteralPath $AppsPath -Directory | Sort-Object Name)
    if ($AppName) {
        $apps = @($apps | Where-Object Name -EQ $AppName)
        if ($apps.Count -eq 0) {
            throw "App '$AppName' does not exist in '$AppsPath'."
        }
    }
    # Explicit loops instead of ForEach-Object <member>: that form honours -WhatIf and then outputs nothing.
    $environments = @(foreach ($file in @(Get-ChildItem -LiteralPath $VariablesPath -Filter '*.json' -File | Sort-Object BaseName)) {
            if ($file.BaseName -ne 'common') {
                $file.BaseName
            }
        })
    if ($Environment) {
        $environments = @($Environment)
    }
    if ($environments.Count -eq 0) {
        throw "No environment files found in '$VariablesPath'."
    }

    foreach ($app in $apps) {
        foreach ($environmentName in $environments) {
            $messages = @(Test-AppConfigurationSet -AppPath $app.FullName -VariablesPath $VariablesPath -Environment $environmentName -SchemaPath $SchemaPath)
            [pscustomobject]@{
                AppName     = $app.Name
                Environment = $environmentName
                Errors      = [string[]]$messages
            }
        }
    }
}

#endregion

#region Desired state

function New-ConfigurationItem {
    param(
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [AllowNull()] [string] $ContentType,
        [Parameter(Mandatory)] [string] $Deployment
    )
    [pscustomobject][ordered]@{
        key         = $Key
        label       = $Label
        value       = $Value
        contentType = if ([string]::IsNullOrEmpty($ContentType)) { $null } else { $ContentType }
        tags        = [ordered]@{ (Get-AppConfigurationConstants).DeploymentTag = $Deployment }
    }
}

function Get-ComparableItem {
    param([Parameter(Mandatory)] $Item, [switch] $ParseValue)

    $value = $Item.value
    if ($ParseValue) {
        try {
            $value = ConvertFrom-JsonText -Json ([string]$Item.value)
        }
        catch {
            $value = [string]$Item.value
        }
    }
    $tags = Get-OptionalProperty -InputObject $Item -Name 'tags'
    if ($null -eq $tags) {
        $tags = @{}
    }
    ConvertTo-CanonicalJson -InputObject ([ordered]@{
            value       = $value
            contentType = [string](Get-OptionalProperty -InputObject $Item -Name 'contentType')
            tags        = $tags
        })
}

function Get-DesiredConfigurationItems {
    <#
    .SYNOPSIS
        Builds the key-values for one app and one deployment label, ending with the sentinel.
    #>
    param(
        [Parameter(Mandatory)] $Resolved,
        [Parameter(Mandatory)] [string] $Label
    )

    $constants = Get-AppConfigurationConstants
    $app = $Resolved.AppName
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($setting in @(ConvertTo-FlatSettings -Node $Resolved.Settings)) {
        $items.Add((New-ConfigurationItem -Key ('{0}:{1}' -f $app, $setting.Key) -Label $Label -Value $setting.Value -Deployment $Label))
    }
    foreach ($reference in @(ConvertTo-FlatKeyVault -Node $Resolved.KeyVault)) {
        $value = ConvertTo-Json -InputObject ([ordered]@{ uri = $reference.Uri }) -Compress
        $items.Add((New-ConfigurationItem -Key ('{0}:{1}' -f $app, $reference.Key) -Label $Label -Value $value -ContentType $constants.KeyVaultContentType -Deployment $Label))
    }

    $keys = [string[]]@(foreach ($item in $items) { $item.key })
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $byKey = @{}
    foreach ($item in $items) {
        $byKey[$item.key] = $item
    }
    $canonical = ConvertTo-CanonicalJson -InputObject @(foreach ($key in $keys) {
            , @($key, [string]$byKey[$key].contentType, $byKey[$key].value)
        })
    $hashBytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($canonical))
    $hash = [Convert]::ToHexString($hashBytes).ToLowerInvariant()

    foreach ($key in $keys) {
        $byKey[$key]
    }
    New-ConfigurationItem -Key ('{0}:{1}' -f $app, $constants.SentinelName) -Label $Label -Value $hash -Deployment $Label
}

function Get-DesiredFeatureFlags {
    param(
        [Parameter(Mandatory)] $Resolved,
        [Parameter(Mandatory)] [string] $Label
    )

    $constants = Get-AppConfigurationConstants
    foreach ($part in $constants.FlagLabels.Keys) {
        foreach ($flag in @(Get-OptionalArray $Resolved.$part)) {
            $id = '{0}.{1}' -f $Resolved.AppName, $flag.name
            $conditionsSource = Get-OptionalProperty -InputObject $flag -Name 'conditions'
            $conditions = [ordered]@{
                client_filters = @(Get-OptionalArray (Get-OptionalProperty -InputObject $conditionsSource -Name 'client_filters'))
            }
            $requirementType = Get-OptionalProperty -InputObject $conditionsSource -Name 'requirement_type'
            if ($null -ne $requirementType) {
                $conditions.requirement_type = $requirementType
            }
            [pscustomobject]@{
                Id             = $id
                Key            = $constants.FeatureFlagKeyPrefix + $id
                Label          = $constants.FlagLabels[$part]
                Description    = [string](Get-OptionalProperty -InputObject $flag -Name 'description' -Default '')
                Enabled        = Get-OptionalProperty -InputObject $flag -Name 'enabled'
                DefaultEnabled = ($part -eq 'CircuitBreakerFlags')
                Conditions     = $conditions
            }
        }
    }
}

#endregion

#region Store operations

function Get-StoreItems {
    param(
        [Parameter(Mandatory)] [string] $StoreEndpoint,
        [Parameter(Mandatory)] [string] $Key,
        [string] $Label
    )

    $arguments = @('appconfig', 'kv', 'list', '--endpoint', $StoreEndpoint, '--auth-mode', 'login', '--key', $Key, '--all')
    if ($Label) {
        $arguments += @('--label', $Label)
    }
    Invoke-AzCli -Arguments $arguments
}

function Test-ConfigurationSetExists {
    param(
        [Parameter(Mandatory)] [string] $StoreEndpoint,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [string] $Label
    )

    $sentinel = '{0}:{1}' -f $AppName, (Get-AppConfigurationConstants).SentinelName
    return (@(Get-StoreItems -StoreEndpoint $StoreEndpoint -Key $sentinel -Label $Label).Count -gt 0)
}

function Write-StoreItems {
    param(
        [Parameter(Mandatory)] [string] $StoreEndpoint,
        [Parameter(Mandatory)] [object[]] $Items
    )

    $payload = [ordered]@{
        items = @(foreach ($item in $Items) {
                [ordered]@{
                    key          = $item.key
                    value        = $item.value
                    label        = $item.label
                    content_type = $item.contentType
                    tags         = $item.tags
                }
            })
    }
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ('appconfig-kvset-{0}.json' -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $file -Value (ConvertTo-Json -InputObject $payload -Depth 64) -Encoding utf8NoBOM
    try {
        Invoke-AzCli -Arguments @('appconfig', 'kv', 'import', '--endpoint', $StoreEndpoint, '--auth-mode', 'login',
            '--source', 'file', '--path', $file, '--format', 'json', '--profile', 'appconfig/kvset',
            '--import-mode', 'ignore-match', '--yes') | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Remove-StoreItem {
    param(
        [Parameter(Mandatory)] [string] $StoreEndpoint,
        [Parameter(Mandatory)] [string] $Key,
        [AllowNull()] [string] $Label
    )

    # Without --label, az deletes the key-value that has no label.
    $arguments = @('appconfig', 'kv', 'delete', '--endpoint', $StoreEndpoint, '--auth-mode', 'login', '--key', $Key, '--yes')
    if (-not [string]::IsNullOrEmpty($Label)) {
        $arguments += @('--label', $Label)
    }
    Invoke-AzCli -Arguments $arguments | Out-Null
}

function Invoke-ConfigurationImport {
    <#
    .SYNOPSIS
        Imports one resolved app as a configuration set with the given deployment label.
    .DESCRIPTION
        Settings and Key Vault references are written under '<app>:' with the deployment
        label; keys that no longer exist are deleted from that label only. Feature flags
        and circuit breakers use fixed labels; their enabled state is kept from the store.
        Writes only what differs, so a second run changes nothing.
    .OUTPUTS
        Change records (Action, Target, Name, Label, Detail).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StoreEndpoint,
        [Parameter(Mandatory)] $Resolved,
        [Parameter(Mandatory)] [string] $Label,
        [switch] $DryRun
    )

    Assert-DeploymentLabel -Label $Label
    $constants = Get-AppConfigurationConstants
    $app = $Resolved.AppName
    $sentinelKey = '{0}:{1}' -f $app, $constants.SentinelName

    $existing = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($item in @(Get-StoreItems -StoreEndpoint $StoreEndpoint -Key "${app}:*" -Label $Label)) {
        $existing[$item.key] = $item
    }

    $changes = [System.Collections.Generic.List[object]]::new()
    $writes = [System.Collections.Generic.List[object]]::new()
    $sentinelWrite = $null
    $desiredKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in @(Get-DesiredConfigurationItems -Resolved $Resolved -Label $Label)) {
        [void]$desiredKeys.Add($item.key)
        if ($existing.ContainsKey($item.key)) {
            if ((Get-ComparableItem -Item $existing[$item.key]) -ceq (Get-ComparableItem -Item $item)) {
                continue
            }
            $action = 'Update'
        }
        else {
            $action = 'Add'
        }
        if ($item.key -ceq $sentinelKey) {
            $sentinelWrite = $item
        }
        else {
            $writes.Add($item)
        }
        $changes.Add((New-ChangeRecord -Action $action -Target 'setting' -Name $item.key -Label $Label))
    }
    $deletes = @($existing.Keys | Where-Object { -not $desiredKeys.Contains($_) } | Sort-Object)
    foreach ($key in $deletes) {
        $changes.Add((New-ChangeRecord -Action 'Delete' -Target 'setting' -Name $key -Label $Label))
    }

    $flagLabels = @($constants.FlagLabels.Values) -join ','
    $existingFlags = @{}
    foreach ($item in @(Get-StoreItems -StoreEndpoint $StoreEndpoint -Key ('{0}{1}.*' -f $constants.FeatureFlagKeyPrefix, $app) -Label $flagLabels)) {
        $existingFlags['{0}|{1}' -f $item.key, $item.label] = $item
    }
    foreach ($flag in @(Get-DesiredFeatureFlags -Resolved $Resolved -Label $Label)) {
        $lookup = '{0}|{1}' -f $flag.Key, $flag.Label
        $current = if ($existingFlags.ContainsKey($lookup)) { $existingFlags[$lookup] } else { $null }
        if ($null -ne $current) {
            $enabled = $flag.DefaultEnabled
            try {
                $currentEnabled = Get-OptionalProperty -InputObject (ConvertFrom-JsonText -Json ([string]$current.value)) -Name 'enabled'
                if ($currentEnabled -is [bool]) {
                    $enabled = $currentEnabled
                }
            }
            catch {
                Write-Warning "Flag '$($flag.Key)' has an unreadable value in the store; using the default state."
            }
        }
        elseif ($flag.Enabled -is [bool]) {
            $enabled = $flag.Enabled
        }
        else {
            $enabled = $flag.DefaultEnabled
        }

        $value = ConvertTo-Json -Depth 64 -Compress -InputObject ([ordered]@{
                id          = $flag.Id
                description = $flag.Description
                enabled     = $enabled
                conditions  = $flag.Conditions
            })
        $item = New-ConfigurationItem -Key $flag.Key -Label $flag.Label -Value $value -ContentType $constants.FeatureFlagContentType -Deployment $Label
        if ($null -ne $current -and ((Get-ComparableItem -Item $current -ParseValue) -ceq (Get-ComparableItem -Item $item -ParseValue))) {
            continue
        }
        $writes.Add($item)
        $action = if ($null -eq $current) { 'Add' } else { 'Update' }
        $changes.Add((New-ChangeRecord -Action $action -Target 'flag' -Name $flag.Key -Label $flag.Label -Detail ('enabled={0}' -f $enabled.ToString().ToLowerInvariant())))
    }

    if (-not $DryRun) {
        if ($writes.Count -gt 0) {
            Write-StoreItems -StoreEndpoint $StoreEndpoint -Items $writes.ToArray()
        }
        foreach ($key in $deletes) {
            Remove-StoreItem -StoreEndpoint $StoreEndpoint -Key $key -Label $Label
        }
        # The sentinel goes last, so a client that refreshes on it sees the complete set.
        if ($null -ne $sentinelWrite) {
            Write-StoreItems -StoreEndpoint $StoreEndpoint -Items @($sentinelWrite)
        }
    }
    $changes
}

#endregion

#region Slots, switch, rollback

function Get-SlotArguments {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $WebAppName,
        [Parameter(Mandatory)] [string] $Slot
    )

    '--resource-group'
    $ResourceGroup
    '--name'
    $WebAppName
    if ($Slot -ne 'production') {
        '--slot'
        $Slot
    }
}

function Get-SlotAppSettings {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $WebAppName,
        [Parameter(Mandatory)] [string] $Slot
    )

    Invoke-AzCli -Arguments (@('webapp', 'config', 'appsettings', 'list') + @(Get-SlotArguments -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot $Slot))
}

function Get-SlotConfigurationLabel {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $WebAppName,
        [Parameter(Mandatory)] [string] $Slot,
        [string] $SettingName = (Get-AppConfigurationConstants).LabelSettingName
    )

    foreach ($setting in @(Get-SlotAppSettings -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot $Slot)) {
        if ($setting.name -eq $SettingName) {
            return [string]$setting.value
        }
    }
    return $null
}

function Set-SlotAppSettings {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $WebAppName,
        [Parameter(Mandatory)] [string] $Slot,
        [Parameter(Mandatory)] [object[]] $Settings
    )

    $file = Join-Path ([System.IO.Path]::GetTempPath()) ('appsettings-{0}.json' -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $file -Value (ConvertTo-Json -InputObject $Settings -Depth 10) -Encoding utf8NoBOM
    try {
        Invoke-AzCli -Arguments (@('webapp', 'config', 'appsettings', 'set') +
            @(Get-SlotArguments -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot $Slot) +
            @('--settings', "@$file")) | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Remove-SlotAppSettings {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $WebAppName,
        [Parameter(Mandatory)] [string] $Slot,
        [Parameter(Mandatory)] [string[]] $Names
    )

    Invoke-AzCli -Arguments (@('webapp', 'config', 'appsettings', 'delete') +
        @(Get-SlotArguments -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot $Slot) +
        @('--setting-names') + $Names) | Out-Null
}

function Invoke-SlotSwap {
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $WebAppName
    )

    Invoke-AzCli -Arguments @('webapp', 'deployment', 'slot', 'swap', '--resource-group', $ResourceGroup,
        '--name', $WebAppName, '--slot', 'staging', '--target-slot', 'production') | Out-Null
}

function Update-AppConfigurationReference {
    <#
    .SYNOPSIS
        Returns the App Service reference with its Label replaced when it points to a key of the app; otherwise $null.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [string] $Label
    )

    if ($Value -notmatch '^@Microsoft\.AppConfiguration\((?<body>.*)\)\s*$') {
        return $null
    }
    $parts = [System.Collections.Generic.List[object]]::new()
    $key = $null
    foreach ($segment in ($Matches.body -split ';')) {
        $trimmed = $segment.Trim()
        if (-not $trimmed) {
            continue
        }
        $name, $partValue = $trimmed -split '=', 2
        $parts.Add([pscustomobject]@{ Name = $name.Trim(); Value = [string]$partValue })
        if ($name.Trim() -eq 'Key') {
            $key = [string]$partValue
        }
    }
    if ($null -eq $key -or -not $key.StartsWith("${AppName}:", [StringComparison]::Ordinal)) {
        return $null
    }
    $labelPart = @($parts | Where-Object Name -EQ 'Label')
    if ($labelPart.Count -gt 0) {
        $labelPart[0].Value = $Label
    }
    else {
        $parts.Add([pscustomobject]@{ Name = 'Label'; Value = $Label })
    }
    return '@Microsoft.AppConfiguration({0})' -f (@($parts | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join '; ')
}

function Invoke-SlotLabelUpdate {
    <#
    .SYNOPSIS
        Points a slot at a configuration set: sets the label setting, rewrites App Service
        references to keys of the app, and sets or removes the swap warm-up settings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $WebAppName,
        [Parameter(Mandatory)] [string] $StoreEndpoint,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [string] $Label,
        [string] $Slot = 'staging',
        [string] $SettingName = (Get-AppConfigurationConstants).LabelSettingName,
        [string] $HealthCheckPath,
        [string] $HealthCheckStatuses = '200',
        [switch] $DryRun
    )

    Assert-DeploymentLabel -Label $Label
    $constants = Get-AppConfigurationConstants
    if (-not (Test-ConfigurationSetExists -StoreEndpoint $StoreEndpoint -AppName $AppName -Label $Label)) {
        throw "Configuration set '$Label' of app '$AppName' does not exist in the store. Import it first."
    }
    if ($Slot -ne 'production') {
        # A rerun of a deployment that is already live must not overwrite the rollback target on staging.
        $production = Get-SlotConfigurationLabel -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot 'production' -SettingName $SettingName
        if ($production -ceq $Label) {
            Write-Verbose "Production already uses configuration set '$Label'; the $Slot slot is left alone."
            return
        }
    }

    $current = @{}
    foreach ($setting in @(Get-SlotAppSettings -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot $Slot)) {
        $current[[string]$setting.name] = $setting
    }

    $desired = [System.Collections.Generic.List[object]]::new()
    $desired.Add([ordered]@{ name = $SettingName; value = $Label; slotSetting = $false })
    foreach ($name in @($current.Keys | Sort-Object)) {
        $rewritten = Update-AppConfigurationReference -Value ([string]$current[$name].value) -AppName $AppName -Label $Label
        if ($null -ne $rewritten) {
            $desired.Add([ordered]@{ name = $name; value = $rewritten; slotSetting = [bool]$current[$name].slotSetting })
        }
    }

    $removals = [System.Collections.Generic.List[string]]::new()
    $warmupSettings = @($constants.WarmupPathSetting, $constants.WarmupStatusesSetting)
    if ($HealthCheckPath) {
        $desired.Add([ordered]@{ name = $constants.WarmupPathSetting; value = $HealthCheckPath; slotSetting = $true })
        $desired.Add([ordered]@{ name = $constants.WarmupStatusesSetting; value = $HealthCheckStatuses; slotSetting = $true })
    }
    else {
        foreach ($name in $warmupSettings) {
            if ($current.ContainsKey($name)) {
                $removals.Add($name)
            }
        }
    }

    $changes = [System.Collections.Generic.List[object]]::new()
    $updates = [System.Collections.Generic.List[object]]::new()
    foreach ($setting in $desired) {
        if ($current.ContainsKey($setting.name)) {
            $existing = $current[$setting.name]
            if (([string]$existing.value -ceq $setting.value) -and ([bool]$existing.slotSetting -eq $setting.slotSetting)) {
                continue
            }
        }
        $updates.Add($setting)
        $changes.Add((New-ChangeRecord -Action 'Set' -Target 'slot-setting' -Name $setting.name -Label $Label -Detail "slot=$Slot"))
    }
    foreach ($name in $removals) {
        $changes.Add((New-ChangeRecord -Action 'Delete' -Target 'slot-setting' -Name $name -Detail "slot=$Slot"))
    }

    if (-not $DryRun) {
        if ($updates.Count -gt 0) {
            Set-SlotAppSettings -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot $Slot -Settings $updates.ToArray()
        }
        if ($removals.Count -gt 0) {
            Remove-SlotAppSettings -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot $Slot -Names $removals.ToArray()
        }
    }
    $changes
}

function Invoke-ConfigurationSwitch {
    <#
    .SYNOPSIS
        Makes a configuration set active by swapping the staging slot (which points at it) into production.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $WebAppName,
        [Parameter(Mandatory)] [string] $Label,
        [string] $SettingName = (Get-AppConfigurationConstants).LabelSettingName,
        [switch] $DryRun
    )

    Assert-DeploymentLabel -Label $Label
    $production = Get-SlotConfigurationLabel -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot 'production' -SettingName $SettingName
    if ($production -ceq $Label) {
        Write-Verbose "Production already uses configuration set '$Label'."
        return
    }
    $staging = Get-SlotConfigurationLabel -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot 'staging' -SettingName $SettingName
    if ($staging -cne $Label) {
        throw "The staging slot uses configuration set '$staging', not '$Label'. Point staging at '$Label' first."
    }

    if (-not $DryRun) {
        Invoke-SlotSwap -ResourceGroup $ResourceGroup -WebAppName $WebAppName
        $after = Get-SlotConfigurationLabel -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot 'production' -SettingName $SettingName
        if ($after -cne $Label) {
            throw "After the swap production uses configuration set '$after' instead of '$Label'."
        }
    }
    New-ChangeRecord -Action 'Swap' -Target 'slot' -Name 'staging->production' -Label $Label -Detail "previous=$production"
}

function Invoke-ConfigurationRollback {
    <#
    .SYNOPSIS
        Restores the previous configuration set after a failed deployment by swapping back.
    .DESCRIPTION
        Only acts when production runs the failed label, so a rerun or a later deployment
        is never rolled back by mistake. The previous set is the label on the staging slot
        (the old production after the swap). The swap warm-up settings are removed from
        staging first, so a failing health check cannot block the way back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $WebAppName,
        [Parameter(Mandatory)] [string] $StoreEndpoint,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [string] $Label,
        [string] $SettingName = (Get-AppConfigurationConstants).LabelSettingName,
        [switch] $DryRun
    )

    $constants = Get-AppConfigurationConstants
    $production = Get-SlotConfigurationLabel -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot 'production' -SettingName $SettingName
    if ($production -cne $Label) {
        Write-Warning "Production uses configuration set '$production', not '$Label'. Nothing to roll back."
        return
    }
    $previous = Get-SlotConfigurationLabel -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot 'staging' -SettingName $SettingName
    if ([string]::IsNullOrEmpty($previous)) {
        throw "The staging slot has no previous configuration set; cannot roll back '$Label'."
    }
    if ($previous -ceq $Label) {
        throw "The staging slot also uses '$Label'; there is no previous configuration set to roll back to."
    }
    if (-not (Test-ConfigurationSetExists -StoreEndpoint $StoreEndpoint -AppName $AppName -Label $previous)) {
        throw "The previous configuration set '$previous' no longer exists in the store; cannot roll back '$Label'."
    }

    $changes = [System.Collections.Generic.List[object]]::new()
    $warmup = @($constants.WarmupPathSetting, $constants.WarmupStatusesSetting)
    $present = @(Get-SlotAppSettings -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot 'staging' |
            Where-Object { $warmup -contains $_.name } |
            ForEach-Object { [string]$_.name })
    foreach ($name in $present) {
        $changes.Add((New-ChangeRecord -Action 'Delete' -Target 'slot-setting' -Name $name -Detail 'slot=staging'))
    }
    $changes.Add((New-ChangeRecord -Action 'Swap' -Target 'slot' -Name 'staging->production' -Label $previous -Detail "rolled back from $Label"))

    if (-not $DryRun) {
        if ($present.Count -gt 0) {
            Remove-SlotAppSettings -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot 'staging' -Names $present
        }
        Invoke-SlotSwap -ResourceGroup $ResourceGroup -WebAppName $WebAppName
        $after = Get-SlotConfigurationLabel -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot 'production' -SettingName $SettingName
        if ($after -cne $previous) {
            throw "After the rollback production uses configuration set '$after' instead of '$previous'."
        }
    }
    $changes
}

#endregion

#region Cleanup

function Invoke-ConfigurationCleanup {
    <#
    .SYNOPSIS
        Deletes configuration sets that no slot uses any more.
    .DESCRIPTION
        Keeps the current label and the labels of the production and staging slots, so the
        rollback target always survives. Deletes all other labels of the app, unlabelled keys
        under '<app>:', and flags whose deployment tag is not kept.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $StoreEndpoint,
        [Parameter(Mandatory)] [string] $AppName,
        [Parameter(Mandatory)] [string] $ResourceGroup,
        [Parameter(Mandatory)] [string] $WebAppName,
        [Parameter(Mandatory)] [string] $CurrentLabel,
        [string] $SettingName = (Get-AppConfigurationConstants).LabelSettingName,
        [switch] $DryRun
    )

    Assert-DeploymentLabel -Label $CurrentLabel
    $constants = Get-AppConfigurationConstants
    $production = Get-SlotConfigurationLabel -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot 'production' -SettingName $SettingName
    $staging = Get-SlotConfigurationLabel -ResourceGroup $ResourceGroup -WebAppName $WebAppName -Slot 'staging' -SettingName $SettingName
    if ($production -cne $CurrentLabel -and $staging -cne $CurrentLabel) {
        throw "Neither slot uses configuration set '$CurrentLabel' (production: '$production', staging: '$staging'). Refusing to clean up."
    }

    $keep = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($label in @($CurrentLabel, $production, $staging)) {
        if (-not [string]::IsNullOrEmpty($label)) {
            [void]$keep.Add($label)
        }
    }

    $deletes = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-StoreItems -StoreEndpoint $StoreEndpoint -Key "${AppName}:*")) {
        $label = [string]$item.label
        if ([string]::IsNullOrEmpty($label) -or -not $keep.Contains($label)) {
            $deletes.Add([pscustomobject]@{ Key = $item.key; Label = $label; Target = 'setting' })
        }
    }
    $flagLabels = @($constants.FlagLabels.Values) -join ','
    foreach ($item in @(Get-StoreItems -StoreEndpoint $StoreEndpoint -Key ('{0}{1}.*' -f $constants.FeatureFlagKeyPrefix, $AppName) -Label $flagLabels)) {
        $deployment = [string](Get-OptionalProperty -InputObject (Get-OptionalProperty -InputObject $item -Name 'tags') -Name $constants.DeploymentTag)
        if (-not $keep.Contains($deployment)) {
            $deletes.Add([pscustomobject]@{ Key = $item.key; Label = [string]$item.label; Target = 'flag' })
        }
    }

    foreach ($delete in $deletes) {
        if (-not $DryRun) {
            Remove-StoreItem -StoreEndpoint $StoreEndpoint -Key $delete.Key -Label $delete.Label
        }
        New-ChangeRecord -Action 'Delete' -Target $delete.Target -Name $delete.Key -Label $delete.Label
    }
}

#endregion
