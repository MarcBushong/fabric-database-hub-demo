function Get-DemoConfig {
    <#
    .SYNOPSIS
    Loads the demo configuration, validates it against config/environment.schema.json, and applies defaults.

    .DESCRIPTION
    Defaults come from the schema itself, so they're defined in one place. An invalid file stops the
    script with every validation error listed. activityProfile's default (business-day since 2026-11-03) is resolved
    where a run uses it (Get-DemoActivityProfile), not merged here, so a run can tell that the file doesn't set it and
    say so once, and a configuration written back from this one still inherits the default. t2SqlInstallMode's default
    (JumpstartImage) is merged, and a file that doesn't name it is marked t2SqlInstallModeSource default; PaygWizard, retired
    from the one-click deployment, becomes JumpstartImage, marked legacy. t4Enabled is always true: T4 is part of every
    deployment, and a file's false is marked t4EnabledIgnored (2026-11-09, ADR 0006 and ADR 0019).
    ConvertTo-DemoConfigFileText leaves the marks out.

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
    # Resolved where it's used (Get-DemoActivityProfile), so an unset activityProfile stays recognizable.
    $defaults.Remove('activityProfile')
    $values = $json | ConvertFrom-Json -AsHashtable
    $values.Remove('$schema')

    $config = Merge-DemoHashtable -Base $defaults -Override $values
    # Whether the file names t2SqlInstallMode (2026-11-09): when it doesn't, the default applies to a new T2. PaygWizard is
    # retired from the one-click deployment (user-directed: "They should not need to manually do a wizard"): it was the
    # default an older init.ps1 wrote (before 2026-11-05), so it runs as JumpstartImage, with one line that says so, and no
    # configuration value leads to the setup wizard. An existing PaygWizard guest with SQL Server set up is kept as it is
    # (the T2 host decides). The schema doesn't allow these marks in the file (additionalProperties false), so they're
    # never mistaken for settings; ConvertTo-DemoConfigFileText leaves them out.
    if (-not $values.Contains('t2SqlInstallMode') -or [string]::IsNullOrWhiteSpace([string]$values['t2SqlInstallMode'])) {
        $config['t2SqlInstallModeSource'] = 'default'
    }
    elseif ([string]$values['t2SqlInstallMode'] -ceq 'PaygWizard') {
        $config['t2SqlInstallMode'] = 'JumpstartImage'
        $config['t2SqlInstallModeSource'] = 'legacy'
    }
    # T4 is part of every deployment (2026-11-09, user-directed: "making sure postgres is deployed with the deployment and
    # not being an optional component"): t4Enabled false is ignored, with one line that says so.
    if ($values.Contains('t4Enabled') -and $values['t4Enabled'] -eq $false) {
        $config['t4EnabledIgnored'] = $true
    }
    $config['t4Enabled'] = $true
    # In GitHub Actions only: mask the configuration's IDs and accounts in the job log (ADR 0022).
    Register-DemoLogMask -Config $config
    return $config
}
