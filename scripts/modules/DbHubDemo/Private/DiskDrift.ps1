function Get-DemoVmDiskDrift {
    <#
    .SYNOPSIS
    The existing demo VMs' managed disks whose storage type differs from what the template declares for them:
    the profile's OS disk tier, and the data disk tier for <vm>-data01. Internal.

    .DESCRIPTION
    Reads each VM's storage profile with 'az vm show' (Virtual Machines - Get, a read), where every attached
    managed disk of a running VM carries its current storage type. A deallocated VM's model omits it (live,
    2026-10-26), so then the disk itself is read ('az disk show', Disks - Get). The subscription's automation
    was seen switching both demo VMs' OS disks to Standard HDD while they were deallocated (2026-10-24), and
    Azure doesn't change an OS disk's type through its VM (OperationNotAllowed), so Invoke-DemoTemplateDeployment
    passes each drifted disk's current type to the template (diskSkuOverrides) and keeps it, and
    Get-DemoEnvironmentStatus reports the drift (STATUS.DISKS). Nothing here changes a disk.

    Returns VmName, DiskName, Kind (OS or Data), Current, Expected, and TemplateSetsType (false for an OS disk
    attached by ID, a golden host's, whose type the template never sets). A VM that can't be read is skipped.
    Sources: https://learn.microsoft.com/cli/azure/vm#az-vm-show,
    https://learn.microsoft.com/cli/azure/disk#az-disk-show,
    https://learn.microsoft.com/azure/virtual-machines/disks-convert-types
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('sqlvm01', 'archost01', 'arcsql01')]
        [string[]] $VmName = @()
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = Get-DemoResourceGroupName -Config $Config
    $catalog = Get-DemoProfile
    $profileName = if ($Config['profile']) { [string]$Config['profile'] } else { 'lowest-cost' }
    $sizing = $catalog.profiles[$profileName]
    $tiers = $catalog.diskTiers
    $zone = if ($Config.Contains('zone') -and $Config['zone']) { [string]$Config['zone'] } else { '' }
    $override = Get-DemoDataDiskOverride -Config $Config
    $drift = [System.Collections.Generic.List[object]]::new()
    $diskType = {
        param([object] $Disk)
        $type = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Disk -Name 'managedDisk') -Name 'storageAccountType')
        $diskName = [string](Get-DemoMemberValue -InputObject $Disk -Name 'name')
        if ($type -or -not $diskName) {
            return $type
        }
        $show = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('disk', 'show', '--resource-group', $resourceGroupName, '--name', $diskName, '--query', 'sku.name', '--output', 'tsv') -AllowFailure
        if ($show.ExitCode -ne 0) {
            Write-DemoLog -Level Warning -Message ('{0}: its storage type couldn''t be read, so it wasn''t compared with the profile.' -f $diskName)
            return ''
        }
        return ([string]$show.StdOut).Trim()
    }
    foreach ($vm in @($VmName)) {
        $role = if ($vm -eq 'sqlvm01') { 't1' } else { 't2Host' }
        # The evaluation-only T2 VM (arcsql01) never has a data disk (infra/modules/demo.bicep).
        $dataTier = if ($vm -eq 'arcsql01') { 'None' } else { Resolve-DemoDataDiskTier -VmSizing $sizing[$role] -Zone $zone -Override $override }
        $read = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'show', '--resource-group', $resourceGroupName, '--name', $vm, '--query', 'storageProfile', '--output', 'json') -AllowFailure
        if ($read.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
            Write-DemoLog -Level Warning -Message ('{0}: its storage profile couldn''t be read, so its disks weren''t compared with the profile.' -f $vm)
            continue
        }
        $storage = $null
        try {
            $storage = [string]$read.StdOut | ConvertFrom-Json -Depth 32
        }
        catch {
            Write-DemoLog -Level Warning -Message ('{0}: its storage profile wasn''t readable JSON, so its disks weren''t compared with the profile.' -f $vm)
            continue
        }
        $osDisk = Get-DemoMemberValue -InputObject $storage -Name 'osDisk'
        $osCurrent = & $diskType $osDisk
        $osExpected = [string]$tiers[[string]$sizing[$role].osDisk].sku
        if ($osCurrent -and $osExpected -and $osCurrent -ne $osExpected) {
            $drift.Add([pscustomobject]@{
                    VmName           = $vm
                    DiskName         = [string](Get-DemoMemberValue -InputObject $osDisk -Name 'name')
                    Kind             = 'OS'
                    Current          = $osCurrent
                    Expected         = $osExpected
                    TemplateSetsType = ([string](Get-DemoMemberValue -InputObject $osDisk -Name 'createOption') -ne 'Attach')
                })
        }
        if ($dataTier -eq 'None') {
            continue
        }
        $dataExpected = [string]$tiers[$dataTier].sku
        foreach ($dataDisk in (Get-DemoMemberList -InputObject $storage -Name 'dataDisks')) {
            $name = [string](Get-DemoMemberValue -InputObject $dataDisk -Name 'name')
            if ($name -ne ('{0}-data01' -f $vm)) {
                continue
            }
            $current = & $diskType $dataDisk
            if ($current -and $current -ne $dataExpected) {
                $drift.Add([pscustomobject]@{ VmName = $vm; DiskName = $name; Kind = 'Data'; Current = $current; Expected = $dataExpected; TemplateSetsType = $true })
            }
        }
    }
    return $drift.ToArray()
}

function New-DemoDiskDriftResult {
    <#
    The Warning that names each drifted disk (Get-DemoVmDiskDrift), or a Pass when there's none: the deployment
    keeps each disk's current type and carries on, and the demo runs slower on Standard HDD. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $CheckId,

        [AllowEmptyCollection()]
        [object[]] $Drift = @(),

        [string[]] $VmName = @()
    )

    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/disks-convert-types'
    if (@($Drift).Count -eq 0) {
        return (New-DemoResult -CheckId $CheckId -Area 'infra' -Target 'subscription' -Status 'Pass' -Message ('The disks of {0} have the profile''s storage types.' -f $(if ($VmName) { $VmName -join ' and ' } else { 'the demo VMs' })) -Evidence ([ordered]@{ vms = @($VmName) }) -DocUrl $docUrl)
    }
    $parts = @($Drift | ForEach-Object { '{0} ({1}''s {2} disk) is {3}, not the profile''s {4}' -f $_.DiskName, $_.VmName, $(if ($_.Kind -eq 'OS') { 'OS' } else { 'data' }), $_.Current, $_.Expected })
    $message = '{0}. The subscription''s automation can switch a deallocated VM''s disks to another type, such as Standard HDD (seen 2026-10-24), and Azure doesn''t change an OS disk''s type through its VM, so the deployment keeps each disk''s current type and carries on. On Standard HDD, boots and IO are slower, and IO-heavy scenarios look worse than the profile intends.' -f ($parts -join '; ')
    $evidence = [ordered]@{ disks = @($Drift | ForEach-Object { [ordered]@{ vm = $_.VmName; disk = $_.DiskName; kind = $_.Kind; current = $_.Current; expected = $_.Expected; templateSetsType = [bool]$_.TemplateSetsType } }) }
    $remediation = 'Nothing to do for the deployment. Whether to change a disk back (only while its VM is deallocated) is the subscription owner''s call, because the automation can switch it again.'
    return (New-DemoResult -CheckId $CheckId -Area 'infra' -Target 'subscription' -Status 'Warning' -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
}
