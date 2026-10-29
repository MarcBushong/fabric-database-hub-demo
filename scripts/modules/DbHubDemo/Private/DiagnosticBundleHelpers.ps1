# The diagnostics bundle (Phase 28, brief item 9): what out/ holds after a run, redacted again for a Deployment problem
# issue. Sources (checked 2026-10-29): Compress-Archive,
# https://learn.microsoft.com/powershell/module/microsoft.powershell.archive/compress-archive

function Protect-DemoBundleText {
    <#
    .SYNOPSIS
    Text for the diagnostics bundle: Protect-DemoText (secrets), then what identifies the person or the tenant: every
    GUID (subscription, tenant, object, and run IDs) as ***, the T3 and T4 servers' random suffix, email addresses,
    this machine's home folder (as ~), and each -Mask value (for example the configuration's owner alias) as [masked].
    A public issue is the destination, so this is stricter than a local log. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text,

        [AllowEmptyString()]
        [string] $HomePath = $HOME,

        [AllowEmptyCollection()]
        [string[]] $Mask = @()
    )

    $safe = Protect-DemoText -Text $Text
    if ([string]::IsNullOrEmpty($safe)) {
        return $safe
    }
    foreach ($value in @($Mask | Where-Object { $_ -and $_.Length -ge 3 } | Sort-Object -Property Length -Descending)) {
        $safe = $safe.Replace($value, '[masked]', [System.StringComparison]::OrdinalIgnoreCase)
    }
    $safe = [regex]::Replace($safe, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '***')
    $safe = [regex]::Replace($safe, '(?i)\b(azuresql01|pgflex01)-[a-z0-9]{6}\b', '$1-***')
    $safe = [regex]::Replace($safe, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b', '[email]')
    if ($HomePath -and $HomePath.Length -ge 3) {
        # As written, with forward slashes, and with the doubled backslashes of JSON.
        foreach ($candidate in @(($HomePath -replace '\\', '\\'), $HomePath, ($HomePath -replace '\\', '/'))) {
            $safe = $safe.Replace($candidate, '~', [System.StringComparison]::OrdinalIgnoreCase)
        }
    }
    return $safe
}
