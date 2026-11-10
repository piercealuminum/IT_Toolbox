function Get-ITLoggedOnUser {
    <#
    .SYNOPSIS
    Shows who is signed in to a computer (console and Remote Desktop), including disconnected sessions and idle time.

    .DESCRIPTION
    Wraps quser.exe and returns its sessions as objects. Use it before restarting a computer
    or a Remote Desktop server, or to find which server a user left a disconnected session on.

    Read-only: it signs nobody out. To sign out a session, run: logoff <Id> /server:<computer>

    .PARAMETER ComputerName
    Computers to check. Defaults to this computer. Accepts pipeline input.

    .PARAMETER Credential
    Credential for remote computers. Not used for this computer.

    .EXAMPLE
    Get-ITLoggedOnUser -ComputerName PC0142

    .EXAMPLE
    'RDS01', 'RDS02', 'RDS03' | Get-ITLoggedOnUser | Where-Object UserName -eq 'jsmith'

    Finds the Remote Desktop server where jsmith has a session.

    .EXAMPLE
    Get-ITLoggedOnUser -ComputerName RDS01 | Where-Object State -eq 'Disconnected'

    .OUTPUTS
    ITToolkit.Session
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('CN', 'DNSHostName')]
        [string[]]$ComputerName = [Environment]::MachineName,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    process {
        foreach ($computer in $ComputerName) {
            $target = $null
            try {
                $target = Open-ITTarget -ComputerName $computer -Credential $Credential
                $raw = Invoke-ITCollector -Name 'LoggedOnUser' -Target $target
                if ($raw.Error) { throw $raw.Error }
                $sessions = @(ConvertFrom-ITQuser -Lines $raw.Lines -ComputerName $target.ComputerName)
                if (-not $sessions.Count) { Write-Verbose "$($target.ComputerName): nobody is signed in" }
                $sessions
            }
            catch {
                Write-Error -Message "${computer}: $($_.Exception.Message)" -Exception $_.Exception -TargetObject $computer
            }
            finally {
                Close-ITTarget -Target $target
            }
        }
    }
}
