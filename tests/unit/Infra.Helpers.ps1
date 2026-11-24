# A small evaluator for the compiled template (azuredeploy.json) and its nested templates, shared by the Infra tests: each
# resource whose condition holds, with its ARM template expressions resolved. Unknown functions throw, so a template change
# that needs more fails visibly instead of being skipped. Dot-source it in a BeforeAll.

# Every node of the compiled template, depth first.
function Get-TemplateNode {
    param([object] $Root)
    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $node = $stack.Pop()
        if ($node -is [System.Collections.IDictionary]) {
            $node
            foreach ($value in $node.Values) { $stack.Push($value) }
        }
        elseif ($node -is [System.Collections.IList]) {
            foreach ($value in $node) { $stack.Push($value) }
        }
    }
}

function Get-NestedDeployment {
    param([object] $Root, [string] $Name)
    Get-TemplateNode -Root $Root | Where-Object { $_['type'] -eq 'Microsoft.Resources/deployments' -and $_['name'] -eq $Name } | Select-Object -First 1
}

# A small evaluator for the ARM template expressions the T3 module and its caller use. Unknown functions
# throw, so a template change that needs more fails here visibly instead of being skipped.
function ConvertTo-ArmToken {
    param([string] $Text)
    $tokens = [System.Collections.Generic.List[object]]::new()
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ([char]::IsWhiteSpace($c)) { $i++; continue }
        if ($c -eq "'") {
            $builder = [System.Text.StringBuilder]::new()
            $i++
            while ($true) {
                if ($Text[$i] -eq "'") {
                    if ($i + 1 -lt $Text.Length -and $Text[$i + 1] -eq "'") { [void]$builder.Append("'"); $i += 2; continue }
                    $i++
                    break
                }
                [void]$builder.Append($Text[$i])
                $i++
            }
            $tokens.Add(@{ Kind = 'value'; Value = $builder.ToString() })
            continue
        }
        if ($c -match '[0-9]' -or ($c -eq '-' -and $Text[$i + 1] -match '[0-9]')) {
            $start = $i
            $i++
            while ($i -lt $Text.Length -and $Text[$i] -match '[0-9.]') { $i++ }
            $tokens.Add(@{ Kind = 'value'; Value = [double]::Parse($Text.Substring($start, $i - $start), [System.Globalization.CultureInfo]::InvariantCulture) })
            continue
        }
        if ($c -match '[A-Za-z_$#]') {
            $start = $i
            while ($i -lt $Text.Length -and $Text[$i] -match '[A-Za-z0-9_$#]') { $i++ }
            $tokens.Add(@{ Kind = 'name'; Value = $Text.Substring($start, $i - $start) })
            continue
        }
        if ('(),.[]'.Contains($c)) {
            $tokens.Add(@{ Kind = 'punct'; Value = [string]$c })
            $i++
            continue
        }
        throw "Unexpected character '$c' in [$Text]"
    }
    return , $tokens
}

function Get-ArmMember {
    param([object] $Value, [object] $Name)
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ([string]::Equals([string]$key, [string]$Name, [System.StringComparison]::OrdinalIgnoreCase)) { return , $Value[$key] }
        }
        throw "No member '$Name'."
    }
    if ($Value -is [System.Collections.IList]) { return , $Value[[int]$Name] }
    throw "Can't read '$Name' from a $($Value.GetType().Name)."
}

function Invoke-ArmFunction {
    param([string] $Name, [object[]] $Arguments, [hashtable] $Context)
    switch ($Name.ToLowerInvariant()) {
        'parameters' {
            if (-not $Context.Parameters.ContainsKey($Arguments[0])) { throw "No value for parameter '$($Arguments[0])'." }
            return , $Context.Parameters[$Arguments[0]]
        }
        'variables' { return , (Get-ArmVariable -Name $Arguments[0] -Context $Context) }
        'equals' { return ([string]$Arguments[0] -ceq [string]$Arguments[1]) }
        'not' { return (-not [bool]$Arguments[0]) }
        'and' { return (@($Arguments | Where-Object { -not [bool]$_ }).Count -eq 0) }
        'or' { return (@($Arguments | Where-Object { [bool]$_ }).Count -gt 0) }
        'if' { if ([bool]$Arguments[0]) { return , $Arguments[1] } else { return , $Arguments[2] } }
        'true' { return $true }
        'false' { return $false }
        'createobject' {
            $object = [ordered]@{}
            for ($i = 0; $i -lt $Arguments.Count; $i += 2) { $object[[string]$Arguments[$i]] = $Arguments[$i + 1] }
            return , $object
        }
        'createarray' { return , @($Arguments) }
        'union' {
            $merged = [ordered]@{}
            foreach ($object in $Arguments) { foreach ($key in $object.Keys) { $merged[$key] = $object[$key] } }
            return , $merged
        }
        'mul' { return ([long]$Arguments[0] * [long]$Arguments[1]) }
        'format' { return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, [string]$Arguments[0], [object[]]@($Arguments | Select-Object -Skip 1)) }
        'split' { return , ([string]$Arguments[0]).Split([string]$Arguments[1]) }
        'last' { $items = $Arguments[0]; return , $items[$items.Count - 1] }
        'string' { return [string]$Arguments[0] }
        'json' { return , ([string]$Arguments[0] | ConvertFrom-Json -AsHashtable) }
        'replace' { return ([string]$Arguments[0]).Replace([string]$Arguments[1], [string]$Arguments[2]) }
        'environment' { return , @{ name = 'AzureCloud'; suffixes = @{ sqlServerHostname = '.database.windows.net' } } }
        'subscription' { return , @{ id = '/subscriptions/11111111-2222-3333-4444-555555555555'; subscriptionId = '11111111-2222-3333-4444-555555555555'; tenantId = '66666666-7777-8888-9999-000000000000' } }
        'resourceid' { return ('resourceId:{0}' -f (@($Arguments) -join '/')) }
        'reference' { return , @{ reference = $Arguments[0] } }
        default { throw "The test evaluator doesn't support the ARM function '$Name'." }
    }
}

function Read-ArmExpression {
    param([hashtable] $State, [hashtable] $Context)
    $token = $State.Tokens[$State.Position]
    $State.Position++
    if ($token.Kind -eq 'value') {
        $value = $token.Value
    }
    elseif ($token.Kind -eq 'name') {
        $State.Position++ # (
        $arguments = [System.Collections.Generic.List[object]]::new()
        while ($State.Tokens[$State.Position].Value -ne ')') {
            $arguments.Add((Read-ArmExpression -State $State -Context $Context))
            if ($State.Tokens[$State.Position].Value -eq ',') { $State.Position++ }
        }
        $State.Position++ # )
        $value = Invoke-ArmFunction -Name $token.Value -Arguments $arguments.ToArray() -Context $Context
    }
    else {
        throw "Unexpected '$($token.Value)'."
    }
    while ($State.Position -lt $State.Tokens.Count) {
        $next = $State.Tokens[$State.Position]
        if ($next.Kind -eq 'punct' -and $next.Value -eq '.') {
            $value = Get-ArmMember -Value $value -Name $State.Tokens[$State.Position + 1].Value
            $State.Position += 2
        }
        elseif ($next.Kind -eq 'punct' -and $next.Value -eq '[') {
            $State.Position++
            $index = Read-ArmExpression -State $State -Context $Context
            $State.Position++ # ]
            $value = Get-ArmMember -Value $value -Name $index
        }
        else {
            break
        }
    }
    return , $value
}

function Resolve-ArmValue {
    param([object] $Value, [hashtable] $Context)
    if ($Value -is [string]) {
        if ($Value.StartsWith('[[')) { return $Value.Substring(1) }
        if ($Value.StartsWith('[') -and $Value.EndsWith(']')) {
            $state = @{ Tokens = (ConvertTo-ArmToken -Text $Value.Substring(1, $Value.Length - 2)); Position = 0 }
            return , (Read-ArmExpression -State $state -Context $Context)
        }
        return $Value
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) { $copy[$key] = Resolve-ArmValue -Value $Value[$key] -Context $Context }
        return , $copy
    }
    if ($Value -is [System.Collections.IList]) {
        return , @(foreach ($item in $Value) { , (Resolve-ArmValue -Value $item -Context $Context) })
    }
    return $Value
}

function Get-ArmVariable {
    param([string] $Name, [hashtable] $Context)
    if (-not $Context.VariableCache.ContainsKey($Name)) {
        $Context.VariableCache[$Name] = Resolve-ArmValue -Value $Context.Template['variables'][$Name] -Context $Context
    }
    return , $Context.VariableCache[$Name]
}

# Evaluates a (nested) template: every resource whose condition holds, with its expressions resolved.
function Invoke-ArmTemplate {
    param([System.Collections.IDictionary] $Template, [hashtable] $Parameters)
    $values = @{}
    foreach ($name in $Template['parameters'].Keys) {
        if ($Parameters.ContainsKey($name)) { $values[$name] = $Parameters[$name] }
        elseif ($Template['parameters'][$name].Contains('defaultValue')) { $values[$name] = $Template['parameters'][$name]['defaultValue'] }
        else { throw "The test supplies no value for the required parameter '$name'." }
    }
    $context = @{ Template = $Template; Parameters = $values; VariableCache = @{} }
    $resources = if ($Template['resources'] -is [System.Collections.IDictionary]) { @($Template['resources'].Values) } else { @($Template['resources']) }
    $deployed = foreach ($resource in $resources) {
        if ($resource.Contains('condition') -and -not [bool](Resolve-ArmValue -Value $resource['condition'] -Context $context)) { continue }
        [pscustomobject]@{
            Type       = $resource['type']
            Name       = Resolve-ArmValue -Value $resource['name'] -Context $context
            Sku        = if ($resource.Contains('sku')) { Resolve-ArmValue -Value $resource['sku'] -Context $context } else { $null }
            Properties = if ($resource.Contains('properties')) { Resolve-ArmValue -Value $resource['properties'] -Context $context } else { $null }
            Location   = if ($resource.Contains('location')) { Resolve-ArmValue -Value $resource['location'] -Context $context } else { $null }
        }
    }
    [pscustomobject]@{ Resources = @($deployed); Context = $context }
}
