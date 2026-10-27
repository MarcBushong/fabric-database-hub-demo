function Enable-DemoT4Workload {
    <#
    .SYNOPSIS
    Sets T4 up with the runner on T1 and adds T4 to T1's activity host (Phase 24, ADR 0019).

    .DESCRIPTION
    Run it after Add-DemoT1ToT3AdminGroup, when T1's workload runner is installed (the WorkloadRunner step in
    T1's health.json) and T4 is running. Through action Run Command, T1:
    1. signs in to T4 with its managed identity as the P6 group's role (T1 is a member; the group is T4's
       Microsoft Entra administrator), creates the runner's role contosocare_runner for its own object ID with
       pgaadauth_create_principal_with_oid, applies the schema, seeds it, applies the demo control objects and
       scenario functions, and grants the runner's role what the scenarios need in contosocare;
    2. records C:\ProgramData\DbHubDemo\t4-workload.json, which tells the WorkloadRunner step and
       Start-DemoWorkload.ps1 that T1's identity reaches T4;
    3. sets T4's activity profile (activityProfile, baseline by default) until the next auto-shutdown; and
    4. restarts DbHubDemo-Workload, whose host then drives T4 too.
    No token, password, or connection string leaves this machine or reaches T1: T1's runner asks its own
    identity for a token. The group's name comes from T4's administrator record (the name PostgreSQL knows it
    by). Idempotent.

    Returns one WORKLOAD.T4.ENABLE result: Pass, Warning (setup passed but the profile wasn't set), Not
    selected (T4 off), Manual action required (T4 stopped), or Fail.

    Sources (checked 2026-10-23):
    - Microsoft Entra roles: https://learn.microsoft.com/azure/postgresql/security/security-manage-entra-users
    - Managed identity sign-in: https://learn.microsoft.com/azure/postgresql/security/security-connect-with-managed-identity
    - Action Run Command: https://learn.microsoft.com/azure/virtual-machines/windows/run-command

    .PARAMETER DeploymentId
    The deployment's six-character suffix. Read from the resource group's deploymentId tag when omitted.

    .PARAMETER PrincipalId
    T1's managed identity object ID. Read from T1 when omitted.

    .EXAMPLE
    Enable-DemoT4Workload -Config $config
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [ValidatePattern('^$|^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $PrincipalId = ''
    )

    $checkId = 'WORKLOAD.T4.ENABLE'
    $postgres = Get-DemoPostgresSetting
    $docUrl = [string]$postgres['docUrls']['entraRoles']
    $names = Get-DemoT4Name -Config $Config -DeploymentId $DeploymentId
    if (-not $names.Enabled) {
        return New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T4' -Status 'Not selected' -Message 'T4 is off in this configuration (t4Enabled is false).'
    }
    $current = Get-DemoT4State -Config $Config -DeploymentId $DeploymentId
    if (-not $current.Exists) {
        return New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T4' -Status 'Fail' -Message ('T4 ({0}) wasn''t found: {1}' -f $names.ServerName, $(if ($current.Error) { $current.Error } else { 'not deployed' })) -Remediation 'Deploy it with scripts/deploy.ps1 -Resume, then run this again.' -DocUrl $docUrl
    }
    if ($current.State -ne 'Ready') {
        return New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T4' -Status 'Manual action required' -Message ('T4 ({0}) is {1}, so T1 can''t set it up now.' -f $names.ServerName, $current.State) -Remediation 'Start it with start-demo.ps1 (or wait until it''s Ready), then run this again.' -DocUrl $docUrl
    }

    $groupId = [string]$Config['t3AdminGroupObjectId']
    $admins = Get-DemoT4Resource -Config $Config -ServerId $names.ServerId -Child 'administrators'
    $entries = if ($admins.Found) { Get-DemoMemberList -InputObject $admins.Value -Name 'value' } else { @() }
    $admin = $entries | Where-Object { [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_ -Name 'properties') -Name 'objectId') -eq $groupId } | Select-Object -First 1
    $adminRole = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $admin -Name 'properties') -Name 'principalName')
    if (-not $adminRole) {
        return New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T4' -Status 'Fail' -Message ('The P6 group isn''t T4''s Microsoft Entra administrator{0}, so T1 has no role to set T4 up with.' -f $(if ($admins.Found) { '' } else { ' (the administrators couldn''t be read: ' + $admins.Error + ')' })) -Remediation 'Redeploy with scripts/deploy.ps1 -Resume, which adds the group (T4.ADMIN).' -DocUrl $docUrl
    }
    if (-not $PrincipalId) {
        $PrincipalId = Get-DemoT1PrincipalId -Config $Config
    }
    if ($PrincipalId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        return New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T4' -Status 'Fail' -Message 'T1''s managed identity wasn''t found.' -Remediation 'Deploy T1 first (scripts/deploy.ps1), then run this again.' -DocUrl $docUrl
    }
    # Scale 1 (10,000 patients) on every profile: T4 is a one-vCore Burstable server, and the scenarios size
    # their work from the seed (demo.fn_seed_scale).
    $seedScale = 1
    if (-not $PSCmdlet.ShouldProcess($names.T1VmName, ('Set up {0} as {1} and add T4 to the activity host' -f $names.ServerName, $adminRole))) {
        return
    }

    Write-DemoLog -Message ('T1 sets up T4 ({0}) as the P6 group''s role and adds it to the activity host.' -f $names.Fqdn)
    $request = @{
        serverFqdn     = $names.Fqdn
        adminRole      = $adminRole
        runnerRole     = $names.RunnerRole
        runnerObjectId = $PrincipalId.ToLowerInvariant()
        seedScale      = $seedScale
    }
    $data = Invoke-DemoWorkloadAction -Config $Config -VmName $names.T1VmName -Action 'EnableT4' -Request $request
    $evidence = @{}
    if ($data['evidence'] -is [System.Collections.IDictionary]) {
        foreach ($key in $data['evidence'].Keys) {
            $evidence[$key] = $data['evidence'][$key]
        }
    }
    $evidence['server'] = $names.ServerName
    $status = [string]$data['status']
    $remediation = switch ($status) {
        'Pass' { '' }
        'Warning' { 'T4 is set up; check the profile message, then set it with demo-control.yml or Invoke-DemoWorkloadCommand -Target T4.' }
        default { 'Check that T1''s WorkloadRunner step succeeded (health.json), that T1 is in the P6 group (Add-DemoT1ToT3AdminGroup; a new membership can take a few minutes to reach a token), and that T4 is Ready; then run this again. It''s idempotent.' }
    }
    return New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T4' -Status $status -Message ([string]$data['message']) -Evidence $evidence -Remediation $remediation -DocUrl $docUrl
}
