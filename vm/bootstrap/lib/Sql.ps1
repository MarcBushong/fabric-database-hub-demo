function Split-DemoVmSqlBatch {
    <#
    .SYNOPSIS
    Splits a T-SQL script into batches on GO lines, as sqlcmd does. Empty batches are dropped.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
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

function Invoke-DemoVmSql {
    <#
    .SYNOPSIS
    Runs one T-SQL batch against the local instance with Windows authentication and returns rows as objects.

    .DESCRIPTION
    Uses the .NET Framework SqlClient, so it needs no sqlcmd or SqlServer module. SQL authentication is
    never used (ADR 0009).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Query,

        [string] $Database = 'master',

        [string] $ServerInstance = '.',

        [string] $ApplicationName = 'DbHubDemo.Bootstrap',

        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds = 600
    )

    $builder = New-Object -TypeName 'System.Data.SqlClient.SqlConnectionStringBuilder'
    $builder['Data Source'] = $ServerInstance
    $builder['Initial Catalog'] = $Database
    $builder['Integrated Security'] = $true
    $builder['Application Name'] = $ApplicationName
    $builder['Connect Timeout'] = 30
    $connection = New-Object -TypeName 'System.Data.SqlClient.SqlConnection' -ArgumentList $builder.ConnectionString
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = $TimeoutSeconds
        $reader = $command.ExecuteReader()
        try {
            do {
                while ($reader.Read()) {
                    $row = [ordered]@{}
                    for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                        $column = $reader.GetName($i)
                        if (-not $column) {
                            $column = 'Column{0}' -f $i
                        }
                        $value = $reader.GetValue($i)
                        if ($value -is [System.DBNull]) {
                            $value = $null
                        }
                        $row[$column] = $value
                    }
                    [pscustomobject]$row
                }
            } while ($reader.NextResult())
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $connection.Dispose()
    }
}

function Invoke-DemoVmSqlScript {
    <#
    .SYNOPSIS
    Runs a T-SQL file batch by batch. {{TOKEN}} placeholders, which appear only inside string literals, are
    replaced first; an unreplaced token stops the script before anything runs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $Database = 'master',

        [hashtable] $Token = @{},

        [string] $ServerInstance = '.',

        [ValidateRange(1, 86400)]
        [int] $TimeoutSeconds = 1800
    )

    $text = [System.IO.File]::ReadAllText($Path)
    foreach ($key in $Token.Keys) {
        $text = $text.Replace(('{{' + $key + '}}'), [string]$Token[$key])
    }
    $unreplaced = [regex]::Match($text, '\{\{[A-Z0-9_]+\}\}')
    if ($unreplaced.Success) {
        throw ('{0} has an unreplaced token {1}.' -f (Split-Path -Path $Path -Leaf), $unreplaced.Value)
    }
    $count = 0
    foreach ($batch in (Split-DemoVmSqlBatch -Script $text)) {
        Invoke-DemoVmSql -Query $batch -Database $Database -ServerInstance $ServerInstance -TimeoutSeconds $TimeoutSeconds | Out-Null
        $count++
    }
    Write-DemoVmLog -Message ('Ran {0} batches from {1} in {2}.' -f $count, (Split-Path -Path $Path -Leaf), $Database)
}
