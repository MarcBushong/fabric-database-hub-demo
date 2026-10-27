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

    It 'points only the uploaded copy at a GitHub repository and environment, without a lakehouse too' {
        $before = [System.IO.File]::ReadAllBytes($liveNotebook)
        $definition = Get-DemoFabricNotebookDefinition -Path $liveNotebook -GitHubRepository 'contoso/dbhub-fork' -GitHubEnvironment 'demo-fork'
        $definition.LakehouseRebound | Should -BeFalse
        $uploaded = ConvertFrom-TestPayload -Payload $definition.Definition.parts[0].payload | ConvertFrom-Json -AsHashtable -Depth 64
        $parameters = (@($uploaded['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]['source']) -join ''
        $parameters | Should -Match '(?m)^GITHUB_REPOSITORY = "contoso/dbhub-fork"$'
        $parameters | Should -Match '(?m)^GITHUB_ENVIRONMENT = "demo-fork"$'
        $parameters | Should -Match '(?m)^WORKSPACE_ID = ""$'
        $uploaded['metadata']['dependencies']['lakehouse'].Contains('default_lakehouse') | Should -BeFalse
        [System.IO.File]::ReadAllBytes($liveNotebook) | Should -Be $before
        # The deployment notebook has no GITHUB_ENVIRONMENT line, so only its repository changes.
        $deployment = Get-DemoFabricNotebookDefinition -Path $deploymentNotebook -GitHubRepository 'contoso/dbhub-fork' -GitHubEnvironment 'demo-fork'
        $text = ConvertFrom-TestPayload -Payload $deployment.Definition.parts[0].payload
        $text | Should -Match 'GITHUB_REPOSITORY = \\"contoso/dbhub-fork\\"'
        $text | Should -Not -Match 'GITHUB_ENVIRONMENT'
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

    It 'points the uploaded notebooks at github.repository and github.environment, but not at the example''s placeholder' {
        Mock -ModuleName DbHubDemo -CommandName Invoke-DemoAzCli -MockWith { throw 'no Azure CLI calls expected' }
        $gitHubConfig = Get-Content -LiteralPath $idConfigPath -Raw | ConvertFrom-Json -AsHashtable
        $gitHubConfig['github'] = [ordered]@{ repository = 'contoso/dbhub-fork'; environment = 'demo-fork' }
        $gitHubConfigPath = Join-Path -Path $TestDrive -ChildPath 'demo.github.config.json'
        Set-Content -LiteralPath $gitHubConfigPath -Value ($gitHubConfig | ConvertTo-Json -Depth 10) -Encoding utf8NoBOM
        $default = [regex]::Match([System.IO.File]::ReadAllText($liveNotebook), 'GITHUB_REPOSITORY = \\"([^\\"]+)\\"').Groups[1].Value
        $default | Should -Not -BeNullOrEmpty
        # The ID configuration is the example's, so its github.repository is the placeholder and the default stays.
        foreach ($case in @(
                @{ Path = $gitHubConfigPath; Repository = 'contoso/dbhub-fork'; Environment = 'demo-fork' }
                @{ Path = $idConfigPath; Repository = $default; Environment = 'demo' }
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
                $parameters | Should -Match ('(?m)^GITHUB_REPOSITORY = "{0}"$' -f [regex]::Escape($case.Repository))
                if ($update.Uri -like "*/items/$operationId/updateDefinition") {
                    $parameters | Should -Match ('(?m)^GITHUB_ENVIRONMENT = "{0}"$' -f [regex]::Escape($case.Environment))
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
        $azCalls[$azCalls.Count - 1] | Should -BeExactly "account get-access-token --resource https://api.fabric.microsoft.com --output json --subscription $subscriptionId"
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
        $deployment.message | Should -Match 'fabric\.importNotebooks is false'
        $live.status | Should -Be 'Pass'
        $live.message | Should -Match '^Created'
        $live.message | Should -Match 'imports a missing notebook without asking'
        @($requests | Where-Object { $_.Uri -like '*/updateDefinition' }).Count | Should -Be 0
        # A newly created live-activity notebook runs once, so the lakehouse gets the history tables.
        ($results | Where-Object checkId -EQ 'FABRIC.NOTEBOOKRUN.NB_DATABASEHUB_LIVEACTIVITY').status | Should -Be 'Pass'
    }
}
