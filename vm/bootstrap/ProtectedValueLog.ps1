function Disable-DemoSessionEventLog {
    <#
    .SYNOPSIS
    Stops this PowerShell session from writing more engine and provider events to the Windows PowerShell log
    (ADR 0009, Phase 26f). Managed Run Command passes protected parameters to the script as arguments, and those
    events repeat the session's command line (HostApplication); the session's opening events are already written,
    so Clear-DemoProtectedValueLog removes them after use, and this keeps the closing ones from writing the value
    again. The Log*Event preference variables apply to the current session only:
    https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_preference_variables
    #>
    [CmdletBinding()]
    param()

    foreach ($name in 'LogEngineLifecycleEvent', 'LogProviderLifecycleEvent', 'LogEngineHealthEvent', 'LogProviderHealthEvent') {
        Set-Variable -Name $name -Value $false -Scope Global
    }
}

function Clear-DemoProtectedValueLog {
    <#
    .SYNOPSIS
    After a protected value is used, searches the Windows PowerShell log for that exact value, in memory only,
    and clears the log when it's there (ADR 0009, Phase 26f). Returns the log's name, how many events held the
    value, whether the log was cleared, and an error's type name; never the value.

    .DESCRIPTION
    A non-Security log, cleared only when it holds the value, as the owner's rule for logs requires; endpoint
    protection may report the clearing, so the caller reports it as a Warning. It never clears the Security
    log. Windows PowerShell 5.1, self-contained: the orchestrator inserts it into a Run Command's script.
    https://learn.microsoft.com/dotnet/api/system.diagnostics.eventing.reader.eventlogsession.clearlog
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowEmptyString()]
        [string] $Value = '',

        [string] $LogName = 'Windows PowerShell',

        [scriptblock] $Reader = $null,

        [scriptblock] $Clearer = $null
    )

    $result = [ordered]@{ log = $LogName; found = 0; cleared = $false; error = '' }
    if ([string]::IsNullOrEmpty($Value) -or $LogName -eq 'Security') {
        return $result
    }
    try {
        $events = @()
        if ($null -ne $Reader) {
            $events = @(& $Reader $LogName)
        }
        else {
            $events = @(Get-WinEvent -LogName $LogName -ErrorAction SilentlyContinue)
        }
        foreach ($record in $events) {
            foreach ($property in @($record.Properties)) {
                $text = [string]$property.Value
                if ($text -and $text.IndexOf($Value, [System.StringComparison]::Ordinal) -ge 0) {
                    $result.found++
                    break
                }
            }
        }
        if ($result.found -gt 0) {
            if ($null -ne $Clearer) {
                & $Clearer $LogName
            }
            else {
                [System.Diagnostics.Eventing.Reader.EventLogSession]::GlobalSession.ClearLog($LogName)
            }
            $result.cleared = $true
        }
    }
    catch {
        $result.error = $_.Exception.GetType().Name
    }
    return $result
}
