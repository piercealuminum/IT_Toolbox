function Get-ITUserAccount {
    <#
    .SYNOPSIS
    Looks up an Active Directory account and returns its state as plain fields: enabled, locked out, bad passwords, password and account expiry.

    .DESCRIPTION
    The same facts Get-ITUserStatus judges, as one record with a field each, for scripts and
    for ITHub (which confirms the right person by DisplayName before an unlock or reset).
    Get-ITUserStatus is the one to read; this is the one to build on.

    Lockout and bad password data are read from the PDC emulator by default, which has the
    most current values. Needs the ActiveDirectory module (RSAT). Read-only.

    .PARAMETER Identity
    The user: account name, UPN or email address, distinguished name or SID. Accepts
    pipeline input, including Get-ADUser output.

    .PARAMETER Server
    Domain controller to read from. Defaults to the PDC emulator.

    .EXAMPLE
    Get-ITUserAccount jlee

    .EXAMPLE
    Get-ADGroupMember 'Sales' | Get-ITUserAccount | Where-Object LockedOut

    Lists the locked-out members of a group.

    .EXAMPLE
    Get-ITUserAccount jordan.lee@example.com | Select-Object DisplayName, PasswordExpires

    .OUTPUTS
    ITToolkit.UserAccount
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('SamAccountName', 'UserPrincipalName', 'UserName')]
        [string[]]$Identity,

        [string]$Server
    )

    begin {
        Assert-ITActiveDirectory
        if (-not $Server) { $Server = Get-ITPdcEmulator }
    }

    process {
        foreach ($name in $Identity) {
            try {
                $user = Resolve-ITADUser -Identity $name -Server $Server
                ConvertTo-ITUserAccount -User $user -Server $Server -State 'Current'
            }
            catch {
                Write-Error -Message "${name}: $($_.Exception.Message)" -Exception $_.Exception -TargetObject $name
            }
        }
    }
}
