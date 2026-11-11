# Collectors gather raw facts on the target computer.
#
# A collector runs either in this session (local computer) or through Invoke-Command in a
# remoting session (remote computer), so each one must be self-contained:
#   - no calls to ITToolkit functions and no $script: variables (they do not exist remotely)
#   - Windows PowerShell 5.1 syntax and cmdlets
#   - catch its own errors and report them in the data instead of failing the whole run
# Decisions (OK/Warn/Fail) and wording belong in the ConvertTo-IT* functions, not here.
# tests\Module.Tests.ps1 enforces the first rule.

$script:ITCollectors = @{}

$script:ITCollectors['Clock'] = {
    [DateTime]::UtcNow
}

$script:ITCollectors['PendingReboot'] = {
    $reasons = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]

    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $reasons.Add('Windows servicing (CBS)')
    }
    if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $reasons.Add('Windows Update')
    }
    if (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\JoinDomain') {
        $reasons.Add('Domain join')
    }
    try {
        $active = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction Stop).ComputerName
        $pending = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction Stop).ComputerName
        if ($active -and $pending -and $active -ne $pending) { $reasons.Add("Computer rename ($active to $pending)") }
    }
    catch { $errors.Add("Computer name: $($_.Exception.Message)") }

    $renames = 0
    try {
        $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction Stop
        $renames = @($sessionManager.PendingFileRenameOperations | Where-Object { $_ }).Count
    }
    catch { $renames = 0 }   # the value is absent when nothing is pending

    try {
        $ccm = Invoke-CimMethod -Namespace 'root/ccm/ClientSDK' -ClassName 'CCM_ClientUtilities' -MethodName 'DetermineIfRebootPending' -ErrorAction Stop
        if ($ccm.RebootPending -or $ccm.IsHardRebootPending) { $reasons.Add('Configuration Manager client') }
    }
    catch { $null = $_ }   # no Configuration Manager client on this computer

    $lastBoot = $null
    $uptimeDays = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $lastBoot = $os.LastBootUpTime
        $uptimeDays = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
    }
    catch { $errors.Add("Last boot: $($_.Exception.Message)") }

    [pscustomobject]@{
        Reasons            = $reasons.ToArray()
        PendingFileRenames = $renames
        LastBootTime       = $lastBoot
        UptimeDays         = $uptimeDays
        Errors             = $errors.ToArray()
    }
}

$script:ITCollectors['DeviceHealth'] = {
    $errors = New-Object System.Collections.Generic.List[string]
    $data = [ordered]@{}

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $data.IsElevated = (New-Object System.Security.Principal.WindowsPrincipal($identity)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

    $data.OS = $null
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $data.OS = [pscustomobject]@{
            Caption        = $os.Caption
            Version        = $os.Version
            LastBootUpTime = $os.LastBootUpTime
            TotalMemoryKB  = [int64]$os.TotalVisibleMemorySize
            FreeMemoryKB   = [int64]$os.FreePhysicalMemory
            SystemDrive    = $os.SystemDrive
        }
    }
    catch { $errors.Add("Operating system: $($_.Exception.Message)") }

    $data.DisplayVersion = $null
    $data.Build = $null
    try {
        $currentVersion = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $data.DisplayVersion = $currentVersion.DisplayVersion
        if (-not $data.DisplayVersion) { $data.DisplayVersion = $currentVersion.ReleaseId }
        if ($currentVersion.CurrentBuild) { $data.Build = '{0}.{1}' -f $currentVersion.CurrentBuild, $currentVersion.UBR }
    }
    catch { $errors.Add("Windows version: $($_.Exception.Message)") }

    $data.System = $null
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $data.System = [pscustomobject]@{
            Manufacturer = $cs.Manufacturer
            Model        = $cs.Model
            UserName     = $cs.UserName
            Domain       = $cs.Domain
            PartOfDomain = [bool]$cs.PartOfDomain
        }
    }
    catch { $errors.Add("Computer system: $($_.Exception.Message)") }

    $data.SerialNumber = $null
    try { $data.SerialNumber = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber }
    catch { $errors.Add("BIOS: $($_.Exception.Message)") }

    $data.Disks = @()
    try {
        $data.Disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Drive     = $_.DeviceID
                    SizeBytes = [int64]$_.Size
                    FreeBytes = [int64]$_.FreeSpace
                }
            })
    }
    catch { $errors.Add("Disks: $($_.Exception.Message)") }

    $data.BitLocker = $null
    $data.BitLockerError = $null
    try {
        $data.BitLocker = @(Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Drive            = $_.DriveLetter
                    ProtectionStatus = [int]$_.ProtectionStatus
                }
            })
    }
    catch {
        $data.BitLocker = $null
        if ($_.Exception.Message -match 'namespace') { $data.BitLockerError = 'BitLocker is not available on this computer' }
        else { $data.BitLockerError = $_.Exception.Message }
    }

    $data.Defender = $null
    $data.DefenderError = $null
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $data.Defender = [pscustomobject]@{
            AMServiceEnabled          = $mp.AMServiceEnabled
            AntivirusEnabled          = $mp.AntivirusEnabled
            RealTimeProtectionEnabled = $mp.RealTimeProtectionEnabled
            AntivirusSignatureAge     = $mp.AntivirusSignatureAge
            AntivirusSignatureVersion = $mp.AntivirusSignatureVersion
            IsTamperProtected         = $mp.IsTamperProtected
            AMRunningMode             = $mp.AMRunningMode
        }
    }
    catch { $data.DefenderError = $_.Exception.Message }

    # Security Center only exists on client editions of Windows; servers skip this quietly.
    $data.AntivirusProducts = @()
    try {
        $data.AntivirusProducts = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName })
    }
    catch { $data.AntivirusProducts = @() }

    $data.Firewall = $null
    $data.FirewallError = $null
    try {
        # ActiveStore = the settings in effect, including Group Policy and Intune.
        $data.Firewall = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    Name    = [string]$_.Name
                    Enabled = ([string]$_.Enabled -eq 'True')
                }
            })
    }
    catch { $data.FirewallError = $_.Exception.Message }

    $data.LatestHotFix = $null
    $data.HotFixError = $null
    try {
        $hotFix = Get-HotFix -ErrorAction Stop |
            Where-Object { $_.InstalledOn } |
            Sort-Object -Property InstalledOn -Descending |
            Microsoft.PowerShell.Utility\Select-Object -First 1
        if ($hotFix) {
            $data.LatestHotFix = [pscustomobject]@{
                HotFixId    = $hotFix.HotFixID
                Description = $hotFix.Description
                InstalledOn = [datetime]$hotFix.InstalledOn
                DaysSince   = [int][math]::Floor(((Get-Date) - [datetime]$hotFix.InstalledOn).TotalDays)
            }
        }
    }
    catch { $data.HotFixError = $_.Exception.Message }

    $data.UpdateScan = $null
    try {
        $autoUpdate = New-Object -ComObject 'Microsoft.Update.AutoUpdate'
        $lastSearch = $autoUpdate.Results.LastSearchSuccessDate
        if ($lastSearch -and ([datetime]$lastSearch).Year -gt 2000) {
            $lastSearchUtc = [DateTime]::SpecifyKind([datetime]$lastSearch, [DateTimeKind]::Utc)
            $data.UpdateScan = [pscustomobject]@{
                LastSearch      = $lastSearchUtc.ToLocalTime()
                DaysSinceSearch = [int][math]::Floor(([DateTime]::UtcNow - $lastSearchUtc).TotalDays)
            }
        }
    }
    catch { $errors.Add("Windows Update: $($_.Exception.Message)") }

    # Read from the registry rather than Confirm-SecureBootUEFI, which needs administrator
    # rights. The key only exists on UEFI computers.
    $data.SecureBoot = $null
    $data.SecureBootError = $null
    try {
        $secureBootKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State'
        if (Test-Path -LiteralPath $secureBootKey) {
            $data.SecureBoot = ([int](Get-ItemProperty -LiteralPath $secureBootKey -ErrorAction Stop).UEFISecureBootEnabled -eq 1)
        }
        else {
            $data.SecureBootError = 'not supported on this computer (legacy BIOS boot)'
        }
    }
    catch { $data.SecureBootError = $_.Exception.Message }

    $data.Dsreg = @()
    $dsregPath = Join-Path $env:SystemRoot 'System32\dsregcmd.exe'
    if (Test-Path -LiteralPath $dsregPath) {
        try { $data.Dsreg = @(& $dsregPath /status 2>$null | ForEach-Object { [string]$_ }) }
        catch { $errors.Add("dsregcmd: $($_.Exception.Message)") }
    }

    $data.MdmEnrollments = @()
    try {
        $data.MdmEnrollments = @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop | ForEach-Object {
                $enrollment = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
                if ($enrollment -and $enrollment.ProviderID) {
                    [pscustomobject]@{ ProviderID = $enrollment.ProviderID; UPN = $enrollment.UPN }
                }
            })
    }
    catch { $data.MdmEnrollments = @() }

    $data.Errors = $errors.ToArray()
    [pscustomobject]$data
}

$script:ITCollectors['LocalAdmin'] = {
    # ADSI instead of Get-LocalGroupMember, which fails outright when the group holds an
    # orphaned SID or some Entra ID members.
    $groupSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $groupName = $groupSid.Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    $group = [ADSI]"WinNT://$env:COMPUTERNAME/$groupName,group"
    foreach ($member in @($group.psbase.Invoke('Members'))) {
        # Each lookup can fail on its own for orphaned or unresolvable members; one bad
        # member must not drop the rest of the list.
        $path = $null
        $class = $null
        $sid = $null
        $problem = $null
        $type = $member.GetType()
        try { $path = [string]$type.InvokeMember('ADsPath', 'GetProperty', $null, $member, $null) }
        catch { $problem = $_.Exception.Message }
        try { $class = [string]$type.InvokeMember('Class', 'GetProperty', $null, $member, $null) }
        catch { $class = $null }
        try {
            $sidBytes = $type.InvokeMember('objectSid', 'GetProperty', $null, $member, $null)
            $sid = (New-Object System.Security.Principal.SecurityIdentifier($sidBytes, 0)).Value
        }
        catch { $sid = $null }
        if (-not $sid -and $path) {
            # Unresolved members have the SID as their name. Otherwise ask the computer's own
            # LSA, which works over remoting without credential delegation.
            $segments = @(($path -replace '^WinNT://', '') -split '/' | Where-Object { $_ })
            if ($segments.Count -and $segments[-1] -match '^S-1-[\d-]+$') {
                $sid = $segments[-1]
            }
            elseif ($segments.Count -ge 2) {
                try { $sid = (New-Object System.Security.Principal.NTAccount($segments[-2], $segments[-1])).Translate([System.Security.Principal.SecurityIdentifier]).Value }
                catch { $sid = $null }
            }
        }
        [pscustomobject]@{
            AdsPath      = $path
            Class        = $class
            Sid          = $sid
            ComputerName = $env:COMPUTERNAME
            GroupName    = $groupName
            Error        = $problem
        }
    }
}

$script:ITCollectors['InstalledSoftware'] = {
    param([string]$NamePattern)

    if (-not $NamePattern) { $NamePattern = '*' }
    $sources = New-Object System.Collections.Generic.List[object]
    $machineArch = '32-bit'
    if ([Environment]::Is64BitOperatingSystem) { $machineArch = '64-bit' }
    $sources.Add(@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'Machine', $machineArch))
    if ([Environment]::Is64BitOperatingSystem) {
        $sources.Add(@('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'Machine', '32-bit'))
    }
    # Per-user installs (Teams, Zoom, some browsers) for every user whose profile is loaded.
    $userHives = @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-[\d-]+$' })
    foreach ($hive in $userHives) {
        $sid = $hive.PSChildName
        $account = $sid
        try { $account = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value }
        catch { $account = $sid }
        $sources.Add(@("Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Uninstall", "User $account", ''))
    }

    foreach ($source in $sources) {
        $path, $scope, $arch = $source
        foreach ($key in @(Get-ChildItem -LiteralPath $path -ErrorAction SilentlyContinue)) {
            $entry = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $entry -or -not $entry.DisplayName) { continue }
            if ($entry.SystemComponent -eq 1 -or $entry.ParentKeyName) { continue }   # hidden parts and updates of other products
            if ($entry.DisplayName -notlike $NamePattern) { continue }
            [pscustomobject]@{
                DisplayName          = [string]$entry.DisplayName
                DisplayVersion       = [string]$entry.DisplayVersion
                Publisher            = [string]$entry.Publisher
                InstallDate          = [string]$entry.InstallDate
                Scope                = $scope
                Architecture         = $arch
                UninstallString      = [string]$entry.UninstallString
                QuietUninstallString = [string]$entry.QuietUninstallString
                KeyName              = $key.PSChildName
            }
        }
    }
}

$script:ITCollectors['EventLog'] = {
    param([int]$Hours, [int]$MaxEvents)

    $start = (Get-Date).AddHours(-$Hours)
    $queries = @(
        @{ Label = 'System and Application errors'; Filter = @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = $start } },
        @{ Label = 'restart and shutdown events'; Filter = @{ LogName = 'System'; Id = 41, 1074, 6008; StartTime = $start } },
        @{ Label = 'hardware errors (WHEA)'; Filter = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $start } },
        @{ Label = 'disk warnings'; Filter = @{ LogName = 'System'; ProviderName = 'disk'; Level = 2, 3; StartTime = $start } }
    )
    $events = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    # Windows looks up event message text in the language of the current regional format.
    # Over remoting that is the tech's format, which this computer may have no message files
    # for (the messages come back empty), so read them in the language Windows was installed in.
    $savedCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InstalledUICulture
        foreach ($query in $queries) {
            $found = @()
            try {
                $found = @(Get-WinEvent -FilterHashtable $query.Filter -MaxEvents $MaxEvents -ErrorAction Stop)
            }
            catch {
                # "No events were found" is a normal, healthy answer. Anything else (service
                # stopped, access denied) must not look like a clean log.
                if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
                    $errors.Add(('{0}: {1}' -f $query.Label, $_.Exception.Message))
                }
            }
            foreach ($logEntry in $found) {
                $key = '{0}|{1}' -f $logEntry.LogName, $logEntry.RecordId
                if ($seen.ContainsKey($key)) { continue }
                $seen[$key] = $true
                $message = $null
                try { $message = $logEntry.Message } catch { $message = $null }
                if ($message -and $message.Length -gt 1000) { $message = $message.Substring(0, 1000) }
                $events.Add([pscustomobject]@{
                        TimeCreated  = $logEntry.TimeCreated
                        LogName      = $logEntry.LogName
                        ProviderName = $logEntry.ProviderName
                        Id           = $logEntry.Id
                        Level        = [int]$logEntry.Level
                        LevelName    = $logEntry.LevelDisplayName
                        Message      = $message
                    })
            }
        }
    }
    finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $savedCulture
    }

    [pscustomobject]@{
        Events = $events.ToArray()
        Errors = $errors.ToArray()
    }
}

$script:ITCollectors['LockoutEvents'] = {
    # Account lockout events (4740) from this domain controller's Security log, as XML so the
    # named fields can be read reliably by the converter.
    param([int]$Hours)

    $milliseconds = [int64]$Hours * 3600000
    $xpath = "*[System[(EventID=4740) and TimeCreated[timediff(@SystemTime) <= $milliseconds]]]"
    $events = @()
    $errors = @()
    try {
        $events = @(Get-WinEvent -LogName 'Security' -FilterXPath $xpath -MaxEvents 5000 -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ TimeCreated = $_.TimeCreated; Xml = $_.ToXml() }
            })
    }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
            $errors = @("could not read the Security log: $($_.Exception.Message)")
        }
    }
    [pscustomobject]@{ Events = $events; Errors = $errors }
}

$script:ITCollectors['LoggedOnUser'] = {
    $quser = Join-Path $env:SystemRoot 'System32\quser.exe'
    if (-not (Test-Path -LiteralPath $quser)) {
        return [pscustomobject]@{ Lines = @(); Error = 'quser.exe is not on this computer (Windows Home edition?)' }
    }
    # quser writes "No User exists for *" to stderr when nobody is signed in.
    try {
        $lines = @(& $quser 2>&1 | ForEach-Object { [string]$_ })
        [pscustomobject]@{ Lines = $lines; Error = $null }
    }
    catch {
        [pscustomobject]@{ Lines = @(); Error = "quser failed: $($_.Exception.Message)" }
    }
}

$script:ITCollectors['TempFiles'] = {
    param([string[]]$Folders, [int]$OlderThanDays, [bool]$Delete)

    $cutoff = (Get-Date).AddDays(-$OlderThanDays)
    if (-not $Folders) {
        $list = New-Object System.Collections.Generic.List[string]
        $list.Add((Join-Path $env:SystemRoot 'Temp'))
        try {
            foreach ($userProfile in @(Get-CimInstance -ClassName Win32_UserProfile -Filter 'Special=False' -ErrorAction Stop)) {
                if ($userProfile.LocalPath) { $list.Add((Join-Path $userProfile.LocalPath 'AppData\Local\Temp')) }
            }
        }
        catch { $null = $_ }
        $Folders = $list.ToArray()
    }

    foreach ($folder in $Folders) {
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) { continue }

        # Refuse the folder if it, or any folder above it, is a link or junction. A user can
        # point their own temp folder at a share without admin rights, and this runs as admin.
        $link = $null
        $current = New-Object System.IO.DirectoryInfo($folder)
        while ($current) {
            $current.Refresh()
            if ($current.Exists -and (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
                $link = $current.FullName
                break
            }
            $current = $current.Parent
        }
        if ($link) {
            [pscustomobject]@{
                Path           = $folder
                Files          = 0
                Bytes          = [int64]0
                Failed         = 0
                FoldersRemoved = 0
                Skipped        = "$link is a link or junction, so this folder was not touched"
            }
            continue
        }

        $files = 0
        $bytes = [int64]0
        $failed = 0
        $foldersRemoved = 0
        $directories = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
        $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
        $stack.Push((New-Object System.IO.DirectoryInfo($folder)))
        while ($stack.Count -gt 0) {
            $directory = $stack.Pop()
            # Check again just before reading, in case the folder was swapped for a junction
            # after it was found.
            $directory.Refresh()
            if (-not $directory.Exists -or (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) { continue }
            try { $entries = $directory.GetFileSystemInfos() }
            catch { $failed++; continue }
            foreach ($entry in $entries) {
                # Never follow links or junctions: they can point outside the temp folder.
                if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($entry -is [System.IO.DirectoryInfo]) {
                    $stack.Push($entry)
                    $directories.Add($entry)
                    continue
                }
                # Files extracted from a zip or installer keep their original (old) write time,
                # so a file only counts as old if it was also created before the cutoff.
                if ($entry.LastWriteTime -ge $cutoff -or $entry.CreationTime -ge $cutoff) { continue }
                if ($Delete) {
                    try {
                        $length = $entry.Length
                        if ($entry.IsReadOnly) { $entry.IsReadOnly = $false }
                        $entry.Delete()
                        $files++
                        $bytes += $length
                    }
                    catch { $failed++ }   # in use or access denied
                }
                else {
                    $files++
                    $bytes += $entry.Length
                }
            }
        }
        if ($Delete) {
            # Remove empty folders, deepest first. The times are the values read before anything
            # was deleted, so folders in recent use are left alone.
            for ($i = $directories.Count - 1; $i -ge 0; $i--) {
                $directory = $directories[$i]
                try {
                    if ($directory.LastWriteTime -lt $cutoff -and $directory.CreationTime -lt $cutoff -and
                        -not ($directory.EnumerateFileSystemInfos() | Microsoft.PowerShell.Utility\Select-Object -First 1)) {
                        $directory.Delete()
                        $foldersRemoved++
                    }
                }
                catch { $null = $_ }
            }
        }
        [pscustomobject]@{
            Path           = $folder
            Files          = $files
            Bytes          = $bytes
            Failed         = $failed
            FoldersRemoved = $foldersRemoved
            Skipped        = $null
        }
    }
}

$script:ITCollectors['NetworkConfig'] = {
    param([string[]]$DnsNames)

    $errors = New-Object System.Collections.Generic.List[string]

    $adapters = @()
    try {
        $adapters = @(Get-NetIPConfiguration -ErrorAction Stop |
                Where-Object { $_.NetAdapter -and [string]$_.NetAdapter.Status -eq 'Up' } |
                ForEach-Object {
                    $netProfile = $_.NetProfile
                    [pscustomobject]@{
                        Alias           = $_.InterfaceAlias
                        Description     = $_.InterfaceDescription
                        IPv4            = @($_.IPv4Address | ForEach-Object { '{0}/{1}' -f $_.IPAddress, $_.PrefixLength })
                        Gateways        = @($_.IPv4DefaultGateway | ForEach-Object { $_.NextHop })
                        DnsServers      = @($_.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses })
                        NetworkName     = $(if ($netProfile) { [string]$netProfile.Name } else { $null })
                        NetworkCategory = $(if ($netProfile) { [string]$netProfile.NetworkCategory } else { $null })
                    }
                })
    }
    catch { $errors.Add("Adapters: $($_.Exception.Message)") }

    $gateways = @($adapters | ForEach-Object { $_.Gateways } | Where-Object { $_ } | Microsoft.PowerShell.Utility\Select-Object -Unique)
    $gatewayResults = @(foreach ($gateway in $gateways) {
            $reply = $null
            $failure = $null
            try { $reply = (New-Object System.Net.NetworkInformation.Ping).Send($gateway, 1000) }
            catch { $failure = $_.Exception.Message }
            [pscustomobject]@{
                Gateway     = $gateway
                Success     = [bool]($reply -and [string]$reply.Status -eq 'Success')
                RoundtripMs = $(if ($reply) { [int]$reply.RoundtripTime } else { $null })
                Status      = $(if ($reply) { [string]$reply.Status } else { $failure })
            }
        })

    $hasResolveDnsName = [bool](Microsoft.PowerShell.Core\Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue)
    $dnsResults = @(foreach ($name in @($DnsNames | Where-Object { $_ })) {
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                if ($hasResolveDnsName) {
                    $addresses = @(Resolve-DnsName -Name $name -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
                }
                else {
                    $addresses = @([System.Net.Dns]::GetHostAddresses($name) | ForEach-Object { $_.IPAddressToString })
                }
                $timer.Stop()
                [pscustomobject]@{ Name = $name; Success = ($addresses.Count -gt 0); Addresses = $addresses; ElapsedMs = [int]$timer.ElapsedMilliseconds; Error = $null }
            }
            catch {
                $timer.Stop()
                [pscustomobject]@{ Name = $name; Success = $false; Addresses = @(); ElapsedMs = [int]$timer.ElapsedMilliseconds; Error = $_.Exception.Message }
            }
        })

    $winHttpProxy = @()
    try { $winHttpProxy = @(& (Join-Path $env:SystemRoot 'System32\netsh.exe') winhttp show proxy 2>&1 | ForEach-Object { [string]$_ }) }
    catch { $errors.Add("WinHTTP proxy: $($_.Exception.Message)") }

    $userProxy = $null
    try {
        $internetSettings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        $userProxy = [pscustomobject]@{
            Enabled       = [bool]$internetSettings.ProxyEnable
            Server        = [string]$internetSettings.ProxyServer
            AutoConfigUrl = [string]$internetSettings.AutoConfigURL
        }
    }
    catch { $userProxy = $null }

    $timeStatus = @()
    try { $timeStatus = @(& (Join-Path $env:SystemRoot 'System32\w32tm.exe') /query /status 2>&1 | ForEach-Object { [string]$_ }) }
    catch { $errors.Add("Windows Time: $($_.Exception.Message)") }

    [pscustomobject]@{
        Adapters     = $adapters
        Gateways     = $gatewayResults
        Dns          = $dnsResults
        WinHttpProxy = $winHttpProxy
        UserProxy    = $userProxy
        TimeStatus   = $timeStatus
        Errors       = $errors.ToArray()
    }
}

$script:ITCollectors['TcpTest'] = {
    # Targets are 'host|port' strings. Works on any OS (no Windows-only calls), so it is
    # also what the tests use to check Test-ITPort.
    param([string[]]$Targets, [int]$TimeoutMs)

    foreach ($target in $Targets) {
        $hostName, $portText = $target -split '\|', 2
        $hostName = $hostName.Trim([char[]]'[]')
        $port = [int]$portText
        $open = $false
        $latency = $null
        $detail = $null

        # Resolve first, then connect to each address with a socket of the same family:
        # a plain TcpClient in Windows PowerShell 5.1 only speaks IPv4. IPv4 addresses are
        # tried first; at most 4 addresses are tried.
        $addresses = @()
        $literal = $null
        if ([System.Net.IPAddress]::TryParse($hostName, [ref]$literal)) {
            $addresses = @($literal)
        }
        else {
            try {
                $lookup = [System.Net.Dns]::BeginGetHostAddresses($hostName, $null, $null)
                if ($lookup.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                    $addresses = @([System.Net.Dns]::EndGetHostAddresses($lookup) |
                            Sort-Object -Property @{ Expression = { $_.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork } } |
                            Microsoft.PowerShell.Utility\Select-Object -First 4)
                    if (-not $addresses.Count) { $detail = 'DNS lookup failed: no address for this name' }
                }
                else {
                    $detail = "DNS lookup did not answer within $TimeoutMs ms"
                }
            }
            catch {
                $exception = $_.Exception
                while ($exception.InnerException) { $exception = $exception.InnerException }
                $detail = "DNS lookup failed: $($exception.Message)"
            }
        }

        foreach ($address in $addresses) {
            $client = $null
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                # Inside the try: on a computer without IPv6 even creating the socket fails.
                $client = New-Object System.Net.Sockets.TcpClient($address.AddressFamily)
                $async = $client.BeginConnect($address, $port, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
                    $client.EndConnect($async)
                    $open = $true
                    $latency = [int]$timer.ElapsedMilliseconds
                    $detail = "Connected to $address"
                }
                else {
                    $detail = "No answer within $TimeoutMs ms (blocked by a firewall, or the host is off)"
                }
            }
            catch {
                $exception = $_.Exception
                while ($exception.InnerException) { $exception = $exception.InnerException }
                $code = $null
                if ($exception -is [System.Net.Sockets.SocketException]) { $code = [string]$exception.SocketErrorCode }
                switch ($code) {
                    'ConnectionRefused' { $detail = 'Refused: the host is up but nothing is listening on this port' }
                    'TimedOut' { $detail = 'Timed out' }
                    'NetworkUnreachable' { $detail = "Network unreachable from this computer ($address)" }
                    'HostUnreachable' { $detail = "Host unreachable from this computer ($address)" }
                    'AddressFamilyNotSupported' { $detail = "This computer cannot use $($address.AddressFamily) addresses" }
                    default { $detail = $exception.Message }
                }
            }
            finally {
                $timer.Stop()
                if ($client) { $client.Close() }
            }
            if ($open) { break }
        }

        [pscustomobject]@{
            Host      = $hostName
            Port      = $port
            Open      = $open
            LatencyMs = $latency
            Detail    = $detail
        }
    }
}
