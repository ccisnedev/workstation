#Requires -Version 7.0
<#
    QA for the preference architecture. Runs on Windows, Linux and macOS.

    Asserts that taste is resolved separately from architecture, that an
    override merges rather than replaces, that the compiled artifact is
    regenerated when it drifts, and — the point of the whole exercise — that a
    preference actually reaches the running editor and terminal.

    Uses WORKSTATION_PREFERENCE_FILE throughout, so it never touches an
    override the user may really have.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code/powershell/Workstation'
$WezTermConfig  = Join-Path $RepositoryRoot 'code/assets/wezterm/wezterm.lua'
$TempRoot       = [System.IO.Path]::GetTempPath()
$OverrideFile   = Join-Path $TempRoot 'qa-workstation-preferences.psd1'
$ToolFreeState  = Join-Path $TempRoot 'qa-preference-tool-free-state.psd1'

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
function Set-Override {
    param([Parameter(Mandatory)][string] $Body)
    Set-Content -LiteralPath $OverrideFile -Value $Body -Encoding utf8
    $env:WORKSTATION_PREFERENCE_FILE = $OverrideFile
}
function Clear-Override {
    Remove-Item -LiteralPath $OverrideFile -Force -ErrorAction Ignore
    $env:WORKSTATION_PREFERENCE_FILE = $null
}

# ---------------------------------------------------------------------------
#  A declared state with no tools in it.
#
#  Installing a declared tool is an ordinary step now (ADR-0006), so a bare
#  `Install-Workstation -Apply` performs one. This suite mutates the real
#  machine and promises to restore it, and installing a terminal is not
#  something it could restore. It therefore runs against the real declared
#  state with the Tools block emptied, which is exactly what
#  WORKSTATION_DECLARED_STATE exists for.
#
#  The transform is verified rather than trusted: if the Tools block were not
#  emptied the suite aborts, because the failure mode is installing software
#  on someone's machine rather than a red assertion.
# ---------------------------------------------------------------------------
function Set-ToolFreeDeclaredState {
    $realText = Get-Content -LiteralPath (Join-Path $ModulePath 'DeclaredState.psd1') -Raw
    $stripped = [regex]::Replace($realText, '(?ms)^[ \t]*Tools[ \t]*=[ \t]*@\(.*?^[ \t]*\)[ \t]*\r?$', '    Tools = @()', 1)
    Set-Content -LiteralPath $ToolFreeState -Value $stripped -Encoding utf8
    $env:WORKSTATION_DECLARED_STATE = $ToolFreeState

    $toolSteps = @((Test-Workstation -PassThru 6>$null) | Where-Object { $_.Kind -eq 'tool' })
    if ($toolSteps.Count -ne 0) {
        $env:WORKSTATION_DECLARED_STATE = $null
        throw "The Tools block was not emptied; refusing to run a suite that would install software. Steps: $($toolSteps.Count)"
    }
}
function Clear-ToolFreeDeclaredState {
    $env:WORKSTATION_DECLARED_STATE = $null
    Remove-Item -LiteralPath $ToolFreeState -Force -ErrorAction Ignore
}

Write-Host ''
Write-Host '  WORKSTATION — PREFERENCE QA' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray
Write-Host "  platform:   $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim())" -ForegroundColor DarkGray

Import-Module $ModulePath -Force -ErrorAction Stop
Clear-Override
Set-ToolFreeDeclaredState

# ===========================================================================
Set-Group 'Group F1 — architecture and taste are separate files'

$declaredPath    = Join-Path $ModulePath 'DeclaredState.psd1'
$preferencesPath = Join-Path $ModulePath 'Preferences.psd1'
Confirm-That 'F01' 'the declared state and the preferences are two files' `
    ((Test-Path $declaredPath) -and (Test-Path $preferencesPath))

$declared = Import-PowerShellDataFile -Path $declaredPath
$prefs    = Import-PowerShellDataFile -Path $preferencesPath

$tasteWords = 'ColorScheme|FontFamily|FontSize|LeaderKey|TabWidth|PaneWidth|PaneHeight'
$declaredText = Get-Content -LiteralPath $declaredPath -Raw
Confirm-That 'F02' 'no taste leaked into the declared state' `
    (($declaredText -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -notmatch $tasteWords)

Confirm-That 'F03' 'the declared state still holds architecture' `
    ($declared.ContainsKey('Links') -and $declared.ContainsKey('Tools') -and $declared.ContainsKey('GeneratedArtifacts'))
Confirm-That 'F04' 'the preferences hold only taste sections' `
    ($prefs.ContainsKey('Layout') -and $prefs.ContainsKey('Terminal') -and $prefs.ContainsKey('Editor') `
     -and (-not $prefs.ContainsKey('Links')) -and (-not $prefs.ContainsKey('Tools')))
Confirm-That 'F05' 'the preferences carry a schema version, for later migration' `
    ($prefs.ContainsKey('Schema'))

# ===========================================================================
Set-Group 'Group F2 — resolution with no override'

$resolved = Get-WorkstationPreference
Confirm-That 'F06' 'shipped defaults resolve' `
    ($resolved.Terminal.ColorScheme -eq $prefs.Terminal.ColorScheme) "got: $($resolved.Terminal.ColorScheme)"
Confirm-That 'F07' 'the default agent comes from the preferences' `
    ($resolved.Workstation.DefaultAgent -eq $prefs.Workstation.DefaultAgent)

$agentDefault = (Get-Command Start-Workstation).Parameters['Agent'].Attributes |
    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
    Select-Object -ExpandProperty ValidValues
Confirm-That 'F08' 'the preferred default agent is one the declared state supports' `
    ($resolved.Workstation.DefaultAgent -in $agentDefault) "default: $($resolved.Workstation.DefaultAgent)"

# ===========================================================================
Set-Group 'Group F3 — an override merges, it does not replace'

Set-Override -Body @'
@{
    Terminal = @{ ColorScheme = 'QA Scheme' }
}
'@

$resolved = Get-WorkstationPreference
Confirm-That 'F09' 'the named key is overridden' ($resolved.Terminal.ColorScheme -eq 'QA Scheme')
Confirm-That 'F10' 'its siblings in the same section keep their defaults' `
    ($resolved.Terminal.FontFamily -eq $prefs.Terminal.FontFamily) "got: $($resolved.Terminal.FontFamily)"
Confirm-That 'F11' 'untouched sections keep their defaults' `
    ($resolved.Editor.TabWidth -eq $prefs.Editor.TabWidth)
Confirm-That 'F12' 'the shipped defaults file was not modified' `
    ((Import-PowerShellDataFile -Path $preferencesPath).Terminal.ColorScheme -eq $prefs.Terminal.ColorScheme)

# ===========================================================================
Set-Group 'Group F4 — the compiled artifact'

Install-Workstation -Apply -AutoApprove 6>$null | Out-Null

$artifact = @($declared.GeneratedArtifacts | Where-Object { $_.Name -eq 'Resolved preferences' })[0]
$targetKey = if ($IsWindows) { 'WindowsTarget' } else { 'LinuxTarget' }
$artifactDir = $artifact[$targetKey].Replace('{LOCALAPPDATA}', [string]$env:LOCALAPPDATA)
$artifactDir = $artifactDir.Replace('{XDG_CONFIG_HOME}', $(if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }))
if ($IsWindows) { $artifactDir = $artifactDir.Replace('/', '\') } else { $artifactDir = $artifactDir.Replace('\', '/') }
$artifactPath = Join-Path $artifactDir $artifact.FileName

Confirm-That 'F13' 'the compiled preferences exist' (Test-Path -LiteralPath $artifactPath) $artifactPath

$lua = Get-Content -LiteralPath $artifactPath -Raw
Confirm-That 'F14' 'the override value reached the compiled file' ($lua -match 'QA Scheme')
Confirm-That 'F15' 'keys are compiled to snake case' ($lua -match 'agent_pane_width')
Confirm-That 'F16' 'booleans are compiled as Lua booleans' ($lua -match 'maximize_on_start = (true|false)')
Confirm-That 'F17' 'the file says it is generated and must not be edited' ($lua -match 'DO NOT EDIT')

$insideRepository = $artifactPath.StartsWith($RepositoryRoot, [StringComparison]::OrdinalIgnoreCase)
Confirm-That 'F18' 'the generated file lands outside the repository' (-not $insideRepository) $artifactPath

# ===========================================================================
Set-Group 'Group F5 — decimal separator does not depend on the locale'

Set-Override -Body @'
@{
    Layout = @{ AgentPaneWidth = 0.45 }
}
'@
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$lua = Get-Content -LiteralPath $artifactPath -Raw
Confirm-That 'F19' 'a fractional preference is written with a dot' ($lua -match 'agent_pane_width = 0\.45')
Confirm-That 'F20' 'never with a comma, which Lua would read as two values' (-not ($lua -match 'agent_pane_width = 0,45'))

# ===========================================================================
Set-Group 'Group F6 — drift on the compiled artifact'

Set-Override -Body @'
@{
    Editor = @{ TabWidth = 8 }
}
'@
$drift = Test-Workstation -PassThru 6>$null
$generatedStep = @($drift | Where-Object { $_.Kind -eq 'generated' })[0]
Confirm-That 'F21' 'changing an override marks the artifact pending' ($generatedStep.State -eq 'Pending') "state: $($generatedStep.State)"
Confirm-That 'F22' 'the plan says it will refresh, not write from scratch' ($generatedStep.Detail -match 'refresh')

Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$drift = Test-Workstation -PassThru 6>$null
Confirm-That 'F23' 'after applying, the artifact is in sync' `
    (@($drift | Where-Object { $_.Kind -eq 'generated' })[0].State -eq 'InSync')

Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$drift = Test-Workstation -PassThru 6>$null
Confirm-That 'F24' 'a second apply regenerates nothing' `
    (@($drift | Where-Object { $_.State -eq 'Pending' }).Count -eq 0)

# ===========================================================================
Set-Group 'Group F7 — a preference reaches the running editor'

$env:WORKSTATION_PREFERENCES = $artifactPath
$env:NVIM_APPNAME = 'workstation'

$report = & nvim --headless '+lua io.write("shiftwidth=" .. vim.o.shiftwidth)' +q 2>&1 | Out-String
Confirm-That 'F25' 'TabWidth = 8 arrived in Neovim as shiftwidth' `
    ($report -match 'shiftwidth=8') "output: $($report.Trim() -replace "`n", ' | ')"

Confirm-That 'F26' 'Neovim started with no configuration error' `
    (-not ($report -match 'Failed to run|Error in command line|stacktrace|not found:|E5\d\d')) `
    "output: $($report.Trim() -replace "`n", ' | ')"

$treesitter = & nvim --headless '+lua local ok = pcall(require, "nvim-treesitter.configs"); io.write("configs=" .. tostring(ok))' +q 2>&1 | Out-String
Confirm-That 'F27' 'the syntax highlighting plugin exposes the API the config calls' `
    ($treesitter -match 'configs=True') "output: $($treesitter.Trim() -replace "`n", ' | ')"

$env:NVIM_APPNAME = $null

# ===========================================================================
Set-Group 'Group F8 — a preference reaches the terminal'

Set-Override -Body @'
@{
    Terminal = @{ FontFamily = 'Consolas' }
    Editor   = @{ TabWidth = 8 }
}
'@
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$env:WORKSTATION_PREFERENCES = $artifactPath

$weztermCommand = Get-Command wezterm -ErrorAction Ignore
if ($null -eq $weztermCommand) {
    Confirm-That 'F28' 'WezTerm is available to verify the font preference' $false 'wezterm not installed; test skipped'
}
else {
    $fonts = & $weztermCommand.Source --config-file $WezTermConfig ls-fonts 2>&1 | Out-String
    Confirm-That 'F28' 'the preferred font reached WezTerm' ($fonts -match 'Consolas') `
        "first lines: $((($fonts -split "`n") | Select-Object -First 4) -join ' | ')"
    Confirm-That 'F29' 'WezTerm loaded the configuration without error' `
        (-not ($fonts -match 'error|Error')) "output: $($fonts.Substring(0, [Math]::Min(200, $fonts.Length)))"
}

$env:WORKSTATION_PREFERENCES = $null

# ===========================================================================
Set-Group 'Group F9 — removing the override returns to the defaults'

Clear-Override
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$resolved = Get-WorkstationPreference
Confirm-That 'F30' 'the resolved values are the shipped defaults again' `
    (($resolved.Terminal.ColorScheme -eq $prefs.Terminal.ColorScheme) -and `
     ($resolved.Editor.TabWidth -eq $prefs.Editor.TabWidth))

$lua = Get-Content -LiteralPath $artifactPath -Raw
Confirm-That 'F31' 'the compiled file no longer carries the override value' (-not ($lua -match 'QA Scheme'))

$drift = Test-Workstation -PassThru 6>$null
Confirm-That 'F32' 'the machine is in sync on the defaults' `
    (@($drift | Where-Object { $_.State -in @('Pending','Blocked') }).Count -eq 0)

# ===========================================================================
Set-Group 'Group F10 — the configuration seams'

$env:WORKSTATION_PREFERENCE_FILE = $null
$declaredOverride = Get-WorkstationPreference
Confirm-That 'F33' 'with no seam set, resolution still works' ($null -ne $declaredOverride)

Set-Override -Body '@{ Editor = @{ TabWidth = 3 } }'
Confirm-That 'F34' 'WORKSTATION_PREFERENCE_FILE redirects the override' `
    ((Get-WorkstationPreference).Editor.TabWidth -eq 3)
Clear-Override

$fakeState = Join-Path $TempRoot 'qa-declared-state.psd1'
Set-Content -LiteralPath $fakeState -Encoding utf8 -Value @'
@{
    Name = 'qa'; Version = '0.0.0'; Description = 'fixture'
    Tools = @(
        @{
            Name           = 'DefinitelyNotInstalled'
            Purpose        = 'a tool that cannot exist'
            Command        = 'workstation-qa-absent-tool'
            WindowsInstall = 'winget install --id Fake.Tool --exact'
            LinuxInstall   = 'sudo apt install fake-tool'
        }
    )
    Links = @()
    PowerShellProfile = @{ Name = 'x'; OpenMarker = '# >>> qa >>>'; CloseMarker = '# <<< qa <<<' }
    Agents = @(
        @{ Name = 'ghost'; Command = 'workstation-qa-absent-agent'; Product = 'Ghost'
           WindowsInstall = 'irm https://example.invalid/win | iex'
           LinuxInstall   = 'curl -fsSL https://example.invalid/linux | bash' }
    )
}
'@
$env:WORKSTATION_DECLARED_STATE = $fakeState
$fixtureDrift = Test-Workstation -PassThru 6>$null

$toolStep = @($fixtureDrift | Where-Object { $_.Kind -eq 'tool' -and $_.Name -eq 'DefinitelyNotInstalled' })[0]
Confirm-That 'F35' 'WORKSTATION_DECLARED_STATE redirects the declared state' ($null -ne $toolStep)
# Whether this machine can install a tool at all. Since ADR-0006 the state of
# a missing tool is a capability answer, not a policy answer.
$canInstallHere = [bool] $IsWindows -and ($null -ne (Get-Command 'winget' -ErrorAction Ignore))
$expectedToolState = if ($canInstallHere) { 'Pending' } else { 'Missing' }
Confirm-That 'F36' "a tool that cannot exist is reported $expectedToolState on this platform" `
    ($null -ne $toolStep -and $toolStep.State -eq $expectedToolState) `
    "state: $(if ($toolStep) { $toolStep.State })"
Confirm-That 'F36b' 'and reading the state list never installed it' `
    ($null -eq (Get-Command 'workstation-qa-absent-tool' -ErrorAction Ignore))

# The advice a tool step carries is the one for this platform. Where the step
# is Pending it lives in the detail, as the identifier about to be installed;
# where it is Missing it lives in the hint, as the command for a human to run.
# The property under test is the platform, not the field it arrives in.
$expectedAdvice  = if ($IsWindows) { 'Fake.Tool' } else { 'sudo apt install' }
$forbiddenAdvice = if ($IsWindows) { 'sudo apt install' } else { 'winget' }
$toolAdvice = if ($null -ne $toolStep) { "$($toolStep.Detail) $($toolStep.Hint)" } else { '' }
Confirm-That 'F37' "the advice is the one for this platform ($expectedAdvice)" `
    ($null -ne $toolStep -and $toolAdvice -match [regex]::Escape($expectedAdvice)) "advice: $toolAdvice"
Confirm-That 'F38' 'and never the other platform''s' `
    ($null -ne $toolStep -and $toolAdvice -notmatch [regex]::Escape($forbiddenAdvice)) "advice: $toolAdvice"

$agentStep = @($fixtureDrift | Where-Object { $_.Kind -eq 'agent' -and $_.Name -eq 'ghost' })[0]
$expectedAgentHint = if ($IsWindows) { 'irm https' } else { 'curl -fsSL' }
Confirm-That 'F39' 'an absent agent gets the install command for this platform' `
    ($null -ne $agentStep -and $agentStep.State -eq 'Missing' -and $agentStep.Hint -match [regex]::Escape($expectedAgentHint)) `
    "hint: $($agentStep.Hint)"

$env:WORKSTATION_DECLARED_STATE = $ToolFreeState
Remove-Item -LiteralPath $fakeState -Force -ErrorAction Ignore

# ===========================================================================
Set-Group 'Group F9 - the Lua fallbacks match the shipped defaults'

# Both Lua files carry a DEFAULT_PREFERENCES table, so the workspace still
# opens when nothing has been compiled yet - a fresh clone, or wezterm run by
# hand with --config-file. That is a second copy of every shipped default, and
# until now nothing made the two agree: a preference added to Preferences.psd1
# would simply be nil in the fallback, halfway through startup, on exactly the
# machine that has no compiled artifact to fall back from.
#
# The comparison is made with the module's own compiler. Each shipped value is
# rendered by ConvertTo-LuaLiteral and matched against the literal text in the
# Lua file, so what is asserted is "the fallback says what an apply would have
# written", not "two hand-written tables look similar".

function Get-LuaFallbackTable {
    <# The DEFAULT_PREFERENCES table of a Lua file, as
       @{ section = @{ key = 'literal text' } }. Two levels, which is the only
       shape these tables have. #>
    param([Parameter(Mandatory)][string] $Path)

    $text = Get-Content -LiteralPath $Path -Raw
    $start = $text.IndexOf('local DEFAULT_PREFERENCES = {')
    if ($start -lt 0) { return $null }

    # Brace depth is tracked rather than guessed, so the scan stops at the end
    # of DEFAULT_PREFERENCES instead of running on into the plugin specs that
    # follow it in init.lua.
    $result  = @{}
    $section = $null
    $depth   = 1
    foreach ($line in ($text.Substring($start) -split "`r?`n" | Select-Object -Skip 1)) {
        $trimmed = $line.Trim()

        if ($trimmed -match '^\}') {
            $depth--
            if ($depth -le 0) { break }
            $section = $null
            continue
        }

        if ($trimmed -match '^(\w+)\s*=\s*\{$') {
            $depth++
            $section = $Matches[1]
            $result[$section] = @{}
            continue
        }

        if ($null -ne $section -and $trimmed -match '^(\w+)\s*=\s*(.+?),?$') {
            $result[$section][$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $result
}

$weztermFallback = Get-LuaFallbackTable -Path $WezTermConfig
$neovimConfig    = Join-Path $RepositoryRoot 'code/assets/neovim/init.lua'
$neovimFallback  = Get-LuaFallbackTable -Path $neovimConfig

Confirm-That 'F42' 'both Lua files carry a DEFAULT_PREFERENCES table' `
    ($null -ne $weztermFallback -and $null -ne $neovimFallback)

# One merged view, so a section owned by neither file is caught rather than
# silently skipped.
$fallback = @{}
foreach ($source in @($weztermFallback, $neovimFallback)) {
    if ($null -eq $source) { continue }
    foreach ($sectionName in $source.Keys) { $fallback[$sectionName] = $source[$sectionName] }
}

Confirm-That 'F43' 'no section is declared in both Lua files at once' `
    ($null -ne $weztermFallback -and $null -ne $neovimFallback -and
     @($weztermFallback.Keys | Where-Object { $neovimFallback.ContainsKey($_) }).Count -eq 0) `
    "shared: $(@($weztermFallback.Keys | Where-Object { $neovimFallback.ContainsKey($_) }) -join ', ')"

# Schema is a version marker and Workstation is read by the module alone;
# neither Lua file has any use for them.
$shipped        = Import-PowerShellDataFile -Path $preferencesPath
$notForLua      = @('Schema', 'Workstation')
$expectedInLua  = @($shipped.Keys | Where-Object { $_ -notin $notForLua })

$missingSections = @($expectedInLua | ForEach-Object {
    $snake = & (Get-Module Workstation) { param($n) ConvertTo-SnakeCase -Name $n } $_
    if (-not $fallback.ContainsKey($snake)) { $_ }
})
Confirm-That 'F44' 'every shipped preference section has a Lua fallback' `
    ($missingSections.Count -eq 0) `
    "sections with no fallback: $($missingSections -join ', ')"

$expectedSnake = @($expectedInLua | ForEach-Object {
    & (Get-Module Workstation) { param($n) ConvertTo-SnakeCase -Name $n } $_
})
$extraSections = @($fallback.Keys | Where-Object { $_ -notin $expectedSnake })
Confirm-That 'F45' 'and no Lua fallback section is unknown to the shipped defaults' `
    ($extraSections.Count -eq 0) `
    "unknown sections: $($extraSections -join ', ')"

# Key by key, value by value.
$keyMismatches   = [System.Collections.Generic.List[string]]::new()
$valueMismatches = [System.Collections.Generic.List[string]]::new()

foreach ($sectionName in $expectedInLua) {
    $snakeSection = & (Get-Module Workstation) { param($n) ConvertTo-SnakeCase -Name $n } $sectionName
    if (-not $fallback.ContainsKey($snakeSection)) { continue }

    $luaSection = $fallback[$snakeSection]
    $seen       = @{}

    foreach ($key in $shipped[$sectionName].Keys) {
        $snakeKey = & (Get-Module Workstation) { param($n) ConvertTo-SnakeCase -Name $n } $key
        $seen[$snakeKey] = $true

        if (-not $luaSection.ContainsKey($snakeKey)) {
            $keyMismatches.Add("$snakeSection.$snakeKey is shipped but absent from the fallback")
            continue
        }

        $expectedLiteral = & (Get-Module Workstation) { param($v) ConvertTo-LuaLiteral -Value $v } $shipped[$sectionName][$key]
        if ($luaSection[$snakeKey] -cne $expectedLiteral) {
            $valueMismatches.Add("$snakeSection.${snakeKey}: shipped $expectedLiteral, fallback $($luaSection[$snakeKey])")
        }
    }

    foreach ($luaKey in $luaSection.Keys) {
        if (-not $seen.ContainsKey($luaKey)) {
            $keyMismatches.Add("$snakeSection.$luaKey is in the fallback but not shipped")
        }
    }
}

Confirm-That 'F46' 'the Lua fallbacks name exactly the shipped keys' `
    ($keyMismatches.Count -eq 0) `
    ($keyMismatches -join ' | ')
Confirm-That 'F47' 'and every fallback value is the literal an apply would compile' `
    ($valueMismatches.Count -eq 0) `
    ($valueMismatches -join ' | ')

# ===========================================================================
Set-Group 'Cleanup'
Clear-Override
$env:WORKSTATION_PREFERENCES = $null

# Still on the tool-free state, so the apply that restores the shipped
# preferences cannot reach a package manager.
Install-Workstation -Apply -AutoApprove 6>$null | Out-Null
$drift = Test-Workstation -PassThru 6>$null
Confirm-That 'F40' 'the machine is left in sync on the shipped defaults' `
    (@($drift | Where-Object { $_.State -in @('Pending','Blocked') }).Count -eq 0)

Clear-ToolFreeDeclaredState
Confirm-That 'F41' 'the real declared state is restored and no tool was installed' `
    ([string]::IsNullOrEmpty($env:WORKSTATION_DECLARED_STATE) -and
     @((Test-Workstation -PassThru 6>$null) | Where-Object { $_.Kind -eq 'tool' }).Count -gt 0 -and
     $null -eq (Get-Command 'workstation-qa-absent-tool' -ErrorAction Ignore))

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
