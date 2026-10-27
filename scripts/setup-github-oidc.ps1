#Requires -Version 7.4
<#
.SYNOPSIS
One-time setup of the GitHub Actions identity, its federated credentials, and (opt-in) the GitHub environments
and their secrets (prerequisite P7, plan section 9.5, ADR 0022).

.DESCRIPTION
Creates rg-<prefix>-control, the user-assigned managed identity id-<prefix>-github, and one federated
credential per GitHub environment (subject repo:<owner>/<repo>:environment:<name>, so only this repository's
named environments get a token: not a fork, not a pull request), all of which Contributor can do. It then prints,
as Manual action required:
- the one role assignment an Owner, User Access Administrator, or Role Based Access Control Administrator
  runs once: Contributor on the subscription for the identity. With -AssignRole (or assignRoles true) it
  creates the assignment itself;
- optionally, making the identity an owner of the T3 administrators group (P6), so deploy.yml can add T1;
- the GitHub environments and their secrets (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, and
  DBHUB_CONFIG_JSON), with the 'gh secret set --env' commands. They're identifiers, not credentials; they're
  environment secrets so that GitHub masks them, because a public repository's Actions logs are public.

-ConfigureGitHub (opt-in) does the GitHub part itself with the GitHub CLI, as the account gh is signed in with
(run 'gh auth login' first; the script never signs in to GitHub or Azure): each environment gets you as its
required reviewer and deployments from the default branch only, then its secrets.
-ScheduleEnvironment (opt-in) adds a second environment, <environment>-schedule, for the scheduled workflows:
its own federated credential, the default branch only, and no reviewers, so scheduled runs don't wait for an
approval; it sets the repository variable DBHUB_SCHEDULE_ENVIRONMENT. The schedules stay off until you set
DBHUB_SCHEDULES_ENABLED to true yourself. See ADR 0022 for the trade-off.

It never signs in: sign in first with 'az login --tenant <tenantId>'. You don't need to change the Azure CLI's
default subscription. With -WhatIf, nothing is created in Azure or GitHub.

.PARAMETER ConfigPath
Demo configuration (default: config/demo.config.json). Its text becomes the DBHUB_CONFIG_JSON secret.

.PARAMETER Repository
owner/repo; defaults to github.repository.

.PARAMETER Environment
GitHub environment names; defaults to github.environment.

.PARAMETER AssignRole
Create the Contributor assignment (needs Microsoft.Authorization/roleAssignments/write).

.PARAMETER ConfigureGitHub
Create the GitHub environments and set their secrets with the GitHub CLI (opt-in).

.PARAMETER ScheduleEnvironment
Also create the schedule environment, with no reviewers, for the scheduled workflows only (opt-in).

.PARAMETER ScheduleEnvironmentName
The schedule environment's name (default: <environment>-schedule).

.PARAMETER OutputPath
Where to write the results as JSON lines.

.EXAMPLE
./scripts/setup-github-oidc.ps1 -Repository contoso/fabric-database-hub-demo -Environment demo -ConfigureGitHub

.EXAMPLE
./scripts/setup-github-oidc.ps1 -ConfigureGitHub -ScheduleEnvironment -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath = (Join-Path -Path $PSScriptRoot -ChildPath '../config/demo.config.json'),

    [string] $Repository = '',

    [string[]] $Environment = @(),

    [switch] $AssignRole,

    [switch] $ConfigureGitHub,

    [switch] $ScheduleEnvironment,

    [string] $ScheduleEnvironmentName = '',

    [string] $OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath '../out/setup-github-oidc.jsonl')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Reuse DbHubDemo when it's already loaded (for example by a test); otherwise load it.
if (-not (Get-Module -Name 'DbHubDemo')) {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'modules/DbHubDemo/DbHubDemo.psd1')
}

$config = Get-DemoConfig -Path $ConfigPath
$parameters = @{
    Config              = $config
    AssignRole          = $AssignRole
    ConfigureGitHub     = $ConfigureGitHub
    ScheduleEnvironment = $ScheduleEnvironment
    ConfigJson          = (Get-Content -LiteralPath $ConfigPath -Raw)
    WhatIf              = [bool]$WhatIfPreference
    Confirm             = $false
}
if ($Repository) {
    $parameters['Repository'] = $Repository
}
if ($Environment.Count -gt 0) {
    $parameters['Environment'] = $Environment
}
if ($ScheduleEnvironmentName) {
    $parameters['ScheduleEnvironmentName'] = $ScheduleEnvironmentName
}
$results = @(Initialize-DemoGitHubOidc @parameters)

Write-DemoResultReport -Result $results -Title 'setup-github-oidc.ps1'
Export-DemoResult -Result $results -Path $OutputPath
exit (Get-DemoExitCode -Result $results)
