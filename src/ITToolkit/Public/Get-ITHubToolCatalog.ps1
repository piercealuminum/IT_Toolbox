function Get-ITHubToolCatalog {
    <#
    .SYNOPSIS
    Lists, as JSON, the tools ITHub may run through Invoke-ITHubTool, with each tool's parameters and rules.

    .DESCRIPTION
    ITHub builds its Tools page from this catalog: one entry per tool with its id, title,
    description (the command's synopsis), its kind (read or change), the ITHub permission it
    needs, what it targets
    (computer or user), the type of its result rows, and each parameter's name, type,
    whether it is required, its default and the rule its value must meet (pattern, minimum,
    maximum, list length or allowed values).

    resultTypes gives, for each result type, the columns to show by default: field, label,
    format (text, number, boolean, datetime, date, list or status), whether long text may wrap,
    and a fallback field for when the column's own field is empty. It matches what PowerShell
    shows for the same results; every other field stays in the result rows.

    A tool added here appears in ITHub without an ITHub change. Removing or renaming a tool or
    a parameter is a breaking change for ITHub. Tools listed in the ITHub.DisabledTools setting
    are left out, and Invoke-ITHubTool refuses them.

    .EXAMPLE
    Get-ITHubToolCatalog

    .EXAMPLE
    Get-ITHubToolCatalog | ConvertFrom-Json | Select-Object -ExpandProperty tools | Format-Table id, title, permission

    .OUTPUTS
    System.String (JSON)
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $module = $ExecutionContext.SessionState.Module
    $disabled = Get-ITHubDisabledTool
    $tools = foreach ($tool in $script:ITHubTools) {
        if ($disabled -ccontains $tool.Id) { continue }
        $help = Microsoft.PowerShell.Core\Get-Help -Name $tool.Command -ErrorAction SilentlyContinue
        $parameters = foreach ($parameter in $tool.Parameters) {
            $rule = $script:ITHubRules[$parameter.Rule]
            $entry = [ordered]@{
                name        = $parameter.Name
                type        = $rule.Type
                required    = [bool]$parameter.Required
                description = $parameter.Description
            }
            if ($parameter.ContainsKey('Default')) { $entry.default = $parameter.Default }
            if ($rule.ContainsKey('Pattern')) { $entry.pattern = $rule.Pattern }
            if ($rule.ContainsKey('Minimum')) { $entry.minimum = $rule.Minimum }
            if ($rule.ContainsKey('Maximum')) { $entry.maximum = $rule.Maximum }
            if ($rule.ContainsKey('MaxItems')) { $entry.maxItems = $rule.MaxItems }
            if ($rule.ContainsKey('Values')) { $entry.values = @($rule.Values) }
            $entry
        }
        $item = [ordered]@{
            id          = $tool.Id
            title       = $tool.Title
            description = ([string]$help.Synopsis).Trim()
            command     = $tool.Command
            kind        = Get-ITHubToolKind -Tool $tool
            permission  = $tool.Permission
            target      = $tool.Target
            phase       = $tool.Phase
            resultType  = $tool.ResultType
            parameters  = @($parameters)
        }
        if ($tool.ContainsKey('OneOf')) { $item.oneOf = @($tool.OneOf) }
        if ($tool.ContainsKey('PreviewResultType')) { $item.previewResultType = $tool.PreviewResultType }
        $item
    }

    # Default columns for every result type a listed tool can return.
    $types = @($tools | ForEach-Object { $_.resultType; if ($_.Contains('previewResultType')) { $_.previewResultType } } | Where-Object { $_ } | Microsoft.PowerShell.Utility\Select-Object -Unique)
    $resultTypes = [ordered]@{}
    foreach ($type in $types) {
        if (-not $script:ITHubColumns.Contains($type)) { continue }
        $resultTypes[$type] = [ordered]@{
            columns = @(foreach ($column in $script:ITHubColumns[$type]) {
                    $entry = [ordered]@{
                        field  = $column.Field
                        label  = $column.Label
                        format = $(if ($column.ContainsKey('Format')) { $column.Format } else { 'text' })
                        wrap   = [bool]$column.Wrap
                    }
                    if ($column.ContainsKey('Fallback')) { $entry.fallback = $column.Fallback }
                    $entry
                })
        }
    }

    $catalog = [ordered]@{
        schemaVersion  = $script:ITHubSchemaVersion
        toolkitVersion = $module.Version.ToString()
        tools          = @($tools)
        resultTypes    = $resultTypes
    }
    ConvertTo-Json -InputObject $catalog -Depth 10 -Compress
}
