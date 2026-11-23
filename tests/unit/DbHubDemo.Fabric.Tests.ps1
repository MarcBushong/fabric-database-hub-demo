BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    . (Join-Path -Path $PSScriptRoot -ChildPath 'DbHubDemo.Guard.Helpers.ps1')
    # Writes and token requests need the context the subscription guard validates; this is the unit-test hook.
    Initialize-GuardTestContext -SubscriptionId '44444444-4444-4444-4444-444444444444' -TenantId '55555555-5555-5555-5555-555555555555'
    $script:configureFabric = Join-Path -Path $repoRoot -ChildPath 'scripts/configure-fabric.ps1'
    $script:deploymentNotebook = Join-Path -Path $repoRoot -ChildPath 'fabric/notebooks/NB_DatabaseHub_Deployment.ipynb'
    $script:liveNotebook = Join-Path -Path $repoRoot -ChildPath 'fabric/notebooks/NB_DatabaseHub_LiveActivity.ipynb'
    $script:api = 'https://api.fabric.microsoft.com/v1'

    # Obviously fake IDs: every group repeats one character.
    $script:workspaceId = '11111111-1111-1111-1111-111111111111'
    $script:itemId = '22222222-2222-2222-2222-222222222222'
    $script:operationId = '33333333-3333-3333-3333-333333333333'
    $script:subscriptionId = '44444444-4444-4444-4444-444444444444'
    $script:tenantId = '55555555-5555-5555-5555-555555555555'
    $script:otherLakehouseId = '66666666-6666-6666-6666-666666666666'
    $script:otherWorkspaceId = '77777777-7777-7777-7777-777777777777'

    # Built at run time so secret scanners don't flag the fixture.
    $script:plainToken = 'ey' + 'J' + ('t' * 24) + '.' + 'ey' + 'J' + ('p' * 24) + '.' + ('s' * 24)

    function ConvertTo-TestSecureString {
        param([string] $Value)
        $secure = [System.Security.SecureString]::new()
        foreach ($character in $Value.ToCharArray()) {
            $secure.AppendChar($character)
        }
        $secure.MakeReadOnly()
        return $secure
    }

    function New-FabricResponse {
        param(
            [int] $Status,
            [object] $Body,
            [hashtable] $Headers = @{}
        )
        $content = if ($null -ne $Body) { $Body | ConvertTo-Json -Depth 20 -Compress } else { '' }
        [pscustomobject]@{ StatusCode = $Status; Headers = $Headers; Content = $content }
    }

    function New-TestNotebook {
        param(
            [string] $Path,
            [switch] $WithOutput,
            [switch] $WithExecutionCount
        )
        $cell = [ordered]@{
            cell_type       = 'code'
            execution_count = if ($WithExecutionCount) { 3 } else { $null }
            id              = '0'
            metadata        = @{}
            outputs         = if ($WithOutput) { @(@{ output_type = 'stream'; name = 'stdout'; text = @('2') }) } else { @() }
            source          = @('1+1')
        }
        $notebook = [ordered]@{
            cells          = @($cell)
            metadata       = [ordered]@{
                dependencies = [ordered]@{
                    lakehouse = [ordered]@{
                        default_lakehouse              = '88888888-8888-8888-8888-888888888888'
                        default_lakehouse_name         = 'LH_DatabaseHub'
                        default_lakehouse_workspace_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                        known_lakehouses               = @(@{ id = '88888888-8888-8888-8888-888888888888' })
                    }
                }
                kernelspec   = [ordered]@{ display_name = 'PySpark'; language = 'python'; name = 'synapse_pyspark' }
            }
            nbformat       = 4
            nbformat_minor = 5
        }
        Set-Content -LiteralPath $Path -Value ($notebook | ConvertTo-Json -Depth 20) -Encoding utf8NoBOM
        return $Path
    }

    function ConvertFrom-TestPayload {
        param([string] $Payload)
        [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Payload))
    }

    # Records every Invoke-WebRequest call and answers it from $routes, a list of
    # @{ Method; Match (regex on the URI); Responses (queue) } entries. The last response repeats.
    function Set-FabricMock {
        param([object[]] $Routes)
        $script:requests = [System.Collections.Generic.List[object]]::new()
        $script:routes = foreach ($route in $Routes) {
            [pscustomobject]@{ Method = $route.Method; Match = $route.Match; Responses = [System.Collections.Generic.Queue[object]]::new([object[]]$route.Responses) }
        }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith {}
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            # Unqualified names: a mock can run inside configure-fabric.ps1, whose own script scope is not this file's.
            # configure-fabric.ps1 runs under Set-StrictMode, so read parameters that may not be bound with Get-Variable.
            $requests.Add([pscustomobject]@{
                    Method         = $Method
                    Uri            = [string]$Uri
                    Body           = Get-Variable -Name 'Body' -ValueOnly -ErrorAction Ignore
                    Authentication = Get-Variable -Name 'Authentication' -ValueOnly -ErrorAction Ignore
                    Token          = Get-Variable -Name 'Token' -ValueOnly -ErrorAction Ignore
                    Headers        = Get-Variable -Name 'Headers' -ValueOnly -ErrorAction Ignore
                })
            foreach ($route in $routes) {
                if ($route.Method -eq $Method -and [string]$Uri -match $route.Match) {
                    if ($route.Responses.Count -gt 1) {
                        return $route.Responses.Dequeue()
                    }
                    return $route.Responses.Peek()
                }
            }
            throw "Unexpected request: $Method $Uri"
        }
    }

    function Get-RequestBody {
        param([object] $Request)
        $Request.Body | ConvertFrom-Json -Depth 32
    }

    # A workspace's copy of a notebook as Fabric gives it back (Get Item Definition, ipynb), for -KeepEdited (2026-11-23):
    # each cell's source in one string with CRLF, outputs and execution counts from a run, Fabric's own metadata, and a
    # .platform part. -Change edits the parsed notebook first.
    function New-WorkspaceCopy {
        param([pscustomobject] $Notebook, [scriptblock] $Change = {})
        $copy = ConvertFrom-TestPayload -Payload ([string]$Notebook.Definition['parts'][0]['payload']) | ConvertFrom-Json -AsHashtable
        foreach ($cell in @($copy['cells'])) {
            $cell['source'] = ((@($cell['source']) -join '') -replace "`n", "`r`n") + "`r`n"
            if ($cell['cell_type'] -eq 'code') {
                $cell['execution_count'] = 4
                $cell['outputs'] = @(@{ output_type = 'stream'; name = 'stdout'; text = @('ran') })
            }
        }
        $copy['metadata'] = @{ kernel_info = @{ name = 'synapse_pyspark' }; widgets = @{} }
        & $Change $copy
        $payload = [System.Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $copy -Depth 20)))
        New-FabricResponse -Status 200 -Body @{ definition = @{ format = 'ipynb'; parts = @(
                    @{ path = 'notebook-content.ipynb'; payload = $payload; payloadType = 'InlineBase64' }
                    @{ path = '.platform'; payload = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes('{}')); payloadType = 'InlineBase64' }
                ) }
        }
    }

    # The fingerprint of a copy from New-WorkspaceCopy, as deploy.ps1 reads it.
    function Get-CopyFingerprint {
        param([object] $Response)
        InModuleScope DbHubDemo -Parameters @{ Content = $Response.Content } {
            Get-DemoNotebookFingerprint -Text ([System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String([string]($Content | ConvertFrom-Json).definition.parts[0].payload)))
        }
    }

    # An edit in Fabric: the first code cell after the parameters gets a line.
    $script:editCode = {
        param($Notebook)
        $cell = @($Notebook['cells'] | Where-Object { $_['cell_type'] -eq 'code' -and -not (@($_['metadata']['tags']) -contains 'parameters') })[0]
        $cell['source'] = '# my change' + "`r`n" + $cell['source']
    }

    $script:listUri = [regex]::Escape("$script:api/workspaces/$script:workspaceId/items?type=Notebook")
    $script:createUri = '^' + [regex]::Escape("$script:api/workspaces/$script:workspaceId/items") + '$'
    $script:updateUri = '^' + [regex]::Escape("$script:api/workspaces/$script:workspaceId/items/$script:itemId/updateDefinition") + '$'
    $script:operationUri = '^' + [regex]::Escape("$script:api/operations/$script:operationId") + '$'
    $script:resultUri = '^' + [regex]::Escape("$script:api/operations/$script:operationId/result") + '$'
}

AfterAll {
    Remove-Module -Name DbHubDemo -ErrorAction SilentlyContinue
}

Describe 'Get-DemoFabricNotebookDefinition' {
    It 'builds the documented ipynb definition for <_>: one notebook-content.ipynb part in InlineBase64' -ForEach @('NB_DatabaseHub_Deployment', 'NB_DatabaseHub_LiveActivity') {
        $path = Join-Path -Path $repoRoot -ChildPath "fabric/notebooks/$_.ipynb"
        # No lakehouse to bind, so the payload is the file as it is (the repository's copy holds no IDs, ADR 0021).
        $definition = Get-DemoFabricNotebookDefinition -Path $path
        $definition.DisplayName | Should -Be $_
        $definition.LakehouseRebound | Should -BeFalse
        $definition.Definition.format | Should -Be 'ipynb'
        @($definition.Definition.parts).Count | Should -Be 1
        $definition.Definition.parts[0].path | Should -Be 'notebook-content.ipynb'
        $definition.Definition.parts[0].payloadType | Should -Be 'InlineBase64'
        $bytes = [System.Convert]::FromBase64String($definition.Definition.parts[0].payload)
        $bytes | Should -Be ([System.IO.File]::ReadAllBytes($path))
        $definition.Sha256 | Should -Be ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant())
    }

    It 'refuses a notebook with outputs' {
        $path = New-TestNotebook -Path (Join-Path -Path $TestDrive -ChildPath 'with-output.ipynb') -WithOutput
        { Get-DemoFabricNotebookDefinition -Path $path } | Should -Throw '*outputs*'
    }

    It 'refuses a notebook with an execution count' {
        $path = New-TestNotebook -Path (Join-Path -Path $TestDrive -ChildPath 'with-count.ipynb') -WithExecutionCount
        { Get-DemoFabricNotebookDefinition -Path $path } | Should -Throw '*execution counts*'
    }

    It 'refuses a file that is not nbformat 4 JSON' {
        $broken = Join-Path -Path $TestDrive -ChildPath 'broken.ipynb'
        Set-Content -LiteralPath $broken -Value '{ "cells": [' -Encoding utf8NoBOM
        { Get-DemoFabricNotebookDefinition -Path $broken } | Should -Throw '*valid JSON*'
        $old = Join-Path -Path $TestDrive -ChildPath 'v3.ipynb'
        Set-Content -LiteralPath $old -Value '{ "nbformat": 3, "worksheets": [] }' -Encoding utf8NoBOM
        { Get-DemoFabricNotebookDefinition -Path $old } | Should -Throw '*nbformat 4*'
    }

    It 'binds only the uploaded copy to a different configured lakehouse' {
        $path = New-TestNotebook -Path (Join-Path -Path $TestDrive -ChildPath 'rebind.ipynb')
        $before = [System.IO.File]::ReadAllBytes($path)
        $definition = Get-DemoFabricNotebookDefinition -Path $path -LakehouseId $otherLakehouseId -LakehouseName 'LH_Other' -LakehouseWorkspaceId $otherWorkspaceId
        $definition.LakehouseRebound | Should -BeTrue
        $uploaded = ConvertFrom-TestPayload -Payload $definition.Definition.parts[0].payload | ConvertFrom-Json -AsHashtable
        $binding = $uploaded.metadata.dependencies.lakehouse
        $binding.default_lakehouse | Should -Be $otherLakehouseId
        $binding.default_lakehouse_name | Should -Be 'LH_Other'
        $binding.default_lakehouse_workspace_id | Should -Be $otherWorkspaceId
        @($binding.known_lakehouses)[0].id | Should -Be $otherLakehouseId
        $uploaded.cells[0].source | Should -Be @('1+1')
        [System.IO.File]::ReadAllBytes($path) | Should -Be $before
    }

    It 'points only the uploaded copy at a GitHub repository, without a lakehouse too, and leaves the live-activity notebook, which has no GitHub path, as it is' {
        $before = [System.IO.File]::ReadAllBytes($liveNotebook)
        $definition = Get-DemoFabricNotebookDefinition -Path $liveNotebook -GitHubRepository 'contoso/dbhub-fork' -GitHubEnvironment 'demo-fork'
        $definition.LakehouseRebound | Should -BeFalse
        $uploaded = ConvertFrom-TestPayload -Payload $definition.Definition.parts[0].payload | ConvertFrom-Json -AsHashtable -Depth 64
        $parameters = (@($uploaded['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]['source']) -join ''
        # Since 2026-11-14 (ADR 0026) the live-activity notebook has no GITHUB_* parameter, so nothing is added to it.
        $parameters | Should -Not -Match 'GITHUB_'
        $parameters | Should -Match '(?m)^WORKSPACE_ID = ""$'
        $uploaded['metadata']['dependencies']['lakehouse'].Contains('default_lakehouse') | Should -BeFalse
        [System.IO.File]::ReadAllBytes($liveNotebook) | Should -Be $before
        # The deployment notebook has no GITHUB_ENVIRONMENT line, so only its repository changes.
        $deploymentBefore = [System.IO.File]::ReadAllBytes($deploymentNotebook)
        $deployment = Get-DemoFabricNotebookDefinition -Path $deploymentNotebook -GitHubRepository 'contoso/dbhub-fork' -GitHubEnvironment 'demo-fork'
        $text = ConvertFrom-TestPayload -Payload $deployment.Definition.parts[0].payload
        $text | Should -Match 'GITHUB_REPOSITORY = \\"contoso/dbhub-fork\\"'
        $text | Should -Not -Match 'GITHUB_ENVIRONMENT'
        [System.IO.File]::ReadAllBytes($deploymentNotebook) | Should -Be $deploymentBefore
        { Get-DemoFabricNotebookDefinition -Path $liveNotebook -GitHubRepository 'not a repository' } | Should -Throw
    }
}

Describe 'Get-DemoFabricToken' {
    BeforeEach {
        Clear-DemoSecret
    }

    It 'asks the Azure CLI for a Fabric token in the configured subscription and returns a SecureString' {
        $script:fabricToken = Get-GuardTestToken -TenantId $tenantId
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $script:azArguments = $ArgumentList
            [pscustomobject]@{ ExitCode = 0; StdOut = ('{"accessToken":"' + $script:fabricToken + '"}'); StdErr = '' }
        }
        $secure = Get-DemoFabricToken -SubscriptionId $subscriptionId
        $secure | Should -BeOfType ([securestring])
        [System.Net.NetworkCredential]::new('', $secure).Password | Should -BeExactly $script:fabricToken
        ($script:azArguments -join ' ') | Should -BeExactly "account get-access-token --resource https://api.fabric.microsoft.com --output json --subscription $subscriptionId"
        Protect-DemoText -Text "token $($script:fabricToken)" | Should -Be 'token [REDACTED]'
    }

    It 'refuses a Fabric token issued for another tenant' {
        $script:fabricToken = Get-GuardTestToken -TenantId '99999999-9999-9999-9999-999999999999'
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdOut = ('{"accessToken":"' + $script:fabricToken + '"}'); StdErr = '' }
        }
        { Get-DemoFabricToken -SubscriptionId $subscriptionId } | Should -Throw '*not the configured tenant*'
    }

    It 'fails with sign-in guidance when the Azure CLI returns no token' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { [pscustomobject]@{ ExitCode = 0; StdOut = ''; StdErr = '' } }
        { Get-DemoFabricToken -SubscriptionId $subscriptionId } | Should -Throw '*az login*'
    }
}

Describe 'Import-DemoFabricNotebook' {
    BeforeAll {
        $script:secureToken = ConvertTo-TestSecureString -Value $plainToken
        $script:notebook = Get-DemoFabricNotebookDefinition -Path $deploymentNotebook
    }

    BeforeEach {
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
    }

    It 'sends nothing and needs no token with -WhatIf' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { throw 'no network calls expected' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-RestMethod -MockWith { throw 'no network calls expected' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -WhatIf
        $result.status | Should -Be 'Not selected'
        $result.checkId | Should -Be 'FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT'
        ($result.evidence.plannedRequests -join ' ') | Should -Match ([regex]::Escape("$api/workspaces/$workspaceId/items"))
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-RestMethod -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
    }

    It 'creates the notebook with Items - Create Item when none has its name' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $otherLakehouseId; displayName = 'Another notebook' }) }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId; type = 'Notebook'; displayName = 'NB_DatabaseHub_Deployment' }) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        $result.status | Should -Be 'Pass'
        $result.evidence.operation | Should -Be 'created'
        $result.evidence.itemId | Should -Be $itemId
        $requests.Count | Should -Be 2
        $requests[0].Method | Should -Be 'Get'
        $requests[0].Uri | Should -BeExactly "$api/workspaces/$workspaceId/items?type=Notebook"
        $requests[1].Method | Should -Be 'Post'
        $requests[1].Uri | Should -BeExactly "$api/workspaces/$workspaceId/items"
        $body = Get-RequestBody -Request $requests[1]
        $body.displayName | Should -Be 'NB_DatabaseHub_Deployment'
        $body.type | Should -Be 'Notebook'
        $body.definition.format | Should -Be 'ipynb'
        @($body.definition.parts).Count | Should -Be 1
        $body.definition.parts[0].path | Should -Be 'notebook-content.ipynb'
        $body.definition.parts[0].payloadType | Should -Be 'InlineBase64'
        [System.Convert]::FromBase64String($body.definition.parts[0].payload) | Should -Be ([System.IO.File]::ReadAllBytes($deploymentNotebook))
    }

    It 'sends the token only as a SecureString bearer token, never in a header or a result' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId }) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        foreach ($request in $requests) {
            $request.Authentication | Should -Be 'Bearer'
            $request.Token | Should -BeOfType ([securestring])
            $request.Headers | Should -BeNullOrEmpty
            $request.Uri | Should -BeLike "$api/*"
        }
        ($result | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($plainToken))
    }

    It 'updates the definition when a notebook with the name exists' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'nb_databasehub_deployment' }) }) }
            @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        $result.status | Should -Be 'Pass'
        $result.evidence.operation | Should -Be 'updated'
        $requests.Count | Should -Be 2
        $requests[1].Uri | Should -BeExactly "$api/workspaces/$workspaceId/items/$itemId/updateDefinition"
        $body = Get-RequestBody -Request $requests[1]
        @($body.PSObject.Properties.Name) | Should -Be @('definition')
        $body.definition.parts[0].path | Should -Be 'notebook-content.ipynb'
        @($requests | Where-Object { $_.Uri -match $createUri }).Count | Should -Be 0
    }

    It 'polls a long-running create with Get Operation State and reads the item from Get Operation Result' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ 'Location' = @("$api/operations/$operationId"); 'x-ms-operation-id' = @($operationId); 'Retry-After' = @('7') }) }
            @{ Method = 'Get'; Match = $operationUri; Responses = @(
                    (New-FabricResponse -Status 200 -Body @{ status = 'Running'; percentComplete = 25 } -Headers @{ 'Retry-After' = @('3') })
                    (New-FabricResponse -Status 200 -Body @{ status = 'Succeeded'; percentComplete = 100 })
                ) 
            }
            @{ Method = 'Get'; Match = $resultUri; Responses = @(New-FabricResponse -Status 200 -Body @{ id = $itemId; type = 'Notebook' }) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        $result.status | Should -Be 'Pass'
        $result.evidence.itemId | Should -Be $itemId
        $result.evidence.operationId | Should -Be $operationId
        @($requests | Where-Object { $_.Uri -match $operationUri }).Count | Should -Be 2
        @($requests | Where-Object { $_.Uri -match $resultUri }).Count | Should -Be 1
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 7 } -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 3 } -Times 1 -Exactly
    }

    It 'polls a long-running update and reports Fail with the operation error' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment' }) }) }
            @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ 'x-ms-operation-id' = @($operationId); 'Retry-After' = @('2') }) }
            @{ Method = 'Get'; Match = $operationUri; Responses = @(New-FabricResponse -Status 200 -Body @{ status = 'Failed'; error = @{ errorCode = 'CorruptedPayload'; message = 'The provided payload is corrupted.' } }) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'CorruptedPayload'
    }

    It 'reports Warning when a long-running operation outlasts -TimeoutSeconds' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ 'x-ms-operation-id' = @($operationId); 'Retry-After' = @('20') }) }
            @{ Method = 'Get'; Match = $operationUri; Responses = @(New-FabricResponse -Status 200 -Body @{ status = 'Running' } -Headers @{ 'Retry-After' = @('20') }) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -TimeoutSeconds 60 -Confirm:$false
        $result.status | Should -Be 'Warning'
        $result.remediation | Should -Match 'again'
        @($requests | Where-Object { $_.Uri -match $operationUri }).Count | Should -Be 3
    }

    It 'reports Fail with the P5 remediation when the workspace denies access' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 403 -Body @{ errorCode = 'InsufficientPrivileges'; message = 'The caller does not have sufficient permissions.'; requestId = $operationId }) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'HTTP 403 InsufficientPrivileges'
        $result.remediation | Should -Match 'P5'
        $requests.Count | Should -Be 1
    }

    It 'reports Manual action required with the resume steps when the workspace capacity is paused' {
        # Live behavior with a paused F capacity: List Items works, Create Item answers HTTP 404 CapacityNotActive.
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 404 -Body @{ errorCode = 'CapacityNotActive'; message = 'Internal error CapacityNotActive.Capacity is not active'; isRetriable = $false; requestId = $operationId }) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        $result.status | Should -Be 'Manual action required'
        $result.message | Should -Match 'HTTP 404 CapacityNotActive'
        $result.remediation | Should -Match 'Resume'
        $result.remediation | Should -Not -Match 'workspaceId'
        $result.docUrl | Should -Be 'https://learn.microsoft.com/fabric/enterprise/pause-resume'
        $result.evidence.httpStatus | Should -Be 404
        $requests.Count | Should -Be 2
    }

    It 'refuses to guess when two notebooks share the name' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment' }, @{ id = $operationId; displayName = 'NB_DatabaseHub_Deployment' }) }) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        $result.status | Should -Be 'Fail'
        @($requests | Where-Object { $_.Method -eq 'Post' }).Count | Should -Be 0
    }

    It 'follows continuation pages when it looks for the notebook, and ignores other item types with the same name' {
        # The documented continuationUri can drop the type filter, so a later page can hold other item types.
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = 'continuationToken=page2'; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(
                            @{ id = $otherLakehouseId; displayName = 'NB_DatabaseHub_Deployment'; type = 'Lakehouse' }
                            @{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment'; type = 'Notebook' }
                        ) 
                    }) 
            }
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(); continuationToken = 'page2'; continuationUri = "$api/workspaces/$workspaceId/items?type=Notebook&continuationToken=page2" }) }
            @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        $result.status | Should -Be 'Pass'
        $result.evidence.operation | Should -Be 'updated'
        @($requests | Where-Object { $_.Method -eq 'Get' }).Count | Should -Be 2
    }

    It 'updates instead when the name was taken between the list and the create' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(
                    (New-FabricResponse -Status 200 -Body @{ value = @() })
                    (New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment' }) })
                ) 
            }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 400 -Body @{ errorCode = 'ItemDisplayNameAlreadyInUse'; message = 'Item display name is already used.' }) }
            @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        $result.status | Should -Be 'Pass'
        $result.evidence.operation | Should -Be 'updated'
    }

    It 'retries after HTTP 429, honoring Retry-After' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(
                    (New-FabricResponse -Status 429 -Body @{ errorCode = 'RequestBlocked'; message = 'Too many requests.' } -Headers @{ 'Retry-After' = @('4') })
                    (New-FabricResponse -Status 200 -Body @{ value = @() })
                ) 
            }
            @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId }) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        $result.status | Should -Be 'Pass'
        Should -Invoke -ModuleName DbHubDemo -CommandName Start-Sleep -ParameterFilter { $Seconds -eq 4 } -Times 1 -Exactly
    }

    It 'never sends the token outside the Fabric API, even when a continuation URI points elsewhere' {
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(); continuationUri = 'https://attacker.example/v1/items' }) }
        )
        $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $notebook -Token $secureToken -Confirm:$false
        $result.status | Should -Be 'Fail'
        $result.message | Should -Match 'Refusing to send the Fabric token'
        @($requests | Where-Object { $_.Uri -notlike "$api/*" }).Count | Should -Be 0
        $token = $secureToken
        { InModuleScope DbHubDemo -Parameters @{ Token = $token } { Invoke-DemoFabricRequest -Method Get -Uri 'https://example.com/v1/workspaces' -Token $Token } } |
            Should -Throw '*Refusing*'
    }

    Context 'with -KeepEdited: deploy.ps1 brings a copy that nobody edited up to date, and keeps an edited one (follow-ups decision 2a, 2026-11-23)' {
        BeforeAll {
            # The live-activity notebook as this run uploads it, bound to the workspace and a lakehouse.
            $script:live = Get-DemoFabricNotebookDefinition -Path $liveNotebook -LakehouseId $otherLakehouseId -LakehouseWorkspaceId $workspaceId
            $script:liveListUri = $listUri
            $script:definitionUri = '^' + [regex]::Escape("$api/workspaces/$workspaceId/items/$itemId/getDefinition?format=ipynb") + '$'
            # Each notebook file's own values in its parameters cell, which published-versions.json lists with each version.
            $script:liveParameters = (InModuleScope DbHubDemo -Parameters @{ Text = [System.IO.File]::ReadAllText($liveNotebook) } { Get-DemoNotebookFingerprint -Text $Text }).Bindings
            $script:deploymentParameters = (InModuleScope DbHubDemo -Parameters @{ Text = [System.IO.File]::ReadAllText($deploymentNotebook) } { Get-DemoNotebookFingerprint -Text $Text }).Bindings
            # A hand edit of GITHUB_REPOSITORY in the parameters cell.
            $script:fork = {
                param($Notebook)
                $parameters = @($Notebook['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]
                $parameters['source'] = $parameters['source'] -replace '(?m)^GITHUB_REPOSITORY = "[^"]*"', 'GITHUB_REPOSITORY = "contoso/my-fork"'
            }
        }

        BeforeEach {
            # The versions this repository published: an earlier one of the live-activity notebook is known to the test,
            # whatever the real file lists, with its file's own parameter values.
            $script:earlier = $null
            $script:earlierParameters = $liveParameters
            Mock -ModuleName DbHubDemo -CommandName Get-DemoNotebookPublishedVersion -MockWith {
                if ($null -ne $earlier) { @([pscustomobject]@{ Sha256 = $earlier; Since = '2026-11-13'; Parameters = $earlierParameters }) } else { @() }
            }
        }

        It 'updates an earlier version of the demo''s that nobody edited, read as ipynb, and says which' {
            $older = New-WorkspaceCopy -Notebook $live -Change $editCode
            $script:earlier = (Get-CopyFingerprint -Response $older).Sha256
            Set-FabricMock -Routes @(
                @{ Method = 'Get'; Match = $liveListUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity' }) }) }
                @{ Method = 'Post'; Match = $definitionUri; Responses = @($older) }
                @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            )
            $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $live -Token $secureToken -KeepEdited -Confirm:$false
            $result.status | Should -Be 'Pass'
            $result.evidence.operation | Should -Be 'updated'
            $result.evidence.notebookState | Should -Be 'Older'
            $result.evidence.publishedSince | Should -Be '2026-11-13'
            $result.message | Should -Match '^Updated notebook ''NB_DatabaseHub_LiveActivity'''
            $result.message | Should -Match 'It was the demo''s version of 2026-11-13, and nobody had edited it\. fabric\.importNotebooks is false, so deploy\.ps1 adds a missing notebook, brings one that nobody edited up to date, and keeps an edited one\.$'
            @($requests | Where-Object { $_.Uri -match $definitionUri }).Count | Should -Be 1
            @($requests | Where-Object { $_.Uri -match $updateUri }).Count | Should -Be 1
        }

        It 'keeps an edited copy, with the command that replaces that notebook alone' {
            Set-FabricMock -Routes @(
                @{ Method = 'Get'; Match = $liveListUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity' }) }) }
                @{ Method = 'Post'; Match = $definitionUri; Responses = @(New-WorkspaceCopy -Notebook $live -Change $editCode) }
            )
            $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $live -Token $secureToken -KeepEdited -Confirm:$false
            $result.status | Should -Be 'Not selected'
            $result.checkId | Should -Be 'FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY'
            $result.evidence.operation | Should -Be 'unchanged'
            $result.evidence.notebookState | Should -Be 'Edited'
            $result.evidence.itemId | Should -Be $itemId
            $result.message | Should -Match '^Kept notebook ''NB_DatabaseHub_LiveActivity'' in Fabric workspace .+ as it is: it isn''t a version the demo published, so someone edited it'
            $result.remediation | Should -Match '^To replace it with this version, which drops the edits, run \./scripts/configure-fabric\.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity: it updates that notebook alone\.'
            @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -notmatch $definitionUri }).Count | Should -Be 0 -Because 'an edited notebook is kept'
        }

        It 'leaves this version as it is, and binds this version to another lakehouse again: <Case>' -ForEach @(
            @{ Case = 'the same values'; Lakehouse = $null; Status = 'Pass'; State = 'Current'; Updates = 0 }
            @{ Case = 'another lakehouse'; Lakehouse = '88888888-8888-8888-8888-888888888888'; Status = 'Pass'; State = 'Rebind'; Updates = 1 }
        ) {
            $other = $Lakehouse
            $copy = New-WorkspaceCopy -Notebook $live -Change {
                param($Notebook)
                if ($other) {
                    $parameters = @($Notebook['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]
                    $parameters['source'] = $parameters['source'] -replace '(?m)^LAKEHOUSE_ID = "[^"]*"', ('LAKEHOUSE_ID = "{0}"' -f $other)
                }
            }
            Set-FabricMock -Routes @(
                @{ Method = 'Get'; Match = $liveListUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity' }) }) }
                @{ Method = 'Post'; Match = $definitionUri; Responses = @($copy) }
                @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            )
            $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $live -Token $secureToken -KeepEdited -Confirm:$false
            $result.status | Should -Be $Status
            $result.evidence.notebookState | Should -Be $State
            @($requests | Where-Object { $_.Uri -match $updateUri }).Count | Should -Be $Updates
            if ($State -eq 'Current') {
                $result.evidence.operation | Should -Be 'unchanged'
                $result.message | Should -Match '^Notebook ''NB_DatabaseHub_LiveActivity'' in Fabric workspace .+ is this version already, so it was left as it is\.'
            }
            else {
                $result.evidence.operation | Should -Be 'updated'
                $result.message | Should -Match 'It was this version, bound to another workspace, lakehouse, or GitHub path than this run''s, and nobody had edited it\.'
            }
        }

        It 'keeps a copy it couldn''t read: <Case>' -ForEach @(
            @{ Case = 'an error, a Warning'; Body = @{ errorCode = 'InternalError'; message = 'Something went wrong.' }; HttpStatus = 500; Status = 'Warning'; Fix = '^The next \./scripts/deploy\.ps1 reads it again\. To update it now, run \./scripts/configure-fabric\.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity, which replaces any edits\.$' }
            @{ Case = 'a paused capacity, Manual action required'; Body = @{ errorCode = 'CapacityNotActive'; message = 'Capacity is not active' }; HttpStatus = 404; Status = 'Manual action required'; Fix = '^Resume the capacity' }
        ) {
            Set-FabricMock -Routes @(
                @{ Method = 'Get'; Match = $liveListUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity' }) }) }
                @{ Method = 'Post'; Match = $definitionUri; Responses = @(New-FabricResponse -Status $HttpStatus -Body $Body) }
            )
            $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $live -Token $secureToken -KeepEdited -Confirm:$false
            $result.status | Should -Be $Status
            $result.evidence.notebookState | Should -Be 'Unread'
            $result.evidence.operation | Should -Be 'unchanged'
            $result.message | Should -Match 'as it is: its definition couldn''t be read'
            $result.remediation | Should -Match $Fix
            @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -notmatch $definitionUri }).Count | Should -Be 0
        }

        It 'creates a missing notebook, and reads nothing' {
            Set-FabricMock -Routes @(
                @{ Method = 'Get'; Match = $liveListUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @() }) }
                @{ Method = 'Post'; Match = $createUri; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId }) }
            )
            $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $live -Token $secureToken -KeepEdited -Confirm:$false
            $result.status | Should -Be 'Pass'
            $result.evidence.operation | Should -Be 'created'
            $result.evidence.notebookState | Should -Be 'Missing'
            $result.message | Should -Match '^Created notebook'
            @($requests | Where-Object { $_.Uri -like '*getDefinition*' }).Count | Should -Be 0
        }

        It 'sends nothing with -WhatIf, and says it reads a notebook that''s there first' {
            Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { throw 'no network calls expected' }
            $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $live -KeepEdited -WhatIf
            $result.status | Should -Be 'Not selected'
            $result.message | Should -Match 'It reads one that''s there first \(POST .+/getDefinition\?format=ipynb\)\.$'
            Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 0 -Exactly
        }

        It 'keeps <Case> whose GITHUB_REPOSITORY someone edited, which the import doesn''t set while github.repository is the example''s placeholder (the review of 42acec35)' -ForEach @(
            @{ Case = 'this version'; Earlier = $false }
            @{ Case = 'an earlier version'; Earlier = $true }
        ) {
            # With the placeholder, the import binds the lakehouse alone, and GITHUB_REPOSITORY keeps the file's value.
            $deployment = Get-DemoFabricNotebookDefinition -Path $deploymentNotebook -LakehouseId $otherLakehouseId -LakehouseWorkspaceId $workspaceId
            @($deployment.BoundKeys) | Should -Be @('WORKSPACE_ID', 'LAKEHOUSE_ID', 'LAKEHOUSE_NAME')
            $useEarlier = $Earlier
            $copy = New-WorkspaceCopy -Notebook $deployment -Change {
                param($Notebook)
                if ($useEarlier) {
                    & $editCode $Notebook
                }
                & $fork $Notebook
            }
            if ($Earlier) {
                $script:earlier = (Get-CopyFingerprint -Response $copy).Sha256
                $script:earlierParameters = $deploymentParameters
            }
            Set-FabricMock -Routes @(
                @{ Method = 'Get'; Match = $liveListUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment' }) }) }
                @{ Method = 'Post'; Match = $definitionUri; Responses = @($copy) }
                @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            )
            $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $deployment -Token $secureToken -KeepEdited -Confirm:$false
            $result.status | Should -Be 'Not selected'
            $result.checkId | Should -Be 'FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT'
            $result.evidence.notebookState | Should -Be 'Edited'
            @($result.evidence.editedParameters) | Should -Be @('GITHUB_REPOSITORY')
            $result.message | Should -Match '^Kept notebook ''NB_DatabaseHub_Deployment'' in Fabric workspace .+ as it is: its GITHUB_REPOSITORY isn''t the value the demo publishes there, and this run doesn''t set it, so it counts as an edit\. fabric\.importNotebooks is false'
            $result.remediation | Should -Match '^To replace it with this version, which drops the edits, run \./scripts/configure-fabric\.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_Deployment'
            @($requests | Where-Object { $_.Uri -match $updateUri }).Count | Should -Be 0 -Because 'an edited notebook is kept'
        }

        It 'binds GITHUB_REPOSITORY again when the import sets it, from a github.repository of the configuration''s own' {
            $deployment = Get-DemoFabricNotebookDefinition -Path $deploymentNotebook -LakehouseId $otherLakehouseId -LakehouseWorkspaceId $workspaceId -GitHubRepository 'contoso/fork'
            @($deployment.BoundKeys) | Should -Contain 'GITHUB_REPOSITORY'
            $copy = New-WorkspaceCopy -Notebook $deployment -Change $fork
            Set-FabricMock -Routes @(
                @{ Method = 'Get'; Match = $liveListUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment' }) }) }
                @{ Method = 'Post'; Match = $definitionUri; Responses = @($copy) }
                @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            )
            $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $deployment -Token $secureToken -KeepEdited -Confirm:$false
            $result.status | Should -Be 'Pass'
            $result.evidence.notebookState | Should -Be 'Rebind'
            @($requests | Where-Object { $_.Uri -match $updateUri }).Count | Should -Be 1
        }
    }

    Context 'with -KeepEdited and the list of versions as deploy.ps1 reads it (the review of 42acec35)' {
        BeforeAll {
            $script:live = Get-DemoFabricNotebookDefinition -Path $liveNotebook -LakehouseId $otherLakehouseId -LakehouseWorkspaceId $workspaceId
            $script:definitionUri = '^' + [regex]::Escape("$api/workspaces/$workspaceId/items/$itemId/getDefinition?format=ipynb") + '$'
            $script:savedVersionsPath = InModuleScope DbHubDemo { $script:FabricNotebookVersionsPath }
            $script:versionsFile = Join-Path -Path $TestDrive -ChildPath 'published-versions.json'
            InModuleScope DbHubDemo -Parameters @{ Path = $versionsFile } { $script:FabricNotebookVersionsPath = $Path }
            # A live-activity version from before 2026-11-14, whose parameters cell still had the GitHub path that this
            # version doesn't (ADR 0026), with a code change.
            $script:before14 = {
                param($Notebook)
                & $editCode $Notebook
                $parameters = @($Notebook['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]
                $parameters['source'] = $parameters['source'] + 'GITHUB_REPOSITORY = "MarcBushong/fabric-database-hub-demo"' + "`r`n" + 'GITHUB_ENVIRONMENT = "demo"' + "`r`n"
            }
        }

        AfterAll {
            InModuleScope DbHubDemo -Parameters @{ Path = $savedVersionsPath } { $script:FabricNotebookVersionsPath = $Path }
        }

        It 'updates an earlier version that nobody edited, whose file had parameters this version doesn''t, and keeps one whose GITHUB_REPOSITORY someone edited' {
            $older = New-WorkspaceCopy -Notebook $live -Change $before14
            $document = [ordered]@{ notebooks = [ordered]@{ NB_DatabaseHub_LiveActivity = @([ordered]@{
                            sha256     = (Get-CopyFingerprint -Response $older).Sha256
                            since      = '2026-11-10'
                            parameters = [ordered]@{ WORKSPACE_ID = ''; LAKEHOUSE_ID = ''; LAKEHOUSE_NAME = 'LH_DatabaseHub'; GITHUB_REPOSITORY = 'MarcBushong/fabric-database-hub-demo'; GITHUB_ENVIRONMENT = 'demo' }
                        }) }
            }
            [System.IO.File]::WriteAllText($versionsFile, (ConvertTo-Json -InputObject $document -Depth 6))
            Set-FabricMock -Routes @(
                @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity' }) }) }
                @{ Method = 'Post'; Match = $definitionUri; Responses = @($older) }
                @{ Method = 'Post'; Match = $updateUri; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            )
            $result = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $live -Token $secureToken -KeepEdited -Confirm:$false
            $result.status | Should -Be 'Pass'
            $result.evidence.notebookState | Should -Be 'Older'
            $result.evidence.publishedSince | Should -Be '2026-11-10'
            @($requests | Where-Object { $_.Uri -match $updateUri }).Count | Should -Be 1

            # The same version, with its GITHUB_REPOSITORY edited by hand, is kept.
            $forked = New-WorkspaceCopy -Notebook $live -Change {
                param($Notebook)
                & $before14 $Notebook
                $parameters = @($Notebook['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]
                $parameters['source'] = $parameters['source'] -replace '(?m)^GITHUB_REPOSITORY = "[^"]*"', 'GITHUB_REPOSITORY = "contoso/my-fork"'
            }
            Set-FabricMock -Routes @(
                @{ Method = 'Get'; Match = $listUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity' }) }) }
                @{ Method = 'Post'; Match = $definitionUri; Responses = @($forked) }
            )
            $kept = Import-DemoFabricNotebook -WorkspaceId $workspaceId -Notebook $live -Token $secureToken -KeepEdited -Confirm:$false
            $kept.status | Should -Be 'Not selected'
            $kept.evidence.notebookState | Should -Be 'Edited'
            @($kept.evidence.editedParameters) | Should -Be @('GITHUB_REPOSITORY')
            @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -notmatch $definitionUri }).Count | Should -Be 0
        }
    }
}

Describe 'configure-fabric.ps1' {
    BeforeAll {
        $config = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json') -Raw | ConvertFrom-Json -AsHashtable
        $config['subscriptionId'] = $subscriptionId
        $config['tenantId'] = $tenantId
        $config.Remove('$schema')
        # Names only, as the example has them (ADR 0021): the workspace and the lakehouse are resolved by name.
        $script:configPath = Join-Path -Path $TestDrive -ChildPath 'demo.config.json'
        Set-Content -LiteralPath $configPath -Value ($config | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        # With the ID overrides, step 0 sends nothing, so these tests cover the import alone.
        $config['fabric']['workspaceId'] = $workspaceId
        $config['fabric']['lakehouseId'] = $otherLakehouseId
        $script:idConfigPath = Join-Path -Path $TestDrive -ChildPath 'demo.ids.config.json'
        Set-Content -LiteralPath $idConfigPath -Value ($config | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        $script:outputPath = Join-Path -Path $TestDrive -ChildPath 'configure-fabric.jsonl'

        function Read-ImportResult {
            @(Get-Content -LiteralPath $outputPath | ConvertFrom-Json | Where-Object { $_.checkId -notlike 'FABRIC.RESOLVE.*' })
        }
    }

    BeforeEach {
        Clear-DemoSecret
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith {}
    }

    It 'makes no Azure CLI, Fabric, or other web call with -WhatIf' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith { throw 'no network calls expected' }
        Mock -ModuleName DbHubDemo -CommandName Invoke-RestMethod -MockWith { throw 'no network calls expected' }
        Mock -CommandName Invoke-WebRequest -MockWith { throw 'no network calls expected' }
        Mock -CommandName Invoke-RestMethod -MockWith { throw 'no network calls expected' }
        $null = & $configureFabric -ConfigPath $configPath -OutputPath $outputPath -SkipHubChecks -WhatIf *>&1
        $LASTEXITCODE | Should -Be 0
        $results = @(Get-Content -LiteralPath $outputPath | ConvertFrom-Json)
        # Without a token, the dry run names what it would look up, and imports nothing until the workspace is resolved.
        $results.checkId | Should -Be @('FABRIC.RESOLVE.WORKSPACE', 'FABRIC.RESOLVE.LAKEHOUSE', 'FABRIC.NOTEBOOKS.IMPORT')
        $results.status | Should -Be @('Not selected', 'Not selected', 'Not selected')
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-RestMethod -Times 0 -Exactly
        Should -Invoke -CommandName Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke -CommandName Invoke-RestMethod -Times 0 -Exactly
    }

    It 'imports both notebooks with a token the operator passes, without the Azure CLI' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment' }, @{ id = $operationId; displayName = 'NB_DatabaseHub_LiveActivity' }) }) }
            @{ Method = 'Post'; Match = '/updateDefinition$'; Responses = @(New-FabricResponse -Status 200 -Body $null) }
        )
        $output = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $results = Read-ImportResult
        $results.checkId | Should -Be @('FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT', 'FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY')
        $results.status | Should -Be @('Pass', 'Pass')
        @($requests | Where-Object { $_.Method -eq 'Post' }).Count | Should -Be 2
        $output | Should -Not -Match ([regex]::Escape($plainToken))
    }

    It 'runs the updated live-activity notebook once when the lakehouse doesn''t have the Incident RCA''s tables yet, and only then (2026-11-20)' {
        # An environment from the release before the Incident RCA: deploy.ps1 updates its notebooks, and the history model
        # that follows reads eight tables its lakehouse doesn't have until the updated notebook runs.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoStorageToken -MockWith { [securestring]::new() }
        $script:lakeTables = @('incident_windows', 'telemetry_snapshots', 'validation_results', 'analysis_findings', 'scenario_runs')
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoOneLakeRequest -MockWith {
            if ($Method -ne 'Get' -or $Query -notlike 'resource=filesystem&recursive=false&directory=*Tables%2Fdbo*') {
                throw ('unexpected OneLake request: {0} {1} {2}' -f $Method, $Path, $Query)
            }
            # Unqualified, as Set-FabricMock's: the mock runs inside configure-fabric.ps1, whose script scope isn't this file's.
            if ($null -eq $lakeTables) {
                return [pscustomobject]@{ StatusCode = 403; Headers = @{}; Content = '{"error":{"code":"Forbidden","message":"no access"}}' }
            }
            $paths = @($lakeTables | ForEach-Object { @{ name = ('lakehouse/Tables/dbo/{0}' -f $_); isDirectory = 'true' } })
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = (ConvertTo-Json -InputObject @{ paths = $paths } -Depth 5 -Compress) }
        }
        $fabricRoutes = @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment' }, @{ id = $operationId; displayName = 'NB_DatabaseHub_LiveActivity' }) }) }
            @{ Method = 'Post'; Match = '/updateDefinition$'; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            @{ Method = 'Get'; Match = '/jobs/instances/'; Responses = @(New-FabricResponse -Status 200 -Body @{ status = 'Completed' }) }
            @{ Method = 'Post'; Match = [regex]::Escape('/jobs/instances?jobType=RunNotebook'); Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ Location = "$api/workspaces/$workspaceId/items/$operationId/jobs/instances/$operationId" }) }
        )
        Set-FabricMock -Routes $fabricRoutes
        $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        $results = Read-ImportResult
        $results.checkId | Should -Be @('FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT', 'FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY', 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY')
        $results.status | Should -Be @('Pass', 'Pass', 'Pass')
        $run = @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like '*jobType=RunNotebook' })
        $run.Count | Should -Be 1
        $sent = (Get-RequestBody -Request $run[0]).executionData.parameters
        $sent.SAVE_RESULTS.value | Should -Be 'true'
        $sent.PSObject.Properties.Name | Should -Not -Contain 'RCA_EVIDENCE_FILE' -Because 'a run that creates the tables takes no evidence'

        # The lakehouse has them already, or its tables can't be listed: nothing more runs (the model's step leaves out what
        # it can't read, FABRIC.SEMANTICMODEL.RCA).
        foreach ($tables in @(@($script:lakeTables + @(InModuleScope DbHubDemo { Get-DemoRcaHistoryTable } | ForEach-Object Name)), $null)) {
            $script:lakeTables = $tables
            Set-FabricMock -Routes $fabricRoutes
            $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
            $LASTEXITCODE | Should -Be 0
            (Read-ImportResult).checkId | Should -Be @('FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT', 'FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY')
            @($requests | Where-Object { $_.Uri -like '*jobType=RunNotebook' }).Count | Should -Be 0
        }
    }

    It 'points the uploaded deployment notebook at github.repository, but not at the example''s placeholder, and adds no GitHub parameter to the live-activity notebook' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        $gitHubConfig = Get-Content -LiteralPath $idConfigPath -Raw | ConvertFrom-Json -AsHashtable
        $gitHubConfig['github'] = [ordered]@{ repository = 'contoso/dbhub-fork'; environment = 'demo-fork' }
        $gitHubConfigPath = Join-Path -Path $TestDrive -ChildPath 'demo.github.config.json'
        Set-Content -LiteralPath $gitHubConfigPath -Value ($gitHubConfig | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        $default = [regex]::Match([System.IO.File]::ReadAllText($deploymentNotebook), 'GITHUB_REPOSITORY = \\"([^\\"]+)\\"').Groups[1].Value
        $default | Should -Not -BeNullOrEmpty
        # The ID configuration is the example's, so its github.repository is the placeholder and the default stays.
        foreach ($case in @(
                @{ Path = $gitHubConfigPath; Repository = 'contoso/dbhub-fork' }
                @{ Path = $idConfigPath; Repository = $default }
            )) {
            Set-FabricMock -Routes @(
                @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment' }, @{ id = $operationId; displayName = 'NB_DatabaseHub_LiveActivity' }) }) }
                @{ Method = 'Post'; Match = '/updateDefinition$'; Responses = @(New-FabricResponse -Status 200 -Body $null) }
            )
            $null = & $configureFabric -ConfigPath $case.Path -OutputPath $outputPath -SkipHubChecks -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
            $LASTEXITCODE | Should -Be 0
            $updates = @($requests | Where-Object { $_.Uri -like '*/updateDefinition' })
            $updates.Count | Should -Be 2
            foreach ($update in $updates) {
                $uploaded = ConvertFrom-TestPayload -Payload (Get-RequestBody -Request $update).definition.parts[0].payload | ConvertFrom-Json -AsHashtable -Depth 64
                $parameters = (@($uploaded['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]['source']) -join ''
                if ($update.Uri -like "*/items/$operationId/updateDefinition") {
                    # The live-activity notebook has no GitHub path since 2026-11-14 (ADR 0026).
                    $parameters | Should -Not -Match 'GITHUB_'
                }
                else {
                    $parameters | Should -Match ('(?m)^GITHUB_REPOSITORY = "{0}"$' -f [regex]::Escape($case.Repository))
                }
            }
        }
    }

    It 'uses the subscription guard and a verified Azure CLI Fabric token when no token is passed' {
        $script:azCalls = [System.Collections.Generic.List[string]]::new()
        $script:canaryTokenForTest = Get-GuardTestToken -TenantId $tenantId
        $script:importTokenForTest = Get-GuardTestToken -TenantId $tenantId
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $joined = $ArgumentList -join ' '
            $azCalls.Add($joined)
            $out = switch -Regex ($joined) {
                '^account show' { '{"id":"' + $subscriptionId + '","tenantId":"' + $tenantId + '","user":{"name":"you@example.com","type":"user"}}' }
                '^group list' { '[]' }
                '^rest --method get --url https://management\.azure\.com/subscriptions/' { '{"subscriptionId":"' + $subscriptionId + '","tenantId":"' + $tenantId + '"}' }
                '^account get-access-token --resource https://api\.fabric\.microsoft\.com' { '{"accessToken":"' + $importTokenForTest + '"}'; break }
                '^account get-access-token' { '{"accessToken":"' + $canaryTokenForTest + '"}' }
                default { throw "Unexpected az call: $joined" }
            }
            [pscustomobject]@{ ExitCode = 0; StdOut = $out; StdErr = '' }
        }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRestRequest -MockWith {
            [pscustomobject]@{ ExitCode = 0; StdOut = ('{"value":[{"id":"' + $tenantId + '"}]}'); StdErr = ''; StatusCode = 200 }
        }
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity' }) }) }
            @{ Method = 'Post'; Match = '/updateDefinition$'; Responses = @(New-FabricResponse -Status 200 -Body $null) }
        )
        $output = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity -Confirm:$false *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        (Read-ImportResult).status | Should -Be 'Pass'
        $azCalls[0] | Should -Match '^account show'
        @($azCalls | Where-Object { $_ -match '--tenant' }) | Should -BeNullOrEmpty
        @($azCalls | Where-Object { $_ -notmatch "--subscription $subscriptionId" }) | Should -BeNullOrEmpty
        # The import's Fabric token; after it, for an update, at most a Storage token for the lakehouse's table list
        # (2026-11-20, ADR 0031: the notebook runs once when the lakehouse lacks a table the history model reads).
        $fabricCall = "account get-access-token --resource https://api.fabric.microsoft.com --output json --subscription $subscriptionId"
        $azCalls | Should -Contain $fabricCall
        @($azCalls[($azCalls.LastIndexOf($fabricCall) + 1)..($azCalls.Count - 1)] | Where-Object { $_ -and $_ -ne $fabricCall -and $_ -ne "account get-access-token --resource https://storage.azure.com/ --output json --subscription $subscriptionId" }) | Should -BeNullOrEmpty
        $update = @($requests | Where-Object { $_.Uri -like '*/updateDefinition' })
        [System.Net.NetworkCredential]::new('', $update[0].Token).Password | Should -BeExactly $importTokenForTest
        $output | Should -Not -Match ([regex]::Escape($importTokenForTest))
        $output | Should -Not -Match ([regex]::Escape($canaryTokenForTest))
    }

    It 'exits 1 when an import fails' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 404 -Body @{ errorCode = 'WorkspaceNotFound'; message = 'The requested workspace was not found.' }) }
        )
        $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -Notebook NB_DatabaseHub_Deployment -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 1
        $result = Read-ImportResult
        $result.status | Should -Be 'Fail'
        $result.remediation | Should -Match 'fabric.workspaceId'
    }

    It 'with names only, finds the workspace and lakehouse, binds the new notebooks to them, and runs the live-activity notebook with their IDs (ADR 0021)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        $lakehouseUri = '^' + [regex]::Escape("$api/workspaces/$workspaceId/lakehouses") + '$'
        $jobUri = "$api/workspaces/$workspaceId/items/$itemId/jobs/instances/$operationId"
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = ('^' + [regex]::Escape("$api/workspaces") + '$'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(
                            @{ id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; displayName = 'My workspace'; type = 'Personal' }
                            @{ id = $workspaceId; displayName = 'Database Hub Demo'; type = 'Workspace'; capacityId = 'cccccccc-cccc-cccc-cccc-cccccccccccc' }
                        ) }) }
            @{ Method = 'Get'; Match = $lakehouseUri; Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $otherLakehouseId; displayName = 'LH_DatabaseHub'; type = 'Lakehouse' }) }) }
            # Both notebooks are missing; the run then finds the live-activity notebook that the import created.
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(
                    New-FabricResponse -Status 200 -Body @{ value = @() }
                    New-FabricResponse -Status 200 -Body @{ value = @() }
                    New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity'; type = 'Notebook' }) }
                ) }
            @{ Method = 'Get'; Match = ('^' + [regex]::Escape($jobUri) + '$'); Responses = @(New-FabricResponse -Status 200 -Body @{ status = 'Completed'; startTimeUtc = '2026-10-27T15:00:00Z'; endTimeUtc = '2026-10-27T15:02:00Z' }) }
            @{ Method = 'Post'; Match = [regex]::Escape('/jobs/instances?jobType=RunNotebook'); Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ Location = $jobUri }) }
            @{ Method = 'Post'; Match = '/items$'; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId }) }
        )
        $null = & $configureFabric -ConfigPath $configPath -OutputPath $outputPath -SkipHubChecks -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        $results = @(Get-Content -LiteralPath $outputPath | ConvertFrom-Json)
        $results.checkId | Should -Be @('FABRIC.RESOLVE.WORKSPACE', 'FABRIC.RESOLVE.LAKEHOUSE', 'FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT', 'FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY', 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY')
        $results.status | Should -Be @('Pass', 'Pass', 'Pass', 'Pass', 'Pass')
        ($results | Where-Object checkId -EQ 'FABRIC.RESOLVE.WORKSPACE').message | Should -Not -Match $workspaceId

        $creates = @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like '*/items' })
        $creates.Count | Should -Be 2
        foreach ($create in $creates) {
            $uploaded = ConvertFrom-TestPayload -Payload (Get-RequestBody -Request $create).definition.parts[0].payload | ConvertFrom-Json -AsHashtable -Depth 64
            $binding = $uploaded.metadata.dependencies.lakehouse
            $binding.default_lakehouse | Should -Be $otherLakehouseId
            $binding.default_lakehouse_workspace_id | Should -Be $workspaceId
            $binding.default_lakehouse_name | Should -Be 'LH_DatabaseHub'
            @($binding.known_lakehouses)[0].id | Should -Be $otherLakehouseId
            $parameters = (@($uploaded['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]['source']) -join ''
            $parameters | Should -Match ('(?m)^WORKSPACE_ID = "{0}"$' -f $workspaceId)
            $parameters | Should -Match ('(?m)^LAKEHOUSE_ID = "{0}"$' -f $otherLakehouseId)
        }

        $run = @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like '*jobType=RunNotebook' })
        $run.Count | Should -Be 1
        $sent = (Get-RequestBody -Request $run[0]).executionData.parameters
        $sent.WORKSPACE_ID.value | Should -Be $workspaceId
        $sent.LAKEHOUSE_ID.value | Should -Be $otherLakehouseId
        $sent.SAVE_RESULTS.value | Should -Be 'true'
        @($requests | Where-Object { $_.Uri -notlike "$api/*" }).Count | Should -Be 0
    }

    It 'with -NewNotebooksOnly, creates a missing notebook and leaves one that exists as it is, saying why' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(
                    New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment'; type = 'Notebook' }) }
                    New-FabricResponse -Status 200 -Body @{ value = @() }
                    New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity'; type = 'Notebook' }) }
                ) }
            @{ Method = 'Get'; Match = '/jobs/instances/'; Responses = @(New-FabricResponse -Status 200 -Body @{ status = 'Completed' }) }
            @{ Method = 'Post'; Match = [regex]::Escape('/jobs/instances?jobType=RunNotebook'); Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ Location = "$api/workspaces/$workspaceId/items/$itemId/jobs/instances/$operationId" }) }
            @{ Method = 'Post'; Match = '/items$'; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId }) }
        )
        $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -NewNotebooksOnly -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        $results = Read-ImportResult
        $deployment = $results | Where-Object checkId -EQ 'FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT'
        $live = $results | Where-Object checkId -EQ 'FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY'
        $deployment.status | Should -Be 'Not selected'
        $deployment.message | Should -Match 'already there, so it was left as it is'
        $deployment.message | Should -Match 'Only a missing notebook is imported \(-NewNotebooksOnly\): \./scripts/configure-fabric\.ps1 without it updates one that exists\.$'
        $live.status | Should -Be 'Pass'
        $live.message | Should -Match '^Created'
        $live.message | Should -Match 'Only a missing notebook is imported \(-NewNotebooksOnly\)'
        @($requests | Where-Object { $_.Uri -like '*/updateDefinition' }).Count | Should -Be 0
        # A newly created live-activity notebook runs once, so the lakehouse gets the history tables.
        ($results | Where-Object checkId -EQ 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY').status | Should -Be 'Pass'
    }

    It 'with -KeepEditedNotebooks, as deploy.ps1 runs it while fabric.importNotebooks is false, updates a notebook nobody edited and keeps an edited one (follow-ups decision 2a)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        # The copies this run's configuration binds: the ID overrides, and the example's placeholder repository, which stays.
        $binding = @{ LakehouseId = $otherLakehouseId; LakehouseName = 'LH_DatabaseHub'; LakehouseWorkspaceId = $workspaceId }
        $deployment = Get-DemoFabricNotebookDefinition -Path $deploymentNotebook @binding
        $live = Get-DemoFabricNotebookDefinition -Path $liveNotebook @binding
        # The deployment notebook is an earlier version of the demo's; the live-activity notebook was edited in Fabric.
        $olderDeployment = New-WorkspaceCopy -Notebook $deployment -Change $editCode
        $script:earlierDeployment = (Get-CopyFingerprint -Response $olderDeployment).Sha256
        # With the file's own parameter values, as published-versions.json lists them: GITHUB_REPOSITORY, which the example
        # configuration's placeholder leaves unbound, is the file's (the review of 42acec35).
        $script:deploymentFileParameters = (InModuleScope DbHubDemo -Parameters @{ Text = [System.IO.File]::ReadAllText($deploymentNotebook) } { Get-DemoNotebookFingerprint -Text $Text }).Bindings
        Mock -ModuleName DbHubDemo -CommandName Get-DemoNotebookPublishedVersion -MockWith {
            if ($Name -eq 'NB_DatabaseHub_Deployment') { @([pscustomobject]@{ Sha256 = $earlierDeployment; Since = '2026-11-03'; Parameters = $deploymentFileParameters }) } else { @() }
        }
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment' }, @{ id = $operationId; displayName = 'NB_DatabaseHub_LiveActivity' }) }) }
            @{ Method = 'Post'; Match = [regex]::Escape("/items/$itemId/getDefinition?format=ipynb"); Responses = @($olderDeployment) }
            @{ Method = 'Post'; Match = [regex]::Escape("/items/$operationId/getDefinition?format=ipynb"); Responses = @(New-WorkspaceCopy -Notebook $live -Change $editCode) }
            @{ Method = 'Post'; Match = '/updateDefinition$'; Responses = @(New-FabricResponse -Status 200 -Body $null) }
        )
        $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -KeepEditedNotebooks -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        $results = Read-ImportResult
        $results.checkId | Should -Be @('FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT', 'FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY')
        $updated = $results | Where-Object checkId -EQ 'FABRIC.IMPORT.NB_DATABASEHUB_DEPLOYMENT'
        $kept = $results | Where-Object checkId -EQ 'FABRIC.IMPORT.NB_DATABASEHUB_LIVEACTIVITY'
        $updated.status | Should -Be 'Pass'
        $updated.evidence.notebookState | Should -Be 'Older'
        $updated.message | Should -Match 'It was the demo''s version of 2026-11-03, and nobody had edited it\.'
        $kept.status | Should -Be 'Not selected'
        $kept.evidence.notebookState | Should -Be 'Edited'
        $kept.remediation | Should -Match '-Notebook NB_DatabaseHub_LiveActivity'
        $updates = @($requests | Where-Object { $_.Uri -like '*/updateDefinition' })
        $updates.Count | Should -Be 1
        $updates[0].Uri | Should -BeLike "*/items/$itemId/updateDefinition"
        # The kept notebook wasn't created or bound again, so it doesn't run.
        @($requests | Where-Object { $_.Uri -like '*jobType=RunNotebook*' }).Count | Should -Be 0
    }

    It 'refuses -NewNotebooksOnly and -KeepEditedNotebooks together' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        { & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -NewNotebooksOnly -KeepEditedNotebooks -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1 } | Should -Throw '*not both*'
    }

    It 'waits up to -HistoryRunWaitMinutes for the first history run, which a busy capacity keeps queued for more than 10 minutes, on the status page (#68)' {
        # Live (2026-11-19, a shared F4): the first history run stayed queued for about 15 minutes, past the 10 minutes it was
        # waited for, and the first deployment ended NOT DONE.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        $queued = @(foreach ($i in 1..40) { New-FabricResponse -Status 200 -Body @{ status = 'NotStarted'; startTimeUtc = '2026-11-19T02:02:45Z' } })
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(
                    New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_Deployment'; type = 'Notebook' }) }
                    New-FabricResponse -Status 200 -Body @{ value = @() }
                    New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity'; type = 'Notebook' }) }
                ) }
            @{ Method = 'Get'; Match = '/jobs/instances/'; Responses = @($queued + @(New-FabricResponse -Status 200 -Body @{ status = 'Completed'; startTimeUtc = '2026-11-19T02:02:45Z'; endTimeUtc = '2026-11-19T02:19:23Z' })) }
            @{ Method = 'Post'; Match = [regex]::Escape('/jobs/instances?jobType=RunNotebook'); Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ Location = "$api/workspaces/$workspaceId/items/$itemId/jobs/instances/$operationId" }) }
            @{ Method = 'Post'; Match = '/items$'; Responses = @(New-FabricResponse -Status 201 -Body @{ id = $itemId }) }
        )
        # The wait's clock: each poll's sleep moves it (Set-FabricMock's own Start-Sleep doesn't). Unqualified in the mocks,
        # as Set-FabricMock's are.
        $script:clock = [pscustomobject]@{ Now = [datetime]::new(2026, 11, 19, 2, 2, 45, [System.DateTimeKind]::Utc) }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoUtcNow -MockWith { $clock.Now }
        Mock -ModuleName DbHubDemo -CommandName Start-Sleep -MockWith { $clock.Now = $clock.Now.AddSeconds([int]$PesterBoundParameters['Seconds']) }
        Mock -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -MockWith { }
        $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -NewNotebooksOnly -ProgressPath (Join-Path -Path $TestDrive -ChildPath 'deploy-progress.json') -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        $run = Read-ImportResult | Where-Object checkId -EQ 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY'
        $run.status | Should -Be 'Pass'
        $run.evidence.queuedSeconds | Should -BeGreaterThan 600
        $run.message | Should -Match 'waited about 14 minutes in the capacity''s queue'
        Should -Invoke -ModuleName DbHubDemo -CommandName Set-DemoProgressStep -ParameterFilter { $Id -eq 'Fabric.Items' -and $Message -eq 'NB_DatabaseHub_LiveActivity is queued on the capacity (13 of at most 45 minutes). It''s the first history run: the history model refreshes once it has run.' }
    }

    It 'scopes -RunLiveActivity to the configured resource group, analyze-only (live finding, 2026-11-06)' {
        # Live: a clean deploy in rg-dbhublt-demo, then -RunLiveActivity without RESOURCE_GROUP, which left the notebook on
        # its default, rg-dbhub-demo: its queries found nothing, so it saved no telemetry snapshots.
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        $otherConfig = Get-Content -LiteralPath $idConfigPath -Raw | ConvertFrom-Json -AsHashtable
        $otherConfig['prefix'] = 'dbhublt'
        $otherConfigPath = Join-Path -Path $TestDrive -ChildPath 'demo.dbhublt.config.json'
        Set-Content -LiteralPath $otherConfigPath -Value ($otherConfig | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity'; type = 'Notebook' }) }) }
            @{ Method = 'Get'; Match = '/jobs/instances/'; Responses = @(New-FabricResponse -Status 200 -Body @{ status = 'Completed' }) }
            @{ Method = 'Post'; Match = [regex]::Escape('/jobs/instances?jobType=RunNotebook'); Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ Location = "$api/workspaces/$workspaceId/items/$itemId/jobs/instances/$operationId" }) }
        )
        $null = & $configureFabric -ConfigPath $otherConfigPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -RunLiveActivity -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        (Read-ImportResult | Where-Object checkId -EQ 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY').status | Should -Be 'Pass'
        $run = @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like '*jobType=RunNotebook' })
        $run.Count | Should -Be 1
        $sent = (Get-RequestBody -Request $run[0]).executionData.parameters
        $sent.RESOURCE_GROUP.value | Should -Be 'rg-dbhublt-demo' -Because 'the notebook''s queries are scoped to it'
        $sent.CONFIRM.value | Should -Be 'false' -Because 'Run all would otherwise send an activity request'
        $sent.STOP_ACTIVITY.value | Should -Be 'false'
        $sent.SAVE_RESULTS.value | Should -Be 'true'
        $sent.PSObject.Properties.Name | Should -Not -Contain 'POSTGRES_METRICS' -Because 'with -FabricToken no subscription guard runs, so Azure Monitor isn''t read'
        $sent.PSObject.Properties.Name | Should -Not -Contain 'RCA_EVIDENCE_FILE' -Because 'nor are the VMs'' Run Commands'
    }

    It 'with -RunLiveActivity and the Azure CLI''s sign-in, exports the Incident RCA''s evidence and stages it as RCA_EVIDENCE_FILE (2026-11-20)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        Mock -CommandName Assert-DemoAzContext -MockWith { New-DemoResult -CheckId 'PREFLIGHT.GUARD.CONTEXT' -Area 'preflight' -Target 'subscription' -Status 'Pass' -Message 'ok' }
        Mock -CommandName Get-DemoFabricToken -MockWith { [securestring]::new() }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoPostgresHistoryCapture -MockWith { $null }
        Mock -ModuleName DbHubDemo -CommandName Get-DemoCosmosHistoryCapture -MockWith { $null }
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricNotebookParameter -MockWith { [pscustomobject]@{ Known = $true; Has = $true; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRcaScriptExport -MockWith {
            [pscustomobject]@{ Evidence = '{"kind":"ContosoCare.RcaEvidenceParts","version":1,"sessionId":null,"parts":["x"]}'; Documents = @([ordered]@{ documentId = 'd'; vm = 'sqlvm01' }); Pending = @(); PendingFound = $false; Results = @(New-DemoResult -CheckId 'FABRIC.RCA.EXPORT' -Area 'workload' -Target 'subscription' -Status 'Pass' -Message '1 RCA evidence document(s), 1 part(s), for the history run.') }
        }
        Mock -ModuleName DbHubDemo -CommandName Send-DemoRcaEvidenceFile -MockWith { [pscustomobject]@{ Path = 'Files/rca/inbox/20261120T173000Z-script-1a2b3c4d.json'; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Remove-DemoRcaEvidenceFile -MockWith { [pscustomobject]@{ Deleted = $true; Found = $false } }
        Mock -ModuleName DbHubDemo -CommandName Save-DemoRcaPending -MockWith { $null }
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity'; type = 'Notebook' }) }) }
            @{ Method = 'Get'; Match = '/jobs/instances/'; Responses = @(New-FabricResponse -Status 200 -Body @{ status = 'Completed' }) }
            @{ Method = 'Post'; Match = [regex]::Escape('/jobs/instances?jobType=RunNotebook'); Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ Location = "$api/workspaces/$workspaceId/items/$itemId/jobs/instances/$operationId" }) }
        )
        $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -RunLiveActivity -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        $results = Read-ImportResult
        ($results | Where-Object checkId -EQ 'FABRIC.RCA.EXPORT').status | Should -Be 'Pass'
        ($results | Where-Object checkId -EQ 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY').status | Should -Be 'Pass'
        $run = @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like '*jobType=RunNotebook' })
        $run.Count | Should -Be 1
        (Get-RequestBody -Request $run[0]).executionData.parameters.RCA_EVIDENCE_FILE.value | Should -Be 'Files/rca/inbox/20261120T173000Z-script-1a2b3c4d.json'
        Should -Invoke -ModuleName DbHubDemo -CommandName Invoke-DemoRcaScriptExport -Times 1 -Exactly -ParameterFilter { $CheckPrefix -eq 'FABRIC' -and -not $Final }
        Should -Invoke -ModuleName DbHubDemo -CommandName Remove-DemoRcaEvidenceFile -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Save-DemoRcaPending -Times 1 -Exactly -ParameterFilter { $Saved -and $CheckPrefix -eq 'FABRIC' }

        # The workspace's notebook is from before the Incident RCA: nothing is staged, the run goes on, and a Warning says
        # how the evidence follows; the documents stay pending.
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricNotebookParameter -MockWith { [pscustomobject]@{ Known = $true; Has = $false; Error = '' } }
        $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -RunLiveActivity -Confirm:$false *>&1
        $withheld = Read-ImportResult | Where-Object checkId -EQ 'FABRIC.RCA.EVIDENCE'
        $withheld.status | Should -Be 'Warning'
        $withheld.message | Should -Be 'The RCA evidence wasn''t sent with the run: the workspace''s NB_DatabaseHub_LiveActivity is from before the Incident RCA (2026-11-20), so it would ignore it.'
        $withheld.remediation | Should -Match 'with -Notebook NB_DatabaseHub_LiveActivity in place of -SkipNotebookImport, which updates that notebook alone' -Because 'the fix leaves NB_DatabaseHub_Deployment, which fabric.importNotebooks false keeps as the person left it (the review of e113eab)'
        $withheld.remediation | Should -Match '^Run \./scripts/deploy\.ps1, which updates the notebook unless someone edited it, ' -Because 'deploy.ps1 updates an unedited notebook while fabric.importNotebooks is false (follow-ups decision 2a)'
        Should -Invoke -ModuleName DbHubDemo -CommandName Send-DemoRcaEvidenceFile -Times 1 -Exactly
        Should -Invoke -ModuleName DbHubDemo -CommandName Save-DemoRcaPending -Times 1 -Exactly -ParameterFilter { -not $Saved -and $Why -match 'from before the Incident RCA' }

        # A run that throws (review of 3b1348a): the documents the export took from the runner, which lists each once, are
        # still kept for the next save before the error goes on.
        Mock -ModuleName DbHubDemo -CommandName Test-DemoFabricNotebookParameter -MockWith { [pscustomobject]@{ Known = $true; Has = $true; Error = '' } }
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoRcaNotebookRun -MockWith { throw 'The Fabric API didn''t answer.' }
        { $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -RunLiveActivity -Confirm:$false *>&1 } | Should -Throw '*didn''t answer*'
        Should -Invoke -ModuleName DbHubDemo -CommandName Save-DemoRcaPending -Times 1 -Exactly -ParameterFilter { -not $Saved -and $Why -eq 'the run didn''t complete' -and $CheckPrefix -eq 'FABRIC' }
    }

    It 'works out the run''s kept values through Livy after -RunLiveActivity''s run completed, with the run''s token, and not after a run that failed (F35, 2026-11-23)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        Mock -CommandName Invoke-DemoHistoryKeptValue -MockWith { New-DemoResult -CheckId $CheckId -Area 'fabric' -Target 'fabric' -Status 'Pass' -Message 'worked out' }
        foreach ($job in 'Completed', 'Failed') {
            Set-FabricMock -Routes @(
                @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity'; type = 'Notebook' }) }) }
                @{ Method = 'Get'; Match = '/jobs/instances/'; Responses = @(New-FabricResponse -Status 200 -Body @{ status = $job }) }
                @{ Method = 'Post'; Match = [regex]::Escape('/jobs/instances?jobType=RunNotebook'); Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ Location = "$api/workspaces/$workspaceId/items/$itemId/jobs/instances/$operationId" }) }
            )
            $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -RunLiveActivity -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
            $kept = @(Read-ImportResult | Where-Object checkId -EQ 'FABRIC.KEPTVALUE')
            if ($job -eq 'Completed') {
                $kept.Count | Should -Be 1
                $kept[0].status | Should -Be 'Pass'
            }
            else {
                $kept.Count | Should -Be 0 -Because 'a run that failed saved nothing to work out'
            }
        }
        Should -Invoke -CommandName Invoke-DemoHistoryKeptValue -Times 1 -Exactly -ParameterFilter { $CheckId -eq 'FABRIC.KEPTVALUE' -and $null -ne $Token -and [string]$Config['fabric']['workspaceId'] -eq $workspaceId }
    }

    It 'adds the PostgreSQL metrics stop-demo.ps1 kept for a paused capacity with -PostgresMetricsPath, then moves the file aside (ADR 0025)' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        $pending = Join-Path -Path $TestDrive -ChildPath 'history-pending'
        $null = New-Item -ItemType Directory -Path $pending -Force
        $file = Join-Path -Path $pending -ChildPath 'postgres-metrics-20261113T190000Z.json'
        $document = '{"version":1,"servers":[{"role":"replica","target":"T4-replica","resourceName":"pgreplica01-abc123","sku":"Standard_D4ds_v5"}],"series":[]}'
        [System.IO.File]::WriteAllText($file, $document)
        $notebookDefinition = { param([string] $Text) New-FabricResponse -Status 200 -Body @{ definition = @{ parts = @(@{ path = 'notebook-content.py'; payload = [System.Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($Text)); payloadType = 'InlineBase64' }) } } }
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity'; type = 'Notebook' }) }) }
            @{ Method = 'Post'; Match = [regex]::Escape("/items/$itemId/getDefinition"); Responses = @(& $notebookDefinition "# PARAMETERS CELL`nPOSTGRES_METRICS = ''`n") }
            @{ Method = 'Get'; Match = '/jobs/instances/'; Responses = @(New-FabricResponse -Status 200 -Body @{ status = 'Completed' }) }
            @{ Method = 'Post'; Match = [regex]::Escape('/jobs/instances?jobType=RunNotebook'); Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ Location = "$api/workspaces/$workspaceId/items/$itemId/jobs/instances/$operationId" }) }
        )
        $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -RunLiveActivity -PostgresMetricsPath $file -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
        $LASTEXITCODE | Should -Be 0
        (Read-ImportResult | Where-Object checkId -EQ 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY').status | Should -Be 'Pass'
        $run = @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like '*jobType=RunNotebook' })
        (Get-RequestBody -Request $run[-1]).executionData.parameters.POSTGRES_METRICS.value | Should -BeExactly $document
        Test-Path -LiteralPath $file | Should -BeFalse
        Test-Path -LiteralPath (Join-Path -Path $pending -ChildPath 'saved/postgres-metrics-20261113T190000Z.json') | Should -BeTrue

        # The workspace's notebook is from before T4's history (2026-11-16): it would ignore them, so they aren't sent, the
        # run says so, and the file stays where it is.
        [System.IO.File]::WriteAllText($file, $document)
        Set-FabricMock -Routes @(
            @{ Method = 'Get'; Match = [regex]::Escape('/items?type=Notebook'); Responses = @(New-FabricResponse -Status 200 -Body @{ value = @(@{ id = $itemId; displayName = 'NB_DatabaseHub_LiveActivity'; type = 'Notebook' }) }) }
            @{ Method = 'Post'; Match = [regex]::Escape("/items/$itemId/getDefinition"); Responses = @(& $notebookDefinition "# PARAMETERS CELL`nCONFIRM = True`n") }
            @{ Method = 'Get'; Match = '/jobs/instances/'; Responses = @(New-FabricResponse -Status 200 -Body @{ status = 'Completed' }) }
            @{ Method = 'Post'; Match = [regex]::Escape('/jobs/instances?jobType=RunNotebook'); Responses = @(New-FabricResponse -Status 202 -Body $null -Headers @{ Location = "$api/workspaces/$workspaceId/items/$itemId/jobs/instances/$operationId" }) }
        )
        $null = & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -RunLiveActivity -PostgresMetricsPath $file -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false *>&1
        $withheld = Read-ImportResult | Where-Object checkId -EQ 'FABRIC.T4.HISTORY'
        $withheld.status | Should -Be 'Warning'
        $withheld.message | Should -Match 'is from before T4''s history \(2026-11-13\), so it would ignore them\.$'
        $withheld.remediation | Should -Match '^Run this command again with -Notebook NB_DatabaseHub_LiveActivity in place of -SkipNotebookImport, which updates that notebook alone first, edited or not; the file stays where it is\.$' -Because 'it leaves NB_DatabaseHub_Deployment as it is (2026-11-23)'
        $run = @($requests | Where-Object { $_.Method -eq 'Post' -and $_.Uri -like '*jobType=RunNotebook' })
        (Get-RequestBody -Request $run[-1]).executionData.parameters.PSObject.Properties.Name | Should -Not -Contain 'POSTGRES_METRICS'
        Test-Path -LiteralPath $file | Should -BeTrue -Because 'the metrics aren''t in the history'

        { & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -RunLiveActivity -PostgresMetricsPath (Join-Path -Path $pending -ChildPath 'missing.json') -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false } | Should -Throw '*doesn''t exist*'
        { & $configureFabric -ConfigPath $idConfigPath -OutputPath $outputPath -SkipHubChecks -SkipNotebookImport -PostgresMetricsPath $file -FabricToken (ConvertTo-TestSecureString -Value $plainToken) -Confirm:$false } | Should -Throw '*goes with -RunLiveActivity*'
    }
}

Describe 'Fabric and Power BI requests with a token that expires (2026-11-16 live finding)' {
    # Live: configure-powerbi.ps1 imported the history report with the Fabric token it got before an 8-minute Direct Lake
    # refresh, and Fabric answered HTTP 401 TokenExpired, so a first deployment ended NOT DONE.
    BeforeDiscovery {
        $renewalCases = @(
            # How each refuses a token, as seen live on 2026-11-16: Fabric with 401 and an error code, Power BI with 403, an
            # X-PowerBI-Error-Info header, and no body.
            @{ Service = 'Fabric'; Uri = 'https://api.fabric.microsoft.com/v1/workspaces'; Status = 401; Info = ''; Content = '{"requestId":"r","errorCode":"TokenExpired","message":"Access token has expired, resubmit with a new access token"}' }
            @{ Service = 'Power BI'; Uri = 'https://api.powerbi.com/v1.0/myorg/groups'; Status = 403; Info = 'TokenExpired'; Content = '' }
        )
    }

    BeforeAll {
        function New-RenewalTestToken {
            # A fake token Get-DemoAccessToken accepts, with an exp claim.
            param([int] $ExpiresInSeconds = 3600)
            $claims = [ordered]@{ tid = $tenantId; oid = $script:GuardTestObjectId; idtyp = 'user'; exp = [System.DateTimeOffset]::UtcNow.AddSeconds($ExpiresInSeconds).ToUnixTimeSeconds(); nonce = [guid]::NewGuid().ToString('N') }
            return ('tok{0}.{1}.sig{2}' -f [guid]::NewGuid().ToString('N'), (ConvertTo-GuardTestBase64Url ($claims | ConvertTo-Json -Compress)), [guid]::NewGuid().ToString('N'))
        }

        $script:getToken = {
            param([string] $Service)
            if ($Service -eq 'Fabric') { Get-DemoFabricToken -SubscriptionId $subscriptionId } else { Get-DemoPowerBIToken -SubscriptionId $subscriptionId }
        }
        $script:send = {
            param([string] $Service, [string] $Uri, [securestring] $Token)
            InModuleScope DbHubDemo -Parameters @{ Service = $Service; Uri = $Uri; Token = $Token } {
                if ($Service -eq 'Fabric') { Invoke-DemoFabricRequest -Method Get -Uri $Uri -Token $Token } else { Invoke-DemoPowerBIRequest -Method Get -Uri $Uri -Token $Token }
            }
        }
    }

    BeforeEach {
        Clear-DemoSecret
        Mock -ModuleName DbHubDemo -CommandName Write-DemoLog -MockWith { }
        # The Azure CLI hands out the tokens in $script:issue, in order.
        $script:issue = [System.Collections.Generic.Queue[string]]::new()
        $script:azCalls = 0
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith {
            $script:azCalls++
            [pscustomobject]@{ ExitCode = 0; StdOut = (@{ accessToken = $script:issue.Dequeue() } | ConvertTo-Json); StdErr = '' }
        }
        # Fabric and Power BI refuse the tokens in $script:refused as $script:refusal says; each request's token is kept.
        $script:refused = [System.Collections.Generic.HashSet[string]]::new()
        $script:refusal = $null
        $script:sent = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName DbHubDemo -CommandName Invoke-WebRequest -MockWith {
            $plain = [System.Net.NetworkCredential]::new('', $Token).Password
            $script:sent.Add($plain)
            if ($script:refused.Contains($plain)) {
                return $script:refusal
            }
            [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{"value":[]}' }
        }
    }

    It 'renews a refused <Service> token once and sends the request again; a caller still holding it sends the new one, without the Azure CLI' -TestCases $renewalCases {
        param($Service, $Uri, $Status, $Info, $Content)
        $script:refusal = [pscustomobject]@{ StatusCode = $Status; Headers = @{ 'X-PowerBI-Error-Info' = @($Info | Where-Object { $_ }) }; Content = $Content }
        $old = New-RenewalTestToken
        $new = New-RenewalTestToken
        $script:issue.Enqueue($old)
        $script:issue.Enqueue($new)
        $null = $script:refused.Add($old)
        $token = & $getToken $Service

        (& $send $Service $Uri $token).StatusCode | Should -Be 200
        @($script:sent) | Should -Be @($old, $new)
        $script:azCalls | Should -Be 2
        (& $send $Service $Uri $token).StatusCode | Should -Be 200
        $script:sent[-1] | Should -Be $new -Because 'the renewal is remembered for the token the caller still holds'
        $script:azCalls | Should -Be 2
        $pattern = '{0} refused the token in use (HTTP {1}), so a new one came from the Azure CLI*' -f $Service, $Status
        Should -Invoke -ModuleName DbHubDemo -CommandName Write-DemoLog -ParameterFilter { $Message -like $pattern } -Times 1 -Exactly
    }

    It 'renews a <Service> token that expires within 4 minutes before sending it, so it''s never refused' -TestCases $renewalCases {
        param($Service, $Uri, $Status, $Info, $Content)
        $script:refusal = [pscustomobject]@{ StatusCode = $Status; Headers = @{ 'X-PowerBI-Error-Info' = @($Info | Where-Object { $_ }) }; Content = $Content }
        $old = New-RenewalTestToken -ExpiresInSeconds 120
        $new = New-RenewalTestToken -ExpiresInSeconds 3600
        $script:issue.Enqueue($old)
        $script:issue.Enqueue($new)
        $null = $script:refused.Add($old)
        $token = & $getToken $Service

        (& $send $Service $Uri $token).StatusCode | Should -Be 200
        @($script:sent) | Should -Be @($new)
        (& $send $Service $Uri $token).StatusCode | Should -Be 200
        $script:azCalls | Should -Be 2 -Because 'the new token is far from its expiry'
    }

    It 'sends a refused <Service> token again only when the Azure CLI has a new one, asks it at most once a minute, and leaves a caller''s own token, and a 403 for a permission, as they are' -TestCases $renewalCases {
        param($Service, $Uri, $Status, $Info, $Content)
        $script:refusal = [pscustomobject]@{ StatusCode = $Status; Headers = @{ 'X-PowerBI-Error-Info' = @($Info | Where-Object { $_ }) }; Content = $Content }
        $only = New-RenewalTestToken
        $script:issue.Enqueue($only)
        $script:issue.Enqueue($only)
        $null = $script:refused.Add($only)
        $token = & $getToken $Service

        (& $send $Service $Uri $token).StatusCode | Should -Be $Status
        $script:sent.Count | Should -Be 1
        $script:azCalls | Should -Be 2
        (& $send $Service $Uri $token).StatusCode | Should -Be $Status
        $script:azCalls | Should -Be 2 -Because 'the same token came back less than a minute ago'

        $ownPlain = New-RenewalTestToken
        $null = $script:refused.Add($ownPlain)
        (& $send $Service $Uri (ConvertTo-TestSecureString -Value $ownPlain)).StatusCode | Should -Be $Status
        $script:azCalls | Should -Be 2
        $script:sent.Count | Should -Be 3

        # A 403 for a missing permission says nothing about the token.
        $script:refusal = [pscustomobject]@{ StatusCode = 403; Headers = @{}; Content = '{"error":{"code":"PowerBINotAuthorizedException"}}' }
        $fresh = New-RenewalTestToken
        $script:issue.Enqueue($fresh)
        $null = $script:refused.Add($fresh)
        $other = & $getToken $Service
        (& $send $Service $Uri $other).StatusCode | Should -Be 403
        $script:azCalls | Should -Be 3 -Because 'only the token itself came from the Azure CLI'
    }
}
