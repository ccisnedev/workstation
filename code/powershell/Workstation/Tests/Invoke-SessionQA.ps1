#Requires -Version 7.0
<#
    QA for opening a project and continuing a Claude session from `ws`.
    Runs on Windows, Linux and macOS, and needs nothing but PowerShell.

    The contract under test:

        ws                        the default agent, the current directory, a new session
        ws -Project <name|path>   a known project by name, or any directory, a new session
        ws -List [-Limit n]       the most recent Claude sessions, numbered
        ws -Session <n|uuid>      continue one: its project, its conversation
        ws -Agent <name>          another agent; never together with -Session

    Nothing is positional, so `ws codex` and `ws 3` are errors rather than
    guesses. The list comes from Claude's own history file, read from a fixture
    under CLAUDE_CONFIG_DIR so the suite never reads the real one. Launches are
    stopped with -WhatIf and inspected through -PassThru, against a declared
    state whose tools and agents are all `pwsh`, so no terminal, editor or
    agent has to be installed.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code/powershell/Workstation'
$TempRoot       = Join-Path ([System.IO.Path]::GetTempPath()) 'qa-workstation-sessions'
$ClaudeHome     = Join-Path $TempRoot 'claude-home'
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

# Runs Start-Workstation, swallows its errors, and returns what it produced
# and what it complained about, so an assertion can look at both.
function Invoke-Start {
    param([hashtable] $Arguments)
    $errors = $null
    $result = Start-Workstation @Arguments -WhatIf -PassThru -ErrorAction SilentlyContinue -ErrorVariable errors -WarningAction SilentlyContinue 2>$null
    return [PSCustomObject]@{
        Result  = $result
        Errors  = @($errors)
        Message = (@($errors) | ForEach-Object { $_.ToString() }) -join ' '
    }
}

# ---------------------------------------------------------------------------
#  Fixture: a Claude home, a few project directories, a declared state
# ---------------------------------------------------------------------------
if (Test-Path $TempRoot) { Remove-Item -Recurse -Force $TempRoot }
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

$ShopDir  = Join-Path $TempRoot 'shop'
$ApiDir   = Join-Path $TempRoot 'billing-api'
$BingoA   = Join-Path (Join-Path $TempRoot 'a') 'bingo'
$BingoB   = Join-Path (Join-Path $TempRoot 'b') 'bingo'
$GoneDir  = Join-Path $TempRoot 'gone-project'
foreach ($d in @($ShopDir, $ApiDir, $BingoA, $BingoB)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

$S1 = '11111111-1111-4111-8111-111111111111'   # shop, two prompts
$S2 = '22222222-2222-4222-8222-222222222222'   # billing-api
$S3 = '33333333-3333-4333-8333-333333333333'   # shop, but its file is gone: retention took it
$S4 = '44444444-4444-4444-8444-444444444444'   # a directory that no longer exists
$S5 = '55555555-5555-4555-8555-555555555555'   # a/bingo
$S6 = '66666666-6666-4666-8666-666666666666'   # b/bingo, the most recent

function ConvertTo-JsonPath { param([string] $Path) return $Path.Replace('\', '\\') }

$historyLines = @(
    ('{{"display":"first prompt of shop","pastedContents":{{}},"timestamp":1000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ShopDir), $S1)
    ('{{"display":"second prompt of shop","pastedContents":{{}},"timestamp":2000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ShopDir), $S1)
    ('{{"display":"   fix   the api  ","pastedContents":{{}},"timestamp":3000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ApiDir), $S2)
    ('{{"display":"and the tests","pastedContents":{{}},"timestamp":3500000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ApiDir), $S2)
    ('{{"display":"a shop session retention removed","pastedContents":{{}},"timestamp":4000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $ShopDir), $S3)
    ('{{"display":"work in a project that is gone","pastedContents":{{}},"timestamp":5000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $GoneDir), $S4)
    ('{{"display":"bingo in a","pastedContents":{{}},"timestamp":6000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $BingoA), $S5)
    ('{{"display":"bingo in b","pastedContents":{{}},"timestamp":7000000,"project":"{0}","sessionId":"{1}"}}' -f (ConvertTo-JsonPath $BingoB), $S6)
    '{ this line is not json and must not break the listing'
)
New-Item -ItemType Directory -Force -Path $ClaudeHome | Out-Null
Set-Content -LiteralPath (Join-Path $ClaudeHome 'history.jsonl') -Value ($historyLines -join "`n") -Encoding utf8 -NoNewline

# The session files live under projects/<encoded dir>/<uuid>.jsonl. The encoded
# names are Claude's business; the reader finds a file by its uuid, so the
# fixture uses arbitrary directory names on purpose.
#
# Claude writes its short title for the conversation into the transcript as
# "aiTitle" records, repeated as the conversation goes on, and a title the
# user set as "customTitle". The fixture gives each session a different case:
#   S1  one aiTitle
#   S2  no title at all: the first prompt is the fallback
#   S4  an aiTitle longer than the list can show
#   S5  two aiTitles: the later one is the title
#   S6  an aiTitle and a customTitle with an escaped quote: the custom one wins
$LongTitle = 'A title so long that the list has to cut it somewhere sensible before the end'
$projectsRoot = Join-Path $ClaudeHome 'projects'
# One entry per statement would be unrolled by @( ), so the entries are added
# one by one.
$transcripts = [System.Collections.Generic.List[hashtable]]::new()
$transcripts.Add(@{ Dir = 'p-shop'; Id = $S1; Lines = @('{"type":"user"}', ('{{"type":"ai-title","aiTitle":"Shop checkout fix","sessionId":"{0}"}}' -f $S1), '{"type":"assistant"}') })
$transcripts.Add(@{ Dir = 'p-api';  Id = $S2; Lines = @('{"type":"user"}') })
$transcripts.Add(@{ Dir = 'p-gone'; Id = $S4; Lines = @(('{{"type":"ai-title","aiTitle":"{0}","sessionId":"{1}"}}' -f $LongTitle, $S4)) })
$transcripts.Add(@{ Dir = 'p-a';    Id = $S5; Lines = @(('{{"type":"ai-title","aiTitle":"Bingo A, first title","sessionId":"{0}"}}' -f $S5), '{"type":"user"}', ('{{"type":"ai-title","aiTitle":"Bingo A, later title","sessionId":"{0}"}}' -f $S5)) })
$transcripts.Add(@{ Dir = 'p-b';    Id = $S6; Lines = @(('{{"type":"ai-title","aiTitle":"Bingo B by Claude","sessionId":"{0}"}}' -f $S6), ('{{"type":"custom-title","customTitle":"Bingo \"B\" renamed","sessionId":"{0}"}}' -f $S6)) })
foreach ($t in $transcripts) {
    $dir = Join-Path $projectsRoot $t.Dir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -LiteralPath (Join-Path $dir "$($t.Id).jsonl") -Value (@($t.Lines) -join "`n") -Encoding utf8
}
$env:CLAUDE_CONFIG_DIR = $ClaudeHome

# A declared state whose terminal and agents are all pwsh, so the gates before
# a launch pass on any machine and -WhatIf is what stops it.
Set-Content -LiteralPath $FixturePath -Encoding utf8 -Value @"
@{
    Name = 'qa-sessions'; Version = '0.0.0'; Description = 'fixture'
    Tools = @(
        @{ Name = 'Stand-in terminal'; Purpose = 'Terminal'; Command = 'pwsh'; Required = `$true; Role = 'terminal'
           WindowsInstall = 'x'; LinuxInstall = 'x' }
    )
    Links = @()
    PowerShellProfile = @{ Name = 'qa profile'; OpenMarker = '# >>> qa >>>'; CloseMarker = '# <<< qa <<<' }
    Agents = @(
        @{ Name = 'claude'; Command = 'pwsh'; Product = 'stand-in'; WindowsInstall = 'x'; LinuxInstall = 'x' }
        @{ Name = 'codex';  Command = 'pwsh'; Product = 'stand-in'; WindowsInstall = 'x'; LinuxInstall = 'x' }
    )
}
"@
$env:WORKSTATION_DECLARED_STATE = $FixturePath

Write-Host ''
Write-Host '  WORKSTATION — SESSION QA' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray
Write-Host "  fixture:    $TempRoot" -ForegroundColor DarkGray

Import-Module $ModulePath -Force -ErrorAction Stop

# ===========================================================================
Set-Group 'Group S1 - nothing is positional, and the parameters exclude each other'

$parameters = (Get-Command Start-Workstation).Parameters
Confirm-That 'S01' '-Directory is gone; the parameter is -Project' `
    ($parameters.ContainsKey('Project') -and -not $parameters.ContainsKey('Directory'))

$positional = $false
try { Start-Workstation codex -WhatIf -ErrorAction Stop | Out-Null } catch { $positional = $_.Exception.Message }
Confirm-That 'S02' 'ws codex is rejected: the agent must be named with -Agent' `
    ($positional -is [string] -and $positional -match 'positional') "got: $positional"

$positional = $false
try { Start-Workstation 3 -WhatIf -ErrorAction Stop | Out-Null } catch { $positional = $_.Exception.Message }
Confirm-That 'S03' 'ws 3 is rejected: a session must be named with -Session' `
    ($positional -is [string] -and $positional -match 'positional') "got: $positional"

$together = $false
try { Start-Workstation -Project $ShopDir -Session 1 -WhatIf -ErrorAction Stop | Out-Null } catch { $together = $true }
Confirm-That 'S04' '-Project and -Session together are rejected' $together

$together = $false
try { Start-Workstation -List -Project $ShopDir -ErrorAction Stop | Out-Null } catch { $together = $true }
Confirm-That 'S05' '-List and -Project together are rejected' $together

$together = $false
try { Start-Workstation -List -Session 1 -ErrorAction Stop | Out-Null } catch { $together = $true }
Confirm-That 'S06' '-List and -Session together are rejected' $together

$agents = $parameters['Agent'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } | Select-Object -ExpandProperty ValidValues
Confirm-That 'S07' 'the four agents are still selectable through -Agent' `
    ((@('claude', 'codex', 'antigravity', 'opencode') | Where-Object { $_ -in $agents }).Count -eq 4)

# ===========================================================================
Set-Group 'Group S2 - the list: recent Claude sessions, numbered'

$warnings = @()
$rows = @(Start-Workstation -List -PassThru -WarningVariable warnings -WarningAction SilentlyContinue 6>$null)

Confirm-That 'S10' 'the list holds every session that still has a file, newest first' `
    ($rows.Count -eq 5 -and (($rows | ForEach-Object { $_.SessionId }) -join ',') -eq "$S6,$S5,$S4,$S2,$S1") `
    "got: $(($rows | ForEach-Object { $_.SessionId.Substring(0, 8) }) -join ', ')"
Confirm-That 'S11' 'rows are numbered from 1 in that order' `
    ((($rows | ForEach-Object { $_.Id }) -join ',') -eq '1,2,3,4,5')
Confirm-That 'S12' 'a session removed by retention is not listed, however recent' `
    ($S3 -notin @($rows | ForEach-Object { $_.SessionId }))
function Get-Row { param($Id) return @($rows | Where-Object { $_.SessionId -eq $Id })[0] }

Confirm-That 'S13' 'the title is the short title Claude gave the conversation, not the first prompt' `
    ((Get-Row $S1).Title -eq 'Shop checkout fix') "got: $((Get-Row $S1).Title)"
Confirm-That 'S13b' 'with no title in the transcript, the first prompt is the fallback, not the last' `
    ((Get-Row $S2).Title -eq 'fix the api') "got: $((Get-Row $S2).Title)"
Confirm-That 'S13c' 'the later of two titles wins, because Claude retitles as the conversation goes' `
    ((Get-Row $S5).Title -eq 'Bingo A, later title') "got: $((Get-Row $S5).Title)"
Confirm-That 'S13d' 'a title the user set wins over the one Claude gave, and its escapes are undone' `
    ((Get-Row $S6).Title -eq 'Bingo "B" renamed') "got: $((Get-Row $S6).Title)"
Confirm-That 'S14' 'the last-used time is the latest prompt of the session' `
    ((Get-Row $S1).LastUsed -eq [DateTimeOffset]::FromUnixTimeMilliseconds(2000000).LocalDateTime)
Confirm-That 'S15' 'the fallback title is trimmed and its whitespace collapsed' `
    ((Get-Row $S2).Title -eq 'fix the api') "got: '$((Get-Row $S2).Title)'"
Confirm-That 'S16' 'the project is the directory name and the directory is the full path' `
    ((@($rows | Where-Object { $_.SessionId -eq $S2 })[0]).Project -eq 'billing-api' -and (@($rows | Where-Object { $_.SessionId -eq $S2 })[0]).Directory -eq $ApiDir)
Confirm-That 'S17' 'a session whose directory no longer exists is listed but marked unavailable' `
    ((@($rows | Where-Object { $_.SessionId -eq $S4 })[0]).Available -eq $false -and (@($rows | Where-Object { $_.SessionId -eq $S2 })[0]).Available -eq $true)
Confirm-That 'S18' 'a line that is not JSON is skipped and counted in a warning, not fatal' `
    ($warnings.Count -eq 1 -and ($warnings[0].ToString() -match '1 line') -and ($warnings[0].ToString() -match 'history\.jsonl')) `
    "warnings: $(($warnings | ForEach-Object { $_.ToString() }) -join ' | ')"

$two = @(Start-Workstation -List -Limit 2 -PassThru -WarningAction SilentlyContinue 6>$null)
Confirm-That 'S19' '-Limit caps the list at the newest n' `
    ($two.Count -eq 2 -and $two[0].SessionId -eq $S6 -and $two[1].SessionId -eq $S5)

$printed = (Start-Workstation -List -WarningAction SilentlyContinue 6>&1 | Out-String)
Confirm-That 'S20' 'the printed list shows the number, the project and the title of each row' `
    ($printed -match '(?m)^\s*1\s+bingo\s+.*Bingo "B" renamed' -and $printed -match '(?m)^\s*5\s+shop\s+.*Shop checkout fix') `
    "printed: $($printed.Trim() -replace "`r?`n", ' | ')"
Confirm-That 'S21' 'and says how to continue one' ($printed -match 'ws -Session')
Confirm-That 'S22' 'and marks the row whose directory is missing' ($printed -match '(?m)^\s*3\s+gone-project\s+.*missing')
$cut = $LongTitle.Substring(0, 50).TrimEnd() + '...'
Confirm-That 'S23' 'a title longer than 50 characters is cut there with an ellipsis' `
    ($printed -match [regex]::Escape($cut) -and $printed -notmatch [regex]::Escape($LongTitle)) "printed: $($printed.Trim() -replace "`r?`n", ' | ')"
Confirm-That 'S24' 'while the row keeps the full title' ((Get-Row $S4).Title -eq $LongTitle)
$shownShop = if ($ShopDir.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) { '~' + $ShopDir.Substring($HOME.Length) } else { $ShopDir }
Confirm-That 'S25' 'each row ends with its directory, with the home directory shortened to ~' `
    ($printed -match ('(?m)^\s*5\s+shop\s+.*Shop checkout fix\s+' + [regex]::Escape($shownShop) + '\s*$')) `
    "expected '$shownShop' in: $(($printed -split "`r?`n" | Where-Object { $_ -match '^\s*5\s' }) -join ' | ')"

# ===========================================================================
Set-Group 'Group S3 - continuing a session'

$launch = Invoke-Start @{ Session = '2' }
Confirm-That 'S30' '-Session <n> resolves the n-th row of the last list printed here' `
    ($launch.Errors.Count -eq 0 -and $null -ne $launch.Result -and $launch.Result.Directory -is [string] -and $launch.Result.Directory -eq $BingoA -and $launch.Result.SessionId -eq $S5) `
    "errors: $($launch.Message) result: $($launch.Result | Out-String)"
Confirm-That 'S31' 'and the agent pane will run claude resuming that conversation' `
    ($null -ne $launch.Result -and $launch.Result.Agent -eq 'claude' -and $launch.Result.AgentCommand -match ('--resume ' + [regex]::Escape($S5) + '$')) `
    "command: $(if ($launch.Result) { $launch.Result.AgentCommand })"

$launch = Invoke-Start @{ Session = '3' }
Confirm-That 'S32' 'a session whose directory is gone is refused, naming the directory' `
    ($launch.Errors.Count -eq 1 -and $null -eq $launch.Result -and $launch.Message -match [regex]::Escape($GoneDir)) "message: $($launch.Message)"

$launch = Invoke-Start @{ Session = '9' }
Confirm-That 'S33' 'a number past the end of the last list is refused and the list size is named' `
    ($launch.Errors.Count -eq 1 -and $launch.Message -match '\b5\b' -and $launch.Message -match 'ws -List') "message: $($launch.Message)"

$launch = Invoke-Start @{ Session = '0' }
Confirm-That 'S34' 'zero is refused' ($launch.Errors.Count -eq 1 -and $null -eq $launch.Result)

$launch = Invoke-Start @{ Session = $S2 }
Confirm-That 'S35' 'a session id works without a list and resolves its own project' `
    ($launch.Errors.Count -eq 0 -and $null -ne $launch.Result -and $launch.Result.Directory -is [string] -and $launch.Result.Directory -eq $ApiDir -and $launch.Result.AgentCommand -match [regex]::Escape($S2)) `
    "errors: $($launch.Message)"

$launch = Invoke-Start @{ Session = 'no-such-session-0000' }
Confirm-That 'S36' 'an unknown session id is refused' ($launch.Errors.Count -eq 1 -and $null -eq $launch.Result) "message: $($launch.Message)"

$launch = Invoke-Start @{ Session = '1'; Agent = 'codex' }
Confirm-That 'S37' '-Session with an explicit agent other than claude is refused, naming claude' `
    ($launch.Errors.Count -eq 1 -and $launch.Message -match 'claude') "message: $($launch.Message)"

$launch = Invoke-Start @{ Session = '1'; Agent = 'claude' }
Confirm-That 'S38' '-Session with -Agent claude spelled out is fine' ($launch.Errors.Count -eq 0 -and $null -ne $launch.Result)

# Numbers belong to the terminal that printed them. A fresh process has no
# list, so a number there is refused rather than resolved against a list it
# never showed.
$fresh = & pwsh -NoProfile -Command "
    `$env:CLAUDE_CONFIG_DIR = '$ClaudeHome'; `$env:WORKSTATION_DECLARED_STATE = '$FixturePath'
    Import-Module '$ModulePath' -Force
    Start-Workstation -Session 1 -WhatIf -ErrorAction SilentlyContinue -ErrorVariable e 2>`$null | Out-Null
    (`$e | ForEach-Object { `$_.ToString() }) -join ' '
" 2>&1 | Out-String
Confirm-That 'S39' 'a number in a terminal that has printed no list is refused and told to list first' `
    ($fresh -match 'ws -List') "got: $($fresh.Trim())"

# Revalidated at launch, not trusted from the list: the file can vanish between
# the two commands.
Remove-Item -LiteralPath (Join-Path (Join-Path $projectsRoot 'p-a') "$S5.jsonl") -Force
$launch = Invoke-Start @{ Session = '2' }
Confirm-That 'S40' 'a listed session whose file has since vanished is refused at launch' `
    ($launch.Errors.Count -eq 1 -and $null -eq $launch.Result -and $launch.Message -match [regex]::Escape($S5)) "message: $($launch.Message)"

# ===========================================================================
Set-Group 'Group S4 - opening a project'

$launch = Invoke-Start @{ Project = 'shop' }
Confirm-That 'S50' 'a known project opens by name, in a new session' `
    ($launch.Errors.Count -eq 0 -and $null -ne $launch.Result -and $launch.Result.Directory -is [string] -and $launch.Result.Directory -eq $ShopDir -and [string]::IsNullOrEmpty($launch.Result.SessionId)) `
    "errors: $($launch.Message)"
Confirm-That 'S51' 'and the agent pane runs the agent bare, with nothing to resume' `
    ($null -ne $launch.Result -and $launch.Result.AgentCommand -notmatch 'resume')

$launch = Invoke-Start @{ Project = 'SHOP' }
Confirm-That 'S52' 'the name is matched regardless of case' ($launch.Errors.Count -eq 0 -and $null -ne $launch.Result -and $launch.Result.Directory -eq $ShopDir)

$launch = Invoke-Start @{ Project = 'bingo' }
Confirm-That 'S53' 'an ambiguous name is refused and both directories are shown' `
    ($launch.Errors.Count -eq 1 -and $null -eq $launch.Result -and $launch.Message -match [regex]::Escape($BingoA) -and $launch.Message -match [regex]::Escape($BingoB)) `
    "message: $($launch.Message)"

$launch = Invoke-Start @{ Project = 'never-heard-of-it' }
Confirm-That 'S54' 'an unknown name is refused and a path is suggested instead' `
    ($launch.Errors.Count -eq 1 -and $launch.Message -match 'never-heard-of-it' -and $launch.Message -match '-Project') "message: $($launch.Message)"

$launch = Invoke-Start @{ Project = $BingoB }
Confirm-That 'S55' 'a full path opens that directory, ambiguity or not' ($launch.Errors.Count -eq 0 -and $null -ne $launch.Result -and $launch.Result.Directory -is [string] -and $launch.Result.Directory -eq $BingoB)

Push-Location $TempRoot
$launch = Invoke-Start @{ Project = (Join-Path '.' 'shop') }
Pop-Location
Confirm-That 'S56' 'a relative path is a path, resolved from the current directory' ($launch.Errors.Count -eq 0 -and $null -ne $launch.Result -and $launch.Result.Directory -eq $ShopDir)

$launch = Invoke-Start @{ Project = (Join-Path $TempRoot 'does-not-exist') }
Confirm-That 'S57' 'a path that does not exist is refused with exactly one error' ($launch.Errors.Count -eq 1 -and $null -eq $launch.Result) "message: $($launch.Message)"

Push-Location $ApiDir
$launch = Invoke-Start @{}
Pop-Location
Confirm-That 'S58' 'with no -Project, the current directory is the project' ($launch.Errors.Count -eq 0 -and $null -ne $launch.Result -and $launch.Result.Directory -eq $ApiDir)

$launch = Invoke-Start @{ Project = $ShopDir; Agent = 'codex' }
Confirm-That 'S59' '-Agent picks the agent for a new session' ($launch.Errors.Count -eq 0 -and $null -ne $launch.Result -and $launch.Result.Agent -eq 'codex')

# ===========================================================================
Set-Group 'Group S5 - a -WhatIf launches nothing and leaves nothing behind'

$before = @(Get-Process pwsh -ErrorAction Ignore | ForEach-Object { $_.Id })
Start-Workstation -Project $ShopDir -WhatIf -WarningAction SilentlyContinue | Out-Null
$after = @(Get-Process pwsh -ErrorAction Ignore | ForEach-Object { $_.Id })
Confirm-That 'S60' 'no process was started' (@($after | Where-Object { $_ -notin $before }).Count -eq 0)
Confirm-That 'S61' 'the launch environment variables are not left set' `
    ([string]::IsNullOrEmpty($env:WORKSTATION_AGENT) -and [string]::IsNullOrEmpty($env:WORKSTATION_DIRECTORY))

# ===========================================================================
Set-Group 'Group S6 - an empty or absent history is a state, not a failure'

$emptyHome = Join-Path $TempRoot 'empty-home'
New-Item -ItemType Directory -Force -Path $emptyHome | Out-Null
$env:CLAUDE_CONFIG_DIR = $emptyHome
$errors = $null
$none = @(Start-Workstation -List -PassThru -ErrorAction SilentlyContinue -ErrorVariable errors 6>$null)
Confirm-That 'S70' 'with no history file the list is empty and there is no error' ($none.Count -eq 0 -and @($errors).Count -eq 0)
$printedNone = (Start-Workstation -List 6>&1 | Out-String)
Confirm-That 'S71' 'and it says so, naming where it looked' ($printedNone -match 'No Claude sessions' -and $printedNone -match [regex]::Escape($emptyHome)) "printed: $($printedNone.Trim())"

# ===========================================================================
Set-Group 'Cleanup'
$env:CLAUDE_CONFIG_DIR = $null
$env:WORKSTATION_DECLARED_STATE = $null
Remove-Module Workstation -Force -ErrorAction Ignore
Remove-Item -Recurse -Force $TempRoot -ErrorAction Ignore
Confirm-That 'S99' 'the fixture is gone' (-not (Test-Path $TempRoot))

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
