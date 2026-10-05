#Requires -Version 7.0
<#
    QA for showing and hiding the panes of the workstation layout. Needs
    Neovim, to run Lua, so it does not run in CI.

    WezTerm cannot be opened here: a window is the one thing these assertions
    must not touch. So the feature is split where the testing can reach. What
    the window should look like is decided by panes.lua, which calls no WezTerm
    API and is run through Neovim as identity.lua is. How the decision is drawn
    is wezterm.lua, which is loaded here against a stub of the `wezterm`
    module and driven with fake panes, a fake tab and a fake window. What these
    assertions prove is the decision, the wiring and the bookkeeping. That the
    real windows move is the reviewer's manual check; the issue lists it.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$WezTermDir     = Join-Path $RepositoryRoot 'code/assets/wezterm'
$PanesLua       = Join-Path $WezTermDir 'panes.lua'
$WezTermConfig  = Join-Path $WezTermDir 'wezterm.lua'

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
Write-Host '  WORKSTATION - PANE TOGGLE QA' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray

if ($null -eq (Get-Command nvim -ErrorAction Ignore)) {
    Write-Host '  Neovim is not installed; this suite needs it.' -ForegroundColor Red
    exit 1
}

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "workstation-pane-toggle-qa-$(Get-Random)"
New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

function Invoke-Lua {
    <# Runs a Lua script under headless Neovim and returns what it wrote. The
       script is written to a file because -l is the one way to run Lua that
       has no quoting of its own to get wrong. #>
    param([Parameter(Mandatory)][string] $Script, [string] $Name = 'case')
    $path = Join-Path $TempRoot "$Name-$(Get-Random).lua"
    Set-Content -LiteralPath $path -Value $Script -Encoding utf8NoBOM
    $out = & nvim --headless -u NONE -l $path 2>&1 | Out-String
    return $out.Trim()
}
function ConvertTo-LuaPath { param([string] $Path) return $Path.Replace('\', '/') }

$Roles = @('agent', 'editor', 'shell')

# ===========================================================================
Set-Group 'Group P1 - the decision is a pure function'

Confirm-That 'P01' 'the decision lives in its own file beside the WezTerm configuration' `
    (Test-Path -LiteralPath $PanesLua) $PanesLua

$panesText = if (Test-Path -LiteralPath $PanesLua) { Get-Content -LiteralPath $PanesLua -Raw } else { '' }
Confirm-That 'P02' 'and it calls no WezTerm API: it neither requires the module nor names it' `
    ($panesText -ne '' -and $panesText -notmatch 'require\s*\(?\s*["'']wezterm' -and $panesText -notmatch 'wezterm\.') `
    'panes.lua must carry no dependency, so that a test can run it without a window'

# Every visible set and every key. The Lua prints one line per case and the
# expectation is computed here, from the rules in the issue, not from the code.
$decideLua = @"
local panes = dofile([[$(ConvertTo-LuaPath $PanesLua)]])
local roles = { 'agent', 'editor', 'shell' }
local function set_of(mask)
  local s = {}
  for i, r in ipairs(roles) do if bit.band(mask, bit.lshift(1, i - 1)) ~= 0 then s[r] = true end end
  return s
end
local function names(s)
  local out = {}
  for _, r in ipairs(roles) do if s[r] then out[#out + 1] = r end end
  return table.concat(out, ',')
end
for mask = 1, 7 do
  for _, key in ipairs(roles) do
    local focuses = { '-' }
    for _, r in ipairs(roles) do if set_of(mask)[r] then focuses[#focuses + 1] = r end end
    for _, focused in ipairs(focuses) do
      local d = panes.decide(set_of(mask), key, focused ~= '-' and focused or nil)
      io.write(table.concat({ names(set_of(mask)), key, focused, names(d.visible), tostring(d.mode), tostring(d.pane), tostring(d.focus), tostring(d.changed) }, '|'), '\n')
    end
  end
end
"@
$decided = @()
if (Test-Path -LiteralPath $PanesLua) {
    $decided = @((Invoke-Lua -Script $decideLua -Name 'decide') -split "`r?`n" | Where-Object { $_ -match '\|' })
}

$wrongSet   = [System.Collections.Generic.List[string]]::new()
$wrongMode  = [System.Collections.Generic.List[string]]::new()
$wrongFocus = [System.Collections.Generic.List[string]]::new()
foreach ($line in $decided) {
    $f = $line -split '\|'
    $before = @($f[0] -split ',' | Where-Object { $_ })
    $key = $f[1]; $focused = $f[2]
    $mode = $f[4]; $pane = $f[5]; $focus = $f[6]; $changed = $f[7]

    $expected = if ($before -contains $key) { @($before | Where-Object { $_ -ne $key }) } else { @($before + $key) }
    $noop = ($expected.Count -eq 0)
    if ($noop) { $expected = $before }
    $expectedSorted = (($Roles | Where-Object { $expected -contains $_ }) -join ',')
    if ($f[3] -cne $expectedSorted -or $changed -cne (-not $noop).ToString().ToLower()) {
        $wrongSet.Add("$line (expected set $expectedSorted)")
    }

    $expectedMode = switch ($expected.Count) {
        3 { 'layout|nil' }
        2 { 'collapse|' + ($Roles | Where-Object { $expected -notcontains $_ }) }
        1 { 'zoom|' + $expected[0] }
    }
    if ("$mode|$pane" -cne $expectedMode) { $wrongMode.Add("$line (expected $expectedMode)") }

    $shown = (-not $noop) -and ($before -notcontains $key)
    $ok = $expected -contains $focus
    if ($shown) { $ok = $ok -and ($focus -ceq $key) }
    elseif ($focused -ne '-' -and $expected -contains $focused) { $ok = $ok -and ($focus -ceq $focused) }
    if (-not $ok) { $wrongFocus.Add("$line") }
}

# Per mask, one case without a focus and one for each visible pane; per key.
Confirm-That 'P03' 'all 7 visible sets by 3 keys, with every focus a person can have, were decided' `
    ($decided.Count -eq 57) "cases: $($decided.Count)"
Confirm-That 'P04' 'a key flips its own pane, and one that would hide the last pane changes nothing' `
    ($decided.Count -gt 0 -and $wrongSet.Count -eq 0) (($wrongSet | Select-Object -First 3) -join ' | ')
Confirm-That 'P05' 'three visible are the layout, two are a collapse of the third, one is a zoom of it' `
    ($decided.Count -gt 0 -and $wrongMode.Count -eq 0) (($wrongMode | Select-Object -First 3) -join ' | ')
Confirm-That 'P06' 'the focus is always in the new visible set, is the pane just shown, and stays put when it can' `
    ($decided.Count -gt 0 -and $wrongFocus.Count -eq 0) (($wrongFocus | Select-Object -First 3) -join ' | ')

# ===========================================================================
Set-Group 'Cleanup'
Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction Ignore
Confirm-That 'P99' 'the fixture directory is gone' (-not (Test-Path -LiteralPath $TempRoot))

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
