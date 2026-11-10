function Get-ITPendingReboot {
    <#
    .SYNOPSIS
    Shows whether a computer needs a restart and why, with its uptime.

    .DESCRIPTION
    Checks the places Windows records a pending restart: Windows servicing (CBS), Windows
    Update, a pending domain join or computer rename, and the Configuration Manager client
    when it is installed.

    Pending file rename operations are reported as a count only (PendingFileRenames). Many
    installers and antivirus products leave them behind, so on their own they are not
    treated as a reason to restart.

    Read-only: it changes nothing on the computer.

    .PARAMETER ComputerName
    Computers to check. Defaults to this computer. Accepts pipeline input.

    .PARAMETER Credential
    Credential for remote computers. Not used for this computer.

    .EXAMPLE
    Get-ITPendingReboot -ComputerName PC0142

    .EXAMPLE
    Get-ADComputer -Filter 'Name -like "FS*"' | Get-ITPendingReboot | Where-Object RebootPending

    Lists file servers that are waiting for a restart.

    .OUTPUTS
    ITToolkit.PendingReboot
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
                $reboot = Invoke-ITCollector -Name 'PendingReboot' -Target $target
                foreach ($message in @($reboot.Errors)) {
                    if ($message) { Write-Verbose "$($target.ComputerName): $message" }
                }
                ConvertTo-ITPendingReboot -ComputerName $target.ComputerName -Reboot $reboot
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
