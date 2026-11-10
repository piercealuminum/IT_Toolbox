function Get-ITHubToolCatalog {
    <#
    .SYNOPSIS
    Lists, as JSON, the tools ITHub may run through Invoke-ITHubTool, with each tool's parameters and rules.

    .DESCRIPTION
    ITHub builds its Tools page from this catalog: one entry per tool with its id, title,
    description (the command's synopsis), the ITHub permission it needs, what it targets
    (computer or user), the type of its result rows, and each parameter's name, type,
    whether it is required, its default and the rule its value must meet (pattern, minimum,
    maximum, list length or allowed values).

    A tool added here appears in ITHub without an ITHub change. Removing or renaming a tool or
    a parameter is a breaking change for ITHub.

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
    $tools = foreach ($tool in $script:ITHubTools) {
        $help = Get-Help -Name $tool.Command -ErrorAction SilentlyContinue
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
            permission  = $tool.Permission
            target      = $tool.Target
            phase       = $tool.Phase
            resultType  = $tool.ResultType
            parameters  = @($parameters)
        }
        if ($tool.ContainsKey('OneOf')) { $item.oneOf = @($tool.OneOf) }
        $item
    }

    $catalog = [ordered]@{
        schemaVersion  = $script:ITHubSchemaVersion
        toolkitVersion = $module.Version.ToString()
        tools          = @($tools)
    }
    ConvertTo-Json -InputObject $catalog -Depth 10 -Compress
}
