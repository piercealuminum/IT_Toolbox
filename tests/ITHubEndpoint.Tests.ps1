#Requires -Modules Pester
# End-to-end test of the ITHub path through a real JEA endpoint: the client script, the
# restricted session, Invoke-ITHubTool inside it, and the restrictions themselves.
#
# Needs Windows, ITToolkit installed for all users, and the endpoint registered:
#     .\Install-ITToolkit.ps1
#     .\src\ITToolkit\ITHub\Install-ITHubEndpoint.ps1 -ITHubAccount "$env:USERDOMAIN\$env:USERNAME" -RunAsVirtualAccount
#     $env:ITTOOLKIT_TEST_JEA = '1'
# CI does this in the Windows PowerShell 5.1 job.

BeforeDiscovery {
    $script:runJea = ([System.Environment]::OSVersion.Platform -eq 'Win32NT') -and ($env:ITTOOLKIT_TEST_JEA -eq '1')
}

Describe 'ITHub through the JEA endpoint' -Skip:(-not $runJea) -Tag 'JEA' {
    BeforeAll {
        $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
        $script:client = Join-Path $programFiles 'ITToolkit\Invoke-ITHubRequest.ps1'
        $script:manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot '..\src\ITToolkit\ITToolkit.psd1')

        function Invoke-Client([string]$InputText) {
            $start = New-Object System.Diagnostics.ProcessStartInfo
            $start.FileName = 'powershell.exe'
            $start.Arguments = '-NoProfile -NonInteractive -File "{0}"' -f $client
            $start.RedirectStandardInput = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $start.UseShellExecute = $false
            $start.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $process = [System.Diagnostics.Process]::Start($start)
            $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $process.StandardInput.Close()
            $output = $process.StandardOutput.ReadToEnd()
            $errorText = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            if (-not $output) { throw "The client script wrote nothing. Standard error: $errorText" }
            $output | ConvertFrom-Json
        }

        function Invoke-InEndpoint([scriptblock]$Use) {
            $session = New-PSSession -ComputerName localhost -ConfigurationName 'ITToolkit'
            try { & $Use $session } finally { Remove-PSSession -Session $session }
        }
    }

    It 'installed the client script at the fixed path' {
        Test-Path -LiteralPath $client | Should -BeTrue
    }

    It 'returns the catalog through the endpoint' {
        $catalog = Invoke-Client '{"action":"catalog"}'
        $catalog.PSObject.Properties.Name | Should -Not -Contain 'status' -Because "a failure document would mean: $($catalog.errors)"
        @($catalog.tools).Count | Should -Be 10
        $catalog.toolkitVersion | Should -Be $manifest.ModuleVersion
    }

    It 'runs a port test through the endpoint' {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $envelope = Invoke-Client ('{{"tool":"port-test","parameters":{{"host":"127.0.0.1","ports":[{0}]}},"requestedBy":"CI"}}' -f $listener.LocalEndpoint.Port)
            $envelope.errors | Should -BeNullOrEmpty
            $envelope.status | Should -Be 'completed'
            $envelope.results[0].open | Should -BeTrue
            $envelope.ticketNote | Should -Match 'by CI with ITToolkit'
        }
        finally { $listener.Stop() }
    }

    It 'runs a device health check on this computer through the endpoint' {
        $envelope = Invoke-Client ('{{"tool":"device-health","parameters":{{"computerName":"{0}"}}}}' -f $env:COMPUTERNAME)
        $envelope.status | Should -BeIn @('completed', 'completed_with_errors') -Because "errors: $($envelope.errors)"
        $checks = @($envelope.results | ForEach-Object { $_.check })
        $checks | Should -Contain 'System'
        $checks | Should -Contain 'Uptime'
        $checks | Should -Contain 'Firewall'
        ($envelope.results | Where-Object { $_.check -eq 'Firewall' }).detail | Should -Not -Match '^Not checked' 
        @($checks | Where-Object { $_ -like 'Disk *' }).Count | Should -BeGreaterThan 0
        $envelope.summary | Should -Not -BeNullOrEmpty
    }

    It 'reads real data through the endpoint: CIM, registry and ADSI' {
        $reboot = Invoke-Client ('{{"tool":"pending-reboot","parameters":{{"computerName":"{0}"}}}}' -f $env:COMPUTERNAME)
        $reboot.status | Should -Be 'completed' -Because "errors: $($reboot.errors)"
        # CI machines boot minutes before the run, so uptime can round to 0.0 days.
        $reboot.results[0].uptimeDays | Should -Not -BeNullOrEmpty
        $reboot.results[0].lastBootTime | Should -Not -BeNullOrEmpty

        $software = Invoke-Client ('{{"tool":"installed-software","parameters":{{"computerName":"{0}"}}}}' -f $env:COMPUTERNAME)
        $software.status | Should -Be 'completed' -Because "errors: $($software.errors)"
        @($software.results).Count | Should -BeGreaterThan 0

        $admins = Invoke-Client ('{{"tool":"local-admins","parameters":{{"computerName":"{0}"}}}}' -f $env:COMPUTERNAME)
        $admins.status | Should -Be 'completed' -Because "errors: $($admins.errors)"
        @($admins.results).Count | Should -BeGreaterThan 0
    }

    It 'reads event logs and network settings through the endpoint' {
        $events = Invoke-Client ('{{"tool":"event-summary","parameters":{{"computerName":"{0}","hours":72}}}}' -f $env:COMPUTERNAME)
        $events.status | Should -Be 'completed' -Because "errors: $($events.errors); warnings: $($events.warnings)"
        @($events.warnings).Count | Should -Be 0 -Because "warnings: $($events.warnings)"

        $network = Invoke-Client ('{{"tool":"network-test","parameters":{{"computerName":"{0}"}}}}' -f $env:COMPUTERNAME)
        $network.status | Should -Be 'completed' -Because "errors: $($network.errors)"
        @($network.results | Where-Object { $_.check -like 'Adapter *' }).Count | Should -BeGreaterThan 0
    }

    It 'refuses a bad request inside the endpoint too' {
        $envelope = Invoke-Client '{"tool":"device-health","parameters":{"computerName":"PC1; whoami"}}'
        $envelope.status | Should -Be 'failed'
        $envelope.errors[0] | Should -Match 'is not allowed'
    }

    It 'exposes only the two ITHub functions' {
        Invoke-InEndpoint {
            param($session)
            $names = @(Invoke-Command -Session $session -ScriptBlock { Get-Command } | ForEach-Object { $_.Name })
            $names | Should -Contain 'Invoke-ITHubTool'
            $names | Should -Contain 'Get-ITHubToolCatalog'
            $names | Should -Not -Contain 'Get-ITDeviceHealth'
            $names | Should -Not -Contain 'Clear-ITTempFile'
            $names | Should -Not -Contain 'Reset-ITUserPassword'
            $names | Should -Not -Contain 'Get-ChildItem'
            $names | Should -Not -Contain 'Invoke-Expression'
        }
    }

    It 'refuses scripts and commands outside the role' {
        Invoke-InEndpoint {
            param($session)
            $shell = [System.Management.Automation.PowerShell]::Create()
            try {
                $shell.Runspace = $session.Runspace
                $null = $shell.AddScript('1 + 1')
                { $shell.Invoke() } | Should -Throw
            }
            finally { $shell.Dispose() }

            $shell = [System.Management.Automation.PowerShell]::Create()
            try {
                $shell.Runspace = $session.Runspace
                $null = $shell.AddCommand('Get-ITDeviceHealth')
                { $shell.Invoke() } | Should -Throw
            }
            finally { $shell.Dispose() }
        }
    }

    It 'writes a transcript of each call' {
        $folder = Join-Path $env:ProgramData 'ITToolkit\Transcripts'
        @(Get-ChildItem -LiteralPath $folder -Recurse -File -ErrorAction SilentlyContinue).Count | Should -BeGreaterThan 0
    }
}
