#Requires -Version 7.0
<#
    QA for the keys the editor adds to the file tree. Needs Neovim, so it does
    not run in CI.

    These assertions press the key. Calling the function behind a mapping
    proves the function; it does not prove that the key reaches it, and that is
    exactly what went wrong once already: four commands were written, the
    mapping resolved when it was asked, and in a running editor `Y` was still
    Vim's own yank. Nothing here calls a tree command by name.

    What leaves Neovim -- the clipboard, the program that owns a PDF, the file
    manager -- goes through one table, WorkstationDesktop, which these tests
    replace with a recorder. So a key can be proven to reach the right call
    with the right path without a PDF reader opening on somebody's desktop.
    One assertion does not replace it and puts a real file on the real
    clipboard, because that is the one thing a recorder cannot vouch for.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

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

Write-Host ''
Write-Host '  WORKSTATION - EDITOR QA' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray

if ($null -eq (Get-Command nvim -ErrorAction Ignore)) {
    Write-Host '  Neovim is not installed; this suite needs it.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
#  A fixture workspace, so the paths asserted are ours and not the repository's
# ---------------------------------------------------------------------------
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "workstation-editor-qa-$(Get-Random)"
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
$FixtureDir = Join-Path $TempRoot 'una carpeta'
New-Item -ItemType Directory -Path $FixtureDir -Force | Out-Null
$FixtureFile = Join-Path $FixtureDir 'objetivo.txt'
Set-Content -LiteralPath $FixtureFile -Value 'contenido de prueba' -Encoding utf8NoBOM
$RecordFile = Join-Path $TempRoot 'recorded.txt'

function ConvertTo-LuaLiteral { param([string] $Text) return '[[' + $Text + ']]' }

function Invoke-TreeKey {
    <# Opens the tree over the fixture, waits for it to render, puts the cursor
       on the line named, presses the keys, and returns what the Lua printed.
       Setup runs after the tree is up and before the key is pressed, which is
       where a recorder replaces the seam. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Key,
        [Parameter(Mandatory)][string] $Report,
        [string] $Target = 'objetivo.txt',
        [string] $Setup  = '',
        [string] $Root   = '',
        [int]    $SettleMilliseconds = 900
    )
    if (-not $Root) { $Root = $FixtureDir }
    $steps = [System.Collections.Generic.List[string]]::new()
    $steps.Add("local rendered = vim.wait(15000, function() return vim.bo.filetype == 'neo-tree' and vim.fn.search($(ConvertTo-LuaLiteral $Target), 'nw') > 0 end, 100)")
    $steps.Add("if not rendered then io.write('TREE-NEVER-RENDERED') return end")
    if ($Setup) { $steps.Add($Setup) }
    $steps.Add("vim.fn.search($(ConvertTo-LuaLiteral $Target))")
    if ($Key) { $steps.Add("vim.api.nvim_feedkeys($(ConvertTo-LuaLiteral $Key), 'x', false)") }
    $steps.Add("vim.wait($SettleMilliseconds)")
    $steps.Add("io.write('<<' .. ($Report) .. '>>')")
    $lua = $steps -join '; '

    Push-Location $Root
    $env:NVIM_APPNAME = 'workstation'
    $out = & nvim --headless -c 'Neotree focus' -c "lua $lua" -c 'qa' 2>&1 | Out-String
    Pop-Location

    $match = [regex]::Match($out, '(?s)<<(.*?)>>')
    if (-not $match.Success) { return "NO-REPORT: $($out.Trim())" }
    return $match.Groups[1].Value
}

# The recorder. Replaces everything that leaves Neovim with a line in a file,
# so what is asserted is the call that would have been made.
$RecorderPath = $RecordFile.Replace('\', '/')
$Recorder = @(
    "local out = io.open([[$RecorderPath]], 'w')",
    "_G.WorkstationDesktop.spawn = function(argv) out:write('spawn|' .. table.concat(argv, ' ')) out:flush() end",
    "_G.WorkstationDesktop.open = function(path) out:write('open|' .. path) out:flush() end"
) -join '; '

function Get-Recorded {
    if (-not (Test-Path -LiteralPath $RecordFile)) { return '' }
    return ((Get-Content -LiteralPath $RecordFile -Raw) -replace '\s+$', '')
}
function Clear-Recorded { Remove-Item -LiteralPath $RecordFile -Force -ErrorAction Ignore }

# ===========================================================================
Set-Group 'Group E1 - the tree renders and the keys are on it'

$report = "'ft=' .. vim.bo.filetype .. ' Y=' .. tostring(vim.fn.maparg('Y', 'n') ~= '') .. ' gy=' .. tostring(vim.fn.maparg('gy', 'n') ~= '') .. ' gx=' .. tostring(vim.fn.maparg('gx', 'n') ~= '') .. ' gr=' .. tostring(vim.fn.maparg('gr', 'n') ~= '')"
$bound = Invoke-TreeKey -Key '' -Report $report
Confirm-That 'E01' 'the tree opens over the fixture and shows the file' `
    ($bound -notmatch 'TREE-NEVER-RENDERED' -and $bound -notmatch 'NO-REPORT') $bound
Confirm-That 'E02' 'all four keys are bound inside the tree' `
    ($bound -eq 'ft=neo-tree Y=true gy=true gx=true gr=true') $bound

# Bound in the tree and nowhere else: Y in an ordinary buffer is still Vim's.
Push-Location $FixtureDir
$env:NVIM_APPNAME = 'workstation'
$outside = & nvim --headless -c "lua io.write('<<' .. tostring(vim.fn.maparg('Y', 'n')) .. '>>')" -c 'qa' 2>&1 | Out-String
Pop-Location
# Neovim binds Y to y$ by default -- yank from the cursor to the end of the
# line. That is what an editor pane opened before these keys existed still
# does with Y, and it looks enough like a copy to be mistaken for a broken one.
Confirm-That 'E03' 'and nowhere else: outside the tree Y is still Neovim own y$' `
    ($outside -match '<<y\$>>') "maparg outside the tree: $($outside.Trim())"

# ===========================================================================
Set-Group 'Group E2 - Y copies the path'

$reg = Invoke-TreeKey -Key 'Y' -Report "vim.fn.getreg('+')"
Confirm-That 'E04' 'pressing Y puts the full path of the file in the clipboard register' `
    ($reg -eq $FixtureFile) "expected $FixtureFile, got $reg"

$regFolder = Invoke-TreeKey -Key 'Y' -Target 'una carpeta' -Root $TempRoot -Report "vim.fn.getreg('+')"
Confirm-That 'E05' 'and on a folder, the folder path' `
    ($regFolder -eq $FixtureDir) "expected $FixtureDir, got $regFolder"

$said = Invoke-TreeKey -Key 'Y' -Report "(vim.fn.execute('messages'):gsub('%s+', ' '))"
Confirm-That 'E06' 'and says so, because a key that acts in silence reads as a key that did nothing' `
    ($said -match 'path copied' -and $said -match 'objetivo\.txt') $said

# ===========================================================================
Set-Group 'Group E3 - gx and gr reach the desktop with the right path'

Clear-Recorded
$null = Invoke-TreeKey -Key 'gx' -Setup $Recorder -Report "'done'"
Confirm-That 'E07' 'pressing gx asks the desktop to open the file itself' `
    ((Get-Recorded) -eq "open|$FixtureFile") "recorded: $(Get-Recorded)"

Clear-Recorded
$null = Invoke-TreeKey -Key 'gr' -Setup $Recorder -Report "'done'"
$expectedReveal = if ($IsWindows) { "spawn|explorer.exe /select,$FixtureFile" } else { "open|$FixtureDir" }
Confirm-That 'E08' 'pressing gr asks the file manager for the folder, with the file selected' `
    ((Get-Recorded) -eq $expectedReveal) "expected '$expectedReveal', recorded: $(Get-Recorded)"

if ($IsWindows) {
    # The separator matters: Explorer ignores a /select, argument with forward
    # slashes in it and opens the documents folder instead, which reads as the
    # key doing nothing. neo-tree hands out whichever separator built the node.
    Confirm-That 'E09' 'and the path it is given carries no forward slash' `
        ((Get-Recorded) -notmatch '/select,.*/') "recorded: $(Get-Recorded)"
}
else {
    Confirm-That 'E09' 'and off Windows it is the containing folder that is opened' `
        ((Get-Recorded) -eq "open|$FixtureDir") "recorded: $(Get-Recorded)"
}

# ===========================================================================
Set-Group 'Group E4 - gy copies the file itself'

Clear-Recorded
$null = Invoke-TreeKey -Key 'gy' -Setup $Recorder -Report "'done'"
$recorded = Get-Recorded

if ($IsWindows) {
    Confirm-That 'E10' 'pressing gy runs the one command that puts a file on the clipboard' `
        ($recorded -match '^spawn\|powershell\.exe ' -and $recorded -match 'Set-Clipboard -LiteralPath') $recorded
    Confirm-That 'E11' 'single threaded, without a profile, and naming this file' `
        ($recorded -match ' -STA ' -and $recorded -match ' -NoProfile ' -and
         $recorded -match [regex]::Escape($FixtureFile)) $recorded

    # The one call not made through a recorder. A recorder can prove the right
    # command was chosen; only the clipboard can prove the file is on it.
    Set-Clipboard -Value 'nada de nada'
    $null = Invoke-TreeKey -Key 'gy' -SettleMilliseconds 4000 -Report "'done'"
    $onClipboard = @(& powershell.exe -NoProfile -NonInteractive -STA -Command 'Get-Clipboard -Format FileDropList' 2>$null)
    Confirm-That 'E12' 'and the file really is on the clipboard afterwards, as a file' `
        (@($onClipboard | Where-Object { "$_" -match 'objetivo\.txt' }).Count -gt 0) `
        "clipboard: $($onClipboard -join '; ')"
}
else {
    $pathInstead = Invoke-TreeKey -Key 'gy' -Report "vim.fn.getreg('+')"
    Confirm-That 'E10' 'off Windows, gy copies the path instead' `
        ($pathInstead -eq $FixtureFile) "got: $pathInstead"
    $warned = Invoke-TreeKey -Key 'gy' -Report "(vim.fn.execute('messages'):gsub('%s+', ' '))"
    Confirm-That 'E11' 'and says that it did something other than what was asked' `
        ($warned -match 'Windows only') $warned
    Confirm-That 'E12' 'and reaches no program at all' ($recorded -eq '') "recorded: $recorded"
}

# ===========================================================================
Set-Group 'Group E5 - nothing the tree already did was taken away'

$defaultsReport = "'a=' .. tostring(vim.fn.maparg('a', 'n') ~= '') .. ' r=' .. tostring(vim.fn.maparg('r', 'n') ~= '') .. ' d=' .. tostring(vim.fn.maparg('d', 'n') ~= '') .. ' y=' .. tostring(vim.fn.maparg('y', 'n') ~= '') .. ' q=' .. tostring(vim.fn.maparg('q', 'n') ~= '')"
$defaults = Invoke-TreeKey -Key '' -Report $defaultsReport
Confirm-That 'E13' 'new file, rename, delete, the tree clipboard and close are all still bound' `
    ($defaults -eq 'a=true r=true d=true y=true q=true') $defaults

# ===========================================================================
Set-Group 'Cleanup'
Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction Ignore
Confirm-That 'E14' 'the fixture workspace is gone' (-not (Test-Path -LiteralPath $TempRoot))

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
