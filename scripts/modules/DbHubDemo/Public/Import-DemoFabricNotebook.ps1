function Import-DemoFabricNotebook {
    <#
    .SYNOPSIS
    Creates a notebook in a Fabric workspace, or updates its definition when one with the same name exists.

    .DESCRIPTION
    Idempotent: it finds the notebook by display name (Items - List Items, type Notebook), then either creates it
    (Items - Create Item, type Notebook, with the ipynb definition) or overrides its definition (Items - Update Item
    Definition). Long-running operations (HTTP 202) are polled with Get Operation State until they finish, and a
    created item's ID is read with Get Operation Result. Returns one ADR 0012 record: a paused workspace capacity
    (HTTP 404 CapacityNotActive) is "Manual action required" with the resume steps, not "Fail". Since Phase 18 the
    requests are made by Import-DemoFabricItem, the generic form of this import; the records are the same.

    With -WhatIf it sends nothing and needs no token: it returns a "Not selected" record with the planned requests.
    The token is used only as a SecureString for https://api.fabric.microsoft.com/v1 and is never written anywhere.
    The caller needs Contributor or higher on the workspace, which must be on F or Trial capacity (prerequisite P5).
    With -CreateOnly, a notebook that's already in the workspace is left as it is (Not selected), and -Note adds a
    sentence to the record's message (Phase 26a: deploy.ps1 imports missing notebooks without asking).

    - Create Item: https://learn.microsoft.com/rest/api/fabric/core/items/create-item
    - Update Item Definition: https://learn.microsoft.com/rest/api/fabric/core/items/update-item-definition
    - List Items: https://learn.microsoft.com/rest/api/fabric/core/items/list-items
    - With -FolderId, a created notebook goes in that workspace folder (Create Item's folderId).
    - Long-running operations: https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation

    .EXAMPLE
    $notebook = Get-DemoFabricNotebookDefinition -Path ./fabric/notebooks/NB_DatabaseHub_Deployment.ipynb
    Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token (Get-DemoFabricToken -SubscriptionId $subscriptionId)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [PSTypeName('DbHubDemo.FabricNotebookDefinition')]
        [pscustomobject] $Notebook,

        [securestring] $Token,

        [ValidateLength(0, 256)]
        [string] $Description = 'Fabric Database Hub hybrid SQL demo notebook, imported by scripts/configure-fabric.ps1.',

        [ValidateRange(30, 3600)]
        [int] $TimeoutSeconds = 600,

        [ValidatePattern('^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?$')]
        [string] $FolderId = '',

        [switch] $CreateOnly,

        [ValidateLength(0, 400)]
        [string] $Note = ''
    )

    $item = [pscustomobject]@{
        PSTypeName  = 'DbHubDemo.FabricItemDefinition'
        DisplayName = $Notebook.DisplayName
        Type        = 'Notebook'
        Label       = 'notebook'
        Sha256      = $Notebook.Sha256
        SizeBytes   = $Notebook.SizeBytes
        Evidence    = [ordered]@{ lakehouseRebound = $Notebook.LakehouseRebound }
        Definition  = $Notebook.Definition
    }
    # Confirm here, once; under -WhatIf the generic import prints the plan and sends nothing.
    $action = if ($CreateOnly) { 'Create through the Fabric REST API when it''s missing' } else { 'Create or update through the Fabric REST API' }
    $proceed = if ($WhatIfPreference) { $false } else { $PSCmdlet.ShouldProcess(("notebook '{0}' in Fabric workspace {1}" -f $Notebook.DisplayName, $WorkspaceId), $action) }
    $import = @{
        WorkspaceId    = $WorkspaceId
        Item           = $item
        Description    = $Description
        TimeoutSeconds = $TimeoutSeconds
        WhatIf         = -not $proceed
        Confirm        = $false
        CreateOnly     = $CreateOnly
        Note           = $Note
    }
    if ($null -ne $Token) {
        $import['Token'] = $Token
    }
    if ($FolderId) {
        $import['FolderId'] = $FolderId
    }
    Import-DemoFabricItem @import
}