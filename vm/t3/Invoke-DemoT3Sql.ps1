<#
.SYNOPSIS
Runs T-SQL on T3 (Azure SQL Database) from T1 with T1's system-assigned managed identity.

.DESCRIPTION
VM-side: Windows PowerShell 5.1, ASCII-only. Invoke-DemoT3SqlFromT1 (scripts/modules/DbHubDemo) fills in the
placeholders below and runs the result on sqlvm01 with action Run Command (RunPowerShellScript), as SYSTEM
(ADR 0007, ADR 0008). The T-SQL batches travel inside the script, gzip-compressed and Base64-encoded with
their SHA-256, so no T-SQL travels on a command line.

The script:
- gets an access token for Azure SQL (resource https://database.windows.net/) from the instance metadata
  service (IMDS), as Microsoft documents for a VM's managed identity;
- connects to the server's FQDN with System.Data.SqlClient and that token. In private mode, the private DNS
  zone linked to the VNet resolves the FQDN to the private endpoint; in public mode, the VNet rule admits
  snet-sqlvm;
- retries login failures (error 18456) for up to the login wait, because T1's membership in the P6 group can
  take time to apply, and Azure SQL's documented transient errors (for example 40613 while a paused
  serverless database resumes) for up to the resume wait;
- runs the batches in order, keeps the last result set (at most 20 rows), and stops at the first error;
- prints exactly one line, DBHUBDEMO-T3SQL followed by compact JSON, kept well under the 4,096-byte Run
  Command output limit. The status is Pass, Warning (the login never succeeded within the wait), or Fail.
It never prints, logs, or stores the access token.

Sources (checked 2026-10-20):
- https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/tutorial-windows-managed-identities-vm-access
- https://learn.microsoft.com/azure/virtual-machines/windows/run-command
- https://learn.microsoft.com/azure/azure-sql/database/troubleshoot-common-errors-issues
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Filled in by Invoke-DemoT3SqlFromT1.
$server = '{{SERVER}}'
$database = '{{DATABASE}}'
$label = '{{LABEL}}'
$maxLoginWaitSeconds = [int]'{{MAX_LOGIN_WAIT_SECONDS}}'
$maxResumeWaitSeconds = [int]'{{MAX_RESUME_WAIT_SECONDS}}'
$batchTimeoutSeconds = [int]'{{BATCH_TIMEOUT_SECONDS}}'
$payloadSha256 = '{{PAYLOAD_SHA256}}'
$payload = '{{PAYLOAD}}'

# Azure SQL's documented transient error numbers; the client retries them.
$transientErrorNumbers = @(615, 926, 4060, 4221, 40197, 40501, 40613, 49918, 49919, 49920)
$outputLimit = 3500

function Get-DemoT3ShortText {
    # One line of printable ASCII, at most Length characters.
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text,

        [int] $Length
    )
    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }
    $clean = (($Text -replace '\s+', ' ') -replace '[^\x20-\x7E]', '?').Trim()
    if ($clean.Length -gt $Length) {
        return $clean.Substring(0, $Length) + '...'
    }
    return $clean
}

function Get-DemoT3Batch {
    # Decodes the embedded batches, after checking their SHA-256.
    param(
        [string] $Payload,
        [string] $ExpectedSha256
    )
    $bytes = [System.Convert]::FromBase64String($Payload)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    if ($hash -ne $ExpectedSha256) {
        throw 'The embedded T-SQL does not match its SHA-256, so nothing was run.'
    }
    $compressed = [System.IO.MemoryStream]::new($bytes)
    $gzip = [System.IO.Compression.GZipStream]::new($compressed, [System.IO.Compression.CompressionMode]::Decompress)
    $reader = [System.IO.StreamReader]::new($gzip, [System.Text.Encoding]::UTF8)
    try {
        $json = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
        $gzip.Dispose()
        $compressed.Dispose()
    }
    $batches = [System.Collections.Generic.List[string]]::new()
    foreach ($item in ($json | ConvertFrom-Json)) {
        $batches.Add([string]$item)
    }
    return , $batches.ToArray()
}

function Get-DemoT3AccessToken {
    # The documented IMDS request for an Azure SQL token. The token stays in memory.
    $uri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fdatabase.windows.net%2F'
    $response = Invoke-WebRequest -Uri $uri -Method Get -Headers @{ Metadata = 'true' } -UseBasicParsing -TimeoutSec 30
    return [string](($response.Content | ConvertFrom-Json).access_token)
}

function Get-DemoT3SqlErrorNumber {
    # The SQL error number inside an exception, or 0 when it isn't a SQL error.
    param([System.Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.Data.SqlClient.SqlException]) {
            return [int]$current.Number
        }
        $current = $current.InnerException
    }
    return 0
}

function Open-DemoT3Connection {
    param(
        [string] $Server,
        [string] $Database,
        [string] $AccessToken
    )
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = 'tcp:' + $Server + ',1433'
    $builder['Initial Catalog'] = $Database
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $false
    $builder['Connect Timeout'] = 30
    $builder['Application Name'] = 'DbHubDemo.T3Sql'
    $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    $connection.AccessToken = $AccessToken
    try {
        $connection.Open()
    }
    catch {
        $connection.Dispose()
        throw
    }
    return $connection
}

function Connect-DemoT3 {
    # Returns an open connection, or $null with the status and error set in the state.
    param(
        [System.Collections.IDictionary] $State,
        [string] $Server,
        [string] $Database,
        [int] $MaxLoginWaitSeconds,
        [int] $MaxResumeWaitSeconds,
        [int[]] $TransientErrorNumbers
    )
    $loginClock = [System.Diagnostics.Stopwatch]::StartNew()
    $transientClock = $null
    while ($true) {
        $State['attempts'] = [int]$State['attempts'] + 1
        try {
            $token = Get-DemoT3AccessToken
        }
        catch {
            $State['status'] = 'Fail'
            $State['error'] = 'The managed identity token request to IMDS failed: ' + (Get-DemoT3ShortText -Text $_.Exception.Message -Length 300)
            return $null
        }
        $number = 0
        $message = ''
        try {
            $connection = Open-DemoT3Connection -Server $Server -Database $Database -AccessToken $token
            $State['loginWaitSeconds'] = [int]$loginClock.Elapsed.TotalSeconds
            return $connection
        }
        catch {
            $number = Get-DemoT3SqlErrorNumber -Exception $_.Exception
            $message = Get-DemoT3ShortText -Text $_.Exception.Message -Length 300
        }
        $State['errorNumber'] = $number
        if ($number -eq 18456) {
            $State['loginFailures'] = [int]$State['loginFailures'] + 1
            $State['loginWaitSeconds'] = [int]$loginClock.Elapsed.TotalSeconds
            if ($loginClock.Elapsed.TotalSeconds + 15 -le $MaxLoginWaitSeconds) {
                Start-Sleep -Seconds 15
                continue
            }
            $State['status'] = 'Warning'
            $State['error'] = ('The login still failed after {0} seconds; T1''s membership in the P6 group may not be effective yet. {1}' -f $State['loginWaitSeconds'], $message)
            return $null
        }
        if ($TransientErrorNumbers -contains $number) {
            $State['transientFailures'] = [int]$State['transientFailures'] + 1
            if ($null -eq $transientClock) {
                $transientClock = [System.Diagnostics.Stopwatch]::StartNew()
            }
            if ($transientClock.Elapsed.TotalSeconds + 10 -le $MaxResumeWaitSeconds) {
                Start-Sleep -Seconds 10
                continue
            }
            $State['status'] = 'Fail'
            $State['error'] = ('T3 was still unavailable after {0} seconds. {1}' -f [int]$transientClock.Elapsed.TotalSeconds, $message)
            return $null
        }
        $State['status'] = 'Fail'
        $State['error'] = 'The connection failed: ' + $message
        return $null
    }
}

function ConvertTo-DemoT3Value {
    # JSON-friendly and short: numbers and booleans as they are, anything else as short ASCII text.
    param(
        [AllowNull()]
        [object] $Value
    )
    if ($null -eq $Value -or $Value -is [System.DBNull]) {
        return $null
    }
    if ($Value -is [bool] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double]) {
        return $Value
    }
    if ($Value -is [datetime]) {
        return $Value.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return Get-DemoT3ShortText -Text ([string]$Value) -Length 120
}

function Read-DemoT3ResultSet {
    # Keeps at most 20 rows and 24 columns of the current result set in the state.
    param(
        [System.Data.IDataReader] $Reader,
        [System.Collections.IDictionary] $State
    )
    $columnCount = [System.Math]::Min($Reader.FieldCount, 24)
    $rows = [System.Collections.Generic.List[object]]::new()
    $truncated = $Reader.FieldCount -gt 24
    while ($Reader.Read()) {
        if ($rows.Count -ge 20) {
            $truncated = $true
            break
        }
        $row = [ordered]@{}
        for ($i = 0; $i -lt $columnCount; $i++) {
            $name = $Reader.GetName($i)
            if (-not $name) {
                $name = 'column' + $i
            }
            $row[$name] = ConvertTo-DemoT3Value -Value $Reader.GetValue($i)
        }
        $rows.Add($row)
    }
    $State['rows'] = $rows.ToArray()
    $State['rowsTruncated'] = $truncated
}

function Invoke-DemoT3Batch {
    param(
        [System.Data.SqlClient.SqlConnection] $Connection,
        [string] $Batch,
        [int] $TimeoutSeconds,
        [System.Collections.IDictionary] $State
    )
    $command = $Connection.CreateCommand()
    try {
        $command.CommandText = $Batch
        $command.CommandTimeout = $TimeoutSeconds
        $reader = $command.ExecuteReader()
        try {
            do {
                if ($reader.FieldCount -gt 0) {
                    Read-DemoT3ResultSet -Reader $reader -State $State
                }
            } while ($reader.NextResult())
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $command.Dispose()
    }
}

function ConvertTo-DemoT3Output {
    # One line under the limit: the rows go first, then the error is shortened.
    param(
        [System.Collections.IDictionary] $State,
        [int] $Limit
    )
    $json = ConvertTo-Json -InputObject $State -Depth 5 -Compress
    if ($json.Length -gt $Limit) {
        $State['rows'] = @()
        $State['rowsTruncated'] = $true
        $json = ConvertTo-Json -InputObject $State -Depth 5 -Compress
    }
    if ($json.Length -gt $Limit) {
        $State['error'] = Get-DemoT3ShortText -Text ([string]$State['error']) -Length 200
        $json = ConvertTo-Json -InputObject $State -Depth 5 -Compress
    }
    if ($json.Length -gt $Limit) {
        $json = ConvertTo-Json -InputObject ([ordered]@{ marker = $State['marker']; schemaVersion = $State['schemaVersion']; status = 'Fail'; error = 'The result was too large to print.' }) -Compress
    }
    return 'DBHUBDEMO-T3SQL ' + $json
}

$state = [ordered]@{
    marker            = 'DBHUBDEMO-T3SQL'
    schemaVersion     = 1
    label             = $label
    status            = 'Fail'
    server            = $server
    database          = $database
    batches           = 0
    completed         = 0
    attempts          = 0
    loginFailures     = 0
    transientFailures = 0
    loginWaitSeconds  = 0
    elapsedSeconds    = 0
    errorNumber       = 0
    error             = ''
    rows              = @()
    rowsTruncated     = $false
}
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$connection = $null
try {
    $batches = Get-DemoT3Batch -Payload $payload -ExpectedSha256 $payloadSha256
    $state['batches'] = $batches.Count
    $connectParameters = @{
        State                 = $state
        Server                = $server
        Database              = $database
        MaxLoginWaitSeconds   = $maxLoginWaitSeconds
        MaxResumeWaitSeconds  = $maxResumeWaitSeconds
        TransientErrorNumbers = $transientErrorNumbers
    }
    $connection = Connect-DemoT3 @connectParameters
    if ($null -ne $connection) {
        $state['errorNumber'] = 0
        $index = 0
        $reconnects = 0
        while ($index -lt $batches.Count) {
            try {
                Invoke-DemoT3Batch -Connection $connection -Batch $batches[$index] -TimeoutSeconds $batchTimeoutSeconds -State $state
                $index++
                $state['completed'] = $index
            }
            catch {
                $number = Get-DemoT3SqlErrorNumber -Exception $_.Exception
                if ($transientErrorNumbers -contains $number -and $reconnects -lt 3) {
                    # The scripts are idempotent, so the batch runs again on a new connection.
                    $reconnects++
                    $state['transientFailures'] = [int]$state['transientFailures'] + 1
                    $connection.Dispose()
                    Start-Sleep -Seconds 10
                    $connection = Connect-DemoT3 @connectParameters
                    if ($null -eq $connection) {
                        break
                    }
                    continue
                }
                $state['status'] = 'Fail'
                $state['errorNumber'] = $number
                $state['error'] = ('Batch {0} of {1} failed: {2}' -f ($index + 1), $batches.Count, (Get-DemoT3ShortText -Text $_.Exception.Message -Length 400))
                break
            }
        }
        if ($index -eq $batches.Count) {
            $state['status'] = 'Pass'
            $state['error'] = ''
        }
    }
}
catch {
    $state['status'] = 'Fail'
    $state['error'] = Get-DemoT3ShortText -Text $_.Exception.Message -Length 400
}
finally {
    if ($null -ne $connection) {
        $connection.Dispose()
    }
}
$state['elapsedSeconds'] = [int]$clock.Elapsed.TotalSeconds
Write-Output (ConvertTo-DemoT3Output -State $state -Limit $outputLimit)
