# Shared by the DbHub-Control, DbHub-Stop, and DbHub-Monitor runbooks (ADR 0020). scripts/setup-activity-control.ps1
# publishes each runbook with this file and the settings in place of its markers, so a published runbook is
# self-contained.
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
      time. scenario is "baseline", a catalog scenario that the target can run, a profile from the settings' profiles
      (showcase, 2026-11-04: its own rotation of incidents, from scenarios/activity-profiles.json), or "off", which turns
      the target's activity off (a run needs at least one activity that isn't off); intensity (1-10) and concurrency
      (1 to the scenario's maximum, incidents only) are optional, and a profile or off takes neither; durationMinutes
      is minDurationMinutes to maxDurationMinutes.
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
    $clean = $true
    $links = Invoke-DbHubArm -Context $Context -Method GET -Path ('{0}/jobSchedules' -f $account) -ApiVersion $version
    if ($links.StatusCode -eq 200) {
        foreach ($link in @(Get-DbHubMember -InputObject $links.Body -Name 'value')) {
            $properties = Get-DbHubMember -InputObject $link -Name 'properties'
            $scheduleName = [string](Get-DbHubMember -InputObject (Get-DbHubMember -InputObject $properties -Name 'schedule') -Name 'name')
            $id = [string](Get-DbHubMember -InputObject $properties -Name 'jobScheduleId')
            if (($scheduleName -ne [string]$settings.autoStopSchedule -and $scheduleName -notin $monitors) -or $id -notmatch '^[0-9a-fA-F-]{36}$') {
                continue
            }
            $removed = Invoke-DbHubArm -Context $Context -Method DELETE -Path ('{0}/jobSchedules/{1}' -f $account, $id) -ApiVersion $version
            if ($removed.StatusCode -notin 200, 204, 404) {
                if ($scheduleName -eq [string]$settings.autoStopSchedule) {
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
    Returns Done and Failed.
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

        [int] $PollSeconds = 20
    )

    $settings = $Context.Settings
    if (-not $PSCmdlet.ShouldProcess($settings.demoResourceGroup, 'Start an on-demand run')) {
        return [pscustomobject]@{ action = 'run'; status = 'Refused'; message = 'What if: nothing was started.'; runEndUtc = ''; autoStopUtc = ''; dispatched = @(); skipped = @(); monitoring = ''; rechecks = @() }
    }
    $result = [ordered]@{ action = 'run'; status = 'Refused'; message = ''; runEndUtc = ''; autoStopUtc = ''; dispatched = @(); skipped = @(); monitoring = ''; rechecks = @() }
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
                }
            }
        }
        else {
            foreach ($item in $Chosen) {
                $skipped.Add(('{0} (the Run Command on {1} wasn''t accepted)' -f $item.Target, $VmName))
            }
        }
    }

    $started = Get-DbHubUtcNow
    $vmDeadline = $started.AddMinutes($WaitMinutes)
    $t4Deadline = $started.AddMinutes($T4WaitMinutes)
    # A last bound on the whole loop, past every wait's own.
    $giveUp = $started.AddMinutes([System.Math]::Max($WaitMinutes, $T4WaitMinutes) + 15)
    while ($true) {
        $now = Get-DbHubUtcNow
        $t4State = ''
        if ($t4Pending) {
            $t4State = [string](Get-DbHubT4 -Context $Context -Tags $Tags).State
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
