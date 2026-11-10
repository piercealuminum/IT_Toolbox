function Test-ITNetwork {
    <#
    .SYNOPSIS
    Network triage from the computer's point of view: adapters, gateway, DNS, Microsoft 365 reachability, proxy and time sync.

    .DESCRIPTION
    Runs on the target computer and checks, in order:
      - connected adapters, their IP address, gateway and DNS servers (flags self-assigned
        169.254.x.x addresses and VPN adapters)
      - a ping to each default gateway
      - DNS lookups for the names in the Network.DnsNames and Network.InternalDnsNames settings
      - TCP connections to the host:port pairs in the Network.TcpTargets setting
      - WinHTTP proxy (and, on this computer, your own proxy setting)
      - Windows Time sync status, and for remote computers the clock difference from yours

    Add your own internal names (a domain controller, file server or ITHub) to the
    InternalDnsNames setting so every run checks them; see Get-ITToolkitSetting.

    Read-only: it changes nothing on the computer.

    .PARAMETER ComputerName
    Computers to test from. Defaults to this computer. Accepts pipeline input.

    .PARAMETER DnsName
    Extra names to resolve on this run, in addition to the settings.

    .PARAMETER TcpTarget
    Extra host:port pairs to connect to on this run, for example 'fs01:445'.

    .PARAMETER TimeoutMs
    How long to wait for each TCP connection. Defaults to the Network.TimeoutMs setting.

    .PARAMETER Credential
    Credential for remote computers. Not used for this computer.

    .EXAMPLE
    Test-ITNetwork

    .EXAMPLE
    Test-ITNetwork -ComputerName PC0142 -TcpTarget 'fs01:445', 'printsrv:9100' | ConvertTo-ITTicketNote -Clipboard

    Tests PC0142's network, including the file and print servers, and copies the result for the ticket.

    .EXAMPLE
    Test-ITNetwork | Where-Object Status -in 'Fail', 'Warn'

    Only the problems.

    .OUTPUTS
    ITToolkit.CheckResult
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('CN', 'DNSHostName')]
        [string[]]$ComputerName = [Environment]::MachineName,

        [string[]]$DnsName = @(),

        [string[]]$TcpTarget = @(),

        [ValidateRange(100, 60000)]
        [int]$TimeoutMs,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    begin {
        $settings = (Get-ITSettings).Network
        if (-not $PSBoundParameters.ContainsKey('TimeoutMs')) { $TimeoutMs = $settings.TimeoutMs }
        $names = [string[]]@(@($settings.DnsNames) + @($settings.InternalDnsNames) + $DnsName | Where-Object { $_ } | Select-Object -Unique)
        $tcpList = [string[]]@(@($settings.TcpTargets) + $TcpTarget | Where-Object { $_ } | Select-Object -Unique | ForEach-Object {
                $parsed = ConvertTo-ITTcpTarget -Target $_
                '{0}|{1}' -f $parsed.Host, $parsed.Port
            })
    }

    process {
        foreach ($computer in $ComputerName) {
            $target = $null
            try {
                $target = Open-ITTarget -ComputerName $computer -Credential $Credential

                $skew = $null
                if (-not $target.IsLocal) {
                    $before = [DateTime]::UtcNow
                    $remoteUtc = ([datetime](Invoke-ITCollector -Name 'Clock' -Target $target)).ToUniversalTime()
                    $after = [DateTime]::UtcNow
                    $midpoint = $before.AddTicks([long](($after - $before).Ticks / 2))
                    $skew = ($remoteUtc - $midpoint).TotalSeconds
                }

                $config = Invoke-ITCollector -Name 'NetworkConfig' -Target $target -ArgumentList @(, $names)
                foreach ($message in @($config.Errors)) {
                    if ($message) { Write-Verbose "$($target.ComputerName): $message" }
                }
                $tcp = @()
                if ($tcpList.Count) {
                    $tcp = @(Invoke-ITCollector -Name 'TcpTest' -Target $target -ArgumentList @($tcpList, $TimeoutMs))
                }
                ConvertTo-ITNetworkCheck -ComputerName $target.ComputerName -Config $config -Tcp $tcp -Settings $settings -IsRemote (-not $target.IsLocal) -ClockSkewSeconds $skew
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
