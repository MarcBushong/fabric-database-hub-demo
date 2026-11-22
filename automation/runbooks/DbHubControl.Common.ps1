# Shared by the DbHub-Control, DbHub-Stop, and DbHub-Monitor runbooks (ADR 0020). scripts/setup-activity-control.ps1
# publishes each runbook with this file and the settings in place of its markers, so a published runbook is
# self-contained. deploy.ps1 publishes DbHub-Stop the same way to the nightly safety stop's own account in the demo
# resource group (ADR 0024), where only its Nightly and T3Check scopes are scheduled.
#
# Windows PowerShell 5.1, the runtime Learn recommends for webhooks (a PowerShell 7 runbook receives the webhook's
# input as invalid JSON): https://learn.microsoft.com/azure/automation/automation-webhooks
# Azure Resource Manager REST only, with the user-assigned managed identity's token from the sandbox's identity
# endpoint: https://learn.microsoft.com/azure/automation/add-user-assigned-identity
# Nothing here is secret, and nothing secret is written to the job output: the runbook never sees the webhook URL,
# and a token lives only in the context object of one job.
#
# The stop path (Stop-DbHubDemo) deallocates the VMs and stops T4 through Azure Resource Manager only, never through
# Run Command, which waited more than 10 minutes on a saturated sqlvm01 in Phase 25a. A session's stop first exports its
# evidence for the Incident RCA (2026-11-20, ADR 0031) through read-only managed Run Commands, bounded by rca.stopMinutes:
# what isn't exported by then stays on the VMs, and the next session's start exports it.
# T5, the Azure Cosmos DB account (2026-11-18, ADR 0027), has nothing to start, and an account has no stop: T1's runner
# drives it from sqlvm01, so its activity ends with sqlvm01. Its container's provisioned throughput bills every hour the
# container exists, so since 2026-11-19 the container exists only during a session once its lifecycle is Session (the demo
# resource group's DbHubT5Container tag): a session's start creates it, and the stops delete it (New-DbHubT5Container,
# Remove-DbHubT5Container). The account, its database, its private endpoint, and its DNS zone stay.

$script:DbHubArmRoot = 'https://management.azure.com'
$script:DbHubActiveJobStatuses = @('New', 'Activating', 'Running', 'Resuming', 'Blocked', 'Stopping', 'Suspending')
# start-demo.ps1's own auto-stop (2026-11-19) is the same one-time schedule as a run's, autoStopSchedule, whose description
# begins with this marker ($script:ActivityControlStartDemoMarker in the module, which must match): it never makes a run
# active (Get-DbHubAutoStopRunEnd), so a later Run all, the Insights app's Start, or a run replaces it with its own plan,
# and it waits for a deploy.ps1 run that's still going (Get-DbHubStartDemoDeferral).
$script:DbHubStartDemoMarker = '[start-demo.ps1]'

function Get-DbHubMember {
    # A property of a PSCustomObject or a key of a dictionary, or $null when it's missing (strict-mode safe).
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-DbHubListMember {
    # A property that should be a JSON array, as Present, IsList, and Items. The value never goes through the pipeline,
    # which would unwrap a one-item array into its item.
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $present = $false
    $value = $null
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            $present = $true
            $value = $InputObject[$Name]
        }
    }
    elseif ($null -ne $InputObject) {
        $property = $InputObject.PSObject.Properties[$Name]
        if ($null -ne $property) {
            $present = $true
            $value = $property.Value
        }
    }
    return [pscustomobject]@{ Present = $present; IsList = ($value -is [System.Array]); Items = $value }
}

function Get-DbHubPropertyName {
    # The property names of a parsed JSON object.
    param(
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) {
        return @()
    }
    if ($InputObject -is [System.Collections.IDictionary]) {
        return @($InputObject.Keys | ForEach-Object { [string]$_ })
    }
    return @($InputObject.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Test-DbHubInteger {
    # True for a whole JSON number from Minimum to Maximum. Strings, Booleans, and fractions are refused.
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [long] $Minimum,

        [Parameter(Mandatory = $true)]
        [long] $Maximum
    )

    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool]) {
        return $false
    }
    if (-not ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double])) {
        return $false
    }
    $number = [double]$Value
    if ([System.Math]::Floor($number) -ne $number) {
        return $false
    }
    return ($number -ge $Minimum -and $number -le $Maximum)
}

function ConvertTo-DbHubSafeText {
    # Removes token-like text before a message reaches the job output.
    param(
        [AllowNull()]
        [string] $Text
    )

    if (-not $Text) {
        return ''
    }
    $clean = $Text -replace '(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}', '$1[REDACTED]'
    $clean = $clean -replace 'eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*', '[REDACTED:jwt]'
    $clean = $clean -replace '(?i)(webhooks\?token=)[^&\s"'']+', '$1[REDACTED]'
    if ($clean.Length -gt 400) {
        $clean = $clean.Substring(0, 400) + '...'
    }
    return $clean
}

function ConvertFrom-DbHubSetting {
    # Parses and checks the settings that setup-activity-control.ps1 bakes into the runbook. Nothing in them is secret.
    param(
        [Parameter(Mandatory = $true)]
        [string] $Json
    )

    $settings = $Json | ConvertFrom-Json
    if ([int](Get-DbHubMember -InputObject $settings -Name 'schemaVersion') -ne 1) {
        throw 'The runbook settings have an unknown schemaVersion; run ./scripts/deploy.ps1, which publishes the runbooks again.'
    }
    if ([string](Get-DbHubMember -InputObject $settings -Name 'subscriptionId') -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'The runbook settings have no valid subscriptionId.'
    }
    foreach ($name in 'demoResourceGroup', 'controlResourceGroup', 'automationAccount', 'sqlVmName', 'hostVmName', 'controlRunbook', 'stopRunbook', 'monitorRunbook', 'autoStopSchedule', 'monitorSchedulePrefix', 'runCommandPrefix', 'location') {
        if ([string](Get-DbHubMember -InputObject $settings -Name $name) -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,89}$') {
            throw ('The runbook settings have no valid {0}.' -f $name)
        }
    }
    return $settings
}

function Initialize-DbHubContext {
    # Everything one job needs: its settings, its job ID, the time, the ARM token (fetched on first use), and its log.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [AllowEmptyString()]
        [string] $JobId = '',

        [datetime] $NowUtc = [DateTime]::UtcNow
    )

    return [pscustomobject]@{
        Settings = $Settings
        JobId    = $JobId
        NowUtc   = [DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc)
        Token    = ''
        Log      = New-Object -TypeName 'System.Collections.Generic.List[string]'
    }
}

function Write-DbHubLog {
    # One line for the job output; the runbook prints the context's log when it ends, before its result line.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $line = '[{0}Z] {1}' -f [DateTime]::UtcNow.ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), (ConvertTo-DbHubSafeText -Text $Message)
    $Context.Log.Add($line)
    Write-Verbose -Message $line
}

function Get-DbHubUtcNow {
    # The clock of the runbooks' waits, in a function of its own so tests can move it.
    return [DateTime]::UtcNow
}

function Get-DbHubArmToken {
    # An Azure Resource Manager token for the user-assigned identity, from the Automation sandbox's identity endpoint
    # (IDENTITY_ENDPOINT and IDENTITY_HEADER), as Learn's user-assigned identity article shows. No Az module.
    param(
        [Parameter(Mandatory = $true)]
        [string] $ClientId
    )

    if ($ClientId -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw 'The runbook settings have no valid identityClientId.'
    }
    $endpoint = $env:IDENTITY_ENDPOINT
    $header = $env:IDENTITY_HEADER
    if (-not $endpoint -or -not $header) {
        throw 'The Automation sandbox has no managed identity endpoint (IDENTITY_ENDPOINT); run ./scripts/deploy.ps1 again, which gives the account id-<prefix>-automation.'
    }
    $uri = '{0}?resource={1}&client_id={2}' -f $endpoint, [uri]::EscapeDataString('https://management.azure.com/'), $ClientId
    $headers = @{ 'X-IDENTITY-HEADER' = $header; 'Metadata' = 'True' }
    $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 60
    $token = [string](Get-DbHubMember -InputObject $response -Name 'access_token')
    if (-not $token) {
        throw 'The identity endpoint returned no access token.'
    }
    return $token
}

function Invoke-DbHubArm {
    <#
    .SYNOPSIS
    One Azure Resource Manager request under the configured subscription. Returns StatusCode (0 when the request
    couldn't be sent), Body (parsed JSON or $null), and Error (redacted text). HTTP errors don't throw; 429 and 5xx
    are tried again, at most 3 times.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'PUT', 'POST', 'DELETE', 'PATCH')]
        [string] $Method,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $ApiVersion,

        [AllowNull()]
        [object] $Body
    )

    $prefix = '/subscriptions/{0}/' -f [string]$Context.Settings.subscriptionId
    if (-not $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or $Path -match '[\s"''<>]') {
        throw ('Refusing a request outside the configured subscription: {0}' -f $Path)
    }
    if (-not $Context.Token) {
        $Context.Token = Get-DbHubArmToken -ClientId ([string]$Context.Settings.identityClientId)
    }
    $separator = '?'
    if ($Path.Contains('?')) {
        $separator = '&'
    }
    $request = @{
        Method          = $Method
        Uri             = ('{0}{1}{2}api-version={3}' -f $script:DbHubArmRoot, $Path, $separator, $ApiVersion)
        Headers         = @{ Authorization = ('Bearer ' + $Context.Token) }
        UseBasicParsing = $true
        TimeoutSec      = 100
    }
    if ($null -ne $Body) {
        $request['Body'] = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 20 -Compress))
        $request['ContentType'] = 'application/json'
    }
    elseif ($Method -eq 'POST') {
        # Without a body, Windows PowerShell 5.1 sends a POST as application/x-www-form-urlencoded, which the
        # PostgreSQL resource provider refuses (HTTP 415, Phase 25d live: T4's start failed). An action without
        # parameters takes an empty JSON object.
        $request['Body'] = [System.Text.Encoding]::UTF8.GetBytes('{}')
        $request['ContentType'] = 'application/json'
    }
    $attempt = 0
    while ($true) {
        $attempt++
        $status = 0
        $content = ''
        $errorText = ''
        try {
            $response = Invoke-WebRequest @request
            $status = [int]$response.StatusCode
            $content = [string]$response.Content
        }
        catch {
            # Windows PowerShell 5.1 throws a WebException with an HttpWebResponse; PowerShell 7 an
            # HttpResponseException. Both put the response body in ErrorDetails.
            $errorText = [string]$_.Exception.Message
            $failed = Get-DbHubMember -InputObject $_.Exception -Name 'Response'
            if ($null -ne $failed) {
                $status = [int](Get-DbHubMember -InputObject $failed -Name 'StatusCode')
            }
            if ($null -ne $_.ErrorDetails -and $_.ErrorDetails.Message) {
                $content = [string]$_.ErrorDetails.Message
            }
        }
        if (($status -eq 429 -or $status -ge 500) -and $attempt -lt 3) {
            Start-Sleep -Seconds (10 * $attempt)
            continue
        }
        break
    }
    $parsed = $null
    if ($content) {
        try {
            $parsed = $content | ConvertFrom-Json
        }
        catch {
            $parsed = $null
        }
    }
    if ($status -ge 400 -or $status -eq 0) {
        $detail = Get-DbHubMember -InputObject $parsed -Name 'error'
        $code = [string](Get-DbHubMember -InputObject $detail -Name 'code')
        $message = [string](Get-DbHubMember -InputObject $detail -Name 'message')
        if ($code -or $message) {
            $errorText = ('{0}: {1}' -f $code, $message).Trim(' ', ':')
        }
        elseif (-not $errorText) {
            $errorText = 'HTTP {0}' -f $status
        }
        $errorText = ConvertTo-DbHubSafeText -Text $errorText
    }
    return [pscustomobject]@{ StatusCode = $status; Body = $parsed; Error = $errorText }
}

function Get-DbHubApiVersion {
    # The pinned API version for a resource type (config/versions.json, baked into the settings).
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [Parameter(Mandatory = $true)]
        [string] $Type
    )

    $version = [string](Get-DbHubMember -InputObject $Settings.apiVersions -Name $Type)
    if (-not $version) {
        throw ('The runbook settings have no API version for {0}.' -f $Type)
    }
    return $version
}

function Get-DbHubRefusal {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Reason
    )

    return [pscustomobject]@{ Valid = $false; Reason = $Reason; Action = ''; Activities = @(); DurationMinutes = 0; Targets = @(); RequestedBy = ''; SessionId = '' }
}

function Test-DbHubControlRequest {
    <#
    .SYNOPSIS
    Validates a webhook request against the allow-lists before anything else runs. Returns Valid, Reason, and the
    normalized Action, Activities (Target, Scenario, Intensity, Concurrency), DurationMinutes, Targets, and RequestedBy.

    .DESCRIPTION
    The request body is a JSON object of at most maxBodyBytes (4,096) bytes, and nothing else:
    - {"action": "run", "activities": [{"target": "T1", "scenario": "blocking-chain", "intensity": 5, "concurrency": 4}],
      "durationMinutes": 20}: one activity per target, because a target's activity profile holds one incident at a
      time. scenario is "baseline", a catalog scenario that the target can run, a profile from the settings' profiles
      (showcase, 2026-11-04: its own rotation of incidents, from scenarios/activity-profiles.json), or "off", which turns
      the target's activity off (a run needs at least one activity that isn't off); intensity (1-10) and concurrency
      (1 to the scenario's maximum, incidents only) are optional, and a profile or off takes neither; durationMinutes
      is minDurationMinutes to maxDurationMinutes.
    - {"action": "stop"}: Stop now.
    - {"action": "reset", "targets": ["T1"]}: the runner's reset; without targets, every target whose VM runs.
    - {"action": "session", "sessionId": "<32 lowercase hex>", "durationMinutes": 90}: the control notebook's Run all
      (2026-11-14): the whole demo session, the showcase on every target, T4's read replica, the busy marker, and the
      session's status in the control vault (Start-DbHubSession). durationMinutes is optional (the showcase's default),
      minSessionMinutes to the showcase's maximum.
    - {"action": "capture", "sessionId": "..."}: T4's and its read replica's Azure Monitor metrics, and T5's (2026-11-18),
      into the control vault, for the history (Save-DbHubSessionMetric); nothing is started or stopped.
    - "sessionId" is also allowed on stop, whose status then names the session.
    - "requestedBy" is optional on any action: 1-64 letters, digits, or . _ @ / - (a name, never a secret).
    Unknown fields, other values, free text, and a body that isn't a JSON object are refused.
    #>
    param(
        [AllowNull()]
        [object] $WebhookData,

        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    if ($null -eq $WebhookData) {
        return (Get-DbHubRefusal -Reason 'DbHub-Control runs only from its webhook; it has no WebhookData.')
    }
    $raw = Get-DbHubMember -InputObject $WebhookData -Name 'RequestBody'
    if ($null -eq $raw -or -not ($raw -is [string]) -or [string]::IsNullOrWhiteSpace($raw)) {
        return (Get-DbHubRefusal -Reason 'The webhook request has no body.')
    }
    $limit = [int](Get-DbHubMember -InputObject $Settings -Name 'maxBodyBytes')
    if ($limit -le 0) {
        $limit = 4096
    }
    if ([System.Text.Encoding]::UTF8.GetByteCount($raw) -gt $limit) {
        return (Get-DbHubRefusal -Reason ('The request body is larger than {0} bytes.' -f $limit))
    }
    try {
        $body = $raw | ConvertFrom-Json
    }
    catch {
        return (Get-DbHubRefusal -Reason 'The request body isn''t JSON.')
    }
    # The text check matters: PowerShell 7's ConvertFrom-Json unwraps a one-item JSON array into its item.
    if (-not $raw.TrimStart().StartsWith('{') -or $null -eq $body -or $body -is [System.Array] -or $body -is [string] -or $body -is [System.ValueType]) {
        return (Get-DbHubRefusal -Reason 'The request body must be a JSON object.')
    }
    $action = Get-DbHubMember -InputObject $body -Name 'action'
    if (-not ($action -is [string]) -or $action -cnotin @('run', 'stop', 'reset', 'session', 'capture')) {
        return (Get-DbHubRefusal -Reason 'action must be run, session, stop, capture, or reset.')
    }
    $allowedFields = @{ run = @('action', 'activities', 'durationMinutes', 'requestedBy'); stop = @('action', 'requestedBy', 'sessionId'); reset = @('action', 'targets', 'requestedBy'); session = @('action', 'durationMinutes', 'sessionId', 'requestedBy'); capture = @('action', 'sessionId', 'requestedBy') }
    foreach ($name in (Get-DbHubPropertyName -InputObject $body)) {
        if ($name -cnotin $allowedFields[$action]) {
            return (Get-DbHubRefusal -Reason ('The field ''{0}'' isn''t allowed for {1}.' -f ($name -replace '[^A-Za-z0-9_-]', '?'), $action))
        }
    }
    $requestedBy = 'notebook'
    $who = Get-DbHubMember -InputObject $body -Name 'requestedBy'
    if ($null -ne $who) {
        if (-not ($who -is [string]) -or $who -cnotmatch '^[A-Za-z0-9._@/-]{1,64}$') {
            return (Get-DbHubRefusal -Reason 'requestedBy must be 1-64 letters, digits, or . _ @ / -.')
        }
        $requestedBy = $who
    }
    $sessionId = ''
    $sessionValue = Get-DbHubMember -InputObject $body -Name 'sessionId'
    if ($null -ne $sessionValue) {
        if (-not ($sessionValue -is [string]) -or $sessionValue -cnotmatch '^[0-9a-f]{32}$') {
            return (Get-DbHubRefusal -Reason 'sessionId must be 32 lowercase hexadecimal characters.')
        }
        $sessionId = $sessionValue
    }
    elseif ($action -in 'session', 'capture') {
        return (Get-DbHubRefusal -Reason ('{0} needs a sessionId: 32 lowercase hexadecimal characters.' -f $action))
    }
    $targets = @($Settings.targets.PSObject.Properties | ForEach-Object { [string]$_.Name })

    if ($action -in 'stop', 'capture') {
        return [pscustomobject]@{ Valid = $true; Reason = ''; Action = $action; Activities = @(); DurationMinutes = 0; Targets = @(); RequestedBy = $requestedBy; SessionId = $sessionId }
    }

    if ($action -eq 'session') {
        # The showcase on every target it has incidents for: what Run all always ran, now with the replica (2026-11-14).
        $showcase = Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $Settings -Name 'profiles') -Name 'showcase'
        if ($null -eq $showcase) {
            return (Get-DbHubRefusal -Reason 'The runbook settings have no showcase profile; run ./scripts/deploy.ps1 again.')
        }
        $minimum = [int](Get-DbHubMember -InputObject $Settings -Name 'minSessionMinutes')
        if ($minimum -le 0) {
            $minimum = 30
        }
        $maximum = [int](Get-DbHubMember -InputObject $showcase -Name 'maxMinutes')
        $minutes = [int](Get-DbHubMember -InputObject $showcase -Name 'defaultMinutes')
        $duration = Get-DbHubMember -InputObject $body -Name 'durationMinutes'
        if ($null -ne $duration) {
            if (-not (Test-DbHubInteger -Value $duration -Minimum $minimum -Maximum $maximum)) {
                return (Get-DbHubRefusal -Reason ('durationMinutes must be a whole number from {0} to {1}.' -f $minimum, $maximum))
            }
            $minutes = [int]$duration
        }
        $activities = @($targets | Where-Object { $_ -cin @($showcase.targets) } | ForEach-Object { [pscustomobject]@{ Target = $_; Scenario = 'showcase'; Intensity = 0; Concurrency = 0 } })
        return [pscustomobject]@{ Valid = $true; Reason = ''; Action = 'session'; Activities = $activities; DurationMinutes = $minutes; Targets = @($activities | ForEach-Object { $_.Target }); RequestedBy = $requestedBy; SessionId = $sessionId }
    }

    if ($action -eq 'reset') {
        $chosen = @()
        $list = Get-DbHubListMember -InputObject $body -Name 'targets'
        if ($list.Present) {
            if (-not $list.IsList -or $list.Items.Count -lt 1 -or $list.Items.Count -gt $targets.Count) {
                return (Get-DbHubRefusal -Reason ('targets must be a list of 1 to {0} of: {1}.' -f $targets.Count, ($targets -join ', ')))
            }
            foreach ($item in $list.Items) {
                if (-not ($item -is [string]) -or $item -cnotin $targets -or $item -cin $chosen) {
                    return (Get-DbHubRefusal -Reason ('targets must be distinct values from: {0}.' -f ($targets -join ', ')))
                }
                $chosen += $item
            }
        }
        return [pscustomobject]@{ Valid = $true; Reason = ''; Action = 'reset'; Activities = @(); DurationMinutes = 0; Targets = $chosen; RequestedBy = $requestedBy; SessionId = '' }
    }

    $duration = Get-DbHubMember -InputObject $body -Name 'durationMinutes'
    $minimum = [int]$Settings.minDurationMinutes
    $maximum = [int]$Settings.maxDurationMinutes
    if (-not (Test-DbHubInteger -Value $duration -Minimum $minimum -Maximum $maximum)) {
        return (Get-DbHubRefusal -Reason ('durationMinutes must be a whole number from {0} to {1}.' -f $minimum, $maximum))
    }
    $activities = Get-DbHubListMember -InputObject $body -Name 'activities'
    if (-not $activities.IsList -or $activities.Items.Count -lt 1 -or $activities.Items.Count -gt $targets.Count) {
        return (Get-DbHubRefusal -Reason ('activities must be a list of 1 to {0} items, one per target.' -f $targets.Count))
    }
    $normalized = @()
    $seen = @()
    $profiles = Get-DbHubMember -InputObject $Settings -Name 'profiles'
    $profileNames = @(Get-DbHubPropertyName -InputObject $profiles)
    foreach ($activity in $activities.Items) {
        if ($null -eq $activity -or $activity -is [string] -or $activity -is [System.ValueType] -or $activity -is [System.Array]) {
            return (Get-DbHubRefusal -Reason 'Each activity must be an object with target and scenario.')
        }
        foreach ($name in (Get-DbHubPropertyName -InputObject $activity)) {
            if ($name -cnotin @('target', 'scenario', 'intensity', 'concurrency')) {
                return (Get-DbHubRefusal -Reason ('The activity field ''{0}'' isn''t allowed.' -f ($name -replace '[^A-Za-z0-9_-]', '?')))
            }
        }
        $target = Get-DbHubMember -InputObject $activity -Name 'target'
        if (-not ($target -is [string]) -or $target -cnotin $targets) {
            return (Get-DbHubRefusal -Reason ('Each activity''s target must be one of: {0}.' -f ($targets -join ', ')))
        }
        if ($target -cin $seen) {
            return (Get-DbHubRefusal -Reason ('{0} has more than one activity; a target runs one at a time.' -f $target))
        }
        $seen += $target
        $scenario = Get-DbHubMember -InputObject $activity -Name 'scenario'
        if (-not ($scenario -is [string])) {
            return (Get-DbHubRefusal -Reason 'Each activity needs a scenario: baseline, off, a profile, or a scenario from the catalog.')
        }
        $maximumConcurrency = 0
        $isProfile = $scenario -ceq 'off' -or $scenario -cin $profileNames
        if ($isProfile -and $scenario -cne 'off') {
            $definition = Get-DbHubMember -InputObject $profiles -Name $scenario
            if ($target -cnotin @($definition.targets)) {
                return (Get-DbHubRefusal -Reason ('{0} doesn''t run on {1}.' -f $scenario, $target))
            }
        }
        elseif (-not $isProfile -and $scenario -cne 'baseline') {
            $definition = Get-DbHubMember -InputObject $Settings.scenarios -Name $scenario
            if ($null -eq $definition) {
                return (Get-DbHubRefusal -Reason ('''{0}'' isn''t a scenario in the catalog.' -f ($scenario -replace '[^A-Za-z0-9_-]', '?')))
            }
            if ($target -cnotin @($definition.targets)) {
                return (Get-DbHubRefusal -Reason ('{0} doesn''t run on {1}.' -f $scenario, $target))
            }
            $maximumConcurrency = [int]$definition.maxConcurrency
        }
        $intensity = Get-DbHubMember -InputObject $activity -Name 'intensity'
        $concurrency = Get-DbHubMember -InputObject $activity -Name 'concurrency'
        if ($isProfile -and ($null -ne $intensity -or $null -ne $concurrency)) {
            return (Get-DbHubRefusal -Reason ('intensity and concurrency don''t apply to {0}: a profile takes its own from the catalog.' -f $scenario))
        }
        if ($null -ne $intensity -and -not (Test-DbHubInteger -Value $intensity -Minimum 1 -Maximum 10)) {
            return (Get-DbHubRefusal -Reason 'intensity must be a whole number from 1 to 10.')
        }
        if ($null -ne $concurrency -and ($maximumConcurrency -lt 1 -or -not (Test-DbHubInteger -Value $concurrency -Minimum 1 -Maximum $maximumConcurrency))) {
            return (Get-DbHubRefusal -Reason ('concurrency applies to incidents only, from 1 to the scenario''s maximum ({0}).' -f $maximumConcurrency))
        }
        $normalizedIntensity = 0
        if ($null -ne $intensity) {
            $normalizedIntensity = [int]$intensity
        }
        $normalizedConcurrency = 0
        if ($null -ne $concurrency) {
            $normalizedConcurrency = [int]$concurrency
        }
        $normalized += [pscustomobject]@{ Target = $target; Scenario = $scenario; Intensity = $normalizedIntensity; Concurrency = $normalizedConcurrency }
    }
    if (@($normalized | Where-Object { $_.Scenario -cne 'off' }).Count -eq 0) {
        return (Get-DbHubRefusal -Reason 'A run needs at least one activity that isn''t off; Stop now stops everything.')
    }
    return [pscustomobject]@{ Valid = $true; Reason = ''; Action = 'run'; Activities = $normalized; DurationMinutes = [int]$duration; Targets = @($seen); RequestedBy = $requestedBy; SessionId = '' }
}

function Get-DbHubNextShutdownUtc {
    # The VMs' next auto-shutdown in UTC from autoShutdownTime (HHmm) and autoShutdownTimeZone (a Windows time zone
    # ID): the same schedule as the VMs' DevTest Labs auto-shutdown and the module's Get-DemoNextShutdownUtc.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [Parameter(Mandatory = $true)]
        [datetime] $NowUtc
    )

    $time = [string]$Settings.autoShutdownTime
    if ($time -notmatch '^([01]\d|2[0-3])([0-5]\d)$') {
        throw ('autoShutdownTime ''{0}'' isn''t HHmm.' -f $time)
    }
    $hour = [int]$Matches[1]
    $minute = [int]$Matches[2]
    $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById([string]$Settings.autoShutdownTimeZone)
    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc), $zone)
    $candidate = New-Object -TypeName DateTime -ArgumentList $local.Year, $local.Month, $local.Day, $hour, $minute, 0, ([System.DateTimeKind]::Unspecified)
    if ($candidate -le $local) {
        $candidate = $candidate.AddDays(1)
    }
    if ($zone.IsInvalidTime($candidate)) {
        $candidate = $candidate.AddHours(1)
    }
    return [System.TimeZoneInfo]::ConvertTimeToUtc($candidate, $zone)
}

function Get-DbHubRunPlan {
    <#
    .SYNOPSIS
    How long each activity runs: the requested minutes, capped at its scenario's maximum (maxDurationMinutes for the
    baseline, the profile's maxMinutes for a profile such as showcase) and so that it ends before the VMs' next
    auto-shutdown minus shutdownMarginMinutes; off takes no minutes and doesn't count toward the run's end. Returns
    Valid, Reason, Activities (with Minutes, and Tier, VCores, and NotAfterUtc for the dispatch to fill), RunEndUtc,
    AutoStopUtc (the run's end plus autoStopBufferMinutes), and ShutdownUtc.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Request,

        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [Parameter(Mandatory = $true)]
        [datetime] $NowUtc
    )

    $shutdown = Get-DbHubNextShutdownUtc -Settings $Settings -NowUtc $NowUtc
    $latestEnd = $shutdown.AddMinutes(-1 * [int]$Settings.shutdownMarginMinutes)
    $available = [int][System.Math]::Floor(($latestEnd - $NowUtc).TotalMinutes)
    if ($available -lt [int]$Settings.minDurationMinutes) {
        return [pscustomobject]@{ Valid = $false; Reason = ('The VMs'' auto-shutdown is at {0:yyyy-MM-dd HH:mm} UTC, too soon for a run of at least {1} minutes.' -f $shutdown, [int]$Settings.minDurationMinutes); Activities = @(); RunEndUtc = $NowUtc; AutoStopUtc = $NowUtc; ShutdownUtc = $shutdown }
    }
    $profiles = Get-DbHubMember -InputObject $Settings -Name 'profiles'
    $planned = @()
    $longest = 0
    foreach ($activity in @($Request.Activities)) {
        $cap = [int]$Settings.maxDurationMinutes
        $profileDefinition = Get-DbHubMember -InputObject $profiles -Name ([string]$activity.Scenario)
        if ($activity.Scenario -ceq 'off') {
            $cap = 0
        }
        elseif ($null -ne $profileDefinition) {
            $cap = [int](Get-DbHubMember -InputObject $profileDefinition -Name 'maxMinutes')
        }
        elseif ($activity.Scenario -cne 'baseline') {
            $cap = [int](Get-DbHubMember -InputObject $Settings.scenarios -Name $activity.Scenario).maxMinutes
        }
        $minutes = [System.Math]::Min([System.Math]::Min([int]$Request.DurationMinutes, $cap), $available)
        if ($minutes -gt $longest) {
            $longest = $minutes
        }
        $planned += [pscustomobject]@{ Target = $activity.Target; Scenario = $activity.Scenario; Intensity = $activity.Intensity; Concurrency = $activity.Concurrency; Minutes = $minutes; Tier = ''; VCores = 0; NotAfterUtc = $null }
    }
    $end = $NowUtc.AddMinutes($longest)
    foreach ($item in $planned) {
        # A profile ends with the run (the runner stops 2 minutes before --not-after), even when its target's dispatch
        # waited for the target to start.
        if ($null -ne (Get-DbHubMember -InputObject $profiles -Name ([string]$item.Scenario))) {
            $item.NotAfterUtc = $end.AddMinutes(2)
        }
    }
    return [pscustomobject]@{ Valid = $true; Reason = ''; Activities = $planned; RunEndUtc = $end; AutoStopUtc = $end.AddMinutes([int]$Settings.autoStopBufferMinutes); ShutdownUtc = $shutdown }
}

function Get-DbHubAccountPath {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    return ('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}' -f $Settings.subscriptionId, $Settings.controlResourceGroup, $Settings.automationAccount)
}

function Get-DbHubDemoPath {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    return ('/subscriptions/{0}/resourceGroups/{1}' -f $Settings.subscriptionId, $Settings.demoResourceGroup)
}

function ConvertTo-DbHubUtc {
    # Parses an ISO 8601 time from Azure; $null when it doesn't parse. A DateTime (a JSON parser's) is taken as UTC when it
    # has no kind.
    param(
        [AllowNull()]
        [object] $Value
    )

    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }
    $parsed = [DateTimeOffset]::MinValue
    if ($null -ne $Value -and [DateTimeOffset]::TryParse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }
    return $null
}

function Get-DbHubActiveRun {
    <#
    .SYNOPSIS
    Whether a run is active: an earlier DbHub-Control job that hasn't ended (of two jobs started together, the older
    one goes on), or a pending auto-stop whose run hasn't ended yet (its start minus autoStopBufferMinutes is still in
    the future). Anything that can't be read counts as active. Returns Active, Reason, and RunEndUtc.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    $settings = $Context.Settings
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Automation/automationAccounts'
    $account = Get-DbHubAccountPath -Settings $settings
    $filter = [uri]::EscapeDataString(("properties/runbook/name eq '{0}'" -f $settings.controlRunbook))
    $jobs = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/jobs?$filter={1}' -f $account, $filter) -ApiVersion $version
    if ($jobs.StatusCode -ne 200) {
        return [pscustomobject]@{ Active = $true; Reason = ('The control account''s jobs couldn''t be read ({0}), so nothing was started.' -f $jobs.Error); RunEndUtc = $null }
    }
    $list = @(Get-DbHubMember -InputObject $jobs.Body -Name 'value' | ForEach-Object {
            $properties = Get-DbHubMember -InputObject $_ -Name 'properties'
            [pscustomobject]@{
                Id      = [string](Get-DbHubMember -InputObject $properties -Name 'jobId')
                Status  = [string](Get-DbHubMember -InputObject $properties -Name 'status')
                Runbook = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $properties -Name 'runbook') -Name 'name')
                Created = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject $properties -Name 'creationTime')
            }
        })
    $mine = @($list | Where-Object { $Context.JobId -and $_.Id -eq $Context.JobId }) | Select-Object -First 1
    foreach ($job in $list) {
        if ($job.Runbook -ne [string]$settings.controlRunbook -or ($Context.JobId -and $job.Id -eq $Context.JobId) -or $job.Status -notin $script:DbHubActiveJobStatuses) {
            continue
        }
        if ($null -ne $mine -and $null -ne $mine.Created -and $null -ne $job.Created -and ($job.Created -gt $mine.Created -or ($job.Created -eq $mine.Created -and [string]::CompareOrdinal($job.Id, $mine.Id) -gt 0))) {
            continue
        }
        return [pscustomobject]@{ Active = $true; Reason = ('Another DbHub-Control job ({0}) is {1}.' -f $job.Id, $job.Status); RunEndUtc = $null }
    }
    $pending = Get-DbHubAutoStopRunEnd -Context $Context
    if ($pending.State -eq 'Unknown') {
        return [pscustomobject]@{ Active = $true; Reason = ('The auto-stop schedule couldn''t be read ({0}), so nothing was started.' -f $pending.Error); RunEndUtc = $null }
    }
    if ($pending.State -eq 'Pending') {
        return [pscustomobject]@{ Active = $true; Reason = ('A run is active until {0:yyyy-MM-dd HH:mm} UTC; use Stop now first, or wait for it to end.' -f $pending.RunEndUtc); RunEndUtc = $pending.RunEndUtc }
    }
    return [pscustomobject]@{ Active = $false; Reason = ''; RunEndUtc = $null }
}

function Get-DbHubAutoStopRunEnd {
    # Whether a run's auto-stop is pending: State None (no schedule, or its run has ended: its start minus
    # autoStopBufferMinutes has passed), Pending (with RunEndUtc), or Unknown (it couldn't be read, with Error). StartDemo
    # says the schedule is start-demo.ps1's own auto-stop (2026-11-19): that's never a run that's active, so it's None, and a
    # run's Register-DbHubAutoStop replaces it with its own plan.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    $settings = $Context.Settings
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Automation/automationAccounts'
    $schedule = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/schedules/{1}' -f (Get-DbHubAccountPath -Settings $settings), $settings.autoStopSchedule) -ApiVersion $version
    if ($schedule.StatusCode -eq 404) {
        return [pscustomobject]@{ State = 'None'; RunEndUtc = $null; Error = ''; StartDemo = $false }
    }
    if ($schedule.StatusCode -ne 200) {
        return [pscustomobject]@{ State = 'Unknown'; RunEndUtc = $null; Error = $schedule.Error; StartDemo = $false }
    }
    $properties = Get-DbHubMember -InputObject $schedule.Body -Name 'properties'
    if (([string](Get-DbHubMember -InputObject $properties -Name 'description')).StartsWith($script:DbHubStartDemoMarker, [System.StringComparison]::Ordinal)) {
        return [pscustomobject]@{ State = 'None'; RunEndUtc = $null; Error = ''; StartDemo = $true }
    }
    $start = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject $properties -Name 'startTime')
    if ($null -ne $start) {
        $runEnd = $start.AddMinutes(-1 * [int]$settings.autoStopBufferMinutes)
        if ($runEnd -gt $Context.NowUtc) {
            return [pscustomobject]@{ State = 'Pending'; RunEndUtc = $runEnd; Error = ''; StartDemo = $false }
        }
    }
    return [pscustomobject]@{ State = 'None'; RunEndUtc = $null; Error = ''; StartDemo = $false }
}

function Get-DbHubMonitorScheduleName {
    # The names a run's monitoring re-checks can have: monitorSchedulePrefix and 1 up to the most a run of
    # maxDurationMinutes can hold.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    $count = [int][System.Math]::Ceiling([double]$Settings.maxDurationMinutes / [System.Math]::Max(30, [int]$Settings.monitorRecheckMinutes))
    return @(1..[System.Math]::Max(1, $count) | ForEach-Object { '{0}{1}' -f $Settings.monitorSchedulePrefix, $_ })
}

function Clear-DbHubAutoStop {
    # Deletes the run's one-time schedules, the auto-stop and the monitoring re-checks, and the job schedules that link
    # them to DbHub-Stop and DbHub-Monitor. Azure Resource Manager only. Returns $true when nothing is left of the
    # auto-stop; a re-check that couldn't be deleted is only logged, because it does nothing once its run has ended.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    $settings = $Context.Settings
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Automation/automationAccounts'
    $account = Get-DbHubAccountPath -Settings $settings
    $monitors = @(Get-DbHubMonitorScheduleName -Settings $settings)
    # A session's second auto-stop (2026-11-14), autoStopBackupMinutes after the first, for when the first one's job fails:
    # it goes with the first, so it never stops a later run.
    $backup = [string](Get-DbHubMember -InputObject $settings -Name 'autoStopBackupSchedule')
    $stops = @([string]$settings.autoStopSchedule)
    if ($backup) {
        $stops += $backup
    }
    $clean = $true
    $links = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/jobSchedules' -f $account) -ApiVersion $version
    if ($links.StatusCode -eq 200) {
        foreach ($link in @(Get-DbHubMember -InputObject $links.Body -Name 'value')) {
            $properties = Get-DbHubMember -InputObject $link -Name 'properties'
            $scheduleName = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $properties -Name 'schedule') -Name 'name')
            $id = [string](Get-DbHubMember -InputObject $properties -Name 'jobScheduleId')
            if (($scheduleName -notin $stops -and $scheduleName -notin $monitors) -or $id -notmatch '^[0-9a-fA-F-]{36}$') {
                continue
            }
            $removed = Invoke-DbHubArm -Context $Context -Method DELETE -Path ('{0}/jobSchedules/{1}' -f $account, $id) -ApiVersion $version
            if ($removed.StatusCode -notin 200, 204, 404) {
                if ($scheduleName -in $stops) {
                    $clean = $false
                }
                Write-DbHubLog -Context $Context -Message ('The link {0} to {1} couldn''t be deleted: {2}' -f $id, $scheduleName, $removed.Error)
            }
        }
    }
    elseif ($links.StatusCode -ne 404) {
        $clean = $false
        Write-DbHubLog -Context $Context -Message ('The job schedules couldn''t be read: {0}' -f $links.Error)
    }
    foreach ($name in $monitors) {
        $deleted = Invoke-DbHubArm -Context $Context -Method DELETE -Path ('{0}/schedules/{1}' -f $account, $name) -ApiVersion $version
        if ($deleted.StatusCode -notin 200, 204, 404) {
            Write-DbHubLog -Context $Context -Message ('The monitoring re-check {0} couldn''t be deleted: {1}' -f $name, $deleted.Error)
        }
    }
    if ($backup) {
        $deleted = Invoke-DbHubArm -Context $Context -Method DELETE -Path ('{0}/schedules/{1}' -f $account, $backup) -ApiVersion $version
        if ($deleted.StatusCode -notin 200, 204, 404) {
            $clean = $false
            Write-DbHubLog -Context $Context -Message ('The second auto-stop schedule couldn''t be deleted: {0}' -f $deleted.Error)
        }
    }
    $deleted = Invoke-DbHubArm -Context $Context -Method DELETE -Path ('{0}/schedules/{1}' -f $account, $settings.autoStopSchedule) -ApiVersion $version
    if ($deleted.StatusCode -notin 200, 204, 404) {
        $clean = $false
        Write-DbHubLog -Context $Context -Message ('The auto-stop schedule couldn''t be deleted: {0}' -f $deleted.Error)
    }
    return $clean
}

function Register-DbHubAutoStop {
    <#
    .SYNOPSIS
    Creates the one-time schedule autoStopSchedule at AutoStopUtc, linked to DbHub-Stop (Scope All), after removing
    the previous one. It's created before anything starts, so every run has its stop. -Description replaces the run's own
    (2026-11-19: a start-demo.ps1 auto-stop that waits for deploy.ps1 keeps its marker, and so does its backup).
    https://learn.microsoft.com/rest/api/automation/schedule/create-or-update
    https://learn.microsoft.com/rest/api/automation/job-schedule/create
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [datetime] $AutoStopUtc,

        [string] $Description = ''
    )

    $settings = $Context.Settings
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Automation/automationAccounts'
    $account = Get-DbHubAccountPath -Settings $settings
    if (-not (Clear-DbHubAutoStop -Context $Context)) {
        return [pscustomobject]@{ Created = $false; Error = 'the previous auto-stop couldn''t be removed'; StartUtc = ''; BackupUtc = '' }
    }
    $start = [DateTime]::SpecifyKind($AutoStopUtc, [System.DateTimeKind]::Utc).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    if (-not $Description) {
        $Description = 'Stops the demo after the on-demand run that job {0} started (ADR 0020).' -f $Context.JobId
    }
    $body = @{
        name       = [string]$settings.autoStopSchedule
        properties = @{
            description = $Description
            startTime   = $start
            frequency   = 'OneTime'
            timeZone    = 'UTC'
        }
    }
    $schedule = Invoke-DbHubArm -Context $Context -Method PUT -Path ('{0}/schedules/{1}' -f $account, $settings.autoStopSchedule) -ApiVersion $version -Body $body
    if ($schedule.StatusCode -notin 200, 201) {
        return [pscustomobject]@{ Created = $false; Error = $schedule.Error; StartUtc = ''; BackupUtc = '' }
    }
    $link = @{
        properties = @{
            schedule   = @{ name = [string]$settings.autoStopSchedule }
            runbook    = @{ name = [string]$settings.stopRunbook }
            parameters = @{ Scope = 'All' }
        }
    }
    $linked = Invoke-DbHubArm -Context $Context -Method PUT -Path ('{0}/jobSchedules/{1}' -f $account, [guid]::NewGuid().ToString()) -ApiVersion $version -Body $link
    if ($linked.StatusCode -notin 200, 201) {
        $null = Clear-DbHubAutoStop -Context $Context
        return [pscustomobject]@{ Created = $false; Error = $linked.Error; StartUtc = ''; BackupUtc = '' }
    }
    # The second auto-stop (2026-11-14): if the first one's job fails before it removes them, this one stops the demo.
    $backupUtc = ''
    $backup = [string](Get-DbHubMember -InputObject $settings -Name 'autoStopBackupSchedule')
    if ($backup) {
        $minutes = [int](Get-DbHubMember -InputObject $settings -Name 'autoStopBackupMinutes')
        if ($minutes -le 0) {
            $minutes = 30
        }
        $backupStart = [DateTime]::SpecifyKind($AutoStopUtc, [System.DateTimeKind]::Utc).AddMinutes($minutes).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        $backupDescription = 'Stops the demo if the auto-stop of the run that job {0} started didn''t (ADR 0026).' -f $Context.JobId
        if ($Description.StartsWith($script:DbHubStartDemoMarker, [System.StringComparison]::Ordinal)) {
            $backupDescription = '{0} Stops the demo if the auto-stop of the start-demo.ps1 session didn''t.' -f $script:DbHubStartDemoMarker
        }
        $backupBody = @{ name = $backup; properties = @{ description = $backupDescription; startTime = $backupStart; frequency = 'OneTime'; timeZone = 'UTC' } }
        $made = Invoke-DbHubArm -Context $Context -Method PUT -Path ('{0}/schedules/{1}' -f $account, $backup) -ApiVersion $version -Body $backupBody
        if ($made.StatusCode -in 200, 201) {
            $backupLink = @{ properties = @{ schedule = @{ name = $backup }; runbook = @{ name = [string]$settings.stopRunbook }; parameters = @{ Scope = 'All' } } }
            $madeLink = Invoke-DbHubArm -Context $Context -Method PUT -Path ('{0}/jobSchedules/{1}' -f $account, [guid]::NewGuid().ToString()) -ApiVersion $version -Body $backupLink
            if ($madeLink.StatusCode -in 200, 201) {
                $backupUtc = $backupStart
            }
            else {
                Write-DbHubLog -Context $Context -Message ('The second auto-stop wasn''t linked to {0}: {1}' -f $settings.stopRunbook, $madeLink.Error)
            }
        }
        else {
            Write-DbHubLog -Context $Context -Message ('The second auto-stop wasn''t created: {0}' -f $made.Error)
        }
    }
    return [pscustomobject]@{ Created = $true; Error = ''; StartUtc = $start; BackupUtc = $backupUtc }
}

function Register-DbHubMonitorRecheck {
    <#
    .SYNOPSIS
    T1's monitoring plugin, checked again while a long run lasts: one-time schedules monitorSchedulePrefix1, 2, ... every
    monitorRecheckMinutes after the run's start, while they come at least 5 minutes before its end, each linked to
    DbHub-Monitor (no parameters). Live: the plugin stopped again within 90 minutes after a start (2026-10-30), and a
    run lasts up to 120. Clear-DbHubAutoStop removes them with the auto-stop, so Stop now, the auto-stop, and the next
    run take them away through Azure Resource Manager only; DbHub-Monitor does nothing once its run has ended. A
    re-check that can't be created is only logged: the run goes on. Returns the names created.
    https://learn.microsoft.com/rest/api/automation/schedule/create-or-update
    https://learn.microsoft.com/rest/api/automation/job-schedule/create
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [datetime] $StartUtc,

        [Parameter(Mandatory = $true)]
        [datetime] $RunEndUtc
    )

    $settings = $Context.Settings
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Automation/automationAccounts'
    $account = Get-DbHubAccountPath -Settings $settings
    # Never sooner than 30 minutes: the run's own job looks after the plugin for up to 28 (Start-DbHubActivityRun: sqlvm01 runs
    # within 15, then up to 8 to settle and 5 to verify a restart).
    $interval = [System.Math]::Max(30, [int]$settings.monitorRecheckMinutes)
    $created = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $names = @(Get-DbHubMonitorScheduleName -Settings $settings)
    for ($index = 0; $index -lt $names.Count; $index++) {
        $at = $StartUtc.AddMinutes(($index + 1) * $interval)
        if ($at -gt $RunEndUtc.AddMinutes(-5)) {
            break
        }
        $name = $names[$index]
        $time = [DateTime]::SpecifyKind($at, [System.DateTimeKind]::Utc).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        $body = @{
            name       = $name
            properties = @{
                description = ('Checks T1''s monitoring plugin again during the on-demand run that job {0} started (ADR 0020).' -f $Context.JobId)
                startTime   = $time
                frequency   = 'OneTime'
                timeZone    = 'UTC'
            }
        }
        $schedule = Invoke-DbHubArm -Context $Context -Method PUT -Path ('{0}/schedules/{1}' -f $account, $name) -ApiVersion $version -Body $body
        if ($schedule.StatusCode -notin 200, 201) {
            Write-DbHubLog -Context $Context -Message ('The monitoring re-check {0} wasn''t created: {1}' -f $name, $schedule.Error)
            continue
        }
        $link = @{ properties = @{ schedule = @{ name = $name }; runbook = @{ name = [string]$settings.monitorRunbook } } }
        $linked = Invoke-DbHubArm -Context $Context -Method PUT -Path ('{0}/jobSchedules/{1}' -f $account, [guid]::NewGuid().ToString()) -ApiVersion $version -Body $link
        if ($linked.StatusCode -notin 200, 201) {
            Write-DbHubLog -Context $Context -Message ('The monitoring re-check {0} wasn''t linked to {1}: {2}' -f $name, $settings.monitorRunbook, $linked.Error)
            continue
        }
        $created.Add($name)
    }
    if ($created.Count -gt 0) {
        Write-DbHubLog -Context $Context -Message ('T1''s monitoring plugin is checked again every {0} minutes during the run ({1}).' -f $interval, ($created -join ', '))
    }
    return $created.ToArray()
}

function Get-DbHubVmState {
    # A VM's power state from its instance view: running, deallocated, stopped, starting, deallocating, Missing, or
    # Unknown.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Compute/virtualMachines'
    $view = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/instanceView' -f (Get-DbHubDemoPath -Settings $Context.Settings), $VmName) -ApiVersion $version
    if ($view.StatusCode -eq 404) {
        return 'Missing'
    }
    if ($view.StatusCode -ne 200) {
        return 'Unknown'
    }
    foreach ($status in @(Get-DbHubMember -InputObject $view.Body -Name 'statuses')) {
        $code = [string](Get-DbHubMember -InputObject $status -Name 'code')
        if ($code -like 'PowerState/*') {
            return $code.Substring(11)
        }
    }
    return 'Unknown'
}

function Get-DbHubVmStartUtc {
    <#
    .SYNOPSIS
    A running VM's latest start, as its instance view gives it: the time of its provisioning status, which a start sets
    when it completes ("the time of the status"); $null when it can't be read or has no time. Later VM operations can move
    it later, never earlier, so a plugin status reported after it is from this boot.
    https://learn.microsoft.com/rest/api/compute/virtual-machines/instance-view (InstanceViewStatus, checked 2026-11-04)
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Compute/virtualMachines'
    $view = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/instanceView' -f (Get-DbHubDemoPath -Settings $Context.Settings), $VmName) -ApiVersion $version
    if ($view.StatusCode -ne 200) {
        return $null
    }
    foreach ($status in @(Get-DbHubMember -InputObject $view.Body -Name 'statuses')) {
        if ([string](Get-DbHubMember -InputObject $status -Name 'code') -like 'ProvisioningState/*') {
            return (ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject $status -Name 'time'))
        }
    }
    return $null
}

function Invoke-DbHubVmAction {
    # Starts or deallocates a VM (POST start or deallocate) without waiting. Returns $true when Azure accepted it.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('start', 'deallocate')]
        [string] $Action
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Compute/virtualMachines'
    $sent = Invoke-DbHubArm -Context $Context -Method POST -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/{2}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $VmName, $Action) -ApiVersion $version
    if ($sent.StatusCode -in 200, 202) {
        Write-DbHubLog -Context $Context -Message ('{0}: {1} accepted.' -f $VmName, $Action)
        return $true
    }
    Write-DbHubLog -Context $Context -Message ('{0}: {1} failed: {2}' -f $VmName, $Action, $sent.Error)
    return $false
}

function Get-DbHubResourceGroupTag {
    # The demo resource group's tags. GroupState: Present, Missing, NotGranted (A1 missing after a redeploy), or Unknown.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Resources/resourceGroups'
    $group = Invoke-DbHubArm -Context $Context -Method GET -Path (Get-DbHubDemoPath -Settings $Context.Settings) -ApiVersion $version
    $state = 'Present'
    if ($group.StatusCode -eq 404) {
        $state = 'Missing'
    }
    elseif ($group.StatusCode -eq 403) {
        $state = 'NotGranted'
    }
    elseif ($group.StatusCode -ne 200) {
        $state = 'Unknown'
    }
    return [pscustomobject]@{ GroupState = $state; Tags = (Get-DbHubMember -InputObject $group.Body -Name 'tags'); Error = $group.Error }
}

function Get-DbHubBusyMarker {
    <#
    .SYNOPSIS
    The demo resource group's busy marker (2026-11-14): DbHubBusyUntilUtc, which deploy.ps1 and a control session set
    and refresh while they run, and DbHubBusyBy, who set it (deploy, deploy-grace, or session). Returns Active, UntilUtc,
    By, and Reason. Active only while the marker is ahead of now by at most busyMarkerMaximumMinutes (180 by default): a
    marker further ahead can't come from a refresh, so it's ignored, and an expired one means its run ended or was
    abandoned. Pure, apart from the clock.
    #>
    param(
        [AllowNull()]
        [object] $Tags,

        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [AllowNull()]
        [object] $NowUtc = $null
    )

    $now = if ($null -ne $NowUtc) { ([datetime]$NowUtc).ToUniversalTime() } else { [DateTime]::UtcNow }
    $text = [string](Get-DbHubMember -InputObject $Tags -Name 'DbHubBusyUntilUtc')
    $by = [string](Get-DbHubMember -InputObject $Tags -Name 'DbHubBusyBy')
    if ($by -notmatch '^[a-z][a-z-]{0,31}$') {
        $by = ''
    }
    $answer = [pscustomobject]@{ Active = $false; UntilUtc = $null; By = $by; Reason = 'None' }
    if (-not $text) {
        return $answer
    }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if (-not [datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref] $parsed)) {
        $answer.Reason = 'Unreadable'
        return $answer
    }
    $answer.UntilUtc = $parsed
    $maximum = [int](Get-DbHubMember -InputObject $Settings -Name 'busyMarkerMaximumMinutes')
    if ($maximum -le 0) {
        $maximum = 180
    }
    if ($parsed -le $now) {
        $answer.Reason = 'Expired'
    }
    elseif ($parsed -gt $now.AddMinutes($maximum)) {
        $answer.Reason = 'TooFar'
    }
    else {
        $answer.Active = $true
        $answer.Reason = 'Active'
    }
    return $answer
}

function Get-DbHubBusyDeferral {
    # A stop's result when the busy marker defers it (Get-DbHubBusyMarker): Deferred, with who's busy and until when; or $null.
    param(
        [Parameter(Mandatory = $true)]
        [string] $Label,

        [AllowNull()]
        [object] $Tags,

        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    $busy = Get-DbHubBusyMarker -Tags $Tags -Settings $Context.Settings -NowUtc $Context.NowUtc
    if (-not $busy.Active) {
        if ($busy.Reason -in 'TooFar', 'Unreadable') {
            Write-DbHubLog -Context $Context -Message ('The busy marker ({0}) was ignored: it''s {1}, so the stop goes on.' -f [string](Get-DbHubMember -InputObject $Tags -Name 'DbHubBusyUntilUtc'), $(if ($busy.Reason -eq 'TooFar') { 'further ahead than a run refreshes it' } else { 'not a time' }))
        }
        return $null
    }
    $who = switch ($busy.By) {
        'deploy' { 'deploy.ps1 is still running' }
        'deploy-grace' { 'deploy.ps1 finished after the nightly stop, and its grace period runs' }
        'session' { 'a demo session is running' }
        default { 'a run is still busy' }
    }
    $until = $busy.UntilUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $message = 'Deferred: {0} (busy until {1}), so nothing was stopped now. The run stops everything at its end, or a later pass does once the marker expires.' -f $who, $until
    Write-DbHubLog -Context $Context -Message $message
    $result = [pscustomobject]@{ action = $Label; status = 'Deferred'; message = $message; busyUntil = $until; busyBy = $busy.By }
    if ($Label -eq 'check-t3') {
        $result | Add-Member -NotePropertyName 't3' -NotePropertyValue 'Deferred'
    }
    return $result
}

function Get-DbHubStartDemoDeferral {
    <#
    .SYNOPSIS
    start-demo.ps1's auto-stop waits for a deploy.ps1 run that's still going (2026-11-19), as the nightly stop does: when
    the auto-stop is start-demo.ps1's (its description's marker) and the busy marker says deploy.ps1 runs (DbHubBusyBy
    deploy, Get-DbHubBusyMarker), it moves to 5 minutes after the marker's end, keeping its marker (Register-DbHubAutoStop
    -Description), and nothing is stopped now. Returns the Deferred result, or $null when the stop goes on. A session's
    auto-stop from the control notebook never waits: its session ends at its own plan.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $settings = $Context.Settings
    $busy = Get-DbHubBusyMarker -Tags $Tags -Settings $settings -NowUtc $Context.NowUtc
    if (-not $busy.Active -or $busy.By -ne 'deploy') {
        return $null
    }
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Automation/automationAccounts'
    $schedule = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/schedules/{1}' -f (Get-DbHubAccountPath -Settings $settings), $settings.autoStopSchedule) -ApiVersion $version
    if ($schedule.StatusCode -ne 200) {
        return $null
    }
    $description = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $schedule.Body -Name 'properties') -Name 'description')
    if (-not $description.StartsWith($script:DbHubStartDemoMarker, [System.StringComparison]::Ordinal)) {
        return $null
    }
    $until = $busy.UntilUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $moved = Register-DbHubAutoStop -Context $Context -AutoStopUtc $busy.UntilUtc.AddMinutes(5) -Description $description
    $then = 'it stops the demo at {0}' -f $moved.StartUtc
    if (-not $moved.Created) {
        $then = 'it couldn''t be moved ({0}), so the nightly stop, which waits for deploy.ps1 too, stops the demo' -f $moved.Error
    }
    $message = 'Deferred: deploy.ps1 is still running (busy until {0}), so start-demo.ps1''s auto-stop stopped nothing now; {1}.' -f $until, $then
    Write-DbHubLog -Context $Context -Message $message
    return [pscustomobject]@{ action = 'stop-all'; status = 'Deferred'; message = $message; busyUntil = $until; busyBy = $busy.By; autoStopUtc = [string]$moved.StartUtc }
}

function Get-DbHubT3State {
    # T3's database (<t3ServerPrefix><deploymentId>/<demoDatabase>) from the group's deploymentId tag: Present, Missing,
    # or Unknown.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $deploymentId = [string](Get-DbHubMember -InputObject $Tags -Name 'deploymentId')
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        return 'Unknown'
    }
    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Sql/servers/databases'
    $path = '{0}/providers/Microsoft.Sql/servers/{1}{2}/databases/{3}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $Context.Settings.t3ServerPrefix, $deploymentId, $Context.Settings.demoDatabase
    $read = Invoke-DbHubArm -Context $Context -Method GET -Path $path -ApiVersion $version
    if ($read.StatusCode -eq 200) {
        return 'Present'
    }
    if ($read.StatusCode -eq 404) {
        return 'Missing'
    }
    return 'Unknown'
}

function Get-DbHubT4 {
    # T4, the PostgreSQL flexible server <t4ServerPrefix><deploymentId> (Phase 24): Name, State (Ready, Stopped,
    # Starting, Stopping, Updating, ...), or State Missing or Unknown, and its size: Tier (sku.tier) and SkuName
    # (sku.name), which the showcase's T4 slots use (2026-11-04).
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $deploymentId = [string](Get-DbHubMember -InputObject $Tags -Name 'deploymentId')
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        return [pscustomobject]@{ Name = ''; State = 'Unknown'; Tier = ''; SkuName = '' }
    }
    $name = '{0}{1}' -f $Context.Settings.t4ServerPrefix, $deploymentId
    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.DBforPostgreSQL/flexibleServers'
    $read = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{1}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $name) -ApiVersion $version
    if ($read.StatusCode -eq 404) {
        return [pscustomobject]@{ Name = $name; State = 'Missing'; Tier = ''; SkuName = '' }
    }
    if ($read.StatusCode -ne 200) {
        return [pscustomobject]@{ Name = $name; State = 'Unknown'; Tier = ''; SkuName = '' }
    }
    $sku = Get-DbHubMember -InputObject $read.Body -Name 'sku'
    return [pscustomobject]@{ Name = $name; State = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $read.Body -Name 'properties') -Name 'state'); Tier = [string](Get-DbHubMember -InputObject $sku -Name 'tier'); SkuName = [string](Get-DbHubMember -InputObject $sku -Name 'name') }
}

function Get-DbHubT4VCore {
    # T4's vCores from its size's name (Standard_B1ms 1, Standard_B2s 2, Standard_D2ds_v5 2, Standard_D4ds_v5 and
    # Standard_D4ads_v5 4: the number after the series letter, as Learn's compute sizes name them), or 0 when the name
    # doesn't say. https://learn.microsoft.com/azure/postgresql/compute-storage/concepts-compute
    param(
        [AllowNull()]
        [string] $SkuName
    )

    if ([string]$SkuName -cmatch '^Standard_[A-Z]+(\d{1,2})[a-z_0-9]*$') {
        $vcores = [int]$Matches[1]
        if ($vcores -ge 1 -and $vcores -le 64) {
            return $vcores
        }
    }
    return 0
}

function Invoke-DbHubT4Action {
    # Starts or stops T4 (POST start or stop) without waiting. Returns $true when Azure accepted it.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet('start', 'stop')]
        [string] $Action
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.DBforPostgreSQL/flexibleServers'
    $sent = Invoke-DbHubArm -Context $Context -Method POST -Path ('{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{1}/{2}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $Name, $Action) -ApiVersion $version
    if ($sent.StatusCode -in 200, 202) {
        Write-DbHubLog -Context $Context -Message ('{0}: {1} accepted.' -f $Name, $Action)
        return $true
    }
    Write-DbHubLog -Context $Context -Message ('{0}: {1} failed: {2}' -f $Name, $Action, $sent.Error)
    return $false
}

function Get-DbHubRunCommandTimeout {
    # A dispatch's Run Command timeout: 5 minutes, plus each request's readiness bound (readySeconds) and its runner's
    # timeout, plus the 12-minute heartbeat wait in front of T2's requests. At most 50 minutes, so that
    # Clear-DbHubOldRunCommand's "more than an hour after the time in its name" still means finished.
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Request
    )

    $seconds = 300
    foreach ($item in $Request) {
        $seconds += [int](Get-DbHubMember -InputObject $item -Name 'readySeconds') + [int](Get-DbHubMember -InputObject $item -Name 'timeoutSeconds')
        if ([string](Get-DbHubMember -InputObject $item -Name 'target') -eq 'T2') {
            $seconds += 720
        }
    }
    return [int][System.Math]::Min(3000, $seconds)
}

function Send-DbHubDispatch {
    <#
    .SYNOPSIS
    Sends planned activities to one VM in one asynchronous managed Run Command named Name: each target's request has
    its runner arguments, the runner's timeout, and readySeconds, how long the VM-side control waits for the target to
    accept connections first (settings readySeconds: 20 minutes for T2, whose guest may have to start; 10 for the
    others). Returns $true when Azure accepted it.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName,

        [Parameter(Mandatory = $true)]
        [object[]] $Activity,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $RequestedBy
    )

    $settings = $Context.Settings
    $requests = @()
    foreach ($item in $Activity) {
        $ready = Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $settings -Name 'readySeconds') -Name ([string]$item.Target)
        if ($null -eq $ready) {
            $ready = 600
        }
        if ([string](Get-DbHubMember -InputObject $item -Name 'Scenario') -ceq 'off') {
            # The VM-side control never waits for a target before it turns it off (Test-DemoControlActivityCommand).
            $ready = 0
        }
        $requests += [ordered]@{ target = $item.Target; arguments = @(Get-DbHubRunnerArgument -Activity $item -RequestedBy $RequestedBy); timeoutSeconds = 300; readySeconds = [int]$ready }
    }
    return (Send-DbHubRunCommand -Context $Context -VmName $VmName -Name $Name -Script (Get-DbHubWorkloadScript -Settings $settings -Request $requests) -TimeoutSeconds (Get-DbHubRunCommandTimeout -Request $requests))
}

function Get-DbHubRunnerArgument {
    <#
    The runner arguments for one planned activity, built from validated values only, or for a reset. off turns the
    target's activity off; a profile (showcase) runs for its minutes and ends with the run (--not-after: the run's end
    plus the 2 minutes the runner keeps before it), and T4's gets its tier and vCores (--tier, --vcores), which pick and
    scale its slots; the baseline and an incident end by the VMs' next auto-shutdown at the latest.
    #>
    param(
        [AllowNull()]
        [object] $Activity,

        [Parameter(Mandatory = $true)]
        [string] $RequestedBy,

        [switch] $Reset
    )

    if ($Reset) {
        return @('reset', '--requested-by', $RequestedBy)
    }
    if ($Activity.Scenario -ceq 'off') {
        return @('profile', 'set', '--name', 'off', '--requested-by', $RequestedBy)
    }
    $notAfter = Get-DbHubMember -InputObject $Activity -Name 'NotAfterUtc'
    if ($null -ne $notAfter) {
        $arguments = @('profile', 'set', '--name', [string]$Activity.Scenario, '--duration', ('{0}m' -f [int]$Activity.Minutes), '--not-after', ([datetime]$notAfter).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'+00:00'", [System.Globalization.CultureInfo]::InvariantCulture))
        if ([string]$Activity.Target -ceq 'T4') {
            $tier = [string](Get-DbHubMember -InputObject $Activity -Name 'Tier')
            if ($tier) {
                $arguments += @('--tier', $tier)
            }
            $vcores = [int](Get-DbHubMember -InputObject $Activity -Name 'VCores')
            if ($vcores -gt 0) {
                $arguments += @('--vcores', [string]$vcores)
            }
        }
        $arguments += @('--requested-by', $RequestedBy)
        return $arguments
    }
    $name = 'baseline'
    if ($Activity.Scenario -cne 'baseline') {
        $name = 'incident:' + $Activity.Scenario
    }
    $arguments = @('profile', 'set', '--name', $name, '--duration', ('{0}m' -f [int]$Activity.Minutes), '--not-after', '{{NEXT_SHUTDOWN}}')
    if ([int]$Activity.Concurrency -gt 0) {
        $arguments += @('--concurrency', [string][int]$Activity.Concurrency)
    }
    if ([int]$Activity.Intensity -gt 0) {
        $arguments += @('--intensity', [string][int]$Activity.Intensity)
    }
    $arguments += @('--requested-by', $RequestedBy)
    return $arguments
}

function Get-DbHubWorkloadScript {
    <#
    .SYNOPSIS
    The managed Run Command script for one VM: the module's workload-control template (Get-DemoWorkloadControlTemplate,
    baked into the settings) once per target, in order. T1's runner drives T1, T3, T4, and T5 on sqlvm01; archost01
    relays T2 into its guest. For T2 the script first waits, at most 12 minutes, for the guest's Hyper-V heartbeat,
    because a host that was just started runs its guest a few minutes later; a guest that's off and doesn't start by
    itself (its automatic start action isn't Start: a golden capture's air gap, or a guest that was shut down) isn't
    waited for, because the VM-side control releases or starts it before its activity (Invoke-DemoControlGuestReady).
    Each request is Base64 JSON, checked before it goes between single quotes.
    Each target's result line (DBHUBDEMO-WORKLOAD) is read as the VM-side control writes it (#28, 2026-11-17; live,
    2026-11-04: a profile set that failed on T1 and T2 ended a Succeeded Run Command). A target whose status isn't Pass or
    Warning didn't get its activity, so after the last target the script writes DBHUB-DISPATCH with each such target, its
    status, the end of its message, and whether its runner predates the control (it refused the profile or an option; #21),
    and ends with exit code 1: Azure then shows the Run Command Failed, and the session's host check names the target
    (Get-DbHubSessionHealth). It reads only the line every VM-side control writes, so it works whatever runner a VM has.
    Each target that got its activity also gets the VM's UTC time right after its set returned, which is when the runner
    set the profile and so when its showcase counts its cycles from, and the script writes them in one DBHUB-SET line at
    the end of its output, before DBHUB-DISPATCH (2026-11-19; live: on a VM that had just started, sqlvm01's Run Command,
    accepted at 13:29:28, set T3's profile 2 minutes 41 seconds later). Get-DbHubSessionHealth moves dispatchUtc to it.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [Parameter(Mandatory = $true)]
        [object[]] $Request
    )

    $template = [string]$Settings.controlScriptTemplate
    if (-not $template.Contains('__REQUEST__')) {
        throw 'The runbook settings have no workload-control template.'
    }
    $parts = @(
        '# DbHubDemo on-demand dispatch (ADR 0020), generated by the DbHub-Control runbook; it holds no secrets.',
        '$dbhubConsole = [Console]::Out',
        # The console host binds its own writer to the console's at its first output, so that comes before any capture;
        # otherwise the host's later output would go into a capture that's no longer read.
        'Write-Output ''DbHubDemo on-demand dispatch: one result line per target follows.''',
        '$dbhubFailed = New-Object -TypeName ''System.Collections.Generic.List[object]''',
        '$dbhubSet = [ordered]@{}',
        'function Read-DbHubDispatchResult {',
        '    param([string] $Target, [string] $Text)',
        '    $dbhubConsole.Write($Text)',
        '    $dbhubConsole.Flush()',
        '    $status = ''''',
        '    $message = ''''',
        '    foreach ($line in ($Text -split ''\r?\n'')) {',
        '        if ($line.StartsWith(''DBHUBDEMO-WORKLOAD '')) {',
        '            try { $parsed = $line.Substring(19) | ConvertFrom-Json; $status = [string]$parsed.status; $message = [string]$parsed.message } catch { $status = ''Unreadable'' }',
        '        }',
        '    }',
        '    if ($status -eq ''Pass'' -or $status -eq ''Warning'') {',
        '        $dbhubSet[$Target] = [DateTime]::UtcNow.ToString(''yyyy-MM-ddTHH:mm:ssZ'', [System.Globalization.CultureInfo]::InvariantCulture)',
        '        return',
        '    }',
        '    if (-not $status) { $status = ''NoResult'' }',
        '    if ($message.Length -gt 240) { $message = ''...'' + $message.Substring($message.Length - 240) }',
        '    $dbhubFailed.Add([ordered]@{ target = $Target; status = $status; message = $message; oldRunner = [bool]($Text -match ''Unknown activity profile|Unrecognized command or argument'') })',
        '}'
    )
    if (@($Request | Where-Object { [string](Get-DbHubMember -InputObject $_ -Name 'target') -eq 'T2' }).Count -gt 0) {
        $guest = [string]$Settings.t2GuestName
        if ($guest -notmatch '^[A-Za-z0-9-]{1,15}$') {
            throw 'The runbook settings have no valid t2GuestName.'
        }
        $parts += @(
            '$guestDeadline = [DateTime]::UtcNow.AddMinutes(12)',
            'while ([DateTime]::UtcNow -lt $guestDeadline) {',
            ('    $guestVm = Get-VM -Name ''{0}'' -ErrorAction SilentlyContinue' -f $guest),
            '    if ($guestVm -and [string]$guestVm.State -eq ''Running'' -and [string]$guestVm.Heartbeat -like ''Ok*'') { Start-Sleep -Seconds 30; break }',
            '    if ($guestVm -and [string]$guestVm.State -eq ''Off'' -and [string]$guestVm.AutomaticStartAction -ne ''Start'') { break }',
            '    Start-Sleep -Seconds 15',
            '}'
        )
    }
    foreach ($item in $Request) {
        $target = [string](Get-DbHubMember -InputObject $item -Name 'target')
        if ($target -notmatch '^T[1-5]$') {
            throw 'A request has no valid target.'
        }
        $json = $item | ConvertTo-Json -Depth 6 -Compress
        $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
        if ($encoded -notmatch '^[A-Za-z0-9+/=]+$') {
            throw 'A request did not encode to Base64.'
        }
        # The VM-side control writes its result line straight to the console, so it's captured there, then written out.
        $parts += @(
            '$dbhubCapture = New-Object -TypeName ''System.IO.StringWriter''',
            '[Console]::SetOut($dbhubCapture)',
            'try {',
            $template.Replace('__REQUEST__', $encoded),
            '}',
            'finally {',
            '    [Console]::SetOut($dbhubConsole)',
            '}',
            ('Read-DbHubDispatchResult -Target ''{0}'' -Text $dbhubCapture.ToString()' -f $target)
        )
    }
    $parts += @(
        'if ($dbhubSet.Count -gt 0) {',
        '    $dbhubConsole.WriteLine(''DBHUB-SET '' + (ConvertTo-Json -InputObject $dbhubSet -Compress))',
        '    $dbhubConsole.Flush()',
        '}',
        'if ($dbhubFailed.Count -gt 0) {',
        '    $dbhubConsole.WriteLine(''DBHUB-DISPATCH '' + (ConvertTo-Json -InputObject @{ failed = @($dbhubFailed.ToArray()) } -Depth 4 -Compress))',
        '    $dbhubConsole.Flush()',
        '    exit 1',
        '}'
    )
    return (($parts -join "`n") + "`n")
}

function Send-DbHubRunCommand {
    <#
    .SYNOPSIS
    Creates a managed Run Command with asyncExecution, so Azure returns once it's accepted and nothing waits for the
    script (Phase 25a: one stayed Pending for 654 seconds on a saturated sqlvm01). A Conflict (a policy extension or
    another Run Command is busy) is tried again twice, 30 seconds apart. Returns $true when accepted.
    https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Script,

        [int] $TimeoutSeconds = 900,

        [int] $ConflictDelaySeconds = 30
    )

    if ($Name -notmatch '^[A-Za-z0-9-]{1,64}$') {
        throw ('Invalid Run Command name: {0}' -f $Name)
    }
    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Compute/virtualMachines/runCommands'
    $body = @{
        location   = [string]$Context.Settings.location
        properties = @{
            source                          = @{ script = $Script }
            asyncExecution                  = $true
            treatFailureAsDeploymentFailure = $false
            timeoutInSeconds                = $TimeoutSeconds
        }
    }
    $path = '{0}/providers/Microsoft.Compute/virtualMachines/{1}/runCommands/{2}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $VmName, $Name
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $put = Invoke-DbHubArm -Context $Context -Method PUT -Path $path -ApiVersion $version -Body $body
        if ($put.StatusCode -in 200, 201) {
            Write-DbHubLog -Context $Context -Message ('{0}: Run Command {1} accepted (it runs on its own).' -f $VmName, $Name)
            return $true
        }
        if ($put.StatusCode -ne 409 -or $attempt -eq 3) {
            break
        }
        Start-Sleep -Seconds $ConflictDelaySeconds
    }
    Write-DbHubLog -Context $Context -Message ('{0}: Run Command {1} wasn''t accepted: {2}' -f $VmName, $Name, $put.Error)
    return $false
}

function Clear-DbHubOldRunCommand {
    # Deletes this runbook's earlier managed Run Commands on a VM (names that start with runCommandPrefix), without
    # waiting for the deletes. With -FinishedOnly, only those whose script has ended: the instance view's execution
    # state is terminal, or the time in the name is more than an hour old (the longest timeout is 50 minutes,
    # Get-DbHubRunCommandTimeout), so one whose instance view a deallocation cleared still goes. Managed Run Commands
    # are limited to 25 per VM
    # (https://learn.microsoft.com/azure/virtual-machines/run-command-overview); deleting one whose script still runs
    # stops it (https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed).
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName,

        [string[]] $Keep = @(),

        [switch] $FinishedOnly
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Compute/virtualMachines/runCommands'
    $base = '{0}/providers/Microsoft.Compute/virtualMachines/{1}/runCommands' -f (Get-DbHubDemoPath -Settings $Context.Settings), $VmName
    $listPath = $base
    if ($FinishedOnly) {
        $listPath = $base + '?$expand=instanceView'
    }
    $list = Invoke-DbHubArm -Context $Context -Method GET -Path $listPath -ApiVersion $version
    if ($list.StatusCode -ne 200) {
        return
    }
    $deleted = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($item in @(Get-DbHubMember -InputObject $list.Body -Name 'value')) {
        $name = [string](Get-DbHubMember -InputObject $item -Name 'name')
        if (-not $name.StartsWith([string]$Context.Settings.runCommandPrefix, [System.StringComparison]::Ordinal) -or $name -in $Keep -or $name -notmatch '^[A-Za-z0-9-]{1,64}$') {
            continue
        }
        if ($FinishedOnly) {
            $view = Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $item -Name 'properties') -Name 'instanceView'
            $finished = [string](Get-DbHubMember -InputObject $view -Name 'executionState') -in @('Succeeded', 'Failed', 'TimedOut', 'Canceled')
            $stamp = [DateTime]::MinValue
            if (-not $finished -and $name -match '-(\d{14})$' -and [DateTime]::TryParseExact($Matches[1], 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture, ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$stamp)) {
                $finished = $stamp.AddHours(1) -lt $Context.NowUtc
            }
            if (-not $finished) {
                continue
            }
        }
        $removed = Invoke-DbHubArm -Context $Context -Method DELETE -Path ('{0}/{1}' -f $base, $name) -ApiVersion $version
        if ($removed.StatusCode -in 200, 202, 204, 404) {
            $deleted.Add($name)
        }
    }
    if ($deleted.Count -gt 0) {
        Write-DbHubLog -Context $Context -Message ('{0}: deleted {1} earlier Run Command(s) of this control: {2}.' -f $VmName, $deleted.Count, ($deleted -join ', '))
    }
}

function Clear-DbHubFinishedRunCommand {
    # The control's finished Run Commands on the demo VMs this run or reset doesn't send one to, when they run (a
    # deallocated VM can't remove one, so the next run tries again), at the start of the run. ADR 0020's stop path never
    # touches Run Command, so the last run's own are deleted by the next run, or by start-demo.ps1 once the VMs run.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [string[]] $Except = @()
    )

    foreach ($vm in @([string]$Context.Settings.sqlVmName, [string]$Context.Settings.hostVmName)) {
        if ($vm -in $Except -or (Get-DbHubVmState -Context $Context -VmName $vm) -ne 'running') {
            continue
        }
        Clear-DbHubOldRunCommand -Context $Context -VmName $vm -FinishedOnly
    }
}

function Get-DbHubPluginReportedUtc {
    <#
    .SYNOPSIS
    When the SQL IaaS Agent's main service last reported: the latest ExtensionServiceHealthReport.MainServiceLastReportedTime
    in the extension's status messages (its ComponentStatus/Resource Provider Plugin substatus; live, 2026-11-04); $null
    when there's none. Right after a start, the instance view still holds the status from before the stop (live,
    2026-11-04: Running and OK a minute after boot, NotRunning 12 minutes later), and this time tells the two apart.
    #>
    param(
        [AllowEmptyCollection()]
        [string[]] $Message = @()
    )

    $latest = $null
    foreach ($text in @($Message)) {
        foreach ($match in [regex]::Matches([string]$text, 'MainServiceLastReportedTime\W{1,8}(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)')) {
            $time = ConvertTo-DbHubUtc -Value $match.Groups[1].Value
            if ($null -ne $time -and ($null -eq $latest -or $time -gt $latest)) {
                $latest = $time
            }
        }
    }
    return $latest
}

function Test-DbHubPluginFresh {
    <#
    .SYNOPSIS
    Whether a plugin status (Get-DbHubMonitoringPlugin) was reported after SinceUtc, sqlvm01's start: its ReportedUtc is
    later. Without SinceUtc there's nothing to compare, so it's fresh. Without a ReportedUtc (an agent that doesn't report
    the time), nothing proves a Running status stale, so it's taken at its word (#22, 2026-11-17): the start it would be
    counted from, the VM's provisioning status's time, moves with every Run Command, the control's own included, and a
    healthy agent was restarted on every warm run and re-check. Another state without a time is fresh only once the start
    is more than 30 minutes old, so a recent start still gets its wait before the restart.
    #>
    param(
        [AllowNull()]
        [object] $Plugin,

        [AllowNull()]
        [object] $SinceUtc,

        [Parameter(Mandatory = $true)]
        [datetime] $NowUtc
    )

    if ($null -eq $SinceUtc) {
        return $true
    }
    $reported = Get-DbHubMember -InputObject $Plugin -Name 'ReportedUtc'
    if ($null -ne $reported) {
        return ([datetime]$reported -gt [datetime]$SinceUtc)
    }
    if ([string](Get-DbHubMember -InputObject $Plugin -Name 'State') -eq 'Running') {
        return $true
    }
    return (($NowUtc - [datetime]$SinceUtc).TotalMinutes -gt 30)
}

function Get-DbHubMonitoringPlugin {
    <#
    .SYNOPSIS
    T1's Database Hub monitoring plugin, as the SQL IaaS Agent extension's instance view reports it and as
    start-demo.ps1 reads it (Restore-DemoSqlVmMonitoringPlugin): Read (the extension could be read), FlagSet (its
    settings hold the monitoring feature flag), Found and State (the plugin's line, for example
    DatabaseMonitorArcPlugin: {"State":"Running","MetricsUploadStatus":"OK"}), Upload, Message, and ReportedUtc (when the
    agent's main service last reported, Get-DbHubPluginReportedUtc; $null when it doesn't say).
    https://learn.microsoft.com/azure/azure-sql/virtual-machines/windows/enable-performance-monitoring-sql-vm
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    $settings = $Context.Settings
    $result = [pscustomobject]@{ Read = $false; FlagSet = $false; Found = $false; State = ''; Upload = ''; Message = ''; ReportedUtc = $null }
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Compute/virtualMachines'
    $read = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/extensions/{2}?$expand=instanceView' -f (Get-DbHubDemoPath -Settings $settings), $settings.sqlVmName, $settings.monitoring.extensionInstanceName) -ApiVersion $version
    if ($read.StatusCode -ne 200) {
        return $result
    }
    $result.Read = $true
    $properties = Get-DbHubMember -InputObject $read.Body -Name 'properties'
    $flagName = [string](Get-DbHubMember -InputObject $settings.monitoring -Name 'featureFlag')
    foreach ($flag in @(Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $properties -Name 'settings') -Name 'FeatureFlags')) {
        if ($null -ne $flag -and [string]::Equals([string](Get-DbHubMember -InputObject $flag -Name 'Name'), $flagName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $enable = Get-DbHubMember -InputObject $flag -Name 'Enable'
            $result.FlagSet = ($enable -eq $true -or [string]$enable -eq 'true')
        }
    }
    $view = Get-DbHubMember -InputObject $properties -Name 'instanceView'
    $messages = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($listName in 'statuses', 'substatuses') {
        foreach ($status in @(Get-DbHubMember -InputObject $view -Name $listName)) {
            $messages.Add([string](Get-DbHubMember -InputObject $status -Name 'message'))
        }
    }
    $result.ReportedUtc = Get-DbHubPluginReportedUtc -Message $messages.ToArray()
    $pattern = [regex]::Escape([string]$settings.monitoring.statusPlugin) + '\s*:\s*(\{[^{}]*\})'
    foreach ($message in $messages) {
        $match = [regex]::Match($message, $pattern)
        if (-not $match.Success) {
            continue
        }
        $result.Message = $match.Value
        try {
            $json = $match.Groups[1].Value | ConvertFrom-Json
            $result.Found = $true
            $result.State = [string](Get-DbHubMember -InputObject $json -Name 'State')
            $result.Upload = [string](Get-DbHubMember -InputObject $json -Name 'MetricsUploadStatus')
        }
        catch {
            $result.Found = $false
        }
        break
    }
    return $result
}

function Send-DbHubMonitoringRestart {
    # Restarts the SQL IaaS Agent's service (monitoring.serviceName) on sqlvm01 through the asynchronous Run Command
    # <runCommandPrefix>monitoring-<Stamp>, as start-demo.ps1 does when the plugin isn't running. Returns $true when
    # Azure accepted it.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $Stamp
    )

    $settings = $Context.Settings
    $service = [string]$settings.monitoring.serviceName
    if ($service -notmatch '^[A-Za-z0-9_]{1,64}$') {
        throw 'The runbook settings have no valid monitoring service name.'
    }
    $script = "`$ErrorActionPreference = 'Stop'`nRestart-Service -Name '{0}' -Force`n" -f $service
    return (Send-DbHubRunCommand -Context $Context -VmName ([string]$settings.sqlVmName) -Name ('{0}monitoring-{1}' -f $settings.runCommandPrefix, $Stamp) -Script $script -TimeoutSeconds 300)
}

function Initialize-DbHubMonitorState {
    # The state of one look after T1's monitoring plugin (Step-DbHubMonitor). StartUtc is when this run's start of sqlvm01
    # was accepted; without it (the run didn't start it, or a DbHub-Monitor re-check), the first step reads the VM's
    # latest start from its instance view (Get-DbHubVmStartUtc).
    param(
        [AllowNull()]
        [object] $StartUtc = $null
    )

    return [pscustomobject]@{ Phase = 'Settle'; Done = $false; Outcome = ''; FirstUtc = $null; RestartUtc = $null; Before = ''; After = ''; Restarted = $false; StartUtc = $StartUtc; StartKnown = ($null -ne $StartUtc) }
}

function Step-DbHubMonitor {
    <#
    .SYNOPSIS
    One read of T1's monitoring plugin and what follows from it, decided as Restore-DemoSqlVmMonitoringPlugin decides
    it. Live, 2026-10-26: about a minute after boot the extension reported no plugin status, and a restart then left
    the plugin NotRunning for hours; once the agent had reported, the restart brought it to Running and OK. Live,
    2026-11-03: the control read the plugin right after the start, found no status, sent no restart, and T1 sent no
    telemetry. Live, 2026-11-04: 47 seconds after the run's start the instance view still held the status from before
    the stop, Running and OK, so no restart went out; 12 minutes later it said NotRunning, and T1 had sent nothing. So a
    status counts only when it's fresh: reported (MainServiceLastReportedTime) after sqlvm01's start in this run, or after
    the VM's latest start in its instance view when the run didn't start it (Test-DbHubPluginFresh). Then:
    - no fresh status yet: wait, up to monitoring.settleMinutes (8) after the first read;
    - fresh and Running: left alone (Outcome Running), uploads that aren't OK included, because a restart doesn't fix
      uploads;
    - fresh in any other state, or still no fresh status after the wait: the SQL IaaS Agent's service is restarted once,
      then read until it's Running with uploads OK in a status reported after the restart (Restarted) or
      monitoring.verifyMinutes pass (StillNotRunning).
    Other outcomes: NotSelected (the monitoring flag isn't set), Unread (the extension couldn't be read for the whole
    time), RestartRefused (Azure didn't accept the Run Command). Done says the look is over.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [object] $State,

        [Parameter(Mandatory = $true)]
        [string] $Stamp
    )

    $monitoring = $Context.Settings.monitoring
    $settle = [int](Get-DbHubMember -InputObject $monitoring -Name 'settleMinutes')
    $verify = [int](Get-DbHubMember -InputObject $monitoring -Name 'verifyMinutes')
    $now = Get-DbHubUtcNow
    if ($null -eq $State.FirstUtc) {
        $State.FirstUtc = $now
    }
    if (-not $State.StartKnown) {
        $State.StartUtc = Get-DbHubVmStartUtc -Context $Context -VmName ([string]$Context.Settings.sqlVmName)
        $State.StartKnown = $true
    }
    $plugin = Get-DbHubMonitoringPlugin -Context $Context
    $finish = {
        param([string] $Outcome, [string] $Text)
        $State.Done = $true
        $State.Outcome = $Outcome
        Write-DbHubLog -Context $Context -Message ('T1''s monitoring plugin: {0}' -f $Text)
    }
    $timeText = {
        param([AllowNull()] [object] $Time)
        if ($null -eq $Time) {
            return 'an unknown time'
        }
        return ([datetime]$Time).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    if (-not $plugin.Read) {
        $bound = $State.FirstUtc.AddMinutes($settle + $verify)
        if ($State.Restarted) {
            $bound = $State.RestartUtc.AddMinutes($verify)
        }
        if ($now -lt $bound) {
            return
        }
        if ($State.Restarted) {
            $State.After = 'the SQL IaaS Agent extension couldn''t be read'
            & $finish 'StillNotRunning' ('the SQL IaaS Agent extension couldn''t be read {0} minutes after the restart.' -f $verify)
        }
        else {
            & $finish 'Unread' 'the SQL IaaS Agent extension couldn''t be read.'
        }
        return
    }
    if (-not $plugin.FlagSet) {
        & $finish 'NotSelected' 'performance monitoring isn''t turned on (its feature flag isn''t set).'
        return
    }
    if ($State.Phase -eq 'Settle') {
        $reported = $plugin.Found -and $plugin.State
        $fresh = $reported -and (Test-DbHubPluginFresh -Plugin $plugin -SinceUtc $State.StartUtc -NowUtc $now)
        if ($fresh -and $plugin.State -eq 'Running') {
            $State.Before = $plugin.Message
            & $finish 'Running' ('running ({0}, reported at {1}).' -f $plugin.Message, (& $timeText $plugin.ReportedUtc))
            return
        }
        if (-not $fresh -and $now -lt $State.FirstUtc.AddMinutes($settle)) {
            return
        }
        if ($fresh) {
            $State.Before = $plugin.Message
        }
        elseif ($reported) {
            # Live, 2026-11-04: the status from before the stop said Running and OK, and the plugin was NotRunning.
            $State.Before = 'no fresh plugin status since {0}''s start at {1} (waited {2} minutes); the last one, reported at {3}, said {4}' -f $Context.Settings.sqlVmName, (& $timeText $State.StartUtc), $settle, (& $timeText $plugin.ReportedUtc), $plugin.Message
        }
        else {
            $State.Before = 'no plugin status after {0} minutes' -f $settle
        }
        if (-not (Send-DbHubMonitoringRestart -Context $Context -Stamp $Stamp)) {
            & $finish 'RestartRefused' ('{0}; the SQL IaaS Agent service''s restart wasn''t accepted.' -f $State.Before)
            return
        }
        $State.Restarted = $true
        $State.RestartUtc = $now
        $State.Phase = 'Verify'
        Write-DbHubLog -Context $Context -Message ('T1''s monitoring plugin: {0}; the SQL IaaS Agent service is restarted.' -f $State.Before)
        return
    }
    # After the restart, only a status reported since then counts; an agent that doesn't report the time is taken at its word.
    $afterRestart = $null -eq $plugin.ReportedUtc -or $plugin.ReportedUtc -gt $State.RestartUtc
    if ($plugin.State -eq 'Running' -and $plugin.Upload -eq 'OK' -and $afterRestart) {
        $State.After = $plugin.Message
        & $finish 'Restarted' ('running with uploads OK after the restart ({0}).' -f $plugin.Message)
        return
    }
    if ($now -ge $State.RestartUtc.AddMinutes($verify)) {
        $State.After = if ($plugin.Message) { $plugin.Message } else { 'no plugin status' }
        & $finish 'StillNotRunning' ('{0} {1} minutes after the restart.' -f $State.After, $verify)
    }
}

function Stop-DbHubDemo {
    <#
    .SYNOPSIS
    Stop now, and what the auto-stop does: removes the auto-stop schedule and the run's monitoring re-checks,
    deallocates both VMs, stops T4, and deletes T5's container (2026-11-19), through Azure Resource Manager only. Never
    Run Command (Phase 25a, finding 5) to stop anything: deallocation ends every session on T1 and T2 (the T2 guest shuts
    down through the host's automatic stop action, ShutDown), T3's sessions end with T1's runner, and T3 auto-pauses after
    its delay. The activity profiles end at their own end; the profile host ends what a stopped run left behind when it
    starts again. A session's stop first exports its evidence for the Incident RCA (2026-11-20, ADR 0031,
    Invoke-DbHubRcaStop) through managed Run Commands that only read, bounded by rca.stopMinutes, while the VMs still run.
    Before anything else it marks the session's stop as begun in its status's copy (Set-DbHubStopBegun), so a re-check
    that's still exporting writes no bundle after the metrics' final version.
    Returns Done, Failed, MetricsStatus, MetricsMessage, MetricsVersion (the final version's ID, which the stop's status
    keeps), T5Status (Remove-DbHubT5Container's outcome, '' when it wasn't asked; apart from Failed, review of ab91ee5),
    and Rca (the export's State, Index, and Lines, or $null).

    .DESCRIPTION
    With the control's session settings (2026-11-14, ADR 0026), and T4's read replica there or a session's busy marker set:
    T4's and the replica's Azure Monitor metrics go to the control vault first (Save-DbHubSessionMetric), because a
    deleted server's can't be read; then the replica is deleted (Remove-DbHubT4Replica) before T4 stops, and a session's
    busy marker is cleared. T4's stop right after the replica's deletion is confirmed (Stop-DbHubT4Confirmed): Azure can
    still refuse it then (SourceReplicasStartStopOrder, live 2026-11-14). Without the grant to delete it (or with the safety
    stop's settings), the replica is stopped once T4 is, as before.
    -OnlyVm, -KeepT4, and -RemoveReplica (#27, user-directed 2026-11-17) scope it to what a run that sent no activity
    started itself (Start-DbHubActivityRun): only those VMs are deallocated, and with -KeepT4, T4 and its read replica stay
    as they are, unless -RemoveReplica (the replica that run's session asked for), which is deleted.
    T5's container (2026-11-19, ADR 0027): a whole stop deletes it once the VMs' deallocation is sent, and after the
    history's metrics, which read T5's too (Remove-DbHubT5Container), so its throughput doesn't bill between sessions; only
    when its lifecycle is Session, otherwise it's kept, and the result says why. A scoped stop deletes it only with
    -RemoveT5Container (the run created it).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [AllowEmptyString()]
        [string] $SessionId = '',

        [int] $PollSeconds = 20,

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $OnlyVm = $null,

        [switch] $KeepT4,

        [switch] $RemoveReplica,

        [switch] $RemoveT5Container
    )

    $settings = $Context.Settings
    if (-not $PSCmdlet.ShouldProcess($settings.demoResourceGroup, 'Deallocate the VMs, stop T4, and delete T5''s container')) {
        return [pscustomobject]@{ Done = @(); Failed = @(); MetricsStatus = ''; MetricsMessage = ''; MetricsVersion = ''; Rca = $null }
    }
    $done = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $failed = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $metricsStatus = ''
    $metricsMessage = ''
    $metricsVersion = ''
    $t5Status = ''
    $session = Test-DbHubSessionCapable -Settings $settings
    if ($session -and $null -eq $OnlyVm) {
        # First (review of 15ad76d): a re-check still exporting this session's evidence writes no bundle from now on.
        $stopping = $SessionId
        if (-not $stopping) {
            $stopping = [string](Get-DbHubMember -InputObject $Tags -Name 'DbHubSessionId')
        }
        $null = Set-DbHubStopBegun -Context $Context -SessionId $stopping
    }
    if (Clear-DbHubAutoStop -Context $Context) {
        $done.Add('auto-stop removed')
    }
    else {
        $failed.Add('auto-stop schedule')
    }
    $busy = Get-DbHubBusyMarker -Tags $Tags -Settings $settings -NowUtc $Context.NowUtc
    $replicaThere = $false
    $rca = $null
    # With -KeepT4, T4's read replica stays too, unless the run's session asked for it (-RemoveReplica).
    $replicaGoes = -not $KeepT4 -or $RemoveReplica
    if ($session) {
        $replicaThere = (Get-DbHubT4Replica -Context $Context -Tags $Tags).State -notin 'NotConfigured', 'Missing', 'Unknown'
        if (($replicaThere -and $replicaGoes) -or $busy.By -eq 'session') {
            # The session's evidence for the Incident RCA first (ADR 0031), while the VMs still run: its bundles go into the
            # vault before the metrics' final version, which lists them. Bounded (rca.stopMinutes); what isn't exported by
            # then stays on the VMs, and the next session's start exports it.
            if ($null -eq $OnlyVm) {
                $rca = Invoke-DbHubRcaStop -Context $Context -Tags $Tags -SessionId $SessionId
            }
            $rcaIndex = $null
            if ($null -ne $rca) {
                $rcaIndex = $rca.Index
            }
            # The history's metrics first, while the replica exists.
            $saved = Save-DbHubSessionMetric -Context $Context -Tags $Tags -SessionId $SessionId -Rca $rcaIndex
            $metricsStatus = [string]$saved.Status
            $metricsMessage = [string]$saved.Message
            $metricsVersion = [string](Get-DbHubMember -InputObject $saved -Name 'Version')
            if ($saved.Status -in 'Pass', 'Warning') {
                $done.Add('the history''s metrics saved to the control vault')
            }
            else {
                $done.Add(('the history''s metrics not saved ({0})' -f $saved.Message))
            }
        }
    }
    foreach ($vm in @([string]$settings.sqlVmName, [string]$settings.hostVmName)) {
        if ($null -ne $OnlyVm -and $vm -notin $OnlyVm) {
            continue
        }
        $state = Get-DbHubVmState -Context $Context -VmName $vm
        if ($state -in 'deallocated', 'deallocating', 'Missing') {
            $done.Add(('{0} {1}' -f $vm, $state.ToLowerInvariant()))
            continue
        }
        if (Invoke-DbHubVmAction -Context $Context -VmName $vm -Action deallocate) {
            $done.Add(('{0} deallocating' -f $vm))
        }
        else {
            $failed.Add($vm)
        }
    }
    if ($null -eq $OnlyVm -or $RemoveT5Container) {
        # T5's container (2026-11-19, ADR 0027): its throughput bills every hour it exists, so it goes once the VMs, whose
        # runner drives T5, are on their way down, and after the history's metrics above, which read T5's too.
        # Its outcome is apart from the stop's failed list (review of ab91ee5): one this role can't delete is said, never a
        # failed stop of the VMs and T4.
        $t5 = Remove-DbHubT5Container -Context $Context -Tags $Tags
        $t5Text = Get-DbHubT5ContainerText -Outcome $t5
        $t5Status = [string]$t5.Outcome
        if ($t5Text) {
            $done.Add($t5Text)
        }
    }
    $replicaDeleted = $false
    $replicaJustDeleted = $false
    if ($session -and $replicaThere -and $replicaGoes) {
        # T4's read replica (ADR 0025) bills only during a session: deleted, which doesn't wait for T4 (2026-11-14).
        $removed = Remove-DbHubT4Replica -Context $Context -Tags $Tags -WaitMinutes (Get-DbHubSessionReplicaSetting -Settings $settings).DeleteMinutes
        switch ($removed.Outcome) {
            'Deleted' {
                $done.Add(('T4''s read replica {0} deleted' -f $removed.Name))
                $replicaDeleted = $true
                $replicaJustDeleted = $true
            }
            'Missing' {
                $replicaDeleted = $true
            }
            'NotGranted' {
                Write-DbHubLog -Context $Context -Message ('{0}: the control identity can''t delete it yet (an Owner runs ./scripts/grant-safety-stop.ps1), so it''s stopped after T4 instead.' -f $removed.Name)
            }
            default {
                $failed.Add(('T4''s read replica {0} not deleted: {1}' -f $removed.Name, $removed.Error))
            }
        }
    }
    $t4 = [pscustomobject]@{ Name = ''; State = '' }
    if (-not $KeepT4) {
        $t4 = Get-DbHubT4 -Context $Context -Tags $Tags
    }
    $t4Outcome = ''
    if ($t4.State -in 'Ready', 'Starting', 'Updating' -and $replicaJustDeleted) {
        # Right after the replica's delete, Azure can still refuse T4's stop (live, 2026-11-14), so it's confirmed.
        $confirmed = Stop-DbHubT4Confirmed -Context $Context -Tags $Tags -Name $t4.Name -PollSeconds $PollSeconds
        if ($confirmed.Stopped) {
            $done.Add(('{0} stopping' -f $t4.Name))
            $t4Outcome = 'Sent'
        }
        else {
            $failed.Add(('{0} not stopped: {1}; the nightly safety stop stops it tonight' -f $t4.Name, $confirmed.Error))
            $t4Outcome = 'Failed'
        }
    }
    elseif ($t4.State -in 'Ready', 'Starting', 'Updating') {
        if (Invoke-DbHubT4Action -Context $Context -Name $t4.Name -Action stop) {
            $done.Add(('{0} stopping' -f $t4.Name))
            $t4Outcome = 'Sent'
        }
        else {
            $failed.Add($t4.Name)
            $t4Outcome = 'Failed'
        }
    }
    elseif ($t4.State -notin 'Unknown', '') {
        $done.Add(('T4 {0}' -f $t4.State.ToLowerInvariant()))
    }
    if (-not $replicaDeleted -and -not $KeepT4) {
        # T4's read replica, when a session left it running (ADR 0025) and the control can't delete it: it's stopped once T4
        # is (Azure's order), which waits for T4's stop only when there's a replica to stop.
        $replica = Invoke-DbHubT4ReplicaStop -Context $Context -Tags $Tags -T4Outcome $t4Outcome -WaitMinutes (Get-DbHubT4WaitMinute -Settings $settings)
        $replicaText = Get-DbHubT4ReplicaStopText -Outcome $replica
        if ($replica.Outcome -eq 'Failed') {
            $failed.Add($replicaText)
        }
        elseif ($replicaText) {
            $done.Add($replicaText)
        }
    }
    if ($session -and $busy.By -eq 'session') {
        # The session's busy marker ends with it, so the nightly stop goes on as usual (2026-11-14).
        $cleared = Set-DbHubResourceGroupTag -Context $Context -Tags @{ DbHubBusyUntilUtc = ''; DbHubBusyBy = '' }
        if ($cleared.Ok) {
            $done.Add('busy marker cleared')
        }
        else {
            Write-DbHubLog -Context $Context -Message ('The session''s busy marker wasn''t cleared ({0}); it expires by itself at {1:yyyy-MM-dd HH:mm} UTC.' -f $cleared.Error, $busy.UntilUtc)
        }
    }
    return [pscustomobject]@{ Done = $done.ToArray(); Failed = $failed.ToArray(); MetricsStatus = $metricsStatus; MetricsMessage = $metricsMessage; MetricsVersion = $metricsVersion; T5Status = $t5Status; Rca = $rca }
}

function Get-DbHubLastShutdownUtc {
    # The VMs' latest scheduled auto-shutdown at or before NowUtc, in UTC: the time the nightly safety stop is scheduled
    # for (ADR 0024), from autoShutdownTime (HHmm) and autoShutdownTimeZone, as Get-DbHubNextShutdownUtc reads them.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [Parameter(Mandatory = $true)]
        [datetime] $NowUtc
    )

    $time = [string]$Settings.autoShutdownTime
    if ($time -notmatch '^([01]\d|2[0-3])([0-5]\d)$') {
        throw ('autoShutdownTime ''{0}'' isn''t HHmm.' -f $time)
    }
    $hour = [int]$Matches[1]
    $minute = [int]$Matches[2]
    $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById([string]$Settings.autoShutdownTimeZone)
    $local = [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::SpecifyKind($NowUtc, [System.DateTimeKind]::Utc), $zone)
    $candidate = New-Object -TypeName DateTime -ArgumentList $local.Year, $local.Month, $local.Day, $hour, $minute, 0, ([System.DateTimeKind]::Unspecified)
    if ($candidate -gt $local) {
        $candidate = $candidate.AddDays(-1)
    }
    if ($zone.IsInvalidTime($candidate)) {
        $candidate = $candidate.AddHours(1)
    }
    return [System.TimeZoneInfo]::ConvertTimeToUtc($candidate, $zone)
}

function Send-DbHubVmDeallocate {
    <#
    .SYNOPSIS
    The nightly safety stop's deallocation of one VM (ADR 0024): POST deallocate, without waiting. Its DevTest Labs
    auto-shutdown runs at the same minute, and Azure answers 409 Conflict while that operation runs, so after a 409 the
    VM's state is read again: deallocating or deallocated counts as done, and otherwise the request goes again, at most
    Attempts times, RetrySeconds apart. Returns Outcome (Sent, AlreadyStopping, or Failed), State, and Error.
    https://learn.microsoft.com/rest/api/compute/virtual-machines/deallocate
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName,

        [int] $Attempts = 3,

        [int] $RetrySeconds = 30
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Compute/virtualMachines'
    $path = '{0}/providers/Microsoft.Compute/virtualMachines/{1}/deallocate' -f (Get-DbHubDemoPath -Settings $Context.Settings), $VmName
    $errorText = ''
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $sent = Invoke-DbHubArm -Context $Context -Method POST -Path $path -ApiVersion $version
        if ($sent.StatusCode -in 200, 202) {
            Write-DbHubLog -Context $Context -Message ('{0}: deallocate accepted.' -f $VmName)
            return [pscustomobject]@{ Outcome = 'Sent'; State = ''; Error = '' }
        }
        $errorText = $sent.Error
        if ($sent.StatusCode -ne 409) {
            break
        }
        $state = Get-DbHubVmState -Context $Context -VmName $VmName
        if ($state -in 'deallocating', 'deallocated') {
            Write-DbHubLog -Context $Context -Message ('{0}: already {1}; another operation, such as its auto-shutdown, holds it.' -f $VmName, $state)
            return [pscustomobject]@{ Outcome = 'AlreadyStopping'; State = $state; Error = '' }
        }
        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds $RetrySeconds
        }
    }
    Write-DbHubLog -Context $Context -Message ('{0}: deallocate failed: {1}' -f $VmName, $errorText)
    return [pscustomobject]@{ Outcome = 'Failed'; State = ''; Error = $errorText }
}

function Invoke-DbHubT4NightlyStop {
    <#
    .SYNOPSIS
    The nightly safety stop's T4 part (ADR 0024): stops T4 when it's Ready. One that's starting (Azure starts a stopped
    flexible server again on its own after 7 days), updating, restarting, or provisioning is read again every
    PollSeconds for up to WaitMinutes, because Azure stops only a Ready server; one that's stopped, stopping, missing,
    disabled, or dropping is left alone. It never starts T4. Returns Outcome (Sent, AlreadyStopped, Missing, Skipped, or
    Failed), Name, State (as first read), Current (as last read), and Error.
    https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [int] $WaitMinutes = 10,

        [int] $PollSeconds = 30
    )

    $giveUp = (Get-DbHubUtcNow).AddMinutes($WaitMinutes)
    $transitional = @('Starting', 'Updating', 'Restarting', 'Provisioning')
    $first = ''
    $errorText = ''
    while ($true) {
        $t4 = Get-DbHubT4 -Context $Context -Tags $Tags
        if (-not $first) {
            $first = [string]$t4.State
        }
        $outcome = [pscustomobject]@{ Outcome = ''; Name = [string]$t4.Name; State = $first; Current = [string]$t4.State; Error = '' }
        if ($t4.State -eq 'Ready') {
            $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.DBforPostgreSQL/flexibleServers'
            $sent = Invoke-DbHubArm -Context $Context -Method POST -Path ('{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{1}/stop' -f (Get-DbHubDemoPath -Settings $Context.Settings), $t4.Name) -ApiVersion $version
            if ($sent.StatusCode -in 200, 202) {
                Write-DbHubLog -Context $Context -Message ('{0}: stop accepted.' -f $t4.Name)
                $outcome.Outcome = 'Sent'
                return $outcome
            }
            # A server that's busy with another operation, or no longer Ready, refuses the stop (ServerIsNotReady,
            # SeverBusyWithOtherOperation): read it again while there's time.
            $errorText = $sent.Error
            if ($sent.StatusCode -in 400, 409 -and (Get-DbHubUtcNow) -lt $giveUp) {
                Start-Sleep -Seconds $PollSeconds
                continue
            }
            Write-DbHubLog -Context $Context -Message ('{0}: stop failed: {1}' -f $t4.Name, $errorText)
            $outcome.Outcome = 'Failed'
            $outcome.Error = $errorText
            return $outcome
        }
        if ($t4.State -in 'Stopped', 'Stopping') {
            $outcome.Outcome = 'AlreadyStopped'
            return $outcome
        }
        if ($t4.State -eq 'Missing') {
            $outcome.Outcome = 'Missing'
            return $outcome
        }
        if ($t4.State -in 'Disabled', 'Dropping') {
            $outcome.Outcome = 'Skipped'
            return $outcome
        }
        if ($t4.State -in $transitional -and (Get-DbHubUtcNow) -lt $giveUp) {
            Start-Sleep -Seconds $PollSeconds
            continue
        }
        if ($t4.State -in $transitional) {
            $errorText = 'it was still {0} after {1} minutes; tomorrow''s safety stop tries again' -f $t4.State, $WaitMinutes
        }
        elseif (-not $errorText) {
            $errorText = 'its state is {0}' -f $(if ($t4.State) { $t4.State } else { 'Unknown' })
        }
        Write-DbHubLog -Context $Context -Message ('T4: not stopped: {0}.' -f $errorText)
        $outcome.Outcome = 'Failed'
        $outcome.Error = $errorText
        return $outcome
    }
}

function Invoke-DbHubNightlyStop {
    <#
    .SYNOPSIS
    The nightly safety stop (ADR 0024), DbHub-Stop -Scope Nightly at the VMs' auto-shutdown time: deallocates each demo
    VM that isn't deallocated (a VM stopped from inside the guest still bills its compute), and stops T4 when it runs
    (Invoke-DbHubT4NightlyStop). The T2 guest shuts down with its host. Azure Resource Manager only: it never starts anything,
    never uses Run Command, never connects to a database, and never touches the control's schedules. T5's container
    (2026-11-19, ADR 0027) goes after them, when its lifecycle is Session (Remove-DbHubT5Container, with the safety stop's
    containers/read and containers/delete): a session that ended without its stop doesn't leave its throughput billing all
    night; otherwise it's kept, and the result says why. Returns Done, Failed, Vms (each VM's outcome), T4 (its outcome),
    Replica, and T5 (what happened to T5's container).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [int] $PollSeconds = 30
    )

    $settings = $Context.Settings
    $done = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $failed = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $vms = [ordered]@{}
    foreach ($vm in @([string]$settings.sqlVmName, [string]$settings.hostVmName)) {
        $state = Get-DbHubVmState -Context $Context -VmName $vm
        if ($state -eq 'Missing') {
            $vms[$vm] = 'missing'
            $done.Add(('{0} missing' -f $vm))
            continue
        }
        if ($state -in 'deallocated', 'deallocating') {
            $vms[$vm] = 'already {0}' -f $state
            $done.Add(('{0} {1}' -f $vm, $vms[$vm]))
            continue
        }
        $sent = Send-DbHubVmDeallocate -Context $Context -VmName $vm -RetrySeconds $PollSeconds
        if ($sent.Outcome -eq 'Sent') {
            $vms[$vm] = 'deallocated (was {0})' -f $state
            $done.Add(('{0} {1}' -f $vm, $vms[$vm]))
        }
        elseif ($sent.Outcome -eq 'AlreadyStopping') {
            $vms[$vm] = 'already {0} (its auto-shutdown)' -f $sent.State
            $done.Add(('{0} {1}' -f $vm, $vms[$vm]))
        }
        else {
            $vms[$vm] = 'failed: {0}' -f $sent.Error
            $failed.Add(('{0} ({1})' -f $vm, $sent.Error))
        }
    }
    $t4 = Invoke-DbHubT4NightlyStop -Context $Context -Tags $Tags -WaitMinutes (Get-DbHubT4WaitMinute -Settings $settings) -PollSeconds $PollSeconds
    $t4Text = Get-DbHubT4StopText -Outcome $t4
    if ($t4.Outcome -eq 'Failed') {
        $failed.Add(('T4 ({0})' -f $t4.Error))
    }
    else {
        $done.Add($t4Text)
    }
    # T4's read replica, when a session left it behind (ADR 0025): stopped once T4 is.
    $replica = Invoke-DbHubT4ReplicaStop -Context $Context -Tags $Tags -T4Outcome $t4.Outcome -WaitMinutes (Get-DbHubT4WaitMinute -Settings $settings) -PollSeconds $PollSeconds
    $replicaText = Get-DbHubT4ReplicaStopText -Outcome $replica
    if ($replica.Outcome -eq 'Failed') {
        $failed.Add($replicaText)
    }
    elseif ($replicaText) {
        $done.Add($replicaText)
    }
    # T5's container (2026-11-19, ADR 0027), when a session's stop didn't delete it. Only while sqlvm01, whose runner drives T5,
    # is still on its way down (review of ab91ee5): this pass read the busy marker once, at its start, and a session started
    # since then uses the container. Its outcome is apart from the job's status (t5Status), so a container this role can't
    # delete never makes the stop of the VMs and T4 look failed, which the cost check of T4's restart reads (R910).
    $t5Status = ''
    $t5Text = ''
    if ((Get-DbHubT5Lifecycle -Tags $Tags) -eq 'Session' -and (Get-DbHubT5ContainerPath -Settings $settings -Tags $Tags)) {
        $sqlState = Get-DbHubVmState -Context $Context -VmName ([string]$settings.sqlVmName)
        if ($sqlState -notin 'deallocated', 'deallocating', 'stopped', 'Missing') {
            $t5Status = 'InUse'
            $t5Text = 'T5''s container left alone: {0} is {1}, so a session may use it' -f $settings.sqlVmName, $sqlState
            Write-DbHubLog -Context $Context -Message $t5Text
        }
    }
    if (-not $t5Status) {
        $t5 = Remove-DbHubT5Container -Context $Context -Tags $Tags
        $t5Status = [string]$t5.Outcome
        $t5Text = Get-DbHubT5ContainerText -Outcome $t5
    }
    if ($t5Text) {
        $done.Add($t5Text)
    }
    return [pscustomobject]@{ Done = $done.ToArray(); Failed = $failed.ToArray(); Vms = $vms; T4 = $t4Text; Replica = $replicaText; T5 = $t5Text; T5Status = $t5Status }
}

function Get-DbHubT4WaitMinute {
    # How long the safety stop waits for a T4 that's starting: t4WaitMinutes, 10 without it.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    $configured = Get-DbHubMember -InputObject $Settings -Name 't4WaitMinutes'
    if ($null -ne $configured) {
        return [int]$configured
    }
    return 10
}

function Get-DbHubT4StopText {
    # What the safety stop says it did to T4, from Invoke-DbHubT4NightlyStop's outcome: 'T4 stopped (was Ready)', 'T4
    # already stopped', 'T4 missing', 'T4 disabled', or 'failed: <why>'.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Outcome
    )

    switch ($Outcome.Outcome) {
        'Sent' { return ('T4 stopped (was {0})' -f $Outcome.State) }
        'AlreadyStopped' { return ('T4 already {0}' -f $Outcome.Current.ToLowerInvariant()) }
        'Missing' { return 'T4 missing' }
        'Skipped' { return ('T4 {0}' -f $Outcome.Current.ToLowerInvariant()) }
    }
    return ('failed: {0}' -f $Outcome.Error)
}

function Get-DbHubT4Replica {
    # T4's read replica, <t4ReplicaPrefix><deploymentId> (ADR 0025), which start-demo.ps1 creates for each session and
    # stop-demo.ps1 deletes: Name and State (Ready, Stopped, Starting, Stopping, Dropping, ...), or State Missing (none,
    # as between sessions), Unknown, or NotConfigured (settings without t4ReplicaPrefix).
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $prefix = [string](Get-DbHubMember -InputObject $Context.Settings -Name 't4ReplicaPrefix')
    if (-not $prefix) {
        return [pscustomobject]@{ Name = ''; State = 'NotConfigured' }
    }
    $deploymentId = [string](Get-DbHubMember -InputObject $Tags -Name 'deploymentId')
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        return [pscustomobject]@{ Name = ''; State = 'Unknown' }
    }
    $name = '{0}{1}' -f $prefix, $deploymentId
    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.DBforPostgreSQL/flexibleServers'
    $read = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{1}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $name) -ApiVersion $version
    if ($read.StatusCode -eq 404) {
        return [pscustomobject]@{ Name = $name; State = 'Missing' }
    }
    if ($read.StatusCode -ne 200) {
        return [pscustomobject]@{ Name = $name; State = 'Unknown' }
    }
    return [pscustomobject]@{ Name = $name; State = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $read.Body -Name 'properties') -Name 'state') }
}

function Invoke-DbHubT4ReplicaStop {
    <#
    .SYNOPSIS
    Stops T4's read replica when a session left it behind (ADR 0025): start-demo.ps1 creates it and stop-demo.ps1 deletes
    it, so outside a session it's there only when a session ended without stop-demo.ps1. Azure stops a replica only after
    its primary is stopped (SourceReplicasStartStopOrder, live 2026-11-13), so this waits for T4 to be stopped, reading
    both every PollSeconds for up to WaitMinutes; with -T4Outcome Failed (T4's stop failed) it doesn't wait. A replica that's
    stopped, stopping, being deleted, or missing is left alone, and nothing is started or deleted. Returns Outcome (Sent,
    AlreadyStopped, Missing, Skipped, NotConfigured, or Failed), Name, State (as last read), and Error.
    https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [string] $T4Outcome = '',

        [int] $WaitMinutes = 10,

        [int] $PollSeconds = 30
    )

    $giveUp = (Get-DbHubUtcNow).AddMinutes($WaitMinutes)
    $errorText = ''
    while ($true) {
        $replica = Get-DbHubT4Replica -Context $Context -Tags $Tags
        $outcome = [pscustomobject]@{ Outcome = ''; Name = [string]$replica.Name; State = [string]$replica.State; Error = '' }
        if ($replica.State -in 'NotConfigured', 'Missing') {
            $outcome.Outcome = $replica.State
            return $outcome
        }
        if ($replica.State -in 'Stopped', 'Stopping') {
            $outcome.Outcome = 'AlreadyStopped'
            return $outcome
        }
        if ($replica.State -in 'Dropping', 'Disabled') {
            $outcome.Outcome = 'Skipped'
            return $outcome
        }
        if ($T4Outcome -eq 'Failed') {
            $outcome.Outcome = 'Failed'
            $outcome.Error = 'T4 wasn''t stopped, and Azure stops a read replica only after its primary'
            return $outcome
        }
        $t4 = Get-DbHubT4 -Context $Context -Tags $Tags
        if ($replica.State -eq 'Ready' -and $t4.State -in 'Stopped', 'Missing') {
            $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.DBforPostgreSQL/flexibleServers'
            $sent = Invoke-DbHubArm -Context $Context -Method POST -Path ('{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{1}/stop' -f (Get-DbHubDemoPath -Settings $Context.Settings), $replica.Name) -ApiVersion $version
            if ($sent.StatusCode -in 200, 202) {
                Write-DbHubLog -Context $Context -Message ('{0}: stop accepted (T4''s read replica, left from a session).' -f $replica.Name)
                $outcome.Outcome = 'Sent'
                return $outcome
            }
            $errorText = $sent.Error
            if ($sent.StatusCode -notin 400, 409) {
                $outcome.Outcome = 'Failed'
                $outcome.Error = $errorText
                return $outcome
            }
        }
        if ((Get-DbHubUtcNow) -ge $giveUp) {
            $outcome.Outcome = 'Failed'
            $outcome.Error = if ($errorText) { $errorText } else { 'it was {0} and T4 {1} after {2} minutes, and Azure stops a read replica only after its primary is stopped; the next safety stop tries again' -f $replica.State, $t4.State, $WaitMinutes }
            Write-DbHubLog -Context $Context -Message ('{0}: not stopped: {1}.' -f $replica.Name, $outcome.Error)
            return $outcome
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-DbHubT4ReplicaStopText {
    # What a stop says about T4's read replica, from Invoke-DbHubT4ReplicaStop's outcome, in plain words: nothing when
    # there's none (between sessions); otherwise that a session left it behind, what that bills, and the fix.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Outcome
    )

    switch ($Outcome.Outcome) {
        'Sent' { return ('T4''s read replica {0} stopped (a session left it behind without stop-demo.ps1; stopped it still bills its storage and Defender plans until ./scripts/stop-demo.ps1 deletes it)' -f $Outcome.Name) }
        'AlreadyStopped' { return ('T4''s read replica {0} already {1} (a session left it behind; ./scripts/stop-demo.ps1 deletes it)' -f $Outcome.Name, $Outcome.State.ToLowerInvariant()) }
        'Skipped' { return ('T4''s read replica {0} {1}' -f $Outcome.Name, $Outcome.State.ToLowerInvariant()) }
        { $_ -in 'Missing', 'NotConfigured' } { return '' }
    }
    return ('T4''s read replica {0} (a session left it behind) not stopped: {1}; ./scripts/stop-demo.ps1 deletes it' -f $Outcome.Name, $Outcome.Error)
}

function Invoke-DbHubT4ReplicaStartFirst {
    <#
    .SYNOPSIS
    Before a run starts a stopped T4: Azure starts a primary only once its replicas are Ready (SourceReplicasStartStopOrder,
    live 2026-11-13), so a stopped replica that a session left behind is started first and waited for, up to WaitMinutes.
    The control never creates a replica (it can't create servers); without one, Outcome is Missing, and the run says
    plainly that its replica beat isn't available. Returns Outcome (Missing, NotConfigured, Ready, Started, or Failed), Name,
    State, and Error.
    https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [int] $WaitMinutes = 10,

        [int] $PollSeconds = 20
    )

    $replica = Get-DbHubT4Replica -Context $Context -Tags $Tags
    $outcome = [pscustomobject]@{ Outcome = ''; Name = [string]$replica.Name; State = [string]$replica.State; Error = '' }
    if ($replica.State -in 'NotConfigured', 'Missing') {
        $outcome.Outcome = $replica.State
        return $outcome
    }
    if ($replica.State -eq 'Ready') {
        $outcome.Outcome = 'Ready'
        return $outcome
    }
    if ($replica.State -eq 'Stopped' -and -not (Invoke-DbHubT4Action -Context $Context -Name $replica.Name -Action start)) {
        $outcome.Outcome = 'Failed'
        $outcome.Error = 'Azure didn''t accept its start'
        return $outcome
    }
    $giveUp = (Get-DbHubUtcNow).AddMinutes($WaitMinutes)
    while ((Get-DbHubUtcNow) -lt $giveUp) {
        Start-Sleep -Seconds $PollSeconds
        $replica = Get-DbHubT4Replica -Context $Context -Tags $Tags
        $outcome.State = [string]$replica.State
        if ($replica.State -eq 'Ready') {
            $outcome.Outcome = 'Started'
            return $outcome
        }
        if ($replica.State -in 'Missing', 'Dropping') {
            $outcome.Outcome = 'Missing'
            return $outcome
        }
    }
    $outcome.Outcome = 'Failed'
    $outcome.Error = 'it was still {0} after {1} minutes' -f $outcome.State, $WaitMinutes
    return $outcome
}

function Get-DbHubT4ReplicaRunNote {
    # What an on-demand run says about T4's read replica (ADR 0025), plainly, when its replica beat isn't available: the
    # control doesn't create the replica, so Database Hub's Read replica lag stays empty and the replica-lag scenario
    # can't run, and start-demo.ps1 is how to get it. Empty when the replica is there, or settings predate it.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Outcome
    )

    switch ($Outcome.Outcome) {
        'Missing' { return ('T4''s read replica isn''t there: on-demand runs don''t create it, so Database Hub''s Read replica lag stays empty and the replica-lag scenario can''t run in this run. For that beat, start the demo with ./scripts/start-demo.ps1, which creates the replica (about 9 minutes), and stop it with ./scripts/stop-demo.ps1, which deletes it.') }
        'Failed' { return ('T4''s read replica {0} couldn''t be started ({1}), and Azure starts T4 only after its replicas, so T4 sits this run out. ./scripts/stop-demo.ps1 deletes the replica; ./scripts/start-demo.ps1 then creates a new one.' -f $Outcome.Name, $Outcome.Error) }
    }
    return ''
}

function Get-DbHubT3Database {
    <#
    .SYNOPSIS
    T3's database (<t3ServerPrefix><deploymentId>/<demoDatabase>) through Azure Resource Manager only (Databases - Get):
    the way Learn monitors a serverless database's pause status. It never connects to the database, so it never resumes
    it. Returns State (Present, Missing, or Unknown), Name, Status (Online, Paused, Pausing, Resuming, ...),
    AutoPauseDelay (minutes, -1 when auto-pause is off, or $null), and Error.
    https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-monitor#monitor-pause-and-resume-status
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $deploymentId = [string](Get-DbHubMember -InputObject $Tags -Name 'deploymentId')
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        return [pscustomobject]@{ State = 'Unknown'; Name = ''; Status = ''; AutoPauseDelay = $null; Error = 'the demo resource group has no deploymentId tag' }
    }
    $name = '{0}{1}/{2}' -f $Context.Settings.t3ServerPrefix, $deploymentId, $Context.Settings.demoDatabase
    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Sql/servers/databases'
    $path = '{0}/providers/Microsoft.Sql/servers/{1}{2}/databases/{3}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $Context.Settings.t3ServerPrefix, $deploymentId, $Context.Settings.demoDatabase
    $read = Invoke-DbHubArm -Context $Context -Method GET -Path $path -ApiVersion $version
    if ($read.StatusCode -eq 404) {
        return [pscustomobject]@{ State = 'Missing'; Name = $name; Status = ''; AutoPauseDelay = $null; Error = '' }
    }
    if ($read.StatusCode -ne 200) {
        return [pscustomobject]@{ State = 'Unknown'; Name = $name; Status = ''; AutoPauseDelay = $null; Error = $read.Error }
    }
    $properties = Get-DbHubMember -InputObject $read.Body -Name 'properties'
    $delay = Get-DbHubMember -InputObject $properties -Name 'autoPauseDelay'
    if ($null -ne $delay) {
        $delay = [int]$delay
    }
    return [pscustomobject]@{ State = 'Present'; Name = $name; Status = [string](Get-DbHubMember -InputObject $properties -Name 'status'); AutoPauseDelay = $delay; Error = '' }
}

function Test-DbHubT3Paused {
    <#
    .SYNOPSIS
    The T3 part of the nightly safety stop's T3 check (ADR 0024), DbHub-Stop -Scope T3Check (Invoke-DbHubT3Check), its
    own short job after the stop. Azure has no "pause now" for a serverless database: it pauses itself once it has had
    no session and no CPU for its auto-pause delay, so this only reads T3's status (Get-DbHubT3Database) and says what it
    found. t3: Paused, Pausing, Missing (T3 isn't deployed), AutoPauseOff (its delay is -1), TooEarly (online before the
    delay since the stop, plus t3CheckMarginMinutes, has passed), Awake (online after it: a session or a feature keeps it
    awake), or Unread.
    https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $settings = $Context.Settings
    $database = Get-DbHubT3Database -Context $Context -Tags $Tags
    $since = [int][System.Math]::Floor(($Context.NowUtc - (Get-DbHubLastShutdownUtc -Settings $settings -NowUtc $Context.NowUtc)).TotalMinutes)
    $margin = 10
    $configured = Get-DbHubMember -InputObject $settings -Name 't3CheckMarginMinutes'
    if ($null -ne $configured) {
        $margin = [int]$configured
    }
    $delay = $database.AutoPauseDelay
    $verdict = 'Unread'
    $message = 'T3''s status couldn''t be read: {0}.' -f $database.Error
    if ($database.State -eq 'Missing') {
        $verdict = 'Missing'
        $message = 'T3 ({0}) doesn''t exist (stop-demo.ps1 -RemoveT3 removed it, or it isn''t deployed), so it bills no compute.' -f $database.Name
    }
    elseif ($database.State -eq 'Present') {
        $what = 'T3 ({0}) is {1}, {2} minutes after the safety stop' -f $database.Name, $database.Status, $since
        if ($database.Status -eq 'Paused') {
            $verdict = 'Paused'
            $message = $what + ': it bills no compute until something connects.'
        }
        elseif ($database.Status -eq 'Pausing') {
            $verdict = 'Pausing'
            $message = $what + ': its auto-pause has begun.'
        }
        elseif ($null -ne $delay -and $delay -eq -1) {
            $verdict = 'AutoPauseOff'
            $message = $what + ': its auto-pause is off (delay -1), so it stays online and bills at least its minimum vCores. Set t3AutoPauseMinutes and run deploy.ps1 -FromStage Infrastructure.'
        }
        elseif ($null -ne $delay -and $since -lt ($delay + $margin)) {
            $verdict = 'TooEarly'
            $message = $what + (': its {0}-minute auto-pause delay, plus {1} minutes, hasn''t passed yet.' -f $delay, $margin)
        }
        else {
            $verdict = 'Awake'
            $delayText = 'its auto-pause delay'
            if ($null -ne $delay) {
                $delayText = 'its {0}-minute auto-pause delay' -f $delay
            }
            $message = $what + (', past {0}: a session or a feature keeps it awake. The activity log''s Resume Databases events name what resumed it.' -f $delayText)
        }
    }
    Write-DbHubLog -Context $Context -Message $message
    $status = 'Checked'
    if ($verdict -eq 'Unread') {
        $status = 'Partial'
    }
    return [pscustomobject]@{ action = 'check-t3'; status = $status; t3 = $verdict; t3Status = $database.Status; autoPauseDelay = $delay; minutesSinceStop = $since; message = $message }
}

function Invoke-DbHubT3Check {
    <#
    .SYNOPSIS
    DbHub-Stop -Scope T3Check, the nightly safety stop's check after its stop (ADR 0024): reads T3's status
    (Test-DbHubT3Paused), then stops T4 when it runs, as the stop does (Invoke-DbHubT4NightlyStop). Returns check-t3's
    result with t4, what happened to T4, and failed; Partial when T3 couldn't be read or T4 couldn't be stopped.

    .DESCRIPTION
    Azure starts a stopped flexible server again 7 days after its stop. The stop's own T4 stop ends a minute or two after
    its time, so a week later that restart comes just after the stop, which finds T4 still stopped, and T4 would run
    until the next evening (live: the stop of 2026-11-07 00:01Z ended at 00:03Z, so status.ps1 puts the restart at
    2026-11-14 00:03Z, 3 minutes after that evening's stop). Since 2026-11-09 the check stops it that evening. Azure
    Resource Manager only: T3 is only read, which never wakes it, and nothing is started.
    https://learn.microsoft.com/azure/postgresql/configure-maintain/how-to-stop-server
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [int] $PollSeconds = 30
    )

    $check = Test-DbHubT3Paused -Context $Context -Tags $Tags
    $t4 = Invoke-DbHubT4NightlyStop -Context $Context -Tags $Tags -WaitMinutes (Get-DbHubT4WaitMinute -Settings $Context.Settings) -PollSeconds $PollSeconds
    $t4Text = Get-DbHubT4StopText -Outcome $t4
    $status = $check.status
    $failed = @()
    $sentence = $t4Text
    if ($t4.Outcome -eq 'Failed') {
        $status = 'Partial'
        $failed = @(('T4 ({0})' -f $t4.Error))
        $sentence = 'T4 couldn''t be stopped: {0}' -f $t4.Error
    }
    # T4's read replica, when a session left it behind (ADR 0025): stopped once T4 is.
    $replica = Invoke-DbHubT4ReplicaStop -Context $Context -Tags $Tags -T4Outcome $t4.Outcome -WaitMinutes (Get-DbHubT4WaitMinute -Settings $Context.Settings) -PollSeconds $PollSeconds
    $replicaText = Get-DbHubT4ReplicaStopText -Outcome $replica
    if ($replica.Outcome -eq 'Failed') {
        $status = 'Partial'
        $failed = @($failed) + @($replicaText)
    }
    if ($replicaText) {
        $sentence = '{0}; {1}' -f $sentence, $replicaText
    }
    return [pscustomobject]@{ action = 'check-t3'; status = $status; t3 = $check.t3; t3Status = $check.t3Status; autoPauseDelay = $check.autoPauseDelay; minutesSinceStop = $check.minutesSinceStop; message = ('{0} {1}.' -f $check.message, $sentence); t4 = $t4Text; replica = $replicaText; failed = $failed }
}

function Get-DbHubRequester {
    # What the runner records as requested-by: the request's name and the job's first 8 characters.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $RequestedBy
    )

    $job = 'job'
    if ($Context.JobId) {
        $job = $Context.JobId.Substring(0, [System.Math]::Min(8, $Context.JobId.Length))
    }
    return ('{0}/{1}' -f $RequestedBy, $job)
}

function Get-DbHubTargetVm {
    # The VM whose runner drives a target: archost01 relays T2 into its guest; sqlvm01 drives T1, T3, T4, and T5.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [Parameter(Mandatory = $true)]
        [string] $Target
    )

    if ($Target -eq 'T2') {
        return [string]$Settings.hostVmName
    }
    return [string]$Settings.sqlVmName
}

function Get-DbHubT5Account {
    # T5's Azure Cosmos DB account, <t5AccountPrefix><deploymentId> (2026-11-18, ADR 0027), or '' when the settings don't
    # name T5 (it's off, or they predate it) or the demo resource group has no deploymentId tag.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [AllowNull()]
        [object] $Tags
    )

    $prefix = [string](Get-DbHubMember -InputObject $Settings -Name 't5AccountPrefix')
    $deploymentId = [string](Get-DbHubMember -InputObject $Tags -Name 'deploymentId')
    if ($prefix -notmatch '^[a-z0-9][a-z0-9-]{0,30}$' -or $deploymentId -notmatch '^[a-z0-9]{6}$') {
        return ''
    }
    return ('{0}{1}' -f $prefix, $deploymentId)
}

function Get-DbHubT5Lifecycle {
    # T5's container lifecycle (2026-11-19, ADR 0027), from the demo resource group's DbHubT5Container tag, which the
    # operator side sets (deploy.ps1, grant-safety-stop.ps1, start-demo.ps1, and stop-demo.ps1): Session once the session
    # control's custom role has the container's actions and is assigned at the demo resource group, so a stop may delete the
    # container and the next session creates it again; AlwaysOn while it can't; '' without the tag (an environment deployed
    # before 2026-11-19) or with any other value. Exact, case-sensitive values. Pure.
    param(
        [AllowNull()]
        [object] $Tags
    )

    $value = [string](Get-DbHubMember -InputObject $Tags -Name 'DbHubT5Container')
    if ($value -ceq 'Session' -or $value -ceq 'AlwaysOn') {
        return $value
    }
    return ''
}

function Get-DbHubT5ContainerSetting {
    # The settings' t5Container part (2026-11-19, ADR 0027), config/versions.json's definition of T5's container: Database,
    # Container, PartitionKeyPath, PartitionKeyVersion, Throughput (0 when the settings don't say), IndexingPolicy, and
    # ApiVersion (Microsoft.DocumentDB/databaseAccounts'); $null without it (T5 is off, or the settings predate it) or
    # without that API version. Pure.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    $part = Get-DbHubMember -InputObject $Settings -Name 't5Container'
    $database = [string](Get-DbHubMember -InputObject $part -Name 'databaseName')
    $container = [string](Get-DbHubMember -InputObject $part -Name 'containerName')
    $version = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $Settings -Name 'apiVersions') -Name 'Microsoft.DocumentDB/databaseAccounts')
    $pattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'
    if ($database -notmatch $pattern -or $container -notmatch $pattern -or $version -notmatch '^\d{4}-\d{2}-\d{2}(-preview)?$') {
        return $null
    }
    $keyVersion = [int](Get-DbHubMember -InputObject $part -Name 'partitionKeyVersion')
    if ($keyVersion -le 0) {
        $keyVersion = 2
    }
    return [pscustomobject]@{
        Database            = $database
        Container           = $container
        PartitionKeyPath    = [string](Get-DbHubMember -InputObject $part -Name 'partitionKeyPath')
        PartitionKeyVersion = $keyVersion
        Throughput          = [int](Get-DbHubMember -InputObject $part -Name 'throughput')
        IndexingPolicy      = Get-DbHubMember -InputObject $part -Name 'indexingPolicy'
        ApiVersion          = $version
    }
}

function Get-DbHubT5ContainerPath {
    # T5's container's Azure Resource Manager path (2026-11-19, ADR 0027): the demo resource group's
    # Microsoft.DocumentDB/databaseAccounts/<account>/sqlDatabases/<database>/containers/<container>, or '' when T5 isn't
    # configured: the settings name no account or container (T5 is off, or they predate it), or the group has no
    # deploymentId tag. Pure.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [AllowNull()]
        [object] $Tags
    )

    $account = Get-DbHubT5Account -Settings $Settings -Tags $Tags
    $part = Get-DbHubT5ContainerSetting -Settings $Settings
    if (-not $account -or $null -eq $part) {
        return ''
    }
    return ('{0}/providers/Microsoft.DocumentDB/databaseAccounts/{1}/sqlDatabases/{2}/containers/{3}' -f (Get-DbHubDemoPath -Settings $Settings), $account, $part.Database, $part.Container)
}

function Get-DbHubT5Container {
    # T5's container through Azure Resource Manager (2026-11-19, ADR 0027; Sql Resources - Get Sql Container, with the
    # identity's containers/read): State Present, Missing (404, also when its account or database isn't there), NotGranted
    # (403), Unknown (anything else), or NotConfigured (Get-DbHubT5ContainerPath); Name (<database>/<container>); and Error.
    # https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/get-sql-container
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $path = Get-DbHubT5ContainerPath -Settings $Context.Settings -Tags $Tags
    if (-not $path) {
        return [pscustomobject]@{ State = 'NotConfigured'; Name = ''; Error = '' }
    }
    $part = Get-DbHubT5ContainerSetting -Settings $Context.Settings
    $read = Invoke-DbHubArm -Context $Context -Method GET -Path $path -ApiVersion $part.ApiVersion
    $state = 'Unknown'
    $errorText = [string]$read.Error
    if ($read.StatusCode -eq 200) {
        $state = 'Present'
        $errorText = ''
    }
    elseif ($read.StatusCode -eq 404) {
        $state = 'Missing'
        $errorText = ''
    }
    elseif ($read.StatusCode -eq 403 -or $errorText -match 'AuthorizationFailed') {
        $state = 'NotGranted'
    }
    return [pscustomobject]@{ State = $state; Name = ('{0}/{1}' -f $part.Database, $part.Container); Error = $errorText }
}

function Get-DbHubT5ContainerBody {
    <#
    .SYNOPSIS
    The body that creates T5's container (2026-11-19, ADR 0027; Sql Resources - Create Update Sql Container): the settings'
    t5Container, config/versions.json's definition (its id, hash partition key and version, indexing policy, and manual
    throughput in options), as infra/modules/cosmos01.bicep creates it, and the demo's own tags from the demo resource
    group's (Tags), as cosmos01.bicep tags it: a tenant's tag policy can refuse an untagged resource. Never component, and
    never the group's state tags. $null when T5 isn't configured. Pure.
    https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/create-update-sql-container
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [AllowNull()]
        [object] $Tags
    )

    $part = Get-DbHubT5ContainerSetting -Settings $Settings
    if ($null -eq $part) {
        return $null
    }
    $containerTags = [ordered]@{}
    foreach ($key in 'solution', 'environment', 'owner', 'purpose', 'costCenter', 'autoShutdown', 'deploymentId', 'expiresOn') {
        $value = [string](Get-DbHubMember -InputObject $Tags -Name $key)
        if ($value) {
            $containerTags[$key] = $value
        }
    }
    $resource = [ordered]@{ id = $part.Container; partitionKey = [ordered]@{ paths = @($part.PartitionKeyPath); kind = 'Hash'; version = $part.PartitionKeyVersion } }
    if ($null -ne $part.IndexingPolicy) {
        $resource['indexingPolicy'] = $part.IndexingPolicy
    }
    $properties = [ordered]@{ resource = $resource }
    if ($part.Throughput -gt 0) {
        $properties['options'] = [ordered]@{ throughput = $part.Throughput }
    }
    return [ordered]@{ tags = $containerTags; properties = $properties }
}

function Test-DbHubT5Conflict {
    # Whether Azure refused a request on T5's container because another operation on it still runs, as while it deletes the
    # last container of that name (409 or 412, or a message that says so): such a request is asked again. Pure.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Response
    )

    return ([int]$Response.StatusCode -in 409, 412 -or [string]$Response.Error -match '(?i)being deleted|in progress|another operation')
}

function New-DbHubT5Container {
    <#
    .SYNOPSIS
    Makes sure T5's container is there before T5's activity goes out (2026-11-19, ADR 0027). Its provisioned throughput bills
    every hour it exists, and an account has no stop, so once its lifecycle is Session the container exists only during a
    session: a session's start, or a run that sends T5 activity, creates it when it's missing (Sql Resources - Create Update
    Sql Container, with the session control's containers/write) with config/versions.json's definition (the settings'
    t5Container) and the demo's own tags, as infra/modules/cosmos01.bicep creates it. Azure takes the create at once and
    finishes it on its own, so the container's GET is read every PollSeconds until it's there (never the asynchronous
    operation's URL, which is subscription-scoped, outside the role), at most WaitMinutes; a conflict, as while Azure still
    deletes the last container of that name, is asked again until then too. Returns Outcome (Present, Created, NotGranted,
    Failed, or NotConfigured), Name, Throughput, and Error.
    https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/create-update-sql-container
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Start-DbHubActivityRun and Start-DbHubSession, its callers, ask ShouldProcess.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [int] $WaitMinutes = 5,

        [int] $PollSeconds = 10
    )

    $giveUp = (Get-DbHubUtcNow).AddMinutes($WaitMinutes)
    $current = Get-DbHubT5Container -Context $Context -Tags $Tags
    $outcome = [pscustomobject]@{ Outcome = ''; Name = [string]$current.Name; Throughput = 0; Error = '' }
    if ($current.State -eq 'NotConfigured') {
        $outcome.Outcome = 'NotConfigured'
        return $outcome
    }
    $part = Get-DbHubT5ContainerSetting -Settings $Context.Settings
    $outcome.Throughput = $part.Throughput
    if ($current.State -in 'Present', 'NotGranted') {
        $outcome.Outcome = $current.State
        $outcome.Error = $current.Error
        return $outcome
    }
    if ($current.State -ne 'Missing') {
        $outcome.Outcome = 'Failed'
        $outcome.Error = 'it couldn''t be read: {0}' -f $current.Error
        return $outcome
    }
    $body = Get-DbHubT5ContainerBody -Settings $Context.Settings -Tags $Tags
    $path = Get-DbHubT5ContainerPath -Settings $Context.Settings -Tags $Tags
    while ($true) {
        $put = Invoke-DbHubArm -Context $Context -Method PUT -Path $path -ApiVersion $part.ApiVersion -Body $body
        if ($put.StatusCode -in 200, 201, 202) {
            Write-DbHubLog -Context $Context -Message ('T5''s container {0}: creation accepted.' -f $outcome.Name)
            break
        }
        if ($put.StatusCode -eq 403 -or [string]$put.Error -match 'AuthorizationFailed') {
            $outcome.Outcome = 'NotGranted'
            $outcome.Error = $put.Error
            return $outcome
        }
        if (-not (Test-DbHubT5Conflict -Response $put) -or (Get-DbHubUtcNow) -ge $giveUp) {
            Write-DbHubLog -Context $Context -Message ('T5''s container {0}: not created: {1}' -f $outcome.Name, $put.Error)
            $outcome.Outcome = 'Failed'
            $outcome.Error = $put.Error
            return $outcome
        }
        Write-DbHubLog -Context $Context -Message ('T5''s container {0}: Azure doesn''t take its creation yet ({1}); asking again in {2} seconds.' -f $outcome.Name, $put.Error, $PollSeconds)
        Start-Sleep -Seconds $PollSeconds
    }
    while ($true) {
        $read = Get-DbHubT5Container -Context $Context -Tags $Tags
        if ($read.State -eq 'Present') {
            $outcome.Outcome = 'Created'
            return $outcome
        }
        if ((Get-DbHubUtcNow) -ge $giveUp) {
            $outcome.Outcome = 'Failed'
            $outcome.Error = 'it wasn''t there {0} minutes after Azure accepted its creation{1}' -f $WaitMinutes, $(if ($read.Error) { ' ({0})' -f $read.Error } else { '' })
            Write-DbHubLog -Context $Context -Message ('T5''s container {0}: {1}.' -f $outcome.Name, $outcome.Error)
            return $outcome
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Remove-DbHubT5Container {
    <#
    .SYNOPSIS
    Deletes T5's container (2026-11-19, ADR 0027; Sql Resources - Delete Sql Container) and waits until it's gone, at most
    WaitMinutes, so its provisioned throughput doesn't bill between sessions; the account, its database (no throughput of
    its own), its private endpoint, its DNS zone, and T1's data-plane role (scoped to the account) stay. Only when its
    lifecycle is Session (Get-DbHubT5Lifecycle): otherwise nothing is sent, and it's Kept, with Reason, because a session
    must never run without it (the owner's condition). It's read first, so a container that's already gone is told from one
    deleted now, and nothing is written then; a conflict, as while Azure still creates it, is asked again until WaitMinutes
    pass. Returns Outcome (Deleted, Missing, Kept, NotGranted, Failed, or NotConfigured), Name, Throughput, Reason, and
    Error.
    https://learn.microsoft.com/rest/api/cosmos-db-resource-provider/sql-resources/delete-sql-container
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stop-DbHubDemo, Invoke-DbHubNightlyStop, and Invoke-DbHubStop, its callers, are the stop paths; Stop-DbHubDemo asks ShouldProcess.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [int] $WaitMinutes = 5,

        [int] $PollSeconds = 10
    )

    $outcome = [pscustomobject]@{ Outcome = ''; Name = ''; Throughput = 0; Reason = ''; Error = '' }
    $path = Get-DbHubT5ContainerPath -Settings $Context.Settings -Tags $Tags
    if (-not $path) {
        $outcome.Outcome = 'NotConfigured'
        return $outcome
    }
    $part = Get-DbHubT5ContainerSetting -Settings $Context.Settings
    $outcome.Name = '{0}/{1}' -f $part.Database, $part.Container
    $outcome.Throughput = $part.Throughput
    $lifecycle = Get-DbHubT5Lifecycle -Tags $Tags
    if ($lifecycle -ne 'Session') {
        $outcome.Outcome = 'Kept'
        $outcome.Reason = Get-DbHubT5KeptReason -Lifecycle $lifecycle
        return $outcome
    }
    $giveUp = (Get-DbHubUtcNow).AddMinutes($WaitMinutes)
    $current = Get-DbHubT5Container -Context $Context -Tags $Tags
    if ($current.State -in 'Missing', 'NotGranted') {
        $outcome.Outcome = $current.State
        $outcome.Error = $current.Error
        return $outcome
    }
    while ($true) {
        $deleted = Invoke-DbHubArm -Context $Context -Method DELETE -Path $path -ApiVersion $part.ApiVersion
        if ($deleted.StatusCode -eq 404) {
            $outcome.Outcome = 'Missing'
            return $outcome
        }
        if ($deleted.StatusCode -eq 403 -or [string]$deleted.Error -match 'AuthorizationFailed') {
            $outcome.Outcome = 'NotGranted'
            $outcome.Error = $deleted.Error
            return $outcome
        }
        if ($deleted.StatusCode -in 200, 202, 204) {
            Write-DbHubLog -Context $Context -Message ('T5''s container {0}: delete accepted.' -f $outcome.Name)
            break
        }
        if (-not (Test-DbHubT5Conflict -Response $deleted) -or (Get-DbHubUtcNow) -ge $giveUp) {
            Write-DbHubLog -Context $Context -Message ('T5''s container {0}: not deleted: {1}' -f $outcome.Name, $deleted.Error)
            $outcome.Outcome = 'Failed'
            $outcome.Error = $deleted.Error
            return $outcome
        }
        Start-Sleep -Seconds $PollSeconds
    }
    while ($true) {
        $read = Get-DbHubT5Container -Context $Context -Tags $Tags
        if ($read.State -eq 'Missing') {
            $outcome.Outcome = 'Deleted'
            return $outcome
        }
        if ((Get-DbHubUtcNow) -ge $giveUp) {
            $outcome.Outcome = 'Failed'
            $outcome.Error = 'it was still there {0} minutes after Azure accepted its deletion' -f $WaitMinutes
            Write-DbHubLog -Context $Context -Message ('T5''s container {0}: {1}.' -f $outcome.Name, $outcome.Error)
            return $outcome
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-DbHubT5ContainerText {
    # What a stop says about T5's container (2026-11-19, ADR 0027), from Remove-DbHubT5Container's outcome: one phrase for
    # its done list, whatever the outcome, which is apart from the stop's status (t5Status, review of ab91ee5); '' without
    # T5 (NotConfigured).
    param(
        [Parameter(Mandatory = $true)]
        [object] $Outcome
    )

    $billing = 'its throughput stops'
    $throughput = [int](Get-DbHubMember -InputObject $Outcome -Name 'Throughput')
    if ($throughput -gt 0) {
        $billing = 'its {0} RU/s stop' -f $throughput
    }
    switch ([string](Get-DbHubMember -InputObject $Outcome -Name 'Outcome')) {
        'Deleted' { return ('T5''s container deleted ({0} billing until the next session creates it)' -f $billing) }
        'Missing' { return 'T5''s container already gone' }
        'Kept' { return ('T5''s container kept between sessions ({0})' -f [string](Get-DbHubMember -InputObject $Outcome -Name 'Reason')) }
        'NotGranted' { return 'T5''s container kept: this identity''s role lacks the container''s actions (./scripts/stop-demo.ps1 deletes it if it''s there; an Owner runs ./scripts/grant-safety-stop.ps1 once)' }
        'Failed' { return ('T5''s container not deleted: {0}' -f [string](Get-DbHubMember -InputObject $Outcome -Name 'Error')) }
    }
    return ''
}

function Get-DbHubT5KeptReason {
    # Why T5's container stays between sessions (2026-11-19, ADR 0027) when its lifecycle (Get-DbHubT5Lifecycle) isn't
    # Session: AlwaysOn, the session control's role can't create it yet; '', the environment predates the lifecycle. Pure.
    param(
        [AllowEmptyString()]
        [string] $Lifecycle = ''
    )

    if ($Lifecycle -ceq 'AlwaysOn') {
        return 'the session control''s role can''t create it yet, so its throughput keeps billing; an Owner runs ./scripts/grant-safety-stop.ps1 once'
    }
    return 'this environment was deployed before T5''s container lived only during a session, so its throughput keeps billing; ./scripts/deploy.ps1 sets that up'
}

function Get-DbHubT5ContainerStep {
    <#
    .SYNOPSIS
    What a session's start, or a run's, says about T5's container (2026-11-19, ADR 0027), from New-DbHubT5Container's
    outcome: State (Pass when it's there or was created; Fail when it can't be, and T5's activity is skipped), Message, Fix,
    and Why (for the run's skipped list). Message is empty when T5 isn't configured. Pure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Outcome,

        [AllowNull()]
        [object] $Tags,

        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [switch] $Session
    )

    $what = 'this run'
    if ($Session) {
        $what = 'this session'
    }
    $name = [string](Get-DbHubMember -InputObject $Outcome -Name 'Name')
    $account = Get-DbHubT5Account -Settings $Settings -Tags $Tags
    if ($account) {
        $name = '{0} ({1})' -f $name, $account
    }
    $ru = ''
    $throughput = [int](Get-DbHubMember -InputObject $Outcome -Name 'Throughput')
    if ($throughput -gt 0) {
        $ru = ', with its {0} RU/s' -f $throughput
    }
    $errorText = [string](Get-DbHubMember -InputObject $Outcome -Name 'Error')
    $lifecycle = Get-DbHubT5Lifecycle -Tags $Tags
    $step = [pscustomobject]@{ State = 'Pass'; Message = ''; Fix = ''; Why = '' }
    switch ([string](Get-DbHubMember -InputObject $Outcome -Name 'Outcome')) {
        'Created' {
            $step.Message = 'T5''s container {0} wasn''t there, so it was created{1}; it stays between sessions ({2}).' -f $name, $ru, (Get-DbHubT5KeptReason -Lifecycle $lifecycle)
            if ($lifecycle -eq 'Session') {
                $step.Message = 'T5''s container {0} was created for {1}{2}; the stop at its end deletes it, so it bills only while the demo runs.' -f $name, $what, $ru
            }
        }
        'Present' {
            $step.Message = 'T5''s container {0} is there, and stays between sessions ({1}).' -f $name, (Get-DbHubT5KeptReason -Lifecycle $lifecycle)
            if ($lifecycle -eq 'Session') {
                $step.Message = 'T5''s container {0} is there; the stop at the end of {1} deletes it, so it bills only while the demo runs.' -f $name, $what
            }
        }
        'Kept' {
            # Not Session: nothing deletes the container, so this run uses it as it is, without reading it.
            $step.Message = 'T5''s container {0} stays between sessions ({1}), so {2} uses it as it is.' -f $name, (Get-DbHubT5KeptReason -Lifecycle $lifecycle), $what
        }
        'NotGranted' {
            $step.State = 'Fail'
            $step.Message = 'T5''s container {0} couldn''t be read or created: the session control''s role doesn''t have the container''s actions yet, so T5 gets no activity in {1}; the other targets go on.' -f $name, $what
            $step.Fix = 'An Owner runs ./scripts/grant-safety-stop.ps1 once, which gives the session control its role; then Run all again. ./scripts/start-demo.ps1 creates the container too.'
            $step.Why = 'the session control''s role can''t create it yet; an Owner runs ./scripts/grant-safety-stop.ps1'
        }
        'Failed' {
            $step.State = 'Fail'
            $step.Message = 'T5''s container {0} isn''t there and couldn''t be created ({1}), so T5 gets no activity in {2}; the other targets go on.' -f $name, $errorText, $what
            $step.Fix = 'Run all again in a few minutes; ./scripts/status.ps1 shows T5, and ./scripts/start-demo.ps1 creates its container too.'
            $step.Why = 'it couldn''t be created: {0}' -f $errorText
        }
    }
    return $step
}

function Get-DbHubT5LastStormMinute {
    <#
    .SYNOPSIS
    When T5 is back at its baseline after its last ru-storm (2026-11-19, risk R896), in minutes from the start of a showcase
    whose profile ends ProfileMinutes after it: T5's showcase runs the whole session, as the other targets' do, and the
    runner runs a slot with recoveryMinutes only whole, and only when its recovery ends by the profile's end too, so the
    last one that fits ends there plus its recoveryMinutes (ProfileScheduler.Plan); a slot without recoveryMinutes is
    clipped at the profile's end. After it, T5's baseline runs on until the profile ends. Slot holds T5's slots in a cycle
    (startMinute, durationMinutes, and recoveryMinutes), each taken as running in every cycle. 0 when no ru-storm runs.
    Pure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int] $ProfileMinutes,

        [Parameter(Mandatory = $true)]
        [int] $CycleMinutes,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Slot = @()
    )

    $slots = @(@($Slot) | Where-Object { $null -ne $_ })
    if ($ProfileMinutes -le 0 -or $CycleMinutes -le 0 -or $slots.Count -eq 0) {
        return 0
    }
    $last = 0
    for ($base = 0; $base -lt $ProfileMinutes; $base += $CycleMinutes) {
        foreach ($item in $slots) {
            $start = $base + [int](Get-DbHubMember -InputObject $item -Name 'startMinute')
            $stop = $start + [int](Get-DbHubMember -InputObject $item -Name 'durationMinutes')
            $recovery = Get-DbHubMember -InputObject $item -Name 'recoveryMinutes'
            $end = 0
            if ($null -ne $recovery) {
                # Whole, with its recovery before the profile's end, or not at all.
                if ($stop + [int]$recovery -le $ProfileMinutes) {
                    $end = $stop + [int]$recovery
                }
            }
            elseif ($start -lt $ProfileMinutes) {
                $end = [System.Math]::Min($stop, $ProfileMinutes)
            }
            if ($end -gt $last) {
                $last = $end
            }
        }
    }
    return $last
}

function Get-DbHubT5LastStormEnd {
    <#
    .SYNOPSIS
    At T5's dispatch (2026-11-19, risk R896): when T5 is back at its baseline after its last ru-storm, in UTC, for the
    session's status (t5.endUtc) and the notebook's guide. The showcase's profile ends at its minutes from when it's set,
    or 2 minutes before its NotAfterUtc when that's earlier (the runner's end), and Get-DbHubT5LastStormMinute applies the
    runner's rule to it, less StartMinutes for its Run Command to set the profile on sqlvm01, so a ru-storm that only fits
    when the profile is set at once isn't counted. The profile's minutes count from when it's set, at most StartMinutes
    after now, so the time is that much later too (review of ab91ee5), and T5 is back at its baseline by then. Nothing is
    cut: T5's baseline runs on until the session ends. Returns $null for an activity it doesn't apply to (another target,
    off, the baseline, or an incident) or when no ru-storm runs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [Parameter(Mandatory = $true)]
        [object] $Activity,

        [Parameter(Mandatory = $true)]
        [datetime] $NowUtc,

        [int] $StartMinutes = 2
    )

    $notAfter = Get-DbHubMember -InputObject $Activity -Name 'NotAfterUtc'
    if ([string]$Activity.Target -ne 'T5' -or $null -eq $notAfter) {
        return $null
    }
    $definition = Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $Settings -Name 'profiles') -Name ([string]$Activity.Scenario)
    if ($null -eq $definition) {
        return $null
    }
    $end = ([datetime]$notAfter).AddMinutes(-2)
    $byDuration = $NowUtc.AddMinutes([int]$Activity.Minutes)
    if ($byDuration -lt $end) {
        $end = $byDuration
    }
    $profileMinutes = [int]([System.Math]::Floor(($end - $NowUtc).TotalMinutes)) - $StartMinutes
    $minute = Get-DbHubT5LastStormMinute -ProfileMinutes $profileMinutes -CycleMinutes ([int](Get-DbHubMember -InputObject $definition -Name 'cycleMinutes')) -Slot @(Get-DbHubMember -InputObject $definition -Name 't5Slots')
    if ($minute -le 0) {
        return $null
    }
    return $NowUtc.AddMinutes($StartMinutes + $minute)
}

function Get-DbHubLeftRunning {
    <#
    .SYNOPSIS
    What a run that sent no activity left running because it didn't start it (#27, user-directed 2026-11-17), read after
    it stopped what it started: each demo VM that runs or starts, T4 when it's Ready, starting, or updating, and T5's
    container when it's there while its lifecycle is Session (2026-11-19, ADR 0027), so it bills only during a session.
    Returns Text (what's left, and that the nightly safety stop still stops it, at its time) and Fix (how to stop
    everything now), both empty when nothing runs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $settings = $Context.Settings
    $left = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($vm in @([string]$settings.sqlVmName, [string]$settings.hostVmName)) {
        $state = Get-DbHubVmState -Context $Context -VmName $vm
        if ($state -in 'running', 'starting') {
            $left.Add(('{0} ({1})' -f $vm, $state))
        }
    }
    $t4 = Get-DbHubT4 -Context $Context -Tags $Tags
    if ($t4.State -in 'Ready', 'Starting', 'Updating') {
        $left.Add(('T4 ({0})' -f $t4.State))
    }
    if ((Get-DbHubT5Lifecycle -Tags $Tags) -eq 'Session' -and (Get-DbHubT5Container -Context $Context -Tags $Tags).State -eq 'Present') {
        $left.Add('T5''s container (its throughput bills)')
    }
    if ($left.Count -eq 0) {
        return [pscustomobject]@{ Text = ''; Fix = '' }
    }
    $list = $left[0]
    if ($left.Count -gt 1) {
        $list = '{0} and {1}' -f (($left | Select-Object -SkipLast 1) -join ', '), $left[$left.Count - 1]
    }
    $when = 'tonight'
    try {
        $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById([string]$settings.autoShutdownTimeZone)
        $next = Get-DbHubNextShutdownUtc -Settings $settings -NowUtc (Get-DbHubUtcNow)
        $when = 'at {0} ({1})' -f [System.TimeZoneInfo]::ConvertTimeFromUtc($next, $zone).ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture), $settings.autoShutdownTimeZone
    }
    catch {
        $when = 'tonight'
    }
    return [pscustomobject]@{
        Text = ('This run didn''t start {0}, so it left {1} running, as before; the nightly safety stop still stops {1} {2}.' -f $list, $(if ($left.Count -eq 1) { 'it' } else { 'them' }), $when)
        Fix  = 'To stop everything now: set STOP_NOW = True and Run all in the control notebook, or run ./scripts/stop-demo.ps1.'
    }
}

function Start-DbHubActivityRun {
    <#
    .SYNOPSIS
    The run action: refuses while a run is active, plans the durations, creates the auto-stop (and, when the run uses
    sqlvm01, the monitoring re-checks) before anything starts, starts what's stopped (the VMs, and T4; T3 resumes when
    the runner connects), and dispatches each target's activity profile through an asynchronous managed Run Command,
    then exits. If no activity could be dispatched, it stops again what it started itself, and nothing else (#27).

    .DESCRIPTION
    Each VM's activities go out as soon as that VM runs, at most WaitMinutes after the start: T1 and T3 don't wait for
    T2's host, and none of them waits for T4. T4's activity goes out on its own Run Command on sqlvm01 once T4 is Ready,
    at most T4WaitMinutes after the start, or with sqlvm01's when T4 is already Ready then (live, 2026-11-03: the run
    waited up to 15 minutes for T4 before it dispatched anything). The VM-side control waits for each target to accept
    connections before it sets the profile (readySeconds). Meanwhile T1's monitoring plugin is looked after once sqlvm01
    runs (Step-DbHubMonitor): left alone when a status reported since this run's start of sqlvm01 says it runs, and
    restarted once when a fresh status says another state, or when no fresh status comes within monitoring.settleMinutes
    (live, 2026-11-04: right after a cold start the status from before the stop said Running). The job ends when every VM,
    T4, and the plugin are done, or at their bounds.
    An off never starts anything (review of PR 20, 2026-11-04): a VM whose only activities are off is left as it is and
    gets them only when it already runs, T4's off goes out with sqlvm01's activities (T4's profile is a file on T1)
    without reading, starting, or waiting for T4, and a run whose only dispatched activities are off stops what it started.
    That's only what it started itself (#27, user-directed 2026-11-17): its auto-stop and re-checks, the VMs it started,
    and T4 when it started it (Stop-DbHubDemo -OnlyVm -KeepT4); a VM or T4 that ran before stays as it was, and the
    result's message, left, and leftFix say what that is, that the nightly safety stop still stops it, and how to stop
    everything now (Get-DbHubLeftRunning).
    T5 (2026-11-18, ADR 0027) has no VM of its own: its activity goes out with sqlvm01's (its profile is a file on T1). Its
    container exists only during a session once its lifecycle is Session (2026-11-19), so a run with T5 activity makes sure
    it's there once the starts are sent, while the VMs start (New-DbHubT5Container), and OnProgress gets t5-container with
    what happened; when it can't be there, T5's activity is skipped, with why, and the rest of the run goes on. A run that
    stops what it started deletes the container again when it created it. A showcase on T5 runs the whole run, as on the
    other targets, and OnProgress gets t5-end with when T5 is back at its baseline after its last ru-storm
    (Get-DbHubT5LastStormEnd, risk R896): the runner runs a ru-storm only when it and its recovery end before the profile
    does.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [object] $Request,

        [AllowNull()]
        [object] $Tags,

        [int] $WaitMinutes = 15,

        [int] $T4WaitMinutes = 20,

        [int] $PollSeconds = 20,

        # A session's plan (Start-DbHubSession, 2026-11-14), which also checked that no run is active.
        [AllowNull()]
        [object] $Plan = $null,

        # Called with a kind (autostop, backup, vm-start, t4-start, dispatched, skipped, t5-container, or t5-end) and a detail,
        # for a session's status; t5-container also with the step's state and fix.
        [AllowNull()]
        [scriptblock] $OnProgress = $null,

        # Called once, when T4 is first seen Ready, for a session's read replica.
        [AllowNull()]
        [scriptblock] $OnT4Ready = $null,

        # Called with a VM's name once it runs, and whether it ran before this run started it, after this control's earlier
        # Run Commands there are deleted and right before its activity goes out (2026-11-20, ADR 0031): a session's start
        # sends an evidence export there. It returns the name of a Run Command it sent, which no cleanup of this run
        # deletes, or ''.
        [AllowNull()]
        [scriptblock] $OnVmReady = $null
    )

    $settings = $Context.Settings
    if (-not $PSCmdlet.ShouldProcess($settings.demoResourceGroup, 'Start an on-demand run')) {
        return [pscustomobject]@{ action = 'run'; status = 'Refused'; message = 'What if: nothing was started.'; runEndUtc = ''; autoStopUtc = ''; dispatched = @(); skipped = @(); monitoring = ''; rechecks = @(); replica = ''; runCommands = @(); t5Container = '' }
    }
    $result = [ordered]@{ action = 'run'; status = 'Refused'; message = ''; runEndUtc = ''; autoStopUtc = ''; dispatched = @(); skipped = @(); monitoring = ''; rechecks = @(); replica = ''; runCommands = @(); left = ''; leftFix = ''; t5Container = '' }
    $progress = $OnProgress
    if ($null -eq $progress) {
        # Nothing to tell: the kind and detail it's called with are dropped.
        $progress = { }
    }
    $plan = $Plan
    if ($null -eq $plan) {
        $active = Get-DbHubActiveRun -Context $Context
        if ($active.Active) {
            $result.message = $active.Reason
            return [pscustomobject]$result
        }
        $plan = Get-DbHubRunPlan -Request $Request -Settings $settings -NowUtc $Context.NowUtc
    }
    if (-not $plan.Valid) {
        $result.message = $plan.Reason
        return [pscustomobject]$result
    }

    $activities = @($plan.Activities)
    $skipped = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if (@($activities | Where-Object { $_.Target -eq 'T3' }).Count -gt 0 -and (Get-DbHubT3State -Context $Context -Tags $Tags) -eq 'Missing') {
        $skipped.Add('T3 (not deployed; start-demo.ps1 recreates it)')
        $activities = @($activities | Where-Object { $_.Target -ne 'T3' })
    }
    $t4 = $null
    # T4's off is a file on T1 (its profile), so only an activity that isn't off reads T4, starts it, or waits for it
    # (review of PR 20, 2026-11-04).
    if (@($activities | Where-Object { $_.Target -eq 'T4' -and $_.Scenario -cne 'off' }).Count -gt 0) {
        $t4 = Get-DbHubT4 -Context $Context -Tags $Tags
        # Missing, Unknown, or a state it can't be started from now, such as Stopping right after a stop.
        if ($t4.State -notin 'Ready', 'Starting', 'Updating', 'Stopped') {
            $skipped.Add(('T4 ({0})' -f $t4.State.ToLowerInvariant()))
            $activities = @($activities | Where-Object { $_.Target -ne 'T4' })
            $t4 = $null
        }
        else {
            # The showcase's T4 slots follow its size (2026-11-04): its tier picks the tier-specific slots, and its vCores
            # scale the CPU-bound ones (the runner's --tier and --vcores).
            foreach ($activity in @($activities | Where-Object { $_.Target -eq 'T4' })) {
                $t4Tier = [string](Get-DbHubMember -InputObject $t4 -Name 'Tier')
                if ($t4Tier -cin 'Burstable', 'GeneralPurpose') {
                    $activity.Tier = $t4Tier
                }
                $activity.VCores = Get-DbHubT4VCore -SkuName ([string](Get-DbHubMember -InputObject $t4 -Name 'SkuName'))
            }
        }
    }
    $byVm = [ordered]@{}
    foreach ($activity in $activities) {
        $vm = Get-DbHubTargetVm -Settings $settings -Target $activity.Target
        if (-not $byVm.Contains($vm)) {
            $byVm[$vm] = @()
        }
        $byVm[$vm] += $activity
    }
    # Whether a VM has an activity that isn't off: only such a VM is started, and T1's plugin is looked after only then.
    $hasActivity = {
        param([string] $VmName)
        return (@($byVm[$VmName] | Where-Object { $_.Scenario -cne 'off' }).Count -gt 0)
    }
    foreach ($vm in @($byVm.Keys)) {
        $vmState = Get-DbHubVmState -Context $Context -VmName $vm
        if ($vmState -eq 'Missing') {
            foreach ($activity in $byVm[$vm]) {
                $skipped.Add(('{0} ({1} doesn''t exist)' -f $activity.Target, $vm))
            }
            $byVm.Remove($vm)
        }
        elseif (-not (& $hasActivity $vm) -and $vmState -ne 'running') {
            # An off never starts anything (review of PR 20): on a VM that doesn't run, nothing runs to turn off. Its stored
            # profile ends at its own end, and a boot's leftover-run cleanup ends what a stopped run left.
            foreach ($activity in $byVm[$vm]) {
                $skipped.Add(('{0} (off not sent: {1} is {2}, so nothing runs there)' -f $activity.Target, $vm, $vmState))
            }
            $byVm.Remove($vm)
        }
    }
    $sqlVm = [string]$settings.sqlVmName
    if (-not $byVm.Contains($sqlVm)) {
        # T4's activity goes out on sqlvm01, so without it T4 isn't started.
        $t4 = $null
    }
    if (@($byVm.Keys | Where-Object { & $hasActivity $_ }).Count -eq 0) {
        # Off alone isn't a run: Stop now stops everything (Test-DbHubControlRequest refuses a request of off only).
        $result.message = 'Nothing to run: ' + ($skipped -join '; ')
        $result.skipped = $skipped.ToArray()
        return [pscustomobject]$result
    }
    $sqlActive = $byVm.Contains($sqlVm) -and (& $hasActivity $sqlVm)

    $stop = Register-DbHubAutoStop -Context $Context -AutoStopUtc $plan.AutoStopUtc
    if (-not $stop.Created) {
        $result.message = 'The auto-stop schedule couldn''t be created ({0}), so nothing was started.' -f $stop.Error
        return [pscustomobject]$result
    }
    $result.runEndUtc = $plan.RunEndUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $result.autoStopUtc = $stop.StartUtc
    Write-DbHubLog -Context $Context -Message ('Auto-stop set for {0}; the run ends by {1}.' -f $stop.StartUtc, $result.runEndUtc)
    & $progress 'autostop' $stop.StartUtc
    if ([string](Get-DbHubMember -InputObject $stop -Name 'BackupUtc')) {
        & $progress 'backup' ([string]$stop.BackupUtc)
    }
    if ($sqlActive) {
        $result.rechecks = @(Register-DbHubMonitorRecheck -Context $Context -StartUtc $Context.NowUtc -RunEndUtc $plan.RunEndUtc)
    }

    # When this run's start of sqlvm01 was accepted: T1's monitoring plugin counts only a status reported after it.
    $sqlStartedUtc = $null
    # What this run started itself, which a run that sends no activity stops again (#27): nothing else.
    $startedVms = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $startedT4 = $false
    foreach ($vm in @($byVm.Keys)) {
        if ((& $hasActivity $vm) -and (Get-DbHubVmState -Context $Context -VmName $vm) -ne 'running') {
            $accepted = Invoke-DbHubVmAction -Context $Context -VmName $vm -Action start
            if ($accepted -and $vm -eq $sqlVm) {
                $sqlStartedUtc = Get-DbHubUtcNow
            }
            if ($accepted) {
                $startedVms.Add($vm)
                & $progress 'vm-start' $vm
            }
        }
    }
    if ($null -ne $t4 -and $t4.State -eq 'Stopped') {
        # T4's read replica (ADR 0025): Azure starts T4 only once a stopped replica is Ready, so one a session left behind
        # starts first. The control never creates one: without it, the run says plainly that its replica beat isn't there.
        $replicaFirst = Invoke-DbHubT4ReplicaStartFirst -Context $Context -Tags $Tags -PollSeconds $PollSeconds
        $startedT4 = $replicaFirst.Outcome -eq 'Started'
        $replicaNote = ''
        if ($null -eq $OnT4Ready -or $replicaFirst.Outcome -ne 'Missing') {
            $replicaNote = Get-DbHubT4ReplicaRunNote -Outcome $replicaFirst
        }
        if ($replicaNote) {
            $result.replica = $replicaNote
            Write-DbHubLog -Context $Context -Message $replicaNote
        }
        if ($replicaFirst.Outcome -eq 'Failed') {
            $skipped.Add(('T4 (its read replica {0} couldn''t be started first: {1})' -f $replicaFirst.Name, $replicaFirst.Error))
            foreach ($vm in @($byVm.Keys)) {
                $byVm[$vm] = @($byVm[$vm] | Where-Object { $_.Target -ne 'T4' })
            }
            $t4 = $null
        }
    }
    elseif ($null -ne $t4 -and $null -eq $OnT4Ready) {
        # A T4 that runs needs nothing first; without a replica, the run still says its replica beat isn't there. A session
        # (OnT4Ready) creates the replica itself, so it says nothing here (live, 2026-11-14: the note told a session to use
        # start-demo.ps1 for a replica it was about to create).
        $replicaNow = Get-DbHubT4Replica -Context $Context -Tags $Tags
        $replicaNote = Get-DbHubT4ReplicaRunNote -Outcome ([pscustomobject]@{ Outcome = $(if ($replicaNow.State -eq 'Missing') { 'Missing' } else { '' }); Name = [string]$replicaNow.Name; State = [string]$replicaNow.State; Error = '' })
        if ($replicaNote) {
            $result.replica = $replicaNote
            Write-DbHubLog -Context $Context -Message $replicaNote
        }
    }
    if ($null -ne $t4 -and $t4.State -eq 'Stopped') {
        if (Invoke-DbHubT4Action -Context $Context -Name $t4.Name -Action start) {
            $startedT4 = $true
            & $progress 't4-start' $t4.Name
        }
        else {
            # Don't wait for a start Azure refused (Phase 25d live: the wait for T4 took the run's whole 15 minutes).
            $skipped.Add(('T4 ({0} didn''t accept the start)' -f $t4.Name))
            foreach ($vm in @($byVm.Keys)) {
                $byVm[$vm] = @($byVm[$vm] | Where-Object { $_.Target -ne 'T4' })
            }
            $t4 = $null
        }
    }
    # T5's container (2026-11-19, ADR 0027): it exists only during a session once its lifecycle is Session, so a run with T5
    # activity makes sure it's there now, while the VMs start (Azure creates it in 10 to 60 seconds), before T5's activity
    # goes out with sqlvm01's. Without it, T5's activity is skipped, and the rest of the run goes on. With another lifecycle
    # (AlwaysOn, or an environment deployed before then), nothing deletes the container, and the control's role may not have
    # its actions yet, so it's neither read nor created here: T5's activity goes out as before, and the step says why the
    # container stays between sessions.
    $createdT5 = $false
    $t5Note = ''
    if ($byVm.Contains($sqlVm) -and @($byVm[$sqlVm] | Where-Object { [string]$_.Target -eq 'T5' -and $_.Scenario -cne 'off' }).Count -gt 0) {
        if ((Get-DbHubT5Lifecycle -Tags $Tags) -ceq 'Session') {
            $ensured = New-DbHubT5Container -Context $Context -Tags $Tags
        }
        else {
            $keptPart = Get-DbHubT5ContainerSetting -Settings $settings
            $ensured = [pscustomobject]@{ Outcome = 'Kept'; Name = ('{0}/{1}' -f $keptPart.Database, $keptPart.Container); Throughput = $keptPart.Throughput; Error = '' }
        }
        $result.t5Container = [string]$ensured.Outcome
        $createdT5 = $ensured.Outcome -eq 'Created'
        $t5Step = Get-DbHubT5ContainerStep -Outcome $ensured -Tags $Tags -Settings $settings -Session:($null -ne $OnT4Ready)
        if ($t5Step.Message) {
            Write-DbHubLog -Context $Context -Message $t5Step.Message
            & $progress 't5-container' $t5Step.Message $t5Step.State $t5Step.Fix
        }
        if ($createdT5) {
            $t5Note = $t5Step.Message
        }
        if ($ensured.Outcome -in 'NotGranted', 'Failed') {
            $skipped.Add(('T5 (its container isn''t there: {0})' -f $t5Step.Why))
            $byVm[$sqlVm] = @($byVm[$sqlVm] | Where-Object { [string]$_.Target -ne 'T5' })
        }
    }
    # The control's finished Run Commands on a demo VM this run doesn't use; each VM it uses gets its own cleanup below.
    Clear-DbHubFinishedRunCommand -Context $Context -Except @($byVm.Keys)

    $stamp = $Context.NowUtc.ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $who = Get-DbHubRequester -Context $Context -RequestedBy $Request.RequestedBy
    $dispatched = New-Object -TypeName 'System.Collections.Generic.List[string]'
    # The dispatched activities that aren't off (a reference the dispatch block counts in): without one, the run stops what
    # it started.
    $sent = @{ Activities = 0 }
    # This run's Run Commands, which no cleanup of its own deletes.
    $runNames = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $runNames.Add(('{0}monitoring-{1}' -f $settings.runCommandPrefix, $stamp))
    # The dispatch Run Commands Azure accepted, with their VM and targets, for a session's checks of its hosts (2026-11-16).
    $sentCommands = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $plans = [ordered]@{}
    foreach ($vm in @($byVm.Keys)) {
        # T4's off goes out with sqlvm01's activities, without waiting for T4: its profile is a file on T1.
        $plans[$vm] = [pscustomobject]@{ Activities = @($byVm[$vm] | Where-Object { $_.Target -ne 'T4' -or $_.Scenario -ceq 'off' }); Done = $false; Running = $false }
    }
    $t4Activity = $null
    if ($null -ne $t4 -and $plans.Contains($sqlVm)) {
        $t4Activity = @($byVm[$sqlVm] | Where-Object { $_.Target -eq 'T4' -and $_.Scenario -cne 'off' }) | Select-Object -First 1
    }
    $t4Pending = $null -ne $t4Activity
    $monitor = $null
    if ($sqlActive) {
        $monitor = Initialize-DbHubMonitorState -StartUtc $sqlStartedUtc
    }
    $dispatch = {
        param([string] $VmName, [object[]] $Chosen, [string] $Name)
        $runNames.Add($Name)
        # When T5 is back at its baseline after its last ru-storm (2026-11-19, risk R896): its showcase runs the whole run,
        # and the runner runs a ru-storm only when it and its recovery end before the profile does; counted from now.
        $t5End = $null
        foreach ($item in @($Chosen | Where-Object { [string]$_.Target -eq 'T5' -and $_.Scenario -cne 'off' })) {
            $t5End = Get-DbHubT5LastStormEnd -Settings $settings -Activity $item -NowUtc (Get-DbHubUtcNow)
        }
        if (Send-DbHubDispatch -Context $Context -VmName $VmName -Activity $Chosen -Name $Name -RequestedBy $who) {
            $sentCommands.Add([ordered]@{ vm = $VmName; name = $Name; targets = @($Chosen | ForEach-Object { [string]$_.Target }) })
            foreach ($item in $Chosen) {
                if ($item.Scenario -ceq 'off') {
                    $dispatched.Add(('{0}: off' -f $item.Target))
                }
                else {
                    $dispatched.Add(('{0}: {1} for {2} minutes' -f $item.Target, $item.Scenario, $item.Minutes))
                    $sent.Activities++
                    & $progress 'dispatched' ('{0}: {1} for {2} minutes' -f $item.Target, $item.Scenario, $item.Minutes)
                }
            }
            if ($null -ne $t5End) {
                & $progress 't5-end' (ConvertTo-DbHubTimeText -Value $t5End)
            }
        }
        else {
            foreach ($item in $Chosen) {
                $skipped.Add(('{0} (the Run Command on {1} wasn''t accepted)' -f $item.Target, $VmName))
                & $progress 'skipped' ('{0}: the Run Command on {1} wasn''t accepted' -f $item.Target, $VmName)
            }
        }
    }

    $started = Get-DbHubUtcNow
    $vmDeadline = $started.AddMinutes($WaitMinutes)
    $t4Deadline = $started.AddMinutes($T4WaitMinutes)
    # A last bound on the whole loop, past every wait's own.
    $giveUp = $started.AddMinutes([System.Math]::Max($WaitMinutes, $T4WaitMinutes) + 15)
    $t4ReadySeen = $false
    while ($true) {
        $now = Get-DbHubUtcNow
        $t4State = ''
        if ($t4Pending) {
            $t4State = [string](Get-DbHubT4 -Context $Context -Tags $Tags).State
        }
        if ($t4State -eq 'Ready' -and -not $t4ReadySeen) {
            # A session asks for T4's read replica now (Start-DbHubSession), while the VMs still start.
            $t4ReadySeen = $true
            if ($null -ne $OnT4Ready) {
                & $OnT4Ready
            }
        }
        foreach ($vm in @($plans.Keys)) {
            $vmPlan = $plans[$vm]
            if ($vmPlan.Done) {
                continue
            }
            if ((Get-DbHubVmState -Context $Context -VmName $vm) -ne 'running') {
                if ($now -ge $vmDeadline) {
                    foreach ($activity in $vmPlan.Activities) {
                        $skipped.Add(('{0} ({1} isn''t running yet)' -f $activity.Target, $vm))
                    }
                    if ($vm -eq $sqlVm -and $t4Pending) {
                        $skipped.Add(('T4 ({0} isn''t running yet)' -f $vm))
                        $t4Pending = $false
                    }
                    $vmPlan.Done = $true
                }
                continue
            }
            $vmPlan.Running = $true
            # This control's earlier Run Commands on the VM go first: a VM takes 25 managed ones.
            Clear-DbHubOldRunCommand -Context $Context -VmName $vm -Keep $runNames.ToArray()
            if ($null -ne $OnVmReady) {
                $readyName = [string](& $OnVmReady $vm ($vm -notin $startedVms))
                if ($readyName) {
                    $runNames.Add($readyName)
                }
            }
            $chosen = @($vmPlan.Activities)
            if ($vm -eq $sqlVm -and $t4Pending -and $t4State -eq 'Ready') {
                $chosen += $t4Activity
                $t4Pending = $false
            }
            if ($chosen.Count -gt 0) {
                & $dispatch $vm $chosen ('{0}{1}-{2}' -f $settings.runCommandPrefix, $vm, $stamp)
            }
            $vmPlan.Done = $true
        }
        if ($t4Pending -and $plans[$sqlVm].Running) {
            if ($t4State -eq 'Ready') {
                Write-DbHubLog -Context $Context -Message ('{0} is Ready {1:N0} minutes after the start; its activity goes out now.' -f $t4.Name, ($now - $started).TotalMinutes)
                & $dispatch $sqlVm @($t4Activity) ('{0}{1}-t4-{2}' -f $settings.runCommandPrefix, $sqlVm, $stamp)
                $t4Pending = $false
            }
            elseif ($t4State -in 'Missing', 'Stopping', 'Disabled', 'Dropping') {
                $skipped.Add(('T4 ({0})' -f $t4State.ToLowerInvariant()))
                $t4Pending = $false
            }
            elseif ($now -ge $t4Deadline) {
                $skipped.Add(('T4 ({0} isn''t Ready yet)' -f $t4.Name))
                $t4Pending = $false
            }
        }
        if ($null -ne $monitor -and -not $monitor.Done) {
            if ($plans[$sqlVm].Running) {
                Step-DbHubMonitor -Context $Context -State $monitor -Stamp $stamp
            }
            elseif ($plans[$sqlVm].Done) {
                $monitor.Done = $true
                $monitor.Outcome = 'VmNotRunning'
            }
        }
        $pendingVm = @($plans.Keys | Where-Object { -not $plans[$_].Done }).Count -gt 0
        if (-not $pendingVm -and -not $t4Pending -and ($null -eq $monitor -or $monitor.Done)) {
            break
        }
        if ($now -ge $giveUp) {
            if ($t4Pending) {
                $skipped.Add(('T4 ({0} isn''t Ready yet)' -f $t4.Name))
            }
            break
        }
        Start-Sleep -Seconds $PollSeconds
    }
    if ($null -ne $monitor) {
        $result.monitoring = $monitor.Outcome
        if (-not $monitor.Done) {
            $result.monitoring = 'Unfinished'
        }
    }
    $result.dispatched = $dispatched.ToArray()
    $result.skipped = $skipped.ToArray()
    $result.runCommands = $sentCommands.ToArray()
    if ($sent.Activities -eq 0) {
        # Only what this run started is stopped again (#27, user-directed 2026-11-17): its auto-stop and re-checks, the VMs it
        # started, and T4 when it started it, with the read replica its session asked for, and T5's container when it created
        # it (2026-11-19). What ran before stays as it was, and the result says what that is, and how to stop everything.
        $stopped = Stop-DbHubDemo -Context $Context -Tags $Tags -OnlyVm $startedVms.ToArray() -KeepT4:(-not $startedT4) -RemoveReplica:($t4ReadySeen -and $null -ne $OnT4Ready) -RemoveT5Container:$createdT5
        $left = Get-DbHubLeftRunning -Context $Context -Tags $Tags
        $result.status = 'Failed'
        $result.left = $left.Text
        $result.leftFix = $left.Fix
        $leftText = ''
        if ($left.Text) {
            $leftText = ' {0} {1}' -f $left.Text, $left.Fix
        }
        $result.message = 'No activity could be dispatched ({0}), so this run stopped what it started: {1}.{2}' -f ($skipped -join '; '), ((@($stopped.Done) + @($stopped.Failed)) -join ', '), $leftText
        return [pscustomobject]$result
    }
    $result.status = 'Dispatched'
    $note = ''
    if ($skipped.Count -gt 0) {
        $note = ' Skipped: ' + ($skipped -join '; ') + '.'
    }
    $plugin = @{ Running = ' T1''s monitoring plugin runs.'; Restarted = ' T1''s monitoring plugin was restarted and runs.'; StillNotRunning = ' T1''s monitoring plugin still didn''t run after its restart.'; RestartRefused = ' T1''s monitoring plugin needed a restart that Azure didn''t accept.' }
    if ($plugin.ContainsKey([string]$result.monitoring)) {
        $note += $plugin[[string]$result.monitoring]
    }
    if ($result.replica) {
        $note += ' ' + $result.replica
    }
    if ($t5Note) {
        $note += ' ' + $t5Note
    }
    $result.message = 'Dispatched {0}. The profiles end by {1} UTC and the auto-stop runs at {2}; each target is waited for until it accepts connections, and telemetry shows the activity 3 to 15 minutes later.{3}' -f ($dispatched -join '; '), $result.runEndUtc, $result.autoStopUtc, $note
    return [pscustomobject]$result
}

function Reset-DbHubActivity {
    # The reset action: the runner's reset on each requested target whose VM runs (T4 only when Ready; T5, which has no VM
    # of its own, with sqlvm01, and only when its container is there: since 2026-11-19 it exists only during a session, so
    # without it there's nothing to reset). Nothing is started.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [object] $Request,

        [AllowNull()]
        [object] $Tags
    )

    $settings = $Context.Settings
    if (-not $PSCmdlet.ShouldProcess($settings.demoResourceGroup, 'Reset the activity')) {
        return [pscustomobject]@{ action = 'reset'; status = 'Skipped'; message = 'What if: nothing was reset.'; dispatched = @(); skipped = @() }
    }
    $targets = @($Request.Targets)
    if ($targets.Count -eq 0) {
        $targets = @($settings.targets.PSObject.Properties | ForEach-Object { [string]$_.Name })
    }
    $stamp = $Context.NowUtc.ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $who = Get-DbHubRequester -Context $Context -RequestedBy $Request.RequestedBy
    $sent = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $skipped = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $byVm = [ordered]@{}
    foreach ($target in $targets) {
        if ($target -eq 'T4') {
            $t4 = Get-DbHubT4 -Context $Context -Tags $Tags
            if ($t4.State -ne 'Ready') {
                $skipped.Add(('T4 ({0})' -f $t4.State.ToLowerInvariant()))
                continue
            }
        }
        if ($target -eq 'T5' -and (Get-DbHubT5Container -Context $Context -Tags $Tags).State -eq 'Missing') {
            $skipped.Add('T5 (its container isn''t there between sessions, so there''s nothing to reset; the next session creates it)')
            continue
        }
        $vm = Get-DbHubTargetVm -Settings $settings -Target $target
        if (-not $byVm.Contains($vm)) {
            $byVm[$vm] = @()
        }
        $byVm[$vm] += $target
    }
    # The control's finished Run Commands on a demo VM this reset doesn't use; each VM it uses gets its own cleanup below.
    Clear-DbHubFinishedRunCommand -Context $Context -Except @($byVm.Keys)
    foreach ($vm in @($byVm.Keys)) {
        if ((Get-DbHubVmState -Context $Context -VmName $vm) -ne 'running') {
            foreach ($target in $byVm[$vm]) {
                $skipped.Add(('{0} ({1} isn''t running)' -f $target, $vm))
            }
            continue
        }
        $requests = @()
        foreach ($target in $byVm[$vm]) {
            $requests += [ordered]@{ target = $target; arguments = @(Get-DbHubRunnerArgument -Activity $null -RequestedBy $who -Reset); timeoutSeconds = 900 }
        }
        $name = '{0}{1}-reset-{2}' -f $settings.runCommandPrefix, $vm, $stamp
        Clear-DbHubOldRunCommand -Context $Context -VmName $vm -Keep @($name)
        if (Send-DbHubRunCommand -Context $Context -VmName $vm -Name $name -Script (Get-DbHubWorkloadScript -Settings $settings -Request $requests) -TimeoutSeconds 1500) {
            foreach ($target in $byVm[$vm]) {
                $sent.Add($target)
            }
        }
        else {
            foreach ($target in $byVm[$vm]) {
                $skipped.Add(('{0} (the Run Command on {1} wasn''t accepted)' -f $target, $vm))
            }
        }
    }
    $status = 'Dispatched'
    if ($sent.Count -eq 0) {
        $status = 'Skipped'
    }
    $sentText = 'none'
    if ($sent.Count -gt 0) {
        $sentText = $sent -join ', '
    }
    $skippedText = 'none'
    if ($skipped.Count -gt 0) {
        $skippedText = $skipped -join '; '
    }
    return [pscustomobject]@{ action = 'reset'; status = $status; message = ('Reset sent to: {0}. Skipped: {1}.' -f $sentText, $skippedText); dispatched = $sent.ToArray(); skipped = $skipped.ToArray() }
}

# The control session (ADR 0026, 2026-11-14): the control notebook's one Run all. The session action starts the whole demo
# with the showcase on every target and creates T4's read replica, marks the demo busy so the nightly stop leaves it to
# the session's own auto-stop, and writes its progress to the control vault for the notebook, which can't read a job's
# output. The runbook can't reach a private vault's data plane, so it writes through Azure Resource Manager (Secrets -
# Create Or Update), which a vault's network rules don't apply to. The stop reads T4's and the replica's Azure Monitor
# metrics into the vault for the history, then deletes the replica: a deleted server's metrics can't be read. T5's
# (2026-11-18, ADR 0027) go into the same secret, as its cosmos member, with the identity's Microsoft.Insights/metrics/read
# at the demo resource group.

# What the history keeps of each server, one Metrics - List read per aggregation, as the module's
# Get-DemoPostgresHistoryParameter reads them: Read Replica Lag exists on a replica only, and Max Physical Replication Lag
# on the primary only.
$script:DbHubMetricReads = @{
    primary = @(
        @{ Aggregation = 'Maximum'; Names = @('cpu_percent', 'memory_percent', 'active_connections', 'physical_replication_delay_in_bytes') }
        @{ Aggregation = 'Total'; Names = @('connections_failed') }
    )
    replica = @(
        @{ Aggregation = 'Maximum'; Names = @('physical_replication_delay_in_seconds', 'cpu_percent', 'active_connections') }
    )
}
# The intervals a metrics document steps up through, in minutes, until it fits; each divides a day and the next one.
$script:DbHubMetricIntervals = @(1, 5, 15, 30, 60, 180, 360, 720, 1440)
# Decimals kept per Azure Monitor unit; any other unit keeps two.
$script:DbHubMetricDecimals = @{ Percent = 1; Seconds = 1; Count = 0; Bytes = 0 }
# What the history keeps of T5 (2026-11-18, ADR 0027), as the module's Get-DemoCosmosHistoryParameter reads it: the
# signals Database Hub's Cosmos DB views chart, one Metrics - List read each. ThrottledRequests is TotalRequests filtered to
# StatusCode 429; ProvisionedThroughput and ServiceAvailability have no grain under 5 minutes and an hour, so they're read
# hourly (Interval 60).
# https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-documentdb-databaseaccounts-metrics
$script:DbHubCosmosReads = @(
    @{ Metric = 'NormalizedRUConsumption'; Name = 'NormalizedRUConsumption'; Aggregation = 'Maximum'; StatusCode = ''; Interval = 1 }
    @{ Metric = 'TotalRequestUnits'; Name = 'TotalRequestUnits'; Aggregation = 'Total'; StatusCode = ''; Interval = 1 }
    @{ Metric = 'TotalRequests'; Name = 'TotalRequests'; Aggregation = 'Count'; StatusCode = ''; Interval = 1 }
    @{ Metric = 'ThrottledRequests'; Name = 'TotalRequests'; Aggregation = 'Count'; StatusCode = '429'; Interval = 1 }
    @{ Metric = 'ServerSideLatencyGateway'; Name = 'ServerSideLatencyGateway'; Aggregation = 'Average'; StatusCode = ''; Interval = 1 }
    @{ Metric = 'ProvisionedThroughput'; Name = 'ProvisionedThroughput'; Aggregation = 'Maximum'; StatusCode = ''; Interval = 60 }
    @{ Metric = 'ServiceAvailability'; Name = 'ServiceAvailability'; Aggregation = 'Average'; StatusCode = ''; Interval = 60 }
)

function ConvertTo-DbHubTimeText {
    # A time as UTC yyyy-MM-ddTHH:mm:ssZ, or '' for anything that isn't a time. A time without a kind is taken as UTC.
    param(
        [AllowNull()]
        [object] $Value
    )

    if (-not ($Value -is [datetime])) {
        return ''
    }
    $time = [datetime]$Value
    if ($time.Kind -eq [System.DateTimeKind]::Local) {
        $time = $time.ToUniversalTime()
    }
    return $time.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Test-DbHubSessionCapable {
    # Whether these are the control's settings with the session's parts (2026-11-14): its vault and the API versions the
    # session uses. The safety stop's DbHub-Stop has none of them, so its stops are as before.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    if (-not [string](Get-DbHubMember -InputObject $Settings -Name 'controlVault')) {
        return $false
    }
    $versions = Get-DbHubMember -InputObject $Settings -Name 'apiVersions'
    foreach ($type in 'Microsoft.KeyVault/vaults', 'Microsoft.Resources/tags', 'Microsoft.Insights/metrics', 'Microsoft.DBforPostgreSQL/flexibleServers/configurations') {
        if (-not [string](Get-DbHubMember -InputObject $versions -Name $type)) {
            return $false
        }
    }
    return $true
}

function Set-DbHubVaultSecret {
    <#
    .SYNOPSIS
    Writes one of the control vault's session secrets through Azure Resource Manager (Secrets - Create Or Update, with the
    control identity's Microsoft.KeyVault/vaults/secrets/write on that secret only), which works with the vault private.
    The value is the session's status or its metrics, never a credential. Returns Ok, StatusCode, and Error.
    https://learn.microsoft.com/rest/api/keyvault/keyvault/secrets/create-or-update
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes only the session''s own status or metrics secret; its callers decide.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value,

        [AllowNull()]
        [System.Collections.IDictionary] $Tags
    )

    $settings = $Context.Settings
    $vault = [string](Get-DbHubMember -InputObject $settings -Name 'controlVault')
    if ($vault -notmatch '^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$' -or $Name -notmatch '^[A-Za-z0-9-]{1,127}$') {
        return [pscustomobject]@{ Ok = $false; StatusCode = 0; Error = 'the runbook settings name no control vault' }
    }
    # The vault's pinned version, which its secrets share (config/versions.json).
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.KeyVault/vaults'
    $path = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.KeyVault/vaults/{2}/secrets/{3}' -f $settings.subscriptionId, $settings.controlResourceGroup, $vault, $Name
    $body = @{ properties = @{ value = $Value; contentType = 'application/json' } }
    if ($null -ne $Tags) {
        $body['tags'] = $Tags
    }
    $put = Invoke-DbHubArm -Context $Context -Method PUT -Path $path -ApiVersion $version -Body $body
    # The version this write created (2026-11-20, ADR 0031): Azure Resource Manager returns it in secretUriWithVersion, which
    # the RCA's bundle index lists (https://learn.microsoft.com/rest/api/keyvault/keyvault/secrets/create-or-update).
    $written = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $put.Body -Name 'properties') -Name 'secretUriWithVersion')
    $secretVersion = ''
    if ($written -match ('/secrets/{0}/([0-9a-f]{{32}})$' -f [regex]::Escape($Name))) {
        $secretVersion = $Matches[1]
    }
    return [pscustomobject]@{ Ok = ($put.StatusCode -in 200, 201); StatusCode = $put.StatusCode; Error = $put.Error; Version = $secretVersion }
}

function Set-DbHubResourceGroupTag {
    <#
    .SYNOPSIS
    Merges tags into the demo resource group's (Tags - Update At Scope, operation Merge, with the control identity's
    Microsoft.Resources/tags/write at the demo resource group): the busy marker, the session's ID and start, and the
    replica's size. Returns Ok, StatusCode, and Error.
    https://learn.microsoft.com/rest/api/resources/tags/update-at-scope
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Merges only the session''s own tags; Start-DbHubSession and Stop-DbHubDemo, its callers, ask ShouldProcess.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Tags
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Resources/tags'
    $path = '{0}/providers/Microsoft.Resources/tags/default' -f (Get-DbHubDemoPath -Settings $Context.Settings)
    $patch = Invoke-DbHubArm -Context $Context -Method PATCH -Path $path -ApiVersion $version -Body @{ operation = 'Merge'; properties = @{ tags = $Tags } }
    return [pscustomobject]@{ Ok = ($patch.StatusCode -in 200, 201, 202); StatusCode = $patch.StatusCode; Error = $patch.Error }
}

function New-DbHubSessionStatus {
    # The session's status (schemaVersion 1), which the control notebook reads from the control vault: names, times, each
    # step in plain words with its fix, the dispatches, T4, its read replica, the replica-lag beat's windows, and when T5 is
    # back at its baseline after its last ru-storm (2026-11-18).
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $SessionId,

        [string] $RequestedBy = 'notebook',

        [int] $DurationMinutes = 0,

        [AllowNull()]
        [object] $Tags
    )

    $settings = $Context.Settings
    $deploymentId = [string](Get-DbHubMember -InputObject $Tags -Name 'deploymentId')
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        $deploymentId = ''
    }
    $names = [ordered]@{ resourceGroup = [string]$settings.demoResourceGroup; deploymentId = $deploymentId; sqlVm = [string]$settings.sqlVmName; hostVm = [string]$settings.hostVmName; t2Guest = [string](Get-DbHubMember -InputObject $settings -Name 't2GuestName'); t3Server = ''; t3Database = [string]$settings.demoDatabase; t4Server = ''; t4Replica = ''; t5Account = '' }
    if ($deploymentId) {
        $names['t3Server'] = '{0}{1}' -f $settings.t3ServerPrefix, $deploymentId
        $names['t4Server'] = '{0}{1}' -f $settings.t4ServerPrefix, $deploymentId
        $prefix = [string](Get-DbHubMember -InputObject $settings -Name 't4ReplicaPrefix')
        if ($prefix) {
            $names['t4Replica'] = '{0}{1}' -f $prefix, $deploymentId
        }
        # T5's Azure Cosmos DB account (2026-11-18, ADR 0027), when the settings name it.
        $names['t5Account'] = Get-DbHubT5Account -Settings $settings -Tags $Tags
    }
    return [ordered]@{
        schemaVersion     = 1
        sessionId         = $SessionId
        phase             = 'accepted'
        updatedUtc        = ''
        jobId             = [string]$Context.JobId
        requestedBy       = $RequestedBy
        acceptedUtc       = ConvertTo-DbHubTimeText -Value $Context.NowUtc
        durationMinutes   = $DurationMinutes
        plannedMinutes    = 0
        runEndUtc         = ''
        autoStopUtc       = ''
        autoStopBackupUtc = ''
        autoShutdownUtc   = ''
        timeZone          = [string]$settings.autoShutdownTimeZone
        names             = $names
        busy              = [ordered]@{ marked = $false; untilUtc = ''; nightlyStopUtc = ''; note = '' }
        steps             = @()
        dispatched        = @()
        skipped           = @()
        # The dispatch Run Commands Azure accepted (vm, name, targets), which the checks of the session's hosts read
        # (2026-11-16).
        runCommands       = @()
        monitoring        = ''
        t4                = [ordered]@{ state = ''; sku = ''; tier = ''; dispatchUtc = '' }
        # When each target's activity went out (2026-11-14): its showcase's cycles start there, for the notebook's guide.
        dispatchUtc       = [ordered]@{}
        replica           = [ordered]@{ state = ''; sizeAsked = ''; sizeUsed = ''; attempts = @(); readyUtc = ''; note = ''; fix = '' }
        replicaLag        = [ordered]@{ planned = $false; windows = @(); note = ''; fix = '' }
        # When T5 is back at its baseline after its last ru-storm (2026-11-18; since 2026-11-19 its showcase runs the whole
        # session, and its baseline runs on after it: Get-DbHubT5LastStormEnd); empty without T5's showcase.
        t5                = [ordered]@{ endUtc = '' }
        # The session's evidence for the Incident RCA (ADR 0031): the bundles its exports wrote, the documents in them, and
        # what's left on the VMs (ConvertTo-DbHubRcaState); the re-checks and the stop add to it.
        rca               = (ConvertTo-DbHubRcaState -State $null -SessionId $SessionId)
        message           = ''
    }
}

function Add-DbHubSessionStep {
    # One step of the session for the notebook: what (Plan, Busy, Start, Activity, T4, Replica, ReplicaLag, T5, Stop,
    # Capture), its state (Pass, Warning, Fail, or Info), and the message and fix in plain words. The last 60 are kept.
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [Parameter(Mandatory = $true)]
        [string] $Step,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Pass', 'Warning', 'Fail', 'Info')]
        [string] $State,

        [Parameter(Mandatory = $true)]
        [string] $Message,

        [string] $Fix = ''
    )

    $item = [ordered]@{ step = $Step; state = $State; atUtc = (ConvertTo-DbHubTimeText -Value (Get-DbHubUtcNow)); message = (ConvertTo-DbHubSafeText -Text $Message); fix = (ConvertTo-DbHubSafeText -Text $Fix) }
    $steps = @($Status['steps']) + @($item)
    if ($steps.Count -gt 60) {
        $steps = @($steps | Select-Object -Last 60)
    }
    $Status['steps'] = $steps
}

function Write-DbHubSessionStatus {
    <#
    .SYNOPSIS
    Writes the session's status to the control vault (statusName), tagged with the session and its phase, for the
    control notebook. Returns $true when it was written. Never throws: a write that fails is logged once, and the
    session goes on.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [string] $Phase = ''
    )

    if ($Phase) {
        $Status['phase'] = $Phase
    }
    $Status['updatedUtc'] = ConvertTo-DbHubTimeText -Value (Get-DbHubUtcNow)
    try {
        $json = ConvertTo-Json -InputObject $Status -Depth 8 -Compress
        # A Key Vault secret holds 25 KB; the oldest steps go first.
        while ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt 20000 -and @($Status['steps']).Count -gt 5) {
            $Status['steps'] = @(@($Status['steps']) | Select-Object -Last ([int][System.Math]::Floor(@($Status['steps']).Count / 2)))
            $json = ConvertTo-Json -InputObject $Status -Depth 8 -Compress
        }
        $name = [string](Get-DbHubMember -InputObject $Context.Settings -Name 'statusName')
        if (-not $name) {
            $name = 'dbhub-session-status'
        }
        # The copy DbHub-Monitor reads back, because the vault's can't be read through Azure Resource Manager (2026-11-16).
        $null = Save-DbHubSessionStatusCopy -Context $Context -Json $json
        $written = Set-DbHubVaultSecret -Context $Context -Name $name -Value $json -Tags @{ sessionId = [string]$Status['sessionId']; phase = [string]$Status['phase'] }
        if ($written.Ok) {
            return $true
        }
        if (-not (Get-DbHubMember -InputObject $Context -Name 'StatusWarned')) {
            $Context | Add-Member -NotePropertyName 'StatusWarned' -NotePropertyValue $true -Force
            Write-DbHubLog -Context $Context -Message ('The session''s status couldn''t be written to the control vault ({0}), so the notebook can''t follow this session; an Owner runs ./scripts/grant-safety-stop.ps1, which lets the control identity write it.' -f $written.Error)
        }
    }
    catch {
        Write-DbHubLog -Context $Context -Message ('The session''s status wasn''t written: {0}' -f $_.Exception.Message)
    }
    return $false
}

$script:DbHubStatusVariable = 'DbHubSessionStatus'

function ConvertTo-DbHubDictionary {
    # A parsed JSON value as ordered dictionaries and arrays, as New-DbHubSessionStatus builds a status, because Windows
    # PowerShell 5.1's ConvertFrom-Json has no -AsHashtable. A time that PowerShell 7 parsed goes back to its text.
    param(
        [AllowNull()]
        [object] $InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }
    if ($InputObject -is [datetime]) {
        return (ConvertTo-DbHubTimeText -Value $InputObject)
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $dictionary = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $dictionary[[string]$property.Name] = ConvertTo-DbHubDictionary -InputObject $property.Value
        }
        return $dictionary
    }
    if ($InputObject -is [System.Array]) {
        $items = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($item in $InputObject) {
            $items.Add((ConvertTo-DbHubDictionary -InputObject $item))
        }
        return , $items.ToArray()
    }
    return $InputObject
}

function Save-DbHubSessionStatusCopy {
    <#
    .SYNOPSIS
    Keeps the session's status, as written to the vault, in the control account's variable DbHubSessionStatus too
    (2026-11-16), which infra/control/control.bicep creates: DbHub-Monitor reads it back to add a host's failure,
    because the identity can't read the vault's value through Azure Resource Manager. Set-AutomationVariable is the
    sandbox's internal cmdlet for an existing variable, with no role needed
    (https://learn.microsoft.com/azure/automation/shared-resources/variables). Only in the control's account (its settings
    name the control vault). Never throws; returns whether it was kept.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $Json
    )

    if (-not [string](Get-DbHubMember -InputObject $Context.Settings -Name 'controlVault') -or -not (Get-Command -Name 'Set-AutomationVariable' -ErrorAction SilentlyContinue)) {
        return $false
    }
    try {
        Set-AutomationVariable -Name $script:DbHubStatusVariable -Value $Json
        return $true
    }
    catch {
        if (-not (Get-DbHubMember -InputObject $Context -Name 'StatusCopyWarned')) {
            $Context | Add-Member -NotePropertyName 'StatusCopyWarned' -NotePropertyValue $true -Force
            Write-DbHubLog -Context $Context -Message ('The session''s status couldn''t be kept for the monitoring re-checks ({0}), so they can''t add a host''s failure to it; ./scripts/deploy.ps1 creates the variable {1}.' -f $_.Exception.Message, $script:DbHubStatusVariable)
        }
        return $false
    }
}

function Read-DbHubSessionStatusCopy {
    # The session's last status from the control account's variable DbHubSessionStatus (Get-AutomationVariable), as
    # ordered dictionaries, or $null when there's none.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    if (-not (Get-Command -Name 'Get-AutomationVariable' -ErrorAction SilentlyContinue)) {
        return $null
    }
    try {
        $text = [string](Get-AutomationVariable -Name $script:DbHubStatusVariable)
        if (-not $text.TrimStart().StartsWith('{')) {
            return $null
        }
        $status = ConvertTo-DbHubDictionary -InputObject ($text | ConvertFrom-Json)
    }
    catch {
        Write-DbHubLog -Context $Context -Message ('The session''s status couldn''t be read back from the variable {0}: {1}' -f $script:DbHubStatusVariable, $_.Exception.Message)
        return $null
    }
    if ($status -isnot [System.Collections.IDictionary]) {
        return $null
    }
    return $status
}

function Get-DbHubDispatchFailure {
    <#
    .SYNOPSIS
    The targets a dispatch Run Command's script says didn't get their activity (#28, 2026-11-17): its last
    DBHUB-DISPATCH line (Get-DbHubWorkloadScript), within the end of its output that the instance view keeps. Returns
    Target, Status, Message, and OldRunner (the target's runner refused the profile or an option, #21) for each target
    named T1 to T5; nothing for output without that line, or one that can't be read.
    #>
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Output
    )

    $line = @(([string]$Output) -split '\r?\n' | Where-Object { $_.StartsWith('DBHUB-DISPATCH ') }) | Select-Object -Last 1
    if (-not $line) {
        return
    }
    try {
        $parsed = $line.Substring(15) | ConvertFrom-Json
    }
    catch {
        return
    }
    foreach ($item in @(Get-DbHubMember -InputObject $parsed -Name 'failed')) {
        $target = [string](Get-DbHubMember -InputObject $item -Name 'target')
        if ($target -notmatch '^T[1-5]$') {
            continue
        }
        $old = Get-DbHubMember -InputObject $item -Name 'oldRunner'
        [pscustomobject]@{ Target = $target; Status = [string](Get-DbHubMember -InputObject $item -Name 'status'); Message = [string](Get-DbHubMember -InputObject $item -Name 'message'); OldRunner = ($old -eq $true -or [string]$old -eq 'true') }
    }
}

function Get-DbHubDispatchSetTime {
    <#
    .SYNOPSIS
    When a dispatch Run Command's script set each target's activity on its VM (2026-11-19): its last DBHUB-SET line
    (Get-DbHubWorkloadScript), with the VM's UTC time right after each target's set returned, within the end of its output
    that the instance view keeps. Returns Target and SetUtc for each target named T1 to T5 with a time; nothing for output
    without that line, or one that can't be read.
    #>
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Output
    )

    $line = @(([string]$Output) -split '\r?\n' | Where-Object { $_.StartsWith('DBHUB-SET ') }) | Select-Object -Last 1
    if (-not $line) {
        return
    }
    try {
        $parsed = $line.Substring(10) | ConvertFrom-Json
    }
    catch {
        return
    }
    foreach ($target in @(Get-DbHubPropertyName -InputObject $parsed)) {
        if ($target -notmatch '^T[1-5]$') {
            continue
        }
        $at = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject $parsed -Name $target)
        if ($null -ne $at) {
            [pscustomobject]@{ Target = $target; SetUtc = $at }
        }
    }
}

function Get-DbHubSessionHealth {
    <#
    .SYNOPSIS
    The hosts of a session that runs (2026-11-16; live, archost01's start ended VMStartTimedOut 53 minutes into a session
    and T2's Run Command failed with it, while the session's status still said T2's activity went out): each VM the
    session's activity went out to, from its instance view (its power state, a failed provisioning, and its VM agent,
    which must be Ready 15 minutes after its targets' activity went out; 2026-11-17), and on a VM that runs, each of the
    session's dispatch Run Commands, from its instance view: one that failed, timed out, was canceled, or ended with a
    non-zero exit code. Its DBHUB-DISPATCH line (Get-DbHubDispatchFailure) names each target whose activity wasn't set,
    with why (#28, 2026-11-17), and a runner older than the control (#21) gets deploy.ps1 as its fix. Azure Resource Manager reads only: one per VM and one per Run Command. A VM's
    failed provisioning counts only from the session's start on, so an older failure (an extension's, say) isn't blamed
    on it. Returns one finding (Message and Fix) per problem, in words that stay the same while the problem does, so a
    check that finds it again adds nothing. It also moves each target's dispatchUtc in -Status to when its Run Command's
    script set the target's activity (its DBHUB-SET line, Get-DbHubDispatchSetTime; 2026-11-19), which the caller writes.
    https://learn.microsoft.com/rest/api/compute/virtual-machines/instance-view
    https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/get-by-virtual-machine
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status
    )

    $settings = $Context.Settings
    # The session's VMs with their targets and Run Commands: from runCommands, or, in a status from before them, from the
    # targets its activity went out to.
    $hosts = [ordered]@{}
    $addHost = {
        param([string] $VmName)
        if (-not $hosts.Contains($VmName)) {
            $hosts[$VmName] = [pscustomobject]@{ Targets = (New-Object -TypeName 'System.Collections.Generic.List[string]'); Commands = (New-Object -TypeName 'System.Collections.Generic.List[object]') }
        }
        return $hosts[$VmName]
    }
    foreach ($command in @(Get-DbHubMember -InputObject $Status -Name 'runCommands')) {
        $vm = [string](Get-DbHubMember -InputObject $command -Name 'vm')
        $name = [string](Get-DbHubMember -InputObject $command -Name 'name')
        if ($vm -notmatch '^[A-Za-z0-9-]{1,64}$' -or $name -notmatch '^[A-Za-z0-9-]{1,64}$') {
            continue
        }
        $entry = & $addHost $vm
        $targets = @(@(Get-DbHubMember -InputObject $command -Name 'targets') | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^T[1-5]$' })
        $entry.Commands.Add([pscustomobject]@{ Name = $name; Targets = $targets })
        foreach ($target in $targets) {
            if (-not $entry.Targets.Contains($target)) {
                $entry.Targets.Add($target)
            }
        }
    }
    if ($hosts.Count -eq 0) {
        foreach ($target in @(Get-DbHubPropertyName -InputObject (Get-DbHubMember -InputObject $Status -Name 'dispatchUtc'))) {
            if ($target -match '^T[1-5]$') {
                $entry = & $addHost (Get-DbHubTargetVm -Settings $settings -Target $target)
                if (-not $entry.Targets.Contains($target)) {
                    $entry.Targets.Add($target)
                }
            }
        }
    }
    $label = {
        param([string[]] $Targets, [string] $VmName)
        $sorted = @($Targets | Sort-Object)
        if ($sorted.Count -eq 0) {
            return $VmName
        }
        if ($sorted.Count -le 2) {
            return ($sorted -join ' and ')
        }
        return ('{0}, and {1}' -f ($sorted[0..($sorted.Count - 2)] -join ', '), $sorted[-1])
    }
    $since = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject $Status -Name 'acceptedUtc')
    # How long a VM may run after its targets' activity went out before an agent that isn't Ready is a problem.
    $agentGraceMinutes = 15
    $vmVersion = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Compute/virtualMachines'
    $commandVersion = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Compute/virtualMachines/runCommands'
    $findings = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($vm in @($hosts.Keys)) {
        $entry = $hosts[$vm]
        $who = & $label $entry.Targets.ToArray() $vm
        $vmFix = 'The session''s other targets go on. For {0}: set STOP_NOW = True and Run all, then Run all again, which starts {1} again; ./scripts/status.ps1 shows its state.' -f $who, $vm
        $view = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/instanceView' -f (Get-DbHubDemoPath -Settings $settings), $vm) -ApiVersion $vmVersion
        if ($view.StatusCode -ne 200) {
            Write-DbHubLog -Context $Context -Message ('{0} couldn''t be read for the session''s check: {1}' -f $vm, $view.Error)
            continue
        }
        $power = ''
        $failed = ''
        foreach ($item in @(Get-DbHubMember -InputObject $view.Body -Name 'statuses')) {
            $code = [string](Get-DbHubMember -InputObject $item -Name 'code')
            if ($code -like 'PowerState/*') {
                $power = $code.Substring(11)
            }
            elseif ($code -like 'ProvisioningState/failed*') {
                $at = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject $item -Name 'time')
                if ($null -eq $since -or $null -eq $at -or $at -ge $since) {
                    $parts = $code -split '/'
                    $failed = 'failed'
                    if ($parts.Count -ge 3 -and $parts[2] -match '^[A-Za-z0-9]{1,80}$') {
                        $failed = $parts[2]
                    }
                    Write-DbHubLog -Context $Context -Message ('{0}: {1} ({2})' -f $vm, $code, [string](Get-DbHubMember -InputObject $item -Name 'message'))
                }
            }
        }
        if ($power -in 'deallocated', 'deallocating', 'stopped', 'stopping') {
            # Live, 2026-11-17: sqlvm01 drives T1, T3, and T4, and "T1, T3, and T4 has no activity" read wrong.
            $verb = 'has'
            if ($entry.Targets.Count -gt 1) {
                $verb = 'have'
            }
            $findings.Add([pscustomobject]@{ Message = ('{0}: {1} is {2}, so {0} {3} no activity now.' -f $who, $vm, $power, $verb); Fix = $vmFix })
            continue
        }
        if ($failed) {
            $findings.Add([pscustomobject]@{ Message = ('{0}: Azure says {1}''s last operation failed ({2}), so {0} may have no activity this session.' -f $who, $vm, $failed); Fix = $vmFix })
            continue
        }
        if ($power -ne 'running') {
            continue
        }
        # A running VM whose agent isn't Ready can't run the Run Command that sets its targets' activity (live, 2026-11-17:
        # archost01's agent never got its goal state after the session's start, the status said T2's activity went out for
        # the whole session, and Azure ends such a start VMStartTimedOut about 58 minutes in). Counted from the earliest
        # dispatch of the VM's targets, so a VM that has only just started isn't blamed; the instance view read above
        # carries the agent's status, so this costs no read.
        $agentStatus = @(Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $view.Body -Name 'vmAgent') -Name 'statuses') | Select-Object -First 1
        $agentText = [string](Get-DbHubMember -InputObject $agentStatus -Name 'displayStatus')
        if ($agentText -ne 'Ready') {
            $outSince = $null
            $dispatch = Get-DbHubMember -InputObject $Status -Name 'dispatchUtc'
            foreach ($target in $entry.Targets) {
                $at = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject $dispatch -Name $target)
                if ($null -ne $at -and ($null -eq $outSince -or $at -lt $outSince)) {
                    $outSince = $at
                }
            }
            if ($null -ne $outSince -and ((Get-DbHubUtcNow) - $outSince).TotalMinutes -ge $agentGraceMinutes) {
                $agentLog = 'no status'
                if ($agentText) {
                    $agentLog = '{0}: {1}' -f $agentText, [string](Get-DbHubMember -InputObject $agentStatus -Name 'message')
                }
                Write-DbHubLog -Context $Context -Message ('{0}: its VM agent isn''t Ready ({1}).' -f $vm, $agentLog)
                $findings.Add([pscustomobject]@{ Message = ('{0}: {1}''s VM agent wasn''t Ready {2} minutes after {0}''s activity went out, so the Run Command that sets it can''t run, and {0} may have no activity this session.' -f $who, $vm, $agentGraceMinutes); Fix = ('The session''s other targets go on. For {0}: set STOP_NOW = True and Run all; ./scripts/status.ps1 shows {1}''s state, and docs/troubleshooting.md says what brings its agent back ("A host''s VM agent that isn''t Ready").' -f $who, $vm) })
                continue
            }
        }
        foreach ($command in $entry.Commands) {
            $read = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/runCommands/{2}?$expand=instanceView' -f (Get-DbHubDemoPath -Settings $settings), $vm, $command.Name) -ApiVersion $commandVersion
            if ($read.StatusCode -ne 200) {
                continue
            }
            $instance = Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $read.Body -Name 'properties') -Name 'instanceView'
            # Each target's showcase counts its cycles from when its runner set the profile, which the dispatch script's
            # DBHUB-SET line gives (2026-11-19; live: on a VM that had just started, 2 minutes 41 seconds after Azure
            # accepted the Run Command, and every planned time of T3's showcase came that much early). dispatchUtc moves to
            # it, before the session's start writes "running", so the control notebook's guide, its live view, and the
            # session's history count from it too. Only later, and by at most an hour (T2's guest may take more than 30
            # minutes after a cold start: the script's 12-minute heartbeat wait, then up to 20 for its SQL Server); a
            # target that wasn't set, or a Run Command that hasn't ended, keeps the accepted time.
            $anchors = Get-DbHubMember -InputObject $Status -Name 'dispatchUtc'
            if ($anchors -is [System.Collections.IDictionary]) {
                foreach ($set in @(Get-DbHubDispatchSetTime -Output ([string](Get-DbHubMember -InputObject $instance -Name 'output')) | Where-Object { $command.Targets -contains $_.Target })) {
                    $accepted = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject $anchors -Name $set.Target)
                    if ($null -eq $accepted -or $set.SetUtc -le $accepted.AddSeconds(5) -or $set.SetUtc -gt $accepted.AddMinutes(60)) {
                        continue
                    }
                    $anchors[$set.Target] = ConvertTo-DbHubTimeText -Value $set.SetUtc
                    Write-DbHubLog -Context $Context -Message ('{0}: its activity was set on {1} at {2} UTC, {3} s after Azure accepted the Run Command; the session''s times for {0} count from then.' -f $set.Target, $vm, $set.SetUtc.ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture), [int]($set.SetUtc - $accepted).TotalSeconds)
                }
            }
            $state = [string](Get-DbHubMember -InputObject $instance -Name 'executionState')
            $exit = Get-DbHubMember -InputObject $instance -Name 'exitCode'
            # "A nonzero ExitCode indicates an unsuccessful execution" (Learn, managed Run Commands), whatever the state says.
            $exitFailed = $state -eq 'Succeeded' -and $null -ne $exit -and [int]$exit -ne 0
            if ($state -notin 'Failed', 'TimedOut', 'Canceled' -and -not $exitFailed) {
                continue
            }
            $showOutput = 'Its output: az vm run-command show -g {0} --vm-name {1} -n {2} --instance-view.' -f $settings.demoResourceGroup, $vm, $command.Name
            # The targets whose activity wasn't set, from the dispatch script's DBHUB-DISPATCH line (#28), each by name.
            $failedTargets = @(Get-DbHubDispatchFailure -Output ([string](Get-DbHubMember -InputObject $instance -Name 'output')) | Where-Object { $command.Targets -contains $_.Target })
            if ($failedTargets.Count -gt 0) {
                Write-DbHubLog -Context $Context -Message ('{0}: Run Command {1} ended {2}; no activity was set for {3}.' -f $vm, $command.Name, $state, (($failedTargets | ForEach-Object { $_.Target }) -join ', '))
                foreach ($failed in $failedTargets) {
                    if ($failed.OldRunner) {
                        # An older workload runner refuses the showcase or its options (#21): deploy.ps1 updates it.
                        $findings.Add([pscustomobject]@{ Message = ('{0}: {1}''s workload runner is older than this session control and refused its activity, so {0} doesn''t get this session''s activity.' -f $failed.Target, $vm); Fix = ('The session''s other targets go on. To give {0} its activity: set STOP_NOW = True and Run all to end the session, run ./scripts/deploy.ps1, which updates the workload runner on {1}, then Run all again. {2}' -f $failed.Target, $vm, $showOutput) })
                    }
                    else {
                        $findings.Add([pscustomobject]@{ Message = ('{0}: its activity wasn''t set on {1} ({2}: {3}), so {0} doesn''t get this session''s activity.' -f $failed.Target, $vm, $failed.Status, $failed.Message); Fix = ('{0} The session''s other targets go on; for {1}, set STOP_NOW = True and Run all, then Run all again.' -f $showOutput, $failed.Target) })
                    }
                }
                continue
            }
            $exitText = ''
            if ($null -ne $exit) {
                $exitText = ', exit code {0}' -f [int]$exit
            }
            $ended = '{0}{1}' -f $state, $exitText
            if ($exitFailed) {
                $ended = 'with exit code {0}' -f [int]$exit
            }
            $commandWho = & $label $command.Targets $vm
            Write-DbHubLog -Context $Context -Message ('{0}: Run Command {1} ended {2}: {3}' -f $vm, $command.Name, $ended, [string](Get-DbHubMember -InputObject $instance -Name 'executionMessage'))
            $findings.Add([pscustomobject]@{ Message = ('{0}: the Run Command {1} that set its activity on {2} ended {3}, so {0} may have no activity this session.' -f $commandWho, $command.Name, $vm, $ended); Fix = ('{0} The session''s other targets go on; for {1}, set STOP_NOW = True and Run all, then Run all again.' -f $showOutput, $commandWho) })
        }
    }
    return $findings.ToArray()
}

function Add-DbHubSessionHealthStep {
    # Adds each finding of Get-DbHubSessionHealth as a Host step (Warning) that the status doesn't have yet. Returns how
    # many it added.
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [AllowEmptyCollection()]
        [object[]] $Finding = @()
    )

    $known = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    foreach ($step in @($Status['steps'])) {
        if ([string](Get-DbHubMember -InputObject $step -Name 'step') -eq 'Host') {
            $null = $known.Add([string](Get-DbHubMember -InputObject $step -Name 'message'))
        }
    }
    $added = 0
    foreach ($item in $Finding) {
        if ($null -eq $item -or -not $known.Add((ConvertTo-DbHubSafeText -Text ([string]$item.Message)))) {
            continue
        }
        Add-DbHubSessionStep -Status $Status -Step 'Host' -State 'Warning' -Message ([string]$item.Message) -Fix ([string]$item.Fix)
        $added++
    }
    return $added
}

function Update-DbHubSessionHealth {
    <#
    .SYNOPSIS
    DbHub-Monitor's look at a running session's hosts (2026-11-16): the session's last status from its copy (the
    variable DbHubSessionStatus), the checks of Get-DbHubSessionHealth, and the status written again, to the vault and
    the copy, only when a problem is new, and only while the session runs: before its end, and while its copy is still the
    one it read, untouched since, right before the write, so a newer status, such as the session's end, is never
    overwritten. Never throws. Returns Outcome (NoSession, NoStatus, Ended, Healthy, Known, Changed, Warned) and Note, a
    sentence for the monitor's result.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes only the running session''s own status, from DbHub-Monitor''s scheduled re-check, which starts or stops nothing.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $session = [string](Get-DbHubMember -InputObject $Tags -Name 'DbHubSessionId')
    if ($session -notmatch '^[0-9a-f]{32}$') {
        return [pscustomobject]@{ Outcome = 'NoSession'; Note = '' }
    }
    try {
        $status = Read-DbHubSessionStatusCopy -Context $Context
        if ($null -eq $status) {
            # No copy (a variable that doesn't exist says so once, in Read-DbHubSessionStatusCopy).
            return [pscustomobject]@{ Outcome = 'NoStatus'; Note = '' }
        }
        if ([string]$status['sessionId'] -ne $session -or [string]$status['phase'] -ne 'running') {
            # A session that has ended, or a run after one: nothing runs to check.
            return [pscustomobject]@{ Outcome = 'NoSession'; Note = '' }
        }
        $readUpdated = [string]$status['updatedUtc']
        $end = ConvertTo-DbHubUtc -Value $status['runEndUtc']
        if ($null -ne $end -and (Get-DbHubUtcNow) -ge $end) {
            return [pscustomobject]@{ Outcome = 'Ended'; Note = '' }
        }
        $findings = @(Get-DbHubSessionHealth -Context $Context -Status $status)
        if ($findings.Count -eq 0) {
            return [pscustomobject]@{ Outcome = 'Healthy'; Note = ' The session''s hosts run.' }
        }
        $added = Add-DbHubSessionHealthStep -Status $status -Finding $findings
        if ($added -eq 0) {
            return [pscustomobject]@{ Outcome = 'Known'; Note = ' The session''s status already says what doesn''t run.' }
        }
        # Never over a newer status (the coordinator's guard, 2026-11-16): the copy must be the one read above, of a
        # session that still runs, or the session's end or another job wrote since, and this write would undo it.
        $again = Read-DbHubSessionStatusCopy -Context $Context
        if ($null -eq $again -or [string]$again['sessionId'] -ne $session -or [string]$again['phase'] -ne 'running' -or [string]$again['updatedUtc'] -ne $readUpdated) {
            Write-DbHubLog -Context $Context -Message 'The session''s status changed while its hosts were checked (it ended, or another job wrote it), so this check didn''t write it.'
            return [pscustomobject]@{ Outcome = 'Changed'; Note = '' }
        }
        $null = Write-DbHubSessionStatus -Context $Context -Status $status
        $texts = @(@($status['steps']) | Select-Object -Last $added | ForEach-Object { [string](Get-DbHubMember -InputObject $_ -Name 'message') })
        return [pscustomobject]@{ Outcome = 'Warned'; Note = (' The session''s status now says: {0}' -f ($texts -join ' ')) }
    }
    catch {
        Write-DbHubLog -Context $Context -Message ('The session''s hosts weren''t checked: {0}' -f $_.Exception.Message)
        return [pscustomobject]@{ Outcome = 'NoStatus'; Note = '' }
    }
}

function Get-DbHubT4Server {
    # T4 as Azure Resource Manager returns it (Servers - Get), for its replica's creation: Name, State (as Get-DbHubT4),
    # StatusCode, and Body ($null without one).
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $deploymentId = [string](Get-DbHubMember -InputObject $Tags -Name 'deploymentId')
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        return [pscustomobject]@{ Name = ''; State = 'Unknown'; StatusCode = 0; Body = $null }
    }
    $name = '{0}{1}' -f $Context.Settings.t4ServerPrefix, $deploymentId
    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.DBforPostgreSQL/flexibleServers'
    $read = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{1}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $name) -ApiVersion $version
    $state = 'Unknown'
    if ($read.StatusCode -eq 404) {
        $state = 'Missing'
    }
    elseif ($read.StatusCode -eq 200) {
        $state = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $read.Body -Name 'properties') -Name 'state')
    }
    return [pscustomobject]@{ Name = $name; State = $state; StatusCode = $read.StatusCode; Body = $read.Body }
}

function Get-DbHubReplicaSizeOrder {
    <#
    .SYNOPSIS
    The sizes a session's read replica tries, in order, never with fewer vCores than T4 ("the same or a higher number of
    vCores as the source server", ADR 0025), as the module's Get-DemoT4ReplicaSizeOrder orders them, without its zone
    retry: the recorded size (DbHubT4ReplicaSize, "<size>@<zone or any>") first when it has T4's vCores, then T4's own
    size, a larger recorded size, the documented sizes with T4's vCores, then larger ones. Pure.
    #>
    param(
        [AllowEmptyString()]
        [string] $T4SkuName = '',

        [AllowEmptyString()]
        [string] $Record = '',

        [AllowEmptyCollection()]
        [string[]] $Sizes = @()
    )

    $order = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $t4VCores = Get-DbHubT4VCore -SkuName $T4SkuName
    $documented = @($Sizes | Where-Object { $_ -cmatch '^Standard_[A-Za-z0-9_]+$' })
    $later = ''
    if ($Record -match '^(Standard_[A-Za-z0-9_]+)@(any|[123])$') {
        $recorded = $Matches[1]
        $recordedVCores = Get-DbHubT4VCore -SkuName $recorded
        if ($recorded -cin $documented -and $recordedVCores -eq $t4VCores) {
            $order.Add($recorded)
        }
        elseif ($recorded -cin $documented -and $recordedVCores -gt $t4VCores) {
            $later = $recorded
        }
    }
    if ($T4SkuName -cmatch '^Standard_[A-Za-z0-9_]+$' -and -not $order.Contains($T4SkuName)) {
        $order.Add($T4SkuName)
    }
    if ($later -and -not $order.Contains($later)) {
        $order.Add($later)
    }
    foreach ($size in $documented) {
        if ((Get-DbHubT4VCore -SkuName $size) -eq $t4VCores -and -not $order.Contains($size)) {
            $order.Add($size)
        }
    }
    $larger = @($documented | Where-Object { (Get-DbHubT4VCore -SkuName $_) -gt $t4VCores } | Sort-Object -Property @{ Expression = { Get-DbHubT4VCore -SkuName $_ } }, @{ Expression = { [System.Array]::IndexOf($documented, $_) } })
    foreach ($size in $larger) {
        if (-not $order.Contains($size)) {
            $order.Add($size)
        }
    }
    return $order.ToArray()
}

function Send-DbHubT4ReplicaCreate {
    <#
    .SYNOPSIS
    Asks Azure for T4's read replica at SkuName (Servers - Create, createMode Replica), as infra/replica/pgreplica01.bicep
    makes it: T4's location, delegated subnet, private DNS zone, and storage, General Purpose, no public network access,
    and storage auto-grow off, with the demo's tags and component t4-replica. Returns once Azure answered: Accepted,
    StatusCode, Code (SkuNotAvailable, SourceNotReady, AlreadyExists, NotGranted, or Other), and Error.
    https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/create
    https://learn.microsoft.com/azure/postgresql/read-replica/how-to-create-read-replica
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [object] $Source,

        [Parameter(Mandatory = $true)]
        [string] $SkuName,

        [AllowNull()]
        [object] $Tags
    )

    $properties = Get-DbHubMember -InputObject $Source -Name 'properties'
    $network = Get-DbHubMember -InputObject $properties -Name 'network'
    $storage = Get-DbHubMember -InputObject $properties -Name 'storage'
    $size = [int](Get-DbHubMember -InputObject $storage -Name 'storageSizeGB')
    if ($size -le 0) {
        $size = 32
    }
    $tier = [string](Get-DbHubMember -InputObject $storage -Name 'tier')
    if (-not $tier) {
        $tier = 'P4'
    }
    $replicaTags = [ordered]@{}
    foreach ($key in 'solution', 'environment', 'owner', 'purpose', 'costCenter', 'autoShutdown', 'deploymentId', 'expiresOn') {
        $value = [string](Get-DbHubMember -InputObject $Tags -Name $key)
        if ($value) {
            $replicaTags[$key] = $value
        }
    }
    $replicaTags['component'] = 't4-replica'
    $body = [ordered]@{
        location   = [string](Get-DbHubMember -InputObject $Source -Name 'location')
        tags       = $replicaTags
        sku        = [ordered]@{ name = $SkuName; tier = 'GeneralPurpose' }
        properties = [ordered]@{
            createMode             = 'Replica'
            sourceServerResourceId = [string](Get-DbHubMember -InputObject $Source -Name 'id')
            storage                = [ordered]@{ storageSizeGB = $size; tier = $tier; autoGrow = 'Disabled'; type = 'Premium_LRS' }
            network                = [ordered]@{ delegatedSubnetResourceId = [string](Get-DbHubMember -InputObject $network -Name 'delegatedSubnetResourceId'); privateDnsZoneArmResourceId = [string](Get-DbHubMember -InputObject $network -Name 'privateDnsZoneArmResourceId'); publicNetworkAccess = 'Disabled' }
        }
    }
    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.DBforPostgreSQL/flexibleServers'
    $put = Invoke-DbHubArm -Context $Context -Method PUT -Path ('{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{1}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $Name) -ApiVersion $version -Body $body
    if ($put.StatusCode -in 200, 201, 202) {
        return [pscustomobject]@{ Accepted = $true; StatusCode = $put.StatusCode; Code = ''; Error = '' }
    }
    # The error's code and message, from Invoke-DbHubArm's text and the response body both.
    $detail = Get-DbHubMember -InputObject $put.Body -Name 'error'
    $text = ('{0} {1} {2}' -f $put.Error, [string](Get-DbHubMember -InputObject $detail -Name 'code'), [string](Get-DbHubMember -InputObject $detail -Name 'message')).Trim()
    $code = 'Other'
    if ($put.StatusCode -eq 403 -or $text -match 'AuthorizationFailed') {
        $code = 'NotGranted'
    }
    elseif ($text -match 'SkuNotAvailable') {
        $code = 'SkuNotAvailable'
    }
    elseif ($text -match 'ReadReplicaServerInUnexpectedState') {
        $code = 'SourceNotReady'
    }
    elseif ($text -match 'ReadReplicaAlreadyExistWithGivenName') {
        $code = 'AlreadyExists'
    }
    return [pscustomobject]@{ Accepted = $false; StatusCode = $put.StatusCode; Code = $code; Error = (ConvertTo-DbHubSafeText -Text $text) }
}

function Set-DbHubT4ReplicaParameter {
    # The replica's max_standby_streaming_delay (Configurations - Put), as its template sets it: how long replaying T4's
    # changes waits for a query on the replica, which the replica-lag beat needs. Dynamic: no restart. Returns Ok and Error.
    # https://learn.microsoft.com/rest/api/postgresql/flexibleserver/configurations/put
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Start-DbHubSession, its caller, asks ShouldProcess.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [int] $Milliseconds
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.DBforPostgreSQL/flexibleServers/configurations'
    $path = '{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{1}/configurations/max_standby_streaming_delay' -f (Get-DbHubDemoPath -Settings $Context.Settings), $Name
    $put = Invoke-DbHubArm -Context $Context -Method PUT -Path $path -ApiVersion $version -Body @{ properties = @{ value = [string]$Milliseconds; source = 'user-override' } }
    return [pscustomobject]@{ Ok = ($put.StatusCode -in 200, 201, 202); Error = $put.Error }
}

function Remove-DbHubT4Replica {
    <#
    .SYNOPSIS
    Deletes T4's read replica (Servers - Delete, with the control identity's flexibleServers/delete, 2026-11-14) and waits
    until it's gone, at most WaitMinutes, so nothing bills for it between sessions. Only a server whose replicationRole
    says it's a read replica is deleted. Returns Outcome (Deleted, Missing, NotConfigured, NotGranted, NotReplica, or
    Failed), Name, and Error.
    https://learn.microsoft.com/rest/api/postgresql/flexibleserver/servers/delete
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stop-DbHubDemo, its caller, asks ShouldProcess.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [int] $WaitMinutes = 15,

        [int] $PollSeconds = 15
    )

    $replica = Get-DbHubT4Replica -Context $Context -Tags $Tags
    $outcome = [pscustomobject]@{ Outcome = ''; Name = [string]$replica.Name; Error = '' }
    if ($replica.State -in 'NotConfigured', 'Missing') {
        $outcome.Outcome = $replica.State
        return $outcome
    }
    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.DBforPostgreSQL/flexibleServers'
    $path = '{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{1}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $replica.Name
    if ($replica.State -ne 'Dropping') {
        $read = Invoke-DbHubArm -Context $Context -Method GET -Path $path -ApiVersion $version
        $role = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $read.Body -Name 'properties') -Name 'replicationRole')
        if ($read.StatusCode -eq 404) {
            $outcome.Outcome = 'Missing'
            return $outcome
        }
        if ($read.StatusCode -ne 200 -or $role -notin 'AsyncReplica', 'GeoAsyncReplica') {
            # Never delete a server that isn't a read replica, whatever its name.
            $outcome.Outcome = 'NotReplica'
            $outcome.Error = if ($read.StatusCode -eq 200) { 'its replicationRole is {0}, not a read replica''s, so it wasn''t deleted' -f $(if ($role) { $role } else { 'empty' }) } else { 'it couldn''t be read: {0}' -f $read.Error }
            return $outcome
        }
        $deleted = Invoke-DbHubArm -Context $Context -Method DELETE -Path $path -ApiVersion $version
        if ($deleted.StatusCode -eq 404) {
            $outcome.Outcome = 'Missing'
            return $outcome
        }
        if ($deleted.StatusCode -eq 403 -or $deleted.Error -match 'AuthorizationFailed') {
            $outcome.Outcome = 'NotGranted'
            $outcome.Error = $deleted.Error
            return $outcome
        }
        if ($deleted.StatusCode -notin 200, 202, 204) {
            $outcome.Outcome = 'Failed'
            $outcome.Error = $deleted.Error
            return $outcome
        }
        Write-DbHubLog -Context $Context -Message ('{0}: delete accepted (T4''s read replica).' -f $replica.Name)
    }
    $giveUp = (Get-DbHubUtcNow).AddMinutes($WaitMinutes)
    while ($true) {
        $now = Get-DbHubT4Replica -Context $Context -Tags $Tags
        if ($now.State -eq 'Missing') {
            $outcome.Outcome = 'Deleted'
            return $outcome
        }
        if ((Get-DbHubUtcNow) -ge $giveUp) {
            $outcome.Outcome = 'Failed'
            $outcome.Error = 'it was still {0} after {1} minutes; Azure finishes deleting it on its own' -f $now.State, $WaitMinutes
            return $outcome
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Stop-DbHubT4Confirmed {
    <#
    .SYNOPSIS
    T4's stop right after its read replica's deletion, confirmed: Azure refuses a primary's stop while an operation still
    runs on its replica (SourceReplicasStartStopOrder). Live, 2026-11-14: the replica's GET answered 404 about 20 seconds
    before its delete finished, and T4's stop, accepted, failed a minute later, which left T4 running after the session's
    auto-stop. So the stop is asked again until T4 is Stopping or Stopped, at most Attempts times within WaitMinutes.
    Returns Stopped ($true when T4 is Stopping or Stopped), Attempts, and Error.
    https://learn.microsoft.com/azure/postgresql/read-replica/concepts-read-replicas
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Stop-DbHubDemo, its caller, asks ShouldProcess.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [int] $WaitMinutes = 10,

        [int] $Attempts = 3,

        [int] $SettleSeconds = 150,

        [int] $PollSeconds = 20
    )

    $giveUp = (Get-DbHubUtcNow).AddMinutes($WaitMinutes)
    $tries = 0
    $state = ''
    while ($tries -lt $Attempts -and (Get-DbHubUtcNow) -lt $giveUp) {
        $tries++
        $null = Invoke-DbHubT4Action -Context $Context -Name $Name -Action stop
        # A stop that Azure took starts within seconds; one that failed leaves T4 Ready, and a second stop while the first
        # still runs is refused, so each one gets SettleSeconds to show.
        $settle = (Get-DbHubUtcNow).AddSeconds($SettleSeconds)
        if ($settle -gt $giveUp) {
            $settle = $giveUp
        }
        while ((Get-DbHubUtcNow) -lt $settle) {
            Start-Sleep -Seconds $PollSeconds
            $state = [string](Get-DbHubT4 -Context $Context -Tags $Tags).State
            if ($state -in 'Stopping', 'Stopped') {
                if ($tries -gt 1) {
                    Write-DbHubLog -Context $Context -Message ('{0} is {1} after {2} stops: Azure refused the first while its read replica''s delete finished.' -f $Name, $state.ToLowerInvariant(), $tries)
                }
                return [pscustomobject]@{ Stopped = $true; Attempts = $tries; Error = '' }
            }
        }
        Write-DbHubLog -Context $Context -Message ('{0} is still {1} after stop {2}; asking again.' -f $Name, $(if ($state) { $state } else { 'unknown' }), $tries)
    }
    return [pscustomobject]@{ Stopped = $false; Attempts = $tries; Error = ('it was still {0} after {1} stop(s) in {2} minutes' -f $(if ($state) { $state } else { 'unknown' }), $tries, $WaitMinutes) }
}

function Test-DbHubSessionOpen {
    # Whether the session this job started still goes on: its auto-stop is pending, as a stop removes it. An auto-stop that
    # can't be read counts as pending.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    return ((Get-DbHubAutoStopRunEnd -Context $Context).State -ne 'None')
}

function Get-DbHubSessionReplicaSetting {
    # The settings' t4Replica part (2026-11-14) with its defaults: Sizes, StreamingDelayMs, WaitMinutes, DeleteMinutes, and
    # RaceMinutes.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    $part = Get-DbHubMember -InputObject $Settings -Name 't4Replica'
    $value = {
        param([string] $Name, [int] $Default)
        $item = [int](Get-DbHubMember -InputObject $part -Name $Name)
        if ($item -gt 0) { $item } else { $Default }
    }
    return [pscustomobject]@{
        Sizes            = @(Get-DbHubMember -InputObject $part -Name 'sizes' | Where-Object { $_ })
        StreamingDelayMs = (& $value 'maxStandbyStreamingDelayMs' 600000)
        WaitMinutes      = (& $value 'createWaitMinutes' 25)
        DeleteMinutes    = (& $value 'deleteWaitMinutes' 15)
        RaceMinutes      = (& $value 'raceMinutes' 10)
    }
}

function Start-DbHubSessionReplica {
    <#
    .SYNOPSIS
    T4's read replica for a session (ADR 0025, 2026-11-14): asks Azure for it once T4 is Ready, at T4's size or the next
    documented size Azure accepts, and returns once Azure accepted it; Complete-DbHubSessionReplica waits for it. Updates
    the status's replica part. Returns the work: Done, Pending, Retry, Name, Order, Index, Source, Attempts, and AcceptedUtc.

    .DESCRIPTION
    - None for settings without the replica, an environment deploy.ps1 hasn't set it up in (DbHubT4Replica isn't
      Session: ./scripts/deploy.ps1), a Burstable T4 (Not supported), or a T4 that isn't Ready.
    - A replica that's there and Ready is used as it is; a stopped one is started; one being deleted is waited for.
    - With RaceMinutes 0 (from inside the run's loop), a T4 that's restarting or updating (ReadReplicaServerInUnexpectedState)
      leaves Retry set, and the session asks again after its dispatches (Send-DbHubSessionReplicaAttempt).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Start-DbHubSession, its caller, asks ShouldProcess.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [int] $RaceMinutes = 10,

        [int] $PollSeconds = 30
    )

    $settings = $Context.Settings
    $setting = Get-DbHubSessionReplicaSetting -Settings $settings
    $part = $Status['replica']
    $work = [pscustomobject]@{ Done = $true; Pending = $false; Retry = $false; Name = ''; Order = @(); Index = 0; Source = $null; Attempts = (New-Object -TypeName 'System.Collections.Generic.List[object]'); AcceptedUtc = $null }
    $finish = {
        param([string] $State, [string] $Note, [string] $Fix)
        $part['state'] = $State
        $part['note'] = $Note
        $part['fix'] = $Fix
        $work.Done = $true
        $work.Pending = $false
        $work.Retry = $false
        Write-DbHubLog -Context $Context -Message ('T4''s read replica: {0}. {1}' -f $State, $Note)
        return $work
    }
    $replica = Get-DbHubT4Replica -Context $Context -Tags $Tags
    $work.Name = [string]$replica.Name
    if ($replica.State -eq 'NotConfigured' -or @($setting.Sizes).Count -eq 0) {
        return (& $finish 'NotConfigured' 'The control''s settings predate T4''s read replica, so this session has none.' 'Run ./scripts/deploy.ps1: it publishes the control again.')
    }
    if ([string](Get-DbHubMember -InputObject $Tags -Name 'DbHubT4Replica') -ne 'Session') {
        return (& $finish 'NotSetUp' 'T4''s read replica isn''t set up in this environment, which was deployed before the replica existed, so Database Hub''s Read replica lag stays empty and the replica-lag beat doesn''t run.' 'Run ./scripts/deploy.ps1: it sets the replica up, and each session creates it.')
    }
    $t4 = Get-DbHubT4Server -Context $Context -Tags $Tags
    $sku = Get-DbHubMember -InputObject $t4.Body -Name 'sku'
    $t4Sku = [string](Get-DbHubMember -InputObject $sku -Name 'name')
    $part['sizeAsked'] = $t4Sku
    if ([string](Get-DbHubMember -InputObject $sku -Name 'tier') -eq 'Burstable') {
        return (& $finish 'NotSupported' ('T4 runs on the Burstable size {0}, and Azure supports read replicas only on the General Purpose and Memory Optimized tiers, so this session has none and Database Hub''s Read replica lag stays empty.' -f $t4Sku) 'Remove t4SkuName from config/demo.config.json (the default is General Purpose Standard_D4ds_v5), then run ./scripts/deploy.ps1; ./scripts/estimate-cost.ps1 shows what it costs.')
    }
    if ($replica.State -eq 'Ready') {
        $part['state'] = 'Ready'
        $part['readyUtc'] = ConvertTo-DbHubTimeText -Value (Get-DbHubUtcNow)
        return $work
    }
    if ($replica.State -eq 'Unknown') {
        return (& $finish 'Failed' ('T4''s read replica ({0}) couldn''t be read, so it wasn''t created.' -f $replica.Name) 'Run all again in a few minutes; ./scripts/status.ps1 shows the replica.')
    }
    if ($replica.State -eq 'Dropping') {
        $giveUp = (Get-DbHubUtcNow).AddMinutes($setting.DeleteMinutes)
        while ($replica.State -eq 'Dropping' -and (Get-DbHubUtcNow) -lt $giveUp) {
            Start-Sleep -Seconds $PollSeconds
            $replica = Get-DbHubT4Replica -Context $Context -Tags $Tags
        }
        if ($replica.State -ne 'Missing') {
            return (& $finish 'Failed' ('T4''s read replica ({0}) from an earlier session was still being deleted after {1} minutes, so a new one wasn''t created.' -f $replica.Name, $setting.DeleteMinutes) 'Run all again in a few minutes: Azure finishes deleting it on its own.')
        }
    }
    if ($replica.State -in 'Stopped', 'Stopping') {
        if ($replica.State -eq 'Stopping' -or -not (Invoke-DbHubT4Action -Context $Context -Name $replica.Name -Action start)) {
            return (& $finish 'Failed' ('T4''s read replica ({0}) from an earlier session is {1} and couldn''t be started.' -f $replica.Name, $replica.State.ToLowerInvariant()) 'Run the notebook''s Stop now cell, which deletes it, then Run all again.')
        }
        $part['state'] = 'Starting'
        $work.Done = $false
        $work.Pending = $true
        $work.AcceptedUtc = Get-DbHubUtcNow
        return $work
    }
    if ($replica.State -ne 'Missing') {
        # Provisioning, Starting, Updating, and the like: wait for Ready.
        $part['state'] = 'Creating'
        $work.Done = $false
        $work.Pending = $true
        $work.AcceptedUtc = Get-DbHubUtcNow
        return $work
    }
    if ($t4.State -ne 'Ready') {
        return (& $finish 'NotCreated' ('T4 ({0}) is {1}, not Ready, so its read replica wasn''t created: Azure creates a replica only from a running server.' -f $t4.Name, $t4.State) 'Run all again once T4 runs.')
    }
    $work.Order = @(Get-DbHubReplicaSizeOrder -T4SkuName $t4Sku -Record ([string](Get-DbHubMember -InputObject $Tags -Name 'DbHubT4ReplicaSize')) -Sizes $setting.Sizes)
    $work.Source = $t4.Body
    $work.Done = $false
    return (Send-DbHubSessionReplicaAttempt -Context $Context -Tags $Tags -Status $Status -Work $work -RaceMinutes $RaceMinutes -PollSeconds $PollSeconds)
}

function Send-DbHubSessionReplicaAttempt {
    <#
    .SYNOPSIS
    Asks for the session's read replica at the work's next size: SkuNotAvailable moves to the next size, a T4 that's
    restarting or updating (ReadReplicaServerInUnexpectedState) is asked again every PollSeconds for up to RaceMinutes (live,
    2026-11-13: T4's restart refused the replica), and any other refusal ends it, with the fix in the status. Returns the
    work.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [Parameter(Mandatory = $true)]
        [object] $Work,

        [int] $RaceMinutes = 10,

        [int] $PollSeconds = 30
    )

    $part = $Status['replica']
    $finish = {
        param([string] $State, [string] $Note, [string] $Fix)
        $part['state'] = $State
        $part['note'] = $Note
        $part['fix'] = $Fix
        $Work.Done = $true
        $Work.Pending = $false
        $Work.Retry = $false
        Write-DbHubLog -Context $Context -Message ('T4''s read replica: {0}. {1}' -f $State, $Note)
        return $Work
    }
    $Work.Retry = $false
    while ($Work.Index -lt @($Work.Order).Count) {
        $size = [string](@($Work.Order)[$Work.Index])
        $raceEnd = (Get-DbHubUtcNow).AddMinutes($RaceMinutes)
        while ($true) {
            if (-not (Test-DbHubSessionOpen -Context $Context)) {
                return (& $finish 'NotCreated' 'The session was stopped before its read replica was created.' '')
            }
            $sent = Send-DbHubT4ReplicaCreate -Context $Context -Name $Work.Name -Source $Work.Source -SkuName $size -Tags $Tags
            if ($sent.Accepted -or $sent.Code -ne 'SourceNotReady' -or (Get-DbHubUtcNow) -ge $raceEnd) {
                break
            }
            Write-DbHubLog -Context $Context -Message ('{0}: T4 isn''t ready for a read replica yet ({1}); asking again in {2} seconds.' -f $Work.Name, $sent.Error, $PollSeconds)
            Start-Sleep -Seconds $PollSeconds
        }
        $attempt = [ordered]@{ size = $size; outcome = 'Accepted'; atUtc = (ConvertTo-DbHubTimeText -Value (Get-DbHubUtcNow)); error = '' }
        if (-not $sent.Accepted) {
            $attempt['outcome'] = $sent.Code
            $attempt['error'] = ConvertTo-DbHubSafeText -Text $sent.Error
        }
        $Work.Attempts.Add($attempt)
        $part['attempts'] = @($Work.Attempts.ToArray())
        if ($sent.Accepted -or $sent.Code -eq 'AlreadyExists') {
            Write-DbHubLog -Context $Context -Message ('{0}: creation accepted at {1} (T4''s read replica; about 9 minutes).' -f $Work.Name, $size)
            $part['state'] = 'Creating'
            $Work.Pending = $true
            $Work.AcceptedUtc = Get-DbHubUtcNow
            return $Work
        }
        if ($sent.Code -eq 'SkuNotAvailable') {
            $Work.Index++
            continue
        }
        if ($sent.Code -eq 'SourceNotReady' -and $RaceMinutes -le 0) {
            $Work.Retry = $true
            return $Work
        }
        if ($sent.Code -eq 'NotGranted') {
            return (& $finish 'NotGranted' 'The control identity can''t create T4''s read replica yet: its role doesn''t have the PostgreSQL actions, so this session has none, and Database Hub''s Read replica lag stays empty.' 'An Owner runs ./scripts/grant-safety-stop.ps1 once; the next Run all creates the replica.')
        }
        if ($sent.Code -eq 'SourceNotReady') {
            return (& $finish 'NotCreated' ('T4 wasn''t ready for a read replica within {0} minutes: {1}' -f $RaceMinutes, $sent.Error) 'Run all again in a few minutes.')
        }
        return (& $finish 'Failed' ('T4''s read replica couldn''t be created: {0}' -f $sent.Error) 'Fix the cause (a policy denial names its policy), then Run all again; ./scripts/start-demo.ps1 creates it too, with more detail.')
    }
    $tried = @($Work.Attempts | ForEach-Object { [string]$_['size'] } | Select-Object -Unique) -join ', '
    return (& $finish 'Refused' ('Azure refused every size for T4''s read replica ({0}), so this session has none.' -f $tried) 'Ask for the size in the region (a Region access request), or set t4SkuName in config/demo.config.json and run ./scripts/deploy.ps1.')
}

function Complete-DbHubSessionReplica {
    <#
    .SYNOPSIS
    Waits, at most WaitMinutes, for the read replica Start-DbHubSessionReplica asked for to be Ready, then sets its
    max_standby_streaming_delay (the replica-lag beat needs it) and records its size in DbHubT4ReplicaSize, so the next
    session asks for it first. A creation Azure didn't finish (the server goes away) moves to the next size, and each size
    used other than T4's is in the status. Returns the work.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [Parameter(Mandatory = $true)]
        [object] $Work,

        [int] $WaitMinutes = 25,

        [int] $PollSeconds = 20
    )

    $part = $Status['replica']
    $setting = Get-DbHubSessionReplicaSetting -Settings $Context.Settings
    if ($Work.Retry) {
        $Work = Send-DbHubSessionReplicaAttempt -Context $Context -Tags $Tags -Status $Status -Work $Work -RaceMinutes $setting.RaceMinutes -PollSeconds $PollSeconds
    }
    if ($Work.Done -or -not $Work.Pending) {
        return $Work
    }
    $deadline = (Get-DbHubUtcNow).AddMinutes($WaitMinutes)
    $seen = $false
    while ($true) {
        if (-not (Test-DbHubSessionOpen -Context $Context)) {
            $part['state'] = 'NotCreated'
            $part['note'] = 'The session was stopped before its read replica was Ready.'
            $Work.Done = $true
            return $Work
        }
        $replica = Get-DbHubT4Replica -Context $Context -Tags $Tags
        if ($replica.State -eq 'Ready') {
            break
        }
        if ($replica.State -notin 'Missing', 'Dropping', 'Unknown') {
            $seen = $true
        }
        $sinceAccepted = ((Get-DbHubUtcNow) - $Work.AcceptedUtc).TotalMinutes
        if ($replica.State -in 'Missing', 'Dropping' -and ($seen -or $sinceAccepted -ge 5) -and @($Work.Order).Count -gt 0) {
            # Azure took the request and didn't finish it: the next size, once the name is free.
            $last = @($Work.Attempts)[-1]
            $last['outcome'] = 'NotFinished'
            $part['attempts'] = @($Work.Attempts.ToArray())
            Write-DbHubLog -Context $Context -Message ('{0}: Azure didn''t finish creating it at {1}; the next size is tried.' -f $Work.Name, $last['size'])
            $free = (Get-DbHubUtcNow).AddMinutes($setting.DeleteMinutes)
            while ($replica.State -ne 'Missing' -and (Get-DbHubUtcNow) -lt $free) {
                Start-Sleep -Seconds $PollSeconds
                $replica = Get-DbHubT4Replica -Context $Context -Tags $Tags
            }
            $Work.Index++
            $Work.Pending = $false
            $Work = Send-DbHubSessionReplicaAttempt -Context $Context -Tags $Tags -Status $Status -Work $Work -RaceMinutes $setting.RaceMinutes -PollSeconds $PollSeconds
            if ($Work.Done -or -not $Work.Pending) {
                return $Work
            }
            $deadline = (Get-DbHubUtcNow).AddMinutes($WaitMinutes)
            $seen = $false
            continue
        }
        if ((Get-DbHubUtcNow) -ge $deadline) {
            $part['state'] = 'NotReady'
            $part['note'] = 'T4''s read replica ({0}) was still {1} after {2} minutes, so the replica-lag beat may not run this session.' -f $Work.Name, $replica.State, $WaitMinutes
            $part['fix'] = 'It may still finish: ./scripts/status.ps1 shows it, and the session''s stop deletes it either way.'
            $Work.Done = $true
            return $Work
        }
        Start-Sleep -Seconds $PollSeconds
    }
    $Work.Done = $true
    $Work.Pending = $false
    $part['state'] = 'Ready'
    $part['readyUtc'] = ConvertTo-DbHubTimeText -Value (Get-DbHubUtcNow)
    $used = ''
    $read = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{1}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $Work.Name) -ApiVersion (Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.DBforPostgreSQL/flexibleServers')
    if ($read.StatusCode -eq 200) {
        $used = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $read.Body -Name 'sku') -Name 'name')
    }
    $part['sizeUsed'] = $used
    if ($used -and $part['sizeAsked'] -and $used -cne [string]$part['sizeAsked']) {
        $part['note'] = 'Azure refused T4''s size ({0}) for the replica, so it runs on {1}, which has more vCores and costs more while the session lasts; ./scripts/estimate-cost.ps1 shows the difference.' -f $part['sizeAsked'], $used
    }
    $parameter = Set-DbHubT4ReplicaParameter -Context $Context -Name $Work.Name -Milliseconds $setting.StreamingDelayMs
    if (-not $parameter.Ok) {
        $part['note'] = ('{0} Its max_standby_streaming_delay wasn''t set ({1}), so Read replica lag climbs only to about 30 seconds in the replica-lag beat.' -f [string]$part['note'], $parameter.Error).Trim()
    }
    if ($used) {
        $recorded = Set-DbHubResourceGroupTag -Context $Context -Tags @{ DbHubT4ReplicaSize = ('{0}@any' -f $used) }
        if (-not $recorded.Ok) {
            Write-DbHubLog -Context $Context -Message ('The replica''s size wasn''t recorded: {0}' -f $recorded.Error)
        }
    }
    Write-DbHubLog -Context $Context -Message ('{0}: Ready ({1}).' -f $Work.Name, $used)
    return $Work
}

function Get-DbHubReplicaLagPlan {
    # When the showcase's replica-lag slot runs (ADR 0010, 2026-11-14): from minute 20 of T4's even 30-minute cycles, for 9
    # minutes, counted from when T4's profile was set, while the run lasts (the runner ends 2 minutes before its end).
    # Returns the windows, each with startUtc and endUtc. Pure.
    param(
        [Parameter(Mandatory = $true)]
        [datetime] $ProfileSetUtc,

        [Parameter(Mandatory = $true)]
        [datetime] $RunEndUtc,

        [int] $CycleMinutes = 30,

        [int] $StartMinute = 20,

        [int] $DurationMinutes = 9
    )

    $windows = @()
    $last = $RunEndUtc.AddMinutes(-2)
    for ($cycle = 2; $cycle -le 8; $cycle += 2) {
        $start = $ProfileSetUtc.AddMinutes(($cycle - 1) * $CycleMinutes + $StartMinute)
        if ($start.AddMinutes(1) -ge $last) {
            break
        }
        $end = $start.AddMinutes($DurationMinutes)
        if ($end -gt $last) {
            $end = $last
        }
        $windows += [ordered]@{ startUtc = (ConvertTo-DbHubTimeText -Value $start); endUtc = (ConvertTo-DbHubTimeText -Value $end) }
    }
    return , $windows
}

function Read-DbHubMetric {
    <#
    .SYNOPSIS
    One Metrics - List read for one resource: Name with one Aggregation, every IntervalMinutes over Timespan, and with
    Filter, a dimension filter such as StatusCode eq '429' (T5's throttled requests, 2026-11-18). Returns Series (Metric,
    Unit, Aggregation, and Points: UTC time to value, only the points that have one), StatusCode, and Error. Never throws.
    https://learn.microsoft.com/rest/api/monitor/metrics/list
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $ServerPath,

        [Parameter(Mandatory = $true)]
        [string[]] $Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Maximum', 'Total', 'Average', 'Minimum', 'Count')]
        [string] $Aggregation,

        [Parameter(Mandatory = $true)]
        [string] $Timespan,

        [int] $IntervalMinutes = 1,

        [AllowEmptyString()]
        [string] $Filter = ''
    )

    $series = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $field = $Aggregation.ToLowerInvariant()
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    try {
        $interval = 'PT{0}M' -f $IntervalMinutes
        if ($IntervalMinutes -eq 60) {
            $interval = 'PT1H'
        }
        $query = '{0}/providers/Microsoft.Insights/metrics?timespan={1}&interval={2}&metricnames={3}&aggregation={4}' -f $ServerPath, $Timespan, $interval, ($Name -join ','), $Aggregation
        if ($Filter) {
            $query = '{0}&$filter={1}' -f $query, [uri]::EscapeDataString($Filter)
        }
        $read = Invoke-DbHubArm -Context $Context -Method GET -Path $query -ApiVersion (Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Insights/metrics')
        if ($read.StatusCode -ne 200) {
            $why = $read.Error
            if (-not $why) {
                $why = 'HTTP {0}' -f $read.StatusCode
            }
            return [pscustomobject]@{ Series = $series.ToArray(); StatusCode = $read.StatusCode; Error = $why }
        }
        foreach ($metric in @(Get-DbHubMember -InputObject $read.Body -Name 'value')) {
            $metricName = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $metric -Name 'name') -Name 'value')
            if ($metricName -notin $Name) {
                continue
            }
            $points = New-Object -TypeName 'System.Collections.Generic.SortedDictionary[datetime,double]'
            foreach ($timeseries in @(Get-DbHubMember -InputObject $metric -Name 'timeseries')) {
                foreach ($point in @(Get-DbHubMember -InputObject $timeseries -Name 'data')) {
                    $value = Get-DbHubMember -InputObject $point -Name $field
                    $stamp = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject $point -Name 'timeStamp')
                    $number = 0.0
                    if ($null -eq $value -or $null -eq $stamp -or $value -is [bool] -or -not [double]::TryParse([string]$value, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$number) -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) {
                        continue
                    }
                    $points[[datetime]$stamp] = $number
                }
            }
            $series.Add([pscustomobject]@{ Metric = $metricName; Unit = [string](Get-DbHubMember -InputObject $metric -Name 'unit'); Aggregation = $Aggregation; Points = $points })
        }
    }
    catch {
        return [pscustomobject]@{ Series = $series.ToArray(); StatusCode = 0; Error = (ConvertTo-DbHubSafeText -Text $_.Exception.Message) }
    }
    return [pscustomobject]@{ Series = $series.ToArray(); StatusCode = 200; Error = '' }
}

function ConvertTo-DbHubMetricPoint {
    <#
    .SYNOPSIS
    One series' points at IntervalMinutes, as the history document holds them (the module's
    ConvertTo-DemoPostgresHistoryPoint): pairs of the interval's start (yyyy-MM-ddTHH:mm:ssZ, counted from midnight UTC)
    and its value, the points of one interval combined as the aggregation combines them (Maximum the highest, Total the
    sum, Minimum the lowest, Average the mean), rounded for the unit, and a whole number written without decimals. Pure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $Point,

        [Parameter(Mandatory = $true)]
        [string] $Aggregation,

        [AllowEmptyString()]
        [string] $Unit = '',

        [Parameter(Mandatory = $true)]
        [int] $IntervalMinutes
    )

    $epoch = New-Object -TypeName DateTime -ArgumentList 1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)
    $decimals = 2
    if ($script:DbHubMetricDecimals.ContainsKey($Unit)) {
        $decimals = [int]$script:DbHubMetricDecimals[$Unit]
    }
    $buckets = New-Object -TypeName 'System.Collections.Generic.SortedDictionary[long,System.Collections.Generic.List[double]]'
    if ($null -ne $Point) {
        foreach ($pair in $Point.GetEnumerator()) {
            $minutes = [long][System.Math]::Floor(($pair.Key - $epoch).TotalMinutes)
            $bucket = [long]($minutes - ($minutes % $IntervalMinutes))
            if (-not $buckets.ContainsKey($bucket)) {
                $buckets[$bucket] = New-Object -TypeName 'System.Collections.Generic.List[double]'
            }
            $buckets[$bucket].Add([double]$pair.Value)
        }
    }
    $output = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($bucket in $buckets.GetEnumerator()) {
        $values = $bucket.Value
        $combined = $values[0]
        foreach ($value in $values) {
            switch ($Aggregation) {
                'Total' { }
                'Average' { }
                'Minimum' {
                    if ($value -lt $combined) { $combined = $value }
                }
                default {
                    if ($value -gt $combined) { $combined = $value }
                }
            }
        }
        if ($Aggregation -in 'Total', 'Average') {
            $combined = 0.0
            foreach ($value in $values) {
                $combined += $value
            }
            if ($Aggregation -eq 'Average') {
                $combined = $combined / $values.Count
            }
        }
        $rounded = [System.Math]::Round([double]$combined, $decimals, [System.MidpointRounding]::AwayFromZero)
        $number = $rounded
        if ($rounded -eq [System.Math]::Floor($rounded) -and [System.Math]::Abs($rounded) -lt 1e15) {
            $number = [long]$rounded
        }
        $output.Add([object[]]@($epoch.AddMinutes($bucket.Key).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture), $number))
    }
    return , $output.ToArray()
}

function Get-DbHubPostgresMetricDocument {
    <#
    .SYNOPSIS
    T4's and its read replica's Azure Monitor metrics from StartUtc to EndUtc as NB_DatabaseHub_LiveActivity's
    POSTGRES_METRICS document (version 1, as the module's Get-DemoPostgresHistoryParameter builds it), with the session's
    ID. Returns Json, Status (Pass, Warning, or Skipped), Message, ServerCount, SeriesCount, PointCount, IntervalMinutes,
    Bytes, and Replica (whether the replica's metrics are in it). Never throws for an Azure error.

    .DESCRIPTION
    T4 (role primary): cpu_percent, memory_percent, active_connections, and physical_replication_delay_in_bytes, each its
    Maximum per interval, and connections_failed, its Total. The replica (role replica): physical_replication_delay_in_seconds
    (Read Replica Lag), cpu_percent, and active_connections, each its Maximum. A server that doesn't exist or has no data is
    left out. At most MaxBytes of UTF-8: coarser intervals until it fits. No resource ID, subscription, or credential.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [Parameter(Mandatory = $true)]
        [datetime] $StartUtc,

        [Parameter(Mandatory = $true)]
        [datetime] $EndUtc,

        [AllowEmptyString()]
        [string] $SessionId = '',

        [int] $MaxBytes = 24000
    )

    $settings = $Context.Settings
    $answer = {
        param([string] $Status, [string] $Message, [string] $Json = '', [int] $Servers = 0, [int] $Series = 0, [int] $Points = 0, [int] $Interval = 1, [bool] $Replica = $false)
        [pscustomobject]@{ Json = $Json; Status = $Status; Message = $Message; ServerCount = $Servers; SeriesCount = $Series; PointCount = $Points; IntervalMinutes = $Interval; Bytes = [System.Text.Encoding]::UTF8.GetByteCount($Json); Replica = $Replica }
    }
    $deploymentId = [string](Get-DbHubMember -InputObject $Tags -Name 'deploymentId')
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        return (& $answer 'Skipped' 'The demo resource group has no deploymentId tag, so T4 isn''t known and no metrics were read.')
    }
    $end = [DateTime]::SpecifyKind($EndUtc, [System.DateTimeKind]::Utc)
    $end = New-Object -TypeName DateTime -ArgumentList ($end.Ticks - ($end.Ticks % [TimeSpan]::TicksPerMinute)), ([System.DateTimeKind]::Utc)
    $start = [DateTime]::SpecifyKind($StartUtc, [System.DateTimeKind]::Utc)
    $start = New-Object -TypeName DateTime -ArgumentList ($start.Ticks - ($start.Ticks % [TimeSpan]::TicksPerMinute)), ([System.DateTimeKind]::Utc)
    if ($start -ge $end) {
        $start = $end.AddMinutes(-15)
    }
    $timespan = '{0}/{1}' -f (ConvertTo-DbHubTimeText -Value $start), (ConvertTo-DbHubTimeText -Value $end)
    $demo = Get-DbHubDemoPath -Settings $settings
    $wanted = @([pscustomobject]@{ Role = 'primary'; Target = 'T4'; Name = ('{0}{1}' -f $settings.t4ServerPrefix, $deploymentId) })
    $prefix = [string](Get-DbHubMember -InputObject $settings -Name 't4ReplicaPrefix')
    if ($prefix) {
        $wanted += [pscustomobject]@{ Role = 'replica'; Target = 'T4-replica'; Name = ('{0}{1}' -f $prefix, $deploymentId) }
    }
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.DBforPostgreSQL/flexibleServers'
    $servers = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $series = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $notes = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $failed = $false
    foreach ($server in $wanted) {
        $path = '{0}/providers/Microsoft.DBforPostgreSQL/flexibleServers/{1}' -f $demo, $server.Name
        $read = Invoke-DbHubArm -Context $Context -Method GET -Path $path -ApiVersion $version
        if ($read.StatusCode -eq 404) {
            $notes.Add(('{0} isn''t there, so it''s left out.' -f $server.Name))
            if ($server.Role -eq 'primary') {
                break
            }
            continue
        }
        $sku = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $read.Body -Name 'sku') -Name 'name')
        $found = 0
        foreach ($group in $script:DbHubMetricReads[$server.Role]) {
            $metrics = Read-DbHubMetric -Context $Context -ServerPath $path -Name $group.Names -Aggregation $group.Aggregation -Timespan $timespan -IntervalMinutes 1
            if ($metrics.Error) {
                $failed = $true
                $notes.Add(('{0}''s {1} couldn''t be read: {2}' -f $server.Name, ($group.Names -join ', '), $metrics.Error))
            }
            foreach ($item in @($metrics.Series)) {
                if ($item.Points.Count -gt 0) {
                    $series.Add([pscustomobject]@{ ResourceName = $server.Name; Role = $server.Role; Metric = $item.Metric; Aggregation = $item.Aggregation; Unit = $item.Unit; Points = $item.Points })
                    $found++
                }
            }
        }
        if ($found -gt 0) {
            $servers.Add([ordered]@{ role = $server.Role; target = $server.Target; resourceName = $server.Name; sku = $sku })
        }
        elseif (-not $failed) {
            $notes.Add(('{0} had no Azure Monitor data in the window, so it''s left out.' -f $server.Name))
        }
    }
    $hasReplica = @($servers | Where-Object { $_['role'] -eq 'replica' }).Count -gt 0
    if ($series.Count -eq 0) {
        return (& $answer 'Warning' ('No PostgreSQL metrics were captured: {0}' -f ($notes -join ' ')))
    }
    $json = ''
    $bytes = 0
    $interval = 1
    $points = 0
    foreach ($step in $script:DbHubMetricIntervals) {
        $interval = $step
        $points = 0
        $out = @()
        foreach ($item in $series) {
            $converted = ConvertTo-DbHubMetricPoint -Point $item.Points -Aggregation $item.Aggregation -Unit $item.Unit -IntervalMinutes $step
            $points += @($converted).Count
            $out += , ([ordered]@{ resourceName = $item.ResourceName; role = $item.Role; metric = $item.Metric; aggregation = $item.Aggregation; unit = $item.Unit; points = $converted })
        }
        $document = [ordered]@{
            version         = 1
            sessionId       = $SessionId
            capturedBy      = 'control'
            capturedUtc     = (ConvertTo-DbHubTimeText -Value $end)
            startUtc        = (ConvertTo-DbHubTimeText -Value $start)
            endUtc          = (ConvertTo-DbHubTimeText -Value $end)
            windowMinutes   = [int][System.Math]::Round(($end - $start).TotalMinutes)
            intervalMinutes = $step
            servers         = $servers.ToArray()
            series          = $out
        }
        $json = ConvertTo-Json -InputObject $document -Depth 8 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
        if ($bytes -le $MaxBytes) {
            break
        }
    }
    if ($bytes -gt $MaxBytes) {
        return (& $answer 'Warning' ('T4''s metrics are too large for the control vault even at {0}-minute intervals ({1:N0} bytes), so none were kept.' -f $interval, $bytes))
    }
    $status = 'Pass'
    if ($failed) {
        $status = 'Warning'
    }
    $names = @($servers | ForEach-Object { $_['resourceName'] }) -join ' and '
    $message = 'Azure Monitor metrics for the history: {0}, {1} series and {2:N0} points from {3:HH:mm} to {4:HH:mm} UTC, every {5} minute(s) ({6:N1} KB).' -f $names, $series.Count, $points, $start, $end, $interval, ($bytes / 1024.0)
    if ($notes.Count -gt 0) {
        $message = '{0} {1}' -f $message, ($notes -join ' ')
    }
    return (& $answer $status $message $json $servers.Count $series.Count $points $interval $hasReplica)
}

function Read-DbHubCosmosMetricSeries {
    <#
    .SYNOPSIS
    T5's Azure Monitor metrics from StartUtc to EndUtc for the history (2026-11-18, ADR 0027): one Metrics - List read per
    signal ($script:DbHubCosmosReads), every minute, and hourly for ProvisionedThroughput and ServiceAvailability. Returns
    Account ('' without T5), Found (whether any point was read), Series (Metric, Aggregation, Unit, StatusCode, Interval, and
    Points), Failed, Notes, StartUtc, EndUtc, and Message (why none were captured). Reads only; never throws for an Azure
    error. An account that isn't there (HTTP 404) is left out with a note.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [Parameter(Mandatory = $true)]
        [datetime] $StartUtc,

        [Parameter(Mandatory = $true)]
        [datetime] $EndUtc
    )

    $settings = $Context.Settings
    $account = Get-DbHubT5Account -Settings $settings -Tags $Tags
    $series = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $notes = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $end = [DateTime]::SpecifyKind($EndUtc, [System.DateTimeKind]::Utc)
    $end = New-Object -TypeName DateTime -ArgumentList ($end.Ticks - ($end.Ticks % [TimeSpan]::TicksPerMinute)), ([System.DateTimeKind]::Utc)
    $start = [DateTime]::SpecifyKind($StartUtc, [System.DateTimeKind]::Utc)
    $start = New-Object -TypeName DateTime -ArgumentList ($start.Ticks - ($start.Ticks % [TimeSpan]::TicksPerMinute)), ([System.DateTimeKind]::Utc)
    if ($start -ge $end) {
        $start = $end.AddMinutes(-15)
    }
    $answer = {
        param([bool] $Found, [bool] $Failed, [string] $Message)
        [pscustomobject]@{ Account = $account; Found = $Found; Series = $series.ToArray(); Failed = $Failed; Notes = $notes.ToArray(); StartUtc = $start; EndUtc = $end; Message = $Message }
    }
    if (-not $account) {
        return (& $answer $false $false '')
    }
    $path = '{0}/providers/Microsoft.DocumentDB/databaseAccounts/{1}' -f (Get-DbHubDemoPath -Settings $settings), $account
    # The hourly reads start on the hour, so their one point per hour covers the whole hour.
    $hourStart = New-Object -TypeName DateTime -ArgumentList $start.Year, $start.Month, $start.Day, $start.Hour, 0, 0, ([System.DateTimeKind]::Utc)
    $failed = $false
    foreach ($item in $script:DbHubCosmosReads) {
        $from = $start
        if ([int]$item.Interval -eq 60) {
            $from = $hourStart
        }
        $filter = ''
        if ($item.StatusCode) {
            $filter = "StatusCode eq '{0}'" -f $item.StatusCode
        }
        $metrics = Read-DbHubMetric -Context $Context -ServerPath $path -Name @($item.Name) -Aggregation $item.Aggregation -Timespan ('{0}/{1}' -f (ConvertTo-DbHubTimeText -Value $from), (ConvertTo-DbHubTimeText -Value $end)) -IntervalMinutes ([int]$item.Interval) -Filter $filter
        if ([int](Get-DbHubMember -InputObject $metrics -Name 'StatusCode') -eq 404) {
            $series.Clear()
            $notes.Add(('{0} isn''t there, so T5 is left out.' -f $account))
            return (& $answer $false $false ('No Azure Cosmos DB metrics were captured: {0}' -f ($notes -join ' ')))
        }
        if ($metrics.Error) {
            $failed = $true
            $notes.Add(('{0}''s {1} couldn''t be read: {2}' -f $account, $item.Metric, $metrics.Error))
            continue
        }
        $points = $null
        $unit = ''
        foreach ($entry in @($metrics.Series)) {
            $points = $entry.Points
            $unit = [string]$entry.Unit
        }
        if ($null -eq $points) {
            $points = New-Object -TypeName 'System.Collections.Generic.SortedDictionary[datetime,double]'
        }
        if (-not $unit -and $item.Aggregation -in 'Count', 'Total') {
            $unit = 'Count'
        }
        $series.Add([pscustomobject]@{ Metric = $item.Metric; Aggregation = $item.Aggregation; Unit = $unit; StatusCode = $item.StatusCode; Interval = [int]$item.Interval; Points = $points })
    }
    if (@($series | Where-Object { $_.Points.Count -gt 0 }).Count -eq 0) {
        $series.Clear()
        if (-not $failed) {
            $notes.Add(('{0} had no Azure Monitor data in the window, so T5 is left out.' -f $account))
        }
        return (& $answer $false $failed ('No Azure Cosmos DB metrics were captured: {0}' -f ($notes -join ' ')))
    }
    # A series without a point is left out, but the throttled requests (429) stay: read, and none throttled.
    $kept = @($series | Where-Object { $_.Points.Count -gt 0 -or $_.Metric -eq 'ThrottledRequests' })
    $series.Clear()
    foreach ($item in $kept) {
        $series.Add($item)
    }
    return (& $answer $true $failed '')
}

function ConvertTo-DbHubCosmosMetricDocument {
    <#
    .SYNOPSIS
    T5's metrics (Read-DbHubCosmosMetricSeries) as NB_DatabaseHub_LiveActivity's COSMOS_METRICS document (version 1, as the
    module's Get-DemoCosmosHistoryParameter builds it), with the session's ID: at most MaxBytes of UTF-8, with coarser
    intervals until it fits (an hourly series stays hourly or coarser). Count combines as a sum, and availability keeps
    two decimals. Returns Json ('' when it doesn't fit), Status (Pass or Warning), Message, SeriesCount, PointCount,
    IntervalMinutes, Bytes, CapturedUtc, StartUtc, EndUtc, and WindowMinutes. No resource ID, subscription, or credential. Pure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Read,

        [AllowEmptyString()]
        [string] $SessionId = '',

        [int] $MaxBytes = 24000
    )

    $start = $Read.StartUtc
    $end = $Read.EndUtc
    $window = [int][System.Math]::Round(($end - $start).TotalMinutes)
    $json = ''
    $bytes = 0
    $interval = 1
    $points = 0
    foreach ($step in $script:DbHubMetricIntervals) {
        $interval = $step
        $points = 0
        $out = @()
        foreach ($item in @($Read.Series)) {
            $seriesInterval = [System.Math]::Max($step, [int]$item.Interval)
            $combine = [string]$item.Aggregation
            if ($combine -eq 'Count') {
                $combine = 'Total'
            }
            $unit = [string]$item.Unit
            if ($item.Metric -eq 'ServiceAvailability') {
                # Two decimals, so 99.95 % isn't written as 100.
                $unit = ''
            }
            $converted = ConvertTo-DbHubMetricPoint -Point $item.Points -Aggregation $combine -Unit $unit -IntervalMinutes $seriesInterval
            $points += @($converted).Count
            $entry = [ordered]@{ resourceName = [string]$Read.Account; metric = [string]$item.Metric; aggregation = [string]$item.Aggregation; unit = [string]$item.Unit }
            if ($item.StatusCode) {
                $entry['statusCode'] = [string]$item.StatusCode
            }
            $entry['intervalMinutes'] = $seriesInterval
            $entry['points'] = $converted
            $out += , $entry
        }
        $document = [ordered]@{
            version         = 1
            sessionId       = $SessionId
            capturedBy      = 'control'
            capturedUtc     = (ConvertTo-DbHubTimeText -Value $end)
            startUtc        = (ConvertTo-DbHubTimeText -Value $start)
            endUtc          = (ConvertTo-DbHubTimeText -Value $end)
            windowMinutes   = $window
            intervalMinutes = $step
            accounts        = @([ordered]@{ target = 'T5'; resourceName = [string]$Read.Account })
            series          = $out
        }
        $json = ConvertTo-Json -InputObject $document -Depth 8 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
        if ($bytes -le $MaxBytes) {
            break
        }
    }
    $answer = [ordered]@{ Json = $json; Status = 'Pass'; Message = ''; SeriesCount = @($Read.Series).Count; PointCount = $points; IntervalMinutes = $interval; Bytes = $bytes; CapturedUtc = (ConvertTo-DbHubTimeText -Value $end); StartUtc = (ConvertTo-DbHubTimeText -Value $start); EndUtc = (ConvertTo-DbHubTimeText -Value $end); WindowMinutes = $window }
    if ($bytes -gt $MaxBytes) {
        $answer.Json = ''
        $answer.Bytes = 0
        $answer.Status = 'Warning'
        $answer.Message = 'T5''s metrics are too large for the control vault even at {0}-minute intervals ({1:N0} bytes), so none were kept.' -f $interval, $bytes
        return [pscustomobject]$answer
    }
    if ($Read.Failed) {
        $answer.Status = 'Warning'
    }
    $answer.Message = 'Azure Monitor metrics of T5 for the history: {0}, {1} series and {2:N0} points from {3:HH:mm} to {4:HH:mm} UTC, every {5} minute(s) ({6:N1} KB).' -f $Read.Account, @($Read.Series).Count, $points, $start, $end, $interval, ($bytes / 1024.0)
    if (@($Read.Notes).Count -gt 0) {
        $answer.Message = '{0} {1}' -f $answer.Message, (@($Read.Notes) -join ' ')
    }
    return [pscustomobject]$answer
}

function Save-DbHubSessionMetric {
    <#
    .SYNOPSIS
    The session's history metrics into the control vault (metricsName), for the control notebook to hand to
    NB_DatabaseHub_LiveActivity, which can't read Azure Monitor: from 10 minutes before the session's start (the group's
    DbHubSessionStartUtc, at most 6 hours back; 3 hours without one) to now. Returns Status (Pass, Warning, Skipped, or
    Failed), Message, Bytes, Replica, and Cosmos.

    .DESCRIPTION
    T5's metrics (2026-11-18, ADR 0027) go in the same secret, as the cosmos member of T4's document (or of an empty one
    when T4 has none), because the identity may write only the two session secrets. They're read first: with them, T4's
    document gets at most half of the secret's 24,000-byte bound, and T5's the rest.
    The Incident RCA's bundle index (-Rca, 2026-11-20, ADR 0031) goes in as the rca member, at most 4,000 bytes, which the
    two documents' bound leaves room for; with nothing else, the document holds it alone. This write is the secret's final
    version, after the bundles it lists. Version is that version's ID ('' when nothing was written), which a stop keeps in
    its status (metrics.version), because a re-check's bundle can still be written after it (review of 15ad76d): the
    notebook reads that version, not the latest.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [AllowEmptyString()]
        [string] $SessionId = '',

        [AllowNull()]
        [System.Collections.IDictionary] $Rca = $null
    )

    $now = Get-DbHubUtcNow
    $session = $SessionId
    if (-not $session) {
        $session = [string](Get-DbHubMember -InputObject $Tags -Name 'DbHubSessionId')
    }
    $from = $now.AddMinutes(-180)
    $started = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject $Tags -Name 'DbHubSessionStartUtc')
    if ($null -ne $started -and $started -lt $now -and $started -gt $now.AddHours(-6)) {
        $from = $started.AddMinutes(-10)
    }
    $rcaJson = ''
    if ($null -ne $Rca) {
        $rcaJson = ConvertTo-Json -InputObject $Rca -Depth 6 -Compress
    }
    $room = 24000
    if ($rcaJson) {
        $room = 24000 - [System.Text.Encoding]::UTF8.GetByteCount($rcaJson) - 16
    }
    $cosmos = Read-DbHubCosmosMetricSeries -Context $Context -Tags $Tags -StartUtc $from -EndUtc $now
    $bound = $room
    if ($cosmos.Found) {
        $bound = [int][System.Math]::Floor($room / 2)
    }
    $document = Get-DbHubPostgresMetricDocument -Context $Context -Tags $Tags -StartUtc $from -EndUtc $now -SessionId $session -MaxBytes $bound
    $cosmosDocument = $null
    if ($cosmos.Found) {
        $cosmosDocument = ConvertTo-DbHubCosmosMetricDocument -Read $cosmos -SessionId $session -MaxBytes ($room - $document.Bytes - 16)
    }
    $hasCosmos = $null -ne $cosmosDocument -and [bool]$cosmosDocument.Json
    $messages = @($document.Message)
    if ($null -ne $cosmosDocument) {
        $messages += $cosmosDocument.Message
    }
    elseif ($cosmos.Message) {
        $messages += $cosmos.Message
    }
    $message = (@($messages | Where-Object { $_ }) -join ' ')
    $json = [string]$document.Json
    if ($hasCosmos) {
        if (-not $json) {
            # T5's alone, in a T4 document without servers, which the notebook reads as no T4 metrics.
            $json = ConvertTo-Json -InputObject ([ordered]@{ version = 1; sessionId = $session; capturedBy = 'control'; capturedUtc = $cosmosDocument.CapturedUtc; startUtc = $cosmosDocument.StartUtc; endUtc = $cosmosDocument.EndUtc; windowMinutes = $cosmosDocument.WindowMinutes; intervalMinutes = $cosmosDocument.IntervalMinutes; servers = @(); series = @() }) -Depth 4 -Compress
        }
        $json = '{0},"cosmos":{1}}}' -f $json.Substring(0, $json.Length - 1), $cosmosDocument.Json
    }
    if ($rcaJson) {
        if (-not $json) {
            # The bundle index alone (2026-11-20, ADR 0031), in a document without servers, which the notebook reads as no
            # T4 metrics; its window says which session it's for.
            $json = ConvertTo-Json -InputObject ([ordered]@{ version = 1; sessionId = $session; capturedBy = 'control'; capturedUtc = (ConvertTo-DbHubTimeText -Value $now); startUtc = (ConvertTo-DbHubTimeText -Value $from); endUtc = (ConvertTo-DbHubTimeText -Value $now); windowMinutes = [int]($now - $from).TotalMinutes; intervalMinutes = 1; servers = @(); series = @() }) -Depth 4 -Compress
        }
        $json = '{0},"rca":{1}}}' -f $json.Substring(0, $json.Length - 1), $rcaJson
    }
    if (-not $json) {
        return [pscustomobject]@{ Status = $document.Status; Message = $message; Bytes = 0; Replica = $false; Cosmos = $false; Version = '' }
    }
    $status = 'Pass'
    if ($document.Status -ne 'Pass' -or $cosmos.Failed -or ($null -ne $cosmosDocument -and $cosmosDocument.Status -ne 'Pass')) {
        $status = 'Warning'
    }
    $name = [string](Get-DbHubMember -InputObject $Context.Settings -Name 'metricsName')
    if (-not $name) {
        $name = 'dbhub-session-metrics'
    }
    $replicaText = 'no'
    if ($document.Replica) {
        $replicaText = 'yes'
    }
    $cosmosText = 'no'
    if ($hasCosmos) {
        $cosmosText = 'yes'
    }
    $rcaText = 'no'
    if ($rcaJson) {
        $rcaText = 'yes'
    }
    $written = Set-DbHubVaultSecret -Context $Context -Name $name -Value $json -Tags @{ sessionId = $session; capturedUtc = (ConvertTo-DbHubTimeText -Value $now); replica = $replicaText; t5 = $cosmosText; rca = $rcaText }
    if (-not $written.Ok) {
        return [pscustomobject]@{ Status = 'Failed'; Message = ('The history''s metrics couldn''t be written to the control vault: {0}' -f $written.Error); Bytes = 0; Replica = $document.Replica; Cosmos = $false; Version = '' }
    }
    Write-DbHubLog -Context $Context -Message $message
    return [pscustomobject]@{ Status = $status; Message = $message; Bytes = [System.Text.Encoding]::UTF8.GetByteCount($json); Replica = $document.Replica; Cosmos = $hasCosmos; Version = [string](Get-DbHubMember -InputObject $written -Name 'Version') }
}

# ---- The Incident RCA's evidence (ADR 0031, rca/README.md) -------------------------------------------------------------
# The runner's observer keeps what it captures on the VMs. 'rca export' reduces it into evidence documents, and 'rca part'
# prints each document's parts, one line of at most 3,400 characters per managed Run Command, because the instance view
# keeps the last 4 KB of output (https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed). The parts
# go into the control vault as earlier versions of the metrics secret (bundles: at most 6 parts and 24,000 bytes each),
# which the rca member of its final version lists (the bundle index); the control notebook reads them and passes them to
# NB_DatabaseHub_LiveActivity as RCA_EVIDENCE. Nothing new is granted: the identity writes the same secret, and the
# deployer's Key Vault Secrets User on it covers every version. Run Command and the vault are reached through Azure
# Resource Manager only, as everywhere else here.

$script:DbHubRcaPartPattern = '^DBHUBDEMO-RCA 1 [0-9]{8}T[0-9]{6}Z-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{4} [1-9][0-9]?/[1-9][0-9]? [0-9a-f]{64} [A-Za-z0-9+/]+={0,2}$'
$script:DbHubRcaDocumentPattern = '^[0-9]{8}T[0-9]{6}Z-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{4}$'
$script:DbHubRcaStatuses = @('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')
$script:DbHubRcaTerminal = @('Succeeded', 'Failed', 'TimedOut', 'Canceled')
# What a document may decompress to: far above what the export's 64 KiB of gzip holds, so a bad stream stops early.
$script:DbHubRcaMaxJsonBytes = 16MB
# A stop lists the T2 host this long after its mark (review of 242a3ef7): a re-check that read the mark open just before it
# can still send there, after its three PUTs and Send-DbHubRunCommand's two 10-s conflict waits.
$script:DbHubRcaStopHostDelaySeconds = 60
# How long from an export's start the T2 host waits for the deletes of export Run Commands more than an hour old, which
# Get-DbHubRcaRoom has just asked for (re-review of e55e000b): a finished leftover goes in seconds, so the export doesn't run
# beside its delete (R871); one Azure still lists after this is stuck in Deleting (F31), and the export goes beside it.
$script:DbHubRcaStaleWaitSeconds = 90

function Get-DbHubRcaSetting {
    # The export's bounds from the settings (Get-DemoActivityControlRunbookSetting), with their defaults, and whether these
    # are the control's settings with the VM-side Rca action's script (settings published before ADR 0031 have none).
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    $rca = Get-DbHubMember -InputObject $Settings -Name 'rca'
    $read = {
        param([string] $Name, [int] $Default, [int] $Low, [int] $High)
        $value = Get-DbHubMember -InputObject $rca -Name $Name
        if (Test-DbHubInteger -Value $value -Minimum $Low -Maximum $High) {
            return [int]$value
        }
        return $Default
    }
    $template = [string](Get-DbHubMember -InputObject $Settings -Name 'rcaScriptTemplate')
    return [pscustomobject]@{
        Supported         = ($template.Contains('__REQUEST__') -and (Test-DbHubSessionCapable -Settings $Settings))
        StopMinutes       = (& $read 'stopMinutes' 6 1 30)
        RecheckMinutes    = (& $read 'recheckMinutes' 8 1 30)
        StartMinutes      = (& $read 'startMinutes' 6 1 30)
        MaxParallel       = (& $read 'maxParallel' 10 1 20)
        ExportSeconds     = (& $read 'exportSeconds' 600 60 900)
        PartSeconds       = (& $read 'partSeconds' 120 30 900)
        # How long the T2 host's export waits for a Run Command's delete before it asks again (R871).
        HostDeleteSeconds = (& $read 'hostDeleteSeconds' 300 0 1800)
    }
}

function Get-DbHubRcaHost {
    # The VMs whose runner's observer captures evidence (rca/README.md, The flow), with their targets: sqlvm01 for T1, T3,
    # T4, and T4's read replica; the T2 host for T2, whose guest's runner it reaches. T5 has no observer.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings
    )

    return @(
        [pscustomobject]@{ Vm = [string]$Settings.sqlVmName; Targets = @('T1', 'T3', 'T4', 'T4-replica'); OneAtATime = $false }
        [pscustomobject]@{ Vm = [string]$Settings.hostVmName; Targets = @('T2'); OneAtATime = $true }
    )
}

function Get-DbHubRcaScript {
    # The managed Run Command script of one Rca request: the VM-side control's template with the Rca action
    # (Get-DemoWorkloadControlTemplate, baked into the settings), the request as Base64 JSON, checked before it goes between
    # single quotes. It holds no secret.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Request
    )

    $template = [string](Get-DbHubMember -InputObject $Settings -Name 'rcaScriptTemplate')
    if (-not $template.Contains('__REQUEST__')) {
        throw 'The runbook settings have no RCA export template.'
    }
    $json = ConvertTo-Json -InputObject $Request -Depth 4 -Compress
    $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
    if ($encoded -notmatch '^[A-Za-z0-9+/=]+$') {
        throw 'An RCA request did not encode to Base64.'
    }
    return $template.Replace('__REQUEST__', $encoded)
}

function Read-DbHubRunCommandView {
    # One managed Run Command's instance view (Virtual Machine Run Commands - Get By Virtual Machine, $expand=instanceView):
    # Found, ExecutionState, ExitCode, and Output, the last 4 KB.
    # https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/get-by-virtual-machine
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Compute/virtualMachines/runCommands'
    $read = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/runCommands/{2}?$expand=instanceView' -f (Get-DbHubDemoPath -Settings $Context.Settings), $VmName, $Name) -ApiVersion $version
    if ($read.StatusCode -ne 200) {
        return [pscustomobject]@{ Found = $false; ExecutionState = ''; ExitCode = $null; Output = '' }
    }
    $view = Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $read.Body -Name 'properties') -Name 'instanceView'
    $exit = Get-DbHubMember -InputObject $view -Name 'exitCode'
    $code = $null
    if ($null -ne $exit) {
        $code = [int]$exit
    }
    return [pscustomobject]@{ Found = $true; ExecutionState = [string](Get-DbHubMember -InputObject $view -Name 'executionState'); ExitCode = $code; Output = [string](Get-DbHubMember -InputObject $view -Name 'output') }
}

function Clear-DbHubRcaRunCommand {
    # Deletes one of the export's managed Run Commands without waiting, once it's read or its time is up: deleting one whose
    # script still runs stops it (https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed), and no part
    # of the evidence stays in an instance view.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Compute/virtualMachines/runCommands'
    $null = Invoke-DbHubArm -Context $Context -Method DELETE -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/runCommands/{2}' -f (Get-DbHubDemoPath -Settings $Context.Settings), $VmName, $Name) -ApiVersion $version
}

function Get-DbHubRcaRoom {
    <#
    .SYNOPSIS
    How many managed Run Commands the export may add on a VM: a VM takes 25 in all
    (https://learn.microsoft.com/azure/virtual-machines/run-command-overview), less those it has. The export's own earlier
    ones go once the time in their name is more than an hour old, finished or not (review of 93243d6): until then, another
    job may still have to read one, such as the export a session's start sent before that VM's activity
    (Send-DbHubRcaEarlierExport), or a re-check's parts while a stop runs, and the runner lists a document only once. With
    -ClearFinished (a session's end), this control's other finished ones go too, as a run's start does
    (Clear-DbHubOldRunCommand): a terminal execution state, or a time in the name more than an hour old. Returns -1 when
    the VM's Run Commands couldn't be listed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName,

        [switch] $ClearFinished
    )

    $settings = $Context.Settings
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Compute/virtualMachines/runCommands'
    $list = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/runCommands?$expand=instanceView' -f (Get-DbHubDemoPath -Settings $settings), $VmName) -ApiVersion $version
    if ($list.StatusCode -ne 200) {
        return -1
    }
    $prefix = [string]$settings.runCommandPrefix
    $count = 0
    foreach ($item in @(Get-DbHubMember -InputObject $list.Body -Name 'value')) {
        if ($null -eq $item) {
            continue
        }
        $name = [string](Get-DbHubMember -InputObject $item -Name 'name')
        $export = $name.StartsWith($prefix + 'rca-', [System.StringComparison]::Ordinal)
        $ours = $export -or ($ClearFinished -and $name.StartsWith($prefix, [System.StringComparison]::Ordinal))
        if ($ours -and $name -match '^[A-Za-z0-9-]{1,64}$') {
            $view = Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $item -Name 'properties') -Name 'instanceView'
            $finished = -not $export -and [string](Get-DbHubMember -InputObject $view -Name 'executionState') -in $script:DbHubRcaTerminal
            $stamp = [DateTime]::MinValue
            if (-not $finished -and $name -match '-(\d{14})$' -and [DateTime]::TryParseExact($Matches[1], 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture, ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$stamp)) {
                $finished = $stamp.AddHours(1) -lt $Context.NowUtc
            }
            if ($finished) {
                Clear-DbHubRcaRunCommand -Context $Context -VmName $VmName -Name $name
                continue
            }
        }
        $count++
    }
    return [int][System.Math]::Max(0, 25 - $count)
}

function Get-DbHubRcaListed {
    <#
    .SYNOPSIS
    The export's managed Run Commands that Azure lists on a VM, whatever their state, one it's still deleting included:
    Ok ($false when they couldn't be listed), Names, and Stale. Before an export's first Run Command on the T2 host, which
    takes one at a time (R871), another job's there must be gone: live (2026-11-21), a stop's export ran there beside its
    session's re-check's last parts. A name whose time is more than an hour old is in Stale, not Names (review of 242a3ef7):
    Get-DbHubRcaRoom deletes it, finished or not, and Azure can go on listing one it's deleting (F31), which held the host
    up for every later export. No export runs that long: its deadline is at most 30 minutes, and a Run Command's time-out
    at most 1,020 s. It deletes nothing.
    https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/list-by-virtual-machine
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName
    )

    $settings = $Context.Settings
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Compute/virtualMachines/runCommands'
    $list = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/runCommands' -f (Get-DbHubDemoPath -Settings $settings), $VmName) -ApiVersion $version
    $names = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $stale = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if ($list.StatusCode -ne 200) {
        return [pscustomobject]@{ Ok = $false; Names = $names.ToArray(); Stale = $stale.ToArray() }
    }
    $prefix = [string]$settings.runCommandPrefix + 'rca-'
    foreach ($item in @(Get-DbHubMember -InputObject $list.Body -Name 'value')) {
        $name = [string](Get-DbHubMember -InputObject $item -Name 'name')
        if (-not $name.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            continue
        }
        $stamp = [DateTime]::MinValue
        if ($name -match '-(\d{14})$' -and [DateTime]::TryParseExact($Matches[1], 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture, ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$stamp) -and $stamp.AddHours(1) -lt $Context.NowUtc) {
            $stale.Add($name)
            continue
        }
        $names.Add($name)
    }
    return [pscustomobject]@{ Ok = $true; Names = $names.ToArray(); Stale = $stale.ToArray() }
}

function ConvertFrom-DbHubRcaOutput {
    <#
    .SYNOPSIS
    What one Rca Run Command printed (the VM-side control's Invoke-DemoControlRca): its result line, DBHUBDEMO-WORKLOAD
    with an ADR 0012 status, and the runner's own line after it (DBHUBDEMO-RCA-INDEX for the export, DBHUBDEMO-RCA for a
    part). Returns Status ('' without a result line), Message, OldRunner (the runner predates the export), OldBundle (the
    VM's bootstrap bundle predates the Rca action), Ran (the runner ran: the action records its exit code only then, so a
    Fail without it, such as PowerShell Direct into a guest that's still starting, exported nothing; re-check of d2067d69),
    and Line.
    #>
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Output
    )

    $answer = [pscustomobject]@{ Status = ''; Message = ''; OldRunner = $false; OldBundle = $false; Ran = $false; Line = '' }
    foreach ($raw in ([string]$Output -split '\r?\n')) {
        $text = $raw.Trim()
        if ($text.StartsWith('DBHUBDEMO-WORKLOAD ', [System.StringComparison]::Ordinal)) {
            $parsed = $null
            try {
                $parsed = $text.Substring(19) | ConvertFrom-Json
            }
            catch {
                $parsed = $null
            }
            if ($null -eq $parsed) {
                continue
            }
            $answer.Status = [string](Get-DbHubMember -InputObject $parsed -Name 'status')
            $answer.Message = ConvertTo-DbHubSafeText -Text ([string](Get-DbHubMember -InputObject $parsed -Name 'message'))
            $evidence = Get-DbHubMember -InputObject $parsed -Name 'evidence'
            $answer.OldRunner = (Get-DbHubMember -InputObject $evidence -Name 'oldRunner') -eq $true
            $answer.Ran = $null -ne (Get-DbHubMember -InputObject $evidence -Name 'exitCode')
            # A VM-side control from before the Rca action answers with its list of actions.
            $answer.OldBundle = $answer.Status -eq 'Fail' -and $answer.Message -match '^Unknown action' -and $answer.Message -notmatch '\bRca\b'
        }
        elseif ($text.StartsWith('DBHUBDEMO-RCA-INDEX ', [System.StringComparison]::Ordinal) -or $text.StartsWith('DBHUBDEMO-RCA ', [System.StringComparison]::Ordinal)) {
            $answer.Line = $text
        }
    }
    return $answer
}

function ConvertFrom-DbHubRcaExportIndex {
    <#
    .SYNOPSIS
    The export's index line, 'DBHUBDEMO-RCA-INDEX <json>' (rca/transport.schema.json, exportIndex): Valid, Why, Documents
    (documentId, parts, sha256), Status, and Message. An index of another kind or version isn't used: its Why says so, with
    ./scripts/deploy.ps1 as the fix (rca/README.md, Versioning).
    #>
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Line
    )

    $answer = [pscustomobject]@{ Valid = $false; Why = ''; Documents = @(); Status = ''; Message = '' }
    if (-not ([string]$Line).StartsWith('DBHUBDEMO-RCA-INDEX ', [System.StringComparison]::Ordinal) -or $Line.Length -gt 3400) {
        $answer.Why = 'the export printed no index line'
        return $answer
    }
    try {
        $index = $Line.Substring(20) | ConvertFrom-Json
    }
    catch {
        $answer.Why = 'its index line isn''t JSON'
        return $answer
    }
    $version = Get-DbHubMember -InputObject $index -Name 'version'
    if ([string](Get-DbHubMember -InputObject $index -Name 'kind') -cne 'ContosoCare.RcaExportIndex' -or -not (Test-DbHubInteger -Value $version -Minimum 1 -Maximum 1)) {
        $answer.Why = 'its index is of a kind or version this runbook doesn''t know (run ./scripts/deploy.ps1, which updates the runner and the runbooks together)'
        return $answer
    }
    $list = Get-DbHubListMember -InputObject $index -Name 'documents'
    $status = [string](Get-DbHubMember -InputObject $index -Name 'status')
    $message = Get-DbHubMember -InputObject $index -Name 'message'
    if (-not $list.Present -or -not $list.IsList -or @($list.Items).Count -gt 32 -or $status -cnotin $script:DbHubRcaStatuses -or $message -isnot [string] -or $message.Length -gt 500) {
        $answer.Why = 'its index doesn''t follow the contract'
        return $answer
    }
    $documents = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    foreach ($item in @($list.Items)) {
        $id = [string](Get-DbHubMember -InputObject $item -Name 'documentId')
        $parts = Get-DbHubMember -InputObject $item -Name 'parts'
        $sha = [string](Get-DbHubMember -InputObject $item -Name 'sha256')
        if ($id -cnotmatch $script:DbHubRcaDocumentPattern -or -not (Test-DbHubInteger -Value $parts -Minimum 1 -Maximum 99) -or $sha -cnotmatch '^[0-9a-f]{64}$' -or -not $seen.Add($id)) {
            $answer.Why = 'its index lists a document that doesn''t follow the contract'
            return $answer
        }
        $documents.Add([ordered]@{ documentId = $id; parts = [int]$parts; sha256 = $sha })
    }
    $answer.Valid = $true
    $answer.Documents = $documents.ToArray()
    $answer.Status = $status
    $answer.Message = ConvertTo-DbHubSafeText -Text $message
    return $answer
}

function Test-DbHubRcaPartLine {
    # Whether a line is the part asked for: the contract's pattern (rca/transport.schema.json, partLine), at most 3,400
    # characters, and the document, index, count, and SHA-256 the export's index gave.
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Line,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Document,

        [Parameter(Mandatory = $true)]
        [int] $Part
    )

    if ([string]::IsNullOrEmpty($Line) -or $Line.Length -gt 3400 -or $Line -cnotmatch $script:DbHubRcaPartPattern) {
        return $false
    }
    $fields = $Line.Split(' ')
    return ($fields[2] -ceq [string]$Document['documentId'] -and $fields[3] -ceq ('{0}/{1}' -f $Part, [int]$Document['parts']) -and $fields[4] -ceq [string]$Document['sha256'])
}

function Invoke-DbHubRcaExport {
    <#
    .SYNOPSIS
    The runner's evidence export on the demo's VMs, through managed Run Commands (ADR 0031): on each VM that runs, one
    'rca export' (with -Final, a session's last), then one 'rca part' for each part of each document it lists, and of each
    document an earlier export listed but didn't fetch whole (-Pending), up to maxParallel at a time per VM and never more
    than the VM has room for (Get-DbHubRcaRoom). Each Run Command is deleted once it's read. At -DeadlineUtc it stops: a
    part not read by then stays on the VM, and its document is in Pending for the next export. Returns Hosts (per VM: Vm,
    Targets, Outcome, Message), Lines (each document's part lines, by document ID, for the documents fetched whole), and
    Pending (documentId, parts, sha256, and vm of each document not fetched whole).

    .DESCRIPTION
    -Sent names export Run Commands already sent, by VM name, which this export reads instead of sending one (a session's
    start sends an earlier session's export on a VM right before that VM's activity goes out: Send-DbHubRcaEarlierExport),
    and -SentSession the session each was sent for, when it isn't -SessionId (review of 93243d6). What an export for
    another session lists isn't fetched: those documents are in Others, each with its sessionId and vm, for that session's
    later start. A sent export is read even on a VM that stopped since (review of 93243d6): reading its output needs no
    running VM, and the runner lists a document only once, so what it listed is kept as pending (Outcome Stopped).
    With -NoNewExport, it sends none: a VM that got none only has its -Pending documents' parts fetched (review of
    3b1348a), and one with neither is skipped. A VM in -SkipVm gets no export either (review of 93243d6): an earlier
    session holds what its observer captured that no export took (Get-DbHubRcaHeldByEarlier), and an export now would give
    that to this session; its -Pending documents' parts are still fetched, and it's Held.
    A host's Outcome: Exported, Partial (some documents not fetched whole), Nothing (nothing new was captured), Listed (its
    export listed only another session's documents), Stopped (its export ran, but the VM stopped before their parts were
    fetched), Held (no export: an earlier session holds its capture), Busy (the T2 host still listed another job's export
    Run Commands when this export's time was up, so it sent nothing there: below), OldRunner, OldBundle, Failed,
    TimedOut, NotRunning, or NoRoom. Each host also has ForSession (the session its export was for), ExportRead (that
    export ran, and its index was read), Unread (an export ran, or may have, whose index wasn't read: the runner lists a
    document only once, so what it listed is lost; re-check of d2067d69), Held, Outside (documents it listed that were
    captured outside the session they'd go with, not fetched: review of 02d398a), and Consumed (those an export with no
    session listed that no session takes).
    -HeldBy names, by VM, the earlier session that holds its capture that no export took, when it's known when that
    session's activity ended (-SessionWindow): what an export with no session lists there from within that activity is
    that session's capture, fetched or in Others like its own export's (review of 02d398a: a VM that still ran that
    session's activity at this start, such as a Run all in the minutes between a session's end and its auto-stop).
    Two jobs on the T2 host (live, 2026-11-21: a stop's export ran there beside its session's re-check's last two parts):
    the host takes one Run Command at a time across jobs too (R871), so an export sends its first Run Command there only
    once Azure lists no other export Run Command there (Get-DbHubRcaListed), polling until its deadline without holding
    up the other VM; and -WhileRunning (a session's re-check) sends no more Run Commands once that session's stop has
    begun (Test-DbHubRcaRecheckOpen, before each one): what it's still running ends and is read, and what it didn't fetch
    stays in Pending, which the stop takes (Add-DbHubRcaHandoff). Fenced says that happened.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowEmptyString()]
        [string] $SessionId = '',

        [switch] $Final,

        [Parameter(Mandatory = $true)]
        [datetime] $DeadlineUtc,

        [AllowEmptyCollection()]
        [object[]] $Pending = @(),

        [AllowNull()]
        [System.Collections.IDictionary] $Sent = $null,

        [AllowNull()]
        [System.Collections.IDictionary] $SentSession = $null,

        [switch] $ClearFinished,

        [AllowEmptyCollection()]
        [string[]] $OnlyVm = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $SkipVm = @(),

        [AllowNull()]
        [System.Collections.IDictionary] $SessionWindow = $null,

        [AllowNull()]
        [object] $OutsideFromUtc = $null,

        [AllowNull()]
        [object] $OutsideToUtc = $null,

        [AllowNull()]
        [System.Collections.IDictionary] $HeldBy = $null,

        [int] $PollSeconds = 10,

        [switch] $NoNewExport,

        [switch] $WhileRunning,

        [AllowNull()]
        [object] $HostNotBeforeUtc = $null
    )

    $settings = $Context.Settings
    $bounds = Get-DbHubRcaSetting -Settings $settings
    $startedUtc = Get-DbHubUtcNow
    $stamp = $startedUtc.ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $prefix = [string]$settings.runCommandPrefix
    # Read in the script blocks below.
    $finalExport = [bool]$Final
    $recheck = [bool]$WhileRunning
    $hostNotBefore = $HostNotBeforeUtc
    $hosts = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $work = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $documents = [ordered]@{}
    $pendingOut = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $addDocument = {
        param([object] $State, [System.Collections.IDictionary] $Reference)
        $id = [string]$Reference['documentId']
        if ($documents.Contains($id)) {
            return
        }
        $State.Sequence++
        $documents[$id] = [pscustomobject]@{ Reference = [ordered]@{ documentId = $id; parts = [int]$Reference['parts']; sha256 = [string]$Reference['sha256'] }; Vm = $State.Vm; Sequence = $State.Sequence; Lines = (New-Object -TypeName 'string[]' -ArgumentList ([int]$Reference['parts'])); Gone = $false }
        for ($part = 1; $part -le [int]$Reference['parts']; $part++) {
            $State.Queue.Add([pscustomobject]@{ DocumentId = $id; Part = $part })
        }
    }
    # Deletes a Run Command once it's read, or its time is up. On the T2 host its slot stays taken until Azure no longer
    # lists it (R871: there, parallel Run Commands' deletes failed, and the host's next start didn't get its goal state).
    $release = {
        param([object] $State, [string] $Name)
        Clear-DbHubRcaRunCommand -Context $Context -VmName $State.Vm -Name $Name
        if ($State.OneAtATime -and $bounds.HostDeleteSeconds -gt 0) {
            $State.Deleting.Add([pscustomobject]@{ Name = $Name; SinceUtc = (Get-DbHubUtcNow); Round = 1 })
        }
        else {
            $State.Free++
        }
    }
    # A session's re-check (-WhileRunning) sends no Run Command once that session's stop has begun, read before each one
    # it would send (live, 2026-11-21: one sent the T2 host two more parts after the stop began, beside the stop's export
    # there). Once closed, it stays closed.
    $fence = [pscustomobject]@{ Closed = $false }
    $mayOpen = {
        if ($recheck -and -not $fence.Closed -and -not (Test-DbHubRcaRecheckOpen -Status (Read-DbHubSessionStatusCopy -Context $Context) -SessionId $SessionId -StopMinutes $bounds.StopMinutes)) {
            $fence.Closed = $true
        }
        return (-not $fence.Closed)
    }
    # A VM's first Run Command of this export, with its export when it has one to send (WantExport): none once the
    # session's stop has begun (above), and on the T2 host none while Azure lists another job's export Run Commands there
    # (R871), or, up to DbHubRcaStaleWaitSeconds from this export's start, hour-old ones being deleted: it's Waiting, tried
    # again at each poll, and Busy at the deadline.
    $start = {
        param([object] $State)
        $State.Waiting = $false
        if (-not (& $mayOpen)) {
            # What it didn't fetch stays pending, for the stop (Add-DbHubRcaHandoff).
            $State.WantExport = $false
            $State.Queue.Clear()
            if (-not $State.Outcome) {
                $State.Outcome = 'Nothing'
            }
            $State.Message = '{0}: the session''s stop began, so this re-check sent nothing there.' -f $State.Vm
            return
        }
        if ($State.OneAtATime) {
            # A stop lists the T2 host only from 60 s after its mark (-HostNotBeforeUtc, review of 242a3ef7): a re-check that
            # read the mark just before it can still send there, after its three PUTs and two conflict waits.
            if ($hostNotBefore -is [datetime] -and (Get-DbHubUtcNow) -lt $hostNotBefore) {
                $State.Waiting = $true
                return
            }
            $listed = Get-DbHubRcaListed -Context $Context -VmName $State.Vm
            $State.ListFailed = -not $listed.Ok
            if (-not $listed.Ok -or @($listed.Names).Count -gt 0) {
                $State.Waiting = $true
                return
            }
            # The hour-old ones Get-DbHubRcaRoom has just asked Azure to delete: their deletes first, for a bounded time from
            # this export's start, then beside one that's stuck (re-review of e55e000b).
            if (@($listed.Stale).Count -gt 0 -and (Get-DbHubUtcNow) -lt $startedUtc.AddSeconds($script:DbHubRcaStaleWaitSeconds)) {
                $State.Waiting = $true
                return
            }
        }
        if (-not $State.WantExport) {
            return
        }
        $State.WantExport = $false
        $name = '{0}rca-{1}-x-{2}' -f $prefix, $State.Vm, $stamp
        $request = [ordered]@{ command = 'export'; sessionId = $SessionId; final = $finalExport; timeoutSeconds = $bounds.ExportSeconds }
        if (-not (Send-DbHubRunCommand -Context $Context -VmName $State.Vm -Name $name -Script (Get-DbHubRcaScript -Settings $settings -Request $request) -TimeoutSeconds ($bounds.ExportSeconds + 120) -ConflictDelaySeconds 10)) {
            $State.Outcome = 'Failed'
            $State.Message = 'Azure didn''t accept the export''s Run Command on {0}.' -f $State.Vm
            $State.Queue.Clear()
            return
        }
        $State.Export = $name
        $State.ExportDone = $false
        $State.Free--
    }
    # What an export printed (review of 93243d6, from a running VM or one that stopped since): its own session's documents
    # are fetched, another session's go to Others, for that session's start. A document captured outside the session the
    # export is for isn't fetched (review of 02d398a), decided from its ID, which starts with its window's start:
    # - before that session's activity began or after it ended (-SessionWindow, by session: StartUtc and EndUtc, an earlier
    #   session's at a start), or in the gap between the session before this one and this one (-OutsideFromUtc to
    #   -OutsideToUtc), where no session ran;
    # - everything an export with no session lists (a start's, on a VM that ran before it: activity outside a Run all
    #   session ran there), which goes with no session (Consumed), except what falls within the activity of the earlier
    #   session that holds the VM (-HeldBy), which is that session's.
    $slack = $script:DbHubRcaSlackMinutes
    $windows = $SessionWindow
    $gapFrom = $OutsideFromUtc
    $gapTo = $OutsideToUtc
    $holders = $HeldBy
    $isOutside = {
        param([string] $For, [AllowNull()] [object] $At)
        if ($At -isnot [datetime]) {
            return $false
        }
        if ($null -ne $windows -and $For -and $windows.Contains($For)) {
            $window = $windows[$For]
            $from = Get-DbHubMember -InputObject $window -Name 'StartUtc'
            $to = Get-DbHubMember -InputObject $window -Name 'EndUtc'
            if (($from -is [datetime] -and $At -lt ([datetime]$from).AddMinutes(-$slack)) -or ($to -is [datetime] -and $At -gt ([datetime]$to).AddMinutes($slack))) {
                return $true
            }
        }
        return ($For -eq $SessionId -and $gapFrom -is [datetime] -and $gapTo -is [datetime] -and $At -gt ([datetime]$gapFrom).AddMinutes($slack) -and $At -lt ([datetime]$gapTo).AddMinutes(-$slack))
    }
    # Whether a document's window starts within a session's activity, whose end is known.
    $isWithin = {
        param([string] $For, [AllowNull()] [object] $At)
        if ($At -isnot [datetime] -or -not $For -or $null -eq $windows -or -not $windows.Contains($For)) {
            return $false
        }
        $window = $windows[$For]
        $from = Get-DbHubMember -InputObject $window -Name 'StartUtc'
        $to = Get-DbHubMember -InputObject $window -Name 'EndUtc'
        return ($to -is [datetime] -and $At -le ([datetime]$to).AddMinutes($slack) -and ($from -isnot [datetime] -or $At -ge ([datetime]$from).AddMinutes(-$slack)))
    }
    $others = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $takeExport = {
        param([object] $State, [object] $View)
        $out = ConvertFrom-DbHubRcaOutput -Output $View.Output
        if ($out.OldBundle) {
            $State.Outcome = 'OldBundle'
            $State.Message = '{0}''s bootstrap bundle predates the RCA export, so nothing was exported from it; ./scripts/deploy.ps1 sends the current one.' -f $State.Vm
        }
        elseif ($out.OldRunner -or $out.Status -eq 'Not supported') {
            $State.Outcome = 'OldRunner'
            $State.Message = '{0}''s workload runner predates the RCA export, so nothing was exported from it; ./scripts/deploy.ps1 updates it.' -f $State.Vm
        }
        elseif ($out.Status -eq 'Not selected') {
            $State.Outcome = 'Nothing'
            $State.ExportRead = $true
            $State.Message = '{0}: {1}' -f $State.Vm, $out.Message
        }
        elseif ($out.Status -eq 'Pass') {
            $index = ConvertFrom-DbHubRcaExportIndex -Line $out.Line
            if ($index.Valid) {
                $State.ExportRead = $true
                $State.Outcome = 'Exported'
                foreach ($reference in @($index.Documents)) {
                    $at = ConvertFrom-DbHubRcaDocumentTime -DocumentId ([string]$reference['documentId'])
                    $for = [string]$State.ForSession
                    if (-not $for -and $SessionId) {
                        $holder = ''
                        if ($null -ne $holders -and $holders.Contains($State.Vm)) {
                            $holder = [string]$holders[$State.Vm]
                        }
                        if (-not (& $isWithin $holder $at)) {
                            $State.Consumed++
                            continue
                        }
                        $for = $holder
                    }
                    elseif (& $isOutside $for $at) {
                        $State.Outside++
                        continue
                    }
                    if ($for -eq $SessionId) {
                        $State.Listed++
                        & $addDocument $State $reference
                        continue
                    }
                    $others.Add([ordered]@{ documentId = [string]$reference['documentId']; parts = [int]$reference['parts']; sha256 = [string]$reference['sha256']; vm = $State.Vm; sessionId = $for })
                    $State.Others++
                }
                if (@($index.Documents).Count -eq 0) {
                    $State.Outcome = 'Nothing'
                    $State.Message = '{0}: nothing new was captured since the last export.' -f $State.Vm
                }
                elseif ($State.Listed -eq 0 -and $State.Others -eq 0) {
                    $State.Outcome = 'Nothing'
                    $State.Message = '{0}: only capture from outside a Run all session, which no session''s history takes.' -f $State.Vm
                }
            }
            else {
                $State.Outcome = 'Failed'
                $State.Message = '{0}''s export ran, but {1}.' -f $State.Vm, $index.Why
                $State.Unread = $true
            }
        }
        else {
            $State.Outcome = 'Failed'
            $detail = $out.Message
            if (-not $out.Status) {
                $detail = 'its Run Command ended {0} with no result line' -f $View.ExecutionState
            }
            $State.Message = '{0}''s export failed: {1}' -f $State.Vm, $detail
            # The runner listed what it exported before it failed, or may have (no result line); one that never ran
            # (PowerShell Direct into a guest that's still starting) listed nothing.
            $State.Unread = $out.Ran -or -not $out.Status
        }
    }
    foreach ($entry in (Get-DbHubRcaHost -Settings $settings)) {
        if (@($OnlyVm).Count -gt 0 -and $entry.Vm -notin $OnlyVm) {
            continue
        }
        $earlier = @($Pending | Where-Object { $null -ne $_ -and [string](Get-DbHubMember -InputObject $_ -Name 'vm') -eq $entry.Vm })
        $sentName = ''
        $forSession = $SessionId
        if ($null -ne $Sent -and $Sent.Contains($entry.Vm)) {
            $sentName = [string]$Sent[$entry.Vm]
            if ($null -ne $SentSession -and $SentSession.Contains($entry.Vm)) {
                $forSession = [string]$SentSession[$entry.Vm]
            }
        }
        $held = -not $sentName -and $entry.Vm -in @($SkipVm)
        $state = [pscustomobject]@{ Vm = $entry.Vm; Targets = $entry.Targets; OneAtATime = [bool]$entry.OneAtATime; Outcome = ''; Message = ''; Export = ''; ExportDone = $true; ForSession = $forSession; ExportRead = $false; Unread = $false; Held = $held; Others = 0; Outside = 0; Consumed = 0; Queue = (New-Object -TypeName 'System.Collections.Generic.List[object]'); InFlight = (New-Object -TypeName 'System.Collections.Generic.List[object]'); Deleting = (New-Object -TypeName 'System.Collections.Generic.List[object]'); Blocked = $false; Free = 0; Sequence = 0; Listed = 0; Waiting = $false; ListFailed = $false; WantExport = $false }
        if (($NoNewExport -or $held) -and -not $sentName -and $earlier.Count -eq 0) {
            if ($held) {
                $state.Outcome = 'Held'
                $state.Message = '{0} holds what its observer captured for an earlier session that no export took, so this export skipped it: a later session''s start exports that first, with that session''s ID (RCA.EARLIER).' -f $entry.Vm
                $hosts.Add($state)
            }
            continue
        }
        $hosts.Add($state)
        $power = Get-DbHubVmState -Context $Context -VmName $entry.Vm
        if ($power -ne 'running') {
            $state.Outcome = 'NotRunning'
            $state.Message = '{0} is {1}, so what its observer captured stays on it until the next export.' -f $entry.Vm, $power
            if ($sentName) {
                # The export a session's start sent before this VM stopped (a start that failed, or Stop now during a start;
                # review of 93243d6): its output is an ARM read, and the runner lists a document only once, so what it
                # listed stays pending for the next export, which fetches its parts.
                $view = Read-DbHubRunCommandView -Context $Context -VmName $entry.Vm -Name $sentName
                if ($view.Found -and $view.ExecutionState -in $script:DbHubRcaTerminal) {
                    & $takeExport $state $view
                    Clear-DbHubRcaRunCommand -Context $Context -VmName $entry.Vm -Name $sentName
                    if ($state.ExportRead -and ($state.Listed -gt 0 -or $earlier.Count -gt 0)) {
                        $state.Outcome = 'Stopped'
                    }
                }
                else {
                    $state.Unread = $true
                }
            }
            foreach ($item in $earlier) {
                $pendingOut.Add($item)
            }
            continue
        }
        $free = Get-DbHubRcaRoom -Context $Context -VmName $entry.Vm -ClearFinished:$ClearFinished
        if ($free -lt 0) {
            $state.Outcome = 'Failed'
            $state.Message = '{0}''s Run Commands couldn''t be listed, so nothing was exported from it.' -f $entry.Vm
            $state.Unread = [bool]$sentName
            foreach ($item in $earlier) {
                $pendingOut.Add($item)
            }
            continue
        }
        if (($NoNewExport -or $state.Held) -and -not $sentName) {
            # Only documents an export listed before: their parts are fetched as they are, with no export (review of 3b1348a).
            if ($free -lt 1) {
                $state.Outcome = 'NoRoom'
                $state.Message = '{0} already has 25 managed Run Commands, the most a VM takes, so nothing was fetched from it.' -f $entry.Vm
                foreach ($item in $earlier) {
                    $pendingOut.Add($item)
                }
                continue
            }
            $state.Outcome = 'Exported'
        }
        elseif (-not $sentName) {
            if ($free -lt 2) {
                $state.Outcome = 'NoRoom'
                $state.Message = '{0} already has 25 managed Run Commands, the most a VM takes, so nothing was exported from it.' -f $entry.Vm
                foreach ($item in $earlier) {
                    $pendingOut.Add($item)
                }
                continue
            }
            $state.WantExport = $true
        }
        else {
            $state.Export = $sentName
            $state.ExportDone = $false
        }
        $state.Free = $free
        foreach ($item in $earlier) {
            & $addDocument $state (ConvertTo-DbHubDictionary -InputObject $item)
        }
        $work.Add($state)
        if (-not $sentName) {
            & $start $state
        }
    }

    while ($true) {
        $busy = $false
        $late = (Get-DbHubUtcNow) -ge $DeadlineUtc
        foreach ($state in $work) {
            if ($state.Waiting) {
                if (-not $late) {
                    & $start $state
                }
                if ($state.Waiting) {
                    if (-not $late) {
                        $busy = $true
                        continue
                    }
                    $state.Waiting = $false
                    $state.WantExport = $false
                    $state.Outcome = 'Busy'
                    # A list that kept failing kept the host waiting too, as it should; its message says so (review of 242a3ef7).
                    $state.Message = if ($state.ListFailed) {
                        '{0} takes one Run Command at a time (R871), and its Run Commands couldn''t be listed when this export''s time was up, so this export sent nothing there; what its observer captured stays on it until the next export.' -f $state.Vm
                    }
                    else {
                        '{0} takes one Run Command at a time (R871), and another job''s export Run Commands were still there when this export''s time was up, so this export sent nothing there; what its observer captured stays on it until the next export.' -f $state.Vm
                    }
                    continue
                }
            }
            if (-not $state.ExportDone) {
                $view = Read-DbHubRunCommandView -Context $Context -VmName $state.Vm -Name $state.Export
                if ($view.Found -and $view.ExecutionState -in $script:DbHubRcaTerminal) {
                    $state.ExportDone = $true
                    & $release $state $state.Export
                    & $takeExport $state $view
                }
                elseif ($late) {
                    Clear-DbHubRcaRunCommand -Context $Context -VmName $state.Vm -Name $state.Export
                    $state.ExportDone = $true
                    $state.Outcome = 'TimedOut'
                    $state.Unread = $true
                    $state.Message = '{0}''s export didn''t end in time, so what its observer captured stays on it until the next export.' -f $state.Vm
                }
            }
            # The T2 host's deletes, one Run Command at a time there (R871): a slot comes back once Azure no longer lists it;
            # a delete Azure doesn't finish in time is asked for once more, and after a second one the host gets no more.
            foreach ($item in @($state.Deleting.ToArray())) {
                $read = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/runCommands/{2}' -f (Get-DbHubDemoPath -Settings $settings), $state.Vm, $item.Name) -ApiVersion (Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Compute/virtualMachines/runCommands')
                if ($read.StatusCode -eq 404) {
                    $null = $state.Deleting.Remove($item)
                    $state.Free++
                    continue
                }
                if (((Get-DbHubUtcNow) - $item.SinceUtc).TotalSeconds -lt $bounds.HostDeleteSeconds) {
                    continue
                }
                $null = $state.Deleting.Remove($item)
                if ($item.Round -lt 2) {
                    Clear-DbHubRcaRunCommand -Context $Context -VmName $state.Vm -Name $item.Name
                    $state.Deleting.Add([pscustomobject]@{ Name = $item.Name; SinceUtc = (Get-DbHubUtcNow); Round = 2 })
                    continue
                }
                $state.Blocked = $true
            }
            foreach ($flight in @($state.InFlight.ToArray())) {
                $view = Read-DbHubRunCommandView -Context $Context -VmName $state.Vm -Name $flight.Name
                $ended = $view.Found -and $view.ExecutionState -in $script:DbHubRcaTerminal
                if (-not $ended -and -not $late) {
                    continue
                }
                & $release $state $flight.Name
                $null = $state.InFlight.Remove($flight)
                if (-not $ended) {
                    continue
                }
                $document = $documents[$flight.DocumentId]
                $out = ConvertFrom-DbHubRcaOutput -Output $view.Output
                if ($out.Status -eq 'Pass' -and (Test-DbHubRcaPartLine -Line $out.Line -Document $document.Reference -Part $flight.Part)) {
                    $document.Lines[$flight.Part - 1] = $out.Line
                }
                elseif ($out.Status -eq 'Fail' -and $out.Message -match 'exit code 1\b') {
                    # The runner says the document or part doesn't exist (rca/README.md, The runner's commands).
                    $document.Gone = $true
                }
            }
            $limit = $bounds.MaxParallel
            if ($state.OneAtATime) {
                $limit = 1
            }
            $taken = $state.InFlight.Count + $state.Deleting.Count
            if ($state.OneAtATime -and -not $state.ExportDone) {
                $taken++
            }
            while (-not $late -and -not $state.Blocked -and $state.Queue.Count -gt 0 -and $taken -lt $limit -and $state.Free -gt 0) {
                $item = $state.Queue[0]
                $state.Queue.RemoveAt(0)
                $document = $documents[$item.DocumentId]
                if ($document.Gone) {
                    continue
                }
                if (-not (& $mayOpen)) {
                    $state.Queue.Clear()
                    break
                }
                $name = '{0}rca-{1}-{2:d2}{3:d2}-{4}' -f $prefix, $state.Vm, $document.Sequence, $item.Part, $stamp
                $request = [ordered]@{ command = 'part'; documentId = $item.DocumentId; part = $item.Part; timeoutSeconds = $bounds.PartSeconds }
                if (Send-DbHubRunCommand -Context $Context -VmName $state.Vm -Name $name -Script (Get-DbHubRcaScript -Settings $settings -Request $request) -TimeoutSeconds ($bounds.PartSeconds + 60) -ConflictDelaySeconds 10) {
                    $state.InFlight.Add([pscustomobject]@{ Name = $name; DocumentId = $item.DocumentId; Part = $item.Part })
                    $state.Free--
                    $taken++
                }
            }
            if (-not $state.ExportDone -or $state.InFlight.Count -gt 0 -or ($state.Queue.Count -gt 0 -and -not $late -and -not $state.Blocked)) {
                $busy = $true
            }
        }
        if (-not $busy -or $late) {
            break
        }
        Start-Sleep -Seconds $PollSeconds
    }

    $lines = [ordered]@{}
    $vms = @{}
    foreach ($id in @($documents.Keys)) {
        $document = $documents[$id]
        $missing = @($document.Lines | Where-Object { [string]::IsNullOrEmpty($_) }).Count
        if ($missing -eq 0) {
            $lines[$id] = [string[]]$document.Lines
            $vms[$id] = $document.Vm
        }
        elseif (-not $document.Gone) {
            $kept = ConvertTo-DbHubDictionary -InputObject $document.Reference
            $kept['vm'] = $document.Vm
            $pendingOut.Add($kept)
        }
    }
    $answers = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($state in $hosts) {
        $left = @($pendingOut | Where-Object { [string](Get-DbHubMember -InputObject $_ -Name 'vm') -eq $state.Vm }).Count
        $whole = @($documents.Values | Where-Object { $_.Vm -eq $state.Vm -and $lines.Contains([string]$_.Reference['documentId']) })
        $gone = @($documents.Values | Where-Object { $_.Vm -eq $state.Vm -and $_.Gone }).Count
        $outcome = $state.Outcome
        $message = $state.Message
        if ($outcome -eq 'Exported' -and $state.Others -gt 0 -and $whole.Count -eq 0 -and $left -eq 0 -and $gone -eq 0) {
            # Its export listed only another session's documents (review of 93243d6).
            $outcome = 'Listed'
            $message = '{0}: its export listed {1} document(s) of another session.' -f $state.Vm, $state.Others
        }
        elseif ($outcome -in 'Exported', 'Nothing' -and ($left -gt 0 -or $gone -gt 0)) {
            $outcome = 'Partial'
        }
        if ($outcome -in 'Exported', 'Partial') {
            $partCount = 0
            foreach ($document in $whole) {
                $partCount += [int]$document.Reference['parts']
            }
            $message = '{0}: {1} document(s) in {2} part(s).' -f $state.Vm, $whole.Count, $partCount
            if ($left -gt 0) {
                $message = '{0} {1} document(s) weren''t fetched whole in time; they stay on {2} for the next export.' -f $message, $left, $state.Vm
            }
            if ($gone -gt 0) {
                $message = '{0} {1} document(s) that its export listed weren''t on {2} any more.' -f $message, $gone, $state.Vm
            }
            if ($state.Blocked) {
                $message = '{0} Azure didn''t delete a Run Command on {1} twice, so it got no more parts in this export (R871).' -f $message, $state.Vm
            }
        }
        elseif ($outcome -eq 'Stopped') {
            $message = '{0} stopped once its export had run, so {1} document(s) weren''t fetched; they stay on {0} for the next export.' -f $state.Vm, $left
        }
        $answers.Add([pscustomobject]@{ Vm = $state.Vm; Targets = $state.Targets; Outcome = $outcome; Message = $message; ForSession = [string]$state.ForSession; ExportRead = [bool]$state.ExportRead; Unread = [bool]$state.Unread; Held = [bool]$state.Held; Others = [int]$state.Others; Outside = [int]$state.Outside; Consumed = [int]$state.Consumed })
    }
    return [pscustomobject]@{ Hosts = $answers.ToArray(); Lines = $lines; Vms = $vms; Pending = $pendingOut.ToArray(); Others = $others.ToArray(); Fenced = [bool]$fence.Closed }
}

function Expand-DbHubRcaDocument {
    <#
    .SYNOPSIS
    One evidence document from its part lines (rca/README.md, Part lines): every index from 1 to its count once, each part's
    Base64 decoded on its own, concatenated in order, the SHA-256 that every part names checked, then gunzipped and parsed.
    Returns Ok, Why, and Document (the parsed JSON). A document with a missing or bad part is never used in part.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Line
    )

    $fail = {
        param([string] $Why)
        return [pscustomobject]@{ Ok = $false; Why = $Why; Document = $null }
    }
    $pieces = @{}
    $count = 0
    $sha = ''
    $id = ''
    foreach ($text in $Line) {
        if ([string]$text -cnotmatch $script:DbHubRcaPartPattern) {
            return (& $fail 'a part doesn''t follow the contract')
        }
        $fields = $text.Split(' ')
        $position = $fields[3].Split('/')
        if (-not $id) {
            $id = $fields[2]
            $count = [int]$position[1]
            $sha = $fields[4]
        }
        $index = [int]$position[0]
        if ($fields[2] -cne $id -or [int]$position[1] -ne $count -or $fields[4] -cne $sha -or $index -gt $count -or $pieces.ContainsKey($index)) {
            return (& $fail 'its parts disagree')
        }
        $pieces[$index] = $fields[5]
    }
    if ($count -eq 0 -or $pieces.Count -ne $count) {
        return (& $fail ('{0} of its {1} part(s) arrived' -f $pieces.Count, $count))
    }
    $buffer = New-Object -TypeName 'System.IO.MemoryStream'
    try {
        for ($index = 1; $index -le $count; $index++) {
            $bytes = [System.Convert]::FromBase64String([string]$pieces[$index])
            $buffer.Write($bytes, 0, $bytes.Length)
        }
    }
    catch {
        return (& $fail 'a part''s Base64 doesn''t decode')
    }
    $gzip = $buffer.ToArray()
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = -join ($hasher.ComputeHash($gzip) | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $hasher.Dispose()
    }
    if ($hash -cne $sha) {
        return (& $fail 'its SHA-256 doesn''t match')
    }
    $text = ''
    try {
        $compressed = New-Object -TypeName 'System.IO.MemoryStream' -ArgumentList (, [byte[]]$gzip)
        $stream = New-Object -TypeName 'System.IO.Compression.GZipStream' -ArgumentList $compressed, ([System.IO.Compression.CompressionMode]::Decompress)
        $plain = New-Object -TypeName 'System.IO.MemoryStream'
        try {
            $chunk = New-Object -TypeName 'byte[]' -ArgumentList 65536
            while (($read = $stream.Read($chunk, 0, $chunk.Length)) -gt 0) {
                $plain.Write($chunk, 0, $read)
                if ($plain.Length -gt $script:DbHubRcaMaxJsonBytes) {
                    return (& $fail 'it decompresses to more than the export can hold')
                }
            }
        }
        finally {
            $stream.Dispose()
        }
        $text = [System.Text.Encoding]::UTF8.GetString($plain.ToArray())
        $document = $text | ConvertFrom-Json
    }
    catch {
        return (& $fail 'it doesn''t decompress to JSON')
    }
    if ([string](Get-DbHubMember -InputObject $document -Name 'kind') -cne 'ContosoCare.RcaEvidence' -or -not (Test-DbHubInteger -Value (Get-DbHubMember -InputObject $document -Name 'version') -Minimum 1 -Maximum 1) -or [string](Get-DbHubMember -InputObject $document -Name 'documentId') -cne $id) {
        return (& $fail 'it isn''t an evidence document of version 1 with its own ID (run ./scripts/deploy.ps1, which updates the runner and the runbooks together)')
    }
    return [pscustomobject]@{ Ok = $true; Why = ''; Document = $document }
}

function Get-DbHubRcaCoverage {
    # The rca_coverage rows of a parsed evidence document (rca/history-tables.json): Target, Captured, Gaps, StartUtc, and
    # EndUtc, the strings and times decoded (rca/README.md, The evidence document).
    param(
        [AllowNull()]
        [object] $Document
    )

    $strings = @(Get-DbHubMember -InputObject $Document -Name 'strings')
    $epoch = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject $Document -Name 'epochUtc')
    $table = Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $Document -Name 'tables') -Name 'rca_coverage'
    $columns = Get-DbHubMember -InputObject $table -Name 'columns'
    $rows = Get-DbHubMember -InputObject $table -Name 'rows'
    if ($null -eq $epoch -or -not (Test-DbHubInteger -Value $rows -Minimum 0 -Maximum 20000)) {
        return @()
    }
    $text = {
        param([string] $Column, [int] $Row)
        $values = @(Get-DbHubMember -InputObject $columns -Name $Column)
        if ($Row -ge $values.Count -or $null -eq $values[$Row]) {
            return ''
        }
        $at = [int]$values[$Row]
        if ($at -lt 0 -or $at -ge $strings.Count) {
            return ''
        }
        return [string]$strings[$at]
    }
    $time = {
        param([string] $Column, [int] $Row)
        $values = @(Get-DbHubMember -InputObject $columns -Name $Column)
        if ($Row -ge $values.Count -or $null -eq $values[$Row]) {
            return $null
        }
        return $epoch.AddMilliseconds([double]$values[$Row])
    }
    $captured = @(Get-DbHubMember -InputObject $columns -Name 'captured')
    $found = for ($row = 0; $row -lt [int]$rows; $row++) {
        [pscustomobject]@{
            Target   = (& $text 'target' $row)
            Captured = ($row -lt $captured.Count -and $captured[$row] -eq $true)
            Gaps     = (& $text 'gaps' $row)
            StartUtc = (& $time 'window_start_utc' $row)
            EndUtc   = (& $time 'window_end_utc' $row)
        }
    }
    return @($found)
}

function Get-DbHubRcaCaptureLine {
    <#
    .SYNOPSIS
    The RCA.CAPTURE.<target> lines of an export (ADR 0031): for each target the documents cover, Pass when the observer
    captured its whole window, otherwise a Warning with the gaps it recorded (rca_coverage: what wasn't captured and why);
    for each target whose VM didn't export, a Warning with why. Returns Step, Status, Message, and Fix.
    #>
    param(
        [AllowEmptyCollection()]
        [object[]] $Document = @(),

        [AllowEmptyCollection()]
        [object[]] $HostResult = @()
    )

    $rows = @(foreach ($item in $Document) { Get-DbHubRcaCoverage -Document $item })
    $lines = foreach ($target in @('T1', 'T2', 'T3', 'T4', 'T4-replica')) {
        $mine = @($rows | Where-Object { $_.Target -ceq $target })
        if ($mine.Count -gt 0) {
            $start = @($mine | Where-Object { $null -ne $_.StartUtc } | ForEach-Object { $_.StartUtc } | Sort-Object | Select-Object -First 1)
            $end = @($mine | Where-Object { $null -ne $_.EndUtc } | ForEach-Object { $_.EndUtc } | Sort-Object | Select-Object -Last 1)
            $span = ''
            if ($start.Count -gt 0 -and $end.Count -gt 0) {
                $span = ' from {0} to {1} UTC' -f $start[0].ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture), $end[0].ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
            }
            $gaps = @($mine | ForEach-Object { ([string]$_.Gaps) -split '\r?\n' } | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
            $notCaptured = @($mine | Where-Object { -not $_.Captured }).Count
            if ($notCaptured -eq 0 -and $gaps.Count -eq 0) {
                [pscustomobject]@{ Step = ('RCA.CAPTURE.{0}' -f $target); Status = 'Pass'; Message = ('{0}: the observer captured{1}.' -f $target, $span); Fix = '' }
                continue
            }
            $said = @($gaps | Select-Object -First 3) -join ' '
            if (-not $said) {
                $said = 'the observer didn''t run for the whole window.'
            }
            $head = '{0}: captured{1}, with gaps:' -f $target, $span
            if ($notCaptured -eq $mine.Count) {
                $head = '{0}: not captured{1}:' -f $target, $span
            }
            [pscustomobject]@{ Step = ('RCA.CAPTURE.{0}' -f $target); Status = 'Warning'; Message = ('{0} {1}' -f $head, $said); Fix = 'Each gap says what wasn''t captured and why; docs/troubleshooting.md, "The Incident RCA''s capture", has the fixes.' }
            continue
        }
        $owner = @($HostResult | Where-Object { @($_.Targets) -contains $target }) | Select-Object -First 1
        if ($null -eq $owner -or $owner.Outcome -in 'Exported', 'Partial', 'Nothing', 'Listed', 'Held', '') {
            continue
        }
        $fix = 'What the observer captured stays on the VM, and a later session''s start exports it before its own activity there (RCA.EARLIER).'
        if ($owner.Outcome -in 'OldRunner', 'OldBundle') {
            $fix = 'Run ./scripts/deploy.ps1, which updates the runner and its bootstrap bundle on the VMs.'
        }
        [pscustomobject]@{ Step = ('RCA.CAPTURE.{0}' -f $target); Status = 'Warning'; Message = ('{0}: not exported. {1}' -f $target, $owner.Message); Fix = $fix }
    }
    return @($lines)
}

function New-DbHubRcaBundle {
    # The part lines as bundles (rca/transport.schema.json, bundle): each at most 6 parts and 24,000 bytes of UTF-8, in the
    # order given. Returns each bundle's compact JSON.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds JSON in memory only; it changes no system state.')]
    param(
        [AllowEmptyString()]
        [string] $SessionId = '',

        [AllowEmptyCollection()]
        [string[]] $Line = @()
    )

    $session = $null
    if ($SessionId) {
        $session = $SessionId
    }
    $make = {
        param([string[]] $Parts)
        return (ConvertTo-Json -InputObject ([ordered]@{ kind = 'ContosoCare.RcaBundle'; version = 1; sessionId = $session; parts = $Parts }) -Depth 4 -Compress)
    }
    $bundles = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $current = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($text in $Line) {
        if ($current.Count -gt 0) {
            $grown = New-Object -TypeName 'System.Collections.Generic.List[string]' -ArgumentList (, [string[]]$current.ToArray())
            $grown.Add($text)
            if ($current.Count -ge 6 -or [System.Text.Encoding]::UTF8.GetByteCount((& $make $grown.ToArray())) -gt 24000) {
                $bundles.Add((& $make $current.ToArray()))
                $current.Clear()
            }
        }
        $current.Add($text)
    }
    if ($current.Count -gt 0) {
        $bundles.Add((& $make $current.ToArray()))
    }
    return $bundles.ToArray()
}

function ConvertTo-DbHubRcaState {
    # A session's RCA state as its status keeps it (New-DbHubSessionStatus): sessionId, bundles (the metrics secret's
    # earlier versions that hold its parts), documents (documentId, parts, sha256), pending (documents not fetched whole, with
    # their vm), leftVms (VMs whose final export didn't run), final, finalRan (its final export ran on the VMs leftVms
    # doesn't list, so a VM that only holds pending documents needs no export; review of 3b1348a), status, message, and
    # boundVms (re-check of d2067d69: the VMs where a document of its own carried its ID, so the runner had bound that
    # capture to it, and keeps what's left of it its own, whichever session's export takes it later; Exporter.cs).
    # From a status's copy, or empty.
    param(
        [AllowNull()]
        [object] $State,

        [AllowEmptyString()]
        [string] $SessionId = ''
    )

    $answer = [ordered]@{ sessionId = $SessionId; bundles = @(); documents = @(); pending = @(); leftVms = @(); final = $false; finalRan = $false; status = ''; message = ''; boundVms = @() }
    if ($null -eq $State -or [string](Get-DbHubMember -InputObject $State -Name 'sessionId') -ne $SessionId) {
        return $answer
    }
    $answer['bundles'] = @(@(Get-DbHubMember -InputObject $State -Name 'bundles') | Where-Object { [string]$_ -cmatch '^[0-9a-f]{32}$' } | ForEach-Object { [string]$_ })
    $answer['documents'] = @(@(Get-DbHubMember -InputObject $State -Name 'documents') | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-DbHubDictionary -InputObject $_ })
    $answer['pending'] = @(@(Get-DbHubMember -InputObject $State -Name 'pending') | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-DbHubDictionary -InputObject $_ })
    $answer['leftVms'] = @(@(Get-DbHubMember -InputObject $State -Name 'leftVms') | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $answer['final'] = (Get-DbHubMember -InputObject $State -Name 'final') -eq $true
    $answer['finalRan'] = (Get-DbHubMember -InputObject $State -Name 'finalRan') -eq $true
    $answer['status'] = [string](Get-DbHubMember -InputObject $State -Name 'status')
    $answer['message'] = [string](Get-DbHubMember -InputObject $State -Name 'message')
    $answer['boundVms'] = @(@(Get-DbHubMember -InputObject $State -Name 'boundVms') | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    return $answer
}

function Invoke-DbHubRcaSessionExport {
    <#
    .SYNOPSIS
    A session's evidence into the control vault (ADR 0031): Invoke-DbHubRcaExport, then each document it fetched whole
    checked (Expand-DbHubRcaDocument, and that it's this session's), and their parts written as bundles, earlier versions of
    the metrics secret. Returns State (the session's RCA state, -Earlier's and this export's: ConvertTo-DbHubRcaState),
    Index (the bundle index for the rca member of the metrics' final version: every bundle of the session so far), and
    Lines (RCA.EXPORT and the RCA.CAPTURE.<target> lines: Step, Status, Message, Fix).

    .DESCRIPTION
    A bundle that couldn't be written puts its documents back in the pending list: the runner keeps an exported document for
    7 days, so the next export fetches it again. The index holds at most 16 bundles and 32 documents (rca/README.md,
    Limits); a document past them isn't listed, and RCA.EXPORT says so.
    -WhileRunning (DbHub-Monitor's re-check, review of 15ad76d): before each bundle, the session's status copy must say it
    runs and its stop hasn't begun (Test-DbHubRcaRecheckOpen); once it doesn't, no more bundles are written, and their
    documents stay pending. Held says that happened, and Fresh lists the documents this export found that its earlier state
    didn't have, each with its vm, for Add-DbHubRcaHandoff and Invoke-DbHubRcaEarlier. Invoke-DbHubRcaExport checks the
    same before each Run Command it would send, and sends none once the stop has begun (live, 2026-11-21: on the T2 host,
    which takes one at a time, a re-check's last parts ran beside the stop's export).
    -NoNewExport (an earlier session's evidence at a session's start, review of 3b1348a) sends no export: a VM in -Sent has
    the export its start sent read, and any other VM in -OnlyVm only has its pending documents' parts fetched, since an
    export listed them before.
    Another session's documents (review of 93243d6): the runner keeps a span of capture bound to the session of the first
    export that took from it, so an export can list what's left of an earlier session's, and an export the start sent for
    another session (-SentSession) lists that session's. They aren't written here: Others lists them, each with its
    sessionId and vm, and the caller hands them to that session's entry in rcaEarlierPending (Add-DbHubRcaElsewhere), for a
    later start. -SkipVm (Invoke-DbHubRcaExport) leaves out the export on VMs an earlier session holds; a final export
    counts them in leftVms. Hosts is Invoke-DbHubRcaExport's.
    Capture from outside the session (review of 02d398a): -SessionWindow and -OutsideFromUtc keep Invoke-DbHubRcaExport
    from fetching what was captured outside an earlier session's activity, or between the session before this one and
    this one.
    -OutsideToUtc is this session's start: once fetched, a document whose window starts before it is no capture of this
    session's, so it's not written (activity outside a Run all session that this session's export took, which no history
    takes), unless it's another session's, when it's that session's capture from before this one began, which goes to
    Others. Another session's document whose window starts after it is this session's capture under that session's ID
    (an earlier session's export at this session's start took it), which nothing separates now: it's not written, and
    RCA.EXPORT is a Warning. -HeldBy is Invoke-DbHubRcaExport's.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowEmptyString()]
        [string] $SessionId = '',

        [switch] $Final,

        [int] $Minutes = 6,

        [AllowNull()]
        [object] $Earlier = $null,

        [AllowNull()]
        [System.Collections.IDictionary] $Sent = $null,

        [AllowNull()]
        [System.Collections.IDictionary] $SentSession = $null,

        [switch] $ClearFinished,

        [AllowEmptyCollection()]
        [string[]] $OnlyVm = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $SkipVm = @(),

        [AllowNull()]
        [System.Collections.IDictionary] $SessionWindow = $null,

        [AllowNull()]
        [object] $OutsideFromUtc = $null,

        [AllowNull()]
        [object] $OutsideToUtc = $null,

        [AllowNull()]
        [System.Collections.IDictionary] $HeldBy = $null,

        [int] $PollSeconds = 10,

        [switch] $WhileRunning,

        [switch] $NoNewExport,

        [AllowNull()]
        [object] $HostNotBeforeUtc = $null
    )

    $state = ConvertTo-DbHubRcaState -State $Earlier -SessionId $SessionId
    $bounds = Get-DbHubRcaSetting -Settings $Context.Settings
    if (-not $bounds.Supported) {
        $state['status'] = 'Not supported'
        $state['message'] = 'The control''s runbook settings predate the RCA export (ADR 0031), so no evidence was exported; ./scripts/deploy.ps1 publishes them again.'
        return [pscustomobject]@{ State = $state; Index = $null; Lines = @([pscustomobject]@{ Step = 'RCA.EXPORT'; Status = 'Warning'; Message = $state['message']; Fix = 'Run ./scripts/deploy.ps1.' }); New = 0; Held = $false; Fresh = @(); Others = @(); Hosts = @() }
    }
    $earlierBundles = @($state['bundles']).Count
    $run = Invoke-DbHubRcaExport -Context $Context -SessionId $SessionId -Final:$Final -DeadlineUtc ((Get-DbHubUtcNow).AddMinutes($Minutes)) -Pending @($state['pending']) -Sent $Sent -SentSession $SentSession -ClearFinished:$ClearFinished -OnlyVm $OnlyVm -SkipVm $SkipVm -SessionWindow $SessionWindow -OutsideFromUtc $OutsideFromUtc -OutsideToUtc $OutsideToUtc -HeldBy $HeldBy -NoNewExport:$NoNewExport -WhileRunning:$WhileRunning -PollSeconds $PollSeconds -HostNotBeforeUtc $HostNotBeforeUtc
    $pending = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($item in @($run.Pending)) {
        $pending.Add($item)
    }
    $others = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($item in @($run.Others)) {
        $others.Add($item)
    }
    $known = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    foreach ($item in @($state['documents'])) {
        $null = $known.Add([string]$item['documentId'])
    }
    # Each document fetched whole, checked: its SHA-256, and that it's this session's, or that either has no session (the
    # operator's scripts export with --session none, and NB_DatabaseHub_LiveActivity writes a document when its session is
    # the run's, or either is empty; rca/README.md, RCA_EVIDENCE). Another session's goes to Others (review of 93243d6).
    $notes = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $good = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $parsed = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $elsewhere = 0
    $outside = 0
    $misbound = 0
    # The VMs where a document carried this session's own ID (re-check of d2067d69): the runner bound that capture to it.
    $boundHere = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($item in @($run.Hosts)) {
        $outside += [int](Get-DbHubMember -InputObject $item -Name 'Outside')
    }
    foreach ($id in @($run.Lines.Keys)) {
        $lines = [string[]]$run.Lines[$id]
        $expanded = Expand-DbHubRcaDocument -Line $lines
        if (-not $expanded.Ok) {
            $notes.Add(('{0} was skipped: {1}.' -f $id, $expanded.Why))
            continue
        }
        $documentSession = [string](Get-DbHubMember -InputObject $expanded.Document -Name 'sessionId')
        $documentVm = [string]$run.Vms[$id]
        if ($documentSession -and $documentSession -eq $SessionId -and $documentVm -and -not $boundHere.Contains($documentVm)) {
            $boundHere.Add($documentVm)
        }
        $at = ConvertFrom-DbHubRcaDocumentTime -DocumentId $id
        $before = $OutsideToUtc -is [datetime] -and $null -ne $at -and $at -lt ([datetime]$OutsideToUtc).AddMinutes(-$script:DbHubRcaSlackMinutes)
        if ($documentSession -and $SessionId -and $documentSession -ne $SessionId) {
            if ($OutsideToUtc -is [datetime] -and -not $before) {
                $misbound++
            }
            elseif ($documentSession -cmatch '^[0-9a-f]{32}$') {
                $others.Add([ordered]@{ documentId = $id; parts = $lines.Count; sha256 = $lines[0].Split(' ')[4]; vm = [string]$run.Vms[$id]; sessionId = $documentSession })
                $elsewhere++
            }
            else {
                $notes.Add(('{0} was skipped: it''s another session''s.' -f $id))
            }
            continue
        }
        if ($before) {
            $outside++
            continue
        }
        if ($known.Contains($id)) {
            continue
        }
        $good.Add([pscustomobject]@{ Reference = [ordered]@{ documentId = $id; parts = $lines.Count; sha256 = $lines[0].Split(' ')[4] }; Lines = $lines; Vm = [string]$run.Vms[$id] })
        $parsed.Add($expanded.Document)
    }

    # Bundles: the index lists at most 16 bundles and 32 documents.
    $name = [string](Get-DbHubMember -InputObject $Context.Settings -Name 'metricsName')
    if (-not $name) {
        $name = 'dbhub-session-metrics'
    }
    $bundles = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($version in @($state['bundles'])) {
        $bundles.Add([string]$version)
    }
    $batch = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $unlisted = 0
    foreach ($document in $good) {
        if (@($state['documents']).Count + $batch.Count -ge 32) {
            $unlisted++
            continue
        }
        $batch.Add($document)
    }
    $allLines = @(foreach ($document in $batch) { $document.Lines })
    $back = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    $offset = 0
    $held = $false
    foreach ($text in (New-DbHubRcaBundle -SessionId $SessionId -Line $allLines)) {
        $count = @((ConvertFrom-Json -InputObject $text).parts).Count
        $ids = @($allLines[$offset..($offset + $count - 1)] | ForEach-Object { $_.Split(' ')[2] } | Select-Object -Unique)
        $offset += $count
        $version = ''
        if (-not $held -and $WhileRunning -and -not (Test-DbHubRcaRecheckOpen -Status (Read-DbHubSessionStatusCopy -Context $Context) -SessionId $SessionId -StopMinutes $bounds.StopMinutes)) {
            # The session's stop has begun: its final version of the metrics comes next, and nothing goes after it.
            $held = $true
        }
        if ($bundles.Count -lt 16 -and -not $held) {
            $written = Set-DbHubVaultSecret -Context $Context -Name $name -Value $text -Tags @{ sessionId = $SessionId; rca = 'bundle' }
            if ($written.Ok -and $written.Version) {
                $version = [string]$written.Version
            }
        }
        if ($version) {
            $bundles.Add($version)
            continue
        }
        # Not written, or past the index's 16 bundles: the next export fetches these documents again.
        foreach ($id in $ids) {
            $null = $back.Add($id)
        }
    }
    $documents = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($item in @($state['documents'])) {
        $documents.Add($item)
    }
    $newCount = 0
    $newParts = 0
    # What this export found that its earlier state didn't have, with each document's VM (Add-DbHubRcaHandoff).
    $fresh = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $earlierPending = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    foreach ($item in @($state['pending'])) {
        $null = $earlierPending.Add([string](Get-DbHubMember -InputObject $item -Name 'documentId'))
    }
    foreach ($item in $pending) {
        if (-not $earlierPending.Contains([string](Get-DbHubMember -InputObject $item -Name 'documentId'))) {
            $fresh.Add($item)
        }
    }
    foreach ($document in $batch) {
        $id = [string]$document.Reference['documentId']
        $again = ConvertTo-DbHubDictionary -InputObject $document.Reference
        $again['vm'] = $document.Vm
        if (-not $earlierPending.Contains($id)) {
            $fresh.Add($again)
        }
        if ($back.Contains($id)) {
            $pending.Add($again)
            continue
        }
        $documents.Add($document.Reference)
        $newCount++
        $newParts += [int]$document.Reference['parts']
    }

    $hosts = @($run.Hosts)
    # A VM whose export didn't run, or that an earlier session holds (-SkipVm; review of 93243d6): the session may still
    # hold capture there that no export took.
    $left = @($hosts | Where-Object { $_.Outcome -in 'NotRunning', 'TimedOut', 'Failed', 'NoRoom', 'Held', 'Busy' -or $_.Held } | ForEach-Object { [string]$_.Vm })
    # Between a session's start and its end, a VM that doesn't run keeps what it captured for the stop or the next start,
    # and the session's host check says that it stopped: no export problem to report. Nor is a VM an earlier session holds,
    # or one whose export listed only another session's documents.
    $reported = @($hosts | Where-Object { $_.Outcome -notin 'Held', 'Listed' -and ($Final -or $_.Outcome -ne 'NotRunning') })
    $state['bundles'] = $bundles.ToArray()
    $state['documents'] = $documents.ToArray()
    $state['pending'] = $pending.ToArray()
    $state['boundVms'] = @(@($state['boundVms']) + @($boundHere.ToArray()) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($Final) {
        $state['leftVms'] = $left
        $state['final'] = $left.Count -eq 0 -and $pending.Count -eq 0
        $state['finalRan'] = $true
    }
    $status = 'Pass'
    if (@($reported | Where-Object { $_.Outcome -notin 'Exported', 'Nothing' }).Count -gt 0 -or $notes.Count -gt 0 -or ($Final -and $pending.Count -gt 0) -or $unlisted -gt 0 -or $misbound -gt 0) {
        $status = 'Warning'
    }
    elseif ($documents.Count -eq 0) {
        $status = 'Not selected'
    }
    $message = 'No new evidence document; {0} in all for this session.' -f $documents.Count
    if ($newCount -gt 0) {
        $message = '{0} new evidence document(s), {1} part(s), in {2} bundle(s) in the control vault; {3} in all for this session.' -f $newCount, $newParts, ($bundles.Count - $earlierBundles), $documents.Count
    }
    $extra = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($item in $reported) {
        if ($item.Message -and $item.Outcome -notin 'Exported', 'Nothing') {
            $extra.Add([string]$item.Message)
        }
    }
    foreach ($note in $notes) {
        $extra.Add($note)
    }
    if ($unlisted -gt 0) {
        $extra.Add(('{0} document(s) weren''t listed: the index holds at most 32.' -f $unlisted))
    }
    if ($back.Count -gt 0 -and $held) {
        $extra.Add(('The session''s stop began, so {0} document(s) weren''t written to the vault; its stop''s status keeps them for the next export.' -f $back.Count))
    }
    elseif ($back.Count -gt 0) {
        $extra.Add(('{0} document(s) weren''t written to the vault, so the next export fetches them again.' -f $back.Count))
    }
    $listed = 0
    foreach ($item in $hosts) {
        $listed += [int](Get-DbHubMember -InputObject $item -Name 'Others')
    }
    if ($elsewhere + $listed -gt 0) {
        $extra.Add(('{0} document(s) of another session go with that session''s evidence (RCA.EARLIER).' -f ($elsewhere + $listed)))
    }
    if ($outside -gt 0) {
        $extra.Add(('{0} document(s) from before the session began or after it ended weren''t saved: no session''s history takes them.' -f $outside))
    }
    if ($misbound -gt 0) {
        $extra.Add(('{0} document(s) of this session''s capture went with an earlier session''s ID, so they aren''t saved: that session''s export at this session''s start ran with this session''s activity on the VM.' -f $misbound))
    }
    if ($extra.Count -gt 0) {
        $message = '{0} {1}' -f $message, ($extra -join ' ')
    }
    $state['status'] = $status
    $state['message'] = ConvertTo-DbHubSafeText -Text $message
    $fix = ''
    if ($status -eq 'Warning') {
        # Only what's retried is said to be (review of 3b1348a): the documents not fetched whole, and a VM whose final export
        # didn't run, go to the session's next re-check or its stop, or to a later session's start (Get-DbHubRcaBacklog).
        $fixes = New-Object -TypeName 'System.Collections.Generic.List[string]'
        if ($Final -and ($pending.Count -gt 0 -or $left.Count -gt 0)) {
            $fixes.Add('What''s still on the VMs stays there, and a later session''s start exports it, one earlier session''s per start; that start''s RCA.EARLIER lines say until when')
        }
        elseif ($pending.Count -gt 0) {
            $fixes.Add('What''s still on the VMs is exported by the session''s next re-check, or by its stop')
        }
        if (@($reported | Where-Object { $_.Outcome -in 'OldRunner', 'OldBundle' }).Count -gt 0) {
            $fixes.Add('a runner or bootstrap bundle that predates the export is updated by ./scripts/deploy.ps1')
        }
        if ($misbound -gt 0) {
            $fixes.Add('nothing separates that capture now; it happens when a VM sets its activity profile at boot (activityProfileOnBoot) and an earlier session holds it, and with activityProfileOnBoot false it doesn''t')
        }
        if ($fixes.Count -gt 0) {
            $fix = ($fixes -join '; ') + '.'
            $fix = $fix.Substring(0, 1).ToUpperInvariant() + $fix.Substring(1)
        }
    }
    $out = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $out.Add([pscustomobject]@{ Step = 'RCA.EXPORT'; Status = $status; Message = $message; Fix = $fix })
    foreach ($line in (Get-DbHubRcaCaptureLine -Document $parsed.ToArray() -HostResult $reported)) {
        $out.Add($line)
    }
    return [pscustomobject]@{ State = $state; Index = (New-DbHubRcaIndex -State $state); Lines = $out.ToArray(); New = $newCount; Held = $held; Fresh = $fresh.ToArray(); Others = $others.ToArray(); Hosts = $hosts }
}

function New-DbHubRcaIndex {
    # The bundle index (rca/transport.schema.json, bundleIndex) from a session's RCA state: its bundles and documents, its
    # status, and its message, at most 500 characters, the whole within 4,000 bytes of JSON. $null without a bundle.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory record only; it changes no system state.')]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $State
    )

    if (@($State['bundles']).Count -eq 0) {
        return $null
    }
    $session = $null
    if ([string]$State['sessionId']) {
        $session = [string]$State['sessionId']
    }
    $status = [string]$State['status']
    if ($status -cnotin $script:DbHubRcaStatuses) {
        $status = 'Warning'
    }
    $message = [string]$State['message']
    if ($message.Length -gt 500) {
        $message = $message.Substring(0, 497) + '...'
    }
    $index = [ordered]@{ kind = 'ContosoCare.RcaBundleIndex'; version = 1; sessionId = $session; bundles = @($State['bundles']); documents = @(@($State['documents']) | ForEach-Object { [ordered]@{ documentId = [string]$_['documentId']; parts = [int]$_['parts']; sha256 = [string]$_['sha256'] } }); status = $status; message = $message }
    while ([System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $index -Depth 5 -Compress)) -gt 4000 -and $index['message'].Length -gt 40) {
        $index['message'] = $index['message'].Substring(0, [int]($index['message'].Length / 2)) + '...'
    }
    return $index
}

$script:DbHubRcaCarryDays = 7
$script:DbHubRcaCapturedDays = 30
$script:DbHubRcaCarryMost = 4
$script:DbHubRcaCarryBytes = 6000
$script:DbHubRcaRanPhases = @('starting', 'replica', 'running', 'stopped')
$script:DbHubRcaApartFix = 'Nothing separates it now. Each start exports what an earlier session left on a VM before its own activity there; this happens only when that export can''t run there.'
$script:DbHubRcaOutsideFix = 'Nothing separates it now. A start that finds a VM stopped exports what an earlier session left there before its own activity, so stop the demo (./scripts/stop-demo.ps1) before Run all when it runs outside a session.'
# How far a document's window may stray from its session's before it counts as captured outside it (review of 02d398a):
# the VMs' and the sandbox's clocks, and the observer's last half-minute sample.
$script:DbHubRcaSlackMinutes = 2
# How long a session's start waits for an export it sent to a VM before that VM's activity goes out (review of 02d398a).
$script:DbHubRcaReadySeconds = 180

function ConvertFrom-DbHubRcaDocumentTime {
    # When a document's capture window starts, from its ID (<yyyyMMddTHHmmssZ>-<host>-<sequence>, Exporter.cs), or $null.
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $DocumentId
    )

    $at = [DateTime]::MinValue
    if ([string]$DocumentId -cmatch '^([0-9]{8}T[0-9]{6}Z)-' -and [DateTime]::TryParseExact($Matches[1], 'yyyyMMdd''T''HHmmss''Z''', [System.Globalization.CultureInfo]::InvariantCulture, ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal), [ref]$at)) {
        return $at
    }
    return $null
}

function Get-DbHubRcaSessionEnd {
    # When a session's activity ended, from its status (review of 02d398a): its stop (stoppedUtc) or its planned end
    # (runEndUtc), whichever came first; $null when its status names neither. The observer captures a session only while
    # its activity runs, so a document whose window starts later is capture from outside it.
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Status
    )

    if ($null -eq $Status) {
        return $null
    }
    $end = ConvertTo-DbHubUtc -Value $Status['runEndUtc']
    $stopped = $null
    if ([string]$Status['phase'] -eq 'stopped') {
        $stopped = ConvertTo-DbHubUtc -Value $Status['stoppedUtc']
    }
    if ($null -ne $stopped -and ($null -eq $end -or $stopped -lt $end)) {
        $end = $stopped
    }
    return $end
}

function Wait-DbHubRcaRunCommand {
    <#
    .SYNOPSIS
    Waits at most -Seconds for one of the export's Run Commands to end (review of 02d398a). A session's start sends an
    export to a VM right before that VM's activity goes out, and managed Run Commands run in parallel on a VM
    (https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed): an export that ran beside the activity
    would take the new session's first capture too. Returns the instance view once it ended, or $null.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName,

        [Parameter(Mandatory = $true)]
        [string] $Name,

        [int] $Seconds = $script:DbHubRcaReadySeconds,

        [int] $PollSeconds = 10
    )

    $deadline = (Get-DbHubUtcNow).AddSeconds($Seconds)
    while ($true) {
        $view = Read-DbHubRunCommandView -Context $Context -VmName $VmName -Name $Name
        if ($view.Found -and $view.ExecutionState -in $script:DbHubRcaTerminal) {
            return $view
        }
        if (-not $view.Found) {
            return $null
        }
        if ((Get-DbHubUtcNow) -ge $deadline) {
            Write-DbHubLog -Context $Context -Message ('{0}: the RCA export {1} didn''t end in {2} seconds, so the activity goes out beside it.' -f $VmName, $Name, $Seconds)
            return $null
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-DbHubRcaActivityVm {
    <#
    .SYNOPSIS
    The VMs a session's activity went out to (review of 93243d6), from its status: its dispatch Run Commands' VMs
    (runCommands) and the targets it dispatched (dispatchUtc), T1, T3, T4, and T5 on sqlvm01 and T2 on the T2 host. The
    observer captures on a VM only during a profile run there (rca/README.md, The flow). $null when the status names
    neither, so where its activity went isn't known.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [AllowNull()]
        [System.Collections.IDictionary] $Status
    )

    if ($null -eq $Status -or (-not $Status.Contains('dispatchUtc') -and -not $Status.Contains('runCommands'))) {
        return $null
    }
    $hosts = @(Get-DbHubRcaHost -Settings $Settings)
    $names = @($hosts | ForEach-Object { [string]$_.Vm })
    $vms = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($item in @($Status['runCommands'])) {
        $vm = [string](Get-DbHubMember -InputObject $item -Name 'vm')
        if ($vm -and $vm -in $names -and -not $vms.Contains($vm)) {
            $vms.Add($vm)
        }
    }
    $dispatched = $Status['dispatchUtc']
    if ($dispatched -is [System.Collections.IDictionary]) {
        foreach ($target in @($dispatched.Keys | ForEach-Object { [string]$_ })) {
            foreach ($entry in $hosts) {
                $here = $target -in @($entry.Targets) -or ($target -eq 'T5' -and [string]$entry.Vm -eq [string]$Settings.sqlVmName)
                if ($here -and -not $vms.Contains([string]$entry.Vm)) {
                    $vms.Add([string]$entry.Vm)
                }
            }
        }
    }
    return , $vms.ToArray()
}

function Get-DbHubRcaHeldVm {
    <#
    .SYNOPSIS
    The VMs where a session may still hold capture that no export took (review of 93243d6): those its final export didn't
    run on (its RCA state's leftVms, or every VM when it never ran), of the ones its activity went out to
    (Get-DbHubRcaActivityVm). Returns Vms and Known: whether its status says where its activity went (when it doesn't,
    every VM its final export didn't run on). A status still starting (its start's job ended before its last write) may
    not list every dispatch, so it doesn't say.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $State
    )

    $activity = $null
    if ([string]$Status['phase'] -notin 'accepted', 'starting') {
        $activity = Get-DbHubRcaActivityVm -Settings $Settings -Status $Status
    }
    $known = $null -ne $activity
    if ($State['final']) {
        return [pscustomobject]@{ Vms = @(); Known = $known }
    }
    $vms = @(@($State['leftVms']) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($vms.Count -eq 0 -and -not $State['finalRan']) {
        $vms = @(Get-DbHubRcaHost -Settings $Settings | ForEach-Object { [string]$_.Vm })
    }
    if ($known) {
        $vms = @($vms | Where-Object { $_ -in $activity })
    }
    return [pscustomobject]@{ Vms = $vms; Known = $known }
}

function ConvertTo-DbHubRcaPendingList {
    # Document references as a status keeps them, each with the VM whose runner keeps the document: valid IDs only, each once.
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Item = @()
    )

    $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    foreach ($entry in @($Item)) {
        if ($null -eq $entry) {
            continue
        }
        $id = [string](Get-DbHubMember -InputObject $entry -Name 'documentId')
        $vm = [string](Get-DbHubMember -InputObject $entry -Name 'vm')
        if ($id -cmatch $script:DbHubRcaDocumentPattern -and $vm -and $seen.Add($id)) {
            $list.Add([ordered]@{ documentId = $id; parts = [int](Get-DbHubMember -InputObject $entry -Name 'parts'); sha256 = [string](Get-DbHubMember -InputObject $entry -Name 'sha256'); vm = $vm })
        }
    }
    return , $list.ToArray()
}

function Get-DbHubRcaPendingText {
    # Documents an export listed but didn't fetch whole, in words.
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Pending = @()
    )

    $items = @(@($Pending) | Where-Object { $null -ne $_ })
    $vms = @($items | ForEach-Object { [string](Get-DbHubMember -InputObject $_ -Name 'vm') } | Where-Object { $_ } | Select-Object -Unique)
    return ('{0} document(s) on {1} that an export listed but didn''t fetch whole' -f $items.Count, ($vms -join ' and '))
}

function ConvertTo-DbHubRcaCarry {
    <#
    .SYNOPSIS
    One earlier session's evidence that's still on the VMs, as a status carries it in rcaEarlierPending (review of 3b1348a,
    93243d6): sessionId; pending, the documents an export listed but didn't fetch whole, each with its vm, and expiresUtc,
    when the runner deletes them (7 days after the export that listed them); leftVms, the VMs where it holds capture that no
    export took, and heldUntilUtc, when the runner deletes that (30 days after it began: EvidenceStore.cs); boundVms, those of
    them where a document of its own had carried its ID, so the runner keeps what's left there its own (re-check of
    d2067d69); startUtc and endUtc, when its activity began and ended, outside which nothing an export lists under its ID
    is its capture (review of 02d398a); and, while no
    saved index lists its bundles (the nightly stop or the VMs' auto-shutdown ended it, or a start was refused before it
    fetched them), its bundles and documents, for the index of the start that fetches it. $null when nothing is left.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Entry
    )

    $session = [string]$Entry['sessionId']
    if ($session -cnotmatch '^[0-9a-f]{32}$') {
        return $null
    }
    $pending = ConvertTo-DbHubRcaPendingList -Item @($Entry['pending'])
    $left = @(@($Entry['leftVms']) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    $bundles = @()
    $documents = @()
    if ($Entry['mustFetch'] -and $null -ne $Entry['rca']) {
        $bundles = @(@($Entry['rca']['bundles']) | Where-Object { [string]$_ -cmatch '^[0-9a-f]{32}$' } | ForEach-Object { [string]$_ })
        $documents = @(@($Entry['rca']['documents']) | Where-Object { $null -ne $_ } | ForEach-Object { [ordered]@{ documentId = [string](Get-DbHubMember -InputObject $_ -Name 'documentId'); parts = [int](Get-DbHubMember -InputObject $_ -Name 'parts'); sha256 = [string](Get-DbHubMember -InputObject $_ -Name 'sha256') } })
    }
    if ($pending.Count -eq 0 -and $left.Count -eq 0 -and $bundles.Count -eq 0) {
        return $null
    }
    $carry = [ordered]@{ sessionId = $session; pending = $pending; leftVms = $left }
    if ($pending.Count -gt 0 -and $Entry['expiresUtc'] -is [datetime]) {
        $carry['expiresUtc'] = ConvertTo-DbHubTimeText -Value $Entry['expiresUtc']
    }
    if ($left.Count -gt 0 -and $Entry['heldUntilUtc'] -is [datetime]) {
        $carry['heldUntilUtc'] = ConvertTo-DbHubTimeText -Value $Entry['heldUntilUtc']
    }
    $bound = @(@($Entry['boundVms']) | Where-Object { $_ -and [string]$_ -in $left } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($bound.Count -gt 0) {
        $carry['boundVms'] = $bound
    }
    if ($Entry['startUtc'] -is [datetime]) {
        $carry['startUtc'] = ConvertTo-DbHubTimeText -Value $Entry['startUtc']
    }
    if ($Entry['endUtc'] -is [datetime]) {
        $carry['endUtc'] = ConvertTo-DbHubTimeText -Value $Entry['endUtc']
    }
    if ($bundles.Count -gt 0) {
        $carry['bundles'] = $bundles
        $carry['documents'] = $documents
    }
    return $carry
}

function Get-DbHubRcaBacklog {
    <#
    .SYNOPSIS
    The earlier sessions whose evidence is still on the VMs (review of 3b1348a, 93243d6), from the status a session's start
    or stop replaces: the ones it carried (rcaEarlierPending), then its own session, when that isn't -SessionId, it ran (its
    phase is starting, replica, running, or stopped), and it holds capture that no export took (Get-DbHubRcaHeldVm),
    documents not fetched whole, or bundles that no saved index lists. Returns Entries (each [ordered]@{ sessionId; pending;
    leftVms; boundVms; expiresUtc; heldUntilUtc; rca, its RCA state for the fetch; previous; known; mustFetch }), Expired (each part
    past its time: documents 7 days after the export that listed them, capture 30 days after it began), Dropped (past the 4
    sessions or 6,000 bytes a status keeps, the first to expire going first), and Inseparable (a VM two sessions held). Each
    entry's startUtc and endUtc are when its activity began (acceptedUtc) and ended (Get-DbHubRcaSessionEnd), or $null when
    that isn't known.

    .DESCRIPTION
    The runner binds each span of capture to the session of the first export that takes from it (Exporter.cs), so a VM's
    capture that no export took belongs to one session at most, which must export it before any other session's export runs
    there (review of 93243d6). When two hold the same VM, the later one's activity ran there before the earlier one's export
    did, so whichever exports first takes both: the earlier claim goes (Inseparable), unless the later session's status
    doesn't say where its activity went, when an earlier claim that outlived its start means its activity didn't go there,
    and its own claim goes. An earlier claim that goes is lost even where the runner had bound it to its session
    (boundVms): the later holder's export there lists it with that ID, but from before the later session began, which that
    export doesn't take (review of 02d398a). -KeepAll (a stop, whose status has no steps) keeps everything, so the next
    start says what expired.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [AllowNull()]
        [System.Collections.IDictionary] $Previous,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $SessionId,

        [Parameter(Mandatory = $true)]
        [datetime] $NowUtc,

        [switch] $KeepAll
    )

    $entries = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $expired = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $dropped = New-Object -TypeName 'System.Collections.Generic.List[object]'
    $inseparable = New-Object -TypeName 'System.Collections.Generic.List[object]'
    if ($null -eq $Previous) {
        return [pscustomobject]@{ Entries = @(); Expired = @(); Dropped = @(); Inseparable = @() }
    }
    $hosts = @(Get-DbHubRcaHost -Settings $Settings | ForEach-Object { [string]$_.Vm })
    # The replaced status's own session, which goes last.
    $own = $null
    $ownId = [string]$Previous['sessionId']
    $ownRca = Get-DbHubMember -InputObject $Previous -Name 'rca'
    if ($ownId -cmatch '^[0-9a-f]{32}$' -and $ownId -ne $SessionId -and $null -ne $ownRca -and [string]$Previous['phase'] -in $script:DbHubRcaRanPhases) {
        $state = ConvertTo-DbHubRcaState -State $ownRca -SessionId $ownId
        $held = Get-DbHubRcaHeldVm -Settings $Settings -Status $Previous -State $state
        $pending = ConvertTo-DbHubRcaPendingList -Item @($state['pending'])
        # Its bundles are in a saved index only once its stop wrote the metrics' final version, which lists them.
        $metricsStatus = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $Previous -Name 'metrics') -Name 'status')
        $unsaved = @($state['bundles']).Count -gt 0 -and ([string]$Previous['phase'] -ne 'stopped' -or $metricsStatus -notin 'Pass', 'Warning')
        if (@($held.Vms).Count -gt 0 -or $pending.Count -gt 0 -or $unsaved) {
            $since = ConvertTo-DbHubUtc -Value $Previous['updatedUtc']
            if ($null -eq $since -or $since -gt $NowUtc) {
                $since = $NowUtc
            }
            $began = ConvertTo-DbHubUtc -Value $Previous['acceptedUtc']
            if ($null -eq $began -or $began -gt $since) {
                $began = $since
            }
            $own = [ordered]@{ sessionId = $ownId; pending = $pending; leftVms = @($held.Vms); boundVms = @($state['boundVms']); expiresUtc = $since.AddDays($script:DbHubRcaCarryDays); heldUntilUtc = $began.AddDays($script:DbHubRcaCapturedDays); startUtc = (ConvertTo-DbHubUtc -Value $Previous['acceptedUtc']); endUtc = (Get-DbHubRcaSessionEnd -Status $Previous); rca = $state; previous = $true; known = [bool]$held.Known; mustFetch = $unsaved }
        }
    }
    $seen = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
    foreach ($item in @(Get-DbHubMember -InputObject $Previous -Name 'rcaEarlierPending')) {
        if ($null -eq $item) {
            continue
        }
        $carry = ConvertTo-DbHubDictionary -InputObject $item
        $session = [string]$carry['sessionId']
        if ($session -cnotmatch '^[0-9a-f]{32}$' -or $session -eq $SessionId -or -not $seen.Add($session)) {
            continue
        }
        $pending = ConvertTo-DbHubRcaPendingList -Item @($carry['pending'])
        $left = @(@($carry['leftVms']) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
        if ($left.Count -eq 0 -and $carry.Contains('finalRan') -and $carry['finalRan'] -ne $true) {
            # A carry from before heldUntilUtc (93243d6) whose session's final export never ran: it held every VM.
            $left = $hosts
        }
        $expires = ConvertTo-DbHubUtc -Value $carry['expiresUtc']
        if ($null -eq $expires -or $expires -gt $NowUtc.AddDays($script:DbHubRcaCarryDays)) {
            # Its documents were listed before now, so the runner deletes them within 7 days of now (review of 93243d6: a
            # carry from 93243d6 could give them the 30 days of capture that no export took).
            $expires = $NowUtc.AddDays($script:DbHubRcaCarryDays)
        }
        $heldUntil = ConvertTo-DbHubUtc -Value $carry['heldUntilUtc']
        if ($null -eq $heldUntil) {
            $heldUntil = ConvertTo-DbHubUtc -Value $carry['expiresUtc']
        }
        if ($null -eq $heldUntil) {
            $heldUntil = $NowUtc.AddDays($script:DbHubRcaCapturedDays)
        }
        $bundles = @(@($carry['bundles']) | Where-Object { [string]$_ -cmatch '^[0-9a-f]{32}$' } | ForEach-Object { [string]$_ })
        $bound = @(@($carry['boundVms']) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
        if ($null -ne $own -and $session -eq $ownId) {
            # Documents of the replaced session that another export found (Add-DbHubRcaElsewhere).
            $own['pending'] = ConvertTo-DbHubRcaPendingList -Item (@($own['pending']) + @($pending))
            $own['leftVms'] = @(@($own['leftVms']) + @($left) | Select-Object -Unique)
            $own['boundVms'] = @(@($own['boundVms']) + @($bound) | Where-Object { $_ } | Select-Object -Unique)
            continue
        }
        if ($pending.Count -eq 0 -and $left.Count -eq 0 -and $bundles.Count -eq 0) {
            continue
        }
        $state = ConvertTo-DbHubRcaState -State ([ordered]@{ sessionId = $session; bundles = $bundles; documents = @($carry['documents'] | Where-Object { $null -ne $_ }); pending = $pending; leftVms = $left; finalRan = $true; boundVms = $bound }) -SessionId $session
        $entries.Add([ordered]@{ sessionId = $session; pending = $pending; leftVms = $left; boundVms = $bound; expiresUtc = $expires; heldUntilUtc = $heldUntil; startUtc = (ConvertTo-DbHubUtc -Value $carry['startUtc']); endUtc = (ConvertTo-DbHubUtc -Value $carry['endUtc']); rca = $state; previous = $false; known = $true; mustFetch = ($bundles.Count -gt 0) })
    }
    if ($null -ne $own) {
        $entries.Add($own)
    }
    if (-not $KeepAll) {
        # One session per VM.
        foreach ($vm in $hosts) {
            if (@($entries | Where-Object { $vm -in @($_['leftVms']) }).Count -lt 2) {
                continue
            }
            $keep = $null
            if ($null -ne $own -and $vm -in @($own['leftVms'])) {
                if ($own['known']) {
                    $keep = $own
                }
                else {
                    $own['leftVms'] = @(@($own['leftVms']) | Where-Object { $_ -ne $vm })
                }
            }
            $claims = @($entries | Where-Object { $vm -in @($_['leftVms']) })
            if ($null -eq $keep) {
                $keep = $claims[0]
            }
            foreach ($claim in $claims) {
                if (-not [object]::ReferenceEquals($claim, $keep)) {
                    $claim['leftVms'] = @(@($claim['leftVms']) | Where-Object { $_ -ne $vm })
                    $inseparable.Add([ordered]@{ sessionId = [string]$claim['sessionId']; vm = $vm; with = [string]$keep['sessionId']; why = '' })
                }
            }
        }
        foreach ($entry in $entries.ToArray()) {
            if (@($entry['pending']).Count -gt 0 -and $entry['expiresUtc'] -le $NowUtc) {
                $expired.Add([ordered]@{ sessionId = [string]$entry['sessionId']; kind = 'documents'; pending = @($entry['pending']); leftVms = @(); untilUtc = $entry['expiresUtc'] })
                $entry['pending'] = @()
            }
            if (@($entry['leftVms']).Count -gt 0 -and $entry['heldUntilUtc'] -le $NowUtc) {
                $expired.Add([ordered]@{ sessionId = [string]$entry['sessionId']; kind = 'capture'; pending = @(); leftVms = @($entry['leftVms']); untilUtc = $entry['heldUntilUtc'] })
                $entry['leftVms'] = @()
            }
        }
    }
    foreach ($entry in $entries.ToArray()) {
        if (@($entry['pending']).Count -eq 0 -and @($entry['leftVms']).Count -eq 0 -and -not $entry['mustFetch']) {
            $null = $entries.Remove($entry)
        }
    }
    if (-not $KeepAll) {
        # At most 4 sessions and 6,000 bytes in a status, so its writes stay within a secret's size: the one whose evidence
        # the runner deletes first goes first; bundles in the vault don't expire.
        $last = {
            param([System.Collections.IDictionary] $Item)
            if ($Item['mustFetch']) {
                return [datetime]::MaxValue
            }
            $time = [datetime]::MinValue
            if (@($Item['pending']).Count -gt 0 -and $Item['expiresUtc'] -gt $time) {
                $time = $Item['expiresUtc']
            }
            if (@($Item['leftVms']).Count -gt 0 -and $Item['heldUntilUtc'] -gt $time) {
                $time = $Item['heldUntilUtc']
            }
            return $time
        }
        $size = {
            [System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject @(foreach ($item in $entries) { ConvertTo-DbHubRcaCarry -Entry $item }) -Depth 6 -Compress))
        }
        while ($entries.Count -gt 0 -and ($entries.Count -gt $script:DbHubRcaCarryMost -or (& $size) -gt $script:DbHubRcaCarryBytes)) {
            $first = $entries[0]
            foreach ($entry in $entries) {
                if ((& $last $entry) -lt (& $last $first)) {
                    $first = $entry
                }
            }
            $null = $entries.Remove($first)
            $dropped.Add($first)
        }
    }
    return [pscustomobject]@{ Entries = $entries.ToArray(); Expired = $expired.ToArray(); Dropped = $dropped.ToArray(); Inseparable = $inseparable.ToArray() }
}

function Get-DbHubRcaEarlier {
    # The first earlier session of Get-DbHubRcaBacklog's, from the status a session's start replaces, or $null when no earlier
    # session's evidence is waiting.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [AllowNull()]
        [System.Collections.IDictionary] $Previous,

        [Parameter(Mandatory = $true)]
        [string] $SessionId,

        [datetime] $NowUtc = (Get-DbHubUtcNow)
    )

    return (@((Get-DbHubRcaBacklog -Settings $Settings -Previous $Previous -SessionId $SessionId -NowUtc $NowUtc).Entries) | Select-Object -First 1)
}

function Get-DbHubRcaInseparableText {
    # An earlier session's capture on a VM that other activity reached before an export took it (reviews of 93243d6 and
    # 02d398a): the runner gives capture that no export took to the first export that takes it (Exporter.cs), whose session
    # keeps only what it captured itself, so that capture isn't in any history. -Item: sessionId, vm, with (the later
    # session, or '' when the VM ran before this session's start and its export with no session couldn't tell that capture
    # apart), and why.
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Item
    )

    $earlier = ([string]$Item['sessionId']).Substring(0, 8)
    if (-not [string]$Item['with']) {
        $how = [string]$Item['why']
        if (-not $how) {
            $how = 'an export with no session took it with any activity outside a Run all session there'
        }
        return ('Session {0}''s capture on {1} that no export took isn''t in any history now: {1} was running before this session''s start, and {2}.' -f $earlier, $Item['vm'], $how)
    }
    $why = ''
    if ([string]$Item['why']) {
        $why = ' ({0})' -f $Item['why']
    }
    $later = ([string]$Item['with']).Substring(0, 8)
    return ('Session {0}''s capture on {1} that no export took isn''t in any history now: session {2}''s activity ran there before it was exported{3}, so the runner gave it to {2}''s export, which keeps only what {2} captured.' -f $earlier, $Item['vm'], $later, $why)
}

function Get-DbHubRcaBoundText {
    # An earlier session's capture on a VM that this start's export there didn't take before this session's activity there,
    # where a document of that session's own had carried its ID (re-check of d2067d69): the runner keeps a span bound to the
    # session of the first export that took from it (Exporter.cs), so this session's next export there lists what's left of
    # it with that session's ID, for that session's entry (Add-DbHubRcaElsewhere), which a later start fetches. -Item:
    # sessionId, vm, why, and unread (that export may have listed it, but wasn't read, and the runner lists a document only
    # once).
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Item
    )

    $earlier = ([string]$Item['sessionId']).Substring(0, 8)
    if ($Item['unread']) {
        return ('Session {0}''s capture on {1} that no export took may not be in any history: this start''s export there may have listed what was left of it, but wasn''t read ({2}), and the runner lists a document only once.' -f $earlier, $Item['vm'], $Item['why'])
    }
    return ('Session {0}''s capture on {1} wasn''t exported before this session''s activity there ({2}), but it''s still {0}''s: an export of {0}''s had already taken from it, so this session''s next export there lists the rest with {0}''s ID, and a later start saves it with {0}''s history.' -f $earlier, $Item['vm'], $Item['why'])
}

function Set-DbHubRcaBacklog {
    <#
    .SYNOPSIS
    A session's start (review of 3b1348a, 93243d6): the earlier sessions whose evidence is still on the VMs
    (Get-DbHubRcaBacklog) go into its status as rcaEarlierPending before its first write, so the next start still has them
    whatever happens to this one (refused, failed, or cut off); every later write of the status keeps them. An RCA.EARLIER
    Warning says what's no longer asked for: past the runner's 7 or 30 days, past what a status keeps, or capture that a
    later session's activity reached before an export took it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets members of an in-memory status only.')]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [Parameter(Mandatory = $true)]
        [object] $Backlog
    )

    $carried = @(@($Backlog.Entries) | ForEach-Object { ConvertTo-DbHubRcaCarry -Entry $_ } | Where-Object { $null -ne $_ })
    if ($carried.Count -gt 0) {
        $Status['rcaEarlierPending'] = $carried
    }
    $lost = 'Nothing brings it back. A session that ends with its auto-stop or Stop now exports its evidence before the VMs stop; the nightly stop and the VMs'' auto-shutdown leave it on the VMs for the next session''s start.'
    $time = { param([datetime] $Utc) $Utc.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
    foreach ($part in @($Backlog.Expired)) {
        $short = ([string]$part['sessionId']).Substring(0, 8)
        if ([string]$part['kind'] -eq 'documents') {
            $message = 'Session {0}''s {1} aren''t asked for any more, so they aren''t in its history: the runner deletes an exported document 7 days after its export, which for these was by {2} UTC.' -f $short, (Get-DbHubRcaPendingText -Pending @($part['pending'])), (& $time $part['untilUtc'])
        }
        else {
            $message = 'Session {0}''s capture on {1} that no export took isn''t asked for any more, so it isn''t in its history: the runner deletes capture that no export took 30 days after it began, which for this was by {2} UTC.' -f $short, (@($part['leftVms']) -join ' and '), (& $time $part['untilUtc'])
        }
        Add-DbHubSessionStep -Status $Status -Step 'RCA.EARLIER' -State 'Warning' -Message $message -Fix $lost
    }
    foreach ($entry in @($Backlog.Dropped)) {
        $what = New-Object -TypeName 'System.Collections.Generic.List[string]'
        if (@($entry['pending']).Count -gt 0) {
            $what.Add((Get-DbHubRcaPendingText -Pending @($entry['pending'])))
        }
        if (@($entry['leftVms']).Count -gt 0) {
            $what.Add(('capture on {0} that no export took' -f (@($entry['leftVms']) -join ' and ')))
        }
        if ($what.Count -eq 0) {
            $what.Add('its bundles')
        }
        Add-DbHubSessionStep -Status $Status -Step 'RCA.EARLIER' -State 'Warning' -Message ('Session {0}''s evidence still on the VMs ({1}) isn''t asked for any more, so it isn''t in its history: a session''s status keeps at most {2} earlier sessions'' evidence, and it was the first to expire.' -f ([string]$entry['sessionId']).Substring(0, 8), ($what -join ', and '), $script:DbHubRcaCarryMost) -Fix $lost
    }
    foreach ($item in @($Backlog.Inseparable)) {
        Add-DbHubSessionStep -Status $Status -Step 'RCA.EARLIER' -State 'Warning' -Message (Get-DbHubRcaInseparableText -Item $item) -Fix $script:DbHubRcaApartFix
    }
}

function Send-DbHubRcaEarlierExport {
    <#
    .SYNOPSIS
    At a session's start, on a VM that's about to get the session's activity (Start-DbHubActivityRun's OnVmReady): the
    final export of the earlier session that holds the VM's capture that no export took (Get-DbHubRcaBacklog's leftVms, one
    session at most per VM), with that session's ID, so the runner binds that capture to it before this session's activity
    starts there (review of 93243d6): an export gives capture that no export took to its own session (Exporter.cs). It goes
    out whichever session this start fetches. With -RanBefore (the VM ran before this start: review of 02d398a), an export
    with no session instead, whatever an earlier session held there: activity outside a Run all session (deploy.ps1,
    start-demo.ps1) could run there, so what the observer captured goes with no session, and no history takes it, except
    what falls within the activity of the earlier session that holds the VM, which is that session's (Invoke-DbHubRcaEarlier:
    the VM can still have run it, as after a Run all in the minutes between a session's end and its auto-stop); it isn't
    final, so it doesn't wait for a span that's still capturing. Only sends the Run Command (Invoke-DbHubRcaEarlier reads it
    after the start). Returns Name and SessionId ('' with -RanBefore), or $null.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Entry = @(),

        [switch] $RanBefore
    )

    $bounds = Get-DbHubRcaSetting -Settings $Context.Settings
    if (-not $bounds.Supported) {
        return $null
    }
    $session = ''
    if (-not $RanBefore) {
        $holder = @(@($Entry) | Where-Object { $null -ne $_ -and $VmName -in @($_['leftVms']) }) | Select-Object -First 1
        if ($null -eq $holder) {
            return $null
        }
        $session = [string]$holder['sessionId']
    }
    if ((Get-DbHubRcaRoom -Context $Context -VmName $VmName) -lt 2) {
        return $null
    }
    $name = '{0}rca-{1}-x-{2}' -f $Context.Settings.runCommandPrefix, $VmName, (Get-DbHubUtcNow).ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $request = [ordered]@{ command = 'export'; sessionId = $session; final = (-not $RanBefore); timeoutSeconds = $bounds.ExportSeconds }
    if (Send-DbHubRunCommand -Context $Context -VmName $VmName -Name $name -Script (Get-DbHubRcaScript -Settings $Context.Settings -Request $request) -TimeoutSeconds ($bounds.ExportSeconds + 120) -ConflictDelaySeconds 10) {
        return [pscustomobject]@{ Name = $name; SessionId = $session }
    }
    return $null
}

function Add-DbHubRcaElsewhere {
    <#
    .SYNOPSIS
    Documents an export found of another session than its own (review of 93243d6): the runner keeps a span bound to the
    session of the first export that took from it, so a later export lists what's left of it under that session's ID. They go
    to that session's entry in the status's rcaEarlierPending, as documents still to fetch, which a later start fetches with
    that session's ID, rather than being dropped; the runner keeps them 7 days from this export. Returns how many were added.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets a member of an in-memory status only.')]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Document = @(),

        [Parameter(Mandatory = $true)]
        [datetime] $NowUtc
    )

    $list = New-Object -TypeName 'System.Collections.Generic.List[object]'
    foreach ($item in @($Status['rcaEarlierPending'])) {
        if ($null -ne $item) {
            $list.Add((ConvertTo-DbHubDictionary -InputObject $item))
        }
    }
    $week = $NowUtc.AddDays($script:DbHubRcaCarryDays)
    # That session ended before this one began (review of 02d398a): nothing captured later is its.
    $began = ConvertTo-DbHubUtc -Value $Status['acceptedUtc']
    $added = 0
    foreach ($item in @($Document)) {
        if ($null -eq $item) {
            continue
        }
        $session = [string](Get-DbHubMember -InputObject $item -Name 'sessionId')
        $reference = ConvertTo-DbHubRcaPendingList -Item @($item)
        if ($session -cnotmatch '^[0-9a-f]{32}$' -or $session -eq [string]$Status['sessionId'] -or $reference.Count -eq 0) {
            continue
        }
        $carry = @($list | Where-Object { [string]$_['sessionId'] -eq $session }) | Select-Object -First 1
        if ($null -eq $carry) {
            $carry = [ordered]@{ sessionId = $session; pending = @(); leftVms = @() }
            $list.Add($carry)
        }
        if (@(@($carry['pending']) | Where-Object { [string](Get-DbHubMember -InputObject $_ -Name 'documentId') -eq [string]$reference[0]['documentId'] }).Count -gt 0) {
            continue
        }
        $carry['pending'] = @(@($carry['pending']) | Where-Object { $null -ne $_ }) + @($reference[0])
        $expires = ConvertTo-DbHubUtc -Value $carry['expiresUtc']
        if ($null -eq $expires -or $expires -lt $week) {
            $carry['expiresUtc'] = ConvertTo-DbHubTimeText -Value $week
        }
        $end = ConvertTo-DbHubUtc -Value $carry['endUtc']
        if ($null -ne $began -and ($null -eq $end -or $began -lt $end)) {
            $carry['endUtc'] = ConvertTo-DbHubTimeText -Value $began
        }
        $added++
    }
    if ($list.Count -gt 0) {
        $Status['rcaEarlierPending'] = $list.ToArray()
    }
    return $added
}

function Get-DbHubRcaHeldByEarlier {
    # The VMs whose capture that no export took an earlier session holds (a status's rcaEarlierPending, review of 93243d6): a
    # session's own exports skip them, so the runner never gives that capture to the wrong session.
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Status
    )

    if ($null -eq $Status) {
        return @()
    }
    return @(@($Status['rcaEarlierPending']) | Where-Object { $null -ne $_ } | ForEach-Object { @(Get-DbHubMember -InputObject $_ -Name 'leftVms') } | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
}

function Invoke-DbHubRcaEarlier {
    <#
    .SYNOPSIS
    After a session's start, the earlier sessions whose evidence is still on the VMs (Get-DbHubRcaBacklog), in two steps
    (review of 93243d6). Each export the start sent (Send-DbHubRcaEarlierExport: one per VM, with the ID of the session that
    held its capture) is read, also from a VM that stopped since, because the runner lists a document only once: what it
    lists is that session's. Then one session's documents are fetched and written as bundles (Invoke-DbHubRcaSessionExport):
    the one whose bundles no saved index lists yet, if any (the nightly stop or the VMs' auto-shutdown ended it), otherwise
    the one whose documents the runner deletes first. Their bundle index goes into the status's rcaEarlier, which the control
    notebook saves with that session's history, and what's left back into rcaEarlierPending, for later starts. A held VM that
    this session's activity reached before its holder's export ran has lost that capture: an RCA.EARLIER Warning says so,
    and no export is sent for it later under the wrong session, unless a document of the holder's own had carried its ID
    from that VM (boundVms, re-check of d2067d69): the runner keeps that capture bound to it, so this session's next export
    there lists what's left of it with the holder's ID, and an RCA.EARLIER Info line says so; when this start's export
    there may have listed it without being read (Unread), the Warning says it may not be in any history. RCA.EARLIER lines
    say what's still on the VMs and what
    happens to it. Capture from outside a session (review of 02d398a): the export a start sent with no session (a VM that
    ran before it) is read too, and what it listed goes with no session (an RCA.EXPORT Info line says how much), except
    what falls within the activity of the earlier session that holds that VM, when its status says when that activity
    ended, which goes with that session as its own export's would; a held VM there whose export wasn't read, or whose
    holder's end isn't known, has lost its capture the same way. What an earlier session's export lists from outside that
    session's activity (its startUtc to endUtc) isn't fetched. Never throws: on an error, the entries stay as the start
    wrote them.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Entry = @(),

        [AllowNull()]
        [System.Collections.IDictionary] $Sent,

        [AllowNull()]
        [System.Collections.IDictionary] $SentSession,

        [int] $PollSeconds = 10
    )

    $entries = @(@($Entry) | Where-Object { $null -ne $_ })
    if ($entries.Count -eq 0 -and ($null -eq $Sent -or $Sent.Count -eq 0)) {
        return
    }
    try {
        $settings = $Context.Settings
        $bounds = Get-DbHubRcaSetting -Settings $settings
        $now = Get-DbHubUtcNow
        $week = $now.AddDays($script:DbHubRcaCarryDays)
        $current = [string]$Status['sessionId']
        $time = { param([datetime] $Utc) '{0} UTC' -f $Utc.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
        $sentFor = @{}
        if ($null -ne $Sent) {
            foreach ($key in @($Sent.Keys)) {
                $owner = ''
                if ($null -ne $SentSession -and $SentSession.Contains($key)) {
                    $owner = [string]$SentSession[$key]
                }
                $sentFor[[string]$key] = $owner
            }
        }
        $sentVms = @($sentFor.Keys)
        # When each earlier session's activity began and ended (review of 02d398a): what an export lists under its ID from
        # outside that window is capture from outside it, which isn't fetched.
        $sessionWindow = @{}
        foreach ($item in $entries) {
            $sessionWindow[[string]$item['sessionId']] = [pscustomobject]@{ StartUtc = $item['startUtc']; EndUtc = $item['endUtc'] }
        }
        # The earlier session that holds each VM's capture that no export took, when it's known when its activity ended:
        # what an export with no session lists there from within that activity is its (a VM that still ran it at this
        # start, or that ran activity outside a Run all session since).
        $heldBy = @{}
        foreach ($item in $entries) {
            if ($item['endUtc'] -isnot [datetime]) {
                continue
            }
            foreach ($vm in @(@($item['leftVms']) | ForEach-Object { [string]$_ })) {
                if (-not $heldBy.ContainsKey($vm)) {
                    $heldBy[$vm] = [string]$item['sessionId']
                }
            }
        }
        $activity = Get-DbHubRcaActivityVm -Settings $settings -Status $Status
        if ($null -eq $activity) {
            $activity = @()
        }
        # The session whose documents this start fetches: the one whose bundles no saved index lists yet, otherwise the one
        # whose documents the runner deletes first, a holder whose export went out now counting as 7 days from now.
        $fetch = @($entries | Where-Object { $_['mustFetch'] }) | Select-Object -First 1
        if ($null -eq $fetch) {
            $best = [datetime]::MaxValue
            foreach ($item in $entries) {
                $key = [datetime]::MaxValue
                if (@($item['pending']).Count -gt 0) {
                    $key = $item['expiresUtc']
                }
                if (@($sentVms | Where-Object { $sentFor[$_] -eq [string]$item['sessionId'] -or (-not $sentFor[$_] -and $heldBy[$_] -eq [string]$item['sessionId']) }).Count -gt 0 -and $week -lt $key) {
                    $key = $week
                }
                if ($key -lt $best) {
                    $best = $key
                    $fetch = $item
                }
            }
        }
        $done = $null
        if ($null -ne $fetch -and $bounds.Supported) {
            $vms = @(@($sentVms) + @(@($fetch['pending']) | ForEach-Object { [string](Get-DbHubMember -InputObject $_ -Name 'vm') }) | Where-Object { $_ } | Select-Object -Unique)
            $fetchState = ConvertTo-DbHubRcaState -State $fetch['rca'] -SessionId ([string]$fetch['sessionId'])
            $fetchState['pending'] = @($fetch['pending'])
            $fetchState['leftVms'] = @($fetch['leftVms'])
            $done = Invoke-DbHubRcaSessionExport -Context $Context -SessionId ([string]$fetch['sessionId']) -Final -Minutes $bounds.StartMinutes -Earlier $fetchState -Sent $Sent -SentSession $SentSession -OnlyVm $vms -SessionWindow $sessionWindow -HeldBy $heldBy -NoNewExport -PollSeconds $PollSeconds
            if ($null -ne $done.Index) {
                $Status['rcaEarlier'] = $done.Index
            }
        }
        $hostResults = @()
        $listedOthers = @()
        if ($null -ne $done) {
            $hostResults = @($done.Hosts)
            $listedOthers = @($done.Others)
        }
        elseif ($sentVms.Count -gt 0 -and $bounds.Supported) {
            # Only exports with no session went out (VMs that ran before this start): they're read, and what they listed
            # goes with no session, or with the earlier session that holds the VM (review of 02d398a).
            $readOnly = Invoke-DbHubRcaExport -Context $Context -SessionId $current -DeadlineUtc ($now.AddMinutes($bounds.StartMinutes)) -Sent $Sent -SentSession $SentSession -OnlyVm $sentVms -SessionWindow $sessionWindow -HeldBy $heldBy -NoNewExport -PollSeconds $PollSeconds
            $hostResults = @($readOnly.Hosts)
            $listedOthers = @($readOnly.Others)
        }
        $read = @{}
        $unread = @{}
        $result = @{}
        $consumed = [ordered]@{}
        foreach ($hostResult in $hostResults) {
            $read[[string]$hostResult.Vm] = [bool](Get-DbHubMember -InputObject $hostResult -Name 'ExportRead')
            $unread[[string]$hostResult.Vm] = [bool](Get-DbHubMember -InputObject $hostResult -Name 'Unread')
            $result[[string]$hostResult.Vm] = [string]$hostResult.Outcome
            $count = [int](Get-DbHubMember -InputObject $hostResult -Name 'Consumed')
            if ($count -gt 0) {
                $consumed[[string]$hostResult.Vm] = $count
            }
        }
        # The fetched session's documents that this start decoded say where the runner bound its capture too.
        if ($null -ne $done) {
            $fetch['boundVms'] = @(@($fetch['boundVms']) + @($done.State['boundVms']) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
        }
        # Each held VM: exported now with its holder's ID (or with no session, on a VM that ran before this start, whose
        # documents from within the holder's activity are the holder's), reached by this session's activity first, or still
        # held. Reached first, the holder keeps what's left of its capture there when a document of its own had carried its
        # ID from there (boundVms, re-check of d2067d69): the runner keeps that span bound to it (Exporter.cs), so this
        # session's next export there lists the rest with its ID, for its entry (Add-DbHubRcaElsewhere), unless this start's
        # export there may have listed it without being read (Unread): the runner lists a document only once.
        $apart = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $rest = New-Object -TypeName 'System.Collections.Generic.List[object]'
        $exported = [ordered]@{}
        $timed = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
        foreach ($item in $entries) {
            $session = [string]$item['sessionId']
            $kept = New-Object -TypeName 'System.Collections.Generic.List[string]'
            foreach ($vm in @(@($item['leftVms']) | ForEach-Object { [string]$_ })) {
                $sentHere = $sentFor.ContainsKey($vm) -and ($sentFor[$vm] -eq $session -or (-not $sentFor[$vm] -and $heldBy[$vm] -eq $session))
                if ($sentHere -and $read.ContainsKey($vm) -and $read[$vm]) {
                    if (-not $exported.Contains($session)) {
                        $exported[$session] = New-Object -TypeName 'System.Collections.Generic.List[string]'
                    }
                    $exported[$session].Add($vm)
                    if (-not $sentFor[$vm]) {
                        $null = $timed.Add($vm)
                    }
                    continue
                }
                $bound = $vm -in @($item['boundVms'])
                # A sent export that wasn't read may have listed the capture; one that has no result here wasn't read either.
                $lostRead = ($unread.ContainsKey($vm) -and $unread[$vm]) -or ($sentFor.ContainsKey($vm) -and -not $result.ContainsKey($vm))
                if ($sentFor.ContainsKey($vm) -and -not $sentFor[$vm]) {
                    if ($read.ContainsKey($vm) -and $read[$vm]) {
                        # The VM ran before this start (review of 02d398a), and its export with no session was read, but this
                        # holder's status doesn't say when its activity ended: that export took its capture with any
                        # activity outside a Run all session there, and nothing told them apart.
                        $apart.Add([ordered]@{ sessionId = $session; vm = $vm; with = ''; why = ('session {0}''s status doesn''t say when its activity ended, so the export with no session that this start sent there couldn''t tell that capture from any activity outside a Run all session' -f $session.Substring(0, 8)) })
                        continue
                    }
                    $how = switch ([string]$result[$vm]) {
                        'TimedOut' { 'it didn''t end in time' }
                        'Failed' { 'it failed' }
                        'NotRunning' { 'the VM stopped before it ended' }
                        'OldBundle' { 'the VM''s bootstrap bundle predates the RCA export' }
                        'OldRunner' { 'the VM''s runner predates the RCA export' }
                        default { 'it wasn''t read in time' }
                    }
                    if ($bound) {
                        $whyBound = $how
                        if (-not $lostRead) {
                            $whyBound = switch ([string]$result[$vm]) {
                                'OldBundle' { 'this start''s export there found a bootstrap bundle that predates the RCA export' }
                                'OldRunner' { 'this start''s export there found a runner that predates the RCA export' }
                                default { 'this start''s export there failed' }
                            }
                        }
                        $rest.Add([ordered]@{ sessionId = $session; vm = $vm; unread = $lostRead; why = $whyBound })
                        continue
                    }
                    $apart.Add([ordered]@{ sessionId = $session; vm = $vm; with = ''; why = ('the export with no session that this start sent there, to tell that capture from any activity outside a Run all session, wasn''t read ({0})' -f $how) })
                    continue
                }
                if ($vm -in $activity) {
                    $outcome = ''
                    if ($result.ContainsKey($vm)) {
                        $outcome = $result[$vm]
                    }
                    $why = switch ($outcome) {
                        'TimedOut' { 'its export didn''t end in time' }
                        'Failed' { 'its export failed' }
                        'NotRunning' { 'the VM stopped before its export ran' }
                        'NoRoom' { 'no room for another managed Run Command there' }
                        'OldBundle' { 'the VM''s bootstrap bundle predates the RCA export' }
                        'OldRunner' { 'the VM''s runner predates the RCA export' }
                        default { 'its export didn''t run there' }
                    }
                    if (-not $sentHere) {
                        $why = 'no room for another managed Run Command there, or Azure refused its export'
                    }
                    if ($bound) {
                        $rest.Add([ordered]@{ sessionId = $session; vm = $vm; unread = $lostRead; why = $why })
                        continue
                    }
                    $apart.Add([ordered]@{ sessionId = $session; vm = $vm; with = $current; why = $why })
                    continue
                }
                $kept.Add($vm)
            }
            $item['leftVms'] = $kept.ToArray()
        }
        # The fetched session: its documents not fetched whole, those this start's export listed kept 7 days from now.
        if ($null -ne $done) {
            $before = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
            foreach ($reference in @($fetch['pending'])) {
                $null = $before.Add([string](Get-DbHubMember -InputObject $reference -Name 'documentId'))
            }
            $fetch['pending'] = ConvertTo-DbHubRcaPendingList -Item @($done.State['pending'])
            if (@($fetch['pending'] | Where-Object { -not $before.Contains([string]$_['documentId']) }).Count -gt 0 -and $fetch['expiresUtc'] -lt $week) {
                $fetch['expiresUtc'] = $week
            }
            $fetch['mustFetch'] = $false
            $fetch['rca'] = ConvertTo-DbHubRcaState -State $null -SessionId ([string]$fetch['sessionId'])
        }
        # What the exports listed for another session, and documents of another session found in a fetched one: that
        # session's, kept 7 days from now (review of 93243d6).
        $listedFor = @{}
        foreach ($document in $listedOthers) {
            $session = [string](Get-DbHubMember -InputObject $document -Name 'sessionId')
            $reference = ConvertTo-DbHubRcaPendingList -Item @($document)
            if ($session -cnotmatch '^[0-9a-f]{32}$' -or $session -eq $current -or $reference.Count -eq 0) {
                continue
            }
            $target = @($entries | Where-Object { [string]$_['sessionId'] -eq $session }) | Select-Object -First 1
            if ($null -eq $target) {
                $target = [ordered]@{ sessionId = $session; pending = @(); leftVms = @(); expiresUtc = $week; heldUntilUtc = $now.AddDays($script:DbHubRcaCapturedDays); rca = (ConvertTo-DbHubRcaState -State $null -SessionId $session); previous = $false; known = $true; mustFetch = $false }
                $entries += $target
            }
            $target['pending'] = ConvertTo-DbHubRcaPendingList -Item (@($target['pending']) + $reference)
            if (-not ($target['expiresUtc'] -is [datetime]) -or $target['expiresUtc'] -lt $week) {
                $target['expiresUtc'] = $week
            }
            if (-not $listedFor.ContainsKey($session)) {
                $listedFor[$session] = 0
            }
            $listedFor[$session]++
        }
        # The queue for later starts: bundles no saved index lists first, then documents in the order the runner deletes
        # them, then capture only held.
        $remaining = @($entries | Where-Object { @($_['pending']).Count -gt 0 -or @($_['leftVms']).Count -gt 0 -or $_['mustFetch'] })
        $order = @($remaining | Where-Object { @($_['pending']).Count -gt 0 -and -not $_['mustFetch'] } | Sort-Object -Property { $_['expiresUtc'] })
        $queued = @(@($remaining | Where-Object { $_['mustFetch'] }) + $order + @($remaining | Where-Object { @($_['pending']).Count -eq 0 -and -not $_['mustFetch'] }))
        $carried = @($queued | ForEach-Object { ConvertTo-DbHubRcaCarry -Entry $_ } | Where-Object { $null -ne $_ })
        if ($carried.Count -gt 0) {
            $Status['rcaEarlierPending'] = $carried
        }
        elseif ($Status.Contains('rcaEarlierPending')) {
            $Status.Remove('rcaEarlierPending')
        }
        # The lines, each within a step's 400 characters.
        if ($null -ne $done) {
            $first = @($done.Lines) | Select-Object -First 1
            $level = 'Info'
            if ($first.Status -in 'Warning', 'Fail') {
                $level = 'Warning'
            }
            $message = 'The evidence that session {0}''s stop didn''t export: {1}' -f ([string]$fetch['sessionId']).Substring(0, 8), $first.Message
            if ($null -ne $done.Index) {
                $message = '{0} Run all saves it with that session''s history at this session''s end.' -f $message
            }
            Add-DbHubSessionStep -Status $Status -Step 'RCA.EXPORT' -State $level -Message $message -Fix ([string]$first.Fix)
        }
        elseif ($null -ne $fetch) {
            Add-DbHubSessionStep -Status $Status -Step 'RCA.EXPORT' -State 'Warning' -Message ('The evidence that session {0}''s stop didn''t export wasn''t exported at this start: the control''s runbook settings predate the RCA export (ADR 0031).' -f ([string]$fetch['sessionId']).Substring(0, 8)) -Fix 'Run ./scripts/deploy.ps1.'
        }
        foreach ($session in @($exported.Keys)) {
            if ($null -ne $fetch -and $session -eq [string]$fetch['sessionId']) {
                continue
            }
            $count = 0
            if ($listedFor.ContainsKey($session)) {
                $count = $listedFor[$session]
            }
            $message = 'Session {0}''s capture on {1} that no export had taken was exported with its own ID before this session''s activity there: {2} document(s).'
            if (@($exported[$session] | Where-Object { $timed.Contains($_) }).Count -gt 0) {
                $message = 'Session {0}''s capture on {1} that no export had taken was exported before this session''s activity there, with no session because the VM ran before this start; the documents from within its activity are its: {2} document(s).'
            }
            Add-DbHubSessionStep -Status $Status -Step 'RCA.EARLIER' -State 'Info' -Message ($message -f $session.Substring(0, 8), (@($exported[$session]) -join ' and '), $count)
        }
        foreach ($item in $apart) {
            $apartFix = $script:DbHubRcaApartFix
            if (-not [string]$item['with']) {
                $apartFix = $script:DbHubRcaOutsideFix
            }
            Add-DbHubSessionStep -Status $Status -Step 'RCA.EARLIER' -State 'Warning' -Message (Get-DbHubRcaInseparableText -Item $item) -Fix $apartFix
        }
        foreach ($item in $rest) {
            if ($item['unread']) {
                Add-DbHubSessionStep -Status $Status -Step 'RCA.EARLIER' -State 'Warning' -Message (Get-DbHubRcaBoundText -Item $item) -Fix $script:DbHubRcaApartFix
            }
            else {
                Add-DbHubSessionStep -Status $Status -Step 'RCA.EARLIER' -State 'Info' -Message (Get-DbHubRcaBoundText -Item $item)
            }
        }
        foreach ($vm in @($consumed.Keys)) {
            Add-DbHubSessionStep -Status $Status -Step 'RCA.EXPORT' -State 'Info' -Message ('{0} ran before this session''s start, so an export with no session took what the observer captured there outside a Run all session: {1} document(s), which no history takes.' -f $vm, $consumed[$vm])
        }
        $unsaved = @($remaining | Where-Object { $_['mustFetch'] }).Count
        foreach ($item in $queued) {
            $short = ([string]$item['sessionId']).Substring(0, 8)
            if (@($item['pending']).Count -gt 0) {
                $position = [array]::IndexOf($order, $item) + $unsaved
                $turn = 'which the next session''s start fetches, or the start after it when this session ends without its stop''s export'
                if ($item['mustFetch']) {
                    $turn = 'which a later session''s start fetches with its bundles'
                }
                elseif ($position -gt 0) {
                    $turn = 'which a later session''s start fetches, after the {0} earlier session(s) ahead of it (one session''s per start)' -f $position
                }
                Add-DbHubSessionStep -Status $Status -Step 'RCA.EARLIER' -State 'Info' -Message ('Session {0}''s evidence still on the VMs: {1}, {2}, until {3}, when the runner deletes them.' -f $short, (Get-DbHubRcaPendingText -Pending @($item['pending'])), $turn, (& $time $item['expiresUtc']))
            }
            if (@($item['leftVms']).Count -gt 0) {
                Add-DbHubSessionStep -Status $Status -Step 'RCA.EARLIER' -State 'Info' -Message ('Session {0}''s evidence still on the VMs: what the observer captured on {1} that no export took, which the next start that sends activity there exports first, with session {0}''s ID, until {2}, when the runner deletes it.' -f $short, (@($item['leftVms']) -join ' and '), (& $time $item['heldUntilUtc']))
            }
            if ($item['mustFetch'] -and @($item['pending']).Count -eq 0 -and @($item['leftVms']).Count -eq 0) {
                Add-DbHubSessionStep -Status $Status -Step 'RCA.EARLIER' -State 'Info' -Message ('Session {0}''s evidence: its bundles in the control vault, which no saved index lists yet; a later session''s start lists them in its index, which Run all saves with session {0}''s history.' -f $short)
            }
        }
    }
    catch {
        Write-DbHubLog -Context $Context -Message ('The earlier sessions'' evidence wasn''t exported: {0}' -f $_.Exception.Message)
    }
}

function Set-DbHubStopBegun {
    <#
    .SYNOPSIS
    A session's stop has begun (review of 15ad76d): stopBegunUtc in its status's copy, which DbHub-Monitor's re-check reads
    before each evidence bundle it writes (Test-DbHubRcaRecheckOpen), so none goes after the stop's final version of the
    metrics. Only the copy, and only while it's that session's and it hasn't stopped: the vault's status is the notebook's,
    and the stop's own status replaces both at its end (Write-DbHubStopStatus). Its updatedUtc changes too, so a re-check
    that read the copy before doesn't write over it. Returns whether it was marked. Never throws.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Marks only the session''s own status copy; Stop-DbHubDemo, its caller, asks ShouldProcess.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowEmptyString()]
        [string] $SessionId = ''
    )

    if ($SessionId -notmatch '^[0-9a-f]{32}$') {
        return $false
    }
    try {
        $copy = Read-DbHubSessionStatusCopy -Context $Context
        if ($null -eq $copy -or [string]$copy['sessionId'] -ne $SessionId -or [string]$copy['phase'] -eq 'stopped') {
            return $false
        }
        $now = ConvertTo-DbHubTimeText -Value (Get-DbHubUtcNow)
        $copy['stopBegunUtc'] = $now
        $copy['updatedUtc'] = $now
        return (Save-DbHubSessionStatusCopy -Context $Context -Json (ConvertTo-Json -InputObject $copy -Depth 8 -Compress))
    }
    catch {
        Write-DbHubLog -Context $Context -Message ('The session''s stop wasn''t marked in its status''s copy: {0}' -f $_.Exception.Message)
        return $false
    }
}

$script:DbHubStopBegunMinutes = 15

function Test-DbHubRcaRecheckOpen {
    # Whether DbHub-Monitor's re-check may still write the session's evidence (review of 15ad76d): its status's copy is the
    # session's, it runs, and its stop hasn't begun (Set-DbHubStopBegun). A stop's mark lasts 15 minutes, or its export's
    # bound (rca.stopMinutes) and 9 more when that's longer (review of 3b1348a): by then the stop has written the metrics'
    # final version and deallocated the VMs, or it failed without a stopped status, and the session's re-checks go on.
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Status,

        [Parameter(Mandatory = $true)]
        [string] $SessionId,

        [int] $StopMinutes = 6
    )

    if ($null -eq $Status -or [string]$Status['sessionId'] -ne $SessionId -or [string]$Status['phase'] -ne 'running') {
        return $false
    }
    if (-not $Status.Contains('stopBegunUtc')) {
        return $true
    }
    $begun = ConvertTo-DbHubUtc -Value $Status['stopBegunUtc']
    $lasts = [System.Math]::Max($script:DbHubStopBegunMinutes, $StopMinutes + 9)
    return ($null -eq $begun -or (Get-DbHubUtcNow) -ge $begun.AddMinutes($lasts))
}

function Add-DbHubRcaHandoff {
    <#
    .SYNOPSIS
    A re-check whose session's stop began while it exported (review of 15ad76d): the documents it found (Fresh) go to the
    stop as documents still to export, because the metrics' final version lists only the stop's bundles, and the runner
    keeps a document 7 days after its export. Once the session has stopped, into its status's rca pending (vault and copy),
    which the next session's start exports (Get-DbHubRcaEarlier); while its stop runs, into the copy's rcaHandoff, which
    Write-DbHubStopStatus takes. Another session's documents it found (-Elsewhere, review of 93243d6) go to that session's
    entry in rcaEarlierPending (Add-DbHubRcaElsewhere), which the stop keeps. Returns how many of the session's own it
    handed over. Never throws.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes only the session''s own status, from DbHub-Monitor''s scheduled re-check, which starts or stops nothing.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [Parameter(Mandatory = $true)]
        [string] $SessionId,

        [AllowEmptyCollection()]
        [object[]] $Document = @(),

        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]] $Elsewhere = @()
    )

    try {
        $state = ConvertTo-DbHubRcaState -State $Status['rca'] -SessionId $SessionId
        $known = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
        foreach ($item in @(@($state['documents']) + @($state['pending']) + @(@($Status['rcaHandoff']) | Where-Object { $null -ne $_ }))) {
            $null = $known.Add([string](Get-DbHubMember -InputObject $item -Name 'documentId'))
        }
        $added = New-Object -TypeName 'System.Collections.Generic.List[object]'
        foreach ($item in @($Document | Where-Object { $null -ne $_ })) {
            $id = [string](Get-DbHubMember -InputObject $item -Name 'documentId')
            $vm = [string](Get-DbHubMember -InputObject $item -Name 'vm')
            if ($id -and $vm -and $known.Add($id)) {
                $added.Add([ordered]@{ documentId = $id; parts = [int](Get-DbHubMember -InputObject $item -Name 'parts'); sha256 = [string](Get-DbHubMember -InputObject $item -Name 'sha256'); vm = $vm })
            }
        }
        $routed = Add-DbHubRcaElsewhere -Status $Status -Document @($Elsewhere) -NowUtc (Get-DbHubUtcNow)
        if ($added.Count -eq 0 -and $routed -eq 0) {
            return 0
        }
        if ([string]$Status['phase'] -eq 'stopped') {
            # Its copy is what the next session's start reads (Get-DbHubRcaEarlier); the vault's keeps the notebook's view.
            if ($added.Count -gt 0) {
                $state['pending'] = @(@($state['pending']) + $added.ToArray())
                $state['final'] = $false
                $Status['rca'] = $state
                # The stop's RCA.PENDING line takes them too (finding 4 of the live check of 4e2c65ed).
                $lines = @(Get-DbHubRcaStopLineList -Settings $Context.Settings -Status $Status -NowUtc (Get-DbHubUtcNow))
                if ($lines.Count -gt 0) {
                    $Status['rcaLines'] = $lines
                }
            }
            $null = Write-DbHubSessionStatus -Context $Context -Status $Status
            return $added.Count
        }
        if ($added.Count -gt 0) {
            $Status['rcaHandoff'] = @(@(@($Status['rcaHandoff']) | Where-Object { $null -ne $_ }) + $added.ToArray())
        }
        $Status['updatedUtc'] = ConvertTo-DbHubTimeText -Value (Get-DbHubUtcNow)
        if (-not (Save-DbHubSessionStatusCopy -Context $Context -Json (ConvertTo-Json -InputObject $Status -Depth 8 -Compress))) {
            return 0
        }
        return $added.Count
    }
    catch {
        Write-DbHubLog -Context $Context -Message ('A re-check''s evidence wasn''t handed to the session''s stop: {0}' -f $_.Exception.Message)
        return 0
    }
}

function Update-DbHubSessionRca {
    <#
    .SYNOPSIS
    DbHub-Monitor's export at each 30-minute re-check while a session runs (ADR 0031): what the observer captured since the
    last export goes into the control vault now, so a session's end has only its last half hour left to export. The state
    (Invoke-DbHubRcaSessionExport) goes into the session's status with its RCA.EXPORT and RCA.CAPTURE.<target> steps (only
    the ones it doesn't have yet), written only while its copy is still the one read, as Update-DbHubSessionHealth does; when
    another job wrote it meanwhile, the state goes into that newer copy, while the session still runs. Once the session's
    stop has begun (Set-DbHubStopBegun), it writes no more bundles, and what it found goes to that stop
    (Add-DbHubRcaHandoff), so the next session's start exports it (review of 15ad76d). Never throws. Returns
    Outcome (NoSession, NotSupported, Late, Exported, Nothing, Changed, Failed) and Note.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes only the running session''s own status and evidence, from DbHub-Monitor''s scheduled re-check, which starts or stops nothing.')]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [int] $PollSeconds = 10
    )

    $session = [string](Get-DbHubMember -InputObject $Tags -Name 'DbHubSessionId')
    if ($session -notmatch '^[0-9a-f]{32}$') {
        return [pscustomobject]@{ Outcome = 'NoSession'; Note = '' }
    }
    try {
        $bounds = Get-DbHubRcaSetting -Settings $Context.Settings
        if (-not $bounds.Supported) {
            return [pscustomobject]@{ Outcome = 'NotSupported'; Note = '' }
        }
        $status = Read-DbHubSessionStatusCopy -Context $Context
        if (-not (Test-DbHubRcaRecheckOpen -Status $status -SessionId $session -StopMinutes $bounds.StopMinutes)) {
            return [pscustomobject]@{ Outcome = 'NoSession'; Note = '' }
        }
        # The session's own stop exports its last minutes; a re-check this close to the end leaves them to it.
        $end = ConvertTo-DbHubUtc -Value $status['runEndUtc']
        if ($null -ne $end -and (Get-DbHubUtcNow) -ge $end.AddMinutes(-10)) {
            return [pscustomobject]@{ Outcome = 'Late'; Note = '' }
        }
        $readUpdated = [string]$status['updatedUtc']
        $before = ConvertTo-DbHubRcaState -State $status['rca'] -SessionId $session
        # No bundle once the session's stop has begun (review of 15ad76d): its final version of the metrics, which the
        # notebook reads by its ID, lists only the bundles written before it. No export on a VM that an earlier session
        # holds (review of 93243d6): it would take that session's capture. Nothing captured before the session began
        # (review of 02d398a): its start, and when the session before it ended.
        $done = Invoke-DbHubRcaSessionExport -Context $Context -SessionId $session -Minutes $bounds.RecheckMinutes -Earlier $status['rca'] -SkipVm (Get-DbHubRcaHeldByEarlier -Status $status) -OutsideFromUtc (ConvertTo-DbHubUtc -Value $status['rcaPreviousEndUtc']) -OutsideToUtc (ConvertTo-DbHubUtc -Value $status['acceptedUtc']) -PollSeconds $PollSeconds -WhileRunning
        $write = $status
        $again = Read-DbHubSessionStatusCopy -Context $Context
        if (-not (Test-DbHubRcaRecheckOpen -Status $again -SessionId $session -StopMinutes $bounds.StopMinutes)) {
            # The session's stop began, or it ended: what this re-check found goes to that stop, for the next export.
            $handed = 0
            if ($null -ne $again -and [string]$again['sessionId'] -eq $session) {
                $handed = Add-DbHubRcaHandoff -Context $Context -Status $again -SessionId $session -Document @($done.Fresh) -Elsewhere @($done.Others)
            }
            $found = @($done.Fresh).Count
            if ($found -gt 0 -and $handed -eq $found) {
                Write-DbHubLog -Context $Context -Message ('The session''s stop began while its evidence was exported, so this re-check''s {0} document(s) go to the next session''s start, which exports them again; the runner keeps them for 7 days.' -f $found)
            }
            elseif ($found -gt 0) {
                Write-DbHubLog -Context $Context -Message ('The session ended while its evidence was exported, and {0} of this re-check''s {1} document(s) couldn''t be handed to its stop, so they aren''t in its history; the runner keeps them on the VMs for 7 days.' -f ($found - $handed), $found)
            }
            return [pscustomobject]@{ Outcome = 'Changed'; Note = '' }
        }
        if ([string]$again['updatedUtc'] -ne $readUpdated) {
            $write = $again
        }
        $changed = @($done.State['bundles']).Count -ne @($before['bundles']).Count -or @($done.State['pending']).Count -ne @($before['pending']).Count
        $write['rca'] = $done.State
        # Another session's documents this export found go to that session's entry, for a later start (review of 93243d6).
        if ((Add-DbHubRcaElsewhere -Status $write -Document @($done.Others) -NowUtc (Get-DbHubUtcNow)) -gt 0) {
            $changed = $true
        }
        $known = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
        foreach ($step in @($write['steps'])) {
            $null = $known.Add(('{0}|{1}' -f [string](Get-DbHubMember -InputObject $step -Name 'step'), [string](Get-DbHubMember -InputObject $step -Name 'message')))
        }
        foreach ($line in @($done.Lines)) {
            # A re-check that found nothing new says nothing.
            if ($line.Status -eq 'Not selected' -or ($line.Step -eq 'RCA.EXPORT' -and $line.Status -eq 'Pass' -and $done.New -eq 0)) {
                continue
            }
            $state = 'Pass'
            if ($line.Status -in 'Warning', 'Fail') {
                $state = 'Warning'
            }
            if ($known.Add(('{0}|{1}' -f $line.Step, (ConvertTo-DbHubSafeText -Text $line.Message)))) {
                Add-DbHubSessionStep -Status $write -Step $line.Step -State $state -Message $line.Message -Fix $line.Fix
                $changed = $true
            }
        }
        $outcome = 'Nothing'
        if (@($done.State['bundles']).Count -gt @($before['bundles']).Count) {
            $outcome = 'Exported'
        }
        if (-not $changed) {
            return [pscustomobject]@{ Outcome = $outcome; Note = '' }
        }
        $null = Write-DbHubSessionStatus -Context $Context -Status $write
        return [pscustomobject]@{ Outcome = $outcome; Note = (' The session''s evidence: {0}' -f [string]$done.State['message']) }
    }
    catch {
        Write-DbHubLog -Context $Context -Message ('The session''s evidence wasn''t exported at this re-check: {0}' -f $_.Exception.Message)
        return [pscustomobject]@{ Outcome = 'Failed'; Note = '' }
    }
}

function Get-DbHubRcaResult {
    # The RCA part of a stop's result line (the job's output): the export's status and message, or $null when it didn't run.
    param(
        [AllowNull()]
        [object] $Rca
    )

    if ($null -eq $Rca) {
        return $null
    }
    return [ordered]@{ status = [string]$Rca.State['status']; message = [string]$Rca.State['message']; bundles = @($Rca.State['bundles']).Count; documents = @($Rca.State['documents']).Count; final = [bool]$Rca.State['final'] }
}

function Invoke-DbHubRcaStop {
    <#
    .SYNOPSIS
    A session's stop (Stop now, or the auto-stop): its final export before the VMs deallocate (ADR 0031), with its earlier
    bundles and pending documents from its status's copy. Returns State, Index, and Lines (Invoke-DbHubRcaSessionExport),
    or $null without a session or with settings that predate the export. Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [AllowEmptyString()]
        [string] $SessionId = '',

        [int] $PollSeconds = 10
    )

    $session = $SessionId
    if (-not $session) {
        $session = [string](Get-DbHubMember -InputObject $Tags -Name 'DbHubSessionId')
    }
    if ($session -notmatch '^[0-9a-f]{32}$') {
        return $null
    }
    try {
        $bounds = Get-DbHubRcaSetting -Settings $Context.Settings
        $earlier = $null
        $skip = @()
        $from = $null
        $to = $null
        $hostAfter = $null
        $copy = Read-DbHubSessionStatusCopy -Context $Context
        if ($null -ne $copy -and [string]$copy['sessionId'] -eq $session) {
            $earlier = Get-DbHubMember -InputObject $copy -Name 'rca'
            # A VM an earlier session holds gets no export (review of 93243d6): it would give that session's capture to this one.
            $skip = @(Get-DbHubRcaHeldByEarlier -Status $copy)
            # Nothing captured before the session began (review of 02d398a).
            $from = ConvertTo-DbHubUtc -Value $copy['rcaPreviousEndUtc']
            $to = ConvertTo-DbHubUtc -Value $copy['acceptedUtc']
            # The T2 host from 60 s after the stop's mark (review of 242a3ef7): a re-check that read the mark open just before
            # it can still send there, after its three PUTs and Send-DbHubRunCommand's two conflict waits.
            $begun = ConvertTo-DbHubUtc -Value $copy['stopBegunUtc']
            if ($begun -is [datetime]) {
                $hostAfter = $begun.AddSeconds($script:DbHubRcaStopHostDelaySeconds)
            }
        }
        return (Invoke-DbHubRcaSessionExport -Context $Context -SessionId $session -Final -Minutes $bounds.StopMinutes -Earlier $earlier -SkipVm $skip -OutsideFromUtc $from -OutsideToUtc $to -PollSeconds $PollSeconds -HostNotBeforeUtc $hostAfter)
    }
    catch {
        Write-DbHubLog -Context $Context -Message ('The session''s evidence wasn''t exported at its stop: {0}' -f $_.Exception.Message)
        $state = ConvertTo-DbHubRcaState -State $null -SessionId $session
        $state['status'] = 'Warning'
        $state['message'] = 'The evidence export failed: {0}' -f (ConvertTo-DbHubSafeText -Text $_.Exception.Message)
        return [pscustomobject]@{ State = $state; Index = $null; Lines = @([pscustomobject]@{ Step = 'RCA.EXPORT'; Status = 'Warning'; Message = $state['message']; Fix = 'What wasn''t exported stays on the VMs, and a later session''s start exports it before its own activity there (RCA.EARLIER).' }) }
    }
}

function Start-DbHubSession {
    <#
    .SYNOPSIS
    The session action (ADR 0026, 2026-11-14), the control notebook's one Run all: the whole demo session, with its
    progress in the control vault for the notebook. Returns the job's result.

    .DESCRIPTION
    1. Refused while a run is active (Get-DbHubActiveRun), with the reason in the status.
    2. The plan (Get-DbHubRunPlan): the showcase on every target for the session's minutes, ending before the VMs' next
       auto-shutdown, as a run does: the profile hosts on the VMs end their activity there. A shorter session than asked
       ends after its last whole showcase cycle (cycleMinutes), so no beat is cut off, and says so, with when it ends and
       why; one with less than minSessionMinutes left is refused.
    3. The busy marker (DbHubBusyUntilUtc, DbHubBusyBy session) until busyMarginMinutes after the auto-stop, with the
       session's ID and start (DbHubSessionId, DbHubSessionStartUtc): the nightly stop's passes and the control's T4 stop
       leave the session to its own auto-stop, which saves the metrics and deletes the replica.
    4. The run (Start-DbHubActivityRun) with this plan: the auto-stop and its second, then the starts and the dispatches.
       Once T4 is Ready, its read replica is asked for (Start-DbHubSessionReplica), and after the dispatches the job waits
       for it (Complete-DbHubSessionReplica).
    5. The replica-lag beat's windows from when T4's profile was set (Get-DbHubReplicaLagPlan), or why it won't run.
    6. T5's showcase (2026-11-18, ADR 0027): its activity goes out with sqlvm01's, once its container is there (2026-11-19:
       it exists only during a session, so the run creates it while the VMs start, and a T5 step says so, or why T5 sits
       the session out), and it runs the whole session; a T5 step says when T5 is back at its baseline after its last
       ru-storm (risk R896).
    The job ends with the session going on; its auto-stop ends it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [object] $Request,

        [AllowNull()]
        [object] $Tags,

        [int] $WaitMinutes = 15,

        [int] $T4WaitMinutes = 20,

        [int] $PollSeconds = 20
    )

    $settings = $Context.Settings
    $result = [ordered]@{ action = 'session'; status = 'Refused'; message = ''; sessionId = [string]$Request.SessionId; runEndUtc = ''; autoStopUtc = ''; replica = ''; dispatched = @(); skipped = @() }
    if (-not $PSCmdlet.ShouldProcess($settings.demoResourceGroup, 'Start a demo session')) {
        $result.message = 'What if: nothing was started.'
        return [pscustomobject]$result
    }
    if (-not (Test-DbHubSessionCapable -Settings $settings)) {
        $result.message = 'The control''s runbook settings predate the session (2026-11-14): run ./scripts/deploy.ps1, which publishes them again.'
        return [pscustomobject]$result
    }
    $status = New-DbHubSessionStatus -Context $Context -SessionId ([string]$Request.SessionId) -RequestedBy ([string]$Request.RequestedBy) -DurationMinutes ([int]$Request.DurationMinutes) -Tags $Tags
    # The earlier sessions whose evidence is still on the VMs (ADR 0031; reviews of 3b1348a and 93243d6), from the status
    # this session replaces, read before its first write: each VM's capture that no export took is exported with the ID of
    # the session that holds it right before this session's activity goes out there, one session's documents are fetched
    # (Invoke-DbHubRcaEarlier), and the status carries them all (rcaEarlierPending), so the next start still has them
    # whatever happens to this one. When the session before this one ended goes into the status too (review of 02d398a):
    # what the observer captured between then and this start is activity outside a Run all session, which this session's
    # exports don't take.
    $previousStatus = Read-DbHubSessionStatusCopy -Context $Context
    $rcaBacklog = Get-DbHubRcaBacklog -Settings $settings -Previous $previousStatus -SessionId ([string]$Request.SessionId) -NowUtc (Get-DbHubUtcNow)
    Set-DbHubRcaBacklog -Status $status -Backlog $rcaBacklog
    if ($null -ne $previousStatus -and [string]$previousStatus['sessionId'] -ne [string]$Request.SessionId) {
        $previousEnd = Get-DbHubRcaSessionEnd -Status $previousStatus
        if ($null -ne $previousEnd -and $previousEnd -le (Get-DbHubUtcNow)) {
            $status['rcaPreviousEndUtc'] = ConvertTo-DbHubTimeText -Value $previousEnd
        }
    }
    $rcaEntries = @($rcaBacklog.Entries)
    $rcaSent = [ordered]@{}
    $rcaSentSession = [ordered]@{}
    $sessionShared = @{ Status = $status; Context = $Context; Tags = $Tags; Work = $null; LastWriteUtc = [datetime]::MinValue; PollSeconds = $PollSeconds }
    $null = Write-DbHubSessionStatus -Context $Context -Status $status -Phase 'accepted'
    $refuse = {
        param([string] $Message, [string] $Fix)
        Add-DbHubSessionStep -Status $status -Step 'Start' -State 'Fail' -Message $Message -Fix $Fix
        $status['message'] = $Message
        $null = Write-DbHubSessionStatus -Context $Context -Status $status -Phase 'refused'
        $result.message = $Message
        return [pscustomobject]$result
    }

    $active = Get-DbHubActiveRun -Context $Context
    if ($active.Active) {
        return (& $refuse $active.Reason 'Wait until it ends, or run the notebook''s Stop now cell first.')
    }
    $zone = [System.TimeZoneInfo]::Utc
    try {
        $zone = [System.TimeZoneInfo]::FindSystemTimeZoneById([string]$settings.autoShutdownTimeZone)
    }
    catch {
        $zone = [System.TimeZoneInfo]::Utc
    }
    $clock = {
        param([datetime] $Utc)
        [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::SpecifyKind($Utc, [System.DateTimeKind]::Utc), $zone).ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    $plan = Get-DbHubRunPlan -Request $Request -Settings $settings -NowUtc $Context.NowUtc
    $minimum = [int](Get-DbHubMember -InputObject $settings -Name 'minSessionMinutes')
    if ($minimum -le 0) {
        $minimum = 30
    }
    $planned = [int][System.Math]::Floor(($plan.RunEndUtc - $Context.NowUtc).TotalMinutes)
    $status['autoShutdownUtc'] = ConvertTo-DbHubTimeText -Value $plan.ShutdownUtc
    if (-not $plan.Valid -or $planned -lt $minimum) {
        return (& $refuse ('The VMs shut down at {0} ({1}), too soon for a session of at least {2} minutes, so nothing was started.' -f (& $clock $plan.ShutdownUtc), $settings.autoShutdownTimeZone, $minimum) 'Run all again earlier in the day, or change autoShutdownTime in config/demo.config.json and run ./scripts/deploy.ps1.')
    }
    # A session that the auto-shutdown cuts short ends after its last whole showcase cycle (2026-11-14), so no beat stops
    # midway when the VMs' activity ends.
    $wholeCycles = $false
    $cycle = [int](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $settings -Name 'profiles') -Name 'showcase') -Name 'cycleMinutes')
    if ($planned -lt [int]$Request.DurationMinutes - 1 -and $cycle -gt 0 -and $planned -ge $cycle) {
        if (($planned % $cycle) -ne 0) {
            $shorter = $Request.PSObject.Copy()
            $shorter.DurationMinutes = [int]([System.Math]::Floor($planned / $cycle) * $cycle)
            $plan = Get-DbHubRunPlan -Request $shorter -Settings $settings -NowUtc $Context.NowUtc
            $planned = [int][System.Math]::Floor(($plan.RunEndUtc - $Context.NowUtc).TotalMinutes)
        }
        $wholeCycles = $true
    }
    $status['plannedMinutes'] = $planned
    if ($planned -lt [int]$Request.DurationMinutes - 1) {
        $cycleText = ''
        if ($wholeCycles) {
            $count = [int]($planned / $cycle)
            $noun = 'cycles'
            if ($count -eq 1) {
                $noun = 'cycle'
            }
            $cycleText = ' It ends after {0} whole {1}-minute showcase {2}, so no beat is cut off.' -f $count, $cycle, $noun
        }
        Add-DbHubSessionStep -Status $status -Step 'Plan' -State 'Warning' -Message ('This session runs {0} of the {1} minutes asked: it ends at {2}, before the VMs'' auto-shutdown at {3} ({4}), when the activity on the VMs ends.{5}' -f $planned, $Request.DurationMinutes, (& $clock $plan.RunEndUtc), (& $clock $plan.ShutdownUtc), $settings.autoShutdownTimeZone, $cycleText) -Fix 'For a full session, Run all earlier, or change autoShutdownTime in config/demo.config.json and run ./scripts/deploy.ps1.'
    }
    else {
        Add-DbHubSessionStep -Status $status -Step 'Plan' -State 'Pass' -Message ('The showcase runs {0} minutes on every target, until {1} ({2}).' -f $planned, (& $clock $plan.RunEndUtc), $settings.autoShutdownTimeZone)
    }

    # The busy marker: the nightly stop leaves the session to its own auto-stop (2026-11-14).
    $margin = [int](Get-DbHubMember -InputObject $settings -Name 'busyMarginMinutes')
    if ($margin -le 0) {
        $margin = 15
    }
    $busyUntil = $plan.AutoStopUtc.AddMinutes($margin)
    $marked = Set-DbHubResourceGroupTag -Context $Context -Tags @{ DbHubBusyUntilUtc = (ConvertTo-DbHubTimeText -Value $busyUntil); DbHubBusyBy = 'session'; DbHubSessionId = [string]$Request.SessionId; DbHubSessionStartUtc = (ConvertTo-DbHubTimeText -Value $Context.NowUtc) }
    if ($marked.Ok) {
        $status['busy']['marked'] = $true
        $status['busy']['untilUtc'] = ConvertTo-DbHubTimeText -Value $busyUntil
        $text = 'The demo is marked busy until {0} ({1}).' -f (& $clock $busyUntil), $settings.autoShutdownTimeZone
        if ($plan.ShutdownUtc -le $busyUntil) {
            $status['busy']['nightlyStopUtc'] = ConvertTo-DbHubTimeText -Value $plan.ShutdownUtc
            $text = '{0} The nightly stop at {1} waits for it: the session''s own auto-stop at {2} saves its metrics, deletes T4''s read replica, and stops everything.' -f $text, (& $clock $plan.ShutdownUtc), (& $clock $plan.AutoStopUtc)
        }
        $status['busy']['note'] = $text
        Add-DbHubSessionStep -Status $status -Step 'Busy' -State 'Pass' -Message $text
    }
    else {
        $status['busy']['note'] = 'The demo couldn''t be marked busy ({0}), so a nightly stop that comes before the session''s auto-stop may stop T4 and its read replica first; the auto-stop still deletes the replica.' -f $marked.Error
        Add-DbHubSessionStep -Status $status -Step 'Busy' -State 'Warning' -Message $status['busy']['note'] -Fix 'An Owner runs ./scripts/grant-safety-stop.ps1 once.'
    }
    $null = Write-DbHubSessionStatus -Context $Context -Status $status -Phase 'starting'

    # The run, which asks for T4's read replica as soon as T4 is Ready.
    $onProgress = {
        param([string] $Kind, [string] $Detail, [string] $State = 'Info', [string] $Fix = '')
        $shared = $sessionShared
        switch ($Kind) {
            'autostop' { $shared.Status['autoStopUtc'] = $Detail }
            'backup' { $shared.Status['autoStopBackupUtc'] = $Detail }
            'vm-start' { Add-DbHubSessionStep -Status $shared.Status -Step 'Start' -State 'Info' -Message ('{0} is starting.' -f $Detail) }
            't4-start' { Add-DbHubSessionStep -Status $shared.Status -Step 'T4' -State 'Info' -Message ('T4 ({0}) is starting.' -f $Detail) }
            # T5's container (2026-11-19, ADR 0027): there or created before T5's activity goes out, or why T5 sits it out.
            't5-container' { Add-DbHubSessionStep -Status $shared.Status -Step 'T5' -State $State -Message $Detail -Fix $Fix }
            'dispatched' {
                Add-DbHubSessionStep -Status $shared.Status -Step 'Activity' -State 'Pass' -Message $Detail
                $target = ($Detail -split ':')[0]
                if ($target -match '^T[1-5]$') {
                    $shared.Status['dispatchUtc'][$target] = ConvertTo-DbHubTimeText -Value (Get-DbHubUtcNow)
                }
                if ($Detail -like 'T4:*') {
                    $shared.Status['t4']['dispatchUtc'] = ConvertTo-DbHubTimeText -Value (Get-DbHubUtcNow)
                }
            }
            'skipped' { Add-DbHubSessionStep -Status $shared.Status -Step 'Activity' -State 'Warning' -Message $Detail }
            't5-end' { $shared.Status['t5']['endUtc'] = $Detail }
        }
        $now = Get-DbHubUtcNow
        if (($now - $shared.LastWriteUtc).TotalSeconds -ge 40) {
            $shared.LastWriteUtc = $now
            $null = Write-DbHubSessionStatus -Context $shared.Context -Status $shared.Status
        }
    }
    $onT4Ready = {
        $shared = $sessionShared
        if ($null -eq $shared.Work) {
            Add-DbHubSessionStep -Status $shared.Status -Step 'T4' -State 'Pass' -Message 'T4 is Ready; its read replica is asked for now.'
            $shared.Work = Start-DbHubSessionReplica -Context $shared.Context -Tags $shared.Tags -Status $shared.Status -RaceMinutes 0 -PollSeconds $shared.PollSeconds
            $shared.LastWriteUtc = Get-DbHubUtcNow
            $null = Write-DbHubSessionStatus -Context $shared.Context -Status $shared.Status
        }
    }
    # An earlier session's capture that no export took on this VM (ADR 0031; review of 93243d6): exported with that
    # session's ID right before this session's activity goes out there, so the runner gives it to that session; its parts
    # are fetched after the start, or by a later one. On a VM that ran before this start (review of 02d398a), activity
    # outside a Run all session could run there (deploy.ps1, start-demo.ps1), so an export with no session takes what it
    # captured instead, which no history takes, except what falls within the activity of the earlier session that holds
    # the VM, which goes with that session (a Run all in the minutes between a session's end and its auto-stop finds that
    # session's VMs still running). Either way the export ends before the activity goes out: Run Commands run in
    # parallel on a VM, and one that ran beside the activity would take this session's first capture too.
    $onVmReady = {
        param([string] $VmName, [bool] $RanBefore)
        if ($rcaEntries.Count -eq 0 -and -not $RanBefore) {
            return ''
        }
        $sentExport = Send-DbHubRcaEarlierExport -Context $Context -VmName $VmName -Entry $rcaEntries -RanBefore:$RanBefore
        if ($null -eq $sentExport) {
            return ''
        }
        $rcaSent[$VmName] = [string]$sentExport.Name
        $rcaSentSession[$VmName] = [string]$sentExport.SessionId
        $null = Wait-DbHubRcaRunCommand -Context $Context -VmName $VmName -Name ([string]$sentExport.Name) -PollSeconds ([System.Math]::Min(10, $PollSeconds))
        return [string]$sentExport.Name
    }
    $run = Start-DbHubActivityRun -Context $Context -Request $Request -Tags $Tags -Plan $plan -OnProgress $onProgress -OnT4Ready $onT4Ready -OnVmReady $onVmReady -WaitMinutes $WaitMinutes -T4WaitMinutes $T4WaitMinutes -PollSeconds $PollSeconds
    $result.runEndUtc = [string]$run.runEndUtc
    $result.autoStopUtc = [string]$run.autoStopUtc
    $result.dispatched = @($run.dispatched)
    $result.skipped = @($run.skipped)
    $status['runEndUtc'] = [string]$run.runEndUtc
    $status['dispatched'] = @($run.dispatched)
    $status['skipped'] = @($run.skipped)
    $status['monitoring'] = [string]$run.monitoring
    $status['runCommands'] = @(@(Get-DbHubMember -InputObject $run -Name 'runCommands') | Where-Object { $null -ne $_ })
    if ([string]$run.status -ne 'Dispatched') {
        # Refused (the auto-stop couldn't be created, or there was nothing to run) or Failed (nothing could be dispatched,
        # so the run stopped again what it started, #27). The group's tags were read before the marker was set, so it's cleared here.
        if ($marked.Ok) {
            $null = Set-DbHubResourceGroupTag -Context $Context -Tags @{ DbHubBusyUntilUtc = ''; DbHubBusyBy = '' }
        }
        $startText = [string]$run.message
        $left = [string](Get-DbHubMember -InputObject $run -Name 'left')
        $leftFix = [string](Get-DbHubMember -InputObject $run -Name 'leftFix')
        $leftSuffix = ' {0} {1}' -f $left, $leftFix
        if ($left -and $startText.EndsWith($leftSuffix)) {
            $startText = $startText.Substring(0, $startText.Length - $leftSuffix.Length)
        }
        Add-DbHubSessionStep -Status $status -Step 'Start' -State 'Fail' -Message $startText -Fix 'Run all again; ./scripts/status.ps1 shows what''s stopped or missing, and ./scripts/start-demo.ps1 starts the demo with more detail.'
        if ($left) {
            # What the run left running because it didn't start it, and how to stop everything (#27, user-directed 2026-11-17).
            Add-DbHubSessionStep -Status $status -Step 'Stop' -State 'Warning' -Message $left -Fix $leftFix
        }
        # An earlier session's export that went out before the run failed is still read, so its evidence isn't left behind.
        Invoke-DbHubRcaEarlier -Context $Context -Status $status -Entry $rcaEntries -Sent $rcaSent -SentSession $rcaSentSession -PollSeconds ([System.Math]::Min(10, $PollSeconds))
        $status['message'] = [string]$run.message
        $phase = 'failed'
        if ([string]$run.status -eq 'Refused') {
            $phase = 'refused'
        }
        $null = Write-DbHubSessionStatus -Context $Context -Status $status -Phase $phase
        $result.status = [string]$run.status
        $result.message = [string]$run.message
        return [pscustomobject]$result
    }

    # T4's read replica: asked for once T4 was Ready, or now; then waited for.
    $t4Now = Get-DbHubT4 -Context $Context -Tags $Tags
    $status['t4']['state'] = [string]$t4Now.State
    $status['t4']['sku'] = [string]$t4Now.SkuName
    $status['t4']['tier'] = [string]$t4Now.Tier
    if ($null -eq $sessionShared.Work) {
        if ($t4Now.State -eq 'Ready') {
            $sessionShared.Work = Start-DbHubSessionReplica -Context $Context -Tags $Tags -Status $status -PollSeconds $PollSeconds
        }
        else {
            $status['replica']['state'] = 'NotCreated'
            $status['replica']['note'] = 'T4 is {0}, so its read replica wasn''t created this session, and the replica-lag beat doesn''t run.' -f $(if ($t4Now.State) { $t4Now.State } else { 'unknown' })
            $status['replica']['fix'] = 'Run all again once T4 runs; ./scripts/status.ps1 shows T4.'
        }
    }
    if ($null -ne $sessionShared.Work -and -not $sessionShared.Work.Done) {
        $null = Write-DbHubSessionStatus -Context $Context -Status $status -Phase 'replica'
        $setting = Get-DbHubSessionReplicaSetting -Settings $settings
        $sessionShared.Work = Complete-DbHubSessionReplica -Context $Context -Tags $Tags -Status $status -Work $sessionShared.Work -WaitMinutes $setting.WaitMinutes -PollSeconds $PollSeconds
    }
    $replicaState = [string]$status['replica']['state']
    $replicaLevel = 'Pass'
    if ($replicaState -ne 'Ready') {
        $replicaLevel = 'Warning'
        if ($replicaState -eq 'NotSupported') {
            $replicaLevel = 'Info'
        }
    }
    $replicaText = 'T4''s read replica ({0}) is Ready.' -f $status['names']['t4Replica']
    if ($replicaState -ne 'Ready') {
        $replicaText = [string]$status['replica']['note']
    }
    elseif ([string]$status['replica']['note']) {
        $replicaText = '{0} {1}' -f $replicaText, $status['replica']['note']
    }
    Add-DbHubSessionStep -Status $status -Step 'Replica' -State $replicaLevel -Message $replicaText -Fix ([string]$status['replica']['fix'])
    $result.replica = $replicaText

    # The replica-lag beat: the showcase's slot in T4's even cycles, on T1's profile host, with the replica Ready.
    $dispatchUtc = ConvertTo-DbHubUtc -Value $status['t4']['dispatchUtc']
    $lag = $status['replicaLag']
    if ($replicaState -eq 'Ready' -and $null -ne $dispatchUtc -and [string]$t4Now.Tier -eq 'GeneralPurpose') {
        $windows = Get-DbHubReplicaLagPlan -ProfileSetUtc $dispatchUtc -RunEndUtc $plan.RunEndUtc
        $lag['windows'] = $windows
        if (@($windows).Count -gt 0) {
            $lag['planned'] = $true
            $lag['note'] = 'Read replica lag climbs to about 3 minutes, twice, from {0} ({1}) for 9 minutes: the showcase''s replica-lag beat on T1''s profile host, which knows the replica from deploy.ps1.' -f (& $clock (ConvertTo-DbHubUtc -Value $windows[0]['startUtc'])), $settings.autoShutdownTimeZone
            Add-DbHubSessionStep -Status $status -Step 'ReplicaLag' -State 'Pass' -Message $lag['note']
        }
        else {
            $lag['note'] = 'The session ends before the showcase''s replica-lag beat (50 minutes after T4''s profile was set), so Read replica lag stays at a few seconds.'
            $lag['fix'] = 'Run all with a longer session (durationMinutes), earlier in the day.'
            Add-DbHubSessionStep -Status $status -Step 'ReplicaLag' -State 'Info' -Message $lag['note'] -Fix $lag['fix']
        }
    }
    else {
        $why = 'T4''s read replica isn''t Ready'
        if ($replicaState -eq 'Ready' -and $null -eq $dispatchUtc) {
            $why = 'T4''s activity wasn''t dispatched'
        }
        elseif ($replicaState -eq 'Ready') {
            $why = 'T4 isn''t on the General Purpose tier'
        }
        $lag['note'] = 'The replica-lag beat doesn''t run this session: {0}.' -f $why
        $lag['fix'] = [string]$status['replica']['fix']
        # A Burstable T4 has no replica by Azure's rules (Not supported): that's said once, with the replica.
        $lagLevel = 'Warning'
        if ($replicaState -eq 'NotSupported') {
            $lagLevel = 'Info'
        }
        Add-DbHubSessionStep -Status $status -Step 'ReplicaLag' -State $lagLevel -Message $lag['note'] -Fix $lag['fix']
    }

    # T5's showcase (2026-11-19, ADR 0027, risk R896): it runs the whole session, as the other targets' do, and the runner
    # runs a ru-storm only when it and its recovery end before T5's profile does, so T5 is back at its baseline after its
    # last one, and its baseline runs on until the session's end (Get-DbHubT5LastStormEnd); ru-storm repeats cleanly in
    # every session.
    $t5End = ConvertTo-DbHubUtc -Value $status['t5']['endUtc']
    if ($null -ne $t5End) {
        Add-DbHubSessionStep -Status $status -Step 'T5' -State 'Pass' -Message ('T5 ({0}): its last ru-storm ends, and T5 is back at its baseline, with no throttled requests (429s), by {1} ({2}); its baseline runs on until the session ends at {3}, and the next Run all starts its ru-storm cycles again from the first.' -f $status['names']['t5Account'], (& $clock $t5End), $settings.autoShutdownTimeZone, (& $clock $plan.RunEndUtc))
    }

    # The session's hosts as its start ends (2026-11-16): a VM whose start failed or that stopped, or a dispatch Run
    # Command that failed, is a Warning now; DbHub-Monitor's re-checks look again while the session runs.
    $null = Add-DbHubSessionHealthStep -Status $status -Finding @(Get-DbHubSessionHealth -Context $Context -Status $status)

    # The earlier sessions' evidence (ADR 0031): the exports sent right before this session's activity went out read, one
    # session's documents fetched into the vault, and its bundle index into this status (rcaEarlier), which Run all saves
    # with that session's history.
    Invoke-DbHubRcaEarlier -Context $Context -Status $status -Entry $rcaEntries -Sent $rcaSent -SentSession $rcaSentSession -PollSeconds ([System.Math]::Min(10, $PollSeconds))

    $warnings = @(@($status['steps']) | Where-Object { $_['state'] -in 'Warning', 'Fail' }).Count
    $result.status = 'Started'
    if ($warnings -gt 0 -or @($run.skipped).Count -gt 0) {
        $result.status = 'Partial'
    }
    $result.message = 'The session runs until {0} UTC, and its auto-stop at {1} saves the metrics, deletes the replica, and stops everything. {2}' -f $result.runEndUtc, $result.autoStopUtc, $replicaText
    $status['message'] = $result.message
    $null = Write-DbHubSessionStatus -Context $Context -Status $status -Phase 'running'
    return [pscustomobject]$result
}

function Invoke-DbHubCapture {
    # The capture action (2026-11-14): T4's and its read replica's Azure Monitor metrics, and T5's (2026-11-18), into the
    # control vault, for the history; nothing is started or stopped.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [object] $Request,

        [AllowNull()]
        [object] $Tags
    )

    if (-not (Test-DbHubSessionCapable -Settings $Context.Settings)) {
        return [pscustomobject]@{ action = 'capture'; status = 'Refused'; message = 'The control''s runbook settings predate the session (2026-11-14): run ./scripts/deploy.ps1, which publishes them again.'; sessionId = [string]$Request.SessionId }
    }
    # The session's bundle index stays in the metrics' final version (ADR 0031): from the state its exports left in its
    # status's copy, when there's one for this session.
    $rcaIndex = $null
    $copy = Read-DbHubSessionStatusCopy -Context $Context
    if ($null -ne $copy -and [string]$copy['sessionId'] -eq [string]$Request.SessionId -and $copy.Contains('rca')) {
        $rcaIndex = New-DbHubRcaIndex -State (ConvertTo-DbHubRcaState -State $copy['rca'] -SessionId ([string]$Request.SessionId))
    }
    $saved = Save-DbHubSessionMetric -Context $Context -Tags $Tags -SessionId ([string]$Request.SessionId) -Rca $rcaIndex
    $state = 'Captured'
    if ($saved.Status -eq 'Warning') {
        $state = 'Partial'
    }
    elseif ($saved.Status -ne 'Pass') {
        $state = 'Failed'
    }
    return [pscustomobject]@{ action = 'capture'; status = $state; message = $saved.Message; sessionId = [string]$Request.SessionId; bytes = $saved.Bytes; replica = $saved.Replica; cosmos = [bool](Get-DbHubMember -InputObject $saved -Name 'Cosmos') }
}

$script:DbHubStopStatusPlan = @('acceptedUtc', 'runEndUtc', 'dispatchUtc', 't4', 'replicaLag', 't5', 'rcaEarlier')

function Get-DbHubRcaStopLeftLine {
    <#
    .SYNOPSIS
    The RCA.PENDING line of a session's stop (Final tests' live check of 4e2c65ed, finding 4: Stop now's RCA.CAPTURE lines
    said what it captured from 18:49 to 18:53, and nothing said that 18:21 to 18:49 was still on the VMs): what the stop
    leaves there, which start takes it, and until when, as the next start's own backlog of the stop's status gives them
    (Get-DbHubRcaBacklog) and in the words of that start's RCA.EARLIER lines. $null when the stop leaves nothing.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [Parameter(Mandatory = $true)]
        [datetime] $NowUtc
    )

    $session = [string]$Status['sessionId']
    $entries = @(@((Get-DbHubRcaBacklog -Settings $Settings -Previous $Status -SessionId '' -NowUtc $NowUtc).Entries) | Where-Object { $null -ne $_ })
    $own = @($entries | Where-Object { [string]$_['sessionId'] -eq $session }) | Select-Object -First 1
    if ($null -eq $own) {
        return $null
    }
    $time = { param([datetime] $Utc) '{0} UTC' -f $Utc.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture) }
    # Within a line's 400 characters (ConvertTo-DbHubSafeText), both parts on both VMs, behind earlier sessions.
    $parts = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $pending = @($own['pending'])
    if ($pending.Count -gt 0) {
        # The documents' own times (each ID starts with when its capture began): the minutes they hold begin there.
        $first = @($pending | ForEach-Object { [string](Get-DbHubMember -InputObject $_ -Name 'documentId') } | Sort-Object | Select-Object -First 1)[0]
        $began = [datetime]::ParseExact($first.Substring(0, 16), 'yyyyMMdd\THHmmss\Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        $vms = @($pending | ForEach-Object { [string](Get-DbHubMember -InputObject $_ -Name 'vm') } | Where-Object { $_ } | Select-Object -Unique)
        # The queue a start fetches from, as Invoke-DbHubRcaEarlier keeps it: bundles no saved index lists first, then
        # documents in the order the runner deletes them; one session's per start.
        $unsaved = @($entries | Where-Object { $_['mustFetch'] }).Count
        $order = @($entries | Where-Object { @($_['pending']).Count -gt 0 -and -not $_['mustFetch'] } | Sort-Object -Property { $_['expiresUtc'] })
        $ahead = [array]::IndexOf($order, $own) + $unsaved
        $turn = 'which the next session''s start fetches'
        if ($own['mustFetch']) {
            $turn = 'which a later start fetches with its bundles'
        }
        elseif ($ahead -gt 0) {
            $turn = 'which a later start fetches, behind {0} earlier session(s), one per start' -f $ahead
        }
        $parts.Add(('{0} document(s) on {1} not fetched whole, the first from {2} UTC, {3}, until {4}' -f $pending.Count, ($vms -join ' and '), $began.ToString('HH:mm', [System.Globalization.CultureInfo]::InvariantCulture), $turn, (& $time $own['expiresUtc'])))
    }
    if (@($own['leftVms']).Count -gt 0) {
        $parts.Add(('the capture on {0} that no export took, for the next start that sends activity there, until {1}' -f (@($own['leftVms']) -join ' and '), (& $time $own['heldUntilUtc'])))
    }
    if ($parts.Count -eq 0) {
        if (-not $own['mustFetch']) {
            return $null
        }
        $message = 'This session''s bundles in the control vault aren''t in a saved index yet: a later session''s start lists them in its index, which Run all saves with this session''s history.'
    }
    else {
        $deletes = 'when the runner deletes each'
        if ($parts.Count -eq 1) {
            $deletes = @('when the runner deletes it', 'when the runner deletes them')[[int]($pending.Count -gt 0)]
        }
        $message = 'Still on the VMs, for this session''s history: {0}, {1}.' -f ($parts -join '; and '), $deletes
    }    return [ordered]@{ step = 'RCA.PENDING'; status = 'Info'; message = (ConvertTo-DbHubSafeText -Text $message); fix = '' }
}

function Get-DbHubRcaStopLineList {
    # A stopped status's rcaLines, with its RCA.PENDING line as its rca state gives it now, in place of the one it had: a
    # re-check can hand the stopped session more after its stop wrote them (Add-DbHubRcaHandoff).
    param(
        [Parameter(Mandatory = $true)]
        [object] $Settings,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary] $Status,

        [Parameter(Mandatory = $true)]
        [datetime] $NowUtc
    )

    $lines = @(@($Status['rcaLines']) | Where-Object { $null -ne $_ -and [string](Get-DbHubMember -InputObject $_ -Name 'step') -ne 'RCA.PENDING' })
    $left = Get-DbHubRcaStopLeftLine -Settings $Settings -Status $Status -NowUtc $NowUtc
    if ($null -ne $left) {
        $lines += $left
    }
    return $lines
}

function Write-DbHubStopStatus {
    # After Stop now or an auto-stop of a session (2026-11-14): the session's status says it stopped, what was done, and
    # what failed, for the control notebook. Only when a session is known (the request's or the group's DbHubSessionId).
    # It keeps the session's plan from the status it replaces (2026-11-19): its window, when each target's activity went
    # out, T4's tier, the replica-lag beat, and T5's end, from the copy Read-DbHubSessionStatusCopy reads, when that copy
    # is the same session's (planKept says whether it was). So the control notebook's Stop now, and its next Run all's
    # pre-check, can save the session's history with its beats and its "saved" row when the run that was ending it
    # stopped first. It keeps the evidence of earlier sessions that's still on the VMs (rcaEarlierPending, review of
    # 3b1348a) whichever session's status it replaces, for the next session's start.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [AllowEmptyString()]
        [string] $SessionId = '',

        [Parameter(Mandatory = $true)]
        [object] $Stopped,

        [Parameter(Mandatory = $true)]
        [string] $By
    )

    if (-not (Test-DbHubSessionCapable -Settings $Context.Settings)) {
        return
    }
    $session = $SessionId
    if (-not $session) {
        $session = [string](Get-DbHubMember -InputObject $Tags -Name 'DbHubSessionId')
    }
    if ($session -notmatch '^[0-9a-f]{32}$') {
        return
    }
    $status = [ordered]@{ schemaVersion = 1; sessionId = $session; phase = 'stopped'; updatedUtc = ''; stoppedUtc = (ConvertTo-DbHubTimeText -Value (Get-DbHubUtcNow)); stoppedBy = $By; jobId = [string]$Context.JobId; done = @($Stopped.Done); failed = @($Stopped.Failed); metrics = [ordered]@{ status = [string](Get-DbHubMember -InputObject $Stopped -Name 'MetricsStatus'); message = [string](Get-DbHubMember -InputObject $Stopped -Name 'MetricsMessage') }; planKept = $false }
    # The metrics' final version (review of 15ad76d): the notebook reads it by its ID, because a re-check's bundle can still
    # be written after it.
    $metricsVersion = [string](Get-DbHubMember -InputObject $Stopped -Name 'MetricsVersion')
    if ($metricsVersion -cmatch '^[0-9a-f]{32}$') {
        $status['metrics']['version'] = $metricsVersion
    }
    $earlier = Read-DbHubSessionStatusCopy -Context $Context
    if ($null -ne $earlier -and [string]$earlier['sessionId'] -eq $session) {
        foreach ($name in $script:DbHubStopStatusPlan) {
            if ($earlier.Contains($name)) {
                $status[$name] = $earlier[$name]
            }
        }
        $status['planKept'] = $true
    }
    # The session's evidence (ADR 0031): the stop's export and its lines (RCA.EXPORT, RCA.CAPTURE.<target>) for the
    # notebook, or the state the session's re-checks left, so the next session's start knows what's still on the VMs.
    $rca = Get-DbHubMember -InputObject $Stopped -Name 'Rca'
    if ($null -ne $rca) {
        $status['rca'] = $rca.State
        $status['rcaLines'] = @(@($rca.Lines) | ForEach-Object { [ordered]@{ step = [string]$_.Step; status = [string]$_.Status; message = (ConvertTo-DbHubSafeText -Text ([string]$_.Message)); fix = (ConvertTo-DbHubSafeText -Text ([string]$_.Fix)) } })
    }
    elseif ($null -ne $earlier -and [string]$earlier['sessionId'] -eq $session -and $earlier.Contains('rca')) {
        $status['rca'] = $earlier['rca']
    }
    # The evidence of earlier sessions that's still on the VMs (rcaEarlierPending, reviews of 3b1348a and 93243d6): it isn't
    # this session's, so it's kept whichever session's status this replaces, with that session's own when it's another's
    # (Get-DbHubRcaBacklog), and with the documents of another session that this stop's export found
    # (Add-DbHubRcaElsewhere); the next session's start exports it, and says what's past the runner's time.
    $now = Get-DbHubUtcNow
    $carried = @(@((Get-DbHubRcaBacklog -Settings $Context.Settings -Previous $earlier -SessionId $session -NowUtc $now -KeepAll).Entries) | ForEach-Object { ConvertTo-DbHubRcaCarry -Entry $_ } | Where-Object { $null -ne $_ })
    if ($carried.Count -gt 0) {
        $status['rcaEarlierPending'] = $carried
    }
    if ($null -ne $rca) {
        $null = Add-DbHubRcaElsewhere -Status $status -Document @(Get-DbHubMember -InputObject $rca -Name 'Others') -NowUtc $now
    }
    # What a re-check found while this stop ran (Add-DbHubRcaHandoff): the session's documents still to export, which the
    # next session's start exports (Get-DbHubRcaEarlier).
    if ($null -ne $earlier -and [string]$earlier['sessionId'] -eq $session -and $earlier.Contains('rcaHandoff')) {
        $state = ConvertTo-DbHubRcaState -State $status['rca'] -SessionId $session
        $known = New-Object -TypeName 'System.Collections.Generic.HashSet[string]'
        foreach ($item in @(@($state['documents']) + @($state['pending']))) {
            $null = $known.Add([string](Get-DbHubMember -InputObject $item -Name 'documentId'))
        }
        $added = @(@($earlier['rcaHandoff']) | Where-Object { $null -ne $_ -and [string](Get-DbHubMember -InputObject $_ -Name 'vm') -and $known.Add([string](Get-DbHubMember -InputObject $_ -Name 'documentId')) })
        if ($added.Count -gt 0) {
            $state['pending'] = @(@($state['pending']) + $added)
            $state['final'] = $false
            $status['rca'] = $state
        }
    }
    # What the stop leaves on the VMs, which start takes it, and until when, after the notebook's other lines (finding 4).
    if ($status.Contains('rca')) {
        $lines = @(Get-DbHubRcaStopLineList -Settings $Context.Settings -Status $status -NowUtc $now)
        if ($lines.Count -gt 0) {
            $status['rcaLines'] = $lines
        }
    }
    $null = Write-DbHubSessionStatus -Context $Context -Status $status
}

function Invoke-DbHubControl {
    <#
    .SYNOPSIS
    DbHub-Control's entry point: validates the webhook request, checks that the demo environment exists and that the
    identity can read it (A1), then runs, starts a session (the control notebook's Run all, 2026-11-14), captures the
    history's metrics, stops, or resets. A bad request is refused, never thrown.
    #>
    param(
        [AllowNull()]
        [object] $WebhookData,

        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    $request = Test-DbHubControlRequest -WebhookData $WebhookData -Settings $Context.Settings
    if (-not $request.Valid) {
        Write-DbHubLog -Context $Context -Message ('Refused: {0}' -f $request.Reason)
        return [pscustomobject]@{ action = ''; status = 'Refused'; message = $request.Reason }
    }
    Write-DbHubLog -Context $Context -Message ('Request: {0} by {1}.' -f $request.Action, $request.RequestedBy)
    $group = Get-DbHubResourceGroupTag -Context $Context
    if ($group.GroupState -ne 'Present') {
        $reasons = @{
            Missing    = 'the demo resource group doesn''t exist'
            NotGranted = 'the automation identity can''t read the demo resource group; after a redeploy, an Owner runs ./scripts/grant-safety-stop.ps1 (A1)'
            Unknown    = ('the demo resource group couldn''t be read: {0}' -f $group.Error)
        }
        $why = $reasons[$group.GroupState]
        Write-DbHubLog -Context $Context -Message ('Nothing was done: {0}.' -f $why)
        return [pscustomobject]@{ action = $request.Action; status = 'NoEnvironment'; message = ('Nothing was done: {0}.' -f $why) }
    }
    if ($request.Action -eq 'stop') {
        $stopped = Stop-DbHubDemo -Context $Context -Tags $group.Tags -SessionId $request.SessionId
        $status = 'Stopped'
        $failedText = ''
        if (@($stopped.Failed).Count -gt 0) {
            $status = 'Partial'
            $failedText = '; failed: ' + (@($stopped.Failed) -join ', ')
        }
        Write-DbHubStopStatus -Context $Context -Tags $group.Tags -SessionId $request.SessionId -Stopped $stopped -By 'Stop now'
        return [pscustomobject]@{ action = 'stop'; status = $status; message = ('Stop now: {0}{1}.' -f (@($stopped.Done) -join ', '), $failedText); done = $stopped.Done; failed = $stopped.Failed; t5Status = $stopped.T5Status; rca = (Get-DbHubRcaResult -Rca $stopped.Rca) }
    }
    if ($request.Action -eq 'reset') {
        return (Reset-DbHubActivity -Context $Context -Request $request -Tags $group.Tags)
    }
    if ($request.Action -eq 'session') {
        return (Start-DbHubSession -Context $Context -Request $request -Tags $group.Tags)
    }
    if ($request.Action -eq 'capture') {
        return (Invoke-DbHubCapture -Context $Context -Request $request -Tags $group.Tags)
    }
    return (Start-DbHubActivityRun -Context $Context -Request $request -Tags $group.Tags)
}

function Invoke-DbHubStop {
    <#
    .SYNOPSIS
    DbHub-Stop's entry point. Scope All (the per-run auto-stop): what Stop now does. Scope T4 (the control's daily T4
    safety stop): stops T4 only when it's running, because a stopped flexible server starts itself after 7 days, and deletes
    T5's container while sqlvm01 doesn't run, as a fallback for the nightly stop (2026-11-19). Scope Nightly (the nightly
    safety stop, ADR 0024): deallocates the VMs, stops T4, and deletes T5's container (Invoke-DbHubNightlyStop). Scope
    T3Check (its check, ADR 0024): reads T3's status and stops T4 when it runs (Invoke-DbHubT3Check). None of them starts
    anything, and T5's container goes only when its lifecycle is Session (Remove-DbHubT5Container).
    Nightly and T3Check say when the safety stop's identity can't read the demo resource group (NotGranted: its role isn't
    assigned). Nightly, T3Check, and T4 are Deferred while the group's busy marker is active (Get-DbHubBusyMarker,
    2026-11-14): a deploy.ps1 run or a demo session that's still running isn't cut off.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('All', 'T4', 'Nightly', 'T3Check')]
        [string] $Scope,

        [Parameter(Mandatory = $true)]
        [object] $Context,

        [int] $PollSeconds = 30
    )

    $label = 'stop-' + $Scope.ToLowerInvariant()
    if ($Scope -eq 'T3Check') {
        $label = 'check-t3'
    }
    $group = Get-DbHubResourceGroupTag -Context $Context
    if ($group.GroupState -ne 'Present') {
        if ($Scope -eq 'All') {
            $null = Clear-DbHubAutoStop -Context $Context
        }
        Write-DbHubLog -Context $Context -Message ('Nothing to stop: the demo resource group is {0}.' -f $group.GroupState)
        if ($Scope -in 'Nightly', 'T3Check' -and $group.GroupState -ne 'Missing') {
            # The safety stop's own identity lives in the demo resource group, so a group it can't read means its role
            # isn't assigned (NotGranted) or Azure didn't answer (Unknown): that night's work wasn't done.
            $why = 'its identity can''t read the demo resource group: the role "DbHub Demo Safety Stop" isn''t assigned there yet (an Owner runs ./scripts/grant-safety-stop.ps1)'
            $status = 'NotGranted'
            if ($group.GroupState -eq 'Unknown') {
                $why = 'the demo resource group couldn''t be read: {0}' -f $group.Error
                $status = 'Partial'
            }
            return [pscustomobject]@{ action = $label; status = $status; message = ('Nothing was done: {0}.' -f $why) }
        }
        return [pscustomobject]@{ action = $label; status = 'NoEnvironment'; message = ('The demo resource group is {0}; nothing was stopped.' -f $group.GroupState) }
    }
    if ($Scope -in 'Nightly', 'T3Check', 'T4') {
        # The busy marker (2026-11-14): a deploy.ps1 run or a demo session that's still running isn't cut off by a nightly
        # pass; an expired marker no longer defers anything (Get-DbHubBusyMarker).
        $deferred = Get-DbHubBusyDeferral -Label $label -Tags $group.Tags -Context $Context
        if ($null -ne $deferred) {
            return $deferred
        }
    }
    if ($Scope -eq 'T3Check') {
        return (Invoke-DbHubT3Check -Context $Context -Tags $group.Tags -PollSeconds $PollSeconds)
    }
    if ($Scope -eq 'Nightly') {
        $nightly = Invoke-DbHubNightlyStop -Context $Context -Tags $group.Tags -PollSeconds $PollSeconds
        $status = 'Stopped'
        $failedText = ''
        if (@($nightly.Failed).Count -gt 0) {
            $status = 'Partial'
            $failedText = '; failed: ' + (@($nightly.Failed) -join ', ')
        }
        return [pscustomobject]@{ action = $label; status = $status; message = ('Nightly safety stop: {0}{1}.' -f (@($nightly.Done) -join ', '), $failedText); done = $nightly.Done; failed = $nightly.Failed; vms = $nightly.Vms; t4 = $nightly.T4; replica = $nightly.Replica; t5 = $nightly.T5; t5Status = $nightly.T5Status }
    }
    if ($Scope -eq 'T4') {
        # T5's container (2026-11-19, ADR 0027), as a fallback for a night the safety stop couldn't delete it (its role
        # without the container's actions yet): only while sqlvm01, whose runner drives T5, doesn't run, so nothing uses it.
        # Its outcome is apart from the job's status (t5Status; review of ab91ee5), as in the nightly pass.
        $t5Part = [pscustomobject]@{ Text = ''; Status = ''; Deleted = $false }
        $sqlState = Get-DbHubVmState -Context $Context -VmName ([string]$Context.Settings.sqlVmName)
        if ($sqlState -in 'deallocated', 'deallocating', 'stopped', 'Missing') {
            $t5 = Remove-DbHubT5Container -Context $Context -Tags $group.Tags
            $t5Part.Text = Get-DbHubT5ContainerText -Outcome $t5
            $t5Part.Status = [string]$t5.Outcome
            $t5Part.Deleted = $t5.Outcome -eq 'Deleted'
        }
        else {
            Write-DbHubLog -Context $Context -Message ('T5''s container was left alone: {0} is {1}, so a run may use it.' -f $Context.Settings.sqlVmName, $sqlState)
        }
        $t5Sentence = ''
        if ($t5Part.Text) {
            $t5Sentence = ' {0}.' -f $t5Part.Text
        }
        $t4 = Get-DbHubT4 -Context $Context -Tags $group.Tags
        # T4's read replica, when a session left it behind (ADR 0025): stopped once T4 is, which waits for T4's stop.
        $replicaPart = {
            param([string] $T4Outcome)
            $replica = Invoke-DbHubT4ReplicaStop -Context $Context -Tags $group.Tags -T4Outcome $T4Outcome -WaitMinutes (Get-DbHubT4WaitMinute -Settings $Context.Settings) -PollSeconds $PollSeconds
            return [pscustomobject]@{ Failed = ($replica.Outcome -eq 'Failed'); Text = (Get-DbHubT4ReplicaStopText -Outcome $replica) }
        }
        if ($t4.State -in 'Ready', 'Starting', 'Updating') {
            $sent = Invoke-DbHubT4Action -Context $Context -Name $t4.Name -Action stop
            $status = 'Partial'
            $outcome = 'failed'
            if ($sent) {
                $status = 'Stopped'
                $outcome = 'accepted'
            }
            $replicaDone = & $replicaPart $(if ($sent) { 'Sent' } else { 'Failed' })
            if ($replicaDone.Failed) {
                $status = 'Partial'
            }
            $replicaSentence = if ($replicaDone.Text) { ' {0}.' -f $replicaDone.Text } else { '' }
            return [pscustomobject]@{ action = $label; status = $status; message = ('T4 ({0}) was {1}; its stop was {2}.{3}{4}' -f $t4.Name, $t4.State, $outcome, $replicaSentence, $t5Sentence); replica = $replicaDone.Text; t5 = $t5Part.Text; t5Status = $t5Part.Status }
        }
        $replicaDone = & $replicaPart ''
        if ($replicaDone.Text -or $t5Part.Text) {
            $status = 'Stopped'
            if ($replicaDone.Failed) {
                $status = 'Partial'
            }
            elseif (-not $replicaDone.Text -and -not $t5Part.Deleted) {
                # T4 was already stopped, and T5's container was already gone, is kept, or couldn't be deleted: nothing was
                # stopped now.
                $status = 'Skipped'
            }
            $replicaSentence = if ($replicaDone.Text) { ' {0}.' -f $replicaDone.Text } else { '' }
            return [pscustomobject]@{ action = $label; status = $status; message = ('T4 is {0}.{1}{2}' -f $t4.State, $replicaSentence, $t5Sentence); replica = $replicaDone.Text; t5 = $t5Part.Text; t5Status = $t5Part.Status }
        }
        return [pscustomobject]@{ action = $label; status = 'Skipped'; message = ('T4 is {0}; nothing to stop.' -f $t4.State) }
    }
    # start-demo.ps1's auto-stop (2026-11-19) waits for a deploy.ps1 run that's still going; a session's never does.
    $waiting = Get-DbHubStartDemoDeferral -Context $Context -Tags $group.Tags
    if ($null -ne $waiting) {
        return $waiting
    }
    $stopped = Stop-DbHubDemo -Context $Context -Tags $group.Tags -PollSeconds $PollSeconds
    $status = 'Stopped'
    $failedText = ''
    if (@($stopped.Failed).Count -gt 0) {
        $status = 'Partial'
        $failedText = '; failed: ' + (@($stopped.Failed) -join ', ')
    }
    Write-DbHubStopStatus -Context $Context -Tags $group.Tags -Stopped $stopped -By 'Auto-stop'
    return [pscustomobject]@{ action = $label; status = $status; message = ('Auto-stop: {0}{1}.' -f (@($stopped.Done) -join ', '), $failedText); done = $stopped.Done; failed = $stopped.Failed; t5Status = $stopped.T5Status; rca = (Get-DbHubRcaResult -Rca $stopped.Rca) }
}

function Invoke-DbHubMonitor {
    <#
    .SYNOPSIS
    DbHub-Monitor's entry point, which a run's monitoring re-checks start (Register-DbHubMonitorRecheck): while the run
    lasts (its auto-stop is pending) and sqlvm01 runs, it looks after T1's monitoring plugin as the run's start did
    (Step-DbHubMonitor): left alone when a status reported since the VM's latest start says it runs, its agent's service
    restarted once when a fresh status says another state or no fresh status comes. It never starts or stops a VM or T4,
    and does nothing once the run has ended.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [int] $PollSeconds = 30
    )

    $settings = $Context.Settings
    $group = Get-DbHubResourceGroupTag -Context $Context
    if ($group.GroupState -ne 'Present') {
        Write-DbHubLog -Context $Context -Message ('Nothing to check: the demo resource group is {0}.' -f $group.GroupState)
        return [pscustomobject]@{ action = 'monitor'; status = 'NoEnvironment'; monitoring = ''; message = ('The demo resource group is {0}; nothing was checked.' -f $group.GroupState) }
    }
    $pending = Get-DbHubAutoStopRunEnd -Context $Context
    if ($pending.State -ne 'Pending') {
        $why = 'no on-demand run is active'
        if ($pending.State -eq 'Unknown') {
            $why = 'the auto-stop schedule couldn''t be read ({0})' -f $pending.Error
        }
        Write-DbHubLog -Context $Context -Message ('Nothing to check: {0}.' -f $why)
        return [pscustomobject]@{ action = 'monitor'; status = 'Skipped'; monitoring = ''; message = ('Nothing was checked: {0}.' -f $why) }
    }
    # A running session's hosts first (2026-11-16): a VM that stopped or whose start failed, or a dispatch Run Command that
    # failed, goes into the session's status as a Warning, which Run all's live cell prints.
    $health = Update-DbHubSessionHealth -Context $Context -Tags $group.Tags
    # Then the session's evidence for the Incident RCA (ADR 0031): what the observer captured since the last export goes
    # into the control vault now, so the session's end has only its last half hour left to export.
    $evidence = Update-DbHubSessionRca -Context $Context -Tags $group.Tags
    $vm = [string]$settings.sqlVmName
    $state = Get-DbHubVmState -Context $Context -VmName $vm
    if ($state -ne 'running') {
        Write-DbHubLog -Context $Context -Message ('Nothing to check: {0} is {1}.' -f $vm, $state)
        $skippedStatus = 'Skipped'
        if ($health.Outcome -in 'Warned', 'Known') {
            $skippedStatus = 'Partial'
        }
        return [pscustomobject]@{ action = 'monitor'; status = $skippedStatus; monitoring = ''; session = $health.Outcome; rca = $evidence.Outcome; message = ('T1''s monitoring plugin wasn''t checked: {0} is {1}.{2}{3}' -f $vm, $state, $health.Note, $evidence.Note) }
    }
    $stamp = $Context.NowUtc.ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $look = Initialize-DbHubMonitorState
    $monitoring = $settings.monitoring
    $giveUp = (Get-DbHubUtcNow).AddMinutes([int](Get-DbHubMember -InputObject $monitoring -Name 'settleMinutes') + [int](Get-DbHubMember -InputObject $monitoring -Name 'verifyMinutes') + 5)
    while ($true) {
        Step-DbHubMonitor -Context $Context -State $look -Stamp $stamp
        if ($look.Done -or (Get-DbHubUtcNow) -ge $giveUp) {
            break
        }
        Start-Sleep -Seconds $PollSeconds
    }
    $outcome = $look.Outcome
    if (-not $look.Done) {
        $outcome = 'Unfinished'
    }
    $texts = @{
        Running         = 'T1''s monitoring plugin runs; nothing was changed.'
        Restarted       = 'T1''s monitoring plugin wasn''t running; the SQL IaaS Agent service was restarted, and the plugin runs with uploads OK.'
        StillNotRunning = 'T1''s monitoring plugin wasn''t running, and still didn''t run after the SQL IaaS Agent service''s restart; run start-demo.ps1, which restarts it and reports the plugin''s state (T1.SQLVM.MONITORING).'
        RestartRefused  = 'T1''s monitoring plugin wasn''t running, and Azure didn''t accept the Run Command that restarts the SQL IaaS Agent service.'
        NotSelected     = 'Performance monitoring isn''t turned on for T1; nothing was checked.'
        Unread          = 'The SQL IaaS Agent extension couldn''t be read; nothing was changed.'
        Unfinished      = 'T1''s monitoring plugin wasn''t settled in time; nothing more was changed.'
    }
    $status = 'Checked'
    if ($outcome -in 'StillNotRunning', 'RestartRefused', 'Unread', 'Unfinished' -or $health.Outcome -in 'Warned', 'Known') {
        $status = 'Partial'
    }
    return [pscustomobject]@{ action = 'monitor'; status = $status; monitoring = $outcome; session = $health.Outcome; rca = $evidence.Outcome; message = ($texts[$outcome] + $health.Note + $evidence.Note) }
}
