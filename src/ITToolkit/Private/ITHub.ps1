# The ITHub web interface's contract: which tools ITHub may run, how each parameter is
# checked, and how results become the JSON envelope ITHub reads. See the ITHub Tools spec.
#
# Only tools listed here can be run through Invoke-ITHubTool. Each parameter has a rule; a
# request with an unknown tool, an unknown parameter or a value that breaks a rule is refused
# before any command runs.

$script:ITHubSchemaVersion = 1

# Parameter rules. Patterns are deliberately narrow: no spaces in names, no shell or
# PowerShell metacharacters, nothing that is not needed.
$script:ITHubRules = @{
    computerName = @{ Type = 'string'; Pattern = '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$' }
    identity     = @{ Type = 'string'; Pattern = '^[A-Za-z0-9][A-Za-z0-9._@-]{0,255}$' }
    hours        = @{ Type = 'integer'; Minimum = 1; Maximum = 720 }
    ports        = @{ Type = 'integer[]'; Minimum = 1; Maximum = 65535; MaxItems = 20 }
    hostPorts    = @{ Type = 'string[]'; Pattern = '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}:[0-9]{1,5}$'; MaxItems = 10 }
    softwareName = @{ Type = 'string'; Pattern = '^[A-Za-z0-9 .*_()+&,-]{1,100}$' }
    portPreset   = @{ Type = 'enum'; Values = @('DomainController', 'Email', 'Printer', 'RDP', 'SMB', 'SQL', 'SSH', 'Web', 'WinRM') }
}

# Phase 1 tools: read-only. Phase 2 and 3 tools are added here when their gates pass.
$script:ITHubTools = @(
    @{
        Id = 'device-health'; Title = 'Device health'; Command = 'Get-ITDeviceHealth'; Target = 'computer'; Permission = 'tools.run'; Phase = 1; ResultType = 'ITToolkit.CheckResult'
        Parameters = @(@{ Name = 'computerName'; Bind = 'ComputerName'; Rule = 'computerName'; Required = $true; Description = 'Computer to check' })
    }
    @{
        Id = 'pending-reboot'; Title = 'Pending restart'; Command = 'Get-ITPendingReboot'; Target = 'computer'; Permission = 'tools.run'; Phase = 1; ResultType = 'ITToolkit.PendingReboot'
        Parameters = @(@{ Name = 'computerName'; Bind = 'ComputerName'; Rule = 'computerName'; Required = $true; Description = 'Computer to check' })
    }
    @{
        Id = 'network-test'; Title = 'Network test'; Command = 'Test-ITNetwork'; Target = 'computer'; Permission = 'tools.run'; Phase = 1; ResultType = 'ITToolkit.CheckResult'
        Parameters = @(
            @{ Name = 'computerName'; Bind = 'ComputerName'; Rule = 'computerName'; Required = $true; Description = 'Computer to test from' }
            @{ Name = 'tcpTargets'; Bind = 'TcpTarget'; Rule = 'hostPorts'; Required = $false; Description = 'Extra host:port pairs to connect to, such as fs01:445' }
        )
    }
    @{
        Id = 'port-test'; Title = 'Port test'; Command = 'Test-ITPort'; Target = 'computer'; Permission = 'tools.run'; Phase = 1; ResultType = 'ITToolkit.PortTest'; OneOf = @('ports', 'preset')
        Parameters = @(
            @{ Name = 'host'; Bind = 'ComputerName'; Rule = 'computerName'; Required = $true; Description = 'Server or device to connect to' }
            @{ Name = 'ports'; Bind = 'Port'; Rule = 'ports'; Required = $false; Description = 'TCP ports to test (give ports or preset)' }
            @{ Name = 'preset'; Bind = 'Preset'; Rule = 'portPreset'; Required = $false; Description = 'A named set of ports (give ports or preset)' }
            @{ Name = 'fromComputer'; Bind = 'Source'; Rule = 'computerName'; Required = $false; Description = 'Test from this computer instead of the ITHub server' }
        )
    }
    @{
        Id = 'signed-in-users'; Title = 'Signed-in users'; Command = 'Get-ITLoggedOnUser'; Target = 'computer'; Permission = 'tools.run'; Phase = 1; ResultType = 'ITToolkit.Session'
        Parameters = @(@{ Name = 'computerName'; Bind = 'ComputerName'; Rule = 'computerName'; Required = $true; Description = 'Computer to check' })
    }
    @{
        Id = 'installed-software'; Title = 'Installed software'; Command = 'Get-ITInstalledSoftware'; Target = 'computer'; Permission = 'tools.run'; Phase = 1; ResultType = 'ITToolkit.Software'
        Parameters = @(
            @{ Name = 'computerName'; Bind = 'ComputerName'; Rule = 'computerName'; Required = $true; Description = 'Computer to check' }
            @{ Name = 'name'; Bind = 'Name'; Rule = 'softwareName'; Required = $false; Description = 'Program name to look for; * is a wildcard' }
        )
    }
    @{
        Id = 'event-summary'; Title = 'Event log summary'; Command = 'Get-ITEventSummary'; Target = 'computer'; Permission = 'tools.run'; Phase = 1; ResultType = 'ITToolkit.EventGroup'
        Parameters = @(
            @{ Name = 'computerName'; Bind = 'ComputerName'; Rule = 'computerName'; Required = $true; Description = 'Computer to check' }
            @{ Name = 'hours'; Bind = 'Hours'; Rule = 'hours'; Required = $false; Default = 24; Description = 'How many hours back to look' }
        )
    }
    @{
        Id = 'local-admins'; Title = 'Local administrators'; Command = 'Get-ITLocalAdmin'; Target = 'computer'; Permission = 'tools.run'; Phase = 1; ResultType = 'ITToolkit.LocalAdmin'
        Parameters = @(@{ Name = 'computerName'; Bind = 'ComputerName'; Rule = 'computerName'; Required = $true; Description = 'Computer to check' })
    }
    @{
        Id = 'user-status'; Title = 'User account status'; Command = 'Get-ITUserStatus'; Target = 'user'; Permission = 'tools.run'; Phase = 1; ResultType = 'ITToolkit.UserCheck'; NeedsGraph = $true
        Parameters = @(@{ Name = 'identity'; Bind = 'Identity'; Rule = 'identity'; Required = $true; Description = 'Account name, UPN or email address' })
    }
    @{
        Id = 'lockout-source'; Title = 'Lockout source'; Command = 'Get-ITLockoutSource'; Target = 'user'; Permission = 'tools.run'; Phase = 1; ResultType = 'ITToolkit.Lockout'
        Parameters = @(
            @{ Name = 'identity'; Bind = 'Identity'; Rule = 'identity'; Required = $false; Description = 'Account name or UPN; leave empty for every lockout' }
            @{ Name = 'hours'; Bind = 'Hours'; Rule = 'hours'; Required = $false; Default = 24; Description = 'How many hours back to look' }
        )
    }
)

function Get-ITHubToolDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )

    foreach ($tool in $script:ITHubTools) {
        if ($tool.Id -ceq $Id) { return $tool }
    }
    return $null
}

function Test-ITHubValue {
    # Returns $null when the value meets the rule, else a message saying what is wrong.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [hashtable]$Rule
    )

    switch ($Rule.Type) {
        'string' {
            if ($Value -isnot [string]) { return "$Name must be a string" }
            if ($Value -cnotmatch $Rule.Pattern) { return "$Name '$Value' is not allowed (must match $($Rule.Pattern))" }
        }
        'enum' {
            if ($Value -isnot [string] -or $Rule.Values -cnotcontains $Value) { return "$Name must be one of: $($Rule.Values -join ', ')" }
        }
        'integer' {
            if (-not ($Value -is [int] -or $Value -is [long])) { return "$Name must be a whole number" }
            if ($Value -lt $Rule.Minimum -or $Value -gt $Rule.Maximum) { return "$Name must be from $($Rule.Minimum) to $($Rule.Maximum)" }
        }
        'integer[]' {
            $items = @($Value)
            if ($Value -isnot [array] -or $items.Count -lt 1 -or $items.Count -gt $Rule.MaxItems) { return "$Name must be a list of 1 to $($Rule.MaxItems) numbers" }
            foreach ($item in $items) {
                if (-not ($item -is [int] -or $item -is [long]) -or $item -lt $Rule.Minimum -or $item -gt $Rule.Maximum) {
                    return "$Name values must be whole numbers from $($Rule.Minimum) to $($Rule.Maximum)"
                }
            }
        }
        'string[]' {
            $items = @($Value)
            if ($Value -isnot [array] -or $items.Count -lt 1 -or $items.Count -gt $Rule.MaxItems) { return "$Name must be a list of 1 to $($Rule.MaxItems) values" }
            foreach ($item in $items) {
                if ($item -isnot [string] -or $item -cnotmatch $Rule.Pattern) { return "$Name value '$item' is not allowed (must match $($Rule.Pattern))" }
            }
        }
        default { return "$Name has an unknown rule" }
    }
    return $null
}

function Resolve-ITHubRequest {
    # Parses and checks a request. Returns Tool, Parameters (echoed back, as given), Bound
    # (for splatting into the command) and RequestedBy, or throws listing every problem.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$RequestJson
    )

    try { $request = ConvertFrom-Json -InputObject $RequestJson -ErrorAction Stop }
    catch { throw 'The request is not valid JSON.' }
    if ($request -isnot [System.Management.Automation.PSCustomObject]) { throw 'The request must be a JSON object.' }

    $names = @($request.PSObject.Properties | ForEach-Object { $_.Name })
    $unknownTop = @($names | Where-Object { $_ -cnotin @('tool', 'parameters', 'requestedBy') })
    if ($unknownTop.Count) { throw "Unknown request field(s): $($unknownTop -join ', ')." }

    $toolId = $request.tool
    if ($toolId -isnot [string] -or -not $toolId) { throw 'The request needs a tool.' }
    $tool = Get-ITHubToolDefinition -Id $toolId
    if (-not $tool) { throw "Unknown tool '$toolId'." }

    $requestedBy = $null
    if ($null -ne $request.requestedBy) {
        if ($request.requestedBy -isnot [string] -or $request.requestedBy -cnotmatch "^[A-Za-z0-9 .@'_\\-]{1,128}$") { throw 'requestedBy must be a name of up to 128 letters, digits, spaces and . @ '' _ \ -' }
        $requestedBy = $request.requestedBy
    }

    $given = [ordered]@{}
    if ($null -ne $request.parameters) {
        if ($request.parameters -isnot [System.Management.Automation.PSCustomObject]) { throw 'parameters must be a JSON object.' }
        foreach ($property in $request.parameters.PSObject.Properties) { $given[$property.Name] = $property.Value }
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $known = @($tool.Parameters | ForEach-Object { $_.Name })
    foreach ($name in $given.Keys) {
        if ($known -cnotcontains $name) { $problems.Add("Unknown parameter '$name' for $toolId.") }
    }

    $echo = [ordered]@{}
    $bound = @{}
    foreach ($parameter in $tool.Parameters) {
        $present = $given.Contains($parameter.Name) -and $null -ne $given[$parameter.Name]
        if (-not $present) {
            if ($parameter.Required) { $problems.Add("$($parameter.Name) is required.") }
            elseif ($parameter.ContainsKey('Default')) {
                $echo[$parameter.Name] = $parameter.Default
                $bound[$parameter.Bind] = $parameter.Default
            }
            continue
        }
        $value = $given[$parameter.Name]
        $problem = Test-ITHubValue -Name $parameter.Name -Value $value -Rule $script:ITHubRules[$parameter.Rule]
        if ($problem) { $problems.Add("$problem.") ; continue }
        $echo[$parameter.Name] = $value
        $rule = $script:ITHubRules[$parameter.Rule]
        if ($rule.Type -eq 'integer[]') { $bound[$parameter.Bind] = [int[]]@($value) }
        elseif ($rule.Type -eq 'string[]') { $bound[$parameter.Bind] = [string[]]@($value) }
        elseif ($rule.Type -eq 'integer') { $bound[$parameter.Bind] = [int]$value }
        else { $bound[$parameter.Bind] = [string]$value }
    }

    if ($tool.ContainsKey('OneOf')) {
        $supplied = @($tool.OneOf | Where-Object { $echo.Contains($_) })
        if ($supplied.Count -ne 1) { $problems.Add("Give exactly one of: $($tool.OneOf -join ', ').") }
    }

    if ($problems.Count) { throw ($problems -join ' ') }

    [pscustomobject]@{
        Tool        = $tool
        Parameters  = $echo
        Bound       = $bound
        RequestedBy = $requestedBy
    }
}

function ConvertTo-ITHubName {
    # PascalCase property name to camelCase: ComputerName -> computerName, OK -> ok.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($Name -cmatch '^[A-Z0-9]+$') { return $Name.ToLowerInvariant() }
    $Name.Substring(0, 1).ToLowerInvariant() + $Name.Substring(1)
}

function ConvertTo-ITHubValue {
    # Values for JSON: dates as UTC ISO 8601 text, lists as lists, objects as camelCase maps.
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value,

        [int]$Depth = 0
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [enum]) { return [string]$Value }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint32] -or $Value -is [uint64]) { return $Value }
    if ($Depth -ge 4) { return [string]$Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $map = [ordered]@{}
        foreach ($key in $Value.Keys) { $map[(ConvertTo-ITHubName -Name ([string]$key))] = ConvertTo-ITHubValue -Value $Value[$key] -Depth ($Depth + 1) }
        return $map
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $Value) { $list.Add((ConvertTo-ITHubValue -Value $item -Depth ($Depth + 1))) }
        return , $list.ToArray()
    }
    $map = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        if ($property.MemberType -notin @('NoteProperty', 'Property')) { continue }
        $map[(ConvertTo-ITHubName -Name $property.Name)] = ConvertTo-ITHubValue -Value $property.Value -Depth ($Depth + 1)
    }
    return $map
}

function ConvertTo-ITHubResult {
    # One result row: its ITToolkit type first, then its properties in camelCase.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $InputObject
    )

    $row = [ordered]@{ type = [string]$InputObject.PSObject.TypeNames[0] }
    $converted = ConvertTo-ITHubValue -Value $InputObject
    if ($converted -is [System.Collections.IDictionary]) {
        foreach ($key in $converted.Keys) { $row[$key] = $converted[$key] }
    }
    else {
        $row['value'] = $converted
    }
    $row
}

function Connect-ITHubGraph {
    # App-only Microsoft Graph sign-in for user-status runs through ITHub, using the
    # certificate named in the ITHub settings (in the computer's certificate store). Does
    # nothing when already connected or not configured; never prompts. Returns a warning
    # message when it could not connect, else $null.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $settings = (Get-ITSettings).ITHub
    if (-not ($settings.GraphTenantId -and $settings.GraphClientId -and $settings.GraphCertificateThumbprint)) { return $null }
    if (-not (Get-Command -Name Connect-MgGraph -ErrorAction SilentlyContinue)) {
        return 'Microsoft Graph PowerShell is not installed on the ITHub server, so Entra ID was not checked.'
    }
    if (Get-MgContext) { return $null }
    try {
        $thumbprint = ($settings.GraphCertificateThumbprint -replace '\s', '').ToUpperInvariant()
        $certificate = Get-Item -LiteralPath "Cert:\LocalMachine\My\$thumbprint" -ErrorAction Stop
        Connect-MgGraph -TenantId $settings.GraphTenantId -ClientId $settings.GraphClientId -Certificate $certificate -NoWelcome -ErrorAction Stop | Out-Null
        return $null
    }
    catch {
        return "Could not sign in to Microsoft Graph with the ITHub Tools certificate: $($_.Exception.Message)"
    }
}
