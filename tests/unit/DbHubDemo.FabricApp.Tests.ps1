BeforeAll {
    # Phase 19b: the Fabric App (preview) deploy step. The Rayfin CLI, npm, node, and every web request are mocked; no
    # test touches the network or Fabric, and every ID is an obvious placeholder. Fake keys are built at run time so
    # secret scanners don't flag this file.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    Initialize-GuardTestContext -SubscriptionId $script:HubSubscriptionId -TenantId $script:HubTenantId
    $script:configureApp = Join-Path -Path $repoRoot -ChildPath 'scripts/configure-fabric-app.ps1'
    $script:workspaceId = '11111111-1111-1111-1111-111111111111'
    $script:modelId = '33333333-3333-3333-3333-333333333333'
    $script:reportId = '44444444-4444-4444-4444-444444444444'
    $script:itemId = '55555555-5555-5555-5555-555555555555'
    $script:dashboardId = '66666666-6666-6666-6666-666666666666'
    $script:capacityId = '77777777-7777-7777-7777-777777777777'
    $script:tenantId = $script:HubTenantId
    $script:fakeKey = 'pk' + '-' + ('Zq' * 10)
    $script:token = ConvertTo-HubSecureString ('tok' + ('x' * 40))
    $script:hosting = 'https://app-example.invalid'

    function New-CliResult([object] $Data, [int] $ExitCode = 0, [string] $StdErr = '') {
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = ($Data | ConvertTo-Json -Depth 20 -Compress); StdErr = $StdErr; Data = ($Data | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable) }
    }

    function New-TestProject([string] $Path) {
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $Path -ChildPath 'rayfin') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $Path -ChildPath 'src') -Force
        Set-Content -LiteralPath (Join-Path -Path $Path -ChildPath 'rayfin/rayfin.yml') -Value 'project: test' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path -Path $Path -ChildPath 'package.json') -Value '{"name":"t"}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path -Path $Path -ChildPath 'package-lock.json') -Value '{"lockfileVersion":3}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path -Path $Path -ChildPath 'src/App.tsx') -Value 'export {}' -Encoding utf8NoBOM
    }

    function Install-FakeCli([string] $StagePath) {
        $cliRoot = Join-Path -Path $StagePath -ChildPath 'node_modules/@microsoft/rayfin-cli'
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $cliRoot -ChildPath 'scripts') -Force
        Set-Content -LiteralPath (Join-Path -Path $cliRoot -ChildPath 'package.json') -Value '{"name":"@microsoft/rayfin-cli","bin":{"rayfin":"scripts/main"}}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path -Path $cliRoot -ChildPath 'scripts/main') -Value '' -Encoding utf8NoBOM
    }

    function New-TestConfigFile {
        $config = Get-HubTestConfig
        $config['fabric']['workspaceId'] = $script:workspaceId
        $config['tenantId'] = $script:tenantId
        $path = Join-Path -Path $TestDrive -ChildPath 'demo.config.json'
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        return $path
    }
}

AfterAll {
    Initialize-GuardTestContext -Clear
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Fabric App source' {
    BeforeAll {
        $script:appRoot = Join-Path -Path $repoRoot -ChildPath 'fabric/app'
        $script:appSettings = (Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json -AsHashtable)['fabricApp']
    }

    It 'commits placeholders only, protected assets, and one read-only delegated connector' {
        $yaml = Get-Content -LiteralPath (Join-Path -Path $script:appRoot -ChildPath 'rayfin/rayfin.yml') -Raw
        $yaml | Should -Not -Match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $yaml | Should -Match '(?m)^\s+assetAccess:\s*protected\s*$'
        $yaml | Should -Match '(?m)^\s+workspaceId:\s*\$\{DBHUB_FABRIC_WORKSPACE_ID\}\s*$'
        $yaml | Should -Match '(?m)^\s+itemId:\s*\$\{DBHUB_SEMANTIC_MODEL_ID\}\s*$'
        $yaml | Should -Match '(?m)^\s+type:\s*delegated\s*$'
        @([regex]::Matches($yaml, '(?m)^\s+-\s*name:\s*(\S+)\s*$') | ForEach-Object { $_.Groups[1].Value }) | Should -Be @('history', 'executeQuery')
        $yaml | Should -Not -Match 'webapp\.fabricapps\.net|rayfin\.windows\.net'
    }

    It 'pins exact package versions, the CLI and SDK at the recorded version' {
        $package = Get-Content -LiteralPath (Join-Path -Path $script:appRoot -ChildPath 'package.json') -Raw | ConvertFrom-Json -AsHashtable
        foreach ($group in 'dependencies', 'devDependencies') {
            foreach ($name in $package[$group].Keys) {
                $package[$group][$name] | Should -Match '^\d+\.\d+\.\d+$' -Because "$name must be pinned exactly"
            }
        }
        $package['devDependencies'][$script:appSettings['cliPackage']] | Should -Be $script:appSettings['cliVersion']
        foreach ($name in @($package['dependencies'].Keys | Where-Object { $_ -like '@microsoft/rayfin-*' })) {
            $package['dependencies'][$name] | Should -Be $script:appSettings['sdkVersion'] -Because $name
        }
    }

    It 'resolves every package from the public npm registry with SHA-512 integrity' {
        $lock = Get-Content -LiteralPath (Join-Path -Path $script:appRoot -ChildPath 'package-lock.json') -Raw | ConvertFrom-Json -AsHashtable
        $entries = @($lock['packages'].GetEnumerator() | Where-Object { $_.Key -and $_.Value['resolved'] })
        $entries.Count | Should -BeGreaterThan 100
        @($entries | Where-Object { $_.Value['resolved'] -notmatch '^https://registry\.npmjs\.org/' } | ForEach-Object { $_.Key }) | Should -BeNullOrEmpty
        @($entries | Where-Object { $_.Value['integrity'] -notmatch '^sha512-' } | ForEach-Object { $_.Key }) | Should -BeNullOrEmpty
    }

    It 'pins each npm override exactly, as config/versions.json records it, and resolves every copy of the package to it' {
        $package = Get-Content -LiteralPath (Join-Path -Path $script:appRoot -ChildPath 'package.json') -Raw | ConvertFrom-Json -AsHashtable
        $lock = Get-Content -LiteralPath (Join-Path -Path $script:appRoot -ChildPath 'package-lock.json') -Raw | ConvertFrom-Json -AsHashtable
        $overrides = if ($package.ContainsKey('overrides')) { $package['overrides'] } else { @{} }
        $recorded = if ($script:appSettings.ContainsKey('overrides')) { $script:appSettings['overrides'] } else { @{} }
        (@($overrides.Keys | Sort-Object) -join ', ') | Should -Be (@($recorded.Keys | Where-Object { $_ -ne 'note' } | Sort-Object) -join ', ') -Because 'config/versions.json records every override in fabricApp.overrides'
        foreach ($name in $overrides.Keys) {
            $overrides[$name] | Should -BeOfType [string] -Because "$name is overridden with one version for every parent"
            $overrides[$name] | Should -Match '^\d+\.\d+\.\d+$' -Because "the $name override must be pinned exactly"
            $overrides[$name] | Should -Be $recorded[$name]['version'] -Because $name
            $recorded[$name]['advisory'] | Should -Match '^GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}$' -Because "an override exists only for an advisory ($name)"
            @($recorded[$name]['requiredBy']).Count | Should -BeGreaterThan 0 -Because "the parents that declare $name's range are recorded"
            $copies = @($lock['packages'].GetEnumerator() | Where-Object { $_.Key -match ('(^|/)node_modules/{0}$' -f [regex]::Escape($name)) })
            $copies.Count | Should -BeGreaterThan 0 -Because "$name is in the lock file"
            @($copies | Where-Object { $_.Value['version'] -ne $overrides[$name] } | ForEach-Object { '{0}@{1}' -f $_.Key, $_.Value['version'] }) | Should -BeNullOrEmpty
        }
    }

    It 'keeps deploy-time files out of Git' {
        $ignore = Get-Content -LiteralPath (Join-Path -Path $script:appRoot -ChildPath '.gitignore')
        foreach ($entry in 'rayfin/.env', 'rayfin/.deployments.json', 'rayfin/.temp/', '.env.*', 'public/rayfin.config.json', 'public/dbhub-app.json') {
            $ignore | Should -Contain $entry
        }
    }

    It 'builds the app in CI with the Node.js version and setup-node pin that config/versions.json records' {
        $workflow = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath '.github/workflows/reusable-static-checks.yml') -Raw
        $workflow | Should -Match ('node-version:\s*"{0}"' -f [regex]::Escape([string]$script:appSettings['ciNodeVersion']))
        $workflow | Should -Match 'working-directory:\s*fabric/app'
        $workflow | Should -Match 'npm run verify'
        @($script:appSettings['supportedNodeMajors']) | Should -Contain ([int]$script:appSettings['ciNodeVersion'])
    }
}

Describe 'Fabric App helpers' {
    It 'redacts the publishable key in JSON, environment lines, and bare values' {
        $key = $script:fakeKey
        InModuleScope DbHubDemo -Parameters @{ Key = $key } {
            param($Key)
            $text = '{"publishableKey":"' + $Key + '","hostingUrl":"https://a.example"} RAYFIN_PUBLIC_PUBLISHABLE_KEY=' + $Key + ' then ' + $Key
            $safe = Protect-DemoRayfinText -Text $text
            $safe | Should -Not -Match ([regex]::Escape($Key))
            $safe | Should -Match '"publishableKey":"\[REDACTED\]"'
            $safe | Should -Match 'hostingUrl'
        }
    }

    It 'reads the pinned settings from config/versions.json' {
        InModuleScope DbHubDemo {
            $settings = Get-DemoFabricAppSetting
            $settings['itemName'] | Should -Be 'APP_DatabaseHub_Insights'
            $settings['assetAccess'] | Should -Be 'protected'
            $settings['cliVersion'] | Should -Match '^\d+\.\d+\.\d+$'
        }
    }

    It 'sets dotenv values and keeps the CLI''s own lines' {
        $path = Join-Path -Path $TestDrive -ChildPath 'env/.env'
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force
        Set-Content -LiteralPath $path -Value @('RAYFIN_PUBLIC_ITEM_ID=abc', 'DBHUB_SEMANTIC_MODEL_ID=old') -Encoding utf8NoBOM
        InModuleScope DbHubDemo -Parameters @{ Path = $path } {
            param($Path)
            Set-DemoFabricAppEnvValue -Path $Path -Values @{ DBHUB_SEMANTIC_MODEL_ID = 'new'; DBHUB_FABRIC_WORKSPACE_ID = 'ws' } -Confirm:$false
            { Set-DemoFabricAppEnvValue -Path $Path -Values @{ 'bad name' = 'x' } -Confirm:$false } | Should -Throw
        }
        $lines = @(Get-Content -LiteralPath $path)
        $lines | Should -Contain 'RAYFIN_PUBLIC_ITEM_ID=abc'
        $lines | Should -Contain 'DBHUB_SEMANTIC_MODEL_ID=new'
        $lines | Should -Contain 'DBHUB_FABRIC_WORKSPACE_ID=ws'
        @($lines | Where-Object { $_ -like 'DBHUB_SEMANTIC_MODEL_ID=*' }).Count | Should -Be 1
    }
}

Describe 'Sync-DemoFabricAppStage' {
    BeforeEach {
        $script:source = Join-Path -Path $TestDrive -ChildPath ('src-' + [guid]::NewGuid().ToString('N'))
        $script:stage = Join-Path -Path $TestDrive -ChildPath ('stage-' + [guid]::NewGuid().ToString('N'))
        New-TestProject -Path $script:source
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:source -ChildPath 'node_modules/x') -Force
        Set-Content -LiteralPath (Join-Path -Path $script:source -ChildPath 'node_modules/x/index.js') -Value '' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path -Path $script:source -ChildPath '.env.local') -Value 'VITE_X=1' -Encoding utf8NoBOM
        # The stage has an old template file, the CLI's records, and packages.
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:stage -ChildPath 'rayfin') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:stage -ChildPath 'old/nested') -Force
        Set-Content -LiteralPath (Join-Path -Path $script:stage -ChildPath 'AGENTS.md') -Value 'old' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path -Path $script:stage -ChildPath 'old/nested/file.txt') -Value 'old' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path -Path $script:stage -ChildPath 'rayfin/.deployments.json') -Value '{}' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path -Path $script:stage -ChildPath 'rayfin/.env') -Value 'RAYFIN_PUBLIC_ITEM_ID=kept' -Encoding utf8NoBOM
        Install-FakeCli -StagePath $script:stage
    }

    It 'mirrors the source, keeps the CLI''s records and packages, writes the deploy values, and installs when the lock changed' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        $deployFile = [ordered]@{ expectedAccount = 'admin@contoso.example'; links = [ordered]@{ report = 'https://app.fabric.microsoft.com/groups/x/reports/y' } }
        $results = @(Sync-DemoFabricAppStage -SourcePath $script:source -StagePath $script:stage -EnvValues @{ DBHUB_SEMANTIC_MODEL_ID = $script:modelId } -DeployFile $deployFile -Confirm:$false)
        ($results | Where-Object checkId -EQ 'FABRIC.APP.STAGE').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.DEPENDENCIES').status | Should -Be 'Pass'
        Test-Path -LiteralPath (Join-Path -Path $script:stage -ChildPath 'src/App.tsx') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $script:stage -ChildPath 'AGENTS.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $script:stage -ChildPath 'old') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $script:stage -ChildPath '.env.local') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $script:stage -ChildPath 'node_modules/x') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $script:stage -ChildPath 'rayfin/.deployments.json') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path -Path $script:stage -ChildPath 'rayfin/.env') | Should -Contain 'RAYFIN_PUBLIC_ITEM_ID=kept'
        Get-Content -LiteralPath (Join-Path -Path $script:stage -ChildPath 'rayfin/.env') | Should -Contain "DBHUB_SEMANTIC_MODEL_ID=$script:modelId"
        (Get-Content -LiteralPath (Join-Path -Path $script:stage -ChildPath 'public/dbhub-app.json') -Raw | ConvertFrom-Json).links.report | Should -Match '/reports/'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -Times 1 -Exactly -ParameterFilter { $Tool -eq 'npm' -and $ArgumentList[0] -eq 'ci' }

        # A second run with the same lock file installs nothing.
        $again = @(Sync-DemoFabricAppStage -SourcePath $script:source -StagePath $script:stage -Confirm:$false)
        ($again | Where-Object checkId -EQ 'FABRIC.APP.DEPENDENCIES').evidence['installed'] | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -Times 1 -Exactly
    }

    It 'changes nothing under -WhatIf' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { throw 'npm must not run under -WhatIf.' }
        $results = @(Sync-DemoFabricAppStage -SourcePath $script:source -StagePath $script:stage -WhatIf)
        $results.status | Should -Be 'Not selected'
        Test-Path -LiteralPath (Join-Path -Path $script:stage -ChildPath 'AGENTS.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path -Path $script:stage -ChildPath 'src/App.tsx') | Should -BeFalse
    }

    It 'fails when npm ci fails, and when the source isn''t a Fabric Apps project' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'npm ERR! network' } }
        $results = @(Sync-DemoFabricAppStage -SourcePath $script:source -StagePath $script:stage -Confirm:$false)
        ($results | Where-Object checkId -EQ 'FABRIC.APP.DEPENDENCIES').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.DEPENDENCIES').message | Should -Match 'network'
        $empty = Join-Path -Path $TestDrive -ChildPath ('empty-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $empty
        (Sync-DemoFabricAppStage -SourcePath $empty -StagePath $script:stage -Confirm:$false).status | Should -Be 'Fail'
    }
}

Describe 'Test-DemoFabricAppPrerequisite' {
    BeforeAll {
        $script:config = Get-HubTestConfig
        $script:config['tenantId'] = $script:tenantId
    }

    It 'passes with a supported Node.js and a sign-in to the demo''s tenant, and leaves the tenant setting manual' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = 'v24.11.0'; StdErr = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'ok'; command = 'login status'; identityType = 'user'; tenant = $script:tenantId } }
        $results = @(Test-DemoFabricAppPrerequisite -Config $script:config -StagePath $TestDrive)
        ($results | Where-Object checkId -EQ 'FABRIC.APP.NODE').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.SIGNIN').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.TENANTSETTING').status | Should -Be 'Manual action required'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.EXECUTEQUERIES').status | Should -Be 'Manual action required'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'login status --json' }
    }

    It 'reads both tenant settings through the admin API with -FabricAdmin, including the renamed Execute Queries title' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = 'v24.11.0'; StdErr = '' } }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoHubFabricAccess -MockWith { [pscustomobject]@{ Available = $true; Token = $Token; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Read-DemoHubFabricList -MockWith {
            [pscustomobject]@{ Succeeded = $true; StatusCode = 200; Error = ''; Pages = 1; Complete = $true; Items = @(
                    [pscustomobject]@{ settingName = 'FabricApps'; title = 'Fabric Apps (preview)'; enabled = $true }
                    [pscustomobject]@{ settingName = 'ExecuteQueries'; title = 'Semantic Model Execute Queries REST API'; enabled = $true; enabledSecurityGroups = @([pscustomobject]@{ name = 'Presenters' }) }
                ) }
        }
        $results = @(Test-DemoFabricAppPrerequisite -Config $script:config -StagePath $TestDrive -SkipSignIn -FabricAdmin -Token $script:token)
        ($results | Where-Object checkId -EQ 'FABRIC.APP.TENANTSETTING').status | Should -Be 'Pass'
        $executeQueries = $results | Where-Object checkId -EQ 'FABRIC.APP.EXECUTEQUERIES'
        $executeQueries.status | Should -Be 'Warning'
        $executeQueries.message | Should -Match 'Presenters'
        Should -Invoke -ModuleName DbHubDemo -CommandName Read-DemoHubFabricList -Times 1 -Exactly -ParameterFilter { $Uri -match '/admin/tenantsettings$' }
    }

    It 'asks for the one-time sign-in with the exact command, and flags another tenant' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = 'v26.7.0'; StdErr = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'not-signed-in'; command = 'login status' } }
        $results = @(Test-DemoFabricAppPrerequisite -Config $script:config -StagePath $TestDrive)
        ($results | Where-Object checkId -EQ 'FABRIC.APP.NODE').status | Should -Be 'Warning'
        $signIn = $results | Where-Object checkId -EQ 'FABRIC.APP.SIGNIN'
        $signIn.status | Should -Be 'Manual action required'
        $signIn.remediation | Should -Match ([regex]::Escape("rayfin login --tenant $script:tenantId"))
        $signIn.remediation | Should -Match '@microsoft/rayfin-cli@\d+\.\d+\.\d+'

        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'ok'; tenant = '00000000-0000-0000-0000-000000000000' } }
        (Test-DemoFabricAppPrerequisite -Config $script:config -StagePath $TestDrive | Where-Object checkId -EQ 'FABRIC.APP.SIGNIN').message | Should -Match 'another tenant'
    }

    It 'fails without Node.js or with one that is too old' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = 'v18.20.0'; StdErr = '' } }
        (Test-DemoFabricAppPrerequisite -Config $script:config -StagePath $TestDrive -SkipSignIn | Where-Object checkId -EQ 'FABRIC.APP.NODE').status | Should -Be 'Fail'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { throw 'node was not found on PATH.' }
        $results = @(Test-DemoFabricAppPrerequisite -Config $script:config -StagePath $TestDrive -SkipSignIn)
        ($results | Where-Object checkId -EQ 'FABRIC.APP.NODE').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.SIGNIN').status | Should -Be 'Not selected'
    }
}

Describe 'Invoke-DemoFabricAppDeployment' {
    BeforeAll {
        $script:upSuccess = @{
            status           = 'success'
            deployment       = @{ rayfinItemId = $script:itemId; itemName = 'APP_DatabaseHub_Insights'; fabricWorkspaceId = $script:workspaceId; fabricPortalUrl = "https://app.fabric.microsoft.com/groups/$script:workspaceId/appbackends/$script:itemId"; publishableKey = $script:fakeKey; hostingUrl = $script:hosting }
            steps            = @{ build = @{ status = 'ok' }; staticHosting = @{ status = 'ok' } }
            failedConnectors = @()
        }
        $script:statusOk = @{ deployed = $true; authenticated = $true; deployment = @{ publishableKey = $script:fakeKey }; endpointHealth = @{ reachable = $true; httpStatus = 200; publishableKey = $script:fakeKey } }
    }

    It 'runs nothing under -WhatIf and lists the planned command' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { throw 'The CLI must not run under -WhatIf.' }
        $result = Invoke-DemoFabricAppDeployment -StagePath $TestDrive -WorkspaceId $script:workspaceId -TenantId $script:tenantId -ItemName 'APP_DatabaseHub_Insights' -WhatIf
        $result.status | Should -Be 'Not selected'
        $result.message | Should -Match 'rayfin up --workspace-id .* --item-name APP_DatabaseHub_Insights .* --yes --json'
    }

    It 'deploys unattended to the named item, reads the status back, and never keeps the publishable key' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -ParameterFilter { $ArgumentList[0] -eq 'up' -and $ArgumentList[1] -ne 'status' } -MockWith { New-CliResult $script:upSuccess }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -ParameterFilter { $ArgumentList[1] -eq 'status' } -MockWith { New-CliResult $script:statusOk }
        $results = @(Invoke-DemoFabricAppDeployment -StagePath $TestDrive -WorkspaceId $script:workspaceId -TenantId $script:tenantId -ItemName 'APP_DatabaseHub_Insights' -Confirm:$false)
        $deploy = $results | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY'
        $deploy.status | Should -Be 'Pass'
        $deploy.evidence['itemId'] | Should -Be $script:itemId
        $deploy.evidence['hostingUrl'] | Should -Be $script:hosting
        ($results | Where-Object checkId -EQ 'FABRIC.APP.STATUS').status | Should -Be 'Pass'
        ($results | ConvertTo-Json -Depth 10) | Should -Not -Match ([regex]::Escape($script:fakeKey))
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 1 -Exactly -ParameterFilter {
            $line = $ArgumentList -join ' '
            $line -match '^up ' -and $line -match '--yes' -and $line -match '--json' -and $line -match "--workspace-id $script:workspaceId" -and $line -match '--item-name APP_DatabaseHub_Insights' -and $line -notmatch '--dry-run|--capacity-id'
        }
    }

    It 'asks for a new sign-in when the CLI''s session expired, and fails on a partial deploy' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'error'; error = 'Not signed in. Run rayfin login to authenticate.' } -ExitCode 1 }
        $expired = @(Invoke-DemoFabricAppDeployment -StagePath $TestDrive -WorkspaceId $script:workspaceId -TenantId $script:tenantId -ItemName 'APP_DatabaseHub_Insights' -Confirm:$false)
        $expired.status | Should -Be 'Manual action required'
        $expired.remediation | Should -Match 'rayfin login --tenant'

        $partial = $script:upSuccess.Clone()
        $partial['status'] = 'partial'
        $partial['failedConnectors'] = @('history')
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult $partial }
        $result = @(Invoke-DemoFabricAppDeployment -StagePath $TestDrive -WorkspaceId $script:workspaceId -TenantId $script:tenantId -ItemName 'APP_DatabaseHub_Insights' -Confirm:$false)
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'history'
    }

    It 'validates with --dry-run and deploys nothing' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'dry-run' } }
        $result = Invoke-DemoFabricAppDeployment -StagePath $TestDrive -WorkspaceId $script:workspaceId -TenantId $script:tenantId -ItemName 'APP_DatabaseHub_Insights' -DryRun -Confirm:$false
        $result.status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '--dry-run' }
    }
}

Describe 'Test-DemoFabricApp' {
    BeforeEach {
        $script:checkStage = Join-Path -Path $TestDrive -ChildPath ('check-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:checkStage -Force
        # npm run queries:export writes the payloads and their index into the stage.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith {
            $folder = Join-Path -Path $WorkingDirectory -ChildPath $ArgumentList[3]
            $null = New-Item -ItemType Directory -Path $folder -Force
            $index = @{ latestDay = '2026-10-21'; queries = @(
                    @{ id = 'connector-check'; file = 'connector-check.json' }
                    @{ id = 'history-meta'; file = 'history-meta.json' }
                    @{ id = 'estate-targets'; file = 'estate-targets.json' }
                    @{ id = 'replay-T3'; file = 'replay-T3.json' }
                ) }
            $index | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'index.json') -Encoding utf8NoBOM
            [pscustomobject]@{ ExitCode = 0; StdOut = 'Wrote 4 queries'; StdErr = '' }
        }
    }

    It 'passes when every query returns rows and anonymous requests are refused, and leaves the browser check manual' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith {
            $file = $ArgumentList[[array]::IndexOf($ArgumentList, '--file') + 1]
            $table = if ($file -match 'connector-check') { @{ columns = @(@{ name = '[ValidationRows]' }, @{ name = '[SnapshotRows]' }, @{ name = '[Incidents]' }); rows = @(, @(12, 2293, 4)) } }
            elseif ($file -match 'history-meta') { @{ columns = @(@{ name = '[LatestDay]' }); rows = @(, @('2026-10-21T00:00:00')) } }
            else { @{ columns = @(@{ name = 'Target[Target Key]' }); rows = @(, @('T3')) } }
            New-CliResult @{ status = 'ok'; connector = 'history'; operation = 'executeQuery'; output = @{ status = 'success'; table = $table } }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 401; Content = '{"error":"Authentication required."}' } }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -ItemUrl 'https://app.fabric.microsoft.com/groups/x/appbackends/y')
        $connector = $results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR'
        $connector.status | Should -Be 'Pass'
        $connector.message | Should -Match 'Connector check passed: .* 12 validation checks, 2293 telemetry rows, and 4 incident windows'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.HOSTING').status | Should -Be 'Pass'
        $browser = $results | Where-Object checkId -EQ 'FABRIC.APP.BROWSER'
        $browser.status | Should -Be 'Manual action required'
        $browser.remediation | Should -Match 'Connector check passed'
        $browser.remediation | Should -Match 'Page not accessible directly'
        # The catalog was exported again for the newest telemetry day.
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '2026-10-21' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Headers['Accept'] -eq 'application/json' -and -not $Authentication }
    }

    It 'anchors the T3 replay to history-meta''s newest T3 incident window and newest T3 bin' {
        # Phase 25a (2026-10-26): without anchors the replay ended at midnight before the newest day's data.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith {
            $file = $ArgumentList[[array]::IndexOf($ArgumentList, '--file') + 1]
            $table = if ($file -match 'history-meta') {
                @{ columns = @(@{ name = '[LatestDay]' }, @{ name = '[T3IncidentStart]' }, @{ name = '[T3IncidentEnd]' }, @{ name = '[T3LatestBucket]' }); rows = @(, @('2026-10-23T00:00:00', [datetime]::new(2026, 10, 23, 20, 13, 0, [System.DateTimeKind]::Unspecified), '2026-10-23T20:34:00', $null)) }
            }
            else { @{ columns = @(@{ name = '[ValidationRows]' }, @{ name = '[SnapshotRows]' }, @{ name = '[Incidents]' }); rows = @(, @(12, 2293, 4)) } }
            New-CliResult @{ status = 'ok'; output = @{ status = 'success'; table = $table } }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 401; Content = '' } }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting)
        ($results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -match '2026-10-23 --t3-incident-start 2026-10-23T20:13:00Z --t3-incident-end 2026-10-23T20:34:00Z$'
        }
        InModuleScope -ModuleName DbHubDemo {
            ConvertTo-DemoFabricAppInstant -Value '2026-10-23T21:27:00' | Should -Be '2026-10-23T21:27:00Z'
            ConvertTo-DemoFabricAppInstant -Value '2026-10-23T21:27:00.123Z' | Should -Be '2026-10-23T21:27:00Z'
            ConvertTo-DemoFabricAppInstant -Value ([datetime]::new(2026, 10, 23, 21, 27, 0, [System.DateTimeKind]::Utc)) | Should -Be '2026-10-23T21:27:00Z'
            ConvertTo-DemoFabricAppInstant -Value $null | Should -Be ''
            ConvertTo-DemoFabricAppInstant -Value 'soon' | Should -Be ''
        }
    }

    It 'fails a rejected query and public assets' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith {
            $file = $ArgumentList[[array]::IndexOf($ArgumentList, '--file') + 1]
            if ($file -match 'estate') {
                return (New-CliResult @{ status = 'error'; error = 'Query failed'; connectorError = @{ category = 'query'; message = 'bad column' } } -ExitCode 1)
            }
            # Build the table in one hashtable: an if expression assigned to a variable would unroll the row arrays.
            $table = if ($file -match 'replay') { @{ columns = @(@{ name = '[Cpu]' }); rows = @() } }
            elseif ($file -match 'history-meta') { @{ columns = @(@{ name = '[LatestDay]' }); rows = @(, @('2026-10-21T00:00:00')) } }
            else { @{ columns = @(@{ name = '[ValidationRows]' }, @{ name = '[SnapshotRows]' }, @{ name = '[Incidents]' }); rows = @(, @(12, 2293, 4)) } }
            New-CliResult @{ status = 'ok'; output = @{ status = 'success'; table = $table } }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 200; Content = '<html></html>' } }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting)
        ($results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES').message | Should -Match 'estate-targets'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.HOSTING').status | Should -Be 'Fail'
    }

    It 'reports a blank count as 0: DAX COUNTROWS over an empty table, as in a new lakehouse, is blank' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'ok'; output = @{ status = 'success'; table = @{ columns = @(@{ name = '[ValidationRows]' }, @{ name = '[SnapshotRows]' }, @{ name = '[Incidents]' }); rows = @(, @($null, 2598, 22)) } } } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 401; Content = '' } }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Queries Probe)
        $connector = $results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR'
        $connector.status | Should -Be 'Pass'
        $connector.message | Should -Match 'returned 0 validation checks, 2598 telemetry rows, and 22 incident windows'
    }

    It 'reads the hosting URL from the stage''s deployment record when none is passed' {
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:checkStage -ChildPath 'rayfin') -Force
        @{ active = 'demo'; deployments = @{ demo = @{ itemName = 'APP_DatabaseHub_Insights'; fabricItemId = $script:itemId; hostingUrl = $script:hosting; fabricDeepLink = 'https://app.fabric.microsoft.com/groups/x/appbackends/y'; publishableKey = $script:fakeKey } } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path -Path $script:checkStage -ChildPath 'rayfin/.deployments.json') -Encoding utf8NoBOM
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'ok'; output = @{ status = 'success'; table = @{ columns = @(@{ name = '[ValidationRows]' }); rows = @(, @(12)) } } } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 401; Content = '' } }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -Queries Probe)
        ($results | Where-Object checkId -EQ 'FABRIC.APP.HOSTING').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.BROWSER').remediation | Should -Match 'appbackends'
        ($results | ConvertTo-Json -Depth 10) | Should -Not -Match ([regex]::Escape($script:fakeKey))
        $results.checkId | Should -Not -Contain 'FABRIC.APP.QUERIES'
    }
}

Describe 'Resolve-DemoFabricAppItem' {
    It 'finds the model, the dashboard, and the report, and builds tenant-scoped links' {
        Mock -ModuleName DbHubDemo -CommandName Find-DemoFabricItem -MockWith {
            $id = switch ($Type) { 'SemanticModel' { $script:modelId } 'KQLDashboard' { $script:dashboardId } 'Report' { $script:reportId } }
            [pscustomobject]@{ StatusCode = 200; Items = @([pscustomobject]@{ id = $id; displayName = $DisplayName; type = $Type }); Error = '' }
        }
        $result = Resolve-DemoFabricAppItem -WorkspaceId $script:workspaceId -TenantId $script:tenantId -Token $script:token
        $result.status | Should -Be 'Pass'
        $result.evidence['semanticModelId'] | Should -Be $script:modelId
        $links = $result.evidence['links']
        $links['report'] | Should -Be "https://app.fabric.microsoft.com/groups/$script:workspaceId/reports/$($script:reportId)?ctid=$script:tenantId"
        $links['realTimeDashboard'] | Should -Match "/kustodashboards/$script:dashboardId\?ctid="
        $links['databaseHub'] | Should -Match '^https://app\.fabric\.microsoft\.com/workloads/fdh/databaseHub\?ctid='
    }

    It 'needs the model, and only warns about a missing dashboard or report' {
        Mock -ModuleName DbHubDemo -CommandName Find-DemoFabricItem -MockWith { [pscustomobject]@{ StatusCode = 200; Items = @(); Error = '' } }
        (Resolve-DemoFabricAppItem -WorkspaceId $script:workspaceId -TenantId $script:tenantId -Token $script:token).status | Should -Be 'Manual action required'
        Mock -ModuleName DbHubDemo -CommandName Find-DemoFabricItem -MockWith {
            if ($Type -eq 'SemanticModel') { return [pscustomobject]@{ StatusCode = 200; Items = @([pscustomobject]@{ id = $script:modelId }); Error = '' } }
            [pscustomobject]@{ StatusCode = 200; Items = @(); Error = '' }
        }
        $result = Resolve-DemoFabricAppItem -WorkspaceId $script:workspaceId -TenantId $script:tenantId -Token $script:token
        $result.status | Should -Be 'Warning'
        $result.evidence['links'].Keys | Should -Not -Contain 'report'
    }
}

Describe 'configure-fabric-app.ps1' {
    BeforeAll {
        $script:passResult = { param([string] $CheckId, [hashtable] $Evidence = @{}) New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'ok' -Evidence $Evidence }
    }

    It 'validates the source and plans every step under -WhatIf without a token, a CLI call, or a request' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'No Azure CLI call is expected under -WhatIf.' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { throw 'No Rayfin CLI call is expected under -WhatIf.' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { throw 'No request is expected under -WhatIf.' }
        $output = Join-Path -Path $TestDrive -ChildPath 'whatif.jsonl'
        $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -StagePath (Join-Path -Path $TestDrive -ChildPath 'whatif-stage') -OutputPath $output -WhatIf 6>&1
        $LASTEXITCODE | Should -Be 0
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        ($records | Where-Object checkId -EQ 'FABRIC.APP.SOURCE').status | Should -Be 'Pass'
        @($records | Where-Object { $_.checkId -ne 'FABRIC.APP.SOURCE' -and $_.status -ne 'Not selected' }) | Should -BeNullOrEmpty
        @($records.checkId) | Should -Contain 'FABRIC.APP.DEPLOY'
        Test-Path -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'whatif-stage') | Should -BeFalse
    }

    It 'stops with Fail and sends nothing when the subscription guard fails' {
        Mock -CommandName Assert-DemoAzContext -MockWith { throw "Subscription guard: check 'account' failed: wrong tenant. Nothing was changed." }
        Mock -CommandName Sync-DemoFabricAppStage -MockWith { throw 'The stage must not change when the guard fails.' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { throw 'No request is expected when the guard fails.' }
        $output = Join-Path -Path $TestDrive -ChildPath 'guard.jsonl'
        $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output 6>&1
        $LASTEXITCODE | Should -Be 1
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        ($records | Where-Object checkId -EQ 'PREFLIGHT.GUARD.CONTEXT').status | Should -Be 'Fail'
    }

    It 'deploys and checks the app in one unattended run, and proves the tenant setting through the deploy' {
        $pass = $script:passResult
        # Locals, not script-scope variables: while the script runs, a mock's script scope is the script's own.
        $modelId = $script:modelId
        $capacityId = $script:capacityId
        $itemId = $script:itemId
        $hosting = $script:hosting
        Mock -CommandName Test-DemoFabricWorkspace -MockWith { @((& $pass 'FABRIC.P5.WORKSPACE'), (& $pass 'FABRIC.P5.CAPACITY' @{ capacityId = $capacityId; capacityAssignmentProgress = 'Completed' })) }
        Mock -CommandName Resolve-DemoFabricAppItem -MockWith { & $pass 'FABRIC.APP.ITEMS' @{ semanticModelId = $modelId; links = [ordered]@{ databaseHub = 'https://app.fabric.microsoft.com/workloads/fdh/databaseHub'; report = 'https://app.fabric.microsoft.com/groups/x/reports/y' } } }
        Mock -CommandName Sync-DemoFabricAppStage -MockWith { @((& $pass 'FABRIC.APP.STAGE'), (& $pass 'FABRIC.APP.DEPENDENCIES')) }
        Mock -CommandName Test-DemoFabricAppPrerequisite -MockWith {
            @((& $pass 'FABRIC.APP.NODE'), (& $pass 'FABRIC.APP.SIGNIN'), (New-DemoResult -CheckId 'FABRIC.APP.TENANTSETTING' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'Confirm it.'), (New-DemoResult -CheckId 'FABRIC.APP.EXECUTEQUERIES' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'Confirm it.'))
        }
        Mock -CommandName Invoke-DemoFabricAppDeployment -MockWith { @((& $pass 'FABRIC.APP.DEPLOY' @{ itemId = $itemId; hostingUrl = $hosting; itemUrl = 'https://app.fabric.microsoft.com/groups/x/appbackends/y' }), (& $pass 'FABRIC.APP.STATUS')) }
        Mock -CommandName Test-DemoFabricApp -MockWith { @((& $pass 'FABRIC.APP.CONNECTOR'), (& $pass 'FABRIC.APP.QUERIES'), (& $pass 'FABRIC.APP.HOSTING'), (New-DemoResult -CheckId 'FABRIC.APP.BROWSER' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'Open it.')) }
        $output = Join-Path -Path $TestDrive -ChildPath 'deploy.jsonl'
        $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output -FabricToken $script:token 6>&1
        $LASTEXITCODE | Should -Be 0
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        foreach ($checkId in 'FABRIC.APP.SOURCE', 'FABRIC.APP.ITEMS', 'FABRIC.APP.STAGE', 'FABRIC.APP.SIGNIN', 'FABRIC.APP.DEPLOY', 'FABRIC.APP.TENANTSETTING', 'FABRIC.APP.EXECUTEQUERIES', 'FABRIC.APP.CONNECTOR', 'FABRIC.APP.HOSTING') {
            ($records | Where-Object { $_.checkId -eq $checkId }).status | Should -Be 'Pass' -Because $checkId
        }
        ($records | Where-Object checkId -EQ 'FABRIC.APP.BROWSER').status | Should -Be 'Manual action required'
        Should -Invoke -CommandName Invoke-DemoFabricAppDeployment -Times 1 -Exactly -ParameterFilter { $ItemName -eq 'APP_DatabaseHub_Insights' -and $WorkspaceId -eq $script:workspaceId -and $TenantId -eq $script:tenantId }
        Should -Invoke -CommandName Sync-DemoFabricAppStage -Times 1 -Exactly -ParameterFilter { $EnvValues['DBHUB_SEMANTIC_MODEL_ID'] -eq $script:modelId -and $DeployFile['links']['report'] -match '/reports/' }
        Should -Invoke -CommandName Test-DemoFabricApp -Times 1 -Exactly -ParameterFilter { $HostingUrl -eq $script:hosting }

        # With -TreatManualAsError, the browser check makes the exit code 2.
        $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output -FabricToken $script:token -TreatManualAsError 6>&1
        $LASTEXITCODE | Should -Be 2
    }

    It 'deploys nothing when the capacity isn''t Active or the CLI isn''t signed in' {
        $pass = $script:passResult
        # Locals, not script-scope variables: while the script runs, a mock's script scope is the script's own.
        $modelId = $script:modelId
        $capacityId = $script:capacityId
        Mock -CommandName Test-DemoFabricWorkspace -MockWith { @((& $pass 'FABRIC.P5.WORKSPACE'), (New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'Paused.' -Evidence @{ capacityId = $capacityId })) }
        Mock -CommandName Resolve-DemoFabricAppItem -MockWith { & $pass 'FABRIC.APP.ITEMS' @{ semanticModelId = $modelId; links = @{} } }
        Mock -CommandName Sync-DemoFabricAppStage -MockWith { @(& $pass 'FABRIC.APP.STAGE') }
        Mock -CommandName Test-DemoFabricAppPrerequisite -MockWith { @((& $pass 'FABRIC.APP.NODE'), (& $pass 'FABRIC.APP.SIGNIN')) }
        Mock -CommandName Invoke-DemoFabricAppDeployment -MockWith { throw 'rayfin up must not run on a paused capacity.' }
        Mock -CommandName Test-DemoFabricApp -MockWith { throw 'Nothing to check.' }
        $output = Join-Path -Path $TestDrive -ChildPath 'paused.jsonl'
        $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output -FabricToken $script:token 6>&1
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        ($records | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY').status | Should -Be 'Not selected'
        ($records | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY').message | Should -Match 'Active Fabric capacity'

        Mock -CommandName Test-DemoFabricWorkspace -MockWith { @(& $pass 'FABRIC.P5.CAPACITY' @{ capacityId = $capacityId }) }
        Mock -CommandName Test-DemoFabricAppPrerequisite -MockWith { @((& $pass 'FABRIC.APP.NODE'), (New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'Not signed in.' -Remediation 'rayfin login')) }
        $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output -FabricToken $script:token 6>&1
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        ($records | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY').message | Should -Match 'FABRIC.APP.SIGNIN'
    }

    It 'stops before the stage when the model isn''t deployed' {
        Mock -CommandName Test-DemoFabricWorkspace -MockWith { @() }
        Mock -CommandName Resolve-DemoFabricAppItem -MockWith { New-DemoResult -CheckId 'FABRIC.APP.ITEMS' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'No model.' -Evidence @{ semanticModelId = '' } }
        Mock -CommandName Sync-DemoFabricAppStage -MockWith { throw 'The stage must not change without the model.' }
        $output = Join-Path -Path $TestDrive -ChildPath 'nomodel.jsonl'
        $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output -FabricToken $script:token 6>&1
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        ($records | Where-Object checkId -EQ 'FABRIC.APP.ITEMS').status | Should -Be 'Manual action required'
        ($records | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY').status | Should -Be 'Not selected'
    }

    It 'takes -WorkspaceId as an override, so a workspace deploy.ps1 just resolved isn''t looked up by name again (Phase 28 live finding)' {
        # Live: deploy.ps1's Fabric track had just created the workspace, and the app's own lookup by name failed.
        $config = Get-HubTestConfig
        $config['tenantId'] = $script:tenantId
        $config['fabric'].Remove('workspaceId')
        $config['fabric']['workspaceName'] = 'Database Hub Demo P28 proof'
        $path = Join-Path -Path $TestDrive -ChildPath 'by-name.config.json'
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
        Mock -ModuleName DbHubDemo -CommandName Read-DemoHubFabricList -MockWith { throw 'No lookup by name is expected with -WorkspaceId.' }
        Mock -CommandName Test-DemoFabricWorkspace -MockWith { @() }
        Mock -CommandName Resolve-DemoFabricAppItem -MockWith { New-DemoResult -CheckId 'FABRIC.APP.ITEMS' -Area 'fabric' -Target 'fabric' -Status 'Manual action required' -Message 'No model.' -Evidence @{ semanticModelId = '' } }
        $output = Join-Path -Path $TestDrive -ChildPath 'override.jsonl'
        $null = & $script:configureApp -ConfigPath $path -OutputPath $output -FabricToken $script:token -WorkspaceId $script:workspaceId 6>&1
        $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
        $resolved = $records | Where-Object checkId -EQ 'FABRIC.RESOLVE.WORKSPACE'
        $resolved.status | Should -Be 'Not selected'
        $resolved.message | Should -Match 'override'
        Should -Invoke -ModuleName DbHubDemo -CommandName Read-DemoHubFabricList -Times 0 -Exactly
        Should -Invoke -CommandName Resolve-DemoFabricAppItem -Times 1 -Exactly -ParameterFilter { $WorkspaceId -eq $script:workspaceId }
    }
}
