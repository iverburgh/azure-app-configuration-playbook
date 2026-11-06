<#
.SYNOPSIS
    Fails if any organisation-specific reference leaks into this repository.

.DESCRIPTION
    Everything published here must be generic: no organisation or product names, no tenant or
    object IDs, no internal hostnames, no work item numbers.

    Generic patterns are built in. The names of the organisation and product this playbook was
    extracted from are deliberately NOT in this file — listing them would publish them. They are
    loaded from:

      - tools/forbidden-terms.local.txt  (git-ignored; one regular expression per line, # comments)
      - the FORBIDDEN_TERMS environment variable (separated by newlines or semicolons), which CI
        fills from a repository secret

    Some generic names in this playbook, such as the file name AppConfiguration.CircuitBreakerFlags.json,
    can contain an organisation-specific term. Those exact phrases are listed in $allowedPhrases and
    removed from a line before the organisation-specific terms are matched; the rest of the line is
    still checked.

.PARAMETER Path
    Root to scan. Defaults to the repository root.

.EXAMPLE
    pwsh ./tools/Test-NoInternalReferences.ps1
#>
[CmdletBinding()]
param(
    [string] $Path = (Split-Path $PSScriptRoot -Parent)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$binary = '\.(png|jpe?g|gif|ico|svg|pdf|zip|gz|7z|dll|exe|pfx|cer|snk|woff2?|ttf)$'
$localTerms = Join-Path $PSScriptRoot 'forbidden-terms.local.txt'

# Generic names that are part of this playbook's design. Matched literally and case-insensitively.
$allowedPhrases = @(
    'CircuitBreakerFlags'
)

# Application IDs that are the same in every tenant, and therefore safe to publish.
$publicIds = @(
    '00000003-0000-0000-c000-000000000000' # Microsoft Graph
    '04b07795-8ddb-461a-bbee-02f9e1bf7b46' # Azure CLI
    '1950a258-227b-4e31-a9cf-717495945fc2' # Azure PowerShell
)
$guidPattern = '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b' + (($publicIds | ForEach-Object { "(?<!$_)" }) -join '')

# Scan everything except binaries: an extension allow-list would skip dotfiles, where stray references hide.
$files = @(Get-ChildItem -Path $Path -Recurse -File -Force |
        Where-Object {
            $_.FullName -notmatch '[\\/](\.git|node_modules|bin|obj|out|TestResults)[\\/]' -and
            $_.Extension -notmatch $binary -and
            $_.FullName -ne $PSCommandPath -and
            $_.FullName -ne $localTerms
        })

$generic = @(
    @{ Name = 'Organisation URL';     Pattern = 'dev\.azure\.com/(?!<|example/)[A-Za-z0-9._-]+/[A-Za-z0-9._-]'; Why = 'Use dev.azure.com/<org>/<project>.' }
    @{ Name = 'Legacy org URL';       Pattern = '(?<![./-])\b(?!(code|marketplace|app)\.)[A-Za-z0-9-]+\.visualstudio\.com'; Why = 'Use dev.azure.com/<org>.' }
    @{ Name = 'Tenant domain';        Pattern = '(?i)\b(?!contoso\b|fabrikam\b)[a-z0-9-]+\.onmicrosoft\.com'; Why = 'Use contoso.onmicrosoft.com.' }
    @{ Name = 'Internal mail domain'; Pattern = '@(?!example\.com)[A-Za-z0-9-]+\.(nl|local|internal)\b';  Why = 'Use example.com.' }
    @{ Name = 'Work item reference';  Pattern = '(?i)\b(PBI|task|feature|bug)\s*#?\s*\d{5,}\b|#\d{6,}';   Why = 'Internal tracking numbers.' }
    @{ Name = 'Tenant or object ID';  Pattern = $guidPattern;                                             Why = 'GUIDs identify real tenants, applications and identities. (Well-known Microsoft application IDs are allowed.)' }
    @{ Name = 'Key Vault URL';        Pattern = '(?i)https://(?!<|kv-orders)[a-z0-9-]+\.vault\.azure\.net'; Why = 'Use the example vault names or a <vault> placeholder.' }
    @{ Name = 'App Configuration URL'; Pattern = '(?i)https://(?!<|appcs-orders|appcs-example)[a-z0-9-]+\.azconfig\.io'; Why = 'Use the example store names or a <store> placeholder.' }
    @{ Name = 'Windows user path';    Pattern = '(?i)C:\\Users\\(?!<)[A-Za-z0-9._-]+\\';                  Why = 'Personal paths identify people.' }
    @{ Name = 'Dutch text';           Pattern = '(?i)\b(werd|wordt|niet|geen|deze|zodat|omdat|waardoor|bijvoorbeeld|voorkomt)\b'; Why = 'Repository is English-only.' }
)

$extra = @()
if (Test-Path $localTerms) { $extra += Get-Content $localTerms }
if ($env:FORBIDDEN_TERMS) { $extra += $env:FORBIDDEN_TERMS -split '[;\r\n]+' }
$extra = @($extra | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })

Write-Host "Scanning $($files.Count) files under $Path"
if ($extra.Count -eq 0) {
    Write-Warning 'No organisation-specific terms loaded: create tools/forbidden-terms.local.txt or set FORBIDDEN_TERMS. Only generic patterns are checked.'
}
else {
    Write-Host "Loaded $($extra.Count) organisation-specific term(s)."
}

$findings = [Collections.Generic.List[object]]::new()
foreach ($rule in $generic) {
    foreach ($hit in @($files | Select-String -Pattern $rule.Pattern -AllMatches -ErrorAction SilentlyContinue)) {
        $findings.Add([pscustomobject]@{
                Rule = $rule.Name
                File = [IO.Path]::GetRelativePath($Path, $hit.Path)
                Line = $hit.LineNumber
                Text = $hit.Line.Trim()
                Why  = $rule.Why
            })
    }
}

if ($extra.Count -gt 0) {
    $allowed = ($allowedPhrases | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $termPatterns = @($extra | ForEach-Object { [regex]::new("(?i)$_") })
    foreach ($file in $files) {
        $lineNumber = 0
        foreach ($line in [IO.File]::ReadLines($file.FullName)) {
            $lineNumber++
            $checked = if ($allowed) { [regex]::Replace($line, $allowed, '', 'IgnoreCase') } else { $line }
            if (@($termPatterns | Where-Object { $_.IsMatch($checked) }).Count -gt 0) {
                $findings.Add([pscustomobject]@{
                        Rule = 'Organisation-specific term'
                        File = [IO.Path]::GetRelativePath($Path, $file.FullName)
                        Line = $lineNumber
                        # CI logs are public: never echo an organisation-specific match.
                        Text = '(match hidden)'
                        Why  = 'Listed in forbidden-terms.local.txt or FORBIDDEN_TERMS.'
                    })
            }
        }
    }
}

if ($findings.Count -eq 0) {
    Write-Host 'No internal references found.' -ForegroundColor Green
    exit 0
}

Write-Host ''
Write-Host "$($findings.Count) potential leak(s) found:" -ForegroundColor Red
foreach ($group in $findings | Group-Object Rule) {
    Write-Host ''
    Write-Host "  $($group.Name) - $($group.Group[0].Why)" -ForegroundColor Yellow
    foreach ($f in $group.Group) {
        $snippet = if ($f.Text.Length -gt 110) { $f.Text.Substring(0, 110) + '...' } else { $f.Text }
        Write-Host "    $($f.File):$($f.Line)  $snippet"
    }
}
Write-Host ''
exit 1
