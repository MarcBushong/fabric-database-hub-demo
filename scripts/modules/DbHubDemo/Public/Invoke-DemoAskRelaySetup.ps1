function Invoke-DemoAskRelaySetup {
    <#
    .SYNOPSIS
    Sets up Ask's chat relay (ADR 0028) in the demo resource group: infra/ask/ask-relay.bicep, the Container Apps
    environment cae-<prefix>-<environment>-ask and the relay ca-<prefix>-<environment>-ask, on the pinned image. Returns
    Results (ASK.RELAY), Endpoint (the relay's https address, '' when there's none), AllowedOrigins, and ClientIdSource (where the GitHub OAuth App's client ID came from: pinned, config, or '').

    .DESCRIPTION
    configure-fabric-app.ps1 runs it before it stages the app, so the app's dbhub-app.json gets the relay's address, and
    again with the app's hosting origin once rayfin up has deployed the app, so the relay serves that origin only.
    - The image: demo.config.json's ask.image, else config/versions.json's askRelay.image (pinned by digest, built by
      .github/workflows/ask-relay-image.yml). Without either, nothing is deployed (Warning).
    - The origin it serves: -AllowedOrigin, else the one the stage's rayfin/.deployments.json records (the app's last
      deployment), else the one the relay already has, so an upgrade keeps it.
    - Microsoft.App is registered first when it isn't (az provider register --wait).
    - No secret, registry credential, identity, or role: the relay holds only the OAuth App's public client ID.
    Ask never blocks DONE: ASK.RELAY is Pass, Warning (with the actual reason and the fix), or Not selected (ask.enabled
    is false, or -WhatIf). The template's parameters go in a file in a private directory.
    Sources: https://learn.microsoft.com/azure/container-apps/overview,
    https://learn.microsoft.com/azure/templates/microsoft.app/containerapps,
    https://learn.microsoft.com/cli/azure/deployment/group#az-deployment-group-create,
    https://learn.microsoft.com/cli/azure/provider#az-provider-register

    .EXAMPLE
    $ask = Invoke-DemoAskRelaySetup -Config (Get-DemoConfig) -StagePath ./out/fabric-app
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        # The origin the relay serves, https://<host>: the Insights app's hosting origin.
        [AllowEmptyString()]
        [string] $AllowedOrigin = '',

        # The app's deploy stage, whose rayfin/.deployments.json records the app's last hosting origin.
        [AllowEmptyString()]
        [string] $StagePath = ''
    )

    $setting = Get-DemoAskSetting -Config $Config
    $name = Get-DemoAskRelayName -Config $Config
    $evidence = [ordered]@{ resourceGroup = $name.ResourceGroup; app = $name.App; environment = $name.Environment; image = (Get-DemoAskImageLabel -Image $setting.Image); imageSource = $setting.ImageSource }
    $result = {
        param([string] $Status, [string] $Message, [string] $Remediation = '')
        New-DemoResult -CheckId 'ASK.RELAY' -Area 'infra' -Target 'subscription' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $script:AskRelayDocUrl
    }
    $done = {
        param([object] $Record, [string] $Endpoint = '', [string] $Origins = '')
        [pscustomobject]@{ Results = @($Record); Endpoint = $Endpoint; AllowedOrigins = $Origins; ClientIdSource = $setting.ClientIdSource }
    }
    $rerun = 'Fix the cause, then run ./scripts/configure-fabric-app.ps1 (or ./scripts/deploy.ps1) again. Everything else in the Insights app works meanwhile; its Copilot dock says Ask isn''t deployed.'

    if (-not $setting.Enabled) {
        return (& $done (& $result 'Not selected' 'Ask (the Copilot chat in the Insights app) is off: ask.enabled is false in the configuration, so no chat relay was deployed, and the app''s Copilot dock says Ask isn''t deployed.' 'To turn it on, remove "enabled": false from the ask block in config/demo.config.json and run ./scripts/deploy.ps1.'))
    }
    if (-not $setting.Image) {
        return (& $done (& $result 'Warning' 'Ask''s chat relay wasn''t deployed: no relay image is pinned yet (config/versions.json askRelay.image is empty). The app''s Copilot dock says Ask isn''t deployed; everything else works.' 'The repository''s owner publishes the image with .github/workflows/ask-relay-image.yml and pins its digest in config/versions.json; then run ./scripts/deploy.ps1 again. Or set ask.image in config/demo.config.json to your own image, pinned by digest.'))
    }
    if (-not $PSCmdlet.ShouldProcess($name.ResourceGroup, ('Deploy infra/ask/ask-relay.bicep: {0} and {1} on {2}' -f $name.Environment, $name.App, (Get-DemoAskImageLabel -Image $setting.Image)))) {
        return (& $done (& $result 'Not selected' ('What if: {0} and {1} would be deployed in {2}, on {3}.' -f $name.Environment, $name.App, $name.ResourceGroup, (Get-DemoAskImageLabel -Image $setting.Image))))
    }

    $registered = Invoke-DemoAz -SubscriptionId $name.SubscriptionId -ArgumentList @('provider', 'show', '--namespace', 'Microsoft.App', '--query', 'registrationState', '--output', 'tsv') -AllowFailure -TimeoutSeconds 120
    if ($registered.ExitCode -ne 0 -or ([string]$registered.StdOut).Trim() -ne 'Registered') {
        Write-DemoLog -Message 'Registering the Microsoft.App resource provider for Ask''s chat relay (once per subscription; it can take a few minutes).'
        $register = Invoke-DemoAz -SubscriptionId $name.SubscriptionId -ArgumentList @('provider', 'register', '--namespace', 'Microsoft.App', '--wait') -AllowFailure -TimeoutSeconds 900
        if ($register.ExitCode -ne 0) {
            return (& $done (& $result 'Warning' ('Ask''s chat relay wasn''t deployed: the Microsoft.App resource provider isn''t registered, and registering it failed: {0}' -f (Get-DemoDeploymentErrorText -Text ([string]$register.StdErr) -MaxLength 400)) ('Someone who may register resource providers in the subscription runs az provider register --namespace Microsoft.App --subscription {0}; then run ./scripts/configure-fabric-app.ps1 again.' -f $name.SubscriptionId)))
        }
    }

    $current = Get-DemoAskRelayState -Name $name
    $origins = Get-DemoAskOrigin -Url $AllowedOrigin
    if (-not $origins) {
        $origins = Get-DemoFabricAppHostingOrigin -StagePath $StagePath
    }
    if (-not $origins) {
        $origins = [string]$current.AllowedOrigins
    }
    $evidence['allowedOrigins'] = $origins

    $tags = [ordered]@{}
    try {
        $groupTags = Get-DemoResourceGroupTag -SubscriptionId $name.SubscriptionId -ResourceGroupName $name.ResourceGroup
        foreach ($key in $script:SafetyStopTagNames) {
            if ($groupTags.Contains($key) -and [string]$groupTags[$key]) {
                $tags[$key] = [string]$groupTags[$key]
            }
        }
    }
    catch {
        Write-DemoLog -Level Debug -Message ('The demo resource group''s tags weren''t read for Ask''s relay: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
    }
    $tags['component'] = 'ask-relay'
    $parameters = [ordered]@{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = [ordered]@{
            location        = @{ value = [string]$Config['location'] }
            environmentName = @{ value = $name.Environment }
            appName         = @{ value = $name.App }
            image           = @{ value = $setting.Image }
            githubClientId  = @{ value = $setting.GithubClientId }
            allowedOrigins  = @{ value = $origins }
            cpu             = @{ value = [string]$setting.ContainerApp['cpu'] }
            memory          = @{ value = [string]$setting.ContainerApp['memory'] }
            maxReplicas     = @{ value = [int]$setting.ContainerApp['maxReplicas'] }
            tags            = @{ value = $tags }
        }
    }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-ask'
    try {
        $path = Write-DemoPrivateFile -Directory $directory -Name 'ask-relay.parameters.json' -Content (ConvertTo-Json -InputObject $parameters -Depth 8)
        $template = Join-Path -Path $script:RepoRoot -ChildPath 'infra/ask/ask-relay.bicep'
        $run = Invoke-DemoAz -SubscriptionId $name.SubscriptionId -ArgumentList @('deployment', 'group', 'create', '--resource-group', $name.ResourceGroup, '--name', $name.Deployment, '--template-file', $template, '--parameters', "@$path", '--query', 'properties.outputs', '--output', 'json') -AllowFailure -TimeoutSeconds 900
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false -WhatIf:$false | Out-Null
    }
    $seconds = [int]$watch.Elapsed.TotalSeconds
    $evidence['seconds'] = $seconds
    if ($run.ExitCode -ne 0) {
        $endpoint = if ($current.Exists) { [string]$current.Endpoint } else { '' }
        $kept = if ($current.Exists) { ' The relay that was already there keeps running on its earlier image.' } else { '' }
        $label = Get-DemoAskImageLabel -Image $setting.Image
        switch (Get-DemoAskImagePullProblem -Text ([string]$run.StdErr)) {
            'private' {
                return (& $done (& $result 'Warning' ('Ask''s chat relay wasn''t deployed ({0} s): Container Apps couldn''t pull its image ({1}) without credentials. deploy.ps1 pulls it anonymously, so its package must be public; a new GitHub Container Registry package can start private, GitHub''s default, so a fork''s or a private copy''s may be (or the package doesn''t exist).{2}' -f $seconds, $label, $kept) 'The image''s owner makes its package public (on GitHub, the package''s Package settings: Change visibility, Public; a public package can''t be made private again, only deleted), then run ./scripts/deploy.ps1 again. Or set ask.image in config/demo.config.json to an image that pulls without credentials, pinned by digest. Everything else in the Insights app works meanwhile.') $endpoint ([string]$current.AllowedOrigins))
            }
            'missing' {
                return (& $done (& $result 'Warning' ('Ask''s chat relay wasn''t deployed ({0} s): its registry has no image with the pinned digest ({1}).{2}' -f $seconds, $label, $kept) 'Pin a digest that .github/workflows/ask-relay-image.yml printed (config/versions.json askRelay.image), or correct ask.image in config/demo.config.json; then run ./scripts/deploy.ps1 again. Everything else in the Insights app works meanwhile.') $endpoint ([string]$current.AllowedOrigins))
            }
        }
        return (& $done (& $result 'Warning' ('Ask''s chat relay couldn''t be deployed ({0} s): {1}' -f $seconds, (Get-DemoDeploymentErrorText -Text ([string]$run.StdErr) -MaxLength 600)) $rerun) $endpoint ([string]$current.AllowedOrigins))
    }
    $endpoint = ''
    try {
        $outputs = [string]$run.StdOut | ConvertFrom-Json -AsHashtable
        $endpoint = [string]$outputs['endpoint']['value']
    }
    catch {
        $endpoint = ''
    }
    if ($endpoint -notmatch '^https://[a-z0-9.-]+\.azurecontainerapps\.io$') {
        $endpoint = [string](Get-DemoAskRelayState -Name $name).Endpoint
    }
    $evidence['endpoint'] = $endpoint
    $serves = if ($origins) { 'serves only the Insights app''s origin, {0}' -f $origins } else { 'serves no origin until the Insights app is deployed' }
    $message = 'Ask''s chat relay {0} is deployed in {1} ({2} s): {3}, scaled to zero while nobody asks; it {4}.' -f $name.App, $name.ResourceGroup, $seconds, (Get-DemoAskImageLabel -Image $setting.Image), $serves
    return (& $done (& $result 'Pass' $message) $endpoint $origins)
}
