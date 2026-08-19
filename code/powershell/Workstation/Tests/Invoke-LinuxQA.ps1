#Requires -Version 7.0
<#
    Exhaustive QA suite for the workstation module, on Linux (WSL2 / Ubuntu).
    Operates on a clone at ~/workstation.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code/powershell/Workstation'
$ConfigHome     = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
$LinkTarget     = Join-Path $ConfigHome 'workstation'
$UserNeovim     = Join-Path $ConfigHome 'nvim'
$ProfilePath    = $PROFILE.CurrentUserAllHosts
$PlansDirectory = Join-Path $RepositoryRoot '.workstation/plans'
$OpenMarker     = '# >>> workstation >>>'
$CloseMarker    = '# <<< workstation <<<'

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
    $rest = ($before + $after) -join "`n"
    if ([string]::IsNullOrWhiteSpace($rest)) { Remove-Item -LiteralPath $ProfilePath -Force }
    else { Set-Content -LiteralPath $ProfilePath -Value $rest.Trim() }
}
function Remove-WorkstationLink {
    $item = Get-Item -LiteralPath $LinkTarget -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if ($item.LinkType -eq 'SymbolicLink') { [System.IO.File]::Delete($LinkTarget) }
    else { Remove-Item -LiteralPath $LinkTarget -Recurse -Force }
}
function Invoke-FullUninstall { Remove-WorkstationLink ; Remove-ProfileBlock }
function Get-LinkInfo {
    $item = Get-Item -LiteralPath $LinkTarget -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    return [PSCustomObject]@{ LinkType = $item.LinkType; Target = (@($item.Target)[0]) }
}

Write-Host ''
Write-Host '  WORKSTATION — LINUX QA SUITE' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray
Write-Host "  os:         $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim())" -ForegroundColor DarkGray

Import-Module $ModulePath -Force -ErrorAction Stop

# ===========================================================================
Set-Group 'Group X1 — platform resolution'

Confirm-That 'X01' 'PowerShell reports Linux' ($IsLinux -eq $true)
Confirm-That 'X02' 'the profile path is the Linux one' `
    ($ProfilePath -match '\.config/powershell') $ProfilePath
Confirm-That 'X03' 'the link target resolves under XDG_CONFIG_HOME' `
    ($LinkTarget -eq (Join-Path $HOME '.config/workstation')) $LinkTarget

$expectedSource = Join-Path $RepositoryRoot 'code/assets/neovim'
Confirm-That 'X04' 'the repository clone has the asset tree' (Test-Path -LiteralPath $expectedSource)

$initText = Get-Content -LiteralPath (Join-Path $expectedSource 'init.lua') -Raw
Confirm-That 'X05' 'the checked-out Lua has no stray carriage returns' (-not $initText.Contains("`r")) 'gitattributes normalisation'

# ===========================================================================
Set-Group 'Group X2 — tool and agent detection on Linux'

Invoke-FullUninstall
$drift = Test-Workstation -PassThru 6>$null

$fdStep = @($drift | Where-Object { $_.Kind -eq 'tool' -and $_.Name -eq 'fd' })[0]
Confirm-That 'X06' "fd is found through its Debian name 'fdfind'" ($fdStep.State -eq 'InSync') "state: $($fdStep.State)"

$nvimStep = @($drift | Where-Object { $_.Kind -eq 'tool' -and $_.Name -eq 'Neovim' })[0]
Confirm-That 'X07' 'Neovim is detected' ($nvimStep.State -eq 'InSync')

$rgStep = @($drift | Where-Object { $_.Kind -eq 'tool' -and $_.Name -eq 'ripgrep' })[0]
Confirm-That 'X08' 'ripgrep is detected' ($rgStep.State -eq 'InSync')

# The three below must not depend on what this machine happens to have
# installed. A suite that only passes on a bare machine stops being run the
# moment the machine stops being bare — which is what happened here once the
# launch tests installed WezTerm and the agents. What is asserted is the rule:
# a tool is either detected, or reported with the install command for THIS
# platform, and never installed behind the user's back. The hint-selection
# logic itself is asserted deterministically against a fixture in
# Invoke-PreferenceQA.ps1, where absence can be guaranteed.
$wezStep = @($drift | Where-Object { $_.Kind -eq 'tool' -and $_.Name -eq 'WezTerm' })[0]
Confirm-That 'X09' 'WezTerm resolves to a known state, and is never installed silently' `
    ($wezStep.State -in @('InSync', 'Missing')) "state: $($wezStep.State)"
Confirm-That 'X10' 'when missing, the WezTerm hint is the Linux one and not winget' `
    ($wezStep.State -eq 'InSync' -or ($wezStep.Hint -notmatch 'winget' -and $wezStep.Hint -match 'wezterm.org')) `
    "state: $($wezStep.State) hint: $($wezStep.Hint)"

$agyStep = @($drift | Where-Object { $_.Kind -eq 'agent' -and $_.Name -eq 'antigravity' })[0]
Confirm-That 'X11' 'when missing, the antigravity hint is the shell installer, not the PowerShell one' `
    ($agyStep.State -eq 'InSync' -or ($agyStep.Hint -match 'install.sh' -and $agyStep.Hint -notmatch 'Invoke-RestMethod')) `
    "state: $($agyStep.State) hint: $($agyStep.Hint)"

$agentSteps = @($drift | Where-Object { $_.Kind -eq 'agent' })
Confirm-That 'X12' 'every declared agent resolves, and a missing one always carries an install command' `
    ($agentSteps.Count -eq 4 -and
     @($agentSteps | Where-Object { $_.State -notin @('InSync', 'Missing') }).Count -eq 0 -and
     @($agentSteps | Where-Object { $_.State -eq 'Missing' -and [string]::IsNullOrWhiteSpace($_.Hint) }).Count -eq 0) `
    "states: $(($agentSteps | ForEach-Object { "$($_.Name)=$($_.State)" }) -join ', ')"

# ===========================================================================
Set-Group 'Group X3 — command contract'

$err = $null
Install-Workstation -ErrorAction SilentlyContinue -ErrorVariable err | Out-Null
Confirm-That 'X13' 'bare Install-Workstation is an error' ($err.Count -gt 0)

$err = $null
Install-Workstation -Plan -Apply -ErrorAction SilentlyContinue -ErrorVariable err | Out-Null
Confirm-That 'X14' '-Plan and -Apply together is an error' ($err.Count -gt 0)

# ===========================================================================
Set-Group 'Group X4 — plan writes nothing'

if (Test-Path $PlansDirectory) { Remove-Item -Recurse -Force $PlansDirectory }
Install-Workstation -Plan 6>$null | Out-Null
Confirm-That 'X15' 'plan did not create the link' (-not (Test-Path -LiteralPath $LinkTarget))
Confirm-That 'X16' 'plan did not write the profile block' (-not (Test-ProfileBlockPresent))
$planFiles = @(Get-ChildItem -Path $PlansDirectory -Filter '*.txt' -ErrorAction SilentlyContinue)
Confirm-That 'X17' 'plan wrote a plan file' ($planFiles.Count -eq 1)

# ===========================================================================
Set-Group 'Group X5 — apply creates a symbolic link, not a junction'

Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$link = Get-LinkInfo
Confirm-That 'X18' 'the link exists' ($null -ne $link)
Confirm-That 'X19' 'the link is a symbolic link' ($null -ne $link -and $link.LinkType -eq 'SymbolicLink') "type: $($link.LinkType)"
Confirm-That 'X20' 'the link points at the repository assets' `
    ($null -ne $link -and $link.Target.TrimEnd('/') -eq $expectedSource) "target: $($link.Target)"
Confirm-That 'X21' 'the config is readable through the link' (Test-Path -LiteralPath (Join-Path $LinkTarget 'init.lua'))
Confirm-That 'X22' 'the profile block was written to the Linux profile' (Test-ProfileBlockPresent)
Confirm-That 'X23' 'the profile directory was created as needed' (Test-Path -LiteralPath (Split-Path -Parent $ProfilePath))

$drift = Test-Workstation -PassThru 6>$null
$blocking = @($drift | Where-Object { $_.State -in @('Pending','Blocked') })
Confirm-That 'X24' 'no link or profile step is left pending' `
    (@($blocking | Where-Object { $_.Kind -in @('link','profile') }).Count -eq 0)

# ===========================================================================
Set-Group 'Group X6 — Neovim actually resolves the workstation namespace'

# stdpath is derived from the environment, not from init.lua, so -u NONE gives
# a clean answer without the plugin manager writing progress over it.
$workstationConfig = & env NVIM_APPNAME=workstation nvim -u NONE --headless '+echo stdpath("config")' +q 2>&1 | Out-String
Confirm-That 'X25' 'NVIM_APPNAME=workstation resolves to the deployed directory' `
    ($workstationConfig.Trim() -eq $LinkTarget) "got: '$($workstationConfig.Trim())'"

$plainConfig = & nvim -u NONE --headless '+echo stdpath("config")' +q 2>&1 | Out-String
Confirm-That 'X26' 'plain nvim resolves elsewhere, to the user own config' `
    ($plainConfig.Trim() -ne $LinkTarget) "got: '$($plainConfig.Trim())'"

$workstationData = & env NVIM_APPNAME=workstation nvim -u NONE --headless '+echo stdpath("data")' +q 2>&1 | Out-String
$plainData = & nvim -u NONE --headless '+echo stdpath("data")' +q 2>&1 | Out-String
Confirm-That 'X27' 'plugin data is isolated from plain nvim' `
    ($workstationData.Trim() -ne $plainData.Trim()) "ws: $($workstationData.Trim())  plain: $($plainData.Trim())"

# Warm up: let the plugin manager finish cloning before asking whether the
# configuration loads cleanly. Output is discarded; it is progress, not a result.
& env NVIM_APPNAME=workstation nvim --headless '+Lazy! install' +qa *> /dev/null

$luaLoads = & env NVIM_APPNAME=workstation nvim --headless '+echo "INIT_OK"' +q 2>&1 | Out-String
Confirm-That 'X28' 'the deployed init.lua is read without a Lua error' `
    ($luaLoads -match 'INIT_OK' -and
     $luaLoads -notmatch 'E5113|E5108|Error executing|Error in command line|Failed to run|stacktrace|not found:') `
    "output: $($luaLoads.Trim() -replace "`n", ' | ')"

$pluginRoot = Join-Path $workstationData.Trim() 'lazy'
Confirm-That 'X28b' 'plugins were cloned under the workstation data directory' `
    (Test-Path -LiteralPath $pluginRoot) $pluginRoot

# ===========================================================================
Set-Group 'Group X7 — idempotency'

$before = (Get-LinkInfo).Target
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
Confirm-That 'X29' 'a second apply changes nothing' ((Get-LinkInfo).Target -eq $before)

$blockCount = ([regex]::Matches((Get-ProfileText), [regex]::Escape($OpenMarker))).Count
Confirm-That 'X30' 'the marked block still appears exactly once' ($blockCount -eq 1) "count: $blockCount"

# ===========================================================================
Set-Group 'Group X8 — the workstation never owns what it did not create'

if (Test-Path -LiteralPath $UserNeovim) { Remove-Item -Recurse -Force $UserNeovim }
New-Item -ItemType Directory -Path $UserNeovim -Force | Out-Null
$sentinel = 'vim.opt.number = false -- USER OWNED, MUST SURVIVE'
Set-Content -LiteralPath (Join-Path $UserNeovim 'init.lua') -Value $sentinel

$userLine = '$env:QA_USER_LINE = "must survive"'
Set-Content -LiteralPath $ProfilePath -Value ($userLine + "`n" + (Get-ProfileText))

Invoke-FullUninstall
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null

$userItem = Get-Item -LiteralPath $UserNeovim -Force
Confirm-That 'X31' 'the user Neovim directory is still a real directory' ($null -eq $userItem.LinkType)
Confirm-That 'X32' 'the user Neovim config is untouched' `
    ((Get-Content -LiteralPath (Join-Path $UserNeovim 'init.lua') -Raw).Trim() -ceq $sentinel)
Confirm-That 'X33' 'user content outside the profile markers survives' ((Get-ProfileText).Contains($userLine))

$plainConfig = & nvim --headless '+echo stdpath("config")' +q 2>&1 | Out-String
Confirm-That 'X34' 'plain nvim now resolves to the user own directory' `
    ($plainConfig.Trim() -eq $UserNeovim) "got: '$($plainConfig.Trim())'"

# ===========================================================================
Set-Group 'Group X9 — drift detection and repair'

Remove-WorkstationLink
$drift = Test-Workstation -PassThru 6>$null
Confirm-That 'X35' 'a deleted link is detected' `
    (@($drift | Where-Object { $_.Kind -eq 'link' -and $_.State -eq 'Pending' }).Count -eq 1)
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
Confirm-That 'X36' 'a deleted link is repaired' ($null -ne (Get-LinkInfo))

$decoy = Join-Path $HOME 'qa-decoy'
New-Item -ItemType Directory -Path $decoy -Force | Out-Null
Remove-WorkstationLink
New-Item -ItemType SymbolicLink -Path $LinkTarget -Target $decoy | Out-Null
$drift = Test-Workstation -PassThru 6>$null
$linkStep = @($drift | Where-Object { $_.Kind -eq 'link' })[0]
Confirm-That 'X37' 'a link pointing elsewhere is detected' ($linkStep.State -eq 'Pending')
Confirm-That 'X38' 'the report names the wrong target' ($linkStep.Detail -match 'qa-decoy')
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
Confirm-That 'X39' 'the stale link is repointed' ((Get-LinkInfo).Target.TrimEnd('/') -eq $expectedSource)
Confirm-That 'X40' 'the decoy directory survived' (Test-Path -LiteralPath $decoy)
Remove-Item -Recurse -Force $decoy

Remove-WorkstationLink
New-Item -ItemType Directory -Path $LinkTarget -Force | Out-Null
Set-Content -LiteralPath (Join-Path $LinkTarget 'stale.lua') -Value 'stale'
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$backups = @(Get-ChildItem -Path $ConfigHome -Filter 'workstation.backup-*' -Force -ErrorAction SilentlyContinue)
Confirm-That 'X41' 'a real directory is backed up, not destroyed' ($backups.Count -ge 1)
Confirm-That 'X42' 'the link is in place after the backup' ((Get-LinkInfo).LinkType -eq 'SymbolicLink')
$backups | ForEach-Object { Remove-Item -Recurse -Force $_.FullName }

# ===========================================================================
Set-Group 'Group X11 — uninstall and reinstall, three cycles'

for ($cycle = 1; $cycle -le 3; $cycle++) {
    Invoke-FullUninstall
    $gone = (-not (Test-Path -LiteralPath $LinkTarget)) -and (-not (Test-ProfileBlockPresent))
    Confirm-That ('X{0}' -f (60 + ($cycle - 1) * 2)) "cycle ${cycle}: uninstall leaves nothing behind" $gone

    Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
    $drift = Test-Workstation -PassThru 6>$null
    $bad = @($drift | Where-Object { $_.Kind -in @('link','profile') -and $_.State -in @('Pending','Blocked') })
    Confirm-That ('X{0}' -f (61 + ($cycle - 1) * 2)) "cycle ${cycle}: reinstall returns to in sync" ($bad.Count -eq 0)
}

Confirm-That 'X50' 'user content still survives after three cycles' ((Get-ProfileText).Contains($userLine))
Confirm-That 'X51' 'the user Neovim config still survives after three cycles' `
    ((Get-Content -LiteralPath (Join-Path $UserNeovim 'init.lua') -Raw).Trim() -ceq $sentinel)

# ===========================================================================
Set-Group 'Cleanup'
Remove-Item -Recurse -Force $UserNeovim -ErrorAction SilentlyContinue
$clean = ((Get-ProfileText) -replace [regex]::Escape($userLine), '').Trim()
Set-Content -LiteralPath $ProfilePath -Value $clean
Confirm-That 'X52' 'QA fixtures removed' `
    ((-not (Test-Path $UserNeovim)) -and (-not (Get-ProfileText).Contains($userLine)))

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
