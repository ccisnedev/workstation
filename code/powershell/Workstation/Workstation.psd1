# ============================================================================
#  Module manifest for Workstation
# ============================================================================

@{
    RootModule        = 'Workstation.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '3f9c2d61-8b47-4e05-a2d8-6c1e4b90f735'
    Author            = 'ccisnedev'
    Description       = 'A three-pane terminal workspace: Neovim, an AI agent and a shell, deployed from declared state. Laboratory for the future `macss workstation` command.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Install-Workstation'
        'Get-WorkstationPreference'
        'Test-Workstation'
        'Start-Workstation'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('ws')

    PrivateData = @{
        PSData = @{
            Tags       = @('workstation', 'neovim', 'wezterm', 'macss', 'ai-agent')
            ProjectUri = 'https://github.com/ccisnedev/workstation'
        }
    }
}
