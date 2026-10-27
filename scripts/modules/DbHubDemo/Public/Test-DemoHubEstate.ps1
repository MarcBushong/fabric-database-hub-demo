function Test-DemoHubEstate {
    <#
    .SYNOPSIS
    Checks that each selected target is in Azure Resource Graph, the inventory source of the Database Hub
    Overview and Estate pages (HUB.ESTATE.T1, HUB.ESTATE.T2, HUB.ESTATE.T3, HUB.ESTATE.T4).

    .DESCRIPTION
    The Database Hub discovers SQL resources through Azure Resource Graph
    (https://learn.microsoft.com/fabric/database/hub/overview, checked 2026-10-20) and has no API of its own,
    so this check queries Resource Graph through its documented Resources API with the
    ResourceGraph.Estate template. Seeing the target on the Estate page itself stays a manual check.
    - T1: the SQL virtual machine resource sqlvm01, which the SQL IaaS Agent extension registration
      creates. The VM without it is a Fail.
    - T2: an Arc SQL Server instance on the Arc machine arcsql01 (named arcsql01 or arcsql01_<instance>).
      The machine without an instance is Manual action required in PaygWizard mode (the setup-wizard step
      is pending) and a Warning otherwise (the Azure extension for SQL Server hasn't reported it yet); no
      machine is a Fail.
    - T3: the database ContosoCare on azuresql01-<deploymentId>. When the resource group has no deploymentId
      tag, a single azuresql01-* server in Resource Graph is used.
    - T4: the Azure Database for PostgreSQL flexible server pgflex01-<deploymentId> (Phase 24, ADR 0019). The
      Estate lists flexible servers, not their databases, and the Hub discovers them from Microsoft Entra ID
      and Azure RBAC with Reader on the subscription; no extended property, Arc onboarding, or extra resource
      provider is needed (https://learn.microsoft.com/fabric/database/hub/monitor-postgresql, checked
      2026-10-23). A stopped server is still listed. T4 turned off (t4Enabled false) is Not selected.
    Targets not in -Target are Not selected.

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Target
    Targets to check.

    .PARAMETER DeploymentId
    The deploymentId in T3's server name. Read from the resource group's deploymentId tag when omitted.

    .EXAMPLE
    Test-DemoHubEstate -Config $config
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateSet('T1', 'T2', 'T3', 'T4')]
        [string[]] $Target = @('T1', 'T2', 'T3', 'T4'),

        [AllowEmptyString()]
        [string] $DeploymentId = ''
    )

    $docUrl = 'https://learn.microsoft.com/fabric/database/hub/overview'
    $evaluationOnly = [string]$Config['t2Mode'] -eq 'EvaluationOnlyAzureVm'
    $installMode = if ($Config['t2SqlInstallMode']) { [string]$Config['t2SqlInstallMode'] } else { 'PaygWizard' }
    $manualCheck = 'Seeing it on the Hub Estate page is a manual check.'
    $byTarget = [ordered]@{ T1 = $null; T2 = $null; T3 = $null; T4 = $null }
    if ('T4' -in $Target -and -not (Test-DemoT4Enabled -Config $Config)) {
        $Target = @($Target | Where-Object { $_ -ne 'T4' })
        $byTarget['T4'] = New-DemoResult -CheckId 'HUB.ESTATE.T4' -Area 'hub' -Target 'T4' -Status 'Not selected' -Message 'T4 is off in this configuration (t4Enabled is false).'
    }
    function Add-TargetResult([string] $Name, [string] $Status, [string] $Message, [System.Collections.IDictionary] $Evidence, [string] $Remediation = '') {
        $byTarget[$Name] = New-DemoResult -CheckId ('HUB.ESTATE.{0}' -f $Name) -Area 'hub' -Target $Name -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl -EvaluationOnly:($Name -eq 'T2' -and $evaluationOnly)
    }
    function Get-RowValue([object] $Row, [string] $Name) {
        [string](Get-DemoMemberValue -InputObject $Row -Name $Name)
    }

    foreach ($name in @($byTarget.Keys)) {
        if ($name -notin $Target -and $null -eq $byTarget[$name]) {
            Add-TargetResult $name 'Not selected' ('{0} was not selected for this Estate check.' -f $name) @{}
        }
    }
    if ($Target.Count -eq 0) {
        return @($byTarget.Values)
    }

    $resolved = Resolve-DemoHubTarget -Config $Config -DeploymentId $DeploymentId -NeedT3:('T3' -in $Target -or 'T4' -in $Target)
    $query = Format-DemoKqlTemplate -Name 'ResourceGraph.Estate' -Parameters @{
        SubscriptionId = ConvertTo-DemoKqlLiteral -Value $resolved.SubscriptionId -Type String
        ResourceGroup  = ConvertTo-DemoKqlLiteral -Value $resolved.ResourceGroup -Type String
    }
    $graph = Invoke-DemoHubResourceGraph -SubscriptionId $resolved.SubscriptionId -Query $query
    if (-not $graph.Succeeded) {
        foreach ($name in $Target) {
            Add-TargetResult $name 'Fail' ('Azure Resource Graph, the Hub''s inventory source, could not be queried for {0}: {1}' -f $name, $graph.Error) @{ resourceGroup = $resolved.ResourceGroup } 'Check that you can read the subscription (Reader or higher) and run again.'
        }
        return @($byTarget.Values)
    }
    $rows = @($graph.Rows)
    function Get-TypedRow([string] $Type) {
        @($rows | Where-Object { (Get-RowValue $_ 'type') -ieq $Type })
    }

    if ('T1' -in $Target) {
        $sqlVm = @(Get-TypedRow 'microsoft.sqlvirtualmachine/sqlvirtualmachines' | Where-Object { (Get-RowValue $_ 'name') -ieq 'sqlvm01' }) | Select-Object -First 1
        $vm = @(Get-TypedRow 'microsoft.compute/virtualmachines' | Where-Object { (Get-RowValue $_ 'name') -ieq 'sqlvm01' }) | Select-Object -First 1
        if ($sqlVm) {
            Add-TargetResult 'T1' 'Pass' ('T1 (sqlvm01) is in Azure Resource Graph as a SQL virtual machine, which is how the Hub Estate discovers it. {0}' -f $manualCheck) ([ordered]@{
                    resourceId           = Get-RowValue $sqlVm 'id'
                    location             = Get-RowValue $sqlVm 'location'
                    sqlImageSku          = Get-RowValue $sqlVm 'sqlImageSku'
                    sqlServerLicenseType = Get-RowValue $sqlVm 'sqlServerLicenseType'
                    provisioningState    = Get-RowValue $sqlVm 'provisioningState'
                })
        }
        elseif ($vm) {
            Add-TargetResult 'T1' 'Fail' 'The VM sqlvm01 exists, but its SQL virtual machine resource is missing, so the Hub can''t discover T1.' ([ordered]@{ vmResourceId = Get-RowValue $vm 'id' }) 'Redeploy with scripts/deploy.ps1, which registers sqlvm01 with the SQL IaaS Agent extension (Microsoft.SqlVirtualMachine/sqlVirtualMachines).'
        }
        else {
            Add-TargetResult 'T1' 'Fail' ('T1 (sqlvm01) isn''t in Azure Resource Graph in {0}.' -f $resolved.ResourceGroup) @{ resourceGroup = $resolved.ResourceGroup } 'Deploy it with scripts/deploy.ps1; a new resource can take a few minutes to appear in Resource Graph.'
        }
    }

    if ('T2' -in $Target) {
        $instance = @(Get-TypedRow 'microsoft.azurearcdata/sqlserverinstances' | Where-Object {
                $instanceName = Get-RowValue $_ 'name'
                $instanceName -ieq 'arcsql01' -or $instanceName -like 'arcsql01_*'
            }) | Select-Object -First 1
        $machine = @(Get-TypedRow 'microsoft.hybridcompute/machines' | Where-Object { (Get-RowValue $_ 'name') -ieq 'arcsql01' }) | Select-Object -First 1
        if ($instance) {
            Add-TargetResult 'T2' 'Pass' ('T2 (arcsql01) is in Azure Resource Graph as a SQL Server enabled by Azure Arc instance, which is how the Hub Estate discovers it. {0}' -f $manualCheck) ([ordered]@{
                    resourceId        = Get-RowValue $instance 'id'
                    edition           = Get-RowValue $instance 'edition'
                    licenseType       = Get-RowValue $instance 'licenseType'
                    version           = Get-RowValue $instance 'version'
                    monitoringEnabled = Get-RowValue $instance 'monitoringEnabled'
                    machineStatus     = if ($machine) { Get-RowValue $machine 'status' } else { '' }
                })
        }
        elseif ($machine) {
            $evidence = [ordered]@{ machineResourceId = Get-RowValue $machine 'id'; machineStatus = Get-RowValue $machine 'status'; t2SqlInstallMode = $installMode }
            if ($installMode -eq 'PaygWizard') {
                Add-TargetResult 'T2' 'Manual action required' 'The Arc machine arcsql01 is in Azure Resource Graph, but no SQL Server instance is yet: the PaygWizard setup-wizard step is still pending.' $evidence 'Finish the setup-wizard step in docs/deployment.md ("The PaygWizard manual step"); the Azure extension for SQL Server then reports the instance.'
            }
            else {
                Add-TargetResult 'T2' 'Warning' 'The Arc machine arcsql01 is in Azure Resource Graph, but the Azure extension for SQL Server hasn''t reported its SQL Server instance yet.' $evidence 'Check the extension with scripts/configure-arc.ps1 and run again in a few minutes.'
            }
        }
        else {
            Add-TargetResult 'T2' 'Fail' ('The Arc machine arcsql01 isn''t in Azure Resource Graph in {0}, so T2 isn''t onboarded to Azure Arc.' -f $resolved.ResourceGroup) @{ resourceGroup = $resolved.ResourceGroup } 'Onboard the guest with scripts/configure-arc.ps1 once the host reports WaitingForArcOnboarding.'
        }
    }

    if ('T3' -in $Target) {
        $t3 = $resolved.Targets['T3']
        $serverName = $t3.ServerName
        $databaseId = $t3.ResourceId
        $resolvedFrom = 'deploymentId'
        if (-not $serverName) {
            $servers = @(Get-TypedRow 'microsoft.sql/servers' | Where-Object { (Get-RowValue $_ 'name') -like 'azuresql01-*' })
            if ($servers.Count -eq 1) {
                $serverName = Get-RowValue $servers[0] 'name'
                $databaseId = '{0}/databases/ContosoCare' -f (Get-RowValue $servers[0] 'id')
                $resolvedFrom = 'resourceGraph'
            }
        }
        if (-not $serverName) {
            Add-TargetResult 'T3' 'Fail' ('T3''s logical server isn''t known and no single azuresql01-* server is in Azure Resource Graph. {0}' -f $t3.Error) @{ resourceGroup = $resolved.ResourceGroup } 'If T3 was removed with stop-demo.ps1 -RemoveT3, start-demo.ps1 recreates it; otherwise pass -DeploymentId.'
        }
        else {
            $database = @(Get-TypedRow 'microsoft.sql/servers/databases' | Where-Object { (Get-RowValue $_ 'id') -ieq $databaseId }) | Select-Object -First 1
            $server = @(Get-TypedRow 'microsoft.sql/servers' | Where-Object { (Get-RowValue $_ 'name') -ieq $serverName }) | Select-Object -First 1
            if ($database) {
                Add-TargetResult 'T3' 'Pass' ('T3 (ContosoCare on {0}) is in Azure Resource Graph, which is how the Hub Estate discovers it. {1}' -f $serverName, $manualCheck) ([ordered]@{
                        resourceId   = Get-RowValue $database 'id'
                        status       = Get-RowValue $database 'status'
                        createdUtc   = Get-RowValue $database 'createdUtc'
                        skuName      = Get-RowValue $database 'skuName'
                        resolvedFrom = $resolvedFrom
                    })
            }
            elseif ($server) {
                Add-TargetResult 'T3' 'Fail' ('The logical server {0} is in Azure Resource Graph, but the database ContosoCare isn''t.' -f $serverName) ([ordered]@{ serverResourceId = Get-RowValue $server 'id'; expectedResourceId = $databaseId }) 'Run scripts/deploy.ps1 -Resume to create the database, or wait a few minutes if it was just created.'
            }
            else {
                Add-TargetResult 'T3' 'Fail' ('T3 ({0}) isn''t in Azure Resource Graph in {1}.' -f $serverName, $resolved.ResourceGroup) ([ordered]@{ expectedResourceId = $databaseId }) 'If T3 was removed with stop-demo.ps1 -RemoveT3, start-demo.ps1 recreates it with the same names; a new resource can take a few minutes to appear in Resource Graph.'
            }
        }
    }

    if ('T4' -in $Target) {
        $prefix = [string](Get-DemoPostgresSetting)['serverNamePrefix']
        $t4Name = if ($resolved.DeploymentId) { '{0}-{1}' -f $prefix, $resolved.DeploymentId } else { '' }
        $resolvedFrom = 'deploymentId'
        $servers = @(Get-TypedRow 'microsoft.dbforpostgresql/flexibleservers' | Where-Object { (Get-RowValue $_ 'name') -like ('{0}-*' -f $prefix) })
        if (-not $t4Name -and $servers.Count -eq 1) {
            $t4Name = Get-RowValue $servers[0] 'name'
            $resolvedFrom = 'resourceGraph'
        }
        $server = @($servers | Where-Object { (Get-RowValue $_ 'name') -ieq $t4Name }) | Select-Object -First 1
        if ($server) {
            $state = Get-RowValue $server 'status'
            $stopped = if ($state -ieq 'Stopped') { ' It''s stopped now, so its metrics pause until start-demo.ps1 starts it.' } else { '' }
            Add-TargetResult 'T4' 'Pass' ('T4 ({0}) is in Azure Resource Graph as an Azure Database for PostgreSQL flexible server, which the Hub Estate lists (its monitoring is Azure Monitor metrics only).{1} {2}' -f $t4Name, $stopped, $manualCheck) ([ordered]@{
                    resourceId   = Get-RowValue $server 'id'
                    state        = $state
                    version      = Get-RowValue $server 'version'
                    skuName      = Get-RowValue $server 'skuName'
                    resolvedFrom = $resolvedFrom
                })
        }
        elseif (-not $t4Name) {
            Add-TargetResult 'T4' 'Fail' 'T4''s server name isn''t known: the resource group has no deploymentId tag and no single pgflex01-* server is in Azure Resource Graph.' @{ resourceGroup = $resolved.ResourceGroup } 'Deploy it with scripts/deploy.ps1, or pass -DeploymentId.'
        }
        else {
            Add-TargetResult 'T4' 'Fail' ('T4 ({0}) isn''t in Azure Resource Graph in {1}.' -f $t4Name, $resolved.ResourceGroup) @{ resourceGroup = $resolved.ResourceGroup; expectedName = $t4Name } 'Deploy it with scripts/deploy.ps1 -Resume; a new resource can take a few minutes to appear in Resource Graph.'
        }
    }

    return @($byTarget.Values)
}
