BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force

    $script:brokenText = 'The background process reported an error with the following message: "The Hyper-V socket target process has ended.".'

    # The T2 host's health as deploy.ps1 reads it: PowerShell 7's ConvertFrom-Json makes DateTimes of the ISO times.
    function New-TestHealth([string] $StartedUtc = '2026-11-18T18:52:10.1234567Z', [string] $EndedUtc = '2026-11-18T18:53:45.0000000Z', [bool] $Recovered = $true) {
        $recovery = [ordered]@{ startedUtc = $StartedUtc; endedUtc = $EndedUtc; by = 'Arc onboarding'; key = 'deploy-aaaaaaaaaaaa'; seconds = 95; stoppedBy = 'Shutdown'; recovered = $Recovered; reason = $script:brokenText }
        ([ordered]@{ state = 'Ready'; guestRecovery = $recovery } | ConvertTo-Json -Depth 4) | ConvertFrom-Json
    }

    function Get-TestRestart([object[]] $Result = @(), [object] $Health = $null, [datetime] $SinceUtc = [datetime]::new(2026, 11, 18, 18, 0, 0, [System.DateTimeKind]::Utc)) {
        InModuleScope DbHubDemo -Parameters @{ Result = $Result; Health = $Health; Since = $SinceUtc } {
            Get-DemoGuestRecoveryRunResult -Result $Result -Health $Health -SinceUtc $Since
        }
    }
}

Describe 'deploy.ps1''s report of a guest restart that cleared a broken PowerShell Direct channel (issue #65)' {
    It 'reports a restart once, as a Warning that says what broke and that the restart cleared it, however many sources show it' {
        $relay = New-DemoResult -CheckId 'DEPLOY.PROFILE_T2' -Area 't2' -Target 'T2' -Status 'Warning' -Message 'T2''s profile is set.' -Evidence ([ordered]@{ guestRecovery = [ordered]@{ restarted = $true; recovered = $true; seconds = 95; restartUtc = '2026-11-18T18:52:10.1234567Z'; stoppedBy = 'Shutdown'; by = 'Arc onboarding'; reason = $script:brokenText } })
        $results = @(Get-TestRestart -Result @($relay) -Health (New-TestHealth))
        $results.Count | Should -Be 1
        $results[0].checkId | Should -Be 'DEPLOY.T2.GUESTRESTART'
        $results[0].status | Should -Be 'Warning'
        $results[0].message | Should -Match '^PowerShell Direct into arcsql01 broke at 18:52 UTC \(.*Hyper-V socket target process has ended.*\), so Arc onboarding restarted arcsql01 once for this run: it shut it down cleanly and started it again, and arcsql01 answered again after 95 seconds, so the step went on\.$'
        # New-DemoResult's evidence goes through JSON, so the time may come back as a DateTime.
        ([datetime]$results[0].evidence.atUtc).ToUniversalTime() | Should -Be ([datetime]::new(2026, 11, 18, 18, 52, 10, [System.DateTimeKind]::Utc))

        # The same restart, already reported by an earlier pass, isn't reported again.
        @(Get-TestRestart -Result @($relay, $results[0]) -Health (New-TestHealth)).Count | Should -Be 0
    }

    It 'reports a break that was over, after which the step ran again without a restart, as DEPLOY.T2.GUESTRETRY (the user''s demo, 2026-11-18)' {
        $arc = New-DemoResult -CheckId 'T2.ARC.ONBOARDING' -Area 't2' -Target 'T2' -Status 'Pass' -Message 'arcsql01 is Connected.' -Evidence ([ordered]@{ guestRecovery = [ordered]@{ action = 'Healed'; restarted = $false; recovered = $true; seconds = 0; atUtc = '2026-11-18T18:49:26.5000000Z'; restartUtc = ''; by = 'Arc onboarding'; reason = $script:brokenText } })
        $results = @(Get-TestRestart -Result @($arc))
        $results.Count | Should -Be 1
        $results[0].checkId | Should -Be 'DEPLOY.T2.GUESTRETRY'
        $results[0].status | Should -Be 'Warning'
        $results[0].message | Should -Match '^PowerShell Direct into arcsql01 broke for a moment at 18:49 UTC \(.*target process has ended.*\), so Arc onboarding waited until arcsql01 answered again and ran its step again, which went on\.$'
        @(Get-TestRestart -Result @($arc, $results[0])).Count | Should -Be 0
        InModuleScope DbHubDemo -Parameters @{ Result = $results } { Get-DemoGuestRestartNote -Result $Result } | Should -Match 'broke for a moment.*DEPLOY\.T2\.GUESTRETRY'
        # A recovery that only waited for a guest that was starting, or found nothing to do, isn't reported.
        foreach ($action in 'Wait', 'None', 'Exhausted') {
            $other = New-DemoResult -CheckId 'DEPLOY.PROFILE_T2' -Area 't2' -Target 'T2' -Status 'Fail' -Message 'x' -Evidence ([ordered]@{ guestRecovery = [ordered]@{ action = $action; restarted = $false; recovered = $false; atUtc = '2026-11-18T18:49:26Z' } })
            @(Get-TestRestart -Result @($other)).Count | Should -Be 0 -Because $action
        }
    }

    It 'reports nothing for a restart before this run, or one that''s still going' {
        @(Get-TestRestart -Health (New-TestHealth) -SinceUtc ([datetime]::new(2026, 11, 18, 19, 0, 0, [System.DateTimeKind]::Utc))).Count | Should -Be 0
        @(Get-TestRestart -Health (New-TestHealth -EndedUtc '')).Count | Should -Be 0
        @(Get-TestRestart -Health ([pscustomobject]@{ state = 'Ready' })).Count | Should -Be 0
    }

    It 'stays a Fail, with what to run, when the guest still didn''t answer after its restart, and sets the status page''s row' {
        $failed = @(Get-TestRestart -Health (New-TestHealth -Recovered $false))
        $failed.Count | Should -Be 1
        $failed[0].status | Should -Be 'Fail'
        $failed[0].message | Should -Match 'restarted arcsql01 once for this run, but it still didn''t answer over PowerShell Direct'
        $failed[0].remediation | Should -Match 'deploy\.ps1'

        $path = Join-Path -Path $TestDrive -ChildPath 'progress.json'
        $read = {
            param([string] $Path)
            InModuleScope DbHubDemo -Parameters @{ Path = $Path } {
                $model = Read-DemoProgress -Path $Path
                foreach ($track in @($model['tracks'])) {
                    foreach ($item in @($track['steps'])) {
                        if ([string]$item['id'] -eq 'T2.GuestRestart') {
                            return $item
                        }
                    }
                }
            }
        }
        InModuleScope DbHubDemo -Parameters @{ Path = $path } {
            $model = New-DemoProgressModel -Catalog (Get-DemoProgressCatalog -InstallMode 'JumpstartImage') -Environment 'demo' -ResourceGroup 'rg-dbhub-demo' -NowUnix (Get-DemoUnixTime)
            Initialize-DemoProgress -Path $Path -Model $model -Confirm:$false
        }
        $warning = @(Get-TestRestart -Health (New-TestHealth))
        InModuleScope DbHubDemo -Parameters @{ Path = $path; Result = $warning } { Set-DemoGuestRecoveryProgress -ProgressPath $Path -Result $Result }
        $row = & $read $path
        $row['state'] | Should -Be 'Done'
        $row['status'] | Should -Be 'Warning'
        $row['message'] | Should -Match 'restarted arcsql01 once for this run'
        InModuleScope DbHubDemo -Parameters @{ Path = $path; Result = $failed } { Set-DemoGuestRecoveryProgress -ProgressPath $Path -Result $Result }
        $row = & $read $path
        $row['state'] | Should -Be 'Failed'
        $row['status'] | Should -Be 'Fail'

        # DONE names a restart that cleared it; a failed one is NOT DONE's own reason.
        InModuleScope DbHubDemo -Parameters @{ Result = $warning } { Get-DemoGuestRestartNote -Result $Result } | Should -Match 'restarted arcsql01 once, which cleared it.*DEPLOY\.T2\.GUESTRESTART'
        InModuleScope DbHubDemo -Parameters @{ Result = $failed } { Get-DemoGuestRestartNote -Result $Result } | Should -BeNullOrEmpty
    }

    It 'gives each deploy.ps1 run its own key, from the status page''s run ID' {
        InModuleScope DbHubDemo { New-DemoRunRecoveryKey -RunId '11111111-2222-3333-4444-555555555555' } | Should -Be 'deploy-111111112222'
        InModuleScope DbHubDemo { New-DemoRunRecoveryKey -RunId '' } | Should -Match '^deploy-[0-9a-f]{12}$'
    }
}
