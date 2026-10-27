BeforeAll {
    # Phase 26b: the first-run automation (ADR 0023). Every Azure CLI call, Microsoft Graph request, Fabric request, and
    # prompt is mocked; no test touches the network. IDs are obvious placeholders (each group repeats one character), and
    # tokens are built at run time.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    $script:subA = '11111111-2222-3333-4444-555555555555'
    $script:subB = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $script:tenant = '66666666-7777-8888-9999-000000000000'
    $script:callerId = '88888888-8888-8888-8888-888888888888'
    $script:groupId = '99999999-9999-9999-9999-999999999999'
    $script:capacityFabricId = '77777777-7777-7777-7777-777777777777'
    $script:zeroGuid = '00000000-0000-0000-0000-000000000000'
    $script:fabricToken = ConvertTo-HubSecureString ('tok' + ('f' * 40))

    function New-ProfileEntry([string] $Id, [string] $Name, [bool] $IsDefault = $false) {
        [pscustomobject]@{ SubscriptionId = $Id; Name = $Name; TenantId = $script:tenant; Account = 'colleague@contoso.example'; AccountType = 'user'; IsDefault = $IsDefault; State = 'Enabled' }
    }

    function New-FabricItem([string] $Name, [string] $State = 'Active', [string] $Type = 'Workspace') {
        [pscustomobject]@{ id = $script:capacityFabricId; displayName = $Name; sku = 'F2'; state = $State; region = 'West US 3'; type = $Type }
    }

    function Set-InitMock {
        # Mocks for Initialize-DemoConfig; $script:init holds what each one answers, and $script:calls their order.
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:init = @{
            Profile      = [pscustomobject]@{ Installed = $true; SignedIn = $true; Error = ''; Subscriptions = @(New-ProfileEntry $script:subA 'Contoso Demo' $true) }
            GuardThrows  = $false
            Interactive  = $false
            Choices      = [System.Collections.Generic.Queue[int]]::new()
            Capacities   = @(New-FabricItem 'contosofabric')
            Workspaces   = @()
            Groups       = @()
            Owner        = $true
            Create       = [pscustomobject]@{ Status = 'Created'; GroupId = $script:groupId; StatusCode = 201; Error = '' }
            Permissions  = [pscustomobject]@{ value = @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoAzProfileSubscription -MockWith { $script:calls.Add('Profile'); $script:init.Profile }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoInteractiveSession -MockWith { $script:init.Interactive }
        Mock -ModuleName DbHubDemo -CommandName Read-DemoChoice -MockWith { $script:calls.Add('Ask:' + $Title.Split(' ')[1]); $script:init.Choices.Dequeue() }
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith {
            $script:calls.Add('Guard:' + $SubscriptionId)
            if ($script:init.GuardThrows) {
                throw "Subscription guard: check 'account' failed: another tenant. Nothing was changed."
            }
            New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'Guard passed.'
        }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCallerIdentity -MockWith { [pscustomobject]@{ ObjectId = $script:callerId; PrincipalType = 'User' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSignedInUser -MockWith { $script:calls.Add('Me'); [pscustomobject]@{ ObjectId = $script:callerId; UserPrincipalName = 'colleague@contoso.example'; Mail = 'colleague@contoso.example'; DisplayName = 'A Colleague' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith { $script:calls.Add('Az:' + ($ArgumentList[0..1] -join ' ')); $script:init.Permissions }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { $script:calls.Add('FabricToken'); $script:fabricToken }
        Mock -ModuleName DbHubDemo -CommandName Read-DemoHubFabricList -MockWith {
            $script:calls.Add('Fabric:' + ($Uri -split '/')[-1])
            $items = if ($Uri -like '*/capacities') { $script:init.Capacities } else { $script:init.Workspaces }
            [pscustomobject]@{ Succeeded = $true; StatusCode = 200; Error = ''; Items = @($items); Pages = 1; Complete = $true }
        }
        Mock -ModuleName DbHubDemo -CommandName Find-DemoEntraGroup -MockWith { $script:calls.Add('FindGroup'); [pscustomobject]@{ Succeeded = $true; StatusCode = 200; Error = ''; Groups = @($script:init.Groups) } }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoEntraGroupOwner -MockWith { $script:init.Owner }
        Mock -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -MockWith { $script:calls.Add('CreateGroup'); $script:init.Create }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoGitHubRepositoryName -MockWith { 'contoso/fabric-database-hub-demo' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoWindowsTimeZoneId -MockWith { [pscustomobject]@{ Id = 'Eastern Standard Time'; IsUtc = $false } }
    }

    function Get-InitResult([object] $Init, [string] $CheckId) {
        @($Init.Results | Where-Object { $_.checkId -eq $CheckId }) | Select-Object -First 1
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoAzProfileSubscription (the one call before the guard)' {
    It 'reads az account list locally and keeps enabled subscriptions, the default first' {
        $list = @(
            @{ id = $script:subB; name = 'Other'; tenantId = $script:tenant; state = 'Enabled'; isDefault = $false; user = @{ name = 'colleague@contoso.example'; type = 'user' } }
            @{ id = $script:subA; name = 'Contoso Demo'; tenantId = $script:tenant; state = 'Enabled'; isDefault = $true; user = @{ name = 'colleague@contoso.example'; type = 'user' } }
            @{ id = '22222222-3333-4444-5555-666666666666'; name = 'Old'; tenantId = $script:tenant; state = 'Disabled'; isDefault = $false; user = @{ name = 'colleague@contoso.example'; type = 'user' } }
        )
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { $script:listed = $ArgumentList; [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject $list -Depth 5); StdErr = '' } }
        $listedProfile = InModuleScope DbHubDemo { Get-DemoAzProfileSubscription }
        $script:listed | Should -Be @('account', 'list', '--output', 'json')
        $listedProfile.SignedIn | Should -BeTrue
        @($listedProfile.Subscriptions).Count | Should -Be 2
        $listedProfile.Subscriptions[0].SubscriptionId | Should -Be $script:subA
        $listedProfile.Subscriptions[0].Account | Should -Be 'colleague@contoso.example'
    }

    It 'reports no sign-in for an empty profile, and a missing Azure CLI' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = '[]'; StdErr = "Please run 'az login' to setup account." } }
        $empty = InModuleScope DbHubDemo { Get-DemoAzProfileSubscription }
        $empty.Installed | Should -BeTrue
        $empty.SignedIn | Should -BeFalse
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'The Azure CLI (az) was not found on PATH.' }
        (InModuleScope DbHubDemo { Get-DemoAzProfileSubscription }).Installed | Should -BeFalse
    }
}

Describe 'Initialize-DemoConfig (init.ps1)' {
    BeforeEach {
        Set-InitMock
        $script:path = Join-Path -Path $TestDrive -ChildPath ('demo.config.{0}.json' -f [guid]::NewGuid().ToString('N'))
        $script:backup = Join-Path -Path $TestDrive -ChildPath 'backup'
    }

    It 'writes a schema-valid configuration from the sign-in, with the notebooks imported into a new workspace and the capacity never managed' {
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $init.Written | Should -BeTrue
        (Get-InitResult $init 'INIT.CONFIG').status | Should -Be 'Pass'
        $config = Get-DemoConfig -Path $script:path
        $config['subscriptionId'] | Should -Be $script:subA
        $config['tenantId'] | Should -Be $script:tenant
        $config['azureAccount'] | Should -Be 'colleague@contoso.example'
        $config['ownerEmail'] | Should -Be 'colleague@contoso.example'
        $config['owner'] | Should -Be 'colleague'
        $config['t3AdminGroupObjectId'] | Should -Be $script:groupId
        $config['t2SqlInstallMode'] | Should -Be 'PaygWizard'
        $config['autoShutdownTimeZone'] | Should -Be 'Eastern Standard Time'
        $config['fabric']['workspaceName'] | Should -Be 'Database Hub Demo'
        $config['fabric']['lakehouseName'] | Should -Be 'LH_DatabaseHub'
        $config['fabric']['capacityName'] | Should -Be 'contosofabric'
        $config['fabric']['importNotebooks'] | Should -BeTrue
        $config['fabric']['manageCapacity'] | Should -BeFalse
        $config['fabric'].Contains('workspaceId') | Should -BeFalse
        $config['github']['repository'] | Should -Be 'contoso/fabric-database-hub-demo'
        (Get-Content -LiteralPath $script:path -Raw) | Should -Not -Match '"(workspaceId|lakehouseId)"'
        @($init.NextSteps) -join "`n" | Should -Match 'preflight\.ps1(.|\n)*deploy\.ps1'
    }

    It 'calls nothing but az account list before the subscription guard, and runs the guard for the chosen subscription' {
        Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false | Out-Null
        $script:calls[0] | Should -Be 'Profile'
        $script:calls[1] | Should -Be ('Guard:' + $script:subA)
        @($script:calls | Select-Object -Skip 2 | Where-Object { $_ -eq 'Profile' -or $_ -like 'Guard:*' }) | Should -BeNullOrEmpty
        @($script:calls) | Should -Contain 'CreateGroup'
        Should -Invoke -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -Times 1 -Exactly -ParameterFilter { $OwnerId -eq $script:callerId -and $DisplayName -eq 'dbhub-demo-sql-admins' -and $OwnerType -eq 'User' }
    }

    It 'never replaces an existing configuration without -Force, and then calls nothing' {
        Set-Content -LiteralPath $script:path -Value '{"old": true}'
        $init = Initialize-DemoConfig -Path $script:path -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-InitResult $init 'INIT.CONFIG').status | Should -Be 'Not selected'
        (Get-InitResult $init 'INIT.CONFIG').remediation | Should -Match '-Force'
        (Get-Content -LiteralPath $script:path -Raw).Trim() | Should -Be '{"old": true}'
        $script:calls.Count | Should -Be 0
    }

    It 'backs up the existing configuration to the Git-ignored backup folder before -Force replaces it' {
        Set-Content -LiteralPath $script:path -Value '{"old": true}'
        $init = Initialize-DemoConfig -Path $script:path -Force -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $init.Written | Should -BeTrue
        $init.BackupPath | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $init.BackupPath -Raw).Trim() | Should -Be '{"old": true}'
        (Get-DemoConfig -Path $script:path)['subscriptionId'] | Should -Be $script:subA
        $default = InModuleScope DbHubDemo { (Get-Command -Name Initialize-DemoConfig).Parameters['BackupDirectory'] }
        $default | Should -Not -BeNullOrEmpty
        git -C $repoRoot check-ignore -q -- 'out/config-backup/demo.config.20261027T000000Z.json'
        $LASTEXITCODE | Should -Be 0
    }

    It 'refuses a path Git would commit, before any Azure call' {
        $tracked = Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json'
        $init = Initialize-DemoConfig -Path $tracked -Force -NonInteractive -Confirm:$false
        (Get-InitResult $init 'INIT.CONFIG').status | Should -Be 'Fail'
        $script:calls.Count | Should -Be 0
        InModuleScope DbHubDemo -Parameters @{ Root = $repoRoot } {
            Test-DemoConfigPathIgnored -Path (Join-Path -Path $Root -ChildPath 'config/demo.config.json') | Should -BeTrue
            Test-DemoConfigPathIgnored -Path (Join-Path -Path $Root -ChildPath 'config/test.local.json') | Should -BeTrue
            Test-DemoConfigPathIgnored -Path (Join-Path -Path $Root -ChildPath 'config/demo.config.example.json') | Should -BeFalse
        }
    }

    It 'asks which subscription, capacity, and T2 mode when there''s a choice, and writes the answers' {
        $script:init.Interactive = $true
        $script:init.Profile = [pscustomobject]@{ Installed = $true; SignedIn = $true; Error = ''; Subscriptions = @((New-ProfileEntry $script:subA 'Contoso Demo' $true), (New-ProfileEntry $script:subB 'Contoso Lab')) }
        $script:init.Capacities = @((New-FabricItem 'sharedcap' 'Inactive'), (New-FabricItem 'mycap'))
        foreach ($answer in 1, 1, 1) {
            $script:init.Choices.Enqueue($answer)
        }
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -BackupDirectory $script:backup -Confirm:$false
        @($script:calls | Where-Object { $_ -like 'Ask:*' }).Count | Should -Be 3
        $config = Get-DemoConfig -Path $script:path
        $config['subscriptionId'] | Should -Be $script:subB
        $config['fabric']['capacityName'] | Should -Be 'mycap'
        $config['t2SqlInstallMode'] | Should -Be 'Developer'
        (Get-InitResult $init 'INIT.FABRIC.CAPACITY').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Read-DemoChoice -Times 1 -Exactly -ParameterFilter { $Title -like '*capacity*' -and $Default -eq 1 }
    }

    It 'never guesses without asking: several subscriptions with -NonInteractive are Manual action required, and nothing is written' {
        $script:init.Profile = [pscustomobject]@{ Installed = $true; SignedIn = $true; Error = ''; Subscriptions = @((New-ProfileEntry $script:subA 'Contoso Demo' $true), (New-ProfileEntry $script:subB 'Contoso Lab')) }
        $init = Initialize-DemoConfig -Path $script:path -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-InitResult $init 'INIT.SUBSCRIPTION').status | Should -Be 'Manual action required'
        (Get-InitResult $init 'INIT.SUBSCRIPTION').remediation | Should -Match '-SubscriptionId'
        Test-Path -LiteralPath $script:path | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -Times 0 -Exactly
    }

    It 'takes -SubscriptionId without asking' {
        $script:init.Profile = [pscustomobject]@{ Installed = $true; SignedIn = $true; Error = ''; Subscriptions = @((New-ProfileEntry $script:subA 'Contoso Demo' $true), (New-ProfileEntry $script:subB 'Contoso Lab')) }
        Initialize-DemoConfig -Path $script:path -SubscriptionId $script:subB -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false | Out-Null
        (Get-DemoConfig -Path $script:path)['subscriptionId'] | Should -Be $script:subB
    }

    It 'asks you to sign in yourself when the Azure CLI has no subscription, and never signs in' {
        $script:init.Profile = [pscustomobject]@{ Installed = $true; SignedIn = $false; Error = 'No subscription.'; Subscriptions = @() }
        $init = Initialize-DemoConfig -Path $script:path -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $signIn = Get-InitResult $init 'INIT.AZ.SIGNIN'
        $signIn.status | Should -Be 'Manual action required'
        $signIn.remediation | Should -Match "az login"
        $signIn.remediation | Should -Match 'use-device-code'
        Test-Path -LiteralPath $script:path | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -Times 0 -Exactly
    }

    It 'stops with Fail and writes nothing when the subscription guard fails' {
        $script:init.GuardThrows = $true
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-InitResult $init 'PREFLIGHT.GUARD.CONTEXT').status | Should -Be 'Fail'
        Test-Path -LiteralPath $script:path | Should -BeFalse
        @($script:calls) | Should -Not -Contain 'FabricToken'
        @($script:calls) | Should -Not -Contain 'CreateGroup'
    }

    It 'gives an administrator''s steps when the tenant forbids creating the group, and writes the placeholder' {
        $script:init.Create = [pscustomobject]@{ Status = 'Forbidden'; GroupId = ''; StatusCode = 403; Error = 'HTTP 403: Authorization_RequestDenied' }
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $group = Get-InitResult $init 'INIT.P6.GROUP'
        $group.status | Should -Be 'Manual action required'
        $group.remediation | Should -Match 'az ad group create --display-name dbhub-demo-sql-admins'
        $group.remediation | Should -Match 'az ad group owner add'
        (Get-DemoConfig -Path $script:path)['t3AdminGroupObjectId'] | Should -Be $script:zeroGuid
        @($init.NextSteps)[0] | Should -Match 'INIT\.P6\.GROUP'
    }

    It 'finds an existing group by name, and warns when you aren''t its owner' {
        $script:init.Groups = @([pscustomobject]@{ id = $script:groupId; displayName = 'dbhub-demo-sql-admins'; securityEnabled = $true })
        $script:init.Owner = $false
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-InitResult $init 'INIT.P6.GROUP').status | Should -Be 'Warning'
        (Get-DemoConfig -Path $script:path)['t3AdminGroupObjectId'] | Should -Be $script:groupId
        Should -Invoke -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -Times 0 -Exactly
    }

    It 'creates no group without -CreateAdminGroup, and says how' {
        $init = Initialize-DemoConfig -Path $script:path -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-InitResult $init 'INIT.P6.GROUP').status | Should -Be 'Manual action required'
        (Get-InitResult $init 'INIT.P6.GROUP').remediation | Should -Match '-CreateAdminGroup'
        Should -Invoke -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -Times 0 -Exactly
    }

    It 'writes nothing and creates no group with -WhatIf' {
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -WhatIf
        $init.Written | Should -BeFalse
        Test-Path -LiteralPath $script:path | Should -BeFalse
        (Get-InitResult $init 'INIT.CONFIG').status | Should -Be 'Not selected'
        (Get-InitResult $init 'INIT.P6.GROUP').status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -Times 0 -Exactly
        (Get-InitResult $init 'INIT.CONFIG').message | Should -Not -Match $script:subA
    }

    It 'keeps importNotebooks false for a workspace that exists, and writes manageCapacity only with -ManageCapacity' {
        $script:init.Workspaces = @(New-FabricItem 'Database Hub Demo')
        Initialize-DemoConfig -Path $script:path -CreateAdminGroup -ManageCapacity -NonInteractive -BackupDirectory $script:backup -Confirm:$false | Out-Null
        $config = Get-DemoConfig -Path $script:path
        $config['fabric']['importNotebooks'] | Should -BeFalse
        $config['fabric']['manageCapacity'] | Should -BeTrue
    }

    It 'gives the Owner''s exact command when Contributor is missing (P1)' {
        $script:init.Permissions = [pscustomobject]@{ value = @([pscustomobject]@{ actions = @('*/read'); notActions = @() }) }
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $p1 = Get-InitResult $init 'INIT.P1.CONTRIBUTOR'
        $p1.status | Should -Be 'Manual action required'
        $p1.remediation | Should -Match ('az role assignment create --assignee-object-id {0} --assignee-principal-type User --role Contributor --scope /subscriptions/{1}' -f $script:callerId, $script:subA)
        $init.Written | Should -BeTrue
    }

    It 'warns that a paused capacity must run for deploy.ps1, and asks for the capacity when it can''t choose' {
        $script:init.Capacities = @(New-FabricItem 'contosofabric' 'Inactive')
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-InitResult $init 'INIT.FABRIC.CAPACITY').status | Should -Be 'Warning'
        (Get-InitResult $init 'INIT.FABRIC.CAPACITY').remediation | Should -Match 'Resume'
        $script:init.Capacities = @((New-FabricItem 'one'), (New-FabricItem 'two'))
        $other = Join-Path -Path $TestDrive -ChildPath 'two-capacities.json'
        $init = Initialize-DemoConfig -Path $other -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-InitResult $init 'INIT.FABRIC.CAPACITY').status | Should -Be 'Manual action required'
        (Get-InitResult $init 'INIT.FABRIC.CAPACITY').remediation | Should -Match '-CapacityName'
    }

    It 'refuses a time zone that isn''t a Windows time zone ID' {
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -TimeZone 'Mars/Olympus' -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-InitResult $init 'INIT.CONFIG').status | Should -Be 'Fail'
        Test-Path -LiteralPath $script:path | Should -BeFalse
    }

    It 'offers only capacities that run Fabric items: F, Trial (FTL64, live), and P, never Premium Per User' {
        $ppu = [pscustomobject]@{ id = $script:capacityFabricId; displayName = 'Premium Per User - Reserved'; sku = 'PP3'; state = 'Active'; region = 'West US 3' }
        $trial = [pscustomobject]@{ id = $script:capacityFabricId; displayName = 'Trial-20261027T000000Z'; sku = 'FTL64'; state = 'Active'; region = 'West US 3' }
        $script:init.Capacities = @($ppu, $trial)
        Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false | Out-Null
        (Get-DemoConfig -Path $script:path)['fabric']['capacityName'] | Should -Be 'Trial-20261027T000000Z'
        $script:init.Capacities = @($ppu)
        $other = Join-Path -Path $TestDrive -ChildPath 'ppu-only.json'
        $init = Initialize-DemoConfig -Path $other -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-InitResult $init 'INIT.FABRIC.CAPACITY').status | Should -Be 'Manual action required'
        (Get-InitResult $init 'INIT.FABRIC.CAPACITY').message | Should -Match 'Premium Per User'
    }

    It 'uses the group in -AdminGroupObjectId, and names it in the summary' {
        $script:init.Groups = @([pscustomobject]@{ id = $script:groupId; displayName = 'sg-custom-admins'; securityEnabled = $true })
        $init = Initialize-DemoConfig -Path $script:path -AdminGroupObjectId $script:groupId -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-InitResult $init 'INIT.P6.GROUP').status | Should -Be 'Pass'
        (Get-InitResult $init 'INIT.CONFIG').message | Should -Match 'sg-custom-admins'
        (Get-DemoConfig -Path $script:path)['t3AdminGroupObjectId'] | Should -Be $script:groupId
        Should -Invoke -ModuleName DbHubDemo -CommandName Find-DemoEntraGroup -Times 1 -Exactly -ParameterFilter { $ObjectId -eq $script:groupId }
    }
}

Describe 'Microsoft Entra group helpers (-CreateAdminGroup)' {
    BeforeEach {
        $script:graph = [System.Collections.Generic.List[object]]::new()
        $script:ownersAnswer = '{"value":[]}'
        $script:createStatus = 201
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            # A GET binds no -Body; under Set-StrictMode an unbound parameter has no variable, so read it with Get-Variable.
            $sent = [string](Get-Variable -Name 'Body' -ValueOnly -ErrorAction SilentlyContinue)
            $script:graph.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $sent })
            if ($Method -eq 'POST' -and $Uri -like '*/groups') {
                if ($script:createStatus -ne 201) {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'HTTP 403: {"error":{"code":"Authorization_RequestDenied"}}'; StatusCode = $script:createStatus }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = ('{{"id":"{0}"}}' -f $script:groupId); StdErr = ''; StatusCode = 201 }
            }
            if ($Uri -like '*/owners?*') {
                return [pscustomobject]@{ ExitCode = 0; StdOut = $script:ownersAnswer; StdErr = ''; StatusCode = 200 }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = '{"value":[]}'; StdErr = ''; StatusCode = 204 }
        }
    }

    It 'creates a security group with the caller in owners@odata.bind, and adds the caller when the owners don''t list them' {
        $created = InModuleScope DbHubDemo -Parameters @{ Sub = $script:subA; Owner = $script:callerId } { New-DemoEntraSecurityGroup -SubscriptionId $Sub -DisplayName 'dbhub-demo-sql-admins' -OwnerId $Owner -Confirm:$false }
        $created.Status | Should -Be 'Created'
        $created.GroupId | Should -Be $script:groupId
        $post = $script:graph[0]
        $post.Uri | Should -Be 'https://graph.microsoft.com/v1.0/groups'
        $body = $post.Body | ConvertFrom-Json -AsHashtable
        $body['securityEnabled'] | Should -BeTrue
        $body['mailEnabled'] | Should -BeFalse
        $body['owners@odata.bind'] | Should -Be @("https://graph.microsoft.com/v1.0/users/$($script:callerId)")
        @($script:graph | Where-Object { $_.Uri -like '*/owners/$ref' }).Count | Should -Be 1
    }

    It 'doesn''t add the owner twice when the create already made the caller its owner' {
        $script:ownersAnswer = ('{{"value":[{{"id":"{0}"}}]}}' -f $script:callerId)
        InModuleScope DbHubDemo -Parameters @{ Sub = $script:subA; Owner = $script:callerId } { New-DemoEntraSecurityGroup -SubscriptionId $Sub -DisplayName 'dbhub-demo-sql-admins' -OwnerId $Owner -Confirm:$false } | Out-Null
        @($script:graph | Where-Object { $_.Uri -like '*/owners/$ref' }).Count | Should -Be 0
    }

    It 'reports Forbidden when the tenant doesn''t let the caller create groups' {
        $script:createStatus = 403
        $created = InModuleScope DbHubDemo -Parameters @{ Sub = $script:subA; Owner = $script:callerId } { New-DemoEntraSecurityGroup -SubscriptionId $Sub -DisplayName 'dbhub-demo-sql-admins' -OwnerId $Owner -Confirm:$false }
        $created.Status | Should -Be 'Forbidden'
    }

    It 'searches by display name with the OData quotes escaped, through Microsoft Graph only' {
        InModuleScope DbHubDemo -Parameters @{ Sub = $script:subA } { Find-DemoEntraGroup -SubscriptionId $Sub -DisplayName "o'brien admins" } | Out-Null
        $script:graph[0].Uri | Should -Match '^https://graph\.microsoft\.com/v1\.0/groups\?\$filter='
        [uri]::UnescapeDataString($script:graph[0].Uri) | Should -Match "displayName eq 'o''brien admins'"
    }
}

Describe 'Connect-DemoRayfinCli (configure-fabric-app.ps1 -SignIn)' {
    BeforeEach {
        $script:config = @{ tenantId = $script:tenant; subscriptionId = $script:subA }
        $script:interactive = $true
        $script:statusAfter = 'Pass'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoInteractiveSession -MockWith { $script:interactive }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoRayfinCliPath -MockWith { 'C:\stage\node_modules\@microsoft\rayfin-cli\scripts\main' }
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'node' } -MockWith { [pscustomobject]@{ Source = 'node' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinInteractive -MockWith { 0 }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricAppPrerequisite -MockWith {
            New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status $script:statusAfter -Message 'signed in?' -Remediation 'rayfin login'
        }
    }

    It 'is Not supported in CI or a non-interactive session, and runs nothing' {
        $script:interactive = $false
        $result = Connect-DemoRayfinCli -Config $script:config -StagePath $TestDrive -Confirm:$false
        $result.checkId | Should -Be 'FABRIC.APP.SIGNIN'
        $result.status | Should -Be 'Not supported'
        $result.remediation | Should -Match 'rayfin login --tenant'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinInteractive -Times 0 -Exactly
    }

    It 'runs the pinned CLI''s login for the demo''s tenant in this console, then checks the status' {
        $result = Connect-DemoRayfinCli -Config $script:config -StagePath $TestDrive -Confirm:$false
        $result.status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinInteractive -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq ('login --tenant {0}' -f $script:tenant) }
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricAppPrerequisite -Times 1 -Exactly
    }

    It 'keeps Manual action required when the sign-in didn''t take, and does nothing with -WhatIf' {
        $script:statusAfter = 'Manual action required'
        (Connect-DemoRayfinCli -Config $script:config -StagePath $TestDrive -Confirm:$false).status | Should -Be 'Manual action required'
        (Connect-DemoRayfinCli -Config $script:config -StagePath $TestDrive -WhatIf).status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinInteractive -Times 1 -Exactly
    }
}

Describe 'configure-fabric-app.ps1 -SignIn' {
    BeforeAll {
        Initialize-GuardTestContext -SubscriptionId $script:HubSubscriptionId -TenantId $script:HubTenantId
        $script:configureApp = Join-Path -Path $repoRoot -ChildPath 'scripts/configure-fabric-app.ps1'
        $script:pass = { param([string] $CheckId, [hashtable] $Evidence = @{}) New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'ok' -Evidence $Evidence }
        $config = Get-HubTestConfig
        $config['fabric']['workspaceId'] = '12121212-1212-1212-1212-121212121212'
        $config['tenantId'] = $script:HubTenantId
        $script:appConfig = Join-Path -Path $TestDrive -ChildPath 'app.config.json'
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $script:appConfig -Encoding utf8NoBOM
    }

    AfterAll {
        Initialize-GuardTestContext -Clear
    }

    BeforeEach {
        $pass = $script:pass
        $capacityId = $script:capacityFabricId
        Mock -CommandName Test-DemoFabricWorkspace -MockWith { @(& $pass 'FABRIC.P5.CAPACITY' @{ capacityId = $capacityId; capacityAssignmentProgress = 'Completed' }) }
        Mock -CommandName Resolve-DemoFabricAppItem -MockWith { & $pass 'FABRIC.APP.ITEMS' @{ semanticModelId = '34343434-3434-3434-3434-343434343434'; links = @{} } }
        Mock -CommandName Sync-DemoFabricAppStage -MockWith { @(& $pass 'FABRIC.APP.STAGE') }
        Mock -CommandName Test-DemoFabricAppPrerequisite -MockWith { @((& $pass 'FABRIC.APP.NODE'), (New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'Not signed in.' -Remediation 'rayfin login')) }
        Mock -CommandName Invoke-DemoFabricAppDeployment -MockWith { @(& $pass 'FABRIC.APP.DEPLOY' @{ hostingUrl = 'https://app-example.invalid'; itemUrl = '' }) }
        Mock -CommandName Test-DemoFabricApp -MockWith { @(& $pass 'FABRIC.APP.CONNECTOR') }
    }

    It 'signs the CLI in when it isn''t, then deploys' {
        Mock -CommandName Connect-DemoRayfinCli -MockWith { New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Pass' -Message 'Signed in.' }
        $output = Join-Path -Path $TestDrive -ChildPath 'signin.jsonl'
        $null = & $script:configureApp -ConfigPath $script:appConfig -OutputPath $output -FabricToken $script:fabricToken -SignIn 6>&1
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        ($records | Where-Object checkId -EQ 'FABRIC.APP.SIGNIN').status | Should -Be 'Pass'
        ($records | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY').status | Should -Be 'Pass'
        Should -Invoke -CommandName Connect-DemoRayfinCli -Times 1 -Exactly
    }

    It 'deploys nothing when -SignIn is refused (CI), and never signs in without -SignIn' {
        Mock -CommandName Connect-DemoRayfinCli -MockWith { New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Not supported' -Message 'Not in CI.' }
        $output = Join-Path -Path $TestDrive -ChildPath 'signin-ci.jsonl'
        $null = & $script:configureApp -ConfigPath $script:appConfig -OutputPath $output -FabricToken $script:fabricToken -SignIn 6>&1
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        ($records | Where-Object checkId -EQ 'FABRIC.APP.SIGNIN').status | Should -Be 'Not supported'
        ($records | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY').status | Should -Be 'Not selected'
        Should -Invoke -CommandName Invoke-DemoFabricAppDeployment -Times 0 -Exactly
        $null = & $script:configureApp -ConfigPath $script:appConfig -OutputPath $output -FabricToken $script:fabricToken 6>&1
        Should -Invoke -CommandName Connect-DemoRayfinCli -Times 1 -Exactly
    }
}

Describe 'fabric.manageCapacity (start, stop, destroy, status)' {
    BeforeEach {
        $script:capConfig = @{ subscriptionId = $script:subA; tenantId = $script:tenant; prefix = 'dbhub'; environment = 'demo'; fabric = @{ capacityName = 'fabcap01'; manageCapacity = $true } }
        $script:capState = 'Paused'
        $script:capList = @('fabcap01')
        $script:az = [System.Collections.Generic.List[string]]::new()
        $script:tagWrites = [System.Collections.Generic.List[hashtable]]::new()
        $script:postFails = $false
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoDeploymentState -MockWith { $script:tagWrites.Add([hashtable]$Value) }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            $method = $ArgumentList[2]
            $url = $ArgumentList[4]
            $script:az.Add(('{0} {1}' -f $method, ($url -replace '\?.*$', '')))
            $ok = { param([string] $Json) [pscustomobject]@{ ExitCode = 0; StdOut = $Json; StdErr = '' } }
            $one = { param([string] $Name) @{ id = ('/subscriptions/{0}/resourceGroups/rg-fabric/providers/Microsoft.Fabric/capacities/{1}' -f $script:subA, $Name); name = $Name; sku = @{ name = 'F2'; tier = 'Fabric' }; properties = @{ state = $script:capState } } }
            if ($method -eq 'post') {
                if ($script:postFails) {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (AuthorizationFailed) no access.' }
                }
                $script:capState = if ($url -match '/resume\?') { 'Active' } else { 'Paused' }
                return (& $ok '')
            }
            if ($url -match '/capacities/([a-z0-9]+)\?') {
                return (& $ok ((& $one $Matches[1]) | ConvertTo-Json -Depth 5))
            }
            return (& $ok (@{ value = @($script:capList | ForEach-Object { & $one $_ }) } | ConvertTo-Json -Depth 6))
        }
        function New-CapacityState([string] $Recorded = '') {
            [pscustomobject]@{ Exists = $true; Stage = 'Validation'; FabricCapacityResumed = $Recorded; FabricCapacityResumedUtc = $(if ($Recorded) { '2026-10-27T14:00:00Z' } else { '' }); Tags = @{} }
        }
    }

    It 'never calls the capacity with manageCapacity false (the default): Not selected at start, stop, and destroy, and no status line' {
        $script:capConfig['fabric']['manageCapacity'] = $false
        $state = New-CapacityState
        $start = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig; S = $state } { Resume-DemoFabricCapacity -Config $C -State $S -Confirm:$false }
        $stop = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig; S = $state } { Suspend-DemoFabricCapacity -Config $C -State $S -Confirm:$false }
        $status = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig; S = $state } { Get-DemoFabricCapacityStatus -Config $C -State $S }
        $start.status | Should -Be 'Not selected'
        $stop.status | Should -Be 'Not selected'
        $status | Should -BeNullOrEmpty
        $script:az.Count | Should -Be 0
        $script:tagWrites.Count | Should -Be 0
    }

    It 'warns, still without a call, when a record is left and manageCapacity is false now' {
        $script:capConfig['fabric']['manageCapacity'] = $false
        $stop = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig; S = (New-CapacityState 'rg-fabric/fabcap01') } { Suspend-DemoFabricCapacity -Config $C -State $S -Confirm:$false }
        $stop.status | Should -Be 'Warning'
        $script:az.Count | Should -Be 0
    }

    It 'resumes a Paused capacity at start and records it in the resource group tag' {
        $start = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig; S = (New-CapacityState) } { Resume-DemoFabricCapacity -Config $C -State $S -Confirm:$false }
        $start.checkId | Should -Be 'START.FABRIC.CAPACITY'
        $start.status | Should -Be 'Pass'
        @($script:az) | Should -Contain ('post https://management.azure.com/subscriptions/{0}/resourceGroups/rg-fabric/providers/Microsoft.Fabric/capacities/fabcap01/resume' -f $script:subA)
        $script:tagWrites.Count | Should -Be 1
        $script:tagWrites[0]['FabricCapacityResumed'] | Should -Be 'rg-fabric/fabcap01'
        $script:tagWrites[0]['FabricCapacityResumedUtc'] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }

    It 'leaves an Active capacity alone at start, and records nothing' {
        $script:capState = 'Active'
        $start = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig; S = (New-CapacityState) } { Resume-DemoFabricCapacity -Config $C -State $S -Confirm:$false }
        $start.status | Should -Be 'Pass'
        $start.message | Should -Match 'leaves it running'
        @($script:az | Where-Object { $_ -like 'post *' }) | Should -BeNullOrEmpty
        $script:tagWrites.Count | Should -Be 0
    }

    It 'is Not supported for a capacity that isn''t in the subscription (a Trial, or another subscription''s)' {
        $script:capList = @()
        $start = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig; S = (New-CapacityState) } { Resume-DemoFabricCapacity -Config $C -State $S -Confirm:$false }
        $start.status | Should -Be 'Not supported'
        @($script:az | Where-Object { $_ -like 'post *' }) | Should -BeNullOrEmpty
    }

    It 'pauses only the recorded capacity at stop, then clears the record' {
        $script:capState = 'Active'
        $stop = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig; S = (New-CapacityState 'rg-fabric/fabcap01') } { Suspend-DemoFabricCapacity -Config $C -State $S -Confirm:$false }
        $stop.checkId | Should -Be 'STOP.FABRIC.CAPACITY'
        $stop.status | Should -Be 'Pass'
        @($script:az) | Should -Contain ('post https://management.azure.com/subscriptions/{0}/resourceGroups/rg-fabric/providers/Microsoft.Fabric/capacities/fabcap01/suspend' -f $script:subA)
        $script:tagWrites[-1]['FabricCapacityResumed'] | Should -Be ''
    }

    It 'pauses nothing at stop when the demo didn''t resume it' {
        $script:capState = 'Active'
        $stop = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig; S = (New-CapacityState) } { Suspend-DemoFabricCapacity -Config $C -State $S -Confirm:$false }
        $stop.status | Should -Be 'Pass'
        $script:az.Count | Should -Be 0
    }

    It 'clears a stale record on a capacity that''s already paused, without pausing anything' {
        $stop = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig; S = (New-CapacityState 'rg-fabric/fabcap01') } { Suspend-DemoFabricCapacity -Config $C -State $S -Confirm:$false }
        $stop.status | Should -Be 'Pass'
        $stop.message | Should -Match 'stale'
        @($script:az | Where-Object { $_ -like 'post *' }) | Should -BeNullOrEmpty
        $script:tagWrites[-1]['FabricCapacityResumed'] | Should -Be ''
    }

    It 'warns at destroy when the recorded capacity can''t be paused, and keeps the record' {
        $script:capState = 'Active'
        $script:postFails = $true
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ Exists = $true; FabricCapacityResumed = 'rg-fabric/fabcap01'; FabricCapacityResumedUtc = '2026-10-27T14:00:00Z'; Tags = @{} } }
        $destroy = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig } { Suspend-DemoFabricCapacity -Config $C -CheckPrefix DESTROY -Confirm:$false }
        $destroy.checkId | Should -Be 'DESTROY.FABRIC.CAPACITY'
        $destroy.status | Should -Be 'Warning'
        $destroy.message | Should -Match 'pause it yourself'
        $script:tagWrites.Count | Should -Be 0
    }

    It 'shows the record in status, read-only' {
        $script:capState = 'Active'
        $status = InModuleScope DbHubDemo -Parameters @{ C = $script:capConfig; S = (New-CapacityState 'rg-fabric/fabcap01') } { Get-DemoFabricCapacityStatus -Config $C -State $S }
        $status.checkId | Should -Be 'STATUS.FABRIC.CAPACITY'
        $status.status | Should -Be 'Pass'
        $status.message | Should -Match 'DbHubFabricCapacityResumed'
        @($script:az | Where-Object { $_ -like 'post *' }) | Should -BeNullOrEmpty
        $script:tagWrites.Count | Should -Be 0
    }

    It 'records the capacity in the tags Set-DemoDeploymentState knows' {
        $names = InModuleScope DbHubDemo { Get-DemoDeploymentStateTagName }
        $names['FabricCapacityResumed'] | Should -Be 'DbHubFabricCapacityResumed'
        $names['FabricCapacityResumedUtc'] | Should -Be 'DbHubFabricCapacityResumedUtc'
        $versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
        $versions['apiVersions']['Microsoft.Fabric/capacities'] | Should -Be '2023-11-01'
    }
}

Describe 'stop-demo.ps1 -SaveHistory (Save-DemoFabricHistory)' {
    BeforeEach {
        $script:historyConfig = @{ subscriptionId = $script:subA; tenantId = $script:tenant; prefix = 'dbhub'; environment = 'demo'; fabric = @{ workspaceName = 'Database Hub Demo'; lakehouseName = 'LH_DatabaseHub' } }
        $script:capacityStatus = 'Pass'
        $script:runStatus = 'Pass'
        $script:jobStatus = 'Completed'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { $script:fabricToken }
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -MockWith {
            $copy = @{ subscriptionId = $script:subA; tenantId = $script:tenant; prefix = 'dbhub'; environment = 'demo'; fabric = @{ workspaceId = '13131313-1313-1313-1313-131313131313'; lakehouseId = '14141414-1414-1414-1414-141414141414' } }
            [pscustomobject]@{ Resolved = $true; Config = $copy; Results = @() }
        }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricWorkspace -MockWith {
            New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status $script:capacityStatus -Message 'capacity' -Evidence @{ state = $(if ($script:capacityStatus -eq 'Pass') { 'Active' } else { 'Inactive' }) }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -MockWith {
            New-DemoResult -CheckId 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY' -Area 'fabric' -Target 'fabric' -Status $script:runStatus -Message 'ran' -Evidence @{ status = $script:jobStatus; seconds = 95 }
        }
    }

    It 'runs NB_DatabaseHub_LiveActivity with only its safe switches, bounded at 15 minutes' {
        $saved = InModuleScope DbHubDemo -Parameters @{ C = $script:historyConfig } { Save-DemoFabricHistory -Config $C }
        $saved.Result.checkId | Should -Be 'STOP.FABRIC.SAVEHISTORY'
        $saved.Result.status | Should -Be 'Pass'
        $saved.StillRunning | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'NB_DatabaseHub_LiveActivity' -and $TimeoutMinutes -eq 15 -and $Parameter['SAVE_RESULTS'] -eq $true -and $Parameter['CONFIRM'] -eq $false -and $Parameter['STOP_ACTIVITY'] -eq $false -and $Parameter['KEY_VAULT_URL'] -eq '' -and $Parameter['RESOURCE_GROUP'] -eq 'rg-dbhub-demo' -and $Config['fabric']['workspaceId']
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -Times 1 -Exactly -ParameterFilter { -not $Create }
    }

    It 'is Manual action required, and runs nothing, when the capacity isn''t running' {
        $script:capacityStatus = 'Manual action required'
        $saved = InModuleScope DbHubDemo -Parameters @{ C = $script:historyConfig } { Save-DemoFabricHistory -Config $C }
        $saved.Result.status | Should -Be 'Manual action required'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 0 -Exactly
    }

    It 'says the run is still going when the 15 minutes pass, so the capacity isn''t paused under it' {
        $script:runStatus = 'Warning'
        $script:jobStatus = 'InProgress'
        $saved = InModuleScope DbHubDemo -Parameters @{ C = $script:historyConfig } { Save-DemoFabricHistory -Config $C }
        $saved.Result.status | Should -Be 'Warning'
        $saved.StillRunning | Should -BeTrue
    }

    Context 'in Stop-DemoEnvironment' {
        BeforeEach {
            $script:order = [System.Collections.Generic.List[string]]::new()
            $script:still = $false
            $script:stopConfig = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
            $script:stopConfig['subscriptionId'] = $script:subA
            $script:stopConfig['tenantId'] = $script:tenant
            $script:stopConfig['t4Enabled'] = $false
            $script:stopConfig['fabric']['manageCapacity'] = $true
            Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'ok' }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ Exists = $true; RunnerSha256 = ''; RunnerSentTo = @(); HostPasswordUtc = ''; Tags = @{ deploymentId = 'abc123' }; FabricCapacityResumed = 'rg-fabric/fabcap01'; FabricCapacityResumedUtc = '2026-10-27T14:00:00Z' } }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoVmPowerState -MockWith { 'PowerState/deallocated' }
            Mock -ModuleName DbHubDemo -CommandName Remove-DemoBastion -MockWith { New-DemoResult -CheckId 'STOP.BASTION' -Area 'infra' -Target 'T2' -Status 'Pass' -Message 'ok' }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoVmPowerAction -MockWith { $script:order.Add('Deallocate:' + $VmName); New-DemoResult -CheckId ('STOP.VM_{0}' -f $VmName.ToUpperInvariant()) -Area 'infra' -Target 'T1' -Status 'Pass' -Message 'ok' }
            Mock -ModuleName DbHubDemo -CommandName Save-DemoFabricHistory -MockWith { $script:order.Add('SaveHistory'); [pscustomobject]@{ Result = (New-DemoResult -CheckId 'STOP.FABRIC.SAVEHISTORY' -Area 'fabric' -Target 'fabric' -Status $(if ($script:still) { 'Warning' } else { 'Pass' }) -Message 'saved'); StillRunning = $script:still } }
            Mock -ModuleName DbHubDemo -CommandName Suspend-DemoFabricCapacity -MockWith { $script:order.Add('Pause'); New-DemoResult -CheckId 'STOP.FABRIC.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'paused' }
        }

        It 'saves the history after the VMs stop and before the capacity is paused' {
            Stop-DemoEnvironment -Config $script:stopConfig -SaveHistory -Confirm:$false | Out-Null
            $script:order | Should -Be @('Deallocate:archost01', 'Deallocate:sqlvm01', 'SaveHistory', 'Pause')
        }

        It 'never pauses the capacity under a history run that''s still going' {
            $script:still = $true
            $results = Stop-DemoEnvironment -Config $script:stopConfig -SaveHistory -Confirm:$false
            $script:order | Should -Not -Contain 'Pause'
            ($results | Where-Object { $_.checkId -eq 'STOP.FABRIC.CAPACITY' }).status | Should -Be 'Warning'
        }

        It 'saves nothing without -SaveHistory or saveHistoryOnStop, and touches neither with -ParkT2' {
            Stop-DemoEnvironment -Config $script:stopConfig -Confirm:$false | Out-Null
            $script:order | Should -Not -Contain 'SaveHistory'
            $script:order | Should -Contain 'Pause'
            $script:order.Clear()
            Stop-DemoEnvironment -Config $script:stopConfig -SaveHistory -ParkT2 -Confirm:$false | Out-Null
            $script:order | Should -Not -Contain 'SaveHistory'
            $script:order | Should -Not -Contain 'Pause'
            $script:stopConfig['fabric']['saveHistoryOnStop'] = $true
            $script:order.Clear()
            Stop-DemoEnvironment -Config $script:stopConfig -Confirm:$false | Out-Null
            $script:order | Should -Contain 'SaveHistory'
        }
    }
}

Describe 'The dev container (Phase 26b)' {
    BeforeAll {
        $script:devcontainer = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath '.devcontainer/devcontainer.json') -Raw | ConvertFrom-Json -AsHashtable
        $script:versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable
    }

    It 'pins Node.js to the CI version, Bicep and the .NET SDK to config/versions.json, and PowerShell to its pinned minor' {
        $features = $script:devcontainer['features']
        $node = $features.Keys | Where-Object { $_ -like 'ghcr.io/devcontainers/features/node:*' }
        $features[$node]['version'] | Should -Be ([string]$script:versions['fabricApp']['ciNodeVersion'])
        $cli = $features.Keys | Where-Object { $_ -like 'ghcr.io/devcontainers/features/azure-cli:*' }
        $features[$cli]['installBicep'] | Should -BeTrue
        $features[$cli]['bicepVersion'] | Should -Be ('v' + $script:versions['tools']['bicep'])
        $pwsh = $features.Keys | Where-Object { $_ -like 'ghcr.io/devcontainers/features/powershell:*' }
        $features[$pwsh]['version'] | Should -Be $script:versions['tools']['pwsh']
        $dotnet = $features.Keys | Where-Object { $_ -like 'ghcr.io/devcontainers/features/dotnet:*' }
        $features[$dotnet]['version'] | Should -Be $script:versions['tools']['dotnetSdk']
    }

    It 'asks for a machine big enough for the build and the Fabric App' {
        $script:devcontainer['hostRequirements']['cpus'] | Should -BeGreaterOrEqual 4
        $script:devcontainer['hostRequirements']['memory'] | Should -Match '^\d+gb$'
    }
}
