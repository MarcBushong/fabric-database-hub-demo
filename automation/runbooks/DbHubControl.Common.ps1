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
# Run Command, which waited more than 10 minutes on a saturated sqlvm01 in Phase 25a.

$script:DbHubArmRoot = 'https://management.azure.com'
$script:DbHubActiveJobStatuses = @('New', 'Activating', 'Running', 'Resuming', 'Blocked', 'Stopping', 'Suspending')

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
        throw 'The runbook settings have an unknown schemaVersion; publish the runbooks again with setup-activity-control.ps1.'
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
        throw 'The Automation sandbox has no managed identity endpoint (IDENTITY_ENDPOINT); run setup-activity-control.ps1 again so the account has id-<prefix>-automation.'
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
    - {"action": "capture", "sessionId": "..."}: T4's and its read replica's Azure Monitor metrics into the control vault,
      for the history (Save-DbHubSessionMetric); nothing is started or stopped.
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
    # autoStopBufferMinutes has passed), Pending (with RunEndUtc), or Unknown (it couldn't be read, with Error).
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    $settings = $Context.Settings
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Automation/automationAccounts'
    $schedule = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/schedules/{1}' -f (Get-DbHubAccountPath -Settings $settings), $settings.autoStopSchedule) -ApiVersion $version
    if ($schedule.StatusCode -eq 404) {
        return [pscustomobject]@{ State = 'None'; RunEndUtc = $null; Error = '' }
    }
    if ($schedule.StatusCode -ne 200) {
        return [pscustomobject]@{ State = 'Unknown'; RunEndUtc = $null; Error = $schedule.Error }
    }
    $start = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $schedule.Body -Name 'properties') -Name 'startTime')
    if ($null -ne $start) {
        $runEnd = $start.AddMinutes(-1 * [int]$settings.autoStopBufferMinutes)
        if ($runEnd -gt $Context.NowUtc) {
            return [pscustomobject]@{ State = 'Pending'; RunEndUtc = $runEnd; Error = '' }
        }
    }
    return [pscustomobject]@{ State = 'None'; RunEndUtc = $null; Error = '' }
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
    the previous one. It's created before anything starts, so every run has its stop.
    https://learn.microsoft.com/rest/api/automation/schedule/create-or-update
    https://learn.microsoft.com/rest/api/automation/job-schedule/create
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [datetime] $AutoStopUtc
    )

    $settings = $Context.Settings
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Automation/automationAccounts'
    $account = Get-DbHubAccountPath -Settings $settings
    if (-not (Clear-DbHubAutoStop -Context $Context)) {
        return [pscustomobject]@{ Created = $false; Error = 'the previous auto-stop couldn''t be removed'; StartUtc = ''; BackupUtc = '' }
    }
    $start = [DateTime]::SpecifyKind($AutoStopUtc, [System.DateTimeKind]::Utc).ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $body = @{
        name       = [string]$settings.autoStopSchedule
        properties = @{
            description = ('Stops the demo after the on-demand run that job {0} started (ADR 0020).' -f $Context.JobId)
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
        $backupBody = @{ name = $backup; properties = @{ description = ('Stops the demo if the auto-stop of the run that job {0} started didn''t (ADR 0026).' -f $Context.JobId); startTime = $backupStart; frequency = 'OneTime'; timeZone = 'UTC' } }
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
    baked into the settings) once per target, in order. T1's runner drives T1, T3, and T4 on sqlvm01; archost01
    relays T2 into its guest. For T2 the script first waits, at most 12 minutes, for the guest's Hyper-V heartbeat,
    because a host that was just started runs its guest a few minutes later; a guest that's off and doesn't start by
    itself (its automatic start action isn't Start: a golden capture's air gap, or a guest that was shut down) isn't
    waited for, because the VM-side control releases or starts it before its activity (Invoke-DemoControlGuestReady).
    Each request is Base64 JSON, checked before it goes between single quotes.
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
    $parts = @('# DbHubDemo on-demand dispatch (ADR 0020), generated by the DbHub-Control runbook; it holds no secrets.')
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
        $json = $item | ConvertTo-Json -Depth 6 -Compress
        $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
        if ($encoded -notmatch '^[A-Za-z0-9+/=]+$') {
            throw 'A request did not encode to Base64.'
        }
        $parts += $template.Replace('__REQUEST__', $encoded)
    }
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
    the time), it's fresh only once the start is more than 30 minutes old, so a cold start still gets its restart and a VM
    that has run a while isn't restarted on every look.
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
    deallocates both VMs, and stops T4, through Azure Resource Manager only and without waiting. Never Run Command
    (Phase 25a, finding 5): deallocation ends every session on T1 and T2 (the T2 guest shuts down through the host's
    automatic stop action, ShutDown), T3's sessions end with T1's runner, and T3 auto-pauses after its delay. The
    activity profiles end at their own end; the profile host ends what a stopped run left behind when it starts again.
    Returns Done, Failed, MetricsStatus, and MetricsMessage.

    .DESCRIPTION
    With the control's session settings (2026-11-14, ADR 0026), and T4's read replica there or a session's busy marker set:
    T4's and the replica's Azure Monitor metrics go to the control vault first (Save-DbHubSessionMetric), because a
    deleted server's can't be read; then the replica is deleted (Remove-DbHubT4Replica) before T4 stops, and a session's
    busy marker is cleared. Without the grant to delete it (or with the safety stop's settings), the replica is stopped
    once T4 is, as before.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [AllowEmptyString()]
        [string] $SessionId = ''
    )

    $settings = $Context.Settings
    if (-not $PSCmdlet.ShouldProcess($settings.demoResourceGroup, 'Deallocate the VMs and stop T4')) {
        return [pscustomobject]@{ Done = @(); Failed = @(); MetricsStatus = ''; MetricsMessage = '' }
    }
    $done = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $failed = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $metricsStatus = ''
    $metricsMessage = ''
    if (Clear-DbHubAutoStop -Context $Context) {
        $done.Add('auto-stop removed')
    }
    else {
        $failed.Add('auto-stop schedule')
    }
    $session = Test-DbHubSessionCapable -Settings $settings
    $busy = Get-DbHubBusyMarker -Tags $Tags -Settings $settings -NowUtc $Context.NowUtc
    $replicaThere = $false
    if ($session) {
        $replicaThere = (Get-DbHubT4Replica -Context $Context -Tags $Tags).State -notin 'NotConfigured', 'Missing', 'Unknown'
        if ($replicaThere -or $busy.By -eq 'session') {
            # The history's metrics first, while the replica exists.
            $saved = Save-DbHubSessionMetric -Context $Context -Tags $Tags -SessionId $SessionId
            $metricsStatus = [string]$saved.Status
            $metricsMessage = [string]$saved.Message
            if ($saved.Status -in 'Pass', 'Warning') {
                $done.Add('the history''s metrics saved to the control vault')
            }
            else {
                $done.Add(('the history''s metrics not saved ({0})' -f $saved.Message))
            }
        }
    }
    foreach ($vm in @([string]$settings.sqlVmName, [string]$settings.hostVmName)) {
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
    $replicaDeleted = $false
    if ($session -and $replicaThere) {
        # T4's read replica (ADR 0025) bills only during a session: deleted, which doesn't wait for T4 (2026-11-14).
        $removed = Remove-DbHubT4Replica -Context $Context -Tags $Tags -WaitMinutes (Get-DbHubSessionReplicaSetting -Settings $settings).DeleteMinutes
        switch ($removed.Outcome) {
            'Deleted' {
                $done.Add(('T4''s read replica {0} deleted' -f $removed.Name))
                $replicaDeleted = $true
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
    $t4 = Get-DbHubT4 -Context $Context -Tags $Tags
    $t4Outcome = ''
    if ($t4.State -in 'Ready', 'Starting', 'Updating') {
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
    if (-not $replicaDeleted) {
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
    return [pscustomobject]@{ Done = $done.ToArray(); Failed = $failed.ToArray(); MetricsStatus = $metricsStatus; MetricsMessage = $metricsMessage }
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
    never uses Run Command, never connects to a database, and never touches the control's schedules. Returns Done,
    Failed, Vms (each VM's outcome), and T4 (its outcome).
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
    return [pscustomobject]@{ Done = $done.ToArray(); Failed = $failed.ToArray(); Vms = $vms; T4 = $t4Text; Replica = $replicaText }
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
    # The VM whose runner drives a target: archost01 relays T2 into its guest; sqlvm01 drives T1, T3, and T4.
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

function Start-DbHubActivityRun {
    <#
    .SYNOPSIS
    The run action: refuses while a run is active, plans the durations, creates the auto-stop (and, when the run uses
    sqlvm01, the monitoring re-checks) before anything starts, starts what's stopped (the VMs, and T4; T3 resumes when
    the runner connects), and dispatches each target's activity profile through an asynchronous managed Run Command,
    then exits. If nothing could be dispatched, it stops everything again at once.

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

        # Called with a kind (autostop, backup, vm-start, t4-start, dispatched, or skipped) and a detail, for a session's status.
        [AllowNull()]
        [scriptblock] $OnProgress = $null,

        # Called once, when T4 is first seen Ready, for a session's read replica.
        [AllowNull()]
        [scriptblock] $OnT4Ready = $null
    )

    $settings = $Context.Settings
    if (-not $PSCmdlet.ShouldProcess($settings.demoResourceGroup, 'Start an on-demand run')) {
        return [pscustomobject]@{ action = 'run'; status = 'Refused'; message = 'What if: nothing was started.'; runEndUtc = ''; autoStopUtc = ''; dispatched = @(); skipped = @(); monitoring = ''; rechecks = @(); replica = '' }
    }
    $result = [ordered]@{ action = 'run'; status = 'Refused'; message = ''; runEndUtc = ''; autoStopUtc = ''; dispatched = @(); skipped = @(); monitoring = ''; rechecks = @(); replica = '' }
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
    foreach ($vm in @($byVm.Keys)) {
        if ((& $hasActivity $vm) -and (Get-DbHubVmState -Context $Context -VmName $vm) -ne 'running') {
            $accepted = Invoke-DbHubVmAction -Context $Context -VmName $vm -Action start
            if ($accepted -and $vm -eq $sqlVm) {
                $sqlStartedUtc = Get-DbHubUtcNow
            }
            if ($accepted) {
                & $progress 'vm-start' $vm
            }
        }
    }
    if ($null -ne $t4 -and $t4.State -eq 'Stopped') {
        # T4's read replica (ADR 0025): Azure starts T4 only once a stopped replica is Ready, so one a session left behind
        # starts first. The control never creates one: without it, the run says plainly that its replica beat isn't there.
        $replicaFirst = Invoke-DbHubT4ReplicaStartFirst -Context $Context -Tags $Tags -PollSeconds $PollSeconds
        $replicaNote = Get-DbHubT4ReplicaRunNote -Outcome $replicaFirst
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
    elseif ($null -ne $t4) {
        # A T4 that runs needs nothing first; without a replica, the run still says its replica beat isn't there.
        $replicaNow = Get-DbHubT4Replica -Context $Context -Tags $Tags
        $replicaNote = Get-DbHubT4ReplicaRunNote -Outcome ([pscustomobject]@{ Outcome = $(if ($replicaNow.State -eq 'Missing') { 'Missing' } else { '' }); Name = [string]$replicaNow.Name; State = [string]$replicaNow.State; Error = '' })
        if ($replicaNote) {
            $result.replica = $replicaNote
            Write-DbHubLog -Context $Context -Message $replicaNote
        }
    }
    if ($null -ne $t4 -and $t4.State -eq 'Stopped') {
        if (Invoke-DbHubT4Action -Context $Context -Name $t4.Name -Action start) {
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
        if (Send-DbHubDispatch -Context $Context -VmName $VmName -Activity $Chosen -Name $Name -RequestedBy $who) {
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
    if ($sent.Activities -eq 0) {
        $stopped = Stop-DbHubDemo -Context $Context -Tags $Tags
        $result.status = 'Failed'
        $result.message = 'No activity could be dispatched ({0}), so everything was stopped again: {1}.' -f ($skipped -join '; '), ((@($stopped.Done) + @($stopped.Failed)) -join ', ')
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
    $result.message = 'Dispatched {0}. The profiles end by {1} UTC and the auto-stop runs at {2}; each target is waited for until it accepts connections, and telemetry shows the activity 3 to 15 minutes later.{3}' -f ($dispatched -join '; '), $result.runEndUtc, $result.autoStopUtc, $note
    return [pscustomobject]$result
}

function Reset-DbHubActivity {
    # The reset action: the runner's reset on each requested target whose VM runs (T4 only when Ready). Nothing is
    # started.
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
# metrics into the vault for the history, then deletes the replica: a deleted server's metrics can't be read.

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
    return [pscustomobject]@{ Ok = ($put.StatusCode -in 200, 201); StatusCode = $put.StatusCode; Error = $put.Error }
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
    # step in plain words with its fix, the dispatches, T4, its read replica, and the replica-lag beat's windows.
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
    $names = [ordered]@{ resourceGroup = [string]$settings.demoResourceGroup; deploymentId = $deploymentId; sqlVm = [string]$settings.sqlVmName; hostVm = [string]$settings.hostVmName; t2Guest = [string](Get-DbHubMember -InputObject $settings -Name 't2GuestName'); t3Server = ''; t3Database = [string]$settings.demoDatabase; t4Server = ''; t4Replica = '' }
    if ($deploymentId) {
        $names['t3Server'] = '{0}{1}' -f $settings.t3ServerPrefix, $deploymentId
        $names['t4Server'] = '{0}{1}' -f $settings.t4ServerPrefix, $deploymentId
        $prefix = [string](Get-DbHubMember -InputObject $settings -Name 't4ReplicaPrefix')
        if ($prefix) {
            $names['t4Replica'] = '{0}{1}' -f $prefix, $deploymentId
        }
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
        monitoring        = ''
        t4                = [ordered]@{ state = ''; sku = ''; tier = ''; dispatchUtc = '' }
        replica           = [ordered]@{ state = ''; sizeAsked = ''; sizeUsed = ''; attempts = @(); readyUtc = ''; note = ''; fix = '' }
        replicaLag        = [ordered]@{ planned = $false; windows = @(); note = ''; fix = '' }
        message           = ''
    }
}

function Add-DbHubSessionStep {
    # One step of the session for the notebook: what (Plan, Busy, Start, Activity, T4, Replica, ReplicaLag, Stop, Capture),
    # its state (Pass, Warning, Fail, or Info), and the message and fix in plain words. The last 60 are kept.
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
        return (& $finish 'NotSetUp' 'T4''s read replica isn''t set up in this environment, which was deployed before the replica existed, so Database Hub''s Read replica lag stays empty and the replica-lag beat doesn''t run.' 'Run ./scripts/deploy.ps1: it adds the replica (about 9 minutes) and changes nothing else.')
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
    One Metrics - List read for one server: Name with one Aggregation, every IntervalMinutes over Timespan. Returns Series
    (Metric, Unit, Aggregation, and Points: UTC time to value, only the points that have one) and Error. Never throws.
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
        [ValidateSet('Maximum', 'Total', 'Average', 'Minimum')]
        [string] $Aggregation,

        [Parameter(Mandatory = $true)]
        [string] $Timespan,

        [int] $IntervalMinutes = 1
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
        $read = Invoke-DbHubArm -Context $Context -Method GET -Path $query -ApiVersion (Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Insights/metrics')
        if ($read.StatusCode -ne 200) {
            $why = $read.Error
            if (-not $why) {
                $why = 'HTTP {0}' -f $read.StatusCode
            }
            return [pscustomobject]@{ Series = $series.ToArray(); Error = $why }
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
        return [pscustomobject]@{ Series = $series.ToArray(); Error = (ConvertTo-DbHubSafeText -Text $_.Exception.Message) }
    }
    return [pscustomobject]@{ Series = $series.ToArray(); Error = '' }
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

function Save-DbHubSessionMetric {
    <#
    .SYNOPSIS
    The session's history metrics into the control vault (metricsName), for the control notebook to hand to
    NB_DatabaseHub_LiveActivity, which can't read Azure Monitor: from 10 minutes before the session's start (the group's
    DbHubSessionStartUtc, at most 6 hours back; 3 hours without one) to now. Returns Status (Pass, Warning, Skipped, or
    Failed), Message, Bytes, and Replica.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags,

        [AllowEmptyString()]
        [string] $SessionId = ''
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
    $document = Get-DbHubPostgresMetricDocument -Context $Context -Tags $Tags -StartUtc $from -EndUtc $now -SessionId $session
    if (-not $document.Json) {
        return [pscustomobject]@{ Status = $document.Status; Message = $document.Message; Bytes = 0; Replica = $false }
    }
    $name = [string](Get-DbHubMember -InputObject $Context.Settings -Name 'metricsName')
    if (-not $name) {
        $name = 'dbhub-session-metrics'
    }
    $replicaText = 'no'
    if ($document.Replica) {
        $replicaText = 'yes'
    }
    $written = Set-DbHubVaultSecret -Context $Context -Name $name -Value $document.Json -Tags @{ sessionId = $session; capturedUtc = (ConvertTo-DbHubTimeText -Value $now); replica = $replicaText }
    if (-not $written.Ok) {
        return [pscustomobject]@{ Status = 'Failed'; Message = ('The history''s metrics couldn''t be written to the control vault: {0}' -f $written.Error); Bytes = 0; Replica = $document.Replica }
    }
    Write-DbHubLog -Context $Context -Message $document.Message
    return [pscustomobject]@{ Status = $document.Status; Message = $document.Message; Bytes = $document.Bytes; Replica = $document.Replica }
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
       says so, with when it ends and why; one with less than minSessionMinutes left is refused.
    3. The busy marker (DbHubBusyUntilUtc, DbHubBusyBy session) until busyMarginMinutes after the auto-stop, with the
       session's ID and start (DbHubSessionId, DbHubSessionStartUtc): the nightly stop's passes and the control's T4 stop
       leave the session to its own auto-stop, which saves the metrics and deletes the replica.
    4. The run (Start-DbHubActivityRun) with this plan: the auto-stop and its second, then the starts and the dispatches.
       Once T4 is Ready, its read replica is asked for (Start-DbHubSessionReplica), and after the dispatches the job waits
       for it (Complete-DbHubSessionReplica).
    5. The replica-lag beat's windows from when T4's profile was set (Get-DbHubReplicaLagPlan), or why it won't run.
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
    $status['plannedMinutes'] = $planned
    if ($planned -lt [int]$Request.DurationMinutes - 1) {
        Add-DbHubSessionStep -Status $status -Step 'Plan' -State 'Warning' -Message ('This session runs {0} of the {1} minutes asked: it ends at {2}, before the VMs'' auto-shutdown at {3} ({4}), when the activity on the VMs ends.' -f $planned, $Request.DurationMinutes, (& $clock $plan.RunEndUtc), (& $clock $plan.ShutdownUtc), $settings.autoShutdownTimeZone) -Fix 'For a full session, Run all earlier, or change autoShutdownTime in config/demo.config.json and run ./scripts/deploy.ps1.'
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
        param([string] $Kind, [string] $Detail)
        $shared = $sessionShared
        switch ($Kind) {
            'autostop' { $shared.Status['autoStopUtc'] = $Detail }
            'backup' { $shared.Status['autoStopBackupUtc'] = $Detail }
            'vm-start' { Add-DbHubSessionStep -Status $shared.Status -Step 'Start' -State 'Info' -Message ('{0} is starting.' -f $Detail) }
            't4-start' { Add-DbHubSessionStep -Status $shared.Status -Step 'T4' -State 'Info' -Message ('T4 ({0}) is starting.' -f $Detail) }
            'dispatched' {
                Add-DbHubSessionStep -Status $shared.Status -Step 'Activity' -State 'Pass' -Message $Detail
                if ($Detail -like 'T4:*') {
                    $shared.Status['t4']['dispatchUtc'] = ConvertTo-DbHubTimeText -Value (Get-DbHubUtcNow)
                }
            }
            'skipped' { Add-DbHubSessionStep -Status $shared.Status -Step 'Activity' -State 'Warning' -Message $Detail }
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
    $run = Start-DbHubActivityRun -Context $Context -Request $Request -Tags $Tags -Plan $plan -OnProgress $onProgress -OnT4Ready $onT4Ready -WaitMinutes $WaitMinutes -T4WaitMinutes $T4WaitMinutes -PollSeconds $PollSeconds
    $result.runEndUtc = [string]$run.runEndUtc
    $result.autoStopUtc = [string]$run.autoStopUtc
    $result.dispatched = @($run.dispatched)
    $result.skipped = @($run.skipped)
    $status['runEndUtc'] = [string]$run.runEndUtc
    $status['dispatched'] = @($run.dispatched)
    $status['skipped'] = @($run.skipped)
    $status['monitoring'] = [string]$run.monitoring
    if ([string]$run.status -ne 'Dispatched') {
        # Refused (the auto-stop couldn't be created, or there was nothing to run) or Failed (nothing could be dispatched,
        # so the run stopped everything again). The group's tags were read before the marker was set, so it's cleared here.
        if ($marked.Ok) {
            $null = Set-DbHubResourceGroupTag -Context $Context -Tags @{ DbHubBusyUntilUtc = ''; DbHubBusyBy = '' }
        }
        Add-DbHubSessionStep -Status $status -Step 'Start' -State 'Fail' -Message ([string]$run.message) -Fix 'Run all again; ./scripts/status.ps1 shows what''s stopped or missing, and ./scripts/start-demo.ps1 starts the demo with more detail.'
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
    # The capture action (2026-11-14): T4's and its read replica's Azure Monitor metrics into the control vault, for the
    # history; nothing is started or stopped.
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
    $saved = Save-DbHubSessionMetric -Context $Context -Tags $Tags -SessionId ([string]$Request.SessionId)
    $state = 'Captured'
    if ($saved.Status -eq 'Warning') {
        $state = 'Partial'
    }
    elseif ($saved.Status -ne 'Pass') {
        $state = 'Failed'
    }
    return [pscustomobject]@{ action = 'capture'; status = $state; message = $saved.Message; sessionId = [string]$Request.SessionId; bytes = $saved.Bytes; replica = $saved.Replica }
}

function Write-DbHubStopStatus {
    # After Stop now or an auto-stop of a session (2026-11-14): the session's status says it stopped, what was done, and
    # what failed, for the control notebook. Only when a session is known (the request's or the group's DbHubSessionId).
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
    $status = [ordered]@{ schemaVersion = 1; sessionId = $session; phase = 'stopped'; updatedUtc = ''; stoppedBy = $By; jobId = [string]$Context.JobId; done = @($Stopped.Done); failed = @($Stopped.Failed); metrics = [ordered]@{ status = [string](Get-DbHubMember -InputObject $Stopped -Name 'MetricsStatus'); message = [string](Get-DbHubMember -InputObject $Stopped -Name 'MetricsMessage') } }
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
            NotGranted = 'the automation identity can''t read the demo resource group; after a redeploy, run setup-activity-control.ps1 -GrantRole (A1)'
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
        return [pscustomobject]@{ action = 'stop'; status = $status; message = ('Stop now: {0}{1}.' -f (@($stopped.Done) -join ', '), $failedText); done = $stopped.Done; failed = $stopped.Failed }
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
    safety stop): stops T4 only when it's running, because a stopped flexible server starts itself after 7 days. Scope
    Nightly (the nightly safety stop, ADR 0024): deallocates the VMs and stops T4 (Invoke-DbHubNightlyStop). Scope T3Check (its
    check, ADR 0024): reads T3's status and stops T4 when it runs (Invoke-DbHubT3Check). None of them starts anything.
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
        return [pscustomobject]@{ action = $label; status = $status; message = ('Nightly safety stop: {0}{1}.' -f (@($nightly.Done) -join ', '), $failedText); done = $nightly.Done; failed = $nightly.Failed; vms = $nightly.Vms; t4 = $nightly.T4; replica = $nightly.Replica }
    }
    if ($Scope -eq 'T4') {
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
            return [pscustomobject]@{ action = $label; status = $status; message = ('T4 ({0}) was {1}; its stop was {2}.{3}' -f $t4.Name, $t4.State, $outcome, $replicaSentence); replica = $replicaDone.Text }
        }
        $replicaDone = & $replicaPart ''
        if ($replicaDone.Text) {
            $status = if ($replicaDone.Failed) { 'Partial' } else { 'Stopped' }
            return [pscustomobject]@{ action = $label; status = $status; message = ('T4 is {0}. {1}.' -f $t4.State, $replicaDone.Text); replica = $replicaDone.Text }
        }
        return [pscustomobject]@{ action = $label; status = 'Skipped'; message = ('T4 is {0}; nothing to stop.' -f $t4.State) }
    }
    $stopped = Stop-DbHubDemo -Context $Context -Tags $group.Tags
    $status = 'Stopped'
    $failedText = ''
    if (@($stopped.Failed).Count -gt 0) {
        $status = 'Partial'
        $failedText = '; failed: ' + (@($stopped.Failed) -join ', ')
    }
    Write-DbHubStopStatus -Context $Context -Tags $group.Tags -Stopped $stopped -By 'Auto-stop'
    return [pscustomobject]@{ action = $label; status = $status; message = ('Auto-stop: {0}{1}.' -f (@($stopped.Done) -join ', '), $failedText); done = $stopped.Done; failed = $stopped.Failed }
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
    $vm = [string]$settings.sqlVmName
    $state = Get-DbHubVmState -Context $Context -VmName $vm
    if ($state -ne 'running') {
        Write-DbHubLog -Context $Context -Message ('Nothing to check: {0} is {1}.' -f $vm, $state)
        return [pscustomobject]@{ action = 'monitor'; status = 'Skipped'; monitoring = ''; message = ('Nothing was checked: {0} is {1}.' -f $vm, $state) }
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
    if ($outcome -in 'StillNotRunning', 'RestartRefused', 'Unread', 'Unfinished') {
        $status = 'Partial'
    }
    return [pscustomobject]@{ action = 'monitor'; status = $status; monitoring = $outcome; message = $texts[$outcome] }
}
