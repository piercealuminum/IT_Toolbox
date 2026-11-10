# Active Directory and Microsoft Graph lookups for the user commands.
#
# These run on the tech's computer (not on a target computer), using the ActiveDirectory
# module (RSAT) and, when it is installed and connected, Microsoft Graph PowerShell.
# They only gather data; ConvertTo-ITUserCheck judges it.

$script:ITADUserProperties = @(
    'DisplayName', 'UserPrincipalName', 'SamAccountName', 'EmailAddress', 'Title', 'Department', 'Manager',
    'Enabled', 'LockedOut', 'AccountLockoutTime', 'BadLogonCount', 'LastBadPasswordAttempt',
    'PasswordLastSet', 'PasswordExpired', 'PasswordNeverExpires', 'msDS-UserPasswordExpiryTimeComputed',
    'AccountExpirationDate', 'LastLogonDate', 'DistinguishedName'
)

function Assert-ITActiveDirectory {
    [CmdletBinding()]
    param()

    if (-not (Get-Command -Name Get-ADUser -ErrorAction SilentlyContinue)) {
        throw ('The ActiveDirectory module is not installed. On Windows 10 or 11 install it from an elevated window with: ' +
            'Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0')
    }
}

function Get-ITPdcEmulator {
    # The PDC emulator has the domain's most current lockout and bad password data, because
    # other domain controllers forward failed passwords to it. Cached for the session.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not $script:ITPdcEmulator) {
        $script:ITPdcEmulator = (Get-ADDomain -ErrorAction Stop).PDCEmulator
    }
    $script:ITPdcEmulator
}

function Resolve-ITADUser {
    # Finds one user by sAMAccountName, distinguished name, SID, GUID, UPN or email address.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Identity,

        [string]$Server,

        [string[]]$Properties = $script:ITADUserProperties
    )

    $params = @{ Properties = $Properties; ErrorAction = 'Stop' }
    if ($Server) { $params.Server = $Server }

    $value = $Identity.Trim()
    if ($value -match '@') {
        # Get-ADUser -Identity does not accept a UPN or email address, so search for it.
        $escaped = $value -replace "'", "''"
        $found = @(Get-ADUser -Filter "UserPrincipalName -eq '$escaped' -or mail -eq '$escaped'" @params)
        if ($found.Count -eq 0) { throw "No Active Directory user has the UPN or email address '$value'." }
        if ($found.Count -gt 1) {
            throw "More than one Active Directory user matches '$value': $(($found | ForEach-Object { $_.SamAccountName }) -join ', '). Use the account name."
        }
        return $found[0]
    }
    Get-ADUser -Identity $value @params
}

function Get-ITEntraUser {
    # Microsoft Graph details for one user. Never prompts to sign in: if Graph PowerShell is
    # missing or not connected, returns Available = $false with the reason.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$UserPrincipalName
    )

    $connectHint = 'Connect-MgGraph -Scopes User.Read.All, UserAuthenticationMethod.Read.All, AuditLog.Read.All'
    if (-not (Get-Command -Name Get-MgContext -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Available = $false; Reason = "Microsoft Graph PowerShell is not installed (Install-Module Microsoft.Graph.Users, Microsoft.Graph.Identity.SignIns -Scope CurrentUser), then $connectHint" }
    }
    if (-not (Get-MgContext)) {
        return [pscustomobject]@{ Available = $false; Reason = "not connected to Microsoft Graph. Run: $connectHint" }
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $baseProperties = 'id,userPrincipalName,displayName,accountEnabled,onPremisesSyncEnabled,onPremisesLastSyncDateTime'
    $user = $null
    $signInAvailable = $true
    try {
        # signInActivity needs AuditLog.Read.All and an Entra ID P1 license; fall back without it.
        $user = Get-MgUser -UserId $UserPrincipalName -Property "$baseProperties,signInActivity" -ErrorAction Stop
    }
    catch {
        $signInAvailable = $false
        try { $user = Get-MgUser -UserId $UserPrincipalName -Property $baseProperties -ErrorAction Stop }
        catch {
            return [pscustomobject]@{ Available = $false; Reason = "could not find $UserPrincipalName in Entra ID: $($_.Exception.Message)" }
        }
    }

    $lastSignIn = $null
    if ($signInAvailable -and $user.SignInActivity) { $lastSignIn = $user.SignInActivity.LastSignInDateTime }

    $licenses = @()
    try { $licenses = @(Get-MgUserLicenseDetail -UserId $user.Id -ErrorAction Stop | ForEach-Object { [string]$_.SkuPartNumber }) }
    catch { $errors.Add("licenses: $($_.Exception.Message)") }

    $methods = $null
    try {
        $methods = @(Get-MgUserAuthenticationMethod -UserId $user.Id -ErrorAction Stop | ForEach-Object {
                $extra = $_.AdditionalProperties
                [pscustomobject]@{
                    Type        = [string]$extra['@odata.type']
                    PhoneNumber = [string]$extra['phoneNumber']
                    PhoneType   = [string]$extra['phoneType']
                    DisplayName = [string]$extra['displayName']
                }
            })
    }
    catch {
        $errors.Add("MFA methods (needs UserAuthenticationMethod.Read.All): $($_.Exception.Message)")
    }

    [pscustomobject]@{
        Available       = $true
        Reason          = $null
        AccountEnabled  = $user.AccountEnabled
        SyncEnabled     = $user.OnPremisesSyncEnabled
        LastSyncTime    = $user.OnPremisesLastSyncDateTime
        SignInAvailable = $signInAvailable
        LastSignIn      = $lastSignIn
        Licenses        = $licenses
        Methods         = $methods
        Errors          = $errors.ToArray()
    }
}
