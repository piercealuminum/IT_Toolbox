#Requires -Modules Pester
# The catalog's default columns (resultTypes) must name fields that really exist on the
# results each tool returns, so ITHub never shows an empty column after a rename.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\src\ITToolkit\ITToolkit.psd1') -Force
    $script:catalog = Get-ITHubToolCatalog | ConvertFrom-Json

    # One real object of each result type, made by the same code the tools use.
    $script:objects = InModuleScope ITToolkit {
        $now = Get-Date
        $made = @{}
        $made['ITToolkit.CheckResult'] = New-ITCheckResult -ComputerName 'PC1' -Category 'Storage' -Check 'Disk C:' -Status 'OK' -Detail 'x'
        $made['ITToolkit.UserCheck'] = New-ITUserCheck -UserName 'jlee' -Category 'Active Directory' -Check 'Lockout' -Status 'OK' -Detail 'x'
        $made['ITToolkit.PendingReboot'] = ConvertTo-ITPendingReboot -ComputerName 'PC1' -Reboot ([pscustomobject]@{ Reasons = @('Windows Update'); PendingFileRenames = 0; LastBootTime = $now.AddDays(-2); UptimeDays = 2.0 })
        $made['ITToolkit.Session'] = @(ConvertFrom-ITQuser -ComputerName 'PC1' -Lines @(' USERNAME  SESSIONNAME  ID  STATE   IDLE TIME  LOGON TIME', '>jlee      console       1  Active      none   11/10/2026 8:02 AM'))[0]
        $made['ITToolkit.Software'] = ConvertTo-ITSoftware -ComputerName 'PC1' -Entry ([pscustomobject]@{ DisplayName = '7-Zip'; DisplayVersion = '24.08'; Publisher = 'Igor Pavlov'; InstallDate = '20260915'; Scope = 'Machine'; Architecture = '64-bit'; UninstallString = 'x'; QuietUninstallString = ''; KeyName = '7-Zip' })
        $made['ITToolkit.EventGroup'] = @(ConvertTo-ITEventGroup -ComputerName 'PC1' -Events @([pscustomobject]@{ TimeCreated = $now; LogName = 'System'; ProviderName = 'EventLog'; Id = 6008; Level = 2; LevelName = 'Error'; Message = 'The previous system shutdown was unexpected.' }))[0]
        $made['ITToolkit.LocalAdmin'] = ConvertTo-ITLocalAdmin -ComputerName 'PC1' -Member ([pscustomobject]@{ AdsPath = 'WinNT://PC1/Administrator'; Class = 'User'; Sid = 'S-1-5-21-1-2-3-500'; ComputerName = 'PC1'; GroupName = 'Administrators' })
        $made['ITToolkit.Lockout'] = ConvertTo-ITLockout -Record ([pscustomobject]@{ TimeCreated = $now; Xml = "<Event xmlns='http://schemas.microsoft.com/win/2004/08/events/event'><System><Computer>DC01</Computer></System><EventData><Data Name='TargetUserName'>jlee</Data><Data Name='TargetDomainName'>PC1</Data></EventData></Event>" })
        $made['ITToolkit.UserAccount'] = ConvertTo-ITUserAccount -Server 'DC01' -User ([pscustomobject]@{
                SamAccountName = 'jlee'; UserPrincipalName = 'jlee@example.com'; DisplayName = 'Jordan Lee'; EmailAddress = ''; Title = ''; Department = ''; Manager = $null
                DistinguishedName = 'CN=Jordan Lee,OU=Users,DC=corp,DC=example,DC=com'; Enabled = $true; LockedOut = $false; AccountLockoutTime = $null; BadLogonCount = 0
                LastBadPasswordAttempt = $null; PasswordLastSet = $now.AddDays(-10); PasswordExpired = $false; PasswordNeverExpires = $false
                'msDS-UserPasswordExpiryTimeComputed' = $now.AddDays(80).ToFileTime(); AccountExpirationDate = $null; LastLogonDate = $now
            })
        $made
    }

    # Port test: a real run against a closed local port.
    $objects['ITToolkit.PortTest'] = Test-ITPort -ComputerName 127.0.0.1 -Port 1 -TimeoutMs 2000

    # Temp cleanup and its preview: the real command, with the file scan replaced.
    Mock -ModuleName ITToolkit Invoke-ITCollector -ParameterFilter { $Name -eq 'TempFiles' } {
        [pscustomobject]@{ Path = 'C:\Windows\Temp'; Files = 3; Bytes = [int64]3000; Failed = 0; FoldersRemoved = 1; Skipped = $null }
    }
    $objects['ITToolkit.TempScan'] = @(Clear-ITTempFile -Preview)[0]
    $objects['ITToolkit.TempCleanup'] = @(Clear-ITTempFile -Confirm:$false)[0]

    $script:fieldsByType = @{}
    foreach ($type in $objects.Keys) {
        $row = InModuleScope ITToolkit -Parameters @{ Item = $objects[$type] } { param($Item) ConvertTo-ITHubResult -InputObject $Item }
        $fieldsByType[$type] = @($row.get_Keys())
    }
}

Describe 'Catalog default columns' {
    It 'has columns for every result type a tool returns' {
        $types = @($catalog.tools | ForEach-Object { $_.resultType; if ($_.previewResultType) { $_.previewResultType } } | Sort-Object -Unique)
        foreach ($type in $types) {
            $catalog.resultTypes.PSObject.Properties.Name | Should -Contain $type -Because "a tool returns $type"
        }
    }

    It '<_> names only fields its results have' -ForEach @(
        'ITToolkit.CheckResult', 'ITToolkit.UserCheck', 'ITToolkit.PendingReboot', 'ITToolkit.PortTest', 'ITToolkit.Session',
        'ITToolkit.Software', 'ITToolkit.EventGroup', 'ITToolkit.LocalAdmin', 'ITToolkit.Lockout', 'ITToolkit.UserAccount',
        'ITToolkit.TempScan', 'ITToolkit.TempCleanup'
    ) {
        $objects[$_].PSObject.TypeNames[0] | Should -Be $_ -Because 'the test object must be of the type it stands for'
        $fields = $fieldsByType[$_]
        $columns = @($catalog.resultTypes.$_.columns)
        $columns.Count | Should -BeGreaterThan 0
        foreach ($column in $columns) {
            $fields | Should -Contain $column.field -Because "$_ results need $($column.field)"
            if ($column.fallback) { $fields | Should -Contain $column.fallback }
            $column.label | Should -Not -BeNullOrEmpty
            $column.format | Should -BeIn @('text', 'number', 'boolean', 'datetime', 'date', 'list', 'status')
            $column.wrap | Should -BeOfType [bool]
        }
    }

    It 'leaves long technical fields out of the default view' {
        ($catalog.resultTypes.'ITToolkit.LocalAdmin'.columns.field) | Should -Not -Contain 'sid'
        ($catalog.resultTypes.'ITToolkit.Software'.columns.field) | Should -Not -Contain 'uninstallString'
        ($catalog.resultTypes.'ITToolkit.Software'.columns.field) | Should -Not -Contain 'quietUninstallString'
    }

    It 'does not list a result type no tool returns' {
        $types = @($catalog.tools | ForEach-Object { $_.resultType; if ($_.previewResultType) { $_.previewResultType } } | Sort-Object -Unique)
        foreach ($name in $catalog.resultTypes.PSObject.Properties.Name) { $types | Should -Contain $name }
    }
}
