function Test-DemoAskRelay {
    <#
    .SYNOPSIS
    Checks Ask's chat relay the way the Insights app reaches it, and wakes it: GET <endpoint>/healthz with the app's
    origin. Returns ASK.RELAY.HEALTH and ASK.SIGNIN, each Pass or Warning (Ask never blocks DONE).

    .DESCRIPTION
    The relay scales to zero, so the first request starts a replica (about 15 seconds, measured on 2026-11-18); this
    asks again every 10 seconds until -TimeoutSeconds.
    - ASK.RELAY.HEALTH: Pass when it answers HTTP 200 and allows exactly -Origin (its Access-Control-Allow-Origin).
      Warning when it doesn't answer, or doesn't allow the origin by -TimeoutSeconds: after the origin changes, the
      relay's earlier revision answers until the new one is ready, so the check waits for it.
    - ASK.SIGNIN: Pass when GitHub sign-in is on (the relay has the OAuth App's client ID: device flow, no client
      secret); Warning when it's off, with how to set it. Each viewer signs in once with their own GitHub account.
    Sources: https://learn.microsoft.com/azure/container-apps/scale-app,
    https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow

    .EXAMPLE
    Test-DemoAskRelay -Endpoint 'https://ca-dbhub-demo-ask.<env>.westus3.azurecontainerapps.io' -Origin 'https://<app>.webapp.fabricapps.net'
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^https://[a-z0-9.-]+$')]
        [string] $Endpoint,

        # The Insights app's hosting origin; '' checks only that the relay answers.
        [AllowEmptyString()]
        [string] $Origin = '',

        # Where the OAuth App's client ID came from: pinned (config/versions.json) or config (demo.config.json).
        [ValidateSet('pinned', 'config', '')]
        [string] $ClientIdSource = 'pinned',

        [ValidateRange(10, 600)]
        [int] $TimeoutSeconds = 120
    )

    $doc = 'https://learn.microsoft.com/azure/container-apps/scale-app'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null
    $stale = $null
    $lastError = ''
    $headers = @{ 'User-Agent' = 'DbHubDemo-AskCheck' }
    if ($Origin) {
        $headers['Origin'] = $Origin
    }
    # A relay at zero starts a replica first, and one whose origin was just set answers from its earlier revision until
    # the new one is ready (live, 2026-11-19: 27 s), so it asks again every 10 seconds until it allows -Origin.
    $attempts = [int][Math]::Ceiling($TimeoutSeconds / 10) + 1
    for ($attempt = 1; $attempt -le $attempts -and $watch.Elapsed.TotalSeconds -lt $TimeoutSeconds; $attempt++) {
        try {
            $candidate = Invoke-WebRequest -Uri ('{0}/healthz' -f $Endpoint) -Headers $headers -TimeoutSec ([Math]::Max(10, [Math]::Min(45, $TimeoutSeconds - [int]$watch.Elapsed.TotalSeconds))) -SkipHttpErrorCheck -ErrorAction Stop
            if ($candidate.StatusCode -eq 200) {
                $allowedNow = [string](@($candidate.Headers['Access-Control-Allow-Origin']) | Select-Object -First 1)
                if (-not $Origin -or $allowedNow -eq $Origin) {
                    $response = $candidate
                    break
                }
                $stale = $candidate
            }
            else {
                $lastError = 'HTTP {0}' -f $candidate.StatusCode
            }
        }
        catch {
            $lastError = Protect-DemoText -Text $_.Exception.Message
        }
        Start-Sleep -Seconds 10
    }
    if ($null -eq $response) {
        $response = $stale
    }
    $seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1)
    $evidence = [ordered]@{ endpoint = $Endpoint; origin = $Origin; seconds = $seconds }
    if ($null -eq $response) {
        $appName = ([uri]$Endpoint).Host.Split('.')[0]
        return @(New-DemoResult -CheckId 'ASK.RELAY.HEALTH' -Area 'fabric' -Target 'subscription' -Status 'Warning' -Message ('Ask''s chat relay didn''t answer within {0} s: {1}. The Copilot dock says it can''t reach it; everything else in the app works.' -f $TimeoutSeconds, $lastError) -Evidence $evidence -Remediation ('Run ./scripts/configure-fabric-app.ps1 again. If it still doesn''t answer, its log says why: in the Azure portal, the container app {0} > Monitoring > Log stream. An image Container Apps can''t pull is the usual cause.' -f $appName) -DocUrl $doc)
    }
    $health = $null
    try {
        $health = $response.Content | ConvertFrom-Json -AsHashtable
    }
    catch {
        $health = @{}
    }
    $allowed = [string](@($response.Headers['Access-Control-Allow-Origin']) | Select-Object -First 1)
    $evidence['version'] = [string]$health['version']
    $evidence['signIn'] = [string]$health['signIn']
    $evidence['allowedOrigin'] = $allowed
    $results = [System.Collections.Generic.List[object]]::new()
    if ($Origin -and $allowed -ne $Origin) {
        $results.Add((New-DemoResult -CheckId 'ASK.RELAY.HEALTH' -Area 'fabric' -Target 'subscription' -Status 'Warning' -Message ('Ask''s chat relay answers ({0} s, version {1}), but doesn''t allow the Insights app''s origin {2} yet, so the Copilot dock can''t use it.' -f $seconds, $evidence['version'], $Origin) -Evidence $evidence -Remediation 'Run ./scripts/configure-fabric-app.ps1 again: it sets the relay''s origin from the app''s deployment.' -DocUrl $doc))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'ASK.RELAY.HEALTH' -Area 'fabric' -Target 'subscription' -Status 'Pass' -Message ('Ask''s chat relay answers ({0} s, from zero or warm; version {1}){2}.' -f $seconds, $evidence['version'], $(if ($Origin) { ' and allows only the Insights app''s origin, {0}' -f $Origin } else { '' })) -Evidence $evidence -DocUrl $doc))
    }
    $deviceFlow = 'https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow'
    if ([string]$health['signIn'] -eq 'device') {
        $whose = if ($ClientIdSource -eq 'config') { 'your own GitHub OAuth App (ask.githubClientId in config/demo.config.json)' } else { 'the shared GitHub OAuth App "Database Hub Insights Ask" (config/versions.json), so nobody registers anything' }
        $results.Add((New-DemoResult -CheckId 'ASK.SIGNIN' -Area 'fabric' -Target 'github' -Status 'Pass' -Message ('GitHub sign-in is on: each viewer signs in once per browser with their own GitHub account and Copilot license, through {0}.' -f $whose) -Evidence ([ordered]@{ signIn = 'device'; clientIdSource = $ClientIdSource }) -DocUrl $deviceFlow))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'ASK.SIGNIN' -Area 'fabric' -Target 'github' -Status 'Warning' -Message 'GitHub sign-in isn''t set up on Ask''s chat relay: it has no GitHub OAuth App client ID, so the Copilot dock shows the one-time registration steps instead of Sign in with GitHub.' -Evidence ([ordered]@{ signIn = [string]$health['signIn']; clientIdSource = $ClientIdSource }) -Remediation 'Put a GitHub OAuth App''s client ID (device flow on, no client secret) in config/versions.json askRelay.githubClientId, or ask.githubClientId in config/demo.config.json, and run ./scripts/configure-fabric-app.ps1 again.' -DocUrl $deviceFlow))
    }
    return $results.ToArray()
}
