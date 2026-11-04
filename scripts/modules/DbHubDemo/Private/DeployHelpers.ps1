function Get-DemoResourceGroupName {
    # rg-<prefix>-<environment>, the demo resource group (ADR 0002). Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    return ('rg-{0}-{1}' -f $Config['prefix'], $Config['environment'])
}

function Get-DemoMainDeploymentName {
    # The template's subscription-scope deployment record: <prefix>-<environment>-main, which is dbhub-demo-main with the
    # defaults, as before. With the prefix in it (Phase 28), an environment with its own prefix, such as a throwaway proof,
    # never replaces, reads, or deletes another environment's record. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $prefix = if ([string]$Config['prefix']) { [string]$Config['prefix'] } else { 'dbhub' }
    return ('{0}-{1}-main' -f $prefix, $Config['environment'])
}

function Get-DemoHostVmName {
    # The T2 VM: archost01 (nested, the default) or arcsql01 (evaluation-only mode, ADR 0006). Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    if ([string]$Config['t2Mode'] -eq 'EvaluationOnlyAzureVm') {
        return 'arcsql01'
    }
    return 'archost01'
}

function Get-DemoVmTarget {
    # The result target for a demo VM (ADR 0012): T1 for sqlvm01, T2 for the T2 VM. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $VmName
    )

    if ($VmName -eq 'sqlvm01') {
        return 'T1'
    }
    return 'T2'
}

function Get-DemoDeploymentStateTagName {
    # The resource group tags that hold deploy.ps1's state, so -Resume works from any machine and from
    # GitHub Actions (plan section 9.2). Internal.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return [ordered]@{
        Stage             = 'DbHubDeployStage'
        StageUtc          = 'DbHubDeployStageUtc'
        BundleSha256      = 'DbHubBundleSha256'
        BundleChunkCount  = 'DbHubBundleChunks'
        RunnerSha256      = 'DbHubRunnerSha256'
        RunnerChunkCount  = 'DbHubRunnerChunks'
        BundleSentTo      = 'DbHubBundleSentTo'
        RunnerSentTo      = 'DbHubRunnerSentTo'
        NetworkMode       = 'DbHubNetworkMode'
        T3UseFreeLimit    = 'DbHubT3FreeOffer'
        T3AdminGroupName  = 'DbHubT3AdminGroup'
        BastionExpiresUtc = 'DbHubBastionExpiresUtc'
        HostPasswordSet   = 'DbHubHostPasswordUtc'
        TrackT1           = 'DbHubTrackT1'
        TrackT2           = 'DbHubTrackT2'
        TrackT4           = 'DbHubTrackT4'
        TrackFabric       = 'DbHubTrackFabric'
        T2Source          = 'DbHubT2Source'
        # fabric.manageCapacity (Phase 26b): the capacity start-demo.ps1 resumed, "<resource group>/<name>", and when.
        FabricCapacityResumed    = 'DbHubFabricCapacityResumed'
        FabricCapacityResumedUtc = 'DbHubFabricCapacityResumedUtc'
        # Phase 28: until when the PaygWizard guided stop's request on the T2 host is valid (empty when there's none), and the
        # size T4's fallback settled on for later runs (since T4's 4-vCore default, 2026-11-04, under a new name, so Phase 28's
        # DbHubT4Sku isn't read): Standard_D4ads_v5, Standard_D2ds_v5 (after its cost check), the size an existing server kept
        # when Azure refused to scale it to the default, None (left out; the 2-vCore step is checked again), or Refused.
        GuidedStopUtc            = 'DbHubGuidedStopUtc'
        T4Sku                    = 'DbHubT4Size'
        # Phase 28 review follow-up: when the T2 host's loader started a bootstrap generation that nobody has seen finish (empty
        # when none runs), so deploy.ps1's watchdog never restarts the host during its guest build (Get-DemoHostRestartBlocker).
        T2BuildUtc               = 'DbHubT2BuildUtc'
    }
}

function Get-DemoDeploymentStageName {
    # deploy.ps1's stages, in order (plan section 9.2). Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    return @('Preflight', 'Infrastructure', 'Artifacts', 'Bootstraps', 'T3', 'T4', 'Activity', 'Monitoring', 'T2', 'Fabric', 'Validation')
}

function Test-DemoDeploymentStageReached {
    # True when the recorded stage is this stage or a later one. The recorded stage never moves past an open
    # stage (Manual action required), so a stage that's reached is finished. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowEmptyString()]
        [string] $Recorded,

        [Parameter(Mandatory)]
        [string] $Stage
    )

    $stages = @(Get-DemoDeploymentStageName)
    if ($Recorded -notin $stages -or $Stage -notin $stages) {
        return $false
    }
    return ([array]::IndexOf($stages, $Recorded) -ge [array]::IndexOf($stages, $Stage))
}

function Get-DemoPinnedApiVersion {
    # The API version config/versions.json pins for a resource type that scripts call through az rest. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ResourceType
    )

    $versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    $apiVersion = [string]$versions.apiVersions[$ResourceType]
    if (-not $apiVersion) {
        throw ('config/versions.json has no API version for {0}.' -f $ResourceType)
    }
    return $apiVersion
}

function Get-DemoExistingVmName {
    # Names of the demo VMs that exist in the resource group; empty when the group doesn't exist. Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('vm', 'list', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--query', '[].name', '--output', 'json') -AllowFailure
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$result.StdOut)) {
        return @()
    }
    return @(([string]$result.StdOut | ConvertFrom-Json) | Where-Object { $_ } | ForEach-Object { [string]$_ })
}

function Test-DemoResourceGroupExist {
    # True when the demo resource group exists. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('group', 'exists', '--name', (Get-DemoResourceGroupName -Config $Config)) -AllowFailure
    return ($result.ExitCode -eq 0 -and ([string]$result.StdOut).Trim() -eq 'true')
}

function Get-DemoBudgetStartDate {
    <#
    .SYNOPSIS
    The existing budget's start date (yyyy-MM-dd, UTC), or empty when there's no budget yet. A redeployment must keep
    it: the template's default is the first day of the current month, and Azure refuses to change a budget's start
    date. Internal.

    .DESCRIPTION
    Reads timePeriod.startDate as the text the API returns (az rest with --query and --output tsv) and converts it to
    a UTC date with the invariant culture, whatever the machine's time zone or culture. Phase 28 live finding
    (2026-11-02): the whole budget went through ConvertFrom-Json, which in PowerShell 7 turns an ISO 8601 string into a
    DateTime whose text is "10/01/2026 00:00:00", so the date was never found, the template sent the first day of the
    current month, and every redeploy in a later month than the budget's own failed at the budget ("Start date of
    budgets cannot be updated"). Not found (HTTP 404: no budget yet, or no resource group) returns '' quietly; any
    other failure, or a date that isn't the first of a month, logs one redacted Warning and returns '', as before.
    The budget is read at its resource group's scope even when the group doesn't exist, because a budget there
    outlives the group (live, 2026-10-22).
    Sources: https://learn.microsoft.com/rest/api/consumption/budgets/get,
    https://learn.microsoft.com/rest/api/consumption/budgets/create-or-update (the start date must be the first of a
    month), https://learn.microsoft.com/cli/azure/reference-index#az-rest
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $budgetName = 'budget-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $url = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Consumption/budgets/{2}?api-version={3}' -f $subscriptionId, $resourceGroupName, $budgetName, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Consumption/budgets')
    $read = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $url, '--query', 'properties.timePeriod.startDate', '--output', 'tsv') -AllowFailure
    if ($read.ExitCode -ne 0) {
        if (Test-DemoAzNotFound -Text ([string]$read.StdErr)) {
            return ''
        }
        $why = Get-DemoDeploymentErrorText -Text ([string]$read.StdErr) -MaxLength 400
    }
    else {
        $raw = ([string]$read.StdOut).Trim()
        $start = ConvertTo-DemoUtcDateTime -Value $raw
        if ($null -ne $start -and $start.Day -eq 1) {
            return $start.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $why = if ($raw) { 'Azure returned "{0}", not the first day of a month' -f (Get-DemoDeploymentErrorText -Text $raw -MaxLength 100) } else { 'Azure returned no start date' }
    }
    Write-DemoLog -Level Warning -Message ('The start date of the budget {0} couldn''t be read ({1}), so the template sends the first day of this month. In a later month than the budget''s own, Azure refuses that change and the template fails at the budget; DEPLOY.TEMPLATE then says how to recreate it.' -f $budgetName, ($why -replace '\s+', ' ').Trim())
    return ''
}

function Get-DemoDeploymentErrorText {
    # The error text of a failed 'az deployment' call, redacted and shortened for a result message. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text,

        [ValidateRange(100, 4000)]
        [int] $MaxLength = 1200
    )

    $clean = (Protect-DemoText -Text ([string]$Text)).Trim()
    if ($clean.Length -gt $MaxLength) {
        $clean = $clean.Substring(0, $MaxLength) + '...'
    }
    return $clean
}

function Get-DemoOperationError {
    <#
    .SYNOPSIS
    The innermost error (Code and Message) in a failed deployment operation's statusMessage, or $null. Internal.

    .DESCRIPTION
    A statusMessage holds an error ({ error: { code, message, details } }, with or without status), and a resource
    provider's own error body can arrive as JSON text in a message. Each level's first detail is followed, and a
    message that is a JSON error is read too, at most 8 levels. A level without a code keeps the code above it; with
    no code at all, the operation's statusCode (BadRequest, for example) is used.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $StatusMessage,

        [AllowEmptyString()]
        [string] $StatusCode = ''
    )

    $code = ''
    $message = ''
    $node = $StatusMessage
    for ($level = 0; $level -lt 8 -and $null -ne $node; $level++) {
        if ($node -is [string]) {
            $text = $node.Trim()
            $parsed = $null
            if ($text.StartsWith('{', [System.StringComparison]::Ordinal)) {
                try {
                    $parsed = $text | ConvertFrom-Json -Depth 32 -ErrorAction Stop
                }
                catch {
                    $parsed = $null
                }
            }
            if ($null -eq $parsed) {
                if ($text) {
                    $message = $text
                }
                break
            }
            $node = $parsed
            continue
        }
        $wrapped = Get-DemoMemberValue -InputObject $node -Name 'error'
        if ($null -ne $wrapped) {
            $node = $wrapped
            continue
        }
        $levelCode = [string](Get-DemoMemberValue -InputObject $node -Name 'code')
        if ($levelCode) {
            $code = $levelCode
        }
        $levelMessage = [string](Get-DemoMemberValue -InputObject $node -Name 'message')
        if ($levelMessage) {
            $message = $levelMessage
        }
        # Assigned first: Get-DemoMemberValue returns an array as one object.
        $detailValue = Get-DemoMemberValue -InputObject $node -Name 'details'
        $details = @(@($detailValue) | Where-Object { $null -ne $_ })
        if ($details.Count -gt 0) {
            $node = $details[0]
            continue
        }
        if ($levelMessage.Trim().StartsWith('{', [System.StringComparison]::Ordinal)) {
            $node = $levelMessage
            continue
        }
        break
    }
    if (-not $code) {
        $code = $StatusCode
    }
    if (-not $code -and -not $message) {
        return $null
    }
    return [pscustomobject]@{ Code = $code; Message = $message }
}

function Read-DemoFailedOperation {
    <#
    .SYNOPSIS
    Adds the innermost errors of one deployment's failed operations to -State's Errors, following each failed nested
    deployment. Returns whether the operations could be read. Internal; Get-DemoDeploymentFailure calls it.

    .DESCRIPTION
    'az deployment operation group list' for a deployment in a resource group, 'az deployment operation sub list' for one
    at subscription scope, through Invoke-DemoAz. A failed nested deployment (Microsoft.Resources/deployments) is read
    in turn while -Depth is below the state's MaxDepth; when it names no error of its own, its operation's error is used.
    The state bounds the reads (MaxReads), the errors (MaxErrors), and each message's length (MaxMessage); each code,
    name, and message is redacted (Protect-DemoText) and kept on one line.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [AllowEmptyString()]
        [string] $ResourceGroup = '',

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [int] $Depth,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $State
    )

    if ($State['Reads'] -ge $State['MaxReads']) {
        return $false
    }
    $State['Reads'] = 1 + [int]$State['Reads']
    $arguments = if ($ResourceGroup) { @('deployment', 'operation', 'group', 'list', '--resource-group', $ResourceGroup, '--name', $Name, '--output', 'json') } else { @('deployment', 'operation', 'sub', 'list', '--name', $Name, '--output', 'json') }
    $read = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList $arguments -AllowFailure
    if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
        return $false
    }
    try {
        $operations = @([string]$read.StdOut | ConvertFrom-Json -Depth 64 -ErrorAction Stop)
    }
    catch {
        return $false
    }
    $clean = {
        param([string] $Text, [int] $MaxLength)
        $value = ((Protect-DemoText -Text $Text) -replace '\s+', ' ').Trim()
        if ($value.Length -gt $MaxLength) {
            $value = $value.Substring(0, $MaxLength - 3) + '...'
        }
        $value
    }
    foreach ($operation in $operations) {
        if ($State['Errors'].Count -ge $State['MaxErrors']) {
            break
        }
        $properties = Get-DemoMemberValue -InputObject $operation -Name 'properties'
        if ([string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState') -ne 'Failed') {
            continue
        }
        $target = Get-DemoMemberValue -InputObject $properties -Name 'targetResource'
        $type = [string](Get-DemoMemberValue -InputObject $target -Name 'resourceType')
        $resourceName = [string](Get-DemoMemberValue -InputObject $target -Name 'resourceName')
        $id = [string](Get-DemoMemberValue -InputObject $target -Name 'id')
        if ($type -eq 'Microsoft.Resources/deployments' -and $Depth -lt $State['MaxDepth']) {
            $before = $State['Errors'].Count
            $nestedGroup = $null
            $nestedName = ''
            if ($id -match '(?i)/resourceGroups/([^/]+)/providers/Microsoft\.Resources/deployments/([^/]+)$') {
                $nestedGroup = $Matches[1]
                $nestedName = $Matches[2]
            }
            elseif ($id -match '(?i)^/subscriptions/[^/]+/providers/Microsoft\.Resources/deployments/([^/]+)$') {
                $nestedGroup = ''
                $nestedName = $Matches[1]
            }
            if ($null -ne $nestedGroup) {
                $null = Read-DemoFailedOperation -SubscriptionId $SubscriptionId -ResourceGroup $nestedGroup -Name $nestedName -Depth ($Depth + 1) -State $State
            }
            if ($State['Errors'].Count -gt $before) {
                continue
            }
        }
        $innermost = Get-DemoOperationError -StatusMessage (Get-DemoMemberValue -InputObject $properties -Name 'statusMessage') -StatusCode ([string](Get-DemoMemberValue -InputObject $properties -Name 'statusCode'))
        if ($null -eq $innermost) {
            continue
        }
        $item = [pscustomobject]@{
            ResourceType = & $clean $type 120
            ResourceName = & $clean $resourceName 120
            Code         = & $clean ([string]$innermost.Code) 80
            Message      = & $clean ([string]$innermost.Message) ([int]$State['MaxMessage'])
        }
        if ($State['Seen'].Add(('{0}|{1}|{2}|{3}' -f $item.ResourceType, $item.ResourceName, $item.Code, $item.Message))) {
            $State['Errors'].Add($item)
        }
    }
    return $true
}

function Get-DemoDeploymentFailure {
    <#
    .SYNOPSIS
    Why a template deployment failed while it ran: the innermost errors of its failed operations, as Errors
    (ResourceType, ResourceName, Code, and Message, each redacted and shortened) and Text (them on one line, for
    example "Microsoft.Consumption/budgets budget-dbhub-demo: 400: Start date of budgets cannot be updated. Please
    delete and create a new budget."). $null when the error isn't DeploymentFailed, or the operations can't be read or
    name no error. Internal.

    .DESCRIPTION
    Azure Resource Manager answers a deployment that failed while it ran with DeploymentFailed ("At least one resource
    deployment operation failed. Please list deployment operations for details."), so the cause is in the deployment
    operations: 'az deployment operation sub list' for the subscription-scope deployment, then, for each failed nested
    deployment, 'az deployment operation group list' in its resource group, recursively (Read-DemoFailedOperation): at
    most -MaxDepth levels, -MaxErrors errors, and 12 reads. Any other error (a validation or preflight error) already
    names its cause, and the deployment record with this name can then still be an earlier run's, so its operations
    aren't read. Phase 28 live finding (2026-11-02): NOT DONE's reason said only that a resource deployment operation
    had failed, while Azure had refused the budget's start date.
    Sources: https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/find-error-code,
    https://learn.microsoft.com/cli/azure/deployment/operation/sub#az-deployment-operation-sub-list,
    https://learn.microsoft.com/cli/azure/deployment/operation/group#az-deployment-operation-group-list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [AllowEmptyString()]
        [AllowNull()]
        [string] $ErrorText,

        [ValidateRange(1, 8)]
        [int] $MaxDepth = 4,

        [ValidateRange(1, 20)]
        [int] $MaxErrors = 5
    )

    if ([string]$ErrorText -notmatch '(?i)\bDeploymentFailed\b|\bDeployment failed\. Correlation ID') {
        return $null
    }
    $state = @{
        Errors     = [System.Collections.Generic.List[object]]::new()
        Seen       = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        Reads      = 0
        MaxReads   = 12
        MaxDepth   = $MaxDepth
        MaxErrors  = $MaxErrors
        MaxMessage = 300
    }
    $readable = Read-DemoFailedOperation -SubscriptionId ([string]$Config['subscriptionId']) -Name $DeploymentName -Depth 1 -State $state
    if (-not $readable -or $state['Errors'].Count -eq 0) {
        return $null
    }
    $parts = foreach ($item in $state['Errors']) {
        $what = (@($item.ResourceType, $item.ResourceName) | Where-Object { $_ }) -join ' '
        (@($what, $item.Code, $item.Message) | Where-Object { $_ }) -join ': '
    }
    $text = @($parts) -join '; '
    if ($text.Length -gt 1200) {
        $text = $text.Substring(0, 1197) + '...'
    }
    return [pscustomobject]@{ Errors = $state['Errors'].ToArray(); Text = $text }
}

function New-DemoTemplateFailureResult {
    <#
    .SYNOPSIS
    DEPLOY.TEMPLATE's Fail for a template deployment that failed. Internal.

    .DESCRIPTION
    With the cause Get-DemoDeploymentFailure read, the message names the innermost errors, and the evidence lists them
    (failedOperations) with the Azure CLI's own error (deploymentError); without it, the message is the Azure CLI's
    error, redacted and shortened, as before. When Azure refused a budget's start date (Phase 28 live finding,
    2026-11-02), the remediation says how to recreate the budget: delete it at its resource group's scope, then run
    deploy.ps1 again, which creates it anew from the first day of the current month
    (https://learn.microsoft.com/rest/api/consumption/budgets/delete,
    https://learn.microsoft.com/rest/api/consumption/budgets/create-or-update). Identifiers stay in the text as Azure
    wrote them; in GitHub Actions, what leaves the process shows them as *** (Protect-DemoLogText, ADR 0022).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $Verb,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [AllowEmptyString()]
        [AllowNull()]
        [string] $ErrorText,

        [AllowNull()]
        [object] $Cause,

        [string] $DocUrl = 'https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-create'
    )

    $evidence = [ordered]@{ deploymentName = $DeploymentName }
    # Assigned first: Get-DemoMemberValue returns an array as one object.
    $causeErrors = Get-DemoMemberValue -InputObject $Cause -Name 'Errors'
    $errors = @(@($causeErrors) | Where-Object { $null -ne $_ })
    if ($errors.Count -gt 0) {
        $message = 'The template {0} failed: {1}' -f $Verb, [string](Get-DemoMemberValue -InputObject $Cause -Name 'Text')
        $evidence['failedOperations'] = @(foreach ($item in $errors) { [ordered]@{ resourceType = $item.ResourceType; resourceName = $item.ResourceName; code = $item.Code; message = $item.Message } })
        $evidence['deploymentError'] = Get-DemoDeploymentErrorText -Text $ErrorText -MaxLength 600
    }
    else {
        $message = 'The template {0} failed: {1}' -f $Verb, (Get-DemoDeploymentErrorText -Text $ErrorText)
    }
    $budgetRefused = @($errors | Where-Object { [string]$_.ResourceType -eq 'Microsoft.Consumption/budgets' -and [string]$_.Message -match '(?i)\bstart date\b' }).Count -gt 0 -or [string]$ErrorText -match '(?i)start date of budgets? cannot be updated'
    if ($budgetRefused) {
        $remediation = 'Azure doesn''t change a budget''s start date, and this deployment asked for another one. Delete the budget budget-{0}-{1} at the scope of the resource group {2} (Azure portal: Cost Management > Budgets, with {2} as the scope; or the REST API''s Budgets - Delete), then run ./scripts/deploy.ps1 again: it creates the budget anew, starting the first day of this month.' -f $Config['prefix'], $Config['environment'], (Get-DemoResourceGroupName -Config $Config)
        $doc = 'https://learn.microsoft.com/rest/api/consumption/budgets/delete'
    }
    else {
        $remediation = 'Fix the cause in the message, then run deploy.ps1 -Resume. A 409 Conflict while a policy installs an extension clears within minutes.'
        $doc = if ($errors.Count -gt 0) { 'https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/find-error-code' } else { $DocUrl }
    }
    return (New-DemoResult -CheckId 'DEPLOY.TEMPLATE' -Area 'infra' -Target 'subscription' -Status 'Fail' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $doc)
}

function ConvertTo-DemoDeploymentOutput {
    # The template outputs as name -> value; empty for a deployment without outputs. Internal.
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object] $Deployment
    )

    $outputs = @{}
    $source = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Deployment -Name 'properties') -Name 'outputs'
    if ($null -eq $source) {
        return $outputs
    }
    # Each name on its own: under strict mode, .Name on an empty property collection (outputs: {}) throws.
    $properties = if ($source -is [System.Collections.IDictionary]) { @($source.Keys) } else { @($source.PSObject.Properties | ForEach-Object { $_.Name }) }
    foreach ($name in $properties) {
        $outputs[[string]$name] = Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $source -Name $name) -Name 'value'
    }
    return $outputs
}

function Get-DemoT1PrincipalId {
    # T1's system-assigned identity, which joins the P6 group (ADR 0008). Empty when T1 doesn't exist. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $result = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('vm', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--name', 'sqlvm01', '--query', 'identity.principalId', '--output', 'tsv') -AllowFailure
    if ($result.ExitCode -ne 0) {
        return ''
    }
    return ([string]$result.StdOut).Trim()
}

function Get-DemoT3State {
    <#
    .SYNOPSIS
    Whether T3's database exists and its status (Online, Paused, ...), read with az sql db show. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $DeploymentId = ''
    )

    $id = $DeploymentId
    if (-not $id) {
        $id = [string](Get-DemoResourceGroupTag -SubscriptionId ([string]$Config['subscriptionId']) -ResourceGroupName (Get-DemoResourceGroupName -Config $Config))['deploymentId']
    }
    $server = 'azuresql01-{0}' -f $id
    $database = Invoke-DemoAz -SubscriptionId ([string]$Config['subscriptionId']) -ArgumentList @('sql', 'db', 'show', '--resource-group', (Get-DemoResourceGroupName -Config $Config), '--server', $server, '--name', 'ContosoCare') -AsJson -AllowFailure
    $status = [string](Get-DemoMemberValue -InputObject $database -Name 'status')
    return [pscustomobject]@{
        Exists       = ($null -ne $database)
        Status       = $status
        ServerName   = $server
        DeploymentId = $id
    }
}

function Get-DemoNextShutdownUtc {
    <#
    .SYNOPSIS
    The next auto-shutdown in UTC from autoShutdownTime (HHmm) and autoShutdownTimeZone (a Windows time zone
    ID), the same schedule as the DevTest Labs auto-shutdown. Internal.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    $time = if ($Config['autoShutdownTime']) { [string]$Config['autoShutdownTime'] } else { '1900' }
    $zoneId = if ($Config['autoShutdownTimeZone']) { [string]$Config['autoShutdownTimeZone'] } else { 'UTC' }
    if ($time -notmatch '^([01]\d|2[0-3])([0-5]\d)$') {
        throw "autoShutdownTime '$time' isn't HHmm."
    }
    $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById($zoneId)
    $now = [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc)
    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($now, $zone)
    $candidate = [datetime]::new($local.Year, $local.Month, $local.Day, [int]$Matches[1], [int]$Matches[2], 0, [System.DateTimeKind]::Unspecified)
    if ($candidate -le $local) {
        $candidate = $candidate.AddDays(1)
    }
    return [System.TimeZoneInfo]::ConvertTimeToUtc($candidate, $zone)
}

function Invoke-DemoRepositoryScript {
    <#
    .SYNOPSIS
    Runs one of the repository's scripts (for example scripts/configure-fabric.ps1) from module code as an operator
    would run it, outside DbHubDemo's session state, and returns its output. Internal.

    .DESCRIPTION
    A script that a module function runs with the call operator runs in the module's session state, so the script's
    own scope becomes the script scope of every DbHubDemo function it calls, and those functions no longer find the
    module's $script: variables (live, 2026-10-22: deploy.ps1's Fabric track stopped at once, because Get-DemoConfig's
    default schema path reads $script:RepoRoot). A script block bound to a separate dynamic module runs the script in
    that module's session state instead, so DbHubDemo's functions keep their own script scope, including the
    subscription guard's validated context.
    https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_scopes
    https://learn.microsoft.com/dotnet/api/system.management.automation.psmoduleinfo.newboundscriptblock
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [System.Collections.IDictionary] $Argument = @{}
    )

    $hostModule = New-Module -Name 'DbHubDemoScriptHost' -ScriptBlock { Export-ModuleMember -Function @() }
    $invoke = $hostModule.NewBoundScriptBlock({
            param([string] $ScriptPath, [System.Collections.IDictionary] $Arguments)
            & $ScriptPath @Arguments
        })
    return (& $invoke $Path $Argument)
}

function Invoke-DemoFabricStage {
    <#
    .SYNOPSIS
    deploy.ps1's Fabric stage: runs scripts/configure-fabric.ps1 (the Database Hub checklist with the T3
    readiness gate, and the notebook import when asked) and returns its results. Internal.

    .DESCRIPTION
    The script stays the one implementation of the import loop (Phases 9 and 12). Telemetry is left to the
    validation stage (-SkipTelemetry). Without -ConfigPath, the configuration goes to a file in a private
    temporary directory that's deleted afterward; it holds no secrets.

    deploy.ps1's parallel Fabric track (ADR 0018) passes -SkipHubChecks and -ImportDashboard: it imports the
    notebooks and the Real-Time Dashboard while the targets deploy, and leaves the Hub checklist, the T3
    gate, and the dashboard's tile check to the validation, which passes -CheckDashboardData once telemetry
    flows, and -T3PerformanceMonitoringCheck with the T3.PROPERTY result, so the gate's extended-property part
    isn't left as a manual step. While fabric.importNotebooks is false, deploy passes -NewNotebooksOnly: notebooks
    that aren't in the workspace yet are imported without asking, and existing ones stay as they are (Phase 26a).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [switch] $ImportNotebooks,

        [switch] $NewNotebooksOnly,

        [switch] $ImportDashboard,

        [switch] $SkipHubChecks,

        [switch] $CheckDashboardData,

        [scriptblock] $T3PerformanceMonitoringCheck
    )

    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-fabric'
    try {
        $path = $ConfigPath
        if (-not $path -or -not (Test-Path -LiteralPath $path)) {
            $path = Write-DemoPrivateFile -Directory $directory -Name 'demo.config.json' -Content ($Config | ConvertTo-Json -Depth 20)
        }
        $output = Join-Path -Path $directory -ChildPath 'configure-fabric.jsonl'
        $arguments = @{
            ConfigPath    = $path
            OutputPath    = $output
            SkipTelemetry = $true
            Confirm       = $false
        }
        if ($SkipHubChecks) {
            $arguments['SkipHubChecks'] = $true
        }
        else {
            $arguments['T3ReadinessGate'] = $true
            if ($null -ne $T3PerformanceMonitoringCheck) {
                $arguments['T3PerformanceMonitoringCheck'] = $T3PerformanceMonitoringCheck
            }
        }
        if ($NewNotebooksOnly -and -not $ImportNotebooks) {
            $arguments['NewNotebooksOnly'] = $true
        }
        elseif (-not $ImportNotebooks) {
            $arguments['SkipNotebookImport'] = $true
        }
        if ($ImportDashboard) {
            $arguments['ImportDashboard'] = $true
            if (-not $CheckDashboardData) {
                $arguments['SkipDashboardDataCheck'] = $true
            }
        }
        if ($CheckDashboardData) {
            $arguments['CheckDashboardData'] = $true
        }
        $null = Invoke-DemoRepositoryScript -Path (Join-Path -Path $script:RepoRoot -ChildPath 'scripts/configure-fabric.ps1') -Argument $arguments
        if (-not (Test-Path -LiteralPath $output)) {
            return @(New-DemoResult -CheckId 'DEPLOY.FABRIC' -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message 'configure-fabric.ps1 wrote no results.' -Remediation 'Run ./scripts/configure-fabric.ps1 yourself to see its output.')
        }
        return @(Get-Content -LiteralPath $output | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
}

function Invoke-DemoFabricScriptStep {
    <#
    .SYNOPSIS
    Runs one of the repository's Fabric scripts in this process with the configuration and an output file, and
    returns the ADR 0012 records it wrote. Internal; Invoke-DemoPowerBIStage and Invoke-DemoFabricAppStage use it.

    .DESCRIPTION
    Only the parameters the script declares are passed (ConfigPath, OutputPath, and Confirm), plus -Argument. A
    script that throws, or writes no records, is reported as -CheckId Fail, with the innermost cause of an exception; one
    that a network error stopped (Invoke-DemoTransientRetry) has evidence networkError and says to run deploy.ps1 again,
    which resumes the step (Phase 28 live finding, 2026-10-30). Without -ConfigPath, the configuration
    goes to a file in a private temporary directory that's deleted afterward; it holds no secrets.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [Parameter(Mandatory)]
        [string] $ScriptPath,

        [Parameter(Mandatory)]
        [string] $CheckId,

        [System.Collections.IDictionary] $Argument = @{}
    )

    $name = Split-Path -Path $ScriptPath -Leaf
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-fabric'
    try {
        $path = $ConfigPath
        if (-not $path -or -not (Test-Path -LiteralPath $path)) {
            $path = Write-DemoPrivateFile -Directory $directory -Name 'demo.config.json' -Content ($Config | ConvertTo-Json -Depth 20)
        }
        $output = Join-Path -Path $directory -ChildPath 'results.jsonl'
        $declared = (Get-Command -Name $ScriptPath -ErrorAction Stop).Parameters
        $arguments = @{}
        foreach ($pair in @(@('ConfigPath', $path), @('OutputPath', $output), @('Confirm', $false))) {
            if ($declared.ContainsKey($pair[0])) {
                $arguments[$pair[0]] = $pair[1]
            }
        }
        foreach ($key in $Argument.Keys) {
            $arguments[[string]$key] = $Argument[$key]
        }
        try {
            $null = Invoke-DemoRepositoryScript -Path $ScriptPath -Argument $arguments
        }
        catch {
            # A step that a network error stopped (Invoke-DemoTransientRetry) needs only a rerun, which resumes this step
            # (Phase 28 live finding, 2026-10-30); anything else, the script's own output.
            if (Test-DemoNetworkFailure -Exception $_.Exception) {
                return @(New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('{0} stopped: {1}' -f $name, (Get-DemoExceptionText -Exception $_.Exception)) -Evidence ([ordered]@{ networkError = $true }) -Remediation ('Run ./scripts/deploy.ps1 again: it resumes where it stopped. {0}' -f (Get-DemoNetworkErrorNote)))
            }
            return @(New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('{0} stopped: {1}' -f $name, (Get-DemoExceptionText -Exception $_.Exception)) -Remediation ('Run ./scripts/{0} yourself to see its output.' -f $name))
        }
        if (-not (Test-Path -LiteralPath $output)) {
            return @(New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Fail' -Message ('{0} wrote no results.' -f $name) -Remediation ('Run ./scripts/{0} yourself to see its output.' -f $name))
        }
        return @(Get-Content -LiteralPath $output | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
    }
}

function Invoke-DemoPowerBIStage {
    <#
    .SYNOPSIS
    The Fabric track's Power BI step (Phase 19, ADR 0018): runs scripts/configure-powerbi.ps1 (the history semantic
    model, its refresh and data check, and the report) and returns its records. Internal.

    .DESCRIPTION
    -CheckModelData runs only the data check against the deployed model (configure-powerbi.ps1 -CheckModelData).
    Without a Fabric workspace and lakehouse in the configuration, the script reports Not selected itself.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [switch] $CheckModelData
    )

    $scriptPath = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/configure-powerbi.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return @(New-DemoResult -CheckId 'DEPLOY.POWERBI' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'scripts/configure-powerbi.ps1 (Phase 19) isn''t in this checkout, so the history report wasn''t deployed.')
    }
    $argument = @{}
    if ($CheckModelData) {
        $argument['CheckModelData'] = $true
    }
    $records = @(Invoke-DemoFabricScriptStep -Config $Config -ConfigPath $ConfigPath -ScriptPath $scriptPath -CheckId 'DEPLOY.POWERBI' -Argument $argument)
    return @(Merge-DemoBlankMeasureResult -Result $records)
}

function Merge-DemoBlankMeasureResult {
    <#
    .SYNOPSIS
    deploy.ps1's view of the history model's data check (Phase 28 live finding, 2026-10-30): before
    NB_DatabaseHub_LiveActivity has saved any snapshot (FABRIC.SEMANTICMODEL.ROWS is the Warning that no history is
    written yet), every measure is blank, and the about 40 FABRIC.SEMANTICMODEL.MEASURE.* Warnings become one,
    FABRIC.SEMANTICMODEL.MEASURES, which says that's expected right after a first deployment and keeps their check IDs
    in its evidence. A measure that fails, or returns a value, stays as it is; with history written, nothing changes.
    configure-powerbi.ps1 itself still reports every measure. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $all = @($Result | Where-Object { $null -ne $_ })
    $rows = @($all | Where-Object { [string]$_.checkId -eq 'FABRIC.SEMANTICMODEL.ROWS' }) | Select-Object -Last 1
    if ($null -eq $rows -or [string]$rows.status -ne 'Warning') {
        return $all
    }
    $blank = @($all | Where-Object { [string]$_.checkId -like 'FABRIC.SEMANTICMODEL.MEASURE.*' -and [string]$_.status -eq 'Warning' })
    if ($blank.Count -lt 2) {
        return $all
    }
    $ids = @($blank | ForEach-Object { [string]$_.checkId })
    $merged = New-DemoResult -CheckId 'FABRIC.SEMANTICMODEL.MEASURES' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message ('The history report is empty until NB_DatabaseHub_LiveActivity saves its first snapshots; that''s expected right after a first deployment ({0} measures are blank for now).' -f $blank.Count) -Evidence ([ordered]@{ blankMeasures = $ids }) -Remediation 'Nothing to do now: ./scripts/stop-demo.ps1 -SaveHistory (or ./scripts/configure-fabric.ps1 -RunLiveActivity) runs NB_DatabaseHub_LiveActivity, which saves the snapshots the report shows; ./scripts/configure-powerbi.ps1 -CheckModelData then checks every measure again.' -DocUrl 'https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group'
    $kept = [System.Collections.Generic.List[object]]::new()
    $placed = $false
    foreach ($item in $all) {
        if ([string]$item.checkId -in $ids -and [string]$item.status -eq 'Warning') {
            if (-not $placed) {
                $kept.Add($merged)
                $placed = $true
            }
            continue
        }
        $kept.Add($item)
    }
    return $kept.ToArray()
}

function Invoke-DemoFabricAppStage {
    <#
    .SYNOPSIS
    The Fabric track's app step: runs scripts/configure-fabric-app.ps1 (Phase 19b, the Fabric app over the history
    model) when this checkout has it, and returns its records; DEPLOY.FABRIC.APP is Not selected otherwise. Phase
    19b verifies the app itself. Internal.

    .DESCRIPTION
    The app is optional (brief item 15), so here its records are never a Fail: a Fail becomes Manual action required
    (evidence reportedStatus Fail), every record is marked optional (evidence optional insightsApp, which
    Test-DemoOptionalResult reads), and the records that aren't the app's own (the script's own workspace and capacity
    checks, for example) say they're the app's. -WorkspaceId is the workspace the Fabric step resolved or created, so
    the script doesn't look it up by name again (Phase 28 live finding).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $ConfigPath = '',

        [AllowEmptyString()]
        [string] $WorkspaceId = ''
    )

    $scriptPath = Join-Path -Path $script:RepoRoot -ChildPath 'scripts/configure-fabric-app.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return @(New-DemoResult -CheckId 'DEPLOY.FABRIC.APP' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'scripts/configure-fabric-app.ps1 (Phase 19b) isn''t in this checkout, so the Fabric app wasn''t deployed.')
    }
    $argument = @{}
    if ($WorkspaceId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        $argument['WorkspaceId'] = $WorkspaceId
    }
    $records = @(Invoke-DemoFabricScriptStep -Config $Config -ConfigPath $ConfigPath -ScriptPath $scriptPath -CheckId 'DEPLOY.FABRIC.APP' -Argument $argument)
    return @(foreach ($record in $records) {
            ConvertTo-DemoOptionalAppRecord -Record $record
        })
}

function ConvertTo-DemoOptionalAppRecord {
    # One record of the optional Insights app's step as deploy.ps1 reports it (brief item 15; Phase 28 live finding):
    # marked optional, a Fail as Manual action required, and named as the app's when it isn't one of its own checks.
    # Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [object] $Record
    )

    $own = [string]$Record.checkId -like 'FABRIC.APP.*' -or [string]$Record.checkId -eq 'DEPLOY.FABRIC.APP'
    $marks = [ordered]@{ optional = 'insightsApp' }
    if ([string]$Record.status -eq 'Fail') {
        $marks['reportedStatus'] = 'Fail'
        $Record.status = 'Manual action required'
        if (-not [string](Get-DemoMemberValue -InputObject $Record -Name 'remediation')) {
            $Record | Add-Member -NotePropertyName 'remediation' -NotePropertyValue 'To add the optional Insights app, run ./scripts/configure-fabric-app.ps1 -SignIn.' -Force
        }
    }
    $evidence = Get-DemoMemberValue -InputObject $Record -Name 'evidence'
    if ($evidence -is [System.Collections.IDictionary]) {
        foreach ($key in $marks.Keys) {
            $evidence[$key] = $marks[$key]
        }
    }
    elseif ($null -ne $evidence -and $evidence -isnot [string] -and $evidence -isnot [System.ValueType]) {
        foreach ($key in $marks.Keys) {
            $evidence | Add-Member -NotePropertyName $key -NotePropertyValue $marks[$key] -Force
        }
    }
    else {
        $Record | Add-Member -NotePropertyName 'evidence' -NotePropertyValue ([pscustomobject]$marks) -Force
    }
    if (-not $own -and [string]$Record.message -notlike 'Optional Insights app:*') {
        $Record.message = 'Optional Insights app: {0}' -f [string]$Record.message
    }
    return $Record
}

function Get-DemoResolvedWorkspaceId {
    # The Fabric workspace's ID that configure-fabric.ps1's records name (FABRIC.RESOLVE.WORKSPACE: found, created, or the
    # fabric.workspaceId override), or '' when none did. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Result = @()
    )

    $pattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $named = @($Result | Where-Object { $null -ne $_ -and [string]$_.checkId -eq 'FABRIC.RESOLVE.WORKSPACE' -and [string]$_.status -ne 'Fail' })
    for ($index = $named.Count - 1; $index -ge 0; $index--) {
        $id = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $named[$index] -Name 'evidence') -Name 'workspaceId')
        if ($id -match $pattern -and $id -ne '00000000-0000-0000-0000-000000000000') {
            return $id.ToLowerInvariant()
        }
    }
    return ''
}
