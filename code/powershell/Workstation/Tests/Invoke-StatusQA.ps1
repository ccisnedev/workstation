#Requires -Version 7.0
<#
    QA for the status line: which model is answering, how much of the context
    window is used, and how much of the plan's limits is spent, shown in the
    agent's own bar and in the WezTerm status bar of the workstation window.
    Runs on Windows, Linux and macOS. Needs PowerShell, and Neovim for the
    group that runs the Lua module, the way the preference suite does.

    The contract under test:

        code/assets/claude/statusline.ps1
            Claude Code runs it on every status update with a JSON payload on
            stdin. It prints one line for Claude's bar, and when
            WORKSTATION_STATUS_FILE names a file it writes the same facts there
            as a Lua table. It prints no price, and never fails.

        code/assets/wezterm/status.lua
            Reads that file and renders it as segments with a level, so the
            WezTerm status bar shows what the agent knows about itself.

        Install-Workstation
            Generates a Claude settings file naming the command, so `ws` can
            hand it to claude with --settings and the user's own settings.json
            is never touched.

        ws
            Passes --settings to claude, names the status file after the
            project, and leaves every other agent alone.

    Everything runs against fixtures: a temporary generated directory, a
    declared state whose tools and agents are all pwsh, and payloads written
    here. No real settings file, credential or window is involved.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code/powershell/Workstation'
$StatusCommand  = Join-Path $RepositoryRoot 'code/assets/claude/statusline.ps1'
$StatusLua      = Join-Path $RepositoryRoot 'code/assets/wezterm/status.lua'
$WezTermLua     = Join-Path $RepositoryRoot 'code/assets/wezterm/wezterm.lua'
$TempRoot       = Join-Path ([System.IO.Path]::GetTempPath()) 'qa-workstation-status'
$GeneratedDir   = Join-Path $TempRoot 'generated'
$StatusDir      = Join-Path $GeneratedDir 'status'
$FixturePath    = Join-Path $TempRoot 'declared-state.psd1'

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

function ConvertTo-LuaPath { param([string] $Path) return $Path.Replace('\', '/') }

# Runs the status line command the way Claude Code does: a fresh process, the
# payload on stdin, and the status file named by the environment. Returns
# what it printed and how it exited.
function Invoke-StatusCommand {
    param([AllowNull()][string] $Payload, [AllowNull()][string] $StatusFile)
    $previous = $env:WORKSTATION_STATUS_FILE
    $env:WORKSTATION_STATUS_FILE = $StatusFile
    try {
        $output = $Payload | pwsh -NoProfile -NonInteractive -File $StatusCommand 2>&1 | Out-String
        return [PSCustomObject]@{ Output = $output.TrimEnd(); ExitCode = $LASTEXITCODE }
    }
    finally {
        $env:WORKSTATION_STATUS_FILE = $previous
    }
}

# Evaluates one Lua expression against the status module, through Neovim,
# and returns what it printed.
function Invoke-StatusLua {
    param([Parameter(Mandatory)][string] $Expression)
    $luaPath = ConvertTo-LuaPath $StatusLua
    $script  = "local status = dofile('$luaPath'); io.write(tostring($Expression))"
    $out = & nvim --headless -u NONE "+lua $script" +q 2>&1 | Out-String
    return $out.Trim()
}

# Runs Start-Workstation stopped by -WhatIf and returns what it would have
# launched, with its errors and warnings.
function Invoke-Start {
    param([hashtable] $Arguments)
    $errors = $null; $warnings = $null
    $result = Start-Workstation @Arguments -WhatIf -PassThru -ErrorAction SilentlyContinue -ErrorVariable errors -WarningAction SilentlyContinue -WarningVariable warnings 2>$null
    return [PSCustomObject]@{
        Result   = $result
        Errors   = @($errors)
        Warnings = (@($warnings) | ForEach-Object { $_.ToString() }) -join ' '
        Message  = (@($errors) | ForEach-Object { $_.ToString() }) -join ' '
    }
}

# The payload Claude Code hands the command, as documented: the model, the
# context window, the plan's limits, and a cost figure that must never be
# repeated anywhere.
$SessionResetEpoch = 1789830000
$WeekResetEpoch    = 1790280000
$FullPayload = @"
{
  "session_id": "qa-session-1234",
  "cwd": "C:/qa/shop",
  "model": { "id": "claude-fable-5-1", "display_name": "Fable 5.1" },
  "workspace": { "current_dir": "C:/qa/shop", "project_dir": "C:/qa/shop" },
  "version": "2.1.273",
  "cost": { "total_cost_usd": 12.3456, "total_duration_ms": 45000 },
  "context_window": {
    "total_input_tokens": 67200, "total_output_tokens": 1200,
    "context_window_size": 200000, "used_percentage": 33.6, "remaining_percentage": 66.4
  },
  "effort": { "level": "high" },
  "rate_limits": {
    "five_hour": { "used_percentage": 8.2, "resets_at": $SessionResetEpoch },
    "seven_day": { "used_percentage": 54.4, "resets_at": $WeekResetEpoch }
  }
}
"@

# The payload at the start of a session: no API call yet, so no percentage
# and no limits.
$EarlyPayload = @"
{
  "session_id": "qa-session-1234",
  "model": { "id": "claude-fable-5-1", "display_name": "Fable 5.1" },
  "cost": { "total_cost_usd": 0 },
  "context_window": { "total_input_tokens": 0, "context_window_size": 200000, "used_percentage": null, "remaining_percentage": null, "current_usage": null }
}
"@

# ---------------------------------------------------------------------------
#  Fixture
# ---------------------------------------------------------------------------
if (Test-Path $TempRoot) { Remove-Item -Recurse -Force $TempRoot }
New-Item -ItemType Directory -Force -Path $TempRoot, $GeneratedDir | Out-Null

$ShopDir  = Join-Path $TempRoot 'shop'
$ShopDir2 = Join-Path (Join-Path $TempRoot 'other') 'shop'
$OddDir   = Join-Path $TempRoot 'my shop (v2)'
foreach ($d in @($ShopDir, $ShopDir2, $OddDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$generatedForPsd1 = $GeneratedDir.Replace('\', '/')
Set-Content -LiteralPath $FixturePath -Encoding utf8 -Value @"
@{
    Name = 'qa-status'; Version = '0.0.0'; Description = 'fixture'
    Tools = @(
        @{ Name = 'Stand-in terminal'; Purpose = 'Terminal'; Command = 'pwsh'; Required = `$true; Role = 'terminal'
           WindowsInstall = 'x'; LinuxInstall = 'x' }
    )
    Links = @()
    PowerShellProfile = @{ Name = 'qa profile'; OpenMarker = '# >>> qa >>>'; CloseMarker = '# <<< qa <<<' }
    GeneratedArtifacts = @(
        @{ Name = 'Claude settings'; Kind = 'claude-settings'; FileName = 'claude-settings.json'
           WindowsTarget = '$generatedForPsd1'; LinuxTarget = '$generatedForPsd1' }
    )
    AgentStatus = @{ Name = 'Agent status'; WindowsTarget = '$generatedForPsd1/status'; LinuxTarget = '$generatedForPsd1/status' }
    Agents = @(
        @{ Name = 'claude'; Command = 'pwsh'; Product = 'stand-in'; WindowsInstall = 'x'; LinuxInstall = 'x' }
        @{ Name = 'codex';  Command = 'pwsh'; Product = 'stand-in'; WindowsInstall = 'x'; LinuxInstall = 'x' }
    )
}
"@
$env:WORKSTATION_DECLARED_STATE = $FixturePath

Write-Host ''
Write-Host '  WORKSTATION — STATUS QA' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray
Write-Host "  fixture:    $TempRoot" -ForegroundColor DarkGray

Import-Module $ModulePath -Force -ErrorAction Stop

# ===========================================================================
Set-Group 'Group C1 - the status line command, as Claude runs it'
# ===========================================================================

Confirm-That 'C01' 'the command lives with the Claude assets' (Test-Path -LiteralPath $StatusCommand) $StatusCommand

$statusFile = Join-Path $StatusDir 'shop-qa.lua'
$full = Invoke-StatusCommand -Payload $FullPayload -StatusFile $statusFile
Confirm-That 'C02' 'the line names the model, the context, the session and the week, in that order' `
    ($full.Output -eq 'Fable 5.1  ctx 67k/200k 34%  5h 8%  wk 54%') "printed: '$($full.Output)'"
Confirm-That 'C03' 'the line carries no price, in any spelling' `
    ($full.Output -notmatch '\$|usd|cost|price') $full.Output
Confirm-That 'C04' 'the command exits cleanly' ($full.ExitCode -eq 0) "exit code $($full.ExitCode)"
Confirm-That 'C05' 'the status file is written where the environment says, creating the directory' `
    (Test-Path -LiteralPath $statusFile) $statusFile
Confirm-That 'C06' 'and nothing half-written is left beside it' `
    (@(Get-ChildItem -LiteralPath $StatusDir -Force).Count -eq 1) ((Get-ChildItem -LiteralPath $StatusDir -Force | ForEach-Object Name) -join ', ')

$written = Get-Content -LiteralPath $statusFile -Raw
Confirm-That 'C07' 'the file says it is generated and by whom' ($written -match 'GENERATED' -and $written -match 'statusline') $written
Confirm-That 'C08' 'the file never repeats the cost figure' ($written -notmatch '12\.3456|usd|cost') $written

# The file is read the way WezTerm will read it: as Lua.
$luaFile = ConvertTo-LuaPath $statusFile
$model   = Invoke-StatusLua "status.load('$luaFile').model"
$context = Invoke-StatusLua "status.load('$luaFile').context_percent"
$session = Invoke-StatusLua "status.load('$luaFile').limits.session_percent"
$week    = Invoke-StatusLua "status.load('$luaFile').limits.week_percent"
$reset   = Invoke-StatusLua "status.load('$luaFile').limits.week_resets_at"
$agent   = Invoke-StatusLua "status.load('$luaFile').agent"
$window  = Invoke-StatusLua "status.load('$luaFile').context_window"
Confirm-That 'C09' 'the file is a Lua table carrying the model' ($model -eq 'Fable 5.1') "model: $model"
Confirm-That 'C0A' 'the context percentage, as Claude reported it' ($context -eq '33.6') "context: $context"
Confirm-That 'C0B' 'the session and week percentages' ($session -eq '8.2' -and $week -eq '54.4') "session: $session, week: $week"
Confirm-That 'C0C' 'the reset as the epoch seconds Claude sent' ($reset -eq "$WeekResetEpoch") "reset: $reset"
Confirm-That 'C0D' 'the agent name and the size of the context window' ($agent -eq 'claude' -and $window -eq '200000') "agent: $agent, window: $window"

$writtenAt = [long] (Invoke-StatusLua "status.load('$luaFile').written_at")
$nowEpoch  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Confirm-That 'C0E' 'the file is stamped with the moment it was written, in epoch seconds' `
    ([math]::Abs($nowEpoch - $writtenAt) -lt 120) "written_at: $writtenAt, now: $nowEpoch"

$early = Invoke-StatusCommand -Payload $EarlyPayload -StatusFile $statusFile
Confirm-That 'C10' 'before the first answer the line is the model alone' ($early.Output -eq 'Fable 5.1') "printed: '$($early.Output)'"
$context = Invoke-StatusLua "status.load('$luaFile').context_percent"
$limits  = Invoke-StatusLua "status.load('$luaFile').limits"
Confirm-That 'C11' 'and the file carries no percentage and no limits rather than zeros' `
    ($context -eq 'nil' -and $limits -eq 'nil') "context: $context, limits: $limits"

$unset = Invoke-StatusCommand -Payload $FullPayload -StatusFile ''
$before = (Get-Item -LiteralPath $statusFile).LastWriteTimeUtc
Confirm-That 'C12' 'without WORKSTATION_STATUS_FILE the line still prints and no file is written' `
    ($unset.Output -eq 'Fable 5.1  ctx 67k/200k 34%  5h 8%  wk 54%' -and (Get-Item -LiteralPath $statusFile).LastWriteTimeUtc -eq $before) "printed: '$($unset.Output)'"

$garbage = Invoke-StatusCommand -Payload '{ this is not json' -StatusFile $statusFile
Confirm-That 'C13' 'a payload that is not JSON prints nothing and exits cleanly' `
    ($garbage.Output -eq '' -and $garbage.ExitCode -eq 0) "printed: '$($garbage.Output)', exit $($garbage.ExitCode)"
Confirm-That 'C14' 'and leaves the last good file alone' `
    ((Get-Item -LiteralPath $statusFile).LastWriteTimeUtc -eq $before)

$empty = Invoke-StatusCommand -Payload '' -StatusFile $statusFile
Confirm-That 'C15' 'an empty payload prints nothing and exits cleanly' `
    ($empty.Output -eq '' -and $empty.ExitCode -eq 0) "printed: '$($empty.Output)', exit $($empty.ExitCode)"

$noModel = Invoke-StatusCommand -Payload '{"context_window":{"used_percentage":50}}' -StatusFile $statusFile
Confirm-That 'C16' 'a payload without a model still reports the context, and without a window size as a percentage alone' ($noModel.Output -eq 'ctx 50%') "printed: '$($noModel.Output)'"

$million = Invoke-StatusCommand -Payload '{"context_window":{"context_window_size":1000000,"used_percentage":15}}' -StatusFile $statusFile
Confirm-That 'C18' 'the tokens used are the window times the percentage, in k, over the window in M when it is one' ($million.Output -eq 'ctx 150k/1M 15%') "printed: '$($million.Output)'"
$small = Invoke-StatusCommand -Payload '{"context_window":{"context_window_size":8000,"used_percentage":6.25}}' -StatusFile $statusFile
Confirm-That 'C19' 'and under a thousand tokens are written out' ($small.Output -eq 'ctx 500/8k 6%') "printed: '$($small.Output)'"

$quoted = Invoke-StatusCommand -Payload '{"model":{"display_name":"Say \"hi\"\\now"}}' -StatusFile $statusFile
$model = Invoke-StatusLua "status.load('$luaFile').model"
Confirm-That 'C17' 'a model name with quotes and backslashes survives the trip through Lua' `
    ($model -eq 'Say "hi"\now') "model: $model"

# ===========================================================================
Set-Group 'Group C2 - the Lua module WezTerm renders from'
# ===========================================================================

Confirm-That 'C20' 'the module lives beside the WezTerm configuration' (Test-Path -LiteralPath $StatusLua) $StatusLua

$missing = Invoke-StatusLua "status.load('$(ConvertTo-LuaPath (Join-Path $StatusDir 'absent.lua'))')"
Confirm-That 'C21' 'a missing file loads as nil' ($missing -eq 'nil') $missing
$blank = Invoke-StatusLua "status.load(nil) == nil and status.load('') == nil"
Confirm-That 'C22' 'and so does no path at all' ($blank -eq 'true') $blank

$notLua = Join-Path $StatusDir 'broken.lua'
Set-Content -LiteralPath $notLua -Value 'return {' -Encoding utf8
$broken = Invoke-StatusLua "status.load('$(ConvertTo-LuaPath $notLua)')"
Confirm-That 'C23' 'a half-written file loads as nil rather than failing the status bar' ($broken -eq 'nil') $broken

$fresh = "{ agent = 'claude', model = 'Fable 5.1', context_percent = 33.6, context_window = 200000, limits = { session_percent = 8.2, week_percent = 54.4 }, written_at = 1000 }"
$text = Invoke-StatusLua "status.text($fresh, 1010)"
Confirm-That 'C24' 'a fresh reading renders as the same line the command printed' `
    ($text -eq 'Fable 5.1  ctx 67k/200k 34%  5h 8%  wk 54%') "text: '$text'"
$count = Invoke-StatusLua "#status.segments($fresh, 1010)"
Confirm-That 'C25' 'as four segments' ($count -eq '4') $count

$levels = Invoke-StatusLua "table.concat({ tostring(status.level(69.9)), status.level(70), status.level(89.9), status.level(90), tostring(status.level(nil)) }, ',')"
Confirm-That 'C26' 'a percentage is ok below 70, warn from 70, high from 90, and nothing when absent' `
    ($levels -eq 'ok,warn,warn,high,nil') $levels

$segmentLevels = Invoke-StatusLua "(function() local t = {} for _, s in ipairs(status.segments({ model = 'M', context_percent = 95, limits = { session_percent = 75, week_percent = 10 }, written_at = 1000 }, 1010)) do table.insert(t, s.level) end return table.concat(t, ',') end)()"
Confirm-That 'C27' 'each segment carries its own level' ($segmentLevels -eq 'ok,high,warn,ok') $segmentLevels

$stale = Invoke-StatusLua "status.is_stale({ written_at = 1000 }, 1000 + status.STALE_AFTER_SECONDS + 1)"
$still = Invoke-StatusLua "status.is_stale({ written_at = 1000 }, 1000 + status.STALE_AFTER_SECONDS)"
Confirm-That 'C28' 'a reading goes stale after the module''s own threshold' ($stale -eq 'true' -and $still -eq 'false') "stale: $stale, still fresh: $still"
$staleLevels = Invoke-StatusLua "(function() local t = {} for _, s in ipairs(status.segments($fresh, 1000 + status.STALE_AFTER_SECONDS + 1)) do table.insert(t, s.level) end return table.concat(t, ',') end)()"
Confirm-That 'C29' 'and every segment of a stale reading says so, whatever its percentage' `
    ($staleLevels -eq 'stale,stale,stale,stale') $staleLevels
$noStamp = Invoke-StatusLua "status.is_stale({ model = 'M' }, 1010)"
Confirm-That 'C2A' 'a reading without a stamp is stale' ($noStamp -eq 'true') $noStamp

$partial = Invoke-StatusLua "status.text({ model = 'Fable 5.1', context_percent = 12, written_at = 1000 }, 1010)"
Confirm-That 'C2B' 'without limits the line stops at the context, and without a window it is a percentage alone' ($partial -eq 'Fable 5.1  ctx 12%') "text: '$partial'"
$tokens = Invoke-StatusLua "status.text({ context_percent = 15, context_window = 1000000, written_at = 1000 }, 1010) .. '|' .. status.text({ context_percent = 6.25, context_window = 8000, written_at = 1000 }, 1010) .. '|' .. status.tokens(67200)"
Confirm-That 'C2F' 'the Lua renders the tokens the same way the command does' ($tokens -eq 'ctx 150k/1M 15%|ctx 500/8k 6%|67k') "text: '$tokens'"
$nothing = Invoke-StatusLua "'[' .. status.text(nil, 1010) .. ']' .. #status.segments(nil, 1010)"
Confirm-That 'C2C' 'no reading is an empty line and no segments' ($nothing -eq '[]0') $nothing

$wezterm = Get-Content -LiteralPath $WezTermLua -Raw
Confirm-That 'C2D' 'wezterm.lua loads the module beside it' ($wezterm -match 'dofile\(wezterm\.config_dir \.\. "/status\.lua"\)')
Confirm-That 'C2E' 'and renders it on the update-status event from WORKSTATION_STATUS_FILE' `
    ($wezterm -match 'wezterm\.on\("update-status"' -and $wezterm -match 'WORKSTATION_STATUS_FILE')

# ===========================================================================
Set-Group 'Group C3 - the settings file the install generates'
# ===========================================================================

$realState = Import-PowerShellDataFile -Path (Join-Path $ModulePath 'DeclaredState.psd1')
$realArtifact = @($realState.GeneratedArtifacts | Where-Object { $_.ContainsKey('Kind') -and $_.Kind -eq 'claude-settings' })
Confirm-That 'C30' 'the shipped declared state declares the Claude settings artifact' ($realArtifact.Count -eq 1)
Confirm-That 'C31' 'and where the agent status files live' ($realState.ContainsKey('AgentStatus'))
$preferenceArtifact = @($realState.GeneratedArtifacts | Where-Object { $_.Name -eq 'Resolved preferences' })
Confirm-That 'C32' 'the preference artifact still says what kind it is' `
    ($preferenceArtifact.Count -eq 1 -and $preferenceArtifact[0].Kind -eq 'preferences')

$content = & (Get-Module Workstation) { New-ClaudeSettingsContent }
$parsed  = $null
try { $parsed = $content | ConvertFrom-Json -ErrorAction Stop } catch { }
Confirm-That 'C33' 'the settings content is JSON with a command status line' `
    ($null -ne $parsed -and $parsed.statusLine.type -eq 'command') $content
$command = if ($null -ne $parsed) { [string] $parsed.statusLine.command } else { '' }
Confirm-That 'C34' 'the command runs the shipped script with pwsh, without a profile' `
    ($command -match '^pwsh -NoProfile -NonInteractive -File "' -and $command -match 'code/assets/claude/statusline\.ps1"$') $command
Confirm-That 'C35' 'with forward slashes only, which both shells Claude may use accept' ($command -notmatch '\\') $command
Confirm-That 'C36' 'and nothing else: no other setting reaches the session' `
    ($null -ne $parsed -and @($parsed.PSObject.Properties).Count -eq 1) $content

$settingsPath = Join-Path $GeneratedDir 'claude-settings.json'
$steps = @(& (Get-Module Workstation) { Get-WorkstationStepList })
$settingsStep = @($steps | Where-Object { $_.Kind -eq 'generated' -and $_.Name -eq 'Claude settings' })
Confirm-That 'C37' 'the step list carries the artifact as pending while the file is absent' `
    ($settingsStep.Count -eq 1 -and $settingsStep[0].State -eq 'Pending') (($steps | ForEach-Object { "$($_.Kind)/$($_.Name)/$($_.State)" }) -join ', ')
if ($settingsStep.Count -eq 1 -and $null -ne $settingsStep[0].Action) { & $settingsStep[0].Action }
Confirm-That 'C38' 'applying the step writes the file' (Test-Path -LiteralPath $settingsPath) $settingsPath
$again = @(& (Get-Module Workstation) { Get-WorkstationStepList } | Where-Object { $_.Kind -eq 'generated' -and $_.Name -eq 'Claude settings' })
Confirm-That 'C39' 'and the step is in sync afterwards' ($again.Count -eq 1 -and $again[0].State -eq 'InSync') $again[0].State

# ===========================================================================
Set-Group 'Group C6 - the check sees whether the command those settings name is there'
# ===========================================================================
#
# The settings are generated from a path, and a path is not a promise. A
# stash, a branch switch or a half-finished rename takes the script away
# while the settings still name it; Claude then runs a file that is not
# there, fails, and says nothing, because a status line is not a place for
# an error. Nobody is left to notice but the check.

$commandStep = @(& (Get-Module Workstation) { Get-WorkstationStepList } | Where-Object { $_.Kind -eq 'command' })
Confirm-That 'C60' 'the step list carries the status line command, in sync while the script is there' `
    ($commandStep.Count -eq 1 -and $commandStep[0].State -eq 'InSync' -and $commandStep[0].Name -match '(?i)status line') `
    (($commandStep | ForEach-Object { "$($_.Name)/$($_.State)/$($_.Detail)" }) -join ', ')
Confirm-That 'C61' 'and names the file it is talking about' `
    ($commandStep.Count -eq 1 -and $commandStep[0].Detail -match 'statusline\.ps1') "detail: $($commandStep.Detail)"
Confirm-That 'C62' 'and carries no action: the check reports it, and no apply can write it' `
    ($commandStep.Count -eq 1 -and $null -eq $commandStep[0].Action -and -not $commandStep[0].Required)

$realCommandPath = & (Get-Module Workstation) { $script:ClaudeStatusLinePath }
$absentPath = Join-Path $TempRoot 'gone' 'statusline.ps1'
& (Get-Module Workstation) { param($Path) $script:ClaudeStatusLinePath = $Path } $absentPath

$absentSteps = @(& (Get-Module Workstation) { Get-WorkstationStepList })
$absentStep  = @($absentSteps | Where-Object { $_.Kind -eq 'command' })
Confirm-That 'C63' 'a script the settings name but the checkout no longer has is missing, not in sync' `
    ($absentStep.Count -eq 1 -and $absentStep[0].State -eq 'Missing') `
    (($absentStep | ForEach-Object { "$($_.Name)/$($_.State)" }) -join ', ')
Confirm-That 'C64' 'and the line says where it should be and what stops working without it' `
    ($absentStep.Count -eq 1 -and $absentStep[0].Detail -match [regex]::Escape($absentPath) -and $absentStep[0].Detail -match '(?i)status bar') `
    "detail: $($absentStep.Detail)"

$summary = & (Get-Module Workstation) { param($Steps) Get-StepSummary -Steps $Steps } $absentSteps
Confirm-That 'C65' 'it counts as drift, so the check cannot report the machine in sync' `
    ($summary.Missing -ge 1 -and $summary.Differences -ge 1) "missing: $($summary.Missing); differences: $($summary.Differences)"

$report = @(& (Get-Module Workstation) { param($Steps) Format-StepReport -Steps $Steps } $absentSteps)
Confirm-That 'C66' 'and the report prints it under a heading of its own, in the missing state' `
    (($report -join "`n") -match '(?m)^\s+\[missing\s*\] .*(?i)status line') ($report -join "`n")

& (Get-Module Workstation) { param($Path) $script:ClaudeStatusLinePath = $Path } $realCommandPath
$restored = @(& (Get-Module Workstation) { Get-WorkstationStepList } | Where-Object { $_.Kind -eq 'command' })
Confirm-That 'C67' 'and it is in sync again once the script is back' `
    ($restored.Count -eq 1 -and $restored[0].State -eq 'InSync') $($restored.State)

# ===========================================================================
Set-Group 'Group C4 - what ws hands the agent'
# ===========================================================================

$launch = Invoke-Start @{ Project = $ShopDir }
# The fixture's agents are all pwsh, so the command starts with pwsh.
Confirm-That 'C40' 'a Claude launch carries the generated settings, with forward slashes' `
    ($null -ne $launch.Result -and $launch.Result.AgentCommand -eq ('pwsh --settings "{0}"' -f (ConvertTo-LuaPath $settingsPath))) "command: $($launch.Result.AgentCommand); $($launch.Message)"
Confirm-That 'C41' 'and names the status file after the project, under the declared directory' `
    ($null -ne $launch.Result -and $launch.Result.StatusFile -like (Join-Path $StatusDir 'shop-*.lua')) "status file: $($launch.Result.StatusFile)"

$other = Invoke-Start @{ Project = $ShopDir2 }
Confirm-That 'C42' 'two projects with the same name get different files' `
    ($null -ne $other.Result -and $other.Result.StatusFile -ne $launch.Result.StatusFile -and $other.Result.StatusFile -like (Join-Path $StatusDir 'shop-*.lua')) "$($other.Result.StatusFile)"
$same = Invoke-Start @{ Project = $ShopDir }
Confirm-That 'C43' 'and the same project gets the same file every time' `
    ($null -ne $same.Result -and $same.Result.StatusFile -eq $launch.Result.StatusFile)

$odd = Invoke-Start @{ Project = $OddDir }
$oddName = if ($null -ne $odd.Result) { Split-Path -Leaf $odd.Result.StatusFile } else { '' }
Confirm-That 'C44' 'a project name is reduced to characters every file system takes' `
    ($oddName -match '^[A-Za-z0-9._-]+\.lua$') "file: $oddName"

$codex = Invoke-Start @{ Project = $ShopDir; Agent = 'codex' }
Confirm-That 'C45' 'another agent runs bare: the settings are Claude''s' `
    ($null -ne $codex.Result -and $codex.Result.AgentCommand -eq 'pwsh') "command: $($codex.Result.AgentCommand)"
Confirm-That 'C46' 'but its window still has a status file to read, should it ever write one' `
    ($null -ne $codex.Result -and $codex.Result.StatusFile -eq $launch.Result.StatusFile)

Remove-Item -LiteralPath $settingsPath -Force
$bare = Invoke-Start @{ Project = $ShopDir }
Confirm-That 'C47' 'without the generated settings claude runs bare and a warning says how to fix it' `
    ($null -ne $bare.Result -and $bare.Result.AgentCommand -eq 'pwsh' -and $bare.Warnings -match 'Install-Workstation -Apply') "command: $($bare.Result.AgentCommand); warnings: $($bare.Warnings)"

# ===========================================================================
Set-Group 'Group C5 - uninstalling takes the status files with it'
# ===========================================================================

$removal = @(& (Get-Module Workstation) { Get-WorkstationRemovalList })
$statusStep = @($removal | Where-Object { $_.Name -eq 'Agent status' })
Confirm-That 'C50' 'the removal list names the status directory while it exists' `
    ($statusStep.Count -eq 1 -and $statusStep[0].State -eq 'Pending') (($removal | ForEach-Object { "$($_.Kind)/$($_.Name)/$($_.State)" }) -join ', ')
if ($statusStep.Count -eq 1 -and $null -ne $statusStep[0].Action) { & $statusStep[0].Action }
Confirm-That 'C51' 'applying it removes the directory and every file in it' (-not (Test-Path -LiteralPath $StatusDir))
$gone = @(& (Get-Module Workstation) { Get-WorkstationRemovalList } | Where-Object { $_.Name -eq 'Agent status' })
Confirm-That 'C52' 'and afterwards the step is in sync' ($gone.Count -eq 1 -and $gone[0].State -eq 'InSync') $gone[0].State

# ===========================================================================
Set-Group 'Group C9 - cleanup'
# ===========================================================================

$env:WORKSTATION_DECLARED_STATE = $null
Remove-Module Workstation -Force -ErrorAction SilentlyContinue
if (Test-Path $TempRoot) { Remove-Item -Recurse -Force $TempRoot }
Confirm-That 'C99' 'the fixture is gone' (-not (Test-Path $TempRoot))

# ---------------------------------------------------------------------------
$passed = @($script:Results | Where-Object Passed).Count
$failed = @($script:Results | Where-Object { -not $_.Passed }).Count
Write-Host ''
Write-Host "  passed: $passed" -ForegroundColor Green
Write-Host "  failed: $failed" -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
Write-Host ''
exit $failed
