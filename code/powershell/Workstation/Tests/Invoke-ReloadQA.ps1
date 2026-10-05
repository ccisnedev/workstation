#Requires -Version 7.0
<#
    QA for the editor reloading what the agent edits: the mod that runs inside
    Claude Code, the function in Neovim it calls, and the launch that connects
    the two panes of one window. Runs on Windows, Linux and macOS. Needs
    PowerShell, Neovim, Claude Code and Node.

    The contract under test:

        code/assets/claude/reload-mod
            After a tool that writes a file has run, tells the Neovim named by
            WORKSTATION_NVIM_SERVER which file changed, by one fixed argv. It
            never fails the edit.

        code/assets/neovim/reload.lua
            The function that argv calls. It reloads a loaded, unmodified
            buffer; it leaves a modified one alone and says so; it ignores a
            path nothing has loaded. It never opens a file, moves the cursor,
            changes the window or changes the current buffer.

        ws
            Gives each window its own Neovim server address, hands it to the
            editor pane as --listen and to the agent pane as an environment
            variable, and passes the mod to claude and to no other agent.

    The Neovim group runs a real headless Neovim listening on a real address
    and sends it the argv the mod builds: the mod's own module is run under
    Node with a stand-in for the engine's `$` that records the process it is
    asked to start. Nothing opens a window, and nothing outside the temporary
    directory is touched. The mod's own events are asserted by `claude plugin
    test`, which this suite runs.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$RepositoryRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ModulePath     = Join-Path $RepositoryRoot 'code/powershell/Workstation'
$ModDirectory   = Join-Path $RepositoryRoot 'code/assets/claude/reload-mod'
$ModModule      = Join-Path $ModDirectory 'hooks/reload.mjs'
$ReloadLua      = Join-Path $RepositoryRoot 'code/assets/neovim/reload.lua'
$InitLua        = Join-Path $RepositoryRoot 'code/assets/neovim/init.lua'
$WezTermLua     = Join-Path $RepositoryRoot 'code/assets/wezterm/wezterm.lua'
$TempRoot       = Join-Path ([System.IO.Path]::GetTempPath()) "workstation-reload-qa-$(Get-Random)"
$IsWindowsHost  = $IsWindows

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

Write-Host ''
Write-Host '  WORKSTATION - RELOAD QA' -ForegroundColor White
Write-Host "  repository: $RepositoryRoot" -ForegroundColor DarkGray

foreach ($needed in 'nvim', 'node', 'claude') {
    if ($null -eq (Get-Command $needed -ErrorAction Ignore)) {
        Write-Host "  $needed is not installed; this suite needs it." -ForegroundColor Red
        exit 1
    }
}

New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null

# ---------------------------------------------------------------------------
#  The mod's argv, produced by the mod's own code
#
#  A harness runs the module under Node, hands its tool.call hook an edit and
#  a stand-in `$`, and prints the process the hook asked to start. So the argv
#  the editor is tested with is the argv the mod builds, not a copy of it.
# ---------------------------------------------------------------------------
$HarnessPath = Join-Path $TempRoot 'harness.mjs'
Set-Content -LiteralPath $HarnessPath -Encoding utf8NoBOM -Value @'
import { pathToFileURL } from 'node:url'
const [modulePath, address, tool, path] = process.argv.slice(2)
const mod = await import(pathToFileURL(modulePath).href)
let hook
mod.register((event, handler) => { if (event === 'tool.call') hook = handler })
const runs = []
const $ = {
  env: { get: async (name) => (name === 'WORKSTATION_NVIM_SERVER' && address !== '-' ? address : undefined) },
  process: { run: async (argv) => { runs.push(argv); return { exitCode: 0, stdout: '', stderr: '' } } },
}
const input = tool === 'NotebookEdit' ? { tool, notebook_path: path } : { tool, file_path: path }
await hook($, input, async () => ({ result: 'ok' }))
console.log(JSON.stringify(runs))
'@

function Get-ModArgv {
    <# The argv the mod would run for an edit of `Path`; $null when it runs nothing. #>
    param([string] $Address, [string] $Path, [string] $Tool = 'Edit')
    $json = & node $HarnessPath $ModModule $Address $Tool $Path 2>&1 | Out-String
    $runs = @($json.Trim() | ConvertFrom-Json -NoEnumerate)
    if ($runs.Count -eq 0 -or $runs[0].Count -eq 0) { return $null }
    return @($runs[0][0])
}

# ---------------------------------------------------------------------------
#  A real, headless Neovim on a real address
# ---------------------------------------------------------------------------
$Address = if ($IsWindowsHost) { "\\.\pipe\workstation-nvim-qa-$([guid]::NewGuid().ToString('N').Substring(0, 12))" }
           else { Join-Path $TempRoot 'qa.sock' }

function Invoke-Remote {
    <# One expression evaluated in the server; returns its text. #>
    param([string] $Expression)
    return ((& nvim --headless --server $Address --remote-expr $Expression 2>&1 | Out-String).TrimEnd())
}
function Invoke-RemoteLua {
    <# One Lua expression evaluated in the server. The Lua must hold no single
       quote: it travels inside a Vim string. #>
    param([string] $Lua)
    return Invoke-Remote ("luaeval('" + $Lua + "')")
}

$reloadPath = $ReloadLua.Replace('\', '/')
$server = Start-Process -FilePath (Get-Command nvim).Source -PassThru -WindowStyle Hidden `
    -ArgumentList '--headless', '--listen', $Address, '-u', 'NONE', '-c', "`"luafile $reloadPath`""
$ready = $false
for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
    Start-Sleep -Milliseconds 250
    $ready = ((Invoke-Remote '1') -eq '1')
}

try {
    # =======================================================================
    Set-Group 'Group R1 - Neovim reloads what the agent changed'
    # =======================================================================

    Confirm-That 'R01' 'a headless Neovim is listening on the address' $ready $Address
    Confirm-That 'R02' 'the function the mod calls is defined there' `
        ((Invoke-RemoteLua 'type(workstation_reload)') -eq 'function') (Invoke-RemoteLua 'type(workstation_reload)')

    $dir = Join-Path $TempRoot 'a project'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $open   = (Join-Path $dir 'open.txt')
    $other  = (Join-Path $dir 'other.txt')
    $absent = (Join-Path $dir 'absent.txt')
    foreach ($f in $open, $other, $absent) { Set-Content -LiteralPath $f -Value 'one' -Encoding utf8NoBOM }

    function ConvertTo-LuaString { param([string] $Text) return '[[' + $Text.Replace('\', '/') + ']]' }

    # open.txt is the current buffer with the cursor on its second line;
    # other.txt is loaded but not displayed.
    Set-Content -LiteralPath $open -Value "one`nuno`ntres" -Encoding utf8NoBOM
    Invoke-RemoteLua ("(function() vim.cmd.edit(vim.fn.fnameescape($(ConvertTo-LuaString $open))); vim.cmd.badd(vim.fn.fnameescape($(ConvertTo-LuaString $other))); vim.fn.bufload($(ConvertTo-LuaString $other)); vim.api.nvim_win_set_cursor(0, {2, 1}); return 1 end)()") | Out-Null

    function Get-Position {
        Invoke-RemoteLua 'vim.api.nvim_get_current_buf() .. [[ ]] .. vim.api.nvim_get_current_win() .. [[ ]] .. table.concat(vim.api.nvim_win_get_cursor(0), [[,]]) .. [[ ]] .. #vim.api.nvim_list_wins() .. [[ ]] .. #vim.fn.getbufinfo({buflisted = 1})'
    }
    function Get-BufferText {
        param([string] $Path)
        Invoke-RemoteLua "table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr($(ConvertTo-LuaString $Path)), 0, -1, false), [[|]])"
    }
    function Send-Edit {
        param([string] $Path)
        $argv = Get-ModArgv -Address $Address -Path $Path
        if ($null -eq $argv) { return 'the mod ran nothing' }
        $exe = (Get-Command nvim).Source
        return ((& $exe @($argv[1..($argv.Count - 1)]) 2>&1 | Out-String).TrimEnd())
    }

    $before = Get-Position

    # The current, unmodified buffer, changed on disk.
    Set-Content -LiteralPath $open -Value "one`ndos`ntres`ncuatro" -Encoding utf8NoBOM
    $sent = Send-Edit $open
    Confirm-That 'R03' 'the argv the mod builds reloads an open, unmodified buffer whose file changed' `
        ((Get-BufferText $open) -eq 'one|dos|tres|cuatro') "buffer: $(Get-BufferText $open); sent: $sent"
    Confirm-That 'R04' 'and the cursor, the window and the current buffer are where they were' `
        ((Get-Position) -eq $before) "before: $before; after: $(Get-Position)"

    # A loaded buffer nobody is looking at.
    Set-Content -LiteralPath $other -Value "dos`nlineas" -Encoding utf8NoBOM
    Send-Edit $other | Out-Null
    Confirm-That 'R05' 'a loaded buffer that is not displayed is reloaded too' `
        ((Get-BufferText $other) -eq 'dos|lineas') (Get-BufferText $other)
    Confirm-That 'R06' 'and neither case changes where the user is' ((Get-Position) -eq $before) "after: $(Get-Position)"

    # A buffer with unsaved changes.
    Invoke-RemoteLua "(function() vim.api.nvim_buf_set_lines(vim.fn.bufnr($(ConvertTo-LuaString $other)), 0, 1, false, {[[mine]]}); return 1 end)()" | Out-Null
    Invoke-RemoteLua 'vim.cmd.messages([[clear]])' | Out-Null
    Set-Content -LiteralPath $other -Value "theirs`nlineas`nmas" -Encoding utf8NoBOM
    Send-Edit $other | Out-Null
    $messages = Invoke-Remote "execute('messages')"
    Confirm-That 'R07' 'a buffer with unsaved changes keeps its text' `
        ((Get-BufferText $other) -eq 'mine|lineas') (Get-BufferText $other)
    Confirm-That 'R08' 'and Neovim records a notice that names the file' `
        ($messages -match 'other\.txt') $messages
    Confirm-That 'R09' 'and the cursor, the window and the current buffer are where they were' ((Get-Position) -eq $before) "after: $(Get-Position)"

    # A path nothing has loaded.
    $bufferCount = Invoke-RemoteLua '#vim.api.nvim_list_bufs()'
    Set-Content -LiteralPath $absent -Value "changed`non disk" -Encoding utf8NoBOM
    Send-Edit $absent | Out-Null
    Confirm-That 'R10' 'a path with no loaded buffer opens nothing' `
        ((Invoke-RemoteLua '#vim.api.nvim_list_bufs()') -eq $bufferCount -and (Invoke-RemoteLua "vim.fn.bufexists($(ConvertTo-LuaString $absent))") -eq '0') `
        "buffers: $(Invoke-RemoteLua '#vim.api.nvim_list_bufs()') (was $bufferCount)"
    Confirm-That 'R11' 'and changes nothing about where the user is' ((Get-Position) -eq $before) "after: $(Get-Position)"

    # The same path spelled the other way round on Windows, where both are the file.
    if ($IsWindowsHost) {
        Set-Content -LiteralPath $open -Value "one`nthree`ntres`ncuatro`ncinco" -Encoding utf8NoBOM
        Send-Edit $open.ToUpperInvariant().Replace('/', '\') | Out-Null
        Confirm-That 'R12' 'on Windows a path spelled in another case reloads the same buffer' `
            ((Get-BufferText $open) -eq 'one|three|tres|cuatro|cinco') (Get-BufferText $open)
    }
}
finally {
    # Close the server this suite started, by its own address, and only if it
    # does not leave when asked, by the process this suite started.
    if ($ready) { Invoke-Remote "execute('qa!')" | Out-Null }
    if ($null -ne $server -and -not $server.WaitForExit(3000)) { Stop-Process -Id $server.Id -Force -ErrorAction Ignore }
}

# ===========================================================================
Set-Group 'Group R2 - the editor loads the function'
# ===========================================================================

$initText = Get-Content -LiteralPath $InitLua -Raw
Confirm-That 'R13' 'init.lua loads reload.lua, which sits beside it' `
    ($initText -match 'reload\.lua' -and (Test-Path -LiteralPath $ReloadLua)) $InitLua

# ===========================================================================
Set-Group 'Group R3 - each window gets its own Neovim address'
# ===========================================================================

$GeneratedDir = Join-Path $TempRoot 'generated'
$StatusDir    = Join-Path $GeneratedDir 'status'
$BinDir       = Join-Path $TempRoot 'bin'
$DumpFile     = Join-Path $TempRoot 'terminal-environment.txt'
$ShopDir      = Join-Path $TempRoot 'shop'
New-Item -ItemType Directory -Force -Path $GeneratedDir, $BinDir, $ShopDir | Out-Null

# A stand-in terminal that writes down what it was started with, so the
# environment a window really inherits can be read without opening one.
if ($IsWindowsHost) {
    Set-Content -LiteralPath (Join-Path $BinDir 'qa-terminal.cmd') -Encoding ascii -Value @(
        '@echo off'
        '>"%QA_DUMP%" echo %WORKSTATION_NVIM_SERVER%'
    )
}
else {
    $stub = Join-Path $BinDir 'qa-terminal'
    Set-Content -LiteralPath $stub -Encoding utf8NoBOM -Value @('#!/bin/sh', 'printf "%s\n" "$WORKSTATION_NVIM_SERVER" > "$QA_DUMP"')
    chmod +x $stub
}

$generatedForPsd1 = $GeneratedDir.Replace('\', '/')
$FixturePath = Join-Path $TempRoot 'declared-state.psd1'
Set-Content -LiteralPath $FixturePath -Encoding utf8 -Value @"
@{
    Name = 'qa-reload'; Version = '0.0.0'; Description = 'fixture'
    Tools = @(
        @{ Name = 'Stand-in terminal'; Purpose = 'Terminal'; Command = 'qa-terminal'; Required = `$true; Role = 'terminal'
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
$separator = [System.IO.Path]::PathSeparator
$previousPath = $env:PATH
$env:PATH = "$BinDir$separator$env:PATH"
$env:WORKSTATION_DECLARED_STATE = $FixturePath
$env:QA_DUMP = $DumpFile
Import-Module $ModulePath -Force -ErrorAction Stop

function Invoke-Start {
    param([hashtable] $Arguments)
    $errors = $null; $warnings = $null
    $result = Start-Workstation @Arguments -WhatIf -PassThru -ErrorAction SilentlyContinue -ErrorVariable errors -WarningAction SilentlyContinue -WarningVariable warnings 2>$null
    return [PSCustomObject]@{
        Result   = $result
        Message  = (@($errors) | ForEach-Object { $_.ToString() }) -join ' '
        Warnings = (@($warnings) | ForEach-Object { $_.ToString() }) -join ' '
    }
}

try {
    $one = Invoke-Start @{ Project = $ShopDir }
    $two = Invoke-Start @{ Project = $ShopDir }
    function Get-LaunchAddress { param($Result)
        if ($null -eq $Result -or $null -eq $Result.PSObject.Properties['NvimServer']) { return '' }
        return [string] $Result.NvimServer
    }
    $addressOne = Get-LaunchAddress $one.Result
    $addressTwo = Get-LaunchAddress $two.Result

    Confirm-That 'R20' 'a launch carries a Neovim server address' `
        (-not [string]::IsNullOrEmpty($addressOne)) "launch: $($one.Message)"
    Confirm-That 'R21' 'two windows over the same project get different addresses' `
        ($addressOne -ne '' -and $addressTwo -ne '' -and $addressOne -ne $addressTwo) "$addressOne / $addressTwo"
    if ($IsWindowsHost) {
        Confirm-That 'R22' 'on Windows the address is a named pipe' `
            ($addressOne -match '^\\\\\.\\pipe\\workstation-nvim-[0-9a-f]+$') $addressOne
    }
    else {
        $expectedDirectory = $StatusDir.Replace('\', '/')
        Confirm-That 'R22' 'elsewhere the address is a socket path in a directory the workstation owns' `
            ($addressOne.Replace('\', '/') -like "$expectedDirectory/*") $addressOne
        Confirm-That 'R23' 'and that directory exists, so Neovim can create the socket in it' `
            (Test-Path -LiteralPath (Split-Path -Parent $addressOne)) $addressOne
    }

    # A real launch, with a stand-in for the terminal: the environment it is
    # started with is the one every pane of the window inherits.
    Remove-Item -LiteralPath $DumpFile -Force -ErrorAction Ignore
    $real = Start-Workstation -Project $ShopDir -PassThru 6>$null
    for ($i = 0; $i -lt 40 -and -not (Test-Path -LiteralPath $DumpFile); $i++) { Start-Sleep -Milliseconds 250 }
    $dumped = if (Test-Path -LiteralPath $DumpFile) { (Get-Content -LiteralPath $DumpFile -Raw).Trim() } else { '' }
    Confirm-That 'R24' 'the window is started with that address in its environment, for the agent pane to read' `
        ($dumped -ne '' -and $dumped -eq (Get-LaunchAddress $real)) "environment: '$dumped'; launch: $(Get-LaunchAddress $real)"
    Confirm-That 'R25' 'and the launching shell is left clean' ([string]::IsNullOrEmpty($env:WORKSTATION_NVIM_SERVER)) $env:WORKSTATION_NVIM_SERVER

    # ---- The mod is passed to claude, and to no other agent ----------------
    $modForCommand = $ModDirectory.Replace('\', '/')
    $claude = Invoke-Start @{ Project = $ShopDir }
    Confirm-That 'R26' 'claude is started with the mod, by --plugin-dir and forward slashes' `
        ($null -ne $claude.Result -and $claude.Result.AgentCommand -eq ('pwsh --plugin-dir "{0}"' -f $modForCommand)) "command: $($claude.Result.AgentCommand)"

    $settingsPath = Join-Path $GeneratedDir 'claude-settings.json'
    Set-Content -LiteralPath $settingsPath -Value '{}' -Encoding utf8NoBOM
    $withSettings = Invoke-Start @{ Project = $ShopDir }
    Confirm-That 'R27' 'beside the generated settings, which stay as they were' `
        ($null -ne $withSettings.Result -and $withSettings.Result.AgentCommand -eq ('pwsh --settings "{0}" --plugin-dir "{1}"' -f $settingsPath.Replace('\', '/'), $modForCommand)) "command: $($withSettings.Result.AgentCommand)"
    Confirm-That 'R28' 'the mod is a directory with a manifest, so the flag names something that loads' `
        (Test-Path -LiteralPath (Join-Path $ModDirectory '.claude-plugin/plugin.json'))

    $codex = Invoke-Start @{ Project = $ShopDir; Agent = 'codex' }
    Confirm-That 'R29' 'another agent is started exactly as before' `
        ($null -ne $codex.Result -and $codex.Result.AgentCommand -eq 'pwsh') "command: $($codex.Result.AgentCommand)"


    # =======================================================================
    Set-Group 'Group R4 - the editor pane listens on that address'
    # =======================================================================

    # wezterm.lua is run here with a stand-in for WezTerm that records the
    # panes it is asked to open, so the command the editor pane runs can be
    # read without a window.
    $weztermDir = (Split-Path -Parent $WezTermLua).Replace('\', '/')
    $stubLua = Join-Path $TempRoot 'wezterm-stub.lua'
    Set-Content -LiteralPath $stubLua -Encoding utf8NoBOM -Value @"
local function inert() local p; p = setmetatable({}, { __index = function() return p end, __call = function() return p end }); return p end
local handlers = {}
local spawned = {}
local pane = { split = function(_, o) spawned[#spawned + 1] = o.args end, activate = function() end }
local wezterm = setmetatable({
  target_triple = '$(if ($IsWindowsHost) { 'x86_64-pc-windows-msvc' } else { 'x86_64-unknown-linux-gnu' })',
  config_dir = [[$weztermDir]],
  config_builder = function() return {} end,
  on = function(name, fn) handlers[name] = fn end,
  mux = { spawn_window = function(o) spawned[#spawned + 1] = o.args; return {}, pane, {} end },
}, { __index = function() return inert() end })
package.preload['wezterm'] = function() return wezterm end
dofile([[$($WezTermLua.Replace('\', '/'))]])
handlers['gui-startup']({})
io.write(vim.json.encode(spawned))
"@

    function Get-PaneCommands {
        param([AllowNull()][string] $Address)
        $previous = @{ A = $env:WORKSTATION_AGENT; D = $env:WORKSTATION_DIRECTORY; S = $env:WORKSTATION_NVIM_SERVER }
        $env:WORKSTATION_AGENT = 'claude'; $env:WORKSTATION_DIRECTORY = $ShopDir; $env:WORKSTATION_NVIM_SERVER = $Address
        try { $out = & nvim --headless -u NONE -l $stubLua 2>&1 | Out-String }
        finally { $env:WORKSTATION_AGENT = $previous.A; $env:WORKSTATION_DIRECTORY = $previous.D; $env:WORKSTATION_NVIM_SERVER = $previous.S }
        try { return @($out.Trim() | ConvertFrom-Json -NoEnumerate) } catch { return @("NOT-JSON: $out") }
    }

    $panes = Get-PaneCommands -Address $addressOne
    $editorText = if ($panes.Count -gt 0) { ($panes[0] -join ' ') } else { '' }
    Confirm-That 'R40' 'the editor pane runs nvim with --listen set to the window''s address' `
        ($editorText.Contains("--listen '$addressOne'")) $editorText
    $agentText = if ($panes.Count -gt 1) { ($panes[1] -join ' ') } else { '' }
    Confirm-That 'R41' 'the agent pane command is untouched: it reads the address from its environment' `
        (-not $agentText.Contains('--listen')) $agentText

    $unaddressed = Get-PaneCommands -Address ''
    $plainText = if ($unaddressed.Count -gt 0) { ($unaddressed[0] -join ' ') } else { '' }
    Confirm-That 'R42' 'with no address the editor pane is the one it always was' `
        ($plainText -match 'nvim \.' -and -not $plainText.Contains('--listen')) $plainText

    # The command string, as the pane's shell reads it, really listens there.
    $probeAddress = if ($IsWindowsHost) { "\\.\pipe\workstation-nvim-qa-probe-$([guid]::NewGuid().ToString('N').Substring(0, 8))" }
                    else { Join-Path $TempRoot 'probe.sock' }
    $probePanes = Get-PaneCommands -Address $probeAddress
    $probeCommand = ($probePanes[0][-1]) -replace 'nvim ', 'nvim --headless ' -replace ' \.$', ''
    $probeShell = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-Command', "`"$($probeCommand.Replace('"', '\"'))`""
    $listening = $false
    for ($i = 0; $i -lt 40 -and -not $listening; $i++) {
        Start-Sleep -Milliseconds 250
        $listening = ((& nvim --headless --server $probeAddress --remote-expr '1' 2>&1 | Out-String).Trim() -eq '1')
    }
    Confirm-That 'R43' 'and the command, run by a shell, starts a Neovim that answers on that address' $listening $probeCommand
    if ($listening) { & nvim --headless --server $probeAddress --remote-expr "execute('qa!')" 2>&1 | Out-Null }
    if (-not $probeShell.WaitForExit(3000)) { Stop-Process -Id $probeShell.Id -Force -ErrorAction Ignore }

    # =======================================================================
    Set-Group 'Group R5 - the mod'
    # =======================================================================

    $validation = (& claude plugin validate $ModDirectory 2>&1 | Out-String)
    Confirm-That 'R50' '`claude plugin validate` passes on the mod' `
        ($validation -match 'Validation passed') $validation
    Confirm-That 'R51' 'and the calls it makes are env.get and process.run, nothing else' `
        ($validation -match 'calls: \$\.env\.get, \$\.process\.run\r?\n' -and $validation -match 'hooks: tool\.call\r?\n' -and $validation -match 'env writes: nothing') $validation
    Confirm-That 'R52' 'and the only variable it reads is the Neovim address' `
        ($validation -match 'env reads: WORKSTATION_NVIM_SERVER\r?\n') $validation

    $testRun = (& claude plugin test $ModDirectory 2>&1 | Out-String)
    $testExit = $LASTEXITCODE
    Confirm-That 'R53' '`claude plugin test` passes: the events, the other tools, the failures that must not matter' `
        ($testExit -eq 0 -and $testRun -match ' 0 fail') $testRun
}
finally {
    $env:PATH = $previousPath
    $env:WORKSTATION_DECLARED_STATE = $null
    $env:QA_DUMP = $null
}

# ---------------------------------------------------------------------------
#  Summary
# ---------------------------------------------------------------------------
Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction Ignore

$failed = @($script:Results | Where-Object { -not $_.Passed })
Write-Host ''
Write-Host ('  {0} assertions, {1} passed, {2} failed' -f $script:Results.Count, ($script:Results.Count - $failed.Count), $failed.Count) `
    -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })
exit $failed.Count
