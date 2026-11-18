# A first run in a subscription that already has the demo (issue 60, 2026-11-18). With no configuration file (a fresh
# clone, another PC, a lost file), init.ps1 and deploy.ps1's first run wrote the defaults for the prefix dbhub without
# checking whether that environment existed, so the next deploy.ps1 applied them to it: another administrators' group for
# T3 and T4, and the default network mode, schedule, ceilings, sizes, and workspace; in someone else's environment, your
# settings and your group. Now the first run reads what's deployed first, read-only. An environment that's yours gets its
# configuration back from its deployment record and its resource groups' tags, so the update changes nothing you didn't
# ask for; one that isn't yours, or can't be told apart, is never updated by a first run, which picks a free prefix.

# The configuration's settings that Azure doesn't record anywhere a first run reads, so a recovered configuration has their
# defaults. The control's settings other than its workspace are the control section's.
$script:DemoUnrecordedSetting = @('sessionCeilingUsd', 'activityProfile', 't3FreeOffer', 't2Source', 'bastionMaxHours', 'presenterObjectIds', 'keyVault', 'control', 'fabric.lakehouseName', 'fabric.manageCapacity', 'fabric.saveHistoryOnStop', 't2ArcBillableCores')

function ConvertFrom-DemoJsonElementValue {
    # One JSON value as PowerShell reads a template parameter: a string as it is (never a date), true and false as
    # booleans, a number as Int64 when it's whole, null as $null, and anything else as its JSON text. Pure. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement] $Element
    )

    switch ([string]$Element.ValueKind) {
        'String' { return $Element.GetString() }
        'True' { return $true }
        'False' { return $false }
        'Null' { return $null }
        'Number' {
            $whole = [long]0
            if ($Element.TryGetInt64([ref]$whole)) {
                return $whole
            }
            return $Element.GetDouble()
        }
        default { return $Element.GetRawText() }
    }
}

function Get-DemoSubscriptionInventory {
    <#
    .SYNOPSIS
    The subscription's resource groups, with their tags as text, and its subscription-scope deployment records, each read
    once, so a first run can tell which prefixes the demo's environments use (issue 60). Read-only. Internal; tests mock
    it.

    .DESCRIPTION
    Returns Succeeded, Error, Groups (resource group name -> its tags, both ignoring case), and Deployments (the records'
    names, ignoring case). Tags are read as text (System.Text.Json), as Get-DemoResourceGroupTag reads them.
    Sources (checked 2026-11-18): https://learn.microsoft.com/cli/azure/group#az-group-list and
    https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId
    )

    $groups = [System.Collections.Generic.Dictionary[string, hashtable]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $deployments = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $answer = { param([bool] $Succeeded, [string] $Problem) [pscustomobject]@{ Succeeded = $Succeeded; Error = $Problem; Groups = $groups; Deployments = $deployments } }
    $listed = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('group', 'list', '--query', '[].{name:name, tags:tags}', '--output', 'json') -AllowFailure -TimeoutSeconds 120
    if ($listed.ExitCode -ne 0) {
        return (& $answer $false ('the resource groups couldn''t be listed: {0}' -f (Get-DemoDeploymentErrorText -Text ([string]$listed.StdErr) -MaxLength 300)))
    }
    $records = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('deployment', 'sub', 'list', '--query', '[].name', '--output', 'json') -AllowFailure -TimeoutSeconds 120
    if ($records.ExitCode -ne 0) {
        return (& $answer $false ('the subscription''s deployment records couldn''t be listed: {0}' -f (Get-DemoDeploymentErrorText -Text ([string]$records.StdErr) -MaxLength 300)))
    }
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$listed.StdOut)) {
            $document = [System.Text.Json.JsonDocument]::Parse([string]$listed.StdOut)
            try {
                foreach ($item in $document.RootElement.EnumerateArray()) {
                    $name = [System.Text.Json.JsonElement]::new()
                    if ($item.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or -not $item.TryGetProperty('name', [ref]$name) -or $name.ValueKind -ne [System.Text.Json.JsonValueKind]::String) {
                        continue
                    }
                    $tags = [System.Text.Json.JsonElement]::new()
                    $groups[$name.GetString()] = if ($item.TryGetProperty('tags', [ref]$tags)) { ConvertFrom-DemoJsonStringMap -Json $tags.GetRawText() } else { @{} }
                }
            }
            finally {
                $document.Dispose()
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$records.StdOut)) {
            $document = [System.Text.Json.JsonDocument]::Parse([string]$records.StdOut)
            try {
                foreach ($item in $document.RootElement.EnumerateArray()) {
                    if ($item.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                        $null = $deployments.Add($item.GetString())
                    }
                }
            }
            finally {
                $document.Dispose()
            }
        }
    }
    catch {
        return (& $answer $false ('the Azure CLI''s answer couldn''t be read: {0}' -f (Protect-DemoText -Text $_.Exception.Message)))
    }
    return (& $answer $true '')
}

function Get-DemoDeploymentRecord {
    <#
    .SYNOPSIS
    A subscription deployment record's parameters, as the template got them, and when it ran (issue 60). Read-only.
    Internal; tests mock it.

    .DESCRIPTION
    Returns Found, Error, Parameters (name -> value, ignoring case), Timestamp (yyyy-MM-dd, or ''), and State. Strings are
    read as text (System.Text.Json), so a date stays as the template got it. A record that doesn't exist is Found $false
    without an Error. Source (checked 2026-11-18): https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-show
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $parameters = @{}
    $answer = [ordered]@{ Found = $false; Error = ''; Parameters = $parameters; Timestamp = ''; State = '' }
    $read = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('deployment', 'sub', 'show', '--name', $Name, '--query', '{timestamp: properties.timestamp, state: properties.provisioningState, parameters: properties.parameters}', '--output', 'json') -AllowFailure -TimeoutSeconds 120
    if ($read.ExitCode -ne 0) {
        if (-not (Test-DemoAzNotFound -Text ([string]$read.StdErr))) {
            $answer.Error = 'the deployment record {0} couldn''t be read: {1}' -f $Name, (Get-DemoDeploymentErrorText -Text ([string]$read.StdErr) -MaxLength 300)
        }
        return [pscustomobject]$answer
    }
    try {
        $document = [System.Text.Json.JsonDocument]::Parse([string]$read.StdOut)
        try {
            $root = $document.RootElement
            $member = [System.Text.Json.JsonElement]::new()
            if ($root.TryGetProperty('timestamp', [ref]$member) -and $member.ValueKind -eq [System.Text.Json.JsonValueKind]::String -and $member.GetString() -match '^(\d{4}-\d{2}-\d{2})') {
                $answer.Timestamp = $Matches[1]
            }
            if ($root.TryGetProperty('state', [ref]$member) -and $member.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                $answer.State = $member.GetString()
            }
            if ($root.TryGetProperty('parameters', [ref]$member) -and $member.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                foreach ($property in $member.EnumerateObject()) {
                    $value = [System.Text.Json.JsonElement]::new()
                    if ($property.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::Object -and $property.Value.TryGetProperty('value', [ref]$value)) {
                        $parameters[$property.Name] = ConvertFrom-DemoJsonElementValue -Element $value
                    }
                }
            }
        }
        finally {
            $document.Dispose()
        }
    }
    catch {
        $answer.Error = 'the deployment record {0} couldn''t be read: {1}' -f $Name, (Protect-DemoText -Text $_.Exception.Message)
        return [pscustomobject]$answer
    }
    $answer.Found = $true
    return [pscustomobject]$answer
}

function Get-DemoControlRoleSuffix {
    <#
    .SYNOPSIS
    The control.roleNameSuffix an environment's session control runs with (issue 60, 2026-11-18), read-only: the custom
    role its automation identity holds at the demo resource group (A1, Get-DemoActivityControlGrantPlan), "DbHub Demo
    Activity Operator" or "DbHub Demo Activity Operator (<suffix>)". Internal; tests mock it.

    .DESCRIPTION
    An environment that shares its subscription with a demo on other code has its own two custom roles, named with its
    suffix. Without the suffix, deploy.ps1 would create or update the shared roles, which the other demo's control holds,
    so an environment that holds a role of its own never gets the shared ones back:
    - One suffix, with or without the shared role: that suffix.
    - More than one: the one named after -Prefix (the convention), else the one assigned last (createdOn), and Note says
      so; the others are in Others.
    - Only the shared role: Found, with Suffix ''.
    - None: Found $false; the setting keeps its default.
    - A read that fails: Error, and the caller writes nothing, as for its other reads.
    Returns Found, Suffix, Others, Note, and Error.
    Source (checked 2026-11-18): https://learn.microsoft.com/cli/azure/role/assignment#az-role-assignment-list
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroup,

        [AllowEmptyString()]
        [string] $Prefix = ''
    )

    $answer = [ordered]@{ Found = $false; Suffix = ''; Others = @(); Note = ''; Error = '' }
    $base = [string]$script:ActivityControlRoleName
    $read = Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('role', 'assignment', 'list', '--resource-group', $ResourceGroup, '--fill-principal-name', 'false', '--query', ("[?starts_with(roleDefinitionName, '{0}')].{{name: roleDefinitionName, created: createdOn}}" -f $base), '--output', 'json') -AllowFailure -TimeoutSeconds 120
    if ($read.ExitCode -ne 0) {
        $answer.Error = 'the role assignments at {0} couldn''t be read: {1}' -f $ResourceGroup, (Get-DemoDeploymentErrorText -Text ([string]$read.StdErr) -MaxLength 300)
        return [pscustomobject]$answer
    }
    $assignments = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$read.StdOut)) {
        try {
            $assignments = @([string]$read.StdOut | ConvertFrom-Json -ErrorAction Stop)
        }
        catch {
            $answer.Error = 'the role assignments at {0} couldn''t be read: {1}' -f $ResourceGroup, (Protect-DemoText -Text $_.Exception.Message)
            return [pscustomobject]$answer
        }
    }
    $pattern = '^{0} \((?<suffix>[A-Za-z0-9-]{{1,24}})\)$' -f [regex]::Escape($base)
    $latest = @{}
    $shared = $false
    foreach ($assignment in $assignments) {
        $name = [string](Get-DemoMemberValue -InputObject $assignment -Name 'name')
        # ConvertFrom-Json reads an ISO 8601 date as a DateTime; text that isn't one counts as the oldest.
        $createdValue = Get-DemoMemberValue -InputObject $assignment -Name 'created'
        $created = [DateTime]::MinValue
        if ($createdValue -is [DateTime]) {
            $created = $createdValue.ToUniversalTime()
        }
        elseif ($createdValue -is [string]) {
            $parsed = [DateTime]::MinValue
            if ([DateTime]::TryParse($createdValue, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsed)) {
                $created = $parsed
            }
        }
        $match = [regex]::Match($name, $pattern)
        if ($match.Success) {
            $suffix = $match.Groups['suffix'].Value
            if (-not $latest.ContainsKey($suffix) -or $created -gt $latest[$suffix]) {
                $latest[$suffix] = $created
            }
        }
        elseif ($name -ceq $base) {
            $shared = $true
        }
    }
    if ($latest.Count -gt 0) {
        $ordered = @($latest.Keys | Sort-Object -Property @{ Expression = { [string]::Equals($_, $Prefix, [System.StringComparison]::OrdinalIgnoreCase) }; Descending = $true }, @{ Expression = { $latest[$_] }; Descending = $true }, @{ Expression = { $_ }; Descending = $false })
        $answer.Found = $true
        $answer.Suffix = [string]$ordered[0]
        $answer.Others = @($ordered | Select-Object -Skip 1)
        if ($answer.Others.Count -gt 0) {
            $why = if ([string]::Equals($answer.Suffix, $Prefix, [System.StringComparison]::OrdinalIgnoreCase)) { 'the one named after its prefix' } else { 'the one assigned last' }
            $answer.Note = 'Its session control''s identity holds the demo''s custom roles under more than one suffix ({0}), so control.roleNameSuffix is "{1}", {2}, and never the shared roles; set it in the configuration if it''s another.' -f (@($ordered) -join ', '), $answer.Suffix, $why
        }
    }
    elseif ($shared) {
        $answer.Found = $true
    }
    return [pscustomobject]$answer
}

function Get-DemoEnvironmentTrace {
    <#
    .SYNOPSIS
    What a subscription holds of one prefix's environment (issue 60): its demo resource group rg-<prefix>-<environment>,
    the session control's rg-<prefix>-control, the golden snapshots' rg-<prefix>-golden, and the template's deployment
    record <prefix>-<environment>-main. Pure. Internal.

    .DESCRIPTION
    Returns Prefix, ResourceGroup, RecordName, DemoGroup, ControlGroup, GoldenGroup, and Record (each $true when it
    exists), Any (one of them does), Label (the first of them that exists, for a message), Tags (the demo resource group's
    tags), and OwnerTags (the owner tag of each group that exists, without repeats).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Inventory,

        [Parameter(Mandatory)]
        [string] $Prefix,

        [Parameter(Mandatory)]
        [string] $Environment
    )

    $groups = $Inventory.Groups
    $names = [ordered]@{
        Demo    = 'rg-{0}-{1}' -f $Prefix, $Environment
        Control = 'rg-{0}-control' -f $Prefix
        Golden  = 'rg-{0}-golden' -f $Prefix
    }
    $exists = @{}
    $owners = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $names.Keys) {
        $exists[$key] = $groups.ContainsKey($names[$key])
        if ($exists[$key]) {
            $owner = [string]$groups[$names[$key]]['owner']
            if ($owner.Trim() -and -not $owners.Contains($owner.Trim())) {
                $owners.Add($owner.Trim())
            }
        }
    }
    $recordName = '{0}-{1}-main' -f $Prefix, $Environment
    $record = @($Inventory.Deployments) -contains $recordName
    $tags = if ($exists['Demo']) { $groups[$names['Demo']] } else { @{} }
    # What a message names when the prefix is taken: its first resource group that exists, or its record.
    $label = @(foreach ($key in $names.Keys) { if ($exists[$key]) { $names[$key] } }) + @($(if ($record) { $recordName })) | Select-Object -First 1
    return [pscustomobject]@{
        Prefix        = $Prefix
        ResourceGroup = $names['Demo']
        RecordName    = $recordName
        DemoGroup     = [bool]$exists['Demo']
        ControlGroup  = [bool]$exists['Control']
        GoldenGroup   = [bool]$exists['Golden']
        Record        = [bool]$record
        Any           = [bool]($exists['Demo'] -or $exists['Control'] -or $exists['Golden'] -or $record)
        Label         = [string]$label
        Tags          = $tags
        OwnerTags     = $owners.ToArray()
    }
}

function Test-DemoEnvironmentOwner {
    <#
    .SYNOPSIS
    Whether an environment is yours, and by which sign (issue 60). Pure. Internal.

    .DESCRIPTION
    Mine when one of these holds, checked in this order; Signal says which:
    - owner-email: its deployment record's ownerEmail, the budget alerts' address, is one of your sign-in's addresses;
    - owner-tag: its owner tag, on one of its resource groups or in its record, is one of them;
    - admin-group: you own the security group that administers its T3 and T4 (-GroupOwned): init.ps1 creates it with you
      as its owner, and deploy.ps1 needs you as its owner to set T3 and T4 up;
    - claim: with init.ps1's explicit -Prefix, its -OwnerEmail is the environment's recorded ownerEmail or owner tag.
    Addresses compare ignoring case. Nothing else counts, an alias included: a first run never updates an environment
    that it can't tell is yours.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()]
        [string[]] $Address = @(),

        [AllowEmptyCollection()]
        [string[]] $Claim = @(),

        [AllowNull()]
        [System.Collections.IDictionary] $Parameter,

        [AllowEmptyCollection()]
        [string[]] $OwnerTag = @(),

        [AllowNull()]
        [object] $GroupOwned
    )

    $normalize = { param([object[]] $Items) @($Items | Where-Object { $_ -is [string] -and $_.Trim() } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Select-Object -Unique) }
    # Wrapped again: the call unrolls the scriptblock's array, so one item or none would lose it.
    $mine = @(& $normalize $Address)
    $claimed = @(& $normalize $Claim)
    $recordedEmail = if ($null -ne $Parameter -and $Parameter.Contains('ownerEmail')) { @(& $normalize @($Parameter['ownerEmail'])) } else { @() }
    $recordedOwner = if ($null -ne $Parameter -and $Parameter.Contains('owner')) { @(& $normalize @($Parameter['owner'])) } else { @() }
    $owners = @(& $normalize (@($OwnerTag) + @($recordedOwner)))
    $match = { param([object[]] $Left, [object[]] $Right) @($Left | Where-Object { $_ -in $Right }).Count -gt 0 }
    $signal = if ($mine.Count -gt 0 -and (& $match $recordedEmail $mine)) {
        'owner-email'
    }
    elseif ($mine.Count -gt 0 -and (& $match $owners $mine)) {
        'owner-tag'
    }
    elseif ($GroupOwned -eq $true) {
        'admin-group'
    }
    elseif ($claimed.Count -gt 0 -and (& $match (@($recordedEmail) + @($owners)) $claimed)) {
        'claim'
    }
    else {
        ''
    }
    return [pscustomobject]@{ Mine = [bool]$signal; Signal = $signal }
}

function Get-DemoOwnerSignalText {
    # The words for Test-DemoEnvironmentOwner's Signal in a result's message (issue 60). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Signal = ''
    )

    switch ($Signal) {
        'owner-email' { return 'its budget alerts go to your address' }
        'owner-tag' { return 'its owner tag is your sign-in' }
        'admin-group' { return 'you own the security group that administers its T3 and T4' }
        'claim' { return 'its budget address is the -OwnerEmail you gave' }
        default { return '' }
    }
}

function ConvertFrom-DemoDeploymentRecord {
    <#
    .SYNOPSIS
    The configuration's values that an environment's deployment record and resource group tags say (issue 60): what
    Get-DemoDeploymentParameter sent the template, read back. Internal.

    .DESCRIPTION
    Returns Values (configuration path -> value, for example 'securityType.t1'), Recovered (those paths), Missing (the
    settings neither had, which keep their defaults), and Notes (what the message says about T4's size). A value that
    doesn't fit the schema is left out and listed in Missing.
    - The record's parameters map to their settings one to one: location, networkMode (public or private, as deployed),
      outboundMode, owner, ownerEmail, costCenter, autoShutdownTime, autoShutdownTimeZone, expiresOn, monthlyCeilingUsd,
      profile, zone, dataDiskSku, t1Priority, hostPriority, securityType.t1 (t1SecurityType), securityType.t2Host
      (hostSecurityType), hybridBenefit (windowsHybridBenefit, sqlHybridBenefit, hybridBenefitAttested), t2Mode,
      t2SqlInstallMode, t3AdminGroupObjectId, t3AutoPauseMinutes, and activityProfileOnBoot.
    - assignRoles from assignArcOnboardingRole, which the nested mode sends.
    - t4SkuName, so deploy.ps1 doesn't move T4 to the default: when T4's fallback chose the server's size (DbHubT4Size, or
      Phase 28's DbHubT4Sku), the size Azure refused first (DbHubT4Refused) when it isn't the default, since that's what
      the configuration asked for; otherwise the record's size when it isn't the profile's default, except Standard_B1ms.
      That was every profile's default before 2026-11-04, and the record can't tell it apart from a t4SkuName that set it
      (a server that kept its size, in start-demo.ps1, while T4 wasn't Ready, or over a ceiling, sends its own size), so
      it's left to the default's move, as for a configuration without t4SkuName, and Notes says so.
      t4AutonomousTuning false only when the record turned it off on a size that runs it.
    - Without a record, the tags give what they hold: the network mode (DbHubNetworkMode), the owner, the cost center, the
      auto-shutdown time and time zone (autoShutdown), and expiresOn.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Parameter,

        [AllowNull()]
        [System.Collections.IDictionary] $Tag
    )

    if ($null -eq $Parameter) {
        $Parameter = @{}
    }
    if ($null -eq $Tag) {
        $Tag = @{}
    }
    $values = [ordered]@{}
    $missing = [System.Collections.Generic.List[string]]::new()
    $isText = { param($Value, [string[]] $Allowed) $Value -is [string] -and $Value -cin $Allowed }
    $isWhole = { param($Value) $Value -is [long] -or $Value -is [int] }
    $rules = @(
        @{ Path = 'location'; Name = 'location'; Test = { param($v) $v -is [string] -and $v -cmatch '^[a-z0-9]+$' } }
        @{ Path = 'networkMode'; Name = 'networkMode'; Test = { param($v) & $isText $v 'public', 'private' } }
        @{ Path = 'outboundMode'; Name = 'outboundMode'; Test = { param($v) & $isText $v 'DefaultOutboundAccess', 'NatGateway' } }
        @{ Path = 'owner'; Name = 'owner'; Test = { param($v) $v -is [string] -and $v.Trim() -and $v.Length -le 64 } }
        @{ Path = 'ownerEmail'; Name = 'ownerEmail'; Test = { param($v) $v -is [string] -and $v -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' } }
        @{ Path = 'costCenter'; Name = 'costCenter'; Test = { param($v) $v -is [string] -and $v.Length -le 64 } }
        @{ Path = 'autoShutdownTime'; Name = 'autoShutdownTime'; Test = { param($v) $v -is [string] -and $v -match '^([01][0-9]|2[0-3])[0-5][0-9]$' } }
        @{ Path = 'autoShutdownTimeZone'; Name = 'autoShutdownTimeZone'; Test = { param($v) $v -is [string] -and $v.Trim().Length -ge 3 } }
        @{ Path = 'expiresOn'; Name = 'expiresOn'; Test = { param($v) $v -is [string] -and ($v -eq '' -or $v -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') }; Convert = { param($v) if ($v) { $v } else { $null } } }
        @{ Path = 'monthlyCeilingUsd'; Name = 'monthlyCeilingUsd'; Test = { param($v) ((& $isWhole $v) -or $v -is [double]) -and $v -gt 0 } }
        @{ Path = 'profile'; Name = 'profile'; Test = { param($v) & $isText $v 'lowest-cost', 'demo-day', 'enhanced-performance' } }
        @{ Path = 'zone'; Name = 'zone'; Test = { param($v) & $isText $v '', '1', '2', '3' }; Convert = { param($v) if ($v) { $v } else { $null } } }
        @{ Path = 'dataDiskSku'; Name = 'dataDiskSku'; Test = { param($v) & $isText $v 'Auto', 'None', 'E10', 'P10', 'PremiumV2' } }
        @{ Path = 't1Priority'; Name = 't1Priority'; Test = { param($v) & $isText $v 'Regular', 'Spot' } }
        @{ Path = 'hostPriority'; Name = 'hostPriority'; Test = { param($v) & $isText $v 'Regular', 'Spot' } }
        @{ Path = 'securityType.t1'; Name = 't1SecurityType'; Test = { param($v) & $isText $v 'TrustedLaunch', 'Standard' } }
        @{ Path = 'securityType.t2Host'; Name = 'hostSecurityType'; Test = { param($v) & $isText $v 'Standard', 'TrustedLaunch' } }
        @{ Path = 'hybridBenefit.windows'; Name = 'windowsHybridBenefit'; Test = { param($v) $v -is [bool] } }
        @{ Path = 'hybridBenefit.sql'; Name = 'sqlHybridBenefit'; Test = { param($v) $v -is [bool] } }
        @{ Path = 'hybridBenefit.entitlementAttested'; Name = 'hybridBenefitAttested'; Test = { param($v) $v -is [bool] } }
        @{ Path = 't2Mode'; Name = 't2Mode'; Test = { param($v) & $isText $v 'Nested', 'EvaluationOnlyAzureVm' } }
        @{ Path = 't2SqlInstallMode'; Name = 't2SqlInstallMode'; Test = { param($v) & $isText $v 'JumpstartImage', 'PaygWizard', 'ProductKey', 'Developer' } }
        @{ Path = 't3AdminGroupObjectId'; Name = 't3AdminGroupObjectId'; Test = { param($v) $v -is [string] -and $v -match $script:GuidPattern -and $v -ne '00000000-0000-0000-0000-000000000000' }; Convert = { param($v) $v.ToLowerInvariant() } }
        @{ Path = 't3AutoPauseMinutes'; Name = 't3AutoPauseMinutes'; Test = { param($v) (& $isWhole $v) -and ($v -eq -1 -or ($v -ge 15 -and $v -le 10080)) }; Convert = { param($v) [int]$v } }
        @{ Path = 'activityProfileOnBoot'; Name = 'activityProfileOnBoot'; Test = { param($v) $v -is [bool] } }
    )
    foreach ($rule in $rules) {
        if (-not $Parameter.Contains($rule.Name)) {
            continue
        }
        $value = $Parameter[$rule.Name]
        if (-not (& $rule.Test $value)) {
            continue
        }
        $values[$rule.Path] = if ($rule.Contains('Convert')) { & $rule.Convert $value } else { $value }
    }

    # What the tags hold, for a record that's gone (destroy.ps1 deletes it; Azure keeps at most 800 per subscription).
    $tagText = { param([string] $Name) if ($Tag.Contains($Name)) { ([string]$Tag[$Name]).Trim() } else { '' } }
    if (-not $values.Contains('networkMode') -and (& $tagText 'DbHubNetworkMode') -cin 'public', 'private') {
        $values['networkMode'] = & $tagText 'DbHubNetworkMode'
    }
    if (-not $values.Contains('owner') -and (& $tagText 'owner') -and (& $tagText 'owner').Length -le 64) {
        $values['owner'] = & $tagText 'owner'
    }
    if (-not $values.Contains('costCenter') -and $Tag.Contains('costCenter') -and (& $tagText 'costCenter').Length -le 64) {
        $values['costCenter'] = & $tagText 'costCenter'
    }
    if (-not $values.Contains('autoShutdownTime') -and (& $tagText 'autoShutdown') -match '^(?<time>([01][0-9]|2[0-3])[0-5][0-9]) (?<zone>\S.{2,})$') {
        $values['autoShutdownTime'] = $Matches['time']
        if (-not $values.Contains('autoShutdownTimeZone')) {
            $values['autoShutdownTimeZone'] = $Matches['zone'].Trim()
        }
    }
    if (-not $values.Contains('expiresOn') -and (& $tagText 'expiresOn') -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') {
        $values['expiresOn'] = & $tagText 'expiresOn'
    }

    # assignRoles: the template gets assignArcOnboardingRole as assignRoles in the nested mode (Get-DemoDeploymentParameter).
    $t2Mode = if ($values.Contains('t2Mode')) { [string]$values['t2Mode'] } else { 'Nested' }
    if ($Parameter.Contains('assignArcOnboardingRole') -and $Parameter['assignArcOnboardingRole'] -is [bool] -and $t2Mode -eq 'Nested') {
        $values['assignRoles'] = [bool]$Parameter['assignArcOnboardingRole']
    }

    # T4's size and its autonomous tuning, so deploy.ps1 doesn't move T4 to the default (see the description).
    $sku = if ($Parameter.Contains('t4SkuName')) { [string]$Parameter['t4SkuName'] } else { '' }
    $profileName = if ($values.Contains('profile')) { [string]$values['profile'] } else { 'lowest-cost' }
    $default = Get-DemoT4DefaultSkuName -Config @{ profile = $profileName }
    $notes = [System.Collections.Generic.List[string]]::new()
    $fallbackSize = & $tagText 'DbHubT4Size'
    if ($fallbackSize -cin $script:T4Sizes -or (& $tagText 'DbHubT4Sku')) {
        $asked = (ConvertFrom-DemoT4RefusedRecord -Value (& $tagText 'DbHubT4Refused')).Asked
        if ($asked -and $asked -cne $default) {
            $values['t4SkuName'] = $asked
        }
    }
    elseif ($sku -ceq 'Standard_B1ms' -and $sku -cne $default) {
        $notes.Add(('T4 is Standard_B1ms, every profile''s default before 2026-11-04, which its record can''t tell apart from a t4SkuName that set it: as for a configuration without t4SkuName, deploy.ps1 moves it to {0} once its cost check passes.' -f $default))
    }
    elseif ($sku -cin $script:T4Sizes -and $sku -cne $default) {
        $values['t4SkuName'] = $sku
    }
    $t4On = -not ($Parameter.Contains('t4Enabled') -and $Parameter['t4Enabled'] -eq $false)
    if ($t4On -and $Parameter.Contains('t4AutonomousTuning') -and $Parameter['t4AutonomousTuning'] -eq $false -and $sku -cin 'Standard_D4ds_v5', 'Standard_D4ads_v5') {
        $values['t4AutonomousTuning'] = $false
    }

    foreach ($rule in $rules) {
        if (-not $values.Contains($rule.Path)) {
            $missing.Add($rule.Path)
        }
    }
    if (-not $values.Contains('assignRoles')) {
        $missing.Add('assignRoles')
    }
    return [pscustomobject]@{
        Values    = $values
        Recovered = @($values.Keys)
        Missing   = $missing.ToArray()
        Notes     = $notes.ToArray()
    }
}

function Get-DemoPrefixCandidate {
    # The prefixes a first run tries, in order, when the configured one is someone else's (issue 60): <prefix>2 to
    # <prefix>99, each cut to the schema's 8 characters (^[a-z][a-z0-9]{2,7}$). Pure. Internal.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z][a-z0-9]{2,7}$')]
        [string] $Prefix
    )

    $candidates = foreach ($number in 2..99) {
        $suffix = [string]$number
        $stem = if ($Prefix.Length + $suffix.Length -gt 8) { $Prefix.Substring(0, 8 - $suffix.Length) } else { $Prefix }
        '{0}{1}' -f $stem, $suffix
    }
    return @($candidates | Where-Object { $_ -ne $Prefix } | Select-Object -Unique)
}

function Get-DemoExistingEnvironmentEvidence {
    <#
    .SYNOPSIS
    For one prefix's environment that exists: its deployment record, its administrators' group, and whether it's yours
    (issue 60). Reads only: the record, and Microsoft Graph for the group. Internal.

    .DESCRIPTION
    The group is the record's t3AdminGroupObjectId, or, without a record, the one named by the resource group's
    DbHubT3AdminGroup tag. Its owners are read only when no address says the environment is yours. Returns Mine, Signal,
    Parameters (the record's, or $null), RecordDate, GroupId, GroupName, and Error: a read that failed, so whether it's
    yours can't be told (never a group that doesn't exist, which isn't yours).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [pscustomobject] $Trace,

        [AllowEmptyCollection()]
        [string[]] $Address = @(),

        [AllowEmptyCollection()]
        [string[]] $Claim = @(),

        [AllowEmptyString()]
        [string] $CallerId = ''
    )

    $answer = [ordered]@{ Mine = $false; Signal = ''; Parameters = $null; RecordDate = ''; GroupId = ''; GroupName = ''; Error = '' }
    if ($Trace.Record) {
        $record = Get-DemoDeploymentRecord -SubscriptionId $SubscriptionId -Name $Trace.RecordName
        if ($record.Error) {
            $answer.Error = $record.Error
            return [pscustomobject]$answer
        }
        if ($record.Found) {
            $answer.Parameters = $record.Parameters
            $answer.RecordDate = [string]$record.Timestamp
        }
    }
    $parameters = $answer.Parameters
    $recordedId = if ($null -ne $parameters -and $parameters.Contains('t3AdminGroupObjectId')) { [string]$parameters['t3AdminGroupObjectId'] } else { '' }
    if ($recordedId -match $script:GuidPattern -and $recordedId -ne '00000000-0000-0000-0000-000000000000') {
        $answer.GroupId = $recordedId.ToLowerInvariant()
    }
    $answer.GroupName = if ($null -ne $parameters -and $parameters.Contains('t3AdminGroupDisplayName') -and [string]$parameters['t3AdminGroupDisplayName']) { [string]$parameters['t3AdminGroupDisplayName'] } elseif ($Trace.Tags.Contains('DbHubT3AdminGroup')) { [string]$Trace.Tags['DbHubT3AdminGroup'] } else { '' }
    $owner = Test-DemoEnvironmentOwner -Address $Address -Claim $Claim -Parameter $parameters -OwnerTag $Trace.OwnerTags
    if (-not $owner.Mine -and $CallerId) {
        if (-not $answer.GroupId -and $answer.GroupName) {
            $named = Find-DemoEntraGroup -SubscriptionId $SubscriptionId -DisplayName $answer.GroupName
            if (-not $named.Succeeded) {
                $answer.Error = 'the administrators'' group "{0}" couldn''t be read from Microsoft Graph: {1}' -f $answer.GroupName, $named.Error
                return [pscustomobject]$answer
            }
            $exact = @($named.Groups | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'displayName') -ieq $answer.GroupName })
            if ($exact.Count -eq 1) {
                $answer.GroupId = ([string](Get-DemoMemberValue -InputObject $exact[0] -Name 'id')).ToLowerInvariant()
            }
        }
        if ($answer.GroupId) {
            $owned = Test-DemoEntraGroupOwner -SubscriptionId $SubscriptionId -GroupId $answer.GroupId -OwnerId $CallerId
            if ($null -eq $owned) {
                # Unreadable owners: a group that's gone isn't yours; any other failure can't tell.
                $group = Find-DemoEntraGroup -SubscriptionId $SubscriptionId -ObjectId $answer.GroupId
                if ($group.Succeeded -or [int]$group.StatusCode -ne 404) {
                    $answer.Error = 'the owners of its administrators'' group couldn''t be read from Microsoft Graph{0}' -f $(if ($group.Error) { ': ' + $group.Error } else { '' })
                    return [pscustomobject]$answer
                }
                $owned = $false
            }
            $owner = Test-DemoEnvironmentOwner -Address $Address -Claim $Claim -Parameter $parameters -OwnerTag $Trace.OwnerTags -GroupOwned $owned
        }
    }
    $answer.Mine = $owner.Mine
    $answer.Signal = $owner.Signal
    return [pscustomobject]$answer
}

function Resolve-DemoExistingEnvironment {
    <#
    .SYNOPSIS
    What a first run's configuration names when the subscription may already have the environment (issue 60, 2026-11-18).
    Reads only. Internal.

    .DESCRIPTION
    It lists the subscription's resource groups and deployment records once (Get-DemoSubscriptionInventory), then:
    - No trace of the prefix (Get-DemoEnvironmentTrace): Kind New, as before.
    - Yours (Get-DemoExistingEnvironmentEvidence, Test-DemoEnvironmentOwner): Kind Recovered, with the values its record and
      tags hold (ConvertFrom-DemoDeploymentRecord), or Kind New when only its control's or golden snapshots' group exists.
    - Not yours, with init.ps1's explicit -Prefix: Kind NotYours; nothing is written.
    - Not yours otherwise: the candidates <prefix>2 to <prefix>99 (Get-DemoPrefixCandidate), at most 10 of them read:
      the first that's yours (Kind Recovered), else the first with no trace at all (Kind NewPrefix), else Kind NotYours.
    - A read that failed: Kind Unreadable; nothing is written, so a first run never applies the defaults to an environment
      it couldn't check.
    Returns Kind, Prefix, ResourceGroup, DefaultResourceGroup (the configured prefix's), Signal, Values, Missing, Notes,
    RecordDate, Record (a record was read), GroupId, GroupName, Tags, ControlGroup, RoleSuffixFound (the session
    control's custom roles were read, Get-DemoControlRoleSuffix: their suffix, if any, is in Values as
    control.roleNameSuffix), Skipped (the taken candidates' resource groups), and Error.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Prefix,

        [Parameter(Mandatory)]
        [string] $Environment,

        [switch] $ExplicitPrefix,

        [AllowEmptyCollection()]
        [string[]] $Address = @(),

        [AllowEmptyCollection()]
        [string[]] $Claim = @(),

        [AllowEmptyString()]
        [string] $CallerId = ''
    )

    $defaultGroup = 'rg-{0}-{1}' -f $Prefix, $Environment
    $answer = [ordered]@{
        Kind                 = 'New'
        Prefix               = $Prefix
        ResourceGroup        = $defaultGroup
        DefaultResourceGroup = $defaultGroup
        Signal               = ''
        Values               = [ordered]@{}
        Missing              = @()
        Notes                = @()
        RecordDate           = ''
        Record               = $false
        GroupId              = ''
        GroupName            = ''
        Tags                 = @{}
        ControlGroup         = $false
        RoleSuffixFound      = $false
        Skipped              = @()
        Error                = ''
    }
    $inventory = Get-DemoSubscriptionInventory -SubscriptionId $SubscriptionId
    if (-not $inventory.Succeeded) {
        $answer.Kind = 'Unreadable'
        $answer.Error = [string]$inventory.Error
        return [pscustomobject]$answer
    }
    $use = {
        param([pscustomobject] $Trace, [pscustomobject] $Evidence)
        $answer.Prefix = $Trace.Prefix
        $answer.ResourceGroup = $Trace.ResourceGroup
        $answer.Signal = $Evidence.Signal
        $answer.Tags = $Trace.Tags
        $answer.ControlGroup = $Trace.ControlGroup
        $answer.GroupId = $Evidence.GroupId
        $answer.GroupName = $Evidence.GroupName
        if ($Trace.DemoGroup -or $null -ne $Evidence.Parameters) {
            $recovered = ConvertFrom-DemoDeploymentRecord -Parameter $Evidence.Parameters -Tag $Trace.Tags
            $answer.Kind = 'Recovered'
            $answer.Values = $recovered.Values
            $answer.Missing = @($recovered.Missing)
            $answer.Notes = @($recovered.Notes)
            $answer.RecordDate = $Evidence.RecordDate
            $answer.Record = $null -ne $Evidence.Parameters
            # Its session control's own custom roles (control.roleNameSuffix), which no record or tag holds: without the
            # suffix, deploy.ps1 would create or update the shared roles, which another environment's control holds. A read
            # that fails writes nothing, as the others do.
            if ($Trace.DemoGroup) {
                $role = Get-DemoControlRoleSuffix -SubscriptionId $SubscriptionId -ResourceGroup $Trace.ResourceGroup -Prefix $Trace.Prefix
                if ($role.Error) {
                    $answer.Kind = 'Unreadable'
                    $answer.Error = [string]$role.Error
                    return [pscustomobject]$answer
                }
                $answer.RoleSuffixFound = [bool]$role.Found
                if ($role.Found -and $role.Suffix) {
                    $answer.Values['control.roleNameSuffix'] = [string]$role.Suffix
                }
                if ($role.Note) {
                    $answer.Notes = @($answer.Notes) + @([string]$role.Note)
                }
            }
        }
        else {
            # Only its session control's or its golden snapshots' group: nothing to recover, and a new environment there.
            $answer.Kind = if ($Trace.Prefix -ceq $Prefix) { 'New' } else { 'NewPrefix' }
        }
        return [pscustomobject]$answer
    }
    $trace = Get-DemoEnvironmentTrace -Inventory $inventory -Prefix $Prefix -Environment $Environment
    if (-not $trace.Any) {
        return [pscustomobject]$answer
    }
    $evidence = Get-DemoExistingEnvironmentEvidence -SubscriptionId $SubscriptionId -Trace $trace -Address $Address -Claim $Claim -CallerId $CallerId
    if ($evidence.Error) {
        $answer.Kind = 'Unreadable'
        $answer.Error = [string]$evidence.Error
        return [pscustomobject]$answer
    }
    if ($evidence.Mine) {
        return (& $use $trace $evidence)
    }
    $answer.Kind = 'NotYours'
    if ($ExplicitPrefix) {
        return [pscustomobject]$answer
    }
    $free = ''
    $skipped = [System.Collections.Generic.List[string]]::new()
    $read = 0
    foreach ($candidate in (Get-DemoPrefixCandidate -Prefix $Prefix)) {
        $other = Get-DemoEnvironmentTrace -Inventory $inventory -Prefix $candidate -Environment $Environment
        if (-not $other.Any) {
            if (-not $free) {
                $free = $candidate
            }
            continue
        }
        $skipped.Add($other.Label)
        if ($read -ge 10) {
            continue
        }
        $read++
        $otherEvidence = Get-DemoExistingEnvironmentEvidence -SubscriptionId $SubscriptionId -Trace $other -Address $Address -CallerId $CallerId
        if ($otherEvidence.Error) {
            $answer.Kind = 'Unreadable'
            $answer.Error = [string]$otherEvidence.Error
            return [pscustomobject]$answer
        }
        if ($otherEvidence.Mine) {
            $answer.Skipped = @($skipped | Where-Object { $_ -ne $other.Label })
            return (& $use $other $otherEvidence)
        }
    }
    $answer.Skipped = $skipped.ToArray()
    if ($free) {
        $answer.Kind = 'NewPrefix'
        $answer.Prefix = $free
        $answer.ResourceGroup = 'rg-{0}-{1}' -f $free, $Environment
    }
    return [pscustomobject]$answer
}

function Resolve-DemoRecoveredWorkspace {
    <#
    .SYNOPSIS
    The Fabric workspaces a recovered environment uses (issue 60): its own, and its control notebook's. Pure. Internal.

    .DESCRIPTION
    From the IDs its demo resource group records (DbHubFabricWorkspaceId and DbHubControlWorkspaceId, since 2026-11-17),
    found among the workspaces you can see; otherwise the names it would have had: "Database Hub Demo" for the default
    prefix, and "Database Hub Demo <prefix>" for another, the name a first run gives a new prefix, when that workspace
    exists. Another prefix's environment without a record or that workspace has no name to recover: Source unknown, and
    the caller decides. The control's workspace, without a record, is the one its name derives from, "<workspace>
    Control", when that exists; else, for the default prefix with a control resource group, "DBHub Control", which
    init.ps1 wrote before 2026-11-14 and which needs control.enabled true to stay (Get-DemoActivityControlSetting).
    Returns WorkspaceName, Source (recorded, default, or unknown), Exists, ControlName ('' keeps the default the
    workspace's name gives), ControlEnabled, and Note (a recorded workspace that isn't among yours).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Workspace = @(),

        [bool] $Listed = $true,

        [Parameter(Mandatory)]
        [string] $Prefix,

        [string] $DefaultPrefix = 'dbhub',

        [string] $DefaultName = 'Database Hub Demo',

        [AllowEmptyString()]
        [string] $FabricWorkspaceId = '',

        [AllowEmptyString()]
        [string] $ControlWorkspaceId = '',

        [bool] $ControlGroup = $false
    )

    $items = @($Workspace | Where-Object { $null -ne $_ })
    $byId = { param([string] $Id) @($items | Where-Object { $Id -and ([string](Get-DemoMemberValue -InputObject $_ -Name 'id')).ToLowerInvariant() -eq $Id.ToLowerInvariant() }) | Select-Object -First 1 }
    $byName = { param([string] $Name) @(Select-DemoFabricNamed -Items $items -Name $Name) | Select-Object -First 1 }
    $answer = [ordered]@{ WorkspaceName = ''; Source = 'unknown'; Exists = $false; ControlName = ''; ControlEnabled = $false; Note = '' }
    $found = $null
    if ($FabricWorkspaceId -match $script:GuidPattern) {
        $found = & $byId $FabricWorkspaceId
        if ($null -ne $found) {
            $answer.Source = 'recorded'
        }
        elseif ($Listed) {
            $answer.Note = 'The Fabric workspace it records isn''t among yours (deleted, or you have no access to it).'
        }
    }
    $ownName = if ($Prefix -ceq $DefaultPrefix) { $DefaultName } else { '{0} {1}' -f $DefaultName, $Prefix }
    if ($null -eq $found) {
        $found = & $byName $ownName
        if ($null -ne $found -or $Prefix -ceq $DefaultPrefix) {
            $answer.Source = 'default'
        }
    }
    if ($null -ne $found) {
        $answer.WorkspaceName = [string](Get-DemoMemberValue -InputObject $found -Name 'displayName')
        $answer.Exists = $true
    }
    else {
        $answer.WorkspaceName = $ownName
    }
    $demoId = if ($null -ne $found) { ([string](Get-DemoMemberValue -InputObject $found -Name 'id')).ToLowerInvariant() } else { '' }
    if ($ControlWorkspaceId -match $script:GuidPattern) {
        if ($ControlWorkspaceId.ToLowerInvariant() -ne $demoId) {
            $control = & $byId $ControlWorkspaceId
            if ($null -ne $control) {
                $answer.ControlName = [string](Get-DemoMemberValue -InputObject $control -Name 'displayName')
            }
        }
    }
    elseif ($ControlGroup -and $Prefix -ceq $DefaultPrefix -and $null -eq (& $byName ('{0} Control' -f $answer.WorkspaceName)) -and $null -ne (& $byName 'DBHub Control')) {
        $answer.ControlName = 'DBHub Control'
    }
    $answer.ControlEnabled = $answer.ControlName -ceq 'DBHub Control'
    return [pscustomobject]$answer
}

function Resolve-DemoRecoveredNotebookImport {
    <#
    .SYNOPSIS
    fabric.importNotebooks for a recovered environment, and why (issue 60; the coordinator's decisions of 2026-11-18).
    Pure. Internal.

    .DESCRIPTION
    A first run gives a workspace that exists false, so deploy.ps1 adds only the notebooks that are missing and keeps
    edits made in Fabric. But an update republishes the notebooks (README, "Upgrading an existing demo"), and the
    configuration that was lost had true when its first run created the workspace. So a recovered environment's own
    workspace gets true:
    1. the one its resource group records (DbHubFabricWorkspaceId);
    2. one that holds only items the demo creates (Get-DemoFabricDemoItem, the rule destroy.ps1 deletes it by);
    3. one that holds the demo's own notebooks already (-Notebook, Get-DemoFabricNotebookName): the demo imported them
       there before, so the update republishes them, as the configuration that was lost did, and what else it holds stays
       as it is. It's read from the items that were listed, even when the list isn't whole.
    Anything else keeps the first run's rule: false for a workspace that holds neither, or whose items couldn't be
    listed; true for one that doesn't exist yet, or that Fabric couldn't be asked about.
    -Found is how many workspaces have the name (-Workspace is the one, when it's 1), -Listed whether Fabric's workspaces
    were listed, and -ItemList Read-DemoHubFabricList's answer for its items ($null when they weren't read). Returns
    Import and Reason, which INIT.EXISTING says.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkspaceName,

        [AllowNull()]
        [object] $Workspace = $null,

        [int] $Found = 0,

        [bool] $Listed = $true,

        [AllowEmptyString()]
        [string] $RecordedId = '',

        [AllowEmptyString()]
        [string] $ResourceGroup = '',

        [AllowNull()]
        [object] $ItemList = $null,

        [AllowEmptyCollection()]
        [object[]] $Allowed = @(),

        [AllowEmptyCollection()]
        [string[]] $Notebook = @()
    )

    $answer = { param([bool] $Import, [string] $Reason) [pscustomobject]@{ Import = $Import; Reason = $Reason } }
    $keep = 'so deploy.ps1 adds only the notebooks that are missing and keeps the copies there (./scripts/configure-fabric.ps1 updates them)'
    if (-not $Listed) {
        return (& $answer $true 'Fabric couldn''t be read, so, as for a workspace that doesn''t exist yet, deploy.ps1 imports the notebooks or updates them')
    }
    if ($Found -gt 1) {
        return (& $answer $true ('more than one workspace is named "{0}" (INIT.FABRIC.WORKSPACE), so, as for a workspace that doesn''t exist yet, deploy.ps1 imports the notebooks or updates them' -f $WorkspaceName))
    }
    if ($Found -eq 0 -or $null -eq $Workspace) {
        return (& $answer $true ('"{0}" doesn''t exist yet, so deploy.ps1 creates it and imports the notebooks' -f $WorkspaceName))
    }
    $id = ([string](Get-DemoMemberValue -InputObject $Workspace -Name 'id')).ToLowerInvariant()
    if ($id -and $RecordedId -and $id -eq $RecordedId.ToLowerInvariant()) {
        return (& $answer $true ('"{0}" is the workspace {1} records (DbHubFabricWorkspaceId), so deploy.ps1 updates its notebooks, as an update does' -f $WorkspaceName, $ResourceGroup))
    }
    if ($null -eq $ItemList -or -not [bool](Get-DemoMemberValue -InputObject $ItemList -Name 'Succeeded')) {
        $problem = if ($null -ne $ItemList) { ([string](Get-DemoMemberValue -InputObject $ItemList -Name 'Error')).TrimEnd('.') } else { '' }
        return (& $answer $false ('the items in "{0}" couldn''t be listed{1}, {2}' -f $WorkspaceName, $(if ($problem) { ' (' + $problem + ')' } else { '' }), $keep))
    }
    $complete = [bool](Get-DemoMemberValue -InputObject $ItemList -Name 'Complete')
    # Assign before wrapping: Get-DemoMemberValue returns an array as one object.
    $listedItems = Get-DemoMemberValue -InputObject $ItemList -Name 'Items'
    $count = 0
    $foreign = [System.Collections.Generic.List[string]]::new()
    $present = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($listedItems)) {
        if ($null -eq $item) {
            continue
        }
        $count++
        $type = [string](Get-DemoMemberValue -InputObject $item -Name 'type')
        $display = [string](Get-DemoMemberValue -InputObject $item -Name 'displayName')
        if (-not (Test-DemoFabricDemoItem -Allowed $Allowed -Type $type -Name $display)) {
            $foreign.Add(('{0} {1}' -f $type, $display))
        }
        if ($type -eq 'Notebook' -and $display -cin @($Notebook) -and -not $present.Contains($display)) {
            $present.Add($display)
        }
    }
    $named = (@($foreign | Select-Object -First 5) -join ', ') + $(if ($foreign.Count -gt 5) { ', and {0} more' -f ($foreign.Count - 5) } else { '' })
    if ($complete -and $foreign.Count -eq 0) {
        return (& $answer $true ('everything in "{0}" is the demo''s ({1} item(s)), so deploy.ps1 updates its notebooks, as an update does' -f $WorkspaceName, $count))
    }
    if ($present.Count -gt 0) {
        $rest = if ($foreign.Count -gt 0) { '; what else it holds ({0}) stays as it is' -f $named } else { '' }
        return (& $answer $true ('the demo''s notebooks are already in "{0}" ({1}): the demo imported them there before, so deploy.ps1 updates them, as an update does{2}' -f $WorkspaceName, ($present -join ', '), $rest))
    }
    if (-not $complete) {
        return (& $answer $false ('the items in "{0}" couldn''t all be listed, {1}' -f $WorkspaceName, $keep))
    }
    return (& $answer $false ('"{0}" holds what the demo didn''t create ({1}), and none of the demo''s notebooks, {2}' -f $WorkspaceName, $named, $keep))
}

function Get-DemoExistingEnvironmentReport {
    <#
    .SYNOPSIS
    What a first run says about the environment it found (issue 60): INIT.EXISTING, and the line for deploy.ps1's start
    banner and its status page (Note). Pure. Internal.

    .DESCRIPTION
    - New: Pass, with no note.
    - Recovered: Warning: whose it is and by which sign, what the configuration took from what's deployed, fabric.importNotebooks
      and why (-NotebookImport, Resolve-DemoRecoveredNotebookImport), and the settings that Azure doesn't record, which
      have their defaults (-Defaulted).
    - NewPrefix: Warning: the environment that isn't yours, which a first run never updates, and the new one's prefix,
      resource group, administrators' group, and Fabric workspace.
    - NotYours: Manual action required; nothing was written.
    - Unreadable: Fail; nothing was written.
    Messages never name another person's address.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Existing,

        [string] $Path = 'config/demo.config.json',

        [AllowEmptyString()]
        [string] $GroupName = '',

        [AllowEmptyString()]
        [string] $WorkspaceName = '',

        [AllowEmptyString()]
        [string] $WorkspaceSource = '',

        [AllowEmptyString()]
        [string] $ControlName = '',

        [AllowNull()]
        [pscustomobject] $NotebookImport = $null,

        [AllowEmptyCollection()]
        [string[]] $Defaulted = @(),

        [switch] $DryRun
    )

    $doc = 'https://learn.microsoft.com/cli/azure/deployment/sub#az-deployment-sub-show'
    # -WhatIf: nothing is written or deployed, so the words say what would happen.
    $written = if ($DryRun) { 'would be written' } else { 'is written' }
    $group = [string]$Existing.ResourceGroup
    $defaultGroup = [string]$Existing.DefaultResourceGroup
    $prefix = [string]$Existing.Prefix
    $values = $Existing.Values
    $evidence = [ordered]@{
        kind          = [string]$Existing.Kind
        prefix        = $prefix
        resourceGroup = $group
        signal        = [string]$Existing.Signal
        recovered     = @($values.Keys)
        defaulted     = @($Defaulted)
        recordDate    = [string]$Existing.RecordDate
        skipped       = @($Existing.Skipped)
    }
    if ($null -ne $NotebookImport) {
        $evidence['importNotebooks'] = [bool]$NotebookImport.Import
    }
    $notYours = 'its owner tag and its budget address aren''t your sign-in, and you don''t own the security group that administers its T3 and T4'
    $result = { param([string] $Status, [string] $Message, [string] $Remediation) New-DemoResult -CheckId 'INIT.EXISTING' -Area 'preflight' -Target 'subscription' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $doc }
    switch ([string]$Existing.Kind) {
        'Unreadable' {
            $message = 'Whether this subscription already has the environment {0}, and what it holds, couldn''t be checked: {1}. A first run writes nothing it can''t check, so it never applies the defaults to an environment that exists. Nothing was written.' -f $defaultGroup, ([string]$Existing.Error).TrimEnd('.')
            return [pscustomobject]@{ Result = (& $result 'Fail' $message 'Run the command again in a few minutes. If it fails the same way, check that you can read the subscription''s resource groups, deployments, and role assignments, and Microsoft Graph''s groups.'); Note = '' }
        }
        'NotYours' {
            $skipped = @($Existing.Skipped)
            if ($skipped.Count -gt 0) {
                $message = '{0} exists in this subscription, and it isn''t yours: {1}. The prefixes after it are taken too ({2}), so nothing was written: deploy.ps1 would update an environment that isn''t yours.' -f $defaultGroup, $notYours, ($skipped -join ', ')
                return [pscustomobject]@{ Result = (& $result 'Manual action required' $message 'Run ./scripts/init.ps1 -Prefix <a prefix that no environment uses>, then ./scripts/deploy.ps1.'); Note = '' }
            }
            $message = '{0} exists in this subscription, and it isn''t yours: {1}. So nothing was written: deploy.ps1 would update it with this configuration.' -f $defaultGroup, $notYours
            $remediation = 'If it''s yours, run ./scripts/init.ps1 -Prefix {0} -OwnerEmail <the budget address it records>, or ask an owner of its administrators'' group to add you as an owner and run ./scripts/init.ps1 -Prefix {0} again. Otherwise choose another -Prefix.' -f $prefix
            return [pscustomobject]@{ Result = (& $result 'Manual action required' $message $remediation); Note = '' }
        }
        'NewPrefix' {
            $taken = @($Existing.Skipped)
            $message = '{0} exists in this subscription, and it isn''t yours: {1}. So a first run never updates it: the configuration {7} a new environment, with the prefix {2}: {3}, the administrators'' group "{4}", and the Fabric workspace "{5}".{6}' -f $defaultGroup, $notYours, $prefix, $group, $GroupName, $WorkspaceName, $(if ($taken.Count -gt 0) { ' {0} {1} taken too.' -f ($taken -join ', '), $(if ($taken.Count -eq 1) { 'is' } else { 'are' }) } else { '' }), $(if ($DryRun) { 'would name' } else { 'names' })
            $remediation = 'If {0} is yours after all: ./scripts/destroy.ps1 deletes the new environment, then run ./scripts/init.ps1 -Force -Prefix {1} -OwnerEmail <the budget address {0} records>, and ./scripts/deploy.ps1.' -f $defaultGroup, ($defaultGroup -replace '^rg-(.+)-[^-]+$', '$1')
            $note = if ($DryRun) {
                'No configuration file, and {0} isn''t yours, so a run would never change it: it would deploy a new environment, {1} (prefix {2}), with its own administrators'' group and the Fabric workspace "{3}" (INIT.EXISTING).' -f $defaultGroup, $group, $prefix, $WorkspaceName
            }
            else {
                'No configuration file, and {0} isn''t yours, so this run never changes it: it deploys a new environment, {1} (prefix {2}), with its own administrators'' group and the Fabric workspace "{3}" (INIT.EXISTING).' -f $defaultGroup, $group, $prefix, $WorkspaceName
            }
            return [pscustomobject]@{ Result = (& $result 'Warning' $message $remediation); Note = $note }
        }
        'Recovered' {
            $parts = [System.Collections.Generic.List[string]]::new()
            $value = { param([string] $Key) if ($values.Contains($Key)) { [string]$values[$Key] } else { '' } }
            if (& $value 'location') { $parts.Add(('region {0}' -f (& $value 'location'))) }
            if (& $value 'networkMode') { $parts.Add(('network {0}' -f (& $value 'networkMode'))) }
            if ($GroupName) { $parts.Add(('the administrators'' group "{0}"' -f $GroupName)) }
            if (& $value 'profile') { $parts.Add(('profile {0}' -f (& $value 'profile'))) }
            if (& $value 't2SqlInstallMode') { $parts.Add(('T2 {0}' -f (& $value 't2SqlInstallMode'))) }
            if (& $value 't4SkuName') { $parts.Add(('T4 {0}' -f (& $value 't4SkuName'))) }
            if (& $value 'monthlyCeilingUsd') { $parts.Add(('the monthly ceiling {0} USD' -f (& $value 'monthlyCeilingUsd'))) }
            if (& $value 'autoShutdownTime') { $parts.Add(('auto-shutdown at {0} {1}' -f (& $value 'autoShutdownTime'), (& $value 'autoShutdownTimeZone')).TrimEnd()) }
            if (& $value 'owner') { $parts.Add(('the owner tag {0}' -f (& $value 'owner'))) }
            if (& $value 'ownerEmail') { $parts.Add(('budget alerts to {0}' -f (& $value 'ownerEmail'))) }
            if ($WorkspaceName -and $WorkspaceSource -ne 'unknown') { $parts.Add(('the Fabric workspace "{0}"{1}' -f $WorkspaceName, $(if ($WorkspaceSource -eq 'default') { ' (by its default name: it doesn''t record one)' } else { '' }))) }
            if ($ControlName) { $parts.Add(('the control''s workspace "{0}"' -f $ControlName)) }
            if (& $value 'control.roleNameSuffix') { $parts.Add(('its own custom roles, "{0} ({1})" and its Session Writer (control.roleNameSuffix)' -f $script:ActivityControlRoleName, (& $value 'control.roleNameSuffix'))) }
            $source = if ([bool]$Existing.Record) { 'its deployment record of {0} and its resource group''s tags' -f $(if ($Existing.RecordDate) { $Existing.RecordDate } else { 'an earlier run' }) } else { 'its resource group''s tags, without a deployment record' }
            $before = if ($group -ne $defaultGroup) { '{0} isn''t yours, so a first run never updates it. ' -f $defaultGroup } else { '' }
            # Assign before wrapping: Get-DemoMemberValue returns an array as one object.
            $noteValue = Get-DemoMemberValue -InputObject $Existing -Name 'Notes'
            $more = (@($noteValue) | Where-Object { $_ } | ForEach-Object { ' ' + $_ }) -join ''
            $notebooks = if ($null -ne $NotebookImport) { ' fabric.importNotebooks is {0}: {1}.' -f $(if ([bool]$NotebookImport.Import) { 'true' } else { 'false' }), ([string]$NotebookImport.Reason).TrimEnd('.') } else { '' }
            $message = '{0}{1} exists in this subscription, and it''s yours ({2}), so the configuration {6} from what''s deployed ({3}), not from the defaults: {4}. deploy.ps1 then changes nothing you didn''t ask for.{8}{5}{7}' -f $before, $group, (Get-DemoOwnerSignalText -Signal ([string]$Existing.Signal)), $source, ($parts -join ', '), $(if (@($Defaulted).Count -gt 0) { ' Not recorded in Azure, so they have the defaults: {0}.' -f (@($Defaulted) -join ', ') } else { '' }), $written, $more, $notebooks
            $remediation = 'Check the settings that have the defaults in {0}, and set any that your earlier configuration had; then run ./scripts/deploy.ps1 again.' -f $Path
            $short = @($parts | Select-Object -First 3) -join ', '
            $note = if ($DryRun) {
                'No configuration file: {0}{1} is yours, so its configuration would be written from what''s deployed ({2}), and a run would change nothing you didn''t ask for. Settings that Azure doesn''t record would have the defaults (INIT.EXISTING lists them).' -f $before, $group, $short
            }
            else {
                'No configuration file: {0}{1} is yours, so its configuration was written from what''s deployed ({2}), and this run changes nothing you didn''t ask for. Settings that Azure doesn''t record have the defaults (INIT.EXISTING lists them).' -f $before, $group, $short
            }
            return [pscustomobject]@{ Result = (& $result 'Warning' $message $remediation); Note = $note }
        }
        default {
            $message = 'No demo environment uses the prefix {0} in this subscription yet, so the configuration is for a new one: {1}.' -f $prefix, $group
            return [pscustomobject]@{ Result = (& $result 'Pass' $message ''); Note = '' }
        }
    }
}
