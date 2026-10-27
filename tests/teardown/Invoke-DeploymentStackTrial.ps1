#Requires -Version 7.4
<#
.SYNOPSIS
Phase 16 deployment-stack trial (ADR 0001): creates, updates, and deletes small deployment stacks in a
disposable resource group, records each result, and removes everything it created.

.DESCRIPTION
Live and opt-in. It touches only the resource group it creates (rg-<prefix>-stacktest by default) and the two
stacks it names, and it uses only free user-assigned managed identities. Every Azure CLI call goes through
Invoke-DemoAz after Assert-DemoAzContext; it never signs in, and never passes --ids, --resource-id, or a
{subscriptionId} placeholder. Values and tags reach the stacks in parameter files in a work folder under out/,
which it deletes at the end.

1. Resource group scope (az stack group): create the stack with an optional identity, add an identity outside
   the stack (like the Arc resources that onboarding creates outside the template), update the stack without
   the optional identity (actionOnUnmanage deleteResources), turn on denyDelete and try to delete a managed
   identity, then delete the stack with deleteAll.
2. Subscription scope (az stack sub, the shape main.bicep would take): the stack creates the resource group
   and an identity, an identity is added outside the stack, and the stack is deleted with deleteAll.
3. Contributor: reads the Contributor role definition and reports whether it allows every action the stacks
   need, including Microsoft.Resources/deploymentStacks/manageDenySetting/action for deny settings.
4. Cleanup in a finally block: the stacks, the identities, and the resource group, then a check that nothing
   is left, deny assignments included (TEARDOWN.STACK.CLEANUP).

Sources (checked 2026-10-21):
- https://learn.microsoft.com/azure/azure-resource-manager/bicep/deployment-stacks
- https://learn.microsoft.com/azure/azure-resource-manager/bicep/deployment-stacks-known-issues
- https://learn.microsoft.com/cli/azure/stack/group
- https://learn.microsoft.com/cli/azure/stack/sub
- https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/general#contributor
- https://learn.microsoft.com/rest/api/authorization/deny-assignments/list

.PARAMETER ConfigPath
Demo configuration: the subscription, tenant, region, and prefix.

.PARAMETER ResourceGroupName
The disposable resource group (default rg-<prefix>-stacktest). It must end in -stacktest and must not exist
unless this script created it (its purpose tag is deployment-stack-trial).

.PARAMETER SkipDenySettings
Skip the denyDelete step.

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./tests/teardown/Invoke-DeploymentStackTrial.ps1 -ConfigPath ./out/demo.config.test.json -Confirm:$false
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string] $ConfigPath,

    [ValidatePattern('^(rg-[a-z0-9]+-stacktest)?$')]
    [string] $ResourceGroupName = '',

    [switch] $SkipDenySettings,

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../../out/stack-trial.jsonl')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1')
}

$config = Get-DemoConfig -Path $ConfigPath
$subscriptionId = [string]$config['subscriptionId']
$location = [string]$config['location']
if (-not $ResourceGroupName) {
    $ResourceGroupName = 'rg-{0}-stacktest' -f $config['prefix']
}
if ($ResourceGroupName -eq ('rg-{0}-{1}' -f $config['prefix'], $config['environment'])) {
    throw ('{0} is the configured demo environment''s resource group; the trial needs its own.' -f $ResourceGroupName)
}
$versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
$denyApiVersion = [string]$versions.apiVersions['Microsoft.Authorization/denyAssignments']
$results = [System.Collections.Generic.List[object]]::new()
$docUrl = 'https://learn.microsoft.com/azure/azure-resource-manager/bicep/deployment-stacks'
$groupStack = 'dbhub-stacktrial-group'
$subStack = 'dbhub-stacktrial-sub'
$identityA = 'id-dbhub-stacktrial-a'
$identityB = 'id-dbhub-stacktrial-b'
$unmanaged = 'id-dbhub-stacktrial-unmanaged'
$trialTag = 'purpose=deployment-stack-trial'
$trialTags = [ordered]@{ purpose = 'deployment-stack-trial'; solution = 'fabric-database-hub-demo'; environment = 'stacktest' }

function Add-TrialResult {
    param([string] $CheckId, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '')
    $results.Add((New-DemoResult -CheckId $CheckId -Area 'teardown' -Target 'subscription' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl))
    Write-DemoLog -Message ('{0}: {1} - {2}' -f $CheckId, $Status, $Message)
}

function Invoke-TrialAz {
    param([string[]] $ArgumentList)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $run = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $ArgumentList -AllowFailure
    $watch.Stop()
    # Object IDs and sign-in names in an error (the caller, a deny assignment) stay out of the results.
    $errorText = (Protect-DemoText -Text ([string]$run.StdErr)).Trim() -replace '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', '<id>' -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<user>'
    [pscustomobject]@{
        Ok      = ($run.ExitCode -eq 0)
        Seconds = [math]::Round($watch.Elapsed.TotalSeconds)
        StdOut  = [string]$run.StdOut
        Error   = $errorText
    }
}

function Test-TrialIdentity {
    param([string] $Name, [string] $Group = $ResourceGroupName)
    $show = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('identity', 'show', '--name', $Name, '--resource-group', $Group, '--query', 'id', '--output', 'tsv') -AllowFailure
    return ($show.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$show.StdOut))
}

function Test-TrialGroup {
    $exists = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'exists', '--name', $ResourceGroupName) -AllowFailure
    return (([string]$exists.StdOut).Trim() -eq 'true')
}

function Get-TrialDeploymentRecord {
    # The names of the subscription stack's deployment records still in the subscription's deployment history.
    $records = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('deployment', 'sub', 'list', '--query', ("[?starts_with(name, '{0}-')].name" -f $subStack), '--output', 'json') -AllowFailure
    if ($records.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$records.StdOut)) {
        return @()
    }
    return @(@([string]$records.StdOut | ConvertFrom-Json) | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^dbhub-stacktrial-sub-[0-9a-z]+$' })
}

function Wait-TrialGroupGone {
    param([int] $Minutes = 15)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalMinutes -lt $Minutes) {
        if (-not (Test-TrialGroup)) {
            return $true
        }
        Start-Sleep -Seconds 15
    }
    return $false
}

function Get-TrialStackResource {
    param([string] $Json)
    if ([string]::IsNullOrWhiteSpace($Json)) {
        return @()
    }
    $stack = $Json | ConvertFrom-Json -Depth 64
    $properties = if ($stack.PSObject.Properties.Name -contains 'properties') { $stack.properties } else { $stack }
    $resources = if ($properties.PSObject.Properties.Name -contains 'resources') { @($properties.resources) } else { @() }
    return @($resources | Where-Object { $null -ne $_ } | ForEach-Object { '{0} ({1})' -f (([string]$_.id) -split '/')[-1], [string]$_.status })
}

function Export-TrialParameterFile {
    # A deployment parameters file in the work folder, so values and tags never pass through a command line.
    param([string] $Name, [System.Collections.IDictionary] $Value)
    $parameters = [ordered]@{}
    foreach ($key in $Value.Keys) {
        $parameters[$key] = @{ value = $Value[$key] }
    }
    $path = Join-Path -Path $work -ChildPath ('{0}.parameters.json' -f $Name)
    $document = [ordered]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = $parameters }
    Set-Content -LiteralPath $path -Value ($document | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM
    return ('@' + $path)
}

$null = Assert-DemoAzContext -SubscriptionId $subscriptionId -TenantId ([string]$config['tenantId']) -Account ([string]$config['azureAccount'])
if (Test-TrialGroup) {
    $purpose = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'show', '--name', $ResourceGroupName, '--query', 'tags.purpose', '--output', 'tsv') -AllowFailure
    if (([string]$purpose.StdOut).Trim() -ne 'deployment-stack-trial') {
        throw ('{0} exists and isn''t a stack-trial group (its purpose tag isn''t deployment-stack-trial); nothing was changed.' -f $ResourceGroupName)
    }
}
if (-not $PSCmdlet.ShouldProcess($ResourceGroupName, 'Create, update, and delete trial deployment stacks, then delete the resource group')) {
    Add-TrialResult -CheckId 'TEARDOWN.STACK.TRIAL' -Status 'Not selected' -Message 'What if: nothing was created.'
    Export-DemoResult -Result $results.ToArray() -Path $OutputPath
    return
}

$work = Join-Path -Path $repoRoot -ChildPath ('out/stack-trial-{0}' -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work -Force
try {
    # Compiled with the pinned Bicep CLI that az uses, so the stack commands get plain ARM JSON.
    $groupTemplate = Join-Path -Path $work -ChildPath 'group.json'
    $subTemplate = Join-Path -Path $work -ChildPath 'subscription.json'
    $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('bicep', 'build', '--file', (Join-Path -Path $PSScriptRoot -ChildPath 'stack-trial/group.bicep'), '--outfile', $groupTemplate)
    $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('bicep', 'build', '--file', (Join-Path -Path $PSScriptRoot -ChildPath 'stack-trial/subscription.bicep'), '--outfile', $subTemplate)

    # Contributor: every action except its notActions (read live, so a role change shows up here).
    $notActions = @(Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('role', 'definition', 'list', '--name', 'Contributor', '--query', '[0].permissions[0].notActions') -AsJson)
    $denyBlocked = $notActions -contains 'Microsoft.Resources/deploymentStacks/manageDenySetting/action'
    $stackBlocked = @($notActions | Where-Object { $_ -like 'Microsoft.Resources/deploymentStacks/*' -and $_ -ne 'Microsoft.Resources/deploymentStacks/manageDenySetting/action' })
    Add-TrialResult -CheckId 'TEARDOWN.STACK.CONTRIBUTOR' -Status $(if ($stackBlocked.Count -eq 0) { 'Pass' } else { 'Warning' }) -Message ('Contributor allows deploymentStacks write, read, and delete{0}; manageDenySetting is {1}, so deny settings other than none need Owner or Azure Deployment Stack Owner.' -f $(if ($stackBlocked.Count) { ' except ' + ($stackBlocked -join ', ') } else { '' }), $(if ($denyBlocked) { 'one of its notActions' } else { 'not excluded' })) -Evidence ([ordered]@{ contributorNotActions = $notActions })

    # 1. Resource group scope.
    $create = Invoke-TrialAz -ArgumentList @('group', 'create', '--name', $ResourceGroupName, '--location', $location, '--tags', $trialTag, 'solution=fabric-database-hub-demo', 'environment=stacktest')
    if (-not $create.Ok) {
        throw ('Creating {0} failed: {1}' -f $ResourceGroupName, $create.Error)
    }
    $first = Invoke-TrialAz -ArgumentList @('stack', 'group', 'create', '--name', $groupStack, '--resource-group', $ResourceGroupName, '--template-file', $groupTemplate, '--parameters', (Export-TrialParameterFile -Name 'group-create' -Value ([ordered]@{ includeOptional = $true; tags = $trialTags })), '--action-on-unmanage', 'deleteResources', '--deny-settings-mode', 'none', '--yes', '--output', 'json')
    $managed = @(Get-TrialStackResource -Json $first.StdOut)
    Add-TrialResult -CheckId 'TEARDOWN.STACK.GROUP.CREATE' -Status $(if ($first.Ok -and (Test-TrialIdentity -Name $identityA) -and (Test-TrialIdentity -Name $identityB)) { 'Pass' } else { 'Fail' }) -Message ('az stack group create with two identities: {0} in {1} s. {2}' -f $(if ($first.Ok) { 'succeeded' } else { 'failed' }), $first.Seconds, $first.Error) -Evidence ([ordered]@{ seconds = $first.Seconds; resources = $managed })

    $outside = Invoke-TrialAz -ArgumentList @('identity', 'create', '--name', $unmanaged, '--resource-group', $ResourceGroupName, '--location', $location, '--tags', $trialTag)
    Add-TrialResult -CheckId 'TEARDOWN.STACK.GROUP.UNMANAGED' -Status $(if ($outside.Ok) { 'Pass' } else { 'Fail' }) -Message ('An identity created outside the stack, in the same group (like the Arc resources onboarding creates): {0} in {1} s.' -f $(if ($outside.Ok) { 'created' } else { 'failed' }), $outside.Seconds)

    $update = Invoke-TrialAz -ArgumentList @('stack', 'group', 'create', '--name', $groupStack, '--resource-group', $ResourceGroupName, '--template-file', $groupTemplate, '--parameters', (Export-TrialParameterFile -Name 'group-update' -Value ([ordered]@{ includeOptional = $false; tags = $trialTags })), '--action-on-unmanage', 'deleteResources', '--deny-settings-mode', 'none', '--yes', '--output', 'json')
    $bGone = -not (Test-TrialIdentity -Name $identityB)
    $keptOutside = Test-TrialIdentity -Name $unmanaged
    Add-TrialResult -CheckId 'TEARDOWN.STACK.GROUP.UPDATE' -Status $(if ($update.Ok -and $bGone -and $keptOutside) { 'Pass' } else { 'Fail' }) -Message ('Update without the optional identity (deleteResources) in {0} s: it was {1}, and the identity outside the stack was {2}. {3}' -f $update.Seconds, $(if ($bGone) { 'deleted' } else { 'left in place' }), $(if ($keptOutside) { 'left alone' } else { 'deleted' }), $update.Error) -Evidence ([ordered]@{ seconds = $update.Seconds; resources = @(Get-TrialStackResource -Json $update.StdOut) })

    if ($SkipDenySettings) {
        Add-TrialResult -CheckId 'TEARDOWN.STACK.GROUP.DENY' -Status 'Not selected' -Message 'The denyDelete step was skipped (-SkipDenySettings).'
    }
    else {
        $deny = Invoke-TrialAz -ArgumentList @('stack', 'group', 'create', '--name', $groupStack, '--resource-group', $ResourceGroupName, '--template-file', $groupTemplate, '--parameters', (Export-TrialParameterFile -Name 'group-deny' -Value ([ordered]@{ includeOptional = $false; tags = $trialTags })), '--action-on-unmanage', 'deleteResources', '--deny-settings-mode', 'denyDelete', '--yes', '--output', 'json')
        $attempt = if ($deny.Ok) { Invoke-TrialAz -ArgumentList @('identity', 'delete', '--name', $identityA, '--resource-group', $ResourceGroupName) } else { $null }
        $denied = $null -ne $attempt -and -not $attempt.Ok -and $attempt.Error -match '(?i)deny'
        $denyStatus = if (-not $deny.Ok) { 'Warning' } elseif ($denied) { 'Pass' } else { 'Fail' }
        Add-TrialResult -CheckId 'TEARDOWN.STACK.GROUP.DENY' -Status $denyStatus -Message ('denyDelete as the signed-in identity: {0} in {1} s; deleting a managed identity directly was {2}. {3}' -f $(if ($deny.Ok) { 'applied' } else { 'refused' }), $deny.Seconds, $(if ($null -eq $attempt) { 'not tried' } elseif ($denied) { 'denied by the deny assignment' } elseif ($attempt.Ok) { 'allowed' } else { 'refused for another reason' }), $(if ($deny.Ok) { $(if ($null -ne $attempt) { $attempt.Error.Substring(0, [math]::Min(300, $attempt.Error.Length)) } else { '' }) } else { $deny.Error })) -Evidence ([ordered]@{ seconds = $deny.Seconds; contributorExcludesManageDenySetting = $denyBlocked })
    }

    $delete = Invoke-TrialAz -ArgumentList @('stack', 'group', 'delete', '--name', $groupStack, '--resource-group', $ResourceGroupName, '--action-on-unmanage', 'deleteAll', '--yes')
    $aGone = -not (Test-TrialIdentity -Name $identityA)
    $keptOutside = Test-TrialIdentity -Name $unmanaged
    $groupKept = Test-TrialGroup
    Add-TrialResult -CheckId 'TEARDOWN.STACK.GROUP.DELETE' -Status $(if ($delete.Ok -and $aGone) { 'Pass' } else { 'Fail' }) -Message ('az stack group delete --action-on-unmanage deleteAll{0}: {1} in {2} s; the managed identity was {3}, the identity outside the stack was {4}, and the resource group was {5}. {6}' -f $(if ($SkipDenySettings) { '' } else { ' (with denyDelete still on)' }), $(if ($delete.Ok) { 'succeeded' } else { 'failed' }), $delete.Seconds, $(if ($aGone) { 'deleted' } else { 'left' }), $(if ($keptOutside) { 'left alone' } else { 'deleted' }), $(if ($groupKept) { 'kept' } else { 'deleted' }), $delete.Error) -Evidence ([ordered]@{ seconds = $delete.Seconds })

    $null = Invoke-TrialAz -ArgumentList @('identity', 'delete', '--name', $unmanaged, '--resource-group', $ResourceGroupName)
    $null = Invoke-TrialAz -ArgumentList @('group', 'delete', '--name', $ResourceGroupName, '--yes', '--no-wait')
    if (-not (Wait-TrialGroupGone)) {
        throw ('{0} is still being deleted after 15 minutes.' -f $ResourceGroupName)
    }

    # 2. Subscription scope: the stack owns the resource group, as main.bicep would. The group gets the trial's
    # purpose tag from the template, so the guard above recognizes it if the run stops halfway.
    $subCreate = Invoke-TrialAz -ArgumentList @('stack', 'sub', 'create', '--name', $subStack, '--location', $location, '--template-file', $subTemplate, '--parameters', (Export-TrialParameterFile -Name 'sub-create' -Value ([ordered]@{ location = $location; resourceGroupName = $ResourceGroupName; tags = $trialTags })), '--action-on-unmanage', 'deleteAll', '--deny-settings-mode', 'none', '--yes', '--output', 'json')
    Add-TrialResult -CheckId 'TEARDOWN.STACK.SUB.CREATE' -Status $(if ($subCreate.Ok -and (Test-TrialIdentity -Name $identityA)) { 'Pass' } else { 'Fail' }) -Message ('az stack sub create (the resource group and an identity): {0} in {1} s. {2}' -f $(if ($subCreate.Ok) { 'succeeded' } else { 'failed' }), $subCreate.Seconds, $subCreate.Error) -Evidence ([ordered]@{ seconds = $subCreate.Seconds; resources = @(Get-TrialStackResource -Json $subCreate.StdOut) })
    if ($subCreate.Ok) {
        $outside = Invoke-TrialAz -ArgumentList @('identity', 'create', '--name', $unmanaged, '--resource-group', $ResourceGroupName, '--location', $location, '--tags', $trialTag)
        $subDelete = Invoke-TrialAz -ArgumentList @('stack', 'sub', 'delete', '--name', $subStack, '--action-on-unmanage', 'deleteAll', '--yes')
        $waitWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $groupGone = Wait-TrialGroupGone -Minutes 15
        $status = if ($subDelete.Ok -and $groupGone) { 'Pass' } elseif ($subDelete.Ok) { 'Warning' } else { 'Fail' }
        Add-TrialResult -CheckId 'TEARDOWN.STACK.SUB.DELETE' -Status $status -Message ('az stack sub delete --action-on-unmanage deleteAll with an identity outside the stack in its resource group ({0}): {1} in {2} s, and the resource group {3} {4} s later. {5}' -f $(if ($outside.Ok) { 'created' } else { 'not created' }), $(if ($subDelete.Ok) { 'succeeded' } else { 'failed' }), $subDelete.Seconds, $(if ($groupGone) { 'was gone, with everything in it,' } else { 'was still there' }), [math]::Round($waitWatch.Elapsed.TotalSeconds), $subDelete.Error) -Evidence ([ordered]@{ seconds = $subDelete.Seconds; groupGoneAfterSeconds = [math]::Round($waitWatch.Elapsed.TotalSeconds); resourceGroupDeleted = $groupGone; unmanagedIdentityCreated = $outside.Ok })
    }
}
finally {
    # Remove whatever is left, whatever happened above.
    foreach ($stack in @(@('stack', 'group', 'delete', '--name', $groupStack, '--resource-group', $ResourceGroupName, '--action-on-unmanage', 'deleteAll', '--yes'), @('stack', 'sub', 'delete', '--name', $subStack, '--action-on-unmanage', 'deleteAll', '--yes'))) {
        if ($stack[1] -eq 'group' -and -not (Test-TrialGroup)) {
            continue
        }
        $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $stack -AllowFailure
    }
    if (Test-TrialGroup) {
        $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('group', 'delete', '--name', $ResourceGroupName, '--yes', '--no-wait') -AllowFailure
        $null = Wait-TrialGroupGone
    }
    # The subscription stack's deployment records (dbhub-stacktrial-sub-<suffix>) stay in the subscription's
    # deployment history after the stack is deleted (live, 2026-10-22), so they're deleted too.
    foreach ($record in @(Get-TrialDeploymentRecord)) {
        $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('deployment', 'sub', 'delete', '--name', $record) -AllowFailure
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

$stackList = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('stack', 'sub', 'list', '--query', '[].name', '--output', 'json') -AllowFailure
$stacksRead = $stackList.ExitCode -eq 0
$leftStacks = @(if ($stacksRead -and -not [string]::IsNullOrWhiteSpace([string]$stackList.StdOut)) { @([string]$stackList.StdOut | ConvertFrom-Json) | Where-Object { ([string]$_) -like 'dbhub-stacktrial*' } })
$leftRecords = @(Get-TrialDeploymentRecord)
$groupLeft = Test-TrialGroup
$denyAssignments = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/denyAssignments?api-version={1}' -f $subscriptionId, $denyApiVersion)) -AsJson -AllowFailure
$denyRead = $null -ne $denyAssignments
$denyItems = if ($denyRead -and $denyAssignments.PSObject.Properties.Name -contains 'value') { @($denyAssignments.value) } else { @() }
$denyLeft = @($denyItems | Where-Object { $null -ne $_ -and ([string]$_.properties.scope) -match [regex]::Escape($ResourceGroupName) })
$clean = $leftStacks.Count -eq 0 -and $leftRecords.Count -eq 0 -and -not $groupLeft -and $denyLeft.Count -eq 0
$cleanupStatus = if (-not $clean) { 'Fail' } elseif (-not ($stacksRead -and $denyRead)) { 'Warning' } else { 'Pass' }
Add-TrialResult -CheckId 'TEARDOWN.STACK.CLEANUP' -Status $cleanupStatus -Message ('After the trial: {0} trial stack(s){1}, {2} trial deployment record(s), the resource group {3}, {4} deny assignment(s) on it{5}.' -f $leftStacks.Count, $(if ($stacksRead) { '' } else { ' (the stack list couldn''t be read)' }), $leftRecords.Count, $(if ($groupLeft) { 'still exists' } else { 'is gone' }), $denyLeft.Count, $(if ($denyRead) { '' } else { ' (the deny assignments couldn''t be read)' })) -Remediation $(if ($cleanupStatus -eq 'Pass') { '' } else { 'Check az stack sub list, az deployment sub list, and the resource group; delete a leftover stack with az stack sub delete --action-on-unmanage deleteAll, a leftover record with az deployment sub delete --name <record>, then the resource group.' })

Write-DemoResultReport -Result $results.ToArray() -Title 'Invoke-DeploymentStackTrial.ps1'
Export-DemoResult -Result $results.ToArray() -Path $OutputPath
exit (Get-DemoExitCode -Result $results.ToArray())
