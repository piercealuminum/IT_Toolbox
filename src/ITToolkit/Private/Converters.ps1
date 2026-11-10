# Converters turn raw collector data into the objects the commands return. They run on the
# tech's computer, never on the target, and hold every threshold and every message.

function ConvertTo-ITHealthCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        $Health,

        [AllowNull()]
        $Reboot,

        [Parameter(Mandatory)]
        [hashtable]$Settings
    )

    $results = New-Object System.Collections.Generic.List[object]
    function Add-Check([string]$Category, [string]$Check, [string]$Status, [string]$Detail) {
        $results.Add((New-ITCheckResult -ComputerName $ComputerName -Category $Category -Check $Check -Status $Status -Detail $Detail))
    }

    $os = $Health.OS
    $system = $Health.System
    $osDrive = 'C:'
    if ($os -and $os.SystemDrive) { $osDrive = $os.SystemDrive }

    # System
    $parts = @()
    if ($system) {
        $hardware = ('{0} {1}' -f $system.Manufacturer, $system.Model).Trim()
        if ($hardware) { $parts += $hardware }
    }
    if ($Health.SerialNumber) { $parts += "serial $($Health.SerialNumber)" }
    if ($os -and $os.Caption) {
        $osText = ([string]$os.Caption -replace '^Microsoft\s+', '').Trim()
        if ($Health.DisplayVersion) { $osText += " $($Health.DisplayVersion)" }
        if ($Health.Build) { $osText += " (build $($Health.Build))" }
        $parts += $osText
    }
    if ($parts.Count) { Add-Check 'System' 'System' 'Info' ($parts -join ', ') }

    if ($system) {
        $user = if ($system.UserName) { [string]$system.UserName } else { 'Nobody is signed in at the console' }
        Add-Check 'System' 'Signed-in user' 'Info' $user
    }

    # Device join
    $dsreg = $null
    if (@($Health.Dsreg).Count) { $dsreg = ConvertFrom-ITDsregStatus -Lines $Health.Dsreg }
    $entraJoined = [bool]($dsreg -and $dsreg['AzureAdJoined'] -eq 'YES')
    if ($dsreg -and $dsreg.ContainsKey('DomainJoined')) { $domainJoined = $dsreg['DomainJoined'] -eq 'YES' }
    else { $domainJoined = [bool]($system -and $system.PartOfDomain) }
    $domainName = $null
    if ($dsreg -and $dsreg['DomainName']) { $domainName = $dsreg['DomainName'] }
    elseif ($system) { $domainName = $system.Domain }
    $tenant = 'unknown'
    if ($dsreg -and $dsreg['TenantName']) { $tenant = $dsreg['TenantName'] }

    $joinStatus = 'Info'
    if ($entraJoined -and $domainJoined) { $join = "Hybrid joined (domain $domainName, tenant $tenant)" }
    elseif ($entraJoined) { $join = "Entra joined (tenant $tenant)" }
    elseif ($domainJoined) { $join = "Domain joined ($domainName)" }
    else {
        $join = 'Not joined to a domain or Entra ID'
        $joinStatus = 'Warn'
    }
    $intune = @($Health.MdmEnrollments | Where-Object { $_ -and $_.ProviderID -eq 'MS DM Server' })
    if ($intune.Count) {
        $upn = @($intune | Where-Object { $_.UPN } | ForEach-Object { $_.UPN }) | Select-Object -First 1
        if ($upn) { $join += "; Intune enrolled ($upn)" } else { $join += '; Intune enrolled' }
    }
    elseif ($entraJoined) {
        $join += '; no Intune enrollment found'
    }
    Add-Check 'System' 'Device join' $joinStatus $join

    # Uptime and pending reboot
    if ($Reboot -and $null -ne $Reboot.UptimeDays) {
        $days = [double]$Reboot.UptimeDays
        $detail = '{0:N1} days since last boot' -f $days
        if ($Reboot.LastBootTime) { $detail += ' ({0:yyyy-MM-dd HH:mm})' -f [datetime]$Reboot.LastBootTime }
        $status = if ($days -gt $Settings.UptimeDaysWarn) { 'Warn' } else { 'OK' }
        Add-Check 'Maintenance' 'Uptime' $status $detail
    }
    if ($Reboot) {
        $reasons = @($Reboot.Reasons | Where-Object { $_ })
        if ($reasons.Count) {
            Add-Check 'Maintenance' 'Pending reboot' 'Warn' ('Restart needed: ' + ($reasons -join ', '))
        }
        else {
            $detail = 'No restart pending'
            if ($Reboot.PendingFileRenames -gt 0) { $detail += " ($($Reboot.PendingFileRenames) pending file rename entries, usually harmless)" }
            Add-Check 'Maintenance' 'Pending reboot' 'OK' $detail
        }
    }

    # Disks
    foreach ($disk in @($Health.Disks | Where-Object { $_ -and $_.SizeBytes -gt 0 } | Sort-Object -Property Drive)) {
        $freePercent = 100 * [double]$disk.FreeBytes / [double]$disk.SizeBytes
        $freeGB = [double]$disk.FreeBytes / 1GB
        $isSystemDrive = $disk.Drive -eq $osDrive
        $status = 'OK'
        if ($freePercent -lt $Settings.DiskFreePercentFail -or ($isSystemDrive -and $freeGB -lt $Settings.DiskFreeGBFail)) { $status = 'Fail' }
        elseif ($freePercent -lt $Settings.DiskFreePercentWarn -or ($isSystemDrive -and $freeGB -lt $Settings.DiskFreeGBWarn)) { $status = 'Warn' }
        $detail = '{0} free of {1} ({2:N0}%)' -f (Format-ITBytes $disk.FreeBytes), (Format-ITBytes $disk.SizeBytes), $freePercent
        Add-Check 'Storage' "Disk $($disk.Drive)" $status $detail
    }

    if ($os -and $os.TotalMemoryKB -gt 0) {
        $total = [double]$os.TotalMemoryKB * 1KB
        $free = [double]$os.FreeMemoryKB * 1KB
        Add-Check 'System' 'Memory' 'Info' ('{0} total, {1} free ({2:N0}%)' -f (Format-ITBytes $total), (Format-ITBytes $free), (100 * $free / $total))
    }

    # BitLocker
    if ($null -eq $Health.BitLocker) {
        $why = if (-not $Health.IsElevated) { 'run as administrator to read BitLocker status' } else { $Health.BitLockerError }
        Add-Check 'Security' 'BitLocker' 'Info' "Not checked: $why"
    }
    else {
        $fixedDrives = @($Health.Disks | ForEach-Object { $_.Drive })
        $volumes = @($Health.BitLocker | Where-Object { $_.Drive -and ($fixedDrives -contains $_.Drive) } | Sort-Object -Property Drive)
        if (-not $volumes.Count) {
            Add-Check 'Security' 'BitLocker' 'Info' 'No fixed drives with a drive letter were reported'
        }
        else {
            $status = 'OK'
            $parts = @()
            foreach ($volume in $volumes) {
                $on = [int]$volume.ProtectionStatus -eq 1
                $parts += '{0} {1}' -f $volume.Drive, $(if ($on) { 'on' } else { 'OFF' })
                if (-not $on) {
                    if ($volume.Drive -eq $osDrive) { $status = 'Fail' }
                    elseif ($status -ne 'Fail') { $status = 'Warn' }
                }
            }
            Add-Check 'Security' 'BitLocker' $status ($parts -join ', ')
        }
    }

    # Antivirus. With another antivirus installed, Defender is either passive (Defender for
    # Endpoint) or switched off ("Not running"); both are fine if the other product is active.
    $defender = $Health.Defender
    $otherAv = @($Health.AntivirusProducts | Where-Object { $_ -and $_ -notmatch 'Defender' })
    $passive = [bool]($defender -and [string]$defender.AMRunningMode -match 'Passive|SxS|Not running')
    $realTimeOff = [bool]($defender -and (-not $defender.RealTimeProtectionEnabled -or -not $defender.AntivirusEnabled))
    if ($otherAv.Count -and (-not $defender -or $passive -or $realTimeOff)) {
        if (-not $defender) { $state = 'Defender is not reporting' }
        elseif ($passive) { $state = "Defender is in '$($defender.AMRunningMode)' mode" }
        else { $state = 'Defender real-time protection is off' }
        Add-Check 'Security' 'Antivirus' 'Info' ($state + '; active antivirus: ' + ($otherAv -join ', '))
    }
    elseif (-not $defender) {
        Add-Check 'Security' 'Antivirus' 'Warn' ("Could not read Microsoft Defender status: $($Health.DefenderError)")
    }
    elseif ($passive) {
        Add-Check 'Security' 'Antivirus' 'Warn' "Defender is in '$($defender.AMRunningMode)' mode and no other antivirus is registered with Windows Security"
    }
    elseif ($realTimeOff) {
        Add-Check 'Security' 'Antivirus' 'Fail' 'Microsoft Defender real-time protection is OFF and no other antivirus is registered with Windows Security'
    }
    else {
        $age = $defender.AntivirusSignatureAge
        $tamper = 'unknown'
        if ($defender.IsTamperProtected -eq $true) { $tamper = 'on' }
        elseif ($defender.IsTamperProtected -eq $false) { $tamper = 'off' }
        if ($null -ne $age -and [double]$age -gt 3650) {
            Add-Check 'Security' 'Antivirus' 'Warn' 'Defender real-time protection on, but signatures have never updated'
        }
        else {
            $status = if ($null -ne $age -and [double]$age -gt $Settings.DefenderSignatureAgeDaysWarn) { 'Warn' } else { 'OK' }
            Add-Check 'Security' 'Antivirus' $status ("Defender real-time protection on, signatures $age day(s) old, tamper protection $tamper")
        }
    }

    # Firewall
    $firewall = @($Health.Firewall | Where-Object { $_ })
    if (-not $firewall.Count) {
        Add-Check 'Security' 'Firewall' 'Info' "Not checked: $($Health.FirewallError)"
    }
    else {
        $off = @($firewall | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
        if ($off.Count) { Add-Check 'Security' 'Firewall' 'Fail' ('OFF for the ' + ($off -join ', ') + ' profile') }
        else { Add-Check 'Security' 'Firewall' 'OK' ('On for all profiles (' + (($firewall | ForEach-Object { $_.Name }) -join ', ') + ')') }
    }

    # Updates
    $hotFix = $Health.LatestHotFix
    if ($hotFix -and $null -ne $hotFix.DaysSince) {
        $status = if ($hotFix.DaysSince -gt $Settings.PatchAgeDaysWarn) { 'Warn' } else { 'OK' }
        Add-Check 'Maintenance' 'Windows updates' $status ('Newest update {0} installed {1:yyyy-MM-dd} ({2} days ago)' -f $hotFix.HotFixId, [datetime]$hotFix.InstalledOn, $hotFix.DaysSince)
    }
    else {
        $why = if ($Health.HotFixError) { ": $($Health.HotFixError)" } else { '' }
        Add-Check 'Maintenance' 'Windows updates' 'Info' "Could not read update history$why"
    }
    if ($Health.UpdateScan -and $null -ne $Health.UpdateScan.DaysSinceSearch) {
        $scan = $Health.UpdateScan
        $status = if ($scan.DaysSinceSearch -gt $Settings.UpdateScanAgeDaysWarn) { 'Warn' } else { 'OK' }
        Add-Check 'Maintenance' 'Update scan' $status ('Windows Update last checked {0:yyyy-MM-dd HH:mm} ({1} days ago)' -f [datetime]$scan.LastSearch, $scan.DaysSinceSearch)
    }

    # Secure Boot
    if ($Health.SecureBoot -eq $true) {
        Add-Check 'Security' 'Secure Boot' 'OK' 'On'
    }
    elseif ($Health.SecureBoot -eq $false) {
        Add-Check 'Security' 'Secure Boot' 'Warn' 'Off (Windows 11 requires it)'
    }
    else {
        $why = if ($Health.SecureBootError) { $Health.SecureBootError } else { 'no data' }
        Add-Check 'Security' 'Secure Boot' 'Info' "Unknown: $why"
    }

    $results.ToArray()
}

function ConvertTo-ITHealthSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [object[]]$Checks = @(),

        [string]$ErrorMessage
    )

    $problems = @($Checks | Where-Object { $_.Status -in @('Fail', 'Warn') } | ForEach-Object { '{0} - {1}' -f $_.Check, $_.Detail })
    [pscustomobject]@{
        PSTypeName   = 'ITToolkit.HealthSummary'
        ComputerName = $ComputerName
        Reachable    = -not $ErrorMessage
        Fail         = @($Checks | Where-Object { $_.Status -eq 'Fail' }).Count
        Warn         = @($Checks | Where-Object { $_.Status -eq 'Warn' }).Count
        OK           = @($Checks | Where-Object { $_.Status -eq 'OK' }).Count
        Issues       = $(if ($ErrorMessage) { $ErrorMessage } else { $problems -join '; ' })
    }
}

function ConvertTo-ITPendingReboot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        $Reboot
    )

    $reasons = @($Reboot.Reasons | Where-Object { $_ })
    [pscustomobject]@{
        PSTypeName         = 'ITToolkit.PendingReboot'
        ComputerName       = $ComputerName
        RebootPending      = ($reasons.Count -gt 0)
        Reasons            = [string[]]$reasons
        PendingFileRenames = [int]$Reboot.PendingFileRenames
        LastBootTime       = $Reboot.LastBootTime
        UptimeDays         = $Reboot.UptimeDays
    }
}

function ConvertTo-ITNetworkCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        $Config,

        [object[]]$Tcp = @(),

        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [bool]$IsRemote,

        [AllowNull()]
        $ClockSkewSeconds,

        [datetime]$Now = (Get-Date)
    )

    $results = New-Object System.Collections.Generic.List[object]
    function Add-Check([string]$Check, [string]$Status, [string]$Detail) {
        $results.Add((New-ITCheckResult -ComputerName $ComputerName -Category 'Network' -Check $Check -Status $Status -Detail $Detail))
    }

    $vpnPattern = 'VPN|AnyConnect|GlobalProtect|Fortinet|FortiClient|WireGuard|TAP-Windows|Pulse Secure|Zscaler|NordLynx|Juniper|SonicWall|WatchGuard'
    $adapters = @($Config.Adapters | Where-Object { $_ })
    if (-not $adapters.Count) {
        $why = if (@($Config.Errors).Count) { ' (' + (@($Config.Errors) -join '; ') + ')' } else { '' }
        Add-Check 'Network adapters' 'Fail' "No connected network adapter$why"
    }
    foreach ($adapter in $adapters) {
        $ipv4 = @($adapter.IPv4 | Where-Object { $_ })
        $status = 'OK'
        if (-not $ipv4.Count) { $status = 'Warn'; $address = 'no IPv4 address' }
        elseif (@($ipv4 | Where-Object { $_ -like '169.254.*' }).Count) {
            $status = 'Fail'
            $address = ($ipv4 -join ', ') + ' (self-assigned: DHCP did not answer)'
        }
        else { $address = $ipv4 -join ', ' }

        $detail = $address
        $gateways = @($adapter.Gateways | Where-Object { $_ })
        if ($gateways.Count) { $detail += ', gateway ' + ($gateways -join ', ') }
        $dnsServers = @($adapter.DnsServers | Where-Object { $_ })
        if ($dnsServers.Count) { $detail += ', DNS ' + ($dnsServers -join ', ') }
        if ($adapter.NetworkName) { $detail += ", network '$($adapter.NetworkName)' ($($adapter.NetworkCategory))" }
        $name = "Adapter $($adapter.Alias)"
        if ([string]$adapter.Description -match $vpnPattern -or [string]$adapter.Alias -match $vpnPattern) { $name += ' [VPN]' }
        Add-Check $name $status $detail
    }

    foreach ($gateway in @($Config.Gateways | Where-Object { $_ })) {
        if ($gateway.Success) { Add-Check "Gateway $($gateway.Gateway)" 'OK' "Replied to ping in $($gateway.RoundtripMs) ms" }
        else { Add-Check "Gateway $($gateway.Gateway)" 'Warn' "No reply to ping ($($gateway.Status)); some gateways block ping" }
    }

    foreach ($lookup in @($Config.Dns | Where-Object { $_ })) {
        if ($lookup.Success) {
            $addresses = @($lookup.Addresses)
            $shown = ($addresses | Select-Object -First 3) -join ', '
            if ($addresses.Count -gt 3) { $shown += ", +$($addresses.Count - 3) more" }
            Add-Check "DNS $($lookup.Name)" 'OK' "Resolved to $shown in $($lookup.ElapsedMs) ms"
        }
        else {
            Add-Check "DNS $($lookup.Name)" 'Fail' "Lookup failed: $($lookup.Error)"
        }
    }

    foreach ($test in @($Tcp | Where-Object { $_ })) {
        $name = 'TCP {0}:{1}' -f $test.Host, $test.Port
        if ($test.Open) { Add-Check $name 'OK' "Connected in $($test.LatencyMs) ms" }
        else { Add-Check $name 'Fail' $test.Detail }
    }

    # Proxy
    $winHttp = ConvertFrom-ITWinHttpProxy -Lines $Config.WinHttpProxy
    $proxyParts = @()
    if ($winHttp) { $proxyParts += "WinHTTP: $winHttp" }
    if ($Config.UserProxy -and -not $IsRemote) {
        $userProxy = $Config.UserProxy
        if ($userProxy.AutoConfigUrl) { $proxyParts += "your user: PAC file $($userProxy.AutoConfigUrl)" }
        elseif ($userProxy.Enabled -and $userProxy.Server) { $proxyParts += "your user: $($userProxy.Server)" }
        else { $proxyParts += 'your user: Direct' }
    }
    if ($proxyParts.Count) { Add-Check 'Proxy' 'Info' ($proxyParts -join '; ') }

    # Time
    $time = ConvertFrom-ITW32tmStatus -Lines $Config.TimeStatus
    $timeWhy = 'Sign-in to Microsoft 365 and the domain fails when the clock drifts more than 5 minutes'
    if ($time.Error) {
        if ($time.Error -match 'denied') { Add-Check 'Time sync' 'Info' 'Not checked: run as administrator to read Windows Time status' }
        else { Add-Check 'Time sync' 'Warn' "Windows Time service: $($time.Error)" }
    }
    elseif (-not $time.Source) {
        Add-Check 'Time sync' 'Info' 'Could not read Windows Time status'
    }
    elseif ($time.Source -match 'Local CMOS Clock|Free-running') {
        Add-Check 'Time sync' 'Warn' "Not syncing with a time server (source: $($time.Source)). $timeWhy."
    }
    elseif ($time.LastSync) {
        $age = ($Now - $time.LastSync).TotalDays
        $status = if ($age -gt $Settings.TimeSyncAgeDaysWarn) { 'Warn' } else { 'OK' }
        Add-Check 'Time sync' $status ('Syncing from {0}, last sync {1:yyyy-MM-dd HH:mm}' -f $time.Source, $time.LastSync)
    }
    else {
        Add-Check 'Time sync' 'Warn' "Source is $($time.Source) but no successful sync is recorded ($($time.LastSyncText))"
    }

    if ($IsRemote -and $null -ne $ClockSkewSeconds) {
        $skew = [math]::Round([double]$ClockSkewSeconds, 0)
        $direction = if ($skew -ge 0) { 'ahead of' } else { 'behind' }
        $status = if ([math]::Abs($skew) -gt $Settings.ClockSkewSecondsWarn) { 'Warn' } else { 'OK' }
        Add-Check 'Clock' $status ('{0} s {1} this computer' -f [math]::Abs($skew), $direction)
    }

    $results.ToArray()
}

function ConvertTo-ITLocalAdmin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        $Member
    )

    $path = [string]$Member.AdsPath -replace '^WinNT://', ''
    $segments = @($path -split '/' | Where-Object { $_ })
    $domainPart = $null
    if ($segments.Count -ge 2) {
        $domainPart = $segments[-2]
        $name = '{0}\{1}' -f $segments[-2], $segments[-1]
    }
    elseif ($segments.Count -eq 1) { $name = $segments[0] }
    else { $name = $Member.Sid }

    $sid = [string]$Member.Sid
    $note = $null
    if ($sid -like 'S-1-12-1-*' -or $domainPart -eq 'AzureAD') {
        $source = 'Entra ID'
        if ($name -like 'S-1-*') { $note = 'Unresolved Entra ID object; usually the Global Administrator or Device Administrator role' }
    }
    elseif ($domainPart -and $domainPart -eq $Member.ComputerName) { $source = 'Local' }
    elseif ($sid -like 'S-1-5-21-*') {
        $source = 'Domain'
        if ($name -like 'S-1-*') { $note = 'Unresolved: deleted account, or no domain controller reachable' }
    }
    elseif ($sid -like 'S-1-5-*') { $source = 'Built-in' }
    else { $source = 'Unknown' }

    if ($sid -match '^S-1-5-21-.+-500$') {
        $note = 'Built-in Administrator account'
    }
    if (-not $name) { $name = '(unreadable member)' }
    if ($Member.PSObject.Properties['Error'] -and $Member.Error) {
        $note = "Could not read this member: $($Member.Error)"
    }

    [pscustomobject]@{
        PSTypeName   = 'ITToolkit.LocalAdmin'
        ComputerName = $ComputerName
        Name         = $name
        Class        = $Member.Class
        Source       = $source
        Sid          = $sid
        Note         = $note
    }
}

function ConvertTo-ITSoftware {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        $Entry
    )

    $installDate = $null
    if ([string]$Entry.InstallDate -match '^\d{8}$') {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact([string]$Entry.InstallDate, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            $installDate = $parsed
        }
    }

    [pscustomobject]@{
        PSTypeName           = 'ITToolkit.Software'
        ComputerName         = $ComputerName
        Name                 = $Entry.DisplayName
        Version              = $Entry.DisplayVersion
        Publisher            = $Entry.Publisher
        InstallDate          = $installDate
        Scope                = $Entry.Scope
        Architecture         = $Entry.Architecture
        UninstallString      = $Entry.UninstallString
        QuietUninstallString = $Entry.QuietUninstallString
        KeyName              = $Entry.KeyName
    }
}

function Get-ITEventLevelName {
    # Level names from the numeric level, so they do not depend on the display language.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        $Level,

        [AllowNull()]
        [string]$Fallback
    )

    switch ([int]$Level) {
        0 { return 'Information' }
        1 { return 'Critical' }
        2 { return 'Error' }
        3 { return 'Warning' }
        4 { return 'Information' }
        5 { return 'Verbose' }
    }
    return $Fallback
}

function Get-ITEventNote {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$ProviderName,
        [int]$Id
    )

    $exact = '{0}|{1}' -f $ProviderName, $Id
    if ($script:ITEventNotes.ContainsKey($exact)) { return $script:ITEventNotes[$exact] }
    $any = '{0}|*' -f $ProviderName
    if ($script:ITEventNotes.ContainsKey($any)) { return $script:ITEventNotes[$any] }
    return $null
}

function ConvertTo-ITEventGroup {
    # Groups events by log, source and Id. Explained events first, then the most frequent.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [AllowEmptyCollection()]
        [object[]]$Events = @()
    )

    $groups = @($Events | Where-Object { $_ } | Group-Object -Property LogName, ProviderName, Id)
    $rows = foreach ($group in $groups) {
        $items = @($group.Group | Sort-Object -Property TimeCreated -Descending)
        $latest = $items[0]
        [pscustomobject]@{
            PSTypeName   = 'ITToolkit.EventGroup'
            ComputerName = $ComputerName
            LogName      = $latest.LogName
            Source       = $latest.ProviderName
            Id           = $latest.Id
            Level        = Get-ITEventLevelName -Level $latest.Level -Fallback $latest.LevelName
            Count        = $items.Count
            FirstSeen    = $items[-1].TimeCreated
            LastSeen     = $latest.TimeCreated
            Note         = Get-ITEventNote -ProviderName $latest.ProviderName -Id $latest.Id
            Message      = Get-ITFirstLine -Text $latest.Message
        }
    }
    @($rows) | Sort-Object -Property @{ Expression = { [bool]$_.Note }; Descending = $true }, @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'LastSeen'; Descending = $true }
}

function ConvertTo-ITEventRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        $Record
    )

    [pscustomobject]@{
        PSTypeName   = 'ITToolkit.Event'
        ComputerName = $ComputerName
        TimeCreated  = $Record.TimeCreated
        LogName      = $Record.LogName
        Source       = $Record.ProviderName
        Id           = $Record.Id
        Level        = Get-ITEventLevelName -Level $Record.Level -Fallback $Record.LevelName
        Note         = Get-ITEventNote -ProviderName $Record.ProviderName -Id $Record.Id
        Message      = Get-ITFirstLine -Text $Record.Message -MaxLength 500
    }
}
