# The unit tests' guard against the real Azure CLI (2026-11-16). Dot-sourced by tests/Invoke-StaticValidation.ps1, around
# Invoke-Pester, and by the test that proves it. While it's on, 'az' is a stand-in first on PATH that records each call
# and fails at once with exit code 97, and AZURE_CONFIG_DIR is an empty folder, so a test that reaches the Azure CLI
# never uses the developer's sign-in, ends fast, and is listed (STATIC.PESTER.AZURECLI). Test code only: nothing here
# ships with the demo. ASCII-only, like every PowerShell file.

$script:DemoTestAzGuardExitCode = 97

function Enable-DemoTestAzGuard {
    # Turns the guard on and returns what Disable-DemoTestAzGuard needs to put the environment back. Nested calls are
    # fine: each returns the state it found.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that changes only this process''s environment.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $Root = (Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ('dbhub-test-az-' + [guid]::NewGuid().ToString('N')))
    )

    $bin = Join-Path -Path $Root -ChildPath 'bin'
    $configDirectory = Join-Path -Path $Root -ChildPath 'azure-config'
    $log = Join-Path -Path $Root -ChildPath 'az-calls.log'
    $null = New-Item -ItemType Directory -Path $bin -Force
    $null = New-Item -ItemType Directory -Path $configDirectory -Force
    $message = 'DBHUB TEST GUARD: a unit test reached the Azure CLI; mock Invoke-DemoAzCli, Invoke-DemoAz, or the function that calls it.'
    if ($IsWindows) {
        $lines = @(
            '@echo off'
            '>>"%DBHUB_TEST_AZ_LOG%" echo az %*'
            ('>&2 echo {0}' -f $message)
            ('exit /b {0}' -f $script:DemoTestAzGuardExitCode)
        )
        [System.IO.File]::WriteAllText((Join-Path -Path $bin -ChildPath 'az.cmd'), (($lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    }
    else {
        $path = Join-Path -Path $bin -ChildPath 'az'
        $lines = @(
            '#!/bin/sh'
            'echo "az $*" >> "$DBHUB_TEST_AZ_LOG"'
            ('echo "{0}" >&2' -f $message)
            ('exit {0}' -f $script:DemoTestAzGuardExitCode)
        )
        [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), [System.Text.Encoding]::ASCII)
        & chmod '+x' $path
    }
    $state = [pscustomobject]@{
        Root            = $Root
        CallLog         = $log
        Path            = $env:PATH
        AzureConfigDir  = $env:AZURE_CONFIG_DIR
        HadConfigDir    = Test-Path -LiteralPath 'Env:AZURE_CONFIG_DIR'
        AzLog           = $env:DBHUB_TEST_AZ_LOG
        HadAzLog        = Test-Path -LiteralPath 'Env:DBHUB_TEST_AZ_LOG'
    }
    $env:PATH = $bin + [System.IO.Path]::PathSeparator + $env:PATH
    $env:AZURE_CONFIG_DIR = $configDirectory
    $env:DBHUB_TEST_AZ_LOG = $log
    return $state
}

function Get-DemoTestAzLeak {
    # The Azure CLI calls the tests made while the guard was on, one 'az ...' line each.
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State
    )

    if (-not (Test-Path -LiteralPath $State.CallLog)) {
        return @()
    }
    return @(Get-Content -LiteralPath $State.CallLog | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
}

function Disable-DemoTestAzGuard {
    # Puts PATH, AZURE_CONFIG_DIR, and DBHUB_TEST_AZ_LOG back as Enable-DemoTestAzGuard found them, and deletes its folder.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'A test helper that changes only this process''s environment.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State
    )

    $env:PATH = $State.Path
    if ($State.HadConfigDir) {
        $env:AZURE_CONFIG_DIR = $State.AzureConfigDir
    }
    else {
        Remove-Item -LiteralPath 'Env:AZURE_CONFIG_DIR' -ErrorAction SilentlyContinue
    }
    if ($State.HadAzLog) {
        $env:DBHUB_TEST_AZ_LOG = $State.AzLog
    }
    else {
        Remove-Item -LiteralPath 'Env:DBHUB_TEST_AZ_LOG' -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $State.Root -Recurse -Force -ErrorAction SilentlyContinue
}
