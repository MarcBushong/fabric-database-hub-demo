BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force

    # Every token is built at run time from harmless parts, so secret scanners never see one in the repo.
    function New-TestJwt {
        $encode = { param([string] $Text) [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        '{0}.{1}.{2}' -f (& $encode '{"alg":"HS256","typ":"JWT"}'), (& $encode ('{"sub":"' + [guid]::NewGuid().ToString() + '"}')), (& $encode ([guid]::NewGuid().ToString('N')))
    }

    function New-TestGitHubToken {
        $alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.ToCharArray()
        ('gh' + 'p_') + (-join (1..36 | ForEach-Object { $alphabet | Get-Random }))
    }

    function New-TestAccessToken {
        # Shaped like an Azure Resource Manager access token: an RS256 header, the claims, and a 256-byte
        # signature, all base64url, so '-' and '_' appear. Random and built at run time; it signs nothing.
        $encode = { param([byte[]] $Bytes) [System.Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        $utf8 = [System.Text.Encoding]::UTF8
        $header = '{"typ":"JWT","alg":"RS256","kid":"' + [guid]::NewGuid().ToString('N') + '"}'
        $claims = '{"aud":"https://management.azure.com/","iss":"https://sts.windows.net/' + [guid]::NewGuid().ToString() + '/","oid":"' + [guid]::NewGuid().ToString() + '","exp":' + [System.DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds() + '}'
        $signature = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(256)
        '{0}.{1}.{2}' -f (& $encode $utf8.GetBytes($header)), (& $encode $utf8.GetBytes($claims)), (& $encode $signature)
    }

    function ConvertTo-TestSecureString([string] $Value) {
        $secure = [System.Security.SecureString]::new()
        foreach ($character in $Value.ToCharArray()) {
            $secure.AppendChar($character)
        }
        $secure.MakeReadOnly()
        return $secure
    }
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Find-DemoSecretLeak (Phase 14 secret scan)' {
    BeforeEach {
        Clear-DemoSecret
        $script:jwt = New-TestJwt
        $script:gitHub = New-TestGitHubToken
        $script:registered = 'reg' + [guid]::NewGuid().ToString('N')
        $script:known = 'kn0wn-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
        Register-DemoSecret -Value $script:registered
        $script:folder = Join-Path -Path $TestDrive -ChildPath ('scan-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:folder | Out-Null
        $script:planted = Join-Path -Path $script:folder -ChildPath 'run.log'
        $lines = @(
            'Starting the run.'
            ('Authorization: Bearer {0}' -f $script:jwt)
            ('token {0}' -f $script:gitHub)
            ('registered value: {0}' -f $script:registered)
            ('known value: {0}' -f $script:known)
            '{"token": "[REDACTED]", "password": "", "sasToken": "***"}'
            'Use Bearer authentication for the API.'
            'password=<password>'
        )
        Set-Content -LiteralPath $script:planted -Value $lines -Encoding utf8NoBOM
    }

    AfterEach {
        Clear-DemoSecret
    }

    It 'finds every planted token, registered secret, and known value, with its line and rule' {
        $scan = Find-DemoSecretLeak -Path $script:folder -KnownValue (ConvertTo-TestSecureString $script:known)
        @($scan.Scanned) | Should -Be @($script:planted)
        $found = @($scan.Findings | ForEach-Object { '{0}:{1}' -f $_.Line, $_.Rule })
        $found | Should -Contain '2:jwt'
        $found | Should -Contain '2:bearer'
        $found | Should -Contain '3:github-token'
        $found | Should -Contain '4:registered-secret'
        $found | Should -Contain '5:known-value'
        @($scan.Findings | Where-Object { $_.Line -ge 6 }).Count | Should -Be 0 -Because 'redaction markers, empty values, masks, prose, and placeholders aren''t leaks'
    }

    It 'never returns a planted value, in findings or excerpts' {
        $scan = Find-DemoSecretLeak -Path $script:planted -KnownValue (ConvertTo-TestSecureString $script:known)
        $text = $scan | ConvertTo-Json -Depth 8
        foreach ($value in $script:jwt, $script:gitHub, $script:registered, $script:known) {
            $text | Should -Not -Match ([regex]::Escape($value))
        }
        ($scan.Findings | Where-Object { $_.Rule -eq 'github-token' }).Excerpt | Should -Be 'token [REDACTED:github-token]'
    }

    It 'scans text from Azure, such as a Run Command instance view' {
        $scan = Find-DemoSecretLeak -Text ("first line`r`nsecond {0}" -f $script:jwt) -Source 'sqlvm01/runCommands/DbHubDemo-Bootstrap'
        @($scan.Findings).Count | Should -Be 1
        $scan.Findings[0].Source | Should -Be 'sqlvm01/runCommands/DbHubDemo-Bootstrap'
        $scan.Findings[0].Line | Should -Be 2
        $scan.Findings[0].Rule | Should -Be 'jwt'
        (Find-DemoSecretLeak -Text '' -Source 'empty').Findings | Should -BeNullOrEmpty
    }

    It 'finds nothing in what Export-DemoResult writes, because it redacts first (ADR 0009)' {
        $result = New-DemoResult -CheckId 'TEST.REDACTED' -Area 'security' -Target 'repo' -Status 'Pass' -Message ('token {0}' -f $script:jwt) -Evidence @{ value = $script:registered; header = ('Bearer {0}' -f $script:gitHub) }
        $path = Join-Path -Path $script:folder -ChildPath 'results.jsonl'
        Export-DemoResult -Result @($result) -Path $path
        @((Find-DemoSecretLeak -Path $path).Findings).Count | Should -Be 0
    }

    It 'skips binary files and missing paths, and lists them' {
        $binary = Join-Path -Path $script:folder -ChildPath 'runner.zip'
        [System.IO.File]::WriteAllBytes($binary, [byte[]](@(80, 75, 3, 4, 0, 0) + [System.Text.Encoding]::UTF8.GetBytes($script:jwt)))
        $missing = Join-Path -Path $script:folder -ChildPath 'missing.log'
        $scan = Find-DemoSecretLeak -Path $binary, $missing
        @($scan.Findings).Count | Should -Be 0
        ($scan.Skipped | Where-Object { $_.Source -eq $binary }).Reason | Should -Be 'binary'
        ($scan.Skipped | Where-Object { $_.Source -eq $missing }).Reason | Should -Be 'not found'
    }

    It 'finds an access token in a log''s XML, as an element or an attribute, in UTF-8 or UTF-16 with or without a byte order mark' {
        $token = New-TestAccessToken
        $token | Should -Match '^eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{300,}$' -Because 'the fake must look like an access token'
        $xml = @(
            '<?xml version="1.0" encoding="utf-16"?>'
            '<Options>'
            ('  <Credential>{0}</Credential>' -f $token)
            ('  <Option Name="Credential" Value="{0}" />' -f $token)
            '</Options>'
        ) -join "`r`n"
        $logs = Join-Path -Path $TestDrive -ChildPath ('tool-log-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $logs | Out-Null
        $files = [ordered]@{
            'Options.utf8.xml'       = [System.Text.UTF8Encoding]::new($false).GetBytes($xml)
            'Options.utf8-bom.xml'   = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes($xml))
            'Options.utf16-bom.xml'  = [byte[]](@(0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes($xml))
            'Detail.utf16.txt'       = [System.Text.Encoding]::Unicode.GetBytes($xml)
            'Summary.utf16be.txt'    = [byte[]](@(0xFE, 0xFF) + [System.Text.Encoding]::BigEndianUnicode.GetBytes($xml))
        }
        foreach ($name in $files.Keys) {
            [System.IO.File]::WriteAllBytes((Join-Path -Path $logs -ChildPath $name), $files[$name])
        }
        $scan = Find-DemoSecretLeak -Path $logs
        @($scan.Skipped).Count | Should -Be 0 -Because 'UTF-16 text isn''t binary'
        @($scan.Scanned).Count | Should -Be $files.Count
        foreach ($name in $files.Keys) {
            $lines = @($scan.Findings | Where-Object { $_.Rule -eq 'jwt' -and [System.IO.Path]::GetFileName($_.Source) -eq $name } | ForEach-Object { $_.Line })
            $lines | Should -Be @(3, 4) -Because $name
        }
        $json = $scan | ConvertTo-Json -Depth 8
        $json | Should -Not -Match ([regex]::Escape($token))
        $json | Should -Not -Match ([regex]::Escape($token.Split('.')[2].Substring(0, 40)))
        Protect-DemoText -Text ('<Credential>{0}</Credential>' -f $token) | Should -Be '<Credential>[REDACTED:jwt]</Credential>' -Because 'the logger redacts the same shape'
    }

    It 'treats short or prose-like bearer and password values as text, and real-looking ones as secrets' {
        (Find-DemoSecretLeak -Text 'The API uses Bearer authentication.' -Source 's').Findings | Should -BeNullOrEmpty
        @((Find-DemoSecretLeak -Text ('Bearer {0}' -f ('abc123' * 4)) -Source 's').Findings).Rule | Should -Be 'bearer'
        (Find-DemoSecretLeak -Text 'password=secret' -Source 's').Findings | Should -BeNullOrEmpty
        @((Find-DemoSecretLeak -Text ('Server=x;Password={0};' -f ('Pw1-' + [guid]::NewGuid().ToString('N').Substring(0, 10))) -Source 's').Findings).Rule | Should -Be 'connection-password'
    }
}
