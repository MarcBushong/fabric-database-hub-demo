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

    With -KeepEdited (deploy.ps1 while fabric.importNotebooks is false; follow-ups decision 2a, 2026-11-23), a missing
    notebook is created, and one that's there is read first (Get-DemoFabricNotebookState): an earlier version of the demo's,
    or this version bound to another workspace, lakehouse, or GitHub path, is updated, since nobody edited it; this version
    already is a Pass, left as it is; and one that's none of them, edited or published by another copy of the scripts, is
    kept (Not selected) with the command that replaces it. A copy that couldn't be read is kept too, as a Warning (Manual
    action required while the capacity is paused). The records have evidence operation (created, updated, or unchanged) and
    notebookState.

    - Create Item: https://learn.microsoft.com/rest/api/fabric/core/items/create-item
    - Update Item Definition: https://learn.microsoft.com/rest/api/fabric/core/items/update-item-definition
    - Get Item Definition: https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition
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

        [switch] $KeepEdited,

        [ValidateLength(0, 400)]
        [string] $Note = ''
    )

    if ($CreateOnly -and $KeepEdited) {
        throw 'Pass -CreateOnly or -KeepEdited, not both.'
    }
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
    $action = if ($CreateOnly) { 'Create through the Fabric REST API when it''s missing' } elseif ($KeepEdited) { 'Create through the Fabric REST API when it''s missing, or update it when nobody edited it' } else { 'Create or update through the Fabric REST API' }
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
    if (-not $KeepEdited) {
        return (Import-DemoFabricItem @import)
    }

    # -KeepEdited: the notebook is read first, and only one that nobody edited is updated (follow-ups decision 2a).
    $rule = 'fabric.importNotebooks is false, so deploy.ps1 adds a missing notebook, brings one that nobody edited up to date, and keeps an edited one.'
    if (-not $proceed) {
        $import['Note'] = ('{0} It reads one that''s there first (POST {1}/workspaces/{2}/items/<itemId>/getDefinition?format=ipynb).' -f $rule, $script:FabricApiBaseUri, $WorkspaceId)
        return (Import-DemoFabricItem @import)
    }
    if ($null -eq $Token) {
        throw 'A Fabric token is required. Use Get-DemoFabricToken, or pass -Token.'
    }
    $state = Get-DemoFabricNotebookState -WorkspaceId $WorkspaceId -Notebook $Notebook -Token $Token -TimeoutSeconds ([System.Math]::Min($TimeoutSeconds, 600))
    $item.Evidence['notebookState'] = [string]$state.State
    $target = "notebook '{0}' in Fabric workspace {1}" -f $Notebook.DisplayName, $WorkspaceId
    $replace = './scripts/configure-fabric.ps1 -SkipHubChecks -Notebook {0}' -f $Notebook.DisplayName
    $record = {
        param([string] $Status, [string] $Message, [string] $Remediation = '', [string] $DocUrl = 'https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition')
        $evidence = [ordered]@{
            workspaceId   = $WorkspaceId
            displayName   = $Notebook.DisplayName
            payloadSha256 = $Notebook.Sha256
            payloadBytes  = $Notebook.SizeBytes
            itemId        = [string]$state.ItemId
            operation     = 'unchanged'
            notebookState = [string]$state.State
        }
        if ([string]$state.Error) {
            $evidence['readError'] = [string]$state.Error
        }
        New-DemoResult -CheckId ('FABRIC.IMPORT.' + ($Notebook.DisplayName.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')) -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $DocUrl
    }
    switch ([string]$state.State) {
        'Older' {
            $item.Evidence['publishedSince'] = [string]$state.Since
            $import['Note'] = ('It was the demo''s version of {0}, and nobody had edited it. {1}' -f $state.Since, $rule)
            return (Import-DemoFabricItem @import)
        }
        'Rebind' {
            $import['Note'] = ('It was this version, bound to another workspace, lakehouse, or GitHub path than this run''s, and nobody had edited it. {0}' -f $rule)
            return (Import-DemoFabricItem @import)
        }
        'Current' {
            return (& $record 'Pass' ('{0} is this version already, so it was left as it is. {1}' -f ($target.Substring(0, 1).ToUpperInvariant() + $target.Substring(1)), $rule))
        }
        'Edited' {
            return (& $record 'Not selected' ('Kept {0} as it is: it isn''t a version the demo published, so someone edited it, or another copy of the scripts published it. {1}' -f $target, $rule) ('To replace it with this version, which drops the edits, run {0}: it updates that notebook alone. With fabric.importNotebooks true, every ./scripts/deploy.ps1 updates both notebooks, edited or not.' -f $replace))
        }
        'Unread' {
            $why = ([string]$state.Error).TrimEnd('.', ' ')
            if ([bool]$state.CapacityInactive) {
                return (& $record 'Manual action required' ('Kept {0} as it is: its definition couldn''t be read, so this run can''t tell whether someone edited it. The workspace''s capacity is paused or inactive ({1}).' -f $target, $why) (Get-DemoFabricCapacityResumeFix -Then 'run ./scripts/deploy.ps1 again; it reads the notebook then.') 'https://learn.microsoft.com/fabric/enterprise/pause-resume')
            }
            return (& $record 'Warning' ('Kept {0} as it is: its definition couldn''t be read ({1}), so this run can''t tell whether someone edited it.' -f $target, $why) ('The next ./scripts/deploy.ps1 reads it again. To update it now, run {0}, which replaces any edits.' -f $replace))
        }
        default {
            # Missing, a duplicate name, or a list that failed: the create-only import lists again, and creates the notebook,
            # or reports the duplicate or the list's error as it does without -KeepEdited.
            $import['CreateOnly'] = $true
            $import['Note'] = $rule
            return (Import-DemoFabricItem @import)
        }
    }
}