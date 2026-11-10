<#
.SYNOPSIS
The client script ITHub starts for each Tools request: reads the request on standard input, calls the ITToolkit endpoint, writes the JSON envelope on standard output.

.DESCRIPTION
ITHub runs this as its own service account, one process per request:

    powershell.exe -NoProfile -NonInteractive -File "C:\Program Files\ITToolkit\Invoke-ITHubRequest.ps1"

Standard input: one JSON object (UTF-8).
  {"action": "catalog"}                       returns the tool catalog
  {"tool": "...", "parameters": {...}, ...}   runs a tool (see Invoke-ITHubTool)

Standard output: exactly one JSON document (UTF-8), also when something fails: then its
"status" is "failed" and "errors" says why. The exit code is 0 whenever a document was written.

The script connects to the JEA endpoint (default "ITToolkit" on this computer) and sends the
command into that session directly, so the endpoint's restrictions and its gMSA apply. The
service account running this script needs no rights of its own beyond connecting to the
endpoint.

Install-ITHubEndpoint.ps1 copies this script to C:\Program Files\ITToolkit, a path that
does not change between ITToolkit versions and that only administrators can change.

.PARAMETER ConfigurationName
The JEA endpoint's name. Default ITToolkit.

.PARAMETER ComputerName
The computer that hosts the endpoint. Default localhost.

.PARAMETER RequestJson
The request, instead of reading standard input. For testing.

.PARAMETER Local
Development and tests only: runs ITToolkit inside this process instead of through the
endpoint, with this account's own rights and none of the endpoint's restrictions. Never use
it on the ITHub server.

.EXAMPLE
'{"action":"catalog"}' | powershell.exe -NoProfile -File .\Invoke-ITHubRequest.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigurationName = 'ITToolkit',
    [string]$ComputerName = 'localhost',
    [string]$RequestJson,
    [switch]$Local
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-Document([string]$Json) {
    # Raw UTF-8 bytes, so the console code page of Windows PowerShell cannot change them.
    $stream = [Console]::OpenStandardOutput()
    $bytes = $utf8.GetBytes($Json)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
}

function New-FailureDocument([string]$Message, $Tool) {
    $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $document = [ordered]@{
        schemaVersion  = 1
        toolkitVersion = $null
        tool           = $Tool
        parameters     = @{}
        requestedBy    = $null
        startedAt      = $now
        finishedAt     = $now
        status         = 'failed'
        results        = @()
        warnings       = @()
        errors         = @($Message)
        ticketNote     = $null
    }
    ConvertTo-Json -InputObject $document -Depth 4 -Compress
}

$tool = $null
try {
    if (-not $PSBoundParameters.ContainsKey('RequestJson')) {
        $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), $utf8)
        $RequestJson = $reader.ReadToEnd()
    }

    $wantsCatalog = $false
    try {
        $parsed = ConvertFrom-Json -InputObject $RequestJson -ErrorAction Stop
        if ($parsed.action -eq 'catalog') { $wantsCatalog = $true }
        if ($parsed.tool -is [string] -and $parsed.tool.Length -le 64) { $tool = $parsed.tool }
    }
    catch { $wantsCatalog = $false }   # Invoke-ITHubTool reports invalid JSON in its own envelope

    $commandName = 'Invoke-ITHubTool'
    if ($wantsCatalog) { $commandName = 'Get-ITHubToolCatalog' }

    if ($Local) {
        $manifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'ITToolkit.psd1'
        if (Test-Path -LiteralPath $manifest) { Import-Module $manifest -Force }
        else { Import-Module ITToolkit -Force }
        if ($wantsCatalog) { $output = @(Get-ITHubToolCatalog) }
        else { $output = @(Invoke-ITHubTool -RequestJson $RequestJson) }
    }
    else {
        $session = New-PSSession -ComputerName $ComputerName -ConfigurationName $ConfigurationName
        $shell = $null
        try {
            # Send the command itself into the session (not a script block), which the
            # endpoint's no-language mode allows, and which needs no local proxy module.
            $shell = [System.Management.Automation.PowerShell]::Create()
            $shell.Runspace = $session.Runspace
            $null = $shell.AddCommand($commandName)
            if (-not $wantsCatalog) { $null = $shell.AddParameter('RequestJson', $RequestJson) }
            $output = @($shell.Invoke())
            if (-not $output.Count -and $shell.Streams.Error.Count) {
                throw $shell.Streams.Error[0].ToString()
            }
        }
        finally {
            if ($shell) { $shell.Dispose() }
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }

    $text = (@($output | ForEach-Object { [string]$_ }) -join '')
    if (-not $text) { throw 'The endpoint returned nothing.' }
    Write-Document $text
}
catch {
    Write-Document (New-FailureDocument -Message ("ITHub client script: " + $_.Exception.Message) -Tool $tool)
}
exit 0
