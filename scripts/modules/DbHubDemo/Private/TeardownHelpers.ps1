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
    RoleAssignments, Principals, Members, Deployments, and with -Extended also References and Records.
    Errors maps each check that couldn't be read to its redacted error, so the caller never reports it as
    clean. Everything is scoped to the configured subscription: Resource Graph through its request body, the
    budget through a URL that names the subscription, and every other command through Invoke-DemoAz. It
    never passes --ids or a {subscriptionId} placeholder.

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
    $environment = [string]$Setting.Environment
    # Only names the configuration schema allows go into query text.
    foreach ($name in @($group, $control)) {
        if ($name -notmatch '^[A-Za-z0-9._()-]{1,90}$') {
            throw ('The resource group name ''{0}'' can''t be used in a Resource Graph query.' -f $name)
        }
    }
    if ($environment -notmatch '^[a-z][a-z0-9]{1,7}$') {
        throw ('The environment name ''{0}'' can''t be used in a Resource Graph query.' -f $environment)
    }
    $groupId = ([string]$Setting.ResourceGroupId).ToLowerInvariant()
    $groupPath = '/resourcegroups/{0}' -f $group.ToLowerInvariant()
    $errors = [ordered]@{}
    # Checks that a canary showed can't be verified with this sign-in: waiting won't change them.
    $unverifiable = [System.Collections.Generic.List[string]]::new()
    $snapshot = [ordered]@{
        GroupExists     = $false
        BudgetExists    = $false
        Tagged          = @()
        GroupResources  = @()
        Arc             = @()
        RoleAssignments = @()
        Principals      = @()
        Members         = @()
        Deployments     = @()
        References      = @()
        Records         = @()
        Errors          = $errors
        Unverifiable    = @()
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

    # The environment's tags: every template resource and the Arc machine (onboarding copies the group's tags)
    # carry solution, environment, and deploymentId. The GitHub identity's group is kept by design (ADR 0002).
    $deploymentId = [string]$Setting.DeploymentId
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        $deploymentId = ''
    }
    $tagMatch = "(tostring(tags.solution) =~ 'fabric-database-hub-demo' and tostring(tags.environment) =~ '{0}')" -f $environment
    if ($deploymentId) {
        $tagMatch = "(tostring(tags.deploymentId) == '{0}' or {1})" -f $deploymentId, $tagMatch
    }
    $snapshot.Tagged = & $graph 'Tagged' ("resources | where {0} | where resourceGroup !~ '{1}' | project id | union (resourcecontainers | where {0} | where name !~ '{1}' | project id)" -f $tagMatch, $control)
    $snapshot.GroupResources = & $graph 'GroupResources' ("resources | where resourceGroup =~ '{0}' | project id" -f $group)

    # Arc resources of this environment wherever they are: in the group, carrying its tags, or hosted by one of
    # its machines or VMs (unified inventory lists T1's instances under the Compute VM).
    $arcTypes = "'microsoft.hybridcompute/machines', 'microsoft.hybridcompute/machines/extensions', 'microsoft.hybridcompute/machines/licenseprofiles', 'microsoft.hybridcompute/machines/runcommands', 'microsoft.azurearcdata/sqlserverinstances', 'microsoft.azurearcdata/sqlserverinstances/databases', 'microsoft.azurearcdata/sqlserverinstances/availabilitygroups'"
    $arcScope = "resourceGroup =~ '{0}' or tolower(tostring(properties.containerResourceId)) contains '{1}/' or {2}" -f $group, $groupPath, $tagMatch
    $snapshot.Arc = & $graph 'Arc' ("resources | where type in~ ({0}) | where {1} | project id" -f $arcTypes, $arcScope)

    $principalIds = @($Setting.PrincipalIds | Where-Object { $_ -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' })
    $principalClause = if ($principalIds.Count) { " or principalId in ({0})" -f (($principalIds | ForEach-Object { "'{0}'" -f $_ }) -join ', ') } else { '' }
    $assignmentQuery = "authorizationresources | where type =~ 'microsoft.authorization/roleassignments' | extend assignmentScope = tolower(tostring(properties.scope)), principalId = tolower(tostring(properties.principalId)) | where assignmentScope startswith '{0}'{1} | project id, assignmentScope, principalId" -f $groupId, $principalClause
    $read = & $readGraph 'RoleAssignments' $assignmentQuery
    if ($null -ne $read) {
        $snapshot.RoleAssignments = @(foreach ($row in @($read.Rows)) {
                $scope = [string](Get-DemoMemberValue -InputObject $row -Name 'assignmentScope')
                $principal = [string](Get-DemoMemberValue -InputObject $row -Name 'principalId')
                if ($scope -eq $groupId -or $scope.StartsWith($groupId + '/', [System.StringComparison]::Ordinal) -or $principal -in $principalIds) {
                    [string](Get-DemoMemberValue -InputObject $row -Name 'id')
                }
            })
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
        $golden = [string](Get-DemoMemberValue -InputObject $Setting -Name 'GoldenGroupName')
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
