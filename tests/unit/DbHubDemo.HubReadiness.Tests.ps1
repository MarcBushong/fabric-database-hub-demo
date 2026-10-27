BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/modules/DbHubDemo/DbHubDemo.psd1'
    Import-Module -Name $modulePath -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Hub.Helpers.ps1')
    $script:scriptPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../../scripts/configure-fabric.ps1'))
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Invoke-DemoHubReadiness (the configure-fabric.ps1 checklist)' {
    BeforeEach {
        $config = Get-HubTestConfig
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'guard' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricHubSetting -MockWith { New-DemoResult -CheckId 'FABRIC.P4.HUBSETTING' -Area 'fabric' -Target 'tenant' -Status 'Manual action required' -Message 'p4' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricWorkspace -MockWith { New-DemoResult -CheckId 'FABRIC.P5.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'p5' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricViewerLicense -MockWith { New-DemoResult -CheckId 'PREFLIGHT.FABRIC.VIEWERLICENSE' -Area 'preflight' -Target 'fabric' -Status 'Warning' -Message 'p11' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubEstate -MockWith { New-DemoResult -CheckId 'HUB.ESTATE.T1' -Area 'hub' -Target 'T1' -Status 'Pass' -Message 'estate' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith { New-DemoResult -CheckId 'TELEMETRY.T1' -Area 'hub' -Target 'T1' -Status 'Pass' -Message 'telemetry' }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoT3Readiness -MockWith { [pscustomobject]@{ Ready = $true; LagMinutes = 4; Results = @(New-DemoResult -CheckId 'T3.READINESS.GATE' -Area 'hub' -Target 'T3' -Status 'Pass' -Message 'gate') } }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoPresenterAccess -MockWith { New-DemoResult -CheckId 'HUB.PRESENTER.READER' -Area 'hub' -Target 'subscription' -Status 'Not selected' -Message 'presenters' }
    }

    It 'stops after the subscription guard when it fails' {
        Mock -ModuleName DbHubDemo -CommandName Assert-DemoAzContext -MockWith { throw 'Subscription guard: the Azure CLI context is another subscription. Nothing was changed.' }
        $results = @(Invoke-DemoHubReadiness -Config $config)
        $results.Count | Should -Be 1
        $results[0].checkId | Should -Be 'PREFLIGHT.GUARD.CONTEXT'
        $results[0].status | Should -Be 'Fail'
        foreach ($name in 'Test-DemoFabricHubSetting', 'Test-DemoFabricWorkspace', 'Test-DemoFabricViewerLicense', 'Test-DemoHubEstate', 'Test-DemoHubTelemetry', 'Test-DemoT3Readiness', 'Set-DemoPresenterAccess') {
            Should -Invoke -ModuleName DbHubDemo -CommandName $name -Times 0
        }
    }

    It 'runs the guard, P4, P5, the P11 viewer licensing, Estate, telemetry, and presenter access in order' {
        $results = @(Invoke-DemoHubReadiness -Config $config -WaitMinutes 15 -FabricAdmin)
        ($results | ForEach-Object { $_.checkId }) | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'FABRIC.P4.HUBSETTING', 'FABRIC.P5.WORKSPACE', 'PREFLIGHT.FABRIC.VIEWERLICENSE', 'HUB.ESTATE.T1', 'TELEMETRY.T1', 'HUB.PRESENTER.READER')
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricHubSetting -Times 1 -Exactly -ParameterFilter { $FabricAdmin }
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -Times 1 -Exactly -ParameterFilter { $WaitMinutes -eq 15 }
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoT3Readiness -Times 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoPresenterAccess -Times 1 -Exactly -ParameterFilter { -not $WhatIf }
    }

    It 'hands the P11 check the capacity that P5 read, so it sends no request of its own (Phase 18)' {
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricWorkspace -MockWith {
            New-DemoResult -CheckId 'FABRIC.P5.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'p5'
            New-DemoResult -CheckId 'FABRIC.P5.CAPACITY' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'capacity' -Evidence @{ capacityId = '77777777-7777-7777-7777-777777777777'; sku = 'F16'; state = 'Active' }
        }
        $null = Invoke-DemoHubReadiness -Config $config
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricViewerLicense -Times 1 -Exactly -ParameterFilter {
            $CapacityResult.checkId -eq 'FABRIC.P5.CAPACITY' -and $CapacityResult.evidence.sku -eq 'F16'
        }
    }

    It 'honors -SkipFabric, -SkipTelemetry, -T3ReadinessGate, and -WhatIf' {
        $results = @(Invoke-DemoHubReadiness -Config $config -SkipFabric -SkipTelemetry -T3ReadinessGate -WhatIf)
        ($results | ForEach-Object { $_.checkId }) | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'HUB.ESTATE.T1', 'T3.READINESS.GATE', 'HUB.PRESENTER.READER')
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricHubSetting -Times 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricViewerLicense -Times 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -Times 0
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoPresenterAccess -Times 1 -Exactly -ParameterFilter { $WhatIf }
    }

    It 'passes a Fabric token the operator already has to P4, P5, and P11' {
        $script:passed = Get-HubFakeToken
        $null = Invoke-DemoHubReadiness -Config $config -FabricToken (ConvertTo-HubSecureString $script:passed)
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricHubSetting -Times 1 -Exactly -ParameterFilter { (ConvertFrom-HubSecureString $Token) -eq $script:passed }
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricWorkspace -Times 1 -Exactly -ParameterFilter { (ConvertFrom-HubSecureString $Token) -eq $script:passed }
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoFabricViewerLicense -Times 1 -Exactly -ParameterFilter { (ConvertFrom-HubSecureString $Token) -eq $script:passed }
    }

    It 'reports a target without telemetry as the pending manual step that Estate reports' {
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubEstate -MockWith {
            New-DemoResult -CheckId 'HUB.ESTATE.T1' -Area 'hub' -Target 'T1' -Status 'Pass' -Message 'estate'
            New-DemoResult -CheckId 'HUB.ESTATE.T2' -Area 'hub' -Target 'T2' -Status 'Manual action required' -Message 'wizard pending'
        }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoHubTelemetry -MockWith {
            New-DemoResult -CheckId 'TELEMETRY.T1' -Area 'hub' -Target 'T1' -Status 'Fail' -Message 'no rows' -Evidence @{ rows = 0 }
            New-DemoResult -CheckId 'TELEMETRY.T2' -Area 'hub' -Target 'T2' -Status 'Fail' -Message 'no rows' -Evidence @{ rows = 0 }
        }
        $results = @(Invoke-DemoHubReadiness -Config $config -SkipFabric -Target T1, T2)
        ($results | Where-Object { $_.checkId -eq 'TELEMETRY.T1' }).status | Should -Be 'Fail'
        $t2 = $results | Where-Object { $_.checkId -eq 'TELEMETRY.T2' }
        $t2.status | Should -Be 'Manual action required'
        $t2.message | Should -Match 'HUB\.ESTATE\.T2'
        Get-DemoExitCode -Result ($results | Where-Object { $_.target -ne 'T1' }) | Should -Be 0
    }

    It 'reports the gate as Not selected when T3 isn''t a target' {
        $results = @(Invoke-DemoHubReadiness -Config $config -Target T1 -T3ReadinessGate -SkipFabric -SkipTelemetry)
        ($results | Where-Object { $_.checkId -eq 'T3.READINESS.GATE' }).status | Should -Be 'Not selected'
        Should -Invoke -ModuleName DbHubDemo -CommandName Test-DemoT3Readiness -Times 0
    }
}

Describe 'scripts/configure-fabric.ps1 (the checklist, then the Phase 12 notebook import)' {
    BeforeAll {
        # Stand-ins with Phase 12's parameters, so the script finds the import functions and the tests can mock
        # them both before and after the merge with Phase 12. Defined in this block, they never leave it.
        function Get-DemoFabricNotebookDefinition {
            [CmdletBinding()]
            param([string] $Path, [string] $LakehouseId, [string] $LakehouseName, [string] $LakehouseWorkspaceId)
            throw ('Stand-in for {0} {1} {2} {3}; the tests mock it.' -f $Path, $LakehouseId, $LakehouseName, $LakehouseWorkspaceId)
        }
        function Import-DemoFabricNotebook {
            [CmdletBinding(SupportsShouldProcess)]
            param([string] $WorkspaceId, [object] $Notebook, [securestring] $Token, [int] $TimeoutSeconds)
            if ($PSCmdlet.ShouldProcess($WorkspaceId, 'Stand-in')) {
                throw ('Stand-in for {0} {1} {2} {3}; the tests mock it.' -f $WorkspaceId, $Notebook, ($null -ne $Token), $TimeoutSeconds)
            }
        }
        function Get-DemoFabricToken {
            [CmdletBinding()]
            param([string] $SubscriptionId)
            throw ('Stand-in for {0}; the tests mock it.' -f $SubscriptionId)
        }

        $script:fakeWorkspaceId = '99999999-9999-9999-9999-999999999999'
        $script:fakeLakehouseId = '88888888-8888-8888-8888-888888888888'
        $example = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath '../../config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $example.Remove('$schema')
        $example['subscriptionId'] = $script:HubSubscriptionId
        $example['tenantId'] = $script:HubTenantId
        $example['t3AdminGroupObjectId'] = '44444444-4444-4444-4444-444444444444'
        $example['fabric']['workspaceId'] = $script:fakeWorkspaceId
        $example['fabric']['lakehouseId'] = $script:fakeLakehouseId
        $script:fabricConfigPath = Join-Path -Path $TestDrive -ChildPath 'fabric.config.json'
        Set-Content -LiteralPath $script:fabricConfigPath -Value ($example | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        $example['fabric'].Remove('workspaceId')
        $script:noWorkspaceConfigPath = Join-Path -Path $TestDrive -ChildPath 'no-workspace.config.json'
        Set-Content -LiteralPath $script:noWorkspaceConfigPath -Value ($example | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        $script:outputPath = Join-Path -Path $TestDrive -ChildPath 'configure-fabric.jsonl'
        $script:importIds = @('FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT', 'FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY')

        function Read-ScriptResult {
            @(Get-Content -LiteralPath $script:outputPath | ConvertFrom-Json)
        }
    }

    BeforeEach {
        # Mock bodies run inside the script's scope, under its StrictMode, so they read plain variables set
        # here (BeforeEach and It share a scope) instead of $script: ones, and read -WhatIf from $WhatIfPreference.
        Clear-DemoSecret
        $script:cliToken = Get-HubFakeToken
        $cliToken = $script:cliToken
        $readinessResults = @(
            New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'guard'
            New-DemoResult -CheckId 'FABRIC.P5.WORKSPACE' -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'p5'
        )
        Mock -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI call expected' }
        Mock -CommandName Invoke-DemoHubReadiness -MockWith { $readinessResults }
        Mock -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'guard' }
        Mock -CommandName Get-DemoFabricToken -MockWith { ConvertTo-HubSecureString $cliToken }
        Mock -CommandName Get-DemoFabricNotebookDefinition -MockWith { [pscustomobject]@{ DisplayName = [System.IO.Path]::GetFileNameWithoutExtension($Path); SizeBytes = 2048; Sha256 = ('ab' * 32) } }
        # Step 0 (Phase 26a) passes the configuration through: these tests cover the checklist and the import, and
        # DbHubDemo.FabricResolve.Tests covers the name lookup.
        Mock -CommandName Resolve-DemoFabricConfig -MockWith { [pscustomobject]@{ Config = $Config; Results = @(); Resolved = $true; LakehouseCreated = $false; WorkspaceCreated = $false } }
        Mock -CommandName Import-DemoFabricNotebook -MockWith {
            $status = if ($WhatIfPreference) { 'Not selected' } else { 'Pass' }
            New-DemoResult -CheckId ('FABRIC.IMPORT.' + $Notebook.DisplayName.ToUpperInvariant()) -Area 'fabric' -Target 'fabric' -Status $status -Message 'import'
        }
    }

    It 'runs the checklist with the passed token, then imports each notebook with it, and exits with the result code' {
        $script:passed = Get-HubFakeToken
        $output = & $script:scriptPath -ConfigPath $script:fabricConfigPath -OutputPath $script:outputPath -FabricToken (ConvertTo-HubSecureString $script:passed) -Confirm:$false *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        (Read-ScriptResult).checkId | Should -Be (@('PREFLIGHT.GUARD.CONTEXT', 'FABRIC.P5.WORKSPACE') + $script:importIds)
        Should -Invoke -CommandName Invoke-DemoHubReadiness -Times 1 -Exactly -ParameterFilter {
            (ConvertFrom-HubSecureString $FabricToken) -eq $script:passed -and -not $WhatIf -and $Config['subscriptionId'] -eq $script:HubSubscriptionId -and $Target.Count -eq 3
        }
        Should -Invoke -CommandName Get-DemoFabricNotebookDefinition -Times 1 -Exactly -ParameterFilter {
            $Path -like '*NB_DatabaseHub_Deployment.ipynb' -and $LakehouseId -eq $script:fakeLakehouseId -and $LakehouseWorkspaceId -eq $script:fakeWorkspaceId
        }
        Should -Invoke -CommandName Import-DemoFabricNotebook -Times 2 -Exactly -ParameterFilter {
            $WorkspaceId -eq $script:fakeWorkspaceId -and (ConvertFrom-HubSecureString $Token) -eq $script:passed -and $TimeoutSeconds -eq 600 -and -not $WhatIf
        }
        Should -Invoke -CommandName Get-DemoFabricToken -Times 0
        Should -Invoke -CommandName Assert-DemoAzContext -Times 0
        $output | Should -Not -Match ([regex]::Escape($script:passed))
        (Get-Content -LiteralPath $script:outputPath -Raw) | Should -Not -Match ([regex]::Escape($script:passed))
    }

    It 'runs the checklist in what-if mode and plans the import without a token under -WhatIf' {
        $null = & $script:scriptPath -ConfigPath $script:fabricConfigPath -OutputPath $script:outputPath -WhatIf *>&1
        $LASTEXITCODE | Should -Be 0
        (Read-ScriptResult | Where-Object { $_.checkId -like 'FABRIC.IMPORT.*' }).status | Should -Be @('Not selected', 'Not selected')
        Should -Invoke -CommandName Invoke-DemoHubReadiness -Times 1 -Exactly -ParameterFilter { $WhatIf }
        Should -Invoke -CommandName Import-DemoFabricNotebook -Times 2 -Exactly -ParameterFilter { $WhatIf }
        Should -Invoke -CommandName Import-DemoFabricNotebook -Times 0 -ParameterFilter { $null -ne $Token }
        # Step 0 (Phase 26a) reads by name with a token after the guard, as the checklist does; it creates nothing.
        Should -Invoke -CommandName Assert-DemoAzContext -Times 1 -Exactly
        Should -Invoke -CommandName Get-DemoFabricToken -Times 1 -Exactly
        Should -Invoke -CommandName Resolve-DemoFabricConfig -Times 1 -Exactly -ParameterFilter { $WhatIf -and $null -ne $Token }
    }

    It 'gets an Azure CLI token after the guard when none is passed' {
        $null = & $script:scriptPath -ConfigPath $script:fabricConfigPath -OutputPath $script:outputPath -Notebook NB_DatabaseHub_LiveActivity -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        (Read-ScriptResult)[-1].checkId | Should -Be 'FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY'
        # One token for the whole run: step 0 gets it after the guard, and the checklist and the import reuse it.
        Should -Invoke -CommandName Invoke-DemoHubReadiness -Times 1 -Exactly -ParameterFilter { (ConvertFrom-HubSecureString $FabricToken) -eq $script:cliToken }
        Should -Invoke -CommandName Assert-DemoAzContext -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:HubSubscriptionId -and $TenantId -eq $script:HubTenantId }
        Should -Invoke -CommandName Get-DemoFabricToken -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq $script:HubSubscriptionId }
        Should -Invoke -CommandName Import-DemoFabricNotebook -Times 1 -Exactly -ParameterFilter { (ConvertFrom-HubSecureString $Token) -eq $script:cliToken }
    }

    It 'imports nothing after a failed subscription guard unless a passed token makes the Azure CLI unnecessary' {
        $readinessResults = @(New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Fail' -Message 'Subscription guard: the Azure CLI context is another subscription.')
        # Step 0 (Phase 26a) runs the guard first, so a failed guard stops the run there, and the checklist is skipped.
        Mock -CommandName Assert-DemoAzContext -MockWith { throw 'Subscription guard: the Azure CLI context is another subscription.' }
        $null = & $script:scriptPath -ConfigPath $script:fabricConfigPath -OutputPath $script:outputPath -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 1
        $results = Read-ScriptResult
        $results.Count | Should -Be 1
        $results[0].status | Should -Be 'Fail'
        Should -Invoke -CommandName Get-DemoFabricNotebookDefinition -Times 0
        Should -Invoke -CommandName Import-DemoFabricNotebook -Times 0
        Should -Invoke -CommandName Assert-DemoAzContext -Times 1 -Exactly
        Should -Invoke -CommandName Invoke-DemoHubReadiness -Times 0

        $null = & $script:scriptPath -ConfigPath $script:fabricConfigPath -OutputPath $script:outputPath -FabricToken (ConvertTo-HubSecureString (Get-HubFakeToken)) -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 1
        (Read-ScriptResult).checkId | Should -Be (@('PREFLIGHT.GUARD.CONTEXT') + $script:importIds)
    }

    It 'runs only the import with -SkipHubChecks, and only the checklist with -SkipNotebookImport' {
        $null = & $script:scriptPath -ConfigPath $script:fabricConfigPath -OutputPath $script:outputPath -SkipHubChecks -FabricToken (ConvertTo-HubSecureString (Get-HubFakeToken)) -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        (Read-ScriptResult).checkId | Should -Be $script:importIds
        Should -Invoke -CommandName Invoke-DemoHubReadiness -Times 0

        $null = & $script:scriptPath -ConfigPath $script:fabricConfigPath -OutputPath $script:outputPath -SkipNotebookImport -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        (Read-ScriptResult).checkId | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'FABRIC.P5.WORKSPACE')
        Should -Invoke -CommandName Invoke-DemoHubReadiness -Times 1 -Exactly
        Should -Invoke -CommandName Import-DemoFabricNotebook -Times 2 -Exactly
    }

    It 'reports the import as Not selected without a workspace, and still writes the checklist''s results' {
        $null = & $script:scriptPath -ConfigPath $script:noWorkspaceConfigPath -OutputPath $script:outputPath -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        $results = Read-ScriptResult
        $results.checkId | Should -Be @('PREFLIGHT.GUARD.CONTEXT', 'FABRIC.P5.WORKSPACE', 'FABRIC.NOTEBOOKS.IMPORT')
        $results[2].status | Should -Be 'Not selected'
        Should -Invoke -CommandName Import-DemoFabricNotebook -Times 0
    }

    It 'asks for the manual import when the module has no Phase 12 import functions' {
        Mock -CommandName Get-Command -ParameterFilter { @($Name | Where-Object { $_ -in 'Get-DemoFabricNotebookDefinition', 'Import-DemoFabricNotebook', 'Get-DemoFabricToken' }).Count -gt 0 } -MockWith { }
        $null = & $script:scriptPath -ConfigPath $script:fabricConfigPath -OutputPath $script:outputPath -TreatManualAsError -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 2
        $import = Read-ScriptResult | Where-Object { $_.checkId -eq 'FABRIC.NOTEBOOKS.IMPORT' }
        $import.status | Should -Be 'Manual action required'
        $import.message | Should -Match 'Import-DemoFabricNotebook'
        $import.remediation | Should -Match 'fabric/notebooks'
        Should -Invoke -CommandName Import-DemoFabricNotebook -Times 0
    }

    It 'needs the configuration unless -WorkspaceId and -FabricToken are both given, and then skips the checklist' {
        $missing = Join-Path -Path $TestDrive -ChildPath 'missing.config.json'
        { & $script:scriptPath -ConfigPath $missing -OutputPath $script:outputPath } | Should -Throw '*Configuration file not found*'
        $null = & $script:scriptPath -ConfigPath $missing -OutputPath $script:outputPath -WorkspaceId $script:fakeWorkspaceId -FabricToken (ConvertTo-HubSecureString (Get-HubFakeToken)) -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        (Read-ScriptResult).checkId | Should -Be $script:importIds
        Should -Invoke -CommandName Invoke-DemoHubReadiness -Times 0
        Should -Invoke -CommandName Get-DemoFabricNotebookDefinition -Times 2 -Exactly -ParameterFilter { -not $LakehouseId }
    }
}

Describe 'scripts/configure-fabric.ps1 (static)' {
    BeforeAll {
        $text = Get-Content -LiteralPath $script:scriptPath -Raw
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:scriptPath, [ref]$tokens, [ref]$errors)
        $commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
    }

    It 'parses and has the script conventions' {
        $errors | Should -BeNullOrEmpty
        $text | Should -Match '(?m)^#Requires -Version 7\.4'
        $text | Should -Match '\.SYNOPSIS'
        $binding = $ast.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
        $binding.NamedArguments.ArgumentName | Should -Contain 'SupportsShouldProcess'
        ($binding.NamedArguments | Where-Object { $_.ArgumentName -eq 'ConfirmImpact' }).Argument.Value | Should -Be 'Medium'
        $names = $ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        foreach ($name in 'ConfigPath', 'Notebook', 'WorkspaceId', 'FabricToken', 'TimeoutSeconds', 'OutputPath', 'Target', 'FabricAdmin', 'WaitMinutes', 'T3ReadinessGate', 'SkipHubChecks', 'SkipNotebookImport', 'TreatManualAsError') {
            $names | Should -Contain $name
            $text | Should -Match ('\.PARAMETER {0}\b' -f $name)
        }
    }

    It 'runs the checklist, then the marked Phase 12 import region, and exits with the result code' {
        foreach ($name in 'Get-DemoConfig', 'Invoke-DemoHubReadiness', 'Get-DemoFabricNotebookDefinition', 'Import-DemoFabricNotebook', 'Export-DemoResult', 'Get-DemoExitCode') {
            $commands | Should -Contain $name
        }
        $start = $text.IndexOf('#region Notebook import (Phase 12)')
        $end = $text.IndexOf('#endregion Notebook import (Phase 12)')
        $start | Should -BeGreaterThan $text.IndexOf('Invoke-DemoHubReadiness @readiness')
        $end | Should -BeGreaterThan $start
        $region = $text.Substring($start, $end - $start)
        $region | Should -Match 'Get-Command -Name'
        $region | Should -Match 'Import-DemoFabricNotebook -WorkspaceId'
        $text.Substring(0, $start) | Should -Not -Match 'Import-DemoFabricNotebook -'
        $text | Should -Match 'exit \(Get-DemoExitCode'
    }

    It 'makes no Azure CLI or HTTP call of its own' {
        $commands | Should -Not -Contain 'az'
        $commands | Should -Not -Contain 'Invoke-RestMethod'
        $commands | Should -Not -Contain 'Invoke-WebRequest'
        $commands | Should -Not -Contain 'Invoke-DemoAz'
    }
}
