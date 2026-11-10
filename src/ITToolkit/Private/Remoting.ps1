# How ITToolkit reaches a computer.
#
# Every command follows the same pattern:
#   1. Open-ITTarget        - this computer, or a PowerShell remoting session to another one
#   2. Invoke-ITCollector   - run a collector (Private\Collectors.ps1) there; it returns raw data
#   3. ConvertTo-IT*        - turn the raw data into results here, on the tech's computer
#   4. Close-ITTarget       - remove the remoting session
# Keeping the checks and wording in step 3 means they behave the same for local and remote
# computers, and can be tested without Windows.

function Test-ITLocalComputer {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string]$ComputerName
    )

    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return $true }
    $name = $ComputerName.Trim()
    $machine = [Environment]::MachineName
    if ($name -in @('.', 'localhost', '127.0.0.1', '::1')) { return $true }
    if ($name -eq $machine) { return $true }
    if ($name -like "$machine.*") { return $true }
    return $false
}

function Open-ITTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [System.Management.Automation.PSCredential]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    if (Test-ITLocalComputer -ComputerName $ComputerName) {
        # 32-bit PowerShell on 64-bit Windows sees redirected System32 and registry paths and
        # would report wrong results (missing software, "not joined"), so refuse it outright.
        if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            throw 'ITToolkit needs 64-bit PowerShell. This window is the 32-bit (x86) version; open "Windows PowerShell" or PowerShell 7 instead.'
        }
        return [pscustomobject]@{
            ComputerName = [Environment]::MachineName
            IsLocal      = $true
            Session      = $null
        }
    }

    $params = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
    if ($Credential -and $Credential -ne [System.Management.Automation.PSCredential]::Empty) {
        $params.Credential = $Credential
    }
    try {
        $session = New-PSSession @params
    }
    catch {
        throw ("Could not connect with PowerShell remoting. Check that the computer is on, WinRM is enabled " +
            "(Enable-PSRemoting) and you are an administrator on it. Details: $($_.Exception.Message)")
    }

    [pscustomobject]@{
        ComputerName = $ComputerName
        IsLocal      = $false
        Session      = $session
    }
}

function Close-ITTarget {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Target
    )

    if ($Target -and $Target.Session) {
        # -WhatIf:$false so Clear-ITTempFile -WhatIf does not leave the session open.
        Remove-PSSession -Session $Target.Session -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
    }
}

function Invoke-ITCollector {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        $Target,

        [object[]]$ArgumentList = @()
    )

    $scriptBlock = $script:ITCollectors[$Name]
    if (-not $scriptBlock) { throw "ITToolkit: unknown collector '$Name'." }

    if ($Target.IsLocal) {
        # A remote collector starts with default preferences. Give a local one the same, so a
        # caller's -ErrorAction Stop or -WhatIf cannot change what it collects.
        $ErrorActionPreference = 'Continue'
        $WarningPreference = 'Continue'
        $WhatIfPreference = $false
        $ConfirmPreference = 'High'
        & $scriptBlock @ArgumentList
    }
    else {
        Invoke-Command -Session $Target.Session -ScriptBlock $scriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    }
}
