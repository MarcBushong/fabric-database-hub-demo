#Requires -Version 7.4
<#
.SYNOPSIS
Runs the repository's static validation and reports each check with the demo status model (ADR 0012).

.DESCRIPTION
Checks:
- PSScriptAnalyzer: every PowerShell file, with tests/PSScriptAnalyzerSettings.psd1; files under vm/ use
  tests/PSScriptAnalyzerSettings.Vm.psd1 (Windows PowerShell 5.1 syntax, commands, and types), and *.Tests.ps1 files use
  tests/PSScriptAnalyzerSettings.Tests.psd1.
- Pester: the unit tests in tests/unit, including schema, notebook, link, workflow-pin, and convention tests.
- Bicep: build, lint, and the azuredeploy.json sync check, plus build and lint of the standalone templates in
  infra/control (ADR 0020). Not selected until infra/main.bicep exists.
- PSRule: PSRule for Azure (Well-Architected rules) on infra/main.bicepparam, with the suppressions in ps-rule.yaml.
- DotNet: restore (locked mode), build, and test the workload generator.
- FabricApp: install the Fabric App (fabric/app) from its lock file, then typecheck, lint, test, check the production
  dependencies' licenses, and build it (npm run verify). Not selected without Node.js.
- Markdown: markdownlint-cli2 at the version pinned in config/versions.json.

Results are printed as a table, written to out/static-validation.jsonl, and added to the GitHub job
summary when run in Actions. The exit code follows Get-DemoExitCode. This script makes no Azure calls.

.PARAMETER Check
Checks to run. Defaults to all of them.

.PARAMETER CI
Also write Pester results as JUnit XML to out/pester.xml.

.EXAMPLE
./tests/Invoke-StaticValidation.ps1

.EXAMPLE
./tests/Invoke-StaticValidation.ps1 -Check PSScriptAnalyzer, Pester -CI
#>
[CmdletBinding()]
param(
    [ValidateSet('PSScriptAnalyzer', 'Pester', 'Bicep', 'PSRule', 'DotNet', 'FabricApp', 'Markdown')]
    [string[]] $Check = @('PSScriptAnalyzer', 'Pester', 'Bicep', 'PSRule', 'DotNet', 'FabricApp', 'Markdown'),

    [switch] $CI
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..'))
$outDirectory = Join-Path -Path $repoRoot -ChildPath 'out'
Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
$versions = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/versions.json') -Raw | ConvertFrom-Json
$results = [System.Collections.Generic.List[object]]::new()
$excluded = '[\\/](\.git|node_modules|bin|obj|out|TestResults)[\\/]'

function Add-StaticResult {
    param(
        [string] $CheckId,
        [string] $Status,
        [string] $Message
    )
    $results.Add((New-DemoResult -CheckId $CheckId -Area 'static' -Target 'repo' -Status $Status -Message $Message))
}

function Invoke-Native {
    param(
        [string] $FilePath,
        [string[]] $ArgumentList
    )
    $PSNativeCommandUseErrorActionPreference = $false
    # Send tool output to the host so the function returns only the exit code.
    & $FilePath @ArgumentList | Out-Host
    return $LASTEXITCODE
}

if ('PSScriptAnalyzer' -in $Check) {
    Import-Module -Name PSScriptAnalyzer -RequiredVersion $versions.tools.psscriptanalyzer
    $settings = Join-Path -Path $PSScriptRoot -ChildPath 'PSScriptAnalyzerSettings.psd1'
    $testSettings = Join-Path -Path $PSScriptRoot -ChildPath 'PSScriptAnalyzerSettings.Tests.psd1'
    # VM-side scripts run on Windows PowerShell 5.1 (ADR 0003), and so do the on-demand control's Azure Automation runbooks
    # (ADR 0020), so their syntax, commands, and types are checked against 5.1.
    $vmSettings = Join-Path -Path $PSScriptRoot -ChildPath 'PSScriptAnalyzerSettings.Vm.psd1'
    $vmRoot = Join-Path -Path $repoRoot -ChildPath 'vm'
    $runbookRoot = Join-Path -Path $repoRoot -ChildPath 'automation'
    $files = @(Get-ChildItem -Path $repoRoot -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' | Where-Object { $_.FullName -notmatch $excluded })
    $findings = @(foreach ($file in $files) {
            $fileSettings = if ($file.Name -like '*.Tests.ps1') {
                $testSettings
            }
            elseif ($file.FullName.StartsWith($vmRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or $file.FullName.StartsWith($runbookRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                $vmSettings
            }
            else {
                $settings
            }
            Invoke-ScriptAnalyzer -Path $file.FullName -Settings $fileSettings
        })
    if ($findings.Count -gt 0) {
        $findings | Format-Table -Property RuleName, Severity, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 240 | Write-Output
        Add-StaticResult -CheckId 'STATIC.PSSCRIPTANALYZER' -Status 'Fail' -Message "$($findings.Count) PSScriptAnalyzer finding(s) in $($files.Count) files."
    }
    else {
        Add-StaticResult -CheckId 'STATIC.PSSCRIPTANALYZER' -Status 'Pass' -Message "No PSScriptAnalyzer findings in $($files.Count) files."
    }
}

if ('Pester' -in $Check) {
    Import-Module -Name Pester -RequiredVersion $versions.tools.pester
    $configuration = New-PesterConfiguration
    $configuration.Run.Path = Join-Path -Path $PSScriptRoot -ChildPath 'unit'
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    if ($CI) {
        $configuration.TestResult.Enabled = $true
        $configuration.TestResult.OutputFormat = 'JUnitXml'
        $configuration.TestResult.OutputPath = Join-Path -Path $outDirectory -ChildPath 'pester.xml'
    }
    $run = Invoke-Pester -Configuration $configuration
    # The unit tests unload DbHubDemo when they finish; load it again for the remaining checks.
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    if ($run.Result -ne 'Passed') {
        Add-StaticResult -CheckId 'STATIC.PESTER' -Status 'Fail' -Message "$($run.FailedCount) of $($run.TotalCount) Pester tests failed."
    }
    else {
        Add-StaticResult -CheckId 'STATIC.PESTER' -Status 'Pass' -Message "$($run.PassedCount) Pester tests passed."
    }
}

if ('Bicep' -in $Check) {
    $mainBicep = Join-Path -Path $repoRoot -ChildPath 'infra/main.bicep'
    if (-not (Test-Path -LiteralPath $mainBicep)) {
        Add-StaticResult -CheckId 'STATIC.BICEP' -Status 'Not selected' -Message 'No infra/main.bicep yet; Bicep checks start in Phase 5.'
    }
    else {
        $built = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('azuredeploy-{0}.json' -f [guid]::NewGuid())
        $buildExit = Invoke-Native -FilePath 'az' -ArgumentList @('bicep', 'build', '--file', $mainBicep, '--outfile', $built)
        $lintExit = Invoke-Native -FilePath 'az' -ArgumentList @('bicep', 'lint', '--file', $mainBicep)
        # The on-demand activity control's templates (ADR 0020) aren't modules of main.bicep: build and lint each one.
        $standalone = @(Get-ChildItem -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'infra/control') -Filter '*.bicep' -File -ErrorAction SilentlyContinue)
        $standaloneFailures = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $standalone) {
            $standaloneBuilt = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('{0}-{1}.json' -f $file.BaseName, [guid]::NewGuid())
            $standaloneBuild = Invoke-Native -FilePath 'az' -ArgumentList @('bicep', 'build', '--file', $file.FullName, '--outfile', $standaloneBuilt)
            $standaloneLint = Invoke-Native -FilePath 'az' -ArgumentList @('bicep', 'lint', '--file', $file.FullName)
            Remove-Item -LiteralPath $standaloneBuilt -Force -ErrorAction SilentlyContinue
            if ($standaloneBuild -ne 0 -or $standaloneLint -ne 0) {
                $standaloneFailures.Add(('infra/control/{0}: build exit {1}, lint exit {2}' -f $file.Name, $standaloneBuild, $standaloneLint))
            }
        }
        if ($buildExit -ne 0 -or $lintExit -ne 0) {
            Add-StaticResult -CheckId 'STATIC.BICEP' -Status 'Fail' -Message "Bicep build exit $buildExit, lint exit $lintExit."
        }
        elseif ($standaloneFailures.Count -gt 0) {
            Add-StaticResult -CheckId 'STATIC.BICEP' -Status 'Fail' -Message ('A standalone template doesn''t build or lint: {0}.' -f ($standaloneFailures -join '; '))
        }
        else {
            $committed = Join-Path -Path $repoRoot -ChildPath 'azuredeploy.json'
            $normalize = { param($p) if (Test-Path -LiteralPath $p) { (Get-Content -LiteralPath $p -Raw) -replace "`r`n", "`n" } else { '' } }
            if ((& $normalize $built) -ne (& $normalize $committed)) {
                Add-StaticResult -CheckId 'STATIC.BICEP' -Status 'Fail' -Message 'azuredeploy.json is out of sync with infra/main.bicep. Rebuild it with the pinned Bicep version.'
            }
            else {
                Add-StaticResult -CheckId 'STATIC.BICEP' -Status 'Pass' -Message ('Bicep builds and lints cleanly (infra/main.bicep and {0} standalone template(s) in infra/control), and azuredeploy.json is in sync.' -f $standalone.Count)
            }
        }
        Remove-Item -LiteralPath $built -Force -ErrorAction SilentlyContinue
    }
}

if ('PSRule' -in $Check) {
    $paramsFile = Join-Path -Path $repoRoot -ChildPath 'infra/main.bicepparam'
    $psruleModule = Get-Module -ListAvailable -Name 'PSRule.Rules.Azure' | Where-Object { $_.Version -eq [version]$versions.tools.psruleRulesAzure }
    # PSRule expands Bicep with the Bicep CLI and needs an explicit binary on every OS: prefer the one the
    # Azure CLI installs (CI installs the pinned version there), then any bicep on PATH.
    $bicepName = if ($IsWindows) { 'bicep.exe' } else { 'bicep' }
    $bicepPath = @(
        $env:PSRULE_AZURE_BICEP_PATH
        (Join-Path -Path $HOME -ChildPath ".azure/bin/$bicepName")
        (Get-Command -Name 'bicep' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1

    if (-not (Test-Path -LiteralPath $paramsFile)) {
        Add-StaticResult -CheckId 'STATIC.PSRULE' -Status 'Not selected' -Message 'No infra/main.bicepparam yet.'
    }
    elseif (-not $psruleModule) {
        Add-StaticResult -CheckId 'STATIC.PSRULE' -Status 'Not selected' -Message "PSRule.Rules.Azure $($versions.tools.psruleRulesAzure) isn't installed; run tests/Install-TestTools.ps1 -IncludePSRule."
    }
    elseif (-not $bicepPath) {
        Add-StaticResult -CheckId 'STATIC.PSRULE' -Status 'Fail' -Message 'The Bicep CLI was not found; run az bicep install or put bicep on PATH.'
    }
    else {
        $env:PSRULE_AZURE_BICEP_PATH = $bicepPath
        Import-Module -Name 'PSRule.Rules.Azure' -RequiredVersion $versions.tools.psruleRulesAzure
        Push-Location -LiteralPath $repoRoot
        try {
            $ruleResults = @(Invoke-PSRule -InputPath 'infra/main.bicepparam' -Module 'PSRule.Rules.Azure' -Option 'ps-rule.yaml' -Format File -WarningAction SilentlyContinue)
        }
        finally {
            Pop-Location
        }
        $failed = @($ruleResults | Where-Object { $_.Outcome -in 'Fail', 'Error' })
        if ($failed.Count -gt 0) {
            $failed | Format-Table -Property RuleName, TargetName, Outcome -AutoSize | Out-String -Width 200 | Write-Output
            Add-StaticResult -CheckId 'STATIC.PSRULE' -Status 'Fail' -Message "$($failed.Count) PSRule for Azure finding(s)."
        }
        elseif ($ruleResults.Count -eq 0) {
            Add-StaticResult -CheckId 'STATIC.PSRULE' -Status 'Fail' -Message 'PSRule evaluated no resources; check the Bicep expansion.'
        }
        else {
            Add-StaticResult -CheckId 'STATIC.PSRULE' -Status 'Pass' -Message "$($ruleResults.Count) PSRule for Azure rules passed (accepted findings are suppressed in ps-rule.yaml). Bicep: $bicepPath"
        }
    }
}

if ('DotNet' -in $Check) {
    if (-not (Get-Command -Name 'dotnet' -ErrorAction SilentlyContinue)) {
        Add-StaticResult -CheckId 'STATIC.DOTNET' -Status 'Not selected' -Message 'The .NET SDK is not installed; workload generator checks were skipped.'
    }
    else {
        # Run from workload-generator so its global.json (SDK pin and test-runner opt-in) applies.
        Push-Location -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'workload-generator')
        try {
            $exitCode = Invoke-Native -FilePath 'dotnet' -ArgumentList @('restore', '--locked-mode')
            if ($exitCode -eq 0) { $exitCode = Invoke-Native -FilePath 'dotnet' -ArgumentList @('build', '--no-restore', '--configuration', 'Release') }
            if ($exitCode -eq 0) { $exitCode = Invoke-Native -FilePath 'dotnet' -ArgumentList @('test', '--no-build', '--configuration', 'Release') }
        }
        finally {
            Pop-Location
        }
        if ($exitCode -ne 0) {
            Add-StaticResult -CheckId 'STATIC.DOTNET' -Status 'Fail' -Message "Workload generator restore, build, or test failed (exit $exitCode)."
        }
        else {
            Add-StaticResult -CheckId 'STATIC.DOTNET' -Status 'Pass' -Message 'Workload generator restores, builds, and passes its tests.'
        }
    }
}

if ('FabricApp' -in $Check) {
    $appRoot = Join-Path -Path $repoRoot -ChildPath 'fabric/app'
    if (-not (Get-Command -Name 'npm' -ErrorAction SilentlyContinue)) {
        Add-StaticResult -CheckId 'STATIC.FABRICAPP' -Status 'Not selected' -Message 'Node.js (npm) is not installed; the Fabric App checks were skipped.'
    }
    else {
        Push-Location -LiteralPath $appRoot
        try {
            # Install from the lock file in CI or when nothing is installed; otherwise reuse node_modules.
            $exitCode = 0
            if ($CI -or -not (Test-Path -LiteralPath (Join-Path -Path $appRoot -ChildPath 'node_modules/.package-lock.json'))) {
                $exitCode = Invoke-Native -FilePath 'npm' -ArgumentList @('ci', '--no-audit', '--no-fund')
            }
            if ($exitCode -eq 0) { $exitCode = Invoke-Native -FilePath 'npm' -ArgumentList @('run', 'verify') }
        }
        finally {
            Pop-Location
        }
        if ($exitCode -ne 0) {
            Add-StaticResult -CheckId 'STATIC.FABRICAPP' -Status 'Fail' -Message "The Fabric App's install, typecheck, lint, tests, license check, or build failed (exit $exitCode)."
        }
        else {
            Add-StaticResult -CheckId 'STATIC.FABRICAPP' -Status 'Pass' -Message 'The Fabric App typechecks, lints, passes its tests and license check, and builds.'
        }
    }
}

if ('Markdown' -in $Check) {
    if (-not (Get-Command -Name 'npx' -ErrorAction SilentlyContinue)) {
        Add-StaticResult -CheckId 'STATIC.MARKDOWN' -Status 'Not selected' -Message 'Node.js (npx) is not installed; markdownlint was skipped.'
    }
    else {
        Push-Location -LiteralPath $repoRoot
        try {
            $exitCode = Invoke-Native -FilePath 'npx' -ArgumentList @('--yes', "markdownlint-cli2@$($versions.tools.markdownlintCli2)")
        }
        finally {
            Pop-Location
        }
        if ($exitCode -ne 0) {
            Add-StaticResult -CheckId 'STATIC.MARKDOWN' -Status 'Fail' -Message 'markdownlint-cli2 reported issues.'
        }
        else {
            Add-StaticResult -CheckId 'STATIC.MARKDOWN' -Status 'Pass' -Message 'markdownlint-cli2 found no issues.'
        }
    }
}

$results | Format-Table -Property checkId, status, message -AutoSize -Wrap | Out-String -Width 200 | Write-Output
Export-DemoResult -Result $results.ToArray() -Path (Join-Path -Path $outDirectory -ChildPath 'static-validation.jsonl')
exit (Get-DemoExitCode -Result $results.ToArray())
