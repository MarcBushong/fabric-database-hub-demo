# One transient-retry policy for the module's REST helpers (Phase 28 live finding, 2026-10-30): a TLS handshake that
# failed once ("The SSL connection could not be established, see inner exception.") stopped configure-powerbi.ps1, and
# the run ended NOT DONE, because the helpers retried only HTTP 429. Internal; tests mock Invoke-WebRequest and
# Start-Sleep.
# Sources (checked 2026-10-30):
# - Transient fault handling: https://learn.microsoft.com/azure/architecture/best-practices/transient-faults
# - Fabric throttling and Retry-After: https://learn.microsoft.com/rest/api/fabric/articles/throttling
# - HttpRequestError (.NET 8, PowerShell 7.4): https://learn.microsoft.com/dotnet/api/system.net.http.httprequesterror
# - HttpClient timeouts: https://learn.microsoft.com/dotnet/api/system.net.http.httpclient.timeout

# The tag on the exception Invoke-DemoTransientRetry throws once a network error lasted through its attempts.
$script:DemoNetworkErrorKey = 'DbHubDemo.NetworkError'

function Get-DemoExceptionText {
    <#
    .SYNOPSIS
    An exception's readable text, redacted: its message without .NET's "see inner exception" pointer, followed by the
    innermost exception's message, which names the cause (for example, the TLS alert). Pure. Internal.

    .DESCRIPTION
    Takes an exception or an ErrorRecord. The network failure Invoke-DemoTransientRetry throws already names the
    innermost cause, so its message is used as it is.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [object] $Exception
    )

    if ($Exception -is [System.Management.Automation.ErrorRecord]) {
        $Exception = $Exception.Exception
    }
    if ($Exception -isnot [System.Exception]) {
        return (Protect-DemoText -Text ([string]$Exception))
    }
    $chain = [System.Collections.Generic.List[System.Exception]]::new()
    $current = $Exception
    while ($null -ne $current -and $chain.Count -lt 10) {
        if ($current.Data.Contains($script:DemoNetworkErrorKey)) {
            return (Protect-DemoText -Text $current.Message)
        }
        $chain.Add($current)
        $current = $current.InnerException
    }
    $pointer = '(?i)[\s,;:.-]*\(?see (the )?inner exception( for details)?\)?\.?\s*$'
    $outer = ([string]$chain[0].Message -replace $pointer, '').Trim()
    $innermost = ([string]$chain[$chain.Count - 1].Message -replace $pointer, '').Trim()
    $text = if ($chain.Count -eq 1 -or -not $innermost -or $innermost -eq $outer) {
        $outer
    }
    elseif (-not $outer) {
        $innermost
    }
    else {
        '{0}: {1}' -f $outer.TrimEnd('.'), $innermost
    }
    if ($text -and $text -notmatch '[.!?]$') {
        $text += '.'
    }
    return (Protect-DemoText -Text $text)
}

function Test-DemoNetworkFailure {
    <#
    .SYNOPSIS
    True when an exception, or one it wraps, means no HTTP answer came back: a network failure. Pure. Internal.

    .DESCRIPTION
    HttpRequestException (a DNS failure, a refused or reset connection, a failed TLS handshake), HttpIOException (a
    response that ended early), a socket error, a timeout (TaskCanceledException, TimeoutException), WebException, and
    the network failure Invoke-DemoTransientRetry throws after its attempts. Anything else, such as a refused URI or a
    script error, isn't one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Exception
    )

    if ($Exception -is [System.Management.Automation.ErrorRecord]) {
        $Exception = $Exception.Exception
    }
    $current = $Exception -as [System.Exception]
    for ($depth = 0; $null -ne $current -and $depth -lt 10; $depth++) {
        if ($current.Data.Contains($script:DemoNetworkErrorKey) -or
            $current -is [System.Net.Http.HttpRequestException] -or
            $current -is [System.Net.Sockets.SocketException] -or
            $current -is [System.Threading.Tasks.TaskCanceledException] -or
            $current -is [System.TimeoutException] -or
            $current -is [System.Net.WebException] -or
            $current.GetType().FullName -eq 'System.Net.Http.HttpIOException') {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Test-DemoUnsentRequest {
    <#
    .SYNOPSIS
    True when a network failure came before the request reached the server: a DNS failure, a connection that couldn't
    be opened, a failed TLS handshake, or a proxy tunnel that failed. Sending a request that isn't idempotent again is
    then safe. Pure. Internal.

    .DESCRIPTION
    Reads HttpRequestException.HttpRequestError (NameResolutionError, ConnectionError, SecureConnectionError,
    ProxyTunnelError; .NET 8), and, where it isn't there, a wrapped AuthenticationException (TLS) or a SocketException
    with a connect-time error code. A timeout, a reset connection, or a response that ended early can come after the
    server processed the request, so none of them is unsent.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Exception
    )

    if ($Exception -is [System.Management.Automation.ErrorRecord]) {
        $Exception = $Exception.Exception
    }
    $current = $Exception -as [System.Exception]
    for ($depth = 0; $null -ne $current -and $depth -lt 10; $depth++) {
        if ($current -is [System.Net.Http.HttpRequestException]) {
            $property = $current.PSObject.Properties['HttpRequestError']
            if ($null -ne $property -and [string]$property.Value -in 'NameResolutionError', 'ConnectionError', 'SecureConnectionError', 'ProxyTunnelError') {
                return $true
            }
        }
        elseif ($current -is [System.Security.Authentication.AuthenticationException]) {
            return $true
        }
        elseif ($current -is [System.Net.Sockets.SocketException] -and [string]$current.SocketErrorCode -in 'HostNotFound', 'TryAgain', 'NoData', 'HostUnreachable', 'NetworkUnreachable', 'ConnectionRefused') {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Test-DemoNetworkResult {
    <#
    .SYNOPSIS
    True when an ADR 0012 result says a network error lasted through Invoke-DemoTransientRetry's attempts: its evidence
    has networkError, or its message carries the network failure's text. A rerun is then the fix. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Result
    )

    if ($null -eq $Result) {
        return $false
    }
    if ([bool](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Result -Name 'evidence') -Name 'networkError')) {
        return $true
    }
    return ([string](Get-DemoMemberValue -InputObject $Result -Name 'message') -match 'A network error reached \S+ (on each of \d+ attempts|and the request wasn''t sent again)')
}

function Invoke-DemoTransientRetry {
    <#
    .SYNOPSIS
    Sends one HTTP request through -Send, and again after a transient failure: up to -MaxAttempts (4) attempts, waiting
    5, 15, then 30 seconds, or what Retry-After says (at most 60), with one console line per retry. Returns -Send's last
    answer. Internal.

    .DESCRIPTION
    Transient: a network failure (Test-DemoNetworkFailure: no answer came back), and HTTP 408, 429, 502, 503, and 504.
    With -NotIdempotent (a request that starts or creates something a second copy would repeat, such as a notebook run
    or a refresh), only what the server never processed: a failure before the request was sent (Test-DemoUnsentRequest)
    and HTTP 429. Any other exception, and any other status, goes back at once. -Send gets -State as its only argument,
    so it never depends on this function's variables, and returns an answer with StatusCode and Headers
    (Invoke-WebRequest's response), or throws. When a network failure lasts, this throws an HttpRequestException that
    names -Target, the attempts, and the innermost cause (Get-DemoExceptionText), wraps the last failure, and is tagged
    for Test-DemoNetworkFailure. -Target is the host, for the console lines; no URI, header, or token is ever logged.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Send,

        [AllowNull()]
        [object] $State,

        [Parameter(Mandatory)]
        [string] $Target,

        [switch] $NotIdempotent,

        [ValidateRange(1, 6)]
        [int] $MaxAttempts = 4
    )

    $backoff = @(5, 15, 30)
    for ($attempt = 1; ; $attempt++) {
        $answer = $null
        $failure = $null
        try {
            $answer = & $Send $State
        }
        catch {
            if (-not (Test-DemoNetworkFailure -Exception $_.Exception)) {
                throw
            }
            $failure = $_.Exception
        }
        $wait = $backoff[[System.Math]::Min($attempt, $backoff.Count) - 1]
        if ($null -ne $failure) {
            $sendAgain = -not $NotIdempotent -or (Test-DemoUnsentRequest -Exception $failure)
            if (-not $sendAgain -or $attempt -ge $MaxAttempts) {
                $text = if ($sendAgain -or $attempt -gt 1) {
                    'A network error reached {0} on each of {1} attempts: {2}' -f $Target, $attempt, (Get-DemoExceptionText -Exception $failure)
                }
                else {
                    'A network error reached {0}, and the request wasn''t sent again, because the server may have processed it: {1}' -f $Target, (Get-DemoExceptionText -Exception $failure)
                }
                $lasting = [System.Net.Http.HttpRequestException]::new($text, $failure)
                $lasting.Data[$script:DemoNetworkErrorKey] = $true
                throw $lasting
            }
            Write-DemoLog -Message ('A network error reached {0}; retrying in {1} s (attempt {2} of {3}); no action needed.' -f $Target, $wait, ($attempt + 1), $MaxAttempts)
        }
        else {
            $code = [int](Get-DemoMemberValue -InputObject $answer -Name 'StatusCode')
            $transient = $code -eq 429 -or (-not $NotIdempotent -and $code -in 408, 502, 503, 504)
            if (-not $transient -or $attempt -ge $MaxAttempts) {
                return $answer
            }
            $headers = Get-DemoMemberValue -InputObject $answer -Name 'Headers'
            if ($headers -is [System.Collections.IDictionary] -and (Get-DemoFabricHeaderValue -Headers $headers -Name 'Retry-After')) {
                $wait = Get-DemoFabricRetryDelay -Headers $headers -Default $wait
            }
            Write-DemoLog -Message ('{0} answered HTTP {1}; retrying in {2} s (attempt {3} of {4}); no action needed.' -f $Target, $code, $wait, ($attempt + 1), $MaxAttempts)
        }
        Start-Sleep -Seconds $wait
    }
}
