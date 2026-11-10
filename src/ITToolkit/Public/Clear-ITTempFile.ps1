function Clear-ITTempFile {
    <#
    .SYNOPSIS
    Frees disk space by deleting old files from the Windows and user temp folders. Supports -WhatIf.

    .DESCRIPTION
    Deletes files that have not changed for OlderThanDays days (default 7, from the
    TempCleanup.OlderThanDays setting) from:
      C:\Windows\Temp
      C:\Users\<each profile>\AppData\Local\Temp
    then removes folders left empty. Files in use are skipped and counted under InUse.
    Links and junctions are never followed, and a temp folder that is itself a link (or sits
    under one) is skipped with a warning, so nothing outside the temp folders is touched.
    Files extracted from archives keep old timestamps, so a file must be both created and
    last changed before the cutoff to be removed.

    Run with -WhatIf first to see how much would be freed in each folder. With -Confirm you
    are asked before each folder.

    This is the only ITToolkit command that changes a computer.

    .PARAMETER OlderThanDays
    Only delete files not changed for at least this many days.

    .PARAMETER ComputerName
    Computers to clean. Defaults to this computer. Accepts pipeline input.

    .PARAMETER Credential
    Credential for remote computers. Not used for this computer.

    .EXAMPLE
    Clear-ITTempFile -ComputerName PC0142 -WhatIf

    Shows how many files and how much space each temp folder would free, without deleting anything.

    .EXAMPLE
    Clear-ITTempFile -ComputerName PC0142

    .EXAMPLE
    Clear-ITTempFile -OlderThanDays 30 -Confirm

    Asks before cleaning each temp folder on this computer.

    .OUTPUTS
    ITToolkit.TempCleanup
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [ValidateRange(1, 3650)]
        [int]$OlderThanDays,

        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('CN', 'DNSHostName')]
        [string[]]$ComputerName = [Environment]::MachineName,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    begin {
        if (-not $PSBoundParameters.ContainsKey('OlderThanDays')) {
            $OlderThanDays = (Get-ITSettings).TempCleanup.OlderThanDays
        }
    }

    process {
        foreach ($computer in $ComputerName) {
            $target = $null
            try {
                $target = Open-ITTarget -ComputerName $computer -Credential $Credential

                # Pass 1 measures; pass 2 deletes only in the folders approved here, so -WhatIf
                # and -Confirm work the same for remote computers.
                $scan = @(Invoke-ITCollector -Name 'TempFiles' -Target $target -ArgumentList @($null, $OlderThanDays, $false))
                $approved = New-Object System.Collections.Generic.List[string]
                foreach ($folder in $scan) {
                    if ($folder.Skipped) {
                        Write-Warning "$($target.ComputerName): skipped $($folder.Path): $($folder.Skipped)"
                        continue
                    }
                    if ($folder.Files -lt 1) {
                        Write-Verbose "$($target.ComputerName): nothing older than $OlderThanDays days in $($folder.Path)"
                        continue
                    }
                    $action = 'Delete {0} file(s), {1}, not changed for {2} days' -f $folder.Files, (Format-ITBytes $folder.Bytes), $OlderThanDays
                    if ($PSCmdlet.ShouldProcess("$($target.ComputerName): $($folder.Path)", $action)) {
                        $approved.Add($folder.Path)
                    }
                }
                if (-not $approved.Count) { continue }

                $cleaned = @(Invoke-ITCollector -Name 'TempFiles' -Target $target -ArgumentList @($approved.ToArray(), $OlderThanDays, $true))
                foreach ($folder in $cleaned) {
                    if ($folder.Skipped) {
                        Write-Warning "$($target.ComputerName): skipped $($folder.Path): $($folder.Skipped)"
                        continue
                    }
                    [pscustomobject]@{
                        PSTypeName     = 'ITToolkit.TempCleanup'
                        ComputerName   = $target.ComputerName
                        Path           = $folder.Path
                        FilesRemoved   = $folder.Files
                        Freed          = Format-ITBytes $folder.Bytes
                        FreedBytes     = [int64]$folder.Bytes
                        Failed         = $folder.Failed
                        FoldersRemoved = $folder.FoldersRemoved
                    }
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
