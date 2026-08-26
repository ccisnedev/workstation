#Requires -Version 7.0
<#
    Exhaustive QA suite for the workstation module, on Windows.
    Mutates the real machine and restores it at the end.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# This script lives at <repository>/code/powershell/Workstation/Tests/, so the
# repository root is four levels up. Nothing is hard-coded, which is what lets
# the suite run on any machine that cloned the repository anywhere.
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code\powershell\Workstation'

if (-not $IsWindows) { Write-Error 'This suite is for Windows. Use Invoke-LinuxQA.ps1 elsewhere.'; exit 1 }
$LinkTarget     = Join-Path $env:LOCALAPPDATA 'workstation'
$NeovimData     = Join-Path $env:LOCALAPPDATA 'workstation-data'
$ResolvedPreferences = Join-Path $env:LOCALAPPDATA 'workstation-generated\preferences.lua'
$UserNeovim     = Join-Path $env:LOCALAPPDATA 'nvim'
$UserWezTerm    = Join-Path $HOME '.config\wezterm'
$ProfilePath    = $PROFILE.CurrentUserAllHosts
$PlansDirectory = Join-Path $RepositoryRoot '.workstation\plans'
$ToolFreeState  = Join-Path ([System.IO.Path]::GetTempPath()) 'qa-windows-tool-free-state.psd1'
$OpenMarker     = '# >>> workstation >>>'
$CloseMarker    = '# <<< workstation <<<'

$script:Results = [System.Collections.Generic.List[object]]::new()
$script:Group   = ''

function Set-Group { param([string] $Name) ; $script:Group = $Name
    Write-Host ''
    Write-Host "  $Name" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $Name.Length)) -ForegroundColor DarkCyan
}

function Confirm-That {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $Description,
        [Parameter(Mandatory)][AllowNull()] $Condition,
        [string] $Detail = ''
    )
    $passed = [bool] $Condition
    $script:Results.Add([PSCustomObject]@{
        Id = $Id; Group = $script:Group; Description = $Description; Passed = $passed; Detail = $Detail
    })
    $mark  = if ($passed) { 'PASS' } else { 'FAIL' }
    $color = if ($passed) { 'Green' } else { 'Red' }
    Write-Host ('    [{0}] {1}  {2}' -f $mark, $Id, $Description) -ForegroundColor $color
    if (-not $passed -and $Detail) { Write-Host "           $Detail" -ForegroundColor DarkRed }
}

# --- helpers ---------------------------------------------------------------

function Get-ProfileText {
    if (Test-Path -LiteralPath $ProfilePath) {
        $t = Get-Content -LiteralPath $ProfilePath -Raw
        if ($null -eq $t) { return '' }
        return $t
    }
    return ''
}

function Test-ProfileBlockPresent {
    $t = Get-ProfileText
    return ($t.Contains($OpenMarker) -and $t.Contains($CloseMarker))
}

function Remove-ProfileBlock {
    if (-not (Test-Path -LiteralPath $ProfilePath)) { return }
    [string[]] $lines = (Get-ProfileText) -split "`r?`n"
    $open = -1; $close = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ceq $OpenMarker)  { $open = $i }
        if ($lines[$i].Trim() -ceq $CloseMarker) { $close = $i }
    }
    if ($open -lt 0 -or $close -le $open) { return }
    [string[]] $before = @() ; if ($open -gt 0) { $before = $lines[0..($open - 1)] }
    [string[]] $after  = @() ; if ($close -lt $lines.Count - 1) { $after = $lines[($close + 1)..($lines.Count - 1)] }
    $rest = ($before + $after) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($rest)) { Remove-Item -LiteralPath $ProfilePath -Force }
    else { Set-Content -LiteralPath $ProfilePath -Value $rest.Trim() -Encoding utf8 }
}

function Remove-WorkstationLink {
    $item = Get-Item -LiteralPath $LinkTarget -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if ($item.LinkType -in @('Junction', 'SymbolicLink')) { [System.IO.Directory]::Delete($LinkTarget, $false) }
    else { Remove-Item -LiteralPath $LinkTarget -Recurse -Force }
}

function Invoke-FullUninstall {
    Remove-WorkstationLink
    Remove-ProfileBlock
}

function Get-LinkInfo {
    $item = Get-Item -LiteralPath $LinkTarget -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return [PSCustomObject]@{ LinkType = $item.LinkType; Target = (@($item.Target)[0]) }
}

function Import-Fresh {
    Remove-Module Workstation -Force -ErrorAction SilentlyContinue
    Import-Module $ModulePath -Force -ErrorAction Stop
}

# ---------------------------------------------------------------------------
#  A declared state with no tools in it.
#
#  Installing a declared tool is an ordinary step now (ADR-0006), so a bare
#  `Install-Workstation -Apply` performs one. This suite mutates the real
#  machine and promises to restore it, and installing a terminal is not
#  something it could restore. It therefore runs against the real declared
#  state with the Tools block emptied, which is exactly what
#  WORKSTATION_DECLARED_STATE exists for.
#
#  The transform is verified rather than trusted: if the Tools block were not
#  emptied the suite aborts, because the failure mode is installing software
#  on someone's machine rather than a red assertion.
# ---------------------------------------------------------------------------
function Set-ToolFreeDeclaredState {
    $realText = Get-Content -LiteralPath (Join-Path $ModulePath 'DeclaredState.psd1') -Raw
    $stripped = [regex]::Replace($realText, '(?ms)^[ \t]*Tools[ \t]*=[ \t]*@\(.*?^[ \t]*\)[ \t]*\r?$', '    Tools = @()', 1)
    Set-Content -LiteralPath $ToolFreeState -Value $stripped -Encoding utf8
    $env:WORKSTATION_DECLARED_STATE = $ToolFreeState

    $toolSteps = @((Test-Workstation -PassThru 6>$null) | Where-Object { $_.Kind -eq 'tool' })
    if ($toolSteps.Count -ne 0) {
        $env:WORKSTATION_DECLARED_STATE = $null
        throw "The Tools block was not emptied; refusing to run a suite that would install software. Steps: $($toolSteps.Count)"
    }
}
function Clear-ToolFreeDeclaredState {
    $env:WORKSTATION_DECLARED_STATE = $null
    Remove-Item -LiteralPath $ToolFreeState -Force -ErrorAction Ignore
}

# ===========================================================================
Write-Host ''
Write-Host '  WORKSTATION — WINDOWS QA SUITE' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray
Write-Host "  started:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor DarkGray

Import-Fresh
Set-ToolFreeDeclaredState

# ===========================================================================
Set-Group 'Group 1 — command contract'

$err = $null
Install-Workstation -ErrorAction SilentlyContinue -ErrorVariable err | Out-Null
Confirm-That 'T01' 'bare Install-Workstation is an error' ($err.Count -gt 0) "errors: $($err.Count)"

$err = $null
Install-Workstation -Plan -Apply -ErrorAction SilentlyContinue -ErrorVariable err | Out-Null
Confirm-That 'T02' '-Plan and -Apply together is an error' ($err.Count -gt 0)

$testParams = (Get-Command Test-Workstation).Parameters.Keys
Confirm-That 'T03' 'Test-Workstation exposes neither -Plan nor -Apply' `
    (('Plan' -notin $testParams) -and ('Apply' -notin $testParams))

$rejected = $false
try { Start-Workstation -Agent 'gemini' -ErrorAction Stop } catch { $rejected = $true }
Confirm-That 'T04' 'an undeclared agent is rejected by the parameter binder' $rejected

$err = $null
Start-Workstation -Agent claude -Directory 'Z:\does\not\exist' -ErrorAction SilentlyContinue -ErrorVariable err | Out-Null
Confirm-That 'T05' 'a non-existent -Directory is rejected' ($err.Count -gt 0)
Confirm-That 'T05b' 'exactly one error is raised, with no path-resolution noise underneath' `
    ($err.Count -eq 1) "errors: $($err.Count) -> $(($err | ForEach-Object { $_.FullyQualifiedErrorId }) -join '; ')"

$declaredAgents = (Get-Command Start-Workstation).Parameters['Agent'].Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
    Select-Object -ExpandProperty ValidValues
Confirm-That 'T06' 'all four agents are selectable' `
    ((@('claude','codex','antigravity','opencode') | Where-Object { $_ -in $declaredAgents }).Count -eq 4) `
    "declared: $($declaredAgents -join ', ')"

# ===========================================================================
Set-Group 'Group 2 — uninstall to a clean baseline'

Invoke-FullUninstall
Confirm-That 'T07' 'the link is gone after uninstall' (-not (Test-Path -LiteralPath $LinkTarget))
Confirm-That 'T08' 'the profile block is gone after uninstall' (-not (Test-ProfileBlockPresent))

Import-Fresh
$drift = Test-Workstation -PassThru 6>$null
$pendingLink = @($drift | Where-Object { $_.Kind -eq 'link' -and $_.State -eq 'Pending' })
Confirm-That 'T09' 'check reports the missing link as pending' ($pendingLink.Count -eq 1)
$pendingProfile = @($drift | Where-Object { $_.Kind -eq 'profile' -and $_.State -eq 'Pending' })
Confirm-That 'T10' 'check reports the missing profile block as pending' ($pendingProfile.Count -eq 1)

# ===========================================================================
Set-Group 'Group 3 — plan writes nothing'

if (Test-Path $PlansDirectory) { Remove-Item -Recurse -Force $PlansDirectory }
Install-Workstation -Plan 6>$null | Out-Null

Confirm-That 'T11' 'plan did not create the link' (-not (Test-Path -LiteralPath $LinkTarget))
Confirm-That 'T12' 'plan did not write the profile block' (-not (Test-ProfileBlockPresent))

$planFiles = @(Get-ChildItem -Path $PlansDirectory -Filter '*.txt' -ErrorAction SilentlyContinue)
Confirm-That 'T13' 'plan wrote exactly one plan file' ($planFiles.Count -eq 1) "found: $($planFiles.Count)"

if ($planFiles.Count -ge 1) {
    $planText = Get-Content -LiteralPath $planFiles[0].FullName -Raw
    Confirm-That 'T14' 'the plan file names the pending link' ($planText -match 'Neovim configuration')
    Confirm-That 'T15' 'the plan file records the pending count' ($planText -match 'pending steps: 2')
}

# ===========================================================================
Set-Group 'Group 4 — apply, then idempotency'

Install-Workstation -Apply -AutoApprove 6>$null | Out-Null

$link = Get-LinkInfo
Confirm-That 'T16' 'the link now exists' ($null -ne $link)
Confirm-That 'T17' 'the link is a junction' ($null -ne $link -and $link.LinkType -eq 'Junction') "type: $($link.LinkType)"
$expected = Join-Path $RepositoryRoot 'code\assets\neovim'
Confirm-That 'T18' 'the junction points at the repository assets' `
    ($null -ne $link -and $link.Target.TrimEnd('\') -ieq $expected) "target: $($link.Target)"
Confirm-That 'T19' 'the profile block was written' (Test-ProfileBlockPresent)

$initThroughLink = Join-Path $LinkTarget 'init.lua'
Confirm-That 'T20' 'the config is readable through the link' (Test-Path -LiteralPath $initThroughLink)

$drift = Test-Workstation -PassThru 6>$null
Confirm-That 'T21' 'check reports no pending or blocked steps' `
    (@($drift | Where-Object { $_.State -in @('Pending','Blocked') }).Count -eq 0)

$before = (Get-LinkInfo).Target
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$after = (Get-LinkInfo).Target
Confirm-That 'T22' 'a second apply changes nothing' ($before -eq $after)

Install-Workstation -Plan 6>$null | Out-Null
$planFiles = @(Get-ChildItem -Path $PlansDirectory -Filter '*.txt' | Sort-Object LastWriteTime)
$planText = Get-Content -LiteralPath $planFiles[-1].FullName -Raw
Confirm-That 'T23' 'a plan after apply reports zero pending steps' ($planText -match 'pending steps: 0')

# ===========================================================================
Set-Group 'Group 5 — the round trip through the link'

$sentinel = "-- qa round trip $(Get-Random)"
Add-Content -LiteralPath $initThroughLink -Value $sentinel
Push-Location $RepositoryRoot
$status = git status --porcelain -- code/assets/neovim/init.lua
Pop-Location
Confirm-That 'T24' 'editing through the link shows up in git' ($status -match 'init.lua') "status: '$status'"

Push-Location $RepositoryRoot
git checkout -- code/assets/neovim/init.lua
Pop-Location
$content = Get-Content -LiteralPath $initThroughLink -Raw
Confirm-That 'T25' 'git checkout reverts the file seen through the link' (-not $content.Contains($sentinel))

# ===========================================================================
Set-Group 'Group 6 — the workstation never owns what it did not create'

# A pre-existing Neovim configuration belonging to the user
if (Test-Path -LiteralPath $UserNeovim) { Remove-Item -Recurse -Force $UserNeovim }
New-Item -ItemType Directory -Path $UserNeovim -Force | Out-Null
$userNeovimSentinel = 'vim.opt.number = false -- USER OWNED, MUST SURVIVE'
Set-Content -LiteralPath (Join-Path $UserNeovim 'init.lua') -Value $userNeovimSentinel

# A pre-existing WezTerm configuration belonging to the user
if (Test-Path -LiteralPath $UserWezTerm) { Remove-Item -Recurse -Force $UserWezTerm }
New-Item -ItemType Directory -Path $UserWezTerm -Force | Out-Null
$userWezSentinel = '-- USER OWNED WEZTERM, MUST SURVIVE'
Set-Content -LiteralPath (Join-Path $UserWezTerm 'wezterm.lua') -Value $userWezSentinel

# User content in the profile, outside the markers
$userProfileLine = '$env:QA_USER_PROFILE_LINE = "must survive"'
$profileText = Get-ProfileText
Set-Content -LiteralPath $ProfilePath -Value ($userProfileLine + [Environment]::NewLine + $profileText) -Encoding utf8

Invoke-FullUninstall
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null

$userNeovimItem = Get-Item -LiteralPath $UserNeovim -Force -ErrorAction SilentlyContinue
Confirm-That 'T26' 'the user Neovim directory is still a real directory, not a link' `
    ($null -ne $userNeovimItem -and $null -eq $userNeovimItem.LinkType) "type: $($userNeovimItem.LinkType)"
Confirm-That 'T27' 'the user Neovim config is byte-for-byte untouched' `
    ((Get-Content -LiteralPath (Join-Path $UserNeovim 'init.lua') -Raw).Trim() -ceq $userNeovimSentinel)

$userWezItem = Get-Item -LiteralPath $UserWezTerm -Force -ErrorAction SilentlyContinue
Confirm-That 'T28' 'the user WezTerm directory was never linked' `
    ($null -ne $userWezItem -and $null -eq $userWezItem.LinkType)
Confirm-That 'T29' 'the user WezTerm config is untouched' `
    ((Get-Content -LiteralPath (Join-Path $UserWezTerm 'wezterm.lua') -Raw).Trim() -ceq $userWezSentinel)

Confirm-That 'T30' 'user content outside the profile markers survives' `
    ((Get-ProfileText).Contains($userProfileLine))
Confirm-That 'T31' 'the profile block is present alongside the user content' (Test-ProfileBlockPresent)

$blockCount = ([regex]::Matches((Get-ProfileText), [regex]::Escape($OpenMarker))).Count
Confirm-That 'T32' 'the marked block appears exactly once' ($blockCount -eq 1) "count: $blockCount"

# ===========================================================================
Set-Group 'Group 7 — drift detection and repair'

# 7a. link deleted
Remove-WorkstationLink
$drift = Test-Workstation -PassThru 6>$null
Confirm-That 'T33' 'a deleted link is detected' `
    (@($drift | Where-Object { $_.Kind -eq 'link' -and $_.State -eq 'Pending' }).Count -eq 1)
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
Confirm-That 'T34' 'a deleted link is repaired' ($null -ne (Get-LinkInfo))

# 7b. link pointing somewhere else
$decoy = Join-Path $env:TEMP 'qa-decoy-target'
New-Item -ItemType Directory -Path $decoy -Force | Out-Null
Remove-WorkstationLink
New-Item -ItemType Junction -Path $LinkTarget -Target $decoy | Out-Null
$drift = Test-Workstation -PassThru 6>$null
$linkStep = @($drift | Where-Object { $_.Kind -eq 'link' })[0]
Confirm-That 'T35' 'a link pointing elsewhere is detected' ($linkStep.State -eq 'Pending')
Confirm-That 'T36' 'the report names the wrong target it found' ($linkStep.Detail -match 'qa-decoy-target')
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
Confirm-That 'T37' 'the stale link is repointed at the repository' `
    ((Get-LinkInfo).Target.TrimEnd('\') -ieq $expected)
Confirm-That 'T38' 'repointing did not delete the decoy contents' (Test-Path -LiteralPath $decoy)
Remove-Item -Recurse -Force $decoy -ErrorAction SilentlyContinue

# 7c. a real directory where the link belongs
Remove-WorkstationLink
New-Item -ItemType Directory -Path $LinkTarget -Force | Out-Null
Set-Content -LiteralPath (Join-Path $LinkTarget 'stale.lua') -Value 'stale install'
$drift = Test-Workstation -PassThru 6>$null
$linkStep = @($drift | Where-Object { $_.Kind -eq 'link' })[0]
Confirm-That 'T39' 'a real directory at the link path is detected' ($linkStep.State -eq 'Pending')
Confirm-That 'T40' 'the plan says it will back it up rather than delete it' ($linkStep.Detail -match 'backup-')
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$backups = @(Get-ChildItem -Path $env:LOCALAPPDATA -Filter 'workstation.backup-*' -Force -ErrorAction SilentlyContinue)
Confirm-That 'T41' 'the previous directory was backed up, not destroyed' ($backups.Count -ge 1)
Confirm-That 'T42' 'the backup still holds its file' `
    ($backups.Count -ge 1 -and (Test-Path (Join-Path $backups[0].FullName 'stale.lua')))
Confirm-That 'T43' 'the link is in place after the backup' ((Get-LinkInfo).LinkType -eq 'Junction')
$backups | ForEach-Object { Remove-Item -Recurse -Force $_.FullName }

# 7d. corrupted profile block
$corrupted = (Get-ProfileText) -replace 'Import-Module.*', 'Import-Module ThisIsWrong'
Set-Content -LiteralPath $ProfilePath -Value $corrupted -Encoding utf8
$drift = Test-Workstation -PassThru 6>$null
Confirm-That 'T44' 'a corrupted profile block is detected' `
    (@($drift | Where-Object { $_.Kind -eq 'profile' -and $_.State -eq 'Pending' }).Count -eq 1)
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
Confirm-That 'T45' 'the profile block is restored' ((Get-ProfileText) -match [regex]::Escape($ModulePath))
Confirm-That 'T46' 'the user line still survives the repair' ((Get-ProfileText).Contains($userProfileLine))

# ===========================================================================
Set-Group 'Group 8 — apply can be declined'

Invoke-FullUninstall
$declineOutput = 'n' | pwsh -NoLogo -NoProfile -Command "Import-Module '$ModulePath'; Install-Workstation -Apply" 2>&1 | Out-String
Confirm-That 'T47' 'answering no cancels the apply' ($declineOutput -match 'Cancelled')
Confirm-That 'T48' 'nothing was written after declining' (-not (Test-Path -LiteralPath $LinkTarget))

# ===========================================================================
Set-Group 'Group 9 — uninstall and reinstall'

Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
Confirm-That 'T49' 'reinstall after a decline succeeds' ($null -ne (Get-LinkInfo))

Invoke-FullUninstall
Confirm-That 'T50' 'full uninstall removes the link' (-not (Test-Path -LiteralPath $LinkTarget))
Confirm-That 'T51' 'full uninstall removes the block but keeps user content' `
    ((-not (Test-ProfileBlockPresent)) -and (Get-ProfileText).Contains($userProfileLine))
Confirm-That 'T52' 'uninstall left the user Neovim config alone' `
    ((Get-Content -LiteralPath (Join-Path $UserNeovim 'init.lua') -Raw).Trim() -ceq $userNeovimSentinel)

Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$drift = Test-Workstation -PassThru 6>$null
Confirm-That 'T53' 'reinstall returns the machine to fully in sync' `
    (@($drift | Where-Object { $_.State -in @('Pending','Blocked') }).Count -eq 0)

# a third cycle, to be sure the sequence is repeatable
Invoke-FullUninstall
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$drift = Test-Workstation -PassThru 6>$null
Confirm-That 'T54' 'a third install/uninstall cycle is still clean' `
    (@($drift | Where-Object { $_.State -in @('Pending','Blocked') }).Count -eq 0)

# ===========================================================================
Set-Group 'Group 10 - Uninstall-Workstation'

# Group 9 above proves that removing the link and the profile block by hand
# leaves the machine sane. It does not exercise the command anyone would
# actually type, which until now did not exist: uninstalling was a two-line
# edit you had to know how to do. These assertions are about the command.

Install-Workstation -Apply -AutoApprove 6>$null | Out-Null

$err = $null
Uninstall-Workstation -ErrorAction SilentlyContinue -ErrorVariable err | Out-Null
Confirm-That 'U01' 'bare Uninstall-Workstation is an error' ($err.Count -gt 0)

$err = $null
Uninstall-Workstation -Plan -Apply -ErrorAction SilentlyContinue -ErrorVariable err | Out-Null
Confirm-That 'U02' '-Plan and -Apply together is an error' ($err.Count -gt 0)

$planText = Uninstall-Workstation -Plan 6>&1 | Out-String
Confirm-That 'U03' 'a plan removes nothing' `
    (($null -ne (Get-LinkInfo)) -and (Test-ProfileBlockPresent))
Confirm-That 'U04' 'and names the link and the profile block it would remove' `
    ($planText -match 'Neovim configuration' -and $planText -match 'PowerShell profile block')
Confirm-That 'U05' 'and says the repository itself is never touched' `
    ($planText -match 'repository itself is never touched')

# Plugin data exists by now, because the launch suite and the preference suite
# have both started Neovim. It is Neovim's, not ours, and must be reported
# rather than removed.
$hadPluginData = Test-Path -LiteralPath $NeovimData
Confirm-That 'U06' 'the plan reports plugin data as kept, when there is any' `
    ((-not $hadPluginData) -or ($planText -match 'Left alone' -and $planText -match 'lazy-lock'))

$applyText = Uninstall-Workstation -Apply -AutoApprove 6>&1 | Out-String
Confirm-That 'U07' 'apply removes the link' (-not (Test-Path -LiteralPath $LinkTarget))
Confirm-That 'U08' 'apply removes the profile block and keeps user content' `
    ((-not (Test-ProfileBlockPresent)) -and (Get-ProfileText).Contains($userProfileLine))
Confirm-That 'U09' 'apply removes the generated preferences' `
    (-not (Test-Path -LiteralPath $ResolvedPreferences))

# The link points into the repository. Removing it recursively would have
# taken the assets with it, which is the single most expensive mistake this
# command could make.
Confirm-That 'U10' 'the repository assets survived the link removal' `
    ((Test-Path -LiteralPath (Join-Path $RepositoryRoot 'code/assets/neovim/init.lua')) -and
     (Test-Path -LiteralPath (Join-Path $RepositoryRoot 'code/assets/wezterm/wezterm.lua')))
Confirm-That 'U11' 'the user Neovim configuration is untouched' `
    ((Get-Content -LiteralPath (Join-Path $UserNeovim 'init.lua') -Raw).Trim() -ceq $userNeovimSentinel)
Confirm-That 'U12' 'plugin data is left where it is' `
    ((-not $hadPluginData) -or (Test-Path -LiteralPath $NeovimData))

$secondText = Uninstall-Workstation -Apply -AutoApprove 6>&1 | Out-String
Confirm-That 'U13' 'a second uninstall finds nothing to remove' `
    ($secondText -match 'Nothing to remove') "output: $secondText"

Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$drift = Test-Workstation -PassThru 6>$null
Confirm-That 'U14' 'installing after an uninstall puts everything back' `
    (@($drift | Where-Object { $_.State -in @('Pending','Blocked') }).Count -eq 0)

# A real directory where our link belongs is not ours, whoever put it there.
Uninstall-Workstation -Apply -AutoApprove 6>$null | Out-Null
New-Item -ItemType Directory -Path $LinkTarget -Force | Out-Null
Set-Content -LiteralPath (Join-Path $LinkTarget 'someone-elses.lua') -Value 'not ours' -Encoding utf8
$decoyText = Uninstall-Workstation -Plan 6>&1 | Out-String
Confirm-That 'U15' 'a real directory at our link path is refused, not deleted' `
    ($decoyText -match 'not our link' -and (Test-Path -LiteralPath (Join-Path $LinkTarget 'someone-elses.lua'))) `
    "output: $decoyText"
Uninstall-Workstation -Apply -AutoApprove 6>$null | Out-Null
Confirm-That 'U16' 'and an apply does not delete it either' `
    (Test-Path -LiteralPath (Join-Path $LinkTarget 'someone-elses.lua'))

Remove-Item -LiteralPath $LinkTarget -Recurse -Force -ErrorAction SilentlyContinue
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
Confirm-That 'U17' 'the machine is deployed again after the decoy' ($null -ne (Get-LinkInfo))

# ===========================================================================
Set-Group 'Cleanup of QA fixtures'

Remove-Item -Recurse -Force $UserNeovim  -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $UserWezTerm -ErrorAction SilentlyContinue
$cleanProfile = ((Get-ProfileText) -replace [regex]::Escape($userProfileLine), '').Trim()
Set-Content -LiteralPath $ProfilePath -Value $cleanProfile -Encoding utf8
Confirm-That 'T55' 'QA fixtures removed' `
    ((-not (Test-Path $UserNeovim)) -and (-not (Test-Path $UserWezTerm)) -and (-not (Get-ProfileText).Contains($userProfileLine)))
Confirm-That 'T56' 'the workstation is still installed after cleanup' (Test-ProfileBlockPresent -and $null -ne (Get-LinkInfo))

Clear-ToolFreeDeclaredState
Confirm-That 'T57' 'the suite installed no tools and left the real declared state in place' `
    ((-not (Test-Path -LiteralPath $ToolFreeState)) -and
     [string]::IsNullOrEmpty($env:WORKSTATION_DECLARED_STATE) -and
     @((Test-Workstation -PassThru 6>$null) | Where-Object { $_.Kind -eq 'tool' }).Count -gt 0)

# ===========================================================================
Write-Host ''
Write-Host '  SUMMARY' -ForegroundColor White
Write-Host '  -------' -ForegroundColor DarkCyan
$passed = @($script:Results | Where-Object { $_.Passed }).Count
$failed = @($script:Results | Where-Object { -not $_.Passed }).Count
Write-Host "  total:  $($script:Results.Count)"
Write-Host "  passed: $passed" -ForegroundColor Green
Write-Host "  failed: $failed" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
if ($failed -gt 0) {
    Write-Host ''
    foreach ($r in $script:Results | Where-Object { -not $_.Passed }) {
        Write-Host "    $($r.Id)  $($r.Group)  —  $($r.Description)" -ForegroundColor Red
        if ($r.Detail) { Write-Host "          $($r.Detail)" -ForegroundColor DarkRed }
    }
}
Write-Host ''
exit $failed
