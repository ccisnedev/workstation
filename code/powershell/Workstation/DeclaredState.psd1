# ============================================================================
#  DECLARED STATE OF THE WORKSTATION
#
#  This file is the source of truth. It describes how a machine must look for
#  the workstation to work: which tools have to be present, which directories
#  have to be linked back to this repository, and which AI agents are expected.
#
#  Install-Workstation reads this file and converges the machine towards it.
#  Nothing happens that is not declared here.
#
#  Two rules govern what may appear in this file:
#
#    1. The workstation never owns what it did not create. Every target below
#       is a path this repository is the sole author of. Nothing points at a
#       directory another tool or the user already owns.
#       See docs/adr/0002-the-workstation-never-owns-what-it-did-not-create.md
#
#    2. Tools are detected and reported, never installed behind your back.
#       `Install-Workstation -InstallMissingTools` is the only way anything
#       reaches a package manager, and you have to ask for it.
# ============================================================================

@{

    Name        = 'workstation'
    Version     = '0.1.0'
    Description = 'A three-pane terminal workspace: editor, AI agent and shell.'


    # ------------------------------------------------------------------------
    #  TOOLS
    #
    #  Command is what is looked for on PATH. LinuxCommand overrides it where a
    #  distribution ships the binary under a different name.
    #
    #  The install strings are printed for the human to run. They are not
    #  executed unless -InstallMissingTools is passed, and on Linux they are
    #  never executed at all, because the correct package manager is not
    #  something this repository is entitled to guess.
    # ------------------------------------------------------------------------
    Tools = @(
        @{
            Name           = 'WezTerm'
            Purpose        = 'Terminal with a native pane multiplexer'
            Command        = 'wezterm'
            WindowsInstall = 'winget install --id wez.wezterm --exact'
            LinuxInstall   = 'See https://wezterm.org/install/linux.html'
        }
        @{
            Name           = 'Neovim'
            Purpose        = 'Editor in the left pane'
            Command        = 'nvim'
            WindowsInstall = 'winget install --id Neovim.Neovim --exact'
            LinuxInstall   = 'sudo apt install neovim   # or see https://neovim.io/'
        }
        @{
            Name           = 'Git'
            Purpose        = 'Required by the Neovim plugin manager'
            Command        = 'git'
            WindowsInstall = 'winget install --id Git.Git --exact'
            LinuxInstall   = 'sudo apt install git'
        }
        @{
            Name           = 'ripgrep'
            Purpose        = 'Text search inside the editor'
            Command        = 'rg'
            WindowsInstall = 'winget install --id BurntSushi.ripgrep.MSVC --exact'
            LinuxInstall   = 'sudo apt install ripgrep'
        }
        @{
            Name           = 'fd'
            Purpose        = 'File search inside the editor'
            Command        = 'fd'
            LinuxCommand   = 'fdfind'
            WindowsInstall = 'winget install --id sharkdp.fd --exact'
            LinuxInstall   = 'sudo apt install fd-find'
        }
    )


    # ------------------------------------------------------------------------
    #  LINKS
    #
    #  Each entry links a directory this repository owns into the place the
    #  tool reads it from. A junction on Windows, a symbolic link elsewhere;
    #  neither needs administrator rights.
    #
    #  A link is not a copy: it is the same directory seen from two paths. That
    #  is what makes editing the deployed file and editing the repository the
    #  same act, and what makes drift between the two impossible.
    #
    #  Placeholders accepted in the target paths:
    #     {LOCALAPPDATA}       Windows, C:\Users\<user>\AppData\Local
    #     {XDG_CONFIG_HOME}    Linux and macOS, defaults to ~/.config
    #     {HOME}               the user's home directory on any platform
    #
    #  WezTerm deliberately has no entry here. Start-Workstation passes its
    #  configuration with `wezterm --config-file`, so the user's own WezTerm
    #  configuration is never displaced.
    # ------------------------------------------------------------------------
    Links = @(
        @{
            Name          = 'Neovim configuration'
            Source        = 'assets/neovim'
            WindowsTarget = '{LOCALAPPDATA}/workstation'
            LinuxTarget   = '{XDG_CONFIG_HOME}/workstation'
            Note          = 'Read only when NVIM_APPNAME=workstation. Plain nvim is untouched.'
        }
    )


    # ------------------------------------------------------------------------
    #  POWERSHELL PROFILE
    #
    #  The profile is a single file, and a link can only replace a directory,
    #  so the module is imported from a marked block appended to the profile
    #  instead. The markers make the block idempotent to write and trivial to
    #  remove, and everything the user already had in that file is preserved.
    # ------------------------------------------------------------------------
    PowerShellProfile = @{
        Name        = 'PowerShell profile block'
        OpenMarker  = '# >>> workstation >>>'
        CloseMarker = '# <<< workstation <<<'
    }


    # ------------------------------------------------------------------------
    #  PREFERENCES
    #
    #  Where taste lives, and where a machine may override it. Nothing in this
    #  entry is itself a preference: it declares the resolution order, which is
    #  architecture. The values being resolved are in Preferences.psd1.
    #
    #  Resolution is shipped defaults first, then the machine override on top,
    #  section by section. A key absent from the override keeps its default.
    # ------------------------------------------------------------------------
    Preferences = @{
        Name            = 'Preference defaults'
        ShippedFile     = 'Preferences.psd1'
        WindowsOverride = '{LOCALAPPDATA}/workstation.preferences.psd1'
        LinuxOverride   = '{XDG_CONFIG_HOME}/workstation.preferences.psd1'
    }


    # ------------------------------------------------------------------------
    #  GENERATED ARTIFACTS
    #
    #  Neither Lua file can read a PowerShell data file, so the resolved
    #  preferences are compiled into one that both can. This is machine output:
    #  regenerated by every apply, never edited by hand, never committed.
    #
    #  It deliberately lands outside the linked configuration directory. Writing
    #  it inside would put generated output into the repository, which is the
    #  one thing a declared-state repository must never contain.
    # ------------------------------------------------------------------------
    GeneratedArtifacts = @(
        @{
            Name          = 'Resolved preferences'
            FileName      = 'preferences.lua'
            WindowsTarget = '{LOCALAPPDATA}/workstation-generated'
            LinuxTarget   = '{XDG_CONFIG_HOME}/workstation-generated'
            Note          = 'Read by both init.lua and wezterm.lua through WORKSTATION_PREFERENCES.'
        }
    )


    # ------------------------------------------------------------------------
    #  AGENTS
    #
    #  Reported only. Every one of these requires an interactive sign-in, so
    #  none of them can be meaningfully installed by a script.
    # ------------------------------------------------------------------------
    Agents = @(
        @{
            Name           = 'claude'
            Command        = 'claude'
            Product        = 'Claude Code by Anthropic'
            WindowsInstall = 'npm install --global @anthropic-ai/claude-code'
            LinuxInstall   = 'npm install --global @anthropic-ai/claude-code'
        }
        @{
            Name           = 'codex'
            Command        = 'codex'
            Product        = 'Codex by OpenAI'
            WindowsInstall = 'npm install --global @openai/codex'
            LinuxInstall   = 'npm install --global @openai/codex'
        }
        @{
            Name           = 'antigravity'
            Command        = 'agy'
            Product        = 'Antigravity CLI by Google'
            WindowsInstall = 'Invoke-RestMethod https://antigravity.google/cli/install.ps1 | Invoke-Expression'
            LinuxInstall   = 'curl -fsSL https://antigravity.google/cli/install.sh | bash'
        }
        @{
            Name           = 'opencode'
            Command        = 'opencode'
            Product        = 'opencode by SST'
            WindowsInstall = 'npm install --global opencode-ai'
            LinuxInstall   = 'npm install --global opencode-ai'
        }
    )
}
