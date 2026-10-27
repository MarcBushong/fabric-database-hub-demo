function Get-DemoPolicyConstraint {
    <#
    .SYNOPSIS
    Reads the Azure Policy assignments that apply to the subscription and reports what they mean for the demo (read-only).

    .DESCRIPTION
    Lists the assignments that apply to the subscription, from the subscription itself and from the
    management groups above it ($filter=atScope()), expands policy sets, and resolves each rule's effect
    through the assignment's parameters, the set member's parameters, the set's defaults, and the
    definition's defaults, plus any policyEffect override. Rules with deny, modify, deployIfNotExists,
    append, or denyAction effects are kept. Assignments with enforcement mode DoNotEnforce are reported
    and skipped. Exemptions and assignments scoped to resource groups aren't read; the what-if check
    still catches denials.

    Every call is a GET ('az rest') through Invoke-DemoAz, made one at a time; each definition is read
    once. Large tenant policy sets can take a few minutes (about 2-3 seconds per definition), so
    preflight has -SkipPolicyInventory. A read failure is a Warning, never a Fail.

    Returns the kept rules with their category, the policies that turn off public network access on SQL
    servers, the resolved network mode (Resolve-DemoNetworkMode), and PREFLIGHT.POLICY.* results:
    INVENTORY, SQLPUBLIC, SQLENTRAONLY, VMSIZE, RESOURCETYPES, DEFENDER, EXTENSIONS, PUBLICIP, STORAGE,
    MFA, and OTHER. Call Assert-DemoAzContext first.

    .PARAMETER Config
    Configuration from Get-DemoConfig. Uses subscriptionId, networkMode, profile, t1Priority, and
    hostPriority.

    .PARAMETER CacheHours
    Reuse the last complete inventory when it's at most this many hours old and nothing it depends on
    changed: the assignments that apply to the subscription (every property), the configuration values
    above, the profile catalog, and this code (Get-DemoPolicyInventoryFingerprint). The assignments are
    always listed (a few seconds); only the definition reads are skipped, and the reused results say so.
    A complete inventory read while CacheHours is above 0 is saved to out/cache (Git-ignored) for the next
    run. 0 (the default) reads everything and saves nothing.

    .PARAMETER CacheDirectory
    Where the cache file lives. Defaults to out/cache under the repository.

    .EXAMPLE
    (Get-DemoPolicyConstraint -Config $config).Results | Format-Table checkId, status, message
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidateRange(0, 720)]
        [int] $CacheHours = 0,

        [string] $CacheDirectory = ''
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $apiVersion = '2023-04-01'
    $keptEffects = @{ deny = 'Deny'; modify = 'Modify'; deployifnotexists = 'DeployIfNotExists'; append = 'Append'; denyaction = 'DenyAction' }
    $assignments = [System.Collections.Generic.List[object]]::new()
    $rules = [System.Collections.Generic.List[object]]::new()
    $unreadable = [System.Collections.Generic.List[string]]::new()
    $doNotEnforce = [System.Collections.Generic.List[string]]::new()
    $results = [System.Collections.Generic.List[object]]::new()
    $definitions = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    $readErrors = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    $cachePath = ''
    $fingerprint = ''

    function Read-PolicyDefinition([string] $Id) {
        if (-not $definitions.ContainsKey($Id)) {
            $response = Get-DemoArmResource -SubscriptionId $subscriptionId -Url ('https://management.azure.com{0}?api-version={1}' -f $Id, $apiVersion)
            $definitions[$Id] = if ($response.Ok -and $response.Value -is [System.Collections.IDictionary]) { $response.Value } else { $null }
            $readErrors[$Id] = if ($response.Ok) { 'unexpected response' } else { $response.Error }
        }
        return $definitions[$Id]
    }

    # The label never includes the scope ID: management group IDs can be tenant IDs.
    function Format-PolicyId([string] $Id) {
        $kind = if ($Id -match '(?i)/managementGroups/') { 'management group' } elseif ($Id -match '(?i)^/subscriptions/') { 'subscription' } else { 'built-in' }
        '{0} ({1})' -f ($Id -split '/')[-1], $kind
    }

    function Format-PolicyList([object[]] $Rule, [int] $Maximum = 3) {
        $names = @($Rule | ForEach-Object { $_.Policy } | Select-Object -Unique)
        $text = (@($names | Select-Object -First $Maximum)) -join '; '
        if ($names.Count -gt $Maximum) {
            $text += ('; and {0} more' -f ($names.Count - $Maximum))
        }
        $text
    }

    function Add-PolicyResult([string] $Check, [string] $Status, [string] $Message, [hashtable] $Evidence = @{}, [string] $Remediation = '', [string] $DocUrl = '') {
        $results.Add((New-DemoResult -CheckId ('PREFLIGHT.POLICY.{0}' -f $Check) -Area 'preflight' -Target 'subscription' -Status $Status -Message $Message -Evidence $Evidence -Remediation $Remediation -DocUrl $DocUrl))
    }

    # Assignments that apply to the subscription, including those inherited from management groups.
    $listed = $true
    $url = 'https://management.azure.com/subscriptions/{0}/providers/Microsoft.Authorization/policyAssignments?$filter=atScope()&api-version={1}' -f $subscriptionId, $apiVersion
    for ($page = 0; $url -and $page -lt 20; $page++) {
        $response = Get-DemoArmResource -SubscriptionId $subscriptionId -Url $url
        if (-not $response.Ok) {
            $unreadable.Add(('the policy assignments that apply to the subscription ({0})' -f $response.Error))
            $listed = $false
            break
        }
        $items = Get-DemoMemberValue -InputObject $response.Value -Name 'value'
        foreach ($item in @($items)) {
            if ($item -is [System.Collections.IDictionary]) {
                $assignments.Add($item)
            }
        }
        $url = [string](Get-DemoMemberValue -InputObject $response.Value -Name 'nextLink')
    }
    if ($listed) {
        if ($CacheHours -gt 0) {
            try {
                $cachePath = Get-DemoPolicyInventoryCachePath -SubscriptionId $subscriptionId -Directory $CacheDirectory
                $fingerprint = Get-DemoPolicyInventoryFingerprint -Assignment $assignments.ToArray() -Config $Config -CodeText $MyInvocation.MyCommand.ScriptBlock.ToString()
            }
            catch {
                Write-DemoLog -Level Warning -Message ('The policy inventory cache key couldn''t be computed, so nothing is reused or saved: {0}' -f $_.Exception.Message)
                $cachePath = ''
            }
        }
        if ($cachePath) {
            $cached = Read-DemoPolicyInventoryCache -Path $cachePath -Fingerprint $fingerprint -MaximumAgeHours $CacheHours
            if ($null -ne $cached) {
                Write-DemoLog -Message ('Policy inventory: the {0} assignment(s) that apply are unchanged since the inventory of {1} UTC ({2:n1} hours old), so it''s reused (-PolicyCacheHours {3}).' -f $assignments.Count, $cached.CreatedUtc.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture), $cached.AgeHours, $CacheHours)
                return (Restore-DemoPolicyInventory -Cached $cached -CacheHours $CacheHours)
            }
        }
        Write-DemoLog -Message ('Policy inventory: {0} assignment(s) apply to the subscription. Definitions are read one at a time, which can take a few minutes.' -f $assignments.Count)
    }

    $index = 0
    foreach ($assignment in $assignments) {
        $index++
        $properties = $assignment['properties']
        if ($properties -isnot [System.Collections.IDictionary]) {
            continue
        }
        $assignmentName = [string]$assignment['name']
        $assignmentLabel = if ($properties['displayName']) { [string]$properties['displayName'] } else { $assignmentName }
        # Some assignment names embed the subscription ID; keep it out of logs and results.
        $assignmentLabel = $assignmentLabel -ireplace [regex]::Escape($subscriptionId), '<subscription>'
        $scopeKind = if ([string]$properties['scope'] -match '(?i)/managementGroups/') { 'management group' } elseif ([string]$properties['scope'] -match '(?i)/resourceGroups/') { 'resource group' } else { 'subscription' }
        if ([string]$properties['enforcementMode'] -eq 'DoNotEnforce') {
            $doNotEnforce.Add($assignmentLabel)
            continue
        }
        $definitionId = [string]$properties['policyDefinitionId']
        if (-not $definitionId) {
            continue
        }

        $isSet = $definitionId -match '(?i)/policySetDefinitions/'
        $setParameters = $null
        $members = [System.Collections.Generic.List[object]]::new()
        if ($isSet) {
            $set = Read-PolicyDefinition -Id $definitionId
            if ($null -eq $set) {
                $unreadable.Add(('policy set {0} in assignment "{1}" ({2})' -f (Format-PolicyId $definitionId), $assignmentLabel, $readErrors[$definitionId]))
                continue
            }
            $setParameters = $set['properties']['parameters']
            foreach ($member in @($set['properties']['policyDefinitions'])) {
                if ($member -is [System.Collections.IDictionary] -and $member['policyDefinitionId']) {
                    $members.Add([pscustomobject]@{ Id = [string]$member['policyDefinitionId']; ReferenceId = [string]$member['policyDefinitionReferenceId']; Parameters = $member['parameters'] })
                }
            }
        }
        else {
            $members.Add([pscustomobject]@{ Id = $definitionId; ReferenceId = ''; Parameters = $null })
        }
        Write-DemoLog -Message ('Policy inventory: assignment {0} of {1}, "{2}" ({3} definition(s)).' -f $index, $assignments.Count, $assignmentLabel, $members.Count)

        foreach ($member in $members) {
            $definition = Read-PolicyDefinition -Id $member.Id
            $definitionProperties = if ($null -ne $definition) { $definition['properties'] } else { $null }
            if ($definitionProperties -isnot [System.Collections.IDictionary] -or $definitionProperties['policyRule'] -isnot [System.Collections.IDictionary]) {
                $unreadable.Add(('definition {0} in assignment "{1}" ({2})' -f (Format-PolicyId $member.Id), $assignmentLabel, $readErrors[$member.Id]))
                continue
            }
            $policyRule = $definitionProperties['policyRule']
            $policyName = if ($definitionProperties['displayName']) { [string]$definitionProperties['displayName'] } else { ($member.Id -split '/')[-1] }
            $parameters = Get-DemoPolicyParameterTable -DefinitionParameter $definitionProperties['parameters'] -AssignmentParameter $properties['parameters'] -MemberParameter $member.Parameters -SetParameter $setParameters -SetMember:$isSet
            $then = $policyRule['then']
            if ($then -isnot [System.Collections.IDictionary]) {
                continue
            }

            $effectValue = Resolve-DemoPolicyExpression -Value $then['effect'] -Parameter $parameters
            $effect = if ($effectValue.Known) { [string]$effectValue.Value } else { '' }
            foreach ($override in @($properties['overrides'])) {
                if ($override -isnot [System.Collections.IDictionary] -or [string]$override['kind'] -ne 'policyEffect' -or -not $override['value']) {
                    continue
                }
                $selectors = @(@($override['selectors']) | Where-Object { $_ -is [System.Collections.IDictionary] })
                $applies = $selectors.Count -eq 0
                foreach ($selector in $selectors) {
                    if ([string]$selector['kind'] -ne 'policyDefinitionReferenceId') {
                        continue
                    }
                    if (($selector.Contains('in') -and @($selector['in']) -contains $member.ReferenceId) -or
                        ($selector.Contains('notIn') -and @($selector['notIn']) -notcontains $member.ReferenceId)) {
                        $applies = $true
                    }
                }
                if ($applies) {
                    $effect = [string]$override['value']
                }
            }
            if (-not $effect) {
                $unreadable.Add(('the effect of "{0}" in assignment "{1}" (unresolved parameter)' -f $policyName, $assignmentLabel))
                continue
            }
            $canonicalEffect = $keptEffects[$effect]
            if (-not $canonicalEffect) {
                continue
            }

            $facts = Get-DemoPolicyRuleFact -Condition $policyRule['if'] -Parameter $parameters
            $rule = [pscustomobject]@{
                Assignment       = $assignmentLabel
                AssignmentName   = $assignmentName
                Scope            = $scopeKind
                Policy           = $policyName
                DefinitionName   = ($member.Id -split '/')[-1]
                ReferenceId      = $member.ReferenceId
                Effect           = $canonicalEffect
                Types            = $facts.Types
                AnyType          = $facts.AnyType
                HasTypeCondition = $facts.HasTypeCondition
                Fields           = $facts.Fields
                Condition        = $policyRule['if']
                Then             = $then
                Parameters       = $parameters
                Category         = ''
            }
            $rule.Category = Get-DemoPolicyRuleCategory -Rule $rule
            $rules.Add($rule)
        }
    }

    $complete = $listed -and $unreadable.Count -eq 0
    $incompleteNote = if ($complete) { '' } else { ', from the policies that could be read' }
    $byCategory = @{}
    foreach ($rule in $rules) {
        if (-not $byCategory.ContainsKey($rule.Category)) {
            $byCategory[$rule.Category] = [System.Collections.Generic.List[object]]::new()
        }
        $byCategory[$rule.Category].Add($rule)
    }
    $category = { param([string] $Name) if ($byCategory.ContainsKey($Name)) { , $byCategory[$Name].ToArray() } else { , @() } }

    # INVENTORY: what was read, what was skipped, and what couldn't be read.
    $unrelatedCount = (& $category 'UNRELATED').Count
    $relatedCount = $rules.Count - $unrelatedCount
    $inventoryEvidence = @{
        assignments    = @($assignments | ForEach-Object {
                $p = $_['properties']
                if ($p -is [System.Collections.IDictionary]) {
                    '{0} ({1}, {2})' -f $(if ($p['displayName']) { $p['displayName'] } else { $_['name'] }), $(if ([string]$p['scope'] -match '(?i)/managementGroups/') { 'management group' } else { 'subscription' }), $(if ($p['enforcementMode']) { $p['enforcementMode'] } else { 'Default' })
                }
            })
        keptRules      = $rules.Count
        relatedRules   = $relatedCount
        unrelatedRules = $unrelatedCount
        doNotEnforce   = @($doNotEnforce)
        unreadable     = @($unreadable)
    }
    $assignmentsDoc = 'https://learn.microsoft.com/rest/api/policy-authorization/policy-assignments/list'
    if (-not $listed) {
        Add-PolicyResult 'INVENTORY' 'Warning' ('The policy assignments that apply to the subscription couldn''t be read: {0}. The policy checks were skipped; the what-if check still catches denials.' -f ($unreadable -join '; ')) $inventoryEvidence 'Ask an administrator for read access to the subscription''s policy assignments and the management groups above it (for example Reader), then run preflight again.' $assignmentsDoc
    }
    else {
        $message = 'Read {0} policy assignment(s) that apply to the subscription: {1} rule(s) have a deny, modify, deployIfNotExists, append, or denyAction effect; {2} are reported below and {3} target resource types the demo doesn''t create.' -f $assignments.Count, $rules.Count, $relatedCount, $unrelatedCount
        if ($doNotEnforce.Count -gt 0) {
            $message += ' Skipped {0} assignment(s) with enforcement mode DoNotEnforce: {1}.' -f $doNotEnforce.Count, ($doNotEnforce -join '; ')
        }
        if ($complete) {
            Add-PolicyResult 'INVENTORY' 'Pass' $message $inventoryEvidence '' $assignmentsDoc
        }
        else {
            $message += ' Couldn''t read: {0}. The checks below cover only what was read; the what-if check still catches denials.' -f ($unreadable -join '; ')
            Add-PolicyResult 'INVENTORY' 'Warning' $message $inventoryEvidence 'Ask an administrator for read access to the management groups above the subscription (for example Reader), then run preflight again.' $assignmentsDoc
        }
    }

    # SQLPUBLIC: a policy that turns off public network access on SQL servers decides the network mode.
    $sqlRules = & $category 'SQLPUBLIC'
    $sqlPolicies = @($sqlRules | ForEach-Object { $_.Policy } | Select-Object -Unique)
    $configuredMode = if ($Config['networkMode']) { [string]$Config['networkMode'] } else { 'auto' }
    $network = Resolve-DemoNetworkMode -ConfiguredMode $configuredMode -SqlPublicAccessPolicy $sqlPolicies -PolicyUnknown:(-not $complete)
    Add-PolicyResult 'SQLPUBLIC' $network.Status $network.Message @{ configuredNetworkMode = $network.ConfiguredMode; effectiveNetworkMode = $network.EffectiveMode; assumed = $network.Assumed; policies = $sqlPolicies } $network.Remediation 'https://learn.microsoft.com/azure/azure-sql/database/connectivity-settings'

    if ($listed) {
        # SQLENTRAONLY: T3 is Entra-only by design (ADR 0009).
        $entraRules = & $category 'SQLENTRAONLY'
        if ($entraRules.Count -gt 0) {
            Add-PolicyResult 'SQLENTRAONLY' 'Pass' ('Azure Policy denies SQL servers without Microsoft Entra-only authentication ({0}). T3 is Entra-only by design (ADR 0009): the server must set administrators.azureADOnlyAuthentication to true in its administrators block when it''s created.' -f (Format-PolicyList $entraRules)) @{ policies = @($entraRules | ForEach-Object { $_.Policy }) } '' 'https://learn.microsoft.com/azure/azure-sql/database/authentication-azure-ad-only-authentication'
        }

        # VMSIZE: the profile's VM sizes against VM size deny rules.
        $sizeRules = & $category 'VMSIZE'
        $catalog = Get-DemoProfile
        $profileName = if ($Config['profile']) { [string]$Config['profile'] } else { 'lowest-cost' }
        $priority = @{
            t1     = if ($Config['t1Priority']) { [string]$Config['t1Priority'] } else { 'Regular' }
            t2Host = if ($Config['hostPriority']) { [string]$Config['hostPriority'] } else { 'Regular' }
        }
        $roleNames = [ordered]@{ t1 = 'T1'; t2Host = 'T2 host' }
        $testSize = {
            param([string] $Size, [string] $Priority)
            $blocked = [System.Collections.Generic.List[string]]::new()
            $unknown = [System.Collections.Generic.List[string]]::new()
            $facts = @{ type = 'Microsoft.Compute/virtualMachines'; 'Microsoft.Compute/virtualMachines/sku.name' = $Size; 'Microsoft.Compute/virtualMachines/priority' = $Priority }
            foreach ($sizeRule in $sizeRules) {
                $outcome = Test-DemoPolicyCondition -Condition $sizeRule.Condition -Fact $facts -Parameter $sizeRule.Parameters
                if ($outcome -is [bool]) {
                    if ($outcome) {
                        $blocked.Add($sizeRule.Policy)
                    }
                }
                else {
                    $unknown.Add($sizeRule.Policy)
                }
            }
            [pscustomobject]@{ Blocked = $blocked.ToArray(); Unknown = $unknown.ToArray() }
        }
        $sizing = $catalog.profiles[$profileName]
        $blockedLines = [System.Collections.Generic.List[string]]::new()
        $unknownLines = [System.Collections.Generic.List[string]]::new()
        $checkedSizes = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $roleNames.Keys) {
            $size = [string]$sizing[$key]['size']
            $checkedSizes.Add(('{0} {1}' -f $roleNames[$key], $size))
            $outcome = & $testSize $size $priority[$key]
            foreach ($name in $outcome.Blocked) {
                $blockedLines.Add(('{0} size {1} ({2})' -f $roleNames[$key], $size, $name))
            }
            foreach ($name in $outcome.Unknown) {
                $unknownLines.Add(('{0} size {1} ({2})' -f $roleNames[$key], $size, $name))
            }
        }
        $sizeEvidence = @{ profile = $profileName; sizes = $checkedSizes.ToArray(); policies = @($sizeRules | ForEach-Object { $_.Policy }) }
        $sizeDoc = 'https://learn.microsoft.com/azure/governance/policy/concepts/effect-deny'
        if ($blockedLines.Count -gt 0) {
            $alternatives = foreach ($name in $catalog.profiles.Keys) {
                if ($name -eq $profileName) {
                    continue
                }
                $candidate = $catalog.profiles[$name]
                $clear = $true
                foreach ($key in $roleNames.Keys) {
                    $outcome = & $testSize ([string]$candidate[$key]['size']) $priority[$key]
                    if ($outcome.Blocked.Count -gt 0 -or $outcome.Unknown.Count -gt 0) {
                        $clear = $false
                    }
                }
                if ($clear) {
                    '{0} (T1 {1}, T2 host {2})' -f $name, $candidate['t1']['size'], $candidate['t2Host']['size']
                }
            }
            $sizeEvidence['alternatives'] = @($alternatives)
            $remediation = if (@($alternatives).Count -gt 0) { 'Choose a profile whose sizes no policy blocks: {0}.' -f (@($alternatives) -join '; ') } else { 'No profile in config/profiles.json avoids the policy. Ask for a policy exemption for the demo resource group, or use another subscription.' }
            Add-PolicyResult 'VMSIZE' 'Fail' ('Azure Policy blocks the {0} profile''s VM sizes: {1}.' -f $profileName, ($blockedLines -join '; ')) $sizeEvidence $remediation $sizeDoc
        }
        elseif ($unknownLines.Count -gt 0) {
            Add-PolicyResult 'VMSIZE' 'Warning' ('These VM size policies couldn''t be evaluated for the {0} profile: {1}.' -f $profileName, ($unknownLines -join '; ')) $sizeEvidence 'Review the policies; the what-if check catches a denial before anything is deployed.' $sizeDoc
        }
        elseif ($sizeRules.Count -gt 0) {
            Add-PolicyResult 'VMSIZE' 'Pass' ('No enforced policy blocks the {0} profile''s VM sizes: {1}. Checked {2} VM size rule(s){3}.' -f $profileName, ($checkedSizes -join ' and '), $sizeRules.Count, $incompleteNote) $sizeEvidence '' $sizeDoc
        }
        else {
            Add-PolicyResult 'VMSIZE' 'Pass' ('No enforced policy restricts VM sizes{0}, so the {1} profile''s sizes are allowed: {2}.' -f $incompleteNote, $profileName, ($checkedSizes -join ' and ')) $sizeEvidence '' $sizeDoc
        }

        # RESOURCETYPES: every resource type the demo creates against type-only deny rules.
        $typeRules = & $category 'RESOURCETYPES'
        $deniedTypes = [System.Collections.Generic.List[string]]::new()
        $unknownTypes = [System.Collections.Generic.List[string]]::new()
        foreach ($type in $script:DemoResourceTypes) {
            foreach ($typeRule in $typeRules) {
                $outcome = Test-DemoPolicyCondition -Condition $typeRule.Condition -Fact @{ type = $type } -Parameter $typeRule.Parameters
                if ($outcome -is [bool]) {
                    if ($outcome) {
                        $deniedTypes.Add(('{0} ({1})' -f $type, $typeRule.Policy))
                    }
                }
                else {
                    $unknownTypes.Add(('{0} ({1})' -f $type, $typeRule.Policy))
                }
            }
        }
        $typeEvidence = @{ demoResourceTypes = $script:DemoResourceTypes.Count; policies = @($typeRules | ForEach-Object { $_.Policy }); denied = $deniedTypes.ToArray() }
        if ($deniedTypes.Count -gt 0) {
            Add-PolicyResult 'RESOURCETYPES' 'Fail' ('Azure Policy denies resource types the demo creates: {0}.' -f ($deniedTypes -join '; ')) $typeEvidence 'Ask for a policy exemption for the demo resource group or subscription, or use a subscription without this policy.' $sizeDoc
        }
        elseif ($unknownTypes.Count -gt 0) {
            Add-PolicyResult 'RESOURCETYPES' 'Warning' ('These resource type policies couldn''t be evaluated: {0}.' -f ((@($unknownTypes) | Select-Object -First 5) -join '; ')) $typeEvidence 'Review the policies; the what-if check catches a denial before anything is deployed.' $sizeDoc
        }
        else {
            Add-PolicyResult 'RESOURCETYPES' 'Pass' ('No enforced policy denies the {0} resource types the demo creates. Checked {1} resource type rule(s){2}.' -f $script:DemoResourceTypes.Count, $typeRules.Count, $incompleteNote) $typeEvidence '' $sizeDoc
        }

        # DEFENDER: Defender plans deployed by policy show up in the cost estimate.
        $defenderRules = & $category 'DEFENDER'
        if ($defenderRules.Count -gt 0) {
            Add-PolicyResult 'DEFENDER' 'Warning' ('Defender plans are enforced by policy ({0} rule(s) deploy Microsoft.Security/pricings, for example {1}); the cost estimate includes them.' -f $defenderRules.Count, (Format-PolicyList $defenderRules 2)) @{ policies = @($defenderRules | ForEach-Object { $_.Policy }) } 'Nothing to change in the demo. To lower the cost, ask the tenant administrator whether the plans can be turned off for a demo subscription.' 'https://learn.microsoft.com/azure/governance/policy/concepts/effect-deploy-if-not-exists'
        }

        # EXTENSIONS: extensions that policy adds to the demo's machines.
        $extensionRules = & $category 'EXTENSIONS'
        if ($extensionRules.Count -gt 0) {
            $extensionLines = foreach ($extensionRule in $extensionRules) {
                $names = [System.Collections.Generic.List[string]]::new()
                $stack = [System.Collections.Generic.Stack[object]]::new()
                $stack.Push((Get-DemoMemberValue -InputObject $extensionRule.Then['details'] -Name 'existenceCondition'))
                while ($stack.Count -gt 0) {
                    $node = $stack.Pop()
                    if ($node -is [System.Collections.IDictionary]) {
                        if ($node['field'] -is [string] -and $node['field'] -match '/extensions/type$' -and $node.Contains('equals')) {
                            $extensionType = Resolve-DemoPolicyExpression -Value $node['equals'] -Parameter $extensionRule.Parameters
                            # Every demo machine runs Windows, so Linux extension types never apply.
                            if ($extensionType.Known -and $extensionType.Value -is [string] -and $extensionType.Value -notmatch '(?i)linux') {
                                $names.Add($extensionType.Value)
                            }
                        }
                        foreach ($value in $node.Values) {
                            $stack.Push($value)
                        }
                    }
                    elseif ($node -is [System.Collections.IList]) {
                        foreach ($value in $node) {
                            $stack.Push($value)
                        }
                    }
                }
                $targets = [System.Collections.Generic.List[string]]::new()
                $ruleTypes = @($extensionRule.Types)
                if ($ruleTypes -contains 'Microsoft.Compute/virtualMachines') {
                    $targets.Add('T1 and the T2 host')
                }
                if ($ruleTypes -contains 'Microsoft.SqlVirtualMachine/sqlVirtualMachines') {
                    $targets.Add('T1')
                }
                if ($ruleTypes -contains 'Microsoft.HybridCompute/machines') {
                    $targets.Add('the Arc machine arcsql01')
                }
                if ($targets.Count -eq 0) {
                    $targets.Add('the demo''s machines')
                }
                $extension = if ($names.Count -gt 0) { ($names | Select-Object -Unique) -join ', ' } else { $extensionRule.Policy }
                '{0} on {1}' -f $extension, (($targets | Select-Object -Unique) -join ' and ')
            }
            $extensionLines = @($extensionLines | Select-Object -Unique)
            Add-PolicyResult 'EXTENSIONS' 'Warning' ('Azure Policy adds VM or Arc machine extensions that the demo doesn''t declare: {0}. Bootstraps and extension deployments must retry when Azure returns Conflict while a policy deployment runs.' -f ($extensionLines -join '; ')) @{ extensions = $extensionLines; policies = @($extensionRules | ForEach-Object { $_.Policy }) } 'Nothing to change now; informational.' 'https://learn.microsoft.com/azure/governance/policy/concepts/effect-deploy-if-not-exists'
        }

        # PUBLICIP: changes to public IP addresses (Bastion's public IP).
        $publicIpRules = & $category 'PUBLICIP'
        if ($publicIpRules.Count -gt 0) {
            $changes = foreach ($publicIpRule in $publicIpRules) {
                $details = $publicIpRule.Then['details']
                $operations = Get-DemoMemberValue -InputObject $details -Name 'operations'
                $entries = if ($publicIpRule.Effect -eq 'Append') { @($details) } else { @($operations) }
                foreach ($entry in $entries) {
                    if ($entry -isnot [System.Collections.IDictionary]) {
                        continue
                    }
                    $value = $entry['value']
                    if ($value -is [System.Collections.IDictionary] -and $value.Contains('ipTagType')) {
                        'ipTag {0}={1}' -f $value['ipTagType'], $value['tag']
                    }
                    else {
                        '{0}={1}' -f $entry['field'], (ConvertTo-Json -InputObject $value -Compress -Depth 5)
                    }
                }
            }
            $changes = @($changes | Select-Object -Unique)
            Add-PolicyResult 'PUBLICIP' 'Warning' ('Azure Policy changes public IP addresses ({0}): {1}. Bastion''s public IP gets this when it''s created. IP tags may not be changeable after creation, so this is checked when Bastion is first created.' -f (Format-PolicyList $publicIpRules), ($changes -join '; ')) @{ changes = $changes; policies = @($publicIpRules | ForEach-Object { $_.Policy }) } 'Nothing to change now; the demo doesn''t set IP tags itself.' 'https://learn.microsoft.com/azure/governance/policy/concepts/effect-append'
        }

        # STORAGE: storage account policies don't apply, because the demo creates no storage account.
        $storageRules = & $category 'STORAGE'
        if ($storageRules.Count -gt 0) {
            Add-PolicyResult 'STORAGE' 'Pass' ('{0} rule(s) change or restrict storage accounts ({1}); the deployment creates no storage accounts.' -f $storageRules.Count, (Format-PolicyList $storageRules 2)) @{ policies = @($storageRules | ForEach-Object { $_.Policy }) } '' 'https://learn.microsoft.com/azure/governance/policy/concepts/effect-modify'
        }

        # MFA: mandatory multifactor authentication for writes and deletes.
        $mfaRules = & $category 'MFA'
        if ($mfaRules.Count -gt 0) {
            Add-PolicyResult 'MFA' 'Pass' ('Azure Policy enforces multifactor authentication ({0}): writes and deletes by a user need an MFA sign-in. Workload identities, such as managed identities and service principals (for example the GitHub OIDC identity), aren''t affected.' -f (Format-PolicyList $mfaRules)) @{ policies = @($mfaRules | ForEach-Object { $_.Policy }) } '' 'https://learn.microsoft.com/entra/identity/authentication/concept-mandatory-multifactor-authentication'
        }

        # OTHER: anything else that can apply to the demo's resource types, so nothing is silently ignored.
        $otherRules = & $category 'OTHER'
        if ($otherRules.Count -gt 0) {
            $otherLines = @($otherRules | ForEach-Object { '{0} ({1}, assignment "{2}")' -f $_.Policy, $_.Effect, $_.Assignment } | Select-Object -Unique)
            $shown = (@($otherLines | Select-Object -First 5)) -join '; '
            if ($otherLines.Count -gt 5) {
                $shown += '; and {0} more' -f ($otherLines.Count - 5)
            }
            Add-PolicyResult 'OTHER' 'Warning' ('{0} other rule(s) can apply to resource types the demo creates: {1}.' -f $otherRules.Count, $shown) @{ rules = $otherLines } 'Review them; the what-if check catches denials, and modify or deployIfNotExists rules change resources after deployment.' 'https://learn.microsoft.com/azure/governance/policy/concepts/effect-basics'
        }
    }

    $inventory = [pscustomobject]@{
        PSTypeName            = 'DbHubDemo.PolicyConstraint'
        Complete              = $complete
        AssignmentCount       = $assignments.Count
        DoNotEnforce          = $doNotEnforce.ToArray()
        Unreadable            = $unreadable.ToArray()
        Rules                 = $rules.ToArray()
        SqlPublicAccessPolicy = $sqlPolicies
        NetworkMode           = $network
        Results               = $results.ToArray()
    }
    if ($complete -and $cachePath) {
        Write-DemoPolicyInventoryCache -Path $cachePath -Fingerprint $fingerprint -Inventory $inventory -Confirm:$false
    }
    $inventory
}
