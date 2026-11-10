# ITToolkit root module. Loads Private\*.ps1 (helpers, collectors, data) and
# Public\*.ps1 (one exported command per file, file name = command name).

$script:ITModuleRoot = $PSScriptRoot

$privateFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
$publicFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)

foreach ($file in @($privateFiles + $publicFiles)) {
    try {
        . $file.FullName
    }
    catch {
        throw "ITToolkit: could not load $($file.Name): $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function @($publicFiles | ForEach-Object { $_.BaseName })
