<#
.SYNOPSIS
Signs every ITToolkit script file with your code signing certificate, for computers that use the AllSigned execution policy.

.DESCRIPTION
Signs the module files in src\ITToolkit (.ps1, .psm1, .psd1, .ps1xml) and Install-ITToolkit.ps1
with Set-AuthenticodeSignature and a timestamp, so signatures stay valid after the certificate
expires.

Sign after every change and before copying to the team share: editing a signed file breaks
its signature and Windows will refuse to load it under AllSigned.

The certificate must be a code signing certificate trusted by the computers (issued by your
internal CA, or added to Trusted Publishers by Group Policy or Intune).

.PARAMETER Thumbprint
Thumbprint of the certificate to use. If omitted, the only code signing certificate in your
personal store (Cert:\CurrentUser\My) is used.

.PARAMETER TimestampServer
RFC 3161 timestamp server. Default: http://timestamp.digicert.com

.EXAMPLE
.\build\Sign-ITToolkit.ps1

.EXAMPLE
.\build\Sign-ITToolkit.ps1 -Thumbprint 0123456789ABCDEF0123456789ABCDEF01234567
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Thumbprint,
    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$certificates = @(Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.NotAfter -gt (Get-Date) })
if ($Thumbprint) {
    $certificates = @($certificates | Where-Object { $_.Thumbprint -eq $Thumbprint })
}
if ($certificates.Count -eq 0) { throw 'No valid code signing certificate found in Cert:\CurrentUser\My.' }
if ($certificates.Count -gt 1) {
    $certificates | Format-Table Thumbprint, Subject, NotAfter -AutoSize | Out-String | Write-Host
    throw 'More than one code signing certificate found. Pick one with -Thumbprint.'
}
$certificate = $certificates[0]
Write-Host "Signing with $($certificate.Subject) (expires $($certificate.NotAfter.ToString('yyyy-MM-dd')))"

$files = @(Get-ChildItem -Path (Join-Path $root 'src\ITToolkit') -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.ps1xml')
$files += Get-Item -LiteralPath (Join-Path $root 'Install-ITToolkit.ps1')

$failed = 0
foreach ($file in $files) {
    if ($PSCmdlet.ShouldProcess($file.FullName, 'Sign')) {
        $result = Set-AuthenticodeSignature -FilePath $file.FullName -Certificate $certificate -TimestampServer $TimestampServer -HashAlgorithm SHA256
        if ($result.Status -ne 'Valid') {
            $failed++
            Write-Warning "$($file.Name): $($result.Status) $($result.StatusMessage)"
        }
    }
}
if ($failed) { throw "$failed file(s) were not signed." }
Write-Host "Signed $($files.Count) files."
