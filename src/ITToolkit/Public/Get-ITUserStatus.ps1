function Get-ITUserStatus {
    <#
    .SYNOPSIS
    One-screen user account check for a hybrid domain: AD enabled, locked out, bad passwords, password expiry, plus Entra ID sync, sign-in, licenses and MFA methods.

    .DESCRIPTION
    Answers the first questions on most "I can't sign in" calls and rates each answer OK, Warn,
    Fail or Info.

    Active Directory (needs the ActiveDirectory module from RSAT):
      account details, enabled, locked out (with bad password count and time), password last set
      and expiry (including fine-grained password policies), account expiry, last logon.
      Lockout and bad password data are read from the PDC emulator by default, which has the most
      current values, because domain controllers keep bad password counts separately.

    Entra ID (needs Microsoft Graph PowerShell, connected with Connect-MgGraph):
      synced from AD or cloud-only, allowed or blocked from signing in to Microsoft 365, last
      sign-in, licenses, and registered MFA methods (phone numbers show only the last 4 digits).
      If Graph PowerShell is missing or not connected, the Entra checks are skipped with a note.
      Connect once per PowerShell window:
          Connect-MgGraph -Scopes User.Read.All, UserAuthenticationMethod.Read.All, AuditLog.Read.All

    Read-only: it changes nothing.

    .PARAMETER Identity
    The user: account name (jlee), UPN or email address (jordan.lee@example.com), distinguished
    name or SID. Accepts pipeline input, including Get-ADUser output.

    .PARAMETER Server
    Domain controller to read from. Defaults to the PDC emulator.

    .PARAMETER SkipEntra
    Checks Active Directory only.

    .EXAMPLE
    Get-ITUserStatus jlee

    .EXAMPLE
    Get-ITUserStatus jordan.lee@example.com | ConvertTo-ITTicketNote -Clipboard

    Checks the user by email address and copies the result for the ticket.

    .EXAMPLE
    Get-ADGroupMember 'Sales' | Get-ITUserStatus -SkipEntra | Where-Object Status -eq 'Fail'

    Finds locked-out, disabled or expired accounts in a group.

    .OUTPUTS
    ITToolkit.UserCheck
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('SamAccountName', 'UserPrincipalName', 'UserName')]
        [string[]]$Identity,

        [string]$Server,

        [switch]$SkipEntra
    )

    begin {
        Assert-ITActiveDirectory
        $settings = (Get-ITSettings).User
        if (-not $Server) { $Server = Get-ITPdcEmulator }
    }

    process {
        foreach ($name in $Identity) {
            try {
                $user = Resolve-ITADUser -Identity $name -Server $Server
                $entra = $null
                if (-not $SkipEntra) {
                    if ($user.UserPrincipalName) {
                        $entra = Get-ITEntraUser -UserPrincipalName $user.UserPrincipalName
                    }
                    else {
                        $entra = [pscustomobject]@{ Available = $false; Reason = 'the account has no UPN' }
                    }
                }
                ConvertTo-ITUserCheck -User $user -Entra $entra -Server $Server -Settings $settings
            }
            catch {
                Write-Error -Message "${name}: $($_.Exception.Message)" -Exception $_.Exception -TargetObject $name
            }
        }
    }
}
