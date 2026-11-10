# Turn Active Directory and Entra ID data into user account results. Like the computer
# converters, these hold every rule and message and are tested without a domain.

$script:ITLicenseNames = @{
    'SPE_E3'                   = 'Microsoft 365 E3'
    'SPE_E5'                   = 'Microsoft 365 E5'
    'SPE_F1'                   = 'Microsoft 365 F3'
    'SPB'                      = 'Microsoft 365 Business Premium'
    'O365_BUSINESS_PREMIUM'    = 'Microsoft 365 Business Standard'
    'O365_BUSINESS_ESSENTIALS' = 'Microsoft 365 Business Basic'
    'ENTERPRISEPACK'           = 'Office 365 E3'
    'ENTERPRISEPREMIUM'        = 'Office 365 E5'
    'STANDARDPACK'             = 'Office 365 E1'
    'DESKLESSPACK'             = 'Office 365 F3'
    'EXCHANGESTANDARD'         = 'Exchange Online (Plan 1)'
    'EXCHANGEENTERPRISE'       = 'Exchange Online (Plan 2)'
    'EMS'                      = 'Enterprise Mobility + Security E3'
    'AAD_PREMIUM'              = 'Entra ID P1'
    'AAD_PREMIUM_P2'           = 'Entra ID P2'
}

$script:ITAuthMethodNames = @{
    '#microsoft.graph.microsoftAuthenticatorAuthenticationMethod'  = 'Authenticator app'
    '#microsoft.graph.phoneAuthenticationMethod'                   = 'Phone'
    '#microsoft.graph.fido2AuthenticationMethod'                   = 'Security key (FIDO2)'
    '#microsoft.graph.windowsHelloForBusinessAuthenticationMethod' = 'Windows Hello for Business'
    '#microsoft.graph.softwareOathAuthenticationMethod'            = 'Authenticator code (OATH)'
    '#microsoft.graph.hardwareOathAuthenticationMethod'            = 'Hardware token (OATH)'
    '#microsoft.graph.temporaryAccessPassAuthenticationMethod'     = 'Temporary Access Pass'
    '#microsoft.graph.platformCredentialAuthenticationMethod'      = 'Platform credential (Mac)'
    '#microsoft.graph.passwordAuthenticationMethod'                = 'Password'
    '#microsoft.graph.emailAuthenticationMethod'                   = 'Email'
}

function ConvertFrom-ITDistinguishedName {
    # 'CN=Jordan Lee,OU=Sales,OU=Users,DC=corp,DC=example,DC=com' ->
    #   Name 'Jordan Lee', Path 'corp.example.com/Users/Sales'
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$DistinguishedName
    )

    if (-not $DistinguishedName) { return [pscustomobject]@{ Name = $null; Path = $null } }
    # Split on commas that are not escaped with a backslash.
    $parts = @([regex]::Split($DistinguishedName, '(?<!\\),') | ForEach-Object { $_.Trim() })
    $name = $null
    $ous = New-Object System.Collections.Generic.List[string]
    $dcs = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $key, $value = $parts[$i] -split '=', 2
        $value = $value -replace '\\(.)', '$1'
        switch ($key.ToUpperInvariant()) {
            'CN' { if ($i -eq 0) { $name = $value } else { $ous.Add($value) } }
            'OU' { $ous.Add($value) }
            'DC' { $dcs.Add($value) }
        }
    }
    $segments = @($dcs -join '.') + @($ous.ToArray()[($ous.Count - 1)..0] | Where-Object { $_ })
    if (-not $ous.Count) { $segments = @($dcs -join '.') }
    [pscustomobject]@{
        Name = $name
        Path = ($segments | Where-Object { $_ }) -join '/'
    }
}

function Format-ITPhoneNumber {
    # Shows only the last digits, enough to confirm with the caller ("ending 4512").
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PhoneNumber
    )

    $digits = ($PhoneNumber -replace '\D', '')
    if ($digits.Length -lt 4) { return 'number hidden' }
    'ending ' + $digits.Substring($digits.Length - 4)
}

function New-ITUserCheck {
    [CmdletBinding()]
    param(
        [string]$UserName,
        [string]$Category,
        [string]$Check,
        [ValidateSet('OK', 'Warn', 'Fail', 'Info')]
        [string]$Status,
        [string]$Detail
    )

    [pscustomobject]@{
        PSTypeName = 'ITToolkit.UserCheck'
        UserName   = $UserName
        Category   = $Category
        Check      = $Check
        Status     = $Status
        Detail     = $Detail
    }
}

function ConvertTo-ITUserCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $User,

        [AllowNull()]
        $Entra,

        [string]$Server,

        [Parameter(Mandatory)]
        [hashtable]$Settings,

        [datetime]$Now = (Get-Date)
    )

    $userName = [string]$User.SamAccountName
    $results = New-Object System.Collections.Generic.List[object]
    function Add-Check([string]$Category, [string]$Check, [string]$Status, [string]$Detail) {
        $results.Add((New-ITUserCheck -UserName $userName -Category $Category -Check $Check -Status $Status -Detail $Detail))
    }
    $dateFormat = 'yyyy-MM-dd HH:mm'
    $from = if ($Server) { " (read from $Server)" } else { '' }

    # Account
    $parts = @()
    $name = if ($User.DisplayName) { [string]$User.DisplayName } else { $userName }
    $ids = @($userName, [string]$User.UserPrincipalName | Where-Object { $_ } | Select-Object -Unique) -join ', '
    $parts += "$name ($ids)"
    $job = @([string]$User.Title, [string]$User.Department | Where-Object { $_ }) -join ', '
    if ($job) { $parts += $job }
    $location = (ConvertFrom-ITDistinguishedName -DistinguishedName $User.DistinguishedName).Path
    if ($location) { $parts += "in $location" }
    $manager = (ConvertFrom-ITDistinguishedName -DistinguishedName $User.Manager).Name
    if ($manager) { $parts += "manager $manager" }
    Add-Check 'Active Directory' 'Account' 'Info' ($parts -join '; ')

    # Enabled
    if ($User.Enabled) { Add-Check 'Active Directory' 'Enabled' 'OK' 'Enabled' }
    else { Add-Check 'Active Directory' 'Enabled' 'Fail' 'Disabled in Active Directory' }

    # Lockout (bad password counts are kept per domain controller)
    $badCount = [int]$User.BadLogonCount
    $badText = ''
    if ($badCount -gt 0) {
        $badText = "$badCount bad password(s)"
        if ($User.LastBadPasswordAttempt) { $badText += ', last {0}' -f ([datetime]$User.LastBadPasswordAttempt).ToString($dateFormat) }
    }
    if ($User.LockedOut) {
        $detail = 'Locked out'
        if ($User.AccountLockoutTime) { $detail += ' since {0}' -f ([datetime]$User.AccountLockoutTime).ToString($dateFormat) }
        if ($badText) { $detail += " ($badText)" }
        $detail += "$from. Find the cause with Get-ITLockoutSource $userName"
        Add-Check 'Active Directory' 'Lockout' 'Fail' $detail
    }
    else {
        $detail = 'Not locked out'
        if ($badText) { $detail += "; $badText" }
        Add-Check 'Active Directory' 'Lockout' 'OK' ($detail + $from)
    }

    # Password
    $expiry = $null
    $expiryRaw = $User.'msDS-UserPasswordExpiryTimeComputed'
    if ($null -ne $expiryRaw -and [int64]$expiryRaw -gt 0 -and [int64]$expiryRaw -lt [int64]::MaxValue) {
        try { $expiry = [datetime]::FromFileTime([int64]$expiryRaw) } catch { $expiry = $null }
    }
    $lastSet = if ($User.PasswordLastSet) { ([datetime]$User.PasswordLastSet).ToString($dateFormat) } else { $null }
    if (-not $User.PasswordLastSet -or ($null -ne $expiryRaw -and [int64]$expiryRaw -eq 0)) {
        Add-Check 'Active Directory' 'Password' 'Warn' 'Must change password at next sign-in'
    }
    elseif ($User.PasswordNeverExpires) {
        Add-Check 'Active Directory' 'Password' 'Info' "Never expires (set on the account); last set $lastSet"
    }
    elseif ($User.PasswordExpired -or ($expiry -and $expiry -le $Now)) {
        $when = if ($expiry) { ' on ' + $expiry.ToString($dateFormat) } else { '' }
        Add-Check 'Active Directory' 'Password' 'Fail' "Expired$when (last set $lastSet). Reset it with Reset-ITUserPassword $userName"
    }
    elseif ($expiry) {
        $days = [int][math]::Floor(($expiry - $Now).TotalDays)
        $status = if ($days -lt $Settings.PasswordExpiryWarnDays) { 'Warn' } else { 'OK' }
        Add-Check 'Active Directory' 'Password' $status ('Last set {0}; expires {1} (in {2} days)' -f $lastSet, $expiry.ToString($dateFormat), $days)
    }
    else {
        Add-Check 'Active Directory' 'Password' 'OK' "Last set $lastSet; no expiry under the password policy"
    }

    # Account expiry (only shown when one is set)
    if ($User.AccountExpirationDate) {
        $expires = [datetime]$User.AccountExpirationDate
        $days = [int][math]::Floor(($expires - $Now).TotalDays)
        if ($expires -le $Now) { Add-Check 'Active Directory' 'Account expiry' 'Fail' ('Account expired on {0}' -f $expires.ToString($dateFormat)) }
        elseif ($days -lt $Settings.AccountExpiryWarnDays) { Add-Check 'Active Directory' 'Account expiry' 'Warn' ('Account expires {0} (in {1} days)' -f $expires.ToString($dateFormat), $days) }
        else { Add-Check 'Active Directory' 'Account expiry' 'Info' ('Account expires {0}' -f $expires.ToString($dateFormat)) }
    }

    # Last logon (lastLogonTimestamp only replicates every 9-14 days)
    if ($User.LastLogonDate) {
        Add-Check 'Active Directory' 'Last logon' 'Info' ('Around {0} (Active Directory updates this only every 9-14 days)' -f ([datetime]$User.LastLogonDate).ToString('yyyy-MM-dd'))
    }
    else {
        Add-Check 'Active Directory' 'Last logon' 'Info' 'Never signed in to the domain'
    }

    # Entra ID
    if ($null -ne $Entra) {
        if (-not $Entra.Available) {
            Add-Check 'Entra ID' 'Entra ID' 'Info' "Not checked: $($Entra.Reason)"
        }
        else {
            if ($Entra.SyncEnabled) {
                $detail = 'Synced from Active Directory'
                if ($Entra.LastSyncTime) { $detail += ', last synced {0}' -f ([datetime]$Entra.LastSyncTime).ToLocalTime().ToString($dateFormat) }
                Add-Check 'Entra ID' 'Sync' 'Info' $detail
            }
            else {
                Add-Check 'Entra ID' 'Sync' 'Info' 'Cloud-only account (not synced from Active Directory)'
            }

            $lastSignIn = ''
            if ($Entra.LastSignIn) { $lastSignIn = '; last sign-in {0}' -f ([datetime]$Entra.LastSignIn).ToLocalTime().ToString($dateFormat) }
            elseif (-not $Entra.SignInAvailable) { $lastSignIn = '; last sign-in not available (needs AuditLog.Read.All and Entra ID P1)' }
            if ($Entra.AccountEnabled) {
                if ($Entra.SyncEnabled -and -not $User.Enabled) {
                    Add-Check 'Entra ID' 'Sign-in' 'Warn' "Still allowed to sign in to Microsoft 365 although disabled in AD; the next Entra Connect sync (up to 30 minutes) will block it$lastSignIn"
                }
                else {
                    Add-Check 'Entra ID' 'Sign-in' 'OK' "Allowed to sign in to Microsoft 365$lastSignIn"
                }
            }
            else {
                if ($Entra.SyncEnabled -and $User.Enabled) {
                    Add-Check 'Entra ID' 'Sign-in' 'Fail' "Blocked from signing in to Microsoft 365 but enabled in AD. If it was just enabled in AD, wait for the next Entra Connect sync (up to 30 minutes)$lastSignIn"
                }
                else {
                    Add-Check 'Entra ID' 'Sign-in' 'Fail' "Blocked from signing in to Microsoft 365$lastSignIn"
                }
            }

            $licenses = @($Entra.Licenses | Where-Object { $_ } | ForEach-Object {
                    if ($script:ITLicenseNames.ContainsKey($_)) { $script:ITLicenseNames[$_] } else { $_ }
                })
            if ($licenses.Count) { Add-Check 'Entra ID' 'Licenses' 'Info' ($licenses -join ', ') }
            else { Add-Check 'Entra ID' 'Licenses' 'Warn' 'No Microsoft 365 licenses assigned' }

            if ($null -ne $Entra.Methods) {
                $mfa = @(foreach ($method in @($Entra.Methods | Where-Object { $_ })) {
                        if ($method.Type -in @('#microsoft.graph.passwordAuthenticationMethod', '#microsoft.graph.emailAuthenticationMethod')) { continue }
                        $label = $script:ITAuthMethodNames[$method.Type]
                        if (-not $label) { $label = ($method.Type -replace '^#microsoft\.graph\.', '' -replace 'AuthenticationMethod$', '') }
                        if ($method.Type -eq '#microsoft.graph.phoneAuthenticationMethod') {
                            $kind = if ($method.PhoneType) { "$($method.PhoneType), " } else { '' }
                            $label += " ($kind$(Format-ITPhoneNumber -PhoneNumber $method.PhoneNumber))"
                        }
                        elseif ($method.DisplayName) {
                            $label += " ($($method.DisplayName))"
                        }
                        $label
                    })
                if ($mfa.Count) { Add-Check 'Entra ID' 'MFA methods' 'OK' ($mfa -join ', ') }
                else { Add-Check 'Entra ID' 'MFA methods' 'Warn' 'No MFA method registered; the user cannot complete an MFA prompt' }
            }

            if (@($Entra.Errors).Count) {
                Add-Check 'Entra ID' 'Entra ID' 'Info' ('Partly checked: ' + (@($Entra.Errors) -join '; '))
            }
        }
    }

    $results.ToArray()
}

function ConvertTo-ITLockout {
    # One 4740 (account locked out) event, as its XML, into a result. In 4740 the field named
    # TargetDomainName holds the caller computer: where the bad passwords came from.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Record
    )

    $xml = [xml]$Record.Xml
    $data = @{}
    foreach ($item in @($xml.Event.EventData.Data)) {
        if ($item -and $item.Name) { $data[$item.Name] = [string]$item.'#text' }
    }
    $caller = [string]$data['TargetDomainName']
    $note = $null
    if (-not $caller) {
        $note = 'No caller computer recorded. Usually a phone, VPN, Outlook on the web or another network service with an old password'
    }
    [pscustomobject]@{
        PSTypeName       = 'ITToolkit.Lockout'
        TimeCreated      = $Record.TimeCreated
        UserName         = $data['TargetUserName']
        CallerComputer   = $caller
        DomainController = [string]$xml.Event.System.Computer
        Note             = $note
    }
}
