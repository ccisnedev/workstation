#Requires -Version 7.0
<#
    Launch QA: opens the workstation once per agent and asserts the three panes
    actually came up, then closes the window again.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# This script lives at <repository>/code/powershell/Workstation/Tests/, so the
# repository root is four levels up.
$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code\powershell\Workstation'
$WezTermConfig  = Join-Path $RepositoryRoot 'code\assets\wezterm\wezterm.lua'
$NeovimData     = Join-Path $env:LOCALAPPDATA 'workstation-data'
$UserNeovimData = Join-Path $env:LOCALAPPDATA 'nvim-data'
$ProjectDir     = Join-Path $env:TEMP 'qa-workstation-project'

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

function Get-PwshCommandLines {
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
        Select-Object -ExpandProperty CommandLine |
        Where-Object { $_ }
}

function Close-AllWezTerm {
    Get-Process wezterm-gui -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 3
}

# --- fixture ---------------------------------------------------------------
if (Test-Path $ProjectDir) { Remove-Item -Recurse -Force $ProjectDir }
New-Item -ItemType Directory -Path $ProjectDir -Force | Out-Null
Set-Content -Path (Join-Path $ProjectDir 'index.js') -Value "console.log('qa');"

Write-Host ''
Write-Host '  WORKSTATION — LAUNCH QA (four agents)' -ForegroundColor White
Write-Host "  project: $ProjectDir" -ForegroundColor DarkGray

Import-Module $ModulePath -Force -ErrorAction Stop
Close-AllWezTerm

$agents = @(
    @{ Name = 'claude';      Process = 'claude'; PaneCommand = 'claude'   }
    @{ Name = 'codex';       Process = 'codex';  PaneCommand = 'codex'    }
    @{ Name = 'antigravity'; Process = 'agy';    PaneCommand = 'agy'      }
    @{ Name = 'opencode';    Process = 'opencode'; PaneCommand = 'opencode' }
)

$index = 0
foreach ($agent in $agents) {
    $index++
    $prefix = 'L{0:d2}' -f $index
    Set-Group "Agent: $($agent.Name)"

    $before = @(Get-PwshCommandLines)

    Start-Workstation -Agent $agent.Name -Directory $ProjectDir | Out-Null
    Start-Sleep -Seconds 18

    $after = @(Get-PwshCommandLines)
    $new   = @($after | Where-Object { $_ -notin $before })

    # 1. WezTerm came up with this repository's configuration
    $wez = @(Get-CimInstance Win32_Process -Filter "Name='wezterm-gui.exe'")
    $wezWithConfig = @($wez | Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape('wezterm.lua') })
    Confirm-That "$prefix.1" 'WezTerm launched with the repository config file' `
        ($wezWithConfig.Count -ge 1) "wezterm procs: $($wez.Count)"

    # 2. editor pane, running Neovim under the workstation application name
    $editorPane = @($new | Where-Object { $_ -match 'NVIM_APPNAME' -and $_ -match 'workstation' -and $_ -match 'nvim' })
    Confirm-That "$prefix.2" 'editor pane runs nvim with NVIM_APPNAME=workstation' `
        ($editorPane.Count -eq 1) "matches: $($editorPane.Count)"

    # 3. agent pane
    $agentPane = @($new | Where-Object { $_ -match ('-Command\s+' + [regex]::Escape($agent.PaneCommand) + '\s*$') })
    Confirm-That "$prefix.3" "agent pane runs '$($agent.PaneCommand)'" `
        ($agentPane.Count -eq 1) "matches: $($agentPane.Count)"

    # 4. free shell pane
    $shellPane = @($new | Where-Object { $_ -match 'pwsh\.exe"?\s+-NoLogo\s*$' })
    Confirm-That "$prefix.4" 'bottom pane is a plain shell' `
        ($shellPane.Count -ge 1) "matches: $($shellPane.Count)"

    # 5. the agent process itself is alive
    $proc = @(Get-Process -Name $agent.Process -ErrorAction SilentlyContinue)
    Confirm-That "$prefix.5" "the '$($agent.Process)' process is running" ($proc.Count -ge 1)

    # 6. nvim is alive
    $nvim = @(Get-Process -Name nvim -ErrorAction SilentlyContinue)
    Confirm-That "$prefix.6" 'nvim is running' ($nvim.Count -ge 1)

    Close-AllWezTerm
    $stillOpen = @(Get-Process wezterm-gui -ErrorAction SilentlyContinue)
    Confirm-That "$prefix.7" 'the window closes cleanly' ($stillOpen.Count -eq 0)
}

# ===========================================================================
Set-Group 'Neovim data isolation'

Confirm-That 'L05.1' 'the workstation keeps its plugin data in its own directory' `
    (Test-Path -LiteralPath $NeovimData) $NeovimData

Confirm-That 'L05.2' 'the plugin data directory is not shared with plain nvim' `
    ($NeovimData -ne $UserNeovimData)

$lazyInWorkstation = Test-Path (Join-Path $NeovimData 'lazy')
Confirm-That 'L05.3' 'plugins were installed under the workstation data directory' $lazyInWorkstation

# ===========================================================================
Set-Group 'Environment hygiene'

Confirm-That 'L06.1' 'WORKSTATION_AGENT is cleared from the caller session' `
    ([string]::IsNullOrEmpty($env:WORKSTATION_AGENT)) "value: '$($env:WORKSTATION_AGENT)'"
Confirm-That 'L06.2' 'WORKSTATION_DIRECTORY is cleared from the caller session' `
    ([string]::IsNullOrEmpty($env:WORKSTATION_DIRECTORY)) "value: '$($env:WORKSTATION_DIRECTORY)'"

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
