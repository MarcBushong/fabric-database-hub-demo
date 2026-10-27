function Initialize-DemoGitHubOidc {
    <#
    .SYNOPSIS
    The one-time GitHub Actions setup (prerequisite P7): a user-assigned managed identity in
    rg-<prefix>-control with one federated credential per GitHub environment, for azure/login with OpenID
    Connect (plan section 9.5, ADR 0011).

    .DESCRIPTION
    Contributor can do all of it except the role assignment, so by default it prints that one command for an
    Owner, User Access Administrator, or Role Based Access Control Administrator (ADR 0008); with
    -AssignRole (or assignRoles true in the configuration) it creates the assignment itself.
    1. Creates or updates rg-<prefix>-control (outside the demo group, so destroy.ps1 never deletes it).
    2. Creates or updates the identity id-<prefix>-github.
    3. For each environment, creates the federated credential gh-<environment> with the issuer
       https://token.actions.githubusercontent.com, the subject repo:<owner>/<repo>:environment:<environment>,
       and the audience api://AzureADTokenExchange. An existing credential with the same subject is kept.
    4. Contributor on the subscription for the identity: the command (Manual action required) or, with
       -AssignRole, the assignment.
    5. The GitHub environment's secrets the workflows read: AZURE_CLIENT_ID, AZURE_TENANT_ID,
       AZURE_SUBSCRIPTION_ID, and DBHUB_CONFIG_JSON (the configuration). They're identifiers, not credentials;
       they're environment secrets so that GitHub masks them, because a public repository's Actions logs are public
       (ADR 0022). By default nothing is written to GitHub: OIDC.GITHUB prints the 'gh secret set --env' commands.
       With -ConfigureGitHub (opt-in), it uses the GitHub CLI as you (gh auth login first; it never signs in):
       each environment gets you as its required reviewer and deployments from the default branch only, then its
       four secrets (Set-DemoGitHubEnvironment).
    6. With -ScheduleEnvironment (opt-in, needs -ConfigureGitHub for the GitHub part), a second environment for
       the scheduled workflows, <environment>-schedule unless -ScheduleEnvironmentName names it: its own federated
       credential, the default branch only, and no required reviewers, so a scheduled run doesn't wait for an
       approval; the repository variable DBHUB_SCHEDULE_ENVIRONMENT points the schedules at it. The trade-off: a
       scheduled start, stop, Bastion cleanup, or expiry runs without a reviewer. Manual runs of those workflows
       still use the reviewed environment, the shared runner refuses the schedule environment outside a schedule,
       and the schedules stay off until you set DBHUB_SCHEDULES_ENABLED to true yourself.
    7. With the Key Vault opt-in (keyVault.enabled), OIDC.KEYVAULT asks to add the identity to
       keyVault.operatorObjectIds, so the scheduled stop can disable the stored host password.

    Sources (checked 2026-10-20; the GitHub ones 2026-10-27):
    - https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect
    - https://learn.microsoft.com/cli/azure/identity/federated-credential#az-identity-federated-credential-create
    - https://docs.github.com/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure
    - https://docs.github.com/rest/deployments/environments#create-or-update-an-environment
    - https://cli.github.com/manual/gh_secret_set

    .PARAMETER Config
    Configuration from Get-DemoConfig.

    .PARAMETER Repository
    owner/repo; defaults to github.repository in the configuration.

    .PARAMETER Environment
    GitHub environment names; defaults to github.environment (or the configuration's environment).

    .PARAMETER AssignRole
    Create the Contributor assignment (needs Microsoft.Authorization/roleAssignments/write).

    .PARAMETER ConfigureGitHub
    Opt-in: create the GitHub environments and set their secrets with the GitHub CLI, as the signed-in gh user.

    .PARAMETER ScheduleEnvironment
    Opt-in: also a schedule environment with no required reviewers, for the scheduled workflows only.

    .PARAMETER ScheduleEnvironmentName
    The schedule environment's name; defaults to <first environment>-schedule.

    .PARAMETER ConfigJson
    The configuration file's text for the DBHUB_CONFIG_JSON secret; defaults to the configuration as JSON.

    .EXAMPLE
    Initialize-DemoGitHubOidc -Config $config -Repository contoso/fabric-database-hub-demo -Environment demo -ConfigureGitHub
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?$')]
        [string] $Repository = '',

        [ValidatePattern('^[A-Za-z0-9_.-]{1,100}$')]
        [string[]] $Environment = @(),

        [switch] $AssignRole,

        [switch] $ConfigureGitHub,

        [switch] $ScheduleEnvironment,

        [ValidatePattern('^$|^[A-Za-z0-9_.-]{1,100}$')]
        [string] $ScheduleEnvironmentName = '',

        [string] $ConfigJson = ''
    )

    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $results.Add((Assert-DemoAzContext -SubscriptionId ([string]$Config['subscriptionId']) -TenantId ([string]$Config['tenantId']) -Account ([string]$Config['azureAccount'])))
    }
    catch {
        $results.Add((New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message $_.Exception.Message -Remediation 'Nothing was created. Sign in yourself and run setup-github-oidc.ps1 again.'))
        return $results.ToArray()
    }
    $github = $Config['github']
    if (-not $Repository) {
        $Repository = [string](Get-DemoMemberValue -InputObject $github -Name 'repository')
    }
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $Repository -like 'your-org/*') {
        $results.Add((New-DemoResult -CheckId 'OIDC.REPOSITORY' -Area 'infra' -Target 'github' -Status 'Fail' -Message 'No GitHub repository: pass -Repository owner/repo, or set github.repository in the configuration.'))
        return $results.ToArray()
    }
    if ($Environment.Count -eq 0) {
        $configured = [string](Get-DemoMemberValue -InputObject $github -Name 'environment')
        $Environment = @(if ($configured) { $configured } else { [string]$Config['environment'] })
    }
    $subscriptionId = [string]$Config['subscriptionId']
    $tenantId = [string]$Config['tenantId']
    $controlGroup = 'rg-{0}-control' -f $Config['prefix']
    $identityName = 'id-{0}-github' -f $Config['prefix']
    $issuer = 'https://token.actions.githubusercontent.com'
    $audience = 'api://AzureADTokenExchange'
    $docUrl = 'https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect'
    $assign = $AssignRole -or [bool]$Config['assignRoles']
    $scheduleName = ''
    if ($ScheduleEnvironment) {
        $scheduleName = if ($ScheduleEnvironmentName) { $ScheduleEnvironmentName } else { '{0}-schedule' -f $Environment[0] }
        if ($scheduleName -in $Environment) {
            $results.Add((New-DemoResult -CheckId 'OIDC.GITHUB.SCHEDULE' -Area 'infra' -Target 'github' -Status 'Fail' -Message ('The schedule environment {0} must differ from the reviewed environment(s) {1}: it has no reviewers.' -f $scheduleName, ($Environment -join ', ')) -Remediation 'Pass another -ScheduleEnvironmentName.'))
            return $results.ToArray()
        }
    }
    $trusted = @($Environment) + @(if ($scheduleName) { $scheduleName })

    if (-not $PSCmdlet.ShouldProcess($controlGroup, ('Create {0} with federated credentials for {1} ({2})' -f $identityName, $Repository, ($trusted -join ', ')))) {
        $results.Add((New-DemoResult -CheckId 'OIDC.IDENTITY' -Area 'infra' -Target 'github' -Status 'Not selected' -Message ('What if: {0} and its credentials for {1} weren''t created.' -f $identityName, ($trusted -join ', '))))
        if ($ConfigureGitHub) {
            $plan = foreach ($name in $Environment) { '{0}: you as required reviewer, the default branch only, and its four secrets' -f $name }
            if ($scheduleName) {
                $plan = @($plan) + ('{0}: no reviewers, the default branch only, its four secrets, and DBHUB_SCHEDULE_ENVIRONMENT' -f $scheduleName)
            }
            $results.Add((New-DemoResult -CheckId 'OIDC.GITHUB' -Area 'infra' -Target 'github' -Status 'Not selected' -Message ('What if: in {0}, nothing was written; it would set up {1}.' -f $Repository, ($plan -join '; ')) -DocUrl 'https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments'))
        }
        return $results.ToArray()
    }
    $tags = @(('owner={0}' -f $Config['owner']), ('costCenter={0}' -f $Config['costCenter']), 'purpose=github-oidc')
    $group = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList (@('group', 'create', '--name', $controlGroup, '--location', [string]$Config['location'], '--tags') + $tags) -AllowFailure
    if ($group.ExitCode -ne 0) {
        $results.Add((New-DemoResult -CheckId 'OIDC.RESOURCEGROUP' -Area 'infra' -Target 'github' -Status 'Fail' -Message ('Creating {0} failed: {1}' -f $controlGroup, (Get-DemoDeploymentErrorText -Text $group.StdErr -MaxLength 400)) -DocUrl $docUrl))
        return $results.ToArray()
    }
    $results.Add((New-DemoResult -CheckId 'OIDC.RESOURCEGROUP' -Area 'infra' -Target 'github' -Status 'Pass' -Message ('{0} exists in {1}.' -f $controlGroup, $Config['location'])))

    $identity = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList (@('identity', 'create', '--name', $identityName, '--resource-group', $controlGroup, '--location', [string]$Config['location'], '--tags') + $tags) -AsJson -AllowFailure
    $clientId = [string](Get-DemoMemberValue -InputObject $identity -Name 'clientId')
    $principalId = [string](Get-DemoMemberValue -InputObject $identity -Name 'principalId')
    if (-not $clientId -or -not $principalId) {
        $results.Add((New-DemoResult -CheckId 'OIDC.IDENTITY' -Area 'infra' -Target 'github' -Status 'Fail' -Message ('Creating the identity {0} failed.' -f $identityName) -DocUrl $docUrl))
        return $results.ToArray()
    }
    $results.Add((New-DemoResult -CheckId 'OIDC.IDENTITY' -Area 'infra' -Target 'github' -Status 'Pass' -Message ('{0} exists (client ID {1}).' -f $identityName, $clientId) -Evidence ([ordered]@{ clientId = $clientId; principalId = $principalId })))

    foreach ($name in $trusted) {
        $credentialName = 'gh-{0}' -f ($name -replace '[^A-Za-z0-9-]', '-')
        $subject = 'repo:{0}:environment:{1}' -f $Repository, $name
        $checkId = 'OIDC.FEDERATED_{0}' -f ($name.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')
        $existing = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('identity', 'federated-credential', 'show', '--name', $credentialName, '--identity-name', $identityName, '--resource-group', $controlGroup) -AsJson -AllowFailure
        if ([string](Get-DemoMemberValue -InputObject $existing -Name 'subject') -eq $subject) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'github' -Status 'Pass' -Message ('{0} already trusts {1}.' -f $credentialName, $subject)))
            continue
        }
        $verb = if ($null -ne $existing) { 'update' } else { 'create' }
        $created = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('identity', 'federated-credential', $verb, '--name', $credentialName, '--identity-name', $identityName, '--resource-group', $controlGroup, '--issuer', $issuer, '--subject', $subject, '--audiences', $audience) -AllowFailure
        if ($created.ExitCode -ne 0) {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'github' -Status 'Fail' -Message ('Creating {0} failed: {1}' -f $credentialName, (Get-DemoDeploymentErrorText -Text $created.StdErr -MaxLength 400)) -DocUrl 'https://learn.microsoft.com/cli/azure/identity/federated-credential'))
            return $results.ToArray()
        }
        $results.Add((New-DemoResult -CheckId $checkId -Area 'infra' -Target 'github' -Status 'Pass' -Message ('{0} trusts {1}.' -f $credentialName, $subject)))
    }

    $scope = '/subscriptions/{0}' -f $subscriptionId
    $roleCommand = 'az role assignment create --assignee-object-id {0} --assignee-principal-type ServicePrincipal --role Contributor --scope {1}' -f $principalId, $scope
    if ($assign) {
        $role = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('role', 'assignment', 'create', '--assignee-object-id', $principalId, '--assignee-principal-type', 'ServicePrincipal', '--role', 'Contributor', '--scope', $scope) -AllowFailure
        if ($role.ExitCode -ne 0) {
            $results.Add((New-DemoResult -CheckId 'OIDC.ROLE' -Area 'infra' -Target 'github' -Status 'Manual action required' -Message ('The Contributor assignment failed: {0}' -f (Get-DemoDeploymentErrorText -Text $role.StdErr -MaxLength 300)) -Remediation ('An Owner, User Access Administrator, or Role Based Access Control Administrator runs: {0}' -f $roleCommand) -DocUrl 'https://learn.microsoft.com/azure/role-based-access-control/role-assignments-cli'))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'OIDC.ROLE' -Area 'infra' -Target 'github' -Status 'Pass' -Message ('{0} has Contributor on the subscription.' -f $identityName)))
        }
    }
    else {
        $results.Add((New-DemoResult -CheckId 'OIDC.ROLE' -Area 'infra' -Target 'github' -Status 'Manual action required' -Message ('{0} needs Contributor on the subscription, and Contributor can''t assign roles (P7).' -f $identityName) -Remediation ('An Owner, User Access Administrator, or Role Based Access Control Administrator runs once: {0}' -f $roleCommand) -Evidence ([ordered]@{ command = $roleCommand }) -DocUrl 'https://learn.microsoft.com/azure/role-based-access-control/role-assignments-cli'))
    }

    $groupId = [string]$Config['t3AdminGroupObjectId']
    $ownerCommand = 'az ad group owner add --group {0} --owner-object-id {1}' -f $groupId, $principalId
    $results.Add((New-DemoResult -CheckId 'OIDC.P6OWNER' -Area 'infra' -Target 'github' -Status 'Manual action required' -Message 'Optional: for deploy.yml to add T1 to the T3 administrators group (P6), the identity must own that group, as you do locally.' -Remediation ("A current owner of the group runs once: {0}. 'az ad' uses the Azure CLI's default account, so run it where that account is in tenant {1} (for example in Cloud Shell or under a separate AZURE_CONFIG_DIR), or add the owner in the Microsoft Entra admin center. Without it, run deploy.ps1 -FromStage T3 locally after the first Actions deployment." -f $ownerCommand, $tenantId) -Evidence ([ordered]@{ command = $ownerCommand }) -DocUrl 'https://learn.microsoft.com/cli/azure/ad/group/owner#az-ad-group-owner-add'))

    $keyVault = Get-DemoKeyVaultSetting -Config $Config
    if ($keyVault.Enabled -and $principalId.ToLowerInvariant() -notin $keyVault.OperatorObjectIds) {
        # The scheduled stop disables the stored host password, which needs Key Vault Secrets Officer on the vault.
        $results.Add((New-DemoResult -CheckId 'OIDC.KEYVAULT' -Area 'infra' -Target 'github' -Status 'Manual action required' -Message ('With the Key Vault opt-in, the scheduled stop and bastion-cleanup.yml disable the stored host password, so {0} needs Key Vault Secrets Officer on the vault.' -f $identityName) -Remediation ('Add {0} to keyVault.operatorObjectIds in the configuration (and DBHUB_CONFIG_JSON), then run deploy.ps1 -FromStage Infrastructure -StopAfter Infrastructure, which assigns the role on the vault only.' -f $principalId) -Evidence ([ordered]@{ principalId = $principalId }) -DocUrl 'https://learn.microsoft.com/azure/key-vault/general/rbac-guide'))
    }

    $identifiers = [ordered]@{
        AZURE_CLIENT_ID       = $clientId
        AZURE_TENANT_ID       = $tenantId
        AZURE_SUBSCRIPTION_ID = $subscriptionId
    }
    $environmentDoc = 'https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments'
    if (-not $ConfigureGitHub) {
        $commands = foreach ($name in $trusted) {
            foreach ($key in $identifiers.Keys) {
                'gh secret set {0} --env {1} --repo {2} --body {3}' -f $key, $name, $Repository, $identifiers[$key]
            }
            'Get-Content -Raw config/demo.config.json | gh secret set DBHUB_CONFIG_JSON --env {0} --repo {1}' -f $name, $Repository
        }
        if ($scheduleName) {
            $commands = @($commands) + ('gh variable set DBHUB_SCHEDULE_ENVIRONMENT --repo {0} --body {1}' -f $Repository, $scheduleName)
        }
        $reviewed = 'in Settings > Environments, create {0} with you as required reviewer and Selected branches set to the default branch' -f ($Environment -join ' and ')
        if ($scheduleName) {
            $reviewed += ('; create {0} with no reviewers and the same branch rule' -f $scheduleName)
        }
        $results.Add((New-DemoResult -CheckId 'OIDC.GITHUB' -Area 'infra' -Target 'github' -Status 'Manual action required' -Message ('Set up the GitHub environment(s) {0} in {1}: {2}, then set their secrets {3} and DBHUB_CONFIG_JSON (identifiers, not credentials; secrets so that GitHub masks them in public logs). Or run setup-github-oidc.ps1 again with -ConfigureGitHub, which does all of it with the GitHub CLI.' -f ($trusted -join ', '), $Repository, $reviewed, (@($identifiers.Keys) -join ', ')) -Remediation ($commands -join ' ; ') -Evidence ([ordered]@{ environments = $trusted; commands = @($commands) }) -DocUrl $environmentDoc))
        return $results.ToArray()
    }

    $github = Get-DemoGitHubContext -Repository $Repository
    if ($github.Status -ne 'Ready') {
        $results.Add((New-DemoResult -CheckId 'OIDC.GITHUB' -Area 'infra' -Target 'github' -Status 'Manual action required' -Message $github.Message -Remediation 'Then run setup-github-oidc.ps1 -ConfigureGitHub again; the Azure part above is already done and is kept.' -DocUrl 'https://cli.github.com/manual/gh_auth_login'))
        return $results.ToArray()
    }
    if (-not $github.IsAdmin) {
        $results.Add((New-DemoResult -CheckId 'OIDC.GITHUB' -Area 'infra' -Target 'github' -Status 'Manual action required' -Message ('{0} isn''t an administrator of {1}, and only administrators create environments.' -f $github.Login, $Repository) -Remediation 'An administrator of the repository runs setup-github-oidc.ps1 -ConfigureGitHub.' -DocUrl $environmentDoc))
        return $results.ToArray()
    }
    $secrets = [ordered]@{}
    foreach ($key in $identifiers.Keys) {
        $secrets[$key] = $identifiers[$key]
    }
    $secrets['DBHUB_CONFIG_JSON'] = if ($ConfigJson) { $ConfigJson } else { $Config | ConvertTo-Json -Depth 32 -Compress }
    foreach ($name in $Environment) {
        foreach ($item in @(Set-DemoGitHubEnvironment -Repository $Repository -Name $name -GitHub $github -Secret $secrets -Confirm:$false)) {
            $results.Add($item)
        }
    }
    if ($scheduleName) {
        foreach ($item in @(Set-DemoGitHubEnvironment -Repository $Repository -Name $scheduleName -GitHub $github -Secret $secrets -NoReviewer -Confirm:$false)) {
            $results.Add($item)
        }
        $variable = Invoke-DemoGitHubCli -ArgumentList @('variable', 'set', 'DBHUB_SCHEDULE_ENVIRONMENT', '--repo', $Repository) -InputText $scheduleName
        if ($variable.ExitCode -ne 0) {
            $results.Add((New-DemoResult -CheckId 'OIDC.GITHUB.SCHEDULE' -Area 'infra' -Target 'github' -Status 'Fail' -Message ('Setting the repository variable DBHUB_SCHEDULE_ENVIRONMENT failed: {0}' -f ([string]$variable.StdErr).Trim()) -Remediation ('gh variable set DBHUB_SCHEDULE_ENVIRONMENT --repo {0} --body {1}' -f $Repository, $scheduleName) -DocUrl 'https://cli.github.com/manual/gh_variable_set'))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'OIDC.GITHUB.SCHEDULE' -Area 'infra' -Target 'github' -Status 'Pass' -Message ('Scheduled runs use {0}, which has no required reviewers, so they don''t wait for an approval; a run by hand uses {1}, and the shared runner refuses {0} outside a schedule (ADR 0022).' -f $scheduleName, $Environment[0]) -DocUrl $environmentDoc))
        }
        $results.Add((New-DemoResult -CheckId 'OIDC.GITHUB.SCHEDULES' -Area 'infra' -Target 'github' -Status 'Not selected' -Message 'The schedules stay off: this script never turns them on.' -Remediation ('To turn them on: gh variable set DBHUB_SCHEDULES_ENABLED --repo {0} --body true' -f $Repository) -DocUrl 'https://cli.github.com/manual/gh_variable_set'))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'OIDC.GITHUB.SCHEDULE' -Area 'infra' -Target 'github' -Status 'Not selected' -Message ('No schedule environment (-ScheduleEnvironment): if you turn the schedules on, each scheduled run waits for a reviewer to approve it in {0}.' -f $Environment[0]) -DocUrl $environmentDoc))
    }
    return $results.ToArray()
}
