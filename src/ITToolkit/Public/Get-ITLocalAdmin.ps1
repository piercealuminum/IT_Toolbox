function Get-ITLocalAdmin {
    <#
    .SYNOPSIS
    Lists the members of the local Administrators group and where each comes from (Local, Domain, Entra ID).

    .DESCRIPTION
    Reads the local Administrators group (found by its well-known SID, so it works on any
    display language) and labels each member:
      Local     an account on the computer itself
      Domain    an Active Directory user or group
      Entra ID  an Entra ID user, group or role
      Built-in  a Windows built-in identity
    Members Windows cannot resolve (deleted accounts, unreachable domain, some Entra roles)
    are listed by SID with a note, instead of breaking the command as Get-LocalGroupMember
    does.

    Useful for least-privilege reviews and for finding who gave themselves admin rights.
    Read-only: it changes nothing on the computer.

    .PARAMETER ComputerName
    Computers to check. Defaults to this computer. Accepts pipeline input.

    .PARAMETER Credential
    Credential for remote computers. Not used for this computer.

    .EXAMPLE
    Get-ITLocalAdmin -ComputerName PC0142

    .EXAMPLE
    Get-Content .\pcs.txt | Get-ITLocalAdmin | Where-Object { $_.Source -eq 'Local' -and -not $_.Note }

    Finds local accounts, other than the built-in Administrator, with admin rights.

    .OUTPUTS
    ITToolkit.LocalAdmin
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('CN', 'DNSHostName')]
        [string[]]$ComputerName = [Environment]::MachineName,

        [System.Management.Automation.PSCredential]
        [System.Management.Automation.Credential()]
        $Credential = [System.Management.Automation.PSCredential]::Empty
    )

    process {
        foreach ($computer in $ComputerName) {
            $target = $null
            try {
                $target = Open-ITTarget -ComputerName $computer -Credential $Credential
                foreach ($member in @(Invoke-ITCollector -Name 'LocalAdmin' -Target $target)) {
                    ConvertTo-ITLocalAdmin -ComputerName $target.ComputerName -Member $member
                }
            }
            catch {
                Write-Error -Message "${computer}: $($_.Exception.Message)" -Exception $_.Exception -TargetObject $computer
            }
            finally {
                Close-ITTarget -Target $target
            }
        }
    }
}
