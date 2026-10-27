BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $modulePath = Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    $runnerPath = Join-Path -Path $repoRoot -ChildPath 'vm/t3/Invoke-DemoT3Sql.ps1'

    function New-TestConfig {
        param([string] $NetworkMode = 'auto', [string] $FreeOffer = 'auto')
        $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        # Obviously fake IDs: every group repeats one character.
        $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $config['tenantId'] = '66666666-7777-8888-9999-000000000000'
        $config['t3AdminGroupObjectId'] = '77777777-7777-7777-7777-777777777777'
        $config['networkMode'] = $NetworkMode
        $config['t3FreeOffer'] = $FreeOffer
        $config
    }

    $script:principalId = '88888888-8888-8888-8888-888888888888'
    $script:serverId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Sql/servers/azuresql01-abc123'

    function New-AzResult {
        param([object] $Json = $null, [int] $ExitCode = 0, [string] $StdErr = '')
        $text = if ($null -eq $Json) { '' } elseif ($Json -is [string]) { $Json } else { ConvertTo-Json -InputObject $Json -Depth 20 -Compress }
        [pscustomobject]@{ ExitCode = $ExitCode; StdOut = $text; StdErr = $StdErr }
    }

    # What the T1 runner prints, wrapped the way 'az vm run-command invoke' returns it.
    function New-RunCommandResponse {
        param([hashtable] $Result, [string] $StdErr = '', [switch] $NoMarker)
        $state = [ordered]@{
            marker = 'DBHUBDEMO-T3SQL'; schemaVersion = 1; label = 'status'; status = 'Pass'; server = 'azuresql01-abc123.database.windows.net'; database = 'ContosoCare'
            batches = 1; completed = 1; attempts = 1; loginFailures = 0; transientFailures = 0; loginWaitSeconds = 0; elapsedSeconds = 3; errorNumber = 0; error = ''; rows = @(); rowsTruncated = $false
        }
        foreach ($key in $Result.Keys) { $state[$key] = $Result[$key] }
        $line = if ($NoMarker) { 'something else' } else { 'DBHUBDEMO-T3SQL ' + (ConvertTo-Json -InputObject $state -Depth 6 -Compress) }
        @{ value = @(
                @{ code = 'ComponentStatus/StdOut/succeeded'; level = 'Info'; displayStatus = 'Provisioning succeeded'; message = $line }
                @{ code = 'ComponentStatus/StdErr/succeeded'; level = 'Info'; displayStatus = 'Provisioning succeeded'; message = $StdErr }
            )
        }
    }

    function Get-RunnerFunction {
        # Loads the VM script's helper functions without running the script.
        param([string[]] $Name)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$null, [ref]$null)
        ($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false) | Where-Object { $_.Name -in $Name } | ForEach-Object { $_.Extent.Text }) -join [System.Environment]::NewLine
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'T3 T-SQL batches' {
    It 'splits on GO lines like sqlcmd: any case, spaces, a trailing comment, and no empty batches' {
        InModuleScope DbHubDemo {
            $script = "SELECT 1;`r`nGO`r`n  go  -- next`nSELECT 2;`nGO`nGO`n`nSELECT 3`n"
            $batches = Split-DemoSqlBatch -Script $script
            $batches | Should -Be @('SELECT 1;', 'SELECT 2;', 'SELECT 3')
        }
    }

    It 'does not split on GO inside a line or a word' {
        InModuleScope DbHubDemo {
            $batches = Split-DemoSqlBatch -Script "SELECT category FROM t; -- GO here`nGOTO label`nSELECT 'GO';"
            @($batches).Count | Should -Be 1
        }
    }

    It 'builds Setup from the common schema and seed, the T3 scripts, the seed with the profile scale, and the status query' {
        InModuleScope DbHubDemo -Parameters @{ Root = $repoRoot } {
            param($Root)
            $sql = Get-DemoT3SqlBatch -Name Setup -SeedScale 2
            $common = @(Get-ChildItem -LiteralPath (Join-Path $Root 'database/common') -Filter '0*.sql' | Sort-Object Name | ForEach-Object { "database/common/$($_.Name)" })
            $t3 = @(Get-ChildItem -LiteralPath (Join-Path $Root 'database/azuresql') -Filter '0*.sql' | Sort-Object Name | ForEach-Object { "database/azuresql/$($_.Name)" })
            $sql.Sources | Should -Be @($common + $t3 + @('seed', 'database/azuresql/900-status.sql'))
            $common | Should -Contain 'database/common/010-schema.sql'
            $common | Should -Contain 'database/common/020-seed.sql'
            $t3 | Should -Contain 'database/azuresql/040-performance-monitoring.sql'
            $sql.Batches | Should -Contain 'EXEC demo.usp_seed_contosocare @scale = 2;'
            $sql.Batches[-1] | Should -Match 'MS_EnablePerformanceMonitoringPreview'
            ($sql.Batches | Where-Object { $_ -match '(?im)^\s*GO\s*$' }) | Should -BeNullOrEmpty
        }
    }

    It 'has the read-only Status set and the PerformanceMonitoring set' {
        InModuleScope DbHubDemo {
            (Get-DemoT3SqlBatch -Name Status).Sources | Should -Be @('database/azuresql/900-status.sql')
            (Get-DemoT3SqlBatch -Name PerformanceMonitoring).Sources | Should -Be @('database/azuresql/040-performance-monitoring.sql', 'database/azuresql/900-status.sql')
        }
    }

    It 'refuses placeholders, because T3''s T-SQL takes none' {
        InModuleScope DbHubDemo {
            { Get-DemoT3SqlBatch -Query "SELECT N'{{DATA_DIRECTORY}}';" } | Should -Throw '*placeholder*'
        }
    }
}

Describe 'The T1 runner script (ConvertTo-DemoT3SqlScript and vm/t3/Invoke-DemoT3Sql.ps1)' {
    It 'fills every placeholder and stays ASCII, parseable, and under the size cap for the full Setup set' {
        InModuleScope DbHubDemo {
            $sql = Get-DemoT3SqlBatch -Name Setup
            $script = ConvertTo-DemoT3SqlScript -ServerFqdn 'azuresql01-abc123.database.windows.net' -DatabaseName 'ContosoCare' -Batch $sql.Batches -Label 'setup'
            $script.Text | Should -Not -Match '\{\{[A-Z0-9_]+\}\}'
            $script.Text | Should -Not -Match '[^\x00-\x7F]'
            $script.Bytes | Should -BeLessThan 65536
            $script.BatchCount | Should -Be $sql.Batches.Count
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($script.Text, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty
            $script.Text | Should -Match "\`$server = 'azuresql01-abc123\.database\.windows\.net'"
        }
    }

    It 'embeds the batches as gzip and Base64 with their SHA-256, so the T-SQL never goes on a command line' {
        InModuleScope DbHubDemo {
            $batches = @("SELECT N'it''s 100% fine' AS ""quoted"";", 'SELECT 2;')
            $script = ConvertTo-DemoT3SqlScript -ServerFqdn 'azuresql01-abc123.database.windows.net' -DatabaseName 'ContosoCare' -Batch $batches
            $payload = [regex]::Match($script.Text, "(?m)^\`$payload = '([A-Za-z0-9+/=]+)'").Groups[1].Value
            $bytes = [System.Convert]::FromBase64String($payload)
            [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() | Should -Be $script.PayloadSha256
            $gzip = [System.IO.Compression.GZipStream]::new([System.IO.MemoryStream]::new($bytes), [System.IO.Compression.CompressionMode]::Decompress)
            $decoded = [System.IO.StreamReader]::new($gzip).ReadToEnd() | ConvertFrom-Json
            @($decoded) | Should -Be $batches
            $script.Text | Should -Not -Match '100% fine'
        }
    }

    It 'refuses values that could break out of the script''s strings: <Case>' -ForEach @(
        @{ Case = 'server'; Server = "azuresql01-abc123.database.windows.net';Remove-Item C:\ -Recurse;'"; Database = 'ContosoCare'; Label = 'setup' }
        @{ Case = 'database'; Server = 'azuresql01-abc123.database.windows.net'; Database = "ContosoCare'"; Label = 'setup' }
        @{ Case = 'label'; Server = 'azuresql01-abc123.database.windows.net'; Database = 'ContosoCare'; Label = 'set up' }
    ) {
        InModuleScope DbHubDemo -Parameters @{ Server = $Server; Database = $Database; Label = $Label } {
            param($Server, $Database, $Label)
            $refused = $false
            try {
                ConvertTo-DemoT3SqlScript -ServerFqdn $Server -DatabaseName $Database -Batch @('SELECT 1;') -Label $Label | Out-Null
            }
            catch {
                $refused = $true
            }
            $refused | Should -BeTrue
        }
    }

    It 'refuses a script above the size cap' {
        InModuleScope DbHubDemo {
            $noise = -join (1..400 | ForEach-Object { [guid]::NewGuid().ToString('N') })
            { ConvertTo-DemoT3SqlScript -ServerFqdn 'azuresql01-abc123.database.windows.net' -DatabaseName 'ContosoCare' -Batch @("SELECT '$noise';") -MaximumBytes 8192 } | Should -Throw '*cap*'
        }
    }

    It 'never prints, logs, or stores the access token' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$null, [ref]$null)
        $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $commands | Where-Object { $_ -match '^(Write-(Host|Information|Verbose|Warning|Debug|Error)|Out-(Host|File|Default)|Set-Content|Add-Content|Export-.*|Start-Transcript|Tee-Object)$' } | Should -BeNullOrEmpty
        @($commands | Where-Object { $_ -eq 'Write-Output' }).Count | Should -Be 1

        # The token is used only to open the connection.
        $tokenUses = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.VariableExpressionAst] -and $node.VariablePath.UserPath -in 'token', 'AccessToken' }, $true))
        $tokenUses.Count | Should -BeGreaterThan 0
        foreach ($use in $tokenUses) {
            $statement = $use
            while ($statement -and $statement -isnot [System.Management.Automation.Language.AssignmentStatementAst] -and $statement -isnot [System.Management.Automation.Language.PipelineAst] -and $statement -isnot [System.Management.Automation.Language.ParameterAst]) {
                $statement = $statement.Parent
            }
            $statement.Extent.Text | Should -Match '^(\$token = Get-DemoT3AccessToken$|Open-DemoT3Connection .*-AccessToken \$token$|\$connection\.AccessToken = \$AccessToken$|\[string\] \$AccessToken$)' -Because 'the token may only be read from IMDS and handed to SqlConnection'
        }
        (@(Select-String -LiteralPath $runnerPath -Pattern 'access_token')).Count | Should -Be 1
        (Get-Content -LiteralPath $runnerPath -Raw) | Should -Not -Match '(?i)password|connectionstring\s*='
    }

    It 'prints only the documented result fields, none of them a token' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($runnerPath, [ref]$null, [ref]$null)
        $state = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$state' }, $false) | Select-Object -First 1
        $keys = @($state.Right.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $true).KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text })
        $keys | Should -Be @('marker', 'schemaVersion', 'label', 'status', 'server', 'database', 'batches', 'completed', 'attempts', 'loginFailures', 'transientFailures', 'loginWaitSeconds', 'elapsedSeconds', 'errorNumber', 'error', 'rows', 'rowsTruncated')
    }

    It 'keeps its one output line under the 4,096-byte Run Command limit, as printable ASCII' {
        . ([scriptblock]::Create((Get-RunnerFunction -Name 'Get-DemoT3ShortText', 'ConvertTo-DemoT3Value', 'ConvertTo-DemoT3Output')))
        $rows = foreach ($r in 1..20) {
            $row = [ordered]@{}
            foreach ($c in 1..24) { $row["column$c"] = ConvertTo-DemoT3Value -Value ('v' * 500) }
            $row
        }
        $state = [ordered]@{ marker = 'DBHUBDEMO-T3SQL'; schemaVersion = 1; status = 'Fail'; error = ("caf$([char]0xE9) " * 2000); rows = @($rows); rowsTruncated = $false }
        $line = ConvertTo-DemoT3Output -State $state -Limit 3500
        $line.Length | Should -BeLessOrEqual 3516
        $line | Should -Match '^DBHUBDEMO-T3SQL \{'
        $line | Should -Not -Match '[^\x20-\x7E]'
        $parsed = $line.Substring(16) | ConvertFrom-Json
        $parsed.rowsTruncated | Should -BeTrue
        $parsed.status | Should -Be 'Fail'
        (ConvertTo-DemoT3Value -Value ([datetime]'2026-10-20T12:00:00Z').ToUniversalTime()) | Should -Match '^2026-10-20T12:00:00'
        ConvertTo-DemoT3Value -Value ([System.DBNull]::Value) | Should -BeNullOrEmpty
        ConvertTo-DemoT3Value -Value 42 | Should -Be 42
    }

    It 'retries login failures within the wait, then reports Warning with the measured wait' {
        . ([scriptblock]::Create((Get-RunnerFunction -Name 'Get-DemoT3ShortText', 'Connect-DemoT3')))
        Mock -CommandName Start-Sleep -MockWith {}
        function Get-DemoT3AccessToken { 'fake-token-for-test' }
        function Get-DemoT3SqlErrorNumber { param([System.Exception] $Exception) [int]$Exception.Data['Number'] }
        $script:failures = 2
        $script:number = 18456
        function Open-DemoT3Connection {
            param([string] $Server, [string] $Database, [string] $AccessToken)
            if (-not $Server -or -not $Database -or $AccessToken -ne 'fake-token-for-test') {
                throw 'Connect-DemoT3 must pass the server, the database, and the token.'
            }
            if ($script:failures -gt 0) {
                $script:failures--
                $exception = [System.InvalidOperationException]::new('Login failed for user ''<token-identified principal>''.')
                $exception.Data['Number'] = $script:number
                throw $exception
            }
            [pscustomobject]@{ Connected = $true }
        }

        $state = [ordered]@{ attempts = 0; loginFailures = 0; transientFailures = 0; loginWaitSeconds = 0; errorNumber = 0; status = 'Fail'; error = '' }
        $connection = Connect-DemoT3 -State $state -Server 's' -Database 'd' -MaxLoginWaitSeconds 600 -MaxResumeWaitSeconds 300 -TransientErrorNumbers @(40613)
        $connection.Connected | Should -BeTrue
        $state['attempts'] | Should -Be 3
        $state['loginFailures'] | Should -Be 2
        Should -Invoke -CommandName Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 15 }

        $script:failures = 1
        $state = [ordered]@{ attempts = 0; loginFailures = 0; transientFailures = 0; loginWaitSeconds = 0; errorNumber = 0; status = 'Fail'; error = '' }
        Connect-DemoT3 -State $state -Server 's' -Database 'd' -MaxLoginWaitSeconds 0 -MaxResumeWaitSeconds 300 -TransientErrorNumbers @(40613) | Should -BeNullOrEmpty
        $state['status'] | Should -Be 'Warning'
        $state['error'] | Should -Match 'P6 group'

        # 40613 while a paused serverless database resumes is retried; anything else fails at once.
        $script:failures = 3
        $script:number = 40613
        $state = [ordered]@{ attempts = 0; loginFailures = 0; transientFailures = 0; loginWaitSeconds = 0; errorNumber = 0; status = 'Fail'; error = '' }
        (Connect-DemoT3 -State $state -Server 's' -Database 'd' -MaxLoginWaitSeconds 0 -MaxResumeWaitSeconds 300 -TransientErrorNumbers @(40613)).Connected | Should -BeTrue
        $state['transientFailures'] | Should -Be 3
        Should -Invoke -CommandName Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 10 }
        $script:failures = 1
        $script:number = 47073
        $state = [ordered]@{ attempts = 0; loginFailures = 0; transientFailures = 0; loginWaitSeconds = 0; errorNumber = 0; status = 'Fail'; error = '' }
        Connect-DemoT3 -State $state -Server 's' -Database 'd' -MaxLoginWaitSeconds 600 -MaxResumeWaitSeconds 300 -TransientErrorNumbers @(40613) | Should -BeNullOrEmpty
        $state['status'] | Should -Be 'Fail'
        $state['attempts'] | Should -Be 1
        $state['errorNumber'] | Should -Be 47073
    }

    It 'decodes the embedded batches in Windows PowerShell 5.1' -Skip:(-not $IsWindows -or -not (Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
        $batches = @("SELECT N'caf$([char]0xE9)' AS name;", "SELECT 2;`nSELECT 3;")
        $script = InModuleScope DbHubDemo -Parameters @{ Batches = $batches } { param($Batches) ConvertTo-DemoT3SqlScript -ServerFqdn 'azuresql01-abc123.database.windows.net' -DatabaseName 'ContosoCare' -Batch $Batches }
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($script.Text, [ref]$null, [ref]$null)
        $parts = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DemoT3Batch' }, $false) | ForEach-Object { $_.Extent.Text })
        $parts += @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -in '$payload', '$payloadSha256' }, $false) | ForEach-Object { $_.Extent.Text })
        $parts += '$decoded = Get-DemoT3Batch -Payload $payload -ExpectedSha256 $payloadSha256'
        $parts += '[System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes(($decoded -join [char]30)))'
        $harness = Join-Path -Path $TestDrive -ChildPath 'decode.ps1'
        [System.IO.File]::WriteAllText($harness, ($parts -join "`r`n"), [System.Text.Encoding]::ASCII)
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness
        $LASTEXITCODE | Should -Be 0
        [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(($output | Select-Object -Last 1))) | Should -Be ($batches -join [char]30)
    }
}

Describe 'Invoke-DemoT3SqlFromT1' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:runResponses = [System.Collections.Generic.Queue[object]]::new()
        $script:powerState = 'PowerState/running'
        $script:serverExists = $true
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            $scriptFile = ($ArgumentList | Where-Object { $_ -like '@*' } | Select-Object -First 1)
            $content = if ($scriptFile) { Get-Content -LiteralPath $scriptFile.Substring(1) -Raw } else { $null }
            $script:calls.Add([pscustomobject]@{ Arguments = $ArgumentList; ScriptFile = $scriptFile; ScriptText = $content })
            switch -Regex ($joined) {
                '^group show' { return New-AzResult -Json @{ name = 'rg-dbhub-demo'; tags = @{ deploymentId = 'abc123' } } }
                '^sql server show' {
                    if (-not $script:serverExists) { return New-AzResult -ExitCode 3 -StdErr 'ERROR: (ResourceNotFound) The Resource was not found.' }
                    return New-AzResult -Json @{ name = 'azuresql01-abc123'; fullyQualifiedDomainName = 'azuresql01-abc123.database.windows.net' }
                }
                '^vm get-instance-view' { return New-AzResult -Json @{ instanceView = @{ statuses = @(@{ code = 'ProvisioningState/succeeded' }, @{ code = $script:powerState }) } } }
                '^vm run-command invoke' { return $script:runResponses.Dequeue() }
                default { return New-AzResult -Json @{} }
            }
        }
    }

    It 'runs the generated script on T1 from a file, through action Run Command, and reads the result' {
        $script:runResponses.Enqueue((New-AzResult -Json (New-RunCommandResponse -Result @{ completed = 1; rows = @(@{ performance_monitoring = 'true'; is_db_owner = 1 }) })))
        $run = Invoke-DemoT3SqlFromT1 -Config (New-TestConfig) -Name Status
        $run.Status | Should -Be 'Pass'
        $run.Reason | Should -Be 'Ok'
        $run.Rows[0]['performance_monitoring'] | Should -Be 'true'
        $run.Result.checkId | Should -Be 'T3.SQL'
        $run.Result.area | Should -Be 't3'
        $run.Result.evidence.sources | Should -Be @('database/azuresql/900-status.sql')

        $invoke = $script:calls | Where-Object { ($_.Arguments -join ' ') -like 'vm run-command invoke*' }
        @($invoke).Count | Should -Be 1
        $arguments = $invoke.Arguments -join ' '
        $arguments | Should -Match '--resource-group rg-dbhub-demo --name sqlvm01 --command-id RunPowerShellScript --scripts @'
        $arguments | Should -Match '--subscription 11111111-2222-3333-4444-555555555555'
        $invoke.Arguments | Where-Object { $_ -match '["%]' } | Should -BeNullOrEmpty
        $invoke.ScriptText | Should -Match "'azuresql01-abc123\.database\.windows\.net'"
        $invoke.ScriptText | Should -Not -Match '\{\{'
        Test-Path -LiteralPath $invoke.ScriptFile.Substring(1) | Should -BeFalse -Because 'the temporary script file is deleted'
    }

    It 'reports Warning with the measured wait when the login never succeeds' {
        $script:runResponses.Enqueue((New-AzResult -Json (New-RunCommandResponse -Result @{ status = 'Warning'; completed = 0; loginFailures = 40; loginWaitSeconds = 601; error = 'The login still failed after 601 seconds.' })))
        $run = Invoke-DemoT3SqlFromT1 -Config (New-TestConfig) -Name Setup
        $run.Status | Should -Be 'Warning'
        $run.Reason | Should -Be 'LoginNotEffective'
        $run.Message | Should -Match '601 seconds'
        $run.Result.evidence.loginWaitSeconds | Should -Be 601
        $run.Result.remediation | Should -Match '24 hours'
    }

    It 'reports Fail with the failing batch' {
        $script:runResponses.Enqueue((New-AzResult -Json (New-RunCommandResponse -Result @{ status = 'Fail'; batches = 36; completed = 4; errorNumber = 2714; error = 'Batch 5 of 36 failed: There is already an object named x.' })))
        $run = Invoke-DemoT3SqlFromT1 -Config (New-TestConfig) -Name Setup
        $run.Status | Should -Be 'Fail'
        $run.Reason | Should -Be 'SqlFailed'
        $run.Message | Should -Match '4 of 36'
    }

    It 'runs nothing when T1 isn''t running' {
        $script:powerState = 'PowerState/deallocated'
        $run = Invoke-DemoT3SqlFromT1 -Config (New-TestConfig) -Name Status
        $run.Status | Should -Be 'Fail'
        $run.Reason | Should -Be 'T1NotRunning'
        $run.Result.evidence.t1PowerState | Should -Be 'deallocated'
        $script:calls | Where-Object { ($_.Arguments -join ' ') -like 'vm run-command*' } | Should -BeNullOrEmpty
    }

    It 'runs nothing when T3 doesn''t exist' {
        $script:serverExists = $false
        $run = Invoke-DemoT3SqlFromT1 -Config (New-TestConfig) -Name Status
        $run.Reason | Should -Be 'ServerNotFound'
        $script:calls | Where-Object { ($_.Arguments -join ' ') -like 'vm *' } | Should -BeNullOrEmpty
    }

    It 'fails, with the redacted standard error, when T1 prints no result line' {
        $fakeJwt = 'eyJ' + ('a' * 12) + '.' + ('b' * 12) + '.' + ('c' * 12)
        $script:runResponses.Enqueue((New-AzResult -Json (New-RunCommandResponse -Result @{} -NoMarker -StdErr "boom $fakeJwt")))
        $run = Invoke-DemoT3SqlFromT1 -Config (New-TestConfig) -Name Status
        $run.Reason | Should -Be 'RunCommandFailed'
        $run.Message | Should -Match 'boom'
        $run.Message | Should -Not -Match ([regex]::Escape($fakeJwt))
    }

    It 'retries while another Run Command is in progress' {
        $script:runResponses.Enqueue((New-AzResult -ExitCode 1 -StdErr 'ERROR: (Conflict) Run command extension execution is in progress.'))
        $script:runResponses.Enqueue((New-AzResult -Json (New-RunCommandResponse -Result @{})))
        (Invoke-DemoT3SqlFromT1 -Config (New-TestConfig) -Name Status).Status | Should -Be 'Pass'
        @($script:calls | Where-Object { ($_.Arguments -join ' ') -like 'vm run-command*' }).Count | Should -Be 2
    }

    It 'uses -DeploymentId without reading the resource group tag' {
        $script:runResponses.Enqueue((New-AzResult -Json (New-RunCommandResponse -Result @{})))
        Invoke-DemoT3SqlFromT1 -Config (New-TestConfig) -Query 'SELECT 1;' -DeploymentId 'abc123' -CheckId 'T3.WARMUP' | Out-Null
        $script:calls | Where-Object { ($_.Arguments -join ' ') -like 'group show*' } | Should -BeNullOrEmpty
    }

    It 'runs nothing on T1 with -WhatIf' {
        Invoke-DemoT3SqlFromT1 -Config (New-TestConfig) -Name Setup -WhatIf | Should -BeNullOrEmpty
        $script:calls | Where-Object { ($_.Arguments -join ' ') -like 'vm run-command*' } | Should -BeNullOrEmpty
    }
}

Describe 'Add-DemoT1ToT3AdminGroup' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:isMember = $false
        $script:visibleAfterChecks = 1
        $script:addError = ''
        $script:addStatus = 403
        $script:addFailures = 0
        $script:graph = 'https://graph.microsoft.com/v1.0'
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            $script:calls.Add($joined)
            if ($joined -like 'vm show*') {
                return New-AzResult -Json @{ name = 'sqlvm01'; identity = @{ type = 'SystemAssigned'; principalId = $script:principalId } }
            }
            return New-AzResult -Json @{}
        }
        # Microsoft Graph goes through Invoke-DemoRestRequest with a verified token, never 'az ad'.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            $script:calls.Add(('graph {0} {1} {2}' -f $Method, $Uri.Replace($script:graph, ''), $Body))
            if ($Uri -like '*/checkMemberGroups') {
                if (-not $script:isMember -and @($script:calls | Where-Object { $_ -like 'graph POST /groups/*/members/$ref*' }).Count -gt 0) {
                    $script:visibleAfterChecks--
                    if ($script:visibleAfterChecks -le 0) { $script:isMember = $true }
                }
                $value = if ($script:isMember) { @('77777777-7777-7777-7777-777777777777') } else { @() }
                return [pscustomobject]@{ ExitCode = 0; StdOut = (@{ value = $value } | ConvertTo-Json); StdErr = ''; StatusCode = 200 }
            }
            if ($Uri -like '*/members/$ref') {
                if ($script:addFailures -gt 0) {
                    $script:addFailures--
                    return [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ('HTTP {0}: {1}' -f $script:addStatus, $script:addError); StatusCode = $script:addStatus }
                }
                return [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = ''; StatusCode = 204 }
            }
            [pscustomobject]@{ ExitCode = 1; StdOut = ''; StdErr = ('HTTP 404: unexpected {0}' -f $Uri); StatusCode = 404 }
        }
    }

    It 'passes without changes when T1 is already a member' {
        $script:isMember = $true
        $result = Add-DemoT1ToT3AdminGroup -Config (New-TestConfig) -PrincipalId $script:principalId
        $result.status | Should -Be 'Pass'
        $result.checkId | Should -Be 'T3.ADMINGROUP'
        $script:calls | Where-Object { $_ -like 'graph POST /groups/*' } | Should -BeNullOrEmpty
        $script:calls | Should -Contain ('graph POST /directoryObjects/{0}/checkMemberGroups {{"groupIds":["77777777-7777-7777-7777-777777777777"]}}' -f $script:principalId)
    }

    It 'adds T1''s identity, waits until Microsoft Graph reports it, and passes' {
        $script:visibleAfterChecks = 2
        $result = Add-DemoT1ToT3AdminGroup -Config (New-TestConfig) -SettleSeconds 0
        $result.status | Should -Be 'Pass'
        $result.evidence.principalId | Should -Be $script:principalId
        $result.evidence.addedAtUtc | Should -Not -BeNullOrEmpty
        $script:calls | Should -Contain ('graph POST /groups/77777777-7777-7777-7777-777777777777/members/$ref {{"@odata.id":"https://graph.microsoft.com/v1.0/directoryObjects/{0}"}}' -f $script:principalId)
        $script:calls | Where-Object { $_ -like 'vm show*' } | Should -Not -BeNullOrEmpty
        # No 'az ad': Microsoft Graph is called with a verified token. Azure resource commands always have --subscription.
        $script:calls | Where-Object { $_ -like 'ad *' } | Should -BeNullOrEmpty
        $script:calls | Where-Object { $_ -like 'vm *' -and $_ -notmatch '--subscription 11111111-2222-3333-4444-555555555555' } | Should -BeNullOrEmpty
    }

    It 'asks for manual action, with the exact command, when the caller can''t add members' {
        $script:addFailures = 1
        $script:addError = '{"error":{"code":"Authorization_RequestDenied","message":"Insufficient privileges to complete the operation."}}'
        $result = Add-DemoT1ToT3AdminGroup -Config (New-TestConfig) -PrincipalId $script:principalId
        $result.status | Should -Be 'Manual action required'
        $result.remediation | Should -Match ([regex]::Escape("az ad group member add --group 77777777-7777-7777-7777-777777777777 --member-id $($script:principalId)"))
        $result.remediation | Should -Match 'default account'
        $result.remediation | Should -Match 'interactively'
    }

    It 'retries an identity that Microsoft Graph doesn''t know yet' {
        $script:addFailures = 2
        $script:addStatus = 404
        $script:addError = '{"error":{"code":"Request_ResourceNotFound","message":"Resource ''88888888-8888-8888-8888-888888888888'' does not exist or one of its queried reference-property objects are not present."}}'
        (Add-DemoT1ToT3AdminGroup -Config (New-TestConfig) -PrincipalId $script:principalId -SettleSeconds 0).status | Should -Be 'Pass'
        @($script:calls | Where-Object { $_ -like 'graph POST /groups/*/members/$ref*' }).Count | Should -Be 3

        $script:calls.Clear()
        $script:isMember = $false
        $script:addFailures = 9
        (Add-DemoT1ToT3AdminGroup -Config (New-TestConfig) -PrincipalId $script:principalId).status | Should -Be 'Manual action required'
        @($script:calls | Where-Object { $_ -like 'graph POST /groups/*/members/$ref*' }).Count | Should -Be 4
    }

    It 'passes when Microsoft Graph says the member already exists' {
        $script:addFailures = 1
        $script:addStatus = 400
        $script:addError = '{"error":{"code":"Request_BadRequest","message":"One or more added object references already exist for the following modified properties: ''members''."}}'
        (Add-DemoT1ToT3AdminGroup -Config (New-TestConfig) -PrincipalId $script:principalId).status | Should -Be 'Pass'
    }

    It 'warns when Microsoft Graph doesn''t report the new membership in time' {
        $script:visibleAfterChecks = 99
        $result = Add-DemoT1ToT3AdminGroup -Config (New-TestConfig) -PrincipalId $script:principalId -WaitSeconds 0
        $result.status | Should -Be 'Warning'
    }

    It 'fails when T1 has no identity' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -ParameterFilter { $ArgumentList[0] -eq 'vm' } -MockWith { New-AzResult -Json @{ name = 'sqlvm01' } }
        (Add-DemoT1ToT3AdminGroup -Config (New-TestConfig)).status | Should -Be 'Fail'
    }

    It 'adds nothing with -WhatIf' {
        Add-DemoT1ToT3AdminGroup -Config (New-TestConfig) -PrincipalId $script:principalId -WhatIf | Should -BeNullOrEmpty
        $script:calls | Where-Object { $_ -like 'graph POST /groups/*' } | Should -BeNullOrEmpty
    }
}
Describe 'Resolve-DemoT3FreeOfferError' {
    It 'recognizes a free-offer rejection: <Name>' -ForEach @(
        @{ Name = 'Azure CLI text'; Text = "ERROR: (DeploymentFailed) At least one resource deployment operation failed.`nCode: DeploymentFailed`nException Details:`t(ProvisioningDisabled) Cannot update paid database to free database.`n`tCode: ProvisioningDisabled`n`tMessage: Cannot update paid database to free database."; Code = 'ProvisioningDisabled' }
        @{ Name = 'deployment JSON'; Text = '{"status":"Failed","error":{"code":"DeploymentFailed","message":"At least one resource deployment operation failed.","details":[{"code":"ResourceDeploymentFailure","target":"/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Sql/servers/azuresql01-abc123/databases/ContosoCare","message":"The resource write operation failed.","details":[{"code":"FreeDatabaseLimitReached","message":"The subscription has reached its free database limit."}]}]}}'; Code = 'FreeDatabaseLimitReached' }
        @{ Name = 'property name'; Text = 'ERROR: (InvalidParameterValue) Invalid value given for parameter useFreeLimit. Specify a valid parameter value.'; Code = 'InvalidParameterValue' }
        @{ Name = 'free offer region'; Text = 'ERROR: (ProvisioningDisabled) The free offer is not available in region westus3 for this subscription.'; Code = 'ProvisioningDisabled' }
    ) {
        $verdict = Resolve-DemoT3FreeOfferError -ErrorText $Text
        $verdict.IsFreeOfferError | Should -BeTrue
        $verdict.Code | Should -Be $Code
        $verdict.Result.checkId | Should -Be 'T3.FREEOFFER'
        $verdict.Result.status | Should -Be 'Warning'
        $verdict.Result.evidence.useFreeLimit | Should -BeFalse
        $verdict.Message | Should -Not -BeNullOrEmpty
    }

    It 'leaves other errors alone: <Name>' -ForEach @(
        @{ Name = 'policy denial'; Text = 'ERROR: (RequestDisallowedByPolicy) Resource azuresql01-abc123 was disallowed by policy.' }
        @{ Name = 'generic code only'; Text = 'ERROR: (ProvisioningDisabled) Provisioning is restricted in this region for this subscription.' }
        @{ Name = 'unrelated free text'; Text = 'ERROR: (SubnetIsFull) Subnet snet-pe has no free IP addresses left.' }
        @{ Name = 'conflict'; Text = 'ERROR: (Conflict) Another operation is in progress on server azuresql01-abc123.' }
        @{ Name = 'empty'; Text = '' }
    ) {
        $verdict = Resolve-DemoT3FreeOfferError -ErrorText $Text
        $verdict.IsFreeOfferError | Should -BeFalse
        $verdict.Result | Should -BeNullOrEmpty
    }

    It 'redacts and shortens the message it reports' {
        $fakeJwt = 'eyJ' + ('a' * 12) + '.' + ('b' * 12) + '.' + ('c' * 12)
        $verdict = Resolve-DemoT3FreeOfferError -ErrorText ("ERROR: (ProvisioningDisabled) Cannot update paid database to free database. $fakeJwt " + ('x' * 600))
        $verdict.Message | Should -Not -Match ([regex]::Escape($fakeJwt))
        $verdict.Message.Length | Should -BeLessOrEqual 303
    }
}

Describe 'Remove-DemoT3' {
    BeforeEach {
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:exists = @{ privateEndpoint = $true; server = $true }
        $script:deleteFails = $false
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            $script:calls.Add($joined)
            switch -Regex ($joined) {
                '^group show' { return New-AzResult -Json @{ tags = @{ deploymentId = 'abc123' } } }
                '^network private-endpoint show' { if ($script:exists.privateEndpoint) { return New-AzResult -Json @{ name = 'pe-dbhub-demo-azuresql01' } } else { return New-AzResult -ExitCode 3 -StdErr 'ERROR: (ResourceNotFound) not found' } }
                '^sql server show' { if ($script:exists.server) { return New-AzResult -Json @{ name = 'azuresql01-abc123' } } else { return New-AzResult -ExitCode 3 -StdErr 'ERROR: (ResourceNotFound) not found' } }
                'delete' { if ($script:deleteFails) { return New-AzResult -ExitCode 1 -StdErr 'ERROR: (ScopeLocked) The scope is locked.' } else { return New-AzResult } }
                default { return New-AzResult -Json @{} }
            }
        }
    }

    It 'makes no Azure calls with -WhatIf' {
        Remove-DemoT3 -Config (New-TestConfig) -WhatIf | Should -BeNullOrEmpty
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
    }

    It 'deletes the private endpoint, then the server, and keeps the private DNS zone' {
        $result = Remove-DemoT3 -Config (New-TestConfig) -Confirm:$false
        $result.status | Should -Be 'Pass'
        $result.checkId | Should -Be 'T3.REMOVE'
        $deletes = @($script:calls | Where-Object { $_ -match ' delete ' })
        $deletes.Count | Should -Be 2
        $deletes[0] | Should -Match '^network private-endpoint delete --name pe-dbhub-demo-azuresql01 --resource-group rg-dbhub-demo'
        $deletes[1] | Should -Match '^sql server delete --name azuresql01-abc123 --resource-group rg-dbhub-demo --yes'
        $script:calls | Where-Object { $_ -match 'private-dns' } | Should -BeNullOrEmpty
        $result.evidence.keptPrivateDnsZone | Should -BeTrue
    }

    It 'is idempotent when T3 is already gone' {
        $script:exists = @{ privateEndpoint = $false; server = $false }
        $result = Remove-DemoT3 -Config (New-TestConfig) -DeploymentId 'abc123' -Confirm:$false
        $result.status | Should -Be 'Pass'
        $result.message | Should -Match 'already removed'
        $script:calls | Where-Object { $_ -match ' delete ' } | Should -BeNullOrEmpty
        $script:calls | Where-Object { $_ -like 'group show*' } | Should -BeNullOrEmpty
    }

    It 'fails, and says why, when a delete fails' {
        $script:deleteFails = $true
        $result = Remove-DemoT3 -Config (New-TestConfig) -Confirm:$false
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'ScopeLocked'
    }
}

Describe 'Test-DemoT3' {
    BeforeEach {
        $script:server = @{
            id = $script:serverId; name = 'azuresql01-abc123'; state = 'Ready'; fullyQualifiedDomainName = 'azuresql01-abc123.database.windows.net'
            publicNetworkAccess = 'Disabled'; minimalTlsVersion = '1.2'
            administrators = @{ administratorType = 'ActiveDirectory'; azureAdOnlyAuthentication = $true; principalType = 'Group'; sid = '77777777-7777-7777-7777-777777777777'; login = 'sg-test' }
        }
        $script:database = @{ name = 'ContosoCare'; status = 'Paused'; currentSku = @{ name = 'GP_S_Gen5'; tier = 'GeneralPurpose'; capacity = 1 }; autoPauseDelay = 15; minCapacity = 0.5; maxSizeBytes = 34359738368; useFreeLimit = $true; freeLimitExhaustionBehavior = 'BillOverUsage' }
        $script:firewallRules = @()
        $script:vnetRules = @()
        $script:endpoint = @{ name = 'pe-dbhub-demo-azuresql01'; provisioningState = 'Succeeded'; privateLinkServiceConnections = @(@{ privateLinkServiceId = $script:serverId; privateLinkServiceConnectionState = @{ status = 'Approved' } }) }
        $script:zoneGroups = @(@{ name = 'default'; privateDnsZoneConfigs = @(@{ privateDnsZoneId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/privateDnsZones/privatelink.database.windows.net' }) })
        $script:links = @(@{ name = 'link-vnet-dbhub-demo'; virtualNetwork = @{ id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/virtualNetworks/vnet-dbhub-demo' } })
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            switch -Regex ($joined) {
                '^group show' { return New-AzResult -Json @{ tags = @{ deploymentId = 'abc123' } } }
                '^sql server show' { if ($script:server) { return New-AzResult -Json $script:server } else { return New-AzResult -ExitCode 3 -StdErr 'not found' } }
                '^sql db show' { return New-AzResult -Json $script:database }
                '^sql server firewall-rule list' { return New-AzResult -Json (ConvertTo-Json -InputObject @($script:firewallRules) -Depth 5 -Compress) }
                '^sql server vnet-rule list' { return New-AzResult -Json (ConvertTo-Json -InputObject @($script:vnetRules) -Depth 5 -Compress) }
                '^network private-endpoint show' { return New-AzResult -Json $script:endpoint }
                '^network private-endpoint dns-zone-group list' { return New-AzResult -Json (ConvertTo-Json -InputObject @($script:zoneGroups) -Depth 8 -Compress) }
                '^network private-dns link vnet list' { return New-AzResult -Json (ConvertTo-Json -InputObject @($script:links) -Depth 8 -Compress) }
                default { return New-AzResult -Json @{} }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith {
            [pscustomobject]@{ Status = 'Pass'; Reason = 'Ok'; Message = 'ok'; Data = @{}; Rows = @(@{ performance_monitoring = 'true'; seed_status = 'Completed'; query_store_state = 'READ_WRITE' }); Result = [pscustomobject]@{ remediation = '' } }
        }
    }

    It 'passes every check for a healthy private-mode T3 on the free offer' {
        $results = Test-DemoT3 -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $true
        @($results.checkId) | Should -Be @('T3.EXISTS', 'T3.ENTRAONLY', 'T3.NETWORK', 'T3.DATABASE', 'T3.FREEOFFER', 'T3.PROPERTY')
        $results | Where-Object { $_.status -ne 'Pass' } | Should -BeNullOrEmpty
        ($results | Where-Object checkId -eq 'T3.NETWORK').evidence.privateEndpointConnection | Should -Be 'Approved'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -Times 1 -Exactly -ParameterFilter { $Name -eq 'Status' -and $CheckId -eq 'T3.PROPERTY' }
    }

    It 'fails the network check in private mode when the zone isn''t linked or public access is on' {
        $script:links = @()
        $script:server.publicNetworkAccess = 'Enabled'
        $network = Test-DemoT3 -Config (New-TestConfig) -NetworkMode private -SkipSqlCheck | Where-Object checkId -eq 'T3.NETWORK'
        $network.status | Should -Be 'Fail'
        $network.message | Should -Match 'not Disabled'
        $network.message | Should -Match "isn't linked"
    }

    It 'passes public mode with only the snet-sqlvm VNet rule, and fails it with any IP firewall rule' {
        $script:server.publicNetworkAccess = 'Enabled'
        $script:vnetRules = @(@{ name = 'snet-sqlvm'; state = 'Ready'; virtualNetworkSubnetId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-dbhub-demo/providers/Microsoft.Network/virtualNetworks/vnet-dbhub-demo/subnets/snet-sqlvm' })
        (Test-DemoT3 -Config (New-TestConfig) -NetworkMode public -SkipSqlCheck | Where-Object checkId -eq 'T3.NETWORK').status | Should -Be 'Pass'
        $script:firewallRules = @(@{ name = 'AllowAllWindowsAzureIps'; startIpAddress = '0.0.0.0'; endIpAddress = '0.0.0.0' })
        $network = Test-DemoT3 -Config (New-TestConfig) -NetworkMode public -SkipSqlCheck | Where-Object checkId -eq 'T3.NETWORK'
        $network.status | Should -Be 'Fail'
        $network.message | Should -Match 'AllowAllWindowsAzureIps'
    }

    It 'fails Entra-only when SQL authentication is allowed or the administrator isn''t the P6 group' {
        $script:server.administrators.azureAdOnlyAuthentication = $false
        (Test-DemoT3 -Config (New-TestConfig) -NetworkMode private -SkipSqlCheck | Where-Object checkId -eq 'T3.ENTRAONLY').status | Should -Be 'Fail'
        $script:server.administrators.azureAdOnlyAuthentication = $true
        $script:server.administrators.sid = '99999999-9999-9999-9999-999999999999'
        (Test-DemoT3 -Config (New-TestConfig) -NetworkMode private -SkipSqlCheck | Where-Object checkId -eq 'T3.ENTRAONLY').message | Should -Match 'P6 group'
    }

    It 'reports the free offer: Warning without it, Not selected when off, Warning with AutoPause' {
        $script:database.useFreeLimit = $false
        $script:database.Remove('freeLimitExhaustionBehavior')
        (Test-DemoT3 -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $true -SkipSqlCheck | Where-Object checkId -eq 'T3.FREEOFFER').status | Should -Be 'Warning'
        (Test-DemoT3 -Config (New-TestConfig -FreeOffer 'off') -NetworkMode private -SkipSqlCheck | Where-Object checkId -eq 'T3.FREEOFFER').status | Should -Be 'Not selected'
        $script:database.useFreeLimit = $true
        $script:database.freeLimitExhaustionBehavior = 'AutoPause'
        (Test-DemoT3 -Config (New-TestConfig) -NetworkMode private -SkipSqlCheck | Where-Object checkId -eq 'T3.FREEOFFER').message | Should -Match 'pause until next month'
    }

    It 'warns about database drift from the profile and the configured auto-pause' {
        $script:database.autoPauseDelay = 60
        $database = Test-DemoT3 -Config (New-TestConfig) -NetworkMode private -SkipSqlCheck | Where-Object checkId -eq 'T3.DATABASE'
        $database.status | Should -Be 'Warning'
        $database.message | Should -Match 'auto-pause after 60 minutes'
    }

    It 'expects the profile''s auto-pause delay when the configuration has none, as the template does' {
        $config = New-TestConfig
        $config['profile'] = 'demo-day'
        $config.Remove('t3AutoPauseMinutes')
        $script:database.currentSku.capacity = 2
        $script:database.autoPauseDelay = 60
        $database = Test-DemoT3 -Config $config -NetworkMode private -SkipSqlCheck | Where-Object checkId -eq 'T3.DATABASE'
        $database.status | Should -Be 'Pass'
        $database.message | Should -Match 'auto-pause after 60 minutes'
    }

    It 'fails the property check when the property is missing, and warns when T1 can''t run the query' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith {
            [pscustomobject]@{ Status = 'Pass'; Reason = 'Ok'; Message = 'ok'; Data = @{}; Rows = @(@{ performance_monitoring = $null }); Result = [pscustomobject]@{ remediation = '' } }
        }
        (Test-DemoT3 -Config (New-TestConfig) -NetworkMode private | Where-Object checkId -eq 'T3.PROPERTY').status | Should -Be 'Fail'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith {
            [pscustomobject]@{ Status = 'Fail'; Reason = 'T1NotRunning'; Message = 'T1 is deallocated.'; Data = $null; Rows = @(); Result = [pscustomobject]@{ remediation = 'Start T1.' } }
        }
        (Test-DemoT3 -Config (New-TestConfig) -NetworkMode private | Where-Object checkId -eq 'T3.PROPERTY').status | Should -Be 'Warning'
    }

    It 'reports only T3.EXISTS when T3 doesn''t exist' {
        $script:server = $null
        $results = Test-DemoT3 -Config (New-TestConfig) -NetworkMode private
        @($results).Count | Should -Be 1
        $results[0].checkId | Should -Be 'T3.EXISTS'
        $results[0].status | Should -Be 'Fail'
    }

    It 'skips the T-SQL check with -SkipSqlCheck, and needs the effective mode when networkMode is auto' {
        (Test-DemoT3 -Config (New-TestConfig) -NetworkMode private -SkipSqlCheck | Where-Object checkId -eq 'T3.PROPERTY').status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -Times 0 -Exactly
        { Test-DemoT3 -Config (New-TestConfig) } | Should -Throw '*-NetworkMode public or private*'
    }
}

Describe 'Invoke-DemoT3WarmUp' {
    BeforeEach {
        $script:databaseStatus = 'Paused'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            switch -Regex ($joined) {
                '^group show' { return New-AzResult -Json @{ tags = @{ deploymentId = 'abc123' } } }
                '^sql db show' { if ($script:databaseStatus) { return New-AzResult -Json @{ name = 'ContosoCare'; status = $script:databaseStatus } } else { return New-AzResult -ExitCode 3 -StdErr 'not found' } }
                default { return New-AzResult -Json @{} }
            }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith {
            [pscustomobject]@{ Status = 'Pass'; Reason = 'Ok'; Message = 'ok'; Data = @{ elapsedSeconds = 58; transientFailures = 4; loginFailures = 0; loginWaitSeconds = 0 }; Rows = @(@{ performance_monitoring = 'true' }); Result = [pscustomobject]@{ remediation = '' } }
        }
    }

    It 'wakes a paused T3, reports how long it took, and confirms the property' {
        $results = Invoke-DemoT3WarmUp -Config (New-TestConfig)
        $warm = $results | Where-Object checkId -eq 'T3.WARMUP'
        $warm.status | Should -Be 'Pass'
        $warm.message | Should -Match 'was Paused'
        $warm.message | Should -Match '58 seconds'
        ($results | Where-Object checkId -eq 'T3.PROPERTY').status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -Times 1 -Exactly -ParameterFilter { $Name -eq 'Status' -and $DeploymentId -eq 'abc123' }
    }

    It 'fails when T3 doesn''t exist, so start-demo can recreate it' {
        $script:databaseStatus = $null
        $results = Invoke-DemoT3WarmUp -Config (New-TestConfig)
        ($results | Where-Object checkId -eq 'T3.WARMUP').status | Should -Be 'Fail'
        ($results | Where-Object checkId -eq 'T3.PROPERTY').status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -Times 0 -Exactly
    }

    It 'warns when T1''s login isn''t effective yet' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoT3SqlFromT1 -MockWith {
            [pscustomobject]@{ Status = 'Warning'; Reason = 'LoginNotEffective'; Message = 'not yet'; Data = @{ loginWaitSeconds = 120 }; Rows = @(); Result = [pscustomobject]@{ remediation = 'Run it again later.' } }
        }
        $results = Invoke-DemoT3WarmUp -Config (New-TestConfig)
        ($results | Where-Object checkId -eq 'T3.WARMUP').status | Should -Be 'Warning'
        ($results | Where-Object checkId -eq 'T3.PROPERTY').status | Should -Be 'Not selected'
    }
}

Describe 'Get-DemoDeploymentParameter: T3 parameters' {
    It 'requires the resolved free-offer setting when t3FreeOffer is auto' {
        { Get-DemoDeploymentParameter -Config (New-TestConfig) -NetworkMode private } | Should -Throw '*-T3UseFreeLimit*'
    }

    It 'passes the resolved free-offer setting: <_>' -ForEach @($true, $false) {
        (Get-DemoDeploymentParameter -Config (New-TestConfig) -NetworkMode private -T3UseFreeLimit $_).parameters.t3UseFreeLimit.value | Should -Be $_
    }

    It 'defaults to no free offer when t3FreeOffer is off, and refuses to turn it on' {
        $off = New-TestConfig -FreeOffer 'off'
        (Get-DemoDeploymentParameter -Config $off -NetworkMode private).parameters.t3UseFreeLimit.value | Should -BeFalse
        (Get-DemoDeploymentParameter -Config $off -NetworkMode private -T3UseFreeLimit $false).parameters.t3UseFreeLimit.value | Should -BeFalse
        { Get-DemoDeploymentParameter -Config $off -NetworkMode private -T3UseFreeLimit $true } | Should -Throw '*off*'
    }

    It 'passes the P6 group and the auto-pause delay, and the group name only when it is known' {
        $config = New-TestConfig
        $config['t3AutoPauseMinutes'] = 30
        $parameters = (Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $true).parameters
        $parameters.t3AdminGroupObjectId.value | Should -Be '77777777-7777-7777-7777-777777777777'
        $parameters.t3AutoPauseMinutes.value | Should -Be 30
        $parameters.Contains('t3AdminGroupDisplayName') | Should -BeFalse
        $named = (Get-DemoDeploymentParameter -Config $config -NetworkMode private -T3UseFreeLimit $true -T3AdminGroupDisplayName ('g' * 200)).parameters
        $named.t3AdminGroupDisplayName.value | Should -Be ('g' * 128)
    }

    It 'declares every T3 parameter it produces in infra/main.bicep' {
        $declared = Select-String -Path (Join-Path -Path $repoRoot -ChildPath 'infra/main.bicep') -Pattern '^param (\w+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
        $parameters = (Get-DemoDeploymentParameter -Config (New-TestConfig) -NetworkMode public -T3UseFreeLimit $true -T3AdminGroupDisplayName 'sg-test').parameters
        foreach ($name in @($parameters.Keys | Where-Object { $_ -like 't3*' })) {
            $declared | Should -Contain $name
        }
        @($parameters.Keys | Where-Object { $_ -like 't3*' }).Count | Should -Be 4
    }
}
