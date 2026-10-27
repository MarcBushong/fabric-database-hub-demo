function Test-DemoSqlVmAssociatedService {
    <#
    .SYNOPSIS
    The read-only T1.SQLVM.ASSOCIATEDSERVICES check: the SQL Server instances unified inventory lists for T1.

    .DESCRIPTION
    Unified inventory gives every SQL Server instance on a registered Azure VM its own SQL Server instance
    resource, associated services included
    (https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/unified-inventory-sql-vm). The SQL
    Server 2022 Standard Marketplace image installs Analysis Services and Integration Services next to the
    database engine, so T1 showed three instance resources: the engine (MSSQLSERVER), SSAS, and SSIS (live
    finding, 2026-10-20). The owner chose the lightest default (2026-10-21), so the T1 bootstrap's
    AssociatedServices step stops, disables, and uninstalls them. This check reads the instances and the SQL
    virtual machine resource, changes nothing, and reports:
    - Pass: only the engine instance is listed.
    - Warning: associated services are still listed (they're named in the message and the evidence), no engine
      instance is listed yet, or the list can't be read. deploy.ps1's validation passes -ListedStatus Fail with
      -WaitMinutes, so a step that didn't converge fails the deployment instead (live, 2026-10-22: the parallel
      path's inventory kept listing them because nothing restarted the SQL IaaS Agent after the uninstall).
    The evidence records each instance's service type, edition, version, and license type, next to the SQL
    virtual machine resource's license type: SQL Server VM features, licensing included, are managed through
    the SQL virtual machines resource, not the instance resource (same page).

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER VmName
    The T1 VM.

    .PARAMETER WaitMinutes
    While associated services are still listed, read inventory again once a minute for up to this many minutes
    (unified inventory dropped them about 6 minutes after the SQL IaaS Agent restarted, live). 0 reads once.

    .PARAMETER ListedStatus
    The status when associated services are still listed after the wait: Warning (the default, for status and
    validate) or Fail (deploy.ps1's validation).

    .EXAMPLE
    Test-DemoSqlVmAssociatedService -Config $config -WaitMinutes 10 -ListedStatus Fail
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $VmName = 'sqlvm01',

        [ValidateRange(0, 60)]
        [int] $WaitMinutes = 0,

        [ValidateSet('Warning', 'Fail')]
        [string] $ListedStatus = 'Warning'
    )

    $checkId = 'T1.SQLVM.ASSOCIATEDSERVICES'
    $docUrl = 'https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/unified-inventory-sql-vm'
    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroupName = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $waited = 0
    for ($poll = 0; $poll -le $WaitMinutes; $poll++) {
        try {
            $instances = @(Get-DemoSqlVmInventoryInstance -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -VmName $VmName)
        }
        catch {
            return (New-DemoResult -CheckId $checkId -Area 't1' -Target 'T1' -Status 'Warning' -Message ('Unified inventory for {0} couldn''t be read: {1}' -f $VmName, $_.Exception.Message) -Remediation 'Check that you can read the resource group (Reader or higher), then run configure-monitoring.ps1 -Target T1 again.' -DocUrl $docUrl)
        }
        $listed = @($instances | Where-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'serviceType') -ne 'Engine' })
        if ($listed.Count -eq 0 -or $poll -ge $WaitMinutes) {
            break
        }
        Write-DemoLog -Message ('Unified inventory still lists {0} associated service(s) for {1}; reading it again in a minute ({2} of {3}).' -f $listed.Count, $VmName, ($poll + 1), $WaitMinutes)
        Start-Sleep -Seconds 60
        $waited++
    }

    $licenseRead = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('sql', 'vm', 'show', '--resource-group', $resourceGroupName, '--name', $VmName, '--query', 'sqlServerLicenseType', '--output', 'tsv') -AllowFailure
    $sqlVmLicenseType = 'Unknown'
    if ($licenseRead.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$licenseRead.StdOut)) {
        $sqlVmLicenseType = ([string]$licenseRead.StdOut).Trim()
    }

    $rows = @(foreach ($instance in $instances) {
            $properties = Get-DemoMemberValue -InputObject $instance -Name 'properties'
            [ordered]@{
                name         = [string](Get-DemoMemberValue -InputObject $instance -Name 'name')
                serviceType  = [string](Get-DemoMemberValue -InputObject $properties -Name 'serviceType')
                instanceName = [string](Get-DemoMemberValue -InputObject $properties -Name 'instanceName')
                edition      = [string](Get-DemoMemberValue -InputObject $properties -Name 'edition')
                version      = [string](Get-DemoMemberValue -InputObject $properties -Name 'version')
                patchLevel   = [string](Get-DemoMemberValue -InputObject $properties -Name 'patchLevel')
                licenseType  = [string](Get-DemoMemberValue -InputObject $properties -Name 'licenseType')
                status       = [string](Get-DemoMemberValue -InputObject $properties -Name 'status')
            }
        })
    $engines = @($rows | Where-Object { $_['serviceType'] -eq 'Engine' })
    $associated = @($rows | Where-Object { $_['serviceType'] -ne 'Engine' } | ForEach-Object { '{0} ({1})' -f $_['serviceType'], $_['instanceName'] })
    $evidence = [ordered]@{
        vmName                       = $VmName
        instances                    = $rows
        engineInstances              = $engines.Count
        associatedServices           = $associated
        sqlVirtualMachineLicenseType = $sqlVmLicenseType
        waitedMinutes                = $waited
    }

    if ($engines.Count -eq 0) {
        $only = ''
        if ($associated.Count -gt 0) {
            $only = ' (it lists only {0})' -f ($associated -join ', ')
        }
        return (New-DemoResult -CheckId $checkId -Area 't1' -Target 'T1' -Status 'Warning' -Message ('Unified inventory lists no database engine instance for {0} yet{1}.' -f $VmName, $only) -Evidence $evidence -Remediation 'Unified inventory discovers instances on its own once the SQL IaaS Agent extension is 2.0.226.0 or later; wait, then run configure-monitoring.ps1 -Target T1 again.' -DocUrl $docUrl)
    }

    $engine = $engines[0]
    $engineText = '{0}, {1} {2}' -f $engine['instanceName'], $engine['edition'], $engine['patchLevel']
    if ($associated.Count -gt 0) {
        $message = 'Unified inventory lists the database engine for {0} ({1}) and {2} associated service(s) that the image installs: {3}. Each is its own SQL Server instance resource; the demo uses only the engine.' -f $VmName, $engineText, $associated.Count, ($associated -join ', ')
        if ($waited -gt 0) {
            $message += ' They were still listed after {0} minute(s) of waiting.' -f $waited
        }
        $remediation = 'The T1 bootstrap''s AssociatedServices step stops, disables, and uninstalls them (owner decision 2026-10-21), then restarts the SQL IaaS Agent service so unified inventory drops them (about 6 minutes later, live). Check health.json and the bootstrap log on {0} for the step''s warnings, then run deploy.ps1 -FromStage Artifacts: a VM with an older bundle gets the current one, whose step converges a VM whose features are already gone.' -f $VmName
        return (New-DemoResult -CheckId $checkId -Area 't1' -Target 'T1' -Status $ListedStatus -Message $message -Evidence $evidence -Remediation $remediation -DocUrl $docUrl)
    }
    $message = 'Unified inventory lists only the database engine for {0} ({1}).' -f $VmName, $engineText
    return (New-DemoResult -CheckId $checkId -Area 't1' -Target 'T1' -Status 'Pass' -Message $message -Evidence $evidence -DocUrl $docUrl)
}
