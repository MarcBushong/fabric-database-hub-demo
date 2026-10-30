BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force

    # A model as Start-DemoDeploymentRun writes it, at a fixed time, read back as nested hashtables as the page reads it.
    function New-TestModel {
        param([long] $Now = 1793000000, [string] $InstallMode = 'PaygWizard', [switch] $T4)
        InModuleScope DbHubDemo -Parameters @{ Now = $Now; Mode = $InstallMode; T4 = [bool]$T4 } {
            $catalog = Get-DemoProgressCatalog -InstallMode $Mode -T4Enabled:$T4
            $model = New-DemoProgressModel -Catalog $catalog -Environment 'demo' -ResourceGroup 'rg-dbhub-demo' -PagePath 'out/deploy-status.html' -Expect @{ text = 'A first deployment takes about 2 to 3 hours (estimate).'; humanText = 'about 60 to 90 minutes after the start, for about 10 minutes.'; guidedStop = $true } -GuidedStop 'Pending' -NowUnix $Now
            ConvertTo-Json -InputObject $model -Depth 20 | ConvertFrom-Json -AsHashtable -Depth 20
        }
    }

    function New-TestModelFile {
        param([long] $Now = 0)
        $path = Join-Path -Path $TestDrive -ChildPath ('progress-' + [guid]::NewGuid().ToString('N') + '.json')
        InModuleScope DbHubDemo -Parameters @{ Path = $path; Now = $Now } {
            $model = New-DemoProgressModel -Catalog (Get-DemoProgressCatalog -InstallMode 'PaygWizard') -Environment 'demo' -ResourceGroup 'rg-dbhub-demo' -GuidedStop 'Pending' -NowUnix $(if ($Now -gt 0) { $Now } else { Get-DemoUnixTime })
            Initialize-DemoProgress -Path $Path -Model $model -Confirm:$false
        }
        return $path
    }

    function Get-TestStep([System.Collections.IDictionary] $Model, [string] $Id) {
        foreach ($track in @($Model['tracks'])) {
            foreach ($item in @($track['steps'])) {
                if ($item['id'] -eq $Id) {
                    return $item
                }
            }
        }
        return $null
    }
}

Describe 'The progress model (Phase 28, brief item 11)' {
    It 'lists the steps per track in the brief''s order, with the guided stop and the setup check only in PaygWizard mode' {
        $model = New-TestModel -T4
        @($model['tracks'] | ForEach-Object { $_['name'] }) | Should -Be @('Preflight', 'Infrastructure', 'T1', 'T3', 'T4', 'Fabric', 'T2', 'Validation')
        $t2 = @(($model['tracks'] | Where-Object { $_['name'] -eq 'T2' })['steps'] | ForEach-Object { $_['id'] })
        $t2 | Should -Be @('T2.Restore', 'T2.Artifacts', 'T2.Bootstraps', 'T2.HostBuild', 'T2.GuidedStop', 'T2.SetupCheck', 'T2.SignInCleanup', 'T2.ArcOnboarding', 'T2.Monitoring', 'T2.Telemetry')
        $productKey = New-TestModel -InstallMode 'ProductKey'
        @(($productKey['tracks'] | Where-Object { $_['name'] -eq 'T2' })['steps'] | ForEach-Object { $_['id'] }) | Should -Not -Contain 'T2.GuidedStop'
        @($productKey['tracks'] | ForEach-Object { $_['name'] }) | Should -Not -Contain 'T4'
        # Phase 28 live finding: a rerun starts the VMs that were stopped first, and the page says so.
        @(($model['tracks'] | Where-Object { $_['name'] -eq 'Preflight' })['steps'] | ForEach-Object { $_['id'] }) | Should -Be @('StartVms', 'Preflight')
        (Get-TestStep -Model $model -Id 'StartVms')['label'] | Should -Match 'VMs that were stopped'
    }

    It 'marks the Insights app optional, and every step starts Pending' {
        $model = New-TestModel
        $app = Get-TestStep -Model $model -Id 'Fabric.App'
        $app['optional'] | Should -BeTrue
        $app['label'] | Should -Match 'optional'
        @($model['tracks'] | ForEach-Object { $_['steps'] } | Where-Object { $_['state'] -ne 'Pending' }).Count | Should -Be 0
        $model['run']['state'] | Should -Be 'Running'
        $model['guidedStop']['state'] | Should -Be 'Pending'
    }

    It 'maps each ADR 0012 status onto one friendly state, and keeps the status underneath' -ForEach @(
        @{ Status = 'Pass'; State = 'Done' }
        @{ Status = 'Warning'; State = 'Done' }
        @{ Status = 'Fail'; State = 'Failed' }
        @{ Status = 'Manual action required'; State = 'Action needed' }
        @{ Status = 'Not selected'; State = 'Skipped' }
        @{ Status = 'Not supported'; State = 'Skipped' }
        @{ Status = ''; State = 'Pending' }
    ) {
        InModuleScope DbHubDemo -Parameters @{ Status = $Status } { ConvertTo-DemoProgressState -Status $Status } | Should -Be $State
    }

    It 'picks the worst status: Fail over Manual action required over Warning over Pass' {
        InModuleScope DbHubDemo { Get-DemoWorstStatus -Status @('Pass', 'Warning', 'Not selected') } | Should -Be 'Warning'
        InModuleScope DbHubDemo { Get-DemoWorstStatus -Status @('Warning', 'Manual action required', 'Pass') } | Should -Be 'Manual action required'
        InModuleScope DbHubDemo { Get-DemoWorstStatus -Status @('Manual action required', 'Fail') } | Should -Be 'Fail'
        InModuleScope DbHubDemo { Get-DemoWorstStatus -Status @() } | Should -Be ''
    }

    It 'updates a step atomically in the file, with its clock, its message redacted, and the Azure-side flag' {
        $path = New-TestModelFile
        $fakeToken = 'eyJ' + ('a' * 24) + '.' + ('b' * 24) + '.' + ('c' * 24)
        InModuleScope DbHubDemo -Parameters @{ Path = $path; Token = $fakeToken } {
            Set-DemoProgressStep -Path $Path -Id 'T1.Artifacts' -State 'Running' -AzureSide -Message ('Azure is finishing MDE.Windows on sqlvm01; token {0}' -f $Token)
        }
        $model = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        $step = Get-TestStep -Model $model -Id 'T1.Artifacts'
        $step['state'] | Should -Be 'Running'
        $step['azureSide'] | Should -BeTrue
        $step['startedAt'] | Should -BeGreaterThan 0
        $step['message'] | Should -Match 'MDE\.Windows'
        $step['message'] | Should -Not -Match ([regex]::Escape($fakeToken))
        InModuleScope DbHubDemo -Parameters @{ Path = $path } { Set-DemoProgressStep -Path $Path -Id 'T1.Artifacts' -Status 'Warning' -Message 'Sent.' }
        $step = Get-TestStep -Model (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 20) -Id 'T1.Artifacts'
        $step['state'] | Should -Be 'Done'
        $step['status'] | Should -Be 'Warning'
        $step['endedAt'] | Should -BeGreaterOrEqual $step['startedAt']
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }

    It 'never throws, and does nothing, without a model (a track a test started, or -NoStatusPage)' {
        { InModuleScope DbHubDemo { Set-DemoProgressStep -Path '' -Id 'T1.Artifacts' -State 'Running' } } | Should -Not -Throw
        { InModuleScope DbHubDemo -Parameters @{ Path = (Join-Path -Path $TestDrive -ChildPath 'missing.json') } { Set-DemoProgressValue -Path $Path -Section 'run' -Value @{ state = 'Done' } } } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path -Path $TestDrive -ChildPath 'missing.json') | Should -BeFalse
    }

    It 'marks the plan: an earlier run''s steps Done, steps outside the run Skipped, and a golden T2''s build and guided stop Skipped' {
        $path = New-TestModelFile
        InModuleScope DbHubDemo -Parameters @{ Path = $path } {
            $state = [pscustomobject]@{ Stage = 'Infrastructure'; TrackT1 = 'Bootstraps'; TrackT2 = ''; TrackT4 = ''; TrackFabric = '' }
            $plan = Resolve-DemoTrackPlan -Resume -State $state -SkipT4
            Set-DemoProgressPlan -Path $Path -Plan $plan -Resume -T2Source 'golden'
        }
        $model = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        (Get-TestStep -Model $model -Id 'Preflight')['state'] | Should -Be 'Done'
        (Get-TestStep -Model $model -Id 'T1.Artifacts')['state'] | Should -Be 'Done'
        (Get-TestStep -Model $model -Id 'T1.Artifacts')['message'] | Should -Match 'earlier run'
        (Get-TestStep -Model $model -Id 'T1.Telemetry')['state'] | Should -Be 'Pending'
        (Get-TestStep -Model $model -Id 'T1.Telemetry')['message'] | Should -BeNullOrEmpty
        (Get-TestStep -Model $model -Id 'T2.HostBuild')['state'] | Should -Be 'Skipped'
        (Get-TestStep -Model $model -Id 'T2.GuidedStop')['message'] | Should -Match 'golden snapshot'
        (Get-TestStep -Model $model -Id 'T2.Restore')['state'] | Should -Be 'Pending'
        # Where each resumed track picks up (Phase 28 live finding, 2026-10-30).
        (Get-TestStep -Model $model -Id 'T3.Checks')['state'] | Should -Be 'Pending'
        (Get-TestStep -Model $model -Id 'T3.Checks')['message'] | Should -Be 'Didn''t finish in the previous run; running it again.'
        (Get-TestStep -Model $model -Id 'T2.Restore')['message'] | Should -Be 'Didn''t finish in the previous run; running it again.'
    }

    It 'shows a step a fresh run left unfinished as running again on the resume, never as finished in an earlier run (Phase 28 live finding, 2026-10-30)' {
        # Live: the fresh run's Fabric step failed; the resume's page said "Finished in an earlier run." for Fabric.Items,
        # Fabric.Report, and Fabric.App, and the step never ran again. Its record now goes when a run starts over.
        $path = New-TestModelFile
        InModuleScope DbHubDemo -Parameters @{ Path = $path } {
            $state = [pscustomobject]@{ Stage = 'Monitoring'; TrackT1 = 'Telemetry'; TrackT2 = 'Telemetry'; TrackT4 = ''; TrackFabric = '' }
            $plan = Resolve-DemoTrackPlan -Resume -State $state -SkipT4
            Set-DemoProgressPlan -Path $Path -Plan $plan -Resume -T2Source 'golden'
        }
        $model = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        (Get-TestStep -Model $model -Id 'Fabric.Items')['state'] | Should -Be 'Pending'
        (Get-TestStep -Model $model -Id 'Fabric.Items')['message'] | Should -Be 'Didn''t finish in the previous run; running it again.'
        foreach ($id in 'Fabric.Report', 'Fabric.App') {
            (Get-TestStep -Model $model -Id $id)['state'] | Should -Be 'Pending'
            (Get-TestStep -Model $model -Id $id)['message'] | Should -Not -Match 'earlier run'
        }
        (Get-TestStep -Model $model -Id 'T1.Telemetry')['state'] | Should -Be 'Done'
        (Get-TestStep -Model $model -Id 'T2.Telemetry')['message'] | Should -Be 'Finished in an earlier run.'
    }

    It 'puts a resumed golden T2''s note on the first row it uses, and nothing on a run that doesn''t resume' {
        $path = New-TestModelFile
        InModuleScope DbHubDemo -Parameters @{ Path = $path } {
            $state = [pscustomobject]@{ Stage = 'Monitoring'; TrackT1 = 'Telemetry'; TrackT2 = 'Bootstraps'; TrackT4 = ''; TrackFabric = 'Fabric' }
            $plan = Resolve-DemoTrackPlan -Resume -State $state -SkipT4
            Set-DemoProgressPlan -Path $Path -Plan $plan -Resume -T2Source 'existing-golden'
        }
        $model = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        (Get-TestStep -Model $model -Id 'T2.HostBuild')['message'] | Should -Match 'golden snapshot'
        (Get-TestStep -Model $model -Id 'T2.ArcOnboarding')['message'] | Should -Be 'Didn''t finish in the previous run; running it again.'
        (Get-TestStep -Model $model -Id 'T2.Monitoring')['message'] | Should -BeNullOrEmpty

        $path = New-TestModelFile
        InModuleScope DbHubDemo -Parameters @{ Path = $path } { Set-DemoProgressPlan -Path $Path -Plan (Resolve-DemoTrackPlan -SkipT4) -T2Source 'golden' }
        $model = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
        @($model['tracks'] | ForEach-Object { $_['steps'] } | Where-Object { [string]$_['message'] -match 'previous run' }) | Should -BeNullOrEmpty
    }
}

Describe 'The status page''s banner: exactly one of four states' {
    It 'is Deploying, no action needed, while nothing waits for a person, with the estimate and when a person is needed' {
        $model = New-TestModel
        $banner = InModuleScope DbHubDemo -Parameters @{ Model = $model } { Get-DemoProgressBanner -Model $Model -NowUnix 1793000060 }
        $banner.Kind | Should -Be 'Deploying'
        $banner.Title | Should -Be 'Deploying, no action needed'
        ($banner.Lines -join ' ') | Should -Match 'step away'
        ($banner.Lines -join ' ') | Should -Match '60 to 90 minutes after the start'
    }

    It 'is Waiting for you at the guided stop, with the steps, the portal link, and a countdown' {
        $model = New-TestModel
        $model['guidedStop']['state'] = 'Ready'
        $model['guidedStop']['url'] = 'https://portal.azure.com/#@contoso.example/resource/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-dbhub-demo/providers/Microsoft.Compute/virtualMachines/archost01'
        $model['guidedStop']['deadlineAt'] = 1793000000 + 2700
        $model['guidedStop']['credential'] = 'portalReset'
        $banner = InModuleScope DbHubDemo -Parameters @{ Model = $model } { Get-DemoProgressBanner -Model $Model -NowUnix 1793000060 }
        $banner.Kind | Should -Be 'Waiting'
        $banner.Title | Should -Be 'Waiting for you'
        $banner.Countdown | Should -Match '44m 00s left'
        $banner.Link | Should -Match '^https://portal\.azure\.com/'
        ($banner.Lines -join ' ') | Should -Match 'pay-as-you-go'
        ($banner.Lines -join ' ') | Should -Match 'Help, then Reset password'
    }

    It 'is Done with where to look and the optional items, and Stopped, not done, with the exact command' {
        $model = New-TestModel
        $model['run']['state'] = 'Done'
        $model['run']['reason'] = 'Database Hub shows every target.'
        $model['optional'] = @(@{ name = 'the Insights app (Fabric Apps preview)'; message = 'It wasn''t added.'; howTo = 'Run ./scripts/configure-fabric-app.ps1 -SignIn.' })
        $done = InModuleScope DbHubDemo -Parameters @{ Model = $model } { Get-DemoProgressBanner -Model $Model -NowUnix 1793000060 }
        $done.Kind | Should -Be 'Done'
        ($done.Lines -join ' ') | Should -Match 'The demo is complete'
        ($done.Lines -join ' ') | Should -Match 'Optional, not needed for the demo: the Insights app'
        ($done.Lines -join ' ') | Should -Match 'capture-t2-golden\.ps1'

        $model['run']['state'] = 'NotDone'
        $model['run']['reason'] = 'TELEMETRY.T2 hasn''t passed yet.'
        $model['run']['next'] = 'Wait about 10 minutes.'
        $model['run']['nextCommand'] = './scripts/deploy.ps1'
        $stopped = InModuleScope DbHubDemo -Parameters @{ Model = $model } { Get-DemoProgressBanner -Model $Model -NowUnix 1793000060 }
        $stopped.Kind | Should -Be 'Stopped'
        $stopped.Title | Should -Be 'Stopped, not done'
        $stopped.Command | Should -Be './scripts/deploy.ps1'
        ($stopped.Lines -join ' ') | Should -Match 'run \./scripts/deploy\.ps1 again; it continues where it stopped'
        ($stopped.Lines -join ' ') | Should -Match 'collect-diagnostics\.ps1'
    }

    It 'is Stopped, not done, when deploy.ps1 stopped updating a running model (its window closed, or the PC slept)' {
        $model = New-TestModel
        $model['heartbeatAt'] = 1793000000
        $banner = InModuleScope DbHubDemo -Parameters @{ Model = $model } { Get-DemoProgressBanner -Model $Model -NowUnix (1793000000 + 600) }
        $banner.Kind | Should -Be 'Stopped'
        ($banner.Lines -join ' ') | Should -Match 'stopped updating this page 10 minutes ago'
    }
}

Describe 'Stale detection' {
    It 'warns when no step changed for 20 minutes while nobody is asked for anything, but not at the guided stop' {
        $model = New-TestModel
        $model['updatedAt'] = 1793000000
        $model['heartbeatAt'] = 1793000000 + 1500
        $stale = InModuleScope DbHubDemo -Parameters @{ Model = $model } { Test-DemoProgressStale -Model $Model -NowUnix (1793000000 + 1510) }
        $stale.Progress | Should -BeTrue
        $stale.Heartbeat | Should -BeFalse
        $stale.StepMinutes | Should -Be 25
        $model['guidedStop']['state'] = 'Ready'
        (InModuleScope DbHubDemo -Parameters @{ Model = $model } { Test-DemoProgressStale -Model $Model -NowUnix (1793000000 + 1510) }).Progress | Should -BeFalse
    }

    It 'is never stale once the run ended' {
        $model = New-TestModel
        $model['run']['state'] = 'Done'
        $stale = InModuleScope DbHubDemo -Parameters @{ Model = $model } { Test-DemoProgressStale -Model $Model -NowUnix (1793000000 + 99999) }
        $stale.Progress | Should -BeFalse
        $stale.Heartbeat | Should -BeFalse
    }
}

Describe 'The status page''s HTML' {
    It 'HTML-encodes every message, has no script and no external resource, and refreshes itself while the run goes on' {
        $model = New-TestModel
        $step = Get-TestStep -Model $model -Id 'T1.Bootstraps'
        $step['state'] = 'Running'
        $step['startedAt'] = 1793000000
        $step['message'] = '<script>alert(1)</script> & "quoted"'
        $html = InModuleScope DbHubDemo -Parameters @{ Model = $model } { ConvertTo-DemoProgressHtml -Model $Model -NowUnix 1793000060 }
        $html | Should -Not -Match '<script'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt; &amp; &quot;quoted&quot;'
        $html | Should -Match '<meta http-equiv="refresh" content="10">'
        $html | Should -Not -Match '(?i)<(link|img|iframe)\b'
        $html | Should -Not -Match '(?i)src='
        $html | Should -Not -Match '(?i)https?://(?!portal\.azure\.com)'
        $html | Should -Match 'Deploying, no action needed'
    }

    It 'stops refreshing once the run ended, and links only to the Azure portal' {
        $model = New-TestModel
        $model['guidedStop']['state'] = 'Ready'
        $model['guidedStop']['url'] = 'javascript:alert(1)'
        $html = InModuleScope DbHubDemo -Parameters @{ Model = $model } { ConvertTo-DemoProgressHtml -Model $Model -NowUnix 1793000060 }
        $html | Should -Not -Match 'href='
        $model['run']['state'] = 'Done'
        $html = InModuleScope DbHubDemo -Parameters @{ Model = $model } { ConvertTo-DemoProgressHtml -Model $Model -NowUnix 1793000060 }
        $html | Should -Not -Match 'http-equiv="refresh"'
        $html | Should -Match '<h1>Done</h1>'
    }

    It 'shows an Azure-side wait as no action needed, and the stale warning' {
        $model = New-TestModel
        $step = Get-TestStep -Model $model -Id 'T1.Artifacts'
        $step['state'] = 'Running'
        $step['azureSide'] = $true
        $step['message'] = 'Azure is finishing MDE.Windows (installed by a policy in your tenant) on sqlvm01; no action needed.'
        $model['updatedAt'] = 1793000000
        $model['heartbeatAt'] = 1793000000 + 1500
        $html = InModuleScope DbHubDemo -Parameters @{ Model = $model } { ConvertTo-DemoProgressHtml -Model $Model -NowUnix (1793000000 + 1510) }
        $html | Should -Match 'Azure-side, no action needed\. Azure is finishing MDE\.Windows'
        $html | Should -Match 'class="warn">No step has changed for 25 minutes'
    }

    It 'writes the page from the model file, and the console view shows the same banner and steps' {
        $path = New-TestModelFile
        $page = Join-Path -Path $TestDrive -ChildPath 'deploy-status.html'
        InModuleScope DbHubDemo -Parameters @{ Path = $path; Page = $page } { Write-DemoProgressPage -ModelPath $Path -PagePath $Page -Heartbeat }
        Get-Content -LiteralPath $page -Raw | Should -Match 'Deploying, no action needed'
        $lines = InModuleScope DbHubDemo -Parameters @{ Path = $path } { Format-DemoProgressConsole -Model (Read-DemoProgress -Path $Path) -Width 120 }
        ($lines -join "`n") | Should -Match 'DEPLOYING, NO ACTION NEEDED'
        ($lines -join "`n") | Should -Match 'T2: Arc-enabled SQL Server'
        ($lines -join "`n") | Should -Match '\[ \] Pending'
    }
}

Describe 'The guided stop''s steps' {
    It 'give the clipboard, Key Vault, and portal Reset password ways in, and never a password' {
        $clipboard = InModuleScope DbHubDemo { Get-DemoGuidedStopInstruction -HostUser 'demoadmin' -SignInWay 'clipboard' }
        ($clipboard -join ' ') | Should -Match 'on your clipboard'
        $portal = InModuleScope DbHubDemo { Get-DemoGuidedStopInstruction -HostUser 'demoadmin' -SignInWay 'portalReset' }
        ($portal -join ' ') | Should -Match 'no password was set or shown'
        ($portal -join ' ') | Should -Match 'open archost01, then Help, then Reset password'
        ($portal -join ' ') | Should -Match 'keep the user name demoadmin'
        ($portal -join ' ') | Should -Match 'Use pay-as-you-go billing through Microsoft Azure'
        ($portal -join ' ') | Should -Match 'Use Azure Login'
        $vault = InModuleScope DbHubDemo { Get-DemoGuidedStopInstruction -SignInWay 'keyVault' -SignInText 'It''s the secret archost01-admin in kv-dbhub.' }
        ($vault -join ' ') | Should -Match 'kv-dbhub'
    }

    It 'tell the person what to do when the Azure Login window stays blank or Internet Explorer blocks it, on the console and the status page (the owner, 2026-10-30)' {
        $steps = @(InModuleScope DbHubDemo { Get-DemoGuidedStopInstruction -HostUser 'demoadmin' -SignInWay 'clipboard' })
        $azure = @($steps | Where-Object { $_ -like '5. On the Azure Extension for SQL Server page*' })
        $azure.Count | Should -Be 1
        $azure[0] | Should -Match 'If the Azure Login window stays blank, or Internet Explorer says content from https://login\.microsoftonline\.com is blocked, follow the dialog''s directions'
        $azure[0] | Should -Match ([regex]::Escape('select Add..., then Add, to put the Microsoft sign-in page in Trusted sites, and Close. Then select "Use Azure Login" again. Repeat for any other sign-in site it names.'))
        $azure[0] | Should -Match ([regex]::Escape('(Confirmed live on 2026-10-30; turning IE Enhanced Security Configuration off while setup is open doesn''t help.)'))
        ($steps -join ' ') | Should -Not -Match 'WebView2'

        # The status page's Waiting banner shows the same steps.
        $model = New-TestModel
        $model['guidedStop']['state'] = 'Ready'
        $model['guidedStop']['deadlineAt'] = 1793000000 + 2700
        $model['guidedStop']['credential'] = 'clipboard'
        $banner = InModuleScope DbHubDemo -Parameters @{ Model = $model } { Get-DemoProgressBanner -Model $Model -NowUnix 1793000060 }
        ($banner.Lines -join ' ') | Should -Match ([regex]::Escape('select Add..., then Add, to put the Microsoft sign-in page in Trusted sites'))

        # The console's WAITING FOR YOU banner too.
        $script:printed = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoConsoleBlock -MockWith { foreach ($line in @($Line)) { $script:printed.Add([string]$line) } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAttention -MockWith { }
        InModuleScope DbHubDemo { Show-DemoGuidedStopPrompt -Url 'https://portal.azure.com/#resource/x' -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(45)) -HostUser 'demoadmin' -SignInWay 'clipboard' -NoBrowser }
        ($script:printed -join ' ') | Should -Match 'WAITING FOR YOU'
        ($script:printed -join ' ') | Should -Match ([regex]::Escape('select Add..., then Add, to put the Microsoft sign-in page in Trusted sites, and Close.'))
    }

    It 'lead with Add... and say the automatic preparation didn''t finish, when the host asks anyway (Phase 28 review)' {
        $steps = @(InModuleScope DbHubDemo { Get-DemoGuidedStopInstruction -HostUser 'demoadmin' -SignInWay 'clipboard' -SignInFallback })
        $steps[0] | Should -Match '^First: the automatic preparation of setup''s Azure sign-in didn''t finish, so Internet Explorer may block it\.'
        $steps[0] | Should -Match ([regex]::Escape('select Add..., then Add, then Close, and select "Use Azure Login" again'))
        $steps[1] | Should -Match '^1\. Sign in to archost01 through Bastion'
        @(InModuleScope DbHubDemo { Get-DemoGuidedStopInstruction -HostUser 'demoadmin' -SignInWay 'clipboard' })[0] | Should -Match '^1\. ' -Because 'without the fallback, the steps start as before'

        # The status page's Waiting banner, from the model the T2 track writes.
        $model = New-TestModel
        $model['guidedStop']['state'] = 'Ready'
        $model['guidedStop']['deadlineAt'] = 1793000000 + 2700
        $model['guidedStop']['credential'] = 'clipboard'
        $model['guidedStop']['signInFallback'] = $true
        $banner = InModuleScope DbHubDemo -Parameters @{ Model = $model } { Get-DemoProgressBanner -Model $Model -NowUnix 1793000060 }
        @($banner.Lines)[1] | Should -Match '^First: the automatic preparation of setup''s Azure sign-in didn''t finish'

        # The console's WAITING FOR YOU banner too.
        $script:printed = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Write-DemoConsoleBlock -MockWith { foreach ($line in @($Line)) { $script:printed.Add([string]$line) } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAttention -MockWith { }
        InModuleScope DbHubDemo { Show-DemoGuidedStopPrompt -Url 'https://portal.azure.com/#resource/x' -DeadlineUtc ([DateTime]::UtcNow.AddMinutes(45)) -HostUser 'demoadmin' -SignInWay 'clipboard' -NoBrowser -SignInFallback }
        ($script:printed -join ' ') | Should -Match 'First: the automatic preparation of setup''s Azure sign-in didn''t finish'
    }
}

Describe 'Show-DemoDeploymentProgress (status.ps1 -Watch)' {
    It 'draws the model once and returns its banner, or None without a model' {
        $path = New-TestModelFile
        Mock -ModuleName DbHubDemo -CommandName Write-Host -MockWith { }
        Show-DemoDeploymentProgress -Path $path | Should -Be 'Deploying'
        Show-DemoDeploymentProgress -Path (Join-Path -Path $TestDrive -ChildPath 'none.json') | Should -Be 'None'
    }

    It 'watches until the run ends' {
        $path = New-TestModelFile
        Mock -ModuleName DbHubDemo -CommandName Write-Host -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Clear-Host -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {
            InModuleScope DbHubDemo -Parameters @{ Path = $script:watchPath } { Set-DemoProgressValue -Path $Path -Section 'run' -Value @{ state = 'Done'; reason = 'Every target is in Database Hub.' } }
        }
        $script:watchPath = $path
        Show-DemoDeploymentProgress -Path $path -Watch -IntervalSeconds 2 | Should -Be 'Done'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -Times 1 -Exactly
    }
}
