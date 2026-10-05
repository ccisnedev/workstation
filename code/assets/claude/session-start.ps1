#Requires -Version 7.0
<#
    The SessionStart hook of the agent pane.

    Lives in the repository at code/assets/claude/session-start.ps1. Claude
    Code runs it whenever a session begins, with a JSON payload on stdin,
    because the settings file Install-Workstation generates names it and `ws`
    hands that file to claude with --settings. A claude opened by hand never
    sees that file, so it never runs this; see docs/adr/0009.

    It does one thing with the payload: adds its session_id to the shown set,
    the file WORKSTATION_SHOWN_SESSIONS names, one session id per line, which
    `ws -List` reads. The hook has no matcher, so it fires for every source
    Claude reports (startup, resume, clear, compact and fork): what is born in
    a workstation window is shown, and entering a session from one shows it
    again.

    It prints nothing on stdout, ever. Claude Code adds a SessionStart hook's
    stdout to the model's context, so a word printed here would be a word the
    agent reads in its first turn. It never blocks the session either:
    whatever happens, it exits zero and reports the reason on stderr, which
    Claude keeps out of the conversation.

    It runs in its own process at the start of every session, so it imports
    no module and reads nothing but stdin and the environment. Ids of
    sessions Claude has discarded are dropped when it writes, the way
    `ws -Show` drops them, and only when the store can be read: with no
    projects directory to compare against, nothing is dropped.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $raw = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'no payload on stdin' }

    $payload = $null
    try { $payload = $raw | ConvertFrom-Json -AsHashtable -Depth 20 } catch { throw 'the payload is not JSON' }
    if (-not ($payload -is [System.Collections.IDictionary])) { throw 'the payload is not a JSON object' }

    $sessionId = if ($payload.Contains('session_id')) { $payload['session_id'] } else { $null }
    if (-not ($sessionId -is [string]) -or [string]::IsNullOrWhiteSpace($sessionId)) { throw 'the payload has no session_id' }
    $sessionId = $sessionId.Trim()

    $shownFile = $env:WORKSTATION_SHOWN_SESSIONS
    if ([string]::IsNullOrWhiteSpace($shownFile)) { throw 'WORKSTATION_SHOWN_SESSIONS is not set, so there is no shown set to add to' }

    $ids = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $shownFile -PathType Leaf) {
        foreach ($line in [System.IO.File]::ReadAllLines($shownFile)) {
            $id = $line.Trim()
            if ($id.Length -gt 0 -and -not $ids.Contains($id)) { $ids.Add($id) }
        }
    }
    if (-not $ids.Contains($sessionId)) { $ids.Add($sessionId) }

    # Claude has not written this session's transcript yet, so the new id is
    # kept whatever the store says; every other id must still have one.
    $configDirectory = if ([string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) { Join-Path $HOME '.claude' } else { $env:CLAUDE_CONFIG_DIR }
    $projectsRoot = Join-Path $configDirectory 'projects'
    if (Test-Path -LiteralPath $projectsRoot -PathType Container) {
        $known = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($file in Get-ChildItem -LiteralPath $projectsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction Ignore) { [void] $known.Add($file.BaseName) }
        $kept = [System.Collections.Generic.List[string]]::new()
        foreach ($id in $ids) { if ($id -eq $sessionId -or $known.Contains($id)) { $kept.Add($id) } }
        $ids = $kept
    }

    # Written beside its final name and moved into place, so a reader never
    # sees half a file. The move replaces whatever was there.
    $directory = Split-Path -Parent $shownFile
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $temporary = "$shownFile.$PID.tmp"
    try {
        [System.IO.File]::WriteAllText($temporary, (($ids -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($temporary, $shownFile, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction Ignore }
    }
    exit 0
}
catch {
    # Unwrapped to the innermost cause, as the status line does, and kept to
    # one line: stderr is for a person who goes looking, and a stack trace is
    # not what they are looking for.
    $cause = $_.Exception
    while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
    $reason = (([string] $cause.Message) -split "`r?`n")[0].Trim()
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'failed' }
    if ($reason.Length -gt 200) { $reason = $reason.Substring(0, 197) + '...' }
    [Console]::Error.WriteLine('session-start: ' + $reason)
    exit 0
}
