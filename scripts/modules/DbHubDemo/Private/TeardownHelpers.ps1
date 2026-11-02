function Resolve-DemoTeardownManifest {
    <#
    .SYNOPSIS
    Combines a fresh manifest with the one an earlier, interrupted destroy of the same resource group wrote,
    and saves the result to -Path. Internal.

    .DESCRIPTION
    Only a manifest recorded while the group existed knows its identities, so a run after an interruption
    keeps what the earlier run recorded:
    - The group is gone: the earlier manifest replaces the fresh one, which knows no identities, and the file
      isn't changed.
    - The group still exists (still being deleted, or partly deleted): the identities the earlier manifest
      recorded for the same deploymentId are added to the fresh one, because their resources may be gone.
    An earlier manifest for another group, one taken after its group was gone, or one that can't be read is
    replaced. The file holds names and IDs only, no secret.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [object] $Manifest,

        [string] $Path = ''
    )

    $previous = $null
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        try {
            $previous = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 10
        }
        catch {
            Write-DemoLog -Level Warning -Message ('The earlier manifest {0} couldn''t be read, so it''s replaced.' -f $Path)
        }
        if ($null -ne $previous -and ([string](Get-DemoMemberValue -InputObject $previous -Name 'ResourceGroupName') -ne [string](Get-DemoMemberValue -InputObject $Manifest -Name 'ResourceGroupName') -or -not [bool](Get-DemoMemberValue -InputObject $previous -Name 'ResourceGroupExisted'))) {
            $previous = $null
        }
    }
    if ($null -ne $previous -and -not [bool](Get-DemoMemberValue -InputObject $Manifest -Name 'ResourceGroupExisted')) {
        Write-DemoLog -Message ('{0} is already gone, so the residual check uses the manifest recorded while it existed ({1}, {2}).' -f (Get-DemoMemberValue -InputObject $Manifest -Name 'ResourceGroupName'), $Path, (Get-DemoMemberValue -InputObject $previous -Name 'RecordedUtc'))
        return $previous
    }
    $deploymentId = [string](Get-DemoMemberValue -InputObject $Manifest -Name 'DeploymentId')
    if ($null -ne $previous -and $deploymentId -and [string](Get-DemoMemberValue -InputObject $previous -Name 'DeploymentId') -eq $deploymentId) {
        # Assigned first: Get-DemoMemberValue returns an array as one object, which @() wouldn't unroll.
        $current = Get-DemoMemberValue -InputObject $Manifest -Name 'Principals'
        $earlier = Get-DemoMemberValue -InputObject $previous -Name 'Principals'
        $known = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($principal in @($current)) {
            $null = $known.Add([string](Get-DemoMemberValue -InputObject $principal -Name 'PrincipalId'))
        }
        $added = @(foreach ($principal in @($earlier)) {
                $id = [string](Get-DemoMemberValue -InputObject $principal -Name 'PrincipalId')
                if ($id -and $known.Add($id)) {
                    $principal
                }
            })
        if ($added.Count) {
            $Manifest.Principals = @(@($current) | Where-Object { $null -ne $_ }) + $added
            Write-DemoLog -Message ('An earlier, interrupted destroy of the group recorded {0} more identit(ies); the residual check looks for them too.' -f $added.Count)
        }
    }
    if ($Path) {
        $directory = Split-Path -Path $Path -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        Set-Content -LiteralPath $Path -Value ($Manifest | ConvertTo-Json -Depth 6) -Encoding utf8NoBOM
    }
    return $Manifest
}

function Get-DemoResourceGraphReach {
    <#
    .SYNOPSIS
    Whether Azure Resource Graph lists the configured subscription for the signed-in identity. Read-only.
    Internal.

    .DESCRIPTION
    Resource Graph reads go through Invoke-DemoRestRequest with a token that Get-DemoAccessToken verified for
    the configured tenant and caller (ADR 0011, guard update), but Resource Graph trims its answer to what the
    caller can read: a query for a subscription the caller can't read comes back empty instead of failing, and
    an empty answer must never read as "nothing is left". So Resource Graph must list the configured
    subscription first. Returns Reached and Error.
    https://learn.microsoft.com/azure/governance/resource-graph/reference/supported-tables-resources
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    try {
        $read = Invoke-DemoHubResourceGraph -SubscriptionId $SubscriptionId -Query "resourcecontainers | where type =~ 'microsoft.resources/subscriptions' | project subscriptionId"
    }
    catch {
        return [pscustomobject]@{ Reached = $false; Error = (Protect-DemoText -Text $_.Exception.Message).Trim() }
    }
    if (-not $read.Succeeded) {
        return [pscustomobject]@{ Reached = $false; Error = [string]$read.Error }
    }
    $listed = @(foreach ($row in @($read.Rows)) { [string](Get-DemoMemberValue -InputObject $row -Name 'subscriptionId') })
    if ($listed -contains $SubscriptionId) {
        return [pscustomobject]@{ Reached = $true; Error = '' }
    }
    return [pscustomobject]@{ Reached = $false; Error = 'Azure Resource Graph doesn''t list the configured subscription for this sign-in, so an empty answer would prove nothing: the signed-in identity can''t read the subscription, or its token isn''t for the configured tenant.' }
}

function Get-DemoResidueSnapshot {
    <#
    .SYNOPSIS
    One read of everything Test-DemoTeardownResidue checks (Azure Resource Graph, the resource group, the
    subscription's deployments, the budget, and Microsoft Entra). Read-only. Internal.

    .DESCRIPTION
    Returns GroupExists, BudgetExists, and lists of what's left: Tagged, GroupResources, Arc,
    RoleAssignments, OrphanedAssignments, Principals, Members, Deployments, and with -Extended also References and
    Records. Errors maps each check that couldn't be read to its redacted error, so the caller never reports it as
    clean. Everything is scoped to the configured subscription: Resource Graph through its request body, the
    budget through a URL that names the subscription, and every other command through Invoke-DemoAz. It
    never passes --ids or a {subscriptionId} placeholder.

    Only this environment is matched (Phase 28 follow-up, live 2026-11-02): its resource group by its exact name
    rg-<prefix>-<environment>, and its resources by the manifest's deploymentId tag, which the template derives from
    the subscription, the prefix, and the environment. Never the solution and environment tags alone, which another
    prefix's environment of the same name carries too, and never a resource's name alone (arcsql01 and sqlvm01 are the
    same in every environment).

    Role assignments: one at or under the group is residue (RoleAssignments), and so is one for a manifest identity
    in another of the demo's resource groups (rg-<prefix>-control, rg-<prefix>-golden). One for a manifest identity
    anywhere else is OrphanedAssignments: the demo gives its managed identities role assignments only at or under its
    group (with assignRoles: the Arc onboarding identity's Azure Connected Machine Onboarding on the group), so
    something else made it, such as a tenant policy with a DeployIfNotExists effect.

    Resource Graph and Microsoft Graph go through Invoke-DemoRestRequest with tokens that Get-DemoAccessToken
    verified for the configured tenant and caller, never 'az rest' or 'az ad', which would use the Azure CLI's
    default account (ADR 0011, guard update). Each is still read only after a canary: Resource Graph must list
    the configured subscription (Get-DemoResourceGraphReach), and Microsoft Graph must answer for the
    configured tenant (GET /v1.0/organization). Otherwise their checks are errors, never clean. The
    identities are looked up in one request (POST /v1.0/directoryObjects/getByIds), and the P6 membership of
    any that still exist with POST /v1.0/directoryObjects/{id}/checkMemberGroups.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Setting,

        [switch] $Extended
    )

    $subscriptionId = [string]$Setting.SubscriptionId
    $group = [string]$Setting.ResourceGroupName
    $control = [string]$Setting.ControlGroupName
    $golden = [string](Get-DemoMemberValue -InputObject $Setting -Name 'GoldenGroupName')
    # Only names the configuration schema allows go into query text.
    foreach ($name in @($group, $control)) {
        if ($name -notmatch '^[A-Za-z0-9._()-]{1,90}$') {
            throw ('The resource group name ''{0}'' can''t be used in a Resource Graph query.' -f $name)
        }
    }
    $groupId = ([string]$Setting.ResourceGroupId).ToLowerInvariant()
    $groupPath = '/resourcegroups/{0}' -f $group.ToLowerInvariant()
    # The demo's other resource groups, which outlive the environment (ADR 0002, ADR 0018).
    $demoGroupIds = @(foreach ($name in @($control, $golden)) {
            if ($name -match '^[A-Za-z0-9._()-]{1,90}$') {
                ('/subscriptions/{0}/resourcegroups/{1}' -f $subscriptionId, $name).ToLowerInvariant()
            }
        })
    $errors = [ordered]@{}
    # Checks that a canary showed can't be verified with this sign-in: waiting won't change them.
    $unverifiable = [System.Collections.Generic.List[string]]::new()
    $snapshot = [ordered]@{
        GroupExists         = $false
        BudgetExists        = $false
        Tagged              = @()
        GroupResources      = @()
        Arc                 = @()
        RoleAssignments     = @()
        OrphanedAssignments = @()
        Principals          = @()
        Members             = @()
        Deployments         = @()
        References          = @()
        Records             = @()
        Errors              = $errors
        Unverifiable        = @()
    }
    $reach = Get-DemoResourceGraphReach -SubscriptionId $subscriptionId
    $readGraph = {
        param([string] $Key, [string] $Query)
        if (-not $reach.Reached) {
            $errors[$Key] = $reach.Error
            if (-not $unverifiable.Contains($Key)) {
                $unverifiable.Add($Key)
            }
            return $null
        }
        try {
            $read = Invoke-DemoHubResourceGraph -SubscriptionId $subscriptionId -Query $Query
        }
        catch {
            $errors[$Key] = (Protect-DemoText -Text $_.Exception.Message).Trim()
            return $null
        }
        if (-not $read.Succeeded) {
            $errors[$Key] = $read.Error
            return $null
        }
        return $read
    }
    $graph = {
        param([string] $Key, [string] $Query, [string] $Column = 'id')
        $read = & $readGraph $Key $Query
        if ($null -eq $read) {
            return @()
        }
        return @(@($read.Rows) | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name $Column) } | Where-Object { $_ })
    }
    $errorText = { param([object] $Run) (Protect-DemoText -Text ([string]$Run.StdErr)).Trim() }

    $exists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'exists', '--name', $group) -AllowFailure
    if ($exists.ExitCode -ne 0) {
        $errors['Group'] = & $errorText $exists
    }
    else {
        $snapshot.GroupExists = ([string]$exists.StdOut).Trim() -eq 'true'
    }

    # The environment's tags: every template resource and the Arc machine (onboarding copies the group's tags) carry
    # its deploymentId, which is unique to the subscription, the prefix, and the environment. The solution and
    # environment tags aren't: another prefix's environment of the same name has them too (live, 2026-11-02). Without
    # the deploymentId, only the resource group itself, by its exact name, is looked for. The GitHub identity's group
    # is kept by design (ADR 0002).
    $deploymentId = [string]$Setting.DeploymentId
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        $deploymentId = ''
    }
    $tagMatch = if ($deploymentId) { "tostring(tags.deploymentId) == '{0}'" -f $deploymentId } else { '' }
    $containers = "resourcecontainers | where type =~ 'microsoft.resources/subscriptions/resourcegroups' | where name =~ '{0}'{1} | where name !~ '{2}' | project id" -f $group, $(if ($tagMatch) { ' or ' + $tagMatch } else { '' }), $control
    $taggedQuery = if ($tagMatch) { "resources | where {0} | where resourceGroup !~ '{1}' | project id | union ({2})" -f $tagMatch, $control, $containers } else { $containers }
    $snapshot.Tagged = & $graph 'Tagged' $taggedQuery
    $snapshot.GroupResources = & $graph 'GroupResources' ("resources | where resourceGroup =~ '{0}' | project id" -f $group)

    # Arc resources of this environment wherever they are: in the group, carrying its deploymentId, or hosted by one of
    # its machines or VMs (unified inventory lists T1's instances under the Compute VM).
    $arcTypes = "'microsoft.hybridcompute/machines', 'microsoft.hybridcompute/machines/extensions', 'microsoft.hybridcompute/machines/licenseprofiles', 'microsoft.hybridcompute/machines/runcommands', 'microsoft.azurearcdata/sqlserverinstances', 'microsoft.azurearcdata/sqlserverinstances/databases', 'microsoft.azurearcdata/sqlserverinstances/availabilitygroups'"
    $arcScope = "resourceGroup =~ '{0}' or tolower(tostring(properties.containerResourceId)) contains '{1}/'{2}" -f $group, $groupPath, $(if ($tagMatch) { ' or ' + $tagMatch } else { '' })
    $snapshot.Arc = & $graph 'Arc' ("resources | where type in~ ({0}) | where {1} | project id" -f $arcTypes, $arcScope)

    $principalIds = @($Setting.PrincipalIds | Where-Object { $_ -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' })
    $principalClause = if ($principalIds.Count) { " or principalId in ({0})" -f (($principalIds | ForEach-Object { "'{0}'" -f $_ }) -join ', ') } else { '' }
    $assignmentQuery = "authorizationresources | where type =~ 'microsoft.authorization/roleassignments' | extend assignmentScope = tolower(tostring(properties.scope)), principalId = tolower(tostring(properties.principalId)), roleDefinitionId = tolower(tostring(properties.roleDefinitionId)) | where assignmentScope startswith '{0}'{1} | project id, assignmentScope, principalId, roleDefinitionId" -f $groupId, $principalClause
    $read = & $readGraph 'RoleAssignments' $assignmentQuery
    if ($null -ne $read) {
        $under = { param([string] $Scope, [string] $Parent) $Scope -eq $Parent -or $Scope.StartsWith($Parent + '/', [System.StringComparison]::Ordinal) }
        $left = [System.Collections.Generic.List[string]]::new()
        $orphaned = [System.Collections.Generic.List[object]]::new()
        foreach ($row in @($read.Rows)) {
            $scope = [string](Get-DemoMemberValue -InputObject $row -Name 'assignmentScope')
            $principal = [string](Get-DemoMemberValue -InputObject $row -Name 'principalId')
            $id = [string](Get-DemoMemberValue -InputObject $row -Name 'id')
            if (& $under $scope $groupId) {
                $left.Add($id)
            }
            elseif ($principal -in $principalIds) {
                if (@($demoGroupIds | Where-Object { & $under $scope $_ }).Count -gt 0) {
                    $left.Add($id)
                }
                else {
                    $orphaned.Add([pscustomobject]@{ Id = $id; Scope = $scope; PrincipalId = $principal; RoleDefinitionId = [string](Get-DemoMemberValue -InputObject $row -Name 'roleDefinitionId') })
                }
            }
        }
        $snapshot.RoleAssignments = $left.ToArray()
        $snapshot.OrphanedAssignments = $orphaned.ToArray()
    }

    $list = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('deployment', 'sub', 'list', '--query', '[].name', '--output', 'json') -AllowFailure
    if ($list.ExitCode -ne 0) {
        $errors['Deployments'] = & $errorText $list
    }
    else {
        $names = if ([string]::IsNullOrWhiteSpace([string]$list.StdOut)) { @() } else { @([string]$list.StdOut | ConvertFrom-Json) }
        $snapshot.Deployments = @($names | Where-Object { ([string]$_).StartsWith([string]$Setting.DeploymentPrefix, [System.StringComparison]::OrdinalIgnoreCase) })
    }

    $budget = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', [string]$Setting.BudgetUrl) -AllowFailure
    if ($budget.ExitCode -eq 0) {
        $snapshot.BudgetExists = $true
    }
    elseif (-not (Test-DemoAzNotFound -Text ([string]$budget.StdErr))) {
        $errors['Budget'] = & $errorText $budget
    }

    $members = [System.Collections.Generic.List[string]]::new()
    $present = [System.Collections.Generic.List[string]]::new()
    if ($principalIds.Count) {
        try {
            # Microsoft Graph only through Invoke-DemoRestRequest, whose token Get-DemoAccessToken verified for
            # the configured tenant and caller ('az ad' and 'az rest' would use the CLI's default account). The
            # canary still has to answer for the configured tenant before a "not found" counts as gone.
            $graphRoot = 'https://graph.microsoft.com/v1.0'
            $organization = Invoke-DemoRestRequest -SubscriptionId $subscriptionId -Method 'GET' -Uri ($graphRoot + '/organization?$select=id')
            $graphTenant = ''
            if ($organization.ExitCode -eq 0) {
                # Assigned first: Get-DemoMemberValue returns an array as one object, which @() wouldn't unroll.
                $organizations = Get-DemoMemberValue -InputObject ([string]$organization.StdOut | ConvertFrom-Json -Depth 8) -Name 'value'
                $graphTenant = [string](Get-DemoMemberValue -InputObject (@($organizations) | Select-Object -First 1) -Name 'id')
            }
            if ($organization.ExitCode -ne 0) {
                $errors['Principals'] = 'Microsoft Graph couldn''t be read: {0}' -f ([string]$organization.StdErr).Trim()
                $unverifiable.Add('Principals')
            }
            elseif ($graphTenant -ne [string]$Setting.TenantId) {
                $errors['Principals'] = 'Microsoft Graph answers for another tenant than the configured one, so the identities weren''t looked up.'
                $unverifiable.Add('Principals')
            }
            else {
                # One request for every identity: Graph returns the ones that still exist and leaves out the rest.
                $byIds = Invoke-DemoRestRequest -SubscriptionId $subscriptionId -Method 'POST' -Uri ($graphRoot + '/directoryObjects/getByIds') -Body (@{ ids = @($principalIds); types = @('servicePrincipal') } | ConvertTo-Json -Compress)
                if ($byIds.ExitCode -ne 0) {
                    $errors['Principals'] = ([string]$byIds.StdErr).Trim()
                }
                else {
                    $found = Get-DemoMemberValue -InputObject ([string]$byIds.StdOut | ConvertFrom-Json -Depth 8) -Name 'value'
                    foreach ($object in @($found)) {
                        $id = ([string](Get-DemoMemberValue -InputObject $object -Name 'id')).ToLowerInvariant()
                        if ($id -in $principalIds) {
                            $present.Add($id)
                        }
                    }
                }
                if ($Setting.GroupObjectId) {
                    $groupBody = @{ groupIds = @([string]$Setting.GroupObjectId) } | ConvertTo-Json -Compress
                    foreach ($principalId in $present) {
                        $check = Invoke-DemoRestRequest -SubscriptionId $subscriptionId -Method 'POST' -Uri ('{0}/directoryObjects/{1}/checkMemberGroups' -f $graphRoot, $principalId) -Body $groupBody
                        if ($check.ExitCode -eq 0) {
                            $groups = Get-DemoMemberValue -InputObject ([string]$check.StdOut | ConvertFrom-Json -Depth 8) -Name 'value'
                            if (([string]$Setting.GroupObjectId).ToLowerInvariant() -in @(@($groups) | ForEach-Object { ([string]$_).ToLowerInvariant() })) {
                                $members.Add($principalId)
                            }
                        }
                        elseif (-not (Test-DemoAzNotFound -Text ([string]$check.StdErr))) {
                            $errors['Principals'] = ([string]$check.StdErr).Trim()
                        }
                    }
                }
            }
        }
        catch {
            $errors['Principals'] = (Protect-DemoText -Text $_.Exception.Message).Trim()
            if (-not $unverifiable.Contains('Principals')) {
                $unverifiable.Add('Principals')
            }
        }
    }
    $snapshot.Principals = $present.ToArray()
    $snapshot.Members = $members.ToArray()

    if ($Extended) {
        # A resource elsewhere that names the group: a resource ID under it, or the group's own ID (a JSON
        # string ends with a quote). The golden group's snapshots name their source group by design (ADR 0018).
        $goldenFilter = if ($golden) { " | where resourceGroup !~ '{0}'" -f $golden } else { '' }
        $snapshot.References = & $graph 'References' ("resources | where resourceGroup !~ '{0}'{2} | extend propertiesText = tostring(properties) | where propertiesText contains '{1}/' or propertiesText contains '{1}""' | project id" -f $group, $groupPath, $goldenFilter)
        # Records the platform keeps about the deleted resources: Defender for Cloud assessments, Azure Policy
        # compliance states, and guest configuration assignments. They aren't resources and don't bill.
        $security = & $graph 'Records' ("securityresources | where tolower(id) contains '{0}/' | summarize n = count() by type | project item = strcat(type, ': ', tostring(n))" -f $groupPath) 'item'
        $policy = & $graph 'Records' ("policyresources | where type =~ 'microsoft.policyinsights/policystates' | where tolower(tostring(properties.resourceId)) contains '{0}/' | summarize n = count() | where n > 0 | project item = strcat('microsoft.policyinsights/policystates: ', tostring(n))" -f $groupPath) 'item'
        $guest = & $graph 'Records' ("guestconfigurationresources | where tolower(id) contains '{0}/' | summarize n = count() by type | project item = strcat(type, ': ', tostring(n))" -f $groupPath) 'item'
        $snapshot.Records = @($security) + @($policy) + @($guest)
    }
    $snapshot.Unverifiable = $unverifiable.ToArray()
    return [pscustomobject]$snapshot
}

function New-DemoResidueConfirmation {
    <#
    .SYNOPSIS
    The state of one residual check's Azure Resource Manager reads (Confirm-DemoResidueResource): how many are left, each
    resource ID's outcome, and the API versions found. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [ValidateRange(0, 100)]
        [int] $MaxReads = 25
    )

    $comparer = [System.StringComparer]::OrdinalIgnoreCase
    return @{
        MaxReads    = $MaxReads
        Reads       = 0
        Outcome     = [System.Collections.Generic.Dictionary[string, string]]::new($comparer)
        Detail      = [System.Collections.Generic.Dictionary[string, string]]::new($comparer)
        ApiVersions = [System.Collections.Generic.Dictionary[string, string]]::new($comparer)
        Namespaces  = [System.Collections.Generic.HashSet[string]]::new($comparer)
        Pinned      = $null
    }
}

function ConvertFrom-DemoArmResourceId {
    <#
    .SYNOPSIS
    The provider namespace and resource type of an Azure Resource Manager ID, from its last /providers/ segment (for
    example Microsoft.AzureArcData and sqlServerInstances/databases); Microsoft.Resources and resourceGroups for a
    resource group's ID. $null for anything else. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $Id
    )

    if ($Id -match '^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+$') {
        return [pscustomobject]@{ Namespace = 'Microsoft.Resources'; Type = 'resourceGroups' }
    }
    $index = $Id.LastIndexOf('/providers/', [System.StringComparison]::OrdinalIgnoreCase)
    if ($Id -notmatch '^/subscriptions/[0-9a-fA-F-]{36}/' -or $index -lt 0) {
        return $null
    }
    # The namespace, then type and name pairs.
    $parts = $Id.Substring($index + '/providers/'.Length).Split('/')
    if ($parts.Count -lt 3 -or ($parts.Count - 1) % 2 -ne 0 -or @($parts | Where-Object { -not $_ }).Count -gt 0) {
        return $null
    }
    $types = for ($i = 1; $i -lt $parts.Count; $i += 2) { $parts[$i] }
    return [pscustomobject]@{ Namespace = $parts[0]; Type = (@($types) -join '/') }
}

function Get-DemoResidueApiVersion {
    <#
    .SYNOPSIS
    An API version for a resource type: the one config/versions.json pins, or else the newest stable one its resource
    provider lists (Providers - Get, one read per namespace, counted against the check's reads); '' when none is known.
    Internal.
    https://learn.microsoft.com/rest/api/resources/providers/get
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Namespace,

        [Parameter(Mandatory)]
        [string] $Type,

        [Parameter(Mandatory)]
        [hashtable] $State
    )

    if ($null -eq $State.Pinned) {
        $State.Pinned = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($key in @($versions['apiVersions'].Keys)) {
            if ($key -ne 'note') {
                $State.Pinned[[string]$key] = [string]$versions['apiVersions'][$key]
            }
        }
    }
    $key = '{0}/{1}' -f $Namespace, $Type
    if ($State.Pinned.ContainsKey($key)) {
        return $State.Pinned[$key]
    }
    if ($State.ApiVersions.ContainsKey($key)) {
        return $State.ApiVersions[$key]
    }
    if ($Namespace -notmatch '^[A-Za-z0-9.]{1,100}$' -or $State.Namespaces.Contains($Namespace) -or $State.Reads -ge $State.MaxReads) {
        return ''
    }
    $null = $State.Namespaces.Add($Namespace)
    $State.Reads++
    try {
        $read = Invoke-DemoRestRequest -SubscriptionId $SubscriptionId -Method 'GET' -Uri ('https://management.azure.com/subscriptions/{0}/providers/{1}?api-version={2}' -f $SubscriptionId, $Namespace, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Resources/providers'))
    }
    catch {
        return ''
    }
    if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
        return ''
    }
    $provider = [string]$read.StdOut | ConvertFrom-Json -Depth 16
    # Assigned first: Get-DemoMemberValue returns an array as one object, which @() wouldn't unroll.
    $resourceTypes = Get-DemoMemberValue -InputObject $provider -Name 'resourceTypes'
    foreach ($entry in @($resourceTypes)) {
        $name = [string](Get-DemoMemberValue -InputObject $entry -Name 'resourceType')
        $listed = Get-DemoMemberValue -InputObject $entry -Name 'apiVersions'
        $all = @(@($listed) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\d{4}-\d{2}-\d{2}(-preview)?$' } | Sort-Object -Descending)
        $stable = @($all | Where-Object { $_ -notlike '*-preview' })
        $chosen = if ($stable.Count) { $stable[0] } elseif ($all.Count) { $all[0] } else { '' }
        if ($name -and $chosen) {
            $State.ApiVersions[('{0}/{1}' -f $Namespace, $name)] = $chosen
        }
    }
    if ($State.ApiVersions.ContainsKey($key)) {
        return $State.ApiVersions[$key]
    }
    return ''
}

function Confirm-DemoResidueResource {
    <#
    .SYNOPSIS
    Asks Azure Resource Manager whether resources that Azure Resource Graph still lists exist, with a bounded number of
    reads for the whole check. Read-only. Internal.

    .DESCRIPTION
    Resource Graph's index lags behind deletes: on 2026-11-02 it listed ten databases of a deleted Arc SQL Server
    instance in their deleted resource group for more than 30 minutes, and in Phase 20 for about 16. So a row counts
    as residue only when Resource Manager returns the resource (Resources - Get By Id, through Invoke-DemoRestRequest).
    HTTP 404 with ResourceNotFound, ResourceGroupNotFound, or ParentResourceNotFound means it's gone, and the row is a
    stale index record. Anything else (another error, an unknown API version, or no reads left) leaves it
    Unconfirmed. Each outcome goes into -State (New-DemoResidueConfirmation): an ID found gone is never read again,
    and with -NewOnly an ID read before isn't read again either. With -AssumePresent (the group still exists, so the
    destroy isn't done), the IDs are Present without a read. Never writes anything.
    - https://learn.microsoft.com/rest/api/resources/resources/get-by-id
    - https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-not-found
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Id = @(),

        [Parameter(Mandatory)]
        [hashtable] $State,

        [switch] $AssumePresent,

        [switch] $NewOnly
    )

    $goneCodes = @('ResourceNotFound', 'ResourceGroupNotFound', 'ParentResourceNotFound')
    $limit = 'not read: the check reads at most {0} resources from Azure Resource Manager' -f $State.MaxReads
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $set = { param([string] $Key, [string] $Outcome, [string] $Detail) $State.Outcome[$Key] = $Outcome; $State.Detail[$Key] = $Detail }
    foreach ($item in @($Id | Where-Object { $_ })) {
        $resourceId = [string]$item
        if (-not $seen.Add($resourceId)) {
            continue
        }
        $previous = if ($State.Outcome.ContainsKey($resourceId)) { $State.Outcome[$resourceId] } else { '' }
        if ($previous -eq 'Gone' -or ($NewOnly -and $previous)) {
            continue
        }
        if ($AssumePresent) {
            & $set $resourceId 'Present' 'its resource group still exists'
            continue
        }
        if ($State.Reads -ge $State.MaxReads) {
            if (-not $previous) {
                & $set $resourceId 'Unconfirmed' $limit
            }
            continue
        }
        $type = ConvertFrom-DemoArmResourceId -Id $resourceId
        if ($null -eq $type) {
            & $set $resourceId 'Unconfirmed' 'not an Azure Resource Manager ID'
            continue
        }
        $version = Get-DemoResidueApiVersion -SubscriptionId $SubscriptionId -Namespace $type.Namespace -Type $type.Type -State $State
        if (-not $version) {
            & $set $resourceId 'Unconfirmed' $(if ($State.Reads -ge $State.MaxReads) { $limit } else { 'no API version is known for {0}/{1}' -f $type.Namespace, $type.Type })
            continue
        }
        if ($State.Reads -ge $State.MaxReads) {
            & $set $resourceId 'Unconfirmed' $limit
            continue
        }
        $State.Reads++
        $path = ($resourceId.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        try {
            $read = Invoke-DemoRestRequest -SubscriptionId $SubscriptionId -Method 'GET' -Uri ('https://management.azure.com{0}?api-version={1}' -f $path, $version)
        }
        catch {
            & $set $resourceId 'Unconfirmed' ('the read failed: {0}' -f (Protect-DemoText -Text $_.Exception.Message).Trim())
            continue
        }
        if ($read.ExitCode -eq 0) {
            & $set $resourceId 'Present' 'Azure Resource Manager returned it'
            continue
        }
        $code = [regex]::Match([string]$read.StdErr, '"code"\s*:\s*"([A-Za-z]+)"').Groups[1].Value
        if ([int](Get-DemoMemberValue -InputObject $read -Name 'StatusCode') -eq 404 -and $code -in $goneCodes) {
            & $set $resourceId 'Gone' $code
            continue
        }
        $text = (Protect-DemoText -Text ([string]$read.StdErr)).Trim()
        if ($text.Length -gt 200) {
            $text = $text.Substring(0, 200) + '...'
        }
        & $set $resourceId 'Unconfirmed' ('Azure Resource Manager answered {0}' -f $(if ($text) { $text } else { 'with an error' }))
    }
}

function Split-DemoResidueResource {
    <#
    .SYNOPSIS
    Sorts resource IDs by what Confirm-DemoResidueResource found: Present (Resource Manager returned it), Gone (a stale
    Resource Graph record), and Unconfirmed (not read, or not answered), with Reasons for the unconfirmed ones. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Id = @(),

        [Parameter(Mandatory)]
        [hashtable] $State
    )

    $present = [System.Collections.Generic.List[string]]::new()
    $gone = [System.Collections.Generic.List[string]]::new()
    $unconfirmed = [System.Collections.Generic.List[string]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @($Id | Where-Object { $_ })) {
        $resourceId = [string]$item
        if (-not $seen.Add($resourceId)) {
            continue
        }
        $outcome = if ($State.Outcome.ContainsKey($resourceId)) { $State.Outcome[$resourceId] } else { '' }
        if ($outcome -eq 'Present') {
            $present.Add($resourceId)
        }
        elseif ($outcome -eq 'Gone') {
            $gone.Add($resourceId)
        }
        else {
            $unconfirmed.Add($resourceId)
            $reason = if ($outcome -and $State.Detail.ContainsKey($resourceId)) { $State.Detail[$resourceId] } else { 'not read' }
            if (-not $reasons.Contains($reason)) {
                $reasons.Add($reason)
            }
        }
    }
    return [pscustomobject]@{ Present = $present.ToArray(); Gone = $gone.ToArray(); Unconfirmed = $unconfirmed.ToArray(); Reasons = $reasons.ToArray() }
}

function Get-DemoResidueTypeCount {
    # 'type: count' for each resource type among resource IDs, for the records evidence. Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Id = @()
    )

    $counts = [ordered]@{}
    foreach ($item in @($Id | Where-Object { $_ })) {
        $type = ConvertFrom-DemoArmResourceId -Id ([string]$item)
        $name = if ($null -eq $type) { 'unknown' } else { ('{0}/{1}' -f $type.Namespace, $type.Type).ToLowerInvariant() }
        $counts[$name] = 1 + [int]$counts[$name]
    }
    return @($counts.Keys | ForEach-Object { '{0}: {1}' -f $_, $counts[$_] })
}

function Read-DemoTeardownManifest {
    <#
    .SYNOPSIS
    Reads the manifest destroy.ps1 wrote (names and IDs only) for a read-only rerun of the residual check, and checks
    that it belongs to this configuration's resource group. Returns Found, Manifest, and Error. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Found = $false; Manifest = $null; Error = '' }
    }
    try {
        $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -Depth 10
    }
    catch {
        return [pscustomobject]@{ Found = $true; Manifest = $null; Error = ('{0} isn''t a readable manifest: {1}' -f $Path, (Protect-DemoText -Text $_.Exception.Message).Trim()) }
    }
    $recordedGroup = [string](Get-DemoMemberValue -InputObject $manifest -Name 'ResourceGroupName')
    if ($recordedGroup -ne $ResourceGroupName) {
        return [pscustomobject]@{ Found = $true; Manifest = $null; Error = ('{0} is the manifest of {1}, not of {2}, this configuration''s resource group.' -f $Path, $(if ($recordedGroup) { $recordedGroup } else { 'no resource group' }), $ResourceGroupName) }
    }
    return [pscustomobject]@{ Found = $true; Manifest = $manifest; Error = '' }
}

function New-DemoResidueSummary {
    <#
    .SYNOPSIS
    DESTROY.RESIDUAL: the TEARDOWN.RESIDUAL.* results in one line. Pass only when every check is clean, Fail when one
    found something left, Warning when nothing was found but something couldn't be verified. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Residue = @(),

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [AllowNull()]
        [object] $Manifest
    )

    $failed = @($Residue | Where-Object { $_.status -eq 'Fail' } | ForEach-Object { $_.checkId })
    $warned = @($Residue | Where-Object { $_.status -eq 'Warning' } | ForEach-Object { $_.checkId })
    $summary = if ($failed.Count) { 'Fail' } elseif ($warned.Count) { 'Warning' } else { 'Pass' }
    $message = switch ($summary) {
        'Pass' { 'Nothing of {0} is left: no resource, Arc resource, role assignment, identity, deployment record, or budget.' -f $ResourceGroupName }
        'Warning' { 'No check found anything of {0} left, but read the warnings: {1}.' -f $ResourceGroupName, ($warned -join ', ') }
        default { 'Something of {0} is left: {1}.' -f $ResourceGroupName, ($failed -join ', ') }
    }
    return (New-DemoResult -CheckId 'DESTROY.RESIDUAL' -Area 'teardown' -Target 'subscription' -Status $summary -Message $message -Evidence ([ordered]@{ failed = $failed; warnings = $warned; deploymentId = [string](Get-DemoMemberValue -InputObject $Manifest -Name 'DeploymentId') }) -Remediation $(if ($summary -eq 'Fail') { 'Read the TEARDOWN.RESIDUAL results above; run destroy.ps1 again, or delete what''s named there.' } else { '' }) -DocUrl 'https://learn.microsoft.com/azure/governance/resource-graph/overview')
}
