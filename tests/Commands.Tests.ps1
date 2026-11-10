#Requires -Modules Pester
# Commands and helpers that work on any operating system.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ITToolkit\ITToolkit.psd1') -Force
}

Describe 'New-ITPassphrase' {
    It 'follows the Word-Word-Word-Word12 pattern by default' {
        $phrase = New-ITPassphrase
        $phrase | Should -BeOfType [string]
        $phrase | Should -MatchExactly '^([A-Z][a-z]{2,8}-){3}[A-Z][a-z]{2,8}\d{2}$'
    }

    It 'meets complexity rules: upper, lower, digit and symbol' {
        foreach ($phrase in New-ITPassphrase -Count 20) {
            $phrase | Should -MatchExactly '[A-Z]'
            $phrase | Should -MatchExactly '[a-z]'
            $phrase | Should -Match '\d'
            $phrase | Should -Match '[^A-Za-z0-9]'
        }
    }

    It 'honors WordCount, Separator, Digits and Count' {
        $phrases = @(New-ITPassphrase -WordCount 3 -Separator '.' -Digits 0 -Count 5)
        $phrases.Count | Should -Be 5
        foreach ($phrase in $phrases) { $phrase | Should -MatchExactly '^[A-Z][a-z]+\.[A-Z][a-z]+\.[A-Z][a-z]+$' }
        New-ITPassphrase -Separator '' -WordCount 2 -Digits 4 | Should -MatchExactly '^[A-Z][a-z]+[A-Z][a-z]+\d{4}$'
    }

    It 'does not repeat itself' {
        $phrases = @(New-ITPassphrase -Count 200)
        @($phrases | Select-Object -Unique).Count | Should -Be 200
    }

    It 'returns a read-only SecureString with -AsSecureString' {
        $secure = New-ITPassphrase -AsSecureString
        $secure | Should -BeOfType [securestring]
        $secure.IsReadOnly() | Should -BeTrue
        $secure.Length | Should -BeGreaterThan 12
    }
}

Describe 'Get-ITRandomIndex' {
    It 'stays in range and covers every value' {
        InModuleScope ITToolkit {
            $seen = @{}
            for ($i = 0; $i -lt 2000; $i++) {
                $value = Get-ITRandomIndex -Maximum 7
                $value | Should -BeGreaterOrEqual 0
                $value | Should -BeLessThan 7
                $seen[$value] = $true
            }
            $seen.Count | Should -Be 7
            Get-ITRandomIndex -Maximum 1 | Should -Be 0
        }
    }

    It 'is roughly uniform' {
        InModuleScope ITToolkit {
            $counts = New-Object int[] 10
            for ($i = 0; $i -lt 10000; $i++) { $counts[(Get-ITRandomIndex -Maximum 10)]++ }
            # Expected 1000 each; 850-1150 is far outside normal variation (sd ~30).
            foreach ($count in $counts) { $count | Should -BeGreaterThan 850; $count | Should -BeLessThan 1150 }
        }
    }
}

Describe 'Test-ITPort' {
    BeforeAll {
        $script:listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $script:openPort = $listener.LocalEndpoint.Port
        # A port that was free a moment ago, so nothing listens on it.
        $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $probe.Start()
        $script:closedPort = $probe.LocalEndpoint.Port
        $probe.Stop()
    }

    AfterAll {
        $listener.Stop()
    }

    It 'reports an open port with its latency' {
        $result = Test-ITPort -ComputerName 127.0.0.1 -Port $openPort
        $result.Open | Should -BeTrue
        $result.LatencyMs | Should -BeGreaterOrEqual 0
        $result.Detail | Should -Be 'Connected to 127.0.0.1'
        $result.PSObject.TypeNames[0] | Should -Be 'ITToolkit.PortTest'
    }

    It 'tries every address of a name (localhost may resolve to ::1 first)' {
        $result = Test-ITPort -ComputerName localhost -Port $openPort
        $result.Open | Should -BeTrue
        $result.Detail | Should -Be 'Connected to 127.0.0.1'
    }

    It 'connects over IPv6' {
        try {
            $listener6 = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::IPv6Loopback, 0)
            $listener6.Start()
        }
        catch {
            Set-ItResult -Skipped -Because 'IPv6 is not available here'
            return
        }
        try {
            $result = Test-ITPort -ComputerName '::1' -Port $listener6.LocalEndpoint.Port
            $result.Open | Should -BeTrue
            $result.Detail | Should -Be 'Connected to ::1'
        }
        finally {
            $listener6.Stop()
        }
    }

    It 'reports an address family the computer cannot use instead of failing' {
        $hasIPv6 = $true
        try { (New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetworkV6, [System.Net.Sockets.SocketType]::Stream, [System.Net.Sockets.ProtocolType]::Tcp)).Close() }
        catch { $hasIPv6 = $false }
        if ($hasIPv6) { Set-ItResult -Skipped -Because 'this computer has IPv6'; return }
        $result = Test-ITPort -ComputerName '::1' -Port 443 -ErrorAction Stop
        $result.Open | Should -BeFalse
        $result.Detail | Should -Not -BeNullOrEmpty
    }

    It 'reports an unreachable -Source computer as an error, not a crash' {
        $errors = @()
        $output = @(Test-ITPort -ComputerName 127.0.0.1 -Port $openPort -Source 'PC-THAT-IS-NOT-THIS-ONE' -ErrorAction SilentlyContinue -ErrorVariable errors)
        $output.Count | Should -Be 0
        $errors.Count | Should -BeGreaterThan 0
        # -ErrorVariable also collects the inner remoting error that the command handled.
        @($errors | Where-Object { "$_" -match '^PC-THAT-IS-NOT-THIS-ONE: Could not connect' }).Count | Should -Be 1
    }

    It 'reports a closed port as refused' {
        $result = Test-ITPort -ComputerName 127.0.0.1 -Port $closedPort
        $result.Open | Should -BeFalse
        $result.Detail | Should -Match '^Refused'
    }

    It 'reports a name that does not resolve' {
        $result = Test-ITPort -ComputerName 'no-such-host.invalid' -Port 443 -TimeoutMs 5000
        $result.Open | Should -BeFalse
        $result.Detail | Should -Match '^DNS lookup'
    }

    It 'tests every host and port, labels known services, and takes pipeline input' {
        $results = @('127.0.0.1', 'localhost' | Test-ITPort -Port $openPort, 445)
        $results.Count | Should -Be 4
        @($results | Where-Object { $_.Port -eq 445 })[0].Service | Should -Be 'SMB'
    }

    It 'expands presets' {
        $results = @(Test-ITPort -ComputerName 127.0.0.1 -Preset WinRM -TimeoutMs 500)
        @($results.Port) | Should -Be @(5985, 5986)
    }
}

Describe 'ConvertTo-ITTicketNote' {
    It 'summarizes checks and lists problems first' {
        $checks = InModuleScope ITToolkit {
            New-ITCheckResult -ComputerName 'PC0142' -Category 'Security' -Check 'BitLocker' -Status 'OK' -Detail 'C: on'
            New-ITCheckResult -ComputerName 'PC0142' -Category 'Maintenance' -Check 'Uptime' -Status 'Warn' -Detail '23.0 days since last boot'
            New-ITCheckResult -ComputerName 'PC0142' -Category 'Storage' -Check 'Disk C:' -Status 'Fail' -Detail '3.0 GB free of 237.0 GB (1%)'
            New-ITCheckResult -ComputerName 'PC0142' -Category 'System' -Check 'System' -Status 'Info' -Detail 'Dell Latitude'
        }
        $note = $checks | ConvertTo-ITTicketNote
        $note | Should -BeOfType [string]
        $lines = $note -split '\r?\n'
        $lines[0] | Should -Be '== Device health check =='
        $lines[1] | Should -Match '^Collected \d{4}-\d{2}-\d{2} \d{2}:\d{2} by .+ with ITToolkit$'
        $note | Should -Match 'PC0142: 1 fail, 1 warn, 1 OK, 1 info'
        $failAt = $note.IndexOf('[FAIL] Disk C: - 3.0 GB')
        $warnAt = $note.IndexOf('[WARN] Uptime - 23.0 days')
        $failAt | Should -BeGreaterThan 0
        $warnAt | Should -BeGreaterThan $failAt
        $note | Should -Match 'All checks:'
    }

    It 'keeps problems in check order within each status' {
        $checks = InModuleScope ITToolkit {
            foreach ($name in 'Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo') {
                New-ITCheckResult -ComputerName 'PC1' -Category 'System' -Check $name -Status 'Warn' -Detail 'x'
            }
            New-ITCheckResult -ComputerName 'PC1' -Category 'System' -Check 'Zulu' -Status 'Fail' -Detail 'x'
        }
        $note = $checks | ConvertTo-ITTicketNote
        $order = @('Zulu', 'Alpha', 'Bravo', 'Charlie', 'Delta', 'Echo' | ForEach-Object { $note.IndexOf("] $_ - ") })
        $order | Should -Be @($order | Sort-Object)
        $order[0] | Should -BeGreaterThan 0
    }

    It 'titles network results and accepts a custom title' {
        $check = InModuleScope ITToolkit { New-ITCheckResult -ComputerName 'PC1' -Category 'Network' -Check 'DNS x' -Status 'OK' -Detail 'Resolved' }
        ($check | ConvertTo-ITTicketNote) | Should -Match '^== Network test =='
        ($check | ConvertTo-ITTicketNote -Title 'Cannot reach S: drive') | Should -Match '^== Cannot reach S: drive =='
    }

    It 'formats other ITToolkit results as a table' {
        $session = [pscustomobject]@{ PSTypeName = 'ITToolkit.Session'; ComputerName = 'RDS01'; UserName = 'jsmith'; SessionName = 'rdp-tcp#3'; Id = 2; State = 'Active'; IdleTime = '5'; LogonTime = 'x' }
        $note = $session | ConvertTo-ITTicketNote
        $note | Should -Match '^== Signed-in users =='
        $note | Should -Match 'jsmith'
    }

    It 'returns nothing for no input' {
        @() | ConvertTo-ITTicketNote | Should -BeNullOrEmpty
    }
}

Describe 'Settings' {
    BeforeEach {
        $script:settingsFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ittoolkit-settings-{0}.psd1" -f [guid]::NewGuid())
        $script:savedVariable = $env:ITTOOLKIT_SETTINGS
        $env:ITTOOLKIT_SETTINGS = $settingsFile
    }

    AfterEach {
        $env:ITTOOLKIT_SETTINGS = $savedVariable
        Remove-Item -LiteralPath $settingsFile -ErrorAction SilentlyContinue
    }

    It 'uses the organization file for the keys it sets and defaults for the rest' {
        Set-Content -LiteralPath $settingsFile -Value "@{ Health = @{ UptimeDaysWarn = 7 }; Network = @{ InternalDnsNames = @('dc01.corp.example.com') } }"
        $settings = @(Get-ITToolkitSetting)
        $uptime = $settings | Where-Object { $_.Section -eq 'Health' -and $_.Name -eq 'UptimeDaysWarn' }
        $uptime.Value | Should -Be 7
        $uptime.Source | Should -Be $settingsFile
        $disk = $settings | Where-Object { $_.Section -eq 'Health' -and $_.Name -eq 'DiskFreePercentWarn' }
        $disk.Value | Should -Be 15
        $disk.Source | Should -Be 'Default'
        ($settings | Where-Object { $_.Name -eq 'InternalDnsNames' }).Value | Should -Be @('dc01.corp.example.com')
    }

    It 'warns about misspelled settings instead of failing' {
        Set-Content -LiteralPath $settingsFile -Value "@{ Health = @{ UptimeDaysWarm = 7 }; Helth = @{} }"
        $warnings = @()
        $null = Get-ITToolkitSetting -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings | Where-Object { "$_" -match 'UptimeDaysWarm' }).Count | Should -Be 1
        @($warnings | Where-Object { "$_" -match "'Helth'" }).Count | Should -Be 1
    }

    It 'ignores a file that is not a valid data file' {
        Set-Content -LiteralPath $settingsFile -Value "@{ Health = @{ UptimeDaysWarn = (Get-Date) } }"
        $warnings = @()
        $settings = @(Get-ITToolkitSetting -WarningVariable warnings -WarningAction SilentlyContinue)
        ($settings | Where-Object { $_.Name -eq 'UptimeDaysWarn' }).Value | Should -Be 14
        @($warnings).Count | Should -BeGreaterThan 0
    }

    It 'returns the settings file path with -Path' {
        Get-ITToolkitSetting -Path | Should -Be $settingsFile
    }
}

Describe 'Test-ITLocalComputer' {
    It 'treats <_> as this computer' -ForEach @('', '.', 'localhost', '127.0.0.1', '::1') {
        InModuleScope ITToolkit -Parameters @{ Name = $_ } { param($Name) Test-ITLocalComputer -ComputerName $Name | Should -BeTrue }
    }

    It 'treats its own name and FQDN as this computer, in any case' {
        InModuleScope ITToolkit {
            $machine = [Environment]::MachineName
            Test-ITLocalComputer -ComputerName $machine.ToLowerInvariant() | Should -BeTrue
            Test-ITLocalComputer -ComputerName "$machine.corp.example.com" | Should -BeTrue
        }
    }

    It 'treats other names as remote' {
        InModuleScope ITToolkit { Test-ITLocalComputer -ComputerName 'PC-THAT-IS-NOT-THIS-ONE' | Should -BeFalse }
    }
}

Describe 'TempFiles collector' {
    # The deletion logic is plain .NET, so it is tested here on real files.
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ("ittoolkit-temp-{0}" -f [guid]::NewGuid())
        $script:outside = Join-Path ([System.IO.Path]::GetTempPath()) ("ittoolkit-outside-{0}" -f [guid]::NewGuid())
        $old = (Get-Date).AddDays(-30)
        New-Item -ItemType Directory -Path (Join-Path $root 'sub\deeper') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'emptyold') -Force | Out-Null
        New-Item -ItemType Directory -Path $outside -Force | Out-Null

        Set-Content -LiteralPath (Join-Path $root 'old.tmp') -Value ('x' * 1000)
        Set-Content -LiteralPath (Join-Path $root 'sub\deeper\old2.tmp') -Value ('x' * 500)
        Set-Content -LiteralPath (Join-Path $root 'new.tmp') -Value 'recent'
        Set-Content -LiteralPath (Join-Path $outside 'precious.txt') -Value 'must survive'
        foreach ($path in @((Join-Path $root 'old.tmp'), (Join-Path $root 'sub\deeper\old2.tmp'), (Join-Path $outside 'precious.txt'), (Join-Path $root 'emptyold'))) {
            $item = Get-Item -LiteralPath $path
            $item.CreationTime = $old
            $item.LastWriteTime = $old
        }

        $script:linkMade = $false
        try {
            New-Item -ItemType SymbolicLink -Path (Join-Path $root 'link') -Target $outside -ErrorAction Stop | Out-Null
            $script:linkMade = $true
        }
        catch { $script:linkMade = $false }   # creating links needs rights Windows users may not have

        $script:collector = InModuleScope ITToolkit { $script:ITCollectors['TempFiles'] }
    }

    AfterEach {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $outside -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'measures without deleting' {
        $scan = & $collector @(, $root) 7 $false
        $scan.Files | Should -Be 2
        $scan.Bytes | Should -BeGreaterThan 1400
        Test-Path -LiteralPath (Join-Path $root 'old.tmp') | Should -BeTrue
    }

    It 'deletes only old files and never follows links out of the folder' {
        $result = & $collector @(, $root) 7 $true
        $result.Files | Should -Be 2
        $result.Failed | Should -Be 0
        Test-Path -LiteralPath (Join-Path $root 'old.tmp') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'sub\deeper\old2.tmp') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $root 'new.tmp') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $root 'emptyold') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $outside 'precious.txt') | Should -BeTrue
        if ($linkMade) { Test-Path -LiteralPath (Join-Path $root 'link') | Should -BeTrue }
    }

    It 'skips folders that do not exist' {
        @(& $collector @(, (Join-Path $root 'missing')) 7 $true).Count | Should -Be 0
    }

    It 'refuses a temp folder that is itself a link' {
        $linkedRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ittoolkit-linkroot-{0}" -f [guid]::NewGuid())
        try {
            New-Item -ItemType SymbolicLink -Path $linkedRoot -Target $outside -ErrorAction Stop | Out-Null
        }
        catch {
            Set-ItResult -Skipped -Because 'this account cannot create links'
            return
        }
        try {
            $result = & $collector @(, $linkedRoot) 7 $true
            $result.Files | Should -Be 0
            $result.Skipped | Should -Match 'link or junction'
            Test-Path -LiteralPath (Join-Path $outside 'precious.txt') | Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath $linkedRoot -Force -ErrorAction SilentlyContinue
        }
    }

    It 'refuses a temp folder under a link' {
        if (-not $linkMade) { Set-ItResult -Skipped -Because 'this account cannot create links'; return }
        New-Item -ItemType Directory -Path (Join-Path $outside 'Temp') | Out-Null
        $victim = Join-Path $outside 'Temp\victim.txt'
        Set-Content -LiteralPath $victim -Value 'must survive'
        $item = Get-Item -LiteralPath $victim
        $item.CreationTime = (Get-Date).AddDays(-30)
        $item.LastWriteTime = (Get-Date).AddDays(-30)

        $result = & $collector @(, (Join-Path $root 'link\Temp')) 7 $true
        $result.Skipped | Should -Match 'link or junction'
        Test-Path -LiteralPath $victim | Should -BeTrue
    }

    It 'keeps newly extracted files that carry an old timestamp' {
        $extracted = Join-Path $root 'extracted.dll'
        Set-Content -LiteralPath $extracted -Value 'x'
        (Get-Item -LiteralPath $extracted).LastWriteTime = (Get-Date).AddDays(-400)
        $item = Get-Item -LiteralPath $extracted
        if ($item.CreationTime -lt (Get-Date).AddDays(-7)) {
            # Linux file systems move the creation time along with the write time.
            Set-ItResult -Skipped -Because 'this file system cannot keep a new creation time with an old write time'
            return
        }
        $null = & $collector @(, $root) 7 $true
        Test-Path -LiteralPath $extracted | Should -BeTrue
    }
}

Describe 'Invoke-ITCollector' {
    It 'runs local collectors with default preferences, like a remote session' {
        InModuleScope ITToolkit {
            $script:ITCollectors['PreferenceProbe'] = { '{0}|{1}' -f $ErrorActionPreference, $WhatIfPreference }
            try {
                $target = Open-ITTarget -ComputerName 'localhost'
                $ErrorActionPreference = 'Stop'
                $WhatIfPreference = $true
                Invoke-ITCollector -Name 'PreferenceProbe' -Target $target | Should -Be 'Continue|False'
            }
            finally {
                $script:ITCollectors.Remove('PreferenceProbe')
            }
        }
    }
}
