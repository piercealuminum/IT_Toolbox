function Get-ITDeviceHealth {
    <#
    .SYNOPSIS
    Health check on one screen: uptime, pending reboot, disks, BitLocker, antivirus, firewall, updates, Secure Boot and device join.

    .DESCRIPTION
    Collects the facts a tech usually checks first on a ticket and rates each one OK, Warn, Fail
    or Info. Thresholds (disk space, uptime, signature and patch age) come from the toolkit
    settings; see Get-ITToolkitSetting.

    Run it from an elevated PowerShell window to include BitLocker. Remote
    computers are reached with PowerShell remoting (WinRM), which needs administrator rights
    on the target.

    Read-only: it changes nothing on the computer.

    .PARAMETER ComputerName
    Computers to check. Defaults to this computer. Accepts pipeline input, including
    Get-ADComputer output (DNSHostName).

    .PARAMETER Credential
    Credential for remote computers. Not used for this computer.

    .PARAMETER Summary
    Returns one line per computer (fail and warn counts plus the problems) instead of every
    check. Use it to sweep many computers; unreachable computers show Reachable = False.

    .EXAMPLE
    Get-ITDeviceHealth

    Checks this computer.

    .EXAMPLE
    Get-ITDeviceHealth -ComputerName PC0142 | ConvertTo-ITTicketNote -Clipboard

    Checks PC0142 and copies a note for the ticket to the clipboard.

    .EXAMPLE
    Get-Content .\lab-pcs.txt | Get-ITDeviceHealth -Summary | Where-Object Fail -gt 0

    Checks every computer in a text file and shows only those with a failed check.

    .OUTPUTS
    ITToolkit.CheckResult, or ITToolkit.HealthSummary with -Summary.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('CN', 'DNSHostName')]
        [string[]]$ComputerName = [Environment]::MachineName,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty,

        [switch]$Summary
    )

    begin {
        $settings = (Get-ITSettings).Health
    }

    process {
        foreach ($computer in $ComputerName) {
            $target = $null
            try {
                $target = Open-ITTarget -ComputerName $computer -Credential $Credential
                $health = Invoke-ITCollector -Name 'DeviceHealth' -Target $target
                $reboot = Invoke-ITCollector -Name 'PendingReboot' -Target $target
                foreach ($message in @($health.Errors) + @($reboot.Errors)) {
                    if ($message) { Write-Verbose "$($target.ComputerName): $message" }
                }
                $checks = @(ConvertTo-ITHealthCheck -ComputerName $target.ComputerName -Health $health -Reboot $reboot -Settings $settings)
                if ($Summary) {
                    ConvertTo-ITHealthSummary -ComputerName $target.ComputerName -Checks $checks
                }
                else {
                    $checks
                }
            }
            catch {
                if ($Summary) {
                    ConvertTo-ITHealthSummary -ComputerName $computer -ErrorMessage $_.Exception.Message
                }
                else {
                    Write-Error -Message "${computer}: $($_.Exception.Message)" -Exception $_.Exception -TargetObject $computer
                }
            }
            finally {
                Close-ITTarget -Target $target
            }
        }
    }
}
