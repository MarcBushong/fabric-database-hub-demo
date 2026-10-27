function Get-DemoVmUtcNow {
    # Timestamps are ISO 8601 strings: Windows PowerShell 5.1 serializes DateTime values as /Date(...)/.
    [CmdletBinding()]
    [OutputType([string])]
    param()

    return [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Initialize-DemoVmContext {
    <#
    .SYNOPSIS
    Sets the state folder and role for this run and creates the folders it needs.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [Parameter(Mandatory = $true)]
        [ValidateSet('SqlVm', 'ArcHost', 'EvalArcVm')]
        [string] $Role,

        [string] $BundleRoot = ''
    )

    $context = @{
        Root               = $Root
        Role               = $Role
        BundleRoot         = $BundleRoot
        LogDirectory       = Join-Path -Path $Root -ChildPath 'logs'
        ProtectedDirectory = Join-Path -Path $Root -ChildPath 'protected'
        StatePath          = Join-Path -Path $Root -ChildPath 'state.json'
        HealthPath         = Join-Path -Path $Root -ChildPath 'health.json'
        LockPath           = Join-Path -Path $Root -ChildPath 'bootstrap.lock'
        SettingsPath       = Join-Path -Path $Root -ChildPath 'settings.json'
        HashCachePath      = Join-Path -Path $Root -ChildPath 'media-hashes.json'
        ArcMarkerPath      = Join-Path -Path $Root -ChildPath 'arc-onboarded.json'
        RunId              = [guid]::NewGuid().ToString()
    }
    foreach ($directory in @($context.Root, $context.LogDirectory, $context.ProtectedDirectory)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }
    $script:DemoVmContext = $context
    return $context
}

function Get-DemoVmContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if ($null -eq $script:DemoVmContext) {
        throw 'Initialize-DemoVmContext has not run.'
    }
    return $script:DemoVmContext
}

function Register-DemoVmSecret {
    <#
    .SYNOPSIS
    Registers a run-time secret so it's redacted from logs, state, and health for the rest of the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Value
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -lt 4) {
        return
    }
    if (-not $script:DemoVmSecrets.Contains($Value)) {
        $script:DemoVmSecrets.Add($Value)
        $sorted = @($script:DemoVmSecrets | Sort-Object -Property Length -Descending)
        $script:DemoVmSecrets.Clear()
        foreach ($item in $sorted) {
            $script:DemoVmSecrets.Add($item)
        }
    }
}

function Protect-DemoVmText {
    <#
    .SYNOPSIS
    Redacts registered secrets, SAS query strings, tokens, passwords, and product keys from text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }
    $result = $Text
    foreach ($secret in $script:DemoVmSecrets) {
        $result = $result.Replace($secret, '[REDACTED]')
    }
    foreach ($rule in $script:DemoVmRedactionRules) {
        $result = [regex]::Replace($result, $rule.Pattern, $rule.Replacement)
    }
    return $result
}

function Write-DemoVmLog {
    <#
    .SYNOPSIS
    Appends one redacted line to C:\ProgramData\DbHubDemo\logs\bootstrap-<date>.log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string] $Message,

        [ValidateSet('Info', 'Warning', 'Error', 'Debug')]
        [string] $Level = 'Info',

        [string] $Step = ''
    )

    $stepText = ''
    if ($Step) {
        $stepText = ' [' + $Step + ']'
    }
    $line = '{0} [{1}]{2} {3}' -f (Get-DemoVmUtcNow), $Level.ToUpperInvariant(), $stepText, (Protect-DemoVmText -Text $Message)
    Write-Verbose -Message $line
    if ($null -ne $script:DemoVmContext) {
        $path = Join-Path -Path $script:DemoVmContext.LogDirectory -ChildPath ('bootstrap-{0}.log' -f [DateTime]::UtcNow.ToString('yyyyMMdd'))
        try {
            [System.IO.File]::AppendAllText($path, $line + "`r`n", $script:DemoVmUtf8)
        }
        catch {
            Write-Verbose -Message 'Could not write the bootstrap log file.'
        }
    }
}

function ConvertTo-DemoVmHashtable {
    <#
    .SYNOPSIS
    Converts ConvertFrom-Json output to ordered hashtables (Windows PowerShell 5.1 has no -AsHashtable).
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [AllowNull()]
        [object] $InputObject
    )

    process {
        if ($null -eq $InputObject) {
            return $null
        }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $dictionary = [ordered]@{}
            foreach ($key in $InputObject.Keys) {
                $dictionary[$key] = ConvertTo-DemoVmHashtable -InputObject $InputObject[$key]
            }
            return $dictionary
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $dictionary = [ordered]@{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $dictionary[$property.Name] = ConvertTo-DemoVmHashtable -InputObject $property.Value
            }
            return $dictionary
        }
        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
            $items = @(foreach ($item in $InputObject) { , (ConvertTo-DemoVmHashtable -InputObject $item) })
            return , $items
        }
        return $InputObject
    }
}

function Read-DemoVmJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }
    return (ConvertTo-DemoVmHashtable -InputObject ($text | ConvertFrom-Json))
}

function Write-DemoVmJsonFile {
    <#
    .SYNOPSIS
    Writes JSON atomically (temporary file, then replace). With -Redact, the text is redacted first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object] $InputObject,

        [ValidateRange(2, 100)]
        [int] $Depth = 20,

        [switch] $Redact
    )

    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    if ($Redact) {
        $json = Protect-DemoVmText -Text $json
    }
    $temporary = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
    [System.IO.File]::WriteAllText($temporary, $json, $script:DemoVmUtf8)
    if ([System.IO.File]::Exists($Path)) {
        # [NullString] passes a real null; PowerShell would turn $null into an empty string.
        [System.IO.File]::Replace($temporary, $Path, [NullString]::Value)
    }
    else {
        [System.IO.File]::Move($temporary, $Path)
    }
}

function Get-DemoVmSetting {
    <#
    .SYNOPSIS
    Returns settings.json, which the loader writes from the Run Command's non-secret settings.
    #>
    [CmdletBinding()]
    param()

    $context = Get-DemoVmContext
    $settings = Read-DemoVmJsonFile -Path $context.SettingsPath
    if ($null -eq $settings) {
        throw ('{0} is missing; the bootstrap loader writes it.' -f $context.SettingsPath)
    }
    return $settings
}

function Get-DemoVmMediaPin {
    <#
    .SYNOPSIS
    Returns a media pin (url, sha256, fileName) from the bundle manifest, which carries config/versions.json media.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [string] $BundleRoot = ''
    )

    if (-not $BundleRoot) {
        $BundleRoot = (Get-DemoVmContext).BundleRoot
    }
    $manifest = Read-DemoVmJsonFile -Path (Join-Path -Path $BundleRoot -ChildPath 'bundle-manifest.json')
    if ($null -eq $manifest -or -not $manifest.Contains('media') -or $null -eq $manifest['media'] -or -not $manifest['media'].Contains($Name)) {
        throw ('The bundle manifest has no media entry named {0}.' -f $Name)
    }
    $pin = $manifest['media'][$Name]
    if (-not $pin.Contains('url') -or [string]$pin['url'] -notmatch '^https://') {
        throw ('Media {0} has no HTTPS URL in the bundle manifest.' -f $Name)
    }
    if (-not $pin.Contains('sha256')) {
        $pin['sha256'] = $null
    }
    return $pin
}
