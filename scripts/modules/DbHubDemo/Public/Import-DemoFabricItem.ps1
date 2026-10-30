function Import-DemoFabricItem {
    <#
    .SYNOPSIS
    Creates a Fabric item from its definition, or updates the definition of the item with the same name and type,
    and optionally reads the definition back.

    .DESCRIPTION
    The generic form of Phase 12's notebook import, for any item type with a documented definition (a notebook or a
    Real-Time Dashboard, for example). Idempotent:
    1. Items - List Items, filtered by type and following continuation pages, finds the item by display name.
    2. Items - Create Item (type and definition) when there's none, or Items - Update Item Definition when there's
       one. Two items with the name are a Fail: the import doesn't guess.
    3. HTTP 202 is a long-running operation: it waits Retry-After, polls Get Operation State, and reads a created
       item's ID from Get Operation Result.
    4. With -ReadBack, Items - Get Item Definition (also a long-running operation), compared with what was sent. For
       a KQL dashboard, the round trip is a Pass when every page, data source, parameter, query text, and tile came
       back, even if Fabric normalized other fields (they're listed in the evidence), and a Fail when any of them
       changed or is missing. For other types, byte-identical parts are a Pass and different ones a Warning.
       A read-back that can't complete is a Warning, because the import itself succeeded.
    Returns FABRIC.IMPORT.<NAME>, and with -ReadBack also FABRIC.READBACK.<NAME> (ADR 0012). A paused workspace
    capacity (HTTP 404 CapacityNotActive) is "Manual action required" with the resume steps, not "Fail".

    With -WhatIf it sends nothing and needs no token: it returns a "Not selected" record with the planned requests.
    The token is a SecureString sent only to https://api.fabric.microsoft.com/v1 and is never written anywhere. The
    caller needs Contributor or higher on the workspace (prerequisite P5), and a workspace on a Fabric capacity for
    non-Power BI items.

    - Create Item: https://learn.microsoft.com/rest/api/fabric/core/items/create-item
    - Update Item Definition: https://learn.microsoft.com/rest/api/fabric/core/items/update-item-definition
    - Get Item Definition: https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition
    - List Items: https://learn.microsoft.com/rest/api/fabric/core/items/list-items
    - Long-running operations: https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation

    .PARAMETER WorkspaceId
    The Fabric workspace.

    .PARAMETER Item
    A definition from Get-DemoFabricDashboardDefinition, or an object of the same shape: DisplayName, Type (the
    Fabric item type), Label (for messages), Sha256, SizeBytes, Definition, and optionally Evidence and Content.

    .PARAMETER Token
    A Fabric REST API token, as a SecureString (Get-DemoFabricToken).

    .PARAMETER Description
    The item description, used when the item is created.

    .PARAMETER TimeoutSeconds
    How long to wait for each long-running operation.

    .PARAMETER ReadBack
    Read the definition back with Get Item Definition and compare it with what was sent.

    .PARAMETER FolderId
    The workspace folder to create the item in (Create Item's folderId); an item that exists stays where it is.

    .PARAMETER CreateOnly
    Create the item only when the workspace has none with its name; one that exists is left as it is, and the record
    is Not selected (Phase 26a: deploy.ps1 imports missing notebooks without asking, and updates existing ones only
    when fabric.importNotebooks is true).

    .PARAMETER Note
    A sentence added to the record's message, for example why the item was imported.

    .EXAMPLE
    $dashboard = Get-DemoFabricDashboardDefinition -Config $config
    Import-DemoFabricItem -WorkspaceId $workspaceId -Item $dashboard -Token (Get-DemoFabricToken -SubscriptionId $subscriptionId) -ReadBack
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [PSTypeName('DbHubDemo.FabricItemDefinition')]
        [pscustomobject] $Item,

        [securestring] $Token,

        [ValidateLength(0, 256)]
        [string] $Description = 'Fabric Database Hub hybrid SQL demo item, imported by scripts/configure-fabric.ps1.',

        [ValidateRange(30, 3600)]
        [int] $TimeoutSeconds = 600,

        [switch] $ReadBack,

        [ValidatePattern('^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?$')]
        [string] $FolderId = '',

        [switch] $CreateOnly,

        [ValidateLength(0, 400)]
        [string] $Note = ''
    )

    if ([string]$Item.Type -notmatch '^[A-Za-z]+$') {
        throw ('The item type must be a Fabric item type name, such as Notebook or KQLDashboard: {0}' -f $Item.Type)
    }
    $label = if (Get-DemoMemberValue -InputObject $Item -Name 'Label') { [string]$Item.Label } else { [string]$Item.Type }
    $suffix = $Item.DisplayName.ToUpperInvariant() -replace '[^A-Z0-9_]', '_'
    $checkId = 'FABRIC.IMPORT.' + $suffix
    $target = "{0} '{1}' in Fabric workspace {2}" -f $label, $Item.DisplayName, $WorkspaceId
    $itemsUri = '{0}/workspaces/{1}/items' -f $script:FabricApiBaseUri, $WorkspaceId
    $evidence = [ordered]@{
        workspaceId   = $WorkspaceId
        displayName   = $Item.DisplayName
        payloadSha256 = $Item.Sha256
        payloadBytes  = $Item.SizeBytes
    }
    $extra = Get-DemoMemberValue -InputObject $Item -Name 'Evidence'
    if ($extra -is [System.Collections.IDictionary]) {
        foreach ($key in $extra.Keys) {
            $evidence[[string]$key] = $extra[$key]
        }
    }
    $docUrl = 'https://learn.microsoft.com/rest/api/fabric/core/items/create-item'
    $p5 = 'You need Contributor or higher on the workspace, and the workspace must be on F or Trial capacity (prerequisite P5).'
    $noteText = if ($Note) { ' ' + $Note.Trim() } else { '' }
    $verbs = if ($CreateOnly) { 'Create when it''s missing (an existing one is left as it is)' } else { 'Create or update' }

    if (-not $PSCmdlet.ShouldProcess($target, ('{0} through the Fabric REST API' -f $verbs))) {
        $planned = [System.Collections.Generic.List[string]]::new()
        $planned.Add(('GET {0}?type={1} (find it by display name)' -f $itemsUri, $Item.Type))
        if ($CreateOnly) {
            $planned.Add(('POST {0} (create, only when it''s missing)' -f $itemsUri))
        }
        else {
            $planned.Add(('POST {0} (create), or POST {0}/<itemId>/updateDefinition (update)' -f $itemsUri))
        }
        $planned.Add(('GET {0}/operations/<operationId> while a request returns 202' -f $script:FabricApiBaseUri))
        if ($ReadBack) {
            $planned.Add(('POST {0}/<itemId>/getDefinition (read the definition back)' -f $itemsUri))
        }
        $evidence['plannedRequests'] = $planned.ToArray()
        $dryRun = if ($CreateOnly) { 'create {0} when it''s missing' -f $target } else { 'create or update {0}' -f $target }
        return New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Not selected' `
            -Message ("Dry run: would {0}. No request was sent.{1}" -f $dryRun, $noteText) -Evidence $evidence -DocUrl $docUrl
    }
    if ($null -eq $Token) {
        throw 'A Fabric token is required. Use Get-DemoFabricToken, or pass -Token.'
    }

    $fail = {
        param([string] $Message, [int] $StatusCode)
        $evidence['httpStatus'] = $StatusCode
        if ($Message -cmatch '\bCapacityNotActive\b') {
            # A paused F capacity: Fabric still lists items but answers definition and create calls with HTTP 404 CapacityNotActive.
            return New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message $Message -Evidence $evidence `
                -Remediation ("The workspace's capacity is paused (prerequisite P5). A capacity administrator resumes it, which also resumes billing: " +
                    'sign in to the Azure portal, open Microsoft Fabric, select the capacity, select Resume, and confirm. Then run the import again; it is idempotent.') `
                -DocUrl 'https://learn.microsoft.com/fabric/enterprise/pause-resume'
        }
        $remediation = switch ($StatusCode) {
            401 { "Fabric rejected the token. Sign in again with 'az login' and run the script again." }
            403 { $p5 }
            404 { 'The workspace wasn''t found: check fabric.workspaceName in config/demo.config.json (or the fabric.workspaceId override, or -WorkspaceId).' }
            default { 'Run the script again; it is idempotent. ' + $p5 }
        }
        if ($evidence.Contains('networkError')) {
            $remediation = 'Run the script again: a network error lasted through the retries, and the import is idempotent.'
        }
        New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message $Message -Evidence $evidence `
            -Remediation $remediation -DocUrl $docUrl
    }

    try {
        $found = Find-DemoFabricItem -WorkspaceId $WorkspaceId -DisplayName $Item.DisplayName -Type $Item.Type -Token $Token
        if ($found.StatusCode -ne 200) {
            return (& $fail ("The workspace's {0}s couldn't be listed: {1}" -f $label, $found.Error) $found.StatusCode)
        }
        if (@($found.Items).Count -gt 1) {
            return (& $fail ("{0} {1}s named '{2}' exist in the workspace, so the import doesn't know which one to update." -f @($found.Items).Count, $label, $Item.DisplayName) 409)
        }

        $operation = 'updated'
        $itemId = $null
        if (@($found.Items).Count -eq 1) {
            $itemId = [string](Get-DemoMemberValue -InputObject @($found.Items)[0] -Name 'id')
            if ($CreateOnly) {
                $evidence['itemId'] = $itemId
                $evidence['operation'] = 'unchanged'
                return New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Not selected' `
                    -Message ("{0} is already there, so it was left as it is.{1}" -f ((Get-Culture).TextInfo.ToTitleCase($target.Substring(0, 1)) + $target.Substring(1)), $noteText) `
                    -Evidence $evidence -DocUrl 'https://learn.microsoft.com/rest/api/fabric/core/items/list-items'
            }
        }
        else {
            $operation = 'created'
            $createBody = [ordered]@{
                displayName = $Item.DisplayName
                type        = $Item.Type
                description = $Description
                definition  = $Item.Definition
            }
            if ($FolderId) {
                $createBody['folderId'] = $FolderId
            }
            $response = Invoke-DemoFabricRequest -Method Post -Uri $itemsUri -Body $createBody -Token $Token
            if ($response.StatusCode -eq 201) {
                $itemId = [string](Get-DemoMemberValue -InputObject $response.Body -Name 'id')
            }
            elseif ($response.StatusCode -eq 202) {
                $operationId = Get-DemoFabricHeaderValue -Headers $response.Headers -Name 'x-ms-operation-id'
                $evidence['operationId'] = $operationId
                $state = Wait-DemoFabricOperation -OperationId $operationId -Token $Token -TimeoutSeconds $TimeoutSeconds `
                    -RetryAfterSeconds (Get-DemoFabricRetryDelay -Headers $response.Headers -Default 5 -Maximum 30)
                if ($state.Status -eq 'TimedOut') {
                    return New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Warning' `
                        -Message ("Creating {0} didn't finish within {1} seconds; it may still complete." -f $target, $TimeoutSeconds) `
                        -Evidence $evidence -Remediation ('Run the script again in a few minutes; it finds the {0} by name and updates it.' -f $label) `
                        -DocUrl 'https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation'
                }
                if ($state.Status -ne 'Succeeded') {
                    return (& $fail ("Creating {0} failed: {1}" -f $target, $state.Error) 0)
                }
                $result = Invoke-DemoFabricRequest -Method Get -Uri ('{0}/operations/{1}/result' -f $script:FabricApiBaseUri, $operationId) -Token $Token
                $itemId = [string](Get-DemoMemberValue -InputObject $result.Body -Name 'id')
            }
            elseif ((Get-DemoMemberValue -InputObject $response.Body -Name 'errorCode') -eq 'ItemDisplayNameAlreadyInUse') {
                # Created by someone else since the list call: update that item instead (or, create-only, leave it).
                $found = Find-DemoFabricItem -WorkspaceId $WorkspaceId -DisplayName $Item.DisplayName -Type $Item.Type -Token $Token
                if ($found.StatusCode -ne 200 -or @($found.Items).Count -ne 1) {
                    return (& $fail ("A {0} named '{1}' appeared during the import and couldn't be identified." -f $label, $Item.DisplayName) $found.StatusCode)
                }
                $operation = 'updated'
                $itemId = [string](Get-DemoMemberValue -InputObject @($found.Items)[0] -Name 'id')
                if ($CreateOnly) {
                    $evidence['itemId'] = $itemId
                    $evidence['operation'] = 'unchanged'
                    return New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Not selected' `
                        -Message ("A {0} named '{1}' appeared in the workspace during the import, so it was left as it is.{2}" -f $label, $Item.DisplayName, $noteText) `
                        -Evidence $evidence -DocUrl 'https://learn.microsoft.com/rest/api/fabric/core/items/list-items'
                }
            }
            else {
                return (& $fail ("Creating {0} failed: {1}" -f $target, (Get-DemoFabricErrorText -Response $response)) $response.StatusCode)
            }
        }

        if ($operation -eq 'updated') {
            if ($itemId -notmatch $script:GuidPattern) {
                return (& $fail ("The existing {0} '{1}' returned an unexpected item ID." -f $label, $Item.DisplayName) 0)
            }
            $updateUri = '{0}/{1}/updateDefinition' -f $itemsUri, $itemId
            $response = Invoke-DemoFabricRequest -Method Post -Uri $updateUri -Body ([ordered]@{ definition = $Item.Definition }) -Token $Token
            if ($response.StatusCode -eq 202) {
                $operationId = Get-DemoFabricHeaderValue -Headers $response.Headers -Name 'x-ms-operation-id'
                $evidence['operationId'] = $operationId
                $state = Wait-DemoFabricOperation -OperationId $operationId -Token $Token -TimeoutSeconds $TimeoutSeconds `
                    -RetryAfterSeconds (Get-DemoFabricRetryDelay -Headers $response.Headers -Default 5 -Maximum 30)
                if ($state.Status -eq 'TimedOut') {
                    return New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Warning' `
                        -Message ("Updating {0} didn't finish within {1} seconds; it may still complete." -f $target, $TimeoutSeconds) `
                        -Evidence $evidence -Remediation 'Run the script again in a few minutes; updating the definition again is safe.' `
                        -DocUrl 'https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation'
                }
                if ($state.Status -ne 'Succeeded') {
                    return (& $fail ("Updating {0} failed: {1}" -f $target, $state.Error) 0)
                }
            }
            elseif ($response.StatusCode -ne 200) {
                return (& $fail ("Updating {0} failed: {1}" -f $target, (Get-DemoFabricErrorText -Response $response)) $response.StatusCode)
            }
            $docUrl = 'https://learn.microsoft.com/rest/api/fabric/core/items/update-item-definition'
        }
    }
    catch {
        # A network error that lasted through the retries (Invoke-DemoTransientRetry): a rerun is the fix, and deploy.ps1's
        # NOT DONE says so (Test-DemoNetworkResult; Phase 28 live finding, 2026-10-30).
        if (Test-DemoNetworkFailure -Exception $_.Exception) {
            $evidence['networkError'] = $true
        }
        return (& $fail ("The import of {0} stopped: {1}" -f $target, (Get-DemoExceptionText -Exception $_.Exception)) 0)
    }

    $evidence['itemId'] = $itemId
    $evidence['operation'] = $operation
    New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status 'Pass' `
        -Message ("{0} {1} (definition SHA-256 {2}).{3}" -f ((Get-Culture).TextInfo.ToTitleCase($operation)), $target, $Item.Sha256.Substring(0, 12), $noteText) `
        -Evidence $evidence -DocUrl $docUrl

    if ($ReadBack) {
        Get-DemoFabricItemReadBack -WorkspaceId $WorkspaceId -ItemId $itemId -Item $Item -Label $label -CheckId ('FABRIC.READBACK.' + $suffix) -Token $Token -TimeoutSeconds $TimeoutSeconds
    }
}
