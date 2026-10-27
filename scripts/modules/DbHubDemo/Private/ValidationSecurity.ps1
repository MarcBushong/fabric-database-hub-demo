function Invoke-DemoValidationSecurity {
    <#
    .SYNOPSIS
    The Security area: secret scans of the local output, the Run Command instance views, and the ARM
    deployments (ADR 0009); the Contributor-only footprint (no role assignments unless assignRoles, no Key
    Vault, ADR 0008); and network exposure (no public IP on a VM, no inbound rule from the internet, ADR 0007).
    Every call reads; nothing changes. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context,

        [AllowEmptyCollection()]
        [string[]] $ScanPath = @(),

        [string] $OutputRoot = (Join-Path -Path $script:RepoRoot -ChildPath 'out'),

        [ValidateRange(1, 500)]
        [int] $MaxDeployments = 25
    )

    $config = $Context.Config
    $group = $Context.ResourceGroup
    $results = [System.Collections.Generic.List[object]]::new()
    $adr = 'ADR 0009'

    # 1. Local output: out/ (script output, JSON lines, transcripts) and anything passed in -ScanPath, such as
    #    downloaded GitHub Actions logs or an exported notebook.
    $outputDoc = 'https://docs.github.com/actions/reference/workflows-and-actions/workflow-commands#masking-a-value-in-a-log'
    $roots = @(@($OutputRoot) + @($ScanPath) | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($roots.Count -eq 0) {
        $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETSCAN.OUTPUT' -Area 'security' -Target 'repo' -Status 'Not selected' -Message 'There''s no local output to scan: out/ doesn''t exist and no -ScanPath was given.' -Remediation 'Save a run''s output in out/ (for example Start-Transcript -Path ./out/run.log, or gh run view <run-id> --log > ./out/actions.log), then run validate.ps1 -Area Security.' -DocUrl $outputDoc))
    }
    else {
        $scan = Find-DemoSecretLeak -Path $roots
        $scanned = @($scan.Scanned)
        $evidence = [ordered]@{
            roots           = @($roots | ForEach-Object { ConvertTo-DemoValidationRelativePath -Path $_ })
            filesScanned    = $scanned.Count
            filesSkipped    = @($scan.Skipped).Count
            skipped         = @($scan.Skipped | Select-Object -First 10 | ForEach-Object { '{0} ({1})' -f (ConvertTo-DemoValidationRelativePath -Path $_.Source), $_.Reason })
            rules           = @($script:RedactionRules | ForEach-Object { $_.Name })
            registeredCount = $script:DemoSecrets.Count
        }
        if (@($scan.Findings).Count -gt 0) {
            $evidence['findings'] = @(ConvertTo-DemoValidationFindingEvidence -Finding $scan.Findings)
            $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETSCAN.OUTPUT' -Area 'security' -Target 'repo' -Status 'Fail' -Message ('{0} secret or token pattern match(es) in {1}: {2}.' -f @($scan.Findings).Count, ($evidence['roots'] -join ', '), (Format-DemoValidationFindingSummary -Finding $scan.Findings)) -Evidence $evidence -Remediation ('Delete the files, rotate any real credential they hold, and find the script that wrote it: output must go through Write-DemoLog and Export-DemoResult ({0}). Excerpts in the evidence are redacted.' -f $adr) -DocUrl $outputDoc))
        }
        elseif ($scanned.Count -eq 0) {
            $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETSCAN.OUTPUT' -Area 'security' -Target 'repo' -Status 'Not selected' -Message ('There''s no readable text output to scan in {0}.' -f ($evidence['roots'] -join ', ')) -Evidence $evidence -DocUrl $outputDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETSCAN.OUTPUT' -Area 'security' -Target 'repo' -Status 'Pass' -Message ('No secret or token pattern, and no value registered in this session, in {0} file(s) under {1}.' -f $scanned.Count, ($evidence['roots'] -join ', ')) -Evidence $evidence -DocUrl $outputDoc))
        }
    }
    if (-not $Context.GroupExists) {
        return $results.ToArray()
    }

    # 2. Run Command instance views on the selected VMs: the last 4 KB of output and error that Azure keeps,
    #    and the scripts and public parameters (protected parameters are never returned).
    $runCommandDoc = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'
    $apiVersion = Get-DemoRunCommandApiVersion
    $findings = [System.Collections.Generic.List[object]]::new()
    $read = [System.Collections.Generic.List[string]]::new()
    $notRunning = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($vmName in @($Context.VmNames.Values)) {
        $state = Get-DemoValidationVmState -Context $Context -VmName $vmName
        if (-not $state.Running) {
            $notRunning.Add(('{0} ({1})' -f $vmName, $state.PowerState))
            continue
        }
        $baseUrl = Get-DemoRunCommandBaseUrl -SubscriptionId $Context.SubscriptionId -ResourceGroupName $group -VmName $vmName
        $list = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('{0}?api-version={1}' -f $baseUrl, $apiVersion))
        if (-not $list.Ok) {
            $errors.Add(('{0}: {1}' -f $vmName, $list.Error))
            continue
        }
        foreach ($item in (Get-DemoMemberList -InputObject $list.Value -Name 'value')) {
            $name = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
            $view = Invoke-DemoAz -SubscriptionId $Context.SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('{0}/{1}?api-version={2}&$expand=instanceView' -f $baseUrl, $name, $apiVersion)) -AllowFailure
            if ($view.ExitCode -ne 0) {
                $errors.Add(('{0}/{1}: {2}' -f $vmName, $name, (Protect-DemoText -Text ([string]$view.StdErr).Trim())))
                continue
            }
            $source = '{0}/runCommands/{1}' -f $vmName, $name
            foreach ($finding in @((Find-DemoSecretLeak -Text ([string]$view.StdOut) -Source $source).Findings)) {
                $findings.Add($finding)
            }
            $read.Add($source)
        }
    }
    $evidence = [ordered]@{ runCommandsScanned = $read.ToArray(); vmsNotRunning = $notRunning.ToArray(); readErrors = $errors.ToArray() }
    if ($findings.Count -gt 0) {
        $evidence['findings'] = @(ConvertTo-DemoValidationFindingEvidence -Finding $findings)
        $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETSCAN.RUNCOMMANDS' -Area 'security' -Target 'subscription' -Status 'Fail' -Message ('{0} secret or token pattern match(es) in Run Command instance views: {1}.' -f $findings.Count, (Format-DemoValidationFindingSummary -Finding $findings)) -Evidence $evidence -Remediation ('Delete the Run Command (az vm run-command delete --subscription {1} --resource-group {2} --vm-name <vm> --name <name>), rotate any real credential, and fix the VM-side script so it prints no secret ({0}).' -f $adr, $Context.SubscriptionId, $group) -DocUrl $runCommandDoc))
    }
    elseif ($read.Count -eq 0 -and $notRunning.Count -gt 0) {
        $verb = if ($notRunning.Count -eq 1) { 'isn''t' } else { 'aren''t' }
        $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETSCAN.RUNCOMMANDS' -Area 'security' -Target 'subscription' -Status 'Warning' -Message ('The Run Command instance views weren''t scanned, because {0} {1} running: a VM''s instance views are empty while it''s deallocated.' -f ($notRunning -join ' and '), $verb) -Evidence $evidence -Remediation 'Start the demo (./scripts/start-demo.ps1), then run validate.ps1 -Area Security again.' -DocUrl $runCommandDoc))
    }
    elseif ($errors.Count -gt 0 -or $notRunning.Count -gt 0) {
        $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETSCAN.RUNCOMMANDS' -Area 'security' -Target 'subscription' -Status 'Warning' -Message ('No secret in the {0} Run Command instance view(s) read, but the scan is incomplete: {1}.' -f $read.Count, ((@($notRunning | ForEach-Object { '{0} isn''t running' -f $_ }) + @($errors)) -join '; ')) -Evidence $evidence -Remediation 'Start the demo, then run validate.ps1 -Area Security again.' -DocUrl $runCommandDoc))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETSCAN.RUNCOMMANDS' -Area 'security' -Target 'subscription' -Status 'Pass' -Message ('No secret or token pattern in the {0} Run Command instance view(s) on {1}.' -f $read.Count, (@($Context.VmNames.Values) -join ' and ')) -Evidence $evidence -DocUrl $runCommandDoc))
    }

    # 3. ARM deployments: the newest deployments in the resource group and the environment's subscription-scope
    #    deployments, with their parameters, outputs, errors, and operations.
    $deploymentDoc = 'https://learn.microsoft.com/azure/azure-resource-manager/templates/deployment-history'
    $findings = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $scannedDeployments = [System.Collections.Generic.List[string]]::new()
    $groupList = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('deployment', 'group', 'list', '--resource-group', $group)
    $subscriptionList = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('deployment', 'sub', 'list')
    foreach ($list in $groupList, $subscriptionList) {
        if (-not $list.Ok) {
            $errors.Add($list.Error)
        }
    }
    $environmentPrefix = '{0}-{1}-' -f $config['prefix'], $config['environment']
    $candidates = @(
        @($groupList.Value) | Where-Object { $null -ne $_ } | ForEach-Object { [pscustomobject]@{ Scope = 'group'; Deployment = $_ } }
        @($subscriptionList.Value) | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -like ($environmentPrefix + '*') } | ForEach-Object { [pscustomobject]@{ Scope = 'sub'; Deployment = $_ } }
    )
    $ordered = @($candidates | Sort-Object -Property { ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $_.Deployment -Name 'properties') -Name 'timestamp') } -Descending)
    $selected = @($ordered | Select-Object -First $MaxDeployments)
    foreach ($candidate in $selected) {
        $name = [string](Get-DemoMemberValue -InputObject $candidate.Deployment -Name 'name')
        $source = if ($candidate.Scope -eq 'group') { 'deployment {0}' -f $name } else { 'subscription deployment {0}' -f $name }
        $text = $candidate.Deployment | ConvertTo-Json -Depth 64 -Compress
        foreach ($finding in @((Find-DemoSecretLeak -Text $text -Source $source).Findings)) {
            $findings.Add($finding)
        }
        $operationArguments = if ($candidate.Scope -eq 'group') { @('deployment', 'operation', 'group', 'list', '--resource-group', $group, '--name', $name) } else { @('deployment', 'operation', 'sub', 'list', '--name', $name) }
        $operations = Invoke-DemoAz -SubscriptionId $Context.SubscriptionId -ArgumentList ($operationArguments + @('--output', 'json')) -AllowFailure
        if ($operations.ExitCode -ne 0) {
            $errors.Add(('{0}: {1}' -f $source, (Protect-DemoText -Text ([string]$operations.StdErr).Trim())))
        }
        else {
            foreach ($finding in @((Find-DemoSecretLeak -Text ([string]$operations.StdOut) -Source ('{0} operations' -f $source)).Findings)) {
                $findings.Add($finding)
            }
        }
        $scannedDeployments.Add($source)
    }
    $evidence = [ordered]@{ deploymentsScanned = $scannedDeployments.Count; deploymentsSkipped = [System.Math]::Max(0, $ordered.Count - $selected.Count); maxDeployments = $MaxDeployments; readErrors = $errors.ToArray() }
    if ($findings.Count -gt 0) {
        $evidence['findings'] = @(ConvertTo-DemoValidationFindingEvidence -Finding $findings)
        $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETSCAN.DEPLOYMENTS' -Area 'security' -Target 'subscription' -Status 'Fail' -Message ('{0} secret or token pattern match(es) in ARM deployments: {1}.' -f $findings.Count, (Format-DemoValidationFindingSummary -Finding $findings)) -Evidence $evidence -Remediation ('Delete the deployment from the history (az deployment group delete --subscription {2} --resource-group {0} --name <name>), rotate any real credential, and make the value a @secure() parameter that no output returns ({1}).' -f $group, $adr, $Context.SubscriptionId) -DocUrl $deploymentDoc))
    }
    elseif ($errors.Count -gt 0) {
        $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETSCAN.DEPLOYMENTS' -Area 'security' -Target 'subscription' -Status 'Warning' -Message ('No secret in the {0} deployment(s) read, but some couldn''t be read: {1}' -f $scannedDeployments.Count, ($errors -join '; ')) -Evidence $evidence -Remediation 'Run validate.ps1 -Area Security again.' -DocUrl $deploymentDoc))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETSCAN.DEPLOYMENTS' -Area 'security' -Target 'subscription' -Status 'Pass' -Message ('No secret or token pattern in the parameters, outputs, errors, and operations of the {0} newest deployment(s) in {1} and the environment''s subscription deployments.' -f $scannedDeployments.Count, $group) -Evidence $evidence -DocUrl $deploymentDoc))
    }

    # 4. Role assignments at or below the resource group (ADR 0008): none unless assignRoles is true. With the
    #    Key Vault opt-in (keyVault.enabled, Phase 13), its two data-plane roles are expected on that vault only.
    $rbacDoc = 'https://learn.microsoft.com/cli/azure/role/assignment#az-role-assignment-list'
    $groupScope = '/subscriptions/{0}/resourceGroups/{1}' -f $Context.SubscriptionId, $group
    $vaultOptIn = Get-DemoValidationKeyVaultOptIn -Context $Context
    $assignments = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('role', 'assignment', 'list', '--all', '--fill-principal-name', 'false')
    $permissions = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01' -f $Context.SubscriptionId))
    $canAssign = $permissions.Ok -and (Test-DemoPermission -Permission (Get-DemoMemberList -InputObject $permissions.Value -Name 'value') -Action 'Microsoft.Authorization/roleAssignments/write')
    if (-not $assignments.Ok) {
        $results.Add((New-DemoResult -CheckId 'SECURITY.RBAC.ROLEASSIGNMENTS' -Area 'security' -Target 'subscription' -Status 'Warning' -Message ('The role assignments couldn''t be read: {0}' -f $assignments.Error) -Remediation 'Run validate.ps1 -Area Security again; reading role assignments needs Reader or higher.' -DocUrl $rbacDoc))
    }
    else {
        $inGroup = @(@($assignments.Value) | Where-Object {
                $null -ne $_ -and ([string](Get-DemoMemberValue -InputObject $_ -Name 'scope')).StartsWith($groupScope, [System.StringComparison]::OrdinalIgnoreCase)
            })
        $expectedRoles = @('Reader', [string](Get-DemoHubSetting)['arcTelemetryRole']['roleName'])
        if ($config['assignRoles']) {
            $expectedRoles += 'Azure Connected Machine Onboarding'
        }
        $vaultScope = '{0}/providers/Microsoft.KeyVault/vaults/' -f $groupScope
        $controlOn = (Get-DemoActivityControlSetting -Config $config).Enabled
        $isExpected = {
            param([object] $Assignment)
            $role = [string](Get-DemoMemberValue -InputObject $Assignment -Name 'roleDefinitionName')
            if ($role -in $expectedRoles) {
                return $true
            }
            $scope = [string](Get-DemoMemberValue -InputObject $Assignment -Name 'scope')
            # A1 of the on-demand activity control (ADR 0020): its custom role for its identity, at the group itself.
            if ($controlOn -and $role -eq $script:ActivityControlRoleName -and [string]::Equals($scope, $groupScope, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
            if (-not $vaultOptIn.Enabled -or $role -notin @('Key Vault Secrets Officer', 'Key Vault Secrets User') -or -not $scope.StartsWith($vaultScope, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }
            $vaultName = $scope.Substring($vaultScope.Length)
            return ($vaultName -and $vaultName -notmatch '/' -and $vaultName -match $vaultOptIn.Pattern)
        }
        $unexpected = @($inGroup | Where-Object { -not (& $isExpected $_) })
        $describe = {
            param([object[]] $Items)
            @($Items | ForEach-Object { '{0} for a {1} at {2}' -f [string](Get-DemoMemberValue -InputObject $_ -Name 'roleDefinitionName'), [string](Get-DemoMemberValue -InputObject $_ -Name 'principalType'), (([string](Get-DemoMemberValue -InputObject $_ -Name 'scope')).Substring($groupScope.Length) -replace '^$', 'the resource group') }) -join '; '
        }
        $contributorNote = if ($canAssign) { ' The caller can also create role assignments, so this run alone doesn''t prove the Contributor-only path.' } else { ' The caller can''t create role assignments, so this run exercises the Contributor-only path.' }
        $evidence = [ordered]@{ assignmentsInGroup = $inGroup.Count; unexpected = $unexpected.Count; assignRoles = [bool]$config['assignRoles']; keyVaultOptIn = [bool]$vaultOptIn.Enabled; callerCanAssignRoles = [bool]$canAssign; roles = @($inGroup | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'roleDefinitionName') }) }
        if ($unexpected.Count -gt 0) {
            $results.Add((New-DemoResult -CheckId 'SECURITY.RBAC.ROLEASSIGNMENTS' -Area 'security' -Target 'subscription' -Status 'Warning' -Message ('Role assignments that the demo never creates are at or below {0}: {1}.{2}' -f $group, (& $describe $unexpected), $contributorNote) -Evidence $evidence -Remediation 'Check who added them and why; the demo needs none, presenters need only Reader and the Arc telemetry role, the Key Vault opt-in needs only Key Vault Secrets Officer and Key Vault Secrets User on its vault, and the on-demand activity control only its custom role for its identity at the group (A1; docs/permissions.md).' -DocUrl $rbacDoc))
        }
        elseif ($inGroup.Count -gt 0) {
            $results.Add((New-DemoResult -CheckId 'SECURITY.RBAC.ROLEASSIGNMENTS' -Area 'security' -Target 'subscription' -Status 'Pass' -Message ('Only the documented optional roles are assigned at or below {0}: {1}.{2}' -f $group, (& $describe $inGroup), $contributorNote) -Evidence $evidence -DocUrl $rbacDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'SECURITY.RBAC.ROLEASSIGNMENTS' -Area 'security' -Target 'subscription' -Status 'Pass' -Message ('No role assignments at or below {0}: the deployment created none (ADR 0008).{1}' -f $group, $contributorNote) -Evidence $evidence -DocUrl $rbacDoc))
        }
    }

    # 5. Key Vaults (ADR 0009): none by default, because the default deployment stores no secret. With the opt-in
    #    (keyVault.enabled, Phase 13), only that vault, with Azure RBAC authorization and soft delete; its
    #    control-plane properties are read with 'az keyvault show' (https://learn.microsoft.com/cli/azure/keyvault).
    $vaultDoc = 'https://learn.microsoft.com/azure/key-vault/general/rbac-guide'
    $vaults = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('resource', 'list', '--resource-group', $group, '--resource-type', 'Microsoft.KeyVault/vaults')
    if (-not $vaults.Ok) {
        $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETS.KEYVAULT' -Area 'security' -Target 'subscription' -Status 'Warning' -Message ('The resource group''s Key Vaults couldn''t be listed: {0}' -f $vaults.Error) -Remediation 'Run validate.ps1 -Area Security again.' -DocUrl $vaultDoc))
    }
    elseif (-not $vaultOptIn.Enabled) {
        $names = @(@($vaults.Value) | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
        if ($names.Count -gt 0) {
            $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETS.KEYVAULT' -Area 'security' -Target 'subscription' -Status 'Warning' -Message ('A Key Vault is in {0} ({1}), but the demo creates none while keyVault.enabled is false: VM passwords are used only at creation, and nothing secret is stored.' -f $group, ($names -join ', ')) -Evidence @{ vaults = $names; keyVaultOptIn = $false } -Remediation 'Check who added it and what it holds. The optional P9 GitHub token belongs in a vault you own outside the demo resource group; a vault the Key Vault opt-in left behind goes with keyVault.enabled set back to true or with the resource group (ADR 0009).' -DocUrl $vaultDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETS.KEYVAULT' -Area 'security' -Target 'subscription' -Status 'Pass' -Message ('No Key Vault in {0}: the default deployment stores no secret, so Contributor needs no data-plane role (ADR 0008, ADR 0009).' -f $group) -Evidence @{ keyVaultOptIn = $false } -DocUrl $vaultDoc))
        }
    }
    else {
        $names = @(@($vaults.Value) | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
        $optInVaults = @($names | Where-Object { $_ -match $vaultOptIn.Pattern })
        $others = @($names | Where-Object { $_ -notmatch $vaultOptIn.Pattern })
        $expectedName = if ($vaultOptIn.Name) { $vaultOptIn.Name } else { 'kv-<prefix><environment>-{0}' -f $Context.DeploymentId }
        $evidence = [ordered]@{ keyVaultOptIn = $true; expectedVault = $expectedName; vaults = $names }
        $problems = [System.Collections.Generic.List[string]]::new()
        if ($others.Count -gt 0) {
            $problems.Add(('other vaults are there too: {0}' -f ($others -join ', ')))
        }
        $summary = ''
        if ($optInVaults.Count -eq 0) {
            $problems.Insert(0, ('the opt-in vault {0} isn''t there' -f $expectedName))
        }
        else {
            $show = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('keyvault', 'show', '--name', $optInVaults[0], '--resource-group', $group)
            if (-not $show.Ok) {
                $problems.Insert(0, ('the properties of {0} couldn''t be read: {1}' -f $optInVaults[0], $show.Error))
            }
            else {
                $properties = Get-DemoMemberValue -InputObject $show.Value -Name 'properties'
                $acls = Get-DemoMemberValue -InputObject $properties -Name 'networkAcls'
                $evidence['rbacAuthorization'] = [bool](Get-DemoMemberValue -InputObject $properties -Name 'enableRbacAuthorization')
                $evidence['softDelete'] = (Get-DemoMemberValue -InputObject $properties -Name 'enableSoftDelete') -ne $false
                $evidence['softDeleteRetentionDays'] = Get-DemoMemberValue -InputObject $properties -Name 'softDeleteRetentionInDays'
                $evidence['purgeProtection'] = [bool](Get-DemoMemberValue -InputObject $properties -Name 'enablePurgeProtection')
                $evidence['publicNetworkAccess'] = [string](Get-DemoMemberValue -InputObject $properties -Name 'publicNetworkAccess')
                $evidence['firewallDefaultAction'] = [string](Get-DemoMemberValue -InputObject $acls -Name 'defaultAction')
                $ipRules = Get-DemoMemberList -InputObject $acls -Name 'ipRules'
                $evidence['allowedIpRules'] = $ipRules.Count
                if (-not $evidence['rbacAuthorization']) {
                    $problems.Insert(0, ('{0} uses access policies, not Azure RBAC' -f $optInVaults[0]))
                }
                if (-not $evidence['softDelete']) {
                    $problems.Add(('soft delete is off on {0}' -f $optInVaults[0]))
                }
                $summary = 'Azure RBAC authorization, soft delete for {0} days, purge protection {1}, firewall default action {2}' -f $evidence['softDeleteRetentionDays'], $(if ($evidence['purgeProtection']) { 'on' } else { 'off' }), $(if ($evidence['firewallDefaultAction']) { $evidence['firewallDefaultAction'] } else { 'unknown' })
            }
        }
        if ($problems.Count -gt 0) {
            $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETS.KEYVAULT' -Area 'security' -Target 'subscription' -Status 'Warning' -Message ('keyVault.enabled is true, but {0} in {1}.' -f ($problems -join '; '), $group) -Evidence $evidence -Remediation 'Run deploy.ps1 -Resume, which deploys the opt-in vault with Azure RBAC and soft delete (INFRA.KEYVAULT); check who added any other vault and what it holds (ADR 0009).' -DocUrl $vaultDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'SECURITY.SECRETS.KEYVAULT' -Area 'security' -Target 'subscription' -Status 'Pass' -Message ('Only the opt-in Key Vault {0} is in {1} (keyVault.enabled): {2}. It holds only the one-time T2 host password (ADR 0009).' -f $optInVaults[0], $group, $summary) -Evidence $evidence -DocUrl $vaultDoc))
        }
    }

    # 6. Network exposure (ADR 0007): no public IP on a VM, and no inbound allow from the internet on the VM and
    #    private-endpoint subnets. AzureBastionSubnet's NSG must allow HTTPS from the internet for Bastion.
    $publicIpDoc = 'https://learn.microsoft.com/azure/virtual-network/ip-services/public-ip-addresses'
    $interfaces = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('network', 'nic', 'list', '--resource-group', $group)
    if (-not $interfaces.Ok) {
        $results.Add((New-DemoResult -CheckId 'SECURITY.NETWORK.NOPUBLICIP' -Area 'security' -Target 'subscription' -Status 'Warning' -Message ('The network interfaces couldn''t be read: {0}' -f $interfaces.Error) -Remediation 'Run validate.ps1 -Area Security again.' -DocUrl $publicIpDoc))
    }
    else {
        $exposed = @(foreach ($nic in @($interfaces.Value) | Where-Object { $null -ne $_ }) {
                foreach ($configuration in (Get-DemoMemberList -InputObject $nic -Name 'ipConfigurations')) {
                    if ($null -ne (Get-DemoMemberValue -InputObject $configuration -Name 'publicIPAddress')) {
                        [string](Get-DemoMemberValue -InputObject $nic -Name 'name')
                    }
                }
            })
        $nicNames = @(@($interfaces.Value) | Where-Object { $null -ne $_ } | ForEach-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') })
        if ($exposed.Count -gt 0) {
            $results.Add((New-DemoResult -CheckId 'SECURITY.NETWORK.NOPUBLICIP' -Area 'security' -Target 'subscription' -Status 'Fail' -Message ('A public IP is attached to {0}; the demo''s VMs have none, and interactive access goes through on-demand Bastion (ADR 0007).' -f ($exposed -join ', ')) -Evidence @{ networkInterfaces = $nicNames; exposed = $exposed } -Remediation ('Dissociate and delete the public IP (az network nic ip-config update --subscription {0} --resource-group {1} --nic-name <nic> --name <ip-config> --remove publicIpAddress), and use Bastion instead.' -f $Context.SubscriptionId, $group) -DocUrl $publicIpDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'SECURITY.NETWORK.NOPUBLICIP' -Area 'security' -Target 'subscription' -Status 'Pass' -Message ('None of the {0} network interfaces in {1} has a public IP.' -f $nicNames.Count, $group) -Evidence @{ networkInterfaces = $nicNames } -DocUrl $publicIpDoc))
        }
    }
    $nsgDoc = 'https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview'
    $prefix = '{0}-{1}' -f $config['prefix'], $config['environment']
    $guarded = @(('nsg-{0}-sqlvm' -f $prefix), ('nsg-{0}-archost' -f $prefix), ('nsg-{0}-pe' -f $prefix))
    $groups = Read-DemoValidationAzJson -SubscriptionId $Context.SubscriptionId -ArgumentList @('network', 'nsg', 'list', '--resource-group', $group)
    if (-not $groups.Ok) {
        $results.Add((New-DemoResult -CheckId 'SECURITY.NETWORK.INBOUND' -Area 'security' -Target 'subscription' -Status 'Warning' -Message ('The network security groups couldn''t be read: {0}' -f $groups.Error) -Remediation 'Run validate.ps1 -Area Security again.' -DocUrl $nsgDoc))
    }
    else {
        $open = [System.Collections.Generic.List[string]]::new()
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($nsg in @($groups.Value) | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -in $guarded }) {
            $nsgName = [string](Get-DemoMemberValue -InputObject $nsg -Name 'name')
            $found.Add($nsgName)
            foreach ($rule in (Get-DemoMemberList -InputObject $nsg -Name 'securityRules')) {
                if ([string](Get-DemoMemberValue -InputObject $rule -Name 'direction') -ne 'Inbound' -or [string](Get-DemoMemberValue -InputObject $rule -Name 'access') -ne 'Allow') {
                    continue
                }
                $prefixes = Get-DemoMemberList -InputObject $rule -Name 'sourceAddressPrefixes'
                $sources = @([string](Get-DemoMemberValue -InputObject $rule -Name 'sourceAddressPrefix')) + @($prefixes | ForEach-Object { [string]$_ })
                if (@($sources | Where-Object { $_ -in '*', 'Internet', '0.0.0.0/0', 'Any' }).Count -gt 0) {
                    $open.Add(('{0}/{1}' -f $nsgName, [string](Get-DemoMemberValue -InputObject $rule -Name 'name')))
                }
            }
        }
        $missingGroups = @($guarded | Where-Object { $_ -notin $found })
        if ($open.Count -gt 0) {
            $results.Add((New-DemoResult -CheckId 'SECURITY.NETWORK.INBOUND' -Area 'security' -Target 'subscription' -Status 'Fail' -Message ('Inbound rules allow traffic from the internet to the VM or private-endpoint subnets: {0}.' -f ($open -join ', ')) -Evidence @{ rules = $open.ToArray() } -Remediation ('Delete those rules (az network nsg rule delete --subscription {0} --resource-group {1} --nsg-name <nsg> --name <rule>) or deploy again (deploy.ps1 -Resume); RDP comes only from AzureBastionSubnet (ADR 0007).' -f $Context.SubscriptionId, $group) -DocUrl $nsgDoc))
        }
        elseif ($missingGroups.Count -gt 0) {
            $results.Add((New-DemoResult -CheckId 'SECURITY.NETWORK.INBOUND' -Area 'security' -Target 'subscription' -Status 'Fail' -Message ('Network security groups are missing: {0}.' -f ($missingGroups -join ', ')) -Remediation 'Deploy again (deploy.ps1 -Resume) to restore them (ADR 0007).' -DocUrl $nsgDoc))
        }
        else {
            $results.Add((New-DemoResult -CheckId 'SECURITY.NETWORK.INBOUND' -Area 'security' -Target 'subscription' -Status 'Pass' -Message ('No inbound rule in {0} allows traffic from the internet; RDP reaches the VMs only from AzureBastionSubnet (ADR 0007).' -f ($guarded -join ', ')) -Evidence @{ networkSecurityGroups = $guarded } -DocUrl $nsgDoc))
        }
    }
    return $results.ToArray()
}

function Invoke-DemoValidationTeardown {
    <#
    .SYNOPSIS
    The Teardown area, read-only: what destroy.ps1 would leave behind. With the environment deployed, nothing
    tagged for it may be outside its resource group, which destroy deletes; after destroy, nothing tagged for
    it may remain at all, Arc resources included (ADR 0002). Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Context
    )

    $config = $Context.Config
    $group = $Context.ResourceGroup
    $control = 'rg-{0}-control' -f $config['prefix']
    $docUrl = 'https://learn.microsoft.com/azure/governance/resource-graph/reference/supported-tables-resources'
    if (-not $Context.GroupExists -and -not $Context.GroupNotFound) {
        return @(New-DemoResult -CheckId 'TEARDOWN.RESIDUAL' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('The resource group {0} couldn''t be read, so the residual check didn''t run: {1}' -f $group, $Context.GroupError) -Remediation 'Check that you can read the subscription (Reader or higher), then run validate.ps1 -Area Teardown again.' -DocUrl $docUrl)
    }
    $query = Format-DemoKqlTemplate -Name 'ResourceGraph.Residual' -Parameters @{
        SubscriptionId = ConvertTo-DemoKqlLiteral -Value $Context.SubscriptionId -Type String
        ResourceGroup  = ConvertTo-DemoKqlLiteral -Value $group -Type String
        ControlGroup   = ConvertTo-DemoKqlLiteral -Value $control -Type String
        Environment    = ConvertTo-DemoKqlLiteral -Value ([string]$config['environment']) -Type String
        DeploymentId   = ConvertTo-DemoKqlLiteral -Value $Context.DeploymentId -Type String
    }
    $graph = Invoke-DemoHubResourceGraph -SubscriptionId $Context.SubscriptionId -Query $query
    if (-not $graph.Succeeded) {
        return @(New-DemoResult -CheckId 'TEARDOWN.RESIDUAL' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('Azure Resource Graph couldn''t be queried for residual resources: {0}' -f $graph.Error) -Remediation 'Check that you can read the subscription (Reader or higher), then run validate.ps1 -Area Teardown again.' -DocUrl $docUrl)
    }
    $rows = @($graph.Rows)
    $isGroup = { param($Row) [string](Get-DemoMemberValue -InputObject $Row -Name 'type') -ieq 'microsoft.resources/subscriptions/resourcegroups' }
    $groupOf = { param($Row) [string](Get-DemoMemberValue -InputObject $Row -Name 'resourceGroup') }
    $controlExists = @($rows | Where-Object { (& $isGroup $_) -and [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -ieq $control }).Count -gt 0
    $kept = @($rows | Where-Object { (& $groupOf $_) -ieq $control })
    $inside = @($rows | Where-Object { -not (& $isGroup $_) -and (& $groupOf $_) -ieq $group })
    $outside = @($rows | Where-Object { (& $groupOf $_) -ine $group -and (& $groupOf $_) -ine $control })
    $describe = { param([object[]] $Items) @($Items | Select-Object -First 20 | ForEach-Object { '{0} ({1}, {2})' -f [string](Get-DemoMemberValue -InputObject $_ -Name 'name'), [string](Get-DemoMemberValue -InputObject $_ -Name 'type'), (& $groupOf $_) }) -join '; ' }
    $evidence = [ordered]@{
        environment         = [string]$config['environment']
        deploymentId        = $Context.DeploymentId
        resourceGroupExists = $Context.GroupExists
        resourcesInGroup    = $inside.Count
        outsideGroup        = $outside.Count
        controlGroupExists  = $controlExists
        controlGroupKept    = $kept.Count
        truncated           = [bool]$graph.Truncated
    }
    $controlNote = if ($controlExists) { ' {0}, the GitHub identity''s resource group, is kept by design (ADR 0002).' -f $control } else { '' }
    $lag = ' Resource Graph can lag a few minutes behind a delete.'
    if ($Context.GroupExists) {
        if ($outside.Count -gt 0) {
            return @(New-DemoResult -CheckId 'TEARDOWN.RESIDUAL' -Area 'teardown' -Target 'subscription' -Status 'Warning' -Message ('{0} resource(s) tagged for this environment are outside {1}, so destroy.ps1 wouldn''t delete them: {2}.{3}' -f $outside.Count, $group, (& $describe $outside), $controlNote) -Evidence $evidence -Remediation 'Move them into the demo resource group or delete them with the demo; destroy.ps1 deletes only the Arc resources and the demo resource group (ADR 0002).' -DocUrl $docUrl)
        }
        return @(New-DemoResult -CheckId 'TEARDOWN.RESIDUAL' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('The environment is deployed: destroy.ps1 deletes {0} and the {1} resource(s) Resource Graph lists in it, and nothing tagged for the environment is outside it.{2}' -f $group, $inside.Count, $controlNote) -Evidence $evidence -DocUrl $docUrl)
    }
    # After destroy, anything left counts, including rows Resource Graph still lists in the deleted group.
    $residual = @($rows | Where-Object { (& $groupOf $_) -ine $control })
    if ($residual.Count -gt 0) {
        return @(New-DemoResult -CheckId 'TEARDOWN.RESIDUAL' -Area 'teardown' -Target 'subscription' -Status 'Fail' -Message ('{0} is gone, but {1} resource(s) of the environment remain: {2}.{3}' -f $group, $residual.Count, (& $describe $residual), $lag) -Evidence $evidence -Remediation ('Delete them (Arc SQL Server instances before their machine; az resource delete --subscription {0} --resource-group <group> --name <name> --resource-type <type>), then run validate.ps1 -Area Teardown again.' -f $Context.SubscriptionId) -DocUrl $docUrl)
    }
    return @(New-DemoResult -CheckId 'TEARDOWN.RESIDUAL' -Area 'teardown' -Target 'subscription' -Status 'Pass' -Message ('Nothing tagged for environment ''{0}'' remains in the subscription, Arc resources included: zero residual resources.{1}{2}' -f $config['environment'], $controlNote, $lag) -Evidence $evidence -DocUrl $docUrl)
}

function ConvertTo-DemoValidationRelativePath {
    # A path relative to the repository root when it's inside it, for messages. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = $script:RepoRoot.TrimEnd([char[]]@('\', '/'))
    if ($full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $relative = $full.Substring($root.Length).TrimStart([char[]]@('\', '/'))
        if (-not $relative) {
            return '.'
        }
        return ($relative -replace '\\', '/')
    }
    return $full
}

function ConvertTo-DemoValidationFindingEvidence {
    # The first 20 secret-scan findings as evidence: source, line, rule, and the redacted excerpt. Internal.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Finding
    )

    @($Finding | Select-Object -First 20 | ForEach-Object {
            $source = [string]$_.Source
            if ([System.IO.Path]::IsPathRooted($source)) {
                $source = ConvertTo-DemoValidationRelativePath -Path $source
            }
            [ordered]@{ source = $source; line = $_.Line; rule = $_.Rule; excerpt = $_.Excerpt }
        })
}

function Format-DemoValidationFindingSummary {
    # "<count> <rule> in <source>" for the first findings, for a one-line message. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Finding
    )

    $groups = @($Finding | Group-Object -Property { '{0}|{1}' -f $_.Rule, $_.Source } | Select-Object -First 5)
    $parts = foreach ($groupItem in $groups) {
        $first = $groupItem.Group[0]
        $source = [string]$first.Source
        if ([System.IO.Path]::IsPathRooted($source)) {
            $source = ConvertTo-DemoValidationRelativePath -Path $source
        }
        '{0} {1} in {2} (line {3})' -f $groupItem.Count, $first.Rule, $source, $first.Line
    }
    return (@($parts) -join ', ')
}
