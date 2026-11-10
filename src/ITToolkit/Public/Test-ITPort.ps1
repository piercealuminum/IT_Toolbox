function Test-ITPort {
    <#
    .SYNOPSIS
    Fast TCP port test against one or more hosts, from this computer or from another one.

    .DESCRIPTION
    Tries a TCP connection to each host and port and reports Open, the connect time and,
    when it fails, why: refused (host up, nothing listening), no answer (firewall or host
    off) or DNS failure. Faster than Test-NetConnection, and it can test several hosts and
    ports at once.

    -Preset tests a common set of ports, for example every port a domain controller needs.
    -Source runs the test from another computer through PowerShell remoting, to answer
    "can PC0142 reach the file server?" without visiting the user.

    .PARAMETER ComputerName
    Hosts to test. Names or IP addresses. Accepts pipeline input.

    .PARAMETER Port
    TCP ports to test.

    .PARAMETER Preset
    A named set of ports instead of -Port: DomainController, Email, Printer, RDP, SMB, SQL, SSH, Web, WinRM.

    .PARAMETER TimeoutMs
    How long to wait for each connection. Default 3000 (Windows takes about 2 seconds to report
    a refused port, so shorter timeouts report "no answer" instead of "refused").

    .PARAMETER Source
    Run the test from this computer instead of yours (needs PowerShell remoting to it).

    .PARAMETER Credential
    Credential for the -Source computer.

    .EXAMPLE
    Test-ITPort fs01 445

    .EXAMPLE
    Test-ITPort dc01, dc02 -Preset DomainController

    Checks every port a client needs on both domain controllers.

    .EXAMPLE
    Test-ITPort printsrv -Preset Printer -Source PC0142

    Tests from the user's computer whether it can reach the print server.

    .OUTPUTS
    ITToolkit.PortTest
    #>
    [CmdletBinding(DefaultParameterSetName = 'Port')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('CN', 'DNSHostName', 'HostName')]
        [string[]]$ComputerName,

        [Parameter(Mandatory, Position = 1, ParameterSetName = 'Port')]
        [ValidateRange(1, 65535)]
        [int[]]$Port,

        [Parameter(Mandatory, ParameterSetName = 'Preset')]
        [ValidateSet('DomainController', 'Email', 'Printer', 'RDP', 'SMB', 'SQL', 'SSH', 'Web', 'WinRM')]
        [string]$Preset,

        [ValidateRange(100, 60000)]
        [int]$TimeoutMs = 3000,

        [string]$Source = [Environment]::MachineName,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    begin {
        if ($PSCmdlet.ParameterSetName -eq 'Preset') { $ports = $script:ITPortPresets[$Preset] }
        else { $ports = $Port }
    }

    process {
        $list = [string[]]@(foreach ($name in $ComputerName) {
                foreach ($number in $ports) { '{0}|{1}' -f $name.Trim(), $number }
            })
        # Opened and closed for each batch, inside try/finally, so the remoting session is
        # closed even when the pipeline is stopped early (Ctrl+C, Select-Object -First).
        $target = $null
        try {
            $target = Open-ITTarget -ComputerName $Source -Credential $Credential
            foreach ($result in @(Invoke-ITCollector -Name 'TcpTest' -Target $target -ArgumentList @($list, $TimeoutMs))) {
                [pscustomobject]@{
                    PSTypeName   = 'ITToolkit.PortTest'
                    Source       = $target.ComputerName
                    ComputerName = $result.Host
                    Port         = $result.Port
                    Service      = $script:ITPortNames[[int]$result.Port]
                    Open         = $result.Open
                    LatencyMs    = $result.LatencyMs
                    Detail       = $result.Detail
                }
            }
        }
        catch {
            Write-Error -Message "${Source}: $($_.Exception.Message)" -Exception $_.Exception -TargetObject $ComputerName
        }
        finally {
            Close-ITTarget -Target $target
        }
    }
}
