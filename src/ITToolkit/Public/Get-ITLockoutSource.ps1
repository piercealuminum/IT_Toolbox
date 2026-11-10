function Get-ITLockoutSource {
    <#
    .SYNOPSIS
    Finds which computer keeps locking a user's account, from the lockout events on the PDC emulator.

    .DESCRIPTION
    Reads "account locked out" events (Id 4740) from the Security log of the PDC emulator, which
    records every lockout in the domain, and shows the caller computer for each: the computer
    the bad passwords came from.

    Common causes on the caller computer: a saved password in Credential Manager, a mapped
    drive or scheduled task using an old password, a service running as the user, or a
    disconnected Remote Desktop session (check with Get-ITLoggedOnUser). A blank caller usually
    means a phone, VPN, Outlook on the web or another network service.

    In a hybrid domain, failed Microsoft 365 sign-ins do not lock the AD account (Entra ID
    has its own smart lockout), so only on-premises lockouts appear here.

    Needs PowerShell remoting to the domain controller as an administrator, or as a member of
    both Remote Management Users and Event Log Readers on the domain controllers.

    .PARAMETER Identity
    The account name to look for (as in AD, any case). Without it, every lockout in the time
    window is listed.

    .PARAMETER Hours
    How far back to look. Default 24.

    .PARAMETER Server
    Domain controller to read. Defaults to the PDC emulator.

    .PARAMETER Credential
    Credential for the domain controller.

    .EXAMPLE
    Get-ITLockoutSource jlee

    .EXAMPLE
    Get-ITLockoutSource -Hours 4

    Every lockout in the domain in the last 4 hours.

    .EXAMPLE
    Get-ITLockoutSource jlee | Select-Object -First 1 -ExpandProperty CallerComputer | Get-ITLoggedOnUser

    Checks who is signed in to the computer that caused the most recent lockout.

    .OUTPUTS
    ITToolkit.Lockout
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('SamAccountName', 'UserName')]
        [string]$Identity,

        [ValidateRange(1, 720)]
        [int]$Hours = 24,

        [string]$Server,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    begin {
        if (-not $Server) {
            Assert-ITActiveDirectory
            $Server = Get-ITPdcEmulator
        }
    }

    process {
        $target = $null
        try {
            $target = Open-ITTarget -ComputerName $Server -Credential $Credential
            $raw = Invoke-ITCollector -Name 'LockoutEvents' -Target $target -ArgumentList @($Hours)
            foreach ($message in @($raw.Errors)) {
                if ($message) { Write-Warning "${Server}: $message" }
            }
            # Matched here rather than in the event query, because the query would be case-sensitive.
            $lockouts = @($raw.Events | Where-Object { $_ } | ForEach-Object { ConvertTo-ITLockout -Record $_ })
            if ($Identity) {
                $wanted = $Identity.Trim() -replace '^.*\\', ''
                if ($wanted -match '@') {
                    # Lockout events name the account (sAMAccountName), not the UPN.
                    Assert-ITActiveDirectory
                    $wanted = (Resolve-ITADUser -Identity $wanted -Properties @('SamAccountName')).SamAccountName
                }
                $lockouts = @($lockouts | Where-Object { $_.UserName -eq $wanted })
            }
            if (-not $lockouts.Count) {
                $who = if ($Identity) { " for $Identity" } else { '' }
                Write-Verbose "No lockouts$who on $Server in the last $Hours hours."
            }
            $lockouts | Sort-Object -Property TimeCreated -Descending
        }
        catch {
            Write-Error -Message "${Server}: $($_.Exception.Message)" -Exception $_.Exception -TargetObject $Identity
        }
        finally {
            Close-ITTarget -Target $target
        }
    }
}
