#Requires -Version 7.0

# ============================================================================
#  Workstation
#
#  A three-pane terminal workspace: Neovim on the left, an AI agent on the
#  right, a shell at the bottom. WezTerm supplies the panes and the mouse.
#
#  This module is the laboratory for the future `macss workstation` command,
#  and deliberately rehearses the discipline that command will have to keep:
#
#    * plan and apply are mandatory, and neither is a default
#    * the preview and the change are produced from one list of steps, so they
#      cannot describe different things
#    * nothing is written outside the paths this repository authored
#
#  See docs/adr/ for the decisions behind each of those.
# ============================================================================

Set-StrictMode -Version Latest


# ----------------------------------------------------------------------------
#  Module paths
#
#  This file sits at <repository>/code/powershell/Workstation/, so the roots
#  are reached by walking up from $PSScriptRoot. Nothing is hard-coded, which
#  is what lets the repository be cloned anywhere.
# ----------------------------------------------------------------------------
$script:ModuleRoot        = $PSScriptRoot
$script:PowerShellRoot    = Split-Path -Parent $script:ModuleRoot
$script:CodeRoot          = Split-Path -Parent $script:PowerShellRoot
$script:RepositoryRoot    = Split-Path -Parent $script:CodeRoot
$script:AssetsRoot        = Join-Path $script:CodeRoot 'assets'
$script:PlansDirectory    = Join-Path $script:RepositoryRoot '.workstation' 'plans'
$script:WezTermConfigPath = Join-Path $script:AssetsRoot 'wezterm' 'wezterm.lua'

# ----------------------------------------------------------------------------
#  Configuration seams
#
#  Both inputs can be pointed elsewhere by an environment variable. This is not
#  a convenience: the eventual `macss workstation` ships its assets from its own
#  tree rather than from here, and a test needs to assert against a state it
#  controls instead of whatever the machine happens to have installed. A seam
#  that exists only when someone remembers to add it does not exist.
# ----------------------------------------------------------------------------
$script:DefaultDeclaredStatePath = Join-Path $script:ModuleRoot 'DeclaredState.psd1'
$script:DefaultPreferencesPath   = Join-Path $script:ModuleRoot 'Preferences.psd1'

function Get-DeclaredStatePath {
    if (-not [string]::IsNullOrWhiteSpace($env:WORKSTATION_DECLARED_STATE)) {
        return $env:WORKSTATION_DECLARED_STATE
    }
    return $script:DefaultDeclaredStatePath
}

function Get-ShippedPreferencesPath {
    if (-not [string]::IsNullOrWhiteSpace($env:WORKSTATION_PREFERENCE_DEFAULTS)) {
        return $env:WORKSTATION_PREFERENCE_DEFAULTS
    }
    return $script:DefaultPreferencesPath
}


# ============================================================================
#  Private helpers
# ============================================================================

function Get-DeclaredState {
    <# Reads the declared state. It is data only, so Import-PowerShellDataFile
       parses it in restricted language mode and nothing in it can execute. #>
    $path = Get-DeclaredStatePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Declared state not found at $path"
    }
    return Import-PowerShellDataFile -Path $path
}


function Merge-PreferenceSection {
    <# Overlays $Override onto a copy of $Default, one section deep.

       Sections are merged rather than replaced, so an override naming a single
       colour keeps every other value it did not mention. Replacing whole
       sections would make a one-key override silently drop the rest, which is
       the failure mode that makes people stop writing override files and start
       editing shipped ones. #>
    param(
        [Parameter(Mandatory)][hashtable] $Default,
        [Parameter(Mandatory)][AllowNull()] $Override
    )

    $result = @{}
    foreach ($key in $Default.Keys) { $result[$key] = $Default[$key] }
    if ($null -eq $Override) { return $result }

    foreach ($key in $Override.Keys) {
        if ($result.ContainsKey($key) -and $result[$key] -is [hashtable] -and $Override[$key] -is [hashtable]) {
            $result[$key] = Merge-PreferenceSection -Default $result[$key] -Override $Override[$key]
        }
        else {
            $result[$key] = $Override[$key]
        }
    }
    return $result
}


function Get-PreferenceOverridePath {
    <# Where this machine may put its own preferences, or an explicit path when
       WORKSTATION_PREFERENCE_FILE names one. #>
    if (-not [string]::IsNullOrWhiteSpace($env:WORKSTATION_PREFERENCE_FILE)) {
        return $env:WORKSTATION_PREFERENCE_FILE
    }
    $declared = Get-DeclaredState
    if (-not $declared.ContainsKey('Preferences')) { return $null }
    $template = Get-PlatformValue -Entry $declared.Preferences -WindowsKey 'WindowsOverride' -OtherKey 'LinuxOverride'
    if ([string]::IsNullOrWhiteSpace($template)) { return $null }
    return Resolve-WorkstationPath -Template $template
}


function Resolve-WorkstationPath {
    <# Expands the placeholders used in the declared state and normalises the
       separators for the current platform. #>
    param([Parameter(Mandatory)][string] $Template)

    $configurationHome = if ($env:XDG_CONFIG_HOME) {
        $env:XDG_CONFIG_HOME
    }
    else {
        Join-Path $HOME '.config'
    }

    $result = $Template
    $result = $result.Replace('{LOCALAPPDATA}', [string]$env:LOCALAPPDATA)
    $result = $result.Replace('{XDG_CONFIG_HOME}', $configurationHome)
    $result = $result.Replace('{HOME}', $HOME)

    if ($IsWindows) { return $result.Replace('/', '\').TrimEnd('\') }
    return $result.Replace('\', '/').TrimEnd('/')
}


function Test-CommandAvailable {
    <# Absence is the expected answer half the time, so the lookup uses
       -ErrorAction Ignore rather than SilentlyContinue. SilentlyContinue only
       hides the error from the screen: the record is still added to $Error and
       to any enclosing -ErrorVariable, which buries the real message under a
       CommandNotFoundException the caller never needed to see. #>
    param([Parameter(Mandatory)][string] $Name)
    return $null -ne (Get-Command $Name -ErrorAction Ignore)
}


function Get-PlatformValue {
    <# Picks the Windows or the non-Windows variant of a declared field,
       falling back to $null when the entry does not carry one. #>
    param(
        [Parameter(Mandatory)][hashtable] $Entry,
        [Parameter(Mandatory)][string]    $WindowsKey,
        [Parameter(Mandatory)][string]    $OtherKey
    )
    $key = if ($IsWindows) { $WindowsKey } else { $OtherKey }
    if ($Entry.ContainsKey($key)) { return $Entry[$key] }
    return $null
}


function Get-ToolCommandName {
    param([Parameter(Mandatory)][hashtable] $Tool)
    if (-not $IsWindows -and $Tool.ContainsKey('LinuxCommand')) {
        return $Tool.LinuxCommand
    }
    return $Tool.Command
}


function New-WorkstationStep {
    param(
        [Parameter(Mandatory)][string] $Kind,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][ValidateSet('InSync', 'Pending', 'Missing', 'Blocked')][string] $State,
        [string]      $Detail,
        [string]      $Hint,
        [scriptblock] $Action
    )
    return [PSCustomObject]@{
        Kind   = $Kind
        Name   = $Name
        State  = $State
        Detail = $Detail
        Hint   = $Hint
        Action = $Action
    }
}


function Get-LinkTarget {
    <# The resolved target of a link, or $null when the item is not a link. #>
    param([Parameter(Mandatory)]$Item)
    if ($null -eq $Item.LinkType) { return $null }
    if ($Item.LinkType -notin @('Junction', 'SymbolicLink')) { return $null }
    $target = @($Item.Target)[0]
    if ([string]::IsNullOrEmpty($target)) { return $null }
    return $target.TrimEnd('\', '/')
}


function Get-DesiredProfileContent {
    <# The profile text this module wants, given whatever the profile holds now.

       The block is delimited by markers so writing it is idempotent and
       removing it is a two-line edit. Everything outside the markers belongs
       to the user and is copied through unchanged. #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $CurrentContent,
        [Parameter(Mandatory)][string] $OpenMarker,
        [Parameter(Mandatory)][string] $CloseMarker
    )

    $newline = [Environment]::NewLine

    $block = @(
        $OpenMarker
        "#  Written by Install-Workstation. Edit the module, not this block."
        "Import-Module '$script:ModuleRoot' -ErrorAction Ignore"
        $CloseMarker
    ) -join $newline

    # Declared as a typed array first. Assigning @() from inside an `if`
    # expression collapses it to $null, and every .Count on it then fails
    # under Set-StrictMode.
    [string[]] $lines = @()
    if (-not [string]::IsNullOrEmpty($CurrentContent)) {
        $lines = $CurrentContent -split "`r?`n"
    }

    $openIndex  = -1
    $closeIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ceq $OpenMarker)  { $openIndex  = $i }
        if ($lines[$i].Trim() -ceq $CloseMarker) { $closeIndex = $i }
    }

    if ($openIndex -ge 0 -and $closeIndex -gt $openIndex) {
        [string[]] $before = @()
        if ($openIndex -gt 0) { $before = $lines[0..($openIndex - 1)] }

        [string[]] $after = @()
        if ($closeIndex -lt $lines.Count - 1) { $after = $lines[($closeIndex + 1)..($lines.Count - 1)] }

        [string[]] $blockLines = $block -split "`r?`n"
        return ($before + $blockLines + $after) -join $newline
    }

    if ($lines.Count -eq 0) { return $block }
    return ($CurrentContent.TrimEnd() + $newline + $newline + $block)
}


# ============================================================================
#  Compiling preferences into something Lua can read
#
#  Neither Neovim nor WezTerm can read a PowerShell data file, so the resolved
#  preferences are compiled into a Lua table. Keys are sorted, so the same
#  preferences always produce byte-identical output — which is what lets the
#  apply compare generated content and do nothing when nothing changed.
# ============================================================================

function ConvertTo-SnakeCase {
    <# AgentPaneWidth -> agent_pane_width. Lua reads better in snake case, and
       the boundary is a good place to stop carrying PowerShell's conventions
       into a file PowerShell does not own. #>
    param([Parameter(Mandatory)][string] $Name)
    return ($Name -creplace '(?<!^)([A-Z])', '_$1').ToLowerInvariant()
}


function ConvertTo-LuaLiteral {
    param([Parameter(Mandatory)][AllowNull()] $Value)

    if ($null -eq $Value)      { return 'nil' }
    if ($Value -is [bool])     { return $(if ($Value) { 'true' } else { 'false' }) }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or
        $Value -is [single] -or $Value -is [decimal]) {
        # Invariant culture on purpose: on a machine with a comma decimal
        # separator, 0.38 would otherwise be written as 0,38 and Lua would read
        # it as two values in a table constructor.
        return [string]::Format([cultureinfo]::InvariantCulture, '{0}', $Value)
    }

    $escaped = ([string] $Value).Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}


function ConvertTo-LuaTable {
    param(
        [Parameter(Mandatory)][hashtable] $Table,
        [int] $Indent = 1
    )

    $pad     = '  ' * $Indent
    $closing = '  ' * ($Indent - 1)
    $lines   = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')

    foreach ($key in ($Table.Keys | Sort-Object)) {
        $value    = $Table[$key]
        $luaKey   = ConvertTo-SnakeCase -Name ([string] $key)
        if ($value -is [hashtable]) {
            $nested = ConvertTo-LuaTable -Table $value -Indent ($Indent + 1)
            $lines.Add("$pad$luaKey = $nested,")
        }
        else {
            $lines.Add("$pad$luaKey = $(ConvertTo-LuaLiteral -Value $value),")
        }
    }

    $lines.Add("$closing}")
    return ($lines -join [Environment]::NewLine)
}


function New-ResolvedPreferenceContent {
    param([Parameter(Mandatory)][hashtable] $Preferences)

    $body = ConvertTo-LuaTable -Table $Preferences -Indent 1

    return @"
-- ============================================================================
--  GENERATED FILE - DO NOT EDIT
--
--  Written by Install-Workstation from the resolved preferences: the defaults
--  shipped in Preferences.psd1, with this machine's override file on top.
--
--  Editing this file achieves nothing; the next apply overwrites it. Change
--  the override file instead, then run Install-Workstation -Apply.
-- ============================================================================

return $body
"@
}


function Get-GeneratedArtifactPath {
    <# Directory and full path of a declared generated artifact. #>
    param([Parameter(Mandatory)][hashtable] $Artifact)

    $template  = Get-PlatformValue -Entry $Artifact -WindowsKey 'WindowsTarget' -OtherKey 'LinuxTarget'
    $directory = Resolve-WorkstationPath -Template $template
    return [PSCustomObject]@{
        Directory = $directory
        FullPath  = Join-Path $directory $Artifact.FileName
    }
}


function Get-ResolvedPreferencePath {
    <# Where the compiled preferences live, for the launcher to point Lua at.
       Returns $null when the declared state ships no generated artifacts. #>
    $declared = Get-DeclaredState
    if (-not $declared.ContainsKey('GeneratedArtifacts')) { return $null }
    $artifact = @($declared.GeneratedArtifacts | Where-Object { $_.Name -eq 'Resolved preferences' })
    if ($artifact.Count -eq 0) { return $null }
    return (Get-GeneratedArtifactPath -Artifact $artifact[0]).FullPath
}


# ============================================================================
#  The step list
#
#  Both Install-Workstation and Test-Workstation build this same list. The
#  preview prints it; the apply prints it and then invokes the actions on it.
#  One list means the preview cannot describe a change other than the one that
#  happens.
# ============================================================================

function Get-WorkstationStepList {
    param([switch] $InstallMissingTools)

    $declared = Get-DeclaredState
    $steps    = [System.Collections.Generic.List[object]]::new()

    # Every step's Action is turned into a closure so it carries the exact
    # values the preview printed. A closure runs in a fresh dynamic module and
    # therefore cannot see this module's private functions, so the actions
    # below use only built-in cmdlets and .NET calls, plus locals captured
    # here.
    #
    # A junction on Windows and a symbolic link elsewhere. The junction is
    # deliberate: a symbolic link on Windows needs administrator rights or
    # Developer Mode, and a junction needs neither.
    $linkItemType     = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
    $runningOnWindows = [bool] $IsWindows

    # ---- Tools -------------------------------------------------------------
    foreach ($tool in $declared.Tools) {

        $commandName   = Get-ToolCommandName -Tool $tool
        $installAdvice = Get-PlatformValue -Entry $tool -WindowsKey 'WindowsInstall' -OtherKey 'LinuxInstall'

        if (Test-CommandAvailable $commandName) {
            $steps.Add((New-WorkstationStep -Kind 'tool' -Name $tool.Name -State 'InSync' `
                        -Detail $tool.Purpose))
            continue
        }

        $canInstall = $InstallMissingTools -and $IsWindows -and (Test-CommandAvailable 'winget')

        if ($canInstall) {
            $identifier = ($installAdvice -split '--id\s+')[1] -split '\s+' | Select-Object -First 1
            $steps.Add((New-WorkstationStep -Kind 'tool' -Name $tool.Name -State 'Pending' `
                        -Detail "install with winget: $identifier" `
                        -Action {
                            & winget install --id $identifier --exact --source winget `
                                --accept-package-agreements --accept-source-agreements | Out-Null
                        }.GetNewClosure()))
            continue
        }

        $steps.Add((New-WorkstationStep -Kind 'tool' -Name $tool.Name -State 'Missing' `
                    -Detail $tool.Purpose -Hint $installAdvice))
    }

    # ---- Links -------------------------------------------------------------
    foreach ($link in $declared.Links) {

        # Source paths in the declared state are written with forward slashes
        # and are relative to code/, so they read the same on both platforms.
        $relativeSource = $link.Source.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $script:CodeRoot $relativeSource))
        $sourcePath = $sourcePath.TrimEnd('\', '/')

        $targetTemplate = Get-PlatformValue -Entry $link -WindowsKey 'WindowsTarget' -OtherKey 'LinuxTarget'
        $targetPath     = Resolve-WorkstationPath -Template $targetTemplate

        if (-not (Test-Path -LiteralPath $sourcePath)) {
            $steps.Add((New-WorkstationStep -Kind 'link' -Name $link.Name -State 'Blocked' `
                        -Detail "source missing: $sourcePath"))
            continue
        }

        $existing = Get-Item -LiteralPath $targetPath -Force -ErrorAction Ignore

        if ($null -ne $existing) {
            $currentTarget = Get-LinkTarget -Item $existing

            if ($null -ne $currentTarget) {
                if ($currentTarget -ieq $sourcePath) {
                    $steps.Add((New-WorkstationStep -Kind 'link' -Name $link.Name -State 'InSync' `
                                -Detail "$targetPath -> $sourcePath"))
                    continue
                }

                $steps.Add((New-WorkstationStep -Kind 'link' -Name $link.Name -State 'Pending' `
                            -Detail "repoint $targetPath, currently -> $currentTarget" `
                            -Action {
                                if ($runningOnWindows) { [System.IO.Directory]::Delete($targetPath, $false) }
                                else { [System.IO.File]::Delete($targetPath) }
                                New-Item -ItemType $linkItemType -Path $targetPath -Target $sourcePath | Out-Null
                            }.GetNewClosure()))
                continue
            }

            # A real directory sits where the link belongs. The name is ours,
            # so this is almost certainly an older non-linked install, but it
            # is still moved aside rather than deleted.
            $backupPath = "$targetPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            $steps.Add((New-WorkstationStep -Kind 'link' -Name $link.Name -State 'Pending' `
                        -Detail "move $targetPath to $backupPath, then link to $sourcePath" `
                        -Action {
                            Move-Item -LiteralPath $targetPath -Destination $backupPath
                            New-Item -ItemType $linkItemType -Path $targetPath -Target $sourcePath | Out-Null
                        }.GetNewClosure()))
            continue
        }

        $steps.Add((New-WorkstationStep -Kind 'link' -Name $link.Name -State 'Pending' `
                    -Detail "link $targetPath -> $sourcePath" `
                    -Action {
                        $parent = Split-Path -Parent $targetPath
                        if (-not (Test-Path -LiteralPath $parent)) {
                            New-Item -ItemType Directory -Path $parent -Force | Out-Null
                        }
                        New-Item -ItemType $linkItemType -Path $targetPath -Target $sourcePath | Out-Null
                    }.GetNewClosure()))
    }

    # ---- Generated artifacts -----------------------------------------------
    #
    # The resolved preferences compiled into Lua. Content is compared, not
    # merely presence: a preference changed in an override file has to show up
    # as a pending step, or the plan would claim a machine is in sync while the
    # editor is still painted in last week's colours.
    if ($declared.ContainsKey('GeneratedArtifacts')) {
        $resolvedPreferences = Get-WorkstationPreference

        foreach ($artifact in $declared.GeneratedArtifacts) {

            $location = Get-GeneratedArtifactPath -Artifact $artifact
            $desired  = New-ResolvedPreferenceContent -Preferences $resolvedPreferences

            $artifactPath      = $location.FullPath
            $artifactDirectory = $location.Directory
            $desiredContent    = $desired

            $current = ''
            if (Test-Path -LiteralPath $artifactPath) {
                $current = Get-Content -LiteralPath $artifactPath -Raw
                if ($null -eq $current) { $current = '' }
            }

            if ($current.Trim() -ceq $desiredContent.Trim()) {
                $steps.Add((New-WorkstationStep -Kind 'generated' -Name $artifact.Name -State 'InSync' `
                            -Detail $artifactPath))
            }
            else {
                $verb = if ([string]::IsNullOrEmpty($current)) { 'write' } else { 'refresh' }
                $steps.Add((New-WorkstationStep -Kind 'generated' -Name $artifact.Name -State 'Pending' `
                            -Detail "$verb $artifactPath from the resolved preferences" `
                            -Action {
                                if (-not (Test-Path -LiteralPath $artifactDirectory)) {
                                    New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
                                }
                                Set-Content -LiteralPath $artifactPath -Value $desiredContent -Encoding utf8
                            }.GetNewClosure()))
            }
        }
    }

    # ---- PowerShell profile ------------------------------------------------
    $profileSpec = $declared.PowerShellProfile
    $profilePath = $PROFILE.CurrentUserAllHosts

    $currentProfile = ''
    if (Test-Path -LiteralPath $profilePath) {
        $currentProfile = Get-Content -LiteralPath $profilePath -Raw
        if ($null -eq $currentProfile) { $currentProfile = '' }
    }

    $desiredProfile = Get-DesiredProfileContent `
        -CurrentContent $currentProfile `
        -OpenMarker  $profileSpec.OpenMarker `
        -CloseMarker $profileSpec.CloseMarker

    if ($currentProfile.TrimEnd() -ceq $desiredProfile.TrimEnd()) {
        $steps.Add((New-WorkstationStep -Kind 'profile' -Name $profileSpec.Name -State 'InSync' `
                    -Detail $profilePath))
    }
    else {
        $steps.Add((New-WorkstationStep -Kind 'profile' -Name $profileSpec.Name -State 'Pending' `
                    -Detail "write the marked block into $profilePath" `
                    -Action {
                        $parent = Split-Path -Parent $profilePath
                        if (-not (Test-Path -LiteralPath $parent)) {
                            New-Item -ItemType Directory -Path $parent -Force | Out-Null
                        }
                        Set-Content -LiteralPath $profilePath -Value $desiredProfile -Encoding utf8
                    }.GetNewClosure()))
    }

    # ---- Agents ------------------------------------------------------------
    foreach ($agent in $declared.Agents) {
        $installAdvice = Get-PlatformValue -Entry $agent -WindowsKey 'WindowsInstall' -OtherKey 'LinuxInstall'

        if (Test-CommandAvailable $agent.Command) {
            $steps.Add((New-WorkstationStep -Kind 'agent' -Name $agent.Name -State 'InSync' `
                        -Detail $agent.Product))
        }
        else {
            $steps.Add((New-WorkstationStep -Kind 'agent' -Name $agent.Name -State 'Missing' `
                        -Detail $agent.Product -Hint $installAdvice))
        }
    }

    return $steps
}


function Format-StepReport {
    <# Renders the step list. Used identically by plan, apply and check, so the
       three never disagree about what they are describing. #>
    param([Parameter(Mandatory)][object[]] $Steps)

    $lines = [System.Collections.Generic.List[string]]::new()
    $kindOrder = @('tool', 'link', 'generated', 'profile', 'agent')
    $headings  = @{
        tool      = 'Tools'
        link      = 'Configuration links'
        generated = 'Generated from preferences'
        profile   = 'PowerShell profile'
        agent     = 'AI agents'
    }

    foreach ($kind in $kindOrder) {
        $ofKind = @($Steps | Where-Object { $_.Kind -eq $kind })
        if ($ofKind.Count -eq 0) { continue }

        $lines.Add('')
        $lines.Add("  $($headings[$kind])")
        $lines.Add('  ' + ('-' * $headings[$kind].Length))

        foreach ($step in $ofKind) {
            $label = switch ($step.State) {
                'InSync'  { 'in sync' }
                'Pending' { 'pending' }
                'Missing' { 'missing' }
                'Blocked' { 'blocked' }
            }
            $lines.Add(('    [{0,-7}] {1}' -f $label, $step.Name))
            if ($step.Detail) { $lines.Add("              $($step.Detail)") }
            if ($step.Hint)   { $lines.Add("              install: $($step.Hint)") }
        }
    }

    return $lines
}


function Write-StepReport {
    param([Parameter(Mandatory)][object[]] $Steps)

    foreach ($line in (Format-StepReport -Steps $Steps)) {
        if ($line -match '^\s*\[in sync\s*\]') { Write-Host $line -ForegroundColor Green }
        elseif ($line -match '^\s*\[pending\s*\]') { Write-Host $line -ForegroundColor Yellow }
        elseif ($line -match '^\s*\[missing\s*\]') { Write-Host $line -ForegroundColor Red }
        elseif ($line -match '^\s*\[blocked\s*\]') { Write-Host $line -ForegroundColor Red }
        elseif ($line -match '^\s{2}\S') { Write-Host $line -ForegroundColor Cyan }
        else { Write-Host $line -ForegroundColor DarkGray }
    }
}


# ============================================================================
#  Public commands
# ============================================================================

function Get-WorkstationPreference {
    <#
    .SYNOPSIS
        The resolved preferences: shipped defaults with this machine's override
        laid on top.

    .DESCRIPTION
        Preferences are taste — colours, fonts, pane proportions, the leader
        key. They are resolved separately from the declared state, which holds
        architecture, so that changing how the workstation looks can never
        change what it writes to a machine.

        Resolution order, later winning:

          1. the defaults shipped in Preferences.psd1
          2. the machine override, if it exists

        Merging is by section, so an override naming one colour keeps every
        value it did not mention.

    .PARAMETER ShowSources
        Print the files considered and the keys the override changed, then
        return the resolved result.

    .EXAMPLE
        Get-WorkstationPreference

    .EXAMPLE
        (Get-WorkstationPreference).Terminal.ColorScheme

    .EXAMPLE
        Get-WorkstationPreference -ShowSources
    #>

    [CmdletBinding()]
    param([switch] $ShowSources)

    $shippedPath = Get-ShippedPreferencesPath
    if (-not (Test-Path -LiteralPath $shippedPath)) {
        throw "Preference defaults not found at $shippedPath"
    }
    $defaults = Import-PowerShellDataFile -Path $shippedPath

    $overridePath  = Get-PreferenceOverridePath
    $overrideFound = $false
    $override      = $null

    if (-not [string]::IsNullOrWhiteSpace($overridePath) -and (Test-Path -LiteralPath $overridePath)) {
        $override      = Import-PowerShellDataFile -Path $overridePath
        $overrideFound = $true
    }

    $resolved = Merge-PreferenceSection -Default $defaults -Override $override

    if ($ShowSources) {
        Write-Host ''
        Write-Host '  Preference sources' -ForegroundColor Cyan
        Write-Host '  ------------------' -ForegroundColor DarkCyan
        Write-Host "    [defaults] $shippedPath" -ForegroundColor Green
        if ($overrideFound) {
            Write-Host "    [override] $overridePath" -ForegroundColor Yellow
            foreach ($section in ($override.Keys | Sort-Object)) {
                if ($override[$section] -is [hashtable]) {
                    foreach ($key in ($override[$section].Keys | Sort-Object)) {
                        Write-Host ("               {0}.{1} = {2}" -f $section, $key, (ConvertTo-LuaLiteral -Value $override[$section][$key])) -ForegroundColor DarkYellow
                    }
                }
                else {
                    Write-Host ("               {0} = {1}" -f $section, (ConvertTo-LuaLiteral -Value $override[$section])) -ForegroundColor DarkYellow
                }
            }
        }
        else {
            $shown = if ([string]::IsNullOrWhiteSpace($overridePath)) { '(none declared)' } else { $overridePath }
            Write-Host "    [override] not present at $shown" -ForegroundColor DarkGray
            Write-Host '               every value below is the shipped default' -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    return $resolved
}


function Install-Workstation {
    <#
    .SYNOPSIS
        Converges this machine towards the declared state.

    .DESCRIPTION
        Mirrors the `macss workstation deploy` command this repository is the
        laboratory for. -Plan and -Apply are mandatory and neither is a
        default: a bare invocation is an error that asks you to choose, so no
        one ever changes a machine by accident.

        -Plan  computes the steps, prints them, writes a plan file under
               .workstation/plans/ and touches nothing else.
        -Apply computes the same steps, prints them, asks once, and performs
               them.

        The preview and the change come from the same list of steps, so they
        cannot describe different things.

    .PARAMETER Plan
        Preview only. Writes a plan file and changes nothing.

    .PARAMETER Apply
        Perform the pending steps after a single confirmation.

    .PARAMETER AutoApprove
        With -Apply, skip the confirmation. For unattended runs.

    .PARAMETER InstallMissingTools
        Opt in to installing missing tools with winget. Windows only, and
        never implied. Without it, missing tools are reported with the command
        you would run yourself.

    .EXAMPLE
        Install-Workstation -Plan

    .EXAMPLE
        Install-Workstation -Apply

    .EXAMPLE
        Install-Workstation -Apply -InstallMissingTools -AutoApprove
    #>

    [CmdletBinding()]
    param(
        [switch] $Plan,
        [switch] $Apply,
        [switch] $AutoApprove,
        [switch] $InstallMissingTools
    )

    if ($Plan -and $Apply) {
        Write-Error 'Choose one of -Plan or -Apply, not both.'
        return
    }
    if (-not $Plan -and -not $Apply) {
        Write-Error 'This command changes the machine, so it needs -Plan or -Apply. Neither is a default.'
        return
    }

    $declared = Get-DeclaredState
    $steps    = Get-WorkstationStepList -InstallMissingTools:$InstallMissingTools

    Write-Host ''
    Write-Host "  $($declared.Name) $($declared.Version)" -ForegroundColor White
    Write-Host "  repository: $script:RepositoryRoot" -ForegroundColor DarkGray
    Write-Host "  platform:   $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim())" -ForegroundColor DarkGray
    Write-Host "  mode:       $(if ($Plan) { 'plan — nothing will be written' } else { 'apply' })" `
        -ForegroundColor $(if ($Plan) { 'Magenta' } else { 'Yellow' })

    Write-StepReport -Steps $steps

    $pending = @($steps | Where-Object { $_.State -eq 'Pending' })
    $blocked = @($steps | Where-Object { $_.State -eq 'Blocked' })

    Write-Host ''
    if ($blocked.Count -gt 0) {
        Write-Host "  $($blocked.Count) step(s) blocked; resolve them before applying." -ForegroundColor Red
    }

    # ---- Plan --------------------------------------------------------------
    if ($Plan) {
        if (-not (Test-Path -LiteralPath $script:PlansDirectory)) {
            New-Item -ItemType Directory -Path $script:PlansDirectory -Force | Out-Null
        }
        $planFile = Join-Path $script:PlansDirectory ("{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

        $header = @(
            "workstation plan"
            "generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "repository: $script:RepositoryRoot"
            "pending steps: $($pending.Count)"
        )
        Set-Content -LiteralPath $planFile -Value (($header + (Format-StepReport -Steps $steps)) -join [Environment]::NewLine) -Encoding utf8

        Write-Host "  $($pending.Count) step(s) would be performed." -ForegroundColor Magenta
        Write-Host "  plan written to $planFile" -ForegroundColor DarkGray
        Write-Host ''
        return
    }

    # ---- Apply -------------------------------------------------------------
    if ($pending.Count -eq 0) {
        Write-Host '  Nothing to do; the machine already matches the declared state.' -ForegroundColor Green
        Write-Host ''
        return
    }

    if (-not $AutoApprove) {
        $answer = Read-Host "  Perform $($pending.Count) pending step(s)? [y/N]"
        if ($answer -notin @('y', 'Y', 'yes')) {
            Write-Host '  Cancelled; nothing was written.' -ForegroundColor DarkGray
            Write-Host ''
            return
        }
    }

    foreach ($step in $pending) {
        try {
            & $step.Action
            Write-Host "    [done   ] $($step.Name)" -ForegroundColor Green
        }
        catch {
            Write-Host "    [failed ] $($step.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host ''
    Write-Host '  Open a new terminal and run:' -ForegroundColor Green
    Write-Host '      Start-Workstation -Agent claude' -ForegroundColor White
    Write-Host ''
}


function Test-Workstation {
    <#
    .SYNOPSIS
        Reports how far this machine has drifted from the declared state.

    .DESCRIPTION
        Mirrors the `macss workstation check` command. Read-only by
        construction: it takes no -Plan or -Apply because it changes nothing.

    .PARAMETER PassThru
        Also return the step objects, for scripting.

    .EXAMPLE
        Test-Workstation
    #>

    [CmdletBinding()]
    param([switch] $PassThru)

    $declared = Get-DeclaredState
    $steps    = Get-WorkstationStepList

    Write-Host ''
    Write-Host "  $($declared.Name) $($declared.Version) — check" -ForegroundColor White
    Write-Host "  repository: $script:RepositoryRoot" -ForegroundColor DarkGray

    Write-StepReport -Steps $steps

    $pending = @($steps | Where-Object { $_.State -in @('Pending', 'Blocked') })
    Write-Host ''
    if ($pending.Count -eq 0) {
        Write-Host '  In sync with the declared state.' -ForegroundColor Green
    }
    else {
        Write-Host "  $($pending.Count) difference(s). Run Install-Workstation -Plan to see the change." -ForegroundColor Yellow
    }
    Write-Host ''

    if ($PassThru) { return $steps }
}


function Start-Workstation {
    <#
    .SYNOPSIS
        Opens the three-pane workspace over a project directory.

    .DESCRIPTION
        Launches WezTerm with this repository's configuration passed
        explicitly, so the user's own WezTerm configuration is never used or
        displaced. The layout is:

            +------------------------------+-------------------+
            |  Neovim                      |                   |
            |  file tree + current file    |  AI agent         |
            +------------------------------+                   |
            |  Shell                       |                   |
            +------------------------------+-------------------+

        Panes are focused by clicking and resized by dragging the divider.

    .PARAMETER Agent
        Which AI agent occupies the right pane.

    .PARAMETER Directory
        The project directory. Defaults to the current one.

    .EXAMPLE
        Start-Workstation

    .EXAMPLE
        ws codex

    .EXAMPLE
        Start-Workstation -Agent antigravity -Directory ~/projects/shop
    #>

    [CmdletBinding()]
    param(
        # The default is a preference, not a constant. A parameter default is
        # only evaluated when the argument is absent, so naming an agent still
        # costs nothing.
        [Parameter(Position = 0)]
        [ValidateSet('claude', 'codex', 'antigravity', 'opencode')]
        [string] $Agent = (Get-WorkstationPreference).Workstation.DefaultAgent,

        [Parameter(Position = 1)]
        [string] $Directory = '.'
    )

    $declared = Get-DeclaredState

    # ---- Project directory -------------------------------------------------
    $resolved = Resolve-Path -LiteralPath $Directory -ErrorAction Ignore
    if ($null -eq $resolved) {
        Write-Error "Directory '$Directory' does not exist."
        return
    }
    $projectDirectory = $resolved.Path

    # ---- Agent -------------------------------------------------------------
    $agentSpec = $declared.Agents | Where-Object { $_.Name -eq $Agent } | Select-Object -First 1
    if ($null -eq $agentSpec) {
        Write-Error "Agent '$Agent' is not declared."
        return
    }

    if (-not (Test-CommandAvailable $agentSpec.Command)) {
        $advice = Get-PlatformValue -Entry $agentSpec -WindowsKey 'WindowsInstall' -OtherKey 'LinuxInstall'
        Write-Error @"
Agent '$Agent' is not installed: the command '$($agentSpec.Command)' was not found.

Install it with:

    $advice
"@
        return
    }

    # ---- WezTerm -----------------------------------------------------------
    $wezterm = Get-Command 'wezterm-gui' -ErrorAction Ignore
    if ($null -eq $wezterm) { $wezterm = Get-Command 'wezterm' -ErrorAction Ignore }
    if ($null -eq $wezterm -and $IsWindows -and (Test-Path 'C:\Program Files\WezTerm\wezterm-gui.exe')) {
        $weztermPath = 'C:\Program Files\WezTerm\wezterm-gui.exe'
    }
    elseif ($null -ne $wezterm) {
        $weztermPath = $wezterm.Source
    }
    else {
        $advice = ($declared.Tools | Where-Object { $_.Name -eq 'WezTerm' } | Select-Object -First 1)
        $hint = Get-PlatformValue -Entry $advice -WindowsKey 'WindowsInstall' -OtherKey 'LinuxInstall'
        Write-Error "WezTerm was not found. Install it with: $hint"
        return
    }

    # ---- Warn if the Neovim configuration has not been deployed ------------
    $neovimLink = $declared.Links | Where-Object { $_.Name -eq 'Neovim configuration' } | Select-Object -First 1
    if ($null -ne $neovimLink) {
        $template = Get-PlatformValue -Entry $neovimLink -WindowsKey 'WindowsTarget' -OtherKey 'LinuxTarget'
        $target   = Resolve-WorkstationPath -Template $template
        if (-not (Test-Path -LiteralPath $target)) {
            Write-Warning "The Neovim configuration is not deployed yet. Run: Install-Workstation -Apply"
        }
    }

    # ---- Warn if the preferences have not been compiled yet ----------------
    $resolvedPreferencePath = Get-ResolvedPreferencePath
    if ($null -ne $resolvedPreferencePath -and -not (Test-Path -LiteralPath $resolvedPreferencePath)) {
        Write-Warning "The preferences have not been compiled yet, so shipped defaults will be used. Run: Install-Workstation -Apply"
    }

    # ---- Launch ------------------------------------------------------------
    $env:WORKSTATION_AGENT     = $agentSpec.Command
    $env:WORKSTATION_DIRECTORY = $projectDirectory
    # Both Lua files read this. When it is absent or the file is missing they
    # fall back to the defaults compiled into them, so the workspace still
    # opens on a machine where nothing has been generated yet.
    $env:WORKSTATION_PREFERENCES = $resolvedPreferencePath

    try {
        $arguments = @(
            '--config-file', $script:WezTermConfigPath
            'start'
            '--always-new-process'
        )
        Start-Process -FilePath $weztermPath -ArgumentList $arguments
        Write-Host "Opening the workstation: agent '$Agent' over '$projectDirectory'."
    }
    finally {
        # Cleared right after the launch: WezTerm has already inherited its own
        # copy, and leaving them set would affect unrelated commands in this
        # same session.
        $env:WORKSTATION_AGENT       = $null
        $env:WORKSTATION_DIRECTORY   = $null
        $env:WORKSTATION_PREFERENCES = $null
    }
}


# ----------------------------------------------------------------------------
#  Short alias for the command typed every day.
#
#  The explicit name stays the real command: it is what Get-Command finds and
#  what the documentation uses. The alias exists only so that sitting down to
#  work costs two letters, the same way `macss` carries `ma`.
# ----------------------------------------------------------------------------
Set-Alias -Name ws -Value Start-Workstation

Export-ModuleMember -Function @(
    'Install-Workstation'
    'Get-WorkstationPreference'
    'Test-Workstation'
    'Start-Workstation'
) -Alias @('ws')
