@{
    RootModule           = 'ITToolkit.psm1'
    ModuleVersion        = '1.2.0'
    CompatiblePSEditions = @('Desktop', 'Core')
    GUID                 = '0d466920-fa5f-4e94-9845-e2c914dccdef'
    Author               = 'IT Department'
    Copyright            = 'Internal use.'
    Description          = 'Everyday diagnostics for the IT team: device health, pending reboots, local admins, installed software, event log summaries, signed-in users, network and port tests, temp file cleanup, user account status, lockout sources, password resets, passphrases and ticket notes.'
    PowerShellVersion    = '5.1'
    FormatsToProcess     = @('ITToolkit.Format.ps1xml')
    FunctionsToExport    = @(
        'Clear-ITTempFile'
        'ConvertTo-ITTicketNote'
        'Get-ITDeviceHealth'
        'Get-ITEventSummary'
        'Get-ITHubToolCatalog'
        'Get-ITInstalledSoftware'
        'Get-ITLocalAdmin'
        'Get-ITLockoutSource'
        'Get-ITLoggedOnUser'
        'Get-ITPendingReboot'
        'Get-ITToolkitCommand'
        'Get-ITToolkitSetting'
        'Get-ITUserStatus'
        'Invoke-ITHubTool'
        'New-ITPassphrase'
        'Reset-ITUserPassword'
        'Test-ITNetwork'
        'Test-ITPort'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags         = @('IT', 'Helpdesk', 'Diagnostics', 'Windows')
            ReleaseNotes = 'See CHANGELOG.md.'
        }
    }
}
