#Requires -Version 7.0
<#
    QA for the documentation. Runs on Windows, Linux and macOS.

    The documents in this repository are not decoration. The ADRs are what gets
    ported to MACSS — ADR 0004 says the port is a review of them plus a rewrite
    — and architecture.md is where someone goes to learn what a step can be.
    Both drift silently: nothing failed when a fifth step state was added and
    the table that lists them was not, and nothing failed when a command was
    added and the page describing the machinery never mentioned it.

    These assertions read the code and the prose and require them to agree.
    They need nothing but PowerShell, so they can run in CI.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code/powershell/Workstation'
$DocsRoot       = Join-Path $RepositoryRoot 'docs'
$AdrRoot        = Join-Path $DocsRoot 'adr'

$script:Results = [System.Collections.Generic.List[object]]::new()

function Set-Group { param([string] $Name)
    Write-Host ''
    Write-Host "  $Name" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $Name.Length)) -ForegroundColor DarkCyan
}
function Confirm-That {
    param([string] $Id, [string] $Description, [AllowNull()] $Condition, [string] $Detail = '')
    $passed = [bool] $Condition
    $script:Results.Add([PSCustomObject]@{ Id = $Id; Description = $Description; Passed = $passed; Detail = $Detail })
    $mark  = if ($passed) { 'PASS' } else { 'FAIL' }
    $color = if ($passed) { 'Green' } else { 'Red' }
    Write-Host ('    [{0}] {1}  {2}' -f $mark, $Id, $Description) -ForegroundColor $color
    if (-not $passed -and $Detail) { Write-Host "           $Detail" -ForegroundColor DarkRed }
}
function Get-Doc { param([string] $Relative) Get-Content -LiteralPath (Join-Path $RepositoryRoot $Relative) -Raw }

Write-Host ''
Write-Host '  WORKSTATION — DOCUMENTATION QA' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray

Import-Module $ModulePath -Force -ErrorAction Stop

$architecture = Get-Doc 'docs/architecture.md'
$readme       = Get-Doc 'README.md'
$usage        = Get-Doc 'docs/usage.md'

# ===========================================================================
Set-Group 'Group D1 — the code and the pages that describe it agree'

# Every state a step can hold has to appear where the states are documented.
# A fifth state was added to the module and this table was not touched, and
# nothing anywhere went red.
$states = @(& (Get-Module Workstation) {
    (Get-Command New-WorkstationStep).Parameters['State'].Attributes |
        Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
        ForEach-Object { $_.ValidValues }
})
Confirm-That 'D01' 'the step states can be read from the module' `
    ($states.Count -ge 4) "states: $($states -join ', ')"

$undocumentedStates = @($states | Where-Object { $architecture -notmatch ('(?m)^' + [regex]::Escape($_) + '\s') })
Confirm-That 'D02' 'every step state is documented in architecture.md' `
    ($undocumentedStates.Count -eq 0) `
    "not in the state table: $($undocumentedStates -join ', ')"

# Every command a user can run has to be findable in the documentation. The
# README command table is the index; usage.md is where it is explained.
$commands = @((Get-Module Workstation).ExportedFunctions.Keys)
Confirm-That 'D03' 'the exported commands can be read from the module' `
    ($commands.Count -ge 4) "commands: $($commands -join ', ')"

$notInReadme = @($commands | Where-Object { $readme -notmatch [regex]::Escape($_) })
Confirm-That 'D04' 'every exported command appears in the README' `
    ($notInReadme.Count -eq 0) "missing from the README: $($notInReadme -join ', ')"

$notInDocs = @($commands | Where-Object { $usage -notmatch [regex]::Escape($_) -and $architecture -notmatch [regex]::Escape($_) })
Confirm-That 'D05' 'and is explained in usage.md or architecture.md' `
    ($notInDocs.Count -eq 0) "explained nowhere: $($notInDocs -join ', ')"

# ===========================================================================
Set-Group 'Group D2 — the ADRs'

$adrFiles = @(Get-ChildItem -LiteralPath $AdrRoot -Filter '*.md' | Sort-Object Name)
Confirm-That 'D06' 'the ADR directory has ADRs in it' ($adrFiles.Count -ge 1) "count: $($adrFiles.Count)"

# ADR 0001 states what the port costs, in ADRs. It said four when there were
# four, and nothing counted again.
$adr0001 = Get-Content -LiteralPath (Join-Path $AdrRoot '0001-record-architecture-decisions.md') -Raw
$spelled = @{ one = 1; two = 2; three = 3; four = 4; five = 5; six = 6; seven = 7; eight = 8; nine = 9; ten = 10 }
$claimed = $null
if ($adr0001 -match '(?i)a review of (\w+) ADRs') {
    $word = $Matches[1].ToLowerInvariant()
    $claimed = if ($spelled.ContainsKey($word)) { $spelled[$word] } elseif ($word -match '^\d+$') { [int] $word } else { $null }
}
Confirm-That 'D07' 'ADR 0001 states how many ADRs the port reviews' ($null -ne $claimed) "parsed: $claimed"
Confirm-That 'D08' 'and that number is how many there are' `
    ($claimed -eq $adrFiles.Count) "claims $claimed, there are $($adrFiles.Count)"

# Every ADR carries the sections the format is made of.
$missingSections = [System.Collections.Generic.List[string]]::new()
foreach ($adr in $adrFiles) {
    $text = Get-Content -LiteralPath $adr.FullName -Raw
    foreach ($section in @('## Status', '## Context', '## Decision', '## Consequences')) {
        if ($text -notmatch [regex]::Escape($section)) { $missingSections.Add("$($adr.Name): $section") }
    }
}
Confirm-That 'D09' 'every ADR has Status, Context, Decision and Consequences' `
    ($missingSections.Count -eq 0) ($missingSections -join ' | ')

# A decision later narrowed by another has to say so where it is read. ADR 0006
# narrowed ADR 0002's promise that uninstalling restores nothing because
# nothing was replaced; that is no longer true, and a reader landing on 0002
# has no way to know.
$adr0002 = Get-Content -LiteralPath (Join-Path $AdrRoot '0002-the-workstation-never-owns-what-it-did-not-create.md') -Raw
$status0002 = if ($adr0002 -match '(?ms)## Status\s*(.+?)\s*## Context') { $Matches[1] } else { '' }
Confirm-That 'D10' 'an ADR narrowed by a later one says so in its own Status' `
    ($status0002 -match '0006') "ADR 0002 status: $($status0002 -replace "`r?`n", ' ')"

# Every ADR a document links to has to exist.
$brokenLinks = [System.Collections.Generic.List[string]]::new()
foreach ($doc in @(
    @{ Name = 'README.md';            Text = $readme;       Base = $RepositoryRoot }
    @{ Name = 'docs/architecture.md'; Text = $architecture; Base = $DocsRoot }
    @{ Name = 'docs/usage.md';        Text = $usage;        Base = $DocsRoot }
    @{ Name = 'docs/testing.md';      Text = (Get-Doc 'docs/testing.md'); Base = $DocsRoot }
)) {
    foreach ($match in [regex]::Matches($doc.Text, '\]\(([^)]*adr/[^)]+\.md)\)')) {
        $target = Join-Path $doc.Base ($match.Groups[1].Value -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $target)) { $brokenLinks.Add("$($doc.Name) -> $($match.Groups[1].Value)") }
    }
}
Confirm-That 'D11' 'every ADR link in the documentation resolves to a file' `
    ($brokenLinks.Count -eq 0) ($brokenLinks -join ' | ')

# ===========================================================================
Set-Group 'Group D2b - the version'

# Two files carry it and both have to be edited together. This is the same
# shape as the manifest-versus-Export-ModuleMember problem the CI workflow
# guards, and worth guarding for the same reason: nothing else keeps them in
# step, and the declared copy is what every command prints in its banner. A
# drift means the banner and the module disagree about what is installed.
$declaredVersion = (Import-PowerShellDataFile -Path (Join-Path $ModulePath 'DeclaredState.psd1')).Version
$manifestVersion = (Import-PowerShellDataFile -Path (Join-Path $ModulePath 'Workstation.psd1')).ModuleVersion

Confirm-That 'D15' 'the declared state and the manifest state a version' `
    (-not [string]::IsNullOrWhiteSpace($declaredVersion) -and -not [string]::IsNullOrWhiteSpace($manifestVersion)) `
    "declared: '$declaredVersion', manifest: '$manifestVersion'"
Confirm-That 'D16' 'and it is the same version in both' `
    ([string] $declaredVersion -eq [string] $manifestVersion) `
    "declared: $declaredVersion, manifest: $manifestVersion"

# ===========================================================================
Set-Group 'Group D3 — the numbers the README reports'

# The per-suite counts and the total are written by hand and have to agree.
$rows = [regex]::Matches($readme, '(?m)^\|\s*`Invoke-\w+`[^|]*\|\s*(\d+)\s*\|')
$sum = 0
foreach ($row in $rows) { $sum += [int] $row.Groups[1].Value }
Confirm-That 'D12' 'the README lists per-suite assertion counts' ($rows.Count -ge 4) "rows: $($rows.Count)"

$claimedTotal = $null
if ($readme -match '\*\*(\d+) assertions') { $claimedTotal = [int] $Matches[1] }
Confirm-That 'D13' 'the README states a total' ($null -ne $claimedTotal) "total: $claimedTotal"
Confirm-That 'D14' 'and the total is the sum of the suites it lists' `
    ($claimedTotal -eq $sum) "claims $claimedTotal, rows sum to $sum"

# ===========================================================================
Write-Host ''
Write-Host '  SUMMARY' -ForegroundColor White
$passed = @($script:Results | Where-Object { $_.Passed }).Count
$failed = @($script:Results | Where-Object { -not $_.Passed }).Count
Write-Host "  total:  $($script:Results.Count)"
Write-Host "  passed: $passed" -ForegroundColor Green
Write-Host "  failed: $failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
if ($failed -gt 0) {
    Write-Host ''
    foreach ($r in $script:Results | Where-Object { -not $_.Passed }) {
        Write-Host "    $($r.Id)  $($r.Description)" -ForegroundColor Red
        if ($r.Detail) { Write-Host "          $($r.Detail)" -ForegroundColor DarkRed }
    }
}
Write-Host ''
exit $failed
