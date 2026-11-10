<#
.SYNOPSIS
Registers or updates the ITToolkit JEA endpoint that ITHub calls, and puts the client script where ITHub runs it.

.DESCRIPTION
Run on the ITHub server, in an elevated Windows PowerShell 5.1 window, after installing
ITToolkit for all users (Install-ITToolkit.ps1). It:

  1. checks ITToolkit is installed for all users with its RoleCapabilities\ITHubTools.psrc
  2. creates the transcript folder, readable and writable by administrators, SYSTEM and the gMSA only
  3. writes the session configuration (C:\ProgramData\ITToolkit\<Name>.pssc):
     restricted session, runs as the gMSA, only the ITHub account may connect, and only to
     the ITHubTools role (Invoke-ITHubTool and Get-ITHubToolCatalog), every call transcribed
  4. registers it as the "<Name>" endpoint (this restarts WinRM, dropping open sessions)
  5. copies Invoke-ITHubRequest.ps1 to C:\Program Files\ITToolkit, the fixed path ITHub runs

Run it again after each ITToolkit update, so the client script copy stays current.

Before the first run: create the gMSA, allow this server to use it
(Install-ADServiceAccount), and give it its rights (see the ITHub Tools spec).

.PARAMETER ITHubAccount
The account ITHub runs as, for example CORP\svc-ithub. Only it may connect.

.PARAMETER GmsaAccount
The group managed service account the endpoint runs as, for example CORP\svc-ittoolkit$.

.PARAMETER RunAsVirtualAccount
Labs and automated tests only: runs the endpoint as a local virtual account instead of a
gMSA. It is a local administrator and cannot reach other computers.

.PARAMETER Name
The endpoint name. Default ITToolkit.

.PARAMETER TranscriptDirectory
Where JEA writes a transcript of every call. Default C:\ProgramData\ITToolkit\Transcripts.

.EXAMPLE
.\Install-ITHubEndpoint.ps1 -ITHubAccount CORP\svc-ithub -GmsaAccount 'CORP\svc-ittoolkit$'
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Gmsa')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[^\\]+\\[^\\]+$')]
    [string]$ITHubAccount,

    [Parameter(Mandatory, ParameterSetName = 'Gmsa')]
    [ValidatePattern('^[^\\]+\\[^\\]+$')]
    [string]$GmsaAccount,

    [Parameter(Mandatory, ParameterSetName = 'Virtual')]
    [switch]$RunAsVirtualAccount,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Name = 'ITToolkit',

    [string]$TranscriptDirectory = (Join-Path $env:ProgramData 'ITToolkit\Transcripts')
)

$ErrorActionPreference = 'Stop'

if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'The endpoint runs on Windows only.' }
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Run this from Windows PowerShell 5.1 (powershell.exe), so the endpoint uses Windows PowerShell like every target computer.'
}
$principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this from an elevated PowerShell window (Run as administrator).'
}

# 1. The module and its role capability
$module = Get-Module -ListAvailable -Name ITToolkit | Sort-Object -Property Version -Descending | Select-Object -First 1
if (-not $module) { throw 'ITToolkit is not installed. Run Install-ITToolkit.ps1 (for all users) first.' }
$programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
if (-not $module.ModuleBase.StartsWith($programFiles, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "ITToolkit $($module.Version) is installed in $($module.ModuleBase). Install it for all users (Install-ITToolkit.ps1 -Scope AllUsers) so the endpoint's account can load it."
}
$roleCapability = Join-Path $module.ModuleBase 'RoleCapabilities\ITHubTools.psrc'
if (-not (Test-Path -LiteralPath $roleCapability)) { throw "ITToolkit $($module.Version) has no RoleCapabilities\ITHubTools.psrc. Install version 1.2.0 or later." }
Write-Host "Using ITToolkit $($module.Version) from $($module.ModuleBase)"

if ($PSCmdlet.ParameterSetName -eq 'Gmsa') {
    $gmsaName = $GmsaAccount.TrimEnd('$')
    if (Get-Command -Name Test-ADServiceAccount -ErrorAction SilentlyContinue) {
        if (-not (Test-ADServiceAccount -Identity ($gmsaName.Split('\')[-1]))) {
            Write-Warning "This server cannot use $GmsaAccount yet. Run Install-ADServiceAccount, and check the gMSA's PrincipalsAllowedToRetrieveManagedPassword includes this server."
        }
    }
}

# 2. Transcript folder: administrators, SYSTEM and the gMSA only
if ($PSCmdlet.ShouldProcess($TranscriptDirectory, 'Create transcript folder and restrict access')) {
    New-Item -ItemType Directory -Path $TranscriptDirectory -Force | Out-Null
    $grants = @('*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F')
    if ($PSCmdlet.ParameterSetName -eq 'Gmsa') { $grants += "$($gmsaName)`$:(OI)(CI)M" }
    $arguments = @($TranscriptDirectory, '/inheritance:r') + @($grants | ForEach-Object { '/grant:r', $_ })
    & icacls.exe @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls could not set permissions on $TranscriptDirectory (exit code $LASTEXITCODE)." }
}

# 3. Session configuration
$configurationFolder = Join-Path $env:ProgramData 'ITToolkit'
$configurationPath = Join-Path $configurationFolder "$Name.pssc"
$configuration = @{
    Path                = $configurationPath
    SessionType         = 'RestrictedRemoteServer'
    TranscriptDirectory = $TranscriptDirectory
    RoleDefinitions     = @{ $ITHubAccount = @{ RoleCapabilities = 'ITHubTools' } }
    Description         = 'ITToolkit for ITHub: only Invoke-ITHubTool and Get-ITHubToolCatalog.'
}
if ($PSCmdlet.ParameterSetName -eq 'Gmsa') { $configuration.GroupManagedServiceAccount = $gmsaName }
else { $configuration.RunAsVirtualAccount = $true }

if ($PSCmdlet.ShouldProcess($configurationPath, 'Write session configuration')) {
    New-Item -ItemType Directory -Path $configurationFolder -Force | Out-Null
    New-PSSessionConfigurationFile @configuration
    if (-not (Test-PSSessionConfigurationFile -Path $configurationPath)) {
        throw "The generated session configuration $configurationPath is not valid."
    }
}

# 4. Register the endpoint
if ($PSCmdlet.ShouldProcess($Name, 'Register the JEA endpoint (restarts WinRM)')) {
    if (Get-PSSessionConfiguration -Name $Name -ErrorAction SilentlyContinue) {
        Unregister-PSSessionConfiguration -Name $Name -Force -NoServiceRestart
    }
    Register-PSSessionConfiguration -Name $Name -Path $configurationPath -Force | Out-Null
    Write-Host "Registered the '$Name' endpoint. Only $ITHubAccount can connect."
}

# 5. The client script, at a path that does not change between versions
$clientFolder = Join-Path $programFiles 'ITToolkit'
$clientPath = Join-Path $clientFolder 'Invoke-ITHubRequest.ps1'
if ($PSCmdlet.ShouldProcess($clientPath, 'Copy the ITHub client script')) {
    New-Item -ItemType Directory -Path $clientFolder -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $module.ModuleBase 'ITHub\Invoke-ITHubRequest.ps1') -Destination $clientPath -Force
    Unblock-File -LiteralPath $clientPath
    Write-Host "Client script: $clientPath"
}

Write-Host ''
Write-Host 'Next: set TOOLS_RUNNER_PATH in ITHub''s .env to the client script path above, then test as the ITHub account:'
Write-Host "  '{""action"":""catalog""}' | powershell.exe -NoProfile -File ""$clientPath"""
