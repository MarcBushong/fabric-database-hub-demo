function Invoke-DemoT3SqlFromT1 {
    <#
    .SYNOPSIS
    Runs T-SQL on T3 (Azure SQL Database) from T1, with T1's managed identity, through action Run Command.

    .DESCRIPTION
    T1's system-assigned identity is a member of the P6 group, T3's Entra administrator (ADR 0008), and T1
    reaches T3 in both network modes: through the private endpoint, or through the VNet rule (ADR 0007).
    This function:
    1. Resolves the names: the logical server is azuresql01-<deploymentId>, from -DeploymentId or the
       resource group's deploymentId tag.
    2. Collects the batches: a named set (-Name Setup, Status, or PerformanceMonitoring; see
       database/azuresql/README.md), T-SQL files (-Path), or queries (-Query), split on GO lines.
    3. Reads the server's FQDN ('az sql server show') and T1's power state ('az vm get-instance-view').
    4. Builds the VM-side script from vm/t3/Invoke-DemoT3Sql.ps1 with the batches embedded, writes it to a
       temporary file, and runs it with 'az vm run-command invoke --command-id RunPowerShellScript
       --scripts @<file>', so no T-SQL, quote, or percent sign goes on a command line. A Run Command that's
       still busy (Conflict) is retried.
    5. Parses the runner's one-line JSON result. The action Run Command returns only the last 4,096 bytes of
       output, so the runner keeps it short.
    The VM side gets the Azure SQL token from IMDS and never prints it. Login failures are retried for up
    to -MaxLoginWaitSeconds, because the group membership can take time to apply; when the login never
    succeeds the status is Warning, with the measured wait. Managed identity tokens are cached for each
    resource for up to about 24 hours, so nothing on T1 should request an Azure SQL token before T1 joins
    the P6 group (Add-DemoT1ToT3AdminGroup).

    Returns Status, Reason (Ok, NoServerName, ServerNotFound, T1NotRunning, LoginNotEffective, SqlFailed,
    or RunCommandFailed), Message, Data (the runner's result), Rows (its last result set), and Result (a
    New-DemoResult record with -CheckId).

    Sources (checked 2026-10-20):
    - Action Run Command: https://learn.microsoft.com/azure/virtual-machines/windows/run-command
    - az vm run-command invoke: https://learn.microsoft.com/cli/azure/vm/run-command
    - Managed identity token for Azure SQL from a VM: https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/tutorial-windows-managed-identities-vm-access
    - Managed identity token caching: https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations

    .PARAMETER Name
    A named script set: Setup (schema, seed, settings, the extended property, and the status row), Status
    (read-only), or PerformanceMonitoring (the extended property only).

    .PARAMETER Path
    T-SQL files to run in order, relative to the repository root or absolute.

    .PARAMETER Query
    T-SQL text to run in order. Each item can hold several batches separated by GO lines.

    .PARAMETER DeploymentId
    The deployment's six-character suffix. Read from the resource group's deploymentId tag when omitted.

    .EXAMPLE
    Invoke-DemoT3SqlFromT1 -Config $config -Name Setup

    .EXAMPLE
    (Invoke-DemoT3SqlFromT1 -Config $config -Name Status).Rows[0].performance_monitoring
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Name')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory, ParameterSetName = 'Name')]
        [ValidateSet('Setup', 'Status', 'PerformanceMonitoring')]
        [string] $Name,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Path,

        [Parameter(Mandatory, ParameterSetName = 'Query')]
        [ValidateNotNullOrEmpty()]
        [string[]] $Query,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [ValidatePattern('^[A-Z0-9]+(\.[A-Z0-9_]+)+$')]
        [string] $CheckId = 'T3.SQL',

        [ValidateRange(0, 1800)]
        [int] $MaxLoginWaitSeconds = 600,

        [ValidateRange(0, 900)]
        [int] $MaxResumeWaitSeconds = 300,

        [ValidateRange(30, 3600)]
        [int] $BatchTimeoutSeconds = 1800,

        [ValidateRange(1, 10)]
        [int] $RunCommandAttempts = 3,

        [ValidateRange(0, 600)]
        [int] $RetryDelaySeconds = 30
    )

    $subscriptionId = $Config['subscriptionId']
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command'
    $resultCheckId = $CheckId
    $names = Get-DemoT3Name -Config $Config -DeploymentId $DeploymentId
    $label = if ($PSCmdlet.ParameterSetName -eq 'Name') { $Name.ToLowerInvariant() } else { $PSCmdlet.ParameterSetName.ToLowerInvariant() }

    function Get-T3Outcome([string] $Status, [string] $Reason, [string] $Message, [hashtable] $Evidence = @{}, [string] $Remediation = '', [object] $Data = $null) {
        $Evidence['reason'] = $Reason
        $Evidence['label'] = $label
        $Evidence['server'] = $names.ServerName
        $Evidence['database'] = $names.DatabaseName
        $rows = @()
        if ($null -ne $Data -and $Data.ContainsKey('rows')) {
            $rows = @($Data['rows'] | Where-Object { $null -ne $_ })
        }
        [pscustomobject]@{
            PSTypeName = 'DbHubDemo.T3SqlRun'
            Status     = $Status
            Reason     = $Reason
            Message    = $Message
            Data       = $Data
            Rows       = $rows
            Result     = New-DemoResult -CheckId $resultCheckId -Area 't3' -Target 'T3' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $docUrl
        }
    }

    if (-not $names.ServerName) {
        return Get-T3Outcome 'Fail' 'NoServerName' ("T3's server name couldn't be resolved: the resource group {0} has no deploymentId tag." -f $names.ResourceGroup) -Remediation 'Deploy the demo first, or pass -DeploymentId.'
    }

    $seedScale = [int](Get-DemoProfile).profiles[[string]$Config['profile']].database.seedScale
    $sql = switch ($PSCmdlet.ParameterSetName) {
        'Name' { Get-DemoT3SqlBatch -Name $Name -SeedScale $seedScale }
        'Path' { Get-DemoT3SqlBatch -Path $Path }
        'Query' { Get-DemoT3SqlBatch -Query $Query }
    }

    $server = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('sql', 'server', 'show', '--name', $names.ServerName, '--resource-group', $names.ResourceGroup) -AsJson -AllowFailure
    $fqdn = [string](Get-DemoMemberValue -InputObject $server -Name 'fullyQualifiedDomainName')
    if (-not $fqdn) {
        return Get-T3Outcome 'Fail' 'ServerNotFound' ("T3's logical server {0} wasn't found in {1}." -f $names.ServerName, $names.ResourceGroup) -Remediation 'Deploy or recreate T3 (deploy.ps1 -Resume) and run this again.'
    }

    $view = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('vm', 'get-instance-view', '--name', $names.T1VmName, '--resource-group', $names.ResourceGroup) -AsJson -AllowFailure
    $statuses = Get-DemoMemberList -InputObject (Get-DemoMemberValue -InputObject $view -Name 'instanceView') -Name 'statuses'
    $powerState = @($statuses | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'code') } | Where-Object { $_ -like 'PowerState/*' }) | Select-Object -First 1
    if ($powerState -ne 'PowerState/running') {
        $state = if ($powerState) { $powerState.Substring('PowerState/'.Length) } else { 'not found' }
        return Get-T3Outcome 'Fail' 'T1NotRunning' ("T1 ({0}) isn't running ({1}), so it can't run T-SQL on T3." -f $names.T1VmName, $state) @{ t1PowerState = $state } -Remediation 'Start T1 (start-demo.ps1, or az vm start) and run this again.'
    }

    $script = ConvertTo-DemoT3SqlScript -ServerFqdn $fqdn -DatabaseName $names.DatabaseName -Batch $sql.Batches -Label $label -MaxLoginWaitSeconds $MaxLoginWaitSeconds -MaxResumeWaitSeconds $MaxResumeWaitSeconds -BatchTimeoutSeconds $BatchTimeoutSeconds
    $target = '{0} in {1}' -f $names.T1VmName, $names.ResourceGroup
    if (-not $PSCmdlet.ShouldProcess($target, ('Run {0} T-SQL batches on {1}/{2} through action Run Command' -f $script.BatchCount, $names.ServerName, $names.DatabaseName))) {
        return
    }

    Write-DemoLog -Message ('Running {0} T-SQL batches ({1}) on T3 {2}/{3} from T1; the script is {4} bytes.' -f $script.BatchCount, ($sql.Sources -join ', '), $names.ServerName, $names.DatabaseName, $script.Bytes)
    $scriptPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('dbhub-t3sql-{0}.ps1' -f [guid]::NewGuid())
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $run = $null
    try {
        [System.IO.File]::WriteAllText($scriptPath, $script.Text, [System.Text.Encoding]::ASCII)
        $arguments = @('vm', 'run-command', 'invoke', '--resource-group', $names.ResourceGroup, '--name', $names.T1VmName, '--command-id', 'RunPowerShellScript', '--scripts', "@$scriptPath", '--output', 'json')
        for ($attempt = 1; $attempt -le $RunCommandAttempts; $attempt++) {
            $run = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList $arguments -AllowFailure
            if ($run.ExitCode -eq 0 -or $attempt -eq $RunCommandAttempts -or $run.StdErr -notmatch '(?i)conflict|in progress|another operation') {
                break
            }
            Write-DemoLog -Level Warning -Message ('A Run Command is already in progress on {0}; retrying in {1} seconds ({2} of {3}).' -f $names.T1VmName, $RetryDelaySeconds, $attempt, $RunCommandAttempts)
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
    finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
    $operatorSeconds = [int]$clock.Elapsed.TotalSeconds

    if ($run.ExitCode -ne 0) {
        $errorText = (Protect-DemoText -Text ([string]$run.StdErr)).Trim()
        if ($errorText.Length -gt 500) {
            $errorText = $errorText.Substring(0, 500) + '...'
        }
        return Get-T3Outcome 'Fail' 'RunCommandFailed' ('The Run Command on T1 failed: {0}' -f $errorText) @{ operatorSeconds = $operatorSeconds } -Remediation 'Check that the VM agent on T1 is Ready and that no other Run Command is running, then run this again.'
    }

    $response = $null
    try {
        $response = [string]$run.StdOut | ConvertFrom-Json -Depth 32
    }
    catch {
        $response = $null
    }
    $parsed = ConvertFrom-DemoT3RunCommandOutput -Response $response
    $data = $parsed.Data
    if ($null -eq $data -or [string]$data['marker'] -ne 'DBHUBDEMO-T3SQL' -or [string]$data['status'] -notin 'Pass', 'Warning', 'Fail') {
        $detail = if ($parsed.StdErr) { $parsed.StdErr } else { 'no result line' }
        return Get-T3Outcome 'Fail' 'RunCommandFailed' ('T1 returned no T3 result: {0}' -f $detail) @{ operatorSeconds = $operatorSeconds } -Remediation 'See C:\WindowsAzure\Logs\Plugins\Microsoft.CPlat.Core.RunCommandWindows on T1 through Bastion.'
    }

    $evidence = @{ operatorSeconds = $operatorSeconds; sources = $sql.Sources }
    foreach ($key in 'batches', 'completed', 'attempts', 'loginFailures', 'transientFailures', 'loginWaitSeconds', 'elapsedSeconds', 'errorNumber', 'rowsTruncated') {
        if ($data.ContainsKey($key)) {
            $evidence[$key] = $data[$key]
        }
    }
    $where = '{0}/{1}' -f $names.ServerName, $names.DatabaseName
    switch ([string]$data['status']) {
        'Pass' {
            $wait = if ([int]$data['loginFailures'] -gt 0) { ' T1''s login succeeded after {0} seconds and {1} failed attempts.' -f $data['loginWaitSeconds'], $data['loginFailures'] } else { '' }
            $resume = if ([int]$data['transientFailures'] -gt 0) { ' T3 answered after {0} transient errors (resuming from auto-pause).' -f $data['transientFailures'] } else { '' }
            $message = ('T1 ran {0} T-SQL batches ({1}) on T3 {2} in {3} seconds.{4}{5}' -f $data['completed'], $label, $where, $data['elapsedSeconds'], $wait, $resume)
            return Get-T3Outcome 'Pass' 'Ok' $message $evidence -Data $data
        }
        'Warning' {
            $message = ('T1''s managed identity couldn''t log in to T3 {0} for {1} seconds, so nothing ran. Its membership in the P6 group may not be effective yet.' -f $where, $data['loginWaitSeconds'])
            $remediation = 'Managed identity tokens are cached for each resource for up to about 24 hours, so a token requested before T1 joined the P6 group keeps failing until it refreshes. Run this step again later (deploy.ps1 -Resume), or run the T-SQL as a P6 group member (the interactive fallback, ADR 0007).'
            return Get-T3Outcome 'Warning' 'LoginNotEffective' $message $evidence -Remediation $remediation -Data $data
        }
        default {
            $message = ('T-SQL from T1 on T3 {0} failed after {1} of {2} batches: {3}' -f $where, $data['completed'], $data['batches'], $data['error'])
            return Get-T3Outcome 'Fail' 'SqlFailed' $message $evidence -Remediation 'Fix the error and run this again; T3''s scripts are idempotent.' -Data $data
        }
    }
}
