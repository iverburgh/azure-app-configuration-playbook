Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'AppConfiguration.ps1')

<#
    Generated pipeline variables: one Azure DevOps variable template per pipeline and environment,
    holding only the variables that pipeline uses, resolved from app-configuration/variables/.
    New-PipelineVariables.ps1 is the entry script; see docs/generated-pipeline-variables.md.
#>

#region Constants and helpers

function Get-PipelineVariablesConstants {
    @{
        HeaderPrefix          = '# AUTO-GENERATED'
        SettingsSuffix        = '.variables.json'
        CommonScope           = 'common'
        AllVariables          = '*'
        PipelineNamePattern   = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
        # Azure Pipelines allows letters, digits, '.' and '_' in variable names, and reserves these
        # prefixes, whatever their case: such a variable never reaches a task or script.
        PipelineVariablePattern = '^[A-Za-z][A-Za-z0-9_.]*$'
        ReservedPrefixes      = @('endpoint', 'input', 'secret', 'path', 'securefile')
        UsagePatterns         = @(
            '\$\(([A-Za-z_][A-Za-z0-9_.]*)\)'          # $(Name)
            '\bvariables\.([A-Za-z_][A-Za-z0-9_]*)'     # variables.Name, in ${{ }}, $[ ] and conditions
            "\bvariables\[\s*'([^']+)'\s*\]"            # variables['Name']
            '\bvariables\[\s*"([^"]+)"\s*\]'            # variables["Name"]
        )
        TokenPattern          = '#\{([A-Za-z][A-Za-z0-9_.-]*)\}#'
        TemplatePattern       = '^\s*(?:-\s*)?template:\s*[''"]?([^''"\s#]+)'
    }
}

function Get-OrdinalSorted {
    <# Sorts strings the same way on every machine: ordinal, optionally ignoring case. #>
    param(
        [AllowNull()] [AllowEmptyCollection()] [string[]] $Values,
        [switch] $IgnoreCase
    )

    if ($null -eq $Values -or $Values.Count -eq 0) {
        return
    }
    $array = [string[]]$Values.Clone()
    $comparer = if ($IgnoreCase) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    [Array]::Sort($array, $comparer)
    foreach ($value in $array) {
        $value
    }
}

function Get-NormalizedFullPath {
    param([Parameter(Mandatory)] [string] $Path)
    [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

function Test-IsUnderPath {
    <# True when Path is Directory itself or inside it. #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Directory
    )

    $full = Get-NormalizedFullPath $Path
    $root = Get-NormalizedFullPath $Directory
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativeDisplayPath {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $RepositoryRoot
    )
    [System.IO.Path]::GetRelativePath((Get-NormalizedFullPath $RepositoryRoot), (Get-NormalizedFullPath $Path)) -replace '\\', '/'
}

function Get-EnvironmentNames {
    <# The environments: every variables file except common.json, sorted ordinally. #>
    param([Parameter(Mandatory)] [string] $VariablesPath)

    $names = @(foreach ($file in @(Get-ChildItem -LiteralPath $VariablesPath -Filter '*.json' -File)) {
            if ($file.Extension -eq '.json' -and $file.BaseName -ne 'common') {
                $file.BaseName
            }
        })
    Get-OrdinalSorted -Values $names
}

function Test-IsGeneratedFile {
    param([Parameter(Mandatory)] [string] $Path)

    $reader = [System.IO.StreamReader]::new($Path)
    try {
        $firstLine = $reader.ReadLine()
    }
    finally {
        $reader.Dispose()
    }
    $null -ne $firstLine -and $firstLine.StartsWith((Get-PipelineVariablesConstants).HeaderPrefix, [StringComparison]::Ordinal)
}

#endregion

#region Scanning

function Find-PipelineVariableReferences {
    <#
    .SYNOPSIS
        Writes the variable names a pipeline YAML text refers to. Full-line comments are skipped.
    #>
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $patterns = (Get-PipelineVariablesConstants).UsagePatterns
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*#') {
            continue
        }
        foreach ($pattern in $patterns) {
            foreach ($match in [regex]::Matches($line, $pattern)) {
                $match.Groups[1].Value
            }
        }
    }
}

function Find-AppTokenNames {
    <# Writes the names of the #{Token}# placeholders in every JSON file of one app. #>
    param([Parameter(Mandatory)] [string] $AppPath)

    $pattern = (Get-PipelineVariablesConstants).TokenPattern
    foreach ($file in @(Get-ChildItem -LiteralPath $AppPath -Filter '*.json' -File)) {
        foreach ($match in [regex]::Matches([System.IO.File]::ReadAllText($file.FullName), $pattern)) {
            $match.Groups[1].Value
        }
    }
}

function Get-PipelineTemplateFiles {
    <#
    .SYNOPSIS
        Writes the full paths of the local templates a pipeline file includes, recursively.
    .DESCRIPTION
        A path relative to the including file, or starting with '/' for the repository root, is
        followed. Paths with an expression (${{ }}), a repository reference (@) or inside the
        generated output folder are not: the generated variable templates are output, not input.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $RepositoryRoot,
        [Parameter(Mandatory)] [string] $OutputPath,
        [System.Collections.Generic.HashSet[string]] $Visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    )

    $pattern = (Get-PipelineVariablesConstants).TemplatePattern
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*#') {
            continue
        }
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) {
            continue
        }
        $reference = $match.Groups[1].Value
        if ($reference.Contains('${{') -or $reference.Contains('$(') -or $reference.Contains('@')) {
            continue
        }
        $base = if ($reference.StartsWith('/')) { $RepositoryRoot } else { Split-Path -Parent $Path }
        $full = Get-NormalizedFullPath (Join-Path $base $reference.TrimStart('/'))
        if (Test-IsUnderPath -Path $full -Directory $OutputPath) {
            continue
        }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            Write-Warning "Template '$reference' in '$Path' does not exist; its variables are not scanned."
            continue
        }
        if ($Visited.Add($full)) {
            $full
            Get-PipelineTemplateFiles -Path $full -RepositoryRoot $RepositoryRoot -OutputPath $OutputPath -Visited $Visited
        }
    }
}

#endregion

#region Pipelines

function Get-PipelineDefinitions {
    <#
    .SYNOPSIS
        Writes one object per pipeline: every *.yml directly in PipelinesPath.
    .OUTPUTS
        Name, PipelineFile, SettingsFile (or $null), Settings (or $null), Apps, Templates.
    #>
    param(
        [Parameter(Mandatory)] [string] $PipelinesPath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [string] $AppsPath,
        [Parameter(Mandatory)] [string] $SchemaPath,
        [Parameter(Mandatory)] [string] $RepositoryRoot
    )

    $constants = Get-PipelineVariablesConstants
    $schemaFile = Join-Path $SchemaPath (Get-AppConfigurationConstants).Schemas.PipelineVariables
    $files = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $PipelinesPath -Filter '*.yml' -File)) {
        if ($file.Extension -eq '.yml') {
            $files[$file.Name] = $file
        }
    }
    foreach ($fileName in @(Get-OrdinalSorted -Values @($files.Keys))) {
        $file = $files[$fileName]
        $name = $file.BaseName
        if ($name -cnotmatch $constants.PipelineNamePattern) {
            throw "Pipeline file name '$($file.Name)' is not valid. Use letters, digits, '.', '_' or '-'."
        }

        $settingsFile = Join-Path $PipelinesPath "$name$($constants.SettingsSuffix)"
        $settings = $null
        if (Test-Path -LiteralPath $settingsFile -PathType Leaf) {
            $errors = @(Test-JsonFile -Path $settingsFile -SchemaFile $schemaFile -Source (Split-Path -Leaf $settingsFile))
            if ($errors.Count -gt 0) {
                throw ("Pipeline settings are not valid:`n  {0}" -f ($errors -join "`n  "))
            }
            $settings = Read-JsonFile -Path $settingsFile
        }
        else {
            $settingsFile = $null
        }

        $appsValue = Get-OptionalProperty -InputObject $settings -Name 'apps'
        $apps = @()
        if ($null -ne $appsValue) {
            $apps = @(Get-OptionalArray $appsValue)
            foreach ($app in $apps) {
                if (-not (Test-Path -LiteralPath (Join-Path $AppsPath $app) -PathType Container)) {
                    throw "Pipeline '$name' lists app '$app', which does not exist in '$AppsPath'."
                }
            }
        }
        elseif (Test-Path -LiteralPath (Join-Path $AppsPath $name) -PathType Container) {
            $apps = @($name)
        }

        [pscustomobject]@{
            Name         = $name
            PipelineFile = $file.FullName
            SettingsFile = $settingsFile
            Settings     = $settings
            Apps         = [string[]]$apps
            Templates    = [string[]]@(Get-PipelineTemplateFiles -Path $file.FullName -RepositoryRoot $RepositoryRoot -OutputPath $OutputPath)
        }
    }
}

function Get-PipelineUsedVariableNames {
    <# Writes, once each, the names the pipeline, its templates and its apps refer to. #>
    param(
        [Parameter(Mandatory)] $Definition,
        [Parameter(Mandatory)] [string] $AppsPath
    )

    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in @(@($Definition.PipelineFile) + @($Definition.Templates))) {
        foreach ($name in @(Find-PipelineVariableReferences -Text ([System.IO.File]::ReadAllText($file)))) {
            [void]$names.Add($name)
        }
    }
    foreach ($app in @($Definition.Apps)) {
        foreach ($name in @(Find-AppTokenNames -AppPath (Join-Path $AppsPath $app))) {
            [void]$names.Add($name)
        }
    }
    Get-OrdinalSorted -Values @($names)
}

function Get-PipelineOverrideScopes {
    <# Writes the scope names in 'overrides' of a pipeline settings object. #>
    param([AllowNull()] $Settings)

    $overrides = Get-OptionalProperty -InputObject $Settings -Name 'overrides'
    if ($null -eq $overrides) {
        return
    }
    foreach ($property in $overrides.PSObject.Properties) {
        $property.Name
    }
}

function Get-PipelineEnvironmentVariables {
    <#
    .SYNOPSIS
        Returns the variables of one pipeline for one environment, sorted, as an ordered dictionary.
    .DESCRIPTION
        Layers, later wins: common.json, <environment>.json, overrides.common,
        overrides.<environment>. References between variables are resolved after the layers are
        merged. Included are: every used name the environment defines, every overridden name and
        every extra key. An extra key the environment does not define gets the value $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Definition,
        [Parameter(Mandatory)] [string] $VariablesPath,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $UsedNames
    )

    $constants = Get-PipelineVariablesConstants
    $settingsName = if ($Definition.SettingsFile) { "'$(Split-Path -Leaf $Definition.SettingsFile)'" } else { 'the pipeline settings' }
    $overrides = Get-OptionalProperty -InputObject $Definition.Settings -Name 'overrides'
    $layers = [System.Collections.Generic.List[object]]::new()
    $overriddenNames = [System.Collections.Generic.List[string]]::new()
    foreach ($scope in @($constants.CommonScope, $Environment)) {
        $values = Get-OptionalProperty -InputObject $overrides -Name $scope
        if ($null -eq $values) {
            continue
        }
        $layers.Add([pscustomobject]@{ Source = "$settingsName (overrides.$scope)"; Values = $values })
        foreach ($property in $values.PSObject.Properties) {
            $overriddenNames.Add($property.Name)
        }
    }

    $variables = Get-DeploymentVariables -VariablesPath $VariablesPath -Environment $Environment -Overrides $layers.ToArray()

    $selected = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $extraKeys = @(Get-OptionalArray (Get-OptionalProperty -InputObject $Definition.Settings -Name 'extraKeys'))
    if ($extraKeys -contains $constants.AllVariables) {
        foreach ($name in $variables.Keys) {
            $selected[$name] = $variables[$name]
        }
    }
    foreach ($name in @($UsedNames) + @($overriddenNames)) {
        if ($variables.ContainsKey($name)) {
            $selected[$name] = $variables[$name]
        }
    }
    foreach ($name in $extraKeys) {
        if ($name -eq $constants.AllVariables -or $selected.ContainsKey($name)) {
            continue
        }
        if ($variables.ContainsKey($name)) {
            $selected[$name] = $variables[$name]
        }
        else {
            Write-Warning "Pipeline '$($Definition.Name)': extra key '$name' is not defined for environment '$Environment'; it gets an empty value."
            $selected[$name] = $null
        }
    }

    $seen = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $result = [ordered]@{}
    foreach ($name in @(Get-OrdinalSorted -Values @($selected.Keys) -IgnoreCase)) {
        if ($seen.ContainsKey($name)) {
            throw "Pipeline '$($Definition.Name)', environment '${Environment}': variables '$($seen[$name])' and '$name' differ only in case. Azure Pipelines variable names are not case-sensitive."
        }
        $seen[$name] = $name
        if ($name -cnotmatch $constants.PipelineVariablePattern) {
            throw "Pipeline '$($Definition.Name)': variable '$name' cannot be a pipeline variable. Use letters, digits, '.' and '_' only."
        }
        foreach ($prefix in $constants.ReservedPrefixes) {
            if ($name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Pipeline '$($Definition.Name)': variable '$name' starts with '$prefix', a prefix Azure Pipelines reserves."
            }
        }
        $value = $selected[$name]
        if ($null -ne $value -and ($value.Contains("`n") -or $value.Contains("`r"))) {
            throw "Pipeline '$($Definition.Name)', environment '${Environment}': the value of '$name' contains a line break, which a pipeline variable cannot hold."
        }
        $result[$name] = $value
    }
    $PSCmdlet.WriteObject($result, $false)
}

function ConvertTo-PipelineVariablesYaml {
    <#
    .SYNOPSIS
        Renders a variable template: header, then one single-quoted value per line, LF line endings.
        A $null value is written as an empty string.
    #>
    param(
        [Parameter(Mandatory)] [string] $PipelineName,
        [Parameter(Mandatory)] [string] $Environment,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.IDictionary] $Variables
    )

    $constants = Get-PipelineVariablesConstants
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("$($constants.HeaderPrefix) by app-configuration/New-PipelineVariables.ps1. Do not edit this file.")
    $lines.Add("# Pipeline '$PipelineName', environment '$Environment'. Change app-configuration/variables/ or")
    $lines.Add("# pipelines/$PipelineName$($constants.SettingsSuffix), then run the generator again.")
    if ($Variables.Count -eq 0) {
        $lines.Add('variables: {}')
    }
    else {
        $lines.Add('variables:')
        foreach ($name in $Variables.Keys) {
            $value = if ($null -eq $Variables[$name]) { '' } else { [string]$Variables[$name] }
            $lines.Add(("  {0}: '{1}'" -f $name, $value.Replace("'", "''")))
        }
    }
    ($lines -join "`n") + "`n"
}

#endregion

#region Selection and plan

function Split-StagedFileList {
    <# Accepts paths as separate values, comma- or newline-separated; writes them with '/' separators. #>
    param([AllowNull()] [AllowEmptyCollection()] [string[]] $StagedFiles)

    foreach ($entry in @(Get-OptionalArray $StagedFiles)) {
        foreach ($part in ($entry -split '[,\r\n]')) {
            $path = ($part.Trim() -replace '\\', '/') -replace '^\./', ''
            if ($path) {
                $path
            }
        }
    }
}

function Select-PipelinesForStagedFiles {
    <#
    .SYNOPSIS
        Maps changed files (relative to the repository root) to the pipelines whose output they affect.
    .OUTPUTS
        An object with All (a shared input changed: regenerate everything) and Names.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Definitions,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $StagedFiles,
        [Parameter(Mandatory)] [string] $RepositoryRoot,
        [Parameter(Mandatory)] [string] $PipelinesPath,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [string] $AppsPath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $SharedInputs
    )

    $constants = Get-PipelineVariablesConstants
    $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($relative in @(Split-StagedFileList $StagedFiles)) {
        $full = Get-NormalizedFullPath (Join-Path $RepositoryRoot $relative)
        foreach ($shared in $SharedInputs) {
            if (Test-IsUnderPath -Path $full -Directory $shared) {
                return [pscustomobject]@{ All = $true; Names = [string[]]@() }
            }
        }
        if (Test-IsUnderPath -Path $full -Directory $OutputPath) {
            $rest = [System.IO.Path]::GetRelativePath((Get-NormalizedFullPath $OutputPath), $full) -replace '\\', '/'
            $segment = ($rest -split '/')[0]
            if ($segment -and $segment -ne '.') {
                [void]$names.Add($segment)
            }
            continue
        }
        $parent = Split-Path -Parent $full
        $leaf = Split-Path -Leaf $full
        if ($parent.Equals((Get-NormalizedFullPath $PipelinesPath), [StringComparison]::OrdinalIgnoreCase)) {
            if ($leaf.EndsWith($constants.SettingsSuffix, [StringComparison]::Ordinal)) {
                [void]$names.Add($leaf.Substring(0, $leaf.Length - $constants.SettingsSuffix.Length))
                continue
            }
            if ($leaf.EndsWith('.yml', [StringComparison]::Ordinal)) {
                [void]$names.Add($leaf.Substring(0, $leaf.Length - 4))
                continue
            }
        }
        foreach ($definition in $Definitions) {
            $affected = $false
            foreach ($template in @($definition.Templates)) {
                if ($template.Equals($full, [StringComparison]::OrdinalIgnoreCase)) {
                    $affected = $true
                }
            }
            foreach ($app in @($definition.Apps)) {
                if (Test-IsUnderPath -Path $full -Directory (Join-Path $AppsPath $app)) {
                    $affected = $true
                }
            }
            if ($affected) {
                [void]$names.Add($definition.Name)
            }
        }
    }
    [pscustomobject]@{ All = $false; Names = [string[]]@(Get-OrdinalSorted -Values @($names)) }
}

function Get-PipelineVariablesPlan {
    <#
    .SYNOPSIS
        Computes every generated file for the given pipelines and compares it with the disk.
    .DESCRIPTION
        Writes one object per file with Pipeline, Environment, Path, Action and Content. Action is
        Create, Update, Delete (a generated file no environment or pipeline needs any more) or
        Unchanged. Line endings are ignored in the comparison, so a CRLF checkout is not drift.
        Only files that start with the generated header are ever deleted.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Definitions,
        [Parameter(Mandatory)] [string] $OutputPath,
        [Parameter(Mandatory)] [string] $AppsPath,
        [Parameter(Mandatory)] [string] $VariablesPath,
        [string[]] $Names = @(),
        [switch] $All
    )

    $environments = @(Get-EnvironmentNames -VariablesPath $VariablesPath)
    if ($environments.Count -eq 0) {
        throw "No environment files found in '$VariablesPath'."
    }

    $targets = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($All) {
        foreach ($definition in $Definitions) {
            [void]$targets.Add($definition.Name)
        }
        if (Test-Path -LiteralPath $OutputPath -PathType Container) {
            foreach ($folder in @(Get-ChildItem -LiteralPath $OutputPath -Directory)) {
                [void]$targets.Add($folder.Name)
            }
        }
    }
    foreach ($name in @(Get-OptionalArray $Names)) {
        [void]$targets.Add($name)
    }

    foreach ($name in @(Get-OrdinalSorted -Values @($targets))) {
        $definition = $null
        foreach ($candidate in $Definitions) {
            if ($candidate.Name -ceq $name) {
                $definition = $candidate
            }
        }
        $folder = Join-Path $OutputPath $name
        $desired = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)

        if ($null -ne $definition) {
            foreach ($scope in @(Get-PipelineOverrideScopes -Settings $definition.Settings)) {
                if ($scope -ne (Get-PipelineVariablesConstants).CommonScope -and $environments -cnotcontains $scope) {
                    Write-Warning "Pipeline '$name': overrides for environment '$scope' are ignored; '$scope.json' does not exist in '$VariablesPath'."
                }
            }
            $usedNames = [string[]]@(Get-PipelineUsedVariableNames -Definition $definition -AppsPath $AppsPath)
            foreach ($environment in $environments) {
                $variables = Get-PipelineEnvironmentVariables -Definition $definition -VariablesPath $VariablesPath -Environment $environment -UsedNames $usedNames
                $path = Join-Path $folder "$environment.yml"
                $desired[$path] = ConvertTo-PipelineVariablesYaml -PipelineName $name -Environment $environment -Variables $variables
                $current = if (Test-Path -LiteralPath $path -PathType Leaf) { [System.IO.File]::ReadAllText($path) -replace "`r`n", "`n" } else { $null }
                $action = if ($null -eq $current) { 'Create' } elseif ($current -ceq $desired[$path]) { 'Unchanged' } else { 'Update' }
                [pscustomobject]@{ Pipeline = $name; Environment = $environment; Path = $path; Action = $action; Content = $desired[$path] }
            }
        }

        if (Test-Path -LiteralPath $folder -PathType Container) {
            $obsolete = @(foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter '*.yml' -File)) {
                    if (-not $desired.ContainsKey($file.FullName) -and (Test-IsGeneratedFile -Path $file.FullName)) {
                        $file.FullName
                    }
                })
            foreach ($path in @(Get-OrdinalSorted -Values $obsolete)) {
                [pscustomobject]@{ Pipeline = $name; Environment = [System.IO.Path]::GetFileNameWithoutExtension($path); Path = $path; Action = 'Delete'; Content = $null }
            }
        }
    }
}

#endregion
