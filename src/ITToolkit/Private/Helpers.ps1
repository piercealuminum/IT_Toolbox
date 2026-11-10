# Small shared helpers.

function New-ITCheckResult {
    [CmdletBinding()]
    param(
        [string]$ComputerName,
        [string]$Category,
        [string]$Check,
        [ValidateSet('OK', 'Warn', 'Fail', 'Info')]
        [string]$Status,
        [string]$Detail
    )

    [pscustomobject]@{
        PSTypeName   = 'ITToolkit.CheckResult'
        ComputerName = $ComputerName
        Category     = $Category
        Check        = $Check
        Status       = $Status
        Detail       = $Detail
    }
}

function Format-ITBytes {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [double]$Bytes
    )

    if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} bytes' -f $Bytes)
}

function Get-ITRandomIndex {
    # Uniform random integer from 0 to Maximum - 1, from a cryptographic random number
    # generator. Rejection sampling avoids the bias a plain modulo would add.
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [int]$Maximum
    )

    if ($Maximum -lt 1) { throw 'Maximum must be 1 or more.' }
    if (-not $script:ITRng) { $script:ITRng = [System.Security.Cryptography.RandomNumberGenerator]::Create() }

    $range = [long]4294967296
    $limit = $range - ($range % $Maximum)
    $bytes = New-Object byte[] 4
    do {
        $script:ITRng.GetBytes($bytes)
        $value = [long][System.BitConverter]::ToUInt32($bytes, 0)
    } while ($value -ge $limit)
    [int]($value % $Maximum)
}

function Get-ITWordList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    if (-not $script:ITWordList) {
        $path = Join-Path $script:ITModuleRoot 'Data\Words.txt'
        $script:ITWordList = @(Get-Content -LiteralPath $path |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and -not $_.StartsWith('#') })
    }
    $script:ITWordList
}

function ConvertTo-ITTcpTarget {
    # Parses 'host:port' (or '[ipv6]:port') into Host and Port.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Target
    )

    $match = [regex]::Match($Target.Trim(), '^\[?(?<host>[^\[\]]+?)\]?:(?<port>\d{1,5})$')
    if (-not $match.Success) {
        throw "'$Target' is not in host:port form (for example dc01:389 or [fe80::1]:443)."
    }
    $port = [int]$match.Groups['port'].Value
    if ($port -lt 1 -or $port -gt 65535) {
        throw "Port $port in '$Target' is outside 1-65535."
    }
    [pscustomobject]@{
        Host = $match.Groups['host'].Value
        Port = $port
    }
}

function Get-ITFirstLine {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [string]$Text,
        [int]$MaxLength = 200
    )

    if (-not $Text) { return '' }
    $line = (($Text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
    if (-not $line) { return '' }
    $line = $line.Trim()
    if ($line.Length -gt $MaxLength) { $line = $line.Substring(0, $MaxLength - 3) + '...' }
    $line
}
