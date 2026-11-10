function Get-ITEventSummary {
    <#
    .SYNOPSIS
    Summarizes recent errors and notable events (crashes, unexpected restarts, disk and hardware errors) from the System and Application logs.

    .DESCRIPTION
    Reads critical and error events from the System and Application logs, plus events that
    explain common tickets even when they are not errors:
      41, 6008      unexpected restarts and shutdowns
      1074          who or what restarted the computer
      WHEA-Logger   hardware errors
      disk          bad blocks and retried disk I/O
    Events are grouped by source and Id with a count and the first and last time seen.
    Known events get a plain-language Note. Events with a Note are listed first, then the
    most frequent.

    Read-only: it changes nothing on the computer.

    .PARAMETER Hours
    How far back to look. Defaults to the EventSummary.Hours setting (24).

    .PARAMETER MaxEvents
    Most events read per query. Defaults to the EventSummary.MaxEvents setting (500).

    .PARAMETER Detailed
    Returns each event instead of the grouped summary, newest first.

    .PARAMETER ComputerName
    Computers to check. Defaults to this computer. Accepts pipeline input.

    .PARAMETER Credential
    Credential for remote computers. Not used for this computer.

    .EXAMPLE
    Get-ITEventSummary -ComputerName PC0142

    What has gone wrong on PC0142 in the last 24 hours.

    .EXAMPLE
    Get-ITEventSummary -ComputerName PC0142 -Hours 168 | Where-Object Note

    Only the explained events from the last week: crashes, unexpected restarts, disk and hardware errors.

    .EXAMPLE
    Get-ITEventSummary -Hours 4 -Detailed | Where-Object Source -eq 'Application Error' | Format-List

    Full messages for application crashes in the last 4 hours.

    .OUTPUTS
    ITToolkit.EventGroup, or ITToolkit.Event with -Detailed.
    #>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 8760)]
        [int]$Hours,

        [ValidateRange(10, 100000)]
        [int]$MaxEvents,

        [switch]$Detailed,

        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('CN', 'DNSHostName')]
        [string[]]$ComputerName = [Environment]::MachineName,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    begin {
        $settings = (Get-ITSettings).EventSummary
        if (-not $PSBoundParameters.ContainsKey('Hours')) { $Hours = $settings.Hours }
        if (-not $PSBoundParameters.ContainsKey('MaxEvents')) { $MaxEvents = $settings.MaxEvents }
    }

    process {
        foreach ($computer in $ComputerName) {
            $target = $null
            try {
                $target = Open-ITTarget -ComputerName $computer -Credential $Credential
                $raw = Invoke-ITCollector -Name 'EventLog' -Target $target -ArgumentList @($Hours, $MaxEvents)
                foreach ($message in @($raw.Errors)) {
                    if ($message) { Write-Warning "$($target.ComputerName): could not read $message" }
                }
                $events = @($raw.Events | Where-Object { $_ })
                Write-Verbose "$($target.ComputerName): $($events.Count) events in the last $Hours hours"
                if ($Detailed) {
                    $events |
                        Sort-Object -Property TimeCreated -Descending |
                        ForEach-Object { ConvertTo-ITEventRecord -ComputerName $target.ComputerName -Record $_ }
                }
                else {
                    ConvertTo-ITEventGroup -ComputerName $target.ComputerName -Events $events
                }
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
