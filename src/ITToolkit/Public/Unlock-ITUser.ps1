function Unlock-ITUser {
    <#
    .SYNOPSIS
    Unlocks a locked-out Active Directory account and shows its state before and after.

    .DESCRIPTION
    Reads the account on the PDC emulator, unlocks it there if it is locked out (so the unlock
    takes effect at once everywhere), and reads it again. Returns two ITToolkit.UserAccount
    records: State Before and State After. If the account was not locked out, nothing is
    changed and a warning says so.

    Unlocking does not stop the cause. If the account locks again, find the computer sending
    the old password with Get-ITLockoutSource.

    Supports -WhatIf and -Confirm. Needs the ActiveDirectory module (RSAT) and the right to
    unlock accounts in the user's OU (write lockoutTime).

    .PARAMETER Identity
    The user: account name, UPN or email address, distinguished name or SID.

    .PARAMETER Server
    Domain controller to unlock on. Defaults to the PDC emulator.

    .EXAMPLE
    Unlock-ITUser jlee

    .EXAMPLE
    Unlock-ITUser jlee -WhatIf

    .EXAMPLE
    Get-ITLockoutSource -Hours 1 | Select-Object -ExpandProperty UserName -Unique | Unlock-ITUser -Confirm

    Unlocks, one confirmation at a time, every account locked out in the last hour.

    .OUTPUTS
    ITToolkit.UserAccount
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('SamAccountName', 'UserPrincipalName', 'UserName')]
        [string]$Identity,

        [string]$Server
    )

    begin {
        Assert-ITActiveDirectory
        if (-not $Server) { $Server = Get-ITPdcEmulator }
    }

    process {
        try {
            $user = Resolve-ITADUser -Identity $Identity -Server $Server
            $before = ConvertTo-ITUserAccount -User $user -Server $Server -State 'Before'
            $label = if ($user.DisplayName) { "$($user.DisplayName) ($($user.SamAccountName))" } else { [string]$user.SamAccountName }

            if (-not $user.LockedOut) {
                Write-Warning "$label is not locked out; nothing to unlock."
                $before
                $after = $before.PSObject.Copy()
                $after.State = 'After'
                $after
                return
            }
            if (-not $PSCmdlet.ShouldProcess($label, 'Unlock the account')) { return }

            $before
            Unlock-ADAccount -Identity $user -Server $Server -ErrorAction Stop
            $user = Resolve-ITADUser -Identity ([string]$user.SamAccountName) -Server $Server
            ConvertTo-ITUserAccount -User $user -Server $Server -State 'After'
        }
        catch {
            Write-Error -Message "${Identity}: $($_.Exception.Message)" -Exception $_.Exception -TargetObject $Identity
        }
    }
}
