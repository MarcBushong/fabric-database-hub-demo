# Fabric resources by name (ADR 0021): the helpers behind Resolve-DemoFabricConfig. Internal; tests mock
# Invoke-WebRequest and Start-Sleep. Every request goes through Invoke-DemoFabricRequest, which sends the token only
# to the Fabric API, and lists go through Read-DemoHubFabricList, which follows continuation pages on that host only.
$script:FabricZeroGuid = '00000000-0000-0000-0000-000000000000'
$script:FabricResolveDoc = [ordered]@{
    ListWorkspaces   = 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/list-workspaces'
    CreateWorkspace  = 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/create-workspace'
    GetWorkspace     = 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/get-workspace'
    AssignToCapacity = 'https://learn.microsoft.com/rest/api/fabric/core/workspaces/assign-to-capacity'
    ListCapacities   = 'https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities'
    ListLakehouses   = 'https://learn.microsoft.com/rest/api/fabric/lakehouse/items/list-lakehouses'
    CreateLakehouse  = 'https://learn.microsoft.com/rest/api/fabric/lakehouse/items/create-lakehouse'
    TenantSetting    = 'https://learn.microsoft.com/fabric/admin/portal-workspace'
    CapacityUsers    = 'https://learn.microsoft.com/power-bi/enterprise/service-admin-premium-manage#manage-user-permissions'
    PauseResume      = 'https://learn.microsoft.com/fabric/enterprise/pause-resume'
}

function Test-DemoFabricIdOverride {
    <#
    .SYNOPSIS
    True when a configured fabric.workspaceId or fabric.lakehouseId is a real override: a GUID other than the
    all-zero placeholder that configurations written before ADR 0021 carry. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Value
    )

    return ($Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -and $Value -ne $script:FabricZeroGuid)
}

function Get-DemoFabricResolveSetting {
    <#
    .SYNOPSIS
    The Fabric names, the ID overrides, and createIfMissing from the configuration, with the schema's defaults for a
    configuration that wasn't loaded through Get-DemoConfig. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $fabric = Get-DemoMemberValue -InputObject $Config -Name 'fabric'
    $text = {
        param([string] $Name, [string] $Default)
        $value = [string](Get-DemoMemberValue -InputObject $fabric -Name $Name)
        if ([string]::IsNullOrWhiteSpace($value)) { $Default } else { $value.Trim() }
    }
    $create = Get-DemoMemberValue -InputObject $fabric -Name 'createIfMissing'
    $workspaceId = [string](Get-DemoMemberValue -InputObject $fabric -Name 'workspaceId')
    $lakehouseId = [string](Get-DemoMemberValue -InputObject $fabric -Name 'lakehouseId')
    [pscustomobject]@{
        WorkspaceName   = (& $text 'workspaceName' 'Database Hub Demo')
        LakehouseName   = (& $text 'lakehouseName' 'LH_DatabaseHub')
        CapacityName    = (& $text 'capacityName' '')
        CreateIfMissing = $(if ($null -eq $create) { $true } else { [bool]$create })
        WorkspaceId     = $(if (Test-DemoFabricIdOverride -Value $workspaceId) { $workspaceId.ToLowerInvariant() } else { '' })
        LakehouseId     = $(if (Test-DemoFabricIdOverride -Value $lakehouseId) { $lakehouseId.ToLowerInvariant() } else { '' })
    }
}

function Select-DemoFabricNamed {
    <#
    .SYNOPSIS
    The items whose displayName is -Name: the exact matches when there are any, otherwise those that match ignoring
    case (Fabric treats names that differ only in case as the same name). Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Items,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $exact = [System.Collections.Generic.List[object]]::new()
    $loose = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($Items)) {
        $displayName = [string](Get-DemoMemberValue -InputObject $item -Name 'displayName')
        if ($displayName -ceq $Name) {
            $exact.Add($item)
        }
        elseif ([string]::Equals($displayName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            $loose.Add($item)
        }
    }
    if ($exact.Count -gt 0) {
        return $exact.ToArray()
    }
    return $loose.ToArray()
}

function Get-DemoFabricResolveStatus {
    <#
    .SYNOPSIS
    The ADR 0012 status for a Fabric REST error: Manual action required for what a person fixes (a sign-in, a
    permission, a name in use, a capacity that isn't usable), Fail for anything else. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int] $StatusCode,

        [AllowNull()]
        [object] $Body
    )

    $code = [string](Get-DemoMemberValue -InputObject $Body -Name 'errorCode')
    if ($StatusCode -in 401, 403, 409) {
        return 'Manual action required'
    }
    if ($code -match '(?i)Unauthorized|Permission|Privilege|Forbidden|AlreadyInUse|AlreadyExists|NameConflict|Capacity') {
        return 'Manual action required'
    }
    return 'Fail'
}

function Get-DemoFabricCapacityChoice {
    <#
    .SYNOPSIS
    Finds the capacity named -Name among those you can assign (Capacities - List Capacities lists only capacities
    you administer or contribute to) and checks it's Active. Internal.

    .DESCRIPTION
    Returns Status (Pass, Manual action required, or Fail), Message, Remediation, DocUrl, CapacityId, Sku, State,
    and Visible (up to five names of capacities you can assign, for the message). Never changes a capacity.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $Name,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [ValidateRange(1, 50)]
        [int] $MaxPages = 20
    )

    $doc = $script:FabricResolveDoc['ListCapacities']
    $choice = [ordered]@{ Status = 'Pass'; Message = ''; Remediation = ''; DocUrl = $doc; CapacityId = ''; Sku = ''; State = ''; Visible = '' }
    $list = Read-DemoHubFabricList -Uri ('{0}/capacities' -f $script:FabricApiBaseUri) -Token $Token -MaxPages $MaxPages
    $names = @($list.Items | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'displayName') } | Where-Object { $_ } | Sort-Object -Unique)
    $choice['Visible'] = if ($names.Count -eq 0) { 'none' } else { (@($names | Select-Object -First 5) -join ', ') + $(if ($names.Count -gt 5) { ', ...' } else { '' }) }
    $addUser = 'A capacity administrator adds you as a contributor in the capacity''s settings (Fabric admin portal > Capacity settings > the capacity > Contributor permissions).'

    if (-not $list.Succeeded) {
        $choice['Status'] = if ($list.StatusCode -in 401, 403) { 'Manual action required' } else { 'Fail' }
        $choice['Message'] = 'The Fabric capacities you can assign couldn''t be listed: {0}' -f $list.Error
        $choice['Remediation'] = 'Check your Fabric access and run the script again.'
        return [pscustomobject]$choice
    }
    if (-not $Name) {
        $choice['Status'] = 'Manual action required'
        $choice['Message'] = 'fabric.capacityName isn''t set, so there''s no capacity to put the workspace on. Capacities you can assign: {0}.' -f $choice['Visible']
        $choice['Remediation'] = 'Set fabric.capacityName in config/demo.config.json to an F or Trial capacity you can assign, then run the script again. {0}' -f $addUser
        return [pscustomobject]$choice
    }
    $matched = @(Select-DemoFabricNamed -Items @($list.Items) -Name $Name)
    if ($matched.Count -eq 0) {
        $choice['Status'] = 'Manual action required'
        $choice['Message'] = 'No capacity named "{0}" is among those you can assign (List Capacities shows only capacities you administer or contribute to). Capacities you can assign: {1}.' -f $Name, $choice['Visible']
        $choice['Remediation'] = 'Set fabric.capacityName to one of those, or: {0} The scripts never create a capacity.' -f $addUser
        $choice['DocUrl'] = $script:FabricResolveDoc['CapacityUsers']
        return [pscustomobject]$choice
    }
    if ($matched.Count -gt 1) {
        $choice['Status'] = 'Manual action required'
        $choice['Message'] = 'More than one capacity named "{0}" is visible to you, so the scripts can''t pick one.' -f $Name
        $choice['Remediation'] = 'Ask a capacity administrator to rename one, or create the workspace yourself on the right capacity and run the script again.'
        return [pscustomobject]$choice
    }
    $capacity = $matched[0]
    $choice['CapacityId'] = [string](Get-DemoMemberValue -InputObject $capacity -Name 'id')
    $choice['Sku'] = [string](Get-DemoMemberValue -InputObject $capacity -Name 'sku')
    $choice['State'] = [string](Get-DemoMemberValue -InputObject $capacity -Name 'state')
    if ($choice['State'] -ine 'Active') {
        $choice['Status'] = 'Manual action required'
        $choice['Message'] = 'The capacity "{0}" ({1}) is {2}, so nothing can be created on it. The scripts never resume, pause, or scale a capacity.' -f $Name, $choice['Sku'], $(if ($choice['State']) { $choice['State'] } else { 'in an unknown state' })
        $choice['Remediation'] = 'The capacity''s administrator resumes it (Azure portal > the Fabric capacity > Resume), then run the script again.'
        $choice['DocUrl'] = $script:FabricResolveDoc['PauseResume']
        return [pscustomobject]$choice
    }
    $choice['Message'] = 'The capacity "{0}" ({1}) is Active.' -f $Name, $choice['Sku']
    return [pscustomobject]$choice
}

function Wait-DemoFabricCapacityAssignment {
    <#
    .SYNOPSIS
    Reads the workspace (Workspaces - Get Workspace) until its capacityAssignmentProgress is Completed or Failed, or
    -TimeoutSeconds passes. Internal.

    .DESCRIPTION
    Assign To Capacity answers 202 without an operation to follow, and Create Workspace can return before the
    assignment is done, so the workspace itself is the documented signal. Returns Progress (Completed, Failed,
    InProgress, or Unknown), CapacityId, and Error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 120,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 5
    )

    $waited = 0
    $last = [pscustomobject]@{ Progress = 'Unknown'; CapacityId = ''; Error = '' }
    while ($true) {
        $read = Invoke-DemoHubFabricGet -Uri ('{0}/workspaces/{1}' -f $script:FabricApiBaseUri, $WorkspaceId) -Token $Token
        if ($read.StatusCode -eq 200) {
            $progress = [string](Get-DemoMemberValue -InputObject $read.Body -Name 'capacityAssignmentProgress')
            $capacityId = [string](Get-DemoMemberValue -InputObject $read.Body -Name 'capacityId')
            if (-not $progress) {
                $progress = if ($capacityId) { 'Completed' } else { 'Unknown' }
            }
            $last = [pscustomobject]@{ Progress = $progress; CapacityId = $capacityId; Error = '' }
            if ($progress -in 'Completed', 'Failed') {
                return $last
            }
        }
        else {
            $last = [pscustomobject]@{ Progress = 'Unknown'; CapacityId = ''; Error = $read.Error }
        }
        if ($waited -ge $TimeoutSeconds) {
            return $last
        }
        Start-Sleep -Seconds $PollSeconds
        $waited += $PollSeconds
    }
}

function Copy-DemoConfig {
    <#
    .SYNOPSIS
    A deep copy of a configuration (a JSON round trip), so a resolved copy never changes the caller's. Internal.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    return ($Config | ConvertTo-Json -Depth 32 | ConvertFrom-Json -AsHashtable -Depth 32)
}

function Test-DemoFabricResolution {
    <#
    .SYNOPSIS
    Preflight's P5 (Phase 26a, ADR 0021): the Fabric workspace and lakehouse by name, read-only. Internal.

    .DESCRIPTION
    Resolve-DemoFabricConfig without -Create, so nothing is created. For a workspace it finds (or the
    fabric.workspaceId override), Test-DemoFabricWorkspace checks your role and its capacity (FABRIC.P5.*); for one
    that deploy.ps1 would create, Get-DemoFabricCapacityChoice checks the capacity in fabric.capacityName. Returns
    Result (PREFLIGHT.P5.WORKSPACE), Config (the resolved copy), and CapacityResult (FABRIC.P5.CAPACITY, or $null),
    so P11 reuses the SKU without another request.
    - Pass: the workspace is there, you're Contributor or higher, and it's on an Active F capacity; the lakehouse is
      there too, or deploy.ps1 creates it.
    - Warning: the workspace doesn't exist yet, and the capacity it would be created on is one you can assign and
      Active: deploy.ps1 creates it, which also needs the Fabric tenant setting "Create workspaces" for you, and no
      API reads that setting without Fabric administrator rights.
    - Otherwise the status of what blocks it, with the same steps (Manual action required, or Fail).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [securestring] $Token
    )

    $setting = Get-DemoFabricResolveSetting -Config $Config
    $doc = 'https://learn.microsoft.com/fabric/enterprise/licenses'
    $rank = @{ 'Fail' = 5; 'Manual action required' = 4; 'Warning' = 3; 'Pass' = 2; 'Not supported' = 1; 'Not selected' = 0 }
    $output = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation, [string] $DocUrl, [object] $Resolved, [object] $Capacity)
        [pscustomobject]@{
            Result         = (New-DemoResult -CheckId 'PREFLIGHT.P5.WORKSPACE' -Area 'preflight' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl)
            Config         = $Resolved
            CapacityResult = $Capacity
        }
    }

    if ($null -eq $Token) {
        $access = Get-DemoHubFabricAccess -SubscriptionId ([string]$Config['subscriptionId'])
        $Token = $access.Token
        if ($null -eq $Token) {
            return (& $output 'Manual action required' ('The Fabric workspace "{0}" couldn''t be checked: {1}' -f $setting.WorkspaceName, $access.Error) ([ordered]@{ workspaceName = $setting.WorkspaceName }) 'Sign in once with ''az login --tenant <tenantId>'' (no need to change the default subscription), then run preflight.ps1 again.' $doc $Config $null)
        }
    }

    $resolution = Resolve-DemoFabricConfig -Config $Config -Token $Token
    $workspaceRecord = @($resolution.Results | Where-Object { $_.checkId -eq 'FABRIC.RESOLVE.WORKSPACE' }) | Select-Object -First 1
    $lakehouseRecord = @($resolution.Results | Where-Object { $_.checkId -eq 'FABRIC.RESOLVE.LAKEHOUSE' }) | Select-Object -First 1
    $evidence = [ordered]@{ workspaceName = $setting.WorkspaceName; lakehouseName = $setting.LakehouseName; capacityName = $setting.CapacityName; createIfMissing = $setting.CreateIfMissing }

    if ($resolution.WorkspaceId) {
        $evidence['workspaceId'] = $resolution.WorkspaceId
        $p5 = @(Test-DemoFabricWorkspace -Config $resolution.Config -Token $Token)
        $parts = @($p5) + @($lakehouseRecord | Where-Object { $null -ne $_ -and $_.status -in 'Manual action required', 'Fail' })
        $worst = @($parts | Sort-Object -Property { $rank[[string]$_.status] } -Descending) | Select-Object -First 1
        $status = if ($null -eq $worst) { 'Manual action required' } else { [string]$worst.status }
        $message = (@($parts | ForEach-Object { [string]$_.message }) -join ' ')
        if ($null -ne $lakehouseRecord -and $lakehouseRecord.status -eq 'Warning') {
            $message += (' The lakehouse "{0}" isn''t there yet; deploy.ps1 creates it, with lakehouse schemas.' -f $setting.LakehouseName)
        }
        $remediation = if ($null -ne $worst) { [string]$worst.remediation } else { '' }
        $capacityResult = @($p5 | Where-Object { $_.checkId -eq 'FABRIC.P5.CAPACITY' }) | Select-Object -First 1
        return (& $output $status $message.Trim() $evidence $remediation $doc $resolution.Config $capacityResult)
    }
    if ($null -ne $workspaceRecord -and $workspaceRecord.status -eq 'Warning') {
        $capacity = Get-DemoFabricCapacityChoice -Name $setting.CapacityName -Token $Token
        $evidence['capacitySku'] = $capacity.Sku
        $evidence['capacityState'] = $capacity.State
        if ($capacity.Status -eq 'Pass') {
            return (& $output 'Warning' ('The Fabric workspace "{0}" doesn''t exist yet: deploy.ps1 creates it, with the lakehouse "{1}", on the capacity "{2}" ({3}), which you can assign and is Active. Creating a workspace also needs the Fabric tenant setting "Create workspaces" for you, which only a Fabric administrator can read.' -f $setting.WorkspaceName, $setting.LakehouseName, $setting.CapacityName, $capacity.Sku) $evidence 'Nothing to do if your tenant lets you create workspaces. Otherwise a Fabric administrator turns on "Create workspaces" for you (Admin portal > Tenant settings > Workspace settings), or a workspace administrator creates the workspace and adds you as Contributor or higher.' $script:FabricResolveDoc['TenantSetting'] $resolution.Config $null)
        }
        return (& $output $capacity.Status ('The Fabric workspace "{0}" doesn''t exist, and deploy.ps1 can''t create it: {1}' -f $setting.WorkspaceName, $capacity.Message) $evidence $capacity.Remediation $capacity.DocUrl $resolution.Config $null)
    }
    $status = if ($null -ne $workspaceRecord) { [string]$workspaceRecord.status } else { 'Manual action required' }
    $message = if ($null -ne $workspaceRecord) { [string]$workspaceRecord.message } else { 'The Fabric workspace couldn''t be resolved.' }
    $remediation = if ($null -ne $workspaceRecord) { [string]$workspaceRecord.remediation } else { '' }
    return (& $output $status $message $evidence $remediation $doc $resolution.Config $null)
}

function Get-DemoFabricStatus {
    <#
    .SYNOPSIS
    status.ps1's STATUS.FABRIC (Phase 26a, ADR 0021): the Fabric workspace and lakehouse by name, and the state of the
    workspace's capacity. Read-only: it never creates anything and never changes the capacity. Internal.

    .DESCRIPTION
    Pass when the workspace and the lakehouse are there, whatever the capacity's state: a capacity paused between
    sessions is normal, and its administrator resumes it. Otherwise the status, message, and steps of what
    Resolve-DemoFabricConfig found (a Warning when deploy.ps1 or configure-fabric.ps1 would create it). Uses Get
    Workspace and List Capacities (https://learn.microsoft.com/rest/api/fabric/core/capacities/list-capacities).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [securestring] $Token
    )

    $setting = Get-DemoFabricResolveSetting -Config $Config
    $doc = $script:FabricResolveDoc['ListWorkspaces']
    $record = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation, [string] $DocUrl)
        New-DemoResult -CheckId 'STATUS.FABRIC' -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl
    }
    if ($null -eq $Token) {
        $access = Get-DemoHubFabricAccess -SubscriptionId ([string]$Config['subscriptionId'])
        $Token = $access.Token
        if ($null -eq $Token) {
            return (& $record 'Warning' ('Fabric wasn''t checked: {0}' -f $access.Error) ([ordered]@{ workspaceName = $setting.WorkspaceName }) 'Sign in once with ''az login --tenant <tenantId>'', then run status.ps1 again.' $doc)
        }
    }

    $resolution = Resolve-DemoFabricConfig -Config $Config -Token $Token
    if (-not $resolution.Resolved) {
        $rank = @{ 'Fail' = 5; 'Manual action required' = 4; 'Warning' = 3; 'Pass' = 2; 'Not supported' = 1; 'Not selected' = 0 }
        $worst = @($resolution.Results | Sort-Object -Property { $rank[[string]$_.status] } -Descending) | Select-Object -First 1
        $status = if ($null -ne $worst -and $worst.status -in 'Fail', 'Manual action required', 'Warning') { [string]$worst.status } else { 'Warning' }
        $message = (@($resolution.Results | Where-Object { $_.status -ne 'Pass' } | ForEach-Object { [string]$_.message }) -join ' ')
        $remediation = if ($null -ne $worst) { [string]$worst.remediation } else { '' }
        return (& $record $status ('Fabric: {0}' -f $message).Trim() ([ordered]@{ workspaceName = $setting.WorkspaceName; lakehouseName = $setting.LakehouseName }) $remediation $doc)
    }

    $evidence = [ordered]@{ workspaceId = $resolution.WorkspaceId; lakehouseId = $resolution.LakehouseId; workspaceName = $resolution.WorkspaceName; lakehouseName = $resolution.LakehouseName }
    $workspace = Invoke-DemoHubFabricGet -Uri ('{0}/workspaces/{1}' -f $script:FabricApiBaseUri, $resolution.WorkspaceId) -Token $Token
    if ($workspace.StatusCode -ne 200) {
        # An ID override isn't looked up by the resolver, so this is where a stale one shows.
        return (& $record 'Warning' ('Fabric: the workspace couldn''t be read: {0}' -f $workspace.Error) $evidence 'Check fabric.workspaceName (or the fabric.workspaceId override) and your role in the workspace, then run status.ps1 again.' $script:FabricResolveDoc['GetWorkspace'])
    }
    $name = [string](Get-DemoMemberValue -InputObject $workspace.Body -Name 'displayName')
    if (-not $name) {
        $name = $resolution.WorkspaceName
    }
    $capacityId = [string](Get-DemoMemberValue -InputObject $workspace.Body -Name 'capacityId')
    $capacityText = 'its capacity couldn''t be read'
    if (-not $capacityId) {
        $capacityText = 'it isn''t on a capacity, so its notebooks, dashboard, report, and app can''t run'
    }
    elseif ($capacityId) {
        $evidence['capacityId'] = $capacityId
        $capacities = Read-DemoHubFabricList -Uri ('{0}/capacities' -f $script:FabricApiBaseUri) -Token $Token
        $capacity = @($capacities.Items | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'id') -ieq $capacityId }) | Select-Object -First 1
        if ($null -eq $capacity) {
            $capacityText = 'its capacity isn''t among those you administer or contribute to, so its state can''t be read'
        }
        else {
            $state = [string](Get-DemoMemberValue -InputObject $capacity -Name 'state')
            $evidence['capacityState'] = $state
            $evidence['capacitySku'] = [string](Get-DemoMemberValue -InputObject $capacity -Name 'sku')
            $capacityText = if ($state -ieq 'Active') {
                'its capacity "{0}" ({1}) is Active' -f [string](Get-DemoMemberValue -InputObject $capacity -Name 'displayName'), $evidence['capacitySku']
            }
            else {
                'its capacity "{0}" ({1}) is {2}: its administrator resumes it before a session (the scripts never do)' -f [string](Get-DemoMemberValue -InputObject $capacity -Name 'displayName'), $evidence['capacitySku'], $state
            }
        }
    }
    & $record 'Pass' ('Fabric: the workspace "{0}" and the lakehouse "{1}" are there; {2}.' -f $name, $resolution.LakehouseName, $capacityText) $evidence '' $doc
}