function Get-DemoConfig {
    <#
    .SYNOPSIS
    Loads the demo configuration, validates it against config/environment.schema.json, and applies defaults.

    .DESCRIPTION
    Defaults come from the schema itself, so they're defined in one place. An invalid file stops the
    script with every validation error listed.

    .EXAMPLE
    $config = Get-DemoConfig -Path ./config/demo.config.json
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [string] $SchemaPath = (Join-Path -Path $script:RepoRoot -ChildPath 'config/environment.schema.json')
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path. Copy config/demo.config.example.json to config/demo.config.json and set your values."
    }

    $json = Get-Content -LiteralPath $Path -Raw
    $validationErrors = @()
    $isValid = Test-Json -Json $json -SchemaFile $SchemaPath -ErrorVariable validationErrors -ErrorAction SilentlyContinue
    if (-not $isValid) {
        $details = ($validationErrors | ForEach-Object { $_.Exception.Message } | Select-Object -Unique) -join '; '
        throw "Configuration file $Path doesn't match config/environment.schema.json: $details"
    }

    $schema = Get-Content -LiteralPath $SchemaPath -Raw | ConvertFrom-Json -AsHashtable
    $defaults = Get-DemoSchemaDefault -Node $schema
    $values = $json | ConvertFrom-Json -AsHashtable
    $values.Remove('$schema')

    $config = Merge-DemoHashtable -Base $defaults -Override $values
    # In GitHub Actions only: mask the configuration's IDs and accounts in the job log (ADR 0022).
    Register-DemoLogMask -Config $config
    return $config
}
