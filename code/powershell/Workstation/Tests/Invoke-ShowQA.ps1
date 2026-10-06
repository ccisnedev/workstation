#Requires -Version 7.0
<#
    QA for choosing which Claude sessions `ws -List` shows. Runs on Windows,
    Linux and macOS, and needs nothing but PowerShell.

    The contract under test:

        ws -List [-Limit n]     only the sessions that are shown
        ws -List -All           every session, shown ones marked
        ws -Show [<n|id>]       show a session; no argument means the session
                                of the agent pane in this window
        ws -Hide [<n|id>]       the reverse, with the same three forms

        A session is shown when it starts in a ws window: the generated
        Claude settings declare a SessionStart hook, code/assets/claude/
        session-start.ps1, which adds the session's id to the shown set.

    The shown set is one file, one session id per line, named by
    WORKSTATION_SHOWN_SESSIONS (the seam, set for the ws window by
    Start-Workstation and by this suite for itself). Claude's own store is
    read and never written, which the suite proves by taking a snapshot of the
    fake Claude home before and after. No suite step opens a window or reads
    the real ~/.claude or the real shown set.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code/powershell/Workstation'
$HookScript     = Join-Path $RepositoryRoot 'code/assets/claude/session-start.ps1'
$StatusScript   = Join-Path $RepositoryRoot 'code/assets/claude/statusline.ps1'
$TempRoot       = Join-Path ([System.IO.Path]::GetTempPath()) 'qa-workstation-show'
$ClaudeHome     = Join-Path $TempRoot 'claude-home'
$StateDir       = Join-Path $TempRoot 'state'
$ShownFile      = Join-Path $StateDir 'shown-sessions.txt'
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

# Runs Start-Workstation, swallows its errors, and returns what it produced,
# what it printed and what it complained about, so an assertion can look at
# all three.
function Invoke-Ws {
    param([hashtable] $Arguments)
    $errors = $null
    $all = @(Start-Workstation @Arguments -PassThru -ErrorAction SilentlyContinue -ErrorVariable errors -WarningAction SilentlyContinue 6>&1 2>$null)
    $printed = ($all | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { $_.MessageData.Message }) -join "`n"
    return [PSCustomObject]@{
        Result  = @($all | Where-Object { $_ -isnot [System.Management.Automation.InformationRecord] })
        Printed = $printed
        Errors  = @($errors)
        Message = (@($errors) | ForEach-Object { $_.ToString() }) -join ' '
    }
}

function Get-Shown {
    if (-not (Test-Path -LiteralPath $ShownFile -PathType Leaf)) { return @() }
    return @([System.IO.File]::ReadAllLines($ShownFile) | Where-Object { $_ -ne '' })
}
function Set-Shown { param([string[]] $Ids)
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    [System.IO.File]::WriteAllText($ShownFile, ((@($Ids) -join "`n") + $(if (@($Ids).Count -gt 0) { "`n" } else { '' })), [System.Text.UTF8Encoding]::new($false))
}
function Get-FileHashOf { param([string] $Path) return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

# A picture of a directory tree: every file with its size, time and hash, so a
# change, an addition or a removal anywhere under it shows.
function Get-TreeSnapshot { param([string] $Root)
    return (@(Get-ChildItem -LiteralPath $Root -Recurse -Force | ForEach-Object {
        if ($_.PSIsContainer) { 'D ' + $_.FullName }
        else { 'F {0} {1} {2} {3}' -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks, (Get-FileHashOf $_.FullName) }
    }) | Sort-Object) -join "`n"
}

# Runs the hook the way Claude Code does: a fresh process, the payload on
# stdin, the shown set named by the environment. Standard output and error are
# kept apart, because the first is added to Claude's context and the second is
# not.
function Start-HookProcess {
    param([AllowNull()][string] $Payload, [AllowNull()][string] $StateFile, [hashtable] $Environment = @{}, [string] $Script = $HookScript)
    $info = [System.Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $Script)) { $info.ArgumentList.Add($argument) }
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    if ($null -ne $StateFile) { $info.Environment['WORKSTATION_SHOWN_SESSIONS'] = $StateFile } else { $info.Environment.Remove('WORKSTATION_SHOWN_SESSIONS') | Out-Null }
    $info.Environment['CLAUDE_CONFIG_DIR'] = $ClaudeHome
    foreach ($key in $Environment.Keys) { $info.Environment[$key] = [string] $Environment[$key] }
    $process = [System.Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
    if ($null -ne $Payload) { $process.StandardInput.Write($Payload) }
    $process.StandardInput.Close()
    return [PSCustomObject]@{ Process = $process; OutTask = $outTask; ErrTask = $errTask }
}
function Wait-HookProcess {
    param($Handle)
    $Handle.Process.WaitForExit()
    return [PSCustomObject]@{ Stdout = $Handle.OutTask.Result; Stderr = $Handle.ErrTask.Result; ExitCode = $Handle.Process.ExitCode }
}
function Invoke-Hook {
    param([AllowNull()][string] $Payload, [AllowNull()][string] $StateFile, [hashtable] $Environment = @{})
    return (Wait-HookProcess (Start-HookProcess -Payload $Payload -StateFile $StateFile -Environment $Environment))
}

# Holds the lock the shown set is edited under, the way a writer does, so a
# suite can show what another writer does while it is held.
function Lock-ShownFile {
    param([string] $Path)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    return [System.IO.File]::Open("$Path.lock", [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
}

# ---------------------------------------------------------------------------
#  Fixture: a Claude home, and a declared state
# ---------------------------------------------------------------------------
if (Test-Path $TempRoot) { Remove-Item -Recurse -Force $TempRoot }
New-Item -ItemType Directory -Force -Path $TempRoot, $StateDir | Out-Null

$ShopDir = Join-Path $TempRoot 'shop'
$ApiDir  = Join-Path $TempRoot 'billing-api'
$GoneDir = Join-Path $TempRoot 'gone-project'
foreach ($d in @($ShopDir, $ApiDir)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$S1 = '11111111-1111-4111-8111-111111111111'   # shop
$S2 = '22222222-2222-4222-8222-222222222222'   # billing-api
$S3 = '33333333-3333-4333-8333-333333333333'   # shop, but its transcript is gone: retention took it
$S4 = '44444444-4444-4444-8444-444444444444'   # a directory that no longer exists
$S5 = '55555555-5555-4555-8555-555555555555'   # shop
$S6 = '66666666-6666-4666-8666-666666666666'   # billing-api, the most recent
$Dead = 'dead0000-dead-4ead-8ead-00000000dead' # an id Claude has discarded
$New  = '77777777-7777-4777-8777-777777777777' # a session that has not reached the history yet

function ConvertTo-JsonPath { param([string] $Path) return $Path.Replace('\', '\\') }

$historyLines = @(
    ('{{"display":"first prompt of shop","pastedContents":{{}},"timestamp":1000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ShopDir), $S1)
    ('{{"display":"fix the api","pastedContents":{{}},"timestamp":3000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ApiDir), $S2)
    ('{{"display":"retention removed this","pastedContents":{{}},"timestamp":4000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ShopDir), $S3)
    ('{{"display":"work in a project that is gone","pastedContents":{{}},"timestamp":5000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $GoneDir), $S4)
    ('{{"display":"a second shop thing","pastedContents":{{}},"timestamp":6000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ShopDir), $S5)
    ('{{"display":"the newest api thing","pastedContents":{{}},"timestamp":7000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ApiDir), $S6)
)
New-Item -ItemType Directory -Force -Path $ClaudeHome | Out-Null
Set-Content -LiteralPath (Join-Path $ClaudeHome 'history.jsonl') -Value ($historyLines -join "`n") -Encoding utf8 -NoNewline

$projectsRoot = Join-Path $ClaudeHome 'projects'
$titles = @{ $S1 = 'Shop checkout fix'; $S2 = 'Billing api fix'; $S4 = 'Work in a gone project'; $S5 = 'Shop second thing'; $S6 = 'Billing newest' }
foreach ($id in $titles.Keys) {
    $dir = Join-Path $projectsRoot "p-$($id.Substring(0, 2))"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -LiteralPath (Join-Path $dir "$id.jsonl") -Encoding utf8 -Value ('{{"type":"ai-title","aiTitle":"{0}","sessionId":"{1}"}}' -f $titles[$id], $id)
}
$env:CLAUDE_CONFIG_DIR = $ClaudeHome
$env:WORKSTATION_SHOWN_SESSIONS = $ShownFile

$shownForPsd1 = $ShownFile.Replace('\', '/')
Set-Content -LiteralPath $FixturePath -Encoding utf8 -Value @"
@{
    Name = 'qa-show'; Version = '0.0.0'; Description = 'fixture'
    Tools = @(
        @{ Name = 'Stand-in terminal'; Purpose = 'Terminal'; Command = 'pwsh'; Required = `$true; Role = 'terminal'
           WindowsInstall = 'x'; LinuxInstall = 'x' }
    )
    Links = @()
    PowerShellProfile = @{ Name = 'qa profile'; OpenMarker = '# >>> qa >>>'; CloseMarker = '# <<< qa <<<' }
    ShownSessions = @{ Name = 'Shown sessions'; WindowsTarget = '$shownForPsd1'; LinuxTarget = '$shownForPsd1' }
    Agents = @(
        @{ Name = 'claude'; Command = 'pwsh'; Product = 'stand-in'; WindowsInstall = 'x'; LinuxInstall = 'x' }
        @{ Name = 'codex';  Command = 'pwsh'; Product = 'stand-in'; WindowsInstall = 'x'; LinuxInstall = 'x' }
    )
}
"@
$env:WORKSTATION_DECLARED_STATE = $FixturePath

Write-Host ''
Write-Host '  WORKSTATION — SHOW QA' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray
Write-Host "  fixture:    $TempRoot" -ForegroundColor DarkGray

Import-Module $ModulePath -Force -ErrorAction Stop

$ClaudeBefore = Get-TreeSnapshot $ClaudeHome

# ===========================================================================
Set-Group 'Group H1 - the parameters'

$parameters = (Get-Command Start-Workstation).Parameters
Confirm-That 'H01' '-Show, -Hide and -All are parameters of Start-Workstation' `
    ($parameters.ContainsKey('Show') -and $parameters.ContainsKey('Hide') -and $parameters.ContainsKey('All'))

$setNames = @((Get-Command Start-Workstation).ParameterSets | ForEach-Object { $_.Name })
Confirm-That 'H02' 'Show and Hide are parameter sets, beside List, Session and Usage' `
    ('Show' -in $setNames -and 'Hide' -in $setNames -and 'List' -in $setNames -and 'Session' -in $setNames -and 'Usage' -in $setNames) ($setNames -join ', ')

function Test-Refused { param([scriptblock] $Call)
    try { & $Call | Out-Null } catch { return $true }
    return $false
}
Confirm-That 'H03' '-Show and -Hide together are refused by the binder' (Test-Refused { Start-Workstation -Show -Hide -WhatIf -ErrorAction Stop })
Confirm-That 'H04' '-Show with -Session is refused' (Test-Refused { Start-Workstation -Show -Session 1 -WhatIf -ErrorAction Stop })
Confirm-That 'H05' '-Hide with -Session is refused' (Test-Refused { Start-Workstation -Hide -Session 1 -WhatIf -ErrorAction Stop })
Confirm-That 'H06' '-Show with -Project is refused' (Test-Refused { Start-Workstation -Show -Project $ShopDir -WhatIf -ErrorAction Stop })
Confirm-That 'H07' '-Hide with -Project is refused' (Test-Refused { Start-Workstation -Hide -Project $ShopDir -WhatIf -ErrorAction Stop })
Confirm-That 'H08' '-Show with -Agent is refused' (Test-Refused { Start-Workstation -Show -Agent claude -WhatIf -ErrorAction Stop })
Confirm-That 'H09' '-Hide with -Agent is refused' (Test-Refused { Start-Workstation -Hide -Agent claude -WhatIf -ErrorAction Stop })
Confirm-That 'H10' '-Show with -List is refused' (Test-Refused { Start-Workstation -Show -List -ErrorAction Stop })
Confirm-That 'H11' '-All without -List is refused' (Test-Refused { Start-Workstation -All -WhatIf -ErrorAction Stop })

# ===========================================================================
Set-Group 'Group H2 - the list shows only what is shown'

# S1 and S6 are shown; $Dead is an id Claude no longer has; S3 is shown but its
# transcript is gone.
Set-Shown @($S1, $S6, $Dead, $S3)

$list = Invoke-Ws @{ List = $true }
$rows = @($list.Result)
Confirm-That 'H20' 'ws -List returns only the shown sessions, newest first' `
    ((($rows | ForEach-Object { $_.SessionId }) -join ',') -eq "$S6,$S1") "got: $(($rows | ForEach-Object { $_.SessionId.Substring(0, 2) }) -join ', ')"
Confirm-That 'H21' 'numbered from 1' ((($rows | ForEach-Object { $_.Id }) -join ',') -eq '1,2')
Confirm-That 'H22' 'and prints those rows, with the numbers to type' `
    ($list.Printed -match '(?m)^\s*1\s+billing-api\s+.*Billing newest' -and $list.Printed -match '(?m)^\s*2\s+shop\s+.*Shop checkout fix' -and $list.Printed -notmatch 'Billing api fix') $list.Printed
Confirm-That 'H23' 'a shown session whose transcript is gone is not listed, and an id Claude discarded is not counted' `
    ($S3 -notin @($rows | ForEach-Object { $_.SessionId }))

$limited = Invoke-Ws @{ List = $true; Limit = 1 }
Confirm-That 'H24' '-Limit caps the shown rows, newest first' `
    (@($limited.Result).Count -eq 1 -and @($limited.Result)[0].SessionId -eq $S6)
Confirm-That 'H25' 'and the summary still counts the whole set, not the cap' ($limited.Printed -match '2 shown · 3 hidden') $limited.Printed

Confirm-That 'H26' 'the list ends with a summary: N shown · M hidden, and how to see the rest' `
    ($list.Printed -match '2 shown · 3 hidden' -and $list.Printed -match 'ws -List -All') $list.Printed
Confirm-That 'H27' 'each row says whether it is shown' `
    (@($rows | Where-Object { $_.Shown }).Count -eq 2 -and $rows[0].PSObject.Properties.Name -contains 'Shown')

$all = Invoke-Ws @{ List = $true; All = $true }
$allRows = @($all.Result)
Confirm-That 'H28' 'ws -List -All returns every session that still has a transcript, newest first' `
    ((($allRows | ForEach-Object { $_.SessionId }) -join ',') -eq "$S6,$S5,$S4,$S2,$S1" -and (($allRows | ForEach-Object { $_.Id }) -join ',') -eq '1,2,3,4,5') `
    "got: $(($allRows | ForEach-Object { $_.SessionId.Substring(0, 2) }) -join ', ')"
Confirm-That 'H29' 'and marks the shown ones, in the rows and in what it prints' `
    (($allRows | Where-Object { $_.Shown } | ForEach-Object { $_.SessionId }) -join ',' -eq "$S6,$S1" -and
     $all.Printed -match '(?m)^\s*1\s+\*\s+billing-api' -and $all.Printed -match '(?m)^\s*2\s+ +shop' -and $all.Printed -match '(?m)^\s*5\s+\*\s+shop') $all.Printed
Confirm-That 'H30' 'the -All list ends with the same summary' ($all.Printed -match '2 shown · 3 hidden') $all.Printed

Set-Shown @()
$empty = Invoke-Ws @{ List = $true }
Confirm-That 'H31' 'with nothing shown the list is empty' (@($empty.Result).Count -eq 0 -and $empty.Errors.Count -eq 0)
Confirm-That 'H32' 'and says why, and names ws -List -All and ws -Show <n>' `
    ($empty.Printed -match 'ws -List -All' -and $empty.Printed -match 'ws -Show <n>' -and $empty.Printed -match '0 shown · 5 hidden') $empty.Printed

Remove-Item -LiteralPath $ShownFile -Force
$absent = Invoke-Ws @{ List = $true }
Confirm-That 'H33' 'with no shown file at all it is the same empty list, not an error' `
    (@($absent.Result).Count -eq 0 -and $absent.Errors.Count -eq 0 -and $absent.Printed -match '0 shown · 5 hidden')

# ===========================================================================
Set-Group 'Group H3 - showing and hiding by number and by id'

Set-Shown @($S1)
$null = Invoke-Ws @{ List = $true; All = $true }   # 1 S6, 2 S5, 3 S4, 4 S2, 5 S1

$act = Invoke-Ws @{ Show = $true; Target = '2' }
Confirm-That 'H40' '-Show <n> shows the n-th row of the last list printed here' `
    ($act.Errors.Count -eq 0 -and $S5 -in (Get-Shown) -and $S1 -in (Get-Shown)) "errors: $($act.Message); shown: $((Get-Shown) -join ',')"
Confirm-That 'H41' 'and prints the title of the session it touched' ($act.Printed -match 'Shop second thing' -and $act.Printed -match '(?i)shown') $act.Printed

$act = Invoke-Ws @{ Show = $true; Target = '2' }
Confirm-That 'H42' 'showing it again changes nothing and says so' `
    ($act.Errors.Count -eq 0 -and $act.Printed -match '(?i)already shown' -and $act.Printed -match 'Shop second thing' -and @(Get-Shown | Where-Object { $_ -eq $S5 }).Count -eq 1) $act.Printed

$act = Invoke-Ws @{ Hide = $true; Target = '2' }
Confirm-That 'H43' '-Hide <n> hides it, and prints its title' `
    ($act.Errors.Count -eq 0 -and $S5 -notin (Get-Shown) -and $act.Printed -match 'Shop second thing' -and $act.Printed -match '(?i)hidden') $act.Printed
$act = Invoke-Ws @{ Hide = $true; Target = '2' }
Confirm-That 'H44' 'hiding it again changes nothing and says so' `
    ($act.Printed -match '(?i)already hidden' -and $act.Printed -match 'Shop second thing') $act.Printed

$act = Invoke-Ws @{ Show = $true; Target = $S2 }
Confirm-That 'H45' '-Show <id> shows a session by id, with no list needed, and prints its title' `
    ($act.Errors.Count -eq 0 -and $S2 -in (Get-Shown) -and $act.Printed -match 'Billing api fix') "errors: $($act.Message)"
$act = Invoke-Ws @{ Hide = $true; Target = $S2 }
Confirm-That 'H46' '-Hide <id> hides it' ($act.Errors.Count -eq 0 -and $S2 -notin (Get-Shown) -and $act.Printed -match 'Billing api fix')

$unknownShow = Invoke-Ws @{ Show = $true; Target = 'no-such-session-0000' }
$unknownSession = Invoke-Ws @{ Session = 'no-such-session-0000'; WhatIf = $true }
Confirm-That 'H47' 'an unknown id is refused with the message -Session gives' `
    ($unknownShow.Errors.Count -eq 1 -and $unknownShow.Message -eq $unknownSession.Message -and $unknownShow.Message -match 'no-such-session-0000') "show: $($unknownShow.Message) | session: $($unknownSession.Message)"
$unknownHide = Invoke-Ws @{ Hide = $true; Target = 'no-such-session-0000' }
Confirm-That 'H48' 'for -Hide as well' ($unknownHide.Errors.Count -eq 1 -and $unknownHide.Message -eq $unknownSession.Message)

$past = Invoke-Ws @{ Show = $true; Target = '9' }
$pastSession = Invoke-Ws @{ Session = '9'; WhatIf = $true }
Confirm-That 'H49' 'a number past the end of the last list is refused with the message -Session gives' `
    ($past.Errors.Count -eq 1 -and $past.Message -eq $pastSession.Message -and $past.Message -match 'ws -List') "show: $($past.Message) | session: $($pastSession.Message)"
$zero = Invoke-Ws @{ Hide = $true; Target = '0' }
Confirm-That 'H50' 'zero is refused' ($zero.Errors.Count -eq 1)

# A fresh process has printed no list, so a number there means nothing. The
# module is imported in a child because the listing is memory of the process.
$childScript = Join-Path $TempRoot 'child.ps1'
Set-Content -LiteralPath $childScript -Encoding utf8 -Value @"
param([string] `$Verb, [string] `$Target, [switch] `$WhatIfOnly)
Import-Module '$ModulePath' -Force
`$arguments = @{ `$Verb = `$true }
if (`$Target) { `$arguments['Target'] = `$Target }
if (`$WhatIfOnly) { `$arguments['WhatIf'] = `$true }
Start-Workstation @arguments -ErrorAction SilentlyContinue -ErrorVariable e *>&1 | Out-String
(`$e | ForEach-Object { `$_.ToString() }) -join ' '
"@
$fresh = & pwsh -NoProfile -File $childScript -Verb Show -Target 1 2>&1 | Out-String
Confirm-That 'H51' 'a number in a terminal that has printed no list is refused and told to list first' ($fresh -match 'No session list' -and $fresh -match 'ws -List') "got: $($fresh.Trim())"

# The target is bound by position exactly as it is typed, not splatted by name.
$null = Start-Workstation -List -All 6>$null
$typed = @(Start-Workstation -Show 2 -PassThru 6>$null)
Confirm-That 'H52' '`Start-Workstation -Show 2`, typed, shows number 2 of the last list' `
    ($typed.Count -eq 1 -and $typed[0].SessionId -eq $S5 -and $S5 -in (Get-Shown))
$typed = @(Start-Workstation -Hide 2 -PassThru 6>$null)
Confirm-That 'H53' '`-Hide 2`, typed, hides it' ($typed.Count -eq 1 -and $typed[0].SessionId -eq $S5 -and $S5 -notin (Get-Shown))
$typed = @(Start-Workstation -Show $S2 -PassThru 6>$null)
Confirm-That 'H54' '`-Show <id>`, typed, shows by id' ($typed.Count -eq 1 -and $typed[0].SessionId -eq $S2 -and $S2 -in (Get-Shown))
$typed = @(Start-Workstation -Hide $S2 -PassThru 6>$null)
Confirm-That 'H55' '`-Hide <id>`, typed, hides by id' ($typed.Count -eq 1 -and $typed[0].SessionId -eq $S2 -and $S2 -notin (Get-Shown))
$typed = @(Start-Workstation -Show -Target $S2 -WhatIf -PassThru 6>$null)
Confirm-That 'H56' 'and the target may be named as well, with -WhatIf writing nothing' ($S2 -notin (Get-Shown)) ((Get-Shown) -join ',')

# ===========================================================================
Set-Group 'Group H4 - no argument means the session of this window'

$StatusFile = Join-Path $TempRoot 'agent-status.lua'
$statusBefore = $env:WORKSTATION_STATUS_FILE
Set-Shown @($S1)

$env:WORKSTATION_STATUS_FILE = $null
$act = Invoke-Ws @{ Show = $true }
Confirm-That 'H60' 'outside a ws window (no WORKSTATION_STATUS_FILE) -Show is refused and suggests a number or an id' `
    ($act.Errors.Count -eq 1 -and $act.Message -match 'WORKSTATION_STATUS_FILE' -and $act.Message -match 'number' -and $act.Message -match '\bid\b' -and (Get-Shown).Count -eq 1) $act.Message
$act = Invoke-Ws @{ Hide = $true }
Confirm-That 'H61' 'and so is -Hide' ($act.Errors.Count -eq 1 -and $act.Message -match 'WORKSTATION_STATUS_FILE' -and $S1 -in (Get-Shown))

$env:WORKSTATION_STATUS_FILE = $StatusFile
$act = Invoke-Ws @{ Show = $true }
Confirm-That 'H62' 'with the variable set but the file not written yet, it is refused and says the agent has not answered' `
    ($act.Errors.Count -eq 1 -and $act.Message -match [regex]::Escape($StatusFile) -and (Get-Shown).Count -eq 1) $act.Message

Set-Content -LiteralPath $StatusFile -Encoding utf8 -Value "return {`n  agent = `"claude`",`n  model = `"Fable 5.1`",`n}"
$act = Invoke-Ws @{ Show = $true }
Confirm-That 'H63' 'a file with no session_id is refused' `
    ($act.Errors.Count -eq 1 -and $act.Message -match 'session_id' -and (Get-Shown).Count -eq 1) $act.Message

Set-Content -LiteralPath $StatusFile -Encoding utf8 -Value "return {`n  agent = `"claude`",`n  session_id = `"$S2`",`n  written_at = 1,`n}"
$act = Invoke-Ws @{ Show = $true }
Confirm-That 'H64' '-Show reads session_id from the status file, shows that session and prints its title' `
    ($act.Errors.Count -eq 0 -and $S2 -in (Get-Shown) -and $act.Printed -match 'Billing api fix') "errors: $($act.Message); printed: $($act.Printed)"
$act = Invoke-Ws @{ Hide = $true }
Confirm-That 'H65' '-Hide does the reverse' ($act.Errors.Count -eq 0 -and $S2 -notin (Get-Shown) -and $act.Printed -match 'Billing api fix')

Set-Content -LiteralPath $StatusFile -Encoding utf8 -Value "return {`n  session_id = `"$S4`",`n}"
$act = Invoke-Ws @{ Show = $true }
Confirm-That 'H66' 'it follows the file: after /clear the new session is the one acted on' `
    ($S4 -in (Get-Shown) -and $act.Printed -match 'Work in a gone project')

Set-Content -LiteralPath $StatusFile -Encoding utf8 -Value "return {`n  session_id = `"00000000-0000-4000-8000-000000000000`",`n}"
$act = Invoke-Ws @{ Show = $true }
Confirm-That 'H67' 'a session_id Claude does not know is refused, naming it' `
    ($act.Errors.Count -eq 1 -and $act.Message -match '00000000-0000-4000-8000-000000000000') $act.Message

$env:WORKSTATION_STATUS_FILE = $statusBefore

# ===========================================================================
Set-Group 'Group H5 - the shown set is a file the workstation owns'

Set-Shown @($S1, $Dead, $S6)
$null = Invoke-Ws @{ List = $true; All = $true }
$act = Invoke-Ws @{ Show = $true; Target = $S2 }
$text = [System.IO.File]::ReadAllText($ShownFile)
Confirm-That 'H70' 'the file holds one id per line' `
    ($text -notmatch "`r" -and (@($text -split "`n" | Where-Object { $_ -ne '' } | Where-Object { $_ -notmatch '^[0-9a-f-]{36}$' }).Count -eq 0) -and $text.EndsWith("`n")) $text
Confirm-That 'H71' 'an id Claude has no transcript for is kept when the file is written: nothing is ever pruned' `
    ($Dead -in (Get-Shown) -and (Get-Shown).Count -eq 4 -and $S2 -in (Get-Shown)) "shown: $((Get-Shown) -join ',')"
Confirm-That 'H72' 'ids are kept in the order they were shown' `
    ((Get-Shown) -join ',' -eq "$S1,$Dead,$S6,$S2") "shown: $((Get-Shown) -join ',')"
Confirm-That 'H73' 'no temporary file is left beside it' (@(Get-ChildItem -LiteralPath $StateDir -Force | Where-Object { $_.Name -ne 'shown-sessions.txt' -and $_.Name -ne 'shown-sessions.txt.lock' }).Count -eq 0) `
    ((Get-ChildItem -LiteralPath $StateDir -Force | ForEach-Object Name) -join ', ')

Remove-Item -LiteralPath $StateDir -Recurse -Force
$null = Invoke-Ws @{ Show = $true; Target = $S6 }
Confirm-That 'H74' 'the directory is created when the first id is written' ((Get-Shown) -join ',' -eq $S6)

# Hiding is a write too, and it removes only the id it was asked to hide.
Set-Shown @($S1, $Dead, $S6)
$null = Invoke-Ws @{ Hide = $true; Target = $S6 }
Confirm-That 'H75' 'hiding removes that id and nothing else' ((Get-Shown) -join ',' -eq "$S1,$Dead") "shown: $((Get-Shown) -join ',')"

# An unreadable store is no evidence that a session is gone. The target
# resolves here (its transcript is under a readable directory), while the
# directory that holds the other shown session's transcript is replaced by a
# file, so it cannot be enumerated, and the projects directory of a second home
# is missing altogether.
$brokenHome = Join-Path $TempRoot 'broken-home'
New-Item -ItemType Directory -Force -Path (Join-Path $brokenHome 'projects') | Out-Null
Copy-Item -LiteralPath (Join-Path $ClaudeHome 'history.jsonl') -Destination $brokenHome
New-Item -ItemType Directory -Force -Path (Join-Path $brokenHome 'projects/p-22') | Out-Null
Copy-Item -LiteralPath (Join-Path $ClaudeHome "projects/p-22/$S2.jsonl") -Destination (Join-Path $brokenHome 'projects/p-22')
Set-Content -LiteralPath (Join-Path $brokenHome 'projects/p-11') -Value 'not a directory'
Set-Shown @($S1, $Dead)
$env:CLAUDE_CONFIG_DIR = $brokenHome
$act = Invoke-Ws @{ Show = $true; Target = $S2 }
$env:CLAUDE_CONFIG_DIR = $ClaudeHome
Confirm-That 'H76' 'a store with an unreadable subdirectory removes nothing: the target resolves, the other ids stay' `
    ($act.Errors.Count -eq 0 -and (Get-Shown) -join ',' -eq "$S1,$Dead,$S2") "errors: $($act.Message); shown: $((Get-Shown) -join ',')"
Remove-Item -LiteralPath (Join-Path $brokenHome 'projects') -Recurse -Force
Set-Shown @($S1, $Dead)
$null = Invoke-Hook -Payload (@{ session_id = $S2 } | ConvertTo-Json) -StateFile $ShownFile -Environment @{ CLAUDE_CONFIG_DIR = $brokenHome }
Confirm-That 'H77' 'and so does the hook when the projects directory is missing' ((Get-Shown) -join ',' -eq "$S1,$Dead,$S2") "shown: $((Get-Shown) -join ',')"

# Two sessions started before either has a transcript: both are kept, and each
# is listed once its transcript appears.
$pendingHome = Join-Path $TempRoot 'pending-home'
New-Item -ItemType Directory -Force -Path $pendingHome | Out-Null
$PendA = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
$PendB = 'bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'
$pendingLines = @(
    ('{{"display":"pending A","pastedContents":{{}},"timestamp":8000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ShopDir), $PendA)
    ('{{"display":"pending B","pastedContents":{{}},"timestamp":9000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ShopDir), $PendB)
)
Set-Content -LiteralPath (Join-Path $pendingHome 'history.jsonl') -Value ($pendingLines -join "`n") -Encoding utf8 -NoNewline
Set-Shown @()
$null = Invoke-Hook -Payload (@{ session_id = $PendA; source = 'startup' } | ConvertTo-Json) -StateFile $ShownFile -Environment @{ CLAUDE_CONFIG_DIR = $pendingHome }
$null = Invoke-Hook -Payload (@{ session_id = $PendB; source = 'startup' } | ConvertTo-Json) -StateFile $ShownFile -Environment @{ CLAUDE_CONFIG_DIR = $pendingHome }
Confirm-That 'H78' 'A and B started before either has a transcript: both stay in the file' ((Get-Shown) -join ',' -eq "$PendA,$PendB") "shown: $((Get-Shown) -join ',')"
$env:CLAUDE_CONFIG_DIR = $pendingHome
$none = Invoke-Ws @{ List = $true }
New-Item -ItemType Directory -Force -Path (Join-Path $pendingHome 'projects/p-a') | Out-Null
Set-Content -LiteralPath (Join-Path $pendingHome "projects/p-a/$PendA.jsonl") -Value '{"type":"user"}'
$some = Invoke-Ws @{ List = $true }
$env:CLAUDE_CONFIG_DIR = $ClaudeHome
Confirm-That 'H79' 'a session without a transcript is left out of the list, and is listed once its transcript appears' `
    (@($none.Result).Count -eq 0 -and @($some.Result).Count -eq 1 -and @($some.Result)[0].SessionId -eq $PendA) "before: $(@($none.Result).Count); after: $(@($some.Result).SessionId -join ',')"

# ===========================================================================
Set-Group 'Group H6 - -WhatIf changes nothing'

Set-Shown @($S1)
$before = Get-FileHashOf $ShownFile
$act = Invoke-Ws @{ Show = $true; Target = $S2; WhatIf = $true }
Confirm-That 'H80' '-Show -WhatIf writes nothing' ($act.Errors.Count -eq 0 -and (Get-FileHashOf $ShownFile) -eq $before)
$act = Invoke-Ws @{ Hide = $true; Target = $S1; WhatIf = $true }
Confirm-That 'H81' '-Hide -WhatIf writes nothing' ($act.Errors.Count -eq 0 -and (Get-FileHashOf $ShownFile) -eq $before)

$null = Invoke-Ws @{ List = $true; All = $true }
$whatIfText = & pwsh -NoProfile -File $childScript -Verb Hide -Target $S1 -WhatIfOnly 2>&1 | Out-String
Confirm-That 'H82' 'and says what it would have done, naming the session by its title' `
    ($whatIfText -match 'What if' -and $whatIfText -match 'Shop checkout fix') $whatIfText

# ===========================================================================
Set-Group 'Group H7 - the generated settings declare the hook'

Confirm-That 'H90' 'the hook script lives with the Claude assets' (Test-Path -LiteralPath $HookScript -PathType Leaf) $HookScript

$content = & (Get-Module Workstation) { New-ClaudeSettingsContent }
$parsed = $null
try { $parsed = $content | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { }
$groups = @()
if ($null -ne $parsed -and $parsed.ContainsKey('hooks') -and $parsed.hooks.ContainsKey('SessionStart')) { $groups = @($parsed.hooks.SessionStart) }
Confirm-That 'H91' 'the settings declare a SessionStart hook' ($groups.Count -eq 1) $content
$group = if ($groups.Count -eq 1) { $groups[0] } else { @{} }
Confirm-That 'H92' 'with no matcher, so it fires for startup, resume, clear, compact and fork alike' `
    ($groups.Count -eq 1 -and -not $group.ContainsKey('matcher')) $content
$entries = @(if ($group.ContainsKey('hooks')) { $group.hooks })
Confirm-That 'H93' 'one command hook, with a short timeout' `
    ($entries.Count -eq 1 -and $entries[0].type -eq 'command' -and $entries[0].timeout -le 10 -and $entries[0].timeout -ge 1) $content
$hookCommand = if ($entries.Count -eq 1) { [string] $entries[0].command } else { '' }
$expectedPath = $HookScript.Replace('\', '/')
Confirm-That 'H94' 'it runs the script by its absolute path, in single quotes so the shell takes the path literally' `
    ($hookCommand -eq ("pwsh -NoProfile -NonInteractive -File '" + $expectedPath + "'")) $hookCommand
$statusCommand = if ($null -ne $parsed) { [string] $parsed.statusLine.command } else { '' }
Confirm-That 'H95' 'beside the status line command, quoted the same way' `
    ($statusCommand -eq ("pwsh -NoProfile -NonInteractive -File '" + $StatusScript.Replace('\', '/') + "'")) $statusCommand

# The string above says how the command is built; what matters is what a
# shell does with it. The checkout is put in a directory whose name has a
# dollar sign, a backtick, a space and a single quote, and the generated
# commands are run by the shell Claude runs hook commands with.
$shell = $null
foreach ($candidate in @('C:\Program Files\Git\bin\bash.exe', '/bin/sh', '/usr/bin/sh')) { if (Test-Path -LiteralPath $candidate) { $shell = $candidate; break } }
if ($null -eq $shell) { $found = Get-Command sh -ErrorAction Ignore; if ($found) { $shell = $found.Source } }
$oddRoot = Join-Path $TempRoot ('odd $cash `tick it''s dir')
$oddClaude = Join-Path $oddRoot 'claude'
New-Item -ItemType Directory -Force -Path $oddClaude | Out-Null
Copy-Item -LiteralPath $HookScript -Destination (Join-Path $oddClaude 'session-start.ps1')
Copy-Item -LiteralPath $StatusScript -Destination (Join-Path $oddClaude 'statusline.ps1')
$realStatusPath = & (Get-Module Workstation) { $script:ClaudeStatusLinePath }
$realHookPath0  = & (Get-Module Workstation) { $script:ClaudeSessionHookPath }
& (Get-Module Workstation) { param($H, $S) $script:ClaudeSessionHookPath = $H; $script:ClaudeStatusLinePath = $S } (Join-Path $oddClaude 'session-start.ps1') (Join-Path $oddClaude 'statusline.ps1')
$oddSettings = (& (Get-Module Workstation) { New-ClaudeSettingsContent }) | ConvertFrom-Json -AsHashtable
& (Get-Module Workstation) { param($H, $S) $script:ClaudeSessionHookPath = $H; $script:ClaudeStatusLinePath = $S } $realHookPath0 $realStatusPath
$oddHookCommand = [string] $oddSettings.hooks.SessionStart[0].hooks[0].command
$oddStatusCommand = [string] $oddSettings.statusLine.command
if ($null -eq $shell) {
    Confirm-That 'H99' 'the generated hook command, run by a shell from a path with $, a backtick, a space and a quote, adds its session (skipped: no POSIX shell here)' $true
    Confirm-That 'H99b' 'and so does the status line command (skipped: no POSIX shell here)' $true
}
else {
    Set-Shown @()
    $info = [System.Diagnostics.ProcessStartInfo]::new($shell)
    $info.ArgumentList.Add('-c'); $info.ArgumentList.Add($oddHookCommand)
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.UseShellExecute = $false
    $info.Environment['WORKSTATION_SHOWN_SESSIONS'] = $ShownFile
    $shellProcess = [System.Diagnostics.Process]::Start($info)
    $so = $shellProcess.StandardOutput.ReadToEndAsync(); $se = $shellProcess.StandardError.ReadToEndAsync()
    $shellProcess.StandardInput.Write((@{ session_id = $S2; source = 'startup' } | ConvertTo-Json)); $shellProcess.StandardInput.Close()
    $shellProcess.WaitForExit()
    Confirm-That 'H99' 'the generated hook command, run by a shell from a path with $, a backtick, a space and a quote, adds its session' `
        ($shellProcess.ExitCode -eq 0 -and (Get-Shown) -join ',' -eq $S2) "shell $shell; exit $($shellProcess.ExitCode); stderr $($se.Result); command: $oddHookCommand"

    $info = [System.Diagnostics.ProcessStartInfo]::new($shell)
    $info.ArgumentList.Add('-c'); $info.ArgumentList.Add($oddStatusCommand)
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.UseShellExecute = $false
    $statusProcess = [System.Diagnostics.Process]::Start($info)
    $so = $statusProcess.StandardOutput.ReadToEndAsync(); $se = $statusProcess.StandardError.ReadToEndAsync()
    $statusProcess.StandardInput.Write('{}'); $statusProcess.StandardInput.Close()
    $statusProcess.WaitForExit()
    Confirm-That 'H99b' 'and so does the status line command: pwsh finds the script, so it exits 0' `
        ($statusProcess.ExitCode -eq 0) "exit $($statusProcess.ExitCode); stderr $($se.Result); command: $oddStatusCommand"
}
Remove-Item -LiteralPath $oddRoot -Recurse -Force -ErrorAction Ignore

# The fixture above declares no settings artifact; the check that the script
# the settings name is there is exercised against one that does.
$GeneratedDir = Join-Path $TempRoot 'generated'
$withSettings = Join-Path $TempRoot 'declared-with-settings.psd1'
$generatedForPsd1 = $GeneratedDir.Replace('\', '/')
Set-Content -LiteralPath $withSettings -Encoding utf8 -Value @"
@{
    Name = 'qa-show'; Version = '0.0.0'; Description = 'fixture'
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
    Agents = @(
        @{ Name = 'claude'; Command = 'pwsh'; Product = 'stand-in'; WindowsInstall = 'x'; LinuxInstall = 'x' }
    )
}
"@
$env:WORKSTATION_DECLARED_STATE = $withSettings
$hookStep = @(& (Get-Module Workstation) { Get-WorkstationStepList } | Where-Object { $_.Kind -eq 'command' -and $_.Name -match '(?i)session hook' })
Confirm-That 'H97' 'the step list carries the session hook, in sync while the script is there, naming the file' `
    ($hookStep.Count -eq 1 -and $hookStep[0].State -eq 'InSync' -and $hookStep[0].Detail -match 'session-start\.ps1' -and $null -eq $hookStep[0].Action) `
    (($hookStep | ForEach-Object { "$($_.Name)/$($_.State)/$($_.Detail)" }) -join ', ')

$realHookPath = & (Get-Module Workstation) { $script:ClaudeSessionHookPath }
$absentHook = Join-Path $TempRoot 'gone' 'session-start.ps1'
& (Get-Module Workstation) { param($Path) $script:ClaudeSessionHookPath = $Path } $absentHook
$absentStep = @(& (Get-Module Workstation) { Get-WorkstationStepList } | Where-Object { $_.Kind -eq 'command' -and $_.Name -match '(?i)session hook' })
Confirm-That 'H98' 'a hook script the settings name but the checkout no longer has is missing, and the line says where it should be' `
    ($absentStep.Count -eq 1 -and $absentStep[0].State -eq 'Missing' -and $absentStep[0].Detail -match [regex]::Escape($absentHook)) `
    (($absentStep | ForEach-Object { "$($_.State)/$($_.Detail)" }) -join ', ')
& (Get-Module Workstation) { param($Path) $script:ClaudeSessionHookPath = $Path } $realHookPath
$env:WORKSTATION_DECLARED_STATE = $FixturePath

# ===========================================================================
Set-Group 'Group H8 - the hook script'

$sources = @('startup', 'resume', 'clear', 'compact', 'fork')
$n = 0
foreach ($source in $sources) {
    $n++
    $id = '{0}{0}{0}{0}{0}{0}{0}{0}-aaaa-4aaa-8aaa-aaaaaaaaaaaa' -f $n
    Set-Shown @()
    $run = Invoke-Hook -Payload (@{ session_id = $id; transcript_path = '/x'; cwd = '/y'; hook_event_name = 'SessionStart'; source = $source } | ConvertTo-Json) -StateFile $ShownFile
    Confirm-That ('H10{0}' -f $n) "a SessionStart payload with source '$source' adds its session_id to the shown set" `
        ($run.ExitCode -eq 0 -and (Get-Shown) -join ',' -eq $id) "exit $($run.ExitCode); shown: $((Get-Shown) -join ','); stderr: $($run.Stderr)"
}

Set-Shown @($S1)
$payload = @{ session_id = $S1; source = 'resume' } | ConvertTo-Json
$null = Invoke-Hook -Payload $payload -StateFile $ShownFile
$null = Invoke-Hook -Payload $payload -StateFile $ShownFile
Confirm-That 'H106' 'a session already shown stays shown, once' (@(Get-Shown | Where-Object { $_ -eq $S1 }).Count -eq 1 -and (Get-Shown).Count -eq 1)

Set-Shown @($S1, $Dead)
$null = Invoke-Hook -Payload (@{ session_id = $New; source = 'startup' } | ConvertTo-Json) -StateFile $ShownFile
Confirm-That 'H107' 'the new session is added although Claude has not written its transcript yet, and an id without one is not pruned' `
    ((Get-Shown) -join ',' -eq "$S1,$Dead,$New") "shown: $((Get-Shown) -join ',')"

Set-Shown @($S1)
$run = Invoke-Hook -Payload (@{ session_id = $S2; source = 'startup' } | ConvertTo-Json) -StateFile $ShownFile
Confirm-That 'H108' 'the hook writes nothing to stdout on success, because Claude would add it to its context' `
    ($run.Stdout -eq '' -and $run.ExitCode -eq 0) "stdout: '$($run.Stdout)'"

$cases = [ordered]@{
    'a payload that is not JSON'        = @{ Payload = 'this is not json'; State = $ShownFile }
    'an empty payload'                  = @{ Payload = ''; State = $ShownFile }
    'a payload that is not an object'   = @{ Payload = '[1,2,3]'; State = $ShownFile }
    'a payload with no session_id'      = @{ Payload = '{"source":"startup"}'; State = $ShownFile }
    'a session_id that is not a string' = @{ Payload = '{"session_id":{"a":1}}'; State = $ShownFile }
    'no WORKSTATION_SHOWN_SESSIONS'     = @{ Payload = (@{ session_id = $S2 } | ConvertTo-Json); State = $null }
    'a state file that cannot be written' = @{ Payload = (@{ session_id = $S2 } | ConvertTo-Json); State = $StateDir }
}
$n = 0
foreach ($name in $cases.Keys) {
    $n++
    Set-Shown @($S1)
    $run = Invoke-Hook -Payload $cases[$name].Payload -StateFile $cases[$name].State
    Confirm-That ('H11{0}' -f $n) "with $name the hook exits 0 and writes nothing to stdout" `
        ($run.ExitCode -eq 0 -and $run.Stdout -eq '') "exit $($run.ExitCode); stdout: '$($run.Stdout)'"
}
$run = Invoke-Hook -Payload 'this is not json' -StateFile $ShownFile
Confirm-That 'H118' 'a failure is reported on stderr, in one line' `
    ($run.Stderr.Trim() -ne '' -and @($run.Stderr.Trim() -split "`r?`n").Count -eq 1 -and $run.Stderr -match 'session-start') "stderr: '$($run.Stderr)'"
Set-Shown @($S1)
$null = Invoke-Hook -Payload '{"source":"startup"}' -StateFile $ShownFile
Confirm-That 'H119' 'and a payload it cannot use leaves the shown set as it was' ((Get-Shown) -join ',' -eq $S1)

$freshDir = Join-Path $TempRoot 'fresh-parent'
Remove-Item -LiteralPath $freshDir -Recurse -Force -ErrorAction Ignore   # the parent must not exist when the hook starts
$freshFile = Join-Path $freshDir 'made-by-hook.txt'
$run = Invoke-Hook -Payload (@{ session_id = $S2 } | ConvertTo-Json) -StateFile $freshFile
Confirm-That 'H120' 'the hook creates the directory of the state file when it is not there yet' `
    ((Test-Path -LiteralPath $freshDir -PathType Container) -and (@([System.IO.File]::ReadAllLines($freshFile)) -join ',' -eq $S2) -and @(Get-ChildItem -LiteralPath $freshDir -Force | Where-Object { $_.Name -like '*.tmp' }).Count -eq 0) "stderr: $($run.Stderr)"
Remove-Item -LiteralPath $freshDir -Recurse -Force -ErrorAction Ignore

# ===========================================================================
Set-Group 'Group H8b - every writer takes the same exclusive lock'

# Ten hooks started at once, each with its own session id: the file has to end
# up holding all ten, which a read-modify-write without a lock does not
# guarantee.
Set-Shown @($S1)
$ids = 1..10 | ForEach-Object { '{0:d8}-bbbb-4bbb-8bbb-bbbbbbbbbbbb' -f $_ }
$handles = @($ids | ForEach-Object { Start-HookProcess -Payload (@{ session_id = $_; source = 'startup' } | ConvertTo-Json) -StateFile $ShownFile })
$runs = @($handles | ForEach-Object { Wait-HookProcess $_ })
$missing = @($ids | Where-Object { $_ -notin (Get-Shown) })
Confirm-That 'H121' 'ten hooks started at once all land in the file' ($missing.Count -eq 0 -and $S1 -in (Get-Shown) -and (Get-Shown).Count -eq 11) "missing: $($missing -join ','); shown: $((Get-Shown).Count)"
Confirm-That 'H122' 'and each exits 0 with nothing on stdout' (@($runs | Where-Object { $_.ExitCode -ne 0 -or $_.Stdout -ne '' }).Count -eq 0)

# The hooks race the module: -Show in this process while hooks run.
Set-Shown @()
$ids2 = 1..6 | ForEach-Object { '{0:d8}-cccc-4ccc-8ccc-cccccccccccc' -f $_ }
$handles = @($ids2 | ForEach-Object { Start-HookProcess -Payload (@{ session_id = $_; source = 'startup' } | ConvertTo-Json) -StateFile $ShownFile })
$null = Invoke-Ws @{ Show = $true; Target = $S2 }
$null = Invoke-Ws @{ Show = $true; Target = $S5 }
$null = @($handles | ForEach-Object { Wait-HookProcess $_ })
$missing = @(@($ids2) + @($S2, $S5) | Where-Object { $_ -notin (Get-Shown) })
Confirm-That 'H123' 'hooks running while -Show writes lose nothing either' ($missing.Count -eq 0) "missing: $($missing -join ','); shown: $((Get-Shown).Count)"

# A hook that cannot get the lock in time leaves the session hidden, says why
# on stderr and still exits 0 with nothing on stdout.
Set-Shown @($S1)
$held = Lock-ShownFile $ShownFile
try {
    $run = Invoke-Hook -Payload (@{ session_id = $S2; source = 'startup' } | ConvertTo-Json) -StateFile $ShownFile -Environment @{ WORKSTATION_SHOWN_LOCK_TIMEOUT_MS = 300 }
    $during = (Get-Shown) -join ','
}
finally { $held.Dispose() }
Confirm-That 'H124' 'with the lock held by another writer the hook gives up: exit 0, nothing on stdout, the reason on stderr, the file untouched' `
    ($run.ExitCode -eq 0 -and $run.Stdout -eq '' -and $run.Stderr -match '(?i)lock' -and $during -eq $S1) "exit $($run.ExitCode); stdout '$($run.Stdout)'; stderr '$($run.Stderr)'; shown $during"

# -Show and -Hide report a clear error instead.
Set-Shown @($S1)
$held = Lock-ShownFile $ShownFile
$env:WORKSTATION_SHOWN_LOCK_TIMEOUT_MS = '300'
try { $locked = Invoke-Ws @{ Show = $true; Target = $S2 } }
finally { $held.Dispose(); $env:WORKSTATION_SHOWN_LOCK_TIMEOUT_MS = $null }
Confirm-That 'H125' '-Show with the lock held is a clear error naming the file, and writes nothing' `
    ($locked.Errors.Count -ge 1 -and $locked.Message -match '(?i)locked|in use|another' -and $locked.Message -match 'shown' -and (Get-Shown) -join ',' -eq $S1) $locked.Message

# A writer that waits for the lock gets it when the holder lets go.
Set-Shown @($S1)
$held = Lock-ShownFile $ShownFile
$handle = Start-HookProcess -Payload (@{ session_id = $S2; source = 'startup' } | ConvertTo-Json) -StateFile $ShownFile -Environment @{ WORKSTATION_SHOWN_LOCK_TIMEOUT_MS = 20000 }
Start-Sleep -Milliseconds 1500
$held.Dispose()
$run = Wait-HookProcess $handle
Confirm-That 'H126' 'a hook that waits for the lock adds its session once the holder lets go' `
    ($run.ExitCode -eq 0 -and (Get-Shown) -join ',' -eq "$S1,$S2") "exit $($run.ExitCode); stderr '$($run.Stderr)'; shown $((Get-Shown) -join ',')"

# ===========================================================================
Set-Group 'Group H9 - Claude''s store is read and never written'

$ClaudeAfter = Get-TreeSnapshot $ClaudeHome
Confirm-That 'H130' 'after every list, show, hide and hook above, nothing under the Claude home was created, changed or deleted' `
    ($ClaudeBefore -eq $ClaudeAfter) 'the snapshot of the fake Claude home differs'

# ===========================================================================
Set-Group 'Group H10 - where the shown set lives'

$env:WORKSTATION_SHOWN_SESSIONS = $null
$path = & (Get-Module Workstation) { Get-ShownSessionsPath }
Confirm-That 'H140' 'without the environment variable the declared state names the file' ($path -eq $ShownFile) "got: $path"

$realState = Import-PowerShellDataFile -Path (Join-Path $ModulePath 'DeclaredState.psd1')
Confirm-That 'H141' 'the shipped declared state declares it, for both platforms, beside the agent status' `
    ($realState.ContainsKey('ShownSessions') -and $realState.ShownSessions.WindowsTarget -match 'LOCALAPPDATA' -and $realState.ShownSessions.LinuxTarget -match 'XDG_CONFIG_HOME' -and $realState.ContainsKey('AgentStatus'))

$launch = Start-Workstation -Project $ShopDir -WhatIf -PassThru -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
Confirm-That 'H142' 'a launch names the shown set for the window, so the hook finds it' `
    ($null -ne $launch -and $launch.PSObject.Properties.Name -contains 'ShownSessionsFile' -and $launch.ShownSessionsFile -eq $ShownFile) "got: $($launch | Out-String)"

$removal = @(& (Get-Module Workstation) { Get-WorkstationRemovalList })
Confirm-That 'H143' 'an uninstall keeps it: it is the user''s choice, not machine output' `
    (@($removal | Where-Object { $_.Name -match '(?i)shown' -or $_.Detail -match 'shown-sessions' }).Count -eq 0)

# ===========================================================================
Set-Group 'Cleanup'
$env:CLAUDE_CONFIG_DIR = $null
$env:WORKSTATION_DECLARED_STATE = $null
$env:WORKSTATION_SHOWN_SESSIONS = $null
Remove-Module Workstation -Force -ErrorAction Ignore
Remove-Item -Recurse -Force $TempRoot -ErrorAction Ignore
Confirm-That 'H199' 'the fixture is gone' (-not (Test-Path $TempRoot))

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
