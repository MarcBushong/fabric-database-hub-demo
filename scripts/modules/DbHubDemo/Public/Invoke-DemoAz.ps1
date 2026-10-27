function Invoke-DemoAz {
    <#
    .SYNOPSIS
    Runs an Azure CLI command pinned to the configured subscription, never relying on the CLI's default
    subscription or account.

    .DESCRIPTION
    The Azure CLI's default subscription belongs to the whole profile, and anything else that uses the profile
    can change it, to another tenant included (live finding, 2026-10-21). So every call is targeted
    explicitly, and anything that would fall back to the default account is refused (ADR 0011, updated
    2026-10-21):
    - '--subscription <id>' is appended to every command that accepts it, 'az rest' and token requests
      included. Any other subscription in any argument (--subscription, a scope, a URL) is refused.
    - Signing in or out and changing the CLI context are refused: 'login', 'logout', 'account set',
      'account clear', 'config set', 'config unset', and 'cloud set'.
    - '--ids' is refused: name the resource with --resource-group, --name, and --resource-type, or use
      'az rest' with the full URL. 'az resource show --ids' failed with AuthorizationFailed under another
      tenant's default account.
    - 'az rest': only fully qualified Azure Resource Manager URLs under
      https://management.azure.com/subscriptions/<configured id>, with no {subscriptionId} placeholder. The CLI
      takes the token's account from the URL's subscription, and from the default account for any other URL,
      so tenant-level Resource Manager and Microsoft Graph URLs go through Invoke-DemoRestRequest instead.
    - 'az ad' is refused: it calls Microsoft Graph with the default account. Invoke-DemoRestRequest calls Graph
      with a verified token.
    - 'az account get-access-token': '--tenant' is refused, because the CLI then takes the identity from the
      default account (and rejects it together with --subscription); the appended --subscription picks the
      account and tenant, and Get-DemoAccessToken checks the token's tid and oid claims. A token request gets
      a 120-second time limit unless -TimeoutSeconds sets one. On 'az account', the subscription aliases
      -s, -n, and --name are refused, so only the appended --subscription selects it.
    - 'az role assignment': '--assignee' is refused (the CLI resolves it through Microsoft Graph in the default
      tenant); 'create' needs --assignee-object-id and --assignee-principal-type, and 'list' needs
      '--fill-principal-name false', so no Graph lookup happens.
    - Writes and token requests need the context that Assert-DemoAzContext validated in this process; reads
      ('show', 'list', 'exists', and similar verbs, and 'az rest --method get') don't.
    Errors are redacted before they're thrown.
    Sources: https://learn.microsoft.com/cli/azure/account#az-account-get-access-token,
    https://learn.microsoft.com/cli/azure/reference-index#az-rest,
    https://learn.microsoft.com/cli/azure/role/assignment#az-role-assignment-create

    .PARAMETER TimeoutSeconds
    Stop the Azure CLI when it hasn't finished after this many seconds (0: no limit, except for token
    requests).

    .EXAMPLE
    Invoke-DemoAz -SubscriptionId $config.subscriptionId -ArgumentList 'group', 'show', '--name', 'rg-dbhub-demo' -AsJson
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $ArgumentList,

        [switch] $AsJson,

        [switch] $AllowFailure,

        [ValidateRange(0, 86400)]
        [int] $TimeoutSeconds = 0
    )

    # The command path is the leading words before the first option, for example 'role assignment create'.
    $path = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in $ArgumentList) {
        if ([string]$argument -like '-*') {
            break
        }
        $path.Add(([string]$argument).ToLowerInvariant())
    }
    $command = if ($path.Count -gt 0) { $path[0] } else { ([string]$ArgumentList[0]).ToLowerInvariant() }
    $subcommand = if ($path.Count -gt 1) { $path[1] } else { '' }
    $joined = $path -join ' '
    $display = if ($joined) { $joined } else { $command }

    function Deny-AzCommand([string] $Reason) {
        throw ("Invoke-DemoAz refuses 'az {0}': {1}" -f $display, $Reason)
    }
    function Find-Value([string[]] $Name) {
        Get-DemoAzArgumentValue -ArgumentList $ArgumentList -Name $Name
    }

    $contextChange = $command -in 'login', 'logout' -or
        ($command -eq 'account' -and $subcommand -in 'set', 'clear') -or
        ($command -eq 'config' -and $subcommand -in 'set', 'unset') -or
        ($command -eq 'cloud' -and $subcommand -eq 'set')
    if ($contextChange) {
        throw "Invoke-DemoAz refuses 'az $display'. Scripts never sign in or change the Azure CLI context."
    }
    if ($command -eq 'ad') {
        Deny-AzCommand 'it calls Microsoft Graph with the Azure CLI''s default account, which can be in another tenant. Use Invoke-DemoRestRequest, which calls Graph with a token verified for the configured tenant.'
    }
    if (@($ArgumentList | Where-Object { $_ -ceq '--ids' -or ([string]$_).StartsWith('--ids=', [System.StringComparison]::Ordinal) }).Count -gt 0) {
        Deny-AzCommand '--ids isn''t allowed. Name the resource with --subscription, --resource-group, --name, and --resource-type, or use az rest with the full URL.'
    }
    if (@($ArgumentList | Where-Object { [string]$_ -match '(?i)\{subscriptionId\}' }).Count -gt 0) {
        Deny-AzCommand 'the {subscriptionId} placeholder is replaced with the default subscription. Put the configured subscription in the URL.'
    }
    foreach ($argument in $ArgumentList) {
        foreach ($match in [regex]::Matches([string]$argument, '(?i)/subscriptions/([0-9a-f-]{36})')) {
            if ($match.Groups[1].Value -ne $SubscriptionId) {
                throw ("Invoke-DemoAz refuses subscription '{0}' in 'az {1}'. Only the configured subscription is allowed." -f $match.Groups[1].Value, $display)
            }
        }
    }

    $subscription = Find-Value @('--subscription')
    if ($subscription.Found -and $subscription.Value -ne $SubscriptionId) {
        throw "Invoke-DemoAz refuses --subscription '$($subscription.Value)'. Only the configured subscription is allowed."
    }
    if ($command -eq 'account' -and (Find-Value @('-s', '-n', '--name')).Found) {
        Deny-AzCommand 'select the subscription only with --subscription, which Invoke-DemoAz adds.'
    }

    $isTokenRequest = $joined -eq 'account get-access-token'
    if ($isTokenRequest -and (Find-Value @('--tenant', '-t')).Found) {
        Deny-AzCommand '--tenant makes the Azure CLI use its default account''s identity, which can be another user, and the CLI rejects it together with --subscription. The token''s account and tenant come from --subscription, and Get-DemoAccessToken checks its tenant.'
    }

    if ($command -eq 'role' -and $subcommand -eq 'assignment') {
        if ((Find-Value @('--assignee')).Found) {
            Deny-AzCommand '--assignee is resolved through Microsoft Graph with the Azure CLI''s default account. Use --assignee-object-id with --assignee-principal-type.'
        }
        $verb = if ($path.Count -gt 2) { $path[2] } else { '' }
        if ($verb -eq 'create' -and -not ((Find-Value @('--assignee-object-id')).Found -and (Find-Value @('--assignee-principal-type')).Found)) {
            Deny-AzCommand 'it needs --assignee-object-id and --assignee-principal-type; without the type, the Azure CLI looks the principal up in Microsoft Graph with its default account, which can be in another tenant.'
        }
        if ($verb -eq 'list' -and (Find-Value @('--fill-principal-name')).Value -ne 'false') {
            Deny-AzCommand 'it needs --fill-principal-name false; otherwise the Azure CLI looks the principals up in Microsoft Graph with its default account, which can be in another tenant.'
        }
    }

    $method = 'get'
    if ($command -eq 'rest') {
        $url = (Find-Value @('--url', '--uri', '-u')).Value
        $pattern = '^https://management\.azure\.com/subscriptions/' + [regex]::Escape($SubscriptionId) + '(/|\?|$)'
        if ($url -notmatch $pattern) {
            Deny-AzCommand 'only fully qualified Azure Resource Manager URLs under https://management.azure.com/subscriptions/<configured subscription> are allowed. The Azure CLI takes the token for any other URL from its default account; use Invoke-DemoRestRequest for tenant-level Resource Manager and Microsoft Graph URLs.'
        }
        $requested = (Find-Value @('--method', '-m')).Value
        if ($requested) {
            $method = $requested.ToLowerInvariant()
        }
    }

    $verbOfPath = if ($path.Count -gt 0) { $path[$path.Count - 1] } else { '' }
    $isRead = $command -in 'bicep', 'version' -or
        $joined -eq 'account show' -or
        ($command -eq 'rest' -and $method -eq 'get') -or
        ($command -notin 'rest', 'account' -and $path.Count -ge 2 -and $verbOfPath -in $script:AzReadOnlyVerbs)
    if (($isTokenRequest -or -not $isRead) -and -not $script:DemoAzGuardActive -and $null -eq (Get-DemoValidatedAzContext -SubscriptionId $SubscriptionId)) {
        Deny-AzCommand 'writes and token requests need the Azure CLI context that Assert-DemoAzContext validates. Run the subscription guard first in this process.'
    }

    $arguments = [System.Collections.Generic.List[string]]::new([string[]]$ArgumentList)
    if (-not $subscription.Found -and $command -notin $script:AzCommandsWithoutSubscription) {
        $arguments.Add('--subscription')
        $arguments.Add($SubscriptionId)
    }

    if ($AsJson -and -not ($arguments.Contains('--output') -or $arguments.Contains('-o'))) {
        $arguments.Add('--output')
        $arguments.Add('json')
    }

    if ($isTokenRequest -and $TimeoutSeconds -eq 0) {
        $TimeoutSeconds = 120
    }
    $result = if ($TimeoutSeconds -gt 0) {
        Invoke-DemoAzCli -ArgumentList $arguments.ToArray() -TimeoutSeconds $TimeoutSeconds
    }
    else {
        Invoke-DemoAzCli -ArgumentList $arguments.ToArray()
    }
    if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
        throw ('az {0} {1} failed with exit code {2}: {3}' -f $command, $subcommand, $result.ExitCode, (Protect-DemoText -Text $result.StdErr).Trim())
    }

    if ($AsJson) {
        # With -AllowFailure, a failed command returns $null so callers can test the result directly.
        if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
            return $null
        }
        return ($result.StdOut | ConvertFrom-Json -Depth 64)
    }

    return $result
}
