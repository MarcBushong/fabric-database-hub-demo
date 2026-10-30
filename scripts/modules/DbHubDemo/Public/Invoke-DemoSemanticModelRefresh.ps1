function Invoke-DemoSemanticModelRefresh {
    <#
    .SYNOPSIS
    Refreshes a semantic model once through the Power BI REST API and waits for the result. For a Direct Lake model
    this is framing: it points the model at the lakehouse's current Delta table versions.

    .DESCRIPTION
    Refresh Dataset In Group with an enhanced-refresh body (type full, transactional, no retry), then Get Refresh
    Execution Details In Group until the refresh is Completed or Failed. The refresh ID comes from x-ms-request-id
    (or the last segment of Location); the polling URI is always built on https://api.powerbi.com. Returns one ADR
    0012 record, FABRIC.SEMANTICMODEL.REFRESH:
    - Pass: Completed.
    - Fail: Failed, TimedOut, Cancelled, or Disabled (with the refresh messages), or the request was refused.
    - Manual action required: the workspace's capacity is paused (it never resumes it), or the token was refused.
    - Warning: it didn't finish within -TimeoutSeconds; it may still complete.
    With -WhatIf it sends nothing and returns Not selected with the planned requests.

    With -TableRetryMinutes, a refresh that fails because Direct Lake can't see some of the lakehouse's tables
    (0xC14700DF, "source tables either do not exist or access was denied") is sent again every -TableRetrySeconds
    until that many minutes have passed. Tables that a notebook has just created in a new lakehouse take a while to
    reach Direct Lake: about 20 minutes in the live check of 2026-10-27, while the same refresh passed later
    unchanged. Any other failure is reported at once.

    - Refresh Dataset In Group: https://learn.microsoft.com/rest/api/power-bi/datasets/refresh-dataset-in-group
    - Get Refresh Execution Details In Group: https://learn.microsoft.com/rest/api/power-bi/datasets/get-refresh-execution-details-in-group
    - Direct Lake framing: https://learn.microsoft.com/fabric/fundamentals/direct-lake-how-it-works

    .EXAMPLE
    Invoke-DemoSemanticModelRefresh -WorkspaceId $workspaceId -SemanticModelId $modelId -Token (Get-DemoPowerBIToken -SubscriptionId $subscriptionId)
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $WorkspaceId,

        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
        [string] $SemanticModelId,

        [securestring] $Token,

        [ValidateRange(30, 3600)]
        [int] $TimeoutSeconds = 900,

        [ValidateRange(0, 120)]
        [int] $TableRetryMinutes = 0,

        [ValidateRange(10, 600)]
        [int] $TableRetrySeconds = 120
    )

    $checkId = 'FABRIC.SEMANTICMODEL.REFRESH'
    $refreshesUri = '{0}/groups/{1}/datasets/{2}/refreshes' -f $script:PowerBIApiBaseUri, $WorkspaceId, $SemanticModelId
    $docUrl = 'https://learn.microsoft.com/rest/api/power-bi/datasets/refresh-dataset-in-group'
    $evidence = [ordered]@{ workspaceId = $WorkspaceId; semanticModelId = $SemanticModelId }
    $new = {
        param([string] $Status, [string] $Message, [string] $Remediation = '')
        New-DemoResult -CheckId $checkId -Area 'fabric' -Target 'fabric' -Status $Status -Message $Message -Evidence $evidence -Remediation $Remediation -DocUrl $docUrl
    }

    if (-not $PSCmdlet.ShouldProcess("semantic model $SemanticModelId", 'Refresh (Direct Lake framing) through the Power BI REST API')) {
        $evidence['plannedRequests'] = @(
            ('POST {0} {{"type":"full","commitMode":"transactional","retryCount":0}}' -f $refreshesUri)
            ('GET {0}/<refreshId> until Completed or Failed' -f $refreshesUri)
        )
        return (& $new 'Not selected' 'Dry run: would refresh the semantic model once. No request was sent.')
    }
    if ($null -eq $Token) {
        throw 'A Power BI token is required. Use Get-DemoPowerBIToken, or pass -Token.'
    }
    $refused = {
        param([pscustomobject] $Response, [string] $What)
        $text = Get-DemoPowerBIErrorText -Response $Response
        $evidence['httpStatus'] = $Response.StatusCode
        if ($text -cmatch 'CapacityNotActive|CapacityNotAvailable|capacity.*paused') {
            return (& $new 'Manual action required' ('{0}: the workspace''s capacity is paused. {1}' -f $What, $text) `
                    'A capacity administrator resumes the capacity (Azure portal, Microsoft Fabric, the capacity, Resume), which also resumes billing. Then run the script again.')
        }
        if ($Response.StatusCode -eq 401) {
            return (& $new 'Manual action required' ('{0}: the Power BI token was refused. {1}' -f $What, $text) "Sign in again with 'az login --tenant <tenantId>' and run the script again.")
        }
        $remediation = if ($Response.StatusCode -eq 403) { 'You need Contributor or higher on the workspace, and the semantic model''s owner must be able to read the lakehouse.' } else { 'Run the script again; the refresh is idempotent.' }
        return (& $new 'Fail' ('{0}: {1}' -f $What, $text) $remediation)
    }

    $timeout = $TimeoutSeconds
    $refreshOnce = {
        try {
            $body = [ordered]@{ type = 'full'; commitMode = 'transactional'; retryCount = 0 }
            # A second request would queue a second refresh, so it's sent again only when it never reached the service.
            $response = Invoke-DemoPowerBIRequest -Method Post -Uri $refreshesUri -Body $body -Token $Token -NotIdempotent
            if ($response.StatusCode -ne 202) {
                return (& $refused $response 'The refresh request was refused')
            }
            $refreshId = Get-DemoFabricHeaderValue -Headers $response.Headers -Name 'x-ms-request-id'
            if ($refreshId -notmatch $script:GuidPattern) {
                $location = Get-DemoFabricHeaderValue -Headers $response.Headers -Name 'Location'
                $refreshId = ($location -split '/')[-1]
            }
            if ($refreshId -notmatch $script:GuidPattern) {
                return (& $new 'Warning' 'The refresh was accepted, but its ID wasn''t returned, so the script couldn''t wait for it.' 'Open the semantic model''s refresh history in the workspace.')
            }
            $evidence['refreshId'] = $refreshId
            $waited = 0
            $delay = Get-DemoFabricRetryDelay -Headers $response.Headers -Default 5 -Maximum 30
            while ($true) {
                Start-Sleep -Seconds $delay
                $waited += $delay
                $state = Invoke-DemoPowerBIRequest -Method Get -Uri ('{0}/{1}' -f $refreshesUri, $refreshId) -Token $Token
                if ($state.StatusCode -notin 200, 202) {
                    return (& $refused $state 'The refresh status couldn''t be read')
                }
                $status = [string](Get-DemoMemberValue -InputObject $state.Body -Name 'status')
                $evidence['status'] = $status
                $evidence['extendedStatus'] = [string](Get-DemoMemberValue -InputObject $state.Body -Name 'extendedStatus')
                if ($status -eq 'Completed') {
                    $evidence['startTime'] = [string](Get-DemoMemberValue -InputObject $state.Body -Name 'startTime')
                    $evidence['endTime'] = [string](Get-DemoMemberValue -InputObject $state.Body -Name 'endTime')
                    return (& $new 'Pass' ('Refreshed the semantic model (Direct Lake framing) in about {0} seconds.' -f $waited))
                }
                if ($status -in 'Failed', 'TimedOut', 'Cancelled', 'Disabled') {
                    $messageList = Get-DemoMemberValue -InputObject $state.Body -Name 'messages'
                    $messages = @(foreach ($item in @($messageList)) {
                            '{0} {1}' -f (Get-DemoMemberValue -InputObject $item -Name 'code'), (Get-DemoMemberValue -InputObject $item -Name 'message')
                        }) | Where-Object { $_.Trim() } | Select-Object -First 5
                    $evidence['messages'] = @($messages)
                    $text = Protect-DemoText -Text ((@($messages) -join ' | ').Trim())
                    $remediation = if ($text -match 'CapacityNotActive') { 'A capacity administrator resumes the capacity, then run the script again.' }
                    else { 'Run NB_DatabaseHub_LiveActivity with SAVE_RESULTS true, so all five lakehouse tables exist with every column the model reads, then run the script again.' }
                    return (& $new 'Fail' ('The refresh ended with status {0}: {1}' -f $status, $text) $remediation)
                }
                if ($waited -ge $timeout) {
                    return (& $new 'Warning' ("The refresh didn't finish within {0} seconds (last status {1}); it may still complete." -f $timeout, $status) 'Check the semantic model''s refresh history, then run the script again.')
                }
                $delay = Get-DemoFabricRetryDelay -Headers $state.Headers -Default 5 -Maximum 30
            }
        }
        catch {
            # A network error that lasted through the retries (Invoke-DemoTransientRetry) says so, with its innermost cause.
            if (Test-DemoNetworkFailure -Exception $_.Exception) {
                $evidence['networkError'] = $true
            }
            return (& $new 'Fail' ('The refresh stopped: {0}' -f (Get-DemoExceptionText -Exception $_.Exception)) 'Run the script again; the refresh is idempotent.')
        }
    }

    # Direct Lake can't see a new table for a while after a notebook creates it (live, 2026-10-27): 0xC14700DF.
    $notVisible = '0xC14700DF|source tables either do not exist or access was denied'
    $maxAttempts = 1 + [int][System.Math]::Floor(($TableRetryMinutes * 60) / $TableRetrySeconds)
    $attempt = 0
    while ($true) {
        $attempt++
        $result = & $refreshOnce
        $retry = $result.status -eq 'Fail' -and [string]$result.message -match $notVisible
        if (-not $retry -or $attempt -ge $maxAttempts) {
            break
        }
        Write-DemoLog -Level Warning -Message ('Direct Lake can''t see some of the lakehouse''s tables yet; new tables take a while to reach it. Refreshing again in {0} seconds (attempt {1} of {2}).' -f $TableRetrySeconds, ($attempt + 1), $maxAttempts)
        Start-Sleep -Seconds $TableRetrySeconds
    }
    if ($attempt -gt 1) {
        $evidence['attempts'] = $attempt
        $minutes = [System.Math]::Round((($attempt - 1) * $TableRetrySeconds) / 60.0, 1)
        if ($result.status -eq 'Pass') {
            $result = & $new 'Pass' ('{0} It took {1} attempts over about {2} minutes, because Direct Lake couldn''t see some of the lakehouse''s new tables at first.' -f $result.message, $attempt, $minutes)
        }
        elseif ($retry) {
            $result = & $new 'Fail' ('{0} (still after {1} attempts over about {2} minutes)' -f $result.message, $attempt, $minutes) 'If NB_DatabaseHub_LiveActivity created the tables in the last half hour, wait a few minutes and run the script again. Otherwise run NB_DatabaseHub_LiveActivity with SAVE_RESULTS true, so all five lakehouse tables exist with every column the model reads, then run the script again.'
        }
    }
    return $result
}
