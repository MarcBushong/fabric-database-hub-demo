BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Protect-DemoText' {
    BeforeEach {
        Clear-DemoSecret
    }

    It 'leaves ordinary text unchanged' {
        Protect-DemoText -Text 'Arc machine arcsql01 is Connected.' | Should -Be 'Arc machine arcsql01 is Connected.'
    }

    It 'returns empty input unchanged' {
        Protect-DemoText -Text '' | Should -Be ''
    }

    It 'redacts JWTs' {
        # Built at run time so secret scanners don't flag the fixture.
        $jwt = 'ey' + 'J' + ('a' * 20) + '.' + 'ey' + 'J' + ('b' * 30) + '.' + ('c' * 40)
        $output = Protect-DemoText -Text "token $jwt end"
        $output | Should -Match '\[REDACTED:jwt\]'
        $output | Should -Not -Match 'aaaaaaaaaa'
    }

    It 'redacts bearer tokens' {
        Protect-DemoText -Text 'Authorization: Bearer abcdefghijklmnop' | Should -Be 'Authorization: Bearer [REDACTED]'
    }

    It 'redacts SAS signatures and keeps the rest of the URL' {
        $url = 'https://st1.blob.core.windows.net/artifacts/runner.zip?sv=2024-11-04&sp=r&sig=' + ('X' * 43) + '%3D'
        $output = Protect-DemoText -Text $url
        $output | Should -Match 'sig=\[REDACTED\]'
        $output | Should -Match 'sp=r'
        $output | Should -Not -Match 'XXXXXXXX'
    }

    It 'redacts storage account keys' {
        $connection = 'DefaultEndpointsProtocol=https;AccountName=st1;AccountKey=' + ('k' * 40) + '==;EndpointSuffix=core.windows.net'
        $output = Protect-DemoText -Text $connection
        $output | Should -Match 'AccountKey=\[REDACTED\]'
        $output | Should -Match 'AccountName=st1'
    }

    It 'redacts connection-string passwords' {
        Protect-DemoText -Text 'Server=x;User ID=y;Password=Sup3rS3cret;' | Should -Be 'Server=x;User ID=y;Password=[REDACTED];'
    }

    It 'redacts secret-named JSON properties' {
        $output = Protect-DemoText -Text '{"adminPassword":"Sup3rSecret!","name":"vm1"}'
        $output | Should -Be '{"adminPassword":"[REDACTED]","name":"vm1"}'
    }

    It 'redacts GitHub tokens' {
        $classic = 'gh' + 'p_' + ('A' * 36)
        $fineGrained = 'github' + '_pat_' + ('B' * 40)
        $output = Protect-DemoText -Text "$classic and $fineGrained"
        $output | Should -Be '[REDACTED:github-token] and [REDACTED:github-token]'
    }

    It 'redacts product keys' {
        Protect-DemoText -Text 'Key ABCDE-FGHIJ-KLMNO-PQRST-UVWXY used' | Should -Be 'Key [REDACTED:product-key] used'
    }

    It 'redacts registered secrets exactly, longest first' {
        Register-DemoSecret -Value 'alpha-secret'
        Register-DemoSecret -Value 'alpha-secret-extended'
        Protect-DemoText -Text 'x alpha-secret-extended y alpha-secret z' | Should -Be 'x [REDACTED] y [REDACTED] z'
    }

    It 'ignores registered values shorter than 4 characters' {
        Register-DemoSecret -Value 'abc'
        Protect-DemoText -Text 'abc abc' | Should -Be 'abc abc'
    }
}

Describe 'Write-DemoLog' {
    BeforeEach {
        Clear-DemoSecret
    }

    It 'never writes a registered secret' {
        Register-DemoSecret -Value 'TopSecretValue123'
        $output = Write-DemoLog -Message 'value TopSecretValue123 here' 6>&1 | Out-String
        $output | Should -Not -Match 'TopSecretValue123'
        $output | Should -Match '\[REDACTED\]'
    }

    It 'includes the level in the line' {
        $output = Write-DemoLog -Level Success -Message 'done' 6>&1 | Out-String
        $output | Should -Match '\[SUCCESS\] done'
    }
}
