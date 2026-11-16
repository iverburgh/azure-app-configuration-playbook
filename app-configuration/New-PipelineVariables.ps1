#Requires -Version 7.2
<#
.SYNOPSIS
    Generates one Azure DevOps variable template per pipeline and environment, holding only the
    variables that pipeline uses.

.DESCRIPTION
    Every *.yml directly in pipelines/ is a pipeline. The generator scans it and the local
    templates it includes for $(Name), variables.Name and variables['Name'], and scans the apps
    it deploys for #{Name}# tokens. For each environment in app-configuration/variables/ it writes
    pipelines/variables/<pipeline>/<environment>.yml with the resolved values of the variables it
    found, plus the overrides and extra keys in pipelines/<pipeline>.variables.json.

    The output is deterministic: names sorted ordinally (ignoring case), values single-quoted,
    culture-invariant, LF line endings, UTF-8 without BOM, no timestamps. A file is only written
    when its content changes, so a second run changes nothing. Generated files that are no longer
    needed are deleted; a file without the generated header is never touched.

    See docs/generated-pipeline-variables.md.

.PARAMETER Pipeline
    Regenerate only these pipelines (file names without .yml).

.PARAMETER StagedFiles
    Regenerate only the pipelines these changed files affect. Paths are relative to the repository
    root, as separate values or comma- or newline-separated (git diff --name-only). A change to a
    shared input, such as app-configuration/variables/, regenerates every pipeline.

.PARAMETER Check
    Drift check for CI: compute everything, write nothing, list the files that differ and exit
    with code 1 when there are any.

.PARAMETER PassThru
    Also write one object per generated file (Pipeline, Environment, Path, Action).

.EXAMPLE
    ./New-PipelineVariables.ps1

.EXAMPLE
    ./New-PipelineVariables.ps1 -Check

.EXAMPLE
    ./New-PipelineVariables.ps1 -StagedFiles (git diff --cached --name-only)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $Pipeline,
    [string[]] $StagedFiles,
    [switch] $Check,
    [switch] $PassThru,
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $PipelinesPath,
    [string] $OutputPath,
    [string] $AppsPath = (Join-Path $PSScriptRoot 'apps'),
    [string] $VariablesPath = (Join-Path $PSScriptRoot 'variables'),
    [string] $SchemaPath = (Join-Path $PSScriptRoot 'schemas')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/PipelineVariables.ps1')

if ($Pipeline -and $PSBoundParameters.ContainsKey('StagedFiles')) {
    throw 'Use either -Pipeline or -StagedFiles, not both.'
}
$RepositoryRoot = Get-NormalizedFullPath $RepositoryRoot
if (-not $PipelinesPath) {
    $PipelinesPath = Join-Path $RepositoryRoot 'pipelines'
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $PipelinesPath 'variables'
}
$PipelinesPath = Get-NormalizedFullPath $PipelinesPath
$OutputPath = Get-NormalizedFullPath $OutputPath
$AppsPath = Get-NormalizedFullPath $AppsPath
$VariablesPath = Get-NormalizedFullPath $VariablesPath
$SchemaPath = Get-NormalizedFullPath $SchemaPath

$definitions = @(Get-PipelineDefinitions -PipelinesPath $PipelinesPath -OutputPath $OutputPath -AppsPath $AppsPath -SchemaPath $SchemaPath -RepositoryRoot $RepositoryRoot)

$all = $false
$names = @()
if ($Pipeline) {
    foreach ($name in $Pipeline) {
        $known = $false
        foreach ($definition in $definitions) {
            if ($definition.Name -ceq $name) {
                $known = $true
            }
        }
        if (-not $known -and -not (Test-Path -LiteralPath (Join-Path $OutputPath $name) -PathType Container)) {
            throw "Pipeline '$name' does not exist in '$PipelinesPath'."
        }
    }
    $names = @($Pipeline)
}
elseif ($PSBoundParameters.ContainsKey('StagedFiles')) {
    $sharedInputs = @(
        $VariablesPath
        Join-Path $SchemaPath (Get-AppConfigurationConstants).Schemas.PipelineVariables
        $PSCommandPath
        Join-Path $PSScriptRoot 'lib/PipelineVariables.ps1'
        Join-Path $PSScriptRoot 'lib/AppConfiguration.ps1'
    )
    $selection = Select-PipelinesForStagedFiles -Definitions $definitions -StagedFiles @(Get-OptionalArray $StagedFiles) -RepositoryRoot $RepositoryRoot -PipelinesPath $PipelinesPath -OutputPath $OutputPath -AppsPath $AppsPath -SharedInputs $sharedInputs
    $all = $selection.All
    $names = @($selection.Names)
    if (-not $all -and $names.Count -eq 0) {
        Write-Host 'No changed file affects the generated pipeline variables. Nothing to regenerate.'
        exit 0
    }
}
else {
    $all = $true
}

$plan = @(Get-PipelineVariablesPlan -Definitions $definitions -OutputPath $OutputPath -AppsPath $AppsPath -VariablesPath $VariablesPath -Names $names -All:$all)
$changes = @(foreach ($item in $plan) { if ($item.Action -ne 'Unchanged') { $item } })
$scope = if ($all) { 'all pipelines' } else { "pipeline(s) $($names -join ', ')" }

if ($Check) {
    if ($changes.Count -eq 0) {
        Write-Host "Generated pipeline variables are up to date ($($plan.Count) file(s), $scope)."
        exit 0
    }
    Write-Host 'Generated pipeline variables are out of date:'
    foreach ($item in $changes) {
        Write-Host ('  {0,-6} {1}' -f $item.Action.ToLowerInvariant(), (Get-RelativeDisplayPath -Path $item.Path -RepositoryRoot $RepositoryRoot))
    }
    Write-Host 'Run ./app-configuration/New-PipelineVariables.ps1 and commit the result. Never edit generated files by hand.'
    exit 1
}

$encoding = [System.Text.UTF8Encoding]::new($false)
$written = 0
foreach ($item in $changes) {
    $display = Get-RelativeDisplayPath -Path $item.Path -RepositoryRoot $RepositoryRoot
    if ($item.Action -eq 'Delete') {
        if ($PSCmdlet.ShouldProcess($display, 'Delete obsolete generated file')) {
            Remove-Item -LiteralPath $item.Path -Force
            $folder = Split-Path -Parent $item.Path
            if (@(Get-ChildItem -LiteralPath $folder -Force).Count -eq 0) {
                Remove-Item -LiteralPath $folder -Force
            }
            Write-Host "Deleted $display"
            $written++
        }
        continue
    }
    if ($PSCmdlet.ShouldProcess($display, "$($item.Action) generated file")) {
        $folder = Split-Path -Parent $item.Path
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $folder -Force)
        }
        [System.IO.File]::WriteAllText($item.Path, $item.Content, $encoding)
        Write-Host "$($item.Action)d $display"
        $written++
    }
}

if ($PassThru) {
    foreach ($item in $plan) {
        [pscustomobject]@{
            Pipeline    = $item.Pipeline
            Environment = $item.Environment
            Path        = Get-RelativeDisplayPath -Path $item.Path -RepositoryRoot $RepositoryRoot
            Action      = $item.Action
        }
    }
}

Write-Host ('{0} of {1} generated file(s) changed ({2}).' -f $written, $plan.Count, $scope)
exit 0
