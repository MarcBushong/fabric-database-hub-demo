function Register-DemoSecret {
    <#
    .SYNOPSIS
    Registers a run-time secret so it's redacted everywhere for the rest of the session.

    .DESCRIPTION
    Values shorter than 4 characters are ignored, because redacting them would mangle normal text.
    In GitHub Actions, the value is also masked in the job log with the add-mask workflow command.

    .EXAMPLE
    Register-DemoSecret -Value $sasUrl
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $Value
    )

    process {
        if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -lt 4) {
            return
        }

        if (-not $script:DemoSecrets.Contains($Value)) {
            $script:DemoSecrets.Add($Value)
            # Longest first, so a secret that contains another is replaced whole.
            $sorted = [string[]]($script:DemoSecrets | Sort-Object -Property Length -Descending)
            $script:DemoSecrets.Clear()
            $script:DemoSecrets.AddRange($sorted)
        }

        if ($env:GITHUB_ACTIONS -eq 'true') {
            [System.Console]::Out.WriteLine("::add-mask::$Value")
        }
    }
}
