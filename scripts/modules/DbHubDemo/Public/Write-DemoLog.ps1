function Write-DemoLog {
    <#
    .SYNOPSIS
    Writes one redacted log line for the operator or the GitHub Actions log.

    .DESCRIPTION
    Every message passes through Protect-DemoText first. In GitHub Actions, warnings and errors are
    emitted as workflow annotations, and the identifiers Register-DemoLogMask registered, any other GUID, and the
    T3 and T4 servers' random suffix are written as *** (Protect-DemoLogText, ADR 0022).

    .EXAMPLE
    Write-DemoLog -Level Warning -Message 'Bastion has existed for 5 hours.'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Operator console output. Every line is redacted before it is written.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Debug')]
        [string] $Level = 'Info'
    )

    $safe = Protect-DemoLogText -Text $Message
    $time = [System.DateTime]::UtcNow.ToString('HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    # deploy.ps1's parallel tracks run in their own processes and set DBHUB_LOG_TRACK, so interleaved lines say whose they are.
    if ($env:DBHUB_LOG_TRACK -match '^[A-Za-z0-9]{1,12}$') {
        $safe = '[{0}] {1}' -f $env:DBHUB_LOG_TRACK, $safe
    }

    if ($Level -eq 'Debug') {
        Write-Debug -Message "[$time] $safe"
        return
    }

    if ($env:GITHUB_ACTIONS -eq 'true' -and $Level -in 'Warning', 'Error') {
        $command = if ($Level -eq 'Error') { 'error' } else { 'warning' }
        Write-Host "::$command::$safe"
        return
    }

    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        default { 'Gray' }
    }
    Write-Host "[$time] [$($Level.ToUpperInvariant())] $safe" -ForegroundColor $color
}
