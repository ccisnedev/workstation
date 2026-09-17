#Requires -Version 7.0
<#
    The status line of the agent pane.

    Lives in the repository at code/assets/claude/statusline.ps1. Claude Code
    runs it on every status update, with a JSON payload on stdin, because the
    settings file Install-Workstation generates names it and `ws` hands that
    file to claude with --settings. The user's own settings.json is never
    touched; see docs/adr/0008.

    It does two things with the payload:

      1. Prints one line for Claude's own bar: the model, the context window
         used, the five-hour limit and the weekly limit, as percentages.

      2. When WORKSTATION_STATUS_FILE names a file, writes the same facts
         there as a Lua table, which the WezTerm status bar reads through
         code/assets/wezterm/status.lua. Start-Workstation sets that variable
         for the window, so every workstation window has its own file.

    It prints no price. The payload carries a cost figure and it is never
    read. It never fails either: whatever happens, it exits zero, because a
    status line that breaks the session is worse than no status line.

    Failing is not the same as saying nothing, though. A payload it cannot
    read is not a failure and prints nothing: Claude sends one before the
    first answer and on every interruption. Anything that actually goes
    wrong is printed on the line Claude shows in the agent's own bar, which
    is already on the screen, because this command runs unattended every few
    hundred milliseconds and has nowhere else to be heard.

    It runs in its own process every few hundred milliseconds, so it imports
    no module and reads nothing but stdin and the environment.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Value {
    <# A nested value of the payload, or $null when any step is missing. #>
    param([AllowNull()] $Object, [string[]] $Path)
    $current = $Object
    foreach ($name in $Path) {
        if ($null -eq $current -or -not ($current -is [System.Collections.IDictionary]) -or -not $current.Contains($name)) { return $null }
        $current = $current[$name]
    }
    return $current
}

function Get-Percent {
    <# A number as a percentage, or $null when it is not a number. #>
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return $null }
    $number = 0.0
    if ([double]::TryParse([string] $Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $number)) { return $number }
    return $null
}

function ConvertTo-LuaString {
    param([string] $Text)
    return '"' + $Text.Replace('\', '\\').Replace('"', '\"').Replace("`n", '\n').Replace("`r", '\r') + '"'
}

function ConvertTo-LuaNumber {
    param([double] $Number)
    return $Number.ToString('0.###', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-TokenText {
    <# A token count as people say it: 500, 67k, 200k, 1M, 1.5M. Mirrors status.lua. #>
    param([double] $Tokens)
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Tokens -ge 1000000) { return ($Tokens / 1000000).ToString('0.#', $invariant) + 'M' }
    if ($Tokens -ge 1000)    { return [math]::Round($Tokens / 1000, [System.MidpointRounding]::AwayFromZero).ToString($invariant) + 'k' }
    return [math]::Round($Tokens, [System.MidpointRounding]::AwayFromZero).ToString($invariant)
}

function Get-ContextText {
    <# "ctx 67k/200k 34%" when the window size is known, "ctx 34%" when not. #>
    param([double] $Percent, [AllowNull()] $Window)
    $rounded = [math]::Round($Percent, [System.MidpointRounding]::AwayFromZero)
    if ($null -ne $Window -and $Window -gt 0) {
        return 'ctx {0}/{1} {2:0}%' -f (ConvertTo-TokenText ($Window * $Percent / 100)), (ConvertTo-TokenText $Window), $rounded
    }
    return 'ctx {0:0}%' -f $rounded
}

# Whether anything has reached the bar yet, so a failure that happens after
# the line was printed is added to it rather than replacing it.
$printed = $false

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

    $payload = $null
    try { $payload = $raw | ConvertFrom-Json -AsHashtable -Depth 20 } catch { exit 0 }
    if (-not ($payload -is [System.Collections.IDictionary])) { exit 0 }

    $model   = Get-Value $payload @('model', 'display_name')
    $context = Get-Percent (Get-Value $payload @('context_window', 'used_percentage'))
    $window  = Get-Percent (Get-Value $payload @('context_window', 'context_window_size'))
    $session = Get-Percent (Get-Value $payload @('rate_limits', 'five_hour', 'used_percentage'))
    $sessionResets = Get-Value $payload @('rate_limits', 'five_hour', 'resets_at')
    $week    = Get-Percent (Get-Value $payload @('rate_limits', 'seven_day', 'used_percentage'))
    $weekResets = Get-Value $payload @('rate_limits', 'seven_day', 'resets_at')
    $sessionId = Get-Value $payload @('session_id')

    # ---- The line for Claude's bar -----------------------------------------
    $parts = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string] $model)) { $parts.Add([string] $model) }
    if ($null -ne $context) { $parts.Add((Get-ContextText -Percent $context -Window $window)) }
    if ($null -ne $session) { $parts.Add(('5h {0:0}%' -f [math]::Round($session, [System.MidpointRounding]::AwayFromZero))) }
    if ($null -ne $week)    { $parts.Add(('wk {0:0}%' -f [math]::Round($week, [System.MidpointRounding]::AwayFromZero))) }
    if ($parts.Count -gt 0) { [Console]::Out.Write(($parts -join '  ')); $printed = $true }

    # ---- The file for the WezTerm status bar --------------------------------
    $statusFile = $env:WORKSTATION_STATUS_FILE
    if ([string]::IsNullOrWhiteSpace($statusFile)) { exit 0 }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('-- GENERATED FILE - DO NOT EDIT')
    $lines.Add('-- Written by code/assets/claude/statusline.ps1 on every status update of')
    $lines.Add('-- the agent in this workstation window, and read by the WezTerm status bar.')
    $lines.Add('return {')
    $lines.Add('  agent = "claude",')
    if (-not [string]::IsNullOrWhiteSpace([string] $model)) { $lines.Add('  model = ' + (ConvertTo-LuaString ([string] $model)) + ',') }
    if (-not [string]::IsNullOrWhiteSpace([string] $sessionId)) { $lines.Add('  session_id = ' + (ConvertTo-LuaString ([string] $sessionId)) + ',') }
    if ($null -ne $context) { $lines.Add('  context_percent = ' + (ConvertTo-LuaNumber $context) + ',') }
    if ($null -ne $window) { $lines.Add('  context_window = ' + (ConvertTo-LuaNumber $window) + ',') }
    if ($null -ne $session -or $null -ne $week) {
        $lines.Add('  limits = {')
        if ($null -ne $session) { $lines.Add('    session_percent = ' + (ConvertTo-LuaNumber $session) + ',') }
        $sessionResetNumber = Get-Percent $sessionResets
        if ($null -ne $sessionResetNumber) { $lines.Add('    session_resets_at = ' + (ConvertTo-LuaNumber $sessionResetNumber) + ',') }
        if ($null -ne $week) { $lines.Add('    week_percent = ' + (ConvertTo-LuaNumber $week) + ',') }
        $weekResetNumber = Get-Percent $weekResets
        if ($null -ne $weekResetNumber) { $lines.Add('    week_resets_at = ' + (ConvertTo-LuaNumber $weekResetNumber) + ',') }
        $lines.Add('  },')
    }
    $lines.Add('  written_at = ' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + ',')
    $lines.Add('}')

    # Written beside its final name and moved into place, so a reader never
    # sees half a file. The move replaces whatever was there.
    $directory = Split-Path -Parent $statusFile
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = "$statusFile.$PID.tmp"
    [System.IO.File]::WriteAllText($temporary, (($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::Move($temporary, $statusFile, $true)
    exit 0
}
catch {
    # The one place a failure can be seen. This command owns the line Claude
    # prints in the agent's bar, and that bar is on the screen already, so
    # the reason goes there: one line, short enough to sit beside what was
    # already known, and never a stack trace. A log file would be a log file
    # nobody opens, and a thrown error would be a silence with extra steps.
    # Unwrapped to the innermost cause: PowerShell wraps a failed method call
    # in a sentence about the method call, which is not the reason and would
    # spend the line's room saying so.
    $cause = $_.Exception
    while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
    $reason = (([string] $cause.Message) -split "`r?`n")[0].Trim()
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'failed' }
    if ($reason.Length -gt 110) { $reason = $reason.Substring(0, 107) + '...' }
    $separator = if ($printed) { '  ' } else { '' }
    [Console]::Out.Write($separator + 'statusline: ' + $reason)
    exit 0
}
