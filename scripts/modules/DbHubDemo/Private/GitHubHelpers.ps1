function Invoke-DemoGitHubCli {
    <#
    .SYNOPSIS
    Runs the GitHub CLI (gh) with an argument array, optionally with text on standard input, and captures the
    exit code, stdout, stderr, and the HTTP status that gh reports. Internal; tests mock it.

    .DESCRIPTION
    Every GitHub call in the module goes through this function. It never signs in (gh auth login stays the
    operator's step), never logs its arguments, and passes values such as secrets on standard input, never on the
    command line. gh runs with prompts and its update notice off, and is stopped after -TimeoutSeconds. When gh
    isn't installed, ExitCode is 127 and nothing runs. StatusCode is the 'HTTP nnn' from gh's error, 200 when gh
    succeeded, and 0 when it's unknown.
    Source (checked 2026-10-27): https://cli.github.com/manual/gh_api
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $ArgumentList,

        [AllowNull()]
        [string] $InputText = $null,

        [ValidateRange(1, 3600)]
        [int] $TimeoutSeconds = 120
    )

    $WhatIfPreference = $false
    $gh = Get-Command -Name 'gh' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $gh) {
        return [pscustomobject]@{ ExitCode = 127; StdOut = ''; StdErr = 'The GitHub CLI (gh) was not found on PATH.'; StatusCode = 0 }
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $gh.Source
    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.Environment['GH_PROMPT_DISABLED'] = '1'
    $startInfo.Environment['GH_NO_UPDATE_NOTIFIER'] = '1'
    $startInfo.Environment['NO_COLOR'] = '1'

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        $null = $process.Start()
        if ($null -ne $InputText) {
            # UTF-8 without a byte order mark, and no trailing line break, so the value arrives exactly as given.
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($InputText)
            $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $process.StandardInput.BaseStream.Flush()
        }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            }
            catch {
                Write-Verbose -Message 'The GitHub CLI process had already exited.'
            }
            return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = ('The GitHub CLI did not finish within {0} seconds and was stopped.' -f $TimeoutSeconds); StatusCode = 0 }
        }
        $process.WaitForExit()
        $stdout = ([string]$stdoutTask.GetAwaiter().GetResult()).TrimEnd()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        $status = 0
        if ($process.ExitCode -eq 0) {
            $status = 200
        }
        elseif ($stderr -match '\(HTTP (\d{3})\)') {
            $status = [int]$Matches[1]
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; StdOut = $stdout; StdErr = (Protect-DemoText -Text $stderr); StatusCode = $status }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-DemoGitHubApi {
    <#
    .SYNOPSIS
    Calls the GitHub REST API through 'gh api' with the documented headers, the body as JSON on standard input,
    and returns ExitCode, StatusCode, Data (the parsed JSON answer, or $null), and Error. Internal.

    .DESCRIPTION
    Source (checked 2026-10-27): https://docs.github.com/rest/about-the-rest-api/api-versions and
    https://cli.github.com/manual/gh_api
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string] $Method = 'GET',

        [Parameter(Mandatory)]
        [ValidatePattern('^(repos|user)(/|$)')]
        [string] $Endpoint,

        [System.Collections.IDictionary] $Body
    )

    $arguments = @('api', '--method', $Method, '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2022-11-28', $Endpoint)
    $inputText = $null
    if ($null -ne $Body) {
        $arguments += @('--input', '-')
        $inputText = $Body | ConvertTo-Json -Depth 16 -Compress
    }
    $call = Invoke-DemoGitHubCli -ArgumentList $arguments -InputText $inputText
    $data = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$call.StdOut)) {
        try {
            $data = [string]$call.StdOut | ConvertFrom-Json -AsHashtable -Depth 32
        }
        catch {
            $data = $null
        }
    }
    $message = ''
    if ($call.ExitCode -ne 0) {
        $message = ([string]$call.StdErr).Trim()
        $answer = [string](Get-DemoMemberValue -InputObject $data -Name 'message')
        if ($answer -and $message -notmatch [regex]::Escape($answer)) {
            $message = ('{0} {1}' -f $message, $answer).Trim()
        }
        if ($message.Length -gt 300) {
            $message = $message.Substring(0, 300) + '...'
        }
    }
    return [pscustomobject]@{ ExitCode = $call.ExitCode; StatusCode = $call.StatusCode; Data = $data; Error = $message }
}

function Get-DemoGitHubContext {
    <#
    .SYNOPSIS
    What the GitHub setup needs to know first, read-only: whether gh is installed and signed in (the caller's login
    and ID), and the repository's default branch, visibility, and whether the caller is an administrator. Internal.
    Status is Ready, NoCli, NoSignIn, or NoRepository, with Message saying what to do.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
        [string] $Repository
    )

    $context = [ordered]@{ Status = 'Ready'; Message = ''; Login = ''; UserId = 0; DefaultBranch = ''; Visibility = ''; IsAdmin = $false; IsTemplate = $false; SecurityAndAnalysis = $null }
    $user = Invoke-DemoGitHubApi -Endpoint 'user'
    if ($user.ExitCode -eq 127) {
        $context.Status = 'NoCli'
        $context.Message = 'The GitHub CLI (gh) isn''t installed. Install it (https://cli.github.com), sign in with gh auth login, and run this again.'
        return [pscustomobject]$context
    }
    if ($user.ExitCode -ne 0 -or $null -eq $user.Data) {
        $context.Status = 'NoSignIn'
        $context.Message = ('gh isn''t signed in to GitHub ({0}). Sign in yourself with gh auth login (the scripts never sign in), then run this again.' -f $user.Error)
        return [pscustomobject]$context
    }
    $context.Login = [string](Get-DemoMemberValue -InputObject $user.Data -Name 'login')
    $context.UserId = [long](Get-DemoMemberValue -InputObject $user.Data -Name 'id')
    $repo = Invoke-DemoGitHubApi -Endpoint ('repos/{0}' -f $Repository)
    if ($repo.ExitCode -ne 0 -or $null -eq $repo.Data) {
        $context.Status = 'NoRepository'
        $context.Message = ('GitHub didn''t return {0} for {1} (HTTP {2}): {3}' -f $Repository, $context.Login, $repo.StatusCode, $repo.Error)
        return [pscustomobject]$context
    }
    $permissions = Get-DemoMemberValue -InputObject $repo.Data -Name 'permissions'
    $context.DefaultBranch = [string](Get-DemoMemberValue -InputObject $repo.Data -Name 'default_branch')
    $context.Visibility = [string](Get-DemoMemberValue -InputObject $repo.Data -Name 'visibility')
    $context.IsAdmin = [bool](Get-DemoMemberValue -InputObject $permissions -Name 'admin')
    $context.IsTemplate = [bool](Get-DemoMemberValue -InputObject $repo.Data -Name 'is_template')
    $context.SecurityAndAnalysis = Get-DemoMemberValue -InputObject $repo.Data -Name 'security_and_analysis'
    return [pscustomobject]$context
}

function Set-DemoGitHubEnvironment {
    <#
    .SYNOPSIS
    Creates or updates one GitHub environment for the demo's workflows, and sets its four secrets: the reviewed
    environment (the caller as required reviewer) or, with -NoReviewer, the schedule environment. Both deploy only
    from the default branch. Internal; Initialize-DemoGitHubOidc -ConfigureGitHub calls it (ADR 0022).

    .DESCRIPTION
    1. PUT /repos/{owner}/{repo}/environments/{name}: required reviewers (the caller, or none with -NoReviewer),
       prevent_self_review false (a solo owner approves their own runs), and deployment_branch_policy with
       custom_branch_policies true. "Protected branches only" isn't used: GitHub counts only branch protection
       rules there, and when no branch has one, all branches can deploy; setup-github-repo.ps1 protects main with
       a ruleset instead.
    2. POST .../deployment-branch-policies with the default branch's name (an existing one answers 303).
    3. gh secret set <name> --env <environment> --repo <owner/repo>, each value on standard input:
       AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, and DBHUB_CONFIG_JSON. They're identifiers, not
       credentials; secrets only so that GitHub masks them in a public repository's logs.
    A refused request (HTTP 403, 404, or 422) on a private repository is Manual action required: required reviewers
    need a public repository on GitHub Free, Pro, and Team. Nothing is printed with a value.
    Sources (checked 2026-10-27):
    https://docs.github.com/rest/deployments/environments#create-or-update-an-environment,
    https://docs.github.com/rest/deployments/branch-policies#create-a-deployment-branch-policy,
    https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments,
    https://cli.github.com/manual/gh_secret_set
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_.-]{1,100}$')]
        [string] $Name,

        [Parameter(Mandatory)]
        [pscustomobject] $GitHub,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Secret,

        [switch] $NoReviewer
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $suffix = ($Name.ToUpperInvariant() -replace '[^A-Z0-9_]', '_')
    $docUrl = 'https://docs.github.com/actions/reference/workflows-and-actions/deployments-and-environments'
    $kind = if ($NoReviewer) { 'no required reviewers (the schedule environment)' } else { ('required reviewer {0}' -f $GitHub.Login) }
    if (-not $PSCmdlet.ShouldProcess(('{0} environment {1}' -f $Repository, $Name), ('Create or update with {0}, deployments from {1} only, and its {2} secrets' -f $kind, $GitHub.DefaultBranch, $Secret.Count))) {
        $results.Add((New-DemoResult -CheckId ('OIDC.GITHUB.ENV_{0}' -f $suffix) -Area 'infra' -Target 'github' -Status 'Not selected' -Message ('What if: the environment {0} would get {1}, deployments from {2} only, and the secrets {3}.' -f $Name, $kind, $GitHub.DefaultBranch, (@($Secret.Keys) -join ', ')) -DocUrl $docUrl))
        return $results.ToArray()
    }
    $refused = {
        param([int] $Status)
        $Status -in 403, 404, 422 -and $GitHub.Visibility -ne 'public'
    }
    # An array even with one reviewer or none, so the request has a JSON list.
    $reviewers = @(if (-not $NoReviewer) { [ordered]@{ type = 'User'; id = $GitHub.UserId } })
    $body = [ordered]@{
        wait_timer               = 0
        prevent_self_review      = $false
        reviewers                = $reviewers
        deployment_branch_policy = [ordered]@{ protected_branches = $false; custom_branch_policies = $true }
    }
    $environmentPath = 'repos/{0}/environments/{1}' -f $Repository, [System.Uri]::EscapeDataString($Name)
    $put = Invoke-DemoGitHubApi -Method 'PUT' -Endpoint $environmentPath -Body $body
    if ($put.ExitCode -ne 0) {
        $status = if (& $refused $put.StatusCode) { 'Manual action required' } else { 'Fail' }
        $results.Add((New-DemoResult -CheckId ('OIDC.GITHUB.ENV_{0}' -f $suffix) -Area 'infra' -Target 'github' -Status $status -Message ('GitHub refused the environment {0} (HTTP {1}): {2}' -f $Name, $put.StatusCode, $put.Error) -Remediation ('Environments with required reviewers need a public repository on GitHub Free, Pro, and Team. Run setup-github-oidc.ps1 -ConfigureGitHub again once {0} is public, or create {1} in Settings > Environments.' -f $Repository, $Name) -DocUrl $docUrl))
        return $results.ToArray()
    }
    $policy = Invoke-DemoGitHubApi -Method 'POST' -Endpoint ('{0}/deployment-branch-policies' -f $environmentPath) -Body ([ordered]@{ name = $GitHub.DefaultBranch; type = 'branch' })
    if ($policy.ExitCode -ne 0 -and $policy.StatusCode -ne 303) {
        $results.Add((New-DemoResult -CheckId ('OIDC.GITHUB.ENV_{0}' -f $suffix) -Area 'infra' -Target 'github' -Status 'Fail' -Message ('The environment {0} exists, but GitHub refused its branch policy for {1} (HTTP {2}): {3}' -f $Name, $GitHub.DefaultBranch, $policy.StatusCode, $policy.Error) -Remediation ('In Settings > Environments > {0}, set Deployment branches and tags to Selected branches, with {1}.' -f $Name, $GitHub.DefaultBranch) -DocUrl $docUrl))
        return $results.ToArray()
    }
    $results.Add((New-DemoResult -CheckId ('OIDC.GITHUB.ENV_{0}' -f $suffix) -Area 'infra' -Target 'github' -Status 'Pass' -Message ('The environment {0} has {1}, and only {2} can deploy to it.' -f $Name, $kind, $GitHub.DefaultBranch) -Evidence ([ordered]@{ environment = $Name; reviewers = $(if ($NoReviewer) { @() } else { @($GitHub.Login) }); branch = $GitHub.DefaultBranch }) -DocUrl $docUrl))

    $failed = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Secret.Keys) {
        $set = Invoke-DemoGitHubCli -ArgumentList @('secret', 'set', [string]$key, '--env', $Name, '--repo', $Repository) -InputText ([string]$Secret[$key])
        if ($set.ExitCode -ne 0) {
            $failed.Add(('{0} ({1})' -f $key, ([string]$set.StdErr).Trim()))
        }
    }
    if ($failed.Count -gt 0) {
        $results.Add((New-DemoResult -CheckId ('OIDC.GITHUB.SECRETS_{0}' -f $suffix) -Area 'infra' -Target 'github' -Status 'Fail' -Message ('Setting the secrets of {0} failed: {1}' -f $Name, ($failed -join '; ')) -Remediation ('Run setup-github-oidc.ps1 -ConfigureGitHub again, or set them with gh secret set <name> --env {0} --repo {1}.' -f $Name, $Repository) -DocUrl 'https://cli.github.com/manual/gh_secret_set'))
    }
    else {
        $results.Add((New-DemoResult -CheckId ('OIDC.GITHUB.SECRETS_{0}' -f $suffix) -Area 'infra' -Target 'github' -Status 'Pass' -Message ('The environment {0} has its secrets {1}; GitHub masks their values in the logs.' -f $Name, (@($Secret.Keys) -join ', ')) -Evidence ([ordered]@{ environment = $Name; secrets = @($Secret.Keys) }) -DocUrl 'https://cli.github.com/manual/gh_secret_set'))
    }
    return $results.ToArray()
}
