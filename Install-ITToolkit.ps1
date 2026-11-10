<#
.SYNOPSIS
Installs or updates ITToolkit on this computer from this folder (a copy of the repository or a file share).

.DESCRIPTION
Copies src\ITToolkit into a versioned folder on the PowerShell module path, so ITToolkit
commands work in both Windows PowerShell 5.1 and PowerShell 7 without Import-Module:

  -Scope AllUsers (default, needs an elevated window)
      C:\Program Files\WindowsPowerShell\Modules\ITToolkit\<version>
  -Scope CurrentUser
      Documents\WindowsPowerShell\Modules\ITToolkit\<version>   (Windows PowerShell 5.1)
      Documents\PowerShell\Modules\ITToolkit\<version>          (PowerShell 7)

Earlier versions are kept so you can go back to one; -RemoveOldVersions deletes them.
Copied files are unblocked, so a copy taken from a downloaded zip still loads under the
RemoteSigned execution policy.

.PARAMETER Scope
AllUsers (default) or CurrentUser.

.PARAMETER SourcePath
Folder that holds ITToolkit.psd1. Defaults to src\ITToolkit next to this script.

.PARAMETER RemoveOldVersions
Deletes other installed versions in the same location.

.EXAMPLE
powershell.exe -ExecutionPolicy Bypass -File \\fs01\it$\ITToolkit\Install-ITToolkit.ps1

Installs for every user from the team share (run from an elevated window).

.EXAMPLE
.\Install-ITToolkit.ps1 -Scope CurrentUser

.EXAMPLE
.\Install-ITToolkit.ps1 -RemoveOldVersions
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('AllUsers', 'CurrentUser')]
    [string]$Scope = 'AllUsers',

    [string]$SourcePath = (Join-Path $PSScriptRoot 'src\ITToolkit'),

    [switch]$RemoveOldVersions
)

$ErrorActionPreference = 'Stop'

if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
    throw 'ITToolkit installs on Windows only.'
}
$manifestPath = Join-Path $SourcePath 'ITToolkit.psd1'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "No ITToolkit.psd1 in '$SourcePath'. Run this script from the ITToolkit folder or pass -SourcePath."
}
$version = (Import-PowerShellDataFile -LiteralPath $manifestPath).ModuleVersion

if ($Scope -eq 'AllUsers') {
    $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Installing for all users needs an elevated PowerShell window (Run as administrator). Or use -Scope CurrentUser.'
    }
    # From a 32-bit host (Intune runs platform scripts 32-bit by default) ProgramFiles is the
    # x86 folder, which 64-bit PowerShell never looks in.
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $moduleRoots = @(Join-Path $programFiles 'WindowsPowerShell\Modules')
}
else {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $moduleRoots = @(
        (Join-Path $documents 'WindowsPowerShell\Modules'),
        (Join-Path $documents 'PowerShell\Modules')
    )
}

$installed = @()
foreach ($moduleRoot in $moduleRoots) {
    $moduleFolder = Join-Path $moduleRoot 'ITToolkit'
    $destination = Join-Path $moduleFolder $version
    if ($PSCmdlet.ShouldProcess($destination, "Install ITToolkit $version")) {
        if (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Recurse -Force
        }
        New-Item -ItemType Directory -Path $destination -Force | Out-Null
        Copy-Item -Path (Join-Path $SourcePath '*') -Destination $destination -Recurse -Force
        Get-ChildItem -LiteralPath $destination -Recurse -File | Unblock-File
        $installed += $destination
        Write-Host "Installed ITToolkit $version to $destination"
    }

    if ($RemoveOldVersions -and (Test-Path -LiteralPath $moduleFolder)) {
        foreach ($old in @(Get-ChildItem -LiteralPath $moduleFolder -Directory | Where-Object { $_.Name -ne $version })) {
            if ($PSCmdlet.ShouldProcess($old.FullName, 'Remove old ITToolkit version')) {
                try {
                    Remove-Item -LiteralPath $old.FullName -Recurse -Force
                    Write-Host "Removed ITToolkit $($old.Name)"
                }
                catch {
                    Write-Warning "Could not remove $($old.FullName) (close PowerShell windows using it and try again): $($_.Exception.Message)"
                }
            }
        }
    }
}

# Load the installed copy to make sure it works before telling anyone it is ready.
foreach ($destination in $installed) {
    $module = Import-Module (Join-Path $destination 'ITToolkit.psd1') -Force -PassThru
    $count = @($module.ExportedFunctions.Keys).Count
    Remove-Module -ModuleInfo $module
    Write-Host "Checked: $count commands load from $destination"
}
if ($installed.Count) {
    Write-Host ''
    Write-Host 'Ready. Open a new PowerShell window and run Get-ITToolkitCommand to see what it can do.'
}
