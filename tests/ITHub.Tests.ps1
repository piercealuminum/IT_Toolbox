#Requires -Modules Pester
# The ITHub contract: request checking, the JSON envelope, the catalog, the client script,
# and the sample envelopes in docs/ithub/samples that ITHub's fake runner uses.
#
# To regenerate the samples after a deliberate change to the envelope:
#     $env:ITTOOLKIT_WRITE_SAMPLES = '1'; Invoke-Pester ./tests/ITHub.Tests.ps1

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..\src\ITToolkit'
    Import-Module (Join-Path $ModuleRoot 'ITToolkit.psd1') -Force
    $script:SampleFolder = Join-Path $PSScriptRoot '..\docs\ithub\samples'

    # Mock bodies run in this file's scope, where the module's private helpers are not visible.
    function New-Check($ComputerName, $Category, $Check, $Status, $Detail) {
        [pscustomobject]@{ PSTypeName = 'ITToolkit.CheckResult'; ComputerName = $ComputerName; Category = $Category; Check = $Check; Status = $Status; Detail = $Detail }
    }
    function New-UserCheckRow($UserName, $Category, $Check, $Status, $Detail) {
        [pscustomobject]@{ PSTypeName = 'ITToolkit.UserCheck'; UserName = $UserName; Category = $Category; Check = $Check; Status = $Status; Detail = $Detail }
    }

    function Invoke-Hub([hashtable]$Request) {
        $json = ConvertTo-Json -InputObject $Request -Depth 5 -Compress
        Invoke-ITHubTool -RequestJson $json | ConvertFrom-Json
    }

    function Get-KeyShape($Value) {
        # Names of every key at every level (list items merged), to compare shapes.
        $keys = New-Object System.Collections.Generic.List[string]
        $walk = {
            param($node, $path)
            if ($node -is [System.Management.Automation.PSCustomObject]) {
                foreach ($property in $node.PSObject.Properties) {
                    $keys.Add("$path.$($property.Name)")
                    & $walk $property.Value "$path.$($property.Name)"
                }
            }
            elseif ($node -is [array]) {
                foreach ($item in $node) { & $walk $item "$path[]" }
            }
        }
        & $walk $Value ''
        @($keys | Sort-Object -Unique)
    }
}

Describe 'Request checking' {
    It 'accepts a valid request and fills defaults' {
        $request = InModuleScope ITToolkit { Resolve-ITHubRequest -RequestJson '{"tool":"event-summary","parameters":{"computerName":"PC0142"},"requestedBy":"Jordan Lee"}' }
        $request.Tool.Id | Should -Be 'event-summary'
        $request.Bound.ComputerName | Should -Be 'PC0142'
        $request.Bound.Hours | Should -Be 24
        $request.Parameters.hours | Should -Be 24
        $request.RequestedBy | Should -Be 'Jordan Lee'
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'invalid JSON'; Json = 'not json'; Pattern = 'not valid JSON' }
        @{ Case = 'a JSON array'; Json = '[1,2]'; Pattern = 'must be a JSON object' }
        @{ Case = 'an unknown tool'; Json = '{"tool":"Remove-Item"}'; Pattern = "Unknown tool 'Remove-Item'" }
        @{ Case = 'a tool in the wrong case'; Json = '{"tool":"Device-Health","parameters":{"computerName":"PC1"}}'; Pattern = 'Unknown tool' }
        @{ Case = 'an extra request field'; Json = '{"tool":"device-health","parameters":{"computerName":"PC1"},"script":"x"}'; Pattern = 'Unknown request field' }
        @{ Case = 'an unknown parameter'; Json = '{"tool":"device-health","parameters":{"computerName":"PC1","credential":"x"}}'; Pattern = "Unknown parameter 'credential'" }
        @{ Case = 'a missing required parameter'; Json = '{"tool":"device-health","parameters":{}}'; Pattern = 'computerName is required' }
        @{ Case = 'a command in a computer name'; Json = '{"tool":"device-health","parameters":{"computerName":"PC1; Remove-Item C:\\\\"}}'; Pattern = 'is not allowed' }
        @{ Case = 'a subexpression in an identity'; Json = '{"tool":"user-status","parameters":{"identity":"$(whoami)"}}'; Pattern = 'is not allowed' }
        @{ Case = 'a leading dash'; Json = '{"tool":"user-status","parameters":{"identity":"-Filter"}}'; Pattern = 'is not allowed' }
        @{ Case = 'a number as text'; Json = '{"tool":"event-summary","parameters":{"computerName":"PC1","hours":"24"}}'; Pattern = 'whole number' }
        @{ Case = 'hours out of range'; Json = '{"tool":"event-summary","parameters":{"computerName":"PC1","hours":9999}}'; Pattern = 'from 1 to 720' }
        @{ Case = 'a port out of range'; Json = '{"tool":"port-test","parameters":{"host":"fs01","ports":[70000]}}'; Pattern = 'from 1 to 65535' }
        @{ Case = 'too many ports'; Json = '{"tool":"port-test","parameters":{"host":"fs01","ports":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21]}}'; Pattern = '1 to 20' }
        @{ Case = 'both ports and preset'; Json = '{"tool":"port-test","parameters":{"host":"fs01","ports":[445],"preset":"SMB"}}'; Pattern = 'exactly one of: ports, preset' }
        @{ Case = 'neither ports nor preset'; Json = '{"tool":"port-test","parameters":{"host":"fs01"}}'; Pattern = 'exactly one of: ports, preset' }
        @{ Case = 'an unknown preset'; Json = '{"tool":"port-test","parameters":{"host":"fs01","preset":"Everything"}}'; Pattern = 'must be one of' }
        @{ Case = 'a bad host:port'; Json = '{"tool":"network-test","parameters":{"computerName":"PC1","tcpTargets":["fs01 445"]}}'; Pattern = 'is not allowed' }
        @{ Case = 'a bad requester name'; Json = '{"tool":"device-health","parameters":{"computerName":"PC1"},"requestedBy":"<script>"}'; Pattern = 'requestedBy' }
    ) {
        { InModuleScope ITToolkit -Parameters @{ Json = $Json } { param($Json) Resolve-ITHubRequest -RequestJson $Json } } | Should -Throw -ExpectedMessage "*$Pattern*"
    }

    It 'lists every problem at once' {
        $message = $null
        try { InModuleScope ITToolkit { Resolve-ITHubRequest -RequestJson '{"tool":"port-test","parameters":{"host":"bad host","ports":[0],"x":1}}' } }
        catch { $message = $_.Exception.Message }
        $message | Should -Match "Unknown parameter 'x'"
        $message | Should -Match 'host'
        $message | Should -Match 'ports'
    }
}

Describe 'Value conversion' {
    It 'camelCases names' {
        InModuleScope ITToolkit {
            ConvertTo-ITHubName -Name 'ComputerName' | Should -BeExactly 'computerName'
            ConvertTo-ITHubName -Name 'OK' | Should -BeExactly 'ok'
            ConvertTo-ITHubName -Name 'Id' | Should -BeExactly 'id'
            ConvertTo-ITHubName -Name 'LatencyMs' | Should -BeExactly 'latencyMs'
        }
    }

    It 'writes dates as UTC ISO 8601, lists as lists and nested objects as maps' {
        InModuleScope ITToolkit {
            $row = [pscustomobject]@{
                PSTypeName = 'ITToolkit.Test'
                When       = [datetime]::SpecifyKind([datetime]'2026-11-10 14:05:09', [DateTimeKind]::Utc)
                Reasons    = [string[]]@('Windows Update')
                Empty      = @()
                Flag       = $true
                Count      = 3
                Kind       = [System.DayOfWeek]::Monday
                Nested     = [pscustomobject]@{ InnerName = 'x' }
                Nothing    = $null
            }
            $json = ConvertTo-Json -InputObject (ConvertTo-ITHubResult -InputObject $row) -Depth 6 -Compress
            $json | Should -BeExactly '{"type":"ITToolkit.Test","when":"2026-11-10T14:05:09Z","reasons":["Windows Update"],"empty":[],"flag":true,"count":3,"kind":"Monday","nested":{"innerName":"x"},"nothing":null}'
        }
    }
}

Describe 'Invoke-ITHubTool' {
    BeforeEach {
        Mock -ModuleName ITToolkit Get-ITDeviceHealth {
            New-Check $ComputerName[0] 'System' 'System' 'Info' 'Dell Inc. Latitude 7450, serial ABC1234, Windows 11 Enterprise 24H2 (build 26100.2314)'
            New-Check $ComputerName[0] 'Maintenance' 'Uptime' 'Warn' '23.4 days since last boot (2026-10-18 07:55)'
            New-Check $ComputerName[0] 'Storage' 'Disk C:' 'Fail' '3.1 GB free of 237.5 GB (1%)'
            New-Check $ComputerName[0] 'Security' 'BitLocker' 'OK' 'C: on'
        }
    }

    It 'returns a completed envelope with results, summary and a ticket note' {
        $envelope = Invoke-Hub @{ tool = 'device-health'; parameters = @{ computerName = 'PC0142' }; requestedBy = 'Jordan Lee' }
        $envelope.schemaVersion | Should -Be 1
        $envelope.toolkitVersion | Should -Be (Get-Module ITToolkit).Version.ToString()
        $envelope.tool | Should -Be 'device-health'
        $envelope.parameters.computerName | Should -Be 'PC0142'
        $envelope.requestedBy | Should -Be 'Jordan Lee'
        $envelope.status | Should -Be 'completed'
        # Checked in the raw JSON: PowerShell 7's ConvertFrom-Json turns ISO dates into DateTime.
        $raw = Invoke-ITHubTool -RequestJson '{"tool":"device-health","parameters":{"computerName":"PC0142"}}'
        $raw | Should -Match '"startedAt":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        $raw | Should -Match '"finishedAt":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        @($envelope.results).Count | Should -Be 4
        $envelope.results[2].type | Should -Be 'ITToolkit.CheckResult'
        $envelope.results[2].check | Should -Be 'Disk C:'
        $envelope.results[2].status | Should -Be 'Fail'
        $envelope.summary.fail | Should -Be 1
        $envelope.summary.warn | Should -Be 1
        $envelope.summary.ok | Should -Be 1
        $envelope.summary.info | Should -Be 1
        $envelope.ticketNote | Should -Match '^== Device health check =='
        $envelope.ticketNote | Should -Match 'by Jordan Lee with ITToolkit'
        @($envelope.errors).Count | Should -Be 0
        Should -Invoke -ModuleName ITToolkit Get-ITDeviceHealth -Times 2 -Exactly -ParameterFilter { $ComputerName -eq 'PC0142' }
    }

    It 'keeps results a list when there is only one' {
        Mock -ModuleName ITToolkit Get-ITPendingReboot {
            [pscustomobject]@{ PSTypeName = 'ITToolkit.PendingReboot'; ComputerName = 'PC0142'; RebootPending = $false; Reasons = [string[]]@(); PendingFileRenames = 0; LastBootTime = (Get-Date).AddDays(-2); UptimeDays = 2.0 }
        }
        $json = Invoke-ITHubTool -RequestJson '{"tool":"pending-reboot","parameters":{"computerName":"PC0142"}}'
        $json | Should -Match '"results":\[\{'
        $json | Should -Match '"reasons":\[\]'
        $json | Should -Not -Match '"summary"'
    }

    It 'runs nothing for a refused request' {
        $envelope = Invoke-Hub @{ tool = 'device-health'; parameters = @{ computerName = 'PC1;whoami' } }
        $envelope.status | Should -Be 'failed'
        $envelope.tool | Should -Be 'device-health'
        $envelope.errors[0] | Should -Match 'is not allowed'
        Should -Invoke -ModuleName ITToolkit Get-ITDeviceHealth -Times 0 -Exactly
    }

    It 'reports an unreachable computer as failed, with the computer in the message' {
        Mock -ModuleName ITToolkit Open-ITTarget { throw 'Could not connect with PowerShell remoting. Check that the computer is on, WinRM is enabled (Enable-PSRemoting) and you are an administrator on it. Details: WinRM cannot complete the operation.' }
        $envelope = Invoke-Hub @{ tool = 'local-admins'; parameters = @{ computerName = 'PC0999' } }
        $envelope.status | Should -Be 'failed'
        @($envelope.errors).Count | Should -Be 1
        $envelope.errors[0] | Should -Match '^PC0999: Could not connect with PowerShell remoting'
        $envelope.ticketNote | Should -BeNullOrEmpty
    }

    It 'passes warnings through' {
        Mock -ModuleName ITToolkit Get-ITEventSummary { Write-Warning 'PC0142: could not read hardware errors (WHEA): Access is denied' }
        $envelope = Invoke-Hub @{ tool = 'event-summary'; parameters = @{ computerName = 'PC0142'; hours = 4 } }
        $envelope.status | Should -Be 'completed'
        $envelope.parameters.hours | Should -Be 4
        $envelope.warnings | Should -Contain 'PC0142: could not read hardware errors (WHEA): Access is denied'
    }

    It 'caps very long result lists with a warning' {
        $file = Join-Path ([System.IO.Path]::GetTempPath()) ("ittoolkit-hub-{0}.psd1" -f [guid]::NewGuid())
        Set-Content -LiteralPath $file -Value '@{ ITHub = @{ MaxResults = 3 } }'
        $saved = $env:ITTOOLKIT_SETTINGS
        $env:ITTOOLKIT_SETTINGS = $file
        try {
            $envelope = Invoke-Hub @{ tool = 'device-health'; parameters = @{ computerName = 'PC0142' } }
            @($envelope.results).Count | Should -Be 3
            $envelope.warnings | Should -Contain 'Showing the first 3 of 4 results.'
        }
        finally {
            $env:ITTOOLKIT_SETTINGS = $saved
            Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
        }
    }

    It 'runs a real port test end to end' {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $envelope = Invoke-Hub @{ tool = 'port-test'; parameters = @{ host = '127.0.0.1'; ports = @($listener.LocalEndpoint.Port) } }
            $envelope.status | Should -Be 'completed'
            $envelope.results[0].type | Should -Be 'ITToolkit.PortTest'
            $envelope.results[0].open | Should -BeTrue
            @($envelope.errors).Count | Should -Be 0
        }
        finally { $listener.Stop() }
    }
}

Describe 'Connect-ITHubGraph' {
    It 'does nothing when no certificate is configured' {
        InModuleScope ITToolkit { Connect-ITHubGraph | Should -BeNullOrEmpty }
    }

    It 'explains what is missing when Graph PowerShell is not installed' {
        $file = Join-Path ([System.IO.Path]::GetTempPath()) ("ittoolkit-hub-{0}.psd1" -f [guid]::NewGuid())
        Set-Content -LiteralPath $file -Value "@{ ITHub = @{ GraphTenantId = 'tenant'; GraphClientId = 'client'; GraphCertificateThumbprint = 'ABC' } }"
        $saved = $env:ITTOOLKIT_SETTINGS
        $env:ITTOOLKIT_SETTINGS = $file
        try {
            InModuleScope ITToolkit {
                Mock Get-Command -ParameterFilter { $Name -eq 'Connect-MgGraph' } { $null }
                Connect-ITHubGraph | Should -Match 'not installed'
            }
        }
        finally {
            $env:ITTOOLKIT_SETTINGS = $saved
            Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Get-ITHubToolCatalog' {
    BeforeAll {
        $script:catalog = Get-ITHubToolCatalog | ConvertFrom-Json
    }

    It 'lists the phase 1 tools with unique ids' {
        @($catalog.tools).Count | Should -Be 10
        @($catalog.tools.id | Select-Object -Unique).Count | Should -Be 10
        $catalog.tools | ForEach-Object { $_.phase | Should -Be 1; $_.permission | Should -Be 'tools.run' }
    }

    It 'describes <_> from its command help, and binds only real parameters' -ForEach @(
        'device-health', 'pending-reboot', 'network-test', 'port-test', 'signed-in-users', 'installed-software', 'event-summary', 'local-admins', 'user-status', 'lockout-source'
    ) {
        $entry = $catalog.tools | Where-Object { $_.id -eq $_ }
        $entry = @($catalog.tools | Where-Object id -eq $_)[0]
        $entry.description | Should -Not -BeNullOrEmpty
        $entry.target | Should -BeIn @('computer', 'user')
        $command = Get-Command -Name $entry.command -Module ITToolkit
        $definition = InModuleScope ITToolkit -Parameters @{ Id = $_ } { param($Id) Get-ITHubToolDefinition -Id $Id }
        foreach ($parameter in $definition.Parameters) {
            $command.Parameters.ContainsKey($parameter.Bind) | Should -BeTrue -Because "$($entry.command) needs -$($parameter.Bind)"
        }
        @($entry.parameters | Where-Object required).Count | Should -BeLessOrEqual @($entry.parameters).Count
    }

    It 'never exposes a command that changes anything in phase 1' {
        $catalog.tools.command | Should -Not -Contain 'Clear-ITTempFile'
        $catalog.tools.command | Should -Not -Contain 'Reset-ITUserPassword'
    }
}

Describe 'ITHubTools role capability' {
    It 'makes exactly the two ITHub functions visible' {
        $role = Import-PowerShellDataFile -Path (Join-Path $ModuleRoot 'RoleCapabilities\ITHubTools.psrc')
        @($role.VisibleFunctions | Sort-Object) | Should -Be @('Get-ITHubToolCatalog', 'Invoke-ITHubTool')
        $role.ModulesToImport | Should -Be 'ITToolkit'
        $role.ContainsKey('VisibleCmdlets') | Should -BeFalse
        $role.ContainsKey('VisibleExternalCommands') | Should -BeFalse
        $role.ContainsKey('VisibleProviders') | Should -BeFalse
    }
}

Describe 'Invoke-ITHubRequest.ps1 (local mode)' {
    BeforeAll {
        $script:client = Join-Path $ModuleRoot 'ITHub\Invoke-ITHubRequest.ps1'
        $script:shell = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { (Get-Process -Id $PID).Path }
        function Invoke-Client([string]$InputText, [string[]]$Extra = @('-Local')) {
            $start = New-Object System.Diagnostics.ProcessStartInfo
            $start.FileName = $shell
            $start.Arguments = '-NoProfile -NonInteractive -File "{0}" {1}' -f $client, ($Extra -join ' ')
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
            $null = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            [pscustomobject]@{ Output = $output; ExitCode = $process.ExitCode }
        }
    }

    It 'returns the catalog' {
        $result = Invoke-Client '{"action":"catalog"}'
        $result.ExitCode | Should -Be 0
        @(($result.Output | ConvertFrom-Json).tools).Count | Should -Be 10
    }

    It 'runs a tool and writes exactly one JSON document' {
        $result = Invoke-Client '{"tool":"port-test","parameters":{"host":"127.0.0.1","ports":[1]},"requestedBy":"Jordan Lee"}'
        $result.ExitCode | Should -Be 0
        $envelope = $result.Output | ConvertFrom-Json
        $envelope.tool | Should -Be 'port-test'
        $envelope.status | Should -Be 'completed'
        $envelope.results[0].open | Should -BeFalse
    }

    It 'answers bad input with a failed document, not a crash' {
        $result = Invoke-Client 'garbage'
        $result.ExitCode | Should -Be 0
        $envelope = $result.Output | ConvertFrom-Json
        $envelope.status | Should -Be 'failed'
        $envelope.errors[0] | Should -Match 'not valid JSON'
    }

    It 'answers an unreachable endpoint with a failed document' {
        $result = Invoke-Client '{"action":"catalog"}' @('-ConfigurationName', 'NoSuchEndpoint', '-ComputerName', 'no-such-host.invalid')
        $result.ExitCode | Should -Be 0
        $envelope = $result.Output | ConvertFrom-Json
        $envelope.status | Should -Be 'failed'
        $envelope.errors[0] | Should -Match '^ITHub client script: '
    }
}

Describe 'Sample envelopes for ITHub (docs/ithub/samples)' {
    BeforeAll {
        Mock -ModuleName ITToolkit Get-ITDeviceHealth {
            New-Check 'PC0142' 'System' 'System' 'Info' 'Dell Inc. Latitude 7450, serial ABC1234, Windows 11 Enterprise 24H2 (build 26100.2314)'
            New-Check 'PC0142' 'System' 'Signed-in user' 'Info' 'CORP\jlee'
            New-Check 'PC0142' 'System' 'Device join' 'Info' 'Hybrid joined (domain CORP, tenant Example Corp); Intune enrolled (jordan.lee@example.com)'
            New-Check 'PC0142' 'Maintenance' 'Uptime' 'Warn' '23.4 days since last boot (2026-10-18 07:55)'
            New-Check 'PC0142' 'Maintenance' 'Pending reboot' 'Warn' 'Restart needed: Windows Update'
            New-Check 'PC0142' 'Storage' 'Disk C:' 'Fail' '3.1 GB free of 237.5 GB (1%)'
            New-Check 'PC0142' 'System' 'Memory' 'Info' '16.0 GB total, 5.2 GB free (33%)'
            New-Check 'PC0142' 'Security' 'BitLocker' 'OK' 'C: on'
            New-Check 'PC0142' 'Security' 'Antivirus' 'OK' 'Defender real-time protection on, signatures 0 day(s) old, tamper protection on'
            New-Check 'PC0142' 'Security' 'Firewall' 'OK' 'On for all profiles (Domain, Private, Public)'
            New-Check 'PC0142' 'Maintenance' 'Windows updates' 'OK' 'Newest update KB5044284 installed 2026-10-29 (12 days ago)'
            New-Check 'PC0142' 'Security' 'Secure Boot' 'OK' 'On'
        }
        Mock -ModuleName ITToolkit Get-ITUserStatus {
            New-UserCheckRow 'jlee' 'Active Directory' 'Account' 'Info' 'Jordan Lee (jlee, jordan.lee@example.com); Sales Manager, Sales; in corp.example.com/Users/Sales; manager Kim, Pat'
            New-UserCheckRow 'jlee' 'Active Directory' 'Enabled' 'OK' 'Enabled'
            New-UserCheckRow 'jlee' 'Active Directory' 'Lockout' 'Fail' 'Locked out since 2026-11-10 08:41 (5 bad password(s), last 2026-11-10 08:41) (read from DC01.corp.example.com). Find the cause with Get-ITLockoutSource jlee'
            New-UserCheckRow 'jlee' 'Active Directory' 'Password' 'OK' 'Last set 2026-10-21 09:12; expires 2027-01-19 09:12 (in 69 days)'
            New-UserCheckRow 'jlee' 'Active Directory' 'Last logon' 'Info' 'Around 2026-11-07 (Active Directory updates this only every 9-14 days)'
            New-UserCheckRow 'jlee' 'Entra ID' 'Sync' 'Info' 'Synced from Active Directory, last synced 2026-11-10 08:30'
            New-UserCheckRow 'jlee' 'Entra ID' 'Sign-in' 'OK' 'Allowed to sign in to Microsoft 365; last sign-in 2026-11-10 08:02'
            New-UserCheckRow 'jlee' 'Entra ID' 'Licenses' 'Info' 'Microsoft 365 Business Premium'
            New-UserCheckRow 'jlee' 'Entra ID' 'MFA methods' 'OK' 'Authenticator app (iPhone 15), Phone (mobile, ending 4512)'
        }
        Mock -ModuleName ITToolkit Get-ITLockoutSource {
            [pscustomobject]@{ PSTypeName = 'ITToolkit.Lockout'; TimeCreated = [datetime]::SpecifyKind([datetime]'2026-11-10 13:41:07', [DateTimeKind]::Utc); UserName = 'jlee'; CallerComputer = 'PC0177'; DomainController = 'DC01.corp.example.com'; Note = $null }
            [pscustomobject]@{ PSTypeName = 'ITToolkit.Lockout'; TimeCreated = [datetime]::SpecifyKind([datetime]'2026-11-10 12:10:44', [DateTimeKind]::Utc); UserName = 'jlee'; CallerComputer = ''; DomainController = 'DC01.corp.example.com'; Note = 'No caller computer recorded. Usually a phone, VPN, Outlook on the web or another network service with an old password' }
        }

        function Use-FixedTimes([string]$Json) {
            # Samples get fixed timestamps so they only change when the envelope does.
            $Json -replace '"startedAt":"[^"]+"', '"startedAt":"2026-11-10T14:05:11Z"' -replace '"finishedAt":"[^"]+"', '"finishedAt":"2026-11-10T14:05:19Z"' -replace 'Collected \d{4}-\d{2}-\d{2} \d{2}:\d{2}', 'Collected 2026-11-10 14:05'
        }

        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $openPort = $listener.LocalEndpoint.Port
        $script:samples = [ordered]@{
            'catalog'            = Get-ITHubToolCatalog
            'device-health'      = Use-FixedTimes (Invoke-ITHubTool -RequestJson '{"tool":"device-health","parameters":{"computerName":"PC0142"},"requestedBy":"Jordan Lee"}')
            'user-status'        = Use-FixedTimes (Invoke-ITHubTool -RequestJson '{"tool":"user-status","parameters":{"identity":"jlee"},"requestedBy":"Jordan Lee"}')
            'lockout-source'     = Use-FixedTimes (Invoke-ITHubTool -RequestJson '{"tool":"lockout-source","parameters":{"identity":"jlee"},"requestedBy":"Jordan Lee"}')
            'port-test'          = Use-FixedTimes ((Invoke-ITHubTool -RequestJson ('{{"tool":"port-test","parameters":{{"host":"127.0.0.1","ports":[{0},1]}},"requestedBy":"Jordan Lee"}}' -f $openPort)) -replace [regex]::Escape([string]$openPort), '8443' -replace '"source":"[^"]+"', '"source":"ITHUB01"' -replace '"latencyMs":\d+', '"latencyMs":2')
            'failed-unreachable' = $null
            'failed-validation'  = Use-FixedTimes (Invoke-ITHubTool -RequestJson '{"tool":"device-health","parameters":{"computerName":"PC0142; whoami"},"requestedBy":"Jordan Lee"}')
        }
        $listener.Stop()

        # Mocked only now, after the real port test above, so that test never depends on how
        # a Pester version treats calls a filtered mock does not match.
        Mock -ModuleName ITToolkit Open-ITTarget {
            throw 'Could not connect with PowerShell remoting. Check that the computer is on, WinRM is enabled (Enable-PSRemoting) and you are an administrator on it. Details: WinRM cannot complete the operation. Verify that the specified computer name is valid.'
        }
        $samples['failed-unreachable'] = Use-FixedTimes (Invoke-ITHubTool -RequestJson '{"tool":"local-admins","parameters":{"computerName":"PC0999"},"requestedBy":"Jordan Lee"}')

        if ($env:ITTOOLKIT_WRITE_SAMPLES -eq '1') {
            New-Item -ItemType Directory -Path $SampleFolder -Force | Out-Null
            foreach ($name in $samples.Keys) {
                $pretty = $samples[$name] | ConvertFrom-Json | ConvertTo-Json -Depth 12
                [System.IO.File]::WriteAllText((Join-Path $SampleFolder "$name.json"), $pretty + "`n", (New-Object System.Text.UTF8Encoding($false)))
            }
        }
    }

    It 'has a committed sample for <_> with the same shape the code produces now' -ForEach @(
        'catalog', 'device-health', 'user-status', 'lockout-source', 'port-test', 'failed-unreachable', 'failed-validation'
    ) {
        $path = Join-Path $SampleFolder "$_.json"
        Test-Path -LiteralPath $path | Should -BeTrue -Because 'regenerate the samples with ITTOOLKIT_WRITE_SAMPLES=1'
        $committed = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $current = $samples[$_] | ConvertFrom-Json
        (Get-KeyShape $committed) -join "`n" | Should -Be ((Get-KeyShape $current) -join "`n")
    }

    It 'shows each status in the samples' {
        ($samples['device-health'] | ConvertFrom-Json).status | Should -Be 'completed'
        ($samples['failed-unreachable'] | ConvertFrom-Json).status | Should -Be 'failed'
        ($samples['failed-validation'] | ConvertFrom-Json).status | Should -Be 'failed'
    }
}
