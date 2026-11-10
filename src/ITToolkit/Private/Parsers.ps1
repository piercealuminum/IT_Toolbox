# Parsers for the text output of Windows tools. They expect the English output of
# dsregcmd, quser, w32tm and netsh; on other display languages some fields come back empty
# and the checks that use them report Info instead of a verdict.

function ConvertFrom-ITDsregStatus {
    # 'dsregcmd /status' lines -> hashtable of Key = Value (spaces removed from keys).
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    $result = @{}
    foreach ($line in @($Lines)) {
        if ($line -match '^\s*(?<key>[A-Za-z][A-Za-z0-9 ]*?)\s*:\s*(?<value>.*?)\s*$') {
            $key = $Matches['key'] -replace '\s', ''
            if (-not $result.ContainsKey($key)) { $result[$key] = $Matches['value'] }
        }
    }
    $result
}

function ConvertFrom-ITQuser {
    # 'quser' lines -> one object per session. The session name column is empty for
    # disconnected sessions, so the pattern treats it as optional.
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Lines,

        [string]$ComputerName
    )

    $pattern = '^[\s>](?<user>\S+)\s+(?:(?<session>\S+)\s+)?(?<id>\d+)\s+(?<state>\S+)\s+(?<idle>\S+)\s+(?<logon>\S.*?)\s*$'
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) { continue }

        $state = $match.Groups['state'].Value
        if ($state -eq 'Disc') { $state = 'Disconnected' }
        $idle = $match.Groups['idle'].Value
        if ($idle -in @('.', 'none')) { $idle = 'none' }
        $logonText = $match.Groups['logon'].Value
        $logon = [datetime]::MinValue
        $logonTime = $logonText
        if ([datetime]::TryParse($logonText, [ref]$logon)) { $logonTime = $logon }

        [pscustomobject]@{
            PSTypeName   = 'ITToolkit.Session'
            ComputerName = $ComputerName
            UserName     = $match.Groups['user'].Value
            SessionName  = $match.Groups['session'].Value
            Id           = [int]$match.Groups['id'].Value
            State        = $state
            IdleTime     = $idle
            LogonTime    = $logonTime
        }
    }
}

function ConvertFrom-ITW32tmStatus {
    # 'w32tm /query /status' lines -> Source, LastSync (datetime or $null), LastSyncText, Error.
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    $result = [ordered]@{ Source = $null; LastSync = $null; LastSyncText = $null; Error = $null }
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }
        if ($line -match 'error occurred[.:]?\s*(?<message>.+)$') {
            $result.Error = $Matches['message'].Trim()
        }
        elseif ($line -match '^\s*Source:\s*(?<value>.+?)\s*$') {
            $result.Source = ($Matches['value'] -replace ',0x[0-9a-fA-F]+$', '')
        }
        elseif ($line -match '^\s*Last Successful Sync Time:\s*(?<value>.+?)\s*$') {
            $result.LastSyncText = $Matches['value']
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($Matches['value'], [ref]$parsed)) { $result.LastSync = $parsed }
        }
    }
    [pscustomobject]$result
}

function ConvertFrom-ITWinHttpProxy {
    # 'netsh winhttp show proxy' lines -> 'Direct', the proxy server, or $null if unreadable.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Lines
    )

    $server = $null
    $bypass = $null
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }
        if ($line -match 'Direct access') { return 'Direct' }
        if ($line -match '^\s*Proxy Server\(s\)\s*:\s*(?<value>.+?)\s*$') { $server = $Matches['value'] }
        elseif ($line -match '^\s*Bypass List\s*:\s*(?<value>.+?)\s*$') { $bypass = $Matches['value'] }
    }
    if ($server -and $bypass) { return "$server (bypass: $bypass)" }
    return $server
}
