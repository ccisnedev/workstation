#Requires -Version 7.0
<#
    Launch QA for Linux. Opens the workstation once per agent and asserts the
    three panes actually came up, then closes the window again.

    Needs a graphical session. On a headless machine, wrap the whole script:

        xvfb-run -a --server-args="-screen 0 1920x1080x24" \
            pwsh -File ./Invoke-LinuxLaunchQA.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# This script lives at <repository>/code/powershell/Workstation/Tests/, so the
# repository root is four levels up.
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code/powershell/Workstation'
$WezTermConfig  = Join-Path $RepositoryRoot 'code/assets/wezterm/wezterm.lua'
$ConfigHome     = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
$DataHome       = if ($env:XDG_DATA_HOME)   { $env:XDG_DATA_HOME }   else { Join-Path $HOME '.local/share' }
$ProjectDir     = Join-Path ([System.IO.Path]::GetTempPath()) 'qa-workstation-project'

if ($IsWindows) { Write-Error 'This suite is for Linux and macOS. Use Invoke-LaunchQA.ps1 on Windows.'; exit 1 }

# Antigravity installs into ~/.local/bin, which a non-login shell may not carry.
$env:PATH = (Join-Path $HOME '.local/bin') + ':' + $env:PATH

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

function Get-ProcessTable {
    <# PowerShell on Linux does not expose command lines through Get-Process,
       so this reads them from ps.

       Processes are keyed by pid, never by their command line. Two panes can
       run byte-identical commands — a bare login shell is the obvious case —
       and diffing on the text silently loses the second one. #>
    $rows = & ps -eo pid=,args= 2>/dev/null
    return @(
        foreach ($row in $rows) {
            if ($row -match '^\s*(\d+)\s+(.*)$') {
                [PSCustomObject]@{ ProcessId = [int] $Matches[1]; CommandLine = $Matches[2].Trim() }
            }
        }
    )
}
function Get-NewProcesses {
    param([object[]] $Before, [object[]] $After)
    $known = @($Before | ForEach-Object { $_.ProcessId })
    return @($After | Where-Object { $_.ProcessId -notin $known })
}
function Close-AllWezTerm {
    & pkill -f 'wezterm-gui' 2>/dev/null | Out-Null
    Start-Sleep -Seconds 3
}

# --- fixture ---------------------------------------------------------------
if (Test-Path $ProjectDir) { Remove-Item -Recurse -Force $ProjectDir }
New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
Set-Content -Path (Join-Path $ProjectDir 'index.js') -Value "console.log('qa');"

Write-Host ''
Write-Host '  WORKSTATION — LINUX LAUNCH QA (four agents)' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray
Write-Host "  display:    $($env:DISPLAY)" -ForegroundColor DarkGray
Write-Host "  project:    $ProjectDir" -ForegroundColor DarkGray

Import-Module $ModulePath -Force -ErrorAction Stop
Close-AllWezTerm

Set-Group 'Preconditions'
Confirm-That 'P01' 'a graphical display is available' (-not [string]::IsNullOrEmpty($env:DISPLAY)) "DISPLAY='$($env:DISPLAY)'"
Confirm-That 'P02' 'WezTerm is installed on this machine' ($null -ne (Get-Command wezterm -ErrorAction Ignore))
foreach ($c in @('claude', 'codex', 'agy', 'opencode')) {
    Confirm-That "P03.$c" "the '$c' command is on PATH" ($null -ne (Get-Command $c -ErrorAction Ignore))
}

$agents = @(
    @{ Name = 'claude';      Process = 'claude';   PaneCommand = 'claude'   }
    @{ Name = 'codex';       Process = 'codex';    PaneCommand = 'codex'    }
    @{ Name = 'antigravity'; Process = 'agy';      PaneCommand = 'agy'      }
    @{ Name = 'opencode';    Process = 'opencode'; PaneCommand = 'opencode' }
)

$index = 0
foreach ($agent in $agents) {
    $index++
    $prefix = 'N{0:d2}' -f $index
    Set-Group "Agent: $($agent.Name)"

    $before = Get-ProcessTable

    Start-Workstation -Agent $agent.Name -Directory $ProjectDir | Out-Null
    Start-Sleep -Seconds 20

    $after = Get-ProcessTable
    $new   = Get-NewProcesses -Before $before -After $after

    $wez = @($new | Where-Object { $_.CommandLine -match 'wezterm-gui' })
    Confirm-That "$prefix.1" 'WezTerm launched with the repository config file, and survived startup' `
        (@($wez | Where-Object { $_.CommandLine -match [regex]::Escape($WezTermConfig) }).Count -ge 1) `
        "new wezterm procs: $($wez.Count)"

    $editorPane = @($new | Where-Object { $_.CommandLine -match 'NVIM_APPNAME=workstation' -and $_.CommandLine -match 'nvim' })
    Confirm-That "$prefix.2" 'editor pane runs nvim with NVIM_APPNAME=workstation' `
        ($editorPane.Count -ge 1) "matches: $($editorPane.Count)"

    $agentPane = @($new | Where-Object { $_.CommandLine -match ('bash -lc ' + [regex]::Escape($agent.PaneCommand) + '; exec') })
    Confirm-That "$prefix.3" "agent pane runs '$($agent.PaneCommand)' and keeps the shell" `
        ($agentPane.Count -ge 1) "matches: $($agentPane.Count)"

    # The bottom pane is the user's login shell with no arguments. Matched among
    # the new pids only, so an identical shell that already existed cannot be
    # mistaken for it, and cannot mask its absence either.
    $shellPanes = @($new | Where-Object { $_.CommandLine -match '^-?(/usr/bin/|/bin/)?bash$' })
    Confirm-That "$prefix.4" 'bottom pane is a plain login shell' `
        ($shellPanes.Count -ge 1) `
        "new bash-only procs: $($shellPanes.Count); new procs seen: $(($new | ForEach-Object { $_.CommandLine }) -join ' | ')"

    $agentProcess = @($new | Where-Object { $_.CommandLine -match ('(^|/)' + [regex]::Escape($agent.Process) + '($|\s)') })
    Confirm-That "$prefix.5" "the '$($agent.Process)' process was started by this launch" `
        ($agentProcess.Count -ge 1) "matches: $($agentProcess.Count)"

    $nvimProcess = @($new | Where-Object { $_.CommandLine -match '(^|/)nvim($|\s)' })
    Confirm-That "$prefix.6" 'nvim was started by this launch' ($nvimProcess.Count -ge 1) "matches: $($nvimProcess.Count)"

    Close-AllWezTerm
    Confirm-That "$prefix.7" 'the window closes cleanly' `
        (@(Get-ProcessTable | Where-Object { $_.CommandLine -match 'wezterm-gui' }).Count -eq 0)
}

# ===========================================================================
Set-Group 'Neovim data isolation on Linux'

$workstationData = Join-Path $DataHome 'workstation'
$userData        = Join-Path $DataHome 'nvim'
Confirm-That 'N05.1' 'the workstation keeps its plugin data in its own directory' `
    (Test-Path -LiteralPath $workstationData) $workstationData
Confirm-That 'N05.2' 'that directory is not the one plain nvim uses' ($workstationData -ne $userData)
Confirm-That 'N05.3' 'plugins live under the workstation data directory' `
    (Test-Path -LiteralPath (Join-Path $workstationData 'lazy'))

Set-Group 'Environment hygiene'
Confirm-That 'N06.1' 'WORKSTATION_AGENT is cleared from the caller session' `
    ([string]::IsNullOrEmpty($env:WORKSTATION_AGENT))
Confirm-That 'N06.2' 'WORKSTATION_DIRECTORY is cleared from the caller session' `
    ([string]::IsNullOrEmpty($env:WORKSTATION_DIRECTORY))

Remove-Item -Recurse -Force $ProjectDir -ErrorAction SilentlyContinue

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
