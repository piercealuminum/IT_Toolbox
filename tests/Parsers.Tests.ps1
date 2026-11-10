#Requires -Modules Pester
# Parsers for Windows tool output, tested against captured English output.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ITToolkit\ITToolkit.psd1') -Force
}

Describe 'ConvertFrom-ITDsregStatus' {
    It 'reads device state for a hybrid joined computer' {
        InModuleScope ITToolkit {
            $lines = @(
                '+----------------------------------------------------------------------+'
                '| Device State                                                         |'
                '+----------------------------------------------------------------------+'
                ''
                '             AzureAdJoined : YES'
                '          EnterpriseJoined : NO'
                '              DomainJoined : YES'
                '                DomainName : CORP'
                '           Virtual Desktop : NOT SET'
                '+----------------------------------------------------------------------+'
                '| Tenant Details                                                       |'
                '                TenantName : Example Corp'
                '                  TenantId : 11111111-2222-3333-4444-555555555555'
                '                    MdmUrl : https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc'
            )
            $result = ConvertFrom-ITDsregStatus -Lines $lines
            $result['AzureAdJoined'] | Should -Be 'YES'
            $result['DomainJoined'] | Should -Be 'YES'
            $result['DomainName'] | Should -Be 'CORP'
            $result['TenantName'] | Should -Be 'Example Corp'
            $result['VirtualDesktop'] | Should -Be 'NOT SET'
            $result['MdmUrl'] | Should -Be 'https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc'
        }
    }

    It 'returns an empty table for no input' {
        InModuleScope ITToolkit {
            (ConvertFrom-ITDsregStatus -Lines @()).Count | Should -Be 0
            (ConvertFrom-ITDsregStatus -Lines $null).Count | Should -Be 0
        }
    }
}

Describe 'ConvertFrom-ITQuser' {
    It 'parses active, Remote Desktop and disconnected sessions' {
        InModuleScope ITToolkit {
            $lines = @(
                ' USERNAME              SESSIONNAME        ID  STATE   IDLE TIME  LOGON TIME'
                '>jsmith                console             1  Active      none   11/10/2026 8:02 AM'
                ' adm-bob               rdp-tcp#3           2  Active          5  11/10/2026 9:15 AM'
                ' alice                                     3  Disc         1:02  11/9/2026 4:40 PM'
                ' carol                 rdp-tcp#7          14  Active  1+02:03  11/8/2026 7:00 AM'
            )
            $sessions = @(ConvertFrom-ITQuser -Lines $lines -ComputerName 'RDS01')
            $sessions.Count | Should -Be 4

            $sessions[0].UserName | Should -Be 'jsmith'
            $sessions[0].SessionName | Should -Be 'console'
            $sessions[0].Id | Should -Be 1
            $sessions[0].State | Should -Be 'Active'
            $sessions[0].IdleTime | Should -Be 'none'
            $sessions[0].ComputerName | Should -Be 'RDS01'

            $sessions[1].UserName | Should -Be 'adm-bob'
            $sessions[1].SessionName | Should -Be 'rdp-tcp#3'
            $sessions[1].IdleTime | Should -Be '5'

            $sessions[2].UserName | Should -Be 'alice'
            $sessions[2].SessionName | Should -Be ''
            $sessions[2].Id | Should -Be 3
            $sessions[2].State | Should -Be 'Disconnected'
            $sessions[2].IdleTime | Should -Be '1:02'

            $sessions[3].Id | Should -Be 14
            $sessions[3].IdleTime | Should -Be '1+02:03'
            $sessions[0].PSObject.TypeNames[0] | Should -Be 'ITToolkit.Session'
        }
    }

    It 'returns nothing when nobody is signed in' {
        InModuleScope ITToolkit {
            @(ConvertFrom-ITQuser -Lines @('No User exists for *')).Count | Should -Be 0
        }
    }
}

Describe 'ConvertFrom-ITW32tmStatus' {
    It 'reads the source and last sync time' {
        InModuleScope ITToolkit {
            $sync = (Get-Date).AddHours(-3)
            $lines = @(
                'Leap Indicator: 0(no warning)'
                'Stratum: 4 (secondary reference - syncd by (S)NTP)'
                ('Last Successful Sync Time: {0}' -f $sync.ToString())
                'Source: dc01.corp.example.com'
                'Poll Interval: 10 (1024s)'
            )
            $result = ConvertFrom-ITW32tmStatus -Lines $lines
            $result.Source | Should -Be 'dc01.corp.example.com'
            $result.LastSync | Should -BeOfType [datetime]
            [math]::Abs(($result.LastSync - $sync).TotalSeconds) | Should -BeLessThan 2
            $result.Error | Should -BeNullOrEmpty
        }
    }

    It 'strips the flags from an NTP source' {
        InModuleScope ITToolkit {
            (ConvertFrom-ITW32tmStatus -Lines @('Source: time.windows.com,0x9')).Source | Should -Be 'time.windows.com'
        }
    }

    It 'reports a stopped Windows Time service' {
        InModuleScope ITToolkit {
            $result = ConvertFrom-ITW32tmStatus -Lines @('The following error occurred: The service has not been started. (0x80070426)')
            $result.Error | Should -Be 'The service has not been started. (0x80070426)'
        }
    }
}

Describe 'ConvertFrom-ITWinHttpProxy' {
    It 'recognizes a direct connection' {
        InModuleScope ITToolkit {
            ConvertFrom-ITWinHttpProxy -Lines @('', 'Current WinHTTP proxy settings:', '', '    Direct access (no proxy server).', '') | Should -Be 'Direct'
        }
    }

    It 'reads a proxy server and bypass list' {
        InModuleScope ITToolkit {
            $lines = @('Current WinHTTP proxy settings:', '', '    Proxy Server(s) :  proxy.corp.example.com:8080', '    Bypass List     :  <local>')
            ConvertFrom-ITWinHttpProxy -Lines $lines | Should -Be 'proxy.corp.example.com:8080 (bypass: <local>)'
        }
    }
}

Describe 'ConvertTo-ITTcpTarget' {
    It 'parses <Text>' -ForEach @(
        @{ Text = 'fs01:445'; HostName = 'fs01'; Port = 445 }
        @{ Text = 'login.microsoftonline.com:443'; HostName = 'login.microsoftonline.com'; Port = 443 }
        @{ Text = '10.1.2.3:3389'; HostName = '10.1.2.3'; Port = 3389 }
        @{ Text = '[fe80::1]:443'; HostName = 'fe80::1'; Port = 443 }
    ) {
        $result = InModuleScope ITToolkit -Parameters @{ Text = $Text } { param($Text) ConvertTo-ITTcpTarget -Target $Text }
        $result.Host | Should -Be $HostName
        $result.Port | Should -Be $Port
    }

    It 'rejects <_>' -ForEach @('fs01', 'fs01:', 'fs01:99999', ':445') {
        { InModuleScope ITToolkit -Parameters @{ Text = $_ } { param($Text) ConvertTo-ITTcpTarget -Target $Text } } | Should -Throw
    }
}
