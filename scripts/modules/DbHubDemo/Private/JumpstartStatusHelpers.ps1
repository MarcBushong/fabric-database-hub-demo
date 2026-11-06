function Get-DemoT2DiskSpaceResult {
    <#
    .SYNOPSIS
    STATUS.T2.DISKSPACE for status.ps1 while archost01 runs (2026-11-05): free space on the drive that holds the guest's
    disk, from the health summary (Get-DemoVmHealth). The Jumpstart image's disk is dynamic with a 100 GiB maximum, and
    the lowest-cost host's 128 GiB OS disk holds it, so the deploy checks the realistic need (the image plus a growth
    allowance) and this warns early instead (user decision, 2026-11-05). $null when the health has no storage figures.
    Internal and pure.

    .DESCRIPTION
    Pass with the free space; a Warning below the host's threshold (vm/dsc/host.psd1 Storage.LowSpaceWarningGB), with
    what to do: a full drive pauses the guest (Hyper-V pauses a VM whose dynamic disk can't grow), which loses nothing
    and resumes once space is freed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Health
    )

    $free = Get-DemoMemberValue -InputObject $Health -Name 'storageFreeGiB'
    if ($null -eq $free -or (Get-DemoHostVmName -Config $Config) -ne 'archost01') {
        return $null
    }
    $drive = [string](Get-DemoMemberValue -InputObject $Health -Name 'storageDrive')
    $warn = Get-DemoMemberValue -InputObject $Health -Name 'storageWarnGiB'
    $evidence = [ordered]@{ drive = $drive; freeGiB = $free; warnBelowGiB = $warn }
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/windows/expand-os-disk'
    if ([bool](Get-DemoMemberValue -InputObject $Health -Name 'storageLow')) {
        return (New-DemoResult -CheckId 'STATUS.T2.DISKSPACE' -Area 't2' -Target 'T2' -Status 'Warning' -Message ('archost01 has {0} GiB free on {1}, below {2} GiB. The guest''s dynamic disk grows into that space; if the drive fills, Hyper-V pauses the guest until space is freed (nothing is lost).' -f $free, $drive, $warn) -Evidence $evidence -Remediation 'Rebuild T2 to start from a fresh disk (./scripts/destroy.ps1, then ./scripts/deploy.ps1), or expand archost01''s OS disk in the Azure portal and extend C: in Windows. A profile with a data disk (dataDiskSku E10) gives the guest its own drive.' -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId 'STATUS.T2.DISKSPACE' -Area 't2' -Target 'T2' -Status 'Pass' -Message ('archost01 has {0} GiB free on {1} for the guest''s disk to grow.' -f $free, $drive) -Evidence $evidence -DocUrl $docUrl)
}

function Get-DemoT2ImageResult {
    <#
    .SYNOPSIS
    STATUS.T2.IMAGE for status.ps1 while archost01 runs, in JumpstartImage mode (2026-11-05): which Arc Jumpstart image
    the guest came from, from the health summary. Pass for the image this repository was tested with
    (config/versions.json media.jumpstartArcBoxSqlStd); a Warning that names a newer one, which the host used only after
    the guest passed the image checks (user decision, 2026-11-05). $null outside JumpstartImage mode or before the image
    is in place. Internal and pure.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Health
    )

    $etag = [string](Get-DemoMemberValue -InputObject $Health -Name 'imageEtag')
    if (-not $etag -or [string](Get-DemoMemberValue -InputObject $Health -Name 'installMode') -ne 'JumpstartImage') {
        return $null
    }
    $modified = [string](Get-DemoMemberValue -InputObject $Health -Name 'imageModified')
    $evidence = [ordered]@{ etag = $etag; lastModified = $modified; pinned = [bool](Get-DemoMemberValue -InputObject $Health -Name 'imagePinned') }
    $docUrl = 'https://github.com/Azure/arc_jumpstart_docs/blob/71a945c619f78acb441c6470d76a9b58347169fe/docs/azure_jumpstart_arcbox/ITPro/_index.md'
    if ($evidence['pinned']) {
        return (New-DemoResult -CheckId 'STATUS.T2.IMAGE' -Area 't2' -Target 'T2' -Status 'Pass' -Message ('T2''s guest came from the Arc Jumpstart image this repository was tested with (etag {0}, {1}).' -f $etag, $modified) -Evidence $evidence -DocUrl $docUrl)
    }
    return (New-DemoResult -CheckId 'STATUS.T2.IMAGE' -Area 't2' -Target 'T2' -Status 'Warning' -Message ('T2''s guest came from a newer Arc Jumpstart image (etag {0}, {1}) than the one this repository was tested with. It passed the image checks (SQL Server 2022 Standard on the default instance) before Arc onboarding.' -f $etag, $modified) -Evidence $evidence -Remediation 'Nothing is needed while T2 works. To record it as tested, update media.jumpstartArcBoxSqlStd in config/versions.json after a full deploy passes with it.' -DocUrl $docUrl)
}
