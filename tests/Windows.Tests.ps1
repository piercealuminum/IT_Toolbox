#Requires -Modules Pester
# Runs every command for real against this Windows computer. Skipped on other systems.
# Run elevated for the fullest coverage.
#
# To also test PowerShell remoting against another computer you administer, set
#     $env:ITTOOLKIT_TEST_REMOTE = 'PC0142'
# before running the tests.

BeforeDiscovery {
    $script:onWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
    $script:remote = $env:ITTOOLKIT_TEST_REMOTE
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ITToolkit\ITToolkit.psd1') -Force
}

Describe 'On this Windows computer' -Skip:(-not $onWindows) -Tag 'Windows' {
    It 'Get-ITDeviceHealth runs every check without errors' {
        $results = @(Get-ITDeviceHealth -ErrorAction Stop)
        $names = @($results | ForEach-Object { $_.Check })
        foreach ($expected in 'System', 'Device join', 'Uptime', 'Pending reboot', 'BitLocker', 'Antivirus', 'Firewall', 'Windows updates', 'Secure Boot') {
            $names | Should -Contain $expected
        }
        @($names | Where-Object { $_ -like 'Disk *' }).Count | Should -BeGreaterThan 0
        $results | ForEach-Object { $_.Status | Should -BeIn @('OK', 'Warn', 'Fail', 'Info') }
        $results | ConvertTo-ITTicketNote | Should -Match 'Device health check'
    }

    It 'Get-ITDeviceHealth -Summary returns one line' {
        $summary = @(Get-ITDeviceHealth -Summary)
        $summary.Count | Should -Be 1
        $summary[0].Reachable | Should -BeTrue
    }

    It 'Get-ITPendingReboot reports uptime' {
        $result = Get-ITPendingReboot -ErrorAction Stop
        $result.UptimeDays | Should -BeGreaterOrEqual 0
        $result.RebootPending | Should -BeOfType [bool]
    }

    It 'Get-ITLocalAdmin lists at least one member' {
        $members = @(Get-ITLocalAdmin -ErrorAction Stop)
        $members.Count | Should -BeGreaterThan 0
        $members | ForEach-Object { $_.Source | Should -BeIn @('Local', 'Domain', 'Entra ID', 'Built-in', 'Unknown') }
    }

    It 'Get-ITInstalledSoftware lists programs and filters by name' {
        $all = @(Get-ITInstalledSoftware -ErrorAction Stop)
        $all.Count | Should -BeGreaterThan 0
        $first = $all[0].Name
        @(Get-ITInstalledSoftware -Name $first) | ForEach-Object { $_.Name | Should -Be $first }
    }

    It 'Get-ITEventSummary runs in both modes' {
        { Get-ITEventSummary -Hours 72 -ErrorAction Stop } | Should -Not -Throw
        { Get-ITEventSummary -Hours 72 -Detailed -ErrorAction Stop } | Should -Not -Throw
    }

    It 'Get-ITLoggedOnUser runs' {
        { Get-ITLoggedOnUser -ErrorAction Stop } | Should -Not -Throw
    }

    It 'Test-ITNetwork reports adapters, DNS and time' {
        $results = @(Test-ITNetwork -ErrorAction Stop)
        @($results | Where-Object { $_.Check -like 'Adapter *' -or $_.Check -eq 'Network adapters' }).Count | Should -BeGreaterThan 0
        @($results | Where-Object { $_.Check -like 'DNS *' }).Count | Should -BeGreaterThan 0
        @($results | Where-Object { $_.Check -eq 'Time sync' }).Count | Should -Be 1
    }

    It 'Clear-ITTempFile -WhatIf deletes nothing' {
        $marker = Join-Path ([System.IO.Path]::GetTempPath()) ("ittoolkit-whatif-{0}.tmp" -f [guid]::NewGuid())
        Set-Content -LiteralPath $marker -Value 'x'
        (Get-Item -LiteralPath $marker).LastWriteTime = (Get-Date).AddDays(-60)
        try {
            Clear-ITTempFile -WhatIf -ErrorAction Stop | Should -BeNullOrEmpty
            Test-Path -LiteralPath $marker | Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
        }
    }
}

Describe 'On a remote computer' -Skip:(-not ($onWindows -and $remote)) -Tag 'Remote' {
    It 'Get-ITDeviceHealth works over remoting' {
        $results = @(Get-ITDeviceHealth -ComputerName $env:ITTOOLKIT_TEST_REMOTE -ErrorAction Stop)
        $results.Count | Should -BeGreaterThan 5
        @($results | ForEach-Object { $_.ComputerName } | Select-Object -Unique) | Should -Be @($env:ITTOOLKIT_TEST_REMOTE)
    }

    It 'Test-ITNetwork reports the clock difference' {
        @(Test-ITNetwork -ComputerName $env:ITTOOLKIT_TEST_REMOTE -ErrorAction Stop | Where-Object { $_.Check -eq 'Clock' }).Count | Should -Be 1
    }

    It 'Test-ITPort runs from the remote computer' {
        $result = Test-ITPort -ComputerName localhost -Port 5985 -Source $env:ITTOOLKIT_TEST_REMOTE
        $result.Source | Should -Be $env:ITTOOLKIT_TEST_REMOTE
        $result.Open | Should -BeTrue
    }

    It 'the other commands work over remoting' {
        { Get-ITPendingReboot -ComputerName $env:ITTOOLKIT_TEST_REMOTE -ErrorAction Stop } | Should -Not -Throw
        @(Get-ITLocalAdmin -ComputerName $env:ITTOOLKIT_TEST_REMOTE -ErrorAction Stop).Count | Should -BeGreaterThan 0
        @(Get-ITInstalledSoftware -ComputerName $env:ITTOOLKIT_TEST_REMOTE -ErrorAction Stop).Count | Should -BeGreaterThan 0
        { Get-ITEventSummary -ComputerName $env:ITTOOLKIT_TEST_REMOTE -ErrorAction Stop } | Should -Not -Throw
        { Get-ITLoggedOnUser -ComputerName $env:ITTOOLKIT_TEST_REMOTE -ErrorAction Stop } | Should -Not -Throw
        { Clear-ITTempFile -ComputerName $env:ITTOOLKIT_TEST_REMOTE -WhatIf -ErrorAction Stop } | Should -Not -Throw
    }
}
