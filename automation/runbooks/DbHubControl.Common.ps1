# Shared by the DbHub-Control and DbHub-Stop runbooks (ADR 0020). scripts/setup-activity-control.ps1 publishes each
# runbook with this file and the settings in place of its markers, so a published runbook is self-contained.
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
    foreach ($name in 'demoResourceGroup', 'controlResourceGroup', 'automationAccount', 'sqlVmName', 'hostVmName', 'controlRunbook', 'stopRunbook', 'autoStopSchedule', 'runCommandPrefix', 'location') {
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
        [ValidateSet('GET', 'PUT', 'POST', 'DELETE')]
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

    return [pscustomobject]@{ Valid = $false; Reason = $Reason; Action = ''; Activities = @(); DurationMinutes = 0; Targets = @(); RequestedBy = '' }
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
      time. scenario is "baseline" or a catalog scenario that the target can run; intensity (1-10) and concurrency
      (1 to the scenario's maximum, incidents only) are optional; durationMinutes is minDurationMinutes to
      maxDurationMinutes.
    - {"action": "stop"}: Stop now.
    - {"action": "reset", "targets": ["T1"]}: the runner's reset; without targets, every target whose VM runs.
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
    if (-not ($action -is [string]) -or $action -cnotin @('run', 'stop', 'reset')) {
        return (Get-DbHubRefusal -Reason 'action must be run, stop, or reset.')
    }
    $allowedFields = @{ run = @('action', 'activities', 'durationMinutes', 'requestedBy'); stop = @('action', 'requestedBy'); reset = @('action', 'targets', 'requestedBy') }
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
    $targets = @($Settings.targets.PSObject.Properties | ForEach-Object { [string]$_.Name })

    if ($action -eq 'stop') {
        return [pscustomobject]@{ Valid = $true; Reason = ''; Action = 'stop'; Activities = @(); DurationMinutes = 0; Targets = @(); RequestedBy = $requestedBy }
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
        return [pscustomobject]@{ Valid = $true; Reason = ''; Action = 'reset'; Activities = @(); DurationMinutes = 0; Targets = $chosen; RequestedBy = $requestedBy }
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
            return (Get-DbHubRefusal -Reason 'Each activity needs a scenario: baseline or a scenario from the catalog.')
        }
        $maximumConcurrency = 0
        if ($scenario -cne 'baseline') {
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
        if ($null -ne $intensity -and -not (Test-DbHubInteger -Value $intensity -Minimum 1 -Maximum 10)) {
            return (Get-DbHubRefusal -Reason 'intensity must be a whole number from 1 to 10.')
        }
        $concurrency = Get-DbHubMember -InputObject $activity -Name 'concurrency'
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
    return [pscustomobject]@{ Valid = $true; Reason = ''; Action = 'run'; Activities = $normalized; DurationMinutes = [int]$duration; Targets = @($seen); RequestedBy = $requestedBy }
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
    baseline) and so that it ends before the VMs' next auto-shutdown minus shutdownMarginMinutes. Returns Valid,
    Reason, Activities (with Minutes), RunEndUtc, AutoStopUtc (the run's end plus autoStopBufferMinutes), and
    ShutdownUtc.
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
    $planned = @()
    $longest = 0
    foreach ($activity in @($Request.Activities)) {
        $cap = [int]$Settings.maxDurationMinutes
        if ($activity.Scenario -cne 'baseline') {
            $cap = [int](Get-DbHubMember -InputObject $Settings.scenarios -Name $activity.Scenario).maxMinutes
        }
        $minutes = [System.Math]::Min([System.Math]::Min([int]$Request.DurationMinutes, $cap), $available)
        if ($minutes -gt $longest) {
            $longest = $minutes
        }
        $planned += [pscustomobject]@{ Target = $activity.Target; Scenario = $activity.Scenario; Intensity = $activity.Intensity; Concurrency = $activity.Concurrency; Minutes = $minutes }
    }
    $end = $NowUtc.AddMinutes($longest)
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
    # Parses an ISO 8601 time from Azure; $null when it doesn't parse.
    param(
        [AllowNull()]
        [object] $Value
    )

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
    $schedule = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/schedules/{1}' -f $account, $settings.autoStopSchedule) -ApiVersion $version
    if ($schedule.StatusCode -eq 404) {
        return [pscustomobject]@{ Active = $false; Reason = ''; RunEndUtc = $null }
    }
    if ($schedule.StatusCode -ne 200) {
        return [pscustomobject]@{ Active = $true; Reason = ('The auto-stop schedule couldn''t be read ({0}), so nothing was started.' -f $schedule.Error); RunEndUtc = $null }
    }
    $start = ConvertTo-DbHubUtc -Value (Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $schedule.Body -Name 'properties') -Name 'startTime')
    if ($null -ne $start) {
        $runEnd = $start.AddMinutes(-1 * [int]$settings.autoStopBufferMinutes)
        if ($runEnd -gt $Context.NowUtc) {
            return [pscustomobject]@{ Active = $true; Reason = ('A run is active until {0:yyyy-MM-dd HH:mm} UTC; use Stop now first, or wait for it to end.' -f $runEnd); RunEndUtc = $runEnd }
        }
    }
    return [pscustomobject]@{ Active = $false; Reason = ''; RunEndUtc = $null }
}

function Clear-DbHubAutoStop {
    # Deletes the one-time auto-stop schedule and the job schedules that link it to DbHub-Stop. Returns $true when
    # nothing is left.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    $settings = $Context.Settings
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Automation/automationAccounts'
    $account = Get-DbHubAccountPath -Settings $settings
    $clean = $true
    $links = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/jobSchedules' -f $account) -ApiVersion $version
    if ($links.StatusCode -eq 200) {
        foreach ($link in @(Get-DbHubMember -InputObject $links.Body -Name 'value')) {
            $properties = Get-DbHubMember -InputObject $link -Name 'properties'
            $scheduleName = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $properties -Name 'schedule') -Name 'name')
            $id = [string](Get-DbHubMember -InputObject $properties -Name 'jobScheduleId')
            if ($scheduleName -ne [string]$settings.autoStopSchedule -or $id -notmatch '^[0-9a-fA-F-]{36}$') {
                continue
            }
            $removed = Invoke-DbHubArm -Context $Context -Method DELETE -Path ('{0}/jobSchedules/{1}' -f $account, $id) -ApiVersion $version
            if ($removed.StatusCode -notin 200, 204, 404) {
                $clean = $false
                Write-DbHubLog -Context $Context -Message ('The auto-stop link {0} couldn''t be deleted: {1}' -f $id, $removed.Error)
            }
        }
    }
    elseif ($links.StatusCode -ne 404) {
        $clean = $false
        Write-DbHubLog -Context $Context -Message ('The job schedules couldn''t be read: {0}' -f $links.Error)
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
        return [pscustomobject]@{ Created = $false; Error = 'the previous auto-stop couldn''t be removed'; StartUtc = '' }
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
        return [pscustomobject]@{ Created = $false; Error = $schedule.Error; StartUtc = '' }
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
        return [pscustomobject]@{ Created = $false; Error = $linked.Error; StartUtc = '' }
    }
    return [pscustomobject]@{ Created = $true; Error = ''; StartUtc = $start }
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
    # T4, the PostgreSQL flexible server <t4ServerPrefix><deploymentId> (Phase 24): Name and State (Ready, Stopped,
    # Starting, Stopping, Updating, ...), or State Missing or Unknown.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $deploymentId = [string](Get-DbHubMember -InputObject $Tags -Name 'deploymentId')
    if ($deploymentId -notmatch '^[a-z0-9]{6}$') {
        return [pscustomobject]@{ Name = ''; State = 'Unknown' }
    }
    $name = '{0}{1}' -f $Context.Settings.t4ServerPrefix, $deploymentId
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

function Wait-DbHubReady {
    # Polls until each VM runs and T4 (when given) is Ready, at most MaxMinutes. Returns the VM names that run and
    # whether T4 is Ready.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [string[]] $VmName = @(),

        [AllowNull()]
        [object] $Tags,

        [switch] $T4,

        [int] $MaxMinutes = 15,

        [int] $PollSeconds = 20
    )

    $deadline = [DateTime]::UtcNow.AddMinutes($MaxMinutes)
    while ($true) {
        $running = @($VmName | Where-Object { (Get-DbHubVmState -Context $Context -VmName $_) -eq 'running' })
        $t4Ready = $false
        if ($T4) {
            $t4Ready = (Get-DbHubT4 -Context $Context -Tags $Tags).State -eq 'Ready'
        }
        if (($running.Count -eq @($VmName).Count -and ($t4Ready -or -not $T4)) -or [DateTime]::UtcNow -ge $deadline) {
            return [pscustomobject]@{ Running = $running; T4Ready = $t4Ready }
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-DbHubRunnerArgument {
    # The runner arguments for one planned activity, built from validated values only, or for a reset.
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
    because a host that was just started runs its guest a few minutes later. Each request is Base64 JSON, checked
    before it goes between single quotes.
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
    # waiting for the deletes.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [string] $VmName,

        [string[]] $Keep = @()
    )

    $version = Get-DbHubApiVersion -Settings $Context.Settings -Type 'Microsoft.Compute/virtualMachines/runCommands'
    $base = '{0}/providers/Microsoft.Compute/virtualMachines/{1}/runCommands' -f (Get-DbHubDemoPath -Settings $Context.Settings), $VmName
    $list = Invoke-DbHubArm -Context $Context -Method GET -Path $base -ApiVersion $version
    if ($list.StatusCode -ne 200) {
        return
    }
    foreach ($item in @(Get-DbHubMember -InputObject $list.Body -Name 'value')) {
        $name = [string](Get-DbHubMember -InputObject $item -Name 'name')
        if (-not $name.StartsWith([string]$Context.Settings.runCommandPrefix, [System.StringComparison]::Ordinal) -or $name -in $Keep -or $name -notmatch '^[A-Za-z0-9-]{1,64}$') {
            continue
        }
        $null = Invoke-DbHubArm -Context $Context -Method DELETE -Path ('{0}/{1}' -f $base, $name) -ApiVersion $version
    }
}

function Test-DbHubMonitoringPlugin {
    # Whether T1's Database Hub monitoring plugin needs its service restarted: the SQL IaaS Agent extension's instance
    # view reports the plugin and it isn't Running (Phase 22: NotRunning for 90 minutes after a start), as start-demo.ps1
    # checks it.
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    $settings = $Context.Settings
    $version = Get-DbHubApiVersion -Settings $settings -Type 'Microsoft.Compute/virtualMachines'
    $read = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/providers/Microsoft.Compute/virtualMachines/{1}/extensions/{2}?$expand=instanceView' -f (Get-DbHubDemoPath -Settings $settings), $settings.sqlVmName, $settings.monitoring.extensionInstanceName) -ApiVersion $version
    if ($read.StatusCode -ne 200) {
        return $false
    }
    $view = Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $read.Body -Name 'properties') -Name 'instanceView'
    $pattern = [regex]::Escape([string]$settings.monitoring.statusPlugin) + '\s*:\s*\{[^{}]*"State"\s*:\s*"([A-Za-z]+)"'
    foreach ($listName in 'statuses', 'substatuses') {
        foreach ($status in @(Get-DbHubMember -InputObject $view -Name $listName)) {
            $match = [regex]::Match([string](Get-DbHubMember -InputObject $status -Name 'message'), $pattern)
            if ($match.Success) {
                return ($match.Groups[1].Value -ne 'Running')
            }
        }
    }
    return $false
}

function Stop-DbHubDemo {
    <#
    .SYNOPSIS
    Stop now, and what the auto-stop does: removes the auto-stop schedule, deallocates both VMs, and stops T4, through
    Azure Resource Manager only and without waiting. Never Run Command (Phase 25a, finding 5): deallocation ends every
    session on T1 and T2 (the T2 guest shuts down through the host's automatic stop action, ShutDown), T3's sessions
    end with T1's runner, and T3 auto-pauses after its delay. The activity profiles end at their own end; the profile
    host ends what a stopped run left behind when it starts again. Returns Done and Failed.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [AllowNull()]
        [object] $Tags
    )

    $settings = $Context.Settings
    if (-not $PSCmdlet.ShouldProcess($settings.demoResourceGroup, 'Deallocate the VMs and stop T4')) {
        return [pscustomobject]@{ Done = @(); Failed = @() }
    }
    $done = New-Object -TypeName 'System.Collections.Generic.List[string]'
    $failed = New-Object -TypeName 'System.Collections.Generic.List[string]'
    if (Clear-DbHubAutoStop -Context $Context) {
        $done.Add('auto-stop removed')
    }
    else {
        $failed.Add('auto-stop schedule')
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
    $t4 = Get-DbHubT4 -Context $Context -Tags $Tags
    if ($t4.State -in 'Ready', 'Starting', 'Updating') {
        if (Invoke-DbHubT4Action -Context $Context -Name $t4.Name -Action stop) {
            $done.Add(('{0} stopping' -f $t4.Name))
        }
        else {
            $failed.Add($t4.Name)
        }
    }
    elseif ($t4.State -notin 'Unknown', '') {
        $done.Add(('T4 {0}' -f $t4.State.ToLowerInvariant()))
    }
    return [pscustomobject]@{ Done = $done.ToArray(); Failed = $failed.ToArray() }
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
    The run action: refuses while a run is active, plans the durations, creates the auto-stop before anything starts,
    starts what's stopped (the VMs, and T4; T3 resumes when the runner connects), restarts T1's monitoring plugin when
    it isn't running, and dispatches each target's activity profile through one asynchronous managed Run Command per
    VM, then exits. If nothing could be dispatched, it stops everything again at once.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object] $Context,

        [Parameter(Mandatory = $true)]
        [object] $Request,

        [AllowNull()]
        [object] $Tags,

        [int] $WaitMinutes = 15
    )

    $settings = $Context.Settings
    if (-not $PSCmdlet.ShouldProcess($settings.demoResourceGroup, 'Start an on-demand run')) {
        return [pscustomobject]@{ action = 'run'; status = 'Refused'; message = 'What if: nothing was started.'; runEndUtc = ''; autoStopUtc = ''; dispatched = @(); skipped = @() }
    }
    $result = [ordered]@{ action = 'run'; status = 'Refused'; message = ''; runEndUtc = ''; autoStopUtc = ''; dispatched = @(); skipped = @() }
    $active = Get-DbHubActiveRun -Context $Context
    if ($active.Active) {
        $result.message = $active.Reason
        return [pscustomobject]$result
    }
    $plan = Get-DbHubRunPlan -Request $Request -Settings $settings -NowUtc $Context.NowUtc
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
    if (@($activities | Where-Object { $_.Target -eq 'T4' }).Count -gt 0) {
        $t4 = Get-DbHubT4 -Context $Context -Tags $Tags
        # Missing, Unknown, or a state it can't be started from now, such as Stopping right after a stop.
        if ($t4.State -notin 'Ready', 'Starting', 'Updating', 'Stopped') {
            $skipped.Add(('T4 ({0})' -f $t4.State.ToLowerInvariant()))
            $activities = @($activities | Where-Object { $_.Target -ne 'T4' })
            $t4 = $null
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
    foreach ($vm in @($byVm.Keys)) {
        if ((Get-DbHubVmState -Context $Context -VmName $vm) -eq 'Missing') {
            foreach ($activity in $byVm[$vm]) {
                $skipped.Add(('{0} ({1} doesn''t exist)' -f $activity.Target, $vm))
            }
            $byVm.Remove($vm)
        }
    }
    if (@($byVm.Keys).Count -eq 0) {
        $result.message = 'Nothing to run: ' + ($skipped -join '; ')
        $result.skipped = $skipped.ToArray()
        return [pscustomobject]$result
    }

    $stop = Register-DbHubAutoStop -Context $Context -AutoStopUtc $plan.AutoStopUtc
    if (-not $stop.Created) {
        $result.message = 'The auto-stop schedule couldn''t be created ({0}), so nothing was started.' -f $stop.Error
        return [pscustomobject]$result
    }
    $result.runEndUtc = $plan.RunEndUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    $result.autoStopUtc = $stop.StartUtc
    Write-DbHubLog -Context $Context -Message ('Auto-stop set for {0}; the run ends by {1}.' -f $stop.StartUtc, $result.runEndUtc)

    foreach ($vm in @($byVm.Keys)) {
        if ((Get-DbHubVmState -Context $Context -VmName $vm) -ne 'running') {
            $null = Invoke-DbHubVmAction -Context $Context -VmName $vm -Action start
        }
    }
    if ($null -ne $t4 -and $t4.State -eq 'Stopped' -and -not (Invoke-DbHubT4Action -Context $Context -Name $t4.Name -Action start)) {
        # Don't wait for a start Azure refused (Phase 25d live: the wait for T4 took the run's whole 15 minutes).
        $skipped.Add(('T4 ({0} didn''t accept the start)' -f $t4.Name))
        foreach ($vm in @($byVm.Keys)) {
            $byVm[$vm] = @($byVm[$vm] | Where-Object { $_.Target -ne 'T4' })
        }
        $t4 = $null
    }
    $ready = Wait-DbHubReady -Context $Context -VmName @($byVm.Keys) -Tags $Tags -T4:($null -ne $t4) -MaxMinutes $WaitMinutes

    $stamp = $Context.NowUtc.ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $who = Get-DbHubRequester -Context $Context -RequestedBy $Request.RequestedBy
    $dispatched = New-Object -TypeName 'System.Collections.Generic.List[string]'
    foreach ($vm in @($byVm.Keys)) {
        if ($vm -notin @($ready.Running)) {
            foreach ($activity in $byVm[$vm]) {
                $skipped.Add(('{0} ({1} isn''t running yet)' -f $activity.Target, $vm))
            }
            continue
        }
        $chosen = @($byVm[$vm] | Where-Object { $_.Target -ne 'T4' -or $ready.T4Ready })
        foreach ($activity in @($byVm[$vm] | Where-Object { $_.Target -eq 'T4' -and -not $ready.T4Ready })) {
            $skipped.Add(('{0} ({1} isn''t Ready yet)' -f $activity.Target, $t4.Name))
        }
        if ($chosen.Count -eq 0) {
            continue
        }
        if ($vm -eq [string]$settings.sqlVmName -and (Test-DbHubMonitoringPlugin -Context $Context)) {
            $restart = "`$ErrorActionPreference = 'Stop'`nRestart-Service -Name '{0}' -Force`n" -f [string]$settings.monitoring.serviceName
            $null = Send-DbHubRunCommand -Context $Context -VmName $vm -Name ('{0}monitoring-{1}' -f $settings.runCommandPrefix, $stamp) -Script $restart -TimeoutSeconds 300
        }
        $requests = @()
        foreach ($activity in $chosen) {
            $requests += [ordered]@{ target = $activity.Target; arguments = @(Get-DbHubRunnerArgument -Activity $activity -RequestedBy $who); timeoutSeconds = 600 }
        }
        $name = '{0}{1}-{2}' -f $settings.runCommandPrefix, $vm, $stamp
        $timeout = 900
        if ($vm -eq [string]$settings.hostVmName) {
            $timeout = 1500
        }
        Clear-DbHubOldRunCommand -Context $Context -VmName $vm -Keep @($name, ('{0}monitoring-{1}' -f $settings.runCommandPrefix, $stamp))
        if (Send-DbHubRunCommand -Context $Context -VmName $vm -Name $name -Script (Get-DbHubWorkloadScript -Settings $settings -Request $requests) -TimeoutSeconds $timeout) {
            foreach ($activity in $chosen) {
                $dispatched.Add(('{0}: {1} for {2} minutes' -f $activity.Target, $activity.Scenario, $activity.Minutes))
            }
        }
        else {
            foreach ($activity in $chosen) {
                $skipped.Add(('{0} (the Run Command on {1} wasn''t accepted)' -f $activity.Target, $vm))
            }
        }
    }
    $result.dispatched = $dispatched.ToArray()
    $result.skipped = $skipped.ToArray()
    if ($dispatched.Count -eq 0) {
        $stopped = Stop-DbHubDemo -Context $Context -Tags $Tags
        $result.status = 'Failed'
        $result.message = 'Nothing could be dispatched ({0}), so everything was stopped again: {1}.' -f ($skipped -join '; '), ((@($stopped.Done) + @($stopped.Failed)) -join ', ')
        return [pscustomobject]$result
    }
    $result.status = 'Dispatched'
    $note = ''
    if ($skipped.Count -gt 0) {
        $note = ' Skipped: ' + ($skipped -join '; ') + '.'
    }
    $result.message = 'Dispatched {0}. The profiles end by {1} UTC and the auto-stop runs at {2}; telemetry shows the activity 3 to 15 minutes later.{3}' -f ($dispatched -join '; '), $result.runEndUtc, $result.autoStopUtc, $note
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

function Invoke-DbHubControl {
    <#
    .SYNOPSIS
    DbHub-Control's entry point: validates the webhook request, checks that the demo environment exists and that the
    identity can read it (A1), then runs, stops, or resets. A bad request is refused, never thrown.
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
        $stopped = Stop-DbHubDemo -Context $Context -Tags $group.Tags
        $status = 'Stopped'
        $failedText = ''
        if (@($stopped.Failed).Count -gt 0) {
            $status = 'Partial'
            $failedText = '; failed: ' + (@($stopped.Failed) -join ', ')
        }
        return [pscustomobject]@{ action = 'stop'; status = $status; message = ('Stop now: {0}{1}.' -f (@($stopped.Done) -join ', '), $failedText); done = $stopped.Done; failed = $stopped.Failed }
    }
    if ($request.Action -eq 'reset') {
        return (Reset-DbHubActivity -Context $Context -Request $request -Tags $group.Tags)
    }
    return (Start-DbHubActivityRun -Context $Context -Request $request -Tags $group.Tags)
}

function Invoke-DbHubStop {
    <#
    .SYNOPSIS
    DbHub-Stop's entry point. Scope All (the per-run auto-stop): what Stop now does. Scope T4 (the daily safety stop):
    stops T4 only when it's running, because a stopped flexible server starts itself after 7 days; it never starts
    anything.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('All', 'T4')]
        [string] $Scope,

        [Parameter(Mandatory = $true)]
        [object] $Context
    )

    $label = 'stop-' + $Scope.ToLowerInvariant()
    $group = Get-DbHubResourceGroupTag -Context $Context
    if ($group.GroupState -ne 'Present') {
        if ($Scope -eq 'All') {
            $null = Clear-DbHubAutoStop -Context $Context
        }
        Write-DbHubLog -Context $Context -Message ('Nothing to stop: the demo resource group is {0}.' -f $group.GroupState)
        return [pscustomobject]@{ action = $label; status = 'NoEnvironment'; message = ('The demo resource group is {0}; nothing was stopped.' -f $group.GroupState) }
    }
    if ($Scope -eq 'T4') {
        $t4 = Get-DbHubT4 -Context $Context -Tags $group.Tags
        if ($t4.State -in 'Ready', 'Starting', 'Updating') {
            $sent = Invoke-DbHubT4Action -Context $Context -Name $t4.Name -Action stop
            $status = 'Partial'
            $outcome = 'failed'
            if ($sent) {
                $status = 'Stopped'
                $outcome = 'accepted'
            }
            return [pscustomobject]@{ action = $label; status = $status; message = ('T4 ({0}) was {1}; its stop was {2}.' -f $t4.Name, $t4.State, $outcome) }
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
    return [pscustomobject]@{ action = $label; status = $status; message = ('Auto-stop: {0}{1}.' -f (@($stopped.Done) -join ', '), $failedText); done = $stopped.Done; failed = $stopped.Failed }
}
