# Settings: shipped defaults (ITToolkit.Defaults.psd1) plus an optional organization file
# ($env:ProgramData\ITToolkit\Settings.psd1, or the path in $env:ITTOOLKIT_SETTINGS).
# Both are data files, read with Import-PowerShellDataFile, so they cannot run code.

function Get-ITSettingsOverridePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:ITTOOLKIT_SETTINGS) { return $env:ITTOOLKIT_SETTINGS }
    if ($env:ProgramData) { return (Join-Path $env:ProgramData 'ITToolkit\Settings.psd1') }
    return $null
}

function Read-ITSettingsFile {
    [CmdletBinding()]
    param()

    $defaults = Import-PowerShellDataFile -LiteralPath (Join-Path $script:ITModuleRoot 'ITToolkit.Defaults.psd1')
    $overridePath = Get-ITSettingsOverridePath
    $override = @{}
    if ($overridePath -and (Test-Path -LiteralPath $overridePath -PathType Leaf)) {
        try {
            $override = Import-PowerShellDataFile -LiteralPath $overridePath
        }
        catch {
            Write-Warning "ITToolkit: ignoring settings file '$overridePath': $($_.Exception.Message)"
            $override = @{}
        }
    }

    @{
        Defaults     = $defaults
        Override     = $override
        OverridePath = $overridePath
    }
}

function Get-ITSettings {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $files = Read-ITSettingsFile
    $settings = $files.Defaults
    foreach ($section in @($files.Override.Keys)) {
        if (-not $settings.ContainsKey($section)) {
            Write-Warning "ITToolkit: unknown settings section '$section' in $($files.OverridePath)"
            continue
        }
        $values = $files.Override[$section]
        if ($values -isnot [hashtable]) {
            Write-Warning "ITToolkit: settings section '$section' in $($files.OverridePath) must be a hashtable, like @{ Name = value }"
            continue
        }
        foreach ($key in @($values.Keys)) {
            if (-not $settings[$section].ContainsKey($key)) {
                Write-Warning "ITToolkit: unknown setting '$section.$key' in $($files.OverridePath)"
                continue
            }
            $settings[$section][$key] = $values[$key]
        }
    }
    $settings
}
