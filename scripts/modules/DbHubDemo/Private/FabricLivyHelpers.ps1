# Fabric's Livy API (F35, 2026-11-23): a Spark session in the demo's lakehouse that runs the repository's own code as
# statements, then is deleted, so a workspace that keeps older notebooks still gets this checkout's code. Internal; tests
# mock Invoke-WebRequest and Start-Sleep. Every request goes through Invoke-DemoFabricRequest, so the token stays a
# SecureString, goes only to the Fabric API, and is renewed and retried as for every other Fabric call.
# The Azure CLI's Fabric token (scope user_impersonation) is accepted: a session started, ran PySpark, and read the
# lakehouse's tables in the live probe (2026-11-23, tests/integration/Invoke-LivyTokenProbe.ps1), although Learn documents
# the API for a Microsoft Entra app or a service principal with the Lakehouse.* and Code.* scopes. The caller needs
# Contributor or higher on the workspace.
# Sources (checked 2026-11-23):
# - Livy API overview: https://learn.microsoft.com/fabric/data-engineering/api-livy-overview
# - Authentication, the endpoint, and the workspace role: https://learn.microsoft.com/fabric/data-engineering/get-started-api-livy
# - Session jobs (create, statements, delete; the starter pool; the end after 20 minutes idle):
#   https://learn.microsoft.com/fabric/data-engineering/get-started-api-livy-session
# - The Livy API's Swagger (session and statement states, a statement's output, cancel), linked from the page above:
#   https://github.com/microsoft/fabric-samples/blob/main/docs-samples/data-engineering/Livy-API-swagger/swagger.json

$script:LivyApiVersion = '2023-12-01'
$script:LivySessionDoc = 'https://learn.microsoft.com/fabric/data-engineering/get-started-api-livy-session'
# The session states after which a session never becomes idle (the Swagger's SessionResponse.state).
$script:LivySessionEnded = @('dead', 'killed', 'error', 'success', 'shutting_down')

function Get-DemoLivySessionsUri {
    # The Livy API's sessions URI for one lakehouse, by Learn's endpoint pattern. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $LakehouseId
    )

    return ('{0}/workspaces/{1}/lakehouses/{2}/livyapi/versions/{3}/sessions' -f $script:FabricApiBaseUri, $WorkspaceId, $LakehouseId, $script:LivyApiVersion)
}

function Get-DemoLivyFailureKind {
    # Why a Livy request failed, from its status and Fabric's error text: CapacityInactive (the workspace's capacity is paused
    # or inactive), Refused (HTTP 401 or 403: the token, the workspace role, or the tenant setting), or Failed. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int] $StatusCode,

        [AllowEmptyString()]
        [string] $ErrorText = ''
    )

    if (Test-DemoFabricCapacityInactiveText -Text $ErrorText) {
        return 'CapacityInactive'
    }
    if ($StatusCode -in 401, 403) {
        return 'Refused'
    }
    return 'Failed'
}

function Open-DemoLivySession {
    <#
    .SYNOPSIS
    Starts a Livy session in a lakehouse, on the workspace's starter pool, and waits until it's idle. Internal.

    .DESCRIPTION
    Create Livy Session (POST .../livyapi/versions/2023-12-01/sessions, with -Name), then Get Livy Session every
    -PollSeconds until the session is idle, at most -TimeoutSeconds. The create is sent once (-NotIdempotent): a second
    would start a second session. Returns Status, Session (Uri, Id, Name, and the token, for Invoke-DemoLivyStatement and
    Close-DemoLivySession; only when Status is Idle), StatusCode, Error (Fabric's, redacted), States (each state the
    session went through, with Fabric's acquisition state in brackets, such as "not_started (acquiringSession)"), and
    Seconds:
    - Idle: ready for statements. Live, 2026-11-23: about 14 seconds on an F4 that wasn't busy.
    - Refused: HTTP 401 or 403, from the token, the workspace role (Contributor or higher), or the tenant setting that
      allows the Livy API.
    - CapacityInactive: the workspace's capacity is paused or inactive.
    - Ended: the session ended before it was idle (dead, killed, error, or Fabric's acquisition failed); Error says why.
    - TimedOut: not idle after -TimeoutSeconds; a busy capacity queues a session (acquisition state queued).
    - Failed: any other answer.
    A session that was created but isn't idle is deleted before the function returns or throws (a network error past the
    retries, or a stop of the run, included), so a caller closes only an Idle one. -TimeoutSeconds counts on the module's
    clock (Get-DemoUtcNow), and on the polls' sleeps, whichever reaches it first.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $LakehouseId,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [ValidatePattern('^[A-Za-z0-9_.-]{1,64}$')]
        [string] $Name = 'dbhub-livy',

        [ValidateRange(10, 3600)]
        [int] $TimeoutSeconds = 600,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 5
    )

    $sessionsUri = Get-DemoLivySessionsUri -WorkspaceId $WorkspaceId -LakehouseId $LakehouseId
    $started = Get-DemoUtcNow
    $elapsed = { ((Get-DemoUtcNow) - $started).TotalSeconds }
    $states = [System.Collections.Generic.List[string]]::new()
    $answer = {
        param([string] $Status, [int] $StatusCode, [string] $Text = '', [object] $Session = $null)
        [pscustomobject]@{ Status = $Status; Session = $Session; StatusCode = $StatusCode; Error = $Text; States = $states.ToArray(); Seconds = [int](& $elapsed) }
    }

    $create = Invoke-DemoFabricRequest -Method Post -Uri $sessionsUri -Token $Token -Body ([ordered]@{ name = $Name }) -NotIdempotent
    if ($create.StatusCode -notin 200, 201, 202) {
        $text = Get-DemoFabricErrorText -Response $create
        return (& $answer (Get-DemoLivyFailureKind -StatusCode $create.StatusCode -ErrorText $text) ([int]$create.StatusCode) $text)
    }
    $id = [string](Get-DemoMemberValue -InputObject $create.Body -Name 'id')
    if ($id -notmatch '^[A-Za-z0-9-]{1,64}$') {
        return (& $answer 'Failed' ([int]$create.StatusCode) 'Fabric accepted the session, but its answer had no session ID.')
    }
    $session = [pscustomobject]@{ Uri = ('{0}/{1}' -f $sessionsUri, $id); Id = $id; Name = $Name; Token = $Token }

    $outcome = $null
    $idle = $false
    # The wait counts the polls' sleeps, or the clock when requests are slow, whichever reaches -TimeoutSeconds first.
    $waited = 0
    try {
        while ($true) {
            $read = Invoke-DemoFabricRequest -Method Get -Uri $session.Uri -Token $Token
            if ($read.StatusCode -ne 200) {
                $text = Get-DemoFabricErrorText -Response $read
                $outcome = & $answer (Get-DemoLivyFailureKind -StatusCode $read.StatusCode -ErrorText $text) ([int]$read.StatusCode) $text
                break
            }
            $state = [string](Get-DemoMemberValue -InputObject $read.Body -Name 'state')
            $fabricState = Get-DemoMemberValue -InputObject $read.Body -Name 'fabricSessionStateInfo'
            $acquisition = [string](Get-DemoMemberValue -InputObject $fabricState -Name 'state')
            $seen = if ($acquisition) { '{0} ({1})' -f $state, $acquisition } else { $state }
            if ($states.Count -eq 0 -or $states[$states.Count - 1] -ne $seen) {
                $states.Add($seen)
            }
            if ($state -eq 'idle') {
                $idle = $true
                return (& $answer 'Idle' 200 '' $session)
            }
            # Why it ended: Fabric's acquisition error, or the first of its error details, or its cancellation's reason.
            $why = [string](Get-DemoMemberValue -InputObject $fabricState -Name 'errorMessage')
            $details = Get-DemoMemberValue -InputObject $read.Body -Name 'errorInfo'
            if (-not $why -and $null -ne $details -and @($details).Count -gt 0) {
                $first = @($details)[0]
                $why = ('{0} {1}' -f (Get-DemoMemberValue -InputObject $first -Name 'errorCode'), (Get-DemoMemberValue -InputObject $first -Name 'message')).Trim()
            }
            if (-not $why) {
                $why = [string](Get-DemoMemberValue -InputObject $read.Body -Name 'cancellationReason')
            }
            # not_submitted with an error is a submission that failed; without one, the session may still be submitted.
            if ($state -in $script:LivySessionEnded -or $acquisition -in 'error', 'cancelled' -or ($state -eq 'not_submitted' -and $why)) {
                $text = Protect-DemoText -Text ('the session is {0}{1}' -f $seen, $(if ($why) { ': ' + $why } else { '' }))
                $outcome = & $answer $(if (Test-DemoFabricCapacityInactiveText -Text $why) { 'CapacityInactive' } else { 'Ended' }) 200 $text
                break
            }
            if ($waited -ge $TimeoutSeconds -or (& $elapsed) -ge $TimeoutSeconds) {
                $outcome = & $answer 'TimedOut' 200 ('the session was still {0} after {1} minutes' -f $seen, [int][System.Math]::Ceiling($TimeoutSeconds / 60.0))
                break
            }
            Start-Sleep -Seconds $PollSeconds
            $waited += $PollSeconds
        }
    }
    finally {
        # Not idle, a wait that threw included: the session it created goes now, rather than when Fabric ends it after 20
        # minutes idle (the review of c96f790a).
        if (-not $idle) {
            $null = Close-DemoLivySession -Session $session
        }
    }
    return $outcome
}

function Invoke-DemoLivyStatement {
    <#
    .SYNOPSIS
    Runs one statement in an idle Livy session and waits for its output. Internal.

    .DESCRIPTION
    Submit Statement (POST .../sessions/{id}/statements with code and kind; sent once, -NotIdempotent), then Get Statement
    every -PollSeconds until it's available, at most -TimeoutSeconds; one still running then is cancelled (POST
    .../statements/{id}/cancel). Returns Status, Output (what it printed, its text/plain output, whole and redacted; other
    output as JSON), ErrorName and ErrorValue (the exception, for Error; the reason, for Failed), StatusCode, StatementId,
    and Seconds:
    - Ok: it ran.
    - Error: it raised (the output's status is error, or the statement's state is Error).
    - Cancelled: Fabric cancelled it.
    - TimedOut: it was still running after -TimeoutSeconds, so it was cancelled.
    - Failed: the submit or a read failed (StatusCode, after Invoke-DemoFabricRequest's retries): an HTTP answer, never
      the code's own error.
    -TimeoutSeconds counts on the module's clock (Get-DemoUtcNow), and on the polls' sleeps, whichever reaches it first.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Code,

        [ValidateSet('pyspark', 'spark', 'sql')]
        [string] $Kind = 'pyspark',

        [ValidateRange(10, 14400)]
        [int] $TimeoutSeconds = 900,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 3
    )

    $started = Get-DemoUtcNow
    $elapsed = { ((Get-DemoUtcNow) - $started).TotalSeconds }
    $statementId = ''
    $answer = {
        param([string] $Status, [int] $StatusCode, [string] $Output = '', [string] $ErrorName = '', [string] $ErrorValue = '')
        $value = Protect-DemoText -Text $ErrorValue
        if ($value.Length -gt 1000) {
            $value = $value.Substring(0, 1000) + '...'
        }
        [pscustomobject]@{ Status = $Status; Output = (Protect-DemoText -Text $Output); ErrorName = $ErrorName; ErrorValue = $value; StatusCode = $StatusCode; StatementId = $statementId; Seconds = [int](& $elapsed) }
    }

    $statementsUri = '{0}/statements' -f [string]$Session.Uri
    $submit = Invoke-DemoFabricRequest -Method Post -Uri $statementsUri -Token $Session.Token -Body ([ordered]@{ code = $Code; kind = $Kind }) -NotIdempotent
    if ($submit.StatusCode -notin 200, 201) {
        return (& $answer 'Failed' ([int]$submit.StatusCode) '' '' (Get-DemoFabricErrorText -Response $submit))
    }
    $statementId = [string](Get-DemoMemberValue -InputObject $submit.Body -Name 'id')
    if ($statementId -notmatch '^\d{1,9}$') {
        return (& $answer 'Failed' ([int]$submit.StatusCode) '' '' 'Fabric accepted the statement, but its answer had no statement ID.')
    }
    $statement = $submit.Body
    $waited = 0
    while ([string](Get-DemoMemberValue -InputObject $statement -Name 'state') -notin 'available', 'Error', 'error', 'cancelled') {
        if ($waited -ge $TimeoutSeconds -or (& $elapsed) -ge $TimeoutSeconds) {
            # Still running: cancelled, so it doesn't keep the session busy; a failed cancel ends with the session anyway.
            $null = Invoke-DemoFabricRequest -Method Post -Uri ('{0}/{1}/cancel' -f $statementsUri, $statementId) -Token $Session.Token -Body @{} -NotIdempotent
            return (& $answer 'TimedOut' 200 '' '' ('it was still {0} after {1} minutes, so it was cancelled' -f [string](Get-DemoMemberValue -InputObject $statement -Name 'state'), [int][System.Math]::Ceiling($TimeoutSeconds / 60.0)))
        }
        Start-Sleep -Seconds $PollSeconds
        $waited += $PollSeconds
        $poll = Invoke-DemoFabricRequest -Method Get -Uri ('{0}/{1}' -f $statementsUri, $statementId) -Token $Session.Token
        if ($poll.StatusCode -ne 200) {
            return (& $answer 'Failed' ([int]$poll.StatusCode) '' '' (Get-DemoFabricErrorText -Response $poll))
        }
        $statement = $poll.Body
    }
    $state = [string](Get-DemoMemberValue -InputObject $statement -Name 'state')
    $output = Get-DemoMemberValue -InputObject $statement -Name 'output'
    $data = Get-DemoMemberValue -InputObject $output -Name 'data'
    $text = [string](Get-DemoMemberValue -InputObject $data -Name 'text/plain')
    if (-not $text -and $null -ne $data) {
        $text = $data | ConvertTo-Json -Depth 16 -Compress
    }
    if ($state -eq 'cancelled') {
        return (& $answer 'Cancelled' 200 $text '' 'Fabric cancelled the statement')
    }
    if ($state -ne 'available' -or [string](Get-DemoMemberValue -InputObject $output -Name 'status') -ne 'ok') {
        return (& $answer 'Error' 200 $text ([string](Get-DemoMemberValue -InputObject $output -Name 'ename')) ([string](Get-DemoMemberValue -InputObject $output -Name 'evalue')))
    }
    return (& $answer 'Ok' 200 $text)
}

function Close-DemoLivySession {
    <#
    .SYNOPSIS
    Deletes a Livy session (Delete Livy Session). Returns Deleted (true when it's gone: HTTP 200, 202, or 204, or 404 when
    it was gone already), StatusCode, and Error. Never throws: a caller closes it in a finally, and a session left behind
    ends by itself after 20 minutes idle. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Session
    )

    try {
        $response = Invoke-DemoFabricRequest -Method Delete -Uri ([string]$Session.Uri) -Token $Session.Token
    }
    catch {
        return [pscustomobject]@{ Deleted = $false; StatusCode = 0; Error = (Get-DemoExceptionText -Exception $_.Exception) }
    }
    if ($response.StatusCode -in 200, 202, 204, 404) {
        return [pscustomobject]@{ Deleted = $true; StatusCode = [int]$response.StatusCode; Error = '' }
    }
    return [pscustomobject]@{ Deleted = $false; StatusCode = [int]$response.StatusCode; Error = (Get-DemoFabricErrorText -Response $response) }
}

function ConvertFrom-DemoLivyJsonLine {
    # The JSON object a statement's output ends with: its last line that isn't blank, parsed, or $null when there's none or
    # it isn't JSON. A Livy statement's text/plain output is everything the code printed. Pure. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyString()]
        [AllowNull()]
        [string] $Text
    )

    $lines = @(([string]$Text) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($lines.Count -eq 0) {
        return $null
    }
    try {
        $parsed = $lines[$lines.Count - 1] | ConvertFrom-Json -Depth 32
    }
    catch {
        return $null
    }
    if ($parsed -isnot [System.Management.Automation.PSCustomObject]) {
        return $null
    }
    return $parsed
}
