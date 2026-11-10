<#
.SYNOPSIS
Checks that every ITToolkit source file will load in Windows PowerShell 5.1.

.DESCRIPTION
Windows PowerShell 5.1 is what every Windows 10 and 11 computer has, so the module must not
use syntax or cmdlet parameters that only exist in PowerShell 7. This script fails on:
  - files that do not parse
  - non-ASCII characters (5.1 reads files without a byte order mark as ANSI, which garbles them)
  - PowerShell 7 only syntax: ternary ?:, ?? and ??=, ?. and ?[], && and || pipeline chains
  - PowerShell 7 only cmdlet parameters and automatic variables listed below
It runs anywhere PowerShell 7 runs, which is how CI and non-Windows machines catch these
before a tech does.

.EXAMPLE
pwsh ./build/Test-Compatibility.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $Path).Path
$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.ps1xml', '*.txt', '*.md', '*.yml' |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })

# PowerShell 7 only parameters, as 'Command|Parameter'.
$ps7Parameters = @(
    'ForEach-Object|Parallel', 'ForEach-Object|ThrottleLimit', 'ConvertFrom-Json|AsHashtable', 'ConvertFrom-Json|Depth',
    'Get-Content|AsByteStream', 'Set-Content|AsByteStream', 'Join-Path|AdditionalChildPath', 'Invoke-WebRequest|SkipCertificateCheck',
    'Invoke-RestMethod|SkipCertificateCheck', 'Test-Connection|TargetName', 'Select-String|Raw', 'Get-ChildItem|FollowSymlink'
)
$ps7Commands = @('Get-Error', 'Test-Json', 'ConvertFrom-Markdown', 'Get-Uptime', 'Remove-Alias', 'Join-String')
$ps7Variables = @('IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR', 'PSStyle')

$problems = New-Object System.Collections.Generic.List[string]
foreach ($file in $files) {
    $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/')
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 127) {
            $line = ([System.Text.Encoding]::ASCII.GetString($bytes, 0, $i) -split "`n").Count
            $problems.Add("${relative}:${line}: non-ASCII character (byte 0x{0:X2})" -f $bytes[$i])
            break
        }
    }

    if ($file.Extension -notin @('.ps1', '.psm1', '.psd1')) { continue }
    # Tests and build scripts run under Pester/PowerShell 7 too, but they must still parse in 5.1.
    $isModuleCode = $relative -match '^src[\\/]' -or $relative -eq 'Install-ITToolkit.ps1'

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    foreach ($parseError in @($errors)) {
        $problems.Add("${relative}:$($parseError.Extent.StartLineNumber): parse error: $($parseError.Message)")
    }

    $nodes = $ast.FindAll({ $true }, $true)
    foreach ($node in $nodes) {
        $line = $node.Extent.StartLineNumber
        $typeName = $node.GetType().Name
        if ($typeName -eq 'TernaryExpressionAst') { $problems.Add("${relative}:${line}: ternary operator ?: needs PowerShell 7") }
        if ($typeName -eq 'PipelineChainAst') { $problems.Add("${relative}:${line}: && or || needs PowerShell 7") }
        if ($node -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$node.Operator -eq 'QuestionQuestion') {
            $problems.Add("${relative}:${line}: ?? needs PowerShell 7")
        }
        if ($node -is [System.Management.Automation.Language.AssignmentStatementAst] -and [string]$node.Operator -eq 'QuestionQuestionEquals') {
            $problems.Add("${relative}:${line}: ??= needs PowerShell 7")
        }
        if (($node -is [System.Management.Automation.Language.MemberExpressionAst] -or $node -is [System.Management.Automation.Language.IndexExpressionAst]) -and
            $node.PSObject.Properties['NullConditional'] -and $node.NullConditional) {
            $problems.Add("${relative}:${line}: ?. or ?[] needs PowerShell 7")
        }
        if (-not $isModuleCode) { continue }
        if ($node -is [System.Management.Automation.Language.CommandAst]) {
            $name = $node.GetCommandName()
            if ($name -in $ps7Commands) { $problems.Add("${relative}:${line}: $name does not exist in Windows PowerShell 5.1") }
            foreach ($element in $node.CommandElements) {
                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    foreach ($entry in $ps7Parameters) {
                        $command, $parameter = $entry -split '\|'
                        if ($name -eq $command -and $parameter -like "$($element.ParameterName)*" -and $element.ParameterName.Length -ge 3) {
                            $problems.Add("${relative}:${line}: $name -$parameter needs PowerShell 7")
                        }
                    }
                }
            }
        }
        if ($node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -in $ps7Variables) {
            $problems.Add("${relative}:${line}: `$$($node.VariablePath.UserPath) is not set in Windows PowerShell 5.1")
        }
    }
}

if ($problems.Count) {
    $problems | ForEach-Object { Write-Host $_ }
    throw "$($problems.Count) compatibility problem(s) found."
}
Write-Host "Compatibility check passed: $($files.Count) files."
