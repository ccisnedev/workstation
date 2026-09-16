#Requires -Version 7.0
<#
    QA for reading how much of each agent's plan is used, and when it resets.
    Runs on Windows, Linux and macOS, and needs nothing but PowerShell.

    The contract under test:

        Get-WorkstationUsage                one row per agent that declares a usage provider
        Get-WorkstationUsage -Agent codex   one agent; an agent without a provider says so
        ws -Usage [-Agent x] [-PassThru]    the same, printed as a report

    Every row carries the account and plan, where the reading came from and
    when, and one entry per limit: a name, a percentage used, and when it
    resets. Nothing is ever a price: the plans are flat, so a percentage is
    the whole truth and a dollar figure would be a guess.

    Claude's numbers come from the endpoint its own /usage reads, called with
    the token in its credentials file; the call is made through one seam the
    suite replaces, so nothing here reaches the network and no real token is
    read. Codex's numbers are the last reading its CLI wrote into a rollout
    under CODEX_HOME, which is why they can be old, and why the row says how
    old. Both homes are fixtures.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code/powershell/Workstation'
$TempRoot       = Join-Path ([System.IO.Path]::GetTempPath()) 'qa-workstation-usage'
$ClaudeHome     = Join-Path $TempRoot 'claude-home'
$CodexHome      = Join-Path $TempRoot 'codex-home'
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

# Runs the command, keeps its complaints, and returns rows and complaints.
function Invoke-Usage {
    param([hashtable] $Arguments = @{})
    $errors = $null
    $rows = @()
    if (Get-Command Get-WorkstationUsage -ErrorAction Ignore) {
        $rows = @(Get-WorkstationUsage @Arguments -ErrorAction SilentlyContinue -ErrorVariable errors -WarningAction SilentlyContinue)
    }
    return [PSCustomObject]@{
        Rows    = $rows
        Errors  = @($errors)
        Message = (@($errors) | ForEach-Object { $_.ToString() }) -join ' '
    }
}
function Get-Row   { param([object[]] $Rows, [string] $Agent) return ($Rows | Where-Object { $_.Agent -eq $Agent } | Select-Object -First 1) }
function Get-Limit { param($Row, [string] $Name) if ($null -eq $Row) { return $null }; return (@($Row.Limits) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1) }
function Get-First { param($Row) if ($null -eq $Row) { return $null }; return (@($Row.Limits) | Select-Object -First 1) }
function Format-Limits { param($Row) if ($null -eq $Row) { return '(no row)' }; return (@($Row.Limits | ForEach-Object { "$($_.Name)=$($_.Percent)" }) -join ', ') }
function Invoke-Report {
    param([hashtable] $Arguments = @{})
    if (-not (Get-Command Start-Workstation -ErrorAction Ignore)) { return '' }
    try { return (Start-Workstation -Usage @Arguments -ErrorAction SilentlyContinue 6>&1 | Out-String) } catch { return "threw: $_" }
}
function ConvertTo-Base64Url { param([string] $Text)
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
function Set-ClaudeCredentials { param([long] $ExpiresAtMs)
    $credentials = @{ claudeAiOauth = @{ accessToken = 'qa-token-that-is-not-real'; refreshToken = 'qa-refresh'; expiresAt = $ExpiresAtMs; subscriptionType = 'max'; scopes = @('user:profile') } }
    Set-Content -LiteralPath (Join-Path $ClaudeHome '.credentials.json') -Value ($credentials | ConvertTo-Json -Depth 5) -Encoding utf8
}

# ---------------------------------------------------------------------------
#  Fixture: a Claude home, a Codex home, a declared state, a fake endpoint
# ---------------------------------------------------------------------------
if (Test-Path $TempRoot) { Remove-Item -Recurse -Force $TempRoot }
New-Item -ItemType Directory -Force -Path $ClaudeHome, $CodexHome | Out-Null

# Claude: a credentials file with a token that expires in an hour, and the
# account file Claude keeps beside its configuration. That file also indexes
# projects by path, and a real one holds two keys that differ only in case,
# which the usual JSON conversion refuses; the fixture carries that pair.
$NowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
Set-ClaudeCredentials -ExpiresAtMs ($NowMs + 3600000)
Set-Content -LiteralPath (Join-Path $ClaudeHome '.claude.json') -Encoding utf8 -Value '{"oauthAccount":{"accountUuid":"x","emailAddress":"claude-qa@example.test","organizationType":"claude_max"},"numStartups":3,"projects":{"c:/qa/shop":{"allowedTools":[]},"C:/qa/shop":{"allowedTools":[]}}}'

# What the endpoint answers: a session limit, the weekly limit, and the
# model-scoped weekly limit that mirrors it. resets_at is what the server
# sends, an ISO instant with an offset.
$ClaudeSessionReset = '2026-09-15T19:00:00.000000+00:00'
$ClaudeWeekReset    = '2026-09-21T01:00:00.000000+00:00'
$ClaudeAnswer = @{
    limits = @(
        @{ kind = 'session';       percent = 22; resets_at = $ClaudeSessionReset; scope = $null }
        @{ kind = 'weekly_all';    percent = 43; resets_at = $ClaudeWeekReset;    scope = $null }
        @{ kind = 'weekly_scoped'; percent = 43; resets_at = $ClaudeWeekReset;    scope = @{ model = @{ display_name = 'Fable' } } }
    )
    seven_day_breakdown = @{ rows = @(@{ display_name = 'Claude Code'; percent = 100 }) }
}
$script:HttpCalls   = [System.Collections.Generic.List[object]]::new()
$script:HttpAnswer  = $ClaudeAnswer
$script:HttpFailure = $null
# Defined here, in the suite's own scope, so that when the module invokes it
# the recording lands where the assertions can read it.
$FakeWebRequest = {
    param([string] $Uri, [hashtable] $Headers)
    $script:HttpCalls.Add([PSCustomObject]@{ Uri = $Uri; Headers = $Headers })
    if ($null -ne $script:HttpFailure) { throw $script:HttpFailure }
    return ($script:HttpAnswer | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
}

# Codex: an auth file whose id token names the account and plan, and two
# rollouts. The newer file holds, in this order: the session header, a line
# that is not JSON, a token count with no limits, the main limit at 93 %, the
# Spark pool at 0 %, and the main limit again at 99 %, which is the reading.
# The older file says 50 % and must lose on time, not on file order.
$JwtPayload = ConvertTo-Base64Url '{"email":"codex-qa@example.test","https://api.openai.com/auth":{"chatgpt_plan_type":"pro"}}'
Set-Content -LiteralPath (Join-Path $CodexHome 'auth.json') -Encoding utf8 -Value ('{{"auth_mode":"chatgpt","tokens":{{"id_token":"{0}.{1}.qa-signature","access_token":"qa"}}}}' -f (ConvertTo-Base64Url '{"alg":"RS256"}'), $JwtPayload)

$MainResetEpoch  = 1789805519     # Fri 19/09/2026 08:11 UTC
$SparkResetEpoch = 1789451545     # a 5 h window
$SparkWeekEpoch  = 1790038345
$T1 = '2026-09-15T02:50:00.000Z'; $T2 = '2026-09-15T02:55:00.000Z'; $T3 = '2026-09-15T02:59:00.000Z'
function New-Reading { param([string] $When, [string] $LimitId, [string] $LimitName, [double] $Percent, [int] $Window, [long] $Reset, [string] $Secondary = 'null')
    $name = if ($LimitName) { '"' + $LimitName + '"' } else { 'null' }
    return ('{{"timestamp":"{0}","type":"event_msg","payload":{{"type":"token_count","info":{{"total_token_usage":{{"input_tokens":10,"output_tokens":5}}}},"rate_limits":{{"limit_id":"{1}","limit_name":{2},"plan_type":"pro","primary":{{"used_percent":{3},"window_minutes":{4},"resets_at":{5}}},"secondary":{6},"rate_limit_reached_type":null}}}}}}' -f $When, $LimitId, $name, $Percent, $Window, $Reset, $Secondary)
}
$OldDir = Join-Path $CodexHome 'sessions/2026/09/14'
$NewDir = Join-Path $CodexHome 'sessions/2026/09/15'
New-Item -ItemType Directory -Force -Path $OldDir, $NewDir | Out-Null
$OldRollout = Join-Path $OldDir 'rollout-2026-09-14T20-00-00-old.jsonl'
$NewRollout = Join-Path $NewDir 'rollout-2026-09-15T14-49-00-new.jsonl'
Set-Content -LiteralPath $OldRollout -Encoding utf8 -Value (New-Reading '2026-09-14T20:00:00.000Z' 'codex' '' 50 10080 $MainResetEpoch)
$sparkSecondary = ('{{"used_percent":0,"window_minutes":10080,"resets_at":{0}}}' -f $SparkWeekEpoch)
Set-Content -LiteralPath $NewRollout -Encoding utf8 -Value (@(
    '{"timestamp":"2026-09-15T02:49:00.000Z","type":"session_meta","payload":{"id":"qa","cwd":"C:\\qa","originator":"codex_exec","model_provider":"openai"}}'
    '{ not json, and must not break the reading'
    '{"timestamp":"2026-09-15T02:49:30.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}'
    (New-Reading $T1 'codex' '' 93 10080 $MainResetEpoch)
    (New-Reading $T2 'codex_bengalfox' 'GPT-5.3-Codex-Spark' 0 300 $SparkResetEpoch $sparkSecondary)
    (New-Reading $T3 'codex' '' 99 10080 $MainResetEpoch)
) -join "`n")
(Get-Item $OldRollout).LastWriteTime = (Get-Date).AddHours(-20)
(Get-Item $NewRollout).LastWriteTime = (Get-Date).AddMinutes(-5)

# A declared state: two agents with a provider each, one without.
Set-Content -LiteralPath $FixturePath -Encoding utf8 -Value @"
@{
    Name = 'qa-usage'; Version = '0.0.0'; Description = 'fixture'
    Tools = @(
        @{ Name = 'Stand-in terminal'; Purpose = 'Terminal'; Command = 'pwsh'; Required = `$true; Role = 'terminal'
           WindowsInstall = 'x'; LinuxInstall = 'x' }
    )
    Links = @()
    PowerShellProfile = @{ Name = 'qa profile'; OpenMarker = '# >>> qa >>>'; CloseMarker = '# <<< qa <<<' }
    Agents = @(
        @{ Name = 'claude';      Command = 'pwsh'; Product = 'stand-in'; WindowsInstall = 'x'; LinuxInstall = 'x'; UsageProvider = 'claude' }
        @{ Name = 'codex';       Command = 'pwsh'; Product = 'stand-in'; WindowsInstall = 'x'; LinuxInstall = 'x'; UsageProvider = 'codex' }
        @{ Name = 'antigravity'; Command = 'pwsh'; Product = 'stand-in'; WindowsInstall = 'x'; LinuxInstall = 'x' }
    )
}
"@
$env:WORKSTATION_DECLARED_STATE = $FixturePath
$env:CLAUDE_CONFIG_DIR = $ClaudeHome
$env:CODEX_HOME        = $CodexHome

Write-Host ''
Write-Host '  WORKSTATION - USAGE QA' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray
Write-Host "  fixture:    $TempRoot" -ForegroundColor DarkGray

Import-Module $ModulePath -Force -ErrorAction Stop
& (Get-Module Workstation) { param($Fake) $script:UsageWebRequest = $Fake } $FakeWebRequest

# ===========================================================================
Set-Group 'Group U1 - the command, and the shape of what it returns'

Confirm-That 'U01' 'Get-WorkstationUsage is exported' ($null -ne (Get-Command Get-WorkstationUsage -ErrorAction Ignore))
Confirm-That 'U02' 'ws has a -Usage parameter set' `
    (@((Get-Command Start-Workstation).ParameterSets | Where-Object { $_.Name -eq 'Usage' }).Count -eq 1)

$all = Invoke-Usage
$agentList = @($all.Rows | ForEach-Object { $_.Agent }) -join ','
Confirm-That 'U03' 'by default there is one row per agent with a provider, in declared order' ($agentList -eq 'claude,codex') "rows: $agentList; errors: $($all.Message)"
$expectedMembers = @('Agent', 'Account', 'Plan', 'Source', 'ReadAt', 'Reason', 'Limits')
$missingMembers = @()
foreach ($row in $all.Rows) {
    $names = @($row.PSObject.Properties.Name)
    $missingMembers += @($expectedMembers | Where-Object { $_ -notin $names })
}
Confirm-That 'U04' 'every row has Agent, Account, Plan, Source, ReadAt, Reason and Limits' ($all.Rows.Count -gt 0 -and $missingMembers.Count -eq 0) "missing: $($missingMembers -join ', ')"
$limitMembers = @('Name', 'Percent', 'ResetsAt')
$badLimits = @($all.Rows | ForEach-Object { @($_.Limits) } | Where-Object { $l = $_; @($limitMembers | Where-Object { $_ -notin @($l.PSObject.Properties.Name) }).Count -gt 0 })
Confirm-That 'U05' 'every limit has Name, Percent and ResetsAt' ($all.Rows.Count -gt 0 -and $badLimits.Count -eq 0)
$prices = @($all.Rows | ForEach-Object { @($_.PSObject.Properties.Name) + @($_.Limits | ForEach-Object { @($_.PSObject.Properties.Name) }) } | Where-Object { $_ -match '(?i)cost|price|usd|dollar' })
Confirm-That 'U06' 'nothing in a row is a price' ($prices.Count -eq 0) "found: $($prices -join ', ')"

# ===========================================================================
Set-Group 'Group U2 - Claude: the endpoint its own /usage reads'

$claude = Get-Row $all.Rows 'claude'
Confirm-That 'U10' 'the Claude reading is live' ($null -ne $claude -and $claude.Source -eq 'live') "row: $($claude | Out-String)"
Confirm-That 'U11' 'the account is the one in the account file, whose project keys differ only in case' ($null -ne $claude -and $claude.Account -eq 'claude-qa@example.test' -and $all.Errors.Count -eq 0) "errors: $($all.Message)"
Confirm-That 'U12' 'the plan is the subscription in the credentials' ($null -ne $claude -and $claude.Plan -eq 'max')
$session = Get-Limit $claude 'Session (5h)'
$week    = Get-Limit $claude 'Week'
Confirm-That 'U13' 'the session limit is named and read' ($null -ne $session -and $session.Percent -eq 22) "limits: $(Format-Limits $claude)"
Confirm-That 'U14' 'the weekly limit is named and read' ($null -ne $week -and $week.Percent -eq 43)
Confirm-That 'U15' 'the model-scoped weekly limit, which mirrors the weekly one, is not a third row' ($null -ne $claude -and @($claude.Limits).Count -eq 2)
$expectedWeekReset = [DateTimeOffset]::Parse($ClaudeWeekReset, [cultureinfo]::InvariantCulture).LocalDateTime
Confirm-That 'U16' 'a reset is a local DateTime, converted from the instant the server sent' `
    ($null -ne $week -and $week.ResetsAt -is [datetime] -and $week.ResetsAt -eq $expectedWeekReset) "expected: $expectedWeekReset"
Confirm-That 'U17' 'the reading is stamped now' ($null -ne $claude -and $claude.ReadAt -is [datetime] -and ((Get-Date) - $claude.ReadAt).TotalSeconds -lt 60)
$call = $script:HttpCalls | Select-Object -Last 1
Confirm-That 'U18' 'the endpoint is called with the bearer token and the oauth beta header' `
    ($null -ne $call -and $call.Headers['Authorization'] -eq 'Bearer qa-token-that-is-not-real' -and $call.Headers['anthropic-beta'] -match 'oauth' -and $call.Uri -match 'api\.anthropic\.com/api/oauth/usage')
$printed = Invoke-Report
Confirm-That 'U19' 'the printed report never shows the token' ($printed -notmatch 'qa-token')
Confirm-That 'U1A' 'the printed report shows the account, the percentages and the resets' `
    ($printed -match 'claude-qa@example\.test' -and $printed -match '22\s*%' -and $printed -match '43\s*%' -and $printed -match '(?i)resets') "printed: $printed"

# ===========================================================================
Set-Group 'Group U3 - Claude when it cannot be read: a state, never an error'

$script:HttpCalls.Clear()
Set-ClaudeCredentials -ExpiresAtMs ($NowMs - 1000)
$expired = Invoke-Usage @{ Agent = 'claude' }
$row = Get-Row $expired.Rows 'claude'
Confirm-That 'U20' 'an expired sign-in is unavailable, says so, and costs no call' `
    ($null -ne $row -and $row.Source -eq 'unavailable' -and $row.Reason -match '(?i)expired' -and $row.Reason -match 'claude' -and $script:HttpCalls.Count -eq 0 -and @($row.Limits).Count -eq 0) `
    "row: $($row | Out-String); calls: $($script:HttpCalls.Count)"
Confirm-That 'U21' 'and the account is still named, so the row says whose sign-in it is' ($null -ne $row -and $row.Account -eq 'claude-qa@example.test')
Confirm-That 'U22' 'and nothing was written as an error' ($expired.Errors.Count -eq 0) $expired.Message

Remove-Item -LiteralPath (Join-Path $ClaudeHome '.credentials.json')
$signedOut = Invoke-Usage @{ Agent = 'claude' }
$row = Get-Row $signedOut.Rows 'claude'
Confirm-That 'U23' 'no credentials file is "not signed in", with no call and no error' `
    ($null -ne $row -and $row.Source -eq 'unavailable' -and $row.Reason -match '(?i)not signed in' -and $script:HttpCalls.Count -eq 0 -and $signedOut.Errors.Count -eq 0) "row: $($row | Out-String)"

Set-ClaudeCredentials -ExpiresAtMs ($NowMs + 3600000)
$script:HttpFailure = 'connection refused (qa)'
$down = Invoke-Usage @{ Agent = 'claude' }
$row = Get-Row $down.Rows 'claude'
Confirm-That 'U24' 'an endpoint failure is unavailable and carries the failure, with no error record' `
    ($null -ne $row -and $row.Source -eq 'unavailable' -and $row.Reason -match 'connection refused' -and $down.Errors.Count -eq 0) "row: $($row | Out-String); errors: $($down.Message)"
$script:HttpFailure = $null

Remove-Item -LiteralPath (Join-Path $ClaudeHome '.claude.json')
$noAccount = Invoke-Usage @{ Agent = 'claude' }
$row = Get-Row $noAccount.Rows 'claude'
Confirm-That 'U25' 'without the account file the reading is still live and the account is simply unknown' `
    ($null -ne $row -and $row.Source -eq 'live' -and $null -eq $row.Account -and @($row.Limits).Count -eq 2) "row: $($row | Out-String)"
Set-Content -LiteralPath (Join-Path $ClaudeHome '.claude.json') -Encoding utf8 -Value '{"oauthAccount":{"emailAddress":"claude-qa@example.test"}}'

# ===========================================================================
Set-Group 'Group U4 - Codex: the last reading its CLI wrote'

$codex = Get-Row $all.Rows 'codex'
Confirm-That 'U30' 'the Codex reading comes from a rollout' ($null -ne $codex -and $codex.Source -eq 'rollout') "row: $($codex | Out-String)"
Confirm-That 'U31' 'the account is the one in the auth file' ($null -ne $codex -and $codex.Account -eq 'codex-qa@example.test')
Confirm-That 'U32' 'the plan is the one in the auth file' ($null -ne $codex -and $codex.Plan -eq 'pro')
$main = Get-First $codex
Confirm-That 'U33' 'the first limit is the weekly limit of the plan, at its newest reading' `
    ($null -ne $main -and $main.Name -eq 'Week' -and $main.Percent -eq 99) "limits: $(Format-Limits $codex)"
$expectedMainReset = [DateTimeOffset]::FromUnixTimeSeconds($MainResetEpoch).LocalDateTime
Confirm-That 'U34' 'its reset is a local DateTime from the epoch seconds Codex writes' ($null -ne $main -and $main.ResetsAt -is [datetime] -and $main.ResetsAt -eq $expectedMainReset) "expected: $expectedMainReset"
$expectedReadAt = [DateTimeOffset]::Parse($T3, [cultureinfo]::InvariantCulture).LocalDateTime
Confirm-That 'U35' 'the reading is stamped with the time of that newest reading, not now' ($null -ne $codex -and $codex.ReadAt -eq $expectedReadAt) "expected: $expectedReadAt"
$spark = @()
if ($null -ne $codex) { $spark = @($codex.Limits | Where-Object { $_.Name -match 'Spark' }) }
Confirm-That 'U36' 'the Spark pool is two more limits, named after the pool, at 0 %' `
    ($spark.Count -eq 2 -and @($spark | Where-Object { $_.Name -match '(?i)5h' }).Count -eq 1 -and @($spark | Where-Object { $_.Name -match '(?i)week' }).Count -eq 1 -and @($spark | Where-Object { $_.Percent -ne 0 }).Count -eq 0) `
    "spark: $(@($spark | ForEach-Object { "$($_.Name)=$($_.Percent)" }) -join ', ')"
Confirm-That 'U37' 'a line that is not JSON and a count without limits are ignored, not errors' ($null -ne $codex -and $all.Errors.Count -eq 0 -and @($codex.Limits).Count -eq 3) "errors: $($all.Message)"

(Get-Item $OldRollout).LastWriteTime = (Get-Date)
$reordered = Invoke-Usage @{ Agent = 'codex' }
$row = Get-Row $reordered.Rows 'codex'
$first = Get-First $row
Confirm-That 'U38' 'a file touched later does not win: the newest reading is by its timestamp' ($null -ne $first -and $first.Percent -eq 99) "limits: $(Format-Limits $row)"
$printedCodex = Invoke-Report @{ Agent = 'codex' }
Confirm-That 'U39' 'the printed report says how old the reading is' ($printedCodex -match '(?i)ago' -and $printedCodex -match '99\s*%') "printed: $printedCodex"

# ===========================================================================
Set-Group 'Group U5 - Codex when there is nothing to read'

Remove-Item -LiteralPath (Join-Path $CodexHome 'auth.json')
$noAuth = Invoke-Usage @{ Agent = 'codex' }
$row = Get-Row $noAuth.Rows 'codex'
Confirm-That 'U40' 'without the auth file the account is unknown and the plan comes from the reading' `
    ($null -ne $row -and $row.Source -eq 'rollout' -and $null -eq $row.Account -and $row.Plan -eq 'pro') "row: $($row | Out-String)"

Rename-Item -LiteralPath (Join-Path $CodexHome 'sessions') -NewName 'sessions-aside'
$noSessions = Invoke-Usage @{ Agent = 'codex' }
$row = Get-Row $noSessions.Rows 'codex'
Confirm-That 'U41' 'with no rollouts it is unavailable, names Codex, and is not an error' `
    ($null -ne $row -and $row.Source -eq 'unavailable' -and $row.Reason -match '(?i)codex' -and $noSessions.Errors.Count -eq 0 -and @($row.Limits).Count -eq 0) "row: $($row | Out-String); errors: $($noSessions.Message)"
Rename-Item -LiteralPath (Join-Path $CodexHome 'sessions-aside') -NewName 'sessions'

# ===========================================================================
Set-Group 'Group U6 - choosing an agent, and the ws front'

$one = Invoke-Usage @{ Agent = 'codex' }
Confirm-That 'U50' '-Agent narrows to that agent' (@($one.Rows).Count -eq 1 -and $one.Rows[0].Agent -eq 'codex')
$none = Invoke-Usage @{ Agent = 'antigravity' }
$row = Get-Row $none.Rows 'antigravity'
Confirm-That 'U51' 'an agent without a provider is a row that says so, not an error' `
    ($null -ne $row -and $row.Source -eq 'unsupported' -and $row.Reason -match 'antigravity' -and $none.Errors.Count -eq 0) "row: $($row | Out-String)"
$unknown = Invoke-Usage @{ Agent = 'no-such-agent' }
Confirm-That 'U52' 'an agent that is not declared is an error, with no rows' (@($unknown.Rows).Count -eq 0 -and $unknown.Message -match 'no-such-agent') "message: $($unknown.Message)"
$viaWs = @()
if (Get-Command Start-Workstation -ErrorAction Ignore) {
    try { $viaWs = @(Start-Workstation -Usage -PassThru -ErrorAction SilentlyContinue 6>$null) } catch { $viaWs = @() }
}
Confirm-That 'U53' 'ws -Usage -PassThru returns the same rows' ((@($viaWs | ForEach-Object { $_.Agent }) -join ',') -eq 'claude,codex')
$mixed = $null
try { Start-Workstation -Usage -Session 3 -ErrorAction Stop 6>$null | Out-Null } catch { $mixed = $_ }
Confirm-That 'U54' 'ws -Usage refuses -Session beside it' ($null -ne $mixed)
$mixedList = $null
try { Start-Workstation -Usage -List -ErrorAction Stop 6>$null | Out-Null } catch { $mixedList = $_ }
Confirm-That 'U55' 'and refuses -List beside it' ($null -ne $mixedList)
$before = @(Get-Process pwsh -ErrorAction Ignore | ForEach-Object { $_.Id })
Invoke-Report | Out-Null
$after = @(Get-Process pwsh -ErrorAction Ignore | ForEach-Object { $_.Id })
Confirm-That 'U56' 'ws -Usage opens nothing' (@($after | Where-Object { $_ -notin $before }).Count -eq 0)

# ===========================================================================
Set-Group 'Cleanup'
$env:CLAUDE_CONFIG_DIR = $null
$env:CODEX_HOME = $null
$env:WORKSTATION_DECLARED_STATE = $null
Remove-Module Workstation -Force -ErrorAction Ignore
Remove-Item -Recurse -Force $TempRoot -ErrorAction Ignore
Confirm-That 'U99' 'the fixture is gone' (-not (Test-Path $TempRoot))

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
