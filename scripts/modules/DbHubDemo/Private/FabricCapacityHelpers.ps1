# fabric.manageCapacity and stop-demo.ps1 -SaveHistory (Phase 26b, ADR 0023). Internal; tests mock Invoke-DemoAz,
# Set-DemoDeploymentState, Get-DemoDeploymentState, and the Fabric helpers.
#
# The record: start-demo.ps1 writes the capacity it resumed to the demo resource group's tags, so stop-demo.ps1 and
# destroy.ps1 pause only that capacity, from any machine or from GitHub Actions, and the record goes with the group.
# With fabric.manageCapacity false (the default, and the owner's setting for a shared capacity), nothing here calls the
# capacity at all.
$script:FabricCapacityDoc = [ordered]@{
    Resume         = 'https://learn.microsoft.com/rest/api/microsoftfabric/fabric-capacities/resume'
    Suspend        = 'https://learn.microsoft.com/rest/api/microsoftfabric/fabric-capacities/suspend'
    Get            = 'https://learn.microsoft.com/rest/api/microsoftfabric/fabric-capacities/get'
    ListBySub      = 'https://learn.microsoft.com/rest/api/microsoftfabric/fabric-capacities/list-by-subscription'
    PauseResume    = 'https://learn.microsoft.com/fabric/enterprise/pause-resume'
    Trial          = 'https://learn.microsoft.com/fabric/fundamentals/fabric-trial'
    NotebookRun    = 'https://learn.microsoft.com/rest/api/fabric/core/job-scheduler/run-on-demand-item-job'
    NotebookParams = 'https://learn.microsoft.com/fabric/data-engineering/notebook-public-api'
}

function Get-DemoFabricCapacitySetting {
    <#
    .SYNOPSIS
    fabric.manageCapacity, fabric.capacityName, and fabric.saveHistoryOnStop, with the schema's defaults (false, '',
    false) for a configuration that wasn't loaded through Get-DemoConfig. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $fabric = Get-DemoMemberValue -InputObject $Config -Name 'fabric'
    [pscustomobject]@{
        ManageCapacity    = [bool](Get-DemoMemberValue -InputObject $fabric -Name 'manageCapacity')
        CapacityName      = ([string](Get-DemoMemberValue -InputObject $fabric -Name 'capacityName')).Trim()
        SaveHistoryOnStop = [bool](Get-DemoMemberValue -InputObject $fabric -Name 'saveHistoryOnStop')
    }
}

function Get-DemoFabricCapacityRecord {
    <#
    .SYNOPSIS
    The capacity that start-demo.ps1 recorded as resumed (the DbHubFabricCapacityResumed tag, "<resource group>/<name>",
    and DbHubFabricCapacityResumedUtc), from Get-DemoDeploymentState; $null when there's none. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $State
    )

    $value = ([string](Get-DemoMemberValue -InputObject $State -Name 'FabricCapacityResumed')).Trim()
    if ($value -notmatch '^([^/]+)/([a-z][a-z0-9]{2,62})$') {
        return $null
    }
    [pscustomobject]@{
        ResourceGroup = $Matches[1]
        Name          = $Matches[2]
        ResumedUtc    = [string](Get-DemoMemberValue -InputObject $State -Name 'FabricCapacityResumedUtc')
    }
}

function Find-DemoFabricCapacityResource {
    <#
    .SYNOPSIS
    The Fabric capacities named -Name in the configured subscription, through Azure Resource Manager (Fabric
    Capacities - List By Subscription): Name, ResourceGroup, State, and Sku. Internal.

    .DESCRIPTION
    A Trial capacity isn't an Azure resource, and a capacity in another subscription isn't listed, so neither is found:
    fabric.manageCapacity supports neither. Returns Succeeded, Error, and Items.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $apiVersion = Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Fabric/capacities'
    $next = 'https://management.azure.com/subscriptions/{0}/providers/Microsoft.Fabric/capacities?api-version={1}' -f $subscriptionId, $apiVersion
    $items = [System.Collections.Generic.List[object]]::new()
    for ($page = 0; $next -and $page -lt 10; $page++) {
        $read = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $next) -AllowFailure
        if ($read.ExitCode -ne 0) {
            return [pscustomobject]@{ Succeeded = $false; Error = (Get-DemoDeploymentErrorText -Text ([string]$read.StdErr) -MaxLength 300); Items = @() }
        }
        $body = if ([string]::IsNullOrWhiteSpace([string]$read.StdOut)) { $null } else { [string]$read.StdOut | ConvertFrom-Json -Depth 16 }
        # Assign before enumerating: Get-DemoMemberValue returns an array as one object.
        $value = Get-DemoMemberValue -InputObject $body -Name 'value'
        foreach ($item in @($value)) {
            if ($null -eq $item) {
                continue
            }
            $itemName = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
            if (-not [string]::Equals($itemName, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $id = [string](Get-DemoMemberValue -InputObject $item -Name 'id')
            $group = if ($id -match '(?i)/resourceGroups/([^/]+)/') { $Matches[1] } else { '' }
            $items.Add([pscustomobject]@{
                    Name          = $itemName
                    ResourceGroup = $group
                    State         = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'properties') -Name 'state')
                    Sku           = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $item -Name 'sku') -Name 'name')
                })
        }
        $next = [string](Get-DemoMemberValue -InputObject $body -Name 'nextLink')
    }
    return [pscustomobject]@{ Succeeded = $true; Error = ''; Items = $items.ToArray() }
}

function Get-DemoFabricCapacityResource {
    <#
    .SYNOPSIS
    One Fabric capacity in the configured subscription (Fabric Capacities - Get): Found, State, Sku, and Error. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $ResourceGroup,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $url = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Fabric/capacities/{2}?api-version={3}' -f $subscriptionId, $ResourceGroup, $Name, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Fabric/capacities')
    $read = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $url) -AllowFailure
    if ($read.ExitCode -ne 0) {
        $text = [string]$read.StdErr
        $missing = $text -match '(?i)ResourceNotFound|ResourceGroupNotFound|\(NotFound\)|Not Found'
        return [pscustomobject]@{ Found = $false; Missing = $missing; State = ''; Sku = ''; Error = (Get-DemoDeploymentErrorText -Text $text -MaxLength 300) }
    }
    $body = [string]$read.StdOut | ConvertFrom-Json -Depth 16
    [pscustomobject]@{
        Found   = $true
        Missing = $false
        State   = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $body -Name 'properties') -Name 'state')
        Sku     = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $body -Name 'sku') -Name 'name')
        Error   = ''
    }
}

function Invoke-DemoFabricCapacityTransition {
    <#
    .SYNOPSIS
    Resumes or suspends one Fabric capacity in the configured subscription (Fabric Capacities - Resume or Suspend), then
    reads it until it's Active or Paused, or -WaitSeconds pass. Internal.

    .DESCRIPTION
    Both operations answer 200 or 202 Accepted. Contributor on the capacity is enough (its actions are
    Microsoft.Fabric/capacities/resume/action and suspend/action). Returns Accepted, State (the last state read),
    Seconds, and Error. Writes need the context the subscription guard validated.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $ResourceGroup,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [ValidateSet('resume', 'suspend')]
        [string] $Action,

        [ValidateRange(0, 1800)]
        [int] $WaitSeconds = 600,

        [ValidateRange(1, 120)]
        [int] $PollSeconds = 15
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $target = if ($Action -eq 'resume') { 'Active' } else { 'Paused' }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not $PSCmdlet.ShouldProcess(('Fabric capacity {0}' -f $Name), ('{0} (Microsoft.Fabric/capacities/{1})' -f $(if ($Action -eq 'resume') { 'Resume' } else { 'Pause' }), $Action))) {
        return [pscustomobject]@{ Accepted = $false; State = ''; Seconds = 0; Error = 'Skipped.' }
    }
    $url = 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Fabric/capacities/{2}/{3}?api-version={4}' -f $subscriptionId, $ResourceGroup, $Name, $Action, (Get-DemoPinnedApiVersion -ResourceType 'Microsoft.Fabric/capacities')
    $sent = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'post', '--url', $url) -AllowFailure
    if ($sent.ExitCode -ne 0) {
        return [pscustomobject]@{ Accepted = $false; State = ''; Seconds = [int]$watch.Elapsed.TotalSeconds; Error = (Get-DemoDeploymentErrorText -Text ([string]$sent.StdErr) -MaxLength 400) }
    }
    $state = ''
    while ($true) {
        $read = Get-DemoFabricCapacityResource -Config $Config -ResourceGroup $ResourceGroup -Name $Name
        $state = [string]$read.State
        if ($state -eq $target -or $watch.Elapsed.TotalSeconds -ge $WaitSeconds) {
            break
        }
        Start-Sleep -Seconds $PollSeconds
    }
    return [pscustomobject]@{ Accepted = $true; State = $state; Seconds = [int]$watch.Elapsed.TotalSeconds; Error = '' }
}

function Resume-DemoFabricCapacity {
    <#
    .SYNOPSIS
    start-demo.ps1's opt-in capacity step (fabric.manageCapacity): resumes the capacity in fabric.capacityName when it's
    Paused, and records it in the DbHubFabricCapacityResumed tag (START.FABRIC.CAPACITY). Internal.

    .DESCRIPTION
    - manageCapacity false (default): Not selected, and the capacity isn't called.
    - No capacityName: Manual action required.
    - Not an F capacity in the configured subscription (a Trial capacity, or one elsewhere): Not supported.
    - Paused: resumed (Fabric Capacities - Resume), and the record written once Azure accepted it, before the wait,
      so a stop that follows pauses it. Pass when it's Active within the wait; a Warning otherwise.
    - Active: Pass, untouched; stop-demo.ps1 pauses it only when the record says the demo resumed it.
    - Any other state: a Warning, untouched.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State,

        [ValidateRange(0, 1800)]
        [int] $WaitSeconds = 600
    )

    $checkId = 'START.FABRIC.CAPACITY'
    $doc = $script:FabricCapacityDoc
    $setting = Get-DemoFabricCapacitySetting -Config $Config
    $result = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '', [string] $DocUrl = $doc['Resume'])
        New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl
    }
    if (-not $setting.ManageCapacity) {
        return (& $result 'Not selected' 'fabric.manageCapacity is false, so the Fabric capacity was left as it is: its administrator resumes and pauses it.' @{} '' $doc['PauseResume'])
    }
    if (-not $setting.CapacityName) {
        return (& $result 'Manual action required' 'fabric.manageCapacity is true, but fabric.capacityName isn''t set, so there''s no capacity to resume.' @{} 'Set fabric.capacityName to your F capacity (init.ps1 writes it), or set fabric.manageCapacity to false.')
    }
    $found = Find-DemoFabricCapacityResource -Config $Config -Name $setting.CapacityName
    if (-not $found.Succeeded) {
        return (& $result 'Warning' ('The Fabric capacities in the subscription couldn''t be listed, so "{0}" wasn''t resumed: {1}' -f $setting.CapacityName, $found.Error) @{} 'Resume it yourself if the notebooks, the dashboard, or the reports are needed (Azure portal > the Fabric capacity > Resume).' $doc['ListBySub'])
    }
    $candidates = @($found.Items)
    if ($candidates.Count -eq 0) {
        return (& $result 'Not supported' ('"{0}" isn''t an F capacity in the configured subscription (a Trial capacity isn''t an Azure resource, and one in another subscription is out of the scripts'' reach), so fabric.manageCapacity can''t resume it.' -f $setting.CapacityName) @{ capacityName = $setting.CapacityName } 'Its administrator resumes and pauses it; set fabric.manageCapacity to false.' $doc['Trial'])
    }
    if ($candidates.Count -gt 1) {
        return (& $result 'Manual action required' ('More than one Fabric capacity in the subscription is named "{0}".' -f $setting.CapacityName) @{} 'Resume the right one yourself, or set fabric.manageCapacity to false.' $doc['ListBySub'])
    }
    $capacity = $candidates[0]
    $record = Get-DemoFabricCapacityRecord -State $State
    $ours = $null -ne $record -and $record.Name -ieq $capacity.Name -and $record.ResourceGroup -ieq $capacity.ResourceGroup
    $evidence = [ordered]@{ capacityName = $capacity.Name; resourceGroup = $capacity.ResourceGroup; sku = $capacity.Sku; stateBefore = $capacity.State; recorded = $ours }
    switch ($capacity.State) {
        'Active' {
            $message = if ($ours) { 'The Fabric capacity "{0}" ({1}) is Active; the demo resumed it at {2}, so stop-demo.ps1 pauses it.' -f $capacity.Name, $capacity.Sku, $record.ResumedUtc } else { 'The Fabric capacity "{0}" ({1}) is already Active. The demo didn''t resume it, so stop-demo.ps1 leaves it running.' -f $capacity.Name, $capacity.Sku }
            return (& $result 'Pass' $message $evidence)
        }
        'Paused' {
            if (-not $PSCmdlet.ShouldProcess(('Fabric capacity {0}' -f $capacity.Name), 'Resume')) {
                return (& $result 'Not selected' ('What if: the Paused Fabric capacity "{0}" would be resumed and recorded for stop-demo.ps1.' -f $capacity.Name) $evidence)
            }
            $transition = Invoke-DemoFabricCapacityTransition -Config $Config -ResourceGroup $capacity.ResourceGroup -Name $capacity.Name -Action resume -WaitSeconds $WaitSeconds -Confirm:$false
            if (-not $transition.Accepted) {
                return (& $result 'Warning' ('The Paused Fabric capacity "{0}" couldn''t be resumed: {1}' -f $capacity.Name, $transition.Error) $evidence 'Resuming needs Contributor on the capacity (Microsoft.Fabric/capacities/resume/action); its administrator can resume it in the Azure portal.')
            }
            $stamp = [System.DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
            $evidence['stateAfter'] = $transition.State
            $evidence['seconds'] = $transition.Seconds
            try {
                Set-DemoDeploymentState -Config $Config -Value @{ FabricCapacityResumed = ('{0}/{1}' -f $capacity.ResourceGroup, $capacity.Name); FabricCapacityResumedUtc = $stamp } -Confirm:$false
            }
            catch {
                return (& $result 'Warning' ('The Fabric capacity "{0}" was resumed, but the record for stop-demo.ps1 couldn''t be written, so stop-demo.ps1 won''t pause it: {1}' -f $capacity.Name, (Protect-DemoText -Text $_.Exception.Message)) $evidence 'Pause it yourself after the session (Azure portal > the Fabric capacity > Pause).' $doc['PauseResume'])
            }
            if ($transition.State -eq 'Active') {
                return (& $result 'Pass' ('Resumed the Fabric capacity "{0}" ({1}) in {2} s; stop-demo.ps1 pauses it again (resource group tag DbHubFabricCapacityResumed). It bills while it runs.' -f $capacity.Name, $capacity.Sku, $transition.Seconds) $evidence)
            }
            return (& $result 'Warning' ('Asked to resume the Fabric capacity "{0}"; it''s {1} after {2} s. stop-demo.ps1 pauses it.' -f $capacity.Name, $(if ($transition.State) { $transition.State } else { 'in an unknown state' }), $transition.Seconds) $evidence 'Check it in a few minutes (status.ps1 shows it); the notebooks need it Active.')
        }
        default {
            return (& $result 'Warning' ('The Fabric capacity "{0}" is {1}, so it was left alone.' -f $capacity.Name, $(if ($capacity.State) { $capacity.State } else { 'in an unknown state' })) $evidence 'Run start-demo.ps1 again once it''s Active or Paused, or ask its administrator.' $doc['PauseResume'])
        }
    }
}

function Suspend-DemoFabricCapacity {
    <#
    .SYNOPSIS
    stop-demo.ps1's and destroy.ps1's opt-in capacity step: pauses only the capacity that the DbHubFabricCapacityResumed
    tag records, then clears the record (<CheckPrefix>.FABRIC.CAPACITY). Internal.

    .DESCRIPTION
    - manageCapacity false: Not selected, and the capacity isn't called; a record left from earlier is a Warning, still
      without a call.
    - No record: Pass; the demo didn't resume a capacity, so none is paused.
    - Recorded and Active: paused (Fabric Capacities - Suspend); Pass once it's Paused, and the record is cleared. A
      Warning when it isn't Paused within the wait; the record stays, so the next stop tries again.
    - Recorded and already Paused (a stale record): the record is cleared; Pass.
    - Recorded but gone: the record is cleared; a Warning.
    - Can't be read or paused: a Warning with the steps; the record stays.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State,

        [ValidateSet('STOP', 'DESTROY')]
        [string] $CheckPrefix = 'STOP',

        [ValidateRange(0, 1800)]
        [int] $WaitSeconds = 600
    )

    $checkId = '{0}.FABRIC.CAPACITY' -f $CheckPrefix
    $doc = $script:FabricCapacityDoc
    $setting = Get-DemoFabricCapacitySetting -Config $Config
    $result = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '', [string] $DocUrl = $doc['Suspend'])
        New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl
    }
    $clear = {
        Set-DemoDeploymentState -Config $Config -Value @{ FabricCapacityResumed = ''; FabricCapacityResumedUtc = '' } -Confirm:$false
    }
    if ($null -eq $State -and $setting.ManageCapacity) {
        $State = Get-DemoDeploymentState -Config $Config
    }
    $record = Get-DemoFabricCapacityRecord -State $State
    if (-not $setting.ManageCapacity) {
        if ($null -ne $record) {
            return (& $result 'Warning' ('The demo recorded that it resumed the Fabric capacity "{0}" at {1}, but fabric.manageCapacity is false now, so it wasn''t paused.' -f $record.Name, $record.ResumedUtc) @{ capacityName = $record.Name } 'Pause it yourself if nothing else needs it (Azure portal > the Fabric capacity > Pause), or set fabric.manageCapacity to true and run stop-demo.ps1 again.' $doc['PauseResume'])
        }
        return (& $result 'Not selected' 'fabric.manageCapacity is false, so the Fabric capacity was left as it is: its administrator pauses it.' @{} '' $doc['PauseResume'])
    }
    if ($null -eq $record) {
        return (& $result 'Pass' 'The demo didn''t resume a Fabric capacity (no DbHubFabricCapacityResumed record), so none was paused.' @{} '' $doc['PauseResume'])
    }
    $evidence = [ordered]@{ capacityName = $record.Name; resourceGroup = $record.ResourceGroup; resumedUtc = $record.ResumedUtc }
    $read = Get-DemoFabricCapacityResource -Config $Config -ResourceGroup $record.ResourceGroup -Name $record.Name
    if (-not $read.Found -and $read.Missing) {
        try { & $clear } catch { Write-DemoLog -Level Warning -Message ('The capacity record couldn''t be cleared: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) }
        return (& $result 'Warning' ('The Fabric capacity "{0}" that the demo resumed no longer exists in {1}; its record was cleared.' -f $record.Name, $record.ResourceGroup) $evidence '' $doc['Get'])
    }
    if (-not $read.Found) {
        return (& $result 'Warning' ('The Fabric capacity "{0}" that the demo resumed couldn''t be read, so it wasn''t paused: {1}' -f $record.Name, $read.Error) $evidence 'Pause it yourself (Azure portal > the Fabric capacity > Pause), or run stop-demo.ps1 again.' $doc['PauseResume'])
    }
    $evidence['stateBefore'] = $read.State
    $evidence['sku'] = $read.Sku
    if ($read.State -in 'Paused', 'Suspended') {
        try { & $clear } catch { Write-DemoLog -Level Warning -Message ('The capacity record couldn''t be cleared: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) }
        return (& $result 'Pass' ('The Fabric capacity "{0}" is already {1}; the demo''s stale record of resuming it was cleared.' -f $record.Name, $read.State) $evidence '' $doc['PauseResume'])
    }
    if ($read.State -ne 'Active') {
        return (& $result 'Warning' ('The Fabric capacity "{0}" that the demo resumed is {1}, so it wasn''t paused now.' -f $record.Name, $(if ($read.State) { $read.State } else { 'in an unknown state' })) $evidence 'Run stop-demo.ps1 again in a few minutes (status.ps1 shows its state), or pause it yourself in the Azure portal.' $doc['PauseResume'])
    }
    if (-not $PSCmdlet.ShouldProcess(('Fabric capacity {0}' -f $record.Name), 'Pause')) {
        return (& $result 'Not selected' ('What if: the Fabric capacity "{0}", which the demo resumed, would be paused.' -f $record.Name) $evidence)
    }
    $transition = Invoke-DemoFabricCapacityTransition -Config $Config -ResourceGroup $record.ResourceGroup -Name $record.Name -Action suspend -WaitSeconds $WaitSeconds -Confirm:$false
    $evidence['stateAfter'] = $transition.State
    $evidence['seconds'] = $transition.Seconds
    $lost = if ($CheckPrefix -eq 'DESTROY') { ' The record goes with the resource group, so pause it yourself.' } else { '' }
    if (-not $transition.Accepted) {
        return (& $result 'Warning' ('The Fabric capacity "{0}" couldn''t be paused, and it bills while it runs: {1}.{2}' -f $record.Name, $transition.Error, $lost) $evidence 'Pause it in the Azure portal (the Fabric capacity > Pause), or run stop-demo.ps1 again; pausing needs Contributor on the capacity.' $doc['PauseResume'])
    }
    if ($transition.State -ne 'Paused') {
        return (& $result 'Warning' ('Asked to pause the Fabric capacity "{0}"; it''s {1} after {2} s.{3}' -f $record.Name, $(if ($transition.State) { $transition.State } else { 'in an unknown state' }), $transition.Seconds, $lost) $evidence 'Check it in a few minutes; run stop-demo.ps1 again if it''s still running.' $doc['PauseResume'])
    }
    try {
        & $clear
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The capacity record couldn''t be cleared: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    return (& $result 'Pass' ('Paused the Fabric capacity "{0}" ({1}) that start-demo.ps1 resumed, in {2} s, and cleared the record.' -f $record.Name, $read.Sku, $transition.Seconds) $evidence)
}

function Get-DemoFabricCapacityStatus {
    <#
    .SYNOPSIS
    status.ps1's view of fabric.manageCapacity (STATUS.FABRIC.CAPACITY): the capacity's state and the
    DbHubFabricCapacityResumed record. Read-only: it changes nothing, not even a stale record. $null with
    manageCapacity false and no record. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State
    )

    $doc = $script:FabricCapacityDoc
    $setting = Get-DemoFabricCapacitySetting -Config $Config
    $record = Get-DemoFabricCapacityRecord -State $State
    if (-not $setting.ManageCapacity -and $null -eq $record) {
        return $null
    }
    $result = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '')
        New-DemoResult -CheckId 'STATUS.FABRIC.CAPACITY' -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $doc['PauseResume']
    }
    if (-not $setting.ManageCapacity) {
        return (& $result 'Warning' ('The tag DbHubFabricCapacityResumed records that the demo resumed the Fabric capacity "{0}" at {1}, but fabric.manageCapacity is false, so stop-demo.ps1 won''t pause it.' -f $record.Name, $record.ResumedUtc) @{ capacityName = $record.Name; resumedUtc = $record.ResumedUtc } 'Pause it yourself when nothing needs it, or set fabric.manageCapacity to true.')
    }
    $name = if ($null -ne $record) { $record.Name } else { $setting.CapacityName }
    $read = $null
    if ($null -ne $record) {
        $read = Get-DemoFabricCapacityResource -Config $Config -ResourceGroup $record.ResourceGroup -Name $record.Name
    }
    elseif ($name) {
        $found = Find-DemoFabricCapacityResource -Config $Config -Name $name
        if ($found.Succeeded -and @($found.Items).Count -eq 1) {
            $read = [pscustomobject]@{ Found = $true; Missing = $false; State = @($found.Items)[0].State; Sku = @($found.Items)[0].Sku; Error = '' }
        }
        elseif ($found.Succeeded) {
            return (& $result 'Not supported' ('"{0}" isn''t a single F capacity in the configured subscription, so fabric.manageCapacity can''t manage it.' -f $name) @{ capacityName = $name } 'Set fabric.manageCapacity to false; its administrator resumes and pauses it.')
        }
    }
    else {
        return (& $result 'Manual action required' 'fabric.manageCapacity is true, but fabric.capacityName isn''t set.' @{} 'Set fabric.capacityName, or fabric.manageCapacity to false.')
    }
    $evidence = [ordered]@{ capacityName = $name; recorded = ($null -ne $record); resumedUtc = $(if ($record) { $record.ResumedUtc } else { '' }); state = $(if ($read) { $read.State } else { '' }) }
    if ($null -eq $read -or -not $read.Found) {
        return (& $result 'Warning' ('The Fabric capacity "{0}" couldn''t be read{1}.' -f $name, $(if ($read -and $read.Error) { ': ' + $read.Error } else { '' })) $evidence 'Run status.ps1 again; check the capacity in the Azure portal.')
    }
    if ($null -ne $record -and $read.State -eq 'Active') {
        return (& $result 'Pass' ('The Fabric capacity "{0}" is Active: the demo resumed it at {1} (tag DbHubFabricCapacityResumed), and stop-demo.ps1 pauses it. It bills while it runs.' -f $name, $record.ResumedUtc) $evidence)
    }
    if ($null -ne $record) {
        return (& $result 'Pass' ('The Fabric capacity "{0}" is {1}; the record that the demo resumed it is stale, and the next stop-demo.ps1 clears it.' -f $name, $read.State) $evidence)
    }
    $next = if ($read.State -eq 'Paused') { 'start-demo.ps1 resumes it' } else { 'the demo didn''t resume it, so stop-demo.ps1 leaves it running' }
    return (& $result 'Pass' ('The Fabric capacity "{0}" is {1}; {2} (fabric.manageCapacity).' -f $name, $read.State, $next) $evidence)
}

function Save-DemoFabricHistory {
    <#
    .SYNOPSIS
    stop-demo.ps1 -SaveHistory (or fabric.saveHistoryOnStop): runs NB_DatabaseHub_LiveActivity on demand to save the
    session's history to the lakehouse, at most -TimeoutMinutes, before any pause (STOP.FABRIC.SAVEHISTORY). Internal.

    .DESCRIPTION
    The workspace and lakehouse are resolved by name, read-only (Resolve-DemoFabricConfig without -Create). A capacity
    that isn't running is Manual action required (FABRIC.P5.CAPACITY). The run (Invoke-DemoFabricNotebookRun) uses the
    notebook's safe switches: SAVE_RESULTS true, CONFIRM and STOP_ACTIVITY false, no Key Vault, so it writes only the
    lakehouse's history tables. Returns Result and StillRunning (the run hadn't finished when the wait ended, so the
    capacity mustn't be paused under it).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(15, 10080)]
        [int] $WindowMinutes = 720,

        [ValidateRange(1, 15)]
        [int] $TimeoutMinutes = 15
    )

    $checkId = 'STOP.FABRIC.SAVEHISTORY'
    $doc = $script:FabricCapacityDoc
    $answer = {
        param([string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence = @{}, [string] $Remediation = '', [bool] $StillRunning = $false)
        [pscustomobject]@{
            Result       = (New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $doc['NotebookRun'])
            StillRunning = $StillRunning
        }
    }
    $manualRun = 'In Fabric, open NB_DatabaseHub_LiveActivity in the demo''s workspace and select Run all (with the defaults it writes only the lakehouse''s history tables).'
    try {
        $token = Get-DemoFabricToken -SubscriptionId ([string]$Config['subscriptionId'])
    }
    catch {
        return (& $answer 'Manual action required' ('The session''s history wasn''t saved: no Fabric token ({0}).' -f (Protect-DemoText -Text $_.Exception.Message)) @{} $manualRun)
    }
    $resolution = Resolve-DemoFabricConfig -Config $Config -Token $token
    if (-not $resolution.Resolved) {
        $why = (@($resolution.Results | Where-Object { $_.status -ne 'Pass' -and $_.status -ne 'Not selected' } | ForEach-Object { '{0}: {1}' -f $_.checkId, $_.message }) -join ' ')
        return (& $answer 'Manual action required' ('The session''s history wasn''t saved: the Fabric workspace or lakehouse isn''t resolved. {0}' -f $why).Trim() @{} 'Run ./scripts/configure-fabric.ps1 (it creates what''s missing), then the notebook.')
    }
    $resolved = $resolution.Config
    $capacity = @(Test-DemoFabricWorkspace -Config $resolved -Token $token | Where-Object { $_.checkId -eq 'FABRIC.P5.CAPACITY' }) | Select-Object -First 1
    $capacityState = if ($capacity) { [string](Get-DemoMemberValue -InputObject $capacity.evidence -Name 'state') } else { '' }
    if ($capacity -and $capacity.status -eq 'Manual action required' -and $capacityState -and $capacityState -ine 'Active') {
        return (& $answer 'Manual action required' ('The session''s history wasn''t saved: the workspace''s capacity is {0}, so notebooks can''t run.' -f $capacityState) @{ capacityState = $capacityState } ('Resume the capacity (or set fabric.manageCapacity for a capacity that''s yours alone, so start-demo.ps1 resumes it), then: {0}' -f $manualRun))
    }
    $parameters = [ordered]@{
        CONFIRM        = $false
        STOP_ACTIVITY  = $false
        SAVE_RESULTS   = $true
        WINDOW_MINUTES = $WindowMinutes
        KEY_VAULT_URL  = ''
        RESOURCE_GROUP = (Get-DemoResourceGroupName -Config $Config)
    }
    $run = Invoke-DemoFabricNotebookRun -Config $resolved -Name 'NB_DatabaseHub_LiveActivity' -Parameter $parameters -Token $token -TimeoutMinutes $TimeoutMinutes
    $jobStatus = [string](Get-DemoMemberValue -InputObject $run.evidence -Name 'status')
    $stillRunning = $run.status -eq 'Warning' -and $jobStatus -notin 'Completed', 'Failed', 'Cancelled', 'Deduped', ''
    $evidence = [ordered]@{ windowMinutes = $WindowMinutes; jobStatus = $jobStatus; seconds = (Get-DemoMemberValue -InputObject $run.evidence -Name 'seconds') }
    if ($run.status -eq 'Pass') {
        return (& $answer 'Pass' ('Saved the session''s history: NB_DatabaseHub_LiveActivity ran on demand over the last {0} minutes. {1}' -f $WindowMinutes, $run.message) $evidence)
    }
    if ($stillRunning) {
        return (& $answer 'Warning' ('The history run was still {0} after {1} minutes; it keeps running in Fabric, so the capacity wasn''t paused under it.' -f $jobStatus, $TimeoutMinutes) $evidence 'Check the run in the workspace (Monitor hub); once it''s done, run stop-demo.ps1 again to pause the capacity the demo resumed.' $true)
    }
    return (& $answer $run.status ('The session''s history: {0}' -f $run.message) $evidence $(if ($run.remediation) { $run.remediation } else { $manualRun }))
}
