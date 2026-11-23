# Ask (ADR 0028): the Insights app's in-app GitHub Copilot chat. Its chat relay is an Azure Container App in the demo
# resource group (infra/ask/ask-relay.bicep). Internal helpers for Invoke-DemoAskRelaySetup, Test-DemoAskRelay, and
# Test-DemoAskCspSetting. Every result about Ask is Pass, Warning, or Not selected: Ask never blocks DONE.

$script:AskRelayDocUrl = 'https://learn.microsoft.com/azure/container-apps/overview'

function Get-DemoAskSetting {
    <#
    .SYNOPSIS
    Ask's settings, demo.config.json's ask block over config/versions.json's askRelay: Enabled; Image and ImageSource
    (config, pinned, or '' when neither has one); GithubClientId and ClientIdSource (config, pinned, or ''); and
    ContainerApp (cpu, memory, maxReplicas). Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        # config/versions.json, parsed; read from the repository when it isn't passed.
        [System.Collections.IDictionary] $Versions
    )

    if ($null -eq $Versions) {
        $Versions = Get-Content -LiteralPath (Join-Path -Path $script:RepoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    }
    $pinned = if ($Versions.Contains('askRelay') -and $Versions['askRelay'] -is [System.Collections.IDictionary]) { $Versions['askRelay'] } else { @{} }
    $ask = if ($Config.Contains('ask') -and $Config['ask'] -is [System.Collections.IDictionary]) { $Config['ask'] } else { @{} }
    $image = if ($ask.Contains('image')) { ([string]$ask['image']).Trim() } else { '' }
    $imageSource = 'config'
    if (-not $image) {
        $image = ([string]$pinned['image']).Trim()
        $imageSource = if ($image) { 'pinned' } else { '' }
    }
    $clientId = if ($ask.Contains('githubClientId')) { ([string]$ask['githubClientId']).Trim() } else { '' }
    $clientIdSource = 'config'
    if (-not $clientId) {
        $clientId = ([string]$pinned['githubClientId']).Trim()
        $clientIdSource = if ($clientId) { 'pinned' } else { '' }
    }
    $app = [ordered]@{ cpu = '1.0'; memory = '2Gi'; maxReplicas = 1 }
    if ($pinned['containerApp'] -is [System.Collections.IDictionary]) {
        foreach ($key in @($app.Keys)) {
            if ($pinned['containerApp'].Contains($key)) {
                $app[$key] = $pinned['containerApp'][$key]
            }
        }
    }
    return [pscustomobject]@{
        Enabled        = -not ($ask.Contains('enabled') -and $ask['enabled'] -eq $false)
        Image          = $image
        ImageSource    = $imageSource
        GithubClientId = $clientId
        ClientIdSource = $clientIdSource
        ContainerApp   = $app
    }
}

function Get-DemoAskRelayName {
    # The relay's names in the demo resource group: the environment cae-<prefix>-<environment>-ask and the container app
    # ca-<prefix>-<environment>-ask (24 characters at most, within the app's 32). Pure. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config
    )

    $stem = '{0}-{1}' -f ([string]$Config['prefix']).ToLowerInvariant(), ([string]$Config['environment']).ToLowerInvariant()
    return [pscustomobject]@{
        SubscriptionId = [string]$Config['subscriptionId']
        ResourceGroup  = Get-DemoResourceGroupName -Config $Config
        Environment    = 'cae-{0}-ask' -f $stem
        App            = 'ca-{0}-ask' -f $stem
        Deployment     = 'ask-relay'
    }
}

function Get-DemoAskOrigin {
    # The origin of an https URL ('https://host', with its port when it has one), lowercase; '' for anything else. Pure.
    # Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Url
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate(([string]$Url).Trim(), [System.UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or -not $uri.Host) {
        return ''
    }
    return $uri.GetLeftPart([System.UriPartial]::Authority).ToLowerInvariant()
}

function Get-DemoFabricAppHostingOrigin {
    # The Insights app's hosting origin from the deploy stage's rayfin/.deployments.json, which rayfin up writes and the
    # stage keeps between runs: its active deployment's hostingUrl. '' when there's none. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $StagePath = ''
    )

    if (-not $StagePath) {
        return ''
    }
    $path = Join-Path -Path $StagePath -ChildPath 'rayfin/.deployments.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    try {
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $active = [string]$data['active']
        $deployments = $data['deployments']
        if (-not $active -or $deployments -isnot [System.Collections.IDictionary] -or -not $deployments.Contains($active)) {
            return ''
        }
        return (Get-DemoAskOrigin -Url ([string](Get-DemoMemberValue -InputObject $deployments[$active] -Name 'hostingUrl')))
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The stage''s rayfin/.deployments.json wasn''t read: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        return ''
    }
}

function Get-DemoAskRelayState {
    # What the relay in the demo resource group runs now (one read): Exists, Image, AllowedOrigins (its ALLOWED_ORIGINS),
    # and Endpoint. Error says why it couldn't be read, '' when it simply isn't there. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Name
    )

    $state = [ordered]@{ Exists = $false; Image = ''; AllowedOrigins = ''; Endpoint = ''; Error = '' }
    $query = '{image:properties.template.containers[0].image,env:properties.template.containers[0].env,fqdn:properties.configuration.ingress.fqdn}'
    $run = Invoke-DemoAz -SubscriptionId $Name.SubscriptionId -ArgumentList @('resource', 'show', '--resource-group', $Name.ResourceGroup, '--resource-type', 'Microsoft.App/containerApps', '--name', $Name.App, '--query', $query, '--output', 'json') -AllowFailure -TimeoutSeconds 120
    if ($run.ExitCode -ne 0) {
        if (-not (Test-DemoAzNotFound -Text ([string]$run.StdErr))) {
            $state['Error'] = Get-DemoDeploymentErrorText -Text ([string]$run.StdErr) -MaxLength 300
        }
        return [pscustomobject]$state
    }
    try {
        $data = [string]$run.StdOut | ConvertFrom-Json -AsHashtable
    }
    catch {
        $state['Error'] = 'its properties couldn''t be read'
        return [pscustomobject]$state
    }
    $state['Exists'] = $true
    $state['Image'] = [string]$data['image']
    $state['AllowedOrigins'] = [string](@(@($data['env']) | Where-Object { $_ -is [System.Collections.IDictionary] -and [string]$_['name'] -eq 'ALLOWED_ORIGINS' } | ForEach-Object { $_['value'] }) | Select-Object -First 1)
    $fqdn = [string]$data['fqdn']
    if ($fqdn -match '^[a-z0-9.-]+\.azurecontainerapps\.io$') {
        $state['Endpoint'] = 'https://{0}' -f $fqdn
    }
    return [pscustomobject]$state
}

function Get-DemoAskImageLabel {
    # A short, readable name for an image reference: repository@sha256:<first 12>. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Image = ''
    )

    if ($Image -match '^(?<repo>[^@]+)@sha256:(?<digest>[0-9a-f]{12})') {
        return '{0}@sha256:{1}' -f ($Matches['repo'] -replace '^.*/', ''), $Matches['digest']
    }
    return $Image
}

function Get-DemoAskImagePullProblem {
    # Why Container Apps couldn't pull the relay's image, from a deployment's error text: 'private' when the registry
    # refused an anonymous pull (a new GitHub Container Registry package can start private, GitHub's default, so a
    # fork's or a private copy's may be, and GHCR answers the same for a package that doesn't exist), 'missing' when no
    # image has the pinned digest, or '' for any other failure. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Text = ''
    )

    if ($Text -notmatch '(?i)template\.containers|\bimage\b') {
        return ''
    }
    if ($Text -match '(?i)MANIFEST_UNKNOWN|manifest unknown') {
        return 'missing'
    }
    if ($Text -match '(?i)\bUNAUTHORIZED\b|\bDENIED\b|authentication required|NAME_UNKNOWN') {
        return 'private'
    }
    return ''
}
