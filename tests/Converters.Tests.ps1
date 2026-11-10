#Requires -Modules Pester
# The OK/Warn/Fail rules, tested with raw data shaped like the collectors' output.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ITToolkit\ITToolkit.psd1') -Force

    function New-TestHealth {
        # A healthy, Entra joined and Intune enrolled laptop. Tests change one thing at a time.
        [pscustomobject]@{
            IsElevated        = $true
            OS                = [pscustomobject]@{ Caption = 'Microsoft Windows 11 Enterprise'; Version = '10.0.26100'; LastBootUpTime = (Get-Date).AddDays(-2); TotalMemoryKB = 16GB / 1KB; FreeMemoryKB = 6GB / 1KB; SystemDrive = 'C:' }
            DisplayVersion    = '24H2'
            Build             = '26100.2314'
            System            = [pscustomobject]@{ Manufacturer = 'Dell Inc.'; Model = 'Latitude 7450'; UserName = 'AzureAD\JordanLee'; Domain = 'WORKGROUP'; PartOfDomain = $false }
            SerialNumber      = 'ABC1234'
            Disks             = @([pscustomobject]@{ Drive = 'C:'; SizeBytes = 512GB; FreeBytes = 200GB })
            BitLocker         = @([pscustomobject]@{ Drive = 'C:'; ProtectionStatus = 1 }, [pscustomobject]@{ Drive = $null; ProtectionStatus = 0 })
            BitLockerError    = $null
            Defender          = [pscustomobject]@{ AMServiceEnabled = $true; AntivirusEnabled = $true; RealTimeProtectionEnabled = $true; AntivirusSignatureAge = 0; AntivirusSignatureVersion = '1.421.0.0'; IsTamperProtected = $true; AMRunningMode = 'Normal' }
            DefenderError     = $null
            AntivirusProducts = @('Windows Defender')
            Firewall          = @('Domain', 'Private', 'Public' | ForEach-Object { [pscustomobject]@{ Name = $_; Enabled = $true } })
            FirewallError     = $null
            LatestHotFix      = [pscustomobject]@{ HotFixId = 'KB5044284'; Description = 'Security Update'; InstalledOn = (Get-Date).AddDays(-12).Date; DaysSince = 12 }
            HotFixError       = $null
            UpdateScan        = [pscustomobject]@{ LastSearch = (Get-Date).AddHours(-5); DaysSinceSearch = 0 }
            SecureBoot        = $true
            SecureBootError   = $null
            Dsreg             = @('             AzureAdJoined : YES', '              DomainJoined : NO', '                TenantName : Example Corp')
            MdmEnrollments    = @([pscustomobject]@{ ProviderID = 'MS DM Server'; UPN = 'jordan.lee@example.com' })
            Errors            = @()
        }
    }

    function New-TestReboot {
        [pscustomobject]@{ Reasons = @(); PendingFileRenames = 0; LastBootTime = (Get-Date).AddDays(-2); UptimeDays = 2.0; Errors = @() }
    }

    function Invoke-HealthCheck($Health, $Reboot = (New-TestReboot)) {
        $settings = InModuleScope ITToolkit { (Get-ITSettings).Health }
        InModuleScope ITToolkit -Parameters @{ Health = $Health; Reboot = $Reboot; Settings = $settings } {
            param($Health, $Reboot, $Settings)
            ConvertTo-ITHealthCheck -ComputerName 'PC0142' -Health $Health -Reboot $Reboot -Settings $Settings
        }
    }

    function Get-Check($Results, $Name) {
        @($Results | Where-Object { $_.Check -eq $Name }) | Select-Object -First 1
    }
}

Describe 'ConvertTo-ITHealthCheck' {
    It 'rates a healthy computer with no Fail or Warn' {
        $results = @(Invoke-HealthCheck (New-TestHealth))
        @($results | Where-Object { $_.Status -in 'Fail', 'Warn' }) | Should -BeNullOrEmpty
        $results[0].PSObject.TypeNames[0] | Should -Be 'ITToolkit.CheckResult'
        @($results | ForEach-Object { $_.ComputerName } | Select-Object -Unique) | Should -Be @('PC0142')
    }

    It 'describes the system and device join' {
        $results = @(Invoke-HealthCheck (New-TestHealth))
        (Get-Check $results 'System').Detail | Should -Be 'Dell Inc. Latitude 7450, serial ABC1234, Windows 11 Enterprise 24H2 (build 26100.2314)'
        (Get-Check $results 'Device join').Detail | Should -Be 'Entra joined (tenant Example Corp); Intune enrolled (jordan.lee@example.com)'
        (Get-Check $results 'Signed-in user').Detail | Should -Be 'AzureAD\JordanLee'
    }

    It 'reports hybrid and domain joins' {
        $health = New-TestHealth
        $health.Dsreg = @('AzureAdJoined : YES', 'DomainJoined : YES', 'DomainName : CORP', 'TenantName : Example Corp')
        $health.MdmEnrollments = @()
        (Get-Check (Invoke-HealthCheck $health) 'Device join').Detail | Should -Be 'Hybrid joined (domain CORP, tenant Example Corp); no Intune enrollment found'

        $health.Dsreg = @()
        $health.System.PartOfDomain = $true
        $health.System.Domain = 'corp.example.com'
        (Get-Check (Invoke-HealthCheck $health) 'Device join').Detail | Should -Be 'Domain joined (corp.example.com)'
    }

    It 'warns when the computer is not joined to anything' {
        $health = New-TestHealth
        $health.Dsreg = @('AzureAdJoined : NO', 'DomainJoined : NO')
        $health.MdmEnrollments = @()
        (Get-Check (Invoke-HealthCheck $health) 'Device join').Status | Should -Be 'Warn'
    }

    It 'rates the system drive <Status> with <Free> GB free of <Size> GB' -ForEach @(
        @{ Size = 100; Free = 3; Status = 'Fail' }    # 3%: under both limits
        @{ Size = 100; Free = 10; Status = 'Warn' }   # 10%: under the warn limits only
        @{ Size = 100; Free = 60; Status = 'OK' }
        @{ Size = 40; Free = 4; Status = 'Fail' }     # 10% would only warn, but under 5 GB fails
        @{ Size = 60; Free = 12; Status = 'Warn' }    # 20% is fine, but under 15 GB warns
    ) {
        $health = New-TestHealth
        $health.Disks = @([pscustomobject]@{ Drive = 'C:'; SizeBytes = [int64]($Size * 1GB); FreeBytes = [int64]($Free * 1GB) })
        (Get-Check (Invoke-HealthCheck $health) 'Disk C:').Status | Should -Be $Status
    }

    It 'rates data drives by percentage only' {
        $health = New-TestHealth
        $health.Disks = @(
            [pscustomobject]@{ Drive = 'C:'; SizeBytes = 512GB; FreeBytes = 200GB }
            [pscustomobject]@{ Drive = 'D:'; SizeBytes = 20GB; FreeBytes = 8GB }    # 40% free, under the GB limits
            [pscustomobject]@{ Drive = 'E:'; SizeBytes = 2TB; FreeBytes = 100GB }   # 5% free
        )
        $results = Invoke-HealthCheck $health
        (Get-Check $results 'Disk D:').Status | Should -Be 'OK'
        (Get-Check $results 'Disk E:').Status | Should -Be 'Fail'
        (Get-Check $results 'Disk E:').Detail | Should -Match '^100\.0 GB free of 2\.0 TB \(5%\)$'
    }

    It 'warns on long uptime and pending restarts' {
        $reboot = New-TestReboot
        $reboot.UptimeDays = 30.4
        $reboot.Reasons = @('Windows Update', 'Windows servicing (CBS)')
        $results = Invoke-HealthCheck (New-TestHealth) $reboot
        (Get-Check $results 'Uptime').Status | Should -Be 'Warn'
        (Get-Check $results 'Pending reboot').Status | Should -Be 'Warn'
        (Get-Check $results 'Pending reboot').Detail | Should -Be 'Restart needed: Windows Update, Windows servicing (CBS)'
    }

    It 'does not treat pending file renames alone as a restart' {
        $reboot = New-TestReboot
        $reboot.PendingFileRenames = 6
        $check = Get-Check (Invoke-HealthCheck (New-TestHealth) $reboot) 'Pending reboot'
        $check.Status | Should -Be 'OK'
        $check.Detail | Should -Match '6 pending file rename'
    }

    It 'fails BitLocker off on the system drive and warns on a data drive' {
        $health = New-TestHealth
        $health.Disks = @([pscustomobject]@{ Drive = 'C:'; SizeBytes = 512GB; FreeBytes = 200GB }, [pscustomobject]@{ Drive = 'D:'; SizeBytes = 1TB; FreeBytes = 500GB })
        $health.BitLocker = @([pscustomobject]@{ Drive = 'C:'; ProtectionStatus = 1 }, [pscustomobject]@{ Drive = 'D:'; ProtectionStatus = 0 })
        $check = Get-Check (Invoke-HealthCheck $health) 'BitLocker'
        $check.Status | Should -Be 'Warn'
        $check.Detail | Should -Be 'C: on, D: OFF'

        $health.BitLocker[0].ProtectionStatus = 0
        (Get-Check (Invoke-HealthCheck $health) 'BitLocker').Status | Should -Be 'Fail'
    }

    It 'explains a BitLocker check skipped because the session is not elevated' {
        $health = New-TestHealth
        $health.IsElevated = $false
        $health.BitLocker = $null
        $health.BitLockerError = 'Access denied'
        $check = Get-Check (Invoke-HealthCheck $health) 'BitLocker'
        $check.Status | Should -Be 'Info'
        $check.Detail | Should -Be 'Not checked: run as administrator to read BitLocker status'
    }

    It 'reports Secure Boot as unknown on legacy BIOS computers' {
        $health = New-TestHealth
        $health.SecureBoot = $null
        $health.SecureBootError = 'not supported on this computer (legacy BIOS boot)'
        $check = Get-Check (Invoke-HealthCheck $health) 'Secure Boot'
        $check.Status | Should -Be 'Info'
        $check.Detail | Should -Be 'Unknown: not supported on this computer (legacy BIOS boot)'
    }

    It 'fails when Defender real-time protection is off' {
        $health = New-TestHealth
        $health.Defender.RealTimeProtectionEnabled = $false
        (Get-Check (Invoke-HealthCheck $health) 'Antivirus').Status | Should -Be 'Fail'
    }

    It 'warns on old Defender signatures' {
        $health = New-TestHealth
        $health.Defender.AntivirusSignatureAge = 9
        (Get-Check (Invoke-HealthCheck $health) 'Antivirus').Status | Should -Be 'Warn'
    }

    It 'accepts another antivirus when Defender is passive' {
        $health = New-TestHealth
        $health.Defender.AMRunningMode = 'Passive Mode'
        $health.AntivirusProducts = @('Windows Defender', 'CrowdStrike Falcon Sensor')
        $check = Get-Check (Invoke-HealthCheck $health) 'Antivirus'
        $check.Status | Should -Be 'Info'
        $check.Detail | Should -Match 'CrowdStrike'
    }

    It 'accepts another antivirus when Defender is switched off (Not running)' {
        $health = New-TestHealth
        $health.Defender.AMRunningMode = 'Not running'
        $health.Defender.RealTimeProtectionEnabled = $false
        $health.Defender.AntivirusEnabled = $false
        $health.AntivirusProducts = @('Windows Defender', 'Sophos Anti-Virus')
        $check = Get-Check (Invoke-HealthCheck $health) 'Antivirus'
        $check.Status | Should -Be 'Info'
        $check.Detail | Should -Be "Defender is in 'Not running' mode; active antivirus: Sophos Anti-Virus"
    }

    It 'warns when Defender is passive and nothing else is protecting the computer' {
        $health = New-TestHealth
        $health.Defender.AMRunningMode = 'Passive Mode'
        (Get-Check (Invoke-HealthCheck $health) 'Antivirus').Status | Should -Be 'Warn'
    }

    It 'fails a firewall profile that is off' {
        $health = New-TestHealth
        $health.Firewall[2].Enabled = $false
        $check = Get-Check (Invoke-HealthCheck $health) 'Firewall'
        $check.Status | Should -Be 'Fail'
        $check.Detail | Should -Be 'OFF for the Public profile'
    }

    It 'warns when updates are old or Windows Update stopped checking' {
        $health = New-TestHealth
        $health.LatestHotFix.DaysSince = 75
        $health.UpdateScan.DaysSinceSearch = 20
        $results = Invoke-HealthCheck $health
        (Get-Check $results 'Windows updates').Status | Should -Be 'Warn'
        (Get-Check $results 'Update scan').Status | Should -Be 'Warn'
    }

    It 'warns when Secure Boot is off' {
        $health = New-TestHealth
        $health.SecureBoot = $false
        (Get-Check (Invoke-HealthCheck $health) 'Secure Boot').Status | Should -Be 'Warn'
    }

    It 'survives a collector that returned almost nothing' {
        $empty = [pscustomobject]@{ IsElevated = $false; OS = $null; System = $null; Disks = @(); BitLocker = $null; Defender = $null; AntivirusProducts = @(); Firewall = $null; LatestHotFix = $null; UpdateScan = $null; SecureBoot = $null; Dsreg = @(); MdmEnrollments = @(); Errors = @('everything failed') }
        { Invoke-HealthCheck $empty $null } | Should -Not -Throw
        @(Invoke-HealthCheck $empty $null).Count | Should -BeGreaterThan 0
    }
}

Describe 'ConvertTo-ITHealthSummary' {
    It 'counts results and lists the problems' {
        InModuleScope ITToolkit {
            $checks = @(
                New-ITCheckResult -ComputerName 'PC1' -Check 'BitLocker' -Status 'Fail' -Detail 'C: OFF'
                New-ITCheckResult -ComputerName 'PC1' -Check 'Uptime' -Status 'Warn' -Detail '20 days'
                New-ITCheckResult -ComputerName 'PC1' -Check 'Firewall' -Status 'OK' -Detail 'On'
            )
            $summary = ConvertTo-ITHealthSummary -ComputerName 'PC1' -Checks $checks
            $summary.Reachable | Should -BeTrue
            $summary.Fail | Should -Be 1
            $summary.Warn | Should -Be 1
            $summary.OK | Should -Be 1
            $summary.Issues | Should -Be 'BitLocker - C: OFF; Uptime - 20 days'
        }
    }

    It 'marks unreachable computers' {
        InModuleScope ITToolkit {
            $summary = ConvertTo-ITHealthSummary -ComputerName 'PC2' -ErrorMessage 'WinRM cannot complete the operation'
            $summary.Reachable | Should -BeFalse
            $summary.Issues | Should -Be 'WinRM cannot complete the operation'
        }
    }
}

Describe 'ConvertTo-ITNetworkCheck' {
    BeforeAll {
        function New-TestNetwork {
            [pscustomobject]@{
                Adapters     = @([pscustomobject]@{ Alias = 'Ethernet'; Description = 'Intel(R) Ethernet Connection'; IPv4 = @('10.1.2.34/24'); Gateways = @('10.1.2.1'); DnsServers = @('10.1.0.10', '10.1.0.11'); NetworkName = 'corp.example.com'; NetworkCategory = 'DomainAuthenticated' })
                Gateways     = @([pscustomobject]@{ Gateway = '10.1.2.1'; Success = $true; RoundtripMs = 1; Status = 'Success' })
                Dns          = @([pscustomobject]@{ Name = 'login.microsoftonline.com'; Success = $true; Addresses = @('20.190.1.1', '20.190.1.2', '20.190.1.3', '20.190.1.4'); ElapsedMs = 12; Error = $null })
                WinHttpProxy = @('    Direct access (no proxy server).')
                UserProxy    = [pscustomobject]@{ Enabled = $false; Server = ''; AutoConfigUrl = '' }
                TimeStatus   = @('Source: dc01.corp.example.com', ('Last Successful Sync Time: {0}' -f (Get-Date).AddHours(-1).ToString()))
                Errors       = @()
            }
        }

        function Invoke-NetworkCheck($Config, $Tcp = @(), [bool]$IsRemote = $false, $Skew = $null) {
            $settings = InModuleScope ITToolkit { (Get-ITSettings).Network }
            InModuleScope ITToolkit -Parameters @{ Config = $Config; Tcp = $Tcp; Settings = $settings; IsRemote = $IsRemote; Skew = $Skew } {
                param($Config, $Tcp, $Settings, $IsRemote, $Skew)
                ConvertTo-ITNetworkCheck -ComputerName 'PC0142' -Config $Config -Tcp $Tcp -Settings $Settings -IsRemote $IsRemote -ClockSkewSeconds $Skew
            }
        }
    }

    It 'rates a healthy network with no Fail or Warn' {
        $tcp = @([pscustomobject]@{ Host = 'login.microsoftonline.com'; Port = 443; Open = $true; LatencyMs = 25; Detail = 'Connected' })
        $results = @(Invoke-NetworkCheck (New-TestNetwork) $tcp)
        @($results | Where-Object { $_.Status -in 'Fail', 'Warn' }) | Should -BeNullOrEmpty
        (Get-Check $results 'Adapter Ethernet').Detail | Should -Be "10.1.2.34/24, gateway 10.1.2.1, DNS 10.1.0.10, 10.1.0.11, network 'corp.example.com' (DomainAuthenticated)"
        (Get-Check $results 'DNS login.microsoftonline.com').Detail | Should -Be 'Resolved to 20.190.1.1, 20.190.1.2, 20.190.1.3, +1 more in 12 ms'
        (Get-Check $results 'Proxy').Detail | Should -Be 'WinHTTP: Direct; your user: Direct'
        (Get-Check $results 'Time sync').Status | Should -Be 'OK'
        @($results | Where-Object { $_.Category -ne 'Network' }) | Should -BeNullOrEmpty
    }

    It 'fails a self-assigned (APIPA) address' {
        $config = New-TestNetwork
        $config.Adapters[0].IPv4 = @('169.254.10.20/16')
        $check = Get-Check (Invoke-NetworkCheck $config) 'Adapter Ethernet'
        $check.Status | Should -Be 'Fail'
        $check.Detail | Should -Match 'DHCP did not answer'
    }

    It 'fails when there is no connected adapter' {
        $config = New-TestNetwork
        $config.Adapters = @()
        $config.Gateways = @()
        (Get-Check (Invoke-NetworkCheck $config) 'Network adapters').Status | Should -Be 'Fail'
    }

    It 'labels VPN adapters' {
        $config = New-TestNetwork
        $config.Adapters += [pscustomobject]@{ Alias = 'Ethernet 3'; Description = 'Cisco AnyConnect Secure Mobility Client Virtual Miniport Adapter'; IPv4 = @('10.200.0.5/32'); Gateways = @(); DnsServers = @('10.1.0.10'); NetworkName = $null; NetworkCategory = $null }
        @(Invoke-NetworkCheck $config | Where-Object { $_.Check -eq 'Adapter Ethernet 3 [VPN]' }).Count | Should -Be 1
    }

    It 'fails DNS lookups and TCP connections that do not work' {
        $config = New-TestNetwork
        $config.Dns = @([pscustomobject]@{ Name = 'fs01.corp.example.com'; Success = $false; Addresses = @(); ElapsedMs = 2000; Error = 'DNS name does not exist' })
        $tcp = @([pscustomobject]@{ Host = 'fs01'; Port = 445; Open = $false; LatencyMs = $null; Detail = 'No answer within 3000 ms' })
        $results = Invoke-NetworkCheck $config $tcp
        (Get-Check $results 'DNS fs01.corp.example.com').Status | Should -Be 'Fail'
        (Get-Check $results 'TCP fs01:445').Status | Should -Be 'Fail'
        (Get-Check $results 'TCP fs01:445').Detail | Should -Be 'No answer within 3000 ms'
    }

    It 'warns when Windows Time is not syncing' {
        $config = New-TestNetwork
        $config.TimeStatus = @('Source: Local CMOS Clock', 'Last Successful Sync Time: unspecified')
        (Get-Check (Invoke-NetworkCheck $config) 'Time sync').Status | Should -Be 'Warn'
    }

    It 'shows clock skew for remote computers only, without the remote session user proxy' {
        $results = Invoke-NetworkCheck (New-TestNetwork) @() $true -300
        (Get-Check $results 'Clock').Status | Should -Be 'Warn'
        (Get-Check $results 'Clock').Detail | Should -Be '300 s behind this computer'
        (Get-Check $results 'Proxy').Detail | Should -Be 'WinHTTP: Direct'
        Get-Check (Invoke-NetworkCheck (New-TestNetwork) @() $false 300) 'Clock' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-ITLocalAdmin' {
    It 'labels <Expected> members' -ForEach @(
        @{ Path = 'WinNT://PC0142/Administrator'; Sid = 'S-1-5-21-1-2-3-500'; Expected = 'Local'; Name = 'PC0142\Administrator'; Note = 'Built-in Administrator account' }
        @{ Path = 'WinNT://WORKGROUP/PC0142/helpdesk'; Sid = 'S-1-5-21-1-2-3-1001'; Expected = 'Local'; Name = 'PC0142\helpdesk'; Note = $null }
        @{ Path = 'WinNT://CORP/Domain Admins'; Sid = 'S-1-5-21-9-8-7-512'; Expected = 'Domain'; Name = 'CORP\Domain Admins'; Note = $null }
        @{ Path = 'WinNT://S-1-12-1-111-222-333-444'; Sid = 'S-1-12-1-111-222-333-444'; Expected = 'Entra ID'; Name = 'S-1-12-1-111-222-333-444'; Note = 'Unresolved Entra ID object; usually the Global Administrator or Device Administrator role' }
        @{ Path = 'WinNT://AzureAD/JordanLee'; Sid = 'S-1-12-1-5-6-7-8'; Expected = 'Entra ID'; Name = 'AzureAD\JordanLee'; Note = $null }
        @{ Path = 'WinNT://S-1-5-21-9-8-7-1234'; Sid = 'S-1-5-21-9-8-7-1234'; Expected = 'Domain'; Name = 'S-1-5-21-9-8-7-1234'; Note = 'Unresolved: deleted account, or no domain controller reachable' }
    ) {
        $member = [pscustomobject]@{ AdsPath = $Path; Class = 'User'; Sid = $Sid; ComputerName = 'PC0142'; GroupName = 'Administrators' }
        $result = InModuleScope ITToolkit -Parameters @{ Member = $member } { param($Member) ConvertTo-ITLocalAdmin -ComputerName 'PC0142' -Member $Member }
        $result.Source | Should -Be $Expected
        $result.Name | Should -Be $Name
        $result.Note | Should -Be $Note
    }
}

Describe 'ConvertTo-ITLocalAdmin errors' {
    It 'keeps a member it could not fully read, with the reason' {
        $member = [pscustomobject]@{ AdsPath = $null; Class = $null; Sid = $null; ComputerName = 'PC0142'; GroupName = 'Administrators'; Error = 'The network path was not found.' }
        $result = InModuleScope ITToolkit -Parameters @{ Member = $member } { param($Member) ConvertTo-ITLocalAdmin -ComputerName 'PC0142' -Member $Member }
        $result.Name | Should -Be '(unreadable member)'
        $result.Note | Should -Be 'Could not read this member: The network path was not found.'
    }
}

Describe 'Get-ITEventLevelName' {
    It 'names level <Level> <Expected> whatever the display language' -ForEach @(
        @{ Level = 1; Expected = 'Critical' }
        @{ Level = 2; Expected = 'Error' }
        @{ Level = 3; Expected = 'Warning' }
        @{ Level = 4; Expected = 'Information' }
        @{ Level = 0; Expected = 'Information' }
    ) {
        InModuleScope ITToolkit -Parameters @{ Level = $Level } { param($Level) Get-ITEventLevelName -Level $Level -Fallback 'Fehler' } | Should -Be $Expected
    }
}

Describe 'ConvertTo-ITSoftware' {
    It 'parses yyyyMMdd install dates and ignores bad ones' {
        InModuleScope ITToolkit {
            $entry = [pscustomobject]@{ DisplayName = '7-Zip 24.08 (x64)'; DisplayVersion = '24.08'; Publisher = 'Igor Pavlov'; InstallDate = '20260915'; Scope = 'Machine'; Architecture = '64-bit'; UninstallString = 'x'; QuietUninstallString = ''; KeyName = '7-Zip' }
            (ConvertTo-ITSoftware -ComputerName 'PC1' -Entry $entry).InstallDate | Should -Be ([datetime]'2026-09-15')
            $entry.InstallDate = '15/09/2026'
            (ConvertTo-ITSoftware -ComputerName 'PC1' -Entry $entry).InstallDate | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-ITEventGroup' {
    It 'groups by source and Id, explained events first' {
        InModuleScope ITToolkit {
            $now = Get-Date
            $events = @(
                [pscustomobject]@{ TimeCreated = $now.AddHours(-1); LogName = 'Application'; ProviderName = 'SomeApp'; Id = 100; Level = 2; LevelName = $null; Message = "Something failed`r`nmore detail" }
                [pscustomobject]@{ TimeCreated = $now.AddHours(-2); LogName = 'Application'; ProviderName = 'SomeApp'; Id = 100; Level = 2; LevelName = 'Error'; Message = 'Something failed' }
                [pscustomobject]@{ TimeCreated = $now.AddHours(-3); LogName = 'Application'; ProviderName = 'SomeApp'; Id = 100; Level = 2; LevelName = 'Error'; Message = 'Something failed' }
                [pscustomobject]@{ TimeCreated = $now.AddHours(-5); LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; Level = 1; LevelName = 'Critical'; Message = 'The system has rebooted without cleanly shutting down first.' }
                [pscustomobject]@{ TimeCreated = $now.AddHours(-6); LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 47; Level = 3; LevelName = 'Warning'; Message = 'A corrected hardware error has occurred.' }
            )
            $groups = @(ConvertTo-ITEventGroup -ComputerName 'PC1' -Events $events)
            $groups.Count | Should -Be 3
            $groups[0].Note | Should -Not -BeNullOrEmpty
            $groups[1].Note | Should -Not -BeNullOrEmpty
            $groups[2].Source | Should -Be 'SomeApp'
            $groups[2].Count | Should -Be 3
            $groups[2].Message | Should -Be 'Something failed'
            $groups[2].Level | Should -Be 'Error'
            $groups[2].LastSeen | Should -Be $now.AddHours(-1)
            $groups[2].FirstSeen | Should -Be $now.AddHours(-3)
            @($groups | Where-Object { $_.Id -eq 47 }).Note | Should -Be 'Hardware error reported (CPU, memory or PCIe)'
        }
    }

    It 'returns nothing for no events' {
        InModuleScope ITToolkit {
            @(ConvertTo-ITEventGroup -ComputerName 'PC1' -Events @()).Count | Should -Be 0
        }
    }
}
