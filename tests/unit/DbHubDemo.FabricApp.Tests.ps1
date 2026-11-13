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

    # Linux and macOS hide a file or folder whose name starts with a dot, as the app's stage has (rayfin/.env,
    # rayfin/.temp, rayfin/.deployments.json), and Remove-Item, Get-Item, and Get-ChildItem refuse or skip a hidden item
    # without -Force (CI on Ubuntu, 2026-11-09: Remove-Item of rayfin/.env said "the item is hidden"). This marks such an
    # item hidden on Windows too, so every OS reads and removes it the way Linux does. Mark only what the code reads or
    # removes: Windows also refuses to overwrite a hidden file with [System.IO.File]::WriteAllText, which Linux allows.
    function Set-TestDotItemHidden([string] $Path) {
        if ($IsWindows -and (Split-Path -Path $Path -Leaf).StartsWith('.')) {
            [System.IO.File]::SetAttributes($Path, [System.IO.File]::GetAttributes($Path) -bor [System.IO.FileAttributes]::Hidden)
        }
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
        foreach ($key in $overrides.Keys) {
            # A key is a package name, or a name and the advisory's vulnerable range (>=x.y.z <x.y.z), so that copies a
            # parent pins outside that range keep their version.
            $key | Should -Match '^(@[a-z0-9-]+/)?[a-z0-9.-]+(@>=\d+\.\d+\.\d+ <\d+\.\d+\.\d+)?$' -Because "$key names a package and, optionally, the vulnerable range"
            $name = $key -replace '(?<=.)@>=.*$', ''
            $overrides[$key] | Should -BeOfType [string] -Because "$key is overridden with one version for every parent"
            $overrides[$key] | Should -Match '^\d+\.\d+\.\d+$' -Because "the $key override must be pinned exactly"
            $overrides[$key] | Should -Be $recorded[$key]['version'] -Because $key
            $recorded[$key]['advisory'] | Should -Match '^GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}$' -Because "an override exists only for an advisory ($key)"
            @($recorded[$key]['requiredBy']).Count | Should -BeGreaterThan 0 -Because "the parents that declare $key's range are recorded"
            [version]$overrides[$key] | Should -BeGreaterOrEqual ([version]$recorded[$key]['fixedIn']) -Because "the $key override is at or after the fix"
            $copies = @($lock['packages'].GetEnumerator() | Where-Object { $_.Key -match ('(^|/)node_modules/{0}$' -f [regex]::Escape($name)) })
            $copies.Count | Should -BeGreaterThan 0 -Because "$name is in the lock file"
            if ($key -match '@>=(\d+\.\d+\.\d+) <(\d+\.\d+\.\d+)$') {
                $from = [version]$Matches[1]
                $to = [version]$Matches[2]
                $to | Should -Be ([version]$recorded[$key]['fixedIn']) -Because "the $key range ends at the fix"
                $copies = @($copies | Where-Object { $_.Value['version'] -notmatch '^\d+\.\d+\.\d+$' -or (([version]$_.Value['version'] -ge $from) -and ([version]$_.Value['version'] -lt $to)) -or $_.Value['version'] -eq $overrides[$key] })
                $copies.Count | Should -BeGreaterThan 0 -Because "$key resolves at least one copy"
            }
            @($copies | Where-Object { $_.Value['version'] -ne $overrides[$key] } | ForEach-Object { '{0}@{1}' -f $_.Key, $_.Value['version'] }) | Should -BeNullOrEmpty
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

Describe 'The Azure CLI''s tokens for the Rayfin CLI: one per command''s audience, in that command''s process only (RAYFIN_TOKEN, 2026-11-09)' {
    It 'maps each command the scripts run to the audience it needs: <Line> is <Audience>' -ForEach @(
        @{ Line = 'up --workspace-id w --item-name APP_DatabaseHub_Insights --tenant t --yes --json'; Audience = 'Fabric' }
        @{ Line = 'up --workspace-id w --item-name APP_DatabaseHub_Insights --tenant t --yes --json --dry-run'; Audience = 'Fabric' }
        @{ Line = 'up status --json'; Audience = 'Fabric' }
        @{ Line = 'connector invoke --name history --operation executeQuery --file q/connector-check.json --max-inline-bytes 0 --json'; Audience = 'PowerBI' }
        @{ Line = 'login status --json'; Audience = 'None' }
        @{ Line = 'login --tenant t'; Audience = 'None' }
        @{ Line = 'logout'; Audience = 'None' }
    ) {
        (InModuleScope DbHubDemo -Parameters @{ Arguments = @($Line -split ' ') } { Get-DemoRayfinTokenAudience -ArgumentList $Arguments }) | Should -Be $Audience
    }

    Context 'Invoke-DemoRayfinCli' {
        BeforeEach {
            $script:cliStage = Join-Path -Path $TestDrive -ChildPath ('cli-' + [guid]::NewGuid().ToString('N'))
            Install-FakeCli -StagePath $script:cliStage
            $script:childEnvironment = $null
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { $script:childEnvironment = $Environment; [pscustomobject]@{ ExitCode = 0; StdOut = '{"status":"ok"}'; StdErr = '' } }
            $script:plainToken = 'eyJ' + ('Qk' * 30) + '.test'
            $script:secureToken = ConvertTo-HubSecureString $script:plainToken
        }

        AfterEach {
            Remove-Item -Path 'Env:RAYFIN_TOKEN' -ErrorAction SilentlyContinue
        }

        It 'gives the child the token as RAYFIN_TOKEN, never this process, and registers it for redaction' {
            Remove-Item -Path 'Env:RAYFIN_TOKEN' -ErrorAction SilentlyContinue
            $null = InModuleScope DbHubDemo -Parameters @{ Stage = $script:cliStage; Token = $script:secureToken } { Invoke-DemoRayfinCli -StagePath $Stage -ArgumentList @('up', 'status', '--json') -Token $Token -TokenAudience Fabric }
            $script:childEnvironment['RAYFIN_TOKEN'] | Should -BeExactly $script:plainToken
            $script:childEnvironment['RAYFIN_TELEMETRY_OPTOUT'] | Should -Be '1'
            [System.Environment]::GetEnvironmentVariable('RAYFIN_TOKEN') | Should -BeNullOrEmpty -Because 'only the child''s environment holds it'
            (Protect-DemoText -Text ('said {0} here' -f $script:plainToken)) | Should -Not -Match ([regex]::Escape($script:plainToken))
            $null = InModuleScope DbHubDemo -Parameters @{ Stage = $script:cliStage; Token = $script:secureToken } { Invoke-DemoRayfinCli -StagePath $Stage -ArgumentList @('connector', 'invoke', '--name', 'history', '--json') -Token $Token -TokenAudience PowerBI }
            $script:childEnvironment['RAYFIN_TOKEN'] | Should -BeExactly $script:plainToken
        }

        It 'removes an ambient RAYFIN_TOKEN without -Token, and for login and logout, which never get one' {
            $env:RAYFIN_TOKEN = 'ambient-' + ('z' * 12)
            $null = InModuleScope DbHubDemo -Parameters @{ Stage = $script:cliStage } { Invoke-DemoRayfinCli -StagePath $Stage -ArgumentList @('up', 'status', '--json') }
            $script:childEnvironment.Contains('RAYFIN_TOKEN') | Should -BeTrue
            $script:childEnvironment['RAYFIN_TOKEN'] | Should -BeNullOrEmpty -Because 'a $null value removes it from the child (Start-Process -Environment)'
            foreach ($command in @(@('login', 'status', '--json'), @('logout'))) {
                $null = InModuleScope DbHubDemo -Parameters @{ Stage = $script:cliStage; Token = $script:secureToken; Command = $command } { Invoke-DemoRayfinCli -StagePath $Stage -ArgumentList $Command -Token $Token }
                $script:childEnvironment['RAYFIN_TOKEN'] | Should -BeNullOrEmpty -Because ('rayfin {0} gets no token' -f ($command -join ' '))
            }
        }

        It 'throws before anything runs when the token is for another audience than the command needs' {
            { InModuleScope DbHubDemo -Parameters @{ Stage = $script:cliStage; Token = $script:secureToken } { Invoke-DemoRayfinCli -StagePath $Stage -ArgumentList @('connector', 'invoke', '--json') -Token $Token -TokenAudience Fabric } } | Should -Throw '*needs a PowerBI token, not a Fabric one*'
            { InModuleScope DbHubDemo -Parameters @{ Stage = $script:cliStage; Token = $script:secureToken } { Invoke-DemoRayfinCli -StagePath $Stage -ArgumentList @('up', '--json') -Token $Token -TokenAudience PowerBI } } | Should -Throw '*needs a Fabric token, not a PowerBI one*'
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -Times 0 -Exactly
        }
    }

    It 'calls a failed run whose error names an authorization failure a refusal, in one line of at most 300 characters: <Case>' -ForEach @(
        @{ Case = 'HTTP 401'; ExitCode = 1; Said = 'Request failed with status code 401'; StdErr = ''; Refused = $true }
        @{ Case = 'HTTP 403 in the error output only'; ExitCode = 1; Said = ''; StdErr = "POST /appBackends failed`n403 Forbidden"; Refused = $true }
        @{ Case = 'an Entra error'; ExitCode = 1; Said = 'AADSTS500011: The resource principal was not found in the tenant.'; StdErr = ''; Refused = $true }
        @{ Case = 'a wrong audience'; ExitCode = 1; Said = 'Invalid audience for this endpoint.'; StdErr = ''; Refused = $true }
        @{ Case = 'an expired token'; ExitCode = 1; Said = 'The token has expired.'; StdErr = ''; Refused = $true }
        @{ Case = 'a build error'; ExitCode = 1; Said = 'Build failed: error TS2304'; StdErr = ''; Refused = $false }
        @{ Case = 'a network error'; ExitCode = 1; Said = 'getaddrinfo ENOTFOUND api.fabric.microsoft.com'; StdErr = ''; Refused = $false }
        @{ Case = 'a success that mentions 401 in its output'; ExitCode = 0; Said = ''; StdErr = 'retrying after 401'; Refused = $false }
    ) {
        $data = if ($Said) { @{ status = 'error'; error = $Said } } elseif ($ExitCode -eq 0) { @{ status = 'success' } } else { @{ status = 'error' } }
        $run = New-CliResult $data -ExitCode $ExitCode -StdErr $StdErr
        $refusal = InModuleScope DbHubDemo -Parameters @{ Run = $run } { Get-DemoRayfinTokenRefusal -Run $Run }
        [bool]$refusal | Should -Be $Refused
        $refusal | Should -Not -Match '\r|\n'
        $long = New-CliResult @{ status = 'error'; error = ('401 Unauthorized ' + ('x' * 600)) } -ExitCode 1
        (InModuleScope DbHubDemo -Parameters @{ Run = $long } { Get-DemoRayfinTokenRefusal -Run $Run }).Length | Should -BeLessOrEqual 303
        (InModuleScope DbHubDemo { Get-DemoRayfinTokenRefusal -Run $null }) | Should -BeExactly ''
    }

    It 'records whether Fabric accepted the token in out/fabric-app-auth.json: no token, only the tenant''s ID, and a redacted reason' {
        $path = Join-Path -Path $TestDrive -ChildPath ('out-' + [guid]::NewGuid().ToString('N') + '/fabric-app-auth.json')
        $secret = 'sek' + ('R' * 20)
        (InModuleScope DbHubDemo -Parameters @{ Path = $path } { Get-DemoRayfinAuthRecord -Path $Path }).Outcome | Should -BeExactly '' -Because 'nothing is recorded on a first run'
        Register-DemoSecret -Value $secret
        InModuleScope DbHubDemo -Parameters @{ Path = $path; Tenant = $script:tenantId; Secret = $secret } { Set-DemoRayfinAuthRecord -Outcome Refused -Reason ('401 for {0}' -f $Secret) -TenantId $Tenant.ToUpperInvariant() -Path $Path }
        $record = InModuleScope DbHubDemo -Parameters @{ Path = $path } { Get-DemoRayfinAuthRecord -Path $Path }
        $record.Outcome | Should -Be 'Refused'
        $record.TenantId | Should -Be $script:tenantId.ToLowerInvariant()
        $record.Reason | Should -Match '^401 for '
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Not -Match ([regex]::Escape($secret))
        @(($text | ConvertFrom-Json -AsHashtable).Keys | Sort-Object) | Should -Be @('azureCliToken', 'checkedUtc', 'reason', 'tenantId')
        InModuleScope DbHubDemo -Parameters @{ Path = $path; Tenant = $script:tenantId } { Set-DemoRayfinAuthRecord -Outcome Accepted -TenantId $Tenant -Path $Path }
        (InModuleScope DbHubDemo -Parameters @{ Path = $path } { Get-DemoRayfinAuthRecord -Path $Path }).Outcome | Should -Be 'Accepted'
        Set-Content -LiteralPath $path -Value '{ not json' -Encoding utf8NoBOM
        { $script:damaged = InModuleScope DbHubDemo -Parameters @{ Path = $path } { Get-DemoRayfinAuthRecord -Path $Path } } | Should -Not -Throw
        $script:damaged.Outcome | Should -BeExactly ''
    }

    It 'names the stage''s CLI from the repository root in remediations, never npx: <Command>' -ForEach @(
        @{ Command = 'login'; Tenant = '66666666-7777-8888-9999-000000000000'; Line = './out/fabric-app/node_modules/.bin/rayfin login --tenant 66666666-7777-8888-9999-000000000000' }
        @{ Command = 'login'; Tenant = ''; Line = './out/fabric-app/node_modules/.bin/rayfin login --tenant <tenantId>' }
        @{ Command = 'login status'; Tenant = ''; Line = './out/fabric-app/node_modules/.bin/rayfin login status' }
        @{ Command = 'logout'; Tenant = ''; Line = './out/fabric-app/node_modules/.bin/rayfin logout' }
    ) {
        (InModuleScope DbHubDemo -Parameters @{ Command = $Command; Tenant = $Tenant } { Get-DemoRayfinCommand -Command $Command -TenantId $Tenant }) | Should -BeExactly $Line
    }
}

Describe 'Start-, Receive-, and Stop-DemoFabricAppProcess: node, npm, and npx, also without waiting (2026-11-06)' {
    BeforeAll {
        # This PowerShell stands in for node, so the child processes are real wherever the tests run (Windows or Linux).
        $script:standIn = (Get-Process -Id $PID).Path
        $script:childArguments = {
            param([string] $Script)
            @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script)))
        }
    }

    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'node' } -MockWith { [pscustomobject]@{ Source = $script:standIn } }
    }

    AfterEach {
        Remove-Item -Path 'Env:DBHUB_TEST_REMOVED' -ErrorAction SilentlyContinue
    }

    It 'starts without waiting, then reads the exit code, the output, and how long it ran; the child gets its environment, and this process keeps its own' {
        $env:DBHUB_TEST_REMOVED = 'this process'
        $arguments = & $script:childArguments 'Start-Sleep -Seconds 6; [Console]::Out.Write(''out ['' + $env:DBHUB_TEST_SET + ''] ['' + $env:DBHUB_TEST_REMOVED + '']''); [Console]::Error.Write(''err''); exit 7'
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $handle = InModuleScope DbHubDemo -Parameters @{ Arguments = $arguments; Dir = $TestDrive } { Start-DemoFabricAppProcess -Tool 'node' -ArgumentList $Arguments -WorkingDirectory $Dir -TimeoutSeconds 120 -Environment @{ DBHUB_TEST_SET = 'set'; DBHUB_TEST_REMOVED = $null } }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 4 -Because 'nothing waits for the child, which runs for at least 6 seconds'
        $read = InModuleScope DbHubDemo -Parameters @{ Handle = $handle } { Receive-DemoFabricAppProcess -Handle $Handle }
        $read.ExitCode | Should -Be 7
        $read.StdOut | Should -BeExactly 'out [set] []'
        $read.StdErr | Should -BeExactly 'err'
        $read.TimedOut | Should -BeFalse
        $read.Seconds | Should -BeGreaterOrEqual 5
        $env:DBHUB_TEST_REMOVED | Should -BeExactly 'this process'
        { InModuleScope DbHubDemo -Parameters @{ Handle = $handle } { Receive-DemoFabricAppProcess -Handle $Handle } } | Should -Throw '*already read or stopped*'
    }

    It 'ends a child that runs past its time limit, with every process it started, and says so' {
        $arguments = & $script:childArguments 'Start-Sleep -Seconds 120'
        $handle = InModuleScope DbHubDemo -Parameters @{ Arguments = $arguments; Dir = $TestDrive } { Start-DemoFabricAppProcess -Tool 'node' -ArgumentList $Arguments -WorkingDirectory $Dir -TimeoutSeconds 3 }
        $childId = $handle.Process.Id
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $read = InModuleScope DbHubDemo -Parameters @{ Handle = $handle } { Receive-DemoFabricAppProcess -Handle $Handle }
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
        $read.ExitCode | Should -Be -1
        $read.TimedOut | Should -BeTrue
        $read.StdOut | Should -BeExactly ''
        $read.StdErr | Should -BeExactly 'node did not finish within 3 seconds and was stopped.'
        $read.Seconds | Should -Be 3
        $gone = $false
        for ($attempt = 0; $attempt -lt 20 -and -not $gone; $attempt++) {
            $gone = $null -eq (Get-Process -Id $childId -ErrorAction SilentlyContinue)
            if (-not $gone) {
                Start-Sleep -Milliseconds 250
            }
        }
        $gone | Should -BeTrue -Because 'the child was ended, not left running'
    }

    It 'runs and waits in one call, as before, and the output''s line ending is trimmed on every platform (Invoke-DemoFabricAppProcess)' {
        $arguments = & $script:childArguments '[Console]::Out.WriteLine(''{"status":"ok"}''); exit 0'
        $read = InModuleScope DbHubDemo -Parameters @{ Arguments = $arguments; Dir = $TestDrive } { Invoke-DemoFabricAppProcess -Tool 'node' -ArgumentList $Arguments -WorkingDirectory $Dir -TimeoutSeconds 120 }
        $read.ExitCode | Should -Be 0
        $read.StdOut | Should -BeExactly '{"status":"ok"}'
        $read.StdErr | Should -BeExactly ''
        $read.TimedOut | Should -BeFalse
    }

    It 'ends a child that''s no longer needed once, with every process it started, and its handle can''t be read after that' {
        $process = [pscustomobject]@{ HasExited = $false; Killed = $null; Disposed = 0 }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($Tree) $this.Killed = [bool]$Tree; $this.HasExited = $true }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed++ }
        $handle = [pscustomobject]@{ Tool = 'npx'; Process = $process; StartedUtc = [DateTime]::UtcNow; TimeoutSeconds = 90; Closed = $false }
        { InModuleScope DbHubDemo -Parameters @{ Handle = $handle } { Stop-DemoFabricAppProcess -Handle $Handle; Stop-DemoFabricAppProcess -Handle $Handle; Stop-DemoFabricAppProcess -Handle $null } } | Should -Not -Throw
        $process.Killed | Should -BeTrue
        $process.Disposed | Should -Be 1
        $handle.Closed | Should -BeTrue
        { InModuleScope DbHubDemo -Parameters @{ Handle = $handle } { Receive-DemoFabricAppProcess -Handle $Handle } } | Should -Throw '*already read or stopped*'
    }

    It 'throws, naming Node.js, when the tool isn''t on PATH' {
        Mock -ModuleName DbHubDemo -CommandName Get-Command -ParameterFilter { $Name -eq 'node' } -MockWith { }
        { InModuleScope DbHubDemo -Parameters @{ Dir = $TestDrive } { Start-DemoFabricAppProcess -Tool 'node' -ArgumentList @('--version') -WorkingDirectory $Dir } } | Should -Throw '*node was not found on PATH. Install Node.js*'
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
        $signIn.remediation | Should -Match ([regex]::Escape("./out/fabric-app/node_modules/.bin/rayfin login --tenant $script:tenantId"))
        $signIn.remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
        $signIn.remediation | Should -Not -Match 'npx' -Because 'npx resolves the CLI''s dependencies without the lock file''s npm overrides (2026-11-09)'

        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'ok'; tenant = '00000000-0000-0000-0000-000000000000' } }
        (Test-DemoFabricAppPrerequisite -Config $script:config -StagePath $TestDrive | Where-Object checkId -EQ 'FABRIC.APP.SIGNIN').message | Should -Match 'another tenant'
    }

    It 'needs no Rayfin sign-in with -UseAzureCliToken: FABRIC.APP.SIGNIN is a Pass that says so, and login status doesn''t run (2026-11-09)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = 'v24.11.0'; StdErr = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { throw 'rayfin login status must not run with the Azure CLI''s token: it checks nothing then.' }
        $results = @(Test-DemoFabricAppPrerequisite -Config $script:config -StagePath $TestDrive -UseAzureCliToken)
        $signIn = $results | Where-Object checkId -EQ 'FABRIC.APP.SIGNIN'
        $signIn.status | Should -Be 'Pass'
        $signIn.evidence['auth'] | Should -Be 'azureCli'
        $signIn.message | Should -Match 'your Azure CLI sign-in \(az login\)'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 0 -Exactly
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
        $expired.remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))

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

    It 'gives rayfin up and rayfin up status the Azure CLI''s Fabric token, and records that Fabric accepted it (2026-11-09)' {
        Mock -ModuleName DbHubDemo -CommandName Set-DemoRayfinAuthRecord -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -ParameterFilter { $ArgumentList[0] -eq 'up' -and $ArgumentList[1] -ne 'status' } -MockWith { New-CliResult $script:upSuccess }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -ParameterFilter { $ArgumentList[1] -eq 'status' } -MockWith { New-CliResult $script:statusOk }
        $results = @(Invoke-DemoFabricAppDeployment -StagePath $TestDrive -WorkspaceId $script:workspaceId -TenantId $script:tenantId -ItemName 'APP_DatabaseHub_Insights' -Token $script:token -Confirm:$false)
        $deploy = $results | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY'
        $deploy.status | Should -Be 'Pass'
        $deploy.message | Should -Match 'with the Azure CLI''s token'
        $deploy.evidence['auth'] | Should -Be 'azureCli'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.STATUS').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 2 -Exactly -ParameterFilter { [object]::ReferenceEquals($PesterBoundParameters['Token'], $script:token) -and $TokenAudience -eq 'Fabric' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoRayfinAuthRecord -Times 1 -Exactly -ParameterFilter { $Outcome -eq 'Accepted' -and $TenantId -eq $script:tenantId }
    }

    It 'makes a token Fabric refuses a Warning with the reason, never a Fail, and records the refusal, except for a dry run (2026-11-09)' {
        Mock -ModuleName DbHubDemo -CommandName Set-DemoRayfinAuthRecord -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'error'; error = 'Request failed with status code 401: Unauthorized' } -ExitCode 1 }
        $refused = @(Invoke-DemoFabricAppDeployment -StagePath $TestDrive -WorkspaceId $script:workspaceId -TenantId $script:tenantId -ItemName 'APP_DatabaseHub_Insights' -Token $script:token -Confirm:$false)
        $refused.Count | Should -Be 1 -Because 'rayfin up status doesn''t run after a refusal'
        $refused[0].checkId | Should -Be 'FABRIC.APP.DEPLOY'
        $refused[0].status | Should -Be 'Warning'
        $refused[0].message | Should -Match 'Fabric refused the Azure CLI''s token for rayfin up: .*401'
        $refused[0].evidence['tokenRefused'] | Should -BeTrue
        $refused[0].evidence['refusal'] | Should -Match '401'
        $refused[0].remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoRayfinAuthRecord -Times 1 -Exactly -ParameterFilter { $Outcome -eq 'Refused' -and $Reason -match '401' -and $TenantId -eq $script:tenantId }

        $dry = @(Invoke-DemoFabricAppDeployment -StagePath $TestDrive -WorkspaceId $script:workspaceId -TenantId $script:tenantId -ItemName 'APP_DatabaseHub_Insights' -Token $script:token -DryRun -Confirm:$false)
        $dry[0].status | Should -Be 'Warning'
        $dry[0].evidence['dryRun'] | Should -BeTrue
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoRayfinAuthRecord -Times 1 -Exactly -Because 'a dry run records nothing'

        # The same failure without the token is the Rayfin CLI's own: no refusal, and nothing recorded.
        $own = @(Invoke-DemoFabricAppDeployment -StagePath $TestDrive -WorkspaceId $script:workspaceId -TenantId $script:tenantId -ItemName 'APP_DatabaseHub_Insights' -Confirm:$false)
        $own[0].status | Should -Be 'Fail'
        $own[0].evidence.Contains('tokenRefused') | Should -BeFalse
        $own[0].evidence['auth'] | Should -Be 'rayfinSignIn'
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoRayfinAuthRecord -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 1 -Exactly -ParameterFilter { $null -eq $PesterBoundParameters['Token'] }
    }

    It 'keeps a failure that isn''t a refusal what it is with the token: a build error is a Fail, and nothing is recorded' {
        Mock -ModuleName DbHubDemo -CommandName Set-DemoRayfinAuthRecord -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'error'; error = 'Build failed: src/App.tsx(3,1): error TS2304: Cannot find name ''x''.' } -ExitCode 1 }
        $result = @(Invoke-DemoFabricAppDeployment -StagePath $TestDrive -WorkspaceId $script:workspaceId -TenantId $script:tenantId -ItemName 'APP_DatabaseHub_Insights' -Token $script:token -Confirm:$false)
        $result[0].status | Should -Be 'Fail'
        $result[0].evidence['auth'] | Should -Be 'azureCli'
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoRayfinAuthRecord -Times 0 -Exactly
    }
}

Describe 'Test-DemoFabricApp' {
    BeforeEach {
        $script:checkStage = Join-Path -Path $TestDrive -ChildPath ('check-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:checkStage -Force
        # The row bound each payload carries (resultSetRowCountLimit), as the catalog sets it; a test can lower one.
        $script:rowLimits = @{ 'connector-check' = 1; 'history-meta' = 1; 'estate-targets' = 50; 'replay-T3' = 500; 'postgres-series' = 500 }
        # The queries the stage's index lists; a test can change them.
        $script:queryIds = @('connector-check', 'history-meta', 'estate-targets', 'replay-T3')
        # npm run queries:export writes the payloads ({ query, resultSetRowCountLimit }) and their index into the stage.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -MockWith {
            $folder = Join-Path -Path $WorkingDirectory -ChildPath $ArgumentList[3]
            $null = New-Item -ItemType Directory -Path $folder -Force
            Set-TestDotItemHidden -Path (Split-Path -Path $folder -Parent)
            $ids = @($script:queryIds)
            foreach ($id in $ids) {
                @{ query = ('EVALUATE /* {0} */ ROW("x", 1)' -f $id); resultSetRowCountLimit = $script:rowLimits[$id] } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath ($id + '.json')) -Encoding utf8NoBOM
            }
            $index = @{ latestDay = '2026-10-21'; queries = @($ids | ForEach-Object { @{ id = $_; file = ($_ + '.json'); rowLimit = $script:rowLimits[$_] } }) }
            $index | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'index.json') -Encoding utf8NoBOM
            [pscustomobject]@{ ExitCode = 0; StdOut = 'Wrote 4 queries'; StdErr = '' }
        }
        # Power BI's Execute Queries runs only when the connector's direct route refuses the token; a test says so.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDaxQuery -MockWith { throw 'Execute Queries isn''t expected here.' }
        # The refusal of the connector's route is never recorded as the deploy token's (2026-11-09).
        Mock -ModuleName DbHubDemo -CommandName Set-DemoRayfinAuthRecord -MockWith { throw 'Test-DemoFabricApp must never record a token refusal.' }
        # The connector's direct route as it answered live for the Azure CLI's token (2026-11-09: Power BI's
        # executeDaxQueries, HTTP 401), and Execute Queries' rows for each query, by the query's text.
        $script:refusedRun = New-CliResult @{ status = 'error'; error = 'Request failed with status code 401'; recovery = 'Check the token.'; connectorError = @{ category = 'api'; code = 'Unauthorized'; message = '{"error":{"code":"Unauthorized","pbi.error":{"code":"Unauthorized","parameters":{},"details":[],"exceptionCulprit":1}}}' } } -ExitCode 1
        $script:daxRows = @{
            'connector-check' = @([pscustomobject]@{ '[ValidationRows]' = 12; '[SnapshotRows]' = 2293; '[Incidents]' = 4 })
            'history-meta'    = @([pscustomobject]@{ '[LatestDay]' = [datetime]::new(2026, 10, 21, 0, 0, 0, [System.DateTimeKind]::Unspecified) })
            'estate-targets'  = @([pscustomobject]@{ 'Target[Target Key]' = 'T1' }, [pscustomobject]@{ 'Target[Target Key]' = 'T3' })
            'replay-T3'       = @()
            'postgres-series' = @()
        }
        $script:daxAnswer = { param([string] $Query) $id = [regex]::Match($Query, '/\* (\S+) \*/').Groups[1].Value; [pscustomobject]@{ StatusCode = 200; Rows = @($script:daxRows[$id]); Error = '' } }
    }

    It 'passes when every query returns rows and anonymous requests are refused, and makes the browser check a note that says exactly what was verified (2026-11-09)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith {
            $file = $ArgumentList[[array]::IndexOf($ArgumentList, '--file') + 1]
            $table = if ($file -match 'connector-check') { @{ columns = @(@{ name = '[ValidationRows]' }, @{ name = '[SnapshotRows]' }, @{ name = '[Incidents]' }); rows = @(, @(12, 2293, 4)) } }
            elseif ($file -match 'history-meta') { @{ columns = @(@{ name = '[LatestDay]' }); rows = @(, @('2026-10-21T00:00:00')) } }
            else { @{ columns = @(@{ name = 'Target[Target Key]' }); rows = @(, @('T3')) } }
            New-CliResult @{ status = 'ok'; connector = 'history'; operation = 'executeQuery'; output = @{ status = 'success'; table = $table } }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 401; Content = '{"error":"Authentication required."}' } }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -ItemUrl 'https://app.fabric.microsoft.com/groups/x/appbackends/y' -Token $script:token -Deployed)
        $connector = $results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR'
        $connector.status | Should -Be 'Pass'
        $connector.message | Should -BeExactly 'Connector check passed with the Azure CLI''s Power BI token: the history connector returned 12 validation checks, 2293 telemetry rows, and 4 incident windows from SM_DatabaseHub_History.'
        $connector.evidence['route'] | Should -Be 'connector'
        $connector.evidence['auth'] | Should -Be 'azureCli'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.HOSTING').status | Should -Be 'Pass'
        $browser = $results | Where-Object checkId -EQ 'FABRIC.APP.BROWSER'
        $browser.status | Should -Be 'Not selected' -Because 'nobody needs to open the app to finish the deployment (user-directed: no user steps)'
        $browser.message | Should -Match '^Not needed: the app is deployed \(FABRIC\.APP\.DEPLOY\), and its hosting is protected: the hosted app refuses anonymous requests \(FABRIC\.APP\.HOSTING\); and every query it runs \(4\) returned data from SM_DatabaseHub_History under your identity \(FABRIC\.APP\.QUERIES, through the connector''s direct route\)\. '
        $browser.message | Should -Match 'What no script can check is the app''s own route in the browser: its embedded sign-in, then its backend, User Data Functions, and a delegated on-behalf-of call to the model'
        $browser.message | Should -Match 'open its item page \(https://app\.fabric\.microsoft\.com/groups/x/appbackends/y\) in the Fabric portal'
        $browser.message | Should -Not -Match 'the one the app uses' -Because 'the direct route never crosses the app''s own route (review, 2026-11-09)'
        @($browser.evidence['verifiedBy']) | Should -Be @('FABRIC.APP.DEPLOY', 'FABRIC.APP.HOSTING', 'FABRIC.APP.CONNECTOR', 'FABRIC.APP.QUERIES')
        $browser.evidence['inAppRouteChecked'] | Should -BeFalse -Because 'the app''s own route in the browser isn''t checked by a script'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 0 -Exactly -ParameterFilter { $null -eq $PesterBoundParameters['Token'] }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDaxQuery -Times 0 -Exactly
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
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Token $script:token)
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
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Token $script:token -Deployed)
        ($results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES').status | Should -Be 'Fail'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES').message | Should -Match 'estate-targets'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.HOSTING').status | Should -Be 'Fail'
        $browser = $results | Where-Object checkId -EQ 'FABRIC.APP.BROWSER'
        $browser.status | Should -Be 'Manual action required' -Because 'a query failed, so the queries didn''t verify the app'
        $browser.message | Should -Match 'its queries didn''t all run here'
        $browser.remediation | Should -Match 'Connector check passed'
        $browser.remediation | Should -Match 'Page not accessible directly'
    }

    It 'gives the connector''s queries the Azure CLI''s Power BI token (2026-11-09)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'ok'; output = @{ status = 'success'; table = @{ columns = @(@{ name = '[ValidationRows]' }, @{ name = '[SnapshotRows]' }, @{ name = '[Incidents]' }); rows = @(, @(12, 2293, 4)) } } } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 401; Content = '' } }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Queries Probe -Token $script:token)
        $connector = $results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR'
        $connector.status | Should -Be 'Pass'
        $connector.message | Should -Match '^Connector check passed with the Azure CLI''s Power BI token: '
        $connector.evidence['auth'] | Should -Be 'azureCli'
        $connector.evidence['route'] | Should -Be 'connector'
        $connector.evidence.Contains('connectorRefusal') | Should -BeFalse
        $connector.evidence.Contains('tokenRefused') | Should -BeFalse
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 0 -Exactly -ParameterFilter { $null -eq $PesterBoundParameters['Token'] }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -ParameterFilter { [object]::ReferenceEquals($PesterBoundParameters['Token'], $script:token) -and $TokenAudience -eq 'PowerBI' -and $ArgumentList[0] -eq 'connector' }
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDaxQuery -Times 0 -Exactly -Because 'the connector''s route took the token'
    }

    Context 'when the connector''s direct route refuses the Azure CLI''s token (live, 2026-11-09)' {
        BeforeEach {
            Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith {
                if ($null -eq $PesterBoundParameters['Token']) {
                    throw 'The Rayfin CLI''s own sign-in must never run without -RayfinSignIn.'
                }
                $script:refusedRun
            }
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDaxQuery -MockWith { & $script:daxAnswer $Query }
            Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 401; Content = '' } }
        }

        It 'runs the connector check and every query through Execute Queries with the same token: no Rayfin sign-in, nothing recorded, and the browser check a note' {
            $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -ItemUrl 'https://app.fabric.microsoft.com/groups/x/appbackends/y' -Token $script:token -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Deployed)
            $connector = $results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR'
            $connector.status | Should -Be 'Pass'
            $connector.message | Should -BeExactly 'Connector check passed through Power BI''s Execute Queries with the Azure CLI''s Power BI token, because the history connector''s direct route refused that token (HTTP 401): SM_DatabaseHub_History returned 12 validation checks, 2293 telemetry rows, and 4 incident windows. No Rayfin sign-in was needed.'
            $connector.evidence['route'] | Should -Be 'executeQueries'
            $connector.evidence['auth'] | Should -Be 'azureCli'
            $connector.evidence['connectorRefusal'] | Should -Match '401'
            $connector.docUrl | Should -Be 'https://learn.microsoft.com/rest/api/power-bi/datasets/execute-queries-in-group'
            $queries = $results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES'
            $queries.status | Should -Be 'Warning' -Because 'replay-T3 has no rows, as incident-windows and readiness-checks had live'
            $queries.message | Should -BeExactly 'All 4 app queries ran through Power BI''s Execute Queries with the Azure CLI''s Power BI token (the history connector''s direct route refused it); 1 returned no rows for the newest telemetry day 2026-10-21: replay-T3.'
            $queries.evidence['route'] | Should -Be 'executeQueries'
            @($queries.evidence['queries'] | ForEach-Object { $_['route'] }) | Should -Be @('executeQueries', 'executeQueries', 'executeQueries', 'executeQueries')
            @($queries.evidence['queries'] | ForEach-Object { $_['rows'] }) | Should -Be @(1, 1, 2, 0)
            $queries.evidence['rowBound'] | Should -Match 'one query per request and has no resultSetRowCountLimit'
            # The deploy accepted the token, so this isn't an auth refusal: no record says so, and nothing is kept for a
            # later run, which would open a browser.
            $results.checkId | Should -Not -Contain 'FABRIC.APP.TOKEN'
            foreach ($record in $results) {
                @($record.evidence.Keys) | Should -Not -Contain 'tokenRefused' -Because $record.checkId
                @($record.evidence.Keys) | Should -Not -Contain 'signInNeeded' -Because $record.checkId
            }
            Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoRayfinAuthRecord -Times 0 -Exactly
            Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -Times 0 -Exactly -ParameterFilter { $PesterBoundParameters['Level'] -in 'Warning', 'Error' }
            # One connector call, the refused probe; then Execute Queries for each query, one per request, with the same token.
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 1 -Exactly
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDaxQuery -Times 4 -Exactly -ParameterFilter { $WorkspaceId -eq $script:workspaceId -and $SemanticModelId -eq $script:modelId -and [object]::ReferenceEquals($Token, $script:token) }
            $browser = $results | Where-Object checkId -EQ 'FABRIC.APP.BROWSER'
            $browser.status | Should -Be 'Not selected'
            $browser.message | Should -Match '^Not needed: the app is deployed \(FABRIC\.APP\.DEPLOY\), and its hosting is protected: the hosted app refuses anonymous requests \(FABRIC\.APP\.HOSTING\); and every query it runs \(4\) ran on SM_DatabaseHub_History under your identity, and 3 returned data; the other one has no history for its window yet \(FABRIC\.APP\.QUERIES, through Power BI''s Execute Queries\)\. '
            $browser.message | Should -Match 'which none of these checks crosses\. To see it, open its item page \(https://app\.fabric\.microsoft\.com/groups/x/appbackends/y\) in the Fabric portal; it opens embedded and signs in by itself\.$'
            $browser.evidence['route'] | Should -Be 'executeQueries'
        }

        It 'says T4''s PostgreSQL page has no capture yet instead of warning, since its rows come after the check (2026-11-13)' {
            $script:queryIds = @('connector-check', 'history-meta', 'estate-targets', 'postgres-series')
            $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -ItemUrl 'https://app.fabric.microsoft.com/groups/x/appbackends/y' -Token $script:token -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Deployed)
            $queries = $results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES'
            $queries.status | Should -Be 'Pass'
            $queries.message | Should -Match 'T4''s PostgreSQL page has no capture yet \(postgres-series\): deploy\.ps1''s history snapshot at its end, and stop-demo\.ps1 -SaveHistory, add one\.$'
            # Another query without rows is still a Warning, with the same note.
            $script:queryIds = @('connector-check', 'history-meta', 'replay-T3', 'postgres-series')
            $script:checkStage = Join-Path -Path $TestDrive -ChildPath ('check-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $script:checkStage -Force
            $warned = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -ItemUrl 'https://app.fabric.microsoft.com/groups/x/appbackends/y' -Token $script:token -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Deployed) | Where-Object checkId -EQ 'FABRIC.APP.QUERIES'
            $warned.status | Should -Be 'Warning'
            $warned.message | Should -Match '1 returned no rows for the newest telemetry day 2026-10-21: replay-T3\. T4''s PostgreSQL page has no capture yet \(postgres-series\)'
        }

        It 'reads the workspace and the model from the stage''s rayfin/.env when they aren''t passed, and fails clearly without them' {
            $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:checkStage -ChildPath 'rayfin') -Force
            Set-Content -LiteralPath (Join-Path -Path $script:checkStage -ChildPath 'rayfin/.env') -Value @('RAYFIN_PUBLIC_URL=https://app-example.invalid', ('DBHUB_FABRIC_WORKSPACE_ID={0}' -f $script:workspaceId), ('DBHUB_SEMANTIC_MODEL_ID={0}' -f $script:modelId)) -Encoding utf8NoBOM
            Set-TestDotItemHidden -Path (Join-Path -Path $script:checkStage -ChildPath 'rayfin/.env')
            $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Queries Probe -Token $script:token)
            ($results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR').status | Should -Be 'Pass'
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDaxQuery -Times 1 -Exactly -ParameterFilter { $WorkspaceId -eq $script:workspaceId -and $SemanticModelId -eq $script:modelId }

            Remove-Item -LiteralPath (Join-Path -Path $script:checkStage -ChildPath 'rayfin/.env') -Force
            $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Queries Probe -Token $script:token)
            $connector = $results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR'
            $connector.status | Should -Be 'Fail'
            $connector.message | Should -Match 'Power BI''s Execute Queries couldn''t run: the workspace and the semantic model aren''t known'
            $connector.remediation | Should -Match '^Pass -WorkspaceId and -SemanticModelId, or deploy the app first'
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDaxQuery -Times 1 -Exactly -Because 'without the IDs, Execute Queries isn''t called'
        }

        It 'fails with the fix for what Power BI answered when Execute Queries refuses the token too: HTTP <Code>' -ForEach @(
            @{ Code = 401; Fix = 'sign in again with az login --tenant <tenantId> as the configured azureAccount' }
            @{ Code = 403; Fix = 'needs Read and Build on SM_DatabaseHub_History .* Dataset Execute Queries REST API must be on for them \(FABRIC\.APP\.EXECUTEQUERIES\)' }
            @{ Code = 404; Fix = 'SM_DatabaseHub_History wasn''t found in the workspace: deploy it with \./scripts/configure-powerbi\.ps1' }
            @{ Code = 503; Fix = 'Power BI didn''t answer the check \(HTTP 503\): check again with -CheckOnly in a few minutes' }
        ) {
            $script:failCode = $Code
            Mock -ModuleName DbHubDemo -CommandName Invoke-DemoDaxQuery -MockWith { [pscustomobject]@{ StatusCode = $script:failCode; Rows = @(); Error = ('HTTP {0} Unauthorized' -f $script:failCode) } }
            $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Token $script:token -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Deployed)
            $connector = $results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR'
            $connector.status | Should -Be 'Fail'
            $connector.message | Should -BeExactly ('The connector check failed on both routes: the history connector''s direct route refused the Azure CLI''s Power BI token (HTTP 401), and Power BI''s Execute Queries answered HTTP {0} Unauthorized' -f $Code)
            $connector.remediation | Should -Match $Fix
            $connector.remediation | Should -Not -Match 'configure-fabric-app\.ps1' -Because 'deploy.ps1''s summary keeps only a fix that doesn''t name the script'
            $connector.evidence['statusCode'] | Should -Be $Code
            $connector.evidence['route'] | Should -Be 'executeQueries'
            ($results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES').status | Should -Be 'Not selected'
            ($results | Where-Object checkId -EQ 'FABRIC.APP.BROWSER').status | Should -Be 'Manual action required'
            $results.checkId | Should -Not -Contain 'FABRIC.APP.TOKEN'
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 1 -Exactly -Because 'the Rayfin CLI''s own sign-in is no fallback'
            Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoRayfinAuthRecord -Times 0 -Exactly
        }

        It 'fails a query over the app''s row bound, as the app''s connector would (overflow): Execute Queries has none' {
            $script:rowLimits['estate-targets'] = 1
            $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Token $script:token -WorkspaceId $script:workspaceId -SemanticModelId $script:modelId -Deployed)
            $queries = $results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES'
            $queries.status | Should -Be 'Fail'
            $queries.message | Should -Match ([regex]::Escape('estate-targets (overflow: 2 rows, over the app''s bound of 1 (resultSetRowCountLimit), which its connector refuses)'))
            $queries.remediation | Should -Match 'A query over its row bound \(overflow\) needs a narrower window, or a larger rowLimit'
            ($results | Where-Object checkId -EQ 'FABRIC.APP.BROWSER').status | Should -Be 'Manual action required'
        }
    }

    It 'runs the queries through the connector with the Rayfin CLI''s own sign-in only with -RayfinSignIn, as before, and never through Execute Queries' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith {
            if ($null -ne $PesterBoundParameters['Token']) {
                throw 'No token with -RayfinSignIn.'
            }
            New-CliResult @{ status = 'ok'; output = @{ status = 'success'; table = @{ columns = @(@{ name = '[ValidationRows]' }, @{ name = '[SnapshotRows]' }, @{ name = '[Incidents]' }); rows = @(, @(12, 2293, 4)) } } }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 401; Content = '' } }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Queries Probe -RayfinSignIn)
        $connector = $results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR'
        $connector.status | Should -Be 'Pass'
        $connector.message | Should -Match '^Connector check passed with the Rayfin CLI''s own sign-in \(-RayfinSignIn\): the history connector returned 12 validation checks'
        $connector.evidence['auth'] | Should -Be 'rayfinSignIn'
        $connector.evidence['route'] | Should -Be 'connector'

        # Not signed in: a Fail that says how to sign in, and still no Execute Queries.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'error'; error = 'Not logged in. Run rayfin login.' } -ExitCode 1 }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Queries Probe -RayfinSignIn -Token $script:token)
        $connector = $results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR'
        $connector.status | Should -Be 'Fail'
        $connector.message | Should -Match '^The history connector didn''t return the connector check with the Rayfin CLI''s own sign-in: Not logged in'
        $connector.remediation | Should -Match '-SignIn signs it in'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -Times 0 -Exactly -ParameterFilter { $null -ne $PesterBoundParameters['Token'] } -Because '-RayfinSignIn passes no token, even when one is given'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDaxQuery -Times 0 -Exactly
    }

    It 'warns, runs no query, and leaves the browser check to a person without a token or -RayfinSignIn: the Rayfin CLI''s own sign-in is never a fallback' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { throw 'No Rayfin CLI call is expected without a token or -RayfinSignIn.' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 401; Content = '' } }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Deployed)
        $connector = $results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR'
        $connector.status | Should -Be 'Warning'
        $connector.message | Should -Match 'the Rayfin CLI''s own sign-in runs them only with -RayfinSignIn, never as a fallback'
        $connector.remediation | Should -Match '-CheckOnly -RayfinSignIn'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.QUERIES').status | Should -Be 'Not selected'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.HOSTING').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'FABRIC.APP.BROWSER').status | Should -Be 'Manual action required'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoFabricAppProcess -Times 0 -Exactly -Because 'nothing exports queries no route can run'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoDaxQuery -Times 0 -Exactly
    }

    It 'says only what was verified in the browser check''s note, and asks a person when the deployment wasn''t confirmed: <Case>' -ForEach @(
        @{ Case = 'deployed in this run, hosting unconfirmed'; Deployed = $true; Code = 302; Hosting = $true; Status = 'Not selected'; Text = '^Not needed: the app is deployed \(FABRIC\.APP\.DEPLOY\), though its hosting''s protection wasn''t confirmed \(FABRIC\.APP\.HOSTING says why\); and every query it runs \(4\) returned data' }
        @{ Case = 'a check of an earlier deploy, hosting protected'; Deployed = $false; Code = 401; Hosting = $true; Status = 'Not selected'; Text = '^Not needed: the app is deployed, and its hosting is protected: the hosted app refuses anonymous requests \(FABRIC\.APP\.HOSTING\); and every query' }
        @{ Case = 'a check without a deployment record'; Deployed = $false; Code = 401; Hosting = $false; Status = 'Manual action required'; Text = '^A person must confirm the app in the browser: that it''s deployed wasn''t confirmed here \(no deploy in this run, and FABRIC\.APP\.HOSTING didn''t pass\), and its own route there' }
    ) {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith {
            $file = $ArgumentList[[array]::IndexOf($ArgumentList, '--file') + 1]
            $table = if ($file -match 'connector-check') { @{ columns = @(@{ name = '[ValidationRows]' }, @{ name = '[SnapshotRows]' }, @{ name = '[Incidents]' }); rows = @(, @(12, 2293, 4)) } }
            elseif ($file -match 'history-meta') { @{ columns = @(@{ name = '[LatestDay]' }); rows = @(, @('2026-10-21T00:00:00')) } }
            else { @{ columns = @(@{ name = 'Target[Target Key]' }); rows = @(, @('T3')) } }
            New-CliResult @{ status = 'ok'; output = @{ status = 'success'; table = $table } }
        }
        $script:hostingCode = $Code
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = $script:hostingCode; Content = '' } }
        $hostingUrl = if ($Hosting) { $script:hosting } else { '' }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $hostingUrl -Token $script:token -Deployed:$Deployed)
        $browser = $results | Where-Object checkId -EQ 'FABRIC.APP.BROWSER'
        $browser.status | Should -Be $Status
        $browser.message | Should -Match $Text
    }

    It 'reports a blank count as 0: DAX COUNTROWS over an empty table, as in a new lakehouse, is blank' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'ok'; output = @{ status = 'success'; table = @{ columns = @(@{ name = '[ValidationRows]' }, @{ name = '[SnapshotRows]' }, @{ name = '[Incidents]' }); rows = @(, @($null, 2598, 22)) } } } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 401; Content = '' } }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -HostingUrl $script:hosting -Queries Probe -Token $script:token)
        $connector = $results | Where-Object checkId -EQ 'FABRIC.APP.CONNECTOR'
        $connector.status | Should -Be 'Pass'
        $connector.message | Should -Match 'returned 0 validation checks, 2598 telemetry rows, and 22 incident windows'
    }

    It 'reads the hosting URL from the stage''s deployment record when none is passed' {
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $script:checkStage -ChildPath 'rayfin') -Force
        @{ active = 'demo'; deployments = @{ demo = @{ itemName = 'APP_DatabaseHub_Insights'; fabricItemId = $script:itemId; hostingUrl = $script:hosting; fabricDeepLink = 'https://app.fabric.microsoft.com/groups/x/appbackends/y'; publishableKey = $script:fakeKey } } } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path -Path $script:checkStage -ChildPath 'rayfin/.deployments.json') -Encoding utf8NoBOM
        Set-TestDotItemHidden -Path (Join-Path -Path $script:checkStage -ChildPath 'rayfin/.deployments.json')
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRayfinCli -MockWith { New-CliResult @{ status = 'ok'; output = @{ status = 'success'; table = @{ columns = @(@{ name = '[ValidationRows]' }); rows = @(, @(12)) } } } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { [pscustomobject]@{ StatusCode = 401; Content = '' } }
        $results = @(Test-DemoFabricApp -StagePath $script:checkStage -Queries Probe -Token $script:token)
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
        # The Azure CLI's Fabric token goes to rayfin up (2026-11-09); a -FabricToken the caller passed means the script ran
        # no guard of its own, so it asks the Azure CLI for no Power BI token.
        Should -Invoke -CommandName Test-DemoFabricAppPrerequisite -Times 1 -Exactly -ParameterFilter { $UseAzureCliToken }
        Should -Invoke -CommandName Invoke-DemoFabricAppDeployment -Times 1 -Exactly -ParameterFilter { [object]::ReferenceEquals($PesterBoundParameters['Token'], $script:token) }
        Should -Invoke -CommandName Test-DemoFabricApp -Times 1 -Exactly -ParameterFilter { $null -eq $PesterBoundParameters['Token'] }

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

    Context 'the Azure CLI''s tokens for the Rayfin CLI, and the fallback to its own sign-in (2026-11-09)' {
        BeforeEach {
            $pass = $script:passResult
            # Locals, not script-scope variables: while the script runs, a mock's script scope is the script's own.
            $modelId = $script:modelId
            $capacityId = $script:capacityId
            $itemId = $script:itemId
            $hosting = $script:hosting
            Mock -CommandName Test-DemoFabricWorkspace -MockWith { @((& $pass 'FABRIC.P5.WORKSPACE'), (& $pass 'FABRIC.P5.CAPACITY' @{ capacityId = $capacityId; capacityAssignmentProgress = 'Completed' })) }
            Mock -CommandName Resolve-DemoFabricAppItem -MockWith { & $pass 'FABRIC.APP.ITEMS' @{ semanticModelId = $modelId; links = [ordered]@{} } }
            Mock -CommandName Sync-DemoFabricAppStage -MockWith { @((& $pass 'FABRIC.APP.STAGE'), (& $pass 'FABRIC.APP.DEPENDENCIES')) }
            # The Rayfin CLI's own sign-in, which only runs when the Azure CLI's token isn't used: signed in, unless a test
            # says otherwise.
            $ownSignIn = 'Pass'
            Mock -CommandName Test-DemoFabricAppPrerequisite -MockWith {
                $signInRecord = if ($UseAzureCliToken) { & $pass 'FABRIC.APP.SIGNIN' @{ auth = 'azureCli' } }
                elseif ($ownSignIn -eq 'Pass') { & $pass 'FABRIC.APP.SIGNIN' @{ auth = 'rayfinSignIn' } }
                else { New-DemoResult -CheckId 'FABRIC.APP.SIGNIN' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'The Rayfin CLI isn''t signed in, so the app can''t be deployed unattended.' -Remediation 'Sign in once.' }
                @((& $pass 'FABRIC.APP.NODE'), $signInRecord)
            }
            # Fabric refuses the Azure CLI's token; the CLI's own sign-in deploys.
            Mock -CommandName Invoke-DemoFabricAppDeployment -MockWith {
                if ($null -ne $PesterBoundParameters['Token']) {
                    return @(New-DemoResult -CheckId 'FABRIC.APP.DEPLOY' -Area 'fabric' -Target 'fabric' -Status 'Warning' -Message 'Fabric refused the Azure CLI''s token for rayfin up: HTTP 401 Unauthorized' -Evidence ([ordered]@{ tokenRefused = $true; refusal = 'HTTP 401 Unauthorized' }))
                }
                @((& $pass 'FABRIC.APP.DEPLOY' @{ itemId = $itemId; hostingUrl = $hosting; itemUrl = 'https://app.fabric.microsoft.com/groups/x/appbackends/y' }), (& $pass 'FABRIC.APP.STATUS'))
            }
            Mock -CommandName Test-DemoFabricApp -MockWith { @((& $pass 'FABRIC.APP.CONNECTOR'), (& $pass 'FABRIC.APP.QUERIES'), (& $pass 'FABRIC.APP.HOSTING')) }
            Mock -CommandName Connect-DemoRayfinCli -MockWith { throw 'No browser sign-in is expected here.' }
        }

        It 'deploys with the Rayfin CLI''s own sign-in when Fabric refuses the Azure CLI''s token, and FABRIC.APP.TOKEN says why' {
            $output = Join-Path -Path $TestDrive -ChildPath 'refused.jsonl'
            $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output -FabricToken $script:token 6>&1
            $LASTEXITCODE | Should -Be 0
            $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
            $tokenRecord = $records | Where-Object checkId -EQ 'FABRIC.APP.TOKEN'
            $tokenRecord.status | Should -Be 'Warning'
            $tokenRecord.message | Should -Match 'so the Rayfin CLI''s own sign-in deploys the app: HTTP 401 Unauthorized'
            $tokenRecord.evidence.fallback | Should -Be 'rayfinSignIn'
            $tokenRecord.evidence.signInNeeded | Should -BeFalse
            @($records | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY').Count | Should -Be 1 -Because 'the refused attempt''s record gives way to the deploy that ran'
            ($records | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY').status | Should -Be 'Pass'
            @($records | Where-Object checkId -EQ 'FABRIC.APP.SIGNIN').Count | Should -Be 1
            ($records | Where-Object checkId -EQ 'FABRIC.APP.SIGNIN').evidence.auth | Should -Be 'rayfinSignIn'
            Should -Invoke -CommandName Invoke-DemoFabricAppDeployment -Times 1 -Exactly -ParameterFilter { $null -ne $PesterBoundParameters['Token'] }
            Should -Invoke -CommandName Invoke-DemoFabricAppDeployment -Times 1 -Exactly -ParameterFilter { $null -eq $PesterBoundParameters['Token'] }
            Should -Invoke -CommandName Connect-DemoRayfinCli -Times 0 -Exactly
        }

        It 'deploys nothing and says why, without failing, when Fabric refuses the token and the Rayfin CLI isn''t signed in; -SignIn signs it in and deploys' {
            $ownSignIn = 'Manual action required'
            $output = Join-Path -Path $TestDrive -ChildPath 'refused-no-signin.jsonl'
            $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output -FabricToken $script:token 6>&1
            $LASTEXITCODE | Should -Be 0
            $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
            $tokenRecord = $records | Where-Object checkId -EQ 'FABRIC.APP.TOKEN'
            $tokenRecord.status | Should -Be 'Warning'
            $tokenRecord.message | Should -Match 'and the Rayfin CLI isn''t signed in to the demo''s tenant, so the app wasn''t deployed: HTTP 401 Unauthorized'
            $tokenRecord.evidence.signInNeeded | Should -BeTrue
            $tokenRecord.remediation | Should -Match ([regex]::Escape('./scripts/configure-fabric-app.ps1 -SignIn'))
            $deploy = $records | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY'
            $deploy.status | Should -Be 'Not selected'
            $deploy.evidence.signInNeeded | Should -BeTrue
            $signIn = $records | Where-Object checkId -EQ 'FABRIC.APP.SIGNIN'
            $signIn.status | Should -Be 'Manual action required'
            $signIn.message | Should -Match '^Fabric refused the Azure CLI''s token \(FABRIC\.APP\.TOKEN\), and the Rayfin CLI isn''t signed in' -Because 'the app''s summary leads with this record'
            @($records | Where-Object { $_.status -eq 'Fail' }) | Should -BeNullOrEmpty
            Should -Invoke -CommandName Test-DemoFabricApp -Times 0 -Exactly
            Should -Invoke -CommandName Connect-DemoRayfinCli -Times 0 -Exactly -Because 'only -SignIn opens a browser'

            $pass = $script:passResult
            Mock -CommandName Connect-DemoRayfinCli -MockWith { & $pass 'FABRIC.APP.SIGNIN' @{ auth = 'rayfinSignIn' } }
            $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output -FabricToken $script:token -SignIn 6>&1
            $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
            ($records | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY').status | Should -Be 'Pass'
            ($records | Where-Object checkId -EQ 'FABRIC.APP.TOKEN').evidence.fallback | Should -Be 'rayfinSignIn'
            Should -Invoke -CommandName Connect-DemoRayfinCli -Times 1 -Exactly
        }

        It 'uses only the Rayfin CLI''s own sign-in with -RayfinSignIn, as before' {
            $output = Join-Path -Path $TestDrive -ChildPath 'rayfin-signin.jsonl'
            $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output -FabricToken $script:token -RayfinSignIn 6>&1
            $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
            ($records | Where-Object checkId -EQ 'FABRIC.APP.DEPLOY').status | Should -Be 'Pass'
            $records.checkId | Should -Not -Contain 'FABRIC.APP.TOKEN'
            Should -Invoke -CommandName Test-DemoFabricAppPrerequisite -Times 1 -Exactly -ParameterFilter { -not $UseAzureCliToken }
            Should -Invoke -CommandName Invoke-DemoFabricAppDeployment -Times 1 -Exactly -ParameterFilter { $null -eq $PesterBoundParameters['Token'] }
            Should -Invoke -CommandName Test-DemoFabricApp -Times 1 -Exactly -ParameterFilter { $null -eq $PesterBoundParameters['Token'] -and $RayfinSignIn }
        }

        It 'asks the Azure CLI for a Power BI token for the app''s queries after its own subscription guard, and goes on without one' {
            $pass = $script:passResult
            $testFabricToken = $script:token
            $testPowerBIToken = ConvertTo-HubSecureString ('pbi' + ('y' * 40))
            Mock -CommandName Assert-DemoAzContext -MockWith { & $pass 'PREFLIGHT.GUARD.CONTEXT' }
            Mock -CommandName Get-DemoFabricToken -MockWith { $testFabricToken }
            Mock -CommandName Get-DemoPowerBIToken -MockWith { $testPowerBIToken }
            Mock -CommandName Invoke-DemoFabricAppDeployment -MockWith { @((& $pass 'FABRIC.APP.DEPLOY' @{ itemId = $itemId; hostingUrl = $hosting }), (& $pass 'FABRIC.APP.STATUS')) }
            $output = Join-Path -Path $TestDrive -ChildPath 'guarded.jsonl'
            $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output 6>&1
            $LASTEXITCODE | Should -Be 0
            Should -Invoke -CommandName Assert-DemoAzContext -Times 1 -Exactly
            Should -Invoke -CommandName Get-DemoPowerBIToken -Times 1 -Exactly
            Should -Invoke -CommandName Invoke-DemoFabricAppDeployment -Times 1 -Exactly -ParameterFilter { [object]::ReferenceEquals($PesterBoundParameters['Token'], $testFabricToken) }
            Should -Invoke -CommandName Test-DemoFabricApp -Times 1 -Exactly -ParameterFilter { [object]::ReferenceEquals($PesterBoundParameters['Token'], $testPowerBIToken) }
            # The workspace and model for Execute Queries, and the deploy that just ran, for the browser check's note (2026-11-09).
            Should -Invoke -CommandName Test-DemoFabricApp -Times 1 -Exactly -ParameterFilter { $WorkspaceId -eq $script:workspaceId -and $SemanticModelId -eq $script:modelId -and $Deployed -and -not $RayfinSignIn }

            Mock -CommandName Get-DemoPowerBIToken -MockWith { throw 'az account get-access-token failed.' }
            $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output 6>&1
            $LASTEXITCODE | Should -Be 0
            Should -Invoke -CommandName Test-DemoFabricApp -Times 1 -Exactly -ParameterFilter { $null -eq $PesterBoundParameters['Token'] -and -not $RayfinSignIn }
        }

        It 'adds no FABRIC.APP.TOKEN and opens no browser when only the connector''s direct route refused the token: Execute Queries checked the app and proves its tenant setting (2026-11-09 live finding)' {
            $pass = $script:passResult
            $testFabricToken = $script:token
            $testPowerBIToken = ConvertTo-HubSecureString ('pbi' + ('y' * 40))
            Mock -CommandName Assert-DemoAzContext -MockWith { & $pass 'PREFLIGHT.GUARD.CONTEXT' }
            Mock -CommandName Get-DemoFabricToken -MockWith { $testFabricToken }
            Mock -CommandName Get-DemoPowerBIToken -MockWith { $testPowerBIToken }
            Mock -CommandName Test-DemoFabricAppPrerequisite -MockWith {
                @((& $pass 'FABRIC.APP.NODE'), (& $pass 'FABRIC.APP.SIGNIN' @{ auth = 'azureCli' }), (New-DemoResult -CheckId 'FABRIC.APP.EXECUTEQUERIES' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'Confirm it.'))
            }
            # rayfin up took the Azure CLI's token; only the connector's direct route refused the Power BI one.
            Mock -CommandName Invoke-DemoFabricAppDeployment -MockWith { @((& $pass 'FABRIC.APP.DEPLOY' @{ itemId = $itemId; hostingUrl = $hosting; auth = 'azureCli' }), (& $pass 'FABRIC.APP.STATUS')) }
            Mock -CommandName Test-DemoFabricApp -MockWith {
                @((& $pass 'FABRIC.APP.CONNECTOR' @{ route = 'executeQueries'; auth = 'azureCli'; connectorRefusal = 'Request failed with status code 401' }), (& $pass 'FABRIC.APP.QUERIES' @{ route = 'executeQueries' }), (& $pass 'FABRIC.APP.HOSTING'), (New-DemoResult -CheckId 'FABRIC.APP.BROWSER' -Area 'fabric' -Target 'fabric' -Status 'Not selected' -Message 'Not needed: ...'))
            }
            $output = Join-Path -Path $TestDrive -ChildPath 'connector-refused.jsonl'
            $null = & $script:configureApp -ConfigPath (New-TestConfigFile) -OutputPath $output 6>&1
            $LASTEXITCODE | Should -Be 0
            $records = @(Get-Content -LiteralPath $output | ConvertFrom-Json)
            $records.checkId | Should -Not -Contain 'FABRIC.APP.TOKEN'
            @($records | Where-Object { $_.checkId -like 'FABRIC.APP.*' -and $_.status -in 'Fail', 'Manual action required' }) | Should -BeNullOrEmpty
            ($records | Where-Object checkId -EQ 'FABRIC.APP.EXECUTEQUERIES').status | Should -Be 'Pass' -Because 'Execute Queries is the API that setting gates'
            Should -Invoke -CommandName Invoke-DemoFabricAppDeployment -Times 1 -Exactly
            Should -Invoke -CommandName Connect-DemoRayfinCli -Times 0 -Exactly
        }
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
        $config['fabric']['workspaceName'] = 'Database Hub Demo test'
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
