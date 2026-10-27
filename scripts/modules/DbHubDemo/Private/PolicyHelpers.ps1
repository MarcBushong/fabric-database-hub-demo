function ConvertTo-DemoPolicyData {
    <#
    .SYNOPSIS
    Copies parsed JSON into case-insensitive hashtables, recursively.

    .DESCRIPTION
    Internal. Policy JSON mixes casing (allOf and AllOf, field and Field), and ConvertFrom-Json -AsHashtable
    returns case-sensitive dictionaries, so every dictionary is copied into one that ignores case. Arrays
    stay arrays.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [object] $InputObject
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        $table = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($key in $InputObject.Keys) {
            $table[[string]$key] = ConvertTo-DemoPolicyData -InputObject $InputObject[$key]
        }
        return $table
    }
    if ($InputObject -is [System.Collections.IList]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $InputObject) {
            $items.Add((ConvertTo-DemoPolicyData -InputObject $item))
        }
        return , $items.ToArray()
    }
    return $InputObject
}

function Get-DemoArmResource {
    <#
    .SYNOPSIS
    Reads one Azure Resource Manager URL (GET) with a token for the configured subscription's tenant.

    .DESCRIPTION
    Internal and read-only. Never throws: returns Ok, Value (case-insensitive hashtables), and Error, a
    short reason such as the ARM error code, so callers can say what they couldn't read.
    A URL under the configured subscription goes through 'az rest' (Invoke-DemoAz). Any other Resource
    Manager URL, such as a built-in or management group policy definition, goes through
    Invoke-DemoRestRequest with a token verified for the configured tenant: for those URLs 'az rest' would
    take its token from the Azure CLI's default account, which can be in another tenant.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $Url
    )

    try {
        $underSubscription = $Url -match ('^https://management\.azure\.com/subscriptions/' + [regex]::Escape($SubscriptionId) + '(/|\?|$)')
        $result = if ($underSubscription) {
            Invoke-DemoAz -SubscriptionId $SubscriptionId -ArgumentList @('rest', '--method', 'get', '--url', $Url, '--output', 'json') -AllowFailure
        }
        else {
            Invoke-DemoRestRequest -SubscriptionId $SubscriptionId -Method 'GET' -Uri $Url
        }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Error = (Protect-DemoText -Text $_.Exception.Message) }
    }

    if ($result.ExitCode -ne 0) {
        $stderr = [string]$result.StdErr
        $code = [regex]::Match($stderr, '"code"\s*:\s*"([^"]+)"')
        if (-not $code.Success) {
            $code = [regex]::Match($stderr, '\(([A-Za-z][A-Za-z0-9]+)\)')
        }
        $reason = if ($code.Success) { $code.Groups[1].Value } else { 'exit code {0}' -f $result.ExitCode }
        return [pscustomobject]@{ Ok = $false; Value = $null; Error = $reason }
    }

    try {
        $value = $null
        if (-not [string]::IsNullOrWhiteSpace($result.StdOut)) {
            $value = ConvertTo-DemoPolicyData -InputObject ($result.StdOut | ConvertFrom-Json -AsHashtable -Depth 100)
        }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Value = $null; Error = 'the response was not valid JSON' }
    }
    [pscustomobject]@{ Ok = $true; Value = $value; Error = '' }
}

function Get-DemoPolicyParameterTable {
    <#
    .SYNOPSIS
    Resolves the parameter values that one policy definition sees inside one assignment.

    .DESCRIPTION
    Internal. For a definition assigned directly: the assignment's value, then the definition's default.
    For a member of a policy set: the member's value, where [parameters('x')] means the assignment's value
    for the set parameter x, then the set's default for x; then the definition's default. Parameters with
    no value are left out, so expressions that use them stay unresolved.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]
        [object] $DefinitionParameter,

        [AllowNull()]
        [object] $AssignmentParameter,

        [AllowNull()]
        [object] $MemberParameter,

        [AllowNull()]
        [object] $SetParameter,

        [switch] $SetMember
    )

    $table = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($DefinitionParameter -isnot [System.Collections.IDictionary]) {
        return $table
    }
    $assignmentValues = if ($AssignmentParameter -is [System.Collections.IDictionary]) { $AssignmentParameter } else { @{} }
    $memberValues = if ($MemberParameter -is [System.Collections.IDictionary]) { $MemberParameter } else { @{} }
    $setDefinitions = if ($SetParameter -is [System.Collections.IDictionary]) { $SetParameter } else { @{} }

    foreach ($name in @($DefinitionParameter.Keys)) {
        $found = $false
        $value = $null
        if ($SetMember) {
            if ($memberValues.Contains($name)) {
                $inner = Get-DemoMemberValue -InputObject $memberValues[$name] -Name 'value'
                if ($inner -is [string] -and $inner -match "^\[parameters\('([^']+)'\)\]$") {
                    $outer = $Matches[1]
                    if ($assignmentValues.Contains($outer)) {
                        $value = Get-DemoMemberValue -InputObject $assignmentValues[$outer] -Name 'value'
                        $found = $true
                    }
                    elseif ($setDefinitions[$outer] -is [System.Collections.IDictionary] -and $setDefinitions[$outer].Contains('defaultValue')) {
                        $value = $setDefinitions[$outer]['defaultValue']
                        $found = $true
                    }
                }
                else {
                    $value = $inner
                    $found = $true
                }
            }
        }
        elseif ($assignmentValues.Contains($name)) {
            $value = Get-DemoMemberValue -InputObject $assignmentValues[$name] -Name 'value'
            $found = $true
        }

        $definition = $DefinitionParameter[$name]
        if (-not $found -and $definition -is [System.Collections.IDictionary] -and $definition.Contains('defaultValue')) {
            $value = $definition['defaultValue']
            $found = $true
        }
        if ($found) {
            $table[[string]$name] = $value
        }
    }

    return $table
}

function Get-DemoPolicyFieldValue {
    <#
    .SYNOPSIS
    Looks up a policy field (for example type or an alias) in the known facts about a resource.

    .DESCRIPTION
    Internal. Returns Known and Value. A field the facts include is known. An alias of another resource
    type, or of a child resource type, doesn't apply to the resource, so its value is known to be absent
    ($null). Anything else is unknown.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Field,

        [AllowNull()]
        [hashtable] $Fact
    )

    $unknown = [pscustomobject]@{ Known = $false; Value = $null }
    $absent = [pscustomobject]@{ Known = $true; Value = $null }
    if ($null -eq $Fact) {
        return $unknown
    }
    if ($Fact.ContainsKey($Field)) {
        return [pscustomobject]@{ Known = $true; Value = $Fact[$Field] }
    }

    $type = [string]$Fact['type']
    if (-not $type -or -not $Field.Contains('/')) {
        return $unknown
    }
    if ($Field.StartsWith($type + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($Field.Substring($type.Length + 1).Contains('/')) {
            return $absent
        }
        return $unknown
    }
    $fieldParts = $Field.Split('/')
    $typeParts = $type.Split('/')
    if ($fieldParts.Count -ge 3 -and $typeParts.Count -ge 2 -and
        -not [string]::Equals(($fieldParts[0..1] -join '/'), ($typeParts[0..1] -join '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return $absent
    }
    return $unknown
}

function Resolve-DemoPolicyExpression {
    <#
    .SYNOPSIS
    Resolves a policy rule value: a literal, [parameters('x')], or [field('x')].

    .DESCRIPTION
    Internal. Returns Known and Value. Any other template expression is unknown, so callers can treat it
    conservatively.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Value,

        [AllowNull()]
        [hashtable] $Parameter,

        [AllowNull()]
        [hashtable] $Fact
    )

    $unknown = [pscustomobject]@{ Known = $false; Value = $null }
    if ($Value -is [string]) {
        if ($Value.StartsWith('[[')) {
            return [pscustomobject]@{ Known = $true; Value = $Value.Substring(1) }
        }
        if ($Value.StartsWith('[') -and $Value.EndsWith(']')) {
            if ($Value -match "^\[parameters\('([^']+)'\)\]$") {
                if ($null -ne $Parameter -and $Parameter.ContainsKey($Matches[1])) {
                    return [pscustomobject]@{ Known = $true; Value = $Parameter[$Matches[1]] }
                }
                return $unknown
            }
            if ($Value -match "^\[field\('([^']+)'\)\]$") {
                return (Get-DemoPolicyFieldValue -Field $Matches[1] -Fact $Fact)
            }
            return $unknown
        }
    }
    return [pscustomobject]@{ Known = $true; Value = $Value }
}

function Test-DemoPolicyValueEqual {
    <#
    .SYNOPSIS
    Compares two policy values the way Azure Policy does: strings ignore case.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Left,

        [AllowNull()]
        [object] $Right
    )

    if ($null -eq $Left -or $null -eq $Right) {
        return ($null -eq $Left -and $null -eq $Right)
    }
    if ($Left -is [string] -or $Right -is [string] -or $Left -is [bool] -or $Right -is [bool]) {
        return [string]::Equals([string]$Left, [string]$Right, [System.StringComparison]::OrdinalIgnoreCase)
    }
    return ($Left -eq $Right)
}

function Test-DemoPolicyOperator {
    <#
    .SYNOPSIS
    Applies one Azure Policy condition operator to a known value: $true, $false, or $null (unknown).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [string] $Operator,

        [AllowNull()]
        [object] $Subject,

        [AllowNull()]
        [object] $Operand
    )

    # Array fields ([*] aliases) follow different rules; the demo's facts never include them.
    if ($Subject -is [System.Collections.IList]) {
        return $null
    }

    switch ($Operator) {
        { $_ -in 'equals', 'notEquals' } {
            $equal = Test-DemoPolicyValueEqual -Left $Subject -Right $Operand
            return $(if ($Operator -eq 'equals') { $equal } else { -not $equal })
        }
        { $_ -in 'in', 'notIn' } {
            $found = $false
            foreach ($item in @($Operand)) {
                if (Test-DemoPolicyValueEqual -Left $Subject -Right $item) {
                    $found = $true
                    break
                }
            }
            return $(if ($Operator -eq 'in') { $found } else { -not $found })
        }
        { $_ -in 'like', 'notLike' } {
            $like = $null -ne $Subject -and ([string]$Subject -like [string]$Operand)
            return $(if ($Operator -eq 'like') { $like } else { -not $like })
        }
        { $_ -in 'match', 'notMatch', 'matchInsensitively', 'notMatchInsensitively' } {
            $pattern = '^' + (-join ([string]$Operand).ToCharArray().ForEach({
                        switch ($_) {
                            '#' { '[0-9]' }
                            '?' { '[a-zA-Z]' }
                            '.' { '.' }
                            default { [regex]::Escape([string]$_) }
                        }
                    })) + '$'
            $options = if ($Operator -like '*Insensitively') { [System.Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [System.Text.RegularExpressions.RegexOptions]::None }
            $matched = $null -ne $Subject -and [regex]::IsMatch([string]$Subject, $pattern, $options)
            return $(if ($Operator -like 'not*') { -not $matched } else { $matched })
        }
        { $_ -in 'contains', 'notContains' } {
            $contains = $null -ne $Subject -and ([string]$Subject).IndexOf([string]$Operand, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
            return $(if ($Operator -eq 'contains') { $contains } else { -not $contains })
        }
        { $_ -in 'containsKey', 'notContainsKey' } {
            if ($null -eq $Subject) {
                return ($Operator -eq 'notContainsKey')
            }
            return $null
        }
        { $_ -in 'less', 'lessOrEquals', 'greater', 'greaterOrEquals' } {
            if ($null -eq $Subject -or $null -eq $Operand) {
                return $null
            }
            $leftNumber = 0.0
            $rightNumber = 0.0
            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            $comparison = if ([double]::TryParse([string]$Subject, [System.Globalization.NumberStyles]::Float, $culture, [ref]$leftNumber) -and
                [double]::TryParse([string]$Operand, [System.Globalization.NumberStyles]::Float, $culture, [ref]$rightNumber)) {
                $leftNumber.CompareTo($rightNumber)
            }
            else {
                [string]::Compare([string]$Subject, [string]$Operand, [System.StringComparison]::OrdinalIgnoreCase)
            }
            switch ($Operator) {
                'less' { return ($comparison -lt 0) }
                'lessOrEquals' { return ($comparison -le 0) }
                'greater' { return ($comparison -gt 0) }
                default { return ($comparison -ge 0) }
            }
        }
        'exists' {
            $wanted = [string]::Equals([string]$Operand, 'true', [System.StringComparison]::OrdinalIgnoreCase)
            return (($null -ne $Subject) -eq $wanted)
        }
    }
    return $null
}

function Test-DemoPolicyCondition {
    <#
    .SYNOPSIS
    Evaluates a policy rule condition against known facts about a resource: $true, $false, or $null (unknown).

    .DESCRIPTION
    Internal. Supports allOf, anyOf, not, field and value conditions, and the documented operators. A field
    the facts don't include, an unsupported template expression, or a count is unknown. allOf is false when
    any part is false, anyOf is true when any part is true, and unknown parts otherwise make the result
    unknown, so callers can treat it conservatively.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowNull()]
        [object] $Condition,

        [Parameter(Mandatory)]
        [hashtable] $Fact,

        [AllowNull()]
        [hashtable] $Parameter
    )

    if ($Condition -isnot [System.Collections.IDictionary]) {
        return $null
    }

    foreach ($logical in 'allOf', 'anyOf') {
        if (-not $Condition.Contains($logical)) {
            continue
        }
        $isAll = $logical -eq 'allOf'
        $unknown = $false
        foreach ($child in @($Condition[$logical])) {
            $result = Test-DemoPolicyCondition -Condition $child -Fact $Fact -Parameter $Parameter
            if ($result -is [bool]) {
                if ($isAll -and -not $result) {
                    return $false
                }
                if (-not $isAll -and $result) {
                    return $true
                }
            }
            else {
                $unknown = $true
            }
        }
        if ($unknown) {
            return $null
        }
        return $isAll
    }

    if ($Condition.Contains('not')) {
        $result = Test-DemoPolicyCondition -Condition $Condition['not'] -Fact $Fact -Parameter $Parameter
        if ($result -is [bool]) {
            return (-not $result)
        }
        return $null
    }

    if ($Condition.Contains('count')) {
        return $null
    }
    if ($Condition.Contains('field')) {
        $fieldName = Resolve-DemoPolicyExpression -Value $Condition['field'] -Parameter $Parameter
        if (-not $fieldName.Known -or $fieldName.Value -isnot [string]) {
            return $null
        }
        $subject = Get-DemoPolicyFieldValue -Field $fieldName.Value -Fact $Fact
    }
    elseif ($Condition.Contains('value')) {
        $subject = Resolve-DemoPolicyExpression -Value $Condition['value'] -Parameter $Parameter -Fact $Fact
    }
    else {
        return $null
    }
    if (-not $subject.Known) {
        return $null
    }

    $operators = @(
        'equals', 'notEquals', 'like', 'notLike', 'match', 'matchInsensitively', 'notMatch', 'notMatchInsensitively',
        'contains', 'notContains', 'in', 'notIn', 'containsKey', 'notContainsKey', 'less', 'lessOrEquals', 'greater',
        'greaterOrEquals', 'exists'
    )
    foreach ($operator in $operators) {
        if ($Condition.Contains($operator)) {
            $operand = Resolve-DemoPolicyExpression -Value $Condition[$operator] -Parameter $Parameter -Fact $Fact
            if (-not $operand.Known) {
                return $null
            }
            return (Test-DemoPolicyOperator -Operator $operator -Subject $subject.Value -Operand $operand.Value)
        }
    }
    return $null
}

function Get-DemoPolicyRuleFact {
    <#
    .SYNOPSIS
    Lists the resource types and fields that a policy rule's condition refers to.

    .DESCRIPTION
    Internal. Types come from 'type' conditions that select resources: equals, in, or like, or their
    negations under not. AnyType is true when the rule has no such condition, so it can apply to any type.
    Fields are every other field the rule reads, including [field('x')] in value conditions.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [object] $Condition,

        [AllowNull()]
        [hashtable] $Parameter
    )

    $types = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $fields = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $hasTypeCondition = $false
    $unresolvedType = $false

    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push([pscustomobject]@{ Node = $Condition; Positive = $true })
    while ($stack.Count -gt 0) {
        $entry = $stack.Pop()
        $node = $entry.Node
        if ($node -is [System.Collections.IList]) {
            foreach ($child in $node) {
                $stack.Push([pscustomobject]@{ Node = $child; Positive = $entry.Positive })
            }
            continue
        }
        if ($node -isnot [System.Collections.IDictionary]) {
            continue
        }

        if ($node.Contains('not')) {
            $stack.Push([pscustomobject]@{ Node = $node['not']; Positive = (-not $entry.Positive) })
        }
        foreach ($logical in 'allOf', 'anyOf') {
            if ($node.Contains($logical)) {
                $stack.Push([pscustomobject]@{ Node = $node[$logical]; Positive = $entry.Positive })
            }
        }
        if ($node['count'] -is [System.Collections.IDictionary]) {
            if ($node['count']['field'] -is [string]) {
                [void]$fields.Add($node['count']['field'])
            }
            if ($node['count'].Contains('where')) {
                $stack.Push([pscustomobject]@{ Node = $node['count']['where']; Positive = $entry.Positive })
            }
        }
        if ($node.Contains('field')) {
            $field = Resolve-DemoPolicyExpression -Value $node['field'] -Parameter $Parameter
            $fieldName = if ($field.Known) { [string]$field.Value } else { [string]$node['field'] }
            if ($fieldName -eq 'type') {
                $hasTypeCondition = $true
                foreach ($operator in 'equals', 'in', 'like', 'notEquals', 'notIn', 'notLike') {
                    if (-not $node.Contains($operator)) {
                        continue
                    }
                    $selects = $operator -in 'equals', 'in', 'like'
                    if ($selects -ne $entry.Positive) {
                        continue
                    }
                    $value = Resolve-DemoPolicyExpression -Value $node[$operator] -Parameter $Parameter
                    if (-not $value.Known) {
                        $unresolvedType = $true
                        continue
                    }
                    foreach ($item in @($value.Value)) {
                        if ($item -is [string] -and $item) {
                            [void]$types.Add($item)
                        }
                    }
                }
            }
            elseif ($fieldName) {
                [void]$fields.Add($fieldName)
            }
        }
        if ($node['value'] -is [string] -and $node['value'] -match "^\[field\('([^']+)'\)\]$" -and $Matches[1] -ne 'type') {
            [void]$fields.Add($Matches[1])
        }
    }

    [pscustomobject]@{
        Types            = @($types)
        AnyType          = ($types.Count -eq 0 -or $unresolvedType)
        HasTypeCondition = $hasTypeCondition
        Fields           = @($fields)
    }
}

function Test-DemoPolicyTypeMatch {
    <#
    .SYNOPSIS
    Tests whether a kept policy rule can apply to a resource type the demo creates.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Rule
    )

    if ($Rule.AnyType) {
        return $true
    }
    foreach ($pattern in @($Rule.Types)) {
        foreach ($type in $script:DemoResourceTypes) {
            if ($type -like $pattern) {
                return $true
            }
        }
    }
    return $false
}

function Get-DemoPolicyRuleCategory {
    <#
    .SYNOPSIS
    Classifies one kept policy rule for the preflight policy checks.

    .DESCRIPTION
    Internal. Returns MFA, SQLPUBLIC, SQLENTRAONLY, DEFENDER, EXTENSIONS, PUBLICIP, STORAGE, VMSIZE,
    RESOURCETYPES, OTHER (any other rule that can apply to a resource type the demo creates), or UNRELATED.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Rule
    )

    $effect = $Rule.Effect
    $details = $Rule.Then['details']
    $fields = @($Rule.Fields)

    if ($Rule.AssignmentName -match '^sys\.mfa' -or $Rule.Policy -match 'multi ?factor authentication enforcement') {
        return 'MFA'
    }

    $sqlPublicAccess = '^Microsoft\.Sql/servers/publicNetworkAccess$'
    if ($effect -eq 'Modify') {
        $operations = Get-DemoMemberValue -InputObject $details -Name 'operations'
        foreach ($operation in @($operations)) {
            if ($operation -isnot [System.Collections.IDictionary]) {
                continue
            }
            $field = Resolve-DemoPolicyExpression -Value $operation['field'] -Parameter $Rule.Parameters
            $value = Resolve-DemoPolicyExpression -Value $operation['value'] -Parameter $Rule.Parameters
            if ($field.Known -and [string]$field.Value -match $sqlPublicAccess -and (-not $value.Known -or [string]$value.Value -eq 'Disabled')) {
                return 'SQLPUBLIC'
            }
        }
    }
    if ($effect -eq 'Deny' -and @($fields | Where-Object { $_ -match $sqlPublicAccess }).Count -gt 0) {
        $facts = @{ type = 'Microsoft.Sql/servers'; 'Microsoft.Sql/servers/publicNetworkAccess' = 'Enabled' }
        if ((Test-DemoPolicyCondition -Condition $Rule.Condition -Fact $facts -Parameter $Rule.Parameters) -ne $false) {
            return 'SQLPUBLIC'
        }
    }
    if ($effect -eq 'Deny' -and @($fields | Where-Object { $_ -match '^Microsoft\.Sql/servers/(administrators\.azureADOnlyAuthentication|azureADOnlyAuthentications/azureADOnlyAuthentication)$' }).Count -gt 0) {
        return 'SQLENTRAONLY'
    }

    if ($effect -eq 'DeployIfNotExists') {
        $deployedType = [string](Get-DemoMemberValue -InputObject $details -Name 'type')
        if ($deployedType -eq 'Microsoft.Security/pricings') {
            return 'DEFENDER'
        }
        if ($deployedType -in 'Microsoft.Compute/virtualMachines/extensions', 'Microsoft.HybridCompute/machines/extensions') {
            return 'EXTENSIONS'
        }
    }

    if ($effect -in 'Append', 'Modify') {
        $changed = [System.Collections.Generic.List[string]]::new()
        $operations = Get-DemoMemberValue -InputObject $details -Name 'operations'
        foreach ($item in @($details) + @($operations)) {
            $field = Get-DemoMemberValue -InputObject $item -Name 'field'
            if ($field -is [string]) {
                $changed.Add($field)
            }
        }
        if (@($Rule.Types) -contains 'Microsoft.Network/publicIPAddresses' -or @($changed | Where-Object { $_ -like 'Microsoft.Network/publicIPAddresses/*' }).Count -gt 0) {
            return 'PUBLICIP'
        }
    }

    if (-not $Rule.AnyType -and @($Rule.Types | Where-Object { $_ -notlike 'Microsoft.Storage/storageAccounts*' }).Count -eq 0) {
        return 'STORAGE'
    }
    if ($effect -eq 'Deny' -and @($fields | Where-Object { $_ -match '^Microsoft\.Compute/virtualMachines/sku\.name$' }).Count -gt 0) {
        return 'VMSIZE'
    }
    if ($effect -eq 'Deny' -and $Rule.HasTypeCondition -and $fields.Count -eq 0) {
        return 'RESOURCETYPES'
    }
    if (Test-DemoPolicyTypeMatch -Rule $Rule) {
        return 'OTHER'
    }
    return 'UNRELATED'
}
