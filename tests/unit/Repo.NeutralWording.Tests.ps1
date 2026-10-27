BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))

    # The repository becomes public, so it describes the sign-in data that setup's interactive sign-in can leave on
    # a VM only in neutral words (R74, ADR 0009): no product file or setting name, no reproduction, no reporting
    # note. Each forbidden text is built at run time, so this file doesn't contain it.
    $script:forbidden = @(
        @{ Name = 'a product setting name'; Pattern = [regex]::Escape(('AZURE' + 'ACCESS' + 'TOKEN')) }
        @{ Name = 'a product file name'; Pattern = [regex]::Escape(('Settings' + '.' + 'xml')) }
        @{ Name = 'a security reporting channel'; Pattern = '\b' + ('MS' + 'RC') + '\b' }
        @{ Name = 'a security reporting channel'; Pattern = ('security' + '\s+' + 'response') }
        @{ Name = 'a reporting note anchor'; Pattern = [regex]::Escape(('product-security' + '-reporting-note')) }
        @{ Name = 'a description of the product''s behavior'; Pattern = '\b' + ('un' + 'masked') + '\b' }
        @{ Name = 'a reporting statement'; Pattern = ('reports?' + '\s+(it|the finding)\s+' + 'to Microsoft') }
    )

    $excludedFolders = '^(\.git|node_modules|out|TestResults)/|/(bin|obj|node_modules)/'
    $binary = '\.(png|jpe?g|gif|ico|zip|7z|gz|pdf|pbix|dll|exe|vhdx?|iso|msi|woff2?|ttf|eot|snk|pfx)$'

    $files = @(git -C $repoRoot ls-files --cached --others --exclude-standard 2>$null)
    if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) {
        $files = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Force | ForEach-Object { [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName) })
    }
    $script:textFiles = @($files |
            ForEach-Object { $_.Replace('\', '/') } |
            Where-Object { $_ -notmatch $excludedFolders -and $_ -notmatch $binary } |
            Where-Object { Test-Path -LiteralPath (Join-Path -Path $repoRoot -ChildPath $_) -PathType Leaf })
}

Describe 'Neutral wording for sign-in data (R74)' {
    It 'checks the files Git would commit' {
        $script:textFiles.Count | Should -BeGreaterThan 100
        # The public report replaced the operator log (Phase 26e), so no file is excluded any more.
        $script:textFiles | Should -Contain 'docs/implementation-report.md'
    }

    It 'keeps product details out of every file' {
        $hits = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:textFiles) {
            $text = [System.IO.File]::ReadAllText((Join-Path -Path $repoRoot -ChildPath $file))
            foreach ($rule in $script:forbidden) {
                foreach ($match in [regex]::Matches($text, $rule.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                    $line = $text.Substring(0, $match.Index).Split("`n").Count
                    $hits.Add(('{0}:{1}: {2}' -f $file, $line, $rule.Name))
                }
            }
        }
        $hits | Should -BeNullOrEmpty -Because 'the repository describes it only as sign-in data that setup can leave on the VM, which the scripts remove and verify (R74)'
    }

    It 'still finds each forbidden text when it''s planted' {
        foreach ($rule in $script:forbidden) {
            $planted = switch ($rule.Name) {
                'a product setting name' { 'x ' + ('AZURE' + 'ACCESS' + 'TOKEN') + ' y' }
                'a product file name' { 'in ' + ('settings' + '.' + 'XML') }
                'a reporting note anchor' { '#' + ('product-security' + '-reporting-note') }
                'a description of the product''s behavior' { 'written ' + ('Un' + 'masked') }
                'a reporting statement' { 'the owner ' + ('reports' + ' it ' + 'to Microsoft') }
                default { 'via ' + ('MS' + 'RC') + ' or the ' + ('Security' + ' Response') + ' team' }
            }
            [regex]::IsMatch($planted, $rule.Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | Should -BeTrue -Because $rule.Name
        }
    }
}
