function Get-ITInstalledSoftware {
    <#
    .SYNOPSIS
    Lists installed programs (as in Settings > Apps), including per-user installs, with version and uninstall command.

    .DESCRIPTION
    Reads the Windows uninstall registry keys: 64-bit and 32-bit machine-wide programs, plus
    per-user programs (Teams, Zoom and some browsers install this way) for every user whose
    profile is loaded. Hidden components and updates to other products are left out.

    It does not use Win32_Product, which is slow and can start a repair of every MSI
    package on the computer.

    Every result has UninstallString and QuietUninstallString; use Select-Object * to see
    them. Read-only: it changes nothing on the computer.

    .PARAMETER Name
    Program name to look for. Wildcards allowed. Defaults to every program.

    .PARAMETER ComputerName
    Computers to check. Defaults to this computer. Accepts pipeline input.

    .PARAMETER Credential
    Credential for remote computers. Not used for this computer.

    .EXAMPLE
    Get-ITInstalledSoftware -Name '*Chrome*' -ComputerName PC0142

    .EXAMPLE
    Get-Content .\pcs.txt | Get-ITInstalledSoftware -Name 'Adobe Acrobat*' | Sort-Object Version

    Compares the Acrobat version across a list of computers.

    .EXAMPLE
    Get-ITInstalledSoftware -Name '*Zoom*' | Select-Object Name, Version, Scope, QuietUninstallString

    Shows how to remove Zoom silently.

    .OUTPUTS
    ITToolkit.Software
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string]$Name = '*',

        [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
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
                $entries = @(Invoke-ITCollector -Name 'InstalledSoftware' -Target $target -ArgumentList @($Name))
                $entries |
                    Sort-Object -Property DisplayName, DisplayVersion |
                    ForEach-Object { ConvertTo-ITSoftware -ComputerName $target.ComputerName -Entry $_ }
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
