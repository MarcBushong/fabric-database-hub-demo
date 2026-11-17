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

    It 'says there''s none when rg-<prefix>-control doesn''t exist' {
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
    }

    It 'deletes the demo''s workspace when everything in it is the demo''s, and the control''s when its notebook serves this environment' {
        $plan = InModuleScope DbHubDemo -Parameters @{ Config = $config; Token = $script:token; Control = $script:control } { Get-DemoDestroyFabricPlan -Config $Config -Token $Token -Control $Control }
        $plan.Ok | Should -BeTrue
        $plan.Demo.Delete | Should -BeTrue
        $plan.Demo.Reason | Should -Be 'everything in it is the demo''s (9 item(s))'
        $plan.Control.Delete | Should -BeTrue
        $plan.Control.Reason | Should -Be 'its control notebook serves rg-dbhub-demo'
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
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'nothing is deleted in a what-if' }
    }

    It 'names each in a what-if, deletes nothing, and passes -KeepFabric on' {
        $result = @(Remove-DemoEnvironment -Config $config -KeepFabric -WhatIf)
        $result[-1].checkId | Should -Be 'DESTROY.RESOURCEGROUP'
        $result[-1].message | Should -Match 'would delete the Arc resources, rg-dbhub-demo and everything in it, the subscription deployment record, and the budget; the Fabric workspace "Database Hub Demo"'
        $result[-1].message | Should -Match 'and keep the Fabric capacity and your licenses, which you manage; rg-dbhub-golden and its golden snapshots \(-IncludeGolden deletes them\)\.$'
        $script:keepFabric | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -eq 'destroy.ps1 keeps the Fabric capacity and your licenses, which you manage.' } -Times 1 -Exactly
    }
}
