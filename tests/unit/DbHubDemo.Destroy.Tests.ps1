BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    Initialize-GuardTestContext

    function New-TestConfig {
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
        return $config
    }

    function New-AzAnswer([int] $ExitCode = 0, [string] $StdOut = '', [string] $StdErr = '') {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr }
    }

    function New-FabricItem([string] $Type, [string] $Name, [string] $Id = '') {
        [pscustomobject]@{ type = $Type; displayName = $Name; id = $(if ($Id) { $Id } else { [guid]::NewGuid().ToString() }) }
    }

    # The control notebook's definition as Fabric returns it: an .ipynb part whose parameters cell names the group.
    function New-NotebookDefinition([string] $ResourceGroup) {
        $notebook = '{"cells":[{"cell_type":"code","source":["RESOURCE_GROUP = \"' + $ResourceGroup + '\"\n"]}]}'
        [pscustomobject]@{ definition = [pscustomobject]@{ parts = @([pscustomobject]@{ path = 'notebook-content.ipynb'; payload = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($notebook)) }) } }
    }

    # The demo's items in its own workspace, as the live ones were on 2026-11-17.
    function New-DemoWorkspaceItem {
        @(
            New-FabricItem 'AppBackend' 'APP_DatabaseHub_Insights'
            New-FabricItem 'KQLDashboard' 'RTD_DatabaseHub_LiveView'
            New-FabricItem 'Lakehouse' 'LH_DatabaseHub'
            New-FabricItem 'Notebook' 'NB_DatabaseHub_Deployment'
            New-FabricItem 'Notebook' 'NB_DatabaseHub_LiveActivity'
            New-FabricItem 'Report' 'RPT_DatabaseHub_History'
            New-FabricItem 'SemanticModel' 'SM_DatabaseHub_History'
            New-FabricItem 'SQLEndpoint' 'LH_DatabaseHub'
            New-FabricItem 'UserDataFunction' 'APP_DatabaseHub_Insights_connector'
        )
    }

    $script:token = [System.Security.SecureString]::new()
}

Describe 'Get-DemoDestroyControlPlan: whether the session control serves this environment (2026-11-17)' {
    BeforeEach {
        $config = New-TestConfig
        $script:groupAnswer = New-AzAnswer -StdOut "true`n"
        $script:runbook = @{}
        $script:accountAnswer = New-AzAnswer -StdOut '/subscriptions/x/resourceGroups/rg-dbhub-control/providers/Microsoft.Automation/automationAccounts/aa-dbhub-control'
        $script:resources = '[]'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $joined = $ArgumentList -join ' '
            if ($joined -match '^group exists --name rg-dbhub-control') { return $script:groupAnswer }
            if ($joined -match '/runbooks/(DbHub-\w+)/content') {
                $text = $script:runbook[$Matches[1]]
                if ($text) { return (New-AzAnswer -StdOut $text) }
                return (New-AzAnswer -ExitCode 1 -StdErr 'ERROR: (NotFound) The runbook was not found.')
            }
            if ($joined -match '^rest --method get --url https://management\.azure\.com/subscriptions/[^ ]+/automationAccounts/aa-dbhub-control\?') { return $script:accountAnswer }
            if ($joined -match '^resource list --resource-group rg-dbhub-control') { return ($script:resources | ConvertFrom-Json) }
            throw ('unexpected Azure CLI call: ' + $joined)
        }
    }

    It 'says there''s none when the control''s resource group doesn''t exist' {
        $script:groupAnswer = New-AzAnswer -StdOut "false`n"
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDestroyControlPlan -Config $Config }
        $plan.State | Should -Be 'None'
    }

    It 'serves this environment when its runbooks'' settings name this environment''s resource group, and another''s when they name another' {
        $script:runbook['DbHub-Stop'] = "`$settings = @'`n{""schemaVersion"":1,""demoResourceGroup"":""rg-dbhub-demo"",""controlResourceGroup"":""rg-dbhub-control""}`n'@"
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDestroyControlPlan -Config $Config }
        $plan.State | Should -Be 'Serves'
        $plan.ServedGroup | Should -Be 'rg-dbhub-demo'

        $script:runbook['DbHub-Stop'] = ''
        $script:runbook['DbHub-Control'] = '{"demoResourceGroup":"rg-dbhubother-demo"}'
        $other = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDestroyControlPlan -Config $Config }
        $other.State | Should -Be 'Other'
        $other.Reason | Should -Be 'its runbooks serve rg-dbhubother-demo, not rg-dbhub-demo'
    }

    It 'finds what an earlier destroy left once its Automation account went, and can''t tell otherwise' {
        $script:accountAnswer = New-AzAnswer -ExitCode 1 -StdErr 'ERROR: (ResourceNotFound) The Resource was not found.'
        # The deleted account's runbooks can still be listed for a moment (live, 2026-11-17), and they go with it.
        $script:resources = '["aa-dbhub-control/DbHub-Stop"]'
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDestroyControlPlan -Config $Config }
        $plan.State | Should -Be 'Leftover'
        @($plan.Resources) | Should -BeNullOrEmpty

        $script:resources = '["id-github-oidc"]'
        $kept = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDestroyControlPlan -Config $Config }
        $kept.State | Should -Be 'Leftover'
        $kept.Reason | Should -Match 'it holds id-github-oidc$'

        $script:accountAnswer = New-AzAnswer -ExitCode 1 -StdErr 'ERROR: (AuthorizationFailed) The client has no access.'
        $unknown = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDestroyControlPlan -Config $Config }
        $unknown.State | Should -Be 'Unknown'
    }
}

Describe 'Get-DemoDestroyFabricPlan: only workspaces that are this environment''s (2026-11-17)' {
    BeforeEach {
        $config = New-TestConfig
        $script:workspaces = @(
            [pscustomobject]@{ id = 'demo-ws'; displayName = 'Database Hub Demo' }
            [pscustomobject]@{ id = 'control-ws'; displayName = 'Database Hub Demo Control' }
        )
        $script:items = @{ 'demo-ws' = @(New-DemoWorkspaceItem); 'control-ws' = @(New-FabricItem 'Notebook' 'NB_DatabaseHub_Control' 'control-nb') }
        $script:listStatus = 200
        $script:servedGroup = 'rg-dbhub-demo'
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlFabricList -MockWith {
            if ($script:listStatus -ne 200) {
                return [pscustomobject]@{ StatusCode = $script:listStatus; Items = @(); Error = 'HTTP 404 CapacityNotActive: The capacity is not active.' }
            }
            if ($Uri -match '/workspaces$') { return [pscustomobject]@{ StatusCode = 200; Items = $script:workspaces; Error = '' } }
            if ($Uri -match '/workspaces/([^/]+)/items$') { return [pscustomobject]@{ StatusCode = 200; Items = @($script:items[$Matches[1]]); Error = '' } }
            throw ('unexpected list: ' + $Uri)
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -MockWith {
            if ($Method -eq 'Post' -and $Uri -match '/workspaces/control-ws/items/control-nb/getDefinition$') {
                return [pscustomobject]@{ StatusCode = 200; Body = (New-NotebookDefinition -ResourceGroup $script:servedGroup); Headers = @{} }
            }
            throw ('unexpected request: {0} {1}' -f $Method, $Uri)
        }
        $script:control = [pscustomobject]@{ Name = (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoActivityControlName -Config $Config }); State = 'Serves' }
        # Resource Graph's answer for the guard (2026-11-17): by default, no other demo environment.
        $script:claim = [pscustomobject]@{ Ok = $true; Error = ''; Others = @() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricWorkspaceClaim -MockWith { $script:claim }
    }

    It 'deletes the demo''s workspace when everything in it is the demo''s, and the control''s when its notebook serves this environment' {
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $script:token; Control = $script:control } { Get-DemoDestroyFabricPlan -Config $Config -Token $Token -Control $Control }
        $plan.Ok | Should -BeTrue
        $plan.Demo.Delete | Should -BeTrue
        $plan.Demo.Reason | Should -Be 'everything in it is the demo''s (9 item(s))'
        $plan.Control.Delete | Should -BeTrue
        $plan.Control.Reason | Should -Be 'its control notebook serves rg-dbhub-demo'
        # Only this environment: one Resource Graph query, and nothing kept for another.
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricWorkspaceClaim -Times 1 -Exactly
        $plan.Demo.Guard | Should -BeNullOrEmpty
    }

    It 'deletes the demo''s workspace with the Insights app''s functions item, which its deployment makes since 2026-11-18' {
        # dbhubc6, 2026-11-19: destroy.ps1 kept the workspace for "UserDataFunction APP_DatabaseHub_Insights", the app's
        # functions, which its backend makes under the app's own name (rayfin.yml services.functions).
        $script:items['demo-ws'] = @(New-DemoWorkspaceItem) + @(New-FabricItem 'UserDataFunction' 'APP_DatabaseHub_Insights')
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $script:token; Control = $script:control } { Get-DemoDestroyFabricPlan -Config $Config -Token $Token -Control $Control }
        $plan.Demo.Delete | Should -BeTrue
        $plan.Demo.Reason | Should -Be 'everything in it is the demo''s (10 item(s))'
    }

    It 'keeps a workspace another environment records as its own, and names it; the other workspace still goes (the shared-workspace guard)' {
        $script:claim = [pscustomobject]@{ Ok = $true; Error = ''; Others = @([pscustomobject]@{ Name = 'rg-dbhubfd-demo'; SubscriptionId = '11111111-2222-3333-4444-555555555555'; Label = 'rg-dbhubfd-demo'; Tagged = $true; Claims = @('demo-ws', '0a0a0a0a-0000-0000-0000-000000000001') }) }
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $script:token; Control = $script:control } { Get-DemoDestroyFabricPlan -Config $Config -Token $Token -Control $Control }
        $plan.Demo.Delete | Should -BeFalse
        $plan.Demo.Guard | Should -Be 'Claimed'
        $plan.Demo.Reason | Should -Be 'rg-dbhubfd-demo records it as its own'
        @($plan.Demo.ClaimedBy) | Should -Be @('rg-dbhubfd-demo')
        $plan.Demo.Remediation | Should -Match '^Run \./scripts/destroy\.ps1 again once rg-dbhubfd-demo is destroyed, or delete it in Fabric once nothing uses it \(Workspace settings > Remove this workspace\)\. To keep environments apart, give each its own fabric\.workspaceName and control\.fabricWorkspaceName\.$'
        $plan.Control.Delete | Should -BeTrue -Because 'no other environment records the control''s workspace'
    }

    It 'keeps both while a demo environment deployed by an earlier version, which records no workspace, might use them' {
        $script:claim = [pscustomobject]@{ Ok = $true; Error = ''; Others = @([pscustomobject]@{ Name = 'rg-dbhub-demo'; SubscriptionId = '99999999-2222-3333-4444-555555555555'; Label = 'rg-dbhub-demo (subscription 99999999-2222-3333-4444-555555555555)'; Tagged = $false; Claims = @() }) }
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $script:token; Control = $script:control } { Get-DemoDestroyFabricPlan -Config $Config -Token $Token -Control $Control }
        foreach ($workspace in $plan.Demo, $plan.Control) {
            $workspace.Delete | Should -BeFalse
            $workspace.Guard | Should -Be 'Untagged'
            $workspace.Reason | Should -Be 'rg-dbhub-demo (subscription 99999999-2222-3333-4444-555555555555) was deployed by an earlier version of the demo, which doesn''t record the workspaces it uses, so it might use it'
            $workspace.Remediation | Should -Match '^Run \./scripts/destroy\.ps1 again after the next \./scripts/deploy\.ps1 of rg-dbhub-demo \(subscription 99999999-2222-3333-4444-555555555555\), which records the workspaces it uses, or after its destroy; or delete it in Fabric once nothing uses it'
        }
    }

    It 'says an environment being deployed hasn''t recorded its workspaces yet, never that an earlier version deployed it, and keeps both with the same fix (the final tests'' F15)' {
        # Live, 2026-11-19: destroy.ps1 of dbhubfx ran while dbhubfy was being deployed, before its Control step recorded its
        # workspaces, and said rg-dbhubfy-demo "was deployed by an earlier version of the demo".
        $script:claim = [pscustomobject]@{ Ok = $true; Error = ''; Others = @([pscustomobject]@{ Name = 'rg-dbhubfy-demo'; SubscriptionId = '11111111-2222-3333-4444-555555555555'; Label = 'rg-dbhubfy-demo'; Tagged = $false; Deployment = 'Running'; Claims = @() }) }
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $script:token; Control = $script:control } { Get-DemoDestroyFabricPlan -Config $Config -Token $Token -Control $Control }
        foreach ($workspace in $plan.Demo, $plan.Control) {
            $workspace.Delete | Should -BeFalse -Because 'a workspace it might use is still kept'
            $workspace.Guard | Should -Be 'Untagged'
            $workspace.Reason | Should -Be 'rg-dbhubfy-demo is being deployed and hasn''t recorded its workspaces yet, so it might use it'
            $workspace.Remediation | Should -Be 'Run ./scripts/destroy.ps1 again after the next ./scripts/deploy.ps1 of rg-dbhubfy-demo, which records the workspaces it uses, or after its destroy; or delete it in Fabric once nothing uses it (Workspace settings > Remove this workspace).'
        }

        # Each one says its own, and the fix still names them all.
        $others = foreach ($case in @(
                @{ Name = 'rg-dbhuba-demo'; Deployment = 'Running' }
                @{ Name = 'rg-dbhubb-demo'; Deployment = 'Running' }
                @{ Name = 'rg-dbhubc-demo'; Deployment = 'Unfinished' }
                @{ Name = 'rg-dbhubd-demo'; Deployment = '' }
            )) {
            [pscustomobject]@{ Name = $case.Name; SubscriptionId = '11111111-2222-3333-4444-555555555555'; Label = $case.Name; Tagged = $false; Deployment = $case.Deployment; Claims = @() }
        }
        $script:claim = [pscustomobject]@{ Ok = $true; Error = ''; Others = @($others) }
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $script:token; Control = $script:control } { Get-DemoDestroyFabricPlan -Config $Config -Token $Token -Control $Control }
        $plan.Demo.Delete | Should -BeFalse
        $plan.Demo.Reason | Should -Be 'rg-dbhuba-demo and rg-dbhubb-demo are being deployed and haven''t recorded their workspaces yet, so they might use it; rg-dbhubc-demo hasn''t finished deploying and hasn''t recorded its workspaces yet, so it might use it; rg-dbhubd-demo was deployed by an earlier version of the demo, which doesn''t record the workspaces it uses, so it might use it'
        $plan.Demo.Remediation | Should -Be 'Run ./scripts/destroy.ps1 again after the next ./scripts/deploy.ps1 of rg-dbhuba-demo, rg-dbhubb-demo, rg-dbhubc-demo, and rg-dbhubd-demo, which records the workspaces each uses, or after their destroy; or delete it in Fabric once nothing uses it (Workspace settings > Remove this workspace).'
    }

    It 'keeps both when Resource Graph can''t be read, and says so' {
        $script:claim = [pscustomobject]@{ Ok = $false; Error = 'AuthorizationFailed: no access.'; Others = @() }
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $script:token; Control = $script:control } { Get-DemoDestroyFabricPlan -Config $Config -Token $Token -Control $Control }
        foreach ($workspace in $plan.Demo, $plan.Control) {
            $workspace.Delete | Should -BeFalse
            $workspace.Guard | Should -Be 'Unreadable'
            $workspace.Reason | Should -Be 'Azure Resource Graph couldn''t be read, so destroy.ps1 can''t tell whether another environment uses it (AuthorizationFailed: no access)'
            $workspace.Remediation | Should -Match '^Run \./scripts/destroy\.ps1 again when Azure Resource Graph answers; or delete it in Fabric once nothing uses it'
        }
    }

    It 'keeps a workspace with anything the demo didn''t create, and names it' {
        $script:items['demo-ws'] = @(New-DemoWorkspaceItem) + @(New-FabricItem 'OrgApp' 'APP_DatabaseHub_Demo')
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $script:token; Control = $script:control } { Get-DemoDestroyFabricPlan -Config $Config -Token $Token -Control $Control }
        $plan.Demo.Delete | Should -BeFalse
        $plan.Demo.Reason | Should -Be 'it holds what the demo didn''t create: OrgApp APP_DatabaseHub_Demo'
    }

    It 'keeps a control workspace whose notebook serves another environment, such as the owner''s under a shared name' {
        $script:servedGroup = 'rg-dbhubowner-demo'
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $script:token; Control = $script:control } { Get-DemoDestroyFabricPlan -Config $Config -Token $Token -Control $Control }
        $plan.Control.Delete | Should -BeFalse
        $plan.Control.Reason | Should -Be 'its control notebook serves rg-dbhubowner-demo, not rg-dbhub-demo'
        $plan.Demo.Delete | Should -BeTrue
    }

    It 'says why nothing was listed when the capacity is paused' {
        $script:listStatus = 404
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $script:token; Control = $script:control } { Get-DemoDestroyFabricPlan -Config $Config -Token $Token -Control $Control }
        $plan.Ok | Should -BeFalse
        $plan.Kind | Should -Be 'CapacityInactive'
    }
}

Describe 'Get-DemoFabricDemoItem: what the Insights app''s deployment makes beside the app (2026-11-19)' {
    It 'lists an item for each service the app''s rayfin.yml enables, and rayfin.yml enables none that makes another' {
        # The app's backend makes a user data function for its connectors (<app>_connector) and one for its functions (the
        # app's name); the data and storage services would make a SQL database or a lakehouse that destroy.ps1 doesn't know.
        $yml = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'fabric/app/rayfin/rayfin.yml') -Raw
        $enabled = { param([string] $Service) $yml -match ('(?m)^  {0}:[ \t]*\r?\n(?:    .*\r?\n)*?    enabled:[ \t]*true\b' -f $Service) }
        $listed = @(InModuleScope DbHubDemo { Get-DemoFabricDemoItem -LakehouseName 'LH_DatabaseHub' } | ForEach-Object { '{0} {1}' -f $_.Type, $_.Name })
        $listed | Should -Contain 'AppBackend APP_DatabaseHub_Insights'
        (& $enabled 'functions') | Should -BeTrue
        $listed | Should -Contain 'UserDataFunction APP_DatabaseHub_Insights'
        $yml | Should -Match '(?m)^connectors:[ \t]*\r?\n(?:[ \t]+.*\r?\n)*?  - name:'
        $listed | Should -Contain 'UserDataFunction APP_DatabaseHub_Insights_connector'
        foreach ($service in 'data', 'storage') {
            (& $enabled $service) | Should -BeFalse -Because "services.$service would make an item destroy.ps1 doesn't list"
        }
    }
}

Describe 'Get-DemoFabricWorkspaceClaim: the other demo environments, across the subscriptions the caller can read (2026-11-17)' {
    BeforeEach {
        $config = New-TestConfig
        $script:subscription = '11111111-2222-3333-4444-555555555555'
        $script:graphCalls = [System.Collections.Generic.List[object]]::new()
        $group = { param([string] $Name, [hashtable] $Tags, [string] $Subscription = $script:subscription) [pscustomobject]@{ id = ('/subscriptions/{0}/resourceGroups/{1}' -f $Subscription, $Name); name = $Name; type = 'microsoft.resources/subscriptions/resourcegroups'; subscriptionId = $Subscription; tags = [pscustomobject]$Tags } }
        $script:rows = @(
            [pscustomobject]@{ id = ('/subscriptions/{0}' -f $script:subscription); name = 'Demo subscription'; type = 'microsoft.resources/subscriptions'; subscriptionId = $script:subscription; tags = $null }
            # This environment's own group isn't another environment.
            & $group 'rg-dbhub-demo' @{ deploymentId = 'aaaaaa'; DbHubDeployStage = 'Validation'; DbHubFabricWorkspaceId = 'dddddddd-0000-0000-0000-000000000001' }
            # Another environment on this code: it records its workspaces.
            & $group 'rg-dbhubfd-demo' @{ deploymentId = 'bbbbbb'; DbHubDeployStage = 'Validation'; DbHubFabricWorkspaceId = 'DDDDDDDD-0000-0000-0000-000000000002'; DbHubControlWorkspaceId = 'cccccccc-0000-0000-0000-000000000002' }
            # One deployed by an earlier version, like the owner's: no workspace recorded, and its tag's name in another case.
            & $group 'rg-dbhubowner-demo' @{ DEPLOYMENTID = 'cccccc' }
            # The golden group and a session control's group carry solution, but neither environment tag.
            & $group 'rg-dbhub-golden' @{ environment = 'golden'; solution = 'fabric-database-hub-demo' }
            & $group 'rg-dbhub-control' @{ component = 'activity-control'; solution = 'fabric-database-hub-demo' }
            # Another subscription's environment, whose only record isn't a workspace ID.
            & $group 'rg-dbhub-demo' @{ deploymentId = 'eeeeee'; DbHubFabricWorkspaceId = 'not-an-id' } '99999999-2222-3333-4444-555555555555'
        )
        $script:graph = { [pscustomobject]@{ Succeeded = $true; Error = ''; Rows = $script:rows; Truncated = $false } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoHubResourceGraph -MockWith { $script:graphCalls.Add([pscustomobject]@{ Query = $Query; All = [bool]$PesterBoundParameters['AllSubscriptions']; SubscriptionId = $SubscriptionId }); & $script:graph }
    }

    It 'lists every other demo environment with what it records, in one query across the subscriptions the caller can read' {
        $claim = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoFabricWorkspaceClaim -Config $Config }
        $claim.Ok | Should -BeTrue
        $script:graphCalls.Count | Should -Be 1
        $script:graphCalls[0].All | Should -BeTrue
        $script:graphCalls[0].Query | Should -Match '^resourcecontainers \| where \(type =~ ''microsoft\.resources/subscriptions'' and subscriptionId =~ ''11111111-2222-3333-4444-555555555555''\)'
        @($claim.Others | ForEach-Object { $_.Label }) | Should -Be @('rg-dbhubfd-demo', 'rg-dbhubowner-demo', 'rg-dbhub-demo (subscription 99999999-2222-3333-4444-555555555555)')
        $fd = $claim.Others[0]
        $fd.Tagged | Should -BeTrue
        @($fd.Claims) | Should -Be @('dddddddd-0000-0000-0000-000000000002', 'cccccccc-0000-0000-0000-000000000002')
        $claim.Others[1].Tagged | Should -BeFalse -Because 'an earlier version records no workspace'
        $claim.Others[2].Tagged | Should -BeFalse -Because 'a record that isn''t a workspace ID doesn''t count'
        # 2026-11-19: this environment's own group, which deploy.ps1's DEPLOY.FABRIC.SHARED compares with the others.
        $claim.Own.Found | Should -BeTrue
        $claim.Own.FabricWorkspaceId | Should -Be 'dddddddd-0000-0000-0000-000000000001'
        @($claim.Own.Claims) | Should -Be @('dddddddd-0000-0000-0000-000000000001')
        $claim.Own.UsedFabric | Should -BeTrue -Because 'its last finished stage, Validation, comes after Fabric'
    }

    It 'says whether this environment''s own group finished a Fabric step, which one deployed before 2026-11-17 did without recording its workspace' {
        foreach ($case in @(
                @{ Tags = @{ deploymentId = 'aaaaaa'; DbHubTrackFabric = 'Fabric' }; Used = $true }
                @{ Tags = @{ deploymentId = 'aaaaaa'; DbHubDeployStage = 'Fabric' }; Used = $true }
                @{ Tags = @{ deploymentId = 'aaaaaa'; DbHubDeployStage = 'Infrastructure'; DbHubTrackFabric = '' }; Used = $false }
            )) {
            $script:rows = @(
                [pscustomobject]@{ id = ('/subscriptions/{0}' -f $script:subscription); name = 'Demo subscription'; type = 'microsoft.resources/subscriptions'; subscriptionId = $script:subscription; tags = $null }
                [pscustomobject]@{ id = ('/subscriptions/{0}/resourceGroups/rg-dbhub-demo' -f $script:subscription); name = 'rg-dbhub-demo'; type = 'microsoft.resources/subscriptions/resourcegroups'; subscriptionId = $script:subscription; tags = [pscustomobject]$case.Tags }
            )
            $claim = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoFabricWorkspaceClaim -Config $Config }
            $claim.Own.Found | Should -BeTrue
            $claim.Own.FabricWorkspaceId | Should -BeNullOrEmpty
            $claim.Own.UsedFabric | Should -Be $case.Used
            @($claim.Others).Count | Should -Be 0
        }
        $script:rows = @($script:rows | Select-Object -First 1)
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoFabricWorkspaceClaim -Config $Config }).Own.Found | Should -BeFalse -Because 'a new environment has no group yet'
    }

    It 'tells another environment that''s being deployed, or whose deployment hasn''t finished, from one an earlier version deployed (the final tests'' F15)' {
        $now = [datetime]::new(2026, 11, 19, 23, 0, 0, [System.DateTimeKind]::Utc)
        $ahead = '2026-11-19T23:40:00Z'
        $past = '2026-11-19T22:00:00Z'
        $script:rows = @(
            $script:rows[0]
            # dbhubfy, live: a first deployment before its Control step, with its busy marker ahead.
            & $group 'rg-dbhubfy-demo' @{ deploymentId = 'f1'; DbHubDeployStage = 'Infrastructure'; DbHubBusyBy = 'deploy'; DbHubBusyUntilUtc = $ahead }
            # An update of a finished environment while it runs: its stage is still the last run's.
            & $group 'rg-dbhubup-demo' @{ deploymentId = 'f2'; DbHubDeployStage = 'Validation'; DbHubBusyBy = 'deploy'; DbHubBusyUntilUtc = $ahead }
            # A run that stopped before the end (NOT DONE), and one whose window closed, so its marker is past.
            & $group 'rg-dbhubnd-demo' @{ deploymentId = 'f3'; DbHubDeployStage = 'T2' }
            & $group 'rg-dbhubcr-demo' @{ deploymentId = 'f4'; DbHubDeployStage = 'Monitoring'; DbHubBusyBy = 'deploy'; DbHubBusyUntilUtc = $past }
            # Finished: a session that's going, a run the nightly stop waited for, an expired run's marker, and only the template's tag.
            & $group 'rg-dbhubss-demo' @{ deploymentId = 'f5'; DbHubDeployStage = 'Validation'; DbHubBusyBy = 'session'; DbHubBusyUntilUtc = $ahead }
            & $group 'rg-dbhubgr-demo' @{ deploymentId = 'f6'; DbHubDeployStage = 'Validation'; DbHubBusyBy = 'deploy-grace'; DbHubBusyUntilUtc = $ahead }
            & $group 'rg-dbhubex-demo' @{ deploymentId = 'f7'; DbHubDeployStage = 'Validation'; DbHubBusyBy = 'deploy'; DbHubBusyUntilUtc = $past }
            & $group 'rg-dbhubol-demo' @{ deploymentId = 'f8' }
        )
        $claim = InModuleScope DbHubDemo -Parameters @{ Config = $config; Now = $now } { Get-DemoFabricWorkspaceClaim -Config $Config -NowUtc $Now }
        $claim.Ok | Should -BeTrue
        @($claim.Others | ForEach-Object { '{0}={1}' -f $_.Name, $_.Deployment }) | Should -Be @('rg-dbhubfy-demo=Running', 'rg-dbhubup-demo=Running', 'rg-dbhubnd-demo=Unfinished', 'rg-dbhubcr-demo=Unfinished', 'rg-dbhubss-demo=', 'rg-dbhubgr-demo=', 'rg-dbhubex-demo=', 'rg-dbhubol-demo=')
        @($claim.Others | Where-Object { $_.Tagged }) | Should -BeNullOrEmpty
    }

    It 'can''t tell when Resource Graph fails, cuts its answer short, throws, or doesn''t list the subscription' {
        foreach ($case in @(
                @{ Graph = { [pscustomobject]@{ Succeeded = $false; Error = 'AccessDenied'; Rows = @(); Truncated = $false } }; Error = '^AccessDenied$' }
                @{ Graph = { [pscustomobject]@{ Succeeded = $true; Error = ''; Rows = $script:rows; Truncated = $true } }; Error = 'cut short' }
                @{ Graph = { throw 'The token''s tenant isn''t the configured one.' }; Error = 'tenant isn''t the configured one' }
                @{ Graph = { [pscustomobject]@{ Succeeded = $true; Error = ''; Rows = @($script:rows | Select-Object -Skip 1); Truncated = $false } }; Error = '^Resource Graph didn''t list the subscription 11111111-2222-3333-4444-555555555555' }
            )) {
            $script:graph = $case.Graph
            $claim = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoFabricWorkspaceClaim -Config $Config }
            $claim.Ok | Should -BeFalse
            $claim.Error | Should -Match $case.Error
        }
    }
}

Describe 'Invoke-DemoHubResourceGraph -AllSubscriptions (2026-11-17)' {
    It 'sends no subscription list for a query across every subscription the caller can read, and the configured one otherwise' {
        $script:bodies = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith { $script:bodies.Add([string]$Body); [pscustomobject]@{ ExitCode = 0; StatusCode = 200; StdOut = '{"data":[],"resultTruncated":"false"}'; StdErr = '' } }
        $null = InModuleScope DbHubDemo { Invoke-DemoHubResourceGraph -SubscriptionId '11111111-2222-3333-4444-555555555555' -Query 'resourcecontainers | limit 1' -AllSubscriptions }
        $null = InModuleScope DbHubDemo { Invoke-DemoHubResourceGraph -SubscriptionId '11111111-2222-3333-4444-555555555555' -Query 'resourcecontainers | limit 1' }
        ($script:bodies[0] | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'subscriptions'
        @(($script:bodies[1] | ConvertFrom-Json).subscriptions) | Should -Be @('11111111-2222-3333-4444-555555555555')
    }
}

Describe 'Get-DemoDestroyGroupPlan: only the group init.ps1 created for this environment (2026-11-17)' {
    BeforeEach {
        $config = New-TestConfig
        $script:graph = [pscustomobject]@{ ExitCode = 0; StatusCode = 200; StdErr = ''; StdOut = '{"id":"77777777-7777-7777-7777-777777777777","displayName":"dbhub-demo-sql-admins","description":"Microsoft Entra administrators of T3 and T4 in the Fabric Database Hub demo (prerequisite P6). Created by init.ps1."}' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith { $script:graph }
    }

    It 'deletes it when its description records init.ps1 and it has this environment''s name' {
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDestroyGroupPlan -Config $Config }
        $plan.State | Should -Be 'Delete'
        $plan.Name | Should -Be 'dbhub-demo-sql-admins'
    }

    It 'keeps a group you supplied, and one init.ps1 made under another environment''s name' {
        $script:graph.StdOut = '{"id":"77777777-7777-7777-7777-777777777777","displayName":"dbhub-demo-sql-admins","description":"Our DBAs"}'
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDestroyGroupPlan -Config $Config }).Reason | Should -Be 'init.ps1 didn''t create it (you supplied it)'
        $script:graph.StdOut = '{"id":"77777777-7777-7777-7777-777777777777","displayName":"dbhubowner-demo-sql-admins","description":"Created by init.ps1."}'
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDestroyGroupPlan -Config $Config }
        $plan.State | Should -Be 'Keep'
        $plan.Reason | Should -Match 'another name than this environment''s \(dbhub-demo-sql-admins\)'
    }

    It 'says when it''s gone, and when the configuration names none' {
        $script:graph = [pscustomobject]@{ ExitCode = 1; StatusCode = 404; StdErr = 'Request_ResourceNotFound'; StdOut = '' }
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDestroyGroupPlan -Config $Config }).State | Should -Be 'Gone'
        $config['t3AdminGroupObjectId'] = '00000000-0000-0000-0000-000000000000'
        (InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoDestroyGroupPlan -Config $Config }).State | Should -Be 'None'
    }
}

Describe 'Custom role definitions go only when nothing holds them (2026-11-17)' {
    BeforeEach {
        $script:count = '0'
        $script:deleted = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $joined = $ArgumentList -join ' '
            if ($joined -match '^role assignment list --all --role (\S+) --fill-principal-name false') { return (New-AzAnswer -StdOut ("{0}`n" -f $script:count)) }
            throw ('unexpected Azure CLI call: ' + $joined)
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoActivityControlArm -MockWith { $script:deleted.Add($Url); [pscustomobject]@{ Ok = $true; Missing = $false; Value = $null; Error = '' } }
    }

    It 'deletes a definition no assignment holds, and keeps one that''s held' {
        $outcome = InModuleScope DbHubDemo { Remove-DemoUnassignedRoleDefinition -SubscriptionId '11111111-2222-3333-4444-555555555555' -RoleId 'aaaaaaaa-0000-0000-0000-000000000001' }
        $outcome.Outcome | Should -Be 'Deleted'
        $script:deleted | Should -Match '/roleDefinitions/aaaaaaaa-0000-0000-0000-000000000001\?'

        $script:deleted.Clear()
        $script:count = '3'
        $kept = InModuleScope DbHubDemo { Remove-DemoUnassignedRoleDefinition -SubscriptionId '11111111-2222-3333-4444-555555555555' -RoleId 'aaaaaaaa-0000-0000-0000-000000000001' }
        $kept.Outcome | Should -Be 'Kept'
        $kept.Count | Should -Be 3
        $script:deleted | Should -BeNullOrEmpty
    }

    It 'keeps the owner''s roles when a test environment''s control goes: its own assignments go, the definitions others hold stay' {
        $config = New-TestConfig
        $name = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoActivityControlName -Config $Config }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlRoleId -MockWith { if ($RoleName -match 'Writer') { 'bbbbbbbb-0000-0000-0000-000000000002' } else { 'aaaaaaaa-0000-0000-0000-000000000001' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlPrincipalId -MockWith { 'dddddddd-0000-0000-0000-000000000004' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlList -MockWith { @() }
        $script:count = '2'
        $result = InModuleScope DbHubDemo -Parameters @{ Name = $name } { Remove-DemoActivityControlRole -Name $Name -Confirm:$false }
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'the custom role "DbHub Demo Activity Operator" was kept: 2 role assignment\(s\) still hold it'
        @($script:deleted | Where-Object { $_ -match '/roleDefinitions/' }) | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DemoDestroyExtra: each part deletes what''s this environment''s and reports itself (2026-11-17)' {
    BeforeEach {
        $config = New-TestConfig
        $name = InModuleScope DbHubDemo -Parameters @{ Config = $config } { Get-DemoActivityControlName -Config $Config }
        $script:requests = [System.Collections.Generic.List[string]]::new()
        $script:deleteStatus = 200
        Mock -ModuleName DbHubDemo -CommandName Get-DemoActivityControlFabricList -MockWith { [pscustomobject]@{ StatusCode = 200; Items = @($(if ($Uri -match 'control-ws/managedPrivateEndpoints') { [pscustomobject]@{ id = 'mpe-1' } })); Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -MockWith {
            $script:requests.Add(('{0} {1}' -f $Method, ($Uri -replace '^https://api\.fabric\.microsoft\.com/v1', '')))
            [pscustomobject]@{ StatusCode = $(if ($Uri -match '/workspaces/[^/]+$') { $script:deleteStatus } else { 200 }); Body = [pscustomobject]@{ errorCode = 'CapacityNotActive'; message = 'The capacity is not active.' }; Headers = @{} }
        }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoActivityControlRole -MockWith { $script:requests.Add('roles'); New-DemoResult -CheckId 'CONTROL.REMOVE.ROLES' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message 'roles' }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoActivityControlResource -MockWith { $script:requests.Add('resources'); New-DemoResult -CheckId 'CONTROL.REMOVE.RESOURCES' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message 'resources' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith { $script:requests.Add(('{0} {1}' -f $Method, $Uri)); [pscustomobject]@{ ExitCode = 0; StatusCode = 204; StdOut = ''; StdErr = '' } }
        $workspace = { param([string] $Id, [string] $Name, [bool] $Delete, [string] $Reason) [pscustomobject]@{ Name = $Name; Id = $Id; Exists = $true; Delete = $Delete; Items = @('Notebook NB_DatabaseHub_Control'); Foreign = @(); Notebook = ''; Reason = $Reason } }
        $script:plan = [pscustomobject]@{
            Control = [pscustomobject]@{ Name = $name; State = 'Serves'; ServedGroup = 'rg-dbhub-demo'; Resources = @(); Reason = 'its runbooks serve rg-dbhub-demo' }
            Fabric  = [pscustomobject]@{ Read = $true; Token = $script:token; Reason = ''; Plan = [pscustomobject]@{ Ok = $true; Error = ''; Kind = ''; Demo = (& $workspace 'demo-ws' 'Database Hub Demo' $true 'everything in it is the demo''s (9 item(s))'); Control = (& $workspace 'control-ws' 'Database Hub Demo Control' $true 'its control notebook serves rg-dbhub-demo') } }
            Group   = [pscustomobject]@{ Id = '77777777-7777-7777-7777-777777777777'; Name = 'dbhub-demo-sql-admins'; State = 'Delete'; Reason = 'init.ps1 created it for this environment' }
            Delete  = @()
            Keep    = @()
        }
    }

    It 'deletes the control''s workspace with its endpoint, the demo''s workspace, the control, and the group, in that order' {
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Plan = $script:plan } { Invoke-DemoDestroyExtra -Config $Config -Plan $Plan })
        @($script:requests) | Should -Be @('Delete /workspaces/control-ws/managedPrivateEndpoints/mpe-1', 'Delete /workspaces/control-ws', 'Delete /workspaces/demo-ws', 'roles', 'resources', 'DELETE https://graph.microsoft.com/v1.0/groups/77777777-7777-7777-7777-777777777777')
        @($results | ForEach-Object { $_.checkId }) | Should -Be @('DESTROY.FABRIC.CONTROL', 'DESTROY.FABRIC.WORKSPACE', 'DESTROY.CONTROL', 'DESTROY.CONTROL.ROLES', 'DESTROY.CONTROL.RESOURCES', 'DESTROY.ENTRA.GROUP')
        @($results | Where-Object { $_.status -ne 'Pass' }) | Should -BeNullOrEmpty
        ($results | Where-Object { $_.checkId -eq 'DESTROY.FABRIC.CONTROL' }).message | Should -Match '^Deleted the Fabric workspace "Database Hub Demo Control" and its 1 managed private endpoint\(s\)'
    }

    It 'keeps both workspaces with -KeepFabric, and what isn''t this environment''s, and says why' {
        $script:plan.Fabric = [pscustomobject]@{ Read = $false; Token = $null; Plan = $null; Reason = '-KeepFabric' }
        $script:plan.Control = [pscustomobject]@{ Name = $script:plan.Control.Name; State = 'Other'; ServedGroup = 'rg-dbhubowner-demo'; Resources = @(); Reason = 'its runbooks serve rg-dbhubowner-demo, not rg-dbhub-demo' }
        $script:plan.Group = [pscustomobject]@{ Id = '77777777-7777-7777-7777-777777777777'; Name = 'Our DBAs'; State = 'Keep'; Reason = 'init.ps1 didn''t create it (you supplied it)' }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Plan = $script:plan } { Invoke-DemoDestroyExtra -Config $Config -Plan $Plan })
        $script:requests | Should -BeNullOrEmpty
        ($results | Where-Object { $_.checkId -eq 'DESTROY.FABRIC.WORKSPACE' }).message | Should -Be 'The demo''s workspace stays with its items and the history (-KeepFabric).'
        $control = $results | Where-Object { $_.checkId -eq 'DESTROY.CONTROL' }
        $control.status | Should -Be 'Not selected'
        $control.message | Should -Be 'The session control in rg-dbhub-control stays: its runbooks serve rg-dbhubowner-demo, not rg-dbhub-demo.'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.ENTRA.GROUP' }).message | Should -Match 'stays: init\.ps1 didn''t create it \(you supplied it\)\.$'
    }

    It 'keeps a workspace the guard kept as a Warning with its fix, and still deletes what''s free (2026-11-17)' {
        $script:plan.Fabric.Plan.Demo = [pscustomobject]@{ Name = 'Database Hub Demo'; Id = 'demo-ws'; Exists = $true; Delete = $false; Items = @(); Foreign = @(); Notebook = ''; Reason = 'rg-dbhub-demo was deployed by an earlier version of the demo, which doesn''t record the workspaces it uses, so it might use it'; Guard = 'Untagged'; ClaimedBy = @(); Untagged = @('rg-dbhub-demo'); Remediation = 'Run ./scripts/destroy.ps1 again after the next ./scripts/deploy.ps1 of rg-dbhub-demo.' }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Plan = $script:plan } { Invoke-DemoDestroyExtra -Config $Config -Plan $Plan })
        @($script:requests) | Should -Not -Contain 'Delete /workspaces/demo-ws'
        @($script:requests) | Should -Contain 'Delete /workspaces/control-ws'
        $workspace = $results | Where-Object { $_.checkId -eq 'DESTROY.FABRIC.WORKSPACE' }
        $workspace.status | Should -Be 'Warning'
        $workspace.message | Should -Be 'The Fabric workspace "Database Hub Demo" stays: rg-dbhub-demo was deployed by an earlier version of the demo, which doesn''t record the workspaces it uses, so it might use it.'
        $workspace.remediation | Should -Be 'Run ./scripts/destroy.ps1 again after the next ./scripts/deploy.ps1 of rg-dbhub-demo.'
        @($workspace.evidence.untagged) | Should -Be @('rg-dbhub-demo')
    }

    It 'says to resume a paused capacity, and goes on with the other parts when one stops' {
        $script:deleteStatus = 404
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricRequest -MockWith {
            $script:requests.Add(('{0} {1}' -f $Method, ($Uri -replace '^https://api\.fabric\.microsoft\.com/v1', '')))
            [pscustomobject]@{ StatusCode = $(if ($Uri -match '/workspaces/[^/]+$') { 400 } else { 200 }); Body = [pscustomobject]@{ errorCode = 'CapacityNotActive'; message = 'The capacity is not active.' }; Headers = @{} }
        }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoActivityControlRole -MockWith { throw 'Azure Resource Manager timed out' }
        $results = @(InModuleScope DbHubDemo -Parameters @{ Config = $config; Plan = $script:plan } { Invoke-DemoDestroyExtra -Config $Config -Plan $Plan })
        $workspace = $results | Where-Object { $_.checkId -eq 'DESTROY.FABRIC.WORKSPACE' }
        $workspace.status | Should -Be 'Warning'
        $workspace.remediation | Should -Match '^Its Fabric capacity is paused: resume it \(or ask its administrator\), then run \./scripts/destroy\.ps1 again\.'
        $control = $results | Where-Object { $_.checkId -eq 'DESTROY.CONTROL' }
        $control.status | Should -Be 'Warning'
        $control.message | Should -Match 'This part stopped: Azure Resource Manager timed out'
        ($results | Where-Object { $_.checkId -eq 'DESTROY.ENTRA.GROUP' }).status | Should -Be 'Pass' -Because 'one part that stops doesn''t stop the others'
    }
}

Describe 'Remove-DemoEnvironment lists what it deletes and keeps before it asks (2026-11-17)' {
    BeforeEach {
        $config = New-TestConfig
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoResourceGroupExist -MockWith { $true }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDestroyExtraPlan -MockWith {
            $script:keepFabric = [bool]$KeepFabric
            [pscustomobject]@{ Control = $null; Fabric = $null; Group = $null; Delete = @('the Fabric workspace "Database Hub Demo" (everything in it is the demo''s (9 item(s)))'); Keep = @('the Fabric capacity and your licenses, which you manage') }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDestroyExtra -MockWith { throw 'nothing is deleted in a what-if' }
        # Whether the golden group exists is read before the list (2026-11-19); nothing else reaches the Azure CLI first.
        $script:goldenAnswer = "true`n"
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            if (($ArgumentList -join ' ') -match '^group exists --name rg-dbhub-golden ') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:goldenAnswer; StdErr = '' }
            }
            throw 'nothing is deleted in a what-if'
        }
    }

    It 'names each in a what-if, deletes nothing, and passes -KeepFabric on' {
        $result = @(Remove-DemoEnvironment -Config $config -KeepFabric -WhatIf)
        $result[-1].checkId | Should -Be 'DESTROY.RESOURCEGROUP'
        $result[-1].message | Should -Match 'would delete the Arc resources, rg-dbhub-demo and everything in it, the subscription deployment record, and the budget; the Fabric workspace "Database Hub Demo"'
        $result[-1].message | Should -Match 'and keep the Fabric capacity and your licenses, which you manage; rg-dbhub-golden and its golden snapshots \(-IncludeGolden deletes them\)\.$'
        $script:keepFabric | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -eq 'destroy.ps1 keeps the Fabric capacity and your licenses, which you manage.' } -Times 1 -Exactly
    }

    It 'leaves a golden group that doesn''t exist out of what it keeps, and says it doesn''t exist (2026-11-19)' {
        $script:goldenAnswer = "false`n"
        $result = @(Remove-DemoEnvironment -Config $config -WhatIf)
        $result[-1].message | Should -Match 'and keep the Fabric capacity and your licenses, which you manage\. rg-dbhub-golden doesn''t exist, so there''s no golden snapshot\.$'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -eq 'rg-dbhub-golden doesn''t exist, so there''s no golden snapshot.' } -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -like '*keeps rg-dbhub-golden*' } -Times 0 -Exactly
    }

    It 'says before it asks to remove T3 from Database agent settings and Save, and why, with Learn''s page; nothing without T3''s name (2026-11-20)' {
        # Live, 2026-11-20: T3s that earlier destroys had deleted stayed in the tenant's selection, and every Save failed.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDestroyExtraPlan -MockWith {
            [pscustomobject]@{ Control = $null; Fabric = $null; Group = $null; T3Agent = 'azuresql01-abc123'; Delete = @(); Keep = @('the Fabric capacity and your licenses, which you manage') }
        }
        $result = @(Remove-DemoEnvironment -Config $config -WhatIf)
        $result.checkId | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'DESTROY.RESOURCEGROUP') -Because 'a what-if deletes nothing, so DESTROY.HUB.AGENT.T3 comes only once T3 is gone'
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -like 'If you selected T3 for Database Agents, uncheck only it, azuresql01-abc123/ContosoCare, in Database Hub''s Database agent settings and Save, before or after destroy.ps1; no API can. Deleted databases can stay in that list for a while*DESTROY.HUB.AGENT.T3 at the end says how (https://learn.microsoft.com/fabric/database/hub/enable-database-agents).' }

        Mock -ModuleName DbHubDemo -CommandName Get-DemoDestroyExtraPlan -MockWith { [pscustomobject]@{ Control = $null; Fabric = $null; Group = $null; Delete = @(); Keep = @() } }
        $null = @(Remove-DemoEnvironment -Config $config -WhatIf)
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 1 -Exactly -ParameterFilter { $Message -like '*Database agent settings*' } -Because 'a plan without T3''s name, as when the group''s tag can''t be read, adds no line to the first run''s one'
    }

    It 'pauses a capacity it resumed (fabric.manageCapacity) only after the Fabric workspaces, whose deletes need it, and before the group' {
        $script:order = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Get-DemoTeardownManifest -MockWith { throw 'no manifest in this test' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDestroyExtra -MockWith { $script:order.Add('fabric, control, and group') }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricCapacitySetting -MockWith { [pscustomobject]@{ ManageCapacity = $true } }
        Mock -ModuleName DbHubDemo -CommandName Suspend-DemoFabricCapacity -MockWith {
            $script:order.Add('capacity')
            New-DemoResult -CheckId 'DESTROY.FABRIC.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'paused'
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoArcSetting -MockWith { $script:order.Add('Arc'); throw 'the order is known' }
        { Remove-DemoEnvironment -Config $config -Confirm:$false } | Should -Throw '*the order is known*'
        ($script:order -join ' > ') | Should -Be 'fabric, control, and group > capacity > Arc'
    }
}

Describe 'Get-DemoDestroyExtraPlan keeps T3''s selection in Database agent settings, named from the group''s tag (2026-11-20)' {
    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDestroyControlPlan -MockWith { [pscustomobject]@{ Name = $null; State = 'None'; ServedGroup = ''; Resources = @(); Reason = 'none' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDestroyGroupPlan -MockWith { [pscustomobject]@{ Id = ''; Name = ''; State = 'None'; Reason = 'none' } }
    }

    It 'names T3 from the deploymentId tag, and lists its selection as kept; none when the tag is <Case>' -ForEach @(
        @{ Case = 'read'; Tags = @{ deploymentId = 'abc123' }; Server = 'azuresql01-abc123' }
        @{ Case = 'missing (the group is gone)'; Tags = @{}; Server = '' }
        @{ Case = 'not a deploymentId'; Tags = @{ deploymentId = 'ABC 12' }; Server = '' }
    ) {
        $script:tags = $Tags
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { $script:tags }
        $plan = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } { Get-DemoDestroyExtraPlan -Config $C -KeepFabric }
        $plan.T3Agent | Should -Be $Server
        $plan.NoT3 | Should -BeFalse -Because 'only the golden boot test''s group is known to have no T3'
        $line = @($plan.Keep | Where-Object { $_ -like '*Database agent settings*' })
        if ($Server) {
            $line | Should -Be @('T3''s selection in Database Hub''s Database agent settings (azuresql01-abc123/ContosoCare), if you made it: no API removes it')
        }
        else {
            $line.Count | Should -Be 0
        }
    }

    It 'names no T3 for the golden boot test''s group, which has a deploymentId tag but never a T3, and says so in NoT3 (review of 5d1f4b0)' {
        # test-t2-golden.ps1 deletes rg-<prefix>-gtest through this path. Its group has a random deploymentId tag, but
        # infra/golden-test.bicep deploys only the network and archost01, so every run, -CleanupOnly too, ended with "1 item(s)
        # need you: ... uncheck azuresql01-<random>/ContosoCare" for a database that never existed.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { @{ deploymentId = 'k3x9q2'; purpose = 't2-golden-boot-test'; environment = 'gtest' } }
        $plan = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } { Get-DemoDestroyExtraPlan -Config $C -KeepFabric }
        $plan.T3Agent | Should -Be ''
        $plan.NoT3 | Should -BeTrue
        @($plan.Keep | Where-Object { $_ -like '*Database agent settings*' }).Count | Should -Be 0
    }

    It 'goes on without T3''s name when the tag can''t be read' {
        Mock -ModuleName DbHubDemo -CommandName Get-DemoResourceGroupTag -MockWith { throw 'the Azure CLI isn''t answering' }
        $plan = InModuleScope DbHubDemo -Parameters @{ C = (New-TestConfig) } { Get-DemoDestroyExtraPlan -Config $C -KeepFabric }
        $plan.T3Agent | Should -Be ''
        $plan.Keep | Should -Contain 'the Fabric capacity and your licenses, which you manage'
    }
}
