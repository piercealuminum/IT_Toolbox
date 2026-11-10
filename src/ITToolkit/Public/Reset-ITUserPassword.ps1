function Reset-ITUserPassword {
    <#
    .SYNOPSIS
    Resets an AD user's password to a new easy-to-read passphrase, requires a change at next sign-in and unlocks the account.

    .DESCRIPTION
    Generates a passphrase with New-ITPassphrase, sets it in Active Directory, sets "User must
    change password at next logon" and unlocks the account if it is locked. Changes are made on
    the PDC emulator by default so they take effect at once everywhere.

    Asks for confirmation before resetting (use -Confirm:$false to skip). Supports -WhatIf.

    The passphrase is shown once in the result so you can read it to the user. Use -Clipboard
    to also copy it. ConvertTo-ITTicketNote leaves it out, so it never ends up in a ticket.

    Hybrid domain: Entra Connect (password hash sync) sends the new password to Microsoft 365
    within a few minutes. Microsoft 365 only forces the change if Entra Connect has the
    ForcePasswordChangeOnLogOn feature turned on; otherwise have the user change it at a
    Windows sign-in or with Ctrl+Alt+Del, Change a password.

    Needs permission to reset passwords on the user's OU.

    .PARAMETER Identity
    The user: account name, UPN or email address, distinguished name or SID.

    .PARAMETER NoChangeAtNextSignIn
    Does not require the user to change the password at next sign-in.

    .PARAMETER Clipboard
    Also copies the new passphrase to the clipboard.

    .PARAMETER Server
    Domain controller to make the change on. Defaults to the PDC emulator.

    .EXAMPLE
    Reset-ITUserPassword jlee

    Asks for confirmation, then shows the new passphrase to read to the user.

    .EXAMPLE
    Reset-ITUserPassword jordan.lee@example.com -Clipboard -Confirm:$false

    .EXAMPLE
    Reset-ITUserPassword jlee -WhatIf

    Shows what would change without changing anything.

    .OUTPUTS
    ITToolkit.PasswordReset
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('SamAccountName', 'UserPrincipalName', 'UserName')]
        [string]$Identity,

        [switch]$NoChangeAtNextSignIn,

        [switch]$Clipboard,

        [string]$Server
    )

    begin {
        Assert-ITActiveDirectory
        if (-not $Server) { $Server = Get-ITPdcEmulator }
    }

    process {
        try {
            $user = Resolve-ITADUser -Identity $Identity -Server $Server
            $label = if ($user.DisplayName) { "$($user.DisplayName) ($($user.SamAccountName))" } else { [string]$user.SamAccountName }
            $steps = @('reset password')
            if (-not $NoChangeAtNextSignIn) { $steps += 'require change at next sign-in' }
            if ($user.LockedOut) { $steps += 'unlock' }
            if (-not $PSCmdlet.ShouldProcess($label, ($steps -join ', '))) { return }

            if (-not $user.Enabled) {
                Write-Warning "$label is disabled in Active Directory. The new password will not work until the account is enabled."
            }

            $passphrase = New-ITPassphrase
            $secure = New-Object System.Security.SecureString
            foreach ($character in $passphrase.ToCharArray()) { $secure.AppendChar($character) }
            $secure.MakeReadOnly()

            Set-ADAccountPassword -Identity $user -Reset -NewPassword $secure -Server $Server -ErrorAction Stop

            # The password has changed now, so from here on report problems but always return
            # the new passphrase: losing it would leave the user with a password nobody knows.
            $problems = New-Object System.Collections.Generic.List[string]
            $mustChange = $false
            if (-not $NoChangeAtNextSignIn) {
                try {
                    Set-ADUser -Identity $user -ChangePasswordAtLogon $true -Server $Server -ErrorAction Stop
                    $mustChange = $true
                }
                catch { $problems.Add("could not require a change at next sign-in: $($_.Exception.Message)") }
            }
            $unlocked = $false
            if ($user.LockedOut) {
                try {
                    Unlock-ADAccount -Identity $user -Server $Server -ErrorAction Stop
                    $unlocked = $true
                }
                catch { $problems.Add("could not unlock the account: $($_.Exception.Message)") }
            }
            if ($Clipboard) {
                try { Set-Clipboard -Value $passphrase }
                catch { $problems.Add("could not copy to the clipboard: $($_.Exception.Message)") }
            }
            foreach ($problem in $problems) { Write-Warning "${label}: password was reset, but $problem" }

            [pscustomobject]@{
                PSTypeName             = 'ITToolkit.PasswordReset'
                UserName               = [string]$user.SamAccountName
                DisplayName            = [string]$user.DisplayName
                Passphrase             = $passphrase
                MustChangeAtNextSignIn = $mustChange
                Unlocked               = $unlocked
                DomainController       = $Server
                ResetAt                = Get-Date
                Problems               = $problems.ToArray()
            }
        }
        catch {
            Write-Error -Message "${Identity}: $($_.Exception.Message)" -Exception $_.Exception -TargetObject $Identity
        }
    }
}
