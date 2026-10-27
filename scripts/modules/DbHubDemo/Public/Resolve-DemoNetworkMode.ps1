function Resolve-DemoNetworkMode {
    <#
    .SYNOPSIS
    Turns the configured networkMode (auto, public, or private) into the mode to deploy (ADR 0007).

    .DESCRIPTION
    - auto: private when an enforced Azure Policy turns off (modify) or denies public network access on
      SQL servers, otherwise public. When the policy inventory was skipped or incomplete, auto resolves
      to private, because private works under any policy (conservative).
    - public: stays public. A policy that turns public network access off makes it Fail, because T1 then
      can't reach T3 through its VNet rule.
    - private: stays private.

    Returns the configured and effective modes, a status (Pass, Fail, or Warning), and a message that
    preflight reports as PREFLIGHT.POLICY.SQLPUBLIC.

    .PARAMETER ConfiguredMode
    networkMode from the configuration.

    .PARAMETER SqlPublicAccessPolicy
    Display names of enforced policies that turn off or deny public network access on SQL servers
    (Get-DemoPolicyConstraint).

    .PARAMETER PolicyUnknown
    The policy inventory was skipped or couldn't read every policy.

    .EXAMPLE
    Resolve-DemoNetworkMode -ConfiguredMode auto -SqlPublicAccessPolicy 'Deny public network access on SQL'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('auto', 'public', 'private')]
        [string] $ConfiguredMode,

        [AllowEmptyCollection()]
        [string[]] $SqlPublicAccessPolicy = @(),

        [switch] $PolicyUnknown
    )

    $configured = $ConfiguredMode.ToLowerInvariant()
    $policies = @($SqlPublicAccessPolicy | Where-Object { $_ })
    $policyList = $policies -join '; '
    $forcedOff = $policies.Count -gt 0
    $effective = $configured
    $status = 'Pass'
    $assumed = $false
    $remediation = ''

    switch ($configured) {
        'auto' {
            if ($forcedOff) {
                $effective = 'private'
                $message = "Azure Policy turns off public network access on SQL servers ($policyList), so networkMode auto resolves to private: T3 gets a private endpoint and a private DNS zone."
            }
            elseif ($PolicyUnknown) {
                $effective = 'private'
                $assumed = $true
                $status = 'Warning'
                $message = 'Azure Policy was not fully read, so networkMode auto resolves to private, which works under any policy.'
                $remediation = 'Re-run preflight with read access to every policy assignment, or set networkMode to public in the configuration if you know no policy turns off public network access on SQL servers.'
            }
            else {
                $effective = 'public'
                $message = 'No enforced policy turns off public network access on SQL servers, so networkMode auto resolves to public.'
            }
        }
        'public' {
            if ($forcedOff) {
                $status = 'Fail'
                $message = "networkMode is public, but Azure Policy turns off public network access on SQL servers ($policyList), so T1 couldn't reach T3 through its VNet rule."
                $remediation = 'Set networkMode to auto or private in the configuration (ADR 0007).'
            }
            elseif ($PolicyUnknown) {
                $status = 'Warning'
                $message = 'networkMode is public, but Azure Policy was not fully read, so a policy that turns off public network access on SQL servers can''t be ruled out.'
                $remediation = 'Re-run preflight with read access to every policy assignment, or set networkMode to auto or private.'
            }
            else {
                $message = 'networkMode is public, and no enforced policy turns off public network access on SQL servers.'
            }
        }
        default {
            $message = 'networkMode is private: T3 uses a private endpoint, which works whatever Azure Policy does to public network access.'
            if ($forcedOff) {
                $message += " Azure Policy also turns public network access off ($policyList)."
            }
        }
    }

    [pscustomobject]@{
        PSTypeName     = 'DbHubDemo.NetworkMode'
        ConfiguredMode = $configured
        EffectiveMode  = $effective
        Assumed        = $assumed
        Status         = $status
        Message        = $message
        Remediation    = $remediation
        Policies       = $policies
    }
}
