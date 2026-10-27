function Get-DemoT3Name {
    <#
    .SYNOPSIS
    Returns T3's resource names: resource group, logical server, database, private endpoint, and T1.

    .DESCRIPTION
    Internal. The logical server is azuresql01-<deploymentId>, the same name every time T3 is created
    (ADR 0016). The deploymentId is -DeploymentId when given; otherwise it's the resource group's
    deploymentId tag, which main.bicep sets on every deployment (read with 'az group show'). With
    -NoLookup nothing is read, and ServerName is empty when -DeploymentId wasn't given.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [ValidatePattern('^$|^[a-z0-9]{6}$')]
        [string] $DeploymentId = '',

        [switch] $NoLookup
    )

    $resourceGroup = 'rg-{0}-{1}' -f $Config['prefix'], $Config['environment']
    $id = $DeploymentId
    if (-not $id -and -not $NoLookup) {
        $group = Invoke-DemoAz -SubscriptionId $Config['subscriptionId'] -ArgumentList @('group', 'show', '--name', $resourceGroup) -AsJson -AllowFailure
        $tag = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $group -Name 'tags') -Name 'deploymentId')
        if ($tag -match '^[a-z0-9]{6}$') {
            $id = $tag
        }
    }
    # In GitHub Actions only: mask the suffix that names T3 (ADR 0022).
    Register-DemoLogMask -Value @($id)

    [pscustomobject]@{
        ResourceGroup       = $resourceGroup
        DeploymentId        = $id
        ServerName          = if ($id) { 'azuresql01-' + $id } else { '' }
        DatabaseName        = 'ContosoCare'
        PrivateEndpointName = 'pe-{0}-{1}-azuresql01' -f $Config['prefix'], $Config['environment']
        VirtualNetworkName  = 'vnet-{0}-{1}' -f $Config['prefix'], $Config['environment']
        T1VmName            = 'sqlvm01'
    }
}

function Get-DemoMemberList {
    <#
    .SYNOPSIS
    Like Get-DemoMemberValue, but always returns an array: a list's items, a single value as one item, or none.

    .DESCRIPTION
    Internal. Get-DemoMemberValue keeps a list intact as one pipeline object, so wrapping its result in @()
    would nest the list instead of enumerating it.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $value = Get-DemoMemberValue -InputObject $InputObject -Name $Name
    return , @($value | Where-Object { $null -ne $_ })
}

function Split-DemoSqlBatch {
    <#
    .SYNOPSIS
    Splits a T-SQL script into batches on GO lines, as sqlcmd does. Empty batches are dropped.

    .DESCRIPTION
    Internal. The same rule as Split-DemoVmSqlBatch on the VMs: a line that holds only GO, optionally
    followed by a comment, ends a batch.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Script
    )

    $batches = [regex]::Split($Script, '(?im)^[ \t]*GO[ \t]*(?:--[^\r\n]*)?\r?$')
    $result = @(foreach ($batch in $batches) {
            $trimmed = $batch.Trim()
            if ($trimmed) {
                $trimmed
            }
        })
    return , $result
}

function Get-DemoT3SqlBatch {
    <#
    .SYNOPSIS
    Resolves a named T3 script set, T-SQL files, or queries into the batches the T1 runner sends.

    .DESCRIPTION
    Internal. Named sets (database/azuresql/README.md):
    - Setup: every database/common/0??-*.sql file in name order, then every database/azuresql/0??-*.sql
      file, then 'EXEC demo.usp_seed_contosocare @scale = <SeedScale>', then database/azuresql/900-status.sql.
    - Status: database/azuresql/900-status.sql (read-only).
    - PerformanceMonitoring: database/azuresql/040-performance-monitoring.sql, then 900-status.sql.
    A batch that still holds a {{TOKEN}} placeholder stops everything, because T3's scripts take none.
    Returns Batches and Sources (repository-relative paths, 'seed', or 'query').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Name')]
        [ValidateSet('Setup', 'Status', 'PerformanceMonitoring')]
        [string] $Name,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [string[]] $Path,

        [Parameter(Mandatory, ParameterSetName = 'Query')]
        [string[]] $Query,

        [ValidateRange(1, 50)]
        [int] $SeedScale = 1,

        [string] $RepositoryRoot = $script:RepoRoot
    )

    $root = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $items = [System.Collections.Generic.List[object]]::new()
    $numbered = {
        param([string] $Folder)
        $directory = Join-Path -Path $root -ChildPath $Folder
        $files = @(Get-ChildItem -LiteralPath $directory -Filter '*.sql' -File | Where-Object { $_.Name -match '^0\d\d-.+\.sql$' })
        [array]::Sort($files, [System.Comparison[object]] { param($left, $right) [string]::CompareOrdinal($left.Name, $right.Name) })
        $files | ForEach-Object { [pscustomobject]@{ Kind = 'file'; Value = $_.FullName } }
    }
    $statusFile = [pscustomobject]@{ Kind = 'file'; Value = (Join-Path -Path $root -ChildPath 'database/azuresql/900-status.sql') }

    switch ($PSCmdlet.ParameterSetName) {
        'Name' {
            switch ($Name) {
                'Setup' {
                    foreach ($item in (& $numbered 'database/common')) { $items.Add($item) }
                    foreach ($item in (& $numbered 'database/azuresql')) { $items.Add($item) }
                    $items.Add([pscustomobject]@{ Kind = 'seed'; Value = ('EXEC demo.usp_seed_contosocare @scale = {0};' -f $SeedScale) })
                    $items.Add($statusFile)
                }
                'Status' {
                    $items.Add($statusFile)
                }
                'PerformanceMonitoring' {
                    $items.Add([pscustomobject]@{ Kind = 'file'; Value = (Join-Path -Path $root -ChildPath 'database/azuresql/040-performance-monitoring.sql') })
                    $items.Add($statusFile)
                }
            }
        }
        'Path' {
            foreach ($file in $Path) {
                $items.Add([pscustomobject]@{ Kind = 'file'; Value = [System.IO.Path]::GetFullPath($file, $root) })
            }
        }
        'Query' {
            foreach ($text in $Query) {
                $items.Add([pscustomobject]@{ Kind = 'query'; Value = $text })
            }
        }
    }

    $batches = [System.Collections.Generic.List[string]]::new()
    $sources = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $items) {
        if ($item.Kind -eq 'file') {
            if (-not (Test-Path -LiteralPath $item.Value -PathType Leaf)) {
                throw "The T-SQL file $($item.Value) doesn't exist."
            }
            $text = [System.IO.File]::ReadAllText($item.Value)
            $source = [System.IO.Path]::GetRelativePath($root, $item.Value).Replace('\', '/')
        }
        else {
            $text = [string]$item.Value
            $source = $item.Kind
        }
        $token = [regex]::Match($text, '\{\{[A-Z0-9_]+\}\}')
        if ($token.Success) {
            throw "$source has the placeholder $($token.Value), but T3's T-SQL takes no placeholders."
        }
        foreach ($batch in (Split-DemoSqlBatch -Script $text)) {
            $batches.Add($batch)
        }
        $sources.Add($source)
    }
    if ($batches.Count -eq 0) {
        throw 'There is no T-SQL to run on T3.'
    }

    [pscustomobject]@{
        Batches = $batches.ToArray()
        Sources = $sources.ToArray()
    }
}

function ConvertTo-DemoT3SqlScript {
    <#
    .SYNOPSIS
    Builds the VM-side script that runs T-SQL batches on T3 from T1 (vm/t3/Invoke-DemoT3Sql.ps1).

    .DESCRIPTION
    Internal and pure. The batches become a JSON array, compressed with gzip and encoded as Base64, with the
    SHA-256 of the compressed bytes; the VM side checks it before it runs anything. Every value is checked
    before it goes into a single-quoted string in the script, so nothing can break out of it. The script
    must stay ASCII-only, keep no placeholder, and stay under MaximumBytes: the action Run Command reference
    doesn't state a script size limit, so this is a conservative internal cap that keeps every Run Command
    request small.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{1,252}$')]
        [string] $ServerFqdn,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_]{1,128}$')]
        [string] $DatabaseName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]] $Batch,

        [ValidatePattern('^[A-Za-z0-9._-]{1,40}$')]
        [string] $Label = 't3-sql',

        [ValidateRange(0, 1800)]
        [int] $MaxLoginWaitSeconds = 600,

        [ValidateRange(0, 900)]
        [int] $MaxResumeWaitSeconds = 300,

        [ValidateRange(30, 3600)]
        [int] $BatchTimeoutSeconds = 1800,

        [ValidateRange(4096, 262144)]
        [int] $MaximumBytes = 65536,

        [string] $TemplatePath = (Join-Path -Path $script:RepoRoot -ChildPath 'vm/t3/Invoke-DemoT3Sql.ps1')
    )

    $json = ConvertTo-Json -InputObject @($Batch) -Compress
    $jsonBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $memory = [System.IO.MemoryStream]::new()
    try {
        $gzip = [System.IO.Compression.GZipStream]::new($memory, [System.IO.Compression.CompressionLevel]::Optimal, $true)
        try {
            $gzip.Write($jsonBytes, 0, $jsonBytes.Length)
        }
        finally {
            $gzip.Dispose()
        }
        $compressed = $memory.ToArray()
    }
    finally {
        $memory.Dispose()
    }
    $payloadSha256 = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($compressed)).ToLowerInvariant()

    $values = [ordered]@{
        '{{SERVER}}'                  = $ServerFqdn
        '{{DATABASE}}'                = $DatabaseName
        '{{LABEL}}'                   = $Label
        '{{MAX_LOGIN_WAIT_SECONDS}}'  = [string]$MaxLoginWaitSeconds
        '{{MAX_RESUME_WAIT_SECONDS}}' = [string]$MaxResumeWaitSeconds
        '{{BATCH_TIMEOUT_SECONDS}}'   = [string]$BatchTimeoutSeconds
        '{{PAYLOAD_SHA256}}'          = $payloadSha256
        '{{PAYLOAD}}'                 = [System.Convert]::ToBase64String($compressed)
    }
    $text = [System.IO.File]::ReadAllText($TemplatePath)
    foreach ($key in $values.Keys) {
        if (-not $text.Contains($key)) {
            throw "The T3 runner template $TemplatePath has no $key placeholder."
        }
        $text = $text.Replace($key, $values[$key])
    }
    $left = [regex]::Match($text, '\{\{[A-Z0-9_]+\}\}')
    if ($left.Success) {
        throw "The T3 runner script still has the placeholder $($left.Value)."
    }
    if ($text -match '[^\x00-\x7F]') {
        throw 'The T3 runner script must be ASCII-only for Windows PowerShell 5.1.'
    }
    $bytes = [System.Text.Encoding]::ASCII.GetByteCount($text)
    if ($bytes -gt $MaximumBytes) {
        throw ("The T3 runner script is {0} bytes, above the {1}-byte cap. Run the T-SQL in smaller sets." -f $bytes, $MaximumBytes)
    }

    [pscustomobject]@{
        Text          = $text
        Bytes         = $bytes
        BatchCount    = $Batch.Count
        PayloadSha256 = $payloadSha256
        PayloadBytes  = $compressed.Length
    }
}

function ConvertFrom-DemoT3RunCommandOutput {
    <#
    .SYNOPSIS
    Reads the T1 runner's result line from 'az vm run-command invoke' output.

    .DESCRIPTION
    Internal and pure. The action Run Command returns value[] entries whose code names the stream
    (ComponentStatus/StdOut/succeeded, ComponentStatus/StdErr/succeeded). The runner prints one line,
    '<Marker> <json>' ('DBHUBDEMO-T3SQL' by default; the workload control script uses 'DBHUBDEMO-WORKLOAD');
    the last such line is parsed. Returns Data (a hashtable, or $null when no result line was found) and
    StdErr (redacted, at most 500 characters).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object] $Response,

        [ValidatePattern('^[A-Z0-9-]{3,40}$')]
        [string] $Marker = 'DBHUBDEMO-T3SQL'
    )

    $stdout = [System.Text.StringBuilder]::new()
    $stderr = [System.Text.StringBuilder]::new()
    foreach ($entry in (Get-DemoMemberList -InputObject $Response -Name 'value')) {
        $code = [string](Get-DemoMemberValue -InputObject $entry -Name 'code')
        $message = [string](Get-DemoMemberValue -InputObject $entry -Name 'message')
        if ($code -match 'StdErr') {
            [void]$stderr.AppendLine($message)
        }
        else {
            [void]$stdout.AppendLine($message)
        }
    }

    $prefix = $Marker + ' '
    $line = @($stdout.ToString() -split '\r?\n' | Where-Object { $_.StartsWith($prefix + '{', [System.StringComparison]::Ordinal) }) | Select-Object -Last 1
    $data = $null
    if ($line) {
        try {
            $data = $line.Substring($prefix.Length) | ConvertFrom-Json -AsHashtable
        }
        catch {
            $data = $null
        }
    }
    $errorText = (Protect-DemoText -Text $stderr.ToString()).Trim()
    if ($errorText.Length -gt 500) {
        $errorText = $errorText.Substring(0, 500) + '...'
    }

    [pscustomobject]@{
        Data   = $data
        StdErr = $errorText
    }
}
