BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    # Dot-sourcing defines the host bootstrap's functions, GuestSetup.ps1's included (and imports DbHubDemo.Vm), without
    # running it.
    . (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Invoke-HostBootstrap.ps1')

    function New-TestHostContext {
        $root = Join-Path -Path $TestDrive -ChildPath ('host-' + [guid]::NewGuid().ToString('N'))
        Initialize-DemoVmContext -Root $root -Role 'ArcHost' -BundleRoot $repoRoot | Out-Null
        $settings = [ordered]@{ role = 'ArcHost'; t2SqlInstallMode = 'PaygWizard'; seedScale = 1; guest = [ordered]@{ name = 'arcsql01'; vcpus = 2; memoryGiB = 8; vhdxGB = 64 } }
        Get-DemoHostContext -StateRoot $root -BundleRoot $repoRoot -Settings $settings
    }

    function Write-TestRequest {
        param([System.Collections.IDictionary] $Context, [datetime] $ExpiresUtc)
        $path = Get-DemoGuidedSetupPath -Root $Context.Root
        $request = [ordered]@{ schemaVersion = 1; requestId = 'request-0001'; expiresUtc = $ExpiresUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [System.Globalization.CultureInfo]::InvariantCulture); subscriptionId = '11111111-2222-3333-4444-555555555555'; resourceGroup = 'rg-dbhub-demo'; region = 'westus3'; tenantId = '66666666-7777-8888-9999-000000000000' }
        Write-DemoVmJsonFile -Path $path.HostRequest -InputObject $request
    }

    function New-TestCredential {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in 'not-a-real-secret'.ToCharArray()) { $secure.AppendChar($character) }
        [System.Management.Automation.PSCredential]::new('Administrator', $secure)
    }

    function New-TestAutoLogonState([bool] $On) {
        [pscustomobject]@{ autoAdminLogon = $On; autoLogonCount = $On; defaultUserName = $On; defaultPassword = $false; lsaSecret = $On }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo.Vm -ErrorAction SilentlyContinue
}

Describe 'The guided stop''s setup configuration file (Phase 28, brief item 5)' {
    BeforeAll {
        $sql = @{ Features = 'SQLENGINE'; InstanceName = 'MSSQLSERVER'; ServiceAccount = 'NT Service\MSSQLSERVER'; AgentAccount = 'NT Service\SQLSERVERAGENT'; SysAdminAccounts = 'BUILTIN\Administrators' }
    }

    It 'pre-fills every page documented parameters allow, in the wizard (UIMODE Normal), and holds no secret' {
        $text = Get-DemoGuidedSetupConfigurationText -Sql $sql -Azure @{ SubscriptionId = '11111111-2222-3333-4444-555555555555'; ResourceGroup = 'rg-dbhub-demo'; Region = 'westus3'; TenantId = '66666666-7777-8888-9999-000000000000' }
        $text | Should -Match '(?m)^\[OPTIONS\]\r?$'
        $text | Should -Match '(?m)^ACTION="Install"\r?$'
        $text | Should -Match '(?m)^UIMODE="Normal"\r?$'
        $text | Should -Match '(?m)^FEATURES=SQLENGINE,AZUREEXTENSION\r?$'
        $text | Should -Match '(?m)^INSTANCENAME="MSSQLSERVER"\r?$'
        $text | Should -Match '(?m)^SQLSYSADMINACCOUNTS="BUILTIN\\Administrators"\r?$'
        $text | Should -Match '(?m)^AZURESUBSCRIPTIONID="11111111-2222-3333-4444-555555555555"\r?$'
        $text | Should -Match '(?m)^AZURERESOURCEGROUP="rg-dbhub-demo"\r?$'
        $text | Should -Match '(?m)^AZUREREGION="westus3"\r?$'
        $text | Should -Not -Match '(?im)^\s*(PID|[A-Z]*PASSWORD|AZURESERVICEPRINCIPAL[A-Z]*|IACCEPTSQLSERVERLICENSETERMS|QUIET[A-Z]*)\s*='
    }

    It 'leaves out an Azure value that isn''t valid, and refuses a value the file can''t hold' {
        $text = Get-DemoGuidedSetupConfigurationText -Sql $sql -Azure @{ SubscriptionId = 'not-a-guid'; Region = 'West US 3' }
        $text | Should -Not -Match 'AZURESUBSCRIPTIONID'
        $text | Should -Not -Match 'AZUREREGION'
        $bad = $sql.Clone()
        $bad['InstanceName'] = 'MSSQL"SERVER'
        { Get-DemoGuidedSetupConfigurationText -Sql $bad } | Should -Throw '*can''t hold*'
    }

    It 'opens setup from a launcher that first clears the automatic sign-in that started the session' {
        $path = Get-DemoGuidedSetupPath -Root (Join-Path -Path $TestDrive -ChildPath 'launcher')
        $launcher = Get-DemoGuidedSetupLauncherText -IsoPath 'C:\DbHubDemo\media\SQLServer2022-x64-ENU.iso' -Path $path
        $launcher | Should -Match 'function Invoke-DemoGuestAutoLogonAction'
        $launcher | Should -Match 'Invoke-DemoGuestAutoLogonAction -Action Clear'
        $launcher | Should -Match ([regex]::Escape('/ConfigurationFile='))
        $launcher.IndexOf('Invoke-DemoGuestAutoLogonAction -Action Clear') | Should -BeLessThan $launcher.IndexOf('/ConfigurationFile=')
        # What setup's sign-in will meet, in the guest's log: IE ESC is read as setup starts (Phase 28 live finding).
        $launcher | Should -Match 'IE Enhanced Security Configuration for administrators as setup starts'
        $launcher.IndexOf('as setup starts') | Should -BeLessThan $launcher.IndexOf('/ConfigurationFile=')
        { Get-DemoGuidedSetupLauncherText -IsoPath "C:\media\it's.iso" -Path $path } | Should -Throw
    }
}

Describe 'Automatic sign-in: kept only as the LSA secret, and always cleaned up (Phase 28, brief item 12)' {
    It 'arms with the LSA secret and AutoLogonCount 1, never the Winlogon DefaultPassword value' {
        $body = ${function:Invoke-DemoGuestAutoLogonAction}.ToString()
        $body | Should -Match "Store\('DefaultPassword', \`$Password\)"
        $body | Should -Match "Remove-ItemProperty -LiteralPath \`$winlogon -Name 'DefaultPassword'"
        $body | Should -Match "-Name 'AutoLogonCount' -PropertyType DWord -Value 1"
        $body | Should -Not -Match "Set-ItemProperty -LiteralPath \`$winlogon -Name 'DefaultPassword'"
        $body | Should -Match 'LsaStorePrivateData'
    }

    It 'counts automatic sign-in as clear only when nothing is left' {
        Test-DemoAutoLogonClear -State (New-TestAutoLogonState $false) | Should -BeTrue
        Test-DemoAutoLogonClear -State $null | Should -BeFalse
        foreach ($name in 'autoAdminLogon', 'autoLogonCount', 'defaultUserName', 'defaultPassword', 'lsaSecret') {
            $state = New-TestAutoLogonState $false
            $state.$name = $true
            Test-DemoAutoLogonClear -State $state | Should -BeFalse -Because $name
        }
    }

    Context 'the cleanup' {
        BeforeEach {
            $context = New-TestHostContext
            $script:path = Get-DemoGuidedSetupPath -Root $context.Root
            Save-DemoGuidedSetupArmed -Path $script:path -Value @{ schemaVersion = 1; requestId = 'request-0001'; arms = 1; armedUtc = '2026-10-29T15:00:00Z'; okSinceUtc = ''; lastLaunchUtc = '' }
            $script:order = [System.Collections.Generic.List[string]]::new()
            $script:after = New-TestAutoLogonState $false
            Mock -CommandName Get-DemoGuestCredential -MockWith { New-TestCredential }
            Mock -CommandName Invoke-DemoGuestSignOut -MockWith { $script:order.Add('signout'); 1 }
            Mock -CommandName Start-Sleep -MockWith { }
            Mock -CommandName Invoke-Command -MockWith {
                $action = @($ArgumentList)[0]
                $script:order.Add([string]$action)
                [pscustomobject]@{ action = $action; before = (New-TestAutoLogonState $true); after = $script:after }
            }
            Mock -CommandName Update-DemoGuestSecret -MockWith { $script:order.Add('rotate') }
            # Setup's sign-in preparation goes back last (Phase 28 live finding); its own tests are further down.
            Mock -CommandName Restore-DemoHostGuidedSignIn -MockWith { $script:order.Add('restore browser') }
        }

        It 'signs out, turns it off and deletes the secret and the values, rotates the password, checks, and drops the record' {
            Disable-DemoHostGuestAutoLogon -Context $context -Reason 'Installed'
            $script:order | Should -Be @('signout', 'Clear', 'rotate', 'Read', 'restore browser')
            Test-Path -LiteralPath $script:path.HostArmed | Should -BeFalse
            $last = Read-DemoVmJsonFile -Path $script:path.HostLast
            $last['reason'] | Should -Be 'Installed'
            @($last['found']) | Should -Contain 'lsaSecret'
            @($last['problems']).Count | Should -Be 0
        }

        It 'runs on a failure or a timeout too, and fails closed, keeping the record, when anything is left' {
            foreach ($reason in 'Expired', 'NoRequest') {
                Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = 'request-0001'; arms = 1 }
                Disable-DemoHostGuestAutoLogon -Context $context -Reason $reason
                (Read-DemoVmJsonFile -Path $script:path.HostLast)['reason'] | Should -Be $reason
            }
            Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = 'request-0001'; arms = 1 }
            $script:after = New-TestAutoLogonState $true
            { Disable-DemoHostGuestAutoLogon -Context $context -Reason 'Expired' } | Should -Throw '*fail closed*'
            Test-Path -LiteralPath $script:path.HostArmed | Should -BeTrue -Because 'the next pass cleans up again'
            Mock -CommandName Update-DemoGuestSecret -MockWith { throw 'the guest is off' }
            $script:after = New-TestAutoLogonState $false
            { Disable-DemoHostGuestAutoLogon -Context $context -Reason 'Retry' } | Should -Throw '*rotating the guest password*'
            Test-Path -LiteralPath $script:path.HostArmed | Should -BeTrue
        }

        It 'runs before every pass of the host when nobody is expected any more, and never while deploy.ps1 waits' {
            Mock -CommandName Disable-DemoHostGuestAutoLogon -MockWith { $script:order.Add('disable ' + $Reason) }
            Mock -CommandName Resolve-DemoGuestPendingSecret -MockWith { }
            Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(30))
            Invoke-DemoHostGuidedSetupGuard -Context $context
            $script:order | Should -Not -Contain 'disable Expired'
            Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(-1))
            Invoke-DemoHostGuidedSetupGuard -Context $context
            $script:order | Should -Contain 'disable Expired'
            Remove-Item -LiteralPath $script:path.HostRequest
            Invoke-DemoHostGuidedSetupGuard -Context $context
            $script:order | Should -Contain 'disable NoRequest'
        }
    }
}

Describe 'The SqlSetupWizard step with the guided stop (Phase 28, brief items 5 and 6)' {
    BeforeEach {
        $context = New-TestHostContext
        $script:path = Get-DemoGuidedSetupPath -Root $context.Root
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:check = [pscustomobject]@{ Ok = $false; Problem = 'NotInstalled'; SetupRunning = $false; Message = 'SQL Server isn''t installed in arcsql01 yet.'; Fix = @() }
        $script:session = $false
        Mock -CommandName Get-DemoHostSetupCheck -MockWith { $script:check }
        Mock -CommandName Get-DemoGuestCredential -MockWith { New-TestCredential }
        Mock -CommandName Test-DemoGuestConsoleSession -MockWith { $script:session }
        Mock -CommandName Invoke-Command -MockWith { $script:calls.Add('start setup') }
        Mock -CommandName Enable-DemoHostGuestAutoLogon -MockWith { $script:calls.Add(('arm {0}' -f $Arms)); Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = $RequestId; arms = $Arms } }
        Mock -CommandName Disable-DemoHostGuestAutoLogon -MockWith { $script:calls.Add('disable ' + $Reason); Remove-Item -LiteralPath $script:path.HostArmed -ErrorAction SilentlyContinue }
        Mock -CommandName Remove-DemoHostGuidedSetup -MockWith { $script:calls.Add('remove tasks') }
        # Setup's sign-in is ready here; its own tests are in the next Describe.
        Mock -CommandName Initialize-DemoHostGuidedSignIn -MockWith { }
    }

    It 'waits for deploy.ps1 when no person is expected, and tells the person to run it' {
        $result = Invoke-DemoHostGuidedSetupStep -Context $context
        $result.Outcome | Should -Be 'ManualActionRequired'
        $result.Message | Should -Match 'run \./scripts/deploy\.ps1'
        $script:calls.Count | Should -Be 0
    }

    It 'arms one automatic sign-in while deploy.ps1 waits, retries a few times, then gives the manual way' {
        Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(45))
        (Invoke-DemoHostGuidedSetupStep -Context $context).Message | Should -Match 'signs itself in once'
        $script:calls | Should -Be @('arm 1')
        Invoke-DemoHostGuidedSetupStep -Context $context | Out-Null
        $script:calls | Should -Be @('arm 1', 'disable Retry', 'arm 2')
        Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = 'request-0001'; arms = 3 }
        $manual = Invoke-DemoHostGuidedSetupStep -Context $context
        $manual.Message | Should -Match 'Copy-GuestCredential\.ps1'
        $script:calls[-1] | Should -Be 'arm 2' -Because 'it never arms more than three times'
    }

    It 'opens setup in a session that''s already signed in, without arming anything' {
        Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(45))
        $script:session = $true
        (Invoke-DemoHostGuidedSetupStep -Context $context).Message | Should -Match 'setup opens there now'
        $script:calls | Should -Be @('start setup')
    }

    It 'shows the documented fix for a wrong install and keeps waiting, without onboarding it' {
        Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(45))
        $script:session = $true
        $script:check = [pscustomobject]@{ Ok = $false; Problem = 'Edition'; SetupRunning = $false; Message = 'SQL Server in arcsql01 is Developer Edition (64-bit); the demo needs Standard with pay-as-you-go.'; Fix = @('Select Maintenance > Edition Upgrade.') }
        $result = Invoke-DemoHostGuidedSetupStep -Context $context
        $result.Outcome | Should -Be 'ManualActionRequired'
        $result.Message | Should -Match 'Fix: Select Maintenance > Edition Upgrade'
    }

    It 'cleans up once the right instance is installed, after setup closes' {
        Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(45))
        Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = 'request-0001'; arms = 1 }
        $script:check = [pscustomobject]@{ Ok = $true; Problem = ''; SetupRunning = $false; Message = 'SQL Server Standard runs in arcsql01 as the default instance, with the Azure extension.'; Fix = @() }
        Invoke-DemoHostGuidedSetupStep -Context $context
        $script:calls | Should -Be @('disable Installed', 'remove tasks')
    }

}

Describe 'Setup''s Azure sign-in: prepared before anyone is asked, restored after (Phase 28 live finding, 2026-10-30)' {
    # Live, setup's Use Azure Login opened in an IE-based control, and IE Enhanced Security Configuration blocked
    # login.microsoftonline.com, though the GuestWebView2 step had succeeded; turning IE ESC off while setup was open
    # didn't reach setup.

    It 'refuses a name the zone map can''t hold, before it changes anything' {
        { Invoke-DemoGuestSignInBrowserAction -Action Prepare -SignInHost @('login') -ActiveSetupRoot 'TestRegistry:\none' -UserRoot 'TestRegistry:\none' } | Should -Throw '*zone map*'
        @(Get-DemoGuidedSignInHost) | Should -Contain 'login.microsoftonline.com'
        @(Get-DemoGuidedSignInHost | Where-Object { $_ -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+){2}$' }).Count | Should -Be 0 -Because 'each is an exact host, a domain and one subkey'
    }

    Context 'in the guest''s registry' -Skip:(-not $IsWindows) {
        BeforeEach {
            $script:as = 'TestRegistry:\as'
            $script:user = 'TestRegistry:\user'
            $script:zone = 'TestRegistry:\user\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap'
            Remove-Item -LiteralPath $script:as, $script:user -Recurse -Force -ErrorAction SilentlyContinue
            foreach ($id in '{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}', '{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}') {
                New-Item -Path ('{0}\{1}' -f $script:as, $id) -Force | Out-Null
                New-ItemProperty -LiteralPath ('{0}\{1}' -f $script:as, $id) -Name 'IsInstalled' -PropertyType DWord -Value 1 -Force | Out-Null
            }
            # What was there before the guided stop: a site the person trusts, and an empty domain key.
            New-Item -Path ('{0}\Domains\contoso.com\www' -f $script:zone) -Force | Out-Null
            New-ItemProperty -LiteralPath ('{0}\Domains\contoso.com\www' -f $script:zone) -Name 'https' -PropertyType DWord -Value 2 -Force | Out-Null
            New-Item -Path ('{0}\EscDomains\microsoftonline.com' -f $script:zone) -Force | Out-Null
            $script:hosts = @(Get-DemoGuidedSignInHost)
        }

        It 'turns IE ESC off for administrators only, trusts each sign-in host under Domains and EscDomains, and keeps the first snapshot' {
            $state = Invoke-DemoGuestSignInBrowserAction -Action Prepare -SignInHost $script:hosts -ActiveSetupRoot $script:as -UserRoot $script:user
            $state.ieEscAdmin | Should -Be 0
            $state.ieEscUsers | Should -Be 1
            @($state.hostsMapped) | Should -Be $script:hosts
            foreach ($map in 'Domains', 'EscDomains') {
                $key = '{0}\{1}\microsoftonline.com\login' -f $script:zone, $map
                (Get-ItemProperty -LiteralPath $key -Name 'https').https | Should -Be 2
                (Get-Item -LiteralPath $key).GetValueKind('https') | Should -Be 'DWord'
            }
            $snapshot = $state.snapshotJson | ConvertFrom-Json
            @($snapshot.valueList) | Should -Be @('Domains\contoso.com\www|https=2')
            @($snapshot.keyList) | Should -Contain 'EscDomains\microsoftonline.com'
            @($snapshot.keyList) | Should -Not -Contain 'EscDomains\microsoftonline.com\login'
            $again = Invoke-DemoGuestSignInBrowserAction -Action Prepare -SignInHost $script:hosts -SnapshotJson $state.snapshotJson -ActiveSetupRoot $script:as -UserRoot $script:user
            $again.snapshotJson | Should -Be $state.snapshotJson -Because 'a second pass keeps what was there before the guided stop'
            $again.changed | Should -Be 0
        }

        It 'turns IE ESC back on for administrators and users, and puts the entries back as they were, the dialog''s Add... included' {
            $state = Invoke-DemoGuestSignInBrowserAction -Action Prepare -SignInHost $script:hosts -ActiveSetupRoot $script:as -UserRoot $script:user
            # Meanwhile: Add... in setup's dialog (IE ESC on, so EscDomains), users' IE ESC off in Server Manager, and a
            # site that was there changed.
            New-Item -Path ('{0}\EscDomains\example.net\sso' -f $script:zone) -Force | Out-Null
            New-ItemProperty -LiteralPath ('{0}\EscDomains\example.net\sso' -f $script:zone) -Name 'https' -PropertyType DWord -Value 2 -Force | Out-Null
            Set-ItemProperty -LiteralPath ('{0}\Domains\contoso.com\www' -f $script:zone) -Name 'https' -Value 4
            Set-ItemProperty -LiteralPath ($script:as + '\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}') -Name 'IsInstalled' -Value 0
            $restored = Invoke-DemoGuestSignInBrowserAction -Action Restore -SignInHost $script:hosts -SnapshotJson $state.snapshotJson -ActiveSetupRoot $script:as -UserRoot $script:user
            $restored.restored | Should -BeTrue
            $restored.ieEscAdmin | Should -Be 1
            $restored.ieEscUsers | Should -Be 1
            @($restored.hostsMapped).Count | Should -Be 0
            Test-Path -LiteralPath ('{0}\EscDomains\example.net' -f $script:zone) | Should -BeFalse
            Test-Path -LiteralPath ('{0}\Domains\microsoftonline.com' -f $script:zone) | Should -BeFalse
            Test-Path -LiteralPath ('{0}\EscDomains\microsoftonline.com' -f $script:zone) | Should -BeTrue -Because 'it was there before, empty'
            Test-Path -LiteralPath ('{0}\EscDomains\microsoftonline.com\login' -f $script:zone) | Should -BeFalse
            (Get-ItemProperty -LiteralPath ('{0}\Domains\contoso.com\www' -f $script:zone) -Name 'https').https | Should -Be 2
        }

        It 'takes out only the sign-in hosts when there''s no snapshot' {
            $null = Invoke-DemoGuestSignInBrowserAction -Action Prepare -SignInHost $script:hosts -ActiveSetupRoot $script:as -UserRoot $script:user
            New-Item -Path ('{0}\EscDomains\example.net\sso' -f $script:zone) -Force | Out-Null
            New-ItemProperty -LiteralPath ('{0}\EscDomains\example.net\sso' -f $script:zone) -Name 'https' -PropertyType DWord -Value 2 -Force | Out-Null
            $restored = Invoke-DemoGuestSignInBrowserAction -Action Restore -SignInHost $script:hosts -ActiveSetupRoot $script:as -UserRoot $script:user
            $restored.restored | Should -BeTrue
            $restored.ieEscAdmin | Should -Be 1
            @($restored.hostsMapped).Count | Should -Be 0
            Test-Path -LiteralPath ('{0}\EscDomains\example.net\sso' -f $script:zone) | Should -BeTrue -Because 'without a snapshot it can''t tell that from a site trusted before'
            (Get-ItemProperty -LiteralPath ('{0}\Domains\contoso.com\www' -f $script:zone) -Name 'https').https | Should -Be 2
        }

        It 'leaves no key it created, the map keys included' {
            Remove-Item -LiteralPath ('{0}\EscDomains' -f $script:zone) -Recurse -Force
            $state = Invoke-DemoGuestSignInBrowserAction -Action Prepare -SignInHost $script:hosts -ActiveSetupRoot $script:as -UserRoot $script:user
            Test-Path -LiteralPath ('{0}\EscDomains\microsoftonline.com\login' -f $script:zone) | Should -BeTrue
            $restored = Invoke-DemoGuestSignInBrowserAction -Action Restore -SignInHost $script:hosts -SnapshotJson $state.snapshotJson -ActiveSetupRoot $script:as -UserRoot $script:user
            $restored.restored | Should -BeTrue
            Test-Path -LiteralPath ('{0}\EscDomains' -f $script:zone) | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:zone -Recurse | ForEach-Object { $_.PSChildName }) | Should -Be @('Domains', 'contoso.com', 'www')
        }
    }

    Context 'on the host' {
        BeforeEach {
            $context = New-TestHostContext
            $script:path = Get-DemoGuidedSetupPath -Root $context.Root
            $script:order = [System.Collections.Generic.List[string]]::new()
            $script:webView2 = $true
            $script:escAdmin = 0
            $script:restored = $true
            $script:lastSnapshot = $null
            Mock -CommandName Get-DemoGuestCredential -MockWith { New-TestCredential }
            Mock -CommandName Get-DemoHostSetupCheck -MockWith { [pscustomobject]@{ Ok = $false; Problem = 'NotInstalled'; SetupRunning = $false; Message = 'SQL Server isn''t installed in arcsql01 yet.'; Fix = @() } }
            Mock -CommandName Test-DemoGuestConsoleSession -MockWith { $false }
            Mock -CommandName Enable-DemoHostGuestAutoLogon -MockWith { $script:order.Add('arm') }
            Mock -CommandName Test-DemoGuestWebView2 -MockWith { $script:order.Add('check WebView2'); $script:webView2 }
            Mock -CommandName Test-DemoHostGuestWebView2 -MockWith { $script:order.Add('check WebView2 again'); $script:webView2 }
            Mock -CommandName Install-DemoHostGuestWebView2 -MockWith { $script:order.Add('install WebView2'); $script:webView2 = $true }
            Mock -CommandName Invoke-Command -MockWith {
                $arguments = @($PesterBoundParameters['ArgumentList'])
                if ($arguments.Count -eq 0 -or $null -eq $arguments[0]) {
                    $script:order.Add('start setup')
                    return
                }
                $action = [string]$arguments[0]
                $script:order.Add('guest ' + $action)
                $script:lastSnapshot = [string]$arguments[3]
                $restore = $action -eq 'Restore'
                [pscustomobject]@{
                    action       = $action
                    ieEscAdmin   = $(if ($restore) { $(if ($script:restored) { 1 } else { 0 }) } else { $script:escAdmin })
                    ieEscUsers   = 1
                    hive         = 'Loaded'
                    hostsMapped  = $(if ($restore) { @() } else { @(Get-DemoGuidedSignInHost) })
                    snapshotJson = '{"keyList":[],"valueList":[]}'
                    changed      = 16
                    restored     = ($restore -and $script:restored)
                }
            }
        }

        It 'installs a missing WebView2 runtime, turns IE ESC off and trusts the sign-in hosts, records it, and only then arms the guest''s sign-in' {
            Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(45))
            $script:webView2 = $false
            $result = Invoke-DemoHostGuidedSetupStep -Context $context
            $result.Outcome | Should -Be 'ManualActionRequired'
            $script:order | Should -Be @('check WebView2', 'install WebView2', 'check WebView2 again', 'guest Prepare', 'arm')
            $record = Read-DemoVmJsonFile -Path $script:path.HostSignIn
            $record['state'] | Should -Be 'Ready'
            $record['snapshot'] | Should -Be '{"keyList":[],"valueList":[]}'
            (Get-DemoHostGuidedSetupDetail -Context $context).signIn | Should -Be 'ready'

            # The next pass, in the session the automatic sign-in opened: the same snapshot goes back to the guest, and
            # setup opens there.
            $script:order.Clear()
            Mock -CommandName Test-DemoGuestConsoleSession -MockWith { $true }
            Invoke-DemoHostGuidedSetupStep -Context $context | Out-Null
            $script:order | Should -Be @('check WebView2', 'guest Prepare', 'start setup')
            $script:lastSnapshot | Should -Be '{"keyList":[],"valueList":[]}'
        }

        It 'asks nobody while a prerequisite is missing: no arm, no setup, and the step says it''s Azure-side preparation' {
            Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(45))
            Mock -CommandName Test-DemoGuestConsoleSession -MockWith { $true }
            $script:webView2 = $false
            Mock -CommandName Install-DemoHostGuestWebView2 -MockWith { $script:order.Add('install WebView2'); throw 'The WebView2 runtime installer is not validly signed by Microsoft; it was deleted (fail closed).' }
            $result = Invoke-DemoHostGuidedSetupStep -Context $context
            $result.Outcome | Should -Be 'InProgress'
            $result.Message | Should -Match 'Azure-side, no action needed'
            $result.Message | Should -Match 'WebView2 runtime isn''t installed'
            $script:order | Should -Not -Contain 'guest Prepare'
            $script:order | Should -Not -Contain 'start setup'
            $script:order | Should -Not -Contain 'arm'
            (Get-DemoHostGuidedSetupDetail -Context $context).signIn | Should -Be 'none'

            # WebView2 is there, but IE ESC is still on for administrators: still nobody is asked.
            $script:order.Clear()
            $script:webView2 = $true
            $script:escAdmin = 1
            $result = Invoke-DemoHostGuidedSetupStep -Context $context
            $result.Outcome | Should -Be 'InProgress'
            $result.Message | Should -Match 'Enhanced Security Configuration is still on for administrators'
            $script:order | Should -Be @('check WebView2', 'guest Prepare')
            (Get-DemoHostGuidedSetupDetail -Context $context).signIn | Should -Be 'preparing'

            # A guest that can't be asked: no install attempt, and nobody is asked.
            $script:order.Clear()
            Mock -CommandName Test-DemoGuestWebView2 -MockWith { throw 'The virtual machine is not running.' }
            (Invoke-DemoHostGuidedSetupStep -Context $context).Outcome | Should -Be 'InProgress'
            $script:order.Count | Should -Be 0
        }

        It 'restores IE ESC and the Trusted sites in the cleanup after success, failure, and timeout, but not between two arms' {
            Mock -CommandName Invoke-DemoGuestSignOut -MockWith { 1 }
            Mock -CommandName Start-Sleep -MockWith { }
            Mock -CommandName Update-DemoGuestSecret -MockWith { }
            Mock -CommandName Invoke-Command -MockWith { [pscustomobject]@{ action = 'Clear'; before = (New-TestAutoLogonState $false); after = (New-TestAutoLogonState $false) } }
            Mock -CommandName Restore-DemoHostGuidedSignIn -MockWith { $script:order.Add('restore') }
            foreach ($reason in 'Installed', 'Expired', 'NoRequest', 'Leftover') {
                Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = 'request-0001'; arms = 1 }
                Disable-DemoHostGuestAutoLogon -Context $context -Reason $reason
            }
            $script:order | Should -Be @('restore', 'restore', 'restore', 'restore')
            $script:order.Clear()
            Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = 'request-0001'; arms = 1 }
            Disable-DemoHostGuestAutoLogon -Context $context -Reason 'Retry'
            $script:order.Count | Should -Be 0 -Because 'the next arm''s sign-in needs them'

            # Fail closed: a restore that fails makes the cleanup throw, and keeps both records for the next pass.
            Save-DemoGuidedSetupArmed -Path $script:path -Value @{ requestId = 'request-0001'; arms = 1 }
            Save-DemoGuidedSignInRecord -Path $script:path -Value @{ schemaVersion = 1; state = 'Ready'; snapshot = '' }
            Mock -CommandName Restore-DemoHostGuidedSignIn -MockWith { throw 'IE Enhanced Security Configuration is still off.' }
            { Disable-DemoHostGuestAutoLogon -Context $context -Reason 'Installed' } | Should -Throw '*restoring IE Enhanced Security Configuration*'
            Test-Path -LiteralPath $script:path.HostArmed | Should -BeTrue
            Test-Path -LiteralPath $script:path.HostSignIn | Should -BeTrue
        }

        It 'drops its record only once the guest says it''s restored, and the setup step isn''t done before' {
            Save-DemoGuidedSignInRecord -Path $script:path -Value @{ schemaVersion = 1; state = 'Ready'; snapshot = '{"keyList":["Domains\\contoso.com"],"valueList":[]}' }
            Mock -CommandName Test-DemoHostSqlEdition -MockWith { $true }
            Test-DemoHostGuidedSetupDone -Context $context | Should -BeFalse -Because 'IE ESC may still be off'
            $script:restored = $false
            { Restore-DemoHostGuidedSignIn -Context $context } | Should -Throw '*fail closed*'
            (Read-DemoVmJsonFile -Path $script:path.HostSignIn)['state'] | Should -Be 'Restoring'
            (Get-DemoHostGuidedSetupDetail -Context $context).signIn | Should -Be 'restoring'
            $script:restored = $true
            Restore-DemoHostGuidedSignIn -Context $context
            $script:lastSnapshot | Should -Be '{"keyList":["Domains\\contoso.com"],"valueList":[]}' -Because 'the guest gets the snapshot from before the guided stop'
            Test-Path -LiteralPath $script:path.HostSignIn | Should -BeFalse
            Test-DemoHostGuidedSetupDone -Context $context | Should -BeTrue
        }

        It 'restores them when nothing is armed and nobody is expected any more, before a pass and in the step, never while deploy.ps1 waits' {
            Mock -CommandName Resolve-DemoGuestPendingSecret -MockWith { }
            Mock -CommandName Restore-DemoHostGuidedSignIn -MockWith { $script:order.Add('restore') }
            Mock -CommandName Disable-DemoHostGuestAutoLogon -MockWith { $script:order.Add('disable') }
            Save-DemoGuidedSignInRecord -Path $script:path -Value @{ schemaVersion = 1; state = 'Ready'; snapshot = '' }
            Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(30))
            Invoke-DemoHostGuidedSetupGuard -Context $context
            $script:order.Count | Should -Be 0
            Write-TestRequest -Context $context -ExpiresUtc ([DateTime]::UtcNow.AddMinutes(-1))
            Invoke-DemoHostGuidedSetupGuard -Context $context
            $script:order | Should -Be @('restore')
            $script:order.Clear()
            (Invoke-DemoHostGuidedSetupStep -Context $context).Outcome | Should -Be 'ManualActionRequired'
            $script:order | Should -Be @('restore')
        }

        It 'tells the person what to do when Internet Explorer still blocks the sign-in, and blames no missing WebView2' {
            $steps = (Get-DemoGuidedSetupStepText -GuestName 'arcsql01') -join ' '
            $steps | Should -Match 'Add\.\.\. for each site it names'
            $instructions = (Get-DemoPaygWizardInstruction -GuestName 'arcsql01') -join ' '
            $instructions | Should -Match 'Add\.\.\. for each site it names, then Use Azure Login again'
            $instructions | Should -Match 'Server Manager > Local Server'
            $instructions | Should -Match 'a change made while setup is open doesn''t reach it'
            $instructions | Should -Not -Match 'WebView2 runtime is missing'
        }

        It 'reports the preparation in the health summary deploy.ps1 reads' {
            $root = Join-Path -Path $TestDrive -ChildPath ('health-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $root -Force
            $health = [ordered]@{ schemaVersion = 1; state = 'ManualActionRequired'; currentStep = 'SqlSetupWizard'; message = 'The guest restarts.'; details = [ordered]@{ guidedSetup = [ordered]@{ armed = $true; request = 'valid'; signIn = 'ready'; lastReason = ''; lastProblems = @() } } }
            [System.IO.File]::WriteAllText((Join-Path -Path $root -ChildPath 'health.json'), (ConvertTo-Json -InputObject $health -Depth 6))
            $summary = (& (Join-Path -Path $repoRoot -ChildPath 'vm/health/Get-DemoHealth.ps1') -Root $root -View Summary) | ConvertFrom-Json
            $summary.guidedSignIn | Should -Be 'ready'
            $summary.guidedArmed | Should -BeTrue
        }
    }
}

Describe 'The host''s setup check (Get-DemoHostSetupCheck, brief item 6)' {
    It 'reads a wrong install from the guest: Developer edition, a named instance, or no Azure extension' {
        $context = New-TestHostContext
        Mock -CommandName Get-DemoGuestCredential -MockWith { New-TestCredential }
        Mock -CommandName Get-DemoGuestSetupFact -MockWith { [pscustomobject]@{ DefaultInstance = $script:default; NamedInstances = $script:named; SetupProcess = @(); Features = $script:features } }
        Mock -CommandName Get-DemoGuestSqlInstance -MockWith { [pscustomobject]@{ Running = $true; Edition = $script:edition; IsSysAdmin = $true; Error = '' } }
        $script:default = $true; $script:named = @(); $script:features = 'SQLENGINE,AZUREEXTENSION'; $script:edition = 'Developer Edition (64-bit)'
        $check = Get-DemoHostSetupCheck -Context $context
        $check.Problem | Should -Be 'Edition'
        ($check.Fix -join ' ') | Should -Match 'Edition Upgrade'
        $script:default = $false; $script:named = @('SQLEXPRESS')
        (Get-DemoHostSetupCheck -Context $context).Problem | Should -Be 'NamedInstance'
        $script:default = $true; $script:named = @(); $script:features = 'SQLENGINE'; $script:edition = 'Standard Edition (64-bit)'
        (Get-DemoHostSetupCheck -Context $context).Problem | Should -Be 'NoAzureExtension'
        $script:features = 'SQLENGINE,AZUREEXTENSION'
        (Get-DemoHostSetupCheck -Context $context).Ok | Should -BeTrue
    }
}

Describe 'deploy.ps1''s request on the host (vm/bootstrap/Set-DemoGuidedSetupRequest.ps1)' {
    It 'holds identifiers and an expiry, never a secret' {
        $text = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'vm/bootstrap/Set-DemoGuidedSetupRequest.ps1') -Raw
        $text | Should -Match 'param\('
        $text | Should -Not -Match '(?i)\[(string|securestring)\]\s*\$(Password|Secret|Token|ProductKey)'
        $text | Should -Match 'ExpiresUtc'
    }
}
