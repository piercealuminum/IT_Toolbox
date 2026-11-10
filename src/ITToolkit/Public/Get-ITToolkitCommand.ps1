function Get-ITToolkitCommand {
    <#
    .SYNOPSIS
    Lists the ITToolkit commands with what each does and its examples. Start here.

    .DESCRIPTION
    Returns one object per ITToolkit command with its synopsis, parameters and the examples
    from its help. Use it to see what the toolkit can do, or export it with ConvertTo-Json
    to feed the command cookbook.

    .PARAMETER Name
    Command name to look for. Wildcards allowed.

    .EXAMPLE
    Get-ITToolkitCommand

    .EXAMPLE
    Get-ITToolkitCommand *Port* | Select-Object -ExpandProperty Examples

    .EXAMPLE
    Get-ITToolkitCommand | ConvertTo-Json -Depth 5 | Set-Content .\ittoolkit-commands.json

    Exports the catalog for the command cookbook.

    .OUTPUTS
    ITToolkit.CommandInfo
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string]$Name = '*'
    )

    $module = $ExecutionContext.SessionState.Module
    $commonParameters = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)

    # ExportedFunctions, not Get-Command -Module: inside the module Get-Command also sees private helpers.
    foreach ($command in @($module.ExportedFunctions.Values | Where-Object { $_.Name -like $Name } | Sort-Object -Property Name)) {
        $help = Get-Help -Name $command.Name -Full -ErrorAction SilentlyContinue
        $examples = @(foreach ($example in @($help.examples.example)) {
                if (-not $example) { continue }
                $remarks = (@($example.remarks | ForEach-Object { $_.Text }) -join ' ').Trim()
                [pscustomobject]@{
                    Code    = ([string]$example.code).Trim()
                    Remarks = $remarks
                }
            })
        $parameters = @(foreach ($parameter in $command.Parameters.Values) {
                if ($commonParameters -contains $parameter.Name) { continue }
                $parameterHelp = @($help.parameters.parameter | Where-Object { $_.name -eq $parameter.Name }) | Select-Object -First 1
                $description = ''
                if ($parameterHelp -and $parameterHelp.description) {
                    $description = (@($parameterHelp.description | ForEach-Object { $_.Text }) -join ' ').Trim()
                }
                [pscustomobject]@{
                    Name        = $parameter.Name
                    Type        = $parameter.ParameterType.Name
                    Description = $description
                }
            })
        [pscustomobject]@{
            PSTypeName  = 'ITToolkit.CommandInfo'
            Name        = $command.Name
            Synopsis    = ([string]$help.Synopsis).Trim()
            Description = (@($help.description | ForEach-Object { $_.Text }) -join [Environment]::NewLine).Trim()
            Parameters  = $parameters
            Examples    = $examples
            Version     = $module.Version.ToString()
        }
    }
}
