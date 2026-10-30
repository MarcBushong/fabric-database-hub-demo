# Fabric item definition read-back (Phase 18). Internal; Import-DemoFabricItem -ReadBack calls it.
# Items - Get Item Definition: https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition

function Get-DemoFabricItemReadBack {
    <#
    .SYNOPSIS
    Reads an item's definition back with Items - Get Item Definition and compares it with the definition that was
    sent. Returns one ADR 0012 record (FABRIC.READBACK.<NAME>). Internal.

    .DESCRIPTION
    POST /v1/workspaces/{workspaceId}/items/{itemId}/getDefinition, which can answer 202: then it waits Retry-After,
    polls Get Operation State, and reads the definition from Get Operation Result. Every part that was sent must come
    back under the same path. A KQL dashboard part is compared with Compare-DemoDashboardDocument: Pass when every
    page, data source, parameter, query text, and tile survived (fields that Fabric normalized are listed), Fail
    otherwise. Other parts are compared byte for byte: Pass when identical, Warning when Fabric changed them. A
    read-back that can't complete is a Warning, because the import before it succeeded.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [string] $ItemId,

        [Parameter(Mandatory)]
        [pscustomobject] $Item,

        [Parameter(Mandatory)]
        [string] $Label,

        [Parameter(Mandatory)]
        [string] $CheckId,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [ValidateRange(30, 3600)]
        [int] $TimeoutSeconds = 600
    )

    $docUrl = 'https://learn.microsoft.com/rest/api/fabric/core/items/get-item-definition'
    $target = "{0} '{1}'" -f $Label, $Item.DisplayName
    $evidence = [ordered]@{ workspaceId = $WorkspaceId; itemId = $ItemId; sentSha256 = $Item.Sha256 }
    $common = @{ CheckId = $CheckId; Area = 'fabric'; Target = 'fabric'; DocUrl = $docUrl }
    $result = {
        param([string] $Status, [string] $Message, [string] $Remediation = '')
        New-DemoResult @common -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation
    }
    $retry = ('Open the {0} in the workspace to check it, or run the import again; it updates the same item.' -f $Label)

    if ($ItemId -notmatch $script:GuidPattern) {
        return (& $result 'Warning' ("The import worked, but it returned no item ID, so the definition of {0} wasn't read back." -f $target) $retry)
    }
    try {
        $uri = '{0}/workspaces/{1}/items/{2}/getDefinition' -f $script:FabricApiBaseUri, $WorkspaceId, $ItemId
        $response = Invoke-DemoFabricRequest -Method Post -Uri $uri -Token $Token
        $body = $null
        if ($response.StatusCode -eq 200) {
            $body = $response.Body
        }
        elseif ($response.StatusCode -eq 202) {
            $operationId = Get-DemoFabricHeaderValue -Headers $response.Headers -Name 'x-ms-operation-id'
            $evidence['operationId'] = $operationId
            $state = Wait-DemoFabricOperation -OperationId $operationId -Token $Token -TimeoutSeconds $TimeoutSeconds `
                -RetryAfterSeconds (Get-DemoFabricRetryDelay -Headers $response.Headers -Default 5 -Maximum 30)
            if ($state.Status -ne 'Succeeded') {
                return (& $result 'Warning' ("The import worked, but reading back the definition of {0} didn't succeed: {1} {2}" -f $target, $state.Status, $state.Error).Trim() $retry)
            }
            $operationResult = Invoke-DemoFabricRequest -Method Get -Uri ('{0}/operations/{1}/result' -f $script:FabricApiBaseUri, $operationId) -Token $Token
            if ($operationResult.StatusCode -ne 200) {
                $evidence['httpStatus'] = $operationResult.StatusCode
                return (& $result 'Warning' ("The import worked, but the definition of {0} couldn't be read from the operation result: {1}" -f $target, (Get-DemoFabricErrorText -Response $operationResult)) $retry)
            }
            $body = $operationResult.Body
        }
        else {
            $evidence['httpStatus'] = $response.StatusCode
            return (& $result 'Warning' ("The import worked, but the definition of {0} couldn't be read back: {1}" -f $target, (Get-DemoFabricErrorText -Response $response)) $retry)
        }
    }
    catch {
        return (& $result 'Warning' ("The import worked, but reading back the definition of {0} stopped: {1}" -f $target, (Get-DemoExceptionText -Exception $_.Exception)) $retry)
    }

    $definition = Get-DemoMemberValue -InputObject $body -Name 'definition'
    $parts = Get-DemoMemberValue -InputObject $definition -Name 'parts'
    $readParts = @{}
    foreach ($part in @($parts)) {
        $path = [string](Get-DemoMemberValue -InputObject $part -Name 'path')
        if ($path) {
            $readParts[$path] = [string](Get-DemoMemberValue -InputObject $part -Name 'payload')
        }
    }
    $evidence['partsReadBack'] = @($readParts.Keys | Sort-Object)

    $statuses = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($sent in @($Item.Definition['parts'])) {
        $path = [string]$sent['path']
        if (-not $readParts.ContainsKey($path)) {
            $statuses.Add('Fail')
            $notes.Add(('the part {0} is missing' -f $path))
            continue
        }
        $sentBytes = [System.Convert]::FromBase64String([string]$sent['payload'])
        try {
            $readBytes = [System.Convert]::FromBase64String($readParts[$path])
        }
        catch {
            $statuses.Add('Fail')
            $notes.Add(('the part {0} came back without a Base64 payload' -f $path))
            continue
        }
        $evidence['readSha256'] = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($readBytes)).ToLowerInvariant()
        $sameBytes = [System.Linq.Enumerable]::SequenceEqual([byte[]]$sentBytes, [byte[]]$readBytes)
        $evidence['byteIdentical'] = $sameBytes
        if ($Item.Type -eq 'KQLDashboard' -and $path -like '*.json') {
            $utf8 = [System.Text.UTF8Encoding]::new($false)
            $comparison = Compare-DemoDashboardDocument -Expected ($utf8.GetString($sentBytes) | ConvertFrom-Json -AsHashtable -Depth 64) -Actual ($utf8.GetString($readBytes) | ConvertFrom-Json -AsHashtable -Depth 64)
            $evidence['identical'] = $sameBytes -or $comparison.Identical
            $evidence['normalizedFields'] = @($comparison.NormalizedFields)
            $evidence['differences'] = @($comparison.Differences | Select-Object -First 20)
            if ($comparison.EssentialMatch) {
                $statuses.Add('Pass')
                if ($sameBytes) {
                    $notes.Add(('{0} is identical to what was sent, byte for byte' -f $path))
                }
                elseif ($comparison.Identical) {
                    # Live, 2026-10-21: Fabric returned the JSON with CRLF line endings and no final newline.
                    $notes.Add(('{0} is identical to what was sent in content; Fabric stored it with other whitespace or line endings' -f $path))
                }
                else {
                    $notes.Add(('every page, data source, parameter, query, and tile in {0} came back; Fabric normalized {1}' -f $path, ($comparison.NormalizedFields -join ', ')))
                }
            }
            else {
                $statuses.Add('Fail')
                $notes.Add(('{0} came back with {1} essential difference(s): {2}' -f $path, $comparison.Differences.Count, (($comparison.Differences | Select-Object -First 5) -join '; ')))
            }
        }
        elseif ($sameBytes) {
            $statuses.Add('Pass')
            $notes.Add(('{0} is identical to what was sent' -f $path))
        }
        else {
            $statuses.Add('Warning')
            $notes.Add(('{0} came back different from what was sent; Fabric may normalize this item type' -f $path))
        }
    }

    $status = if ($statuses -contains 'Fail') { 'Fail' } elseif ($statuses -contains 'Warning') { 'Warning' } elseif ($statuses.Count -gt 0) { 'Pass' } else { 'Fail' }
    $message = 'Read back the definition of {0} with Get Item Definition: {1}.' -f $target, ($(if ($notes.Count -gt 0) { $notes -join '; ' } else { 'no parts were sent' }))
    $remediation = switch ($status) {
        'Fail' { 'Run the import again. If the definition still comes back different, compare it with fabric/realtime/RealTimeDashboard.json and check the schema version pinned in config/versions.json.' }
        'Warning' { $retry }
        default { '' }
    }
    & $result $status $message $remediation
}
