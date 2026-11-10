function Get-ITToolkitSetting {
    <#
    .SYNOPSIS
    Shows the ITToolkit settings in effect (thresholds, DNS names, test targets) and where each value comes from.

    .DESCRIPTION
    ITToolkit ships with defaults. To change them for everyone on a computer, create
        $env:ProgramData\ITToolkit\Settings.psd1
    with only the values you want to change, in the same layout as the defaults:
        @{
            Network = @{ InternalDnsNames = @('dc01.corp.example.com', 'ithub.corp.example.com') }
            Health  = @{ UptimeDaysWarn = 7 }
        }
    Deploy that file with Group Policy or Intune to give every tech the same settings. Set
    $env:ITTOOLKIT_SETTINGS to use a file somewhere else.

    The Source column shows Default or the path of the file a value came from.

    .PARAMETER Path
    Returns the path of the organization settings file instead of the settings.

    .EXAMPLE
    Get-ITToolkitSetting

    .EXAMPLE
    Get-ITToolkitSetting | Where-Object Section -eq 'Network'

    .EXAMPLE
    notepad (Get-ITToolkitSetting -Path)

    Opens the organization settings file to edit it (create the folder first if needed).

    .OUTPUTS
    ITToolkit.Setting, or System.String with -Path.
    #>
    [CmdletBinding()]
    param(
        [switch]$Path
    )

    if ($Path) { return (Get-ITSettingsOverridePath) }

    $files = Read-ITSettingsFile
    $effective = Get-ITSettings
    foreach ($section in @($effective.Keys | Sort-Object)) {
        foreach ($key in @($effective[$section].Keys | Sort-Object)) {
            $overrideSection = $files.Override[$section]
            $fromOverride = ($overrideSection -is [hashtable]) -and $overrideSection.ContainsKey($key)
            [pscustomobject]@{
                PSTypeName = 'ITToolkit.Setting'
                Section    = $section
                Name       = $key
                Value      = $effective[$section][$key]
                Source     = $(if ($fromOverride) { $files.OverridePath } else { 'Default' })
            }
        }
    }
}
