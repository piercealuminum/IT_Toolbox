#Requires -Modules Pester
# Structure rules every ITToolkit change must keep.

BeforeDiscovery {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..\src\ITToolkit'
    $script:PublicNames = @(Get-ChildItem -Path (Join-Path $ModuleRoot 'Public') -Filter '*.ps1' | ForEach-Object { $_.BaseName })
}

BeforeAll {
    $script:ModuleRoot = Join-Path $PSScriptRoot '..\src\ITToolkit'
    Import-Module (Join-Path $ModuleRoot 'ITToolkit.psd1') -Force
}

Describe 'Module' {
    It 'exports exactly the commands in Public\ and listed in the manifest' {
        $manifest = Import-PowerShellDataFile -LiteralPath (Join-Path $ModuleRoot 'ITToolkit.psd1')
        $files = @(Get-ChildItem -Path (Join-Path $ModuleRoot 'Public') -Filter '*.ps1' | ForEach-Object { $_.BaseName } | Sort-Object)
        $exported = @((Get-Module ITToolkit).ExportedFunctions.Keys | Sort-Object)
        $exported | Should -Be $files
        @($manifest.FunctionsToExport | Sort-Object) | Should -Be $files
    }

    It 'defines exactly one function per Public file, named after the file' {
        foreach ($file in Get-ChildItem -Path (Join-Path $ModuleRoot 'Public') -Filter '*.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $names = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } | ForEach-Object { $_.Name })
            $names | Should -Be @($file.BaseName) -Because $file.Name
        }
    }

    It 'loads the shipped default settings' {
        $settings = InModuleScope ITToolkit { Get-ITSettings }
        $settings.Health.UptimeDaysWarn | Should -BeGreaterThan 0
        $settings.Network.TcpTargets | Should -Not -BeNullOrEmpty
    }

    It 'has a word list big enough for passphrases' {
        $words = InModuleScope ITToolkit { Get-ITWordList }
        $words.Count | Should -BeGreaterOrEqual 500
        @($words | Select-Object -Unique).Count | Should -Be $words.Count
        @($words | Where-Object { $_ -notmatch '^[a-z]{3,9}$' }) | Should -BeNullOrEmpty
    }
}

Describe 'Help for <_>' -ForEach $PublicNames {
    BeforeAll {
        $script:help = Get-Help -Name $_ -Full
    }

    It 'has a synopsis' {
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match '^\s*\w+-\w+ \[' # not the auto-generated syntax line
    }

    It 'has a description' {
        (@($help.description | ForEach-Object { $_.Text }) -join '') | Should -Not -BeNullOrEmpty
    }

    It 'has at least one example' {
        @($help.examples.example).Count | Should -BeGreaterOrEqual 1
    }

    It 'documents every parameter' {
        $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
        $command = Get-Command -Name $_
        foreach ($parameter in $command.Parameters.Keys | Where-Object { $common -notcontains $_ }) {
            $entry = @($help.parameters.parameter | Where-Object { $_.name -eq $parameter }) | Select-Object -First 1
            (@($entry.description | ForEach-Object { $_.Text }) -join '') | Should -Not -BeNullOrEmpty -Because "-$parameter needs a .PARAMETER entry"
        }
    }
}

Describe 'Collectors' {
    BeforeAll {
        # Every function name defined anywhere in the module.
        $script:moduleFunctions = @(Get-ChildItem -Path (Join-Path $ModuleRoot 'Private'), (Join-Path $ModuleRoot 'Public') -Filter '*.ps1' | ForEach-Object {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
                $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name }
            })
        $script:collectors = InModuleScope ITToolkit { $script:ITCollectors }
    }

    It 'are all defined' {
        $collectors.Keys | Should -Contain 'DeviceHealth'
        $collectors.Count | Should -BeGreaterOrEqual 9
    }

    It '<_> does not call ITToolkit functions or use $script: variables (it must run on a remote computer)' -ForEach @(
        'Clock', 'PendingReboot', 'DeviceHealth', 'LocalAdmin', 'InstalledSoftware', 'EventLog', 'LockoutEvents', 'LoggedOnUser', 'TempFiles', 'NetworkConfig', 'TcpTest'
    ) {
        $scriptBlock = $collectors[$_]
        $scriptBlock | Should -Not -BeNullOrEmpty
        $ast = $scriptBlock.Ast
        $calls = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        @($calls | Where-Object { $moduleFunctions -contains $_ }) | Should -BeNullOrEmpty
        $scoped = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -match '^script:' }, $true))
        $scoped | Should -BeNullOrEmpty
    }
}
