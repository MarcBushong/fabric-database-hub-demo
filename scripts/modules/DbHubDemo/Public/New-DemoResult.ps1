function New-DemoResult {
    <#
    .SYNOPSIS
    Creates one validation result record (ADR 0012).

    .DESCRIPTION
    The record matches schemas/validation-result.schema.json. Message, evidence, and remediation are
    redacted. With -EvaluationOnly, the message is prefixed with "EVALUATION ONLY:".

    .EXAMPLE
    New-DemoResult -CheckId 'T2.ARC.CONNECTED' -Area t2 -Target T2 -Status Pass -Message 'Arc machine is Connected.'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory record only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z0-9]+(\.[A-Z0-9_]+)+$')]
        [string] $CheckId,

        [Parameter(Mandatory)]
        [ValidateSet('static', 'preflight', 'infra', 't1', 't2', 't3', 't4', 'hub', 'workload', 'teardown', 'fabric', 'cost', 'security')]
        [string] $Area,

        [Parameter(Mandatory)]
        [ValidateSet('T1', 'T2', 'T3', 'T4', 'subscription', 'tenant', 'fabric', 'github', 'repo')]
        [string] $Target,

        [Parameter(Mandatory)]
        [ValidateSet('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')]
        [string] $Status,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Message,

        [System.Collections.IDictionary] $Evidence = @{},

        [string] $Remediation = '',

        [string] $DocUrl = '',

        [switch] $EvaluationOnly
    )

    $safeMessage = Protect-DemoText -Text $Message
    if ($EvaluationOnly -and -not $safeMessage.StartsWith('EVALUATION ONLY:', [System.StringComparison]::Ordinal)) {
        $safeMessage = "EVALUATION ONLY: $safeMessage"
    }

    $safeEvidence = @{}
    if ($Evidence.Count -gt 0) {
        $json = Protect-DemoText -Text ($Evidence | ConvertTo-Json -Depth 8 -Compress)
        $safeEvidence = $json | ConvertFrom-Json -AsHashtable
    }

    [pscustomobject]@{
        PSTypeName     = 'DbHubDemo.Result'
        checkId        = $CheckId
        area           = $Area
        target         = $Target
        status         = $Status
        message        = $safeMessage
        evidence       = $safeEvidence
        remediation    = (Protect-DemoText -Text $Remediation)
        docUrl         = $DocUrl
        evaluationOnly = [bool]$EvaluationOnly
        timestamp      = [System.DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
}
