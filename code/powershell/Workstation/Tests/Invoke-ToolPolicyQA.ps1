#Requires -Version 7.0
<#
    QA for the tool-installation policy. Runs on Windows, Linux and macOS.

    ADR-0006 promoted installing a declared tool to an ordinary step: there is
    no longer a flag deciding whether tool installs appear in the list, because
    -Plan and -Apply already are the consent gate (ADR-0003).

    This suite asserts the properties that make that safe:

      * the flag is gone, so plan, apply and check build one identical list
      * a tool we can install here is Pending and carries an action
      * a tool we cannot install here is Missing and carries a hint
      * building the list never runs an action
      * Missing counts as drift, in every command that counts anything
      * the closing advice after an apply never invites you into a workspace
        that cannot open

    Every assertion runs against a fixture named by WORKSTATION_DECLARED_STATE,
    so the suite never installs anything and never touches the real machine.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code/powershell/Workstation'
$TempRoot       = [System.IO.Path]::GetTempPath()
$FixturePath    = Join-Path $TempRoot 'qa-tool-policy-state.psd1'

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

# A fixture declares no links and no generated artifacts, so the only steps it
# can produce are tools, the profile block and agents. The profile block is
# left in whatever state the machine already has it: the suite reads it, never
# writes it.
function Set-Fixture {
    param(
        [Parameter(Mandatory)][string] $ToolsBody,
        [string] $LinksBody = '',
        # The real markers leave the profile step InSync on an installed
        # machine, so a fixture can produce a pending step that is not the
        # profile. The suite never writes the profile either way.
        [switch] $RealProfileMarkers
    )
    $open  = if ($RealProfileMarkers) { '# >>> workstation >>>' } else { '# >>> qa >>>' }
    $close = if ($RealProfileMarkers) { '# <<< workstation <<<' } else { '# <<< qa <<<' }
    Set-Content -LiteralPath $FixturePath -Encoding utf8 -Value @"
@{
    Name = 'qa-tool-policy'; Version = '0.0.0'; Description = 'fixture'
    Tools = @(
$ToolsBody
    )
    Links = @(
$LinksBody
    )
    PowerShellProfile = @{ Name = 'qa profile'; OpenMarker = '$open'; CloseMarker = '$close' }
    Agents = @()
}
"@
    $env:WORKSTATION_DECLARED_STATE = $FixturePath
}
function Clear-Fixture {
    $env:WORKSTATION_DECLARED_STATE = $null
    Remove-Item -LiteralPath $FixturePath -Force -ErrorAction Ignore
}

# Reaches a private function without exporting it. The module's own scope is
# the only place these live, and the suite asserts on them directly rather
# than inferring their behaviour from printed output.
function Use-ModuleScope {
    param([Parameter(Mandatory)][scriptblock] $Body, [object[]] $Arguments = @())
    $module = Get-Module Workstation
    return & $module $Body @Arguments
}

function Get-ToolStep {
    param([Parameter(Mandatory)][string] $Name)
    $steps = Test-Workstation -PassThru 6>$null
    return @($steps | Where-Object { $_.Kind -eq 'tool' -and $_.Name -eq $Name })[0]
}

Write-Host ''
Write-Host '  WORKSTATION — TOOL POLICY QA' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray
Write-Host "  platform:   $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim())" -ForegroundColor DarkGray

Import-Module $ModulePath -Force -ErrorAction Stop
Clear-Fixture

# Whether this machine can install a tool for you at all. Every state
# assertion below branches on it, because the policy is a capability rule now
# and a capability rule has to be asserted against the real capability.
$CanInstallHere = [bool] $IsWindows -and ($null -ne (Get-Command 'winget' -ErrorAction Ignore))
Write-Host "  can install here: $CanInstallHere" -ForegroundColor DarkGray

# ===========================================================================
Set-Group 'Group T1 — the opt-in flag is gone'

$installParameters = (Get-Command Install-Workstation).Parameters.Keys
Confirm-That 'T01' 'Install-Workstation no longer takes -InstallMissingTools' `
    ('InstallMissingTools' -notin $installParameters) `
    "parameters: $($installParameters -join ', ')"

$stepListParameters = @(Use-ModuleScope { (Get-Command Get-WorkstationStepList).Parameters.Keys | Where-Object { $_ -notin [System.Management.Automation.PSCmdlet]::CommonParameters } })
Confirm-That 'T02' 'Get-WorkstationStepList takes no parameters at all' `
    ($stepListParameters.Count -eq 0) `
    "parameters: $($stepListParameters -join ', ')"

$moduleText = Get-Content -LiteralPath (Join-Path $ModulePath 'Workstation.psm1') -Raw
Confirm-That 'T03' 'the module source never mentions the flag' `
    ($moduleText -notmatch 'InstallMissingTools')

$declaredText = Get-Content -LiteralPath (Join-Path $ModulePath 'DeclaredState.psd1') -Raw
Confirm-That 'T04' 'the declared state header no longer states the old rule' `
    ($declaredText -notmatch 'InstallMissingTools')

# ===========================================================================
Set-Group 'Group T2 — a tool we can install here is an ordinary pending step'

Set-Fixture @"
        @{
            Name           = 'InstallableGhost'
            Purpose        = 'a tool that cannot exist'
            Command        = 'workstation-qa-absent-tool'
            WindowsInstall = 'winget install --id Fake.Tool --exact'
            LinuxInstall   = 'sudo apt install fake-tool'
        }
"@

$ghost = Get-ToolStep -Name 'InstallableGhost'
Confirm-That 'T05' 'the fixture produces a tool step' ($null -ne $ghost)

$expectedState = if ($CanInstallHere) { 'Pending' } else { 'Missing' }
Confirm-That 'T06' "a missing tool is $expectedState on this platform, with no flag passed" `
    ($null -ne $ghost -and $ghost.State -eq $expectedState) `
    "state: $(if ($ghost) { $ghost.State })"

if ($CanInstallHere) {
    Confirm-That 'T07' 'the pending tool step carries an action' `
        ($null -ne $ghost -and $null -ne $ghost.Action)
    Confirm-That 'T08' 'the detail names the winget identifier it would install' `
        ($null -ne $ghost -and $ghost.Detail -match 'Fake\.Tool') `
        "detail: $(if ($ghost) { $ghost.Detail })"
    Confirm-That 'T09' 'the detail never shows an empty identifier' `
        ($null -ne $ghost -and $ghost.Detail -notmatch "--id\s*''" -and $ghost.Detail -notmatch ':\s*$') `
        "detail: $(if ($ghost) { $ghost.Detail })"
}
else {
    Confirm-That 'T07' 'a tool we cannot install here carries no action' `
        ($null -ne $ghost -and $null -eq $ghost.Action)
    Confirm-That 'T08' 'and carries the hint for this platform instead' `
        ($null -ne $ghost -and $ghost.Hint -match 'apt install fake-tool') `
        "hint: $(if ($ghost) { $ghost.Hint })"
    Confirm-That 'T09' 'and never the other platform''s hint' `
        ($null -ne $ghost -and $ghost.Hint -notmatch 'winget')
}

# ===========================================================================
Set-Group 'Group T3 — building the list never runs an action'

# Fake.Tool does not exist in any winget source. If building the list ran the
# action, the command would be attempted; the tool would still be absent, so
# absence alone proves little — but an attempted install takes seconds and
# writes to the console, and the step list is built here ten times over.
$before = $null -ne (Get-Command 'workstation-qa-absent-tool' -ErrorAction Ignore)
1..10 | ForEach-Object { Test-Workstation -PassThru 6>$null | Out-Null }
$after = $null -ne (Get-Command 'workstation-qa-absent-tool' -ErrorAction Ignore)
Confirm-That 'T10' 'ten step-list builds install nothing' `
    ((-not $before) -and (-not $after))

$planOutput = Install-Workstation -Plan 6>&1 | Out-String
Confirm-That 'T11' 'a plan prints the tool step without performing it' `
    ($planOutput -match 'InstallableGhost' -and -not (Get-Command 'workstation-qa-absent-tool' -ErrorAction Ignore))

# ===========================================================================
Set-Group 'Group T4 — plan and check describe the same machine'

# The plan file is the rendered report. Parsing it back and comparing against
# the step list Test-Workstation returns proves the two commands cannot
# disagree, which is the property the removed flag used to break.
$PlansDirectory = Join-Path $RepositoryRoot '.workstation/plans'
$planFile = Get-ChildItem -LiteralPath $PlansDirectory -Filter '*.txt' -ErrorAction Ignore |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

$planStates = @{}
if ($null -ne $planFile) {
    foreach ($line in (Get-Content -LiteralPath $planFile.FullName)) {
        if ($line -match '^\s*\[(in sync|pending|missing|blocked)\s*\]\s+(.+?)\s*$') {
            $planStates[$Matches[2]] = $Matches[1]
        }
    }
}
Confirm-That 'T12' 'the plan file was written and holds labelled steps' `
    ($null -ne $planFile -and $planStates.Count -gt 0) `
    "entries: $($planStates.Count)"

$labelFor = @{ InSync = 'in sync'; Pending = 'pending'; Missing = 'missing'; Blocked = 'blocked' }
$checkSteps = Test-Workstation -PassThru 6>$null
$disagreements = @($checkSteps | Where-Object {
    $planStates.ContainsKey($_.Name) -and $planStates[$_.Name] -ne $labelFor[$_.State]
})
Confirm-That 'T13' 'check and plan agree on the state of every step' `
    ($disagreements.Count -eq 0) `
    "disagreed: $(($disagreements | ForEach-Object { "$($_.Name)=$($_.State)" }) -join ', ')"

Confirm-That 'T14' 'check reported every step the plan did' `
    (@($checkSteps | Where-Object { -not $planStates.ContainsKey($_.Name) }).Count -eq 0)

# ===========================================================================
Set-Group 'Group T5 — the winget identifier is parsed defensively'

# A Windows tool whose install advice is not a winget one-liner cannot yield an
# identifier. It has to fall back to Missing rather than emit a step whose
# action would run `winget install --id '' --exact`.
Set-Fixture @"
        @{
            Name           = 'NotAWingetTool'
            Purpose        = 'installed by something other than winget'
            Command        = 'workstation-qa-absent-tool'
            WindowsInstall = 'Download the installer from https://example.invalid/setup.exe'
            LinuxInstall   = 'See https://example.invalid/linux'
        }
"@

$odd = Get-ToolStep -Name 'NotAWingetTool'
Confirm-That 'T15' 'a Windows tool with no --id in its advice is reported Missing' `
    ($null -ne $odd -and $odd.State -eq 'Missing') `
    "state: $(if ($odd) { $odd.State })"
Confirm-That 'T16' 'and carries no action that could run an empty install' `
    ($null -ne $odd -and $null -eq $odd.Action)
Confirm-That 'T17' 'and still prints the advice a human can follow' `
    ($null -ne $odd -and $odd.Hint -match 'example\.invalid')

# ===========================================================================
Set-Group 'Group T6 — Missing counts as drift'

# Every declared tool here is uninstallable on any platform, so the fixture
# produces Missing steps on Windows and on Linux alike.
Set-Fixture @"
        @{
            Name           = 'UninstallableGhost'
            Purpose        = 'a tool no package manager here can supply'
            Command        = 'workstation-qa-absent-tool'
            WindowsInstall = 'Download it yourself from https://example.invalid'
            LinuxInstall   = 'Build it yourself from https://example.invalid'
        }
"@

$summary = Use-ModuleScope { Get-StepSummary -Steps (Get-WorkstationStepList) }
Confirm-That 'T18' 'the summary counts a missing tool' `
    ($null -ne $summary -and $summary.Missing -ge 1) `
    "missing: $(if ($summary) { $summary.Missing })"
Confirm-That 'T19' 'the summary reports whether anything at all differs' `
    ($null -ne $summary -and $summary.Differences -ge 1) `
    "differences: $(if ($summary) { $summary.Differences })"

$checkOutput = Test-Workstation 6>&1 | Out-String
Confirm-That 'T20' 'check does not claim the machine is in sync while a tool is missing' `
    ($checkOutput -notmatch 'In sync with the declared state') `
    "output tail: $(($checkOutput -split "`n" | Select-Object -Last 3) -join ' | ')"
Confirm-That 'T21' 'check names the missing tool as a difference' `
    ($checkOutput -match 'missing' -and $checkOutput -match 'UninstallableGhost')

$planOutput = Install-Workstation -Plan 6>&1 | Out-String
Confirm-That 'T22' 'a plan states how many tools it cannot install for you' `
    ($planOutput -match '(?i)missing') `
    "output: $(($planOutput -split "`n" | Select-Object -Last 5) -join ' | ')"

# Missing on its own is drift, with nothing else pending to carry it.
$onlyMissing = Use-ModuleScope {
    ,@((New-WorkstationStep -Kind 'tool' -Name 'Ghost' -State 'Missing' -Detail 'x' -Hint 'y'))
}
$onlySummary = Use-ModuleScope -Arguments @(, $onlyMissing) -Body { param($s) Get-StepSummary -Steps $s }
Confirm-That 'T23' 'a list whose only difference is Missing still counts as drift' `
    ($onlySummary.Pending -eq 0 -and $onlySummary.Missing -eq 1 -and $onlySummary.Differences -eq 1) `
    "pending=$($onlySummary.Pending) missing=$($onlySummary.Missing) differences=$($onlySummary.Differences)"

$allInSync = Use-ModuleScope {
    ,@((New-WorkstationStep -Kind 'tool' -Name 'Ghost' -State 'InSync' -Detail 'x'))
}
$syncSummary = Use-ModuleScope -Arguments @(, $allInSync) -Body { param($s) Get-StepSummary -Steps $s }
Confirm-That 'T24' 'and a list with nothing to do counts as no drift' `
    ($syncSummary.Differences -eq 0 -and $syncSummary.InSync -eq 1)

# ===========================================================================
Set-Group 'Group T7 — the closing advice never invites a workspace that cannot open'

# Built from synthetic step lists rather than by applying anything, so the
# advice is asserted directly instead of being inferred from a machine that
# would have to be broken first.
function New-SyntheticSteps {
    param([Parameter(Mandatory)][hashtable] $ToolStates)
    return Use-ModuleScope -Arguments @($ToolStates) -Body {
        param($states)
        $steps = [System.Collections.Generic.List[object]]::new()
        foreach ($name in $states.Keys) {
            $steps.Add((New-WorkstationStep -Kind 'tool' -Name $name -State $states[$name] `
                        -Detail 'x' -Hint "install $name yourself" -Required))
        }
        return $steps.ToArray()
    }
}

$allPresent = New-SyntheticSteps -ToolStates @{ WezTerm = 'InSync'; Neovim = 'InSync' }
$advicePresent = Use-ModuleScope -Arguments @(, $allPresent) -Body { param($s) (Get-CompletionAdvice -Steps $s) -join "`n" }
Confirm-That 'T25' 'with every tool present the advice invites you to start' `
    ($advicePresent -match 'Start-Workstation') `
    "advice: $advicePresent"

$wezMissing = New-SyntheticSteps -ToolStates @{ WezTerm = 'Missing'; Neovim = 'InSync' }
$adviceMissing = Use-ModuleScope -Arguments @(, $wezMissing) -Body { param($s) (Get-CompletionAdvice -Steps $s) -join "`n" }
Confirm-That 'T26' 'with WezTerm missing the advice never invites you to start' `
    ($adviceMissing -notmatch 'Start-Workstation') `
    "advice: $adviceMissing"
Confirm-That 'T27' 'and names what is still missing instead' `
    ($adviceMissing -match 'WezTerm') `
    "advice: $adviceMissing"

$nvimMissing = New-SyntheticSteps -ToolStates @{ WezTerm = 'InSync'; Neovim = 'Missing' }
$adviceNvim = Use-ModuleScope -Arguments @(, $nvimMissing) -Body { param($s) (Get-CompletionAdvice -Steps $s) -join "`n" }
Confirm-That 'T28' 'a missing Neovim also withholds the invitation' `
    ($adviceNvim -notmatch 'Start-Workstation' -and $adviceNvim -match 'Neovim') `
    "advice: $adviceNvim"

# A tool this run just installed reads as absent from the current session,
# because winget updates the machine PATH and this process never re-reads it.
# The advice has to trust the step it just performed, not a fresh lookup.
$justInstalled = New-SyntheticSteps -ToolStates @{ WezTerm = 'Pending'; Neovim = 'Pending' }
$adviceInstalled = Use-ModuleScope -Arguments @(, $justInstalled) -Body { param($s) (Get-CompletionAdvice -Steps $s) -join "`n" }
Confirm-That 'T29' 'a tool installed by this very run counts as present' `
    ($adviceInstalled -match 'Start-Workstation') `
    "advice: $adviceInstalled"
Confirm-That 'T30' 'and the advice still says to open a new terminal first' `
    ($adviceInstalled -match '(?i)new terminal') `
    "advice: $adviceInstalled"

# ===========================================================================
Set-Group 'Group T8 — the apply prints the advice it computed'

# Everything above tested Get-CompletionAdvice directly. This asserts that
# Install-Workstation actually uses it, by driving a real apply whose only
# pending step is a link into a temporary directory. The declared WezTerm
# cannot be installed on any platform, so the invitation must be withheld even
# though the apply itself succeeded.
$LinkTargetPath = Join-Path $TempRoot 'qa-tool-policy-link'

# Deleted as a directory entry, never recursively: the entry is a junction
# pointing at this repository's own assets, and a recursive delete that
# followed it would take the repository with it.
function Remove-QaLink {
    if (Test-Path -LiteralPath $LinkTargetPath) {
        [System.IO.Directory]::Delete($LinkTargetPath, $false)
    }
}
Remove-QaLink

$linkBody = @"
        @{
            Name         = 'QA link'
            Source       = 'assets/neovim'
            WindowsTarget = '$LinkTargetPath'
            LinuxTarget   = '$LinkTargetPath'
        }
"@

Set-Fixture -RealProfileMarkers -LinksBody $linkBody -ToolsBody @"
        @{
            Name           = 'WezTerm'
            Purpose        = 'Terminal with a native pane multiplexer'
            Command        = 'workstation-qa-absent-tool'
            Required       = `$true
            WindowsInstall = 'Download it yourself from https://example.invalid'
            LinuxInstall   = 'Build it yourself from https://example.invalid'
        }
"@

$applyOutput = Install-Workstation -Apply -AutoApprove 6>&1 | Out-String
Confirm-That 'T31' 'the apply performed the pending link' `
    (Test-Path -LiteralPath $LinkTargetPath) `
    "output: $applyOutput"
Confirm-That 'T32' 'and never invited you into a workspace that cannot open' `
    ($applyOutput -notmatch 'Start-Workstation') `
    "output: $(($applyOutput -split "`n" | Select-Object -Last 6) -join ' | ')"
Confirm-That 'T33' 'and named the tool that is still missing' `
    ($applyOutput -match 'WezTerm' -and $applyOutput -match 'example\.invalid') `
    "output: $(($applyOutput -split "`n" | Select-Object -Last 6) -join ' | ')"

# The same apply with the tool present. The link goes first, so there is once
# more a step to perform and the run reaches its closing advice rather than
# stopping at "nothing to do".
Remove-QaLink
Set-Fixture -RealProfileMarkers -LinksBody $linkBody -ToolsBody @"
        @{
            Name           = 'WezTerm'
            Purpose        = 'Terminal with a native pane multiplexer'
            Command        = 'pwsh'
            Required       = `$true
            WindowsInstall = 'Download it yourself from https://example.invalid'
            LinuxInstall   = 'Build it yourself from https://example.invalid'
        }
"@
$applyAgain = Install-Workstation -Apply -AutoApprove 6>&1 | Out-String
Confirm-That 'T34' 'with the required tool present the invitation comes back' `
    ($applyAgain -match 'Start-Workstation') `
    "output: $(($applyAgain -split "`n" | Select-Object -Last 6) -join ' | ')"

Remove-QaLink
Confirm-That 'T35' 'the temporary link was removed again' `
    (-not (Test-Path -LiteralPath $LinkTargetPath))
Confirm-That 'T35b' 'and removing it did not follow the junction into the repository' `
    (Test-Path -LiteralPath (Join-Path $RepositoryRoot 'code/assets/neovim/init.lua'))

# ===========================================================================
Set-Group 'Group T9 - a step that failed is not a step that was performed'

# The apply catches a failing action, prints it, and carries on. Until now the
# step kept the state the plan gave it, so a required tool whose install threw
# still read as Pending and Pending counts as satisfied - the closing advice
# would invite you into a workspace that could not open, which is the very
# defect ADR 0006 was written to remove, arriving by a second route.

$failedTool = Use-ModuleScope {
    ,@((New-WorkstationStep -Kind 'tool' -Name 'WezTerm' -State 'Failed' `
            -Detail 'install with winget: wez.wezterm' -Required))
}
$failedSummary = Use-ModuleScope -Arguments @(, $failedTool) -Body { param($s) Get-StepSummary -Steps $s }
Confirm-That 'T36' 'a failed step is counted as a failure' `
    ($failedSummary.Failed -eq 1) "failed: $($failedSummary.Failed)"
Confirm-That 'T37' 'and as a difference' `
    ($failedSummary.Differences -eq 1) "differences: $($failedSummary.Differences)"

# Exactly one unsatisfied tool is the case a collection-returning function
# gets wrong: PowerShell unrolls a one-element result on the way out, and
# every .Count on it then fails under Set-StrictMode. It is also the most
# common real shape - a machine missing one tool - so it is asserted directly.
$oneUnsatisfied = Use-ModuleScope -Arguments @(, $failedTool) -Body {
    param($s) (Get-UnsatisfiedRequiredTool -Steps $s).Count
}
Confirm-That 'T38a' 'a single unsatisfied tool is still returned as a collection' `
    ($oneUnsatisfied -eq 1) "count: $oneUnsatisfied"

$oneSatisfiedCheck = Use-ModuleScope -Arguments @(, $failedTool) -Body {
    param($s) Test-RequiredToolsSatisfied -Steps $s
}
Confirm-That 'T38b' 'and the satisfied test answers false rather than throwing' `
    ($oneSatisfiedCheck -eq $false) "answer: $oneSatisfiedCheck"

$failedAdvice = Use-ModuleScope -Arguments @(, $failedTool) -Body { param($s) (Get-CompletionAdvice -Steps $s) -join "`n" }
Confirm-That 'T38' 'a required tool whose install failed withholds the invitation' `
    ($failedAdvice -notmatch 'Start-Workstation') "advice: $failedAdvice"
Confirm-That 'T39' 'and is named, falling back to its detail since it carries no hint' `
    ($failedAdvice -match 'WezTerm' -and $failedAdvice -match 'wez\.wezterm') "advice: $failedAdvice"

# End to end: an action that throws must leave Failed on the list the apply
# then reports from. The fixture declares a link whose parent cannot be
# created, because a file sits where the directory would have to go. No
# network, no package manager, and deterministic on both platforms.
$blockingFile = Join-Path $TempRoot 'qa-tool-policy-blocker'
Set-Content -LiteralPath $blockingFile -Value 'not a directory' -Encoding utf8
$impossibleTarget = Join-Path $blockingFile 'child'

$impossibleLink = @"
        @{
            Name         = 'QA impossible link'
            Source       = 'assets/neovim'
            WindowsTarget = '$impossibleTarget'
            LinuxTarget   = '$impossibleTarget'
        }
"@

Set-Fixture -RealProfileMarkers -LinksBody $impossibleLink -ToolsBody @"
        @{
            Name           = 'WezTerm'
            Purpose        = 'Terminal with a native pane multiplexer'
            Command        = 'pwsh'
            Required       = `$true
            WindowsInstall = 'Download it yourself from https://example.invalid'
            LinuxInstall   = 'Build it yourself from https://example.invalid'
        }
"@

$failOutput = Install-Workstation -Apply -AutoApprove 6>&1 | Out-String
Confirm-That 'T40' 'the failing step is reported as failed, not as done' `
    ($failOutput -match '\[failed\s*\]\s*QA impossible link') `
    "output: $(($failOutput -split "`n" | Select-Object -Last 8) -join ' | ')"
Confirm-That 'T41' 'and the run says how many steps failed' `
    ($failOutput -match '1 step\(s\) failed') `
    "output: $(($failOutput -split "`n" | Select-Object -Last 8) -join ' | ')"
Confirm-That 'T42' 'and never claims the step was performed' `
    ($failOutput -notmatch '\[done\s*\]\s*QA impossible link')

# The state really is written back onto the list, not merely printed.
$afterFailure = Test-Workstation -PassThru 6>$null
$linkStep = @($afterFailure | Where-Object { $_.Name -eq 'QA impossible link' })[0]
Confirm-That 'T43' 'a fresh check still reports the step as not done' `
    ($null -ne $linkStep -and $linkStep.State -in @('Pending', 'Blocked', 'Failed')) `
    "state: $(if ($linkStep) { $linkStep.State })"

Remove-Item -LiteralPath $blockingFile -Force -ErrorAction Ignore
Confirm-That 'T44' 'the blocking fixture was removed' `
    (-not (Test-Path -LiteralPath $blockingFile))

# ===========================================================================
Set-Group 'Group T10 - Start-Workstation refuses on a missing required tool'

# A missing agent was refused and a missing WezTerm was refused, but a missing
# Neovim was not: the window opened and the editor pane failed inside it, where
# the message is easy to miss and impossible to act on. Required is declared,
# so the check can be the same rule for every tool that carries it.
#
# The fixture names a required tool that cannot exist and an agent that can, so
# the refusal has to come from the tool. Nothing is launched: the check runs
# before WezTerm is even resolved.

Set-Fixture -RealProfileMarkers -ToolsBody @"
        @{
            Name           = 'Ghost editor'
            Purpose        = 'Editor in the left pane'
            Command        = 'workstation-qa-absent-tool'
            Required       = `$true
            WindowsInstall = 'Download it yourself from https://example.invalid'
            LinuxInstall   = 'Build it yourself from https://example.invalid'
        }
"@
# The fixture's Agents list is empty, so an agent has to be declared for the
# refusal under test to be reachable at all.
$fixtureText = Get-Content -LiteralPath $FixturePath -Raw
$fixtureText = $fixtureText.Replace('Agents = @()', @"
Agents = @(
        @{ Name = 'claude'; Command = 'pwsh'; Product = 'stand-in'
           WindowsInstall = 'x'; LinuxInstall = 'x' }
    )
"@)
Set-Content -LiteralPath $FixturePath -Value $fixtureText -Encoding utf8

# Compared around the call, not asked of the machine. Whether a terminal is
# open somewhere is not this assertion's business, and a developer with one on
# screen should not see a red test for it.
$weztermBefore = @(Get-Process wezterm-gui -ErrorAction Ignore | ForEach-Object { $_.Id })

$startError = $null
Start-Workstation -Agent claude -Directory $TempRoot -ErrorAction SilentlyContinue -ErrorVariable startError 2>$null | Out-Null
$startMessage = ($startError | ForEach-Object { $_.ToString() }) -join ' '

Confirm-That 'T47' 'a missing required tool refuses the launch' `
    ($startError.Count -gt 0) "errors: $($startError.Count)"
Confirm-That 'T48' 'and the refusal names the tool and its command' `
    ($startMessage -match 'Ghost editor' -and $startMessage -match 'workstation-qa-absent-tool') `
    "message: $startMessage"
Confirm-That 'T49' 'and prints the command for this platform' `
    ($startMessage -match 'example\.invalid') "message: $startMessage"
$weztermAfter = @(Get-Process wezterm-gui -ErrorAction Ignore | ForEach-Object { $_.Id })
Confirm-That 'T50' 'and nothing was launched' `
    (@($weztermAfter | Where-Object { $_ -notin $weztermBefore }).Count -eq 0) `
    "wezterm before: $($weztermBefore.Count), after: $($weztermAfter.Count)"

# The same fixture with the tool present must not refuse for this reason. The
# launch is not performed; only the tool gate is exercised, by asking for a
# directory that does not exist so the command stops earlier for a reason of
# its own.
Set-Fixture -RealProfileMarkers -ToolsBody @"
        @{
            Name           = 'Present editor'
            Purpose        = 'Editor in the left pane'
            Command        = 'pwsh'
            Required       = `$true
            WindowsInstall = 'Download it yourself from https://example.invalid'
            LinuxInstall   = 'Build it yourself from https://example.invalid'
        }
"@
$fixtureText = (Get-Content -LiteralPath $FixturePath -Raw).Replace('Agents = @()', @"
Agents = @(
        @{ Name = 'claude'; Command = 'pwsh'; Product = 'stand-in'
           WindowsInstall = 'x'; LinuxInstall = 'x' }
    )
"@)
Set-Content -LiteralPath $FixturePath -Value $fixtureText -Encoding utf8

$otherError = $null
Start-Workstation -Agent claude -Directory 'no-such-directory-for-qa' -ErrorAction SilentlyContinue -ErrorVariable otherError 2>$null | Out-Null
$otherMessage = ($otherError | ForEach-Object { $_.ToString() }) -join ' '
Confirm-That 'T51' 'a present required tool is not what stops the launch' `
    ($otherMessage -notmatch 'is not installed') "message: $otherMessage"

# ===========================================================================
Set-Group 'Group T11 - a malformed declared state says so'

# WORKSTATION_DECLARED_STATE is a documented seam, so the file may be one
# someone wrote this morning. Under Set-StrictMode a missing key used to
# surface as "The property 'Tools' cannot be found on this object", which
# names neither the file, nor the seam, nor what was expected.

$brokenState = Join-Path $TempRoot 'qa-broken-declared-state.psd1'
Set-Content -LiteralPath $brokenState -Encoding utf8 `
    -Value "@{ Name = 'broken'; Version = '0.0.0'; Description = 'x' }"
$env:WORKSTATION_DECLARED_STATE = $brokenState

$shapeError = $null
try { Test-Workstation 6>$null | Out-Null } catch { $shapeError = $_.Exception.Message }

Confirm-That 'T52' 'a declared state missing required keys is refused' `
    ($null -ne $shapeError) "error: $shapeError"
Confirm-That 'T53' 'and every missing key is named at once' `
    ($null -ne $shapeError -and $shapeError -match 'Tools' -and $shapeError -match 'Links' -and
     $shapeError -match 'PowerShellProfile' -and $shapeError -match 'Agents') `
    "error: $shapeError"
Confirm-That 'T54' 'and the file is named' `
    ($null -ne $shapeError -and $shapeError -match [regex]::Escape($brokenState)) "error: $shapeError"
Confirm-That 'T55' 'and the seam is named, since that is what redirected it' `
    ($null -ne $shapeError -and $shapeError -match 'WORKSTATION_DECLARED_STATE') "error: $shapeError"
# Only the list itself, not the sentence after it that explains which keys are
# optional - those are named there on purpose.
$missingList = if ($null -ne $shapeError -and $shapeError -match 'is missing: ([^.]+)\.') { $Matches[1] } else { '' }
Confirm-That 'T56' 'and the optional keys are not reported as missing' `
    ($missingList -ne '' -and $missingList -notmatch 'GeneratedArtifacts' -and $missingList -notmatch 'Preferences') `
    "missing list: $missingList"

$env:WORKSTATION_DECLARED_STATE = $null
Remove-Item -LiteralPath $brokenState -Force -ErrorAction Ignore

# The real declared state must of course satisfy its own rule.
$realStateReadable = $true
try { Get-WorkstationPreference | Out-Null } catch { $realStateReadable = $false }
Confirm-That 'T57' 'the shipped declared state satisfies the shape it requires' $realStateReadable

# ===========================================================================
Set-Group 'Cleanup'
Clear-Fixture
$restored = Test-Workstation -PassThru 6>$null
Confirm-That 'T58' 'the real declared state is readable again after the fixtures' `
    (@($restored | Where-Object { $_.Kind -eq 'tool' -and $_.Name -eq 'WezTerm' }).Count -eq 1)
Confirm-That 'T59' 'and the suite installed nothing along the way' `
    ($null -eq (Get-Command 'workstation-qa-absent-tool' -ErrorAction Ignore))

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
