function New-DemoAdminPassword {
    <#
    .SYNOPSIS
    Generates a VM administrator password with a cryptographic random generator (ADR 0009).

    .DESCRIPTION
    For VM creation only: deploy.ps1 passes it in the secure adminPassword parameter and discards it, and
    preflight uses a throwaway one for what-if. 24 characters with upper case, lower case, digits, and
    symbols; it starts with a letter. The symbols are limited to '#*+-.?_~', which need no escaping for
    cmd.exe: on Windows az is the batch file az.cmd, where '%' expands variables (Invoke-DemoAz refuses
    it), '!' can trigger delayed expansion, '^' escapes, and '&|<>()' end or redirect a command. Azure's
    complexity rule counts any non-alphanumeric character as a symbol. The value is registered for
    redaction and returned as a SecureString.

    .EXAMPLE
    $password = New-DemoAdminPassword
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory value only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([securestring])]
    param(
        [ValidateRange(16, 64)]
        [int] $Length = 24
    )

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $symbols = '#*+-.?_~'
    $all = $upper + $lower + $digits + $symbols

    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in @($upper, $lower, $digits, $symbols)) {
        for ($i = 0; $i -lt 2; $i++) {
            $chars.Add($set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)])
        }
    }
    while ($chars.Count -lt $Length) {
        $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
    }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $chars[$i], $chars[$j] = $chars[$j], $chars[$i]
    }
    $letters = $upper + $lower
    if ($letters.IndexOf($chars[0]) -lt 0) {
        $swap = 1
        while ($letters.IndexOf($chars[$swap]) -lt 0) {
            $swap++
        }
        $chars[0], $chars[$swap] = $chars[$swap], $chars[0]
    }

    $plain = [string]::new($chars.ToArray())
    Register-DemoSecret -Value $plain
    $secure = [System.Security.SecureString]::new()
    foreach ($character in $chars) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    return $secure
}
