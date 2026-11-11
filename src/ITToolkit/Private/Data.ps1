# Reference data used by several commands.

# Event log entries worth explaining, keyed 'Provider|Id' (or 'Provider|*' for every Id).
$script:ITEventNotes = @{
    'Microsoft-Windows-Kernel-Power|41'               = 'Restarted without a clean shutdown (power loss, hard reset or crash)'
    'EventLog|6008'                                   = 'The previous shutdown was unexpected'
    'User32|1074'                                     = 'Restart or shutdown was requested; the message says by whom or what'
    'Microsoft-Windows-WER-SystemErrorReporting|1001' = 'Blue screen (bugcheck); the message has the stop code'
    'Service Control Manager|7031'                    = 'A service crashed and Windows restarted it'
    'Service Control Manager|7034'                    = 'A service crashed'
    'disk|7'                                          = 'Bad block on a disk; check the drive health'
    'disk|51'                                         = 'Disk paging error; check the drive and cable'
    'disk|153'                                        = 'Disk I/O had to be retried; the drive may be failing'
    'Microsoft-Windows-WHEA-Logger|*'                 = 'Hardware error reported (CPU, memory or PCIe)'
    'Application Error|1000'                          = 'An application crashed; the message names it'
    'Application Hang|1002'                           = 'An application stopped responding'
    'NETLOGON|5719'                                   = 'Could not reach a domain controller'
    'Microsoft-Windows-GroupPolicy|1129'              = 'Group Policy failed: no connection to a domain controller'
    'Microsoft-Windows-Time-Service|129'              = 'Windows Time could not reach a time source'
}

# Well-known TCP ports, used to label Test-ITPort results.
$script:ITPortNames = @{
    22   = 'SSH'
    25   = 'SMTP'
    53   = 'DNS'
    80   = 'HTTP'
    88   = 'Kerberos'
    135  = 'RPC'
    139  = 'NetBIOS'
    389  = 'LDAP'
    443  = 'HTTPS'
    445  = 'SMB'
    464  = 'Kerberos password'
    587  = 'SMTP submission'
    631  = 'IPP printing'
    636  = 'LDAPS'
    993  = 'IMAPS'
    1433 = 'SQL Server'
    3268 = 'Global catalog'
    3269 = 'Global catalog SSL'
    3389 = 'RDP'
    5985 = 'WinRM HTTP'
    5986 = 'WinRM HTTPS'
    9100 = 'Raw printing'
}

# Port sets for Test-ITPort -Preset.
$script:ITPortPresets = @{
    DomainController = @(53, 88, 135, 389, 445, 464, 636, 3268, 3269)
    Email            = @(25, 587, 993)
    Printer          = @(9100, 631)
    RDP              = @(3389)
    SMB              = @(445)
    SQL              = @(1433)
    SSH              = @(22)
    Web              = @(80, 443)
    WinRM            = @(5985, 5986)
}

# Commands each collector uses from modules that are not always loaded, and the modules
# that provide them. Invoke-ITCollector loads them before running a collector locally
# (inside the ITHub JEA endpoint nothing loads automatically). Remote sessions load their
# own. The tests check every Get-/Test-/Resolve-/Confirm- command a collector calls is either
# built in or listed here.
$script:ITCollectorDependencies = @{
    PendingReboot = @(@{ Command = 'Get-CimInstance'; Module = @('CimCmdlets') })
    DeviceHealth  = @(
        @{ Command = 'Get-CimInstance'; Module = @('CimCmdlets') }
        @{ Command = 'Get-MpComputerStatus'; Module = @('ConfigDefender', 'Defender') }
        @{ Command = 'Get-NetFirewallProfile'; Module = @('NetSecurity') }
        @{ Command = 'Get-HotFix'; Module = @('Microsoft.PowerShell.Management') }
    )
    EventLog      = @(@{ Command = 'Get-WinEvent'; Module = @('Microsoft.PowerShell.Diagnostics') })
    LockoutEvents = @(@{ Command = 'Get-WinEvent'; Module = @('Microsoft.PowerShell.Diagnostics') })
    TempFiles     = @(@{ Command = 'Get-CimInstance'; Module = @('CimCmdlets') })
    NetworkConfig = @(
        @{ Command = 'Get-NetIPConfiguration'; Module = @('NetTCPIP') }
        @{ Command = 'Resolve-DnsName'; Module = @('DnsClient') }
    )
}
