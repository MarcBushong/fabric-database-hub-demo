# What destroy.ps1 deletes beyond the demo's resource group (2026-11-17; the coordinator's decision, with the user's
# standing preferences "ease above all" and READMEs that say how to delete everything: one command deletes everything
# deploy.ps1 created). Each part reads what it needs before the confirmation (Get-DemoDestroyExtraPlan), deletes only
# what it can tell is this environment's, and reports its own DESTROY.* result; one that fails doesn't stop the others.
# - The session control (rg-<prefix>-control), when its runbooks' settings name this environment's resource group.
# - The demo's Fabric workspace, when every item in it is one the demo creates, and the control's workspace, when its
#   control notebook names this environment's resource group. Never a workspace with anyone else's item in it.
# - The T3 administrators' security group, when init.ps1 created it for this environment (its description says so).
# - The demo's custom role definitions, once no role assignment holds them.
# Sources (checked 2026-11-17):
# - Runbook - Get Content: https://learn.microsoft.com/rest/api/automation/runbook/get-content
# - Items - List Items: https://learn.microsoft.com/rest/api/fabric/core/items/list-items
# - Items - Get Item Definition: https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition
# - Workspaces - Delete Workspace: https://learn.microsoft.com/rest/api/fabric/core/workspaces/delete-workspace
# - Delete group: https://learn.microsoft.com/graph/api/group-delete
# - Role Definitions - Delete: https://learn.microsoft.com/rest/api/authorization/role-definitions/delete

$script:DestroyGroupMarker = 'Created by init.ps1.'

function Get-DemoDestroyControlPlan {
    <#
    .SYNOPSIS
    Whether the session control in rg-<prefix>-control serves this environment, read-only. Its published runbooks carry
    the settings they were deployed with (Get-DemoActivityControlRunbookContent), demoResourceGroup among them: the
    control serves this environment when that's this environment's resource group. Returns Name
    (Get-DemoActivityControlName), State (None, Serves, Other, Unknown, or Leftover: a group with no Automation account
    in it), ServedGroup, Resources (what a group without an Automation account holds), and Reason. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $name = Get-DemoActivityControlName -Config $Config
    $plan = [ordered]@{ Name = $name; State = 'Unknown'; ServedGroup = ''; Resources = @(); Reason = '' }
    $group = Invoke-DemoAz -SubscriptionId $name.SubscriptionId -ArgumentList @('group', 'exists', '--name', $name.ResourceGroup) -AllowFailure -TimeoutSeconds 120
    if ($group.ExitCode -eq 0 -and ([string]$group.StdOut).Trim() -eq 'false') {
        $plan.State = 'None'
        $plan.Reason = ('{0} doesn''t exist' -f $name.ResourceGroup)
        return [pscustomobject]$plan
    }
    $apiVersion = Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Automation/automationAccounts'
    foreach ($runbook in $name.StopRunbook, $name.ControlRunbook, $name.MonitorRunbook) {
        $content = Invoke-DemoAz -SubscriptionId $name.SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('https://management.azure.com{0}/runbooks/{1}/content?api-version={2}' -f $name.AutomationAccountId, $runbook, $apiVersion)) -AllowFailure -TimeoutSeconds 120
        if ($content.ExitCode -ne 0) {
            continue
        }
        $found = [regex]::Match([string]$content.StdOut, '"demoResourceGroup"\s*:\s*"([^"]+)"')
        if ($found.Success) {
            $plan.ServedGroup = $found.Groups[1].Value
            $serves = [string]::Equals($plan.ServedGroup, $name.DemoResourceGroup, [System.StringComparison]::OrdinalIgnoreCase)
            $plan.State = if ($serves) { 'Serves' } else { 'Other' }
            $plan.Reason = if ($serves) { 'its runbooks serve {0}' -f $name.DemoResourceGroup } else { 'its runbooks serve {0}, not {1}' -f $plan.ServedGroup, $name.DemoResourceGroup }
            return [pscustomobject]$plan
        }
    }
    $account = Invoke-DemoAz -SubscriptionId $name.SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('https://management.azure.com{0}?api-version={1}' -f $name.AutomationAccountId, $apiVersion), '--query', 'id', '--output', 'tsv') -AllowFailure -TimeoutSeconds 120
    if ($account.ExitCode -ne 0 -and (Test-DemoAzNotFound -Text ([string]$account.StdErr))) {
        # What an earlier destroy left once it had deleted the Automation account (its last step), or what else is there. The
        # account's runbooks can still be listed for a moment after it goes, and they go with it.
        $list = Invoke-DemoAz -SubscriptionId $name.SubscriptionId -ArgumentList @('resource', 'list', '--resource-group', $name.ResourceGroup, '--query', '[].name', '--output', 'json') -AsJson -AllowFailure -TimeoutSeconds 120
        $plan.Resources = @($list | Where-Object { $_ } | ForEach-Object { [string]$_ } | Where-Object { -not $_.StartsWith(('{0}/' -f $name.AutomationAccount), [System.StringComparison]::OrdinalIgnoreCase) })
        $plan.State = 'Leftover'
        $plan.Reason = if ($plan.Resources.Count -eq 0) { ('{0} is empty' -f $name.ResourceGroup) } else { ('{0} has no Automation account, so it can''t tell which environment it serves; it holds {1}' -f $name.ResourceGroup, ($plan.Resources -join ', ')) }
        return [pscustomobject]$plan
    }
    $plan.Reason = ('its runbooks couldn''t be read, so it can''t tell which environment it serves{0}' -f $(if ($account.ExitCode -ne 0) { ': ' + (Get-DemoDeploymentErrorText -Text ([string]$account.StdErr) -MaxLength 200) } else { '' }))
    return [pscustomobject]$plan
}

function Get-DemoFabricNotebookResourceGroup {
    <#
    .SYNOPSIS
    The RESOURCE_GROUP that a notebook's definition sets, read with Items - Get Item Definition (which can answer 202:
    the operation is then waited for, at most -TimeoutSeconds). Returns Ok, ResourceGroup ('' when the notebook sets
    none), and Error. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [string] $ItemId,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [ValidateRange(30, 1800)]
        [int] $TimeoutSeconds = 300
    )

    $base = $script:FabricApiBaseUri
    $response = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/workspaces/{1}/items/{2}/getDefinition' -f $base, $WorkspaceId, $ItemId) -Token $Token
    $body = $null
    if ($response.StatusCode -eq 200) {
        $body = $response.Body
    }
    elseif ($response.StatusCode -eq 202) {
        $operationId = Get-DemoFabricHeaderValue -Headers $response.Headers -Name 'x-ms-operation-id'
        $state = Wait-DemoFabricOperation -OperationId $operationId -Token $Token -TimeoutSeconds $TimeoutSeconds -RetryAfterSeconds (Get-DemoFabricRetryDelay -Headers $response.Headers -Default 5 -Maximum 30)
        if ($state.Status -ne 'Succeeded') {
            return [pscustomobject]@{ Ok = $false; ResourceGroup = ''; Error = ('reading its definition ended {0} {1}' -f $state.Status, $state.Error).Trim() }
        }
        $result = Invoke-DemoFabricRequest -Method Get -Uri ('{0}/operations/{1}/result' -f $base, $operationId) -Token $Token
        if ($result.StatusCode -ne 200) {
            return [pscustomobject]@{ Ok = $false; ResourceGroup = ''; Error = (Get-DemoFabricErrorText -Response $result) }
        }
        $body = $result.Body
    }
    else {
        return [pscustomobject]@{ Ok = $false; ResourceGroup = ''; Error = (Get-DemoFabricErrorText -Response $response) }
    }
    $parts = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $body -Name 'definition') -Name 'parts'
    foreach ($part in @($parts)) {
        $payload = [string](Get-DemoMemberValue -InputObject $part -Name 'payload')
        if (-not $payload) {
            continue
        }
        try {
            $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload))
        }
        catch {
            continue
        }
        # A .py part has RESOURCE_GROUP = "rg-x"; an .ipynb part has it inside a JSON string, as RESOURCE_GROUP = \"rg-x\".
        $found = [regex]::Match($text, 'RESOURCE_GROUP\s*=\s*\\?"([A-Za-z0-9._()-]{1,90})\\?"')
        if ($found.Success) {
            return [pscustomobject]@{ Ok = $true; ResourceGroup = $found.Groups[1].Value; Error = '' }
        }
    }
    return [pscustomobject]@{ Ok = $true; ResourceGroup = ''; Error = '' }
}

function Get-DemoDestroyFabricPlan {
    <#
    .SYNOPSIS
    Which Fabric workspaces destroy.ps1 deletes, read-only: the demo's (fabric.workspaceName), when every item in it is
    one the demo creates; and the control's (control.fabricWorkspaceName), when everything in it is the control
    notebook, and that notebook names this environment's resource group, or the workspace is empty and the control
    serves this environment. Returns Ok, Error, Kind (Get-DemoFabricListFailureKind, when a list failed), Demo, and
    Control; each workspace has Name, Id, Exists, Delete, Items (type: name), Foreign (what the demo didn't create), and
    Reason. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [Parameter(Mandatory)]
        [pscustomobject] $Control
    )

    $base = $script:FabricApiBaseUri
    $resourceGroup = Get-DemoResourceGroupName -Config $Config
    $setting = Get-DemoFabricResolveSetting -Config $Config
    $app = Get-DemoFabricAppSetting
    $demoItems = @(
        @{ Type = 'Lakehouse'; Name = [string]$setting.LakehouseName }
        @{ Type = 'SQLEndpoint'; Name = [string]$setting.LakehouseName }
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'fabric/notebooks') -Filter '*.ipynb' -File)) {
            @{ Type = 'Notebook'; Name = $file.BaseName }
        }
        @{ Type = 'Notebook'; Name = [string]$Control.Name.Notebook }
        @{ Type = 'KQLDashboard'; Name = [string]$app['dashboardName'] }
        @{ Type = 'SemanticModel'; Name = [string]$app['semanticModelName'] }
        @{ Type = 'Report'; Name = [string]$app['reportName'] }
        @{ Type = [string]$app['itemType']; Name = [string]$app['itemName'] }
        @{ Type = 'UserDataFunction'; Name = ('{0}_connector' -f [string]$app['itemName']) }
    )
    $controlItems = @(@{ Type = 'Notebook'; Name = [string]$Control.Name.Notebook })
    $answer = [ordered]@{ Ok = $true; Error = ''; Kind = ''; Demo = $null; Control = $null }
    $workspaces = Get-DemoActivityControlFabricList -Uri ('{0}/workspaces' -f $base) -Token $Token
    if ($workspaces.StatusCode -ne 200) {
        $answer.Ok = $false
        $answer.Error = $workspaces.Error
        $answer.Kind = Get-DemoFabricListFailureKind -StatusCode $workspaces.StatusCode -ErrorText $workspaces.Error
        return [pscustomobject]$answer
    }
    $read = {
        param([string] $Name, [object[]] $Allowed)
        $plan = [ordered]@{ Name = $Name; Id = ''; Exists = $false; Delete = $false; Items = @(); Foreign = @(); Notebook = ''; Reason = '' }
        $match = @($workspaces.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'displayName') -ceq $Name })
        if ($match.Count -eq 0) {
            $plan.Reason = 'it doesn''t exist'
            return $plan
        }
        $plan.Exists = $true
        $plan.Id = [string](Get-DemoMemberValue -InputObject $match[0] -Name 'id')
        $items = Get-DemoActivityControlFabricList -Uri ('{0}/workspaces/{1}/items' -f $base, $plan.Id) -Token $Token
        if ($items.StatusCode -ne 200) {
            $answer.Ok = $false
            $answer.Error = $items.Error
            $answer.Kind = Get-DemoFabricListFailureKind -StatusCode $items.StatusCode -ErrorText $items.Error
            $plan.Reason = ('its items couldn''t be listed: {0}' -f $items.Error)
            return $plan
        }
        $labels = [System.Collections.Generic.List[string]]::new()
        $foreign = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($items.Items)) {
            $type = [string](Get-DemoMemberValue -InputObject $item -Name 'type')
            $display = [string](Get-DemoMemberValue -InputObject $item -Name 'displayName')
            $labels.Add(('{0} {1}' -f $type, $display))
            if (@($Allowed | Where-Object { $_.Type -eq $type -and $_.Name -ceq $display }).Count -eq 0) {
                $foreign.Add(('{0} {1}' -f $type, $display))
            }
            if ($type -eq 'Notebook' -and $display -ceq [string]$Control.Name.Notebook) {
                $plan.Notebook = [string](Get-DemoMemberValue -InputObject $item -Name 'id')
            }
        }
        $plan.Items = $labels.ToArray()
        $plan.Foreign = $foreign.ToArray()
        return $plan
    }

    $demo = & $read ([string]$setting.WorkspaceName) $demoItems
    if ($demo.Exists -and -not $demo.Reason) {
        if ($demo.Foreign.Count -gt 0) {
            $demo.Reason = ('it holds what the demo didn''t create: {0}' -f ($demo.Foreign -join ', '))
        }
        else {
            $demo.Delete = $true
            $demo.Reason = ('everything in it is the demo''s ({0} item(s))' -f $demo.Items.Count)
        }
    }
    $answer.Demo = [pscustomobject]$demo

    $controlName = [string]$Control.Name.FabricWorkspace
    if ($controlName -ceq [string]$setting.WorkspaceName) {
        $answer.Control = [pscustomobject]@{ Name = $controlName; Id = $demo.Id; Exists = $false; Delete = $false; Items = @(); Foreign = @(); Notebook = ''; Reason = 'it''s the demo''s own workspace' }
        return [pscustomobject]$answer
    }
    $plan = & $read $controlName $controlItems
    if ($plan.Exists -and -not $plan.Reason) {
        if ($plan.Foreign.Count -gt 0) {
            $plan.Reason = ('it holds what the control didn''t create: {0}' -f ($plan.Foreign -join ', '))
        }
        elseif ($plan.Notebook) {
            $served = Get-DemoFabricNotebookResourceGroup -WorkspaceId $plan.Id -ItemId $plan.Notebook -Token $Token
            if (-not $served.Ok) {
                $plan.Reason = ('its control notebook couldn''t be read, so it can''t tell which environment it serves: {0}' -f $served.Error)
            }
            elseif ([string]::Equals($served.ResourceGroup, $resourceGroup, [System.StringComparison]::OrdinalIgnoreCase)) {
                $plan.Delete = $true
                $plan.Reason = ('its control notebook serves {0}' -f $resourceGroup)
            }
            else {
                $plan.Reason = ('its control notebook serves {0}, not {1}' -f $(if ($served.ResourceGroup) { $served.ResourceGroup } else { 'no resource group it names' }), $resourceGroup)
            }
        }
        elseif ($Control.State -eq 'Serves') {
            $plan.Delete = $true
            $plan.Reason = 'it''s empty, and the control serves this environment'
        }
        else {
            $plan.Reason = 'it''s empty, and nothing says it''s this environment''s'
        }
    }
    $answer.Control = [pscustomobject]$plan
    return [pscustomobject]$answer
}

function Get-DemoDestroyGroupPlan {
    <#
    .SYNOPSIS
    Whether destroy.ps1 deletes the T3 and T4 administrators' security group (t3AdminGroupObjectId), read-only: only a
    group init.ps1 created for this environment, which its description records ("Created by init.ps1.",
    New-DemoEntraSecurityGroup), under the name init.ps1 gives it (<prefix>-<environment>-sql-admins). A group you
    supplied is never deleted. Returns Id, Name, State (None, Delete, Keep, Gone, or Unknown), and Reason. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $id = ([string]$Config['t3AdminGroupObjectId']).ToLowerInvariant()
    $expected = '{0}-{1}-sql-admins' -f [string]$Config['prefix'], [string]$Config['environment']
    $plan = [ordered]@{ Id = $id; Name = ''; State = 'None'; Reason = '' }
    if ($id -notmatch $script:GuidPattern -or $id -eq '00000000-0000-0000-0000-000000000000') {
        $plan.Reason = 'the configuration names no group (t3AdminGroupObjectId)'
        return [pscustomobject]$plan
    }
    $read = Invoke-DemoRestRequest -SubscriptionId ([string]$Config['subscriptionId']) -Method 'GET' -Uri ('https://graph.microsoft.com/v1.0/groups/{0}?$select=id,displayName,description' -f $id)
    if ($read.ExitCode -ne 0) {
        if ([int]$read.StatusCode -eq 404 -or [string]$read.StdErr -match '(?i)Request_ResourceNotFound|does not exist') {
            $plan.State = 'Gone'
            $plan.Reason = 'it doesn''t exist'
        }
        else {
            $plan.State = 'Unknown'
            $plan.Reason = ('it couldn''t be read: {0}' -f (Get-DemoDeploymentErrorText -Text ([string]$read.StdErr) -MaxLength 200))
        }
        return [pscustomobject]$plan
    }
    $group = [string]$read.StdOut | ConvertFrom-Json -Depth 8
    $plan.Name = [string](Get-DemoMemberValue -InputObject $group -Name 'displayName')
    $description = [string](Get-DemoMemberValue -InputObject $group -Name 'description')
    if (-not $description.TrimEnd().EndsWith($script:DestroyGroupMarker, [System.StringComparison]::Ordinal)) {
        $plan.State = 'Keep'
        $plan.Reason = 'init.ps1 didn''t create it (you supplied it)'
    }
    elseif (-not [string]::Equals($plan.Name, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        $plan.State = 'Keep'
        $plan.Reason = ('init.ps1 created it under another name than this environment''s ({0})' -f $expected)
    }
    else {
        $plan.State = 'Delete'
        $plan.Reason = 'init.ps1 created it for this environment'
    }
    return [pscustomobject]$plan
}

function Get-DemoDestroyExtraPlan {
    <#
    .SYNOPSIS
    What destroy.ps1 deletes, and keeps, beyond the resource group, read before the confirmation: Control
    (Get-DemoDestroyControlPlan), Fabric (Get-DemoDestroyFabricPlan, or why it wasn't read), Group
    (Get-DemoDestroyGroupPlan), and Delete and Keep, the lines the confirmation lists. A part that can't be read is kept
    and says why. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [switch] $KeepFabric
    )

    $delete = [System.Collections.Generic.List[string]]::new()
    $keep = [System.Collections.Generic.List[string]]::new()
    $control = $null
    try {
        $control = Get-DemoDestroyControlPlan -Config $Config
    }
    catch {
        $control = [pscustomobject]@{ Name = (Get-DemoActivityControlName -Config $Config); State = 'Unknown'; ServedGroup = ''; Resources = @(); Reason = ('it couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) }
    }
    switch ($control.State) {
        'Serves' { $delete.Add(('the session control in {0} ({1}, {2}, {3}, and its custom roles once nothing else holds them)' -f $control.Name.ResourceGroup, $control.Name.AutomationAccount, $control.Name.KeyVault, $control.Name.Identity)) }
        'Leftover' {
            if (@($control.Resources).Count -eq 0) { $delete.Add(('the empty group {0}' -f $control.Name.ResourceGroup)) } else { $keep.Add(('{0}: {1}' -f $control.Name.ResourceGroup, $control.Reason)) }
        }
        'None' { }
        default { $keep.Add(('the session control in {0}: {1}' -f $control.Name.ResourceGroup, $control.Reason)) }
    }
    $fabric = [pscustomobject]@{ Read = $false; Token = $null; Plan = $null; Reason = '' }
    if ($KeepFabric) {
        $fabric.Reason = '-KeepFabric'
        $keep.Add('the Fabric workspaces, their items, and the history (-KeepFabric)')
    }
    else {
        try {
            $fabric.Token = Get-DemoFabricToken -SubscriptionId ([string]$Config['subscriptionId'])
            $fabric.Plan = Get-DemoDestroyFabricPlan -Config $Config -Token $fabric.Token -Control $control
            $fabric.Read = $true
        }
        catch {
            $fabric.Reason = ('Fabric couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        }
        if (-not $fabric.Read) {
            $keep.Add(('the Fabric workspaces: {0}' -f $fabric.Reason))
        }
        else {
            foreach ($workspace in @($fabric.Plan.Demo, $fabric.Plan.Control | Where-Object { $null -ne $_ })) {
                if ($workspace.Delete) {
                    $delete.Add(('the Fabric workspace "{0}" ({1})' -f $workspace.Name, $workspace.Reason))
                }
                elseif ($workspace.Exists) {
                    $keep.Add(('the Fabric workspace "{0}": {1}' -f $workspace.Name, $workspace.Reason))
                }
            }
            if (-not $fabric.Plan.Ok) {
                $keep.Add(('what Fabric couldn''t list: {0}' -f $fabric.Plan.Error))
            }
        }
    }
    $group = $null
    try {
        $group = Get-DemoDestroyGroupPlan -Config $Config
    }
    catch {
        $group = [pscustomobject]@{ Id = [string]$Config['t3AdminGroupObjectId']; Name = ''; State = 'Unknown'; Reason = ('it couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) }
    }
    switch ($group.State) {
        'Delete' { $delete.Add(('the security group "{0}" ({1})' -f $group.Name, $group.Reason)) }
        'Keep' { $keep.Add(('the security group "{0}": {1}' -f $group.Name, $group.Reason)) }
        'Unknown' { $keep.Add(('the security group {0}: {1}' -f $group.Id, $group.Reason)) }
    }
    $delete.Add(('the custom role "{0}" once no role assignment holds it' -f $script:SafetyStopRoleName))
    $keep.Add('the Fabric capacity and your licenses, which you manage')
    return [pscustomobject]@{ Control = $control; Fabric = $fabric; Group = $group; Delete = $delete.ToArray(); Keep = $keep.ToArray() }
}

function Remove-DemoUnassignedRoleDefinition {
    <#
    .SYNOPSIS
    Deletes a custom role definition only when no role assignment in the subscription holds it. Returns Outcome
    (Deleted, Kept, Missing, or Failed), Count (the assignments that hold it), and Error. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Its callers confirm once for the whole removal (destroy.ps1, setup-activity-control.ps1 -Remove).')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [AllowEmptyString()]
        [string] $RoleId
    )

    if (-not $RoleId) {
        return [pscustomobject]@{ Outcome = 'Missing'; Count = 0; Error = '' }
    }
    $count = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('role', 'assignment', 'list', '--all', '--role', $RoleId, '--fill-principal-name', 'false', '--fill-role-definition-name', 'false', '--query', 'length(@)', '--output', 'tsv') -AllowFailure -TimeoutSeconds 300
    $number = 0
    if ($count.ExitCode -ne 0 -or -not [int]::TryParse(([string]$count.StdOut).Trim(), [ref]$number)) {
        return [pscustomobject]@{ Outcome = 'Failed'; Count = -1; Error = ('its role assignments couldn''t be counted: {0}' -f (Get-DemoDeploymentErrorText -Text ([string]$count.StdErr) -MaxLength 200)) }
    }
    if ($number -gt 0) {
        return [pscustomobject]@{ Outcome = 'Kept'; Count = $number; Error = '' }
    }
    $delete = Invoke-DemoActivityControlArm -SubscriptionId $SubscriptionId -Method delete -Url ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/roleDefinitions/{1}?api-version=2022-04-01' -f $SubscriptionId, $RoleId)
    if ($delete.Ok -or $delete.Missing) {
        return [pscustomobject]@{ Outcome = 'Deleted'; Count = 0; Error = '' }
    }
    return [pscustomobject]@{ Outcome = 'Failed'; Count = 0; Error = [string]$delete.Error }
}

function Invoke-DemoDestroyExtra {
    <#
    .SYNOPSIS
    Deletes what Get-DemoDestroyExtraPlan found to be this environment's, in this order: the Fabric workspaces (the
    control's with its managed private endpoint, then the demo's), the session control's role assignments and roles,
    then its resources (Remove-DemoActivityControlRole, Remove-DemoActivityControlResource, as setup-activity-control.ps1
    -Remove), and the security group. Returns DESTROY.FABRIC.CONTROL, DESTROY.FABRIC.WORKSPACE, DESTROY.CONTROL,
    DESTROY.CONTROL.ROLES, DESTROY.CONTROL.RESOURCES, and DESTROY.ENTRA.GROUP. Each part's error is that part's Warning;
    the others go on. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [pscustomobject] $Plan
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $subscriptionId = [string]$Config['subscriptionId']
    $fabricDoc = 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/delete-workspace'
    $base = $script:FabricApiBaseUri
    $part = {
        param([string] $CheckId, [scriptblock] $Body)
        try {
            foreach ($item in @(& $Body)) {
                if ($null -ne $item) {
                    $results.Add($item)
                }
            }
        }
        catch {
            $results.Add((New-DemoResult -CheckId $CheckId -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('This part stopped: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'Run ./scripts/destroy.ps1 again: it finishes what''s left.'))
        }
    }

    # Fabric: the workspaces the plan found to be this environment's.
    $fabric = $Plan.Fabric
    foreach ($kind in @(@{ CheckId = 'DESTROY.FABRIC.CONTROL'; Key = 'Control'; Title = 'The control''s workspace' }, @{ CheckId = 'DESTROY.FABRIC.WORKSPACE'; Key = 'Demo'; Title = 'The demo''s workspace' })) {
        & $part $kind.CheckId {
            if ($fabric.Reason -eq '-KeepFabric') {
                return (New-DemoResult -CheckId $kind.CheckId -Area 'teardown' -Target 'fabric' -Status 'Not selected' -Message ('{0} stays with its items and the history (-KeepFabric).' -f $kind.Title) -DocUrl $fabricDoc)
            }
            if (-not $fabric.Read) {
                return (New-DemoResult -CheckId $kind.CheckId -Area 'teardown' -Target 'fabric' -Status 'Warning' -Message ('Nothing in Fabric was deleted: {0}' -f $fabric.Reason) -Remediation 'Run az login yourself if the sign-in expired, then run ./scripts/destroy.ps1 again: it finishes the Fabric part. Or delete the workspaces in Fabric yourself (Workspace settings > Remove this workspace).' -DocUrl $fabricDoc)
            }
            $workspace = $fabric.Plan.($kind.Key)
            if ($null -eq $workspace -or -not $workspace.Exists) {
                if (-not $fabric.Plan.Ok -and ($null -eq $workspace -or [string]$workspace.Reason -like 'its items*')) {
                    $fix = if ($fabric.Plan.Kind -eq 'CapacityInactive') { 'The workspace''s Fabric capacity is paused: resume it (or ask its administrator), then run ./scripts/destroy.ps1 again; it finishes the Fabric part.' } else { 'Run ./scripts/destroy.ps1 again in a few minutes; it finishes the Fabric part.' }
                    return (New-DemoResult -CheckId $kind.CheckId -Area 'teardown' -Target 'fabric' -Status 'Warning' -Message ('{0} wasn''t deleted: Fabric couldn''t list it ({1}).' -f $kind.Title, $fabric.Plan.Error) -Remediation $fix -DocUrl $fabricDoc)
                }
                $label = if ($null -ne $workspace) { '"{0}"' -f $workspace.Name } else { '' }
                return (New-DemoResult -CheckId $kind.CheckId -Area 'teardown' -Target 'fabric' -Status 'Pass' -Message ('{0} {1} doesn''t exist; nothing to delete.' -f $kind.Title, $label).Replace('  ', ' ') -DocUrl $fabricDoc)
            }
            if (-not $workspace.Delete) {
                return (New-DemoResult -CheckId $kind.CheckId -Area 'teardown' -Target 'fabric' -Status 'Not selected' -Message ('The Fabric workspace "{0}" stays: {1}.' -f $workspace.Name, $workspace.Reason) -Evidence ([ordered]@{ workspace = $workspace.Name; items = @($workspace.Items); foreign = @($workspace.Foreign) }) -Remediation 'If it''s yours to delete, delete it in Fabric (Workspace settings > Remove this workspace).' -DocUrl $fabricDoc)
            }
            $endpoints = Get-DemoActivityControlFabricList -Uri ('{0}/workspaces/{1}/managedPrivateEndpoints' -f $base, $workspace.Id) -Token $fabric.Token
            foreach ($endpoint in @($endpoints.Items)) {
                $null = Invoke-DemoFabricRequest -Method Delete -Uri ('{0}/workspaces/{1}/managedPrivateEndpoints/{2}' -f $base, $workspace.Id, [string](Get-DemoMemberValue -InputObject $endpoint -Name 'id')) -Token $fabric.Token
            }
            $delete = Invoke-DemoFabricRequest -Method Delete -Uri ('{0}/workspaces/{1}' -f $base, $workspace.Id) -Token $fabric.Token
            if ($delete.StatusCode -in 200, 204, 404) {
                $note = if (@($endpoints.Items).Count -gt 0) { ' and its {0} managed private endpoint(s)' -f @($endpoints.Items).Count } else { '' }
                return (New-DemoResult -CheckId $kind.CheckId -Area 'teardown' -Target 'fabric' -Status 'Pass' -Message ('Deleted the Fabric workspace "{0}"{1}: {2}.' -f $workspace.Name, $note, $(if (@($workspace.Items).Count) { ($workspace.Items -join ', ') } else { 'it was empty' })) -Evidence ([ordered]@{ workspace = $workspace.Name; workspaceId = $workspace.Id; items = @($workspace.Items) }) -DocUrl $fabricDoc)
            }
            $errorText = Get-DemoFabricErrorText -Response $delete
            $fix = if ((Get-DemoFabricListFailureKind -StatusCode $delete.StatusCode -ErrorText $errorText) -eq 'CapacityInactive') { 'Its Fabric capacity is paused: resume it (or ask its administrator), then run ./scripts/destroy.ps1 again.' } elseif ($delete.StatusCode -in 401, 403) { 'Deleting a workspace needs its Admin role: ask one of its admins, or delete it in Fabric yourself (Workspace settings > Remove this workspace).' } else { 'Run ./scripts/destroy.ps1 again: it finishes the Fabric part.' }
            return (New-DemoResult -CheckId $kind.CheckId -Area 'teardown' -Target 'fabric' -Status 'Warning' -Message ('The Fabric workspace "{0}" couldn''t be deleted: {1}' -f $workspace.Name, $errorText) -Remediation $fix -DocUrl $fabricDoc)
        }
    }

    # The session control (ADR 0020, ADR 0026): what setup-activity-control.ps1 -Remove deletes, when it serves this
    # environment.
    $control = $Plan.Control
    & $part 'DESTROY.CONTROL' {
        $doc = 'https://learn.microsoft.com/azure/automation/delete-account'
        switch ($control.State) {
            'None' {
                return (New-DemoResult -CheckId 'DESTROY.CONTROL' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('There''s no session control: {0}.' -f $control.Reason) -DocUrl $doc)
            }
            'Serves' {
                $roles = Remove-DemoActivityControlRole -Name $control.Name -Confirm:$false
                $roles.checkId = 'DESTROY.CONTROL.ROLES'
                $resources = Remove-DemoActivityControlResource -Config $Config -Name $control.Name -Confirm:$false
                $resources.checkId = 'DESTROY.CONTROL.RESOURCES'
                $status = Get-DemoWorstStatus -Status @([string]$roles.status, [string]$resources.status)
                $summary = New-DemoResult -CheckId 'DESTROY.CONTROL' -Area 'teardown' -Target 'subscription' -Status $(if ($status -eq 'Pass') { 'Pass' } else { 'Warning' }) -Message ('The session control in {0} served this environment ({1}), so it was deleted: DESTROY.CONTROL.ROLES and DESTROY.CONTROL.RESOURCES say what went.' -f $control.Name.ResourceGroup, $control.Reason) -Remediation $(if ($status -eq 'Pass') { '' } else { 'Run ./scripts/destroy.ps1 again: it finishes what''s left of the control.' }) -DocUrl $doc
                return @($summary, $roles, $resources)
            }
            'Leftover' {
                if (@($control.Resources).Count -eq 0) {
                    $group = Invoke-DemoAz -SubscriptionId $control.Name.SubscriptionId -ArgumentList @('group', 'delete', '--name', $control.Name.ResourceGroup, '--yes', '--no-wait') -AllowFailure -TimeoutSeconds 300
                    if ($group.ExitCode -eq 0) {
                        return (New-DemoResult -CheckId 'DESTROY.CONTROL' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('{0} was empty, so it''s being deleted.' -f $control.Name.ResourceGroup) -DocUrl $doc)
                    }
                    return (New-DemoResult -CheckId 'DESTROY.CONTROL' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('The empty group {0} couldn''t be deleted: {1}' -f $control.Name.ResourceGroup, (Get-DemoDeploymentErrorText -Text ([string]$group.StdErr) -MaxLength 300)) -Remediation 'Run ./scripts/destroy.ps1 again.' -DocUrl $doc)
                }
            }
        }
        $command = './scripts/setup-activity-control.ps1 -Remove'
        return (New-DemoResult -CheckId 'DESTROY.CONTROL' -Area 'teardown' -Target 'subscription' -Status 'Not selected' -Message ('The session control in {0} stays: {1}.' -f $control.Name.ResourceGroup, $control.Reason) -Evidence ([ordered]@{ group = $control.Name.ResourceGroup; servedGroup = $control.ServedGroup; resources = @($control.Resources) }) -Remediation ('If it''s this environment''s, {0} deletes it, with the configuration that set it up.' -f $command) -DocUrl $doc)
    }

    # The T3 and T4 administrators' security group, when init.ps1 created it for this environment.
    $group = $Plan.Group
    & $part 'DESTROY.ENTRA.GROUP' {
        $doc = 'https://learn.microsoft.com/graph/api/group-delete'
        switch ($group.State) {
            'None' { return (New-DemoResult -CheckId 'DESTROY.ENTRA.GROUP' -Area 'teardown' -Target 'tenant' -Status 'Not selected' -Message ('No security group to delete: {0}.' -f $group.Reason) -DocUrl $doc) }
            'Gone' { return (New-DemoResult -CheckId 'DESTROY.ENTRA.GROUP' -Area 'teardown' -Target 'tenant' -Status 'Pass' -Message ('The security group {0} doesn''t exist; nothing to delete.' -f $group.Id) -DocUrl $doc) }
            'Delete' {
                $delete = Invoke-DemoRestRequest -SubscriptionId $subscriptionId -Method 'DELETE' -Uri ('https://graph.microsoft.com/v1.0/groups/{0}' -f $group.Id)
                if ($delete.ExitCode -eq 0 -or [int]$delete.StatusCode -eq 404) {
                    return (New-DemoResult -CheckId 'DESTROY.ENTRA.GROUP' -Area 'teardown' -Target 'tenant' -Status 'Pass' -Message ('Deleted the security group "{0}" ({1}), which init.ps1 created for this environment as T3''s and T4''s Microsoft Entra administrators.' -f $group.Name, $group.Id) -DocUrl $doc)
                }
                return (New-DemoResult -CheckId 'DESTROY.ENTRA.GROUP' -Area 'teardown' -Target 'tenant' -Status 'Warning' -Message ('The security group "{0}" couldn''t be deleted: {1}' -f $group.Name, (Get-DemoDeploymentErrorText -Text ([string]$delete.StdErr) -MaxLength 300)) -Remediation ('One of its owners, or a Groups Administrator, deletes it: Microsoft Entra admin center > Groups > {0} > Delete.' -f $group.Name) -DocUrl $doc)
            }
            default {
                $label = if ($group.Name) { '"{0}" ({1})' -f $group.Name, $group.Id } else { $group.Id }
                return (New-DemoResult -CheckId 'DESTROY.ENTRA.GROUP' -Area 'teardown' -Target 'tenant' -Status 'Not selected' -Message ('The security group {0} stays: {1}.' -f $label, $group.Reason) -Remediation 'If nothing else uses it, delete it in the Microsoft Entra admin center (Groups > the group > Delete).' -DocUrl $doc)
            }
        }
    }
    return $results.ToArray()
}
