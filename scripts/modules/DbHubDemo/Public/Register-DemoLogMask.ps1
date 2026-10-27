function Register-DemoLogMask {
    <#
    .SYNOPSIS
    In GitHub Actions, masks identifiers in the job log and in what the module writes, because a public
    repository's Actions logs and artifacts are public (ADR 0022). Outside GitHub Actions it does nothing.

    .DESCRIPTION
    Only when GITHUB_ACTIONS is 'true'. Each value of six characters or more is registered in three forms: as
    given, in lowercase, and in uppercase, because the runner's masking matches exactly and the scripts write IDs
    in lowercase.
    - For each new form it writes the add-mask workflow command to the host, so the runner prints *** instead of
      it in the job log from then on. The host is used rather than the console stream, so the command also reaches
      the log from deploy.ps1's track processes, whose host output their parent relays.
    - Write-DemoLog, Write-DemoResultReport, and Export-DemoResult replace every registered form with *** (through
      Protect-DemoLogText) in their log lines, in the job summary, and in the out/*.jsonl results that the
      workflows upload as artifacts, which add-mask doesn't cover.
    With -Config, it registers every GUID-shaped and email-shaped string anywhere in the configuration:
    subscriptionId, tenantId, azureAccount, t3AdminGroupObjectId, presenterObjectIds, keyVault.operatorObjectIds,
    the Fabric IDs, owner, ownerEmail, and any later one.
    Results in memory keep their values, so nothing that reads a result changes. Register-DemoSecret is for secrets,
    which it redacts everywhere; this is for identifiers, which stay visible on the operator's own console.

    Source (checked 2026-10-27): https://docs.github.com/actions/reference/workflows-and-actions/workflow-commands#masking-a-value-in-a-log

    .PARAMETER Value
    Identifiers to mask: IDs, accounts, or the deployment's random suffix.

    .PARAMETER Config
    A configuration (Get-DemoConfig, or DBHUB_CONFIG_JSON parsed as a hashtable): its GUIDs and email addresses.

    .EXAMPLE
    Register-DemoLogMask -Value $subscriptionId, $tenantId
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'The add-mask workflow command must reach the job log; host output does, also from track processes.')]
    [CmdletBinding(DefaultParameterSetName = 'Value')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Value', Position = 0, ValueFromPipeline)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]] $Value,

        [Parameter(Mandatory, ParameterSetName = 'Config')]
        [System.Collections.IDictionary] $Config
    )

    process {
        if ($env:GITHUB_ACTIONS -ne 'true') {
            return
        }
        $candidates = if ($PSCmdlet.ParameterSetName -eq 'Config') { @(Get-DemoLogMaskCandidate -InputObject $Config) } else { @($Value) }
        $added = $false
        foreach ($candidate in $candidates) {
            $text = ([string]$candidate).Trim()
            if ($text.Length -lt 6) {
                continue
            }
            $forms = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
            foreach ($form in @($text, $text.ToLowerInvariant(), $text.ToUpperInvariant())) {
                if ($forms.Add($form) -and -not $script:DemoLogMasks.Contains($form)) {
                    $script:DemoLogMasks.Add($form)
                    Write-Host ('::add-mask::{0}' -f $form)
                    $added = $true
                }
            }
        }
        if ($added) {
            # Longest first, so a value that contains another is replaced whole.
            $sorted = [string[]]($script:DemoLogMasks | Sort-Object -Property Length -Descending)
            $script:DemoLogMasks.Clear()
            $script:DemoLogMasks.AddRange($sorted)
        }
    }
}
