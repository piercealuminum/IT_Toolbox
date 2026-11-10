#Requires -Modules Pester
# User account commands. Active Directory and Microsoft Graph are replaced with stand-ins,
# so these tests check how the commands call them and judge the answers, without a domain.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ITToolkit\ITToolkit.psd1') -Force

    # Stand-ins with the parameters ITToolkit uses. Functions win over cmdlets with the same
    # name, so these are used even where the real modules are installed.
    function global:Get-ADUser { [CmdletBinding()] param($Identity, $Filter, $Properties, $Server) }
    function global:Get-ADDomain { [CmdletBinding()] param() }
    function global:Set-ADAccountPassword { [CmdletBinding()] param($Identity, [switch]$Reset, $NewPassword, $Server) }
    function global:Set-ADUser { [CmdletBinding()] param($Identity, $ChangePasswordAtLogon, $Server) }
    function global:Unlock-ADAccount { [CmdletBinding()] param($Identity, $Server) }
    function global:Get-MgContext { [CmdletBinding()] param() }
    function global:Get-MgUser { [CmdletBinding()] param($UserId, $Property) }
    function global:Get-MgUserLicenseDetail { [CmdletBinding()] param($UserId) }
    function global:Get-MgUserAuthenticationMethod { [CmdletBinding()] param($UserId) }

    function New-TestADUser {
        # A healthy user. Tests change one thing at a time.
        [pscustomobject]@{
            SamAccountName                        = 'jlee'
            UserPrincipalName                     = 'jordan.lee@example.com'
            DisplayName                           = 'Jordan Lee'
            EmailAddress                          = 'jordan.lee@example.com'
            Title                                 = 'Sales Manager'
            Department                            = 'Sales'
            Manager                               = 'CN=Kim\, Pat,OU=Sales,OU=Users,DC=corp,DC=example,DC=com'
            DistinguishedName                     = 'CN=Jordan Lee,OU=Sales,OU=Users,DC=corp,DC=example,DC=com'
            Enabled                               = $true
            LockedOut                             = $false
            AccountLockoutTime                    = $null
            BadLogonCount                         = 0
            LastBadPasswordAttempt                = $null
            PasswordLastSet                       = (Get-Date).AddDays(-20)
            PasswordExpired                       = $false
            PasswordNeverExpires                  = $false
            'msDS-UserPasswordExpiryTimeComputed' = (Get-Date).AddDays(70).ToFileTime()
            AccountExpirationDate                 = $null
            LastLogonDate                         = (Get-Date).AddDays(-3)
        }
    }

    function New-TestEntra {
        [pscustomobject]@{
            Available       = $true
            Reason          = $null
            AccountEnabled  = $true
            SyncEnabled     = $true
            LastSyncTime    = (Get-Date).ToUniversalTime().AddMinutes(-20)
            SignInAvailable = $true
            LastSignIn      = (Get-Date).ToUniversalTime().AddHours(-2)
            Licenses        = @('SPB', 'SOME_NEW_SKU')
            Methods         = @(
                [pscustomobject]@{ Type = '#microsoft.graph.passwordAuthenticationMethod'; PhoneNumber = ''; PhoneType = ''; DisplayName = '' }
                [pscustomobject]@{ Type = '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'; PhoneNumber = ''; PhoneType = ''; DisplayName = 'iPhone 15' }
                [pscustomobject]@{ Type = '#microsoft.graph.phoneAuthenticationMethod'; PhoneNumber = '+1 555 555 4512'; PhoneType = 'mobile'; DisplayName = '' }
            )
            Errors          = @()
        }
    }

    function Invoke-UserCheck($User, $Entra = $null) {
        $settings = InModuleScope ITToolkit { (Get-ITSettings).User }
        InModuleScope ITToolkit -Parameters @{ User = $User; Entra = $Entra; Settings = $settings } {
            param($User, $Entra, $Settings)
            ConvertTo-ITUserCheck -User $User -Entra $Entra -Server 'DC01.corp.example.com' -Settings $Settings
        }
    }

    function Get-Check($Results, $Name) {
        @($Results | Where-Object { $_.Check -eq $Name }) | Select-Object -First 1
    }
}

AfterAll {
    foreach ($name in 'Get-ADUser', 'Get-ADDomain', 'Set-ADAccountPassword', 'Set-ADUser', 'Unlock-ADAccount', 'Get-MgContext', 'Get-MgUser', 'Get-MgUserLicenseDetail', 'Get-MgUserAuthenticationMethod') {
        Remove-Item -LiteralPath "function:global:$name" -ErrorAction SilentlyContinue
    }
}

Describe 'ConvertFrom-ITDistinguishedName' {
    It 'reads <Dn>' -ForEach @(
        @{ Dn = 'CN=Jordan Lee,OU=Sales,OU=Users,DC=corp,DC=example,DC=com'; Name = 'Jordan Lee'; Path = 'corp.example.com/Users/Sales' }
        @{ Dn = 'CN=Kim\, Pat,OU=Sales,DC=corp,DC=example,DC=com'; Name = 'Kim, Pat'; Path = 'corp.example.com/Sales' }
        @{ Dn = 'CN=Svc Backup,CN=Users,DC=corp,DC=example,DC=com'; Name = 'Svc Backup'; Path = 'corp.example.com/Users' }
        @{ Dn = 'CN=Root,DC=corp,DC=example,DC=com'; Name = 'Root'; Path = 'corp.example.com' }
    ) {
        $result = InModuleScope ITToolkit -Parameters @{ Dn = $Dn } { param($Dn) ConvertFrom-ITDistinguishedName -DistinguishedName $Dn }
        $result.Name | Should -Be $Name
        $result.Path | Should -Be $Path
    }
}

Describe 'Format-ITPhoneNumber' {
    It 'shows only the last 4 digits' {
        InModuleScope ITToolkit {
            Format-ITPhoneNumber -PhoneNumber '+1 555 555 4512' | Should -Be 'ending 4512'
            Format-ITPhoneNumber -PhoneNumber '12' | Should -Be 'number hidden'
            Format-ITPhoneNumber -PhoneNumber $null | Should -Be 'number hidden'
        }
    }
}

Describe 'ConvertTo-ITUserCheck: Active Directory' {
    It 'rates a healthy user with no Fail or Warn' {
        $results = @(Invoke-UserCheck (New-TestADUser))
        @($results | Where-Object { $_.Status -in 'Fail', 'Warn' }) | Should -BeNullOrEmpty
        $results[0].PSObject.TypeNames[0] | Should -Be 'ITToolkit.UserCheck'
        @($results | ForEach-Object { $_.UserName } | Select-Object -Unique) | Should -Be @('jlee')
        (Get-Check $results 'Account').Detail | Should -Be 'Jordan Lee (jlee, jordan.lee@example.com); Sales Manager, Sales; in corp.example.com/Users/Sales; manager Kim, Pat'
        (Get-Check $results 'Lockout').Detail | Should -Be 'Not locked out (read from DC01.corp.example.com)'
        (Get-Check $results 'Password').Detail | Should -Match '^Last set \d{4}-\d{2}-\d{2} \d{2}:\d{2}; expires .+ \(in (69|70) days\)$'
        Get-Check $results 'Account expiry' | Should -BeNullOrEmpty
    }

    It 'fails a disabled account' {
        $user = New-TestADUser
        $user.Enabled = $false
        (Get-Check (Invoke-UserCheck $user) 'Enabled').Status | Should -Be 'Fail'
    }

    It 'fails a locked-out account and points to the lockout source' {
        $user = New-TestADUser
        $user.LockedOut = $true
        $user.AccountLockoutTime = (Get-Date).AddMinutes(-10)
        $user.BadLogonCount = 5
        $user.LastBadPasswordAttempt = (Get-Date).AddMinutes(-10)
        $check = Get-Check (Invoke-UserCheck $user) 'Lockout'
        $check.Status | Should -Be 'Fail'
        $check.Detail | Should -Match '^Locked out since .+ \(5 bad password\(s\), last .+\) \(read from DC01\.corp\.example\.com\)\. Find the cause with Get-ITLockoutSource jlee$'
    }

    It 'mentions recent bad passwords on an unlocked account' {
        $user = New-TestADUser
        $user.BadLogonCount = 2
        (Get-Check (Invoke-UserCheck $user) 'Lockout').Detail | Should -Match '^Not locked out; 2 bad password\(s\)'
    }

    It 'rates the password: <Case>' -ForEach @(
        @{ Case = 'must change'; Status = 'Warn'; Pattern = '^Must change password at next sign-in$' }
        @{ Case = 'never expires'; Status = 'Info'; Pattern = '^Never expires' }
        @{ Case = 'expired'; Status = 'Fail'; Pattern = '^Expired on .+Reset-ITUserPassword jlee$' }
        @{ Case = 'expires soon'; Status = 'Warn'; Pattern = 'in [23] days\)$' }
        @{ Case = 'no expiry policy'; Status = 'OK'; Pattern = 'no expiry under the password policy$' }
    ) {
        $user = New-TestADUser
        switch ($Case) {
            'must change' { $user.PasswordLastSet = $null; $user.'msDS-UserPasswordExpiryTimeComputed' = 0 }
            'never expires' { $user.PasswordNeverExpires = $true; $user.'msDS-UserPasswordExpiryTimeComputed' = [int64]::MaxValue }
            'expired' { $user.PasswordExpired = $true; $user.'msDS-UserPasswordExpiryTimeComputed' = (Get-Date).AddDays(-2).ToFileTime() }
            'expires soon' { $user.'msDS-UserPasswordExpiryTimeComputed' = (Get-Date).AddDays(3).ToFileTime() }
            'no expiry policy' { $user.'msDS-UserPasswordExpiryTimeComputed' = [int64]::MaxValue }
        }
        $check = Get-Check (Invoke-UserCheck $user) 'Password'
        $check.Status | Should -Be $Status
        $check.Detail | Should -Match $Pattern
    }

    It 'rates account expiry' {
        $user = New-TestADUser
        $user.AccountExpirationDate = (Get-Date).AddDays(-1)
        (Get-Check (Invoke-UserCheck $user) 'Account expiry').Status | Should -Be 'Fail'
        $user.AccountExpirationDate = (Get-Date).AddDays(5)
        (Get-Check (Invoke-UserCheck $user) 'Account expiry').Status | Should -Be 'Warn'
        $user.AccountExpirationDate = (Get-Date).AddDays(200)
        (Get-Check (Invoke-UserCheck $user) 'Account expiry').Status | Should -Be 'Info'
    }
}

Describe 'ConvertTo-ITUserCheck: Entra ID' {
    It 'reports sync, sign-in, licenses and MFA methods' {
        $results = @(Invoke-UserCheck (New-TestADUser) (New-TestEntra))
        @($results | Where-Object { $_.Status -in 'Fail', 'Warn' }) | Should -BeNullOrEmpty
        (Get-Check $results 'Sync').Detail | Should -Match '^Synced from Active Directory, last synced '
        (Get-Check $results 'Sign-in').Detail | Should -Match '^Allowed to sign in to Microsoft 365; last sign-in '
        (Get-Check $results 'Licenses').Detail | Should -Be 'Microsoft 365 Business Premium, SOME_NEW_SKU'
        (Get-Check $results 'MFA methods').Detail | Should -Be 'Authenticator app (iPhone 15), Phone (mobile, ending 4512)'
    }

    It 'warns when only a password (and email) is registered' {
        $entra = New-TestEntra
        $entra.Methods = @(
            [pscustomobject]@{ Type = '#microsoft.graph.passwordAuthenticationMethod'; PhoneNumber = ''; PhoneType = ''; DisplayName = '' }
            [pscustomobject]@{ Type = '#microsoft.graph.emailAuthenticationMethod'; PhoneNumber = ''; PhoneType = ''; DisplayName = '' }
        )
        (Get-Check (Invoke-UserCheck (New-TestADUser) $entra) 'MFA methods').Status | Should -Be 'Warn'
    }

    It 'skips the MFA check when the methods could not be read' {
        $entra = New-TestEntra
        $entra.Methods = $null
        $entra.Errors = @('MFA methods (needs UserAuthenticationMethod.Read.All): Forbidden')
        $results = Invoke-UserCheck (New-TestADUser) $entra
        Get-Check $results 'MFA methods' | Should -BeNullOrEmpty
        (Get-Check $results 'Entra ID').Detail | Should -Match '^Partly checked: MFA methods'
    }

    It 'warns about no licenses' {
        $entra = New-TestEntra
        $entra.Licenses = @()
        (Get-Check (Invoke-UserCheck (New-TestADUser) $entra) 'Licenses').Status | Should -Be 'Warn'
    }

    It 'fails a sign-in block and explains a sync delay when AD is enabled' {
        $entra = New-TestEntra
        $entra.AccountEnabled = $false
        $check = Get-Check (Invoke-UserCheck (New-TestADUser) $entra) 'Sign-in'
        $check.Status | Should -Be 'Fail'
        $check.Detail | Should -Match 'enabled in AD.+Entra Connect sync'
    }

    It 'warns when AD is disabled but Microsoft 365 sign-in still works' {
        $user = New-TestADUser
        $user.Enabled = $false
        (Get-Check (Invoke-UserCheck $user (New-TestEntra)) 'Sign-in').Status | Should -Be 'Warn'
    }

    It 'notes a cloud-only account and missing sign-in data' {
        $entra = New-TestEntra
        $entra.SyncEnabled = $false
        $entra.SignInAvailable = $false
        $entra.LastSignIn = $null
        $results = Invoke-UserCheck (New-TestADUser) $entra
        (Get-Check $results 'Sync').Detail | Should -Be 'Cloud-only account (not synced from Active Directory)'
        (Get-Check $results 'Sign-in').Detail | Should -Match 'needs AuditLog\.Read\.All'
    }

    It 'explains why Entra ID was not checked' {
        $entra = [pscustomobject]@{ Available = $false; Reason = 'not connected to Microsoft Graph. Run: Connect-MgGraph' }
        $check = Get-Check (Invoke-UserCheck (New-TestADUser) $entra) 'Entra ID'
        $check.Status | Should -Be 'Info'
        $check.Detail | Should -Be 'Not checked: not connected to Microsoft Graph. Run: Connect-MgGraph'
    }
}

Describe 'ConvertTo-ITLockout' {
    It 'reads the user and caller computer from a 4740 event' {
        $xml = @'
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="Microsoft-Windows-Security-Auditing"/><EventID>4740</EventID><Computer>DC01.corp.example.com</Computer></System><EventData><Data Name="TargetUserName">jlee</Data><Data Name="TargetDomainName">PC0142</Data><Data Name="TargetSid">S-1-5-21-1-2-3-1105</Data><Data Name="SubjectUserSid">S-1-5-18</Data><Data Name="SubjectUserName">DC01$</Data><Data Name="SubjectDomainName">CORP</Data></EventData></Event>
'@
        $time = Get-Date
        $result = InModuleScope ITToolkit -Parameters @{ Record = [pscustomobject]@{ TimeCreated = $time; Xml = $xml } } { param($Record) ConvertTo-ITLockout -Record $Record }
        $result.UserName | Should -Be 'jlee'
        $result.CallerComputer | Should -Be 'PC0142'
        $result.DomainController | Should -Be 'DC01.corp.example.com'
        $result.TimeCreated | Should -Be $time
        $result.Note | Should -BeNullOrEmpty
    }

    It 'explains a blank caller computer' {
        $xml = '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Computer>DC01</Computer></System><EventData><Data Name="TargetUserName">jlee</Data><Data Name="TargetDomainName"></Data></EventData></Event>'
        $result = InModuleScope ITToolkit -Parameters @{ Record = [pscustomobject]@{ TimeCreated = (Get-Date); Xml = $xml } } { param($Record) ConvertTo-ITLockout -Record $Record }
        $result.CallerComputer | Should -Be ''
        $result.Note | Should -Match 'phone, VPN'
    }
}

Describe 'Get-ITUserStatus' {
    BeforeEach {
        InModuleScope ITToolkit { $script:ITPdcEmulator = $null }
        Mock -ModuleName ITToolkit Get-ADDomain { [pscustomobject]@{ PDCEmulator = 'DC01.corp.example.com' } }
        Mock -ModuleName ITToolkit Get-ADUser { New-TestADUser }
        Mock -ModuleName ITToolkit Get-MgContext { [pscustomobject]@{ Account = 'admin@example.com' } }
        Mock -ModuleName ITToolkit Get-MgUser {
            [pscustomobject]@{ Id = 'user-id-1'; AccountEnabled = $true; OnPremisesSyncEnabled = $true; OnPremisesLastSyncDateTime = (Get-Date).ToUniversalTime(); SignInActivity = [pscustomobject]@{ LastSignInDateTime = (Get-Date).ToUniversalTime() } }
        }
        Mock -ModuleName ITToolkit Get-MgUserLicenseDetail { [pscustomobject]@{ SkuPartNumber = 'SPE_E3' } }
        Mock -ModuleName ITToolkit Get-MgUserAuthenticationMethod {
            [pscustomobject]@{ Id = 'm1'; AdditionalProperties = @{ '@odata.type' = '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'; displayName = 'Pixel 9' } }
        }
    }

    It 'reads the account from the PDC emulator by account name and adds Entra ID' {
        $results = @(Get-ITUserStatus jlee)
        Should -Invoke -ModuleName ITToolkit Get-ADUser -Times 1 -Exactly -ParameterFilter { $Identity -eq 'jlee' -and $Server -eq 'DC01.corp.example.com' }
        Should -Invoke -ModuleName ITToolkit Get-MgUser -ParameterFilter { $UserId -eq 'jordan.lee@example.com' }
        (Get-Check $results 'Licenses').Detail | Should -Be 'Microsoft 365 E3'
        (Get-Check $results 'MFA methods').Detail | Should -Be 'Authenticator app (Pixel 9)'
    }

    It 'searches by UPN or email address' {
        $null = Get-ITUserStatus 'jordan.lee@example.com' -SkipEntra
        Should -Invoke -ModuleName ITToolkit Get-ADUser -Times 1 -Exactly -ParameterFilter { $Filter -eq "UserPrincipalName -eq 'jordan.lee@example.com' -or mail -eq 'jordan.lee@example.com'" }
    }

    It 'skips Entra ID with -SkipEntra' {
        $results = @(Get-ITUserStatus jlee -SkipEntra)
        @($results | Where-Object { $_.Category -eq 'Entra ID' }) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName ITToolkit Get-MgUser -Times 0 -Exactly
    }

    It 'says how to connect when Microsoft Graph is not connected' {
        Mock -ModuleName ITToolkit Get-MgContext { $null }
        $check = Get-Check @(Get-ITUserStatus jlee) 'Entra ID'
        $check.Detail | Should -Match 'Connect-MgGraph -Scopes User\.Read\.All'
    }

    It 'still reads Entra ID without sign-in activity (no AuditLog permission or P1)' {
        Mock -ModuleName ITToolkit Get-MgUser -ParameterFilter { $Property -like '*signInActivity*' } { throw 'Forbidden' }
        $check = Get-Check @(Get-ITUserStatus jlee) 'Sign-in'
        $check.Status | Should -Be 'OK'
        $check.Detail | Should -Match 'not available'
    }

    It 'reports an unknown user as an error and continues with the next' {
        Mock -ModuleName ITToolkit Get-ADUser -ParameterFilter { $Identity -eq 'nobody' } { throw "Cannot find an object with identity: 'nobody'" }
        $errors = @()
        $results = @('nobody', 'jlee' | Get-ITUserStatus -SkipEntra -ErrorAction SilentlyContinue -ErrorVariable errors)
        @($errors | Where-Object { "$_" -match '^nobody: Cannot find' }).Count | Should -Be 1
        @($results | Where-Object { $_.UserName -eq 'jlee' }).Count | Should -BeGreaterThan 0
    }

    It 'makes a ticket note titled for the user' {
        $note = Get-ITUserStatus jlee -SkipEntra | ConvertTo-ITTicketNote
        $note | Should -Match '^== User account check =='
        $note | Should -Match 'jlee: 0 fail, 0 warn'
    }
}

Describe 'Reset-ITUserPassword' {
    BeforeEach {
        InModuleScope ITToolkit { $script:ITPdcEmulator = $null }
        Mock -ModuleName ITToolkit Get-ADDomain { [pscustomobject]@{ PDCEmulator = 'DC01.corp.example.com' } }
        Mock -ModuleName ITToolkit Get-ADUser { $user = New-TestADUser; $user.LockedOut = $true; $user }
        Mock -ModuleName ITToolkit Set-ADAccountPassword { }
        Mock -ModuleName ITToolkit Set-ADUser { }
        Mock -ModuleName ITToolkit Unlock-ADAccount { }
    }

    It 'changes nothing with -WhatIf' {
        Reset-ITUserPassword jlee -WhatIf | Should -BeNullOrEmpty
        Should -Invoke -ModuleName ITToolkit Set-ADAccountPassword -Times 0 -Exactly
        Should -Invoke -ModuleName ITToolkit Set-ADUser -Times 0 -Exactly
        Should -Invoke -ModuleName ITToolkit Unlock-ADAccount -Times 0 -Exactly
    }

    It 'sets the shown passphrase, requires a change and unlocks, on the PDC emulator' {
        $script:setPassword = $null
        Mock -ModuleName ITToolkit Set-ADAccountPassword {
            $script:setPassword = [System.Net.NetworkCredential]::new('', $NewPassword).Password
        }
        $result = Reset-ITUserPassword jlee -Confirm:$false
        $result.Passphrase | Should -MatchExactly '^([A-Z][a-z]+-){3}[A-Z][a-z]+\d{2}$'
        $script:setPassword | Should -BeExactly $result.Passphrase
        $result.MustChangeAtNextSignIn | Should -BeTrue
        $result.Unlocked | Should -BeTrue
        $result.Problems | Should -BeNullOrEmpty
        Should -Invoke -ModuleName ITToolkit Set-ADAccountPassword -Times 1 -Exactly -ParameterFilter { $Reset -and $Server -eq 'DC01.corp.example.com' }
        Should -Invoke -ModuleName ITToolkit Set-ADUser -Times 1 -Exactly -ParameterFilter { $ChangePasswordAtLogon -eq $true }
        Should -Invoke -ModuleName ITToolkit Unlock-ADAccount -Times 1 -Exactly
    }

    It 'does not unlock an account that is not locked, and honors -NoChangeAtNextSignIn' {
        Mock -ModuleName ITToolkit Get-ADUser { New-TestADUser }
        $result = Reset-ITUserPassword jlee -NoChangeAtNextSignIn -Confirm:$false
        $result.Unlocked | Should -BeFalse
        $result.MustChangeAtNextSignIn | Should -BeFalse
        Should -Invoke -ModuleName ITToolkit Unlock-ADAccount -Times 0 -Exactly
        Should -Invoke -ModuleName ITToolkit Set-ADUser -Times 0 -Exactly
    }

    It 'still returns the new passphrase when a later step fails' {
        Mock -ModuleName ITToolkit Unlock-ADAccount { throw 'Access is denied' }
        $warnings = @()
        $result = Reset-ITUserPassword jlee -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Passphrase | Should -Not -BeNullOrEmpty
        $result.Unlocked | Should -BeFalse
        $result.Problems | Should -Match 'could not unlock the account: Access is denied'
        @($warnings | Where-Object { "$_" -match 'password was reset, but could not unlock' }).Count | Should -Be 1
    }

    It 'returns nothing and reports an error when the reset itself fails' {
        Mock -ModuleName ITToolkit Set-ADAccountPassword { throw 'The password does not meet the length, complexity, or history requirement' }
        $errors = @()
        $result = Reset-ITUserPassword jlee -Confirm:$false -ErrorAction SilentlyContinue -ErrorVariable errors
        $result | Should -BeNullOrEmpty
        @($errors | Where-Object { "$_" -match '^jlee: The password does not meet' }).Count | Should -Be 1
        Should -Invoke -ModuleName ITToolkit Unlock-ADAccount -Times 0 -Exactly
    }

    It 'never puts the passphrase in a ticket note' {
        $result = Reset-ITUserPassword jlee -Confirm:$false
        $note = $result | ConvertTo-ITTicketNote
        $note | Should -Match '^== Password reset =='
        $note | Should -Match 'jlee'
        $note.Contains($result.Passphrase) | Should -BeFalse
        $note | Should -Match 'not recorded here'
    }
}

Describe 'Get-ITLockoutSource' {
    BeforeEach {
        InModuleScope ITToolkit { $script:ITPdcEmulator = $null }
        Mock -ModuleName ITToolkit Get-ADDomain { [pscustomobject]@{ PDCEmulator = 'DC01.corp.example.com' } }
        Mock -ModuleName ITToolkit Open-ITTarget { [pscustomobject]@{ ComputerName = $ComputerName; IsLocal = $true; Session = $null } }
        Mock -ModuleName ITToolkit Invoke-ITCollector -ParameterFilter { $Name -eq 'LockoutEvents' } {
            $make = {
                param($minutes, $user, $caller)
                [pscustomobject]@{
                    TimeCreated = (Get-Date).AddMinutes(-$minutes)
                    Xml         = "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><Computer>DC01.corp.example.com</Computer></System><EventData><Data Name='TargetUserName'>$user</Data><Data Name='TargetDomainName'>$caller</Data></EventData></Event>"
                }
            }
            [pscustomobject]@{
                Events = @((& $make 90 'JLee' 'PC0142'), (& $make 30 'JLee' 'PC0177'), (& $make 45 'akim' 'PC0001'))
                Errors = @()
            }
        }
        Mock -ModuleName ITToolkit Get-ADUser { [pscustomobject]@{ SamAccountName = 'JLee' } }
    }

    It 'reads the PDC emulator and lists the user''s lockouts newest first, in any case' {
        $results = @(Get-ITLockoutSource jlee)
        Should -Invoke -ModuleName ITToolkit Open-ITTarget -ParameterFilter { $ComputerName -eq 'DC01.corp.example.com' }
        $results.Count | Should -Be 2
        $results[0].CallerComputer | Should -Be 'PC0177'
        $results[1].CallerComputer | Should -Be 'PC0142'
        $results[0].PSObject.TypeNames[0] | Should -Be 'ITToolkit.Lockout'
    }

    It 'accepts a UPN' {
        @(Get-ITLockoutSource 'jordan.lee@example.com').Count | Should -Be 2
    }

    It 'lists every lockout without -Identity' {
        @(Get-ITLockoutSource).Count | Should -Be 3
    }

    It 'warns when the Security log cannot be read' {
        Mock -ModuleName ITToolkit Invoke-ITCollector -ParameterFilter { $Name -eq 'LockoutEvents' } {
            [pscustomobject]@{ Events = @(); Errors = @('could not read the Security log: Access is denied') }
        }
        $warnings = @()
        $null = Get-ITLockoutSource jlee -WarningVariable warnings -WarningAction SilentlyContinue
        @($warnings | Where-Object { "$_" -match 'Access is denied' }).Count | Should -Be 1
    }
}
