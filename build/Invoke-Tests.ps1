<#
.SYNOPSIS
Runs the compatibility check and the Pester tests. Works in PowerShell 7 and Windows PowerShell 5.1.

.DESCRIPTION
Needs Pester 5. If you only have the Pester 3.4 that ships with Windows, install Pester 5 first:
    Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck

On Windows, run it from an elevated window to cover the admin-only checks. The compatibility
check needs PowerShell 7 (its parser knows the 7-only syntax it looks for), so it is skipped
in Windows PowerShell 5.1.

.PARAMETER Tag
Only run tests with these tags (for example Windows or Remote).

.PARAMETER ExcludeTag
Skip tests with these tags.

.EXAMPLE
pwsh ./build/Invoke-Tests.ps1

.EXAMPLE
powershell.exe -File .\build\Invoke-Tests.ps1
#>
[CmdletBinding()]
param(
    [string[]]$Tag,
    [string[]]$ExcludeTag
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if ($PSVersionTable.PSVersion.Major -ge 7) {
    & (Join-Path $PSScriptRoot 'Test-Compatibility.ps1') -Path $root
}
else {
    Write-Host 'Skipping the compatibility check (it needs PowerShell 7).'
}

Import-Module Pester -MinimumVersion 5.5 -ErrorAction Stop
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $root 'tests'
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = Join-Path $root ('TestResults-PS{0}.xml' -f $PSVersionTable.PSVersion.Major)
if ($Tag) { $configuration.Filter.Tag = $Tag }
if ($ExcludeTag) { $configuration.Filter.ExcludeTag = $ExcludeTag }
Invoke-Pester -Configuration $configuration
