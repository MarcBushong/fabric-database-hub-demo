BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    $config = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
    # Obviously fake IDs: every group repeats one digit.
    $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
    $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
    $config['location'] = 'westus3'

    # Fake servers and databases. 'rg-dbhub-demo' is the demo's resource group in the example configuration.
    function Set-SqlMock {
        param(
            [object[]] $Servers = @(),
            [hashtable] $Databases = @{},
            [string[]] $FailingServers = @(),
            [switch] $ServerListFails
        )
        $script:mockServers = $Servers
        $script:mockDatabases = $Databases
        $script:mockFailingServers = $FailingServers
        $script:mockServerListFails = [bool]$ServerListFails
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            if ($joined -like 'sql server list*') {
                if ($script:mockServerListFails) {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (AuthorizationFailed) no access' }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject @($script:mockServers) -Depth 5); StdErr = '' }
            }
            if ($joined -match '^sql db list --server (\S+)') {
                $server = $Matches[1]
                if ($server -in $script:mockFailingServers) {
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = 'ERROR: (AuthorizationFailed) no access' }
                }
                $items = if ($script:mockDatabases.ContainsKey($server)) { @($script:mockDatabases[$server]) } else { @() }
                return [pscustomobject]@{ ExitCode = 0; StdOut = (ConvertTo-Json -InputObject $items -Depth 5); StdErr = '' }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = '{}'; StdErr = '' }
        }
    }

    function New-FreeDatabase([string] $Name, [string] $Location = 'westus3', [bool] $Free = $true) {
        [pscustomobject]@{ name = $Name; location = $Location; useFreeLimit = $Free }
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoT3FreeOfferStatus' {
    It 'is Not selected and uses regular serverless when t3FreeOffer is off' {
        Set-SqlMock
        $off = Get-DemoConfig -Path (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json')
        $off['subscriptionId'] = $config['subscriptionId']
        $off['t3FreeOffer'] = 'off'
        $status = Get-DemoT3FreeOfferStatus -Config $off
        $status.UseFreeLimit | Should -BeFalse
        $status.Result.status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0
    }

    It 'passes when the subscription has no free databases' {
        Set-SqlMock
        $status = Get-DemoT3FreeOfferStatus -Config $config
        $status.UseFreeLimit | Should -BeTrue
        $status.Result.status | Should -Be 'Pass'
        $status.Result.checkId | Should -Be 'PREFLIGHT.T3.FREEOFFER'
        $status.Result.evidence.useFreeLimit | Should -BeTrue
    }

    It 'passes when fewer than ten other free databases are in the same region' {
        Set-SqlMock -Servers @([pscustomobject]@{ name = 'other1'; resourceGroup = 'rg-other' }) -Databases @{ other1 = @((New-FreeDatabase 'a'), (New-FreeDatabase 'b'), (New-FreeDatabase 'c' -Free $false)) }
        $status = Get-DemoT3FreeOfferStatus -Config $config
        $status.UseFreeLimit | Should -BeTrue
        $status.Result.status | Should -Be 'Pass'
        $status.Result.evidence.otherFreeDatabases | Should -Be 2
        $status.Result.message | Should -Match '2 of 10'
    }

    It 'falls back with a Warning when ten free databases are already in use' {
        $databases = 1..10 | ForEach-Object { New-FreeDatabase "db$_" }
        Set-SqlMock -Servers @([pscustomobject]@{ name = 'other1'; resourceGroup = 'rg-other' }) -Databases @{ other1 = $databases }
        $status = Get-DemoT3FreeOfferStatus -Config $config
        $status.UseFreeLimit | Should -BeFalse
        $status.Result.status | Should -Be 'Warning'
        $status.Result.message | Should -Match 'regular General Purpose serverless'
    }

    It 'falls back with a Warning when the free databases are in another region' {
        Set-SqlMock -Servers @([pscustomobject]@{ name = 'other1'; resourceGroup = 'rg-other' }) -Databases @{ other1 = @(New-FreeDatabase 'a' -Location 'East US') }
        $status = Get-DemoT3FreeOfferStatus -Config $config
        $status.UseFreeLimit | Should -BeFalse
        $status.Result.status | Should -Be 'Warning'
        $status.Result.message | Should -Match 'eastus'
    }

    It 'keeps an existing demo database on the free offer' {
        Set-SqlMock -Servers @([pscustomobject]@{ name = 'azuresql01-abc123'; resourceGroup = 'rg-dbhub-demo' }) -Databases @{ 'azuresql01-abc123' = @((New-FreeDatabase 'master' -Free $false), (New-FreeDatabase 'ContosoCare')) }
        $status = Get-DemoT3FreeOfferStatus -Config $config
        $status.UseFreeLimit | Should -BeTrue
        $status.Result.status | Should -Be 'Pass'
        $status.Result.evidence.demoDatabaseExists | Should -BeTrue
    }

    It 'warns that an existing demo database without the free offer cannot be converted' {
        Set-SqlMock -Servers @([pscustomobject]@{ name = 'azuresql01-abc123'; resourceGroup = 'rg-dbhub-demo' }) -Databases @{ 'azuresql01-abc123' = @(New-FreeDatabase 'ContosoCare' -Free $false) }
        $status = Get-DemoT3FreeOfferStatus -Config $config
        $status.UseFreeLimit | Should -BeFalse
        $status.Result.status | Should -Be 'Warning'
        $status.Result.remediation | Should -Match 'stop-demo.ps1 -RemoveT3'
    }

    It 'does not count the demo database among the ten' {
        $databases = 1..9 | ForEach-Object { New-FreeDatabase "db$_" }
        Set-SqlMock -Servers @([pscustomobject]@{ name = 'other1'; resourceGroup = 'rg-other' }, [pscustomobject]@{ name = 'azuresql01-abc123'; resourceGroup = 'rg-dbhub-demo' }) -Databases @{ other1 = $databases; 'azuresql01-abc123' = @(New-FreeDatabase 'ContosoCare') }
        $status = Get-DemoT3FreeOfferStatus -Config $config
        $status.UseFreeLimit | Should -BeTrue
        $status.Result.evidence.otherFreeDatabases | Should -Be 9
    }

    It 'tries the free offer with a Warning when the servers cannot be listed' {
        Set-SqlMock -ServerListFails
        $status = Get-DemoT3FreeOfferStatus -Config $config
        $status.UseFreeLimit | Should -BeTrue
        $status.Result.status | Should -Be 'Warning'
        $status.Result.message | Should -Match 'falls back'
    }

    It 'tries the free offer with a Warning when a server cannot be read' {
        Set-SqlMock -Servers @([pscustomobject]@{ name = 'locked'; resourceGroup = 'rg-other' }) -FailingServers @('locked')
        $status = Get-DemoT3FreeOfferStatus -Config $config
        $status.UseFreeLimit | Should -BeTrue
        $status.Result.status | Should -Be 'Warning'
        $status.Result.evidence.unread | Should -Contain 'server locked'
    }

    It 'stops reading at the server limit and says so' {
        $servers = 1..3 | ForEach-Object { [pscustomobject]@{ name = "s$_"; resourceGroup = 'rg-other' } }
        Set-SqlMock -Servers $servers
        $status = Get-DemoT3FreeOfferStatus -Config $config -MaximumServers 2
        $status.Result.status | Should -Be 'Warning'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 2 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -like 'sql db list*' }
    }

    It 'passes --subscription on every call' {
        Set-SqlMock -Servers @([pscustomobject]@{ name = 'other1'; resourceGroup = 'rg-other' })
        Get-DemoT3FreeOfferStatus -Config $config | Out-Null
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -ParameterFilter { $ArgumentList -notcontains '--subscription' }
    }
}
