BeforeDiscovery {
    $script:gitleaksCommand = Get-Command -Name 'gitleaks' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
}

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $script:configPath = Join-Path -Path $script:repoRoot -ChildPath '.gitleaks.toml'
    $script:configText = Get-Content -LiteralPath $script:configPath -Raw

    # Shaped like an Azure Resource Manager access token, built at run time from random parts so that no
    # scanner ever finds one in the repository. It signs nothing.
    function New-TestAccessToken {
        $encode = { param([byte[]] $Bytes) [System.Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        $utf8 = [System.Text.Encoding]::UTF8
        $header = '{"typ":"JWT","alg":"RS256","kid":"' + [guid]::NewGuid().ToString('N') + '"}'
        $claims = '{"aud":"https://management.azure.com/","oid":"' + [guid]::NewGuid().ToString() + '","exp":' + [System.DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds() + '}'
        '{0}.{1}.{2}' -f (& $encode $utf8.GetBytes($header)), (& $encode $utf8.GetBytes($claims)), (& $encode ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(256)))
    }

    # Shaped like an Azure Automation webhook URL (ADR 0020), built at run time from random parts for the same reason.
    function New-TestWebhookUrl {
        $token = [System.Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).Replace('+', '%2b').Replace('/', '%2f').Replace('=', '%3d')
        'https://{0}.webhook.wus3.{1}/webhooks?token={2}' -f [guid]::NewGuid().ToString('N'), ('azure-' + 'automation.net'), $token
    }

    function Get-TestGitleaksRulePattern {
        param([string] $Id)
        $match = [regex]::Match($script:configText, ('(?s)\[\[rules\]\]\s*id\s*=\s*"{0}".*?regex\s*=\s*''''''(.+?)''''''' -f [regex]::Escape($Id)))
        if (-not $match.Success) {
            throw ('Rule {0} not found in .gitleaks.toml.' -f $Id)
        }
        return $match.Groups[1].Value
    }

    # The text of each [[allowlists]] table, up to the next table header.
    function Get-TestGitleaksAllowlist {
        @([regex]::Matches($script:configText, '(?ms)^\[\[allowlists\]\]\s*$(.*?)(?=^\[|\z)') | ForEach-Object { $_.Groups[1].Value })
    }

    function Get-TestGitleaksAllowlistValue {
        param([string] $Allowlist, [string] $Key)
        $match = [regex]::Match($Allowlist, ('(?m)^{0}\s*=\s*\[\s*''''''(.+?)''''''\s*\]\s*$' -f [regex]::Escape($Key)))
        if (-not $match.Success) {
            throw ('{0} not found in the allowlist.' -f $Key)
        }
        return $match.Groups[1].Value
    }
}

Describe 'gitleaks configuration (Phase 14, ADR 0009)' {
    It 'keeps every default rule and adds the JWT rule that ignores what follows the token' {
        $script:configText | Should -Match '(?m)^\[extend\]\s*$'
        $script:configText | Should -Match '(?m)^useDefault\s*=\s*true\s*$'
        $script:configText | Should -Not -Match '(?m)^disabledRules\s*=' -Because 'no default rule is turned off'
        $script:configText | Should -Not -Match '(?m)^\[(?:allowlist|rules\.allowlists?|\[rules\.allowlists?\])\]' -Because 'no rule-wide or legacy allowlist'
        Get-TestGitleaksRulePattern -Id 'jwt-any-delimiter' | Should -Not -BeNullOrEmpty
    }

    It 'allowlists only the public commit SHA pins in config/versions.json, and only for the Sourcegraph rule' {
        $allowlists = @(Get-TestGitleaksAllowlist)
        $allowlists.Count | Should -Be 1
        $allowlist = $allowlists[0]
        $allowlist | Should -Match '(?m)^targetRules\s*=\s*\["sourcegraph-access-token"\]\s*$'
        $allowlist | Should -Match '(?m)^condition\s*=\s*"AND"\s*$' -Because 'both the path and the line must match'
        $allowlist | Should -Match '(?m)^regexTarget\s*=\s*"line"\s*$'
        $path = [regex]::new((Get-TestGitleaksAllowlistValue -Allowlist $allowlist -Key 'paths'))
        $line = [regex]::new((Get-TestGitleaksAllowlistValue -Allowlist $allowlist -Key 'regexes'))
        foreach ($name in 'config/versions.json', 'C:/repo/config/versions.json', 'C:\repo\config\versions.json') {
            $path.IsMatch($name) | Should -BeTrue -Because $name
        }
        foreach ($name in 'config/versions.json.bak', 'docs/versions.json', 'config/other.json') {
            $path.IsMatch($name) | Should -BeFalse -Because $name
        }
        $pins = @(Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'config/versions.json') | Where-Object { $_ -match '"[0-9a-f]{40}"' })
        $pins.Count | Should -BeGreaterThan 0
        foreach ($pin in $pins) {
            $line.IsMatch($pin) | Should -BeTrue -Because 'every 40-hex value in versions.json is a sha, commit, or pluginCommit pin'
        }
        $hex = -join (1..40 | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
        $line.IsMatch(('"token": "{0}{1}"' -f ('sg' + 'p_'), $hex)) | Should -BeFalse
        $line.IsMatch(('"token": "{0}"' -f $hex)) | Should -BeFalse
    }

    It 'asks for no newer gitleaks than the one CI and the pre-commit hook pin' {
        $minimum = [regex]::Match($script:configText, '(?m)^minVersion\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"\s*$')
        $minimum.Success | Should -BeTrue
        $pinned = (Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json).tools.gitleaks
        [version]$minimum.Groups[1].Value | Should -BeLessOrEqual ([version]$pinned)
    }

    It 'matches an access token inside an XML element, an attribute, a URL query, JSON, or plain text' {
        $rule = [regex]::new((Get-TestGitleaksRulePattern -Id 'jwt-any-delimiter'))
        $token = New-TestAccessToken
        $contexts = @(
            '<Credential>{0}</Credential>'
            '<Option Name="Credential" Value="{0}" />'
            'GET https://example.invalid/api?access_token={0}&x=1'
            '{{"accessToken":"{0}"}}'
            'token {0}'
        )
        foreach ($context in $contexts) {
            $match = $rule.Match(($context -f $token))
            $match.Success | Should -BeTrue -Because $context
            $match.Groups[1].Value | Should -Be $token -Because $context
        }
    }

    It 'leaves documentation placeholders and short look-alikes alone' {
        $rule = [regex]::new((Get-TestGitleaksRulePattern -Id 'jwt-any-delimiter'))
        foreach ($text in @('eyJ...', 'Authorization: Bearer eyJ<header>.eyJ<payload>.<signature>', 'eyJhbGciOi.eyJzdWIi.abc', 'eyJhbGciOiJIUzI1NiJ9 alone')) {
            $rule.IsMatch($text) | Should -BeFalse -Because $text
        }
    }

    It 'matches an Azure Automation webhook URL wherever it appears, but not a redacted or placeholder one (ADR 0020)' {
        $rule = [regex]::new((Get-TestGitleaksRulePattern -Id 'azure-automation-webhook'))
        $url = New-TestWebhookUrl
        foreach ($context in @('{0}', 'POST {0} HTTP/1.1', '{{"webhookUri":"{0}"}}', "uri = '{0}'")) {
            $rule.IsMatch(($context -f $url)) | Should -BeTrue -Because $context
        }
        $placeholders = @(
            ($url -replace '(token=).+$', '$1[REDACTED]')
            ('https://<id>.webhook.<region>.{0}/webhooks?token=<token>' -f ('azure-' + 'automation.net'))
            ('https://x.webhook.wus3.{0}/webhooks?token=...' -f ('azure-' + 'automation.net'))
        )
        foreach ($text in $placeholders) {
            $rule.IsMatch($text) | Should -BeFalse -Because $text
        }
    }

    It 'finds an Azure Automation webhook URL in a file, when gitleaks is installed' -Skip:(-not $script:gitleaksCommand) {
        $gitleaks = Get-Command -Name 'gitleaks' -CommandType Application | Select-Object -First 1
        $folder = Join-Path -Path $TestDrive -ChildPath ('gitleaks-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $url = New-TestWebhookUrl
        Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'notes.txt') -Value ('The control''s webhook is {0} until January.' -f $url) -Encoding utf8NoBOM
        $report = Join-Path -Path $TestDrive -ChildPath ('gitleaks-' + [guid]::NewGuid().ToString('N') + '.json')
        $null = & $gitleaks.Source dir $folder --config $script:configPath --no-banner --redact --log-level error --report-format json --report-path $report
        $LASTEXITCODE | Should -Be 1 -Because 'gitleaks exits 1 when it finds a leak'
        $findings = @(Get-Content -LiteralPath $report -Raw | ConvertFrom-Json)
        # gitleaks also reports the percent-decoded URL (tag decoded:percent); the line itself is found once.
        @($findings | Where-Object { $_.RuleID -eq 'azure-automation-webhook' -and -not (@($_.Tags) -match '^decoded:') }).Count | Should -Be 1
        (Get-Content -LiteralPath $report -Raw) | Should -Not -Match ([regex]::Escape(($url -split 'token=')[1])) -Because '--redact keeps the token out of the report'
    }

    It 'is what the pinned gitleaks finds a token with inside an XML element, when gitleaks is installed' -Skip:(-not $script:gitleaksCommand) {
        $gitleaks = Get-Command -Name 'gitleaks' -CommandType Application | Select-Object -First 1
        $folder = Join-Path -Path $TestDrive -ChildPath ('gitleaks-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $token = New-TestAccessToken
        Set-Content -LiteralPath (Join-Path -Path $folder -ChildPath 'options.xml') -Value ('<Options><Credential>{0}</Credential></Options>' -f $token) -Encoding utf8NoBOM
        $report = Join-Path -Path $TestDrive -ChildPath ('gitleaks-' + [guid]::NewGuid().ToString('N') + '.json')
        $null = & $gitleaks.Source dir $folder --config $script:configPath --no-banner --redact --log-level error --report-format json --report-path $report
        $LASTEXITCODE | Should -Be 1 -Because 'gitleaks exits 1 when it finds a leak'
        $findings = @(Get-Content -LiteralPath $report -Raw | ConvertFrom-Json)
        @($findings | Where-Object { $_.RuleID -eq 'jwt-any-delimiter' }).Count | Should -Be 1
        (Get-Content -LiteralPath $report -Raw) | Should -Not -Match ([regex]::Escape($token)) -Because '--redact keeps the token out of the report'
    }

    It 'finds nothing in config/versions.json, but still a Sourcegraph-shaped token planted in it, when gitleaks is installed' -Skip:(-not $script:gitleaksCommand) {
        $gitleaks = Get-Command -Name 'gitleaks' -CommandType Application | Select-Object -First 1
        $versions = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath 'config/versions.json') -Raw
        $scan = {
            param([string] $Text)
            $folder = Join-Path -Path $TestDrive -ChildPath ('gitleaks-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path -Path $folder -ChildPath 'config') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path -Path $folder -ChildPath 'config/versions.json'), $Text, [System.Text.UTF8Encoding]::new($false))
            $report = Join-Path -Path $TestDrive -ChildPath ('gitleaks-' + [guid]::NewGuid().ToString('N') + '.json')
            $null = & $gitleaks.Source dir $folder --config $script:configPath --no-banner --redact --log-level error --report-format json --report-path $report
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Findings = @(Get-Content -LiteralPath $report -Raw | ConvertFrom-Json) }
        }
        $clean = & $scan $versions
        $clean.ExitCode | Should -Be 0 -Because 'the pins are public commit SHAs'
        $clean.Findings.Count | Should -Be 0
        $hex = -join (1..40 | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
        $tokenLine = '  "token": "{0}{1}",' -f ('sg' + 'p_'), $hex
        $planted = & $scan ([regex]::new('\{').Replace($versions, ('{' + "`n" + $tokenLine), 1))
        $planted.ExitCode | Should -Be 1
        @($planted.Findings | ForEach-Object { $_.RuleID }) | Should -Be @('sourcegraph-access-token')
        $planted.Findings[0].StartLine | Should -Be 2
    }
}
