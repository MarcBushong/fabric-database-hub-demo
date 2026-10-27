function Resolve-DemoFabricConfig {
    <#
    .SYNOPSIS
    Resolves the demo's Fabric workspace and lakehouse by name, creates them when they're missing and
    fabric.createIfMissing allows it, and returns a copy of the configuration with their IDs (ADR 0021).

    .DESCRIPTION
    The repository stores no Fabric ID. Every script that works in Fabric calls this first and uses the copy it
    returns, so the code after it keeps reading fabric.workspaceId and fabric.lakehouseId:

    1. The workspace. fabric.workspaceId, when it's set to anything but the all-zero placeholder, is an override and
       is used as it is. Otherwise the one workspace named fabric.workspaceName (default "Database Hub Demo") among
       the workspaces you can access (Workspaces - List Workspaces, every page; personal workspaces are skipped).
       With -Create and fabric.createIfMissing, a missing workspace is created on the capacity named
       fabric.capacityName (Workspaces - Create Workspace), and a workspace without a capacity is assigned to it
       (Workspaces - Assign To Capacity). That capacity must be one you can assign (Capacities - List Capacities
       lists only capacities you administer or contribute to) and Active. Both wait until Get Workspace reports the
       capacity assignment as Completed.
    2. The lakehouse, unless -SkipLakehouse. fabric.lakehouseId is an override in the same way. Otherwise the one
       lakehouse named fabric.lakehouseName (default LH_DatabaseHub) in the workspace (Items - List Lakehouses).
       With -Create and createIfMissing, a missing lakehouse is created with lakehouse schemas on (Items - Create
       Lakehouse, creationPayload.enableSchemas), as LH_DatabaseHub has them: the notebooks save their tables to
       the dbo schema, and the history model reads them from there. A 202 answer is followed as a long-running
       operation.

    A capacity is never created, resumed, paused, or scaled. Each step reports one ADR 0012 record:
    FABRIC.RESOLVE.WORKSPACE, FABRIC.RESOLVE.CAPACITY (only when it assigns a capacity), and
    FABRIC.RESOLVE.LAKEHOUSE.
    - Pass: found by name, created, or assigned.
    - Not selected: an ID override is set, so the name isn't looked up (the P5 check still reads the workspace);
      or a dry run.
    - Warning: missing, and the caller only reads (no -Create): deploy.ps1 and configure-fabric.ps1 create it.
    - Manual action required, with the exact steps: missing while createIfMissing is false; fabric.capacityName
      not set, not one you can assign, or not Active; no right to create workspaces (a Fabric tenant setting) or
      items; a name that a workspace you can't access already uses; more than one match; no Fabric token.
    - Fail: any other error from the Fabric REST API.

    Messages name the workspace, the lakehouse, and the capacity, never their IDs; the IDs are in the evidence and
    in the returned copy. -WhatIf creates nothing, and without -Token it sends no request at all. The token comes
    from -Token, or from the Azure CLI after the subscription guard (Get-DemoFabricToken).

    Sources (checked 2026-10-27):
    - List Workspaces: https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces
    - Create Workspace: https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace
    - Get Workspace: https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-workspace
    - Assign To Capacity: https://learn.microsoft.com/rest/api/fabric/core/workspaces/assign-to-capacity
    - List Capacities: https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities
    - List Lakehouses: https://learn.microsoft.com/rest/api/fabric/lakehouse/items/list-lakehouses
    - Create Lakehouse: https://learn.microsoft.com/rest/api/fabric/lakehouse/items/create-lakehouse
    - Long-running operations: https://learn.microsoft.com/rest/api/fabric/articles/long-running-operation
    - Pagination: https://learn.microsoft.com/rest/api/fabric/articles/pagination
    - The "Create workspaces" tenant setting: https://learn.microsoft.com/fabric/admin/portal-workspace

    .PARAMETER Config
    Configuration from Get-DemoConfig: subscriptionId and the fabric section.

    .PARAMETER Token
    A Fabric REST API token you already have, as a SecureString.

    .PARAMETER Create
    Create what's missing when fabric.createIfMissing is true. Scripts that only read omit it.

    .PARAMETER SkipLakehouse
    Resolve only the workspace.

    .PARAMETER TimeoutSeconds
    How long to wait for a capacity assignment or the lakehouse's long-running operation.

    .PARAMETER MaxPages
    The most pages to read from each list call.

    .EXAMPLE
    $resolution = Resolve-DemoFabricConfig -Config $config -Create
    $config = $resolution.Config
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [securestring] $Token,

        [switch] $Create,

        [switch] $SkipLakehouse,

        [ValidateRange(10, 3600)]
        [int] $TimeoutSeconds = 300,

        [ValidateRange(1, 50)]
        [int] $MaxPages = 20
    )

    $setting = Get-DemoFabricResolveSetting -Config $Config
    $doc = $script:FabricResolveDoc
    $base = $script:FabricApiBaseUri
    $results = [System.Collections.Generic.List[object]]::new()
    $state = [ordered]@{
        WorkspaceId      = $setting.WorkspaceId
        WorkspaceName    = $setting.WorkspaceName
        WorkspaceCreated = $false
        CapacityId       = ''
        CapacityName     = $setting.CapacityName
        LakehouseId      = $setting.LakehouseId
        LakehouseName    = $setting.LakehouseName
        LakehouseCreated = $false
    }
    $add = {
        param([string] $CheckId, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation, [string] $DocUrl)
        $results.Add((New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl))
    }
    $finish = {
        $copy = Copy-DemoConfig -Config $Config
        if (-not ($copy['fabric'] -is [System.Collections.IDictionary])) {
            $copy['fabric'] = @{}
        }
        foreach ($pair in @(@('workspaceId', $state['WorkspaceId']), @('lakehouseId', $state['LakehouseId']))) {
            if ($pair[1]) {
                $copy['fabric'][$pair[0]] = $pair[1]
            }
            else {
                # Never pass the all-zero placeholder on: an unresolved ID is absent.
                $copy['fabric'].Remove($pair[0])
            }
        }
        [pscustomobject]@{
            PSTypeName       = 'DbHubDemo.FabricResolution'
            Config           = $copy
            Resolved         = [bool]($state['WorkspaceId'] -and ($SkipLakehouse -or $state['LakehouseId']))
            WorkspaceId      = $state['WorkspaceId']
            WorkspaceName    = $state['WorkspaceName']
            WorkspaceCreated = $state['WorkspaceCreated']
            CapacityId       = $state['CapacityId']
            CapacityName     = $state['CapacityName']
            LakehouseId      = $state['LakehouseId']
            LakehouseName    = $state['LakehouseName']
            LakehouseCreated = $state['LakehouseCreated']
            Results          = $results.ToArray()
        }
    }
    $missingAdvice = {
        param([string] $What)
        if ($setting.CreateIfMissing) {
            'Run ./scripts/configure-fabric.ps1 or ./scripts/deploy.ps1: with fabric.createIfMissing true, they create {0}.' -f $What
        }
        else {
            'Create {0} yourself, or set fabric.createIfMissing to true so the scripts create it.' -f $What
        }
    }
    $createWorkspaceSteps = 'Creating a workspace needs the Fabric tenant setting "Create workspaces" for you (a Fabric administrator turns it on: Admin portal > Tenant settings > Workspace settings), and a contributor or administrator role on the capacity. Or a workspace administrator creates the workspace "{0}" on an F or Trial capacity and adds you as Contributor or higher. Then run the script again.' -f $setting.WorkspaceName

    $workspaceLookup = -not $setting.WorkspaceId
    $lakehouseLookup = -not $SkipLakehouse -and -not $setting.LakehouseId
    if ($setting.WorkspaceId) {
        & $add 'FABRIC.RESOLVE.WORKSPACE' 'Not selected' 'fabric.workspaceId is set (an override), so the workspace isn''t looked up by name; the P5 check reads it.' ([ordered]@{ workspaceId = $setting.WorkspaceId; source = 'override' }) 'Remove fabric.workspaceId to use fabric.workspaceName instead (ADR 0021).' $doc['GetWorkspace']
    }
    if (-not $SkipLakehouse -and $setting.LakehouseId) {
        & $add 'FABRIC.RESOLVE.LAKEHOUSE' 'Not selected' 'fabric.lakehouseId is set (an override), so the lakehouse isn''t looked up by name.' ([ordered]@{ lakehouseId = $setting.LakehouseId; source = 'override' }) 'Remove fabric.lakehouseId to use fabric.lakehouseName instead (ADR 0021).' $doc['ListLakehouses']
    }
    if (-not $workspaceLookup -and -not $lakehouseLookup) {
        return (& $finish)
    }

    # A dry run without a token sends nothing; otherwise the token comes from the Azure CLI after the guard.
    if ($null -eq $Token -and $WhatIfPreference) {
        if ($workspaceLookup) {
            & $add 'FABRIC.RESOLVE.WORKSPACE' 'Not selected' ('Dry run: the workspace "{0}" would be looked up by name{1}. No request was sent.' -f $setting.WorkspaceName, $(if ($Create -and $setting.CreateIfMissing) { ', and created on the capacity in fabric.capacityName when it''s missing' } else { '' })) ([ordered]@{ workspaceName = $setting.WorkspaceName }) '' $doc['ListWorkspaces']
        }
        if ($lakehouseLookup) {
            & $add 'FABRIC.RESOLVE.LAKEHOUSE' 'Not selected' ('Dry run: the lakehouse "{0}" would be looked up by name{1}. No request was sent.' -f $setting.LakehouseName, $(if ($Create -and $setting.CreateIfMissing) { ', and created with lakehouse schemas when it''s missing' } else { '' })) ([ordered]@{ lakehouseName = $setting.LakehouseName }) '' $doc['ListLakehouses']
        }
        return (& $finish)
    }
    if ($null -eq $Token) {
        $access = Get-DemoHubFabricAccess -SubscriptionId ([string]$Config['subscriptionId'])
        $Token = $access.Token
        if ($null -eq $Token) {
            $message = 'The Fabric resources couldn''t be resolved: {0}' -f $access.Error
            $remediation = 'Sign in once with ''az login --tenant <tenantId>'' as the account in azureAccount (you don''t need to change the default subscription), then run the script again.'
            if ($workspaceLookup) {
                & $add 'FABRIC.RESOLVE.WORKSPACE' 'Manual action required' $message ([ordered]@{ workspaceName = $setting.WorkspaceName }) $remediation $doc['ListWorkspaces']
            }
            if ($lakehouseLookup) {
                & $add 'FABRIC.RESOLVE.LAKEHOUSE' 'Manual action required' $message ([ordered]@{ lakehouseName = $setting.LakehouseName }) $remediation $doc['ListLakehouses']
            }
            return (& $finish)
        }
    }

    #region The workspace
    $workspace = $null
    if ($workspaceLookup) {
        $list = Read-DemoHubFabricList -Uri ('{0}/workspaces' -f $base) -Token $Token -MaxPages $MaxPages
        if (-not $list.Succeeded) {
            $status = if ($list.StatusCode -in 401, 403) { 'Manual action required' } else { 'Fail' }
            & $add 'FABRIC.RESOLVE.WORKSPACE' $status ('Your Fabric workspaces couldn''t be listed: {0}' -f $list.Error) ([ordered]@{ workspaceName = $setting.WorkspaceName; statusCode = $list.StatusCode }) 'Check your Fabric access (sign in again with ''az login --tenant <tenantId>'' if the session expired), then run the script again.' $doc['ListWorkspaces']
        }
        else {
            $shared = @($list.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'type') -ine 'Personal' })
            $found = @(Select-DemoFabricNamed -Items $shared -Name $setting.WorkspaceName)
            if ($found.Count -gt 1) {
                & $add 'FABRIC.RESOLVE.WORKSPACE' 'Manual action required' ('More than one workspace named "{0}" is visible to you, so the scripts can''t pick one.' -f $setting.WorkspaceName) ([ordered]@{ workspaceName = $setting.WorkspaceName; matches = $found.Count }) 'Rename all but one, or set fabric.workspaceName to a unique name (or fabric.workspaceId to the one to use, an override).' $doc['ListWorkspaces']
            }
            elseif ($found.Count -eq 1) {
                $workspace = $found[0]
                $state['WorkspaceId'] = ([string](Get-DemoMemberValue -InputObject $workspace -Name 'id')).ToLowerInvariant()
                $state['WorkspaceName'] = [string](Get-DemoMemberValue -InputObject $workspace -Name 'displayName')
                & $add 'FABRIC.RESOLVE.WORKSPACE' 'Pass' ('Found the Fabric workspace "{0}" by name.' -f $state['WorkspaceName']) ([ordered]@{ workspaceId = $state['WorkspaceId']; workspaceName = $state['WorkspaceName']; capacityId = [string](Get-DemoMemberValue -InputObject $workspace -Name 'capacityId'); source = 'name' }) '' $doc['ListWorkspaces']
            }
            elseif (-not $list.Complete) {
                & $add 'FABRIC.RESOLVE.WORKSPACE' 'Manual action required' ('The workspace "{0}" wasn''t in the first {1} pages of your workspaces, so it wasn''t created either.' -f $setting.WorkspaceName, $list.Pages) ([ordered]@{ workspaceName = $setting.WorkspaceName; pages = $list.Pages }) 'Set fabric.workspaceId to the workspace (an override), then run the script again.' $doc['ListWorkspaces']
            }
            elseif (-not $Create -or -not $setting.CreateIfMissing) {
                $status = if (-not $Create -and $setting.CreateIfMissing) { 'Warning' } else { 'Manual action required' }
                & $add 'FABRIC.RESOLVE.WORKSPACE' $status ('The Fabric workspace "{0}" doesn''t exist, or you can''t access it.' -f $setting.WorkspaceName) ([ordered]@{ workspaceName = $setting.WorkspaceName; createIfMissing = $setting.CreateIfMissing }) (& $missingAdvice ('the workspace "{0}" on the capacity in fabric.capacityName' -f $setting.WorkspaceName)) $doc['ListWorkspaces']
            }
            else {
                $capacity = Get-DemoFabricCapacityChoice -Name $setting.CapacityName -Token $Token -MaxPages $MaxPages
                if ($capacity.Status -ne 'Pass') {
                    & $add 'FABRIC.RESOLVE.WORKSPACE' $capacity.Status ('The Fabric workspace "{0}" doesn''t exist, and it can''t be created: {1}' -f $setting.WorkspaceName, $capacity.Message) ([ordered]@{ workspaceName = $setting.WorkspaceName; capacityName = $setting.CapacityName; capacityState = $capacity.State }) $capacity.Remediation $capacity.DocUrl
                }
                elseif (-not $PSCmdlet.ShouldProcess(('Fabric workspace "{0}" on the capacity "{1}"' -f $setting.WorkspaceName, $setting.CapacityName), 'Create through the Fabric REST API (Create Workspace)')) {
                    & $add 'FABRIC.RESOLVE.WORKSPACE' 'Not selected' ('What if: the Fabric workspace "{0}" would be created on the Active capacity "{1}" ({2}).' -f $setting.WorkspaceName, $setting.CapacityName, $capacity.Sku) ([ordered]@{ workspaceName = $setting.WorkspaceName; capacityName = $setting.CapacityName }) '' $doc['CreateWorkspace']
                }
                else {
                    $body = [ordered]@{ displayName = $setting.WorkspaceName; capacityId = $capacity.CapacityId; description = 'Microsoft Fabric Database Hub demo: the notebooks, the lakehouse, the Real-Time Dashboard, the history model and report, and the Insights app. Created by the demo''s scripts (ADR 0021).' }
                    try {
                        $created = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/workspaces' -f $base) -Body $body -Token $Token
                    }
                    catch {
                        $created = [pscustomobject]@{ StatusCode = 0; Headers = @{}; Body = [pscustomobject]@{ message = (Protect-DemoText -Text $_.Exception.Message) } }
                    }
                    $newId = [string](Get-DemoMemberValue -InputObject $created.Body -Name 'id')
                    if ($created.StatusCode -in 200, 201 -and $newId) {
                        $state['WorkspaceId'] = $newId.ToLowerInvariant()
                        $state['WorkspaceCreated'] = $true
                        $state['CapacityId'] = $capacity.CapacityId
                        $assignment = Wait-DemoFabricCapacityAssignment -WorkspaceId $state['WorkspaceId'] -Token $Token -TimeoutSeconds ([System.Math]::Min($TimeoutSeconds, 300))
                        $evidence = [ordered]@{ workspaceId = $state['WorkspaceId']; workspaceName = $setting.WorkspaceName; capacityId = $capacity.CapacityId; capacityName = $setting.CapacityName; capacityAssignmentProgress = $assignment.Progress; source = 'created' }
                        if ($assignment.Progress -eq 'Failed') {
                            # The lakehouse step reads the workspace again and reports that it has no capacity.
                            $state['CapacityId'] = ''
                            & $add 'FABRIC.RESOLVE.WORKSPACE' 'Manual action required' ('The Fabric workspace "{0}" was created, but its assignment to the capacity "{1}" failed.' -f $setting.WorkspaceName, $setting.CapacityName) $evidence 'A workspace administrator assigns an F or Trial capacity in Workspace settings > License info, then run the script again.' $doc['GetWorkspace']
                        }
                        else {
                            & $add 'FABRIC.RESOLVE.WORKSPACE' 'Pass' ('Created the Fabric workspace "{0}" on the capacity "{1}" ({2}).' -f $setting.WorkspaceName, $setting.CapacityName, $capacity.Sku) $evidence '' $doc['CreateWorkspace']
                        }
                    }
                    else {
                        $status = Get-DemoFabricResolveStatus -StatusCode $created.StatusCode -Body $created.Body
                        $errorText = Get-DemoFabricErrorText -Response $created
                        $code = [string](Get-DemoMemberValue -InputObject $created.Body -Name 'errorCode')
                        $remediation = if ($created.StatusCode -eq 409 -or $code -match '(?i)AlreadyInUse|AlreadyExists|NameConflict') {
                            'A workspace named "{0}" already exists, and you can''t access it. Ask its administrator to add you as Contributor or higher, or set fabric.workspaceName to another name; then run the script again.' -f $setting.WorkspaceName
                        }
                        else {
                            $createWorkspaceSteps
                        }
                        & $add 'FABRIC.RESOLVE.WORKSPACE' $status ('The Fabric workspace "{0}" couldn''t be created: {1}' -f $setting.WorkspaceName, $errorText) ([ordered]@{ workspaceName = $setting.WorkspaceName; capacityName = $setting.CapacityName; statusCode = $created.StatusCode }) $remediation $doc['TenantSetting']
                    }
                }
            }
        }
    }
    #endregion The workspace

    #region A found workspace without a capacity
    if ($null -ne $workspace -and -not [string](Get-DemoMemberValue -InputObject $workspace -Name 'capacityId') -and $Create -and $setting.CreateIfMissing -and $setting.CapacityName) {
        $capacity = Get-DemoFabricCapacityChoice -Name $setting.CapacityName -Token $Token -MaxPages $MaxPages
        if ($capacity.Status -ne 'Pass') {
            & $add 'FABRIC.RESOLVE.CAPACITY' $capacity.Status ('The workspace "{0}" isn''t on a capacity, and it can''t be assigned to one: {1}' -f $state['WorkspaceName'], $capacity.Message) ([ordered]@{ workspaceName = $state['WorkspaceName']; capacityName = $setting.CapacityName }) $capacity.Remediation $capacity.DocUrl
        }
        elseif (-not $PSCmdlet.ShouldProcess(('Fabric workspace "{0}"' -f $state['WorkspaceName']), ('Assign to the capacity "{0}" (Assign To Capacity)' -f $setting.CapacityName))) {
            & $add 'FABRIC.RESOLVE.CAPACITY' 'Not selected' ('What if: the workspace "{0}" would be assigned to the Active capacity "{1}".' -f $state['WorkspaceName'], $setting.CapacityName) ([ordered]@{ workspaceName = $state['WorkspaceName']; capacityName = $setting.CapacityName }) '' $doc['AssignToCapacity']
        }
        else {
            try {
                $assigned = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/workspaces/{1}/assignToCapacity' -f $base, $state['WorkspaceId']) -Body ([ordered]@{ capacityId = $capacity.CapacityId }) -Token $Token
            }
            catch {
                $assigned = [pscustomobject]@{ StatusCode = 0; Headers = @{}; Body = [pscustomobject]@{ message = (Protect-DemoText -Text $_.Exception.Message) } }
            }
            $evidence = [ordered]@{ workspaceId = $state['WorkspaceId']; capacityId = $capacity.CapacityId; capacityName = $setting.CapacityName }
            if ($assigned.StatusCode -in 200, 202) {
                $assignment = Wait-DemoFabricCapacityAssignment -WorkspaceId $state['WorkspaceId'] -Token $Token -TimeoutSeconds ([System.Math]::Min($TimeoutSeconds, 300))
                $evidence['capacityAssignmentProgress'] = $assignment.Progress
                if ($assignment.Progress -eq 'Completed') {
                    $state['CapacityId'] = $capacity.CapacityId
                    & $add 'FABRIC.RESOLVE.CAPACITY' 'Pass' ('Assigned the workspace "{0}" to the capacity "{1}" ({2}).' -f $state['WorkspaceName'], $setting.CapacityName, $capacity.Sku) $evidence '' $doc['AssignToCapacity']
                }
                elseif ($assignment.Progress -eq 'Failed') {
                    & $add 'FABRIC.RESOLVE.CAPACITY' 'Manual action required' ('Assigning the workspace "{0}" to the capacity "{1}" failed.' -f $state['WorkspaceName'], $setting.CapacityName) $evidence 'A workspace administrator assigns an F or Trial capacity in Workspace settings > License info, then run the script again.' $doc['AssignToCapacity']
                }
                else {
                    & $add 'FABRIC.RESOLVE.CAPACITY' 'Warning' ('The workspace "{0}" is still being assigned to the capacity "{1}".' -f $state['WorkspaceName'], $setting.CapacityName) $evidence 'Wait a few minutes and run the script again.' $doc['AssignToCapacity']
                }
            }
            else {
                $status = Get-DemoFabricResolveStatus -StatusCode $assigned.StatusCode -Body $assigned.Body
                & $add 'FABRIC.RESOLVE.CAPACITY' $status ('The workspace "{0}" couldn''t be assigned to the capacity "{1}": {2}' -f $state['WorkspaceName'], $setting.CapacityName, (Get-DemoFabricErrorText -Response $assigned)) $evidence 'Assigning a capacity needs the Admin role in the workspace and a contributor or administrator role on the capacity. A workspace administrator can assign it in Workspace settings > License info; then run the script again.' $doc['AssignToCapacity']
            }
        }
    }
    #endregion A found workspace without a capacity

    #region The lakehouse
    if ($lakehouseLookup -and -not $state['WorkspaceId']) {
        & $add 'FABRIC.RESOLVE.LAKEHOUSE' 'Not selected' 'The workspace isn''t resolved (FABRIC.RESOLVE.WORKSPACE says why), so the lakehouse wasn''t looked up.' ([ordered]@{ lakehouseName = $setting.LakehouseName }) '' $doc['ListLakehouses']
    }
    elseif ($lakehouseLookup) {
        $workspaceLabel = if ($state['WorkspaceName'] -and -not $setting.WorkspaceId) { 'the workspace "{0}"' -f $state['WorkspaceName'] } else { 'the workspace' }
        $list = Read-DemoHubFabricList -Uri ('{0}/workspaces/{1}/lakehouses' -f $base, $state['WorkspaceId']) -Token $Token -MaxPages $MaxPages
        if (-not $list.Succeeded) {
            $status = if ($list.StatusCode -in 401, 403, 404) { 'Manual action required' } else { 'Fail' }
            & $add 'FABRIC.RESOLVE.LAKEHOUSE' $status ('The lakehouses in {0} couldn''t be listed: {1}' -f $workspaceLabel, $list.Error) ([ordered]@{ lakehouseName = $setting.LakehouseName; statusCode = $list.StatusCode }) 'Listing lakehouses needs a role in the workspace; a workspace administrator adds you as Contributor or higher (Manage access). Then run the script again.' $doc['ListLakehouses']
        }
        else {
            $found = @(Select-DemoFabricNamed -Items @($list.Items) -Name $setting.LakehouseName)
            if ($found.Count -gt 1) {
                & $add 'FABRIC.RESOLVE.LAKEHOUSE' 'Manual action required' ('More than one lakehouse named "{0}" is in {1}.' -f $setting.LakehouseName, $workspaceLabel) ([ordered]@{ lakehouseName = $setting.LakehouseName; matches = $found.Count }) 'Rename all but one, or set fabric.lakehouseId to the one to use (an override).' $doc['ListLakehouses']
            }
            elseif ($found.Count -eq 1) {
                $state['LakehouseId'] = ([string](Get-DemoMemberValue -InputObject $found[0] -Name 'id')).ToLowerInvariant()
                $state['LakehouseName'] = [string](Get-DemoMemberValue -InputObject $found[0] -Name 'displayName')
                & $add 'FABRIC.RESOLVE.LAKEHOUSE' 'Pass' ('Found the lakehouse "{0}" in {1} by name.' -f $state['LakehouseName'], $workspaceLabel) ([ordered]@{ lakehouseId = $state['LakehouseId']; lakehouseName = $state['LakehouseName']; source = 'name' }) '' $doc['ListLakehouses']
            }
            elseif (-not $list.Complete) {
                & $add 'FABRIC.RESOLVE.LAKEHOUSE' 'Manual action required' ('The lakehouse "{0}" wasn''t in the first {1} pages of lakehouses, so it wasn''t created either.' -f $setting.LakehouseName, $list.Pages) ([ordered]@{ lakehouseName = $setting.LakehouseName }) 'Set fabric.lakehouseId to the lakehouse (an override), then run the script again.' $doc['ListLakehouses']
            }
            elseif (-not $Create -or -not $setting.CreateIfMissing) {
                $status = if (-not $Create -and $setting.CreateIfMissing) { 'Warning' } else { 'Manual action required' }
                & $add 'FABRIC.RESOLVE.LAKEHOUSE' $status ('The lakehouse "{0}" isn''t in {1}.' -f $setting.LakehouseName, $workspaceLabel) ([ordered]@{ lakehouseName = $setting.LakehouseName; createIfMissing = $setting.CreateIfMissing }) (& $missingAdvice ('the lakehouse "{0}", with lakehouse schemas' -f $setting.LakehouseName)) $doc['ListLakehouses']
            }
            else {
                # A lakehouse needs the workspace on a running capacity; a paused one is the administrator's to resume.
                # CapacityId is set only when this run created or assigned the workspace, on a capacity it found Active.
                $blocked = ''
                $capacityId = $state['CapacityId']
                $knownActive = [bool]$capacityId
                if (-not $capacityId) {
                    $read = Invoke-DemoHubFabricGet -Uri ('{0}/workspaces/{1}' -f $base, $state['WorkspaceId']) -Token $Token
                    $capacityId = [string](Get-DemoMemberValue -InputObject $read.Body -Name 'capacityId')
                    if ($read.StatusCode -eq 200 -and -not $capacityId) {
                        $blocked = 'the workspace isn''t on a capacity'
                    }
                }
                if (-not $blocked -and $capacityId -and -not $knownActive) {
                    $capacities = Read-DemoHubFabricList -Uri ('{0}/capacities' -f $base) -Token $Token -MaxPages $MaxPages
                    $capacity = @($capacities.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'id') -ieq $capacityId }) | Select-Object -First 1
                    $capacityState = [string](Get-DemoMemberValue -InputObject $capacity -Name 'state')
                    if ($null -ne $capacity -and $capacityState -ine 'Active') {
                        $blocked = 'its capacity "{0}" is {1}, and the scripts never resume, pause, or scale a capacity' -f [string](Get-DemoMemberValue -InputObject $capacity -Name 'displayName'), $capacityState
                    }
                }
                if ($blocked) {
                    $noCapacity = $blocked -like 'the workspace isn''t*'
                    $remediation = if ($noCapacity) { 'Set fabric.capacityName to an F or Trial capacity you can assign (the scripts then assign it), or a workspace administrator assigns one in Workspace settings > License info. Then run the script again.' } else { 'The capacity''s administrator resumes it (Azure portal > the Fabric capacity > Resume), then run the script again.' }
                    & $add 'FABRIC.RESOLVE.LAKEHOUSE' 'Manual action required' ('The lakehouse "{0}" isn''t in {1}, and it can''t be created now: {2}.' -f $setting.LakehouseName, $workspaceLabel, $blocked) ([ordered]@{ lakehouseName = $setting.LakehouseName; capacityId = $capacityId }) $remediation $(if ($noCapacity) { $doc['AssignToCapacity'] } else { $doc['PauseResume'] })
                }
                elseif (-not $PSCmdlet.ShouldProcess(('lakehouse "{0}" in {1}' -f $setting.LakehouseName, $workspaceLabel), 'Create with lakehouse schemas through the Fabric REST API (Create Lakehouse)')) {
                    & $add 'FABRIC.RESOLVE.LAKEHOUSE' 'Not selected' ('What if: the lakehouse "{0}" would be created in {1}, with lakehouse schemas.' -f $setting.LakehouseName, $workspaceLabel) ([ordered]@{ lakehouseName = $setting.LakehouseName }) '' $doc['CreateLakehouse']
                }
                else {
                    $body = [ordered]@{
                        displayName     = $setting.LakehouseName
                        description     = 'Database Hub demo history: the notebooks'' Delta tables, which the history model reads. Created by the demo''s scripts (ADR 0021).'
                        creationPayload = [ordered]@{ enableSchemas = $true }
                    }
                    try {
                        $created = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/workspaces/{1}/lakehouses' -f $base, $state['WorkspaceId']) -Body $body -Token $Token
                    }
                    catch {
                        $created = [pscustomobject]@{ StatusCode = 0; Headers = @{}; Body = [pscustomobject]@{ message = (Protect-DemoText -Text $_.Exception.Message) } }
                    }
                    $code = [string](Get-DemoMemberValue -InputObject $created.Body -Name 'errorCode')
                    $failure = ''
                    $newId = ''
                    if ($created.StatusCode -in 200, 201) {
                        $newId = [string](Get-DemoMemberValue -InputObject $created.Body -Name 'id')
                    }
                    elseif ($created.StatusCode -eq 202) {
                        $operationId = Get-DemoFabricHeaderValue -Headers $created.Headers -Name 'x-ms-operation-id'
                        $operation = if ($operationId) {
                            Wait-DemoFabricOperation -OperationId $operationId -Token $Token -TimeoutSeconds $TimeoutSeconds -RetryAfterSeconds (Get-DemoFabricRetryDelay -Headers $created.Headers -Default 5 -Maximum 30)
                        }
                        else {
                            [pscustomobject]@{ Status = 'Failed'; Error = 'the answer had no operation to follow' }
                        }
                        if ($operation.Status -ne 'Succeeded') {
                            $failure = 'its creation {0}: {1}' -f $operation.Status.ToLowerInvariant(), $operation.Error
                        }
                    }
                    elseif ($code -ne 'ItemDisplayNameAlreadyInUse') {
                        $failure = Get-DemoFabricErrorText -Response $created
                    }
                    if (-not $failure -and -not $newId) {
                        # After a long-running operation, or a name another run took meanwhile: read it back by name.
                        $again = Read-DemoHubFabricList -Uri ('{0}/workspaces/{1}/lakehouses' -f $base, $state['WorkspaceId']) -Token $Token -MaxPages $MaxPages
                        $match = @(Select-DemoFabricNamed -Items @($again.Items) -Name $setting.LakehouseName) | Select-Object -First 1
                        $newId = [string](Get-DemoMemberValue -InputObject $match -Name 'id')
                        if (-not $newId) {
                            $failure = 'it was accepted, but it isn''t in the workspace''s lakehouses yet'
                        }
                    }
                    if ($failure) {
                        $status = if ($created.StatusCode -eq 202) { 'Fail' } else { Get-DemoFabricResolveStatus -StatusCode $created.StatusCode -Body $created.Body }
                        $remediation = if ($status -eq 'Manual action required') { 'Creating a lakehouse needs Contributor or higher in the workspace; a workspace administrator adds you (Manage access), then run the script again.' } else { 'Run the script again; if it fails again, create the lakehouse "{0}" with lakehouse schemas yourself (New item > Lakehouse > Lakehouse schemas).' -f $setting.LakehouseName }
                        & $add 'FABRIC.RESOLVE.LAKEHOUSE' $status ('The lakehouse "{0}" couldn''t be created in {1}: {2}' -f $setting.LakehouseName, $workspaceLabel, $failure) ([ordered]@{ lakehouseName = $setting.LakehouseName; statusCode = $created.StatusCode }) $remediation $doc['CreateLakehouse']
                    }
                    else {
                        $state['LakehouseId'] = $newId.ToLowerInvariant()
                        $state['LakehouseCreated'] = ($code -ne 'ItemDisplayNameAlreadyInUse')
                        $message = if ($state['LakehouseCreated']) { 'Created the lakehouse "{0}" in {1}, with lakehouse schemas.' -f $setting.LakehouseName, $workspaceLabel } else { 'Found the lakehouse "{0}" in {1} by name: it was created meanwhile.' -f $setting.LakehouseName, $workspaceLabel }
                        & $add 'FABRIC.RESOLVE.LAKEHOUSE' 'Pass' $message ([ordered]@{ lakehouseId = $state['LakehouseId']; lakehouseName = $setting.LakehouseName; source = $(if ($state['LakehouseCreated']) { 'created' } else { 'name' }) }) '' $doc['CreateLakehouse']
                    }
                }
            }
        }
    }
    #endregion The lakehouse

    return (& $finish)
}
