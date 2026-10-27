function Protect-DemoText {
    <#
    .SYNOPSIS
    Redacts secrets from text before it's logged, stored, or displayed.

    .DESCRIPTION
    Replaces every value registered with Register-DemoSecret, then applies pattern rules for
    JWTs, bearer tokens, SAS signatures, storage account keys, connection-string passwords,
    secret-named JSON properties, GitHub tokens, and product keys.

    .EXAMPLE
    'Token: eyJhbGciOi...' | Protect-DemoText
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, ValueFromPipeline, Position = 0)]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    process {
        if ([string]::IsNullOrEmpty($Text)) {
            return $Text
        }

        $result = $Text
        foreach ($secret in $script:DemoSecrets) {
            $result = $result.Replace($secret, '[REDACTED]')
        }

        foreach ($rule in $script:RedactionRules) {
            $result = [regex]::Replace($result, $rule.Pattern, $rule.Replacement)
        }

        return $result
    }
}
