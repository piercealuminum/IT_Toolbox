function Invoke-ITHubTool {
    <#
    .SYNOPSIS
    The one command ITHub runs: checks a tool request, runs the matching ITToolkit command and returns the results as a JSON envelope.

    .DESCRIPTION
    ITHub's Tools page calls this through the locked-down ITToolkit endpoint (JEA). It is the
    only command that endpoint exposes besides Get-ITHubToolCatalog.

    The request is a JSON object:
        {"tool": "device-health", "parameters": {"computerName": "PC0142"}, "requestedBy": "Jordan Lee"}
    The tool must be in the catalog (Get-ITHubToolCatalog) and every parameter must meet its
    rule; otherwise nothing runs and the envelope's status is "failed" with the reasons.

    The envelope always comes back as one JSON string, also on failure:
        schemaVersion, toolkitVersion, tool, parameters, requestedBy, startedAt, finishedAt,
        status (completed, completed_with_errors or failed), summary (check-style tools),
        results, warnings, errors, ticketNote.
    Result rows carry their ITToolkit type in "type" and their properties in camelCase. Dates
    are UTC ISO 8601 text.

    For user-status, the Entra ID part uses app-only Microsoft Graph access when the ITHub
    settings name a certificate (see Get-ITToolkitSetting).

    .PARAMETER RequestJson
    The request as a JSON string.

    .EXAMPLE
    Invoke-ITHubTool -RequestJson '{"tool":"device-health","parameters":{"computerName":"PC0142"}}'

    .EXAMPLE
    Invoke-ITHubTool -RequestJson '{"tool":"port-test","parameters":{"host":"fs01","preset":"SMB"}}' | ConvertFrom-Json

    Runs a port test and reads the envelope as an object.

    .OUTPUTS
    System.String (JSON)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string]$RequestJson
    )

    $started = [DateTime]::UtcNow
    $module = $ExecutionContext.SessionState.Module
    $envelope = [ordered]@{
        schemaVersion  = $script:ITHubSchemaVersion
        toolkitVersion = $module.Version.ToString()
        tool           = $null
        parameters     = [ordered]@{}
        requestedBy    = $null
        startedAt      = ConvertTo-ITHubValue -Value $started
        finishedAt     = $null
        status         = 'failed'
        results        = @()
        warnings       = @()
        errors         = @()
        ticketNote     = $null
    }
    $warnings = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $objects = @()

    try {
        $request = Resolve-ITHubRequest -RequestJson $RequestJson
        $tool = $request.Tool
        $envelope.tool = $tool.Id
        $envelope.parameters = $request.Parameters
        $envelope.requestedBy = $request.RequestedBy

        if ($tool.NeedsGraph) {
            $graphProblem = Connect-ITHubGraph
            if ($graphProblem) { $warnings.Add($graphProblem) }
        }

        $bound = $request.Bound
        $commandWarnings = @()
        $commandErrors = @()
        try {
            $objects = @(& $tool.Command @bound -ErrorAction SilentlyContinue -ErrorVariable commandErrors -WarningAction SilentlyContinue -WarningVariable commandWarnings)
        }
        catch {
            $errors.Add($_.Exception.Message)
        }
        foreach ($item in @($commandWarnings)) { if ($item) { $warnings.Add([string]$item.Message) } }
        # -ErrorVariable also collects errors that the command (or a collector) caught and
        # handled: the raw WinRM failure behind "PC0142: Could not connect ...", or a refused
        # port that is itself a result. Report only the command's own errors, which say which
        # computer or user failed. Only when there are no results and no own errors is
        # anything else shown, so a failure is never silent.
        $records = @($commandErrors | Where-Object { $_ })
        $own = @($records | Where-Object { $_.InvocationInfo -and $_.InvocationInfo.MyCommand -and $_.InvocationInfo.MyCommand.Name -eq $tool.Command })
        if ($own.Count -or @($objects | Where-Object { $null -ne $_ }).Count) { $records = $own }
        else { $records = @($records | Select-Object -Last 1) }
        foreach ($item in $records) {
            if (-not $item) { continue }
            $message = [string]$item
            if (-not $message -and $item.Exception) { $message = $item.Exception.Message }
            if ($message -and $errors -notcontains $message) { $errors.Add($message) }
        }

        $objects = @($objects | Where-Object { $null -ne $_ })
        $maximum = [int](Get-ITSettings).ITHub.MaxResults
        if ($maximum -gt 0 -and $objects.Count -gt $maximum) {
            $warnings.Add("Showing the first $maximum of $($objects.Count) results.")
            $objects = @($objects | Select-Object -First $maximum)
        }

        $envelope.results = @($objects | ForEach-Object { ConvertTo-ITHubResult -InputObject $_ })
        $checks = @($objects | Where-Object { $_.PSObject.TypeNames[0] -in @('ITToolkit.CheckResult', 'ITToolkit.UserCheck') })
        if ($checks.Count -and $checks.Count -eq $objects.Count) {
            $envelope.summary = [ordered]@{
                fail = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count
                warn = @($checks | Where-Object { $_.Status -eq 'Warn' }).Count
                ok   = @($checks | Where-Object { $_.Status -eq 'OK' }).Count
                info = @($checks | Where-Object { $_.Status -eq 'Info' }).Count
            }
        }
        if ($objects.Count -and $tool.Id -ne 'password-reset') {
            $noteParameters = @{ Width = 200 }
            if ($request.RequestedBy) { $noteParameters.CollectedBy = $request.RequestedBy }
            $envelope.ticketNote = $objects | ConvertTo-ITTicketNote @noteParameters
        }

        if ($errors.Count -and $objects.Count) { $envelope.status = 'completed_with_errors' }
        elseif ($errors.Count) { $envelope.status = 'failed' }
        else { $envelope.status = 'completed' }
    }
    catch {
        $errors.Add($_.Exception.Message)
        $envelope.status = 'failed'
        # Echo the tool that was asked for, so ITHub can match the failure to its request.
        try {
            $raw = ConvertFrom-Json -InputObject $RequestJson -ErrorAction Stop
            if ($raw.tool -is [string] -and $raw.tool.Length -le 64) { $envelope.tool = $raw.tool }
        }
        catch { $null = $_ }
    }

    $envelope.warnings = @($warnings)
    $envelope.errors = @($errors)
    $envelope.finishedAt = ConvertTo-ITHubValue -Value ([DateTime]::UtcNow)
    ConvertTo-Json -InputObject $envelope -Depth 10 -Compress
}
