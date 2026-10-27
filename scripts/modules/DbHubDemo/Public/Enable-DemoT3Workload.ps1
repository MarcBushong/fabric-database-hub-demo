function Enable-DemoT3Workload {
    <#
    .SYNOPSIS
    Applies the demo objects to T3 with the runner on T1 and adds T3 to T1's activity host (ADR 0010, Phase 13).

    .DESCRIPTION
    Run it after Add-DemoT1ToT3AdminGroup and Invoke-DemoT3SqlFromT1 -Name Setup, when T1's workload runner is
    installed (the WorkloadRunner step in T1's health.json), and again whenever T3 is recreated
    (start-demo.ps1 after stop-demo.ps1 -RemoveT3). Through action Run Command, T1:
    1. runs 'ContosoCare.Workload setup --target T3 --server <fqdn>' with its managed identity, which applies
       110-demo-control.sql and 120-scenario-procedures.sql (Invoke-DemoT3SqlFromT1 -Name Setup applies only
       the 0nn scripts);
    2. records C:\ProgramData\DbHubDemo\t3-workload.json, which tells the WorkloadRunner step and
       Start-DemoWorkload.ps1 that T1's identity reaches T3;
    3. sets T3's activity profile (activityProfile, baseline by default) until the next auto-shutdown; and
    4. restarts DbHubDemo-Workload, whose host then drives T1 and T3.
    The marker exists so that nothing on T1 asks for an Azure SQL token before T1 is in the P6 group: managed
    identity tokens are cached for up to about 24 hours (Phase 8, R80). While T3 has an active profile, the
    runner keeps the serverless database awake (ADR 0016).

    Returns one WORKLOAD.T3.ENABLE result: Pass, Warning (setup passed but the profile wasn't set, or T3
    answered with warnings), Manual action required, or Fail.

    Sources (checked 2026-10-20):
    - Action Run Command: https://learn.microsoft.com/azure/virtual-machines/windows/run-command
    - Managed identity token caching: https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations

    .PARAMETER DeploymentId
    The deployment's six-character suffix. Read from the resource group's deploymentId tag when omitted.

    .EXAMPLE
    Enable-DemoT3Workload -Config $config
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = ''
    )

    $checkId = 'WORKLOAD.T3.ENABLE'
    $docUrl = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command'
    $names = Get-DemoT3Name -Config $Config -DeploymentId $DeploymentId
    if (-not $names.ServerName) {
        return New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T3' -Status 'Fail' -Message ("T3's server name couldn't be resolved: the resource group {0} has no deploymentId tag." -f $names.ResourceGroup) -Remediation 'Deploy the demo first, or pass -DeploymentId.' -DocUrl $docUrl
    }
    $server = Invoke-DemoAz -SubscriptionId $Config['subscriptionId'] -ArgumentList @('sql', 'server', 'show', '--name', $names.ServerName, '--resource-group', $names.ResourceGroup) -AsJson -AllowFailure
    $fqdn = [string](Get-DemoMemberValue -InputObject $server -Name 'fullyQualifiedDomainName')
    if (-not $fqdn) {
        return New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T3' -Status 'Fail' -Message ("T3's logical server {0} wasn't found in {1}." -f $names.ServerName, $names.ResourceGroup) -Remediation 'Deploy or recreate T3 (deploy.ps1 -Resume or start-demo.ps1), then run this again.' -DocUrl $docUrl
    }
    if (-not $PSCmdlet.ShouldProcess($names.T1VmName, ('Apply the demo objects to {0} and add T3 to the activity host' -f $names.ServerName))) {
        return
    }

    Write-DemoLog -Message ('T1 applies the demo objects to T3 ({0}) and adds it to the activity host.' -f $fqdn)
    $data = Invoke-DemoWorkloadAction -Config $Config -VmName $names.T1VmName -Action 'EnableT3' -Request @{ serverFqdn = $fqdn.ToLowerInvariant() }
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
        'Warning' { 'T3 is set up; check the profile message, then set it with demo-control.yml or Invoke-DemoWorkloadCommand -Target T3.' }
        default { 'Check that T1''s WorkloadRunner step succeeded (health.json), that T1 is in the P6 group (Add-DemoT1ToT3AdminGroup), and that Invoke-DemoT3SqlFromT1 -Name Setup passed; then run this again. It''s idempotent.' }
    }
    return New-DemoResult -CheckId $checkId -Area 'workload' -Target 'T3' -Status $status -Message ([string]$data['message']) -Evidence $evidence -Remediation $remediation -DocUrl $docUrl
}
