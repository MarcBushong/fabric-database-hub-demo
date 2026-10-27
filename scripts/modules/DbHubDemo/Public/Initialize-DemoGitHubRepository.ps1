function Initialize-DemoGitHubRepository {
    <#
    .SYNOPSIS
    Applies the public repository's GitHub settings with the GitHub CLI (gh api), as the signed-in administrator:
    a ruleset that protects the default branch, secret scanning with push protection, private vulnerability
    reporting, Dependabot alerts, and with -Template, the template flag (ADR 0022). Opt-in; -WhatIf changes nothing.

    .DESCRIPTION
    It never changes the repository's visibility and never signs in (run 'gh auth login' first). Each setting is
    read first, then applied only when it's off:
    - REPO.VISIBILITY: Pass when the repository is public. When it's private, Manual action required: on GitHub
      Free, Pro, and Team, GitHub refuses several of these settings on a private repository, so run this again once
      it's public.
    - REPO.RULESET: the repository ruleset "Protect the default branch" on ~DEFAULT_BRANCH, enforced: changes go
      through a pull request (pull_request, with 0 required approvals, because a pull request's author can't approve
      it and a solo owner would be locked out), no force-push (non_fast_forward), and no deletion (deletion). It has
      no bypass actors, because a repository administrator's actor ID isn't documented. Updated in place when it
      exists.
    - REPO.SECRETSCANNING and REPO.PUSHPROTECTION: security_and_analysis.secret_scanning and
      secret_scanning_push_protection set to enabled: GitHub scans the repository for known secret formats, and
      refuses a push that contains one.
    - REPO.VULNERABILITYREPORTING: private vulnerability reporting, so SECURITY.md's "Report a vulnerability" works.
    - REPO.DEPENDABOTALERTS: Dependabot alerts for vulnerable dependencies (Dependabot version updates are already
      configured in .github/dependabot.yml).
    - REPO.TEMPLATE: with -Template, is_template true, so others can start with "Use this template", a copy with one
      fresh commit. Not selected otherwise.
    Statuses (ADR 0012): Pass when the setting is on (applied now or already); Not selected under -WhatIf, with what
    it would do, and for -Template when it isn't given; Manual action required when GitHub refuses (HTTP 403, 404, or
    422) while the repository is private, or when the caller isn't an administrator; Fail for any other error.
    Sources (checked 2026-10-27):
    https://docs.github.com/rest/repos/rules#create-a-repository-ruleset,
    https://docs.github.com/rest/repos/repos#update-a-repository,
    https://docs.github.com/rest/repos/repos#enable-private-vulnerability-reporting-for-a-repository,
    https://docs.github.com/rest/repos/repos#enable-vulnerability-alerts,
    https://docs.github.com/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/about-rulesets,
    https://docs.github.com/code-security/secret-scanning/introduction/about-push-protection,
    https://docs.github.com/repositories/creating-and-managing-repositories/creating-a-template-repository

    .PARAMETER Repository
    owner/repo.

    .PARAMETER Template
    Also mark the repository as a template.

    .EXAMPLE
    Initialize-DemoGitHubRepository -Repository contoso/fabric-database-hub-demo -Template -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string] $Repository,

        [switch] $Template
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $github = Get-DemoGitHubContext -Repository $Repository
    if ($github.Status -ne 'Ready') {
        $results.Add((New-DemoResult -CheckId 'REPO.GITHUB' -Area 'security' -Target 'repo' -Status 'Manual action required' -Message $github.Message -DocUrl 'https://cli.github.com/manual/gh_auth_login'))
        return $results.ToArray()
    }
    if (-not $github.IsAdmin) {
        $results.Add((New-DemoResult -CheckId 'REPO.GITHUB' -Area 'security' -Target 'repo' -Status 'Manual action required' -Message ('{0} isn''t an administrator of {1}, and these settings need one.' -f $github.Login, $Repository) -Remediation 'An administrator of the repository runs setup-github-repo.ps1.'))
        return $results.ToArray()
    }
    $isPublic = $github.Visibility -eq 'public'
    $again = 'Run ./scripts/setup-github-repo.ps1 again once {0} is public: on GitHub Free, Pro, and Team, GitHub refuses this setting on a private repository.' -f $Repository
    if ($isPublic) {
        $results.Add((New-DemoResult -CheckId 'REPO.VISIBILITY' -Area 'security' -Target 'repo' -Status 'Pass' -Message ('{0} is public.' -f $Repository)))
    }
    else {
        $results.Add((New-DemoResult -CheckId 'REPO.VISIBILITY' -Area 'security' -Target 'repo' -Status 'Manual action required' -Message ('{0} is {1}. This script never changes the visibility; settings GitHub refuses on a private repository are reported as Manual action required.' -f $Repository, $github.Visibility) -Remediation ('Once the repository is public, run ./scripts/setup-github-repo.ps1 again.')))
    }

    # Pass, Manual action required, or Fail for a write (or a read) that GitHub answered.
    $outcome = {
        param([pscustomobject] $Call, [string] $CheckId, [string] $Done, [string] $What, [string] $DocUrl, [string] $Settings)
        if ($Call.ExitCode -eq 0) {
            return (New-DemoResult -CheckId $CheckId -Area 'security' -Target 'repo' -Status 'Pass' -Message $Done -DocUrl $DocUrl)
        }
        if ($Call.StatusCode -in 403, 404, 422 -and -not $isPublic) {
            return (New-DemoResult -CheckId $CheckId -Area 'security' -Target 'repo' -Status 'Manual action required' -Message ('GitHub refused {0} while {1} is private (HTTP {2}): {3}' -f $What, $Repository, $Call.StatusCode, $Call.Error) -Remediation $again -DocUrl $DocUrl)
        }
        if ($Call.StatusCode -eq 403) {
            return (New-DemoResult -CheckId $CheckId -Area 'security' -Target 'repo' -Status 'Manual action required' -Message ('GitHub refused {0} (HTTP 403): {1}' -f $What, $Call.Error) -Remediation ('Turn it on in the repository''s {0}, as an administrator.' -f $Settings) -DocUrl $DocUrl)
        }
        return (New-DemoResult -CheckId $CheckId -Area 'security' -Target 'repo' -Status 'Fail' -Message ('{0} failed (HTTP {1}): {2}' -f $What, $Call.StatusCode, $Call.Error) -Remediation ('Run setup-github-repo.ps1 again, or set it in {0}.' -f $Settings) -DocUrl $DocUrl)
    }

    # 1. The ruleset on the default branch.
    $rulesetDoc = 'https://docs.github.com/rest/repos/rules#create-a-repository-ruleset'
    $rulesetName = 'Protect the default branch'
    $ruleset = [ordered]@{
        name        = $rulesetName
        target      = 'branch'
        enforcement = 'active'
        conditions  = [ordered]@{ ref_name = [ordered]@{ include = @('~DEFAULT_BRANCH'); exclude = @() } }
        rules       = @(
            [ordered]@{ type = 'deletion' }
            [ordered]@{ type = 'non_fast_forward' }
            [ordered]@{
                type       = 'pull_request'
                parameters = [ordered]@{
                    required_approving_review_count   = 0
                    dismiss_stale_reviews_on_push     = $false
                    require_code_owner_review         = $false
                    require_last_push_approval        = $false
                    required_review_thread_resolution = $false
                }
            }
        )
    }
    $list = Invoke-DemoGitHubApi -Endpoint ('repos/{0}/rulesets' -f $Repository)
    if ($list.ExitCode -ne 0) {
        $results.Add((& $outcome $list 'REPO.RULESET' '' 'reading the rulesets' $rulesetDoc 'Settings > Rules > Rulesets'))
    }
    else {
        $existing = @($list.Data) | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'name') -eq $rulesetName } | Select-Object -First 1
        $verb = if ($existing) { 'update' } else { 'create' }
        $what = 'the ruleset "{0}" on the default branch ({1}): changes through a pull request with 0 required approvals, no force-push, no deletion, no bypass' -f $rulesetName, $github.DefaultBranch
        if (-not $PSCmdlet.ShouldProcess($Repository, ('{0} {1}' -f $verb, $what))) {
            $results.Add((New-DemoResult -CheckId 'REPO.RULESET' -Area 'security' -Target 'repo' -Status 'Not selected' -Message ('What if: it would {0} {1}.' -f $verb, $what) -DocUrl $rulesetDoc))
        }
        else {
            $call = if ($existing) {
                Invoke-DemoGitHubApi -Method 'PUT' -Endpoint ('repos/{0}/rulesets/{1}' -f $Repository, [long](Get-DemoMemberValue -InputObject $existing -Name 'id')) -Body $ruleset
            }
            else {
                Invoke-DemoGitHubApi -Method 'POST' -Endpoint ('repos/{0}/rulesets' -f $Repository) -Body $ruleset
            }
            $results.Add((& $outcome $call 'REPO.RULESET' ('The ruleset "{0}" protects {1}: changes through a pull request, no force-push, no deletion.' -f $rulesetName, $github.DefaultBranch) ('the ruleset "{0}"' -f $rulesetName) $rulesetDoc 'Settings > Rules > Rulesets'))
        }
    }

    # 2. Secret scanning and push protection.
    $scanningDoc = 'https://docs.github.com/code-security/secret-scanning/introduction/about-push-protection'
    $analysis = $github.SecurityAndAnalysis
    $scanning = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $analysis -Name 'secret_scanning') -Name 'status')
    $push = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $analysis -Name 'secret_scanning_push_protection') -Name 'status')
    if ($scanning -eq 'enabled' -and $push -eq 'enabled') {
        $results.Add((New-DemoResult -CheckId 'REPO.SECRETSCANNING' -Area 'security' -Target 'repo' -Status 'Pass' -Message 'Secret scanning is on.' -DocUrl $scanningDoc))
        $results.Add((New-DemoResult -CheckId 'REPO.PUSHPROTECTION' -Area 'security' -Target 'repo' -Status 'Pass' -Message 'Push protection is on: GitHub refuses a push that contains a known secret format.' -DocUrl $scanningDoc))
    }
    elseif (-not $PSCmdlet.ShouldProcess($Repository, 'Turn on secret scanning and push protection')) {
        foreach ($checkId in 'REPO.SECRETSCANNING', 'REPO.PUSHPROTECTION') {
            $results.Add((New-DemoResult -CheckId $checkId -Area 'security' -Target 'repo' -Status 'Not selected' -Message ('What if: it would turn on secret scanning and push protection (now: {0} and {1}).' -f $(if ($scanning) { $scanning } else { 'unknown' }), $(if ($push) { $push } else { 'unknown' })) -DocUrl $scanningDoc))
        }
    }
    else {
        $body = [ordered]@{ security_and_analysis = [ordered]@{ secret_scanning = [ordered]@{ status = 'enabled' }; secret_scanning_push_protection = [ordered]@{ status = 'enabled' } } }
        $call = Invoke-DemoGitHubApi -Method 'PATCH' -Endpoint ('repos/{0}' -f $Repository) -Body $body
        $results.Add((& $outcome $call 'REPO.SECRETSCANNING' 'Secret scanning is on.' 'secret scanning' $scanningDoc 'Settings > Advanced Security'))
        $results.Add((& $outcome $call 'REPO.PUSHPROTECTION' 'Push protection is on: GitHub refuses a push that contains a known secret format.' 'push protection' $scanningDoc 'Settings > Advanced Security'))
    }

    # 3. Private vulnerability reporting.
    $reportingDoc = 'https://docs.github.com/rest/repos/repos#enable-private-vulnerability-reporting-for-a-repository'
    $reporting = Invoke-DemoGitHubApi -Endpoint ('repos/{0}/private-vulnerability-reporting' -f $Repository)
    if ($reporting.ExitCode -ne 0) {
        $results.Add((& $outcome $reporting 'REPO.VULNERABILITYREPORTING' '' 'reading private vulnerability reporting' $reportingDoc 'Settings > Advanced Security'))
    }
    elseif ([bool](Get-DemoMemberValue -InputObject $reporting.Data -Name 'enabled')) {
        $results.Add((New-DemoResult -CheckId 'REPO.VULNERABILITYREPORTING' -Area 'security' -Target 'repo' -Status 'Pass' -Message 'Private vulnerability reporting is on: the Security tab offers "Report a vulnerability".' -DocUrl $reportingDoc))
    }
    elseif (-not $PSCmdlet.ShouldProcess($Repository, 'Turn on private vulnerability reporting')) {
        $results.Add((New-DemoResult -CheckId 'REPO.VULNERABILITYREPORTING' -Area 'security' -Target 'repo' -Status 'Not selected' -Message 'What if: it would turn on private vulnerability reporting (now off).' -DocUrl $reportingDoc))
    }
    else {
        $call = Invoke-DemoGitHubApi -Method 'PUT' -Endpoint ('repos/{0}/private-vulnerability-reporting' -f $Repository)
        $results.Add((& $outcome $call 'REPO.VULNERABILITYREPORTING' 'Private vulnerability reporting is on: the Security tab offers "Report a vulnerability".' 'private vulnerability reporting' $reportingDoc 'Settings > Advanced Security'))
    }

    # 4. Dependabot alerts: 204 when they're on, 404 when they're off.
    $alertsDoc = 'https://docs.github.com/rest/repos/repos#enable-vulnerability-alerts'
    $alerts = Invoke-DemoGitHubApi -Endpoint ('repos/{0}/vulnerability-alerts' -f $Repository)
    if ($alerts.ExitCode -eq 0) {
        $results.Add((New-DemoResult -CheckId 'REPO.DEPENDABOTALERTS' -Area 'security' -Target 'repo' -Status 'Pass' -Message 'Dependabot alerts are on.' -DocUrl $alertsDoc))
    }
    elseif ($alerts.StatusCode -ne 404) {
        $results.Add((& $outcome $alerts 'REPO.DEPENDABOTALERTS' '' 'reading Dependabot alerts' $alertsDoc 'Settings > Advanced Security'))
    }
    elseif (-not $PSCmdlet.ShouldProcess($Repository, 'Turn on Dependabot alerts')) {
        $results.Add((New-DemoResult -CheckId 'REPO.DEPENDABOTALERTS' -Area 'security' -Target 'repo' -Status 'Not selected' -Message 'What if: it would turn on Dependabot alerts (now off).' -DocUrl $alertsDoc))
    }
    else {
        $call = Invoke-DemoGitHubApi -Method 'PUT' -Endpoint ('repos/{0}/vulnerability-alerts' -f $Repository)
        $results.Add((& $outcome $call 'REPO.DEPENDABOTALERTS' 'Dependabot alerts are on.' 'Dependabot alerts' $alertsDoc 'Settings > Advanced Security'))
    }

    # 5. The template flag, only with -Template.
    $templateDoc = 'https://docs.github.com/repositories/creating-and-managing-repositories/creating-a-template-repository'
    if ($github.IsTemplate) {
        $results.Add((New-DemoResult -CheckId 'REPO.TEMPLATE' -Area 'security' -Target 'repo' -Status 'Pass' -Message ('{0} is a template repository: "Use this template" starts a copy with one fresh commit.' -f $Repository) -DocUrl $templateDoc))
    }
    elseif (-not $Template) {
        $results.Add((New-DemoResult -CheckId 'REPO.TEMPLATE' -Area 'security' -Target 'repo' -Status 'Not selected' -Message ('{0} isn''t a template repository; -Template makes it one.' -f $Repository) -DocUrl $templateDoc))
    }
    elseif (-not $PSCmdlet.ShouldProcess($Repository, 'Mark as a template repository')) {
        $results.Add((New-DemoResult -CheckId 'REPO.TEMPLATE' -Area 'security' -Target 'repo' -Status 'Not selected' -Message 'What if: it would mark the repository as a template.' -DocUrl $templateDoc))
    }
    else {
        $call = Invoke-DemoGitHubApi -Method 'PATCH' -Endpoint ('repos/{0}' -f $Repository) -Body ([ordered]@{ is_template = $true })
        $results.Add((& $outcome $call 'REPO.TEMPLATE' ('{0} is a template repository: "Use this template" starts a copy with one fresh commit.' -f $Repository) 'the template flag' $templateDoc 'Settings > General'))
    }
    return $results.ToArray()
}
