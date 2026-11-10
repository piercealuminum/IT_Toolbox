function ConvertTo-ITTicketNote {
    <#
    .SYNOPSIS
    Turns the output of any ITToolkit command into a plain-text note to paste into an ITHub ticket.

    .DESCRIPTION
    Pipe ITToolkit results into this command to get one block of plain text with a title,
    when and by whom it was collected, and the results as a table. For health and network
    checks it adds a one-line result count and lists the problems first under
    "Needs attention".

    Use -Clipboard to copy the note as well, ready to paste.

    .PARAMETER InputObject
    Results from an ITToolkit command (or any objects). Accepts pipeline input.

    .PARAMETER Title
    Title for the note. Defaults to a title based on the kind of results.

    .PARAMETER Clipboard
    Also copies the note to the clipboard.

    .PARAMETER Width
    Line width for tables. Default 160.

    .EXAMPLE
    Get-ITDeviceHealth -ComputerName PC0142 | ConvertTo-ITTicketNote -Clipboard

    .EXAMPLE
    Test-ITPort fs01 445 -Source PC0142 | ConvertTo-ITTicketNote -Title 'PC0142 cannot reach the S: drive'

    .OUTPUTS
    System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        $InputObject,

        [string]$Title,

        [switch]$Clipboard,

        [ValidateRange(80, 1000)]
        [int]$Width = 160
    )

    begin {
        $items = New-Object System.Collections.Generic.List[object]
        $titles = @{
            'ITToolkit.HealthSummary' = 'Device health sweep'
            'ITToolkit.PendingReboot' = 'Pending restart check'
            'ITToolkit.LocalAdmin'    = 'Local administrators'
            'ITToolkit.Software'      = 'Installed software'
            'ITToolkit.EventGroup'    = 'Event log summary'
            'ITToolkit.Event'         = 'Event log entries'
            'ITToolkit.Session'       = 'Signed-in users'
            'ITToolkit.PortTest'      = 'Port test'
            'ITToolkit.TempCleanup'   = 'Temp file cleanup'
        }
    }

    process {
        if ($null -ne $InputObject) { $items.Add($InputObject) }
    }

    end {
        if (-not $items.Count) { return }

        $typeName = $items[0].PSObject.TypeNames[0]
        $isCheck = @($items | Where-Object { $_.PSObject.TypeNames -contains 'ITToolkit.CheckResult' }).Count -eq $items.Count
        if (-not $Title) {
            if ($isCheck) {
                $categories = @($items | ForEach-Object { $_.Category } | Select-Object -Unique)
                $Title = if ($categories.Count -eq 1 -and $categories[0] -eq 'Network') { 'Network test' } else { 'Device health check' }
            }
            elseif ($titles.ContainsKey($typeName)) { $Title = $titles[$typeName] }
            else { $Title = 'Results' }
        }

        $who = '{0}\{1}' -f [Environment]::UserDomainName, [Environment]::UserName
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("== $Title ==")
        $lines.Add(('Collected {0:yyyy-MM-dd HH:mm} by {1} with ITToolkit' -f (Get-Date), $who))

        if ($isCheck) {
            foreach ($group in @($items | Group-Object -Property ComputerName)) {
                $checks = @($group.Group)
                $count = @{}
                foreach ($status in 'Fail', 'Warn', 'OK', 'Info') { $count[$status] = @($checks | Where-Object { $_.Status -eq $status }).Count }
                $lines.Add('')
                $lines.Add(('{0}: {1} fail, {2} warn, {3} OK, {4} info' -f $group.Name, $count.Fail, $count.Warn, $count.OK, $count.Info))
                # Fails first, then warnings, each in check order (Sort-Object is not stable in 5.1).
                $problems = @($checks | Where-Object { $_.Status -eq 'Fail' }) + @($checks | Where-Object { $_.Status -eq 'Warn' })
                if ($problems.Count) {
                    $lines.Add('')
                    $lines.Add('Needs attention:')
                    foreach ($problem in $problems) {
                        $lines.Add(('  [{0}] {1} - {2}' -f $problem.Status.ToUpperInvariant(), $problem.Check, $problem.Detail))
                    }
                }
                $lines.Add('')
                $lines.Add('All checks:')
                $table = $checks | Select-Object -Property Check, Status, Detail | Format-Table -AutoSize -Wrap | Out-String -Width $Width
                $lines.Add($table.Trim([char[]]"`r`n"))
            }
        }
        else {
            $lines.Add('')
            $table = $items | Format-Table -AutoSize -Wrap | Out-String -Width $Width
            $lines.Add($table.Trim([char[]]"`r`n"))
        }

        $note = ($lines -join [Environment]::NewLine).TrimEnd()
        if ($Clipboard) {
            Set-Clipboard -Value $note
            Write-Verbose 'Ticket note copied to the clipboard.'
        }
        $note
    }
}
