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

function Get-ProcessTable {
    <# Every process, keyed by pid.

       Never by command line. This machine runs 29 pwsh.exe at rest, most of
       them byte-identical VS Code shell integrations, so diffing on the text
       collapses them to one entry and a genuinely new pane whose command line
       matches an existing process disappears from the difference. The Linux
       suite learned this and this one had not. #>
    return @(
        Get-CimInstance Win32_Process | ForEach-Object {
            [PSCustomObject]@{
                ProcessId       = [int] $_.ProcessId
                ParentProcessId = [int] $_.ParentProcessId
                Name            = $_.Name
                CommandLine     = $_.CommandLine
            }
        }
    )
}

function Get-NewProcesses {
    param([object[]] $Before, [object[]] $After)
    $known = @($Before | ForEach-Object { $_.ProcessId })
    return @($After | Where-Object { $_.ProcessId -notin $known })
}

function Get-ChildProcesses {
    <# The processes whose parent is one of these pids. Used to name a pane by
       what spawned it rather than by what it happens to be running. #>
    param([object[]] $Table, [int[]] $ParentIds)
    return @($Table | Where-Object { $_.ParentProcessId -in $ParentIds })
}

function Get-DescendantProcesses {
    <# Everything below these pids, at any depth.

       Direct children are not enough. `codex` on Windows is a shim that runs
       node, which runs codex.exe, so the agent sits two levels under its pane
       — and an assertion that only looked at children would call it absent
       while it was plainly running. Depth is bounded because the walk stops
       when a round adds nothing. #>
    param([object[]] $Table, [int[]] $ParentIds)

    $found   = @{}
    $frontier = @($ParentIds)
    while ($frontier.Count -gt 0) {
        $children = @($Table | Where-Object { $_.ParentProcessId -in $frontier -and -not $found.ContainsKey($_.ProcessId) })
        if ($children.Count -eq 0) { break }
        foreach ($child in $children) { $found[$child.ProcessId] = $child }
        $frontier = @($children | ForEach-Object { $_.ProcessId })
    }
    return @($found.Values)
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

    $before = Get-ProcessTable

    Start-Workstation -Agent $agent.Name -Directory $ProjectDir | Out-Null
    Start-Sleep -Seconds 18

    $after = Get-ProcessTable
    $new   = Get-NewProcesses -Before $before -After $after

    # 1. WezTerm came up with this repository's configuration
    $wez = @($new | Where-Object { $_.Name -eq 'wezterm-gui.exe' })
    $wezWithConfig = @($wez | Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape('wezterm.lua') })
    Confirm-That "$prefix.1" 'WezTerm launched with the repository config file' `
        ($wezWithConfig.Count -ge 1) "new wezterm procs: $($wez.Count)"

    # The panes are the shells WezTerm spawned. Named by their parent rather
    # than by what they are running, so a pane counts as present whatever
    # happened inside it.
    $wezPids = @($wez | ForEach-Object { $_.ProcessId })
    $panes = @((Get-ChildProcesses -Table $after -ParentIds $wezPids) |
        Where-Object { $_.Name -eq 'pwsh.exe' })
    Confirm-That "$prefix.1b" 'the launch produced exactly three panes' `
        ($panes.Count -eq 3) `
        "panes: $($panes.Count) -> $(($panes | ForEach-Object { $_.CommandLine }) -join ' | ')"

    # 2. editor pane, running Neovim under the workstation application name
    $editorPane = @($panes | Where-Object {
        $_.CommandLine -match 'NVIM_APPNAME' -and $_.CommandLine -match 'workstation' -and $_.CommandLine -match 'nvim' })
    Confirm-That "$prefix.2" 'editor pane runs nvim with NVIM_APPNAME=workstation' `
        ($editorPane.Count -eq 1) "matches: $($editorPane.Count)"

    # 3. agent pane
    $agentPane = @($panes | Where-Object {
        $_.CommandLine -match ('-Command\s+' + [regex]::Escape($agent.PaneCommand) + '\s*$') })
    Confirm-That "$prefix.3" "agent pane runs '$($agent.PaneCommand)'" `
        ($agentPane.Count -eq 1) "matches: $($agentPane.Count)"

    # 4. free shell pane
    $shellPane = @($panes | Where-Object { $_.CommandLine -match 'pwsh\.exe"?\s+-NoLogo\s*$' })
    Confirm-That "$prefix.4" 'bottom pane is a plain shell' `
        ($shellPane.Count -eq 1) "matches: $($shellPane.Count)"

    # 5. the agent is running UNDER ITS OWN PANE.
    #
    # Asking the machine whether a process of that name exists proves nothing
    # here: this machine has fourteen claude.exe at rest, from editor terminals
    # that have nothing to do with the workstation, so the assertion passed
    # whatever the launch did. It is therefore looked for beneath the pane that
    # was supposed to start it.
    $agentPanePids  = @($agentPane | ForEach-Object { $_.ProcessId })
    $agentBelowPane = Get-DescendantProcesses -Table $after -ParentIds $agentPanePids
    $agentProcess = @($agentBelowPane | Where-Object { $_.Name -match ('^' + [regex]::Escape($agent.Process) + '(\.exe)?$') })
    Confirm-That "$prefix.5" "the '$($agent.Process)' process is running under the agent pane" `
        ($agentProcess.Count -ge 1) `
        "below the agent pane: $(($agentBelowPane | ForEach-Object { $_.Name }) -join ', ')"

    # 6. and Neovim under its own, for the same reason
    $editorPanePids  = @($editorPane | ForEach-Object { $_.ProcessId })
    $editorBelowPane = Get-DescendantProcesses -Table $after -ParentIds $editorPanePids
    $nvimProcess = @($editorBelowPane | Where-Object { $_.Name -match '^nvim(\.exe)?$' })
    Confirm-That "$prefix.6" 'nvim is running under the editor pane' `
        ($nvimProcess.Count -ge 1) `
        "below the editor pane: $(($editorBelowPane | ForEach-Object { $_.Name }) -join ', ')"

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
