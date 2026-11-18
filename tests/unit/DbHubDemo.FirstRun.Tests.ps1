BeforeAll {
    # Phase 26b: the first-run automation (ADR 0023). Every Azure CLI call, Microsoft Graph request, Fabric request, and
    # prompt is mocked; no test touches the network. IDs are obvious placeholders (each group repeats one character), and
    # tokens are built at run time.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    # No test here reaches the Azure CLI (2026-11-16, tests/TestAzGuard.ps1): an az call that no test mocks gets what the
    # real CLI answered for these tests' made-up subscription, which they relied on, without leaving this process.
    Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
        $at = [array]::IndexOf([string[]]$ArgumentList, '--subscription')
        $subscription = if ($at -ge 0 -and $at + 1 -lt $ArgumentList.Count) { $ArgumentList[$at + 1] } else { '11111111-2222-3333-4444-555555555555' }
        [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ("ERROR: Subscription '{0}' not found. Check the spelling and casing and try again." -f $subscription) }
    }
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

    function New-FabricWorkspaceItem([string] $Name, [string] $Id, [string] $CapacityId = '') {
        # A workspace as List Workspaces returns it, with its own ID and the capacity it's on (issue 60).
        [pscustomobject]@{ id = $Id; displayName = $Name; type = 'Workspace'; capacityId = $CapacityId }
    }

    function New-FabricCapacityItem([string] $Name, [string] $Id) {
        [pscustomobject]@{ id = $Id; displayName = $Name; sku = 'F2'; state = 'Active'; region = 'West US 3' }
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
            OwnedGroups  = $null
            Create       = [pscustomobject]@{ Status = 'Created'; GroupId = $script:groupId; StatusCode = 201; Error = '' }
            Permissions  = [pscustomobject]@{ value = @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
            Inventory    = [pscustomobject]@{ Succeeded = $true; Error = ''; Groups = @{}; Deployments = [System.Collections.Generic.List[string]]::new() }
            Records      = @{}
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
        Mock -ModuleName DbHubDemo -CommandName Test-DemoEntraGroupOwner -MockWith { if ($null -ne $script:init.OwnedGroups) { $GroupId -in @($script:init.OwnedGroups) } else { $script:init.Owner } }
        Mock -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -MockWith { $script:calls.Add('CreateGroup'); $script:init.Create }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoGitHubRepositoryName -MockWith { 'contoso/fabric-database-hub-demo' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoWindowsTimeZoneId -MockWith { [pscustomobject]@{ Id = 'Eastern Standard Time'; IsUtc = $false } }
        # Issue 60: the subscription's resource groups and deployment records, empty unless a test puts an environment in
        # them (New-InitEnvironment), and each record's parameters.
        Mock -ModuleName DbHubDemo -CommandName Get-DemoSubscriptionInventory -MockWith { $script:calls.Add('Inventory'); $script:init.Inventory }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentRecord -MockWith {
            $script:calls.Add('Record:' + $Name)
            if ($script:init.Records.Contains($Name)) {
                [pscustomobject]@{ Found = $true; Error = ''; Parameters = $script:init.Records[$Name]; Timestamp = '2026-11-04'; State = 'Succeeded' }
            }
            else {
                [pscustomobject]@{ Found = $false; Error = ''; Parameters = @{}; Timestamp = ''; State = '' }
            }
        }
    }

    function New-InitEnvironment {
        # Puts a demo environment in the mocked subscription: its resource group with -Tag, its control's group with
        # -ControlTag, and its deployment record with -Parameter (none when it's $null).
        param([string] $Prefix = 'dbhub', [hashtable] $Tag = @{}, [AllowNull()] [hashtable] $Parameter = @{}, [AllowNull()] [hashtable] $ControlTag = $null)
        $script:init.Inventory.Groups[('rg-{0}-demo' -f $Prefix)] = $Tag
        if ($null -ne $ControlTag) {
            $script:init.Inventory.Groups[('rg-{0}-control' -f $Prefix)] = $ControlTag
        }
        if ($null -ne $Parameter) {
            $script:init.Inventory.Deployments.Add(('{0}-demo-main' -f $Prefix))
            $script:init.Records[('{0}-demo-main' -f $Prefix)] = $Parameter
        }
    }

    function New-RecordParameter {
        # What deploy.ps1 sent the template for an environment that isn't the defaults (Get-DemoDeploymentParameter's names).
        param([string] $Owner = 'colleague@contoso.example', [string] $OwnerEmail = 'budget@contoso.example', [string] $GroupId = $script:groupId)
        @{
            location = 'eastus2'; prefix = 'dbhub'; environment = 'demo'; networkMode = 'private'; outboundMode = 'DefaultOutboundAccess'
            owner = $Owner; ownerEmail = $OwnerEmail; costCenter = 'contoso-demo'; autoShutdownTime = '2000'; autoShutdownTimeZone = 'W. Europe Standard Time'
            expiresOn = ''; monthlyCeilingUsd = [long]250; profile = 'lowest-cost'; zone = ''; dataDiskSku = 'Auto'; t1Priority = 'Regular'
            hostPriority = 'Regular'; t1SecurityType = 'Standard'; hostSecurityType = 'Standard'; windowsHybridBenefit = $false
            sqlHybridBenefit = $false; hybridBenefitAttested = $false; t2SqlInstallMode = 'PaygWizard'; t2Mode = 'Nested'
            t3AdminGroupObjectId = $GroupId; t3AdminGroupDisplayName = 'sg-contoso-admins'; t3AutoPauseMinutes = [long]60; t3UseFreeLimit = $false
            activityProfile = 'baseline'; activityProfileOnBoot = $false; assignArcOnboardingRole = $true; t4Enabled = $true
            t4SkuName = 'Standard_D4ds_v5'; t4AutonomousTuning = $true; t4AvailabilityZone = ''
        }
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

    It 'writes a relative -Path under PowerShell''s current location, not the process''s working directory (review fix 8)' {
        # .NET resolves relative paths against [Environment]::CurrentDirectory, which Push-Location doesn't change.
        $location = Join-Path -Path $TestDrive -ChildPath ('location-' + [guid]::NewGuid().ToString('N'))
        $elsewhere = Join-Path -Path $TestDrive -ChildPath ('process-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $location -ChildPath 'config'), (Join-Path -Path $elsewhere -ChildPath 'config') -Force
        $saved = [System.Environment]::CurrentDirectory
        Push-Location -LiteralPath $location
        try {
            [System.Environment]::CurrentDirectory = $elsewhere
            $init = Initialize-DemoConfig -Path './config/proof.local.json' -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        }
        finally {
            [System.Environment]::CurrentDirectory = $saved
            Pop-Location
        }
        $init.Written | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $location -ChildPath 'config/proof.local.json') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $elsewhere -ChildPath 'config/proof.local.json') | Should -BeFalse
        (Get-InitResult $init 'INIT.CONFIG').evidence.path | Should -Be ([System.IO.Path]::Combine($location, 'config', 'proof.local.json'))
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
        $config['t2SqlInstallMode'] | Should -Be 'JumpstartImage' -Because 'the default since 2026-11-05: no person is needed for T2'
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
        @($init.NextSteps) -join "`n" | Should -Match 'nothing needs you: the Insights app deploys with your az login too' -Because 'the app''s Rayfin CLI needs no browser sign-in by default (2026-11-09)'
        @($init.NextSteps) -join "`n" | Should -Not -Match 'one browser sign-in'
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

    It 'asks which subscription and capacity when there''s a choice, never how T2 gets SQL Server, and writes the answers' {
        $script:init.Interactive = $true
        $script:init.Profile = [pscustomobject]@{ Installed = $true; SignedIn = $true; Error = ''; Subscriptions = @((New-ProfileEntry $script:subA 'Contoso Demo' $true), (New-ProfileEntry $script:subB 'Contoso Lab')) }
        $script:init.Capacities = @((New-FabricItem 'sharedcap' 'Inactive'), (New-FabricItem 'mycap'))
        foreach ($answer in 1, 1) {
            $script:init.Choices.Enqueue($answer)
        }
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -BackupDirectory $script:backup -Confirm:$false
        @($script:calls | Where-Object { $_ -like 'Ask:*' }).Count | Should -Be 2
        $config = Get-DemoConfig -Path $script:path
        $config['subscriptionId'] | Should -Be $script:subB
        $config['fabric']['capacityName'] | Should -Be 'mycap'
        $config['t2SqlInstallMode'] | Should -Be 'JumpstartImage' -Because 'a first deployment is one click (2026-11-09): no question, and the default needs nobody'
        (Get-InitResult $init 'INIT.FABRIC.CAPACITY').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Read-DemoChoice -Times 1 -Exactly -ParameterFilter { $Title -like '*capacity*' -and $Default -eq 1 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Read-DemoChoice -Times 0 -Exactly -ParameterFilter { $Title -like '*T2*' -or $Title -like '*SQL Server*' }
    }

    It 'writes the mode -T2SqlInstallMode chooses on purpose, without asking, and offers no setup-wizard mode (2026-11-09)' {
        $script:init.Interactive = $true
        Initialize-DemoConfig -Path $script:path -T2SqlInstallMode Developer -CreateAdminGroup -BackupDirectory $script:backup -Confirm:$false | Out-Null
        $written = Get-Content -LiteralPath $script:path -Raw | ConvertFrom-Json -AsHashtable
        $written['t2SqlInstallMode'] | Should -Be 'Developer'
        $written.Contains('t2PaygWizardOptIn') | Should -BeFalse
        $written.Contains('t4Enabled') | Should -BeFalse -Because 'T4 is part of every deployment'
        Should -Invoke -ModuleName DbHubDemo -CommandName Read-DemoChoice -Times 0 -Exactly -ParameterFilter { $Title -like '*T2*' -or $Title -like '*SQL Server*' }
        # The ValidateSet by its type: the parameter has other attributes too, and strict mode (as in CI) refuses
        # ValidValues on them.
        $set = @((Get-Command -Name Initialize-DemoConfig).Parameters['T2SqlInstallMode'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
        $set.Count | Should -Be 1
        $set[0].ValidValues | Should -Not -Contain 'PaygWizard' -Because 'no first run leads to the setup wizard'
        $set[0].ValidValues | Should -Contain 'Developer'
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

Describe 'A first run in a subscription that already has the environment (issue 60)' {
    BeforeEach {
        Set-InitMock
        $script:path = Join-Path -Path $TestDrive -ChildPath ('demo.config.{0}.json' -f [guid]::NewGuid().ToString('N'))
        $script:backup = Join-Path -Path $TestDrive -ChildPath 'backup'
        $script:otherGroupId = '77777777-aaaa-bbbb-cccc-777777777777'
        $script:init.Groups = @([pscustomobject]@{ id = $script:groupId; displayName = 'sg-contoso-admins'; securityEnabled = $true })
    }

    It 'writes the configuration from what''s deployed when the environment is yours, and creates no other administrators'' group' {
        New-InitEnvironment -Tag @{ owner = 'colleague@contoso.example'; DbHubNetworkMode = 'private'; DbHubT3AdminGroup = 'sg-contoso-admins' } -Parameter (New-RecordParameter)
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $init.Written | Should -BeTrue
        $written = Get-Content -LiteralPath $script:path -Raw | ConvertFrom-Json -AsHashtable
        $written['prefix'] | Should -Be 'dbhub'
        $written['location'] | Should -Be 'eastus2'
        $written['networkMode'] | Should -Be 'private' -Because 'auto would resolve from Azure Policy again, not from what''s deployed'
        $written['t3AdminGroupObjectId'] | Should -Be $script:groupId
        $written['owner'] | Should -Be 'colleague@contoso.example'
        $written['ownerEmail'] | Should -Be 'budget@contoso.example'
        $written['costCenter'] | Should -Be 'contoso-demo'
        $written['monthlyCeilingUsd'] | Should -Be 250
        $written['autoShutdownTime'] | Should -Be '2000'
        $written['autoShutdownTimeZone'] | Should -Be 'W. Europe Standard Time' -Because 'the schedule stays, whatever this machine''s time zone is'
        $written['securityType']['t1'] | Should -Be 'Standard'
        $written['t2SqlInstallMode'] | Should -Be 'PaygWizard'
        $written['t3AutoPauseMinutes'] | Should -Be 60
        $written['assignRoles'] | Should -BeTrue
        $written['expiresOn'] | Should -BeNullOrEmpty
        $written.Contains('t4SkuName') | Should -BeFalse -Because 'the record''s T4 size is the default'
        (Get-DemoConfig -Path $script:path)['t2SqlInstallModeSource'] | Should -Be 'legacy' -Because 'deploy.ps1 still runs PaygWizard as JumpstartImage'
        Should -Invoke -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -Times 0 -Exactly
        $group = Get-InitResult $init 'INIT.P6.GROUP'
        $group.status | Should -Be 'Pass'
        $group.message | Should -Match 'Keeping, as deployed, the security group "sg-contoso-admins"'
        $existing = Get-InitResult $init 'INIT.EXISTING'
        $existing.status | Should -Be 'Warning'
        $existing.message | Should -Match 'rg-dbhub-demo exists in this subscription, and it''s yours \(its owner tag is your sign-in\)'
        $existing.message | Should -Match 'region eastus2, network private, the administrators'' group "sg-contoso-admins"'
        $existing.message | Should -Match 'have the defaults: .*sessionCeilingUsd'
        ($existing.message -split 'have the defaults: ')[1] | Should -Not -Match '\blocation\b|networkMode|ownerEmail'
        (Get-InitResult $init 'INIT.CONFIG').message | Should -Match 'network private'
        (Get-InitResult $init 'INIT.USER').message | Should -Match 'budget alerts go to budget@contoso\.example \(as rg-dbhub-demo has it\)'
        $order = @($init.Results | ForEach-Object { $_.checkId })
        [array]::IndexOf($order, 'INIT.USER') | Should -BeLessThan ([array]::IndexOf($order, 'INIT.P1.CONTRIBUTOR')) -Because 'the first open item a NOT DONE names stays the same'
        $init.Existing.Kind | Should -Be 'Recovered'
        $init.Existing.Note | Should -Match '^No configuration file: rg-dbhub-demo is yours, so its configuration was written from what''s deployed \(region eastus2, network private'
    }

    It 'tells it''s yours by its administrators'' group too, and recovers from the tags alone when its record is gone' {
        $script:init.OwnedGroups = @($script:groupId)
        New-InitEnvironment -Tag @{ owner = 'ops-team'; DbHubNetworkMode = 'private'; DbHubT3AdminGroup = 'sg-contoso-admins'; autoShutdown = '2000 W. Europe Standard Time'; costCenter = 'contoso-demo' } -Parameter $null
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $written = Get-DemoConfig -Path $script:path
        $written['networkMode'] | Should -Be 'private'
        $written['t3AdminGroupObjectId'] | Should -Be $script:groupId
        $written['owner'] | Should -Be 'ops-team'
        $written['ownerEmail'] | Should -Be 'colleague@contoso.example' -Because 'the tags don''t hold the budget address, so it''s your sign-in''s'
        $written['autoShutdownTime'] | Should -Be '2000'
        $written['autoShutdownTimeZone'] | Should -Be 'W. Europe Standard Time'
        $written['location'] | Should -Be 'westus3'
        Should -Invoke -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -Times 0 -Exactly
        $existing = Get-InitResult $init 'INIT.EXISTING'
        $existing.message | Should -Match 'you own the security group that administers its T3 and T4'
        $existing.message | Should -Match 'its resource group''s tags, without a deployment record'
        ($existing.message -split 'have the defaults: ')[1] | Should -Match '\blocation\b'
    }

    It 'never writes for an environment that isn''t yours: the first run names a new one, with a free prefix, its own group, and its own workspace' {
        $script:init.OwnedGroups = @()
        New-InitEnvironment -Tag @{ owner = 'someone@fabrikam.example'; DbHubNetworkMode = 'private' } -Parameter (New-RecordParameter -Owner 'someone@fabrikam.example' -OwnerEmail 'someone@fabrikam.example' -GroupId $script:otherGroupId)
        New-InitEnvironment -Prefix 'dbhub2' -Tag @{ owner = 'another@fabrikam.example' } -Parameter $null
        $script:init.Groups = @()
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $written = Get-DemoConfig -Path $script:path
        $written['prefix'] | Should -Be 'dbhub3'
        $written['networkMode'] | Should -Be 'auto' -Because 'nothing is taken from an environment that isn''t yours'
        $written['ownerEmail'] | Should -Be 'colleague@contoso.example'
        $written['fabric']['workspaceName'] | Should -Be 'Database Hub Demo dbhub3'
        Should -Invoke -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -Times 1 -Exactly -ParameterFilter { $DisplayName -eq 'dbhub3-demo-sql-admins' }
        $existing = Get-InitResult $init 'INIT.EXISTING'
        $existing.status | Should -Be 'Warning'
        $existing.message | Should -Match 'rg-dbhub-demo exists in this subscription, and it isn''t yours'
        $existing.message | Should -Match 'the prefix dbhub3: rg-dbhub3-demo, the administrators'' group "dbhub3-demo-sql-admins", and the Fabric workspace "Database Hub Demo dbhub3"'
        $existing.message | Should -Match 'rg-dbhub2-demo is taken too'
        (@($init.Results | ForEach-Object { '{0} {1}' -f $_.message, $_.remediation }) -join ' ') | Should -Not -Match 'fabrikam' -Because 'no message names another person''s address'
        $init.Existing.Kind | Should -Be 'NewPrefix'
        $init.Existing.Note | Should -Match 'rg-dbhub-demo isn''t yours, so this run never changes it: it deploys a new environment, rg-dbhub3-demo'
    }

    It 'takes the first next prefix that''s yours over a free one, so a later lost configuration finds its environment again' {
        $script:init.OwnedGroups = @()
        New-InitEnvironment -Tag @{ owner = 'someone@fabrikam.example' } -Parameter (New-RecordParameter -Owner 'someone@fabrikam.example' -OwnerEmail 'someone@fabrikam.example' -GroupId $script:otherGroupId)
        New-InitEnvironment -Prefix 'dbhub3' -Tag @{ owner = 'colleague@contoso.example' } -Parameter (New-RecordParameter)
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $written = Get-DemoConfig -Path $script:path
        $written['prefix'] | Should -Be 'dbhub3' -Because 'dbhub2 is free, but rg-dbhub3-demo is yours'
        $written['location'] | Should -Be 'eastus2'
        $written['t3AdminGroupObjectId'] | Should -Be $script:groupId
        (Get-InitResult $init 'INIT.EXISTING').message | Should -Match '^rg-dbhub-demo isn''t yours, so a first run never updates it\. rg-dbhub3-demo exists in this subscription, and it''s yours'
        Should -Invoke -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -Times 0 -Exactly
    }

    It 'never gives a next prefix''s environment the default workspace, which is the default prefix''s, also when Fabric can''t be read' {
        $script:init.OwnedGroups = @()
        $script:init.Workspaces = @(New-FabricWorkspaceItem 'Database Hub Demo' 'dddddddd-0000-0000-0000-000000000001' $script:capacityFabricId)
        New-InitEnvironment -Tag @{ owner = 'someone@fabrikam.example' } -Parameter (New-RecordParameter -Owner 'someone@fabrikam.example' -OwnerEmail 'someone@fabrikam.example' -GroupId $script:otherGroupId)
        New-InitEnvironment -Prefix 'dbhub2' -Tag @{ owner = 'colleague@contoso.example' } -Parameter (New-RecordParameter)
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-DemoConfig -Path $script:path)['fabric']['workspaceName'] | Should -Be 'Database Hub Demo dbhub2'
        $existing = Get-InitResult $init 'INIT.EXISTING'
        $existing.message | Should -Not -Match 'the Fabric workspace "' -Because 'it isn''t recovered from what''s deployed'
        ($existing.message -split 'have the defaults: ')[1] | Should -Match 'fabric\.workspaceName'

        Mock -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -MockWith { throw 'Fabric refused the token.' }
        $unread = Join-Path -Path $TestDrive -ChildPath ('unread.{0}.json' -f [guid]::NewGuid().ToString('N'))
        $init = Initialize-DemoConfig -Path $unread -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-DemoConfig -Path $unread)['fabric']['workspaceName'] | Should -Be 'Database Hub Demo dbhub2'
        $existing = Get-InitResult $init 'INIT.EXISTING'
        $existing.message | Should -Not -Match 'the Fabric workspace "'
        ($existing.message -split 'have the defaults: ')[1] | Should -Match 'fabric\.workspaceName'
        @($init.Results | Where-Object { $_.checkId -eq 'INIT.FABRIC.WORKSPACE' }).Count | Should -Be 0 -Because 'no -Prefix was given, so the run stays one click'
    }

    It 'writes nothing for an explicit -Prefix whose environment isn''t yours, unless -OwnerEmail names the budget address it records' {
        $script:init.OwnedGroups = @()
        $script:init.Workspaces = @(New-FabricWorkspaceItem 'Contoso VN' 'dddddddd-0000-0000-0000-000000000001' $script:capacityFabricId)
        New-InitEnvironment -Prefix 'dbhubvn' -Tag @{ owner = 'alias'; DbHubFabricWorkspaceId = 'dddddddd-0000-0000-0000-000000000001' } -Parameter (New-RecordParameter -Owner 'alias' -OwnerEmail 'alias@contoso.example')
        $init = Initialize-DemoConfig -Path $script:path -Prefix 'dbhubvn' -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $init.Written | Should -BeFalse
        Test-Path -LiteralPath $script:path | Should -BeFalse
        $refused = Get-InitResult $init 'INIT.EXISTING'
        $refused.status | Should -Be 'Manual action required'
        $refused.remediation | Should -Match 'init\.ps1 -Prefix dbhubvn -OwnerEmail <the budget address it records>'
        Should -Invoke -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Get-DemoFabricToken -Times 0 -Exactly

        $claimed = Initialize-DemoConfig -Path $script:path -Prefix 'dbhubvn' -OwnerEmail 'alias@contoso.example' -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $claimed.Written | Should -BeTrue
        (Get-InitResult $claimed 'INIT.EXISTING').message | Should -Match 'its budget address is the -OwnerEmail you gave'
        $written = Get-DemoConfig -Path $script:path
        $written['prefix'] | Should -Be 'dbhubvn'
        $written['fabric']['workspaceName'] | Should -Be 'Contoso VN'
        $written['owner'] | Should -Be 'alias'
    }

    It 'asks for the workspace of another prefix''s environment that doesn''t record it, instead of taking the default, which may be another environment''s' {
        $script:init.Workspaces = @(New-FabricWorkspaceItem 'Database Hub Demo' 'dddddddd-0000-0000-0000-000000000001' $script:capacityFabricId)
        New-InitEnvironment -Prefix 'dbhubvu' -Tag @{ owner = 'colleague@contoso.example' } -Parameter (New-RecordParameter)
        $init = Initialize-DemoConfig -Path $script:path -Prefix 'dbhubvu' -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $workspace = Get-InitResult $init 'INIT.FABRIC.WORKSPACE'
        $workspace.status | Should -Be 'Manual action required'
        $workspace.remediation | Should -Match 'init\.ps1 -Force -Prefix dbhubvu -WorkspaceName'
        (Get-DemoConfig -Path $script:path)['fabric']['workspaceName'] | Should -Not -Be 'Database Hub Demo'
        $named = Initialize-DemoConfig -Path $script:path -Prefix 'dbhubvu' -WorkspaceName 'Contoso VU' -Force -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        (Get-InitResult $named 'INIT.FABRIC.WORKSPACE').status | Should -Be 'Pass'
        (Get-DemoConfig -Path $script:path)['fabric']['workspaceName'] | Should -Be 'Contoso VU'
    }

    It 'writes nothing, and creates no group, when it can''t check what the subscription holds' {
        $script:init.Inventory = [pscustomobject]@{ Succeeded = $false; Error = 'the resource groups couldn''t be listed: HTTP 503'; Groups = @{}; Deployments = @() }
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $init.Written | Should -BeFalse
        Test-Path -LiteralPath $script:path | Should -BeFalse
        $unread = Get-InitResult $init 'INIT.EXISTING'
        $unread.status | Should -Be 'Fail'
        $unread.message | Should -Match 'HTTP 503'
        Should -Invoke -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -Times 0 -Exactly
        $init.Existing.Kind | Should -Be 'Unreadable'
    }

    It 'recovers in a -WhatIf run too, reading only: no file, no group, and the summary says what it would hold' {
        New-InitEnvironment -Tag @{ owner = 'colleague@contoso.example' } -Parameter (New-RecordParameter)
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -WhatIf
        $init.Written | Should -BeFalse
        Test-Path -LiteralPath $script:path | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName New-DemoEntraSecurityGroup -Times 0 -Exactly
        $summary = (Get-InitResult $init 'INIT.CONFIG').message
        $summary | Should -Match '^What if:'
        $summary | Should -Match 'region eastus2, prefix dbhub, network private, T2 PaygWizard'
        $summary | Should -Match 'the P6 group "sg-contoso-admins"'
        (Get-InitResult $init 'INIT.EXISTING').message | Should -Match 'so the configuration would be written from what''s deployed'
        $init.Existing.Note | Should -Match 'would be written from what''s deployed'
    }

    It 'takes the Fabric workspaces it records, and the capacity its workspace is on, without asking' {
        $capacityA = 'cccccccc-0000-0000-0000-00000000000a'
        $capacityB = 'cccccccc-0000-0000-0000-00000000000b'
        $script:init.Capacities = @((New-FabricCapacityItem 'capa' $capacityA), (New-FabricCapacityItem 'capb' $capacityB))
        $script:init.Workspaces = @((New-FabricWorkspaceItem 'Contoso Hub' 'dddddddd-0000-0000-0000-000000000001' $capacityB), (New-FabricWorkspaceItem 'Contoso Hub Ctl' 'dddddddd-0000-0000-0000-000000000002' $capacityB))
        New-InitEnvironment -Tag @{ owner = 'colleague@contoso.example'; DbHubFabricWorkspaceId = 'dddddddd-0000-0000-0000-000000000001'; DbHubControlWorkspaceId = 'dddddddd-0000-0000-0000-000000000002' } -Parameter (New-RecordParameter) -ControlTag @{ owner = 'colleague@contoso.example' }
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $written = Get-DemoConfig -Path $script:path
        $written['fabric']['workspaceName'] | Should -Be 'Contoso Hub'
        $written['fabric']['capacityName'] | Should -Be 'capb' -Because 'the workspace keeps its capacity, so there''s no choice to ask about'
        $written['fabric']['importNotebooks'] | Should -BeFalse
        $written['control']['fabricWorkspaceName'] | Should -Be 'Contoso Hub Ctl'
        (Get-InitResult $init 'INIT.FABRIC.CAPACITY').status | Should -Be 'Pass'
        (Get-InitResult $init 'INIT.FABRIC.CAPACITY').message | Should -Match 'The workspace "Contoso Hub" stays on its capacity capb'
        Should -Invoke -ModuleName DbHubDemo -CommandName Read-DemoChoice -Times 0 -Exactly
    }

    It 'keeps "DBHub Control", the control''s workspace before 2026-11-14, for the default prefix''s environment that doesn''t record its workspaces' {
        $script:init.Workspaces = @((New-FabricWorkspaceItem 'Database Hub Demo' 'dddddddd-0000-0000-0000-000000000001' $script:capacityFabricId), (New-FabricWorkspaceItem 'DBHub Control' 'dddddddd-0000-0000-0000-000000000002' $script:capacityFabricId))
        New-InitEnvironment -Tag @{ owner = 'colleague@contoso.example' } -Parameter (New-RecordParameter) -ControlTag @{ owner = 'colleague@contoso.example' }
        $init = Initialize-DemoConfig -Path $script:path -CreateAdminGroup -NonInteractive -BackupDirectory $script:backup -Confirm:$false
        $written = Get-Content -LiteralPath $script:path -Raw | ConvertFrom-Json -AsHashtable
        $written['fabric']['workspaceName'] | Should -Be 'Database Hub Demo'
        $written['control']['fabricWorkspaceName'] | Should -Be 'DBHub Control'
        $written['control']['enabled'] | Should -BeTrue -Because 'Get-DemoActivityControlSetting keeps "DBHub Control" only with "enabled": true'
        InModuleScope DbHubDemo -Parameters @{ Config = (Get-DemoConfig -Path $script:path) } { (Get-DemoActivityControlSetting -Config $Config).FabricWorkspaceName } | Should -Be 'DBHub Control'
        (Get-InitResult $init 'INIT.EXISTING').message | Should -Match 'the Fabric workspace "Database Hub Demo" \(by its default name: it doesn''t record one\), the control''s workspace "DBHub Control"'
    }
}

Describe 'Reading back what a deployment recorded (issue 60)' {
    It 'reads the inventory and a record as text: tags and dates stay as Azure holds them, and a missing record isn''t an error' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAz -MockWith {
            switch -Wildcard ($ArgumentList -join ' ') {
                'group list*' { [pscustomobject]@{ ExitCode = 0; StdOut = '[{"name":"rg-dbhub-demo","tags":{"owner":"colleague@contoso.example","DbHubDeployStageUtc":"2026-11-04T20:58:57Z"}},{"name":"rg-other","tags":null}]'; StdErr = '' } }
                'deployment sub list*' { [pscustomobject]@{ ExitCode = 0; StdOut = '["dbhub-demo-main","other"]'; StdErr = '' } }
                'deployment sub show --name dbhub-demo-main*' { [pscustomobject]@{ ExitCode = 0; StdOut = '{"timestamp":"2026-11-04T13:48:30.742995+00:00","state":"Succeeded","parameters":{"expiresOn":{"type":"String","value":"2026-12-31"},"monthlyCeilingUsd":{"type":"Int","value":250},"assignArcOnboardingRole":{"type":"Bool","value":true},"existingVmNames":{"type":"Array","value":["sqlvm01"]}}}'; StdErr = '' } }
                'deployment sub show --name broken-demo-main*' { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (AuthorizationFailed) The client does not have authorization.' } }
                default { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = "ERROR: (DeploymentNotFound) Deployment 'dbhub2-demo-main' could not be found." } }
            }
        }
        InModuleScope DbHubDemo -Parameters @{ Sub = $script:subA } {
            $inventory = Get-DemoSubscriptionInventory -SubscriptionId $Sub
            $inventory.Succeeded | Should -BeTrue
            $inventory.Groups['RG-DBHUB-DEMO']['DbHubDeployStageUtc'] | Should -Be '2026-11-04T20:58:57Z'
            $inventory.Groups['rg-other'].Count | Should -Be 0
            @($inventory.Deployments) | Should -Contain 'dbhub-demo-main'
            $record = Get-DemoDeploymentRecord -SubscriptionId $Sub -Name 'dbhub-demo-main'
            $record.Found | Should -BeTrue
            $record.Timestamp | Should -Be '2026-11-04'
            $record.Parameters['expiresOn'] | Should -BeOfType [string]
            $record.Parameters['expiresOn'] | Should -Be '2026-12-31'
            $record.Parameters['monthlyCeilingUsd'] | Should -Be 250
            $record.Parameters['assignArcOnboardingRole'] | Should -BeTrue
            $missing = Get-DemoDeploymentRecord -SubscriptionId $Sub -Name 'dbhub2-demo-main'
            $missing.Found | Should -BeFalse
            $missing.Error | Should -BeNullOrEmpty
            (Get-DemoDeploymentRecord -SubscriptionId $Sub -Name 'broken-demo-main').Error | Should -Match 'AuthorizationFailed'
        }
    }

    It 'keeps a T4 size the configuration set, never one its fallback or an older default chose, and turns tuning off only where it had been' {
        InModuleScope DbHubDemo {
            (ConvertFrom-DemoDeploymentRecord -Parameter @{ t4SkuName = 'Standard_D4ds_v5'; t4AutonomousTuning = $true } -Tag @{}).Values.Contains('t4SkuName') | Should -BeFalse
            (ConvertFrom-DemoDeploymentRecord -Parameter @{ t4SkuName = 'Standard_B2s'; t4AutonomousTuning = $false } -Tag @{}).Values['t4SkuName'] | Should -Be 'Standard_B2s'
            (ConvertFrom-DemoDeploymentRecord -Parameter @{ t4SkuName = 'Standard_B2s' } -Tag @{}).Values['t4SkuName'] | Should -Be 'Standard_B2s' -Because 'Standard_B2s was never a default'
            $oldDefault = ConvertFrom-DemoDeploymentRecord -Parameter @{ t4SkuName = 'Standard_B1ms'; t4AutonomousTuning = $false } -Tag @{}
            $oldDefault.Values.Contains('t4SkuName') | Should -BeFalse -Because 'every profile''s default before 2026-11-04, which a server that kept its size also sends (the review of issue 60)'
            @($oldDefault.Notes) -join ' ' | Should -Match 'deploy\.ps1 moves it to Standard_D4ds_v5 once its cost check passes'
            (ConvertFrom-DemoDeploymentRecord -Parameter @{ t4SkuName = 'Standard_D2ds_v5'; t4AutonomousTuning = $false } -Tag @{ DbHubT4Size = 'Standard_D2ds_v5'; DbHubT4Refused = 'Standard_B2s@any;2026-11-10T00:00Z' }).Values['t4SkuName'] | Should -Be 'Standard_B2s' -Because 'the configuration asked for the size Azure refused first'
            (ConvertFrom-DemoDeploymentRecord -Parameter @{ t4SkuName = 'Standard_D2ds_v5'; t4AutonomousTuning = $false } -Tag @{ DbHubT4Size = 'Standard_D2ds_v5' }).Values.Contains('t4SkuName') | Should -BeFalse -Because 'the fallback stood in for the default, which Resolve-DemoEffectiveConfig keeps'
            (ConvertFrom-DemoDeploymentRecord -Parameter @{ t4SkuName = 'Standard_D2ds_v5' } -Tag @{ DbHubT4Sku = 'Standard_D2ds_v5' }).Values.Contains('t4SkuName') | Should -BeFalse -Because 'Phase 28''s fallback chose it'
            (ConvertFrom-DemoDeploymentRecord -Parameter @{ t4SkuName = 'Standard_D4ds_v5'; t4AutonomousTuning = $false; t4Enabled = $true } -Tag @{}).Values['t4AutonomousTuning'] | Should -BeFalse
            (ConvertFrom-DemoDeploymentRecord -Parameter @{ t4SkuName = 'Standard_D2ds_v5'; t4AutonomousTuning = $false } -Tag @{}).Values.Contains('t4AutonomousTuning') | Should -BeFalse
        }
    }

    It 'counts your addresses, your administrators'' group, or a claim, never an alias' {
        InModuleScope DbHubDemo {
            (Test-DemoEnvironmentOwner -Address 'Colleague@Contoso.example' -OwnerTag 'colleague@contoso.example').Signal | Should -Be 'owner-tag'
            (Test-DemoEnvironmentOwner -Address 'colleague@contoso.example' -Parameter @{ ownerEmail = 'COLLEAGUE@contoso.example' }).Signal | Should -Be 'owner-email'
            (Test-DemoEnvironmentOwner -Address 'colleague@contoso.example' -OwnerTag 'colleague').Mine | Should -BeFalse -Because 'an alias isn''t enough'
            (Test-DemoEnvironmentOwner -Address 'colleague@contoso.example' -OwnerTag 'someone@fabrikam.example' -GroupOwned $true).Signal | Should -Be 'admin-group'
            (Test-DemoEnvironmentOwner -Address 'colleague@contoso.example' -Parameter @{ ownerEmail = 'budget@contoso.example' } -Claim 'budget@contoso.example').Signal | Should -Be 'claim'
            (Test-DemoEnvironmentOwner -Address @() -OwnerTag @() -GroupOwned $null).Mine | Should -BeFalse
        }
    }

    It 'tries prefixes the schema allows, each at most 8 characters' {
        $candidates = InModuleScope DbHubDemo { Get-DemoPrefixCandidate -Prefix 'dbhub' }
        $candidates[0] | Should -Be 'dbhub2'
        $candidates[-1] | Should -Be 'dbhub99'
        @(InModuleScope DbHubDemo { Get-DemoPrefixCandidate -Prefix 'contosox' }) | ForEach-Object { $_ | Should -Match '^[a-z][a-z0-9]{2,7}$' }
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
        $result.remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
        $result.remediation | Should -Not -Match 'npx' -Because 'npx resolves the CLI''s dependencies without the lock file''s npm overrides (2026-11-09)'
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
        $script:notebookKnows = [pscustomobject]@{ Known = $true; Has = $true; Error = '' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricNotebookParameter -MockWith { $script:notebookKnows }
    }

    It 'sends T4''s metrics only to a copy of the notebook that knows POSTGRES_METRICS, and otherwise says so and asks to keep them (2026-11-16)' {
        # An environment whose deploy.ps1 met a paused capacity still has the notebook from before T4's history, which
        # would ignore them: the history then mustn't read as if they were saved.
        $script:notebookKnows = [pscustomobject]@{ Known = $true; Has = $false; Error = '' }
        $saved = InModuleScope DbHubDemo -Parameters @{ C = $script:historyConfig } { Save-DemoFabricHistory -Config $C -PostgresMetrics '{"version":1}' }
        $saved.Result.status | Should -Be 'Warning'
        $saved.Result.message | Should -Match 'T4''s metrics weren''t sent: the workspace''s NB_DatabaseHub_LiveActivity is from before T4''s history \(2026-11-13\), so it would ignore them\.$'
        $saved.Result.remediation | Should -Match '^Run \./scripts/configure-fabric\.ps1, which updates the notebook \(fabric\.importNotebooks is false, so deploy\.ps1 keeps the workspace''s copy\)\. T4''s metrics are kept in out/history-pending'
        $saved.PostgresDropped | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 1 -Exactly -ParameterFilter { -not $Parameter.Contains('POSTGRES_METRICS') }
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricNotebookParameter -Times 1 -Exactly -ParameterFilter { $WorkspaceId -eq '13131313-1313-1313-1313-131313131313' -and $Name -eq 'NB_DatabaseHub_LiveActivity' -and $Parameter -eq 'POSTGRES_METRICS' }
        # With fabric.importNotebooks true, which init.ps1 writes, deploy.ps1 updates it (2026-11-16).
        $updating = @{} + $script:historyConfig
        $updating['fabric'] = @{ workspaceName = 'Database Hub Demo'; lakehouseName = 'LH_DatabaseHub'; importNotebooks = $true }
        $saved = InModuleScope DbHubDemo -Parameters @{ C = $updating } { Save-DemoFabricHistory -Config $C -PostgresMetrics '{"version":1}' }
        $saved.Result.remediation | Should -Match '^Run \./scripts/deploy\.ps1, which updates the notebook\. T4''s metrics are kept in out/history-pending'

        # A copy that knows it, and one whose definition can't be read, get them as before.
        foreach ($knows in @([pscustomobject]@{ Known = $true; Has = $true; Error = '' }, [pscustomobject]@{ Known = $false; Has = $false; Error = 'a fake error' })) {
            $script:notebookKnows = $knows
            $saved = InModuleScope DbHubDemo -Parameters @{ C = $script:historyConfig } { Save-DemoFabricHistory -Config $C -PostgresMetrics '{"version":1}' }
            $saved.Result.status | Should -Be 'Pass'
            $saved.PostgresDropped | Should -BeFalse
        }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 2 -Exactly -ParameterFilter { $Parameter['POSTGRES_METRICS'] -eq '{"version":1}' }

        # Without metrics, nothing is read.
        $null = InModuleScope DbHubDemo -Parameters @{ C = $script:historyConfig } { Save-DemoFabricHistory -Config $C }
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricNotebookParameter -Times 4 -Exactly
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

    It 'says it''s the capacity, not a lakehouse to create, when Fabric refused the lakehouse list because the capacity is paused (live finding, 2026-11-10)' {
        Mock -ModuleName DbHubDemo -CommandName Resolve-DemoFabricConfig -MockWith {
            $copy = @{ subscriptionId = $script:subA; tenantId = $script:tenant; prefix = 'dbhub'; environment = 'demo'; fabric = @{ workspaceId = '13131313-1313-1313-1313-131313131313' } }
            $refused = New-DemoResult -CheckId 'FABRIC.RESOLVE.LAKEHOUSE' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'The lakehouses in the workspace "Database Hub Demo" couldn''t be listed, because its capacity is paused or inactive.' -Evidence ([ordered]@{ lakehouseName = 'LH_DatabaseHub'; statusCode = 404; listed = $false; error = 'HTTP 404: CapacityNotActive: Internal error CapacityNotActive.Capacity is not active.'; capacityInactive = $true })
            [pscustomobject]@{ Resolved = $false; Config = $copy; Results = @($refused) }
        }
        $saved = InModuleScope DbHubDemo -Parameters @{ C = $script:historyConfig } { Save-DemoFabricHistory -Config $C }
        $saved.Result.status | Should -Be 'Manual action required'
        $saved.Result.message | Should -Be 'The session''s history wasn''t saved: the workspace''s capacity is paused or inactive, so notebooks can''t run (HTTP 404: CapacityNotActive: Internal error CapacityNotActive.Capacity is not active).'
        $saved.Result.remediation | Should -Match '^Resume the capacity'
        $saved.Result.remediation | Should -Not -Match 'creates what''s missing'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricNotebookRun -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricWorkspace -Times 0 -Exactly
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

        It 'keeps T4''s and its read replica''s captured metrics when the history run didn''t save them, and only then (ADR 0025)' {
            # stop-demo.ps1 deletes the replica, and Azure Monitor no longer answers for its metrics then: a paused capacity
            # mustn't lose the session's lag without a word.
            $script:stopConfig['t4Enabled'] = $true
            $script:saveStatus = 'Manual action required'
            Mock -ModuleName DbHubDemo -CommandName Get-DemoDeploymentState -MockWith { [pscustomobject]@{ Exists = $true; RunnerSha256 = ''; RunnerSentTo = @(); HostPasswordUtc = ''; Tags = @{ deploymentId = 'abc123' }; T4Replica = 'Session'; FabricCapacityResumed = ''; FabricCapacityResumedUtc = '' } }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoT4State -MockWith { [pscustomobject]@{ State = 'Ready'; Exists = $true; Removing = $false } }
            Mock -ModuleName DbHubDemo -CommandName Get-DemoPostgresHistoryCapture -MockWith { $script:order.Add('Capture'); [pscustomobject]@{ Json = '{"version":1}'; Result = (New-DemoResult -CheckId 'STOP.T4.HISTORY' -Area 'fabric' -Target 'T4' -Status 'Pass' -Message 'captured') } }
            Mock -ModuleName DbHubDemo -CommandName Remove-DemoT4Replica -MockWith { $script:order.Add('DeleteReplica'); New-DemoResult -CheckId 'STOP.T4.REPLICA' -Area 'infra' -Target 'T4' -Status 'Pass' -Message 'deleted' -Evidence @{ replica = 'pgreplica01-abc123'; stateBefore = 'Ready' } }
            Mock -ModuleName DbHubDemo -CommandName Wait-DemoT4ReplicaState -MockWith { [pscustomobject]@{ State = 'NotFound'; Present = $false; Names = [pscustomobject]@{ ServerName = 'pgreplica01-abc123' } } }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -MockWith { New-DemoResult -CheckId 'STOP.T4.STOP' -Area 'infra' -Target 'T4' -Status 'Pass' -Message 'stopped' }
            # This run deleted the replica, so T4's stop is the confirmed one (R843), which its own tests cover.
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT4StopConfirmed -MockWith { $script:order.Add('ConfirmedStop'); New-DemoResult -CheckId 'STOP.T4.STOP' -Area 'infra' -Target 'T4' -Status 'Pass' -Message 'stopped' }
            Mock -ModuleName DbHubDemo -CommandName Save-DemoPostgresHistoryPending -MockWith { $script:order.Add('Keep:' + $Json); New-DemoResult -CheckId 'STOP.T4.HISTORY.PENDING' -Area 'fabric' -Target 'T4' -Status 'Warning' -Message 'kept' }
            $script:dropped = $false
            Mock -ModuleName DbHubDemo -CommandName Save-DemoFabricHistory -MockWith { $script:order.Add('SaveHistory:' + $PostgresMetrics); [pscustomobject]@{ Result = (New-DemoResult -CheckId 'STOP.FABRIC.SAVEHISTORY' -Area 'fabric' -Target 'fabric' -Status $script:saveStatus -Message 'history'); StillRunning = $script:still; PostgresDropped = $script:dropped } }

            $results = Stop-DemoEnvironment -Config $script:stopConfig -SaveHistory -Confirm:$false
            $script:order.IndexOf('Capture') | Should -BeLessThan $script:order.IndexOf('DeleteReplica') -Because 'a deleted replica''s metrics are gone'
            @($script:order | Where-Object { $_ -eq 'DeleteReplica' }).Count | Should -Be 1 -Because 'the delete goes once; the wait sees it gone'
            $script:order.IndexOf('DeleteReplica') | Should -BeLessThan $script:order.IndexOf('ConfirmedStop') -Because 'T4''s stop after the replica''s delete is confirmed (R843)'
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoT4PowerAction -Times 0 -Exactly -Because 'only the confirmed stop stops T4 when this run deleted the replica'
            ($results | Where-Object { $_.checkId -eq 'STOP.T4.REPLICA' }).message | Should -Be 'T4''s read replica (pgreplica01-abc123) was deleted, so nothing bills for it until the next session creates it again.' -Because 'live, a second call said "isn''t there, so there''s nothing to delete" after this run deleted it'
            $script:order | Should -Contain 'SaveHistory:{"version":1}'
            $script:order | Should -Contain 'Keep:{"version":1}'
            ($results | Where-Object { $_.checkId -eq 'STOP.T4.HISTORY.PENDING' }).status | Should -Be 'Warning'

            # Saved, or still running in Fabric with the metrics: nothing to keep.
            foreach ($case in @(@{ Status = 'Pass'; Still = $false }, @{ Status = 'Warning'; Still = $true })) {
                $script:order.Clear()
                $script:saveStatus = $case.Status
                $script:still = $case.Still
                $results = Stop-DemoEnvironment -Config $script:stopConfig -SaveHistory -Confirm:$false
                @($script:order | Where-Object { $_ -like 'Keep:*' }).Count | Should -Be 0 -Because $case.Status
                $results | Where-Object { $_.checkId -eq 'STOP.T4.HISTORY.PENDING' } | Should -BeNullOrEmpty
            }

            # Saved without them, because the workspace's notebook predates T4's history (2026-11-16): they're kept.
            $script:order.Clear()
            $script:saveStatus = 'Warning'
            $script:still = $false
            $script:dropped = $true
            $results = Stop-DemoEnvironment -Config $script:stopConfig -SaveHistory -Confirm:$false
            $script:order | Should -Contain 'Keep:{"version":1}'
            ($results | Where-Object { $_.checkId -eq 'STOP.T4.HISTORY.PENDING' }).status | Should -Be 'Warning'
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
