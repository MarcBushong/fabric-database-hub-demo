function Connect-DemoRayfinCli {
    <#
    .SYNOPSIS
    Signs the Rayfin CLI in to the demo's tenant once, interactively, for configure-fabric-app.ps1 -SignIn
    (prerequisite P14; Phase 26b, ADR 0023).

    .DESCRIPTION
    The Insights app deploys with the Rayfin CLI, which uses its own cached sign-in; its service principal sign-in is
    listed but not supported yet (https://learn.microsoft.com/fabric/apps/cli-reference), so a person signs in once.
    This function runs that sign-in for them, and only where a person can answer it:
    - In CI (CI, GITHUB_ACTIONS, or TF_BUILD set) or without an interactive console, nothing runs: Not supported,
      with the command to run on your own machine.
    - Otherwise it runs the stage's pinned CLI, 'rayfin login --tenant <tenantId>', attached to this console
      (Invoke-DemoRayfinInteractive): the CLI opens a browser, and you sign in as the demo's Fabric user. Nothing is
      captured, logged, or stored by the script; the CLI keeps its own token cache.
    - Then it checks the result the usual way, with 'rayfin login status --json' (Test-DemoFabricAppPrerequisite,
      FABRIC.APP.SIGNIN): Pass when the CLI is signed in to the configured tenant.
    The Azure CLI context is never touched. A machine without an operating system keychain (for example some
    containers) may need the CLI's --encryption-fallback-enabled, which stores the token in plain text; the script
    never adds it, so that stays your decision.

    .PARAMETER Config
    Configuration from Get-DemoConfig (tenantId).

    .PARAMETER StagePath
    The deploy stage whose pinned CLI signs in (out/fabric-app, after Sync-DemoFabricAppStage).

    .EXAMPLE
    Connect-DemoRayfinCli -Config $config -StagePath ./out/fabric-app
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $StagePath
    )

    $settings = Get-DemoFabricAppSetting
    $cliReference = 'https://learn.microsoft.com/fabric/apps/cli-reference'
    $tenantId = [string]$Config['tenantId']
    $loginCommand = 'npx --yes --package={0}@{1} -- rayfin login --tenant {2}' -f $settings['cliPackage'], $settings['cliVersion'], $(if ($tenantId) { $tenantId } else { '<tenantId>' })
    $result = {
        param([string] $Status, [string] $Message, [string] $Remediation = '')
        New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status $Status -Message $Message -Remediation $Remediation -DocUrl $cliReference
    }

    if (-not (Test-DemoInteractiveSession)) {
        return (& $result 'Not supported' '-SignIn needs a person at an interactive console: the Rayfin CLI''s sign-in opens a browser, and its service principal sign-in isn''t supported yet, so it doesn''t run in CI or a non-interactive session.' ('On your own machine, sign in once as the demo''s Fabric user, then run configure-fabric-app.ps1 again: {0}' -f $loginCommand))
    }
    if ($tenantId -notmatch $script:GuidPattern) {
        return (& $result 'Manual action required' 'No tenant (tenantId) is configured, so the Rayfin CLI can''t be signed in to it.' 'Run ./scripts/init.ps1, or set tenantId in the configuration.')
    }
    $cli = Get-DemoRayfinCliPath -StagePath $StagePath
    if (-not $cli) {
        return (& $result 'Manual action required' ('The pinned Rayfin CLI isn''t installed in {0} yet, so -SignIn couldn''t run it.' -f $StagePath) ('Run configure-fabric-app.ps1 without -SkipInstall, or sign in yourself: {0}' -f $loginCommand))
    }
    $node = Get-Command -Name 'node' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $node) {
        return (& $result 'Manual action required' 'Node.js wasn''t found on PATH, so the Rayfin CLI can''t run.' ('Install Node.js {0}, then run configure-fabric-app.ps1 -SignIn again.' -f (@($settings['supportedNodeMajors']) -join ', ')))
    }
    if (-not $PSCmdlet.ShouldProcess('the Rayfin CLI', 'Sign in to the demo''s tenant (a browser opens)')) {
        return (& $result 'Not selected' 'What if: the Rayfin CLI would be signed in to the demo''s tenant (rayfin login --tenant); a browser would open.')
    }

    Write-DemoLog -Message 'Signing the Rayfin CLI in to the demo''s tenant: a browser opens; sign in as the demo''s Fabric user. The script doesn''t see or keep your sign-in.'
    # The Rayfin CLI's own sign-in command (not the Azure CLI's, which no script runs).
    $rayfinSignIn = @('login', '--tenant', $tenantId)
    try {
        $exitCode = Invoke-DemoRayfinInteractive -NodePath $node.Source -CliPath $cli -ArgumentList $rayfinSignIn -WorkingDirectory $StagePath
    }
    catch {
        return (& $result 'Manual action required' ('The Rayfin CLI''s sign-in couldn''t start: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) ('Sign in yourself: {0}' -f $loginCommand))
    }
    $check = @(Test-DemoFabricAppPrerequisite -Config $Config -StagePath $StagePath | Where-Object { $_.checkId -eq 'FABRIC.APP.SIGNIN' }) | Select-Object -First 1
    if ($null -eq $check) {
        return (& $result 'Manual action required' ('The Rayfin CLI''s sign-in ended with exit code {0}, and its status couldn''t be read.' -f $exitCode) ('Check it with: npx --yes --package={0}@{1} -- rayfin login status' -f $settings['cliPackage'], $settings['cliVersion']))
    }
    if ($check.status -eq 'Pass') {
        return (& $result 'Pass' 'The Rayfin CLI is signed in to the demo''s tenant (-SignIn; checked with rayfin login status). It renews its own token; the script never sees it.')
    }
    return (& $result $check.status ('After -SignIn (exit code {0}): {1}' -f $exitCode, $check.message) $check.remediation)
}
