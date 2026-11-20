# The Incident RCA's evidence for the operator's scripts (2026-11-20, ADR 0031, rca/README.md): stop-demo.ps1 -SaveHistory,
# deploy.ps1's history snapshot, and configure-fabric.ps1 -RunLiveActivity run the runner's 'rca export' and 'rca part' on
# the demo's VMs through managed Run Commands with the operator's sign-in, as the control's runbook does, check the parts,
# and stage them in the demo lakehouse's Files/rca/inbox for NB_DatabaseHub_LiveActivity's RCA_EVIDENCE_FILE. Nothing new
# is granted: Run Command takes the Contributor role that deploys the demo, and OneLake the workspace role that deploy gave
# the operator. A document a save didn't take stays listed in out/history-pending (IDs, part counts, and SHA-256s; none of
# the evidence), and the runner keeps it for 7 days, so the next save fetches it again.
# - Managed Run Command, the 4 KB of output its instance view keeps, and 25 per VM:
#   https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed
#   https://learn.microsoft.com/azure/virtual-machines/run-command-overview
# - Virtual Machine Run Commands - Create Or Update, Get By Virtual Machine, List By Virtual Machine, Delete:
#   https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands
# - OneLake's ADLS Gen2 API, with the Storage audience: https://learn.microsoft.com/fabric/onelake/onelake-access-api
$script:RcaPartPattern = '^DBHUBDEMO-RCA 1 [0-9]{8}T[0-9]{6}Z-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{4} [1-9][0-9]?/[1-9][0-9]? [0-9a-f]{64} [A-Za-z0-9+/]+={0,2}$'
$script:RcaDocumentPattern = '^[0-9]{8}T[0-9]{6}Z-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{4}$'
$script:RcaStatuses = @('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')
$script:RcaTerminalStates = @('Succeeded', 'Failed', 'TimedOut', 'Canceled')
# What a document may decompress to: far above the 64 KiB of gzip an export holds, so a bad stream stops early.
$script:RcaMaxJsonBytes = 16MB
# rca/README.md, Limits: RCA_EVIDENCE holds at most 64 parts, and RCA_EVIDENCE_FILE at most 262,144 bytes.
$script:RcaMaxParts = 64
$script:RcaEvidenceFileBytes = 262144
$script:RcaEvidenceFilePattern = '^Files/rca/inbox/[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json$'
$script:RcaInbox = 'Files/rca/inbox'
$script:RcaRunCommandPrefix = 'DbHubDemo-Rca-'
$script:RcaTargets = @('T1', 'T2', 'T3', 'T4', 'T4-replica')
# The runner deletes an exported document 7 days after its export (rca/README.md, The flow).
$script:RcaKeepDays = 7
$script:RcaRunCommandDoc = 'https://learn.microsoft.com/azure/virtual-machines/windows/run-command-managed'
$script:RcaOneLakeDoc = 'https://learn.microsoft.com/fabric/onelake/onelake-access-api'
$script:RcaRunAgain = './scripts/configure-fabric.ps1 -SkipHubChecks -SkipNotebookImport -RunLiveActivity'

function Test-DemoRcaInteger {
    # Whether a JSON value is a whole number from -Minimum to -Maximum (not a string or a fraction). Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object] $Value,

        [long] $Minimum,

        [long] $Maximum
    )

    return (($Value -is [int] -or $Value -is [long]) -and [long]$Value -ge $Minimum -and [long]$Value -le $Maximum)
}

function ConvertTo-DemoRcaReference {
    # One document reference (documentId, parts, sha256, vm, exportedUtc) from an index or the pending list, checked against
    # the contract's patterns, or $null. Pure. Internal.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [object] $InputObject,

        [AllowEmptyString()]
        [string] $Vm = '',

        [AllowNull()]
        [object] $ExportedUtc = $null
    )

    $id = [string](Get-DemoMemberValue -InputObject $InputObject -Name 'documentId')
    $parts = Get-DemoMemberValue -InputObject $InputObject -Name 'parts'
    $sha = [string](Get-DemoMemberValue -InputObject $InputObject -Name 'sha256')
    if ($id -cnotmatch $script:RcaDocumentPattern -or -not (Test-DemoRcaInteger -Value $parts -Minimum 1 -Maximum 99) -or $sha -cnotmatch '^[0-9a-f]{64}$') {
        return $null
    }
    $vmName = [string](Get-DemoMemberValue -InputObject $InputObject -Name 'vm')
    if (-not $vmName) {
        $vmName = $Vm
    }
    if ($vmName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') {
        return $null
    }
    $when = $ExportedUtc
    if ($null -eq $when) {
        $when = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $InputObject -Name 'exportedUtc')
    }
    if ($null -eq $when) {
        $when = Get-DemoUtcNow
    }
    return [ordered]@{ documentId = $id; parts = [int]$parts; sha256 = $sha; vm = $vmName; exportedUtc = ([datetime]$when).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) }
}

function Get-DemoRcaExportHost {
    <#
    .SYNOPSIS
    The VMs whose runner's observer captures RCA evidence (rca/README.md, The flow), for the scripts' export: sqlvm01 for
    T1, T3, T4, and T4's read replica, and the T2 host for T2, whose guest's runner the VM-side control reaches over
    PowerShell Direct. T5 has no observer. Returns Vm, Targets, OneAtATime (the T2 host: R871), and Outcome and Message
    when the export skips the VM (NoRunner, or NotRunning: what it captured stays on it). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $State = $null,

        [System.Collections.IDictionary] $Power = @{}
    )

    $hostVm = Get-DemoHostVmName -Config $Config
    $runner = [string](Get-DemoMemberValue -InputObject $State -Name 'RunnerSha256')
    # Into a variable first: Get-DemoMemberValue returns the array whole.
    $sentList = Get-DemoMemberValue -InputObject $State -Name 'RunnerSentTo'
    $sentTo = @(@($sentList) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $hosts = foreach ($entry in @(
            [pscustomobject]@{ Vm = 'sqlvm01'; Targets = @('T1', 'T3', 'T4', 'T4-replica'); OneAtATime = $false }
            [pscustomobject]@{ Vm = $hostVm; Targets = @('T2'); OneAtATime = $true }
        )) {
        $outcome = ''
        $message = ''
        if (-not $runner) {
            $outcome = 'NoRunner'
            $message = 'No workload runner was deployed on {0}, so nothing was captured there.' -f $entry.Vm
        }
        elseif ($entry.Targets -contains 'T2' -and ($hostVm -ne 'archost01' -or 'archost01' -notin $sentTo)) {
            $outcome = 'NoRunner'
            $message = 'T2 has no workload runner (the evaluation-only mode, or the runner wasn''t sent to archost01), so nothing was captured there.'
        }
        elseif ([string]$Power[$entry.Vm] -ne 'PowerState/running') {
            $outcome = 'NotRunning'
            $message = '{0} isn''t running, so what its observer captured stays on it until the next export.' -f $entry.Vm
        }
        [pscustomobject]@{ Vm = $entry.Vm; Targets = $entry.Targets; OneAtATime = $entry.OneAtATime; Outcome = $outcome; Message = $message }
    }
    return @($hosts)
}

function ConvertFrom-DemoRcaRunOutput {
    <#
    .SYNOPSIS
    What one Rca Run Command printed (the VM-side control's Invoke-DemoControlRca): its result line, DBHUBDEMO-WORKLOAD with
    an ADR 0012 status, and the runner's own line after it (DBHUBDEMO-RCA-INDEX for the export, DBHUBDEMO-RCA for a part).
    Returns Status ('' without a result line), Message, OldRunner (the runner predates the export), OldBundle (the VM's
    bootstrap bundle predates the Rca action), and Line. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Output
    )

    $answer = [pscustomobject]@{ Status = ''; Message = ''; OldRunner = $false; OldBundle = $false; Line = '' }
    foreach ($raw in ([string]$Output -split '\r?\n')) {
        $text = $raw.Trim()
        if ($text.StartsWith('DBHUBDEMO-WORKLOAD ', [System.StringComparison]::Ordinal)) {
            $parsed = $null
            try {
                $parsed = $text.Substring(19) | ConvertFrom-Json -Depth 8
            }
            catch {
                $parsed = $null
            }
            if ($null -eq $parsed) {
                continue
            }
            $answer.Status = [string](Get-DemoMemberValue -InputObject $parsed -Name 'status')
            $answer.Message = Protect-DemoText -Text ([string](Get-DemoMemberValue -InputObject $parsed -Name 'message'))
            $answer.OldRunner = (Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $parsed -Name 'evidence') -Name 'oldRunner') -eq $true
            # A VM-side control from before the Rca action answers with its list of actions.
            $answer.OldBundle = $answer.Status -eq 'Fail' -and $answer.Message -match '^Unknown action' -and $answer.Message -notmatch '\bRca\b'
        }
        elseif ($text.StartsWith('DBHUBDEMO-RCA-INDEX ', [System.StringComparison]::Ordinal) -or $text.StartsWith('DBHUBDEMO-RCA ', [System.StringComparison]::Ordinal)) {
            $answer.Line = $text
        }
    }
    return $answer
}

function ConvertFrom-DemoRcaExportIndex {
    <#
    .SYNOPSIS
    The export's index line, 'DBHUBDEMO-RCA-INDEX <json>' (rca/transport.schema.json, exportIndex): Valid, Why, Documents
    (documentId, parts, sha256), Status, and Message. An index of another kind or version isn't used: its Why says so, with
    ./scripts/deploy.ps1 as the fix (rca/README.md, Versioning). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Line
    )

    $answer = [pscustomobject]@{ Valid = $false; Why = ''; Documents = @(); Status = ''; Message = '' }
    if (-not ([string]$Line).StartsWith('DBHUBDEMO-RCA-INDEX ', [System.StringComparison]::Ordinal) -or $Line.Length -gt 3400) {
        $answer.Why = 'the export printed no index line'
        return $answer
    }
    try {
        $index = $Line.Substring(20) | ConvertFrom-Json -AsHashtable
    }
    catch {
        $answer.Why = 'its index line isn''t JSON'
        return $answer
    }
    if ($index -isnot [System.Collections.IDictionary] -or [string]$index['kind'] -cne 'ContosoCare.RcaExportIndex' -or -not (Test-DemoRcaInteger -Value $index['version'] -Minimum 1 -Maximum 1)) {
        $answer.Why = 'its index is of a kind or version these scripts don''t know (run ./scripts/deploy.ps1, which updates the runner and the scripts together)'
        return $answer
    }
    $list = $index['documents']
    $status = [string]$index['status']
    $message = $index['message']
    if ($list -isnot [System.Collections.IList] -or $list.Count -gt 32 -or $status -cnotin $script:RcaStatuses -or $message -isnot [string] -or $message.Length -gt 500) {
        $answer.Why = 'its index doesn''t follow the contract'
        return $answer
    }
    $documents = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $list) {
        $reference = ConvertTo-DemoRcaReference -InputObject $item -Vm 'unknown'
        if ($null -eq $reference -or -not $seen.Add([string]$reference['documentId'])) {
            $answer.Why = 'its index lists a document that doesn''t follow the contract'
            return $answer
        }
        $documents.Add([ordered]@{ documentId = $reference['documentId']; parts = $reference['parts']; sha256 = $reference['sha256'] })
    }
    $answer.Valid = $true
    $answer.Documents = $documents.ToArray()
    $answer.Status = $status
    $answer.Message = Protect-DemoText -Text $message
    return $answer
}

function Test-DemoRcaPartLine {
    # Whether a line is the part asked for: the contract's pattern (rca/transport.schema.json, partLine), at most 3,400
    # characters, and the document, index, count, and SHA-256 its export's index gave. Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Line,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Document,

        [Parameter(Mandatory)]
        [int] $Part
    )

    if ([string]::IsNullOrEmpty($Line) -or $Line.Length -gt 3400 -or $Line -cnotmatch $script:RcaPartPattern) {
        return $false
    }
    $fields = $Line.Split(' ')
    return ($fields[2] -ceq [string]$Document['documentId'] -and $fields[3] -ceq ('{0}/{1}' -f $Part, [int]$Document['parts']) -and $fields[4] -ceq [string]$Document['sha256'])
}

function Expand-DemoRcaDocument {
    <#
    .SYNOPSIS
    One evidence document from its part lines (rca/README.md, Part lines): every index from 1 to its count once, each part's
    Base64 decoded on its own, concatenated in order, the SHA-256 every part names checked, then gunzipped (at most 16 MB)
    and parsed. Returns Ok, Why, and Document (a hashtable). A document with a missing or bad part is never used in part.
    Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Line
    )

    $fail = { param([string] $Why) [pscustomobject]@{ Ok = $false; Why = $Why; Document = $null } }
    $pieces = @{}
    $count = 0
    $sha = ''
    $id = ''
    foreach ($text in $Line) {
        if ([string]$text -cnotmatch $script:RcaPartPattern) {
            return (& $fail 'a part doesn''t follow the contract')
        }
        $fields = $text.Split(' ')
        $position = $fields[3].Split('/')
        if (-not $id) {
            $id = $fields[2]
            $count = [int]$position[1]
            $sha = $fields[4]
        }
        $index = [int]$position[0]
        if ($fields[2] -cne $id -or [int]$position[1] -ne $count -or $fields[4] -cne $sha -or $index -gt $count -or $pieces.ContainsKey($index)) {
            return (& $fail 'its parts disagree')
        }
        $pieces[$index] = $fields[5]
    }
    if ($count -eq 0 -or $pieces.Count -ne $count) {
        return (& $fail ('{0} of its {1} part(s) arrived' -f $pieces.Count, $count))
    }
    $buffer = [System.IO.MemoryStream]::new()
    try {
        for ($index = 1; $index -le $count; $index++) {
            $bytes = [System.Convert]::FromBase64String([string]$pieces[$index])
            $buffer.Write($bytes, 0, $bytes.Length)
        }
    }
    catch {
        return (& $fail 'a part''s Base64 doesn''t decode')
    }
    $gzip = $buffer.ToArray()
    $hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($gzip)).ToLowerInvariant()
    if ($hash -cne $sha) {
        return (& $fail 'its SHA-256 doesn''t match')
    }
    try {
        $plain = [System.IO.MemoryStream]::new()
        $stream = [System.IO.Compression.GZipStream]::new([System.IO.MemoryStream]::new($gzip), [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $chunk = [byte[]]::new(65536)
            while (($read = $stream.Read($chunk, 0, $chunk.Length)) -gt 0) {
                $plain.Write($chunk, 0, $read)
                if ($plain.Length -gt $script:RcaMaxJsonBytes) {
                    return (& $fail 'it decompresses to more than an export holds')
                }
            }
        }
        finally {
            $stream.Dispose()
        }
        $document = [System.Text.Encoding]::UTF8.GetString($plain.ToArray()) | ConvertFrom-Json -AsHashtable
    }
    catch {
        return (& $fail 'it doesn''t decompress to JSON')
    }
    if ($document -isnot [System.Collections.IDictionary] -or [string]$document['kind'] -cne 'ContosoCare.RcaEvidence' -or -not (Test-DemoRcaInteger -Value $document['version'] -Minimum 1 -Maximum 1) -or [string]$document['documentId'] -cne $id) {
        return (& $fail 'it isn''t an evidence document of version 1 with its own ID (run ./scripts/deploy.ps1, which updates the runner and the scripts together)')
    }
    return [pscustomobject]@{ Ok = $true; Why = ''; Document = $document }
}

function Get-DemoRcaCoverage {
    # The rca_coverage rows of a parsed evidence document (rca/history-tables.json): Target, Captured, Gaps, StartUtc, and
    # EndUtc, the strings and times decoded (rca/README.md, The evidence document). Pure. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [AllowNull()]
        [System.Collections.IDictionary] $Document
    )

    if ($null -eq $Document) {
        return @()
    }
    $strings = @($Document['strings'])
    $epoch = ConvertTo-DemoUtcDateTime -Value $Document['epochUtc']
    $table = $Document['tables']
    if ($table -is [System.Collections.IDictionary]) {
        $table = $table['rca_coverage']
    }
    if ($null -eq $epoch -or $table -isnot [System.Collections.IDictionary] -or -not (Test-DemoRcaInteger -Value $table['rows'] -Minimum 0 -Maximum 20000)) {
        return @()
    }
    $columns = $table['columns']
    if ($columns -isnot [System.Collections.IDictionary]) {
        return @()
    }
    $value = {
        param([string] $Column, [int] $Row)
        $values = $columns[$Column]
        if ($values -isnot [System.Collections.IList] -or $Row -ge $values.Count) {
            return $null
        }
        return $values[$Row]
    }
    $text = {
        param([string] $Column, [int] $Row)
        $at = & $value $Column $Row
        if (-not (Test-DemoRcaInteger -Value $at -Minimum 0 -Maximum ($strings.Count - 1))) {
            return ''
        }
        return [string]$strings[[int]$at]
    }
    $time = {
        param([string] $Column, [int] $Row)
        $at = & $value $Column $Row
        if ($null -eq $at -or $at -isnot [ValueType] -or $at -is [bool]) {
            return $null
        }
        return $epoch.AddMilliseconds([double]$at)
    }
    $rows = for ($row = 0; $row -lt [int]$table['rows']; $row++) {
        [pscustomobject]@{
            Target   = (& $text 'target' $row)
            Captured = ((& $value 'captured' $row) -eq $true)
            Gaps     = (& $text 'gaps' $row)
            StartUtc = (& $time 'window_start_utc' $row)
            EndUtc   = (& $time 'window_end_utc' $row)
        }
    }
    return @($rows)
}

function Get-DemoRcaCaptureResult {
    <#
    .SYNOPSIS
    The <prefix>.RCA.CAPTURE.<target> results of an export (ADR 0031), as the runbook's RCA.CAPTURE.<target> lines say them:
    for each target the documents cover, Pass when the observer captured its whole window, otherwise a Warning with the
    gaps it recorded (rca_coverage: what wasn't captured, and why); for each target whose VM's export failed, a Warning that
    says why. A VM without a runner, or one that isn't running, adds none. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Document = @(),

        [AllowEmptyCollection()]
        [object[]] $ExportHost = @(),

        [Parameter(Mandatory)]
        [ValidateSet('STOP', 'DEPLOY', 'FABRIC')]
        [string] $CheckPrefix
    )

    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $rows = @(foreach ($item in $Document) { Get-DemoRcaCoverage -Document $item })
    $results = foreach ($target in $script:RcaTargets) {
        $checkId = '{0}.RCA.CAPTURE.{1}' -f $CheckPrefix, $target.ToUpperInvariant().Replace('-', '_')
        $resultTarget = if ($target -like 'T4*') { 'T4' } else { $target }
        $mine = @($rows | Where-Object { $_.Target -ceq $target })
        if ($mine.Count -gt 0) {
            $starts = @($mine | Where-Object { $null -ne $_.StartUtc } | ForEach-Object { $_.StartUtc } | Sort-Object)
            $ends = @($mine | Where-Object { $null -ne $_.EndUtc } | ForEach-Object { $_.EndUtc } | Sort-Object)
            $span = ''
            if ($starts.Count -gt 0 -and $ends.Count -gt 0) {
                $span = ' from {0} to {1} UTC' -f $starts[0].ToString('HH:mm', $invariant), $ends[-1].ToString('HH:mm', $invariant)
            }
            $gaps = @($mine | ForEach-Object { ([string]$_.Gaps) -split '\r?\n' } | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
            $notCaptured = @($mine | Where-Object { -not $_.Captured }).Count
            $evidence = [ordered]@{ target = $target; rows = $mine.Count; notCaptured = $notCaptured; gaps = $gaps.Count }
            if ($notCaptured -eq 0 -and $gaps.Count -eq 0) {
                New-DemoResult -CheckId $checkId -Area 'workload' -Target $resultTarget -Status 'Pass' -Message ('{0}: the RCA observer captured{1}.' -f $target, $span) -Evidence $evidence
                continue
            }
            $said = @($gaps | Select-Object -First 3) -join ' '
            if (-not $said) {
                $said = 'the observer didn''t run for the whole window.'
            }
            $head = if ($notCaptured -eq $mine.Count) { '{0}: not captured{1}:' -f $target, $span } else { '{0}: captured{1}, with gaps:' -f $target, $span }
            New-DemoResult -CheckId $checkId -Area 'workload' -Target $resultTarget -Status 'Warning' -Message ('{0} {1}' -f $head, $said) -Evidence $evidence -Remediation 'Each gap says what wasn''t captured and why; docs/troubleshooting.md, "The Incident RCA''s capture", has the fixes.'
            continue
        }
        $owner = @($ExportHost | Where-Object { @($_.Targets) -contains $target }) | Select-Object -First 1
        if ($null -eq $owner -or [string]$owner.Outcome -in 'Exported', 'Partial', 'Nothing', 'NoRunner', 'NotRunning', '') {
            continue
        }
        $fix = 'What the observer captured stays on the VM (the runner keeps it 7 days), and the next history save exports it.'
        if ([string]$owner.Outcome -in 'OldRunner', 'OldBundle') {
            $fix = 'Run ./scripts/deploy.ps1, which updates the runner and its bootstrap bundle on the VMs.'
        }
        New-DemoResult -CheckId $checkId -Area 'workload' -Target $resultTarget -Status 'Warning' -Message ('{0}: not exported. {1}' -f $target, [string]$owner.Message) -Evidence ([ordered]@{ target = $target; vm = [string]$owner.Vm; outcome = [string]$owner.Outcome }) -Remediation $fix -DocUrl $script:RcaRunCommandDoc
    }
    return @($results)
}

function Get-DemoRcaRunCommandRoom {
    <#
    .SYNOPSIS
    How many managed Run Commands the export may add on a VM: Azure takes 25 per VM, and every one it lists counts, one it's
    deleting included. Earlier exports' DbHubDemo-Rca-* that have finished, or are more than an hour old
    (Test-DemoRunCommandFinished), are deleted first, without waiting: their instance view holds evidence. Returns -1 when
    the VM's Run Commands couldn't be listed. Internal.
    https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/list-by-virtual-machine
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $apiVersion = Get-DemoRunCommandApiVersion
    $base = Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName (Get-DemoResourceGroupName -Config $Config) -VmName $VmName
    $list = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('{0}?api-version={1}&$expand=instanceView' -f $base, $apiVersion)) -AllowFailure
    if ($list.ExitCode -ne 0) {
        return -1
    }
    try {
        $parsed = if ([string]::IsNullOrWhiteSpace([string]$list.StdOut)) { $null } else { [string]$list.StdOut | ConvertFrom-Json -Depth 32 }
    }
    catch {
        return -1
    }
    $values = Get-DemoMemberValue -InputObject $parsed -Name 'value'
    $count = 0
    foreach ($item in @($values)) {
        if ($null -eq $item) {
            continue
        }
        $count++
        $name = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
        if (-not $name.StartsWith($script:RcaRunCommandPrefix, [System.StringComparison]::Ordinal) -or $name -notmatch '^[A-Za-z0-9-]{1,64}$') {
            continue
        }
        $properties = Get-DemoMemberValue -InputObject $item -Name 'properties'
        $execution = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'instanceView') -Name 'executionState')
        if ([string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState') -ne 'Deleting' -and (Test-DemoRunCommandFinished -Name $name -ExecutionState $execution -NowUtc (Get-DemoUtcNow))) {
            $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', ('{0}/{1}?api-version={2}' -f $base, $name, $apiVersion)) -AllowFailure
        }
    }
    return [int][System.Math]::Max(0, 25 - $count)
}

function Send-DemoRcaRunCommand {
    <#
    .SYNOPSIS
    Creates one of the export's managed Run Commands without waiting for its script: the VM-side control's Rca action
    (Get-DemoWorkloadControlScript) with -Request, through 'az rest' (Virtual Machine Run Commands - Create Or Update, whose
    operation it doesn't follow), the body in a file in -Directory. A conflict (an extension a policy installs) is retried
    at most 3 times. Returns '' when Azure accepted it, otherwise its error. Internal.
    https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/create-or-update
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $VmName,

        [Parameter(Mandatory)]
        [ValidatePattern('^DbHubDemo-Rca-[A-Za-z0-9-]{1,48}$')]
        [string] $Name,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Request,

        [ValidateRange(60, 1800)]
        [int] $TimeoutSeconds = 720,

        [Parameter(Mandatory)]
        [string] $Directory
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $url = '{0}/{1}?api-version={2}' -f (Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName (Get-DemoResourceGroupName -Config $Config) -VmName $VmName), $Name, (Get-DemoRunCommandApiVersion)
    $body = [ordered]@{
        location   = [string]$Config['location']
        properties = [ordered]@{
            source                          = [ordered]@{ script = (Get-DemoWorkloadControlScript -Action 'Rca' -Request $Request) }
            asyncExecution                  = $false
            treatFailureAsDeploymentFailure = $false
            timeoutInSeconds                = $TimeoutSeconds
        }
    }
    $path = Write-DemoPrivateFile -Directory $Directory -Name ('{0}.json' -f $Name) -Content ($body | ConvertTo-Json -Depth 6 -Compress)
    try {
        $put = Invoke-DemoAzWithConflictRetry -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'put', '--url', $url, '--body', "@$path") -Label ('{0}: {1}' -f $VmName, $Name) -MaxConflictRetries 3 -TimeoutSeconds 120
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    if ($put.ExitCode -eq 0) {
        return ''
    }
    $text = (Protect-DemoText -Text ([string]$put.StdErr)).Trim() -replace '\s+', ' '
    if (-not $text) {
        $text = 'az ended with exit code {0}' -f $put.ExitCode
    }
    return $text.Substring(0, [System.Math]::Min(300, $text.Length))
}

function Invoke-DemoRcaExport {
    <#
    .SYNOPSIS
    The runner's evidence export on the demo's VMs through managed Run Commands, with the operator's sign-in (ADR 0031): on
    each VM in -ExportHost that the export reaches, one 'rca export' (with -Final, a session's last), then one 'rca part' for
    each part of each document it lists, and of each document an earlier save didn't take (-Pending). Returns Hosts (Vm,
    Targets, Outcome, Message), Lines (each document's part lines, by document ID, for those fetched whole), Vms (their VMs),
    Pending (references of the documents not fetched whole, with their VMs), and Leftover (Run Commands Azure didn't delete
    on the T2 host). Internal.

    .DESCRIPTION
    As the control's runbook does it (Invoke-DbHubRcaExport):
    - Each Run Command is the VM-side control's Rca action, created with 'az rest' (Send-DemoRcaRunCommand), read from its
      instance view (the last 4 KB of output, which holds the result line and the runner's one line), and deleted without
      waiting once it's read. Names: DbHubDemo-Rca-<vm>-x-<yyyyMMddHHmmss> for the export, DbHubDemo-Rca-<vm>-<ddpp>-<time>
      for a part, so status.ps1 lists one that stays (STATUS.RUNCOMMANDS), and the next export deletes it
      (Get-DemoRcaRunCommandRoom).
    - On sqlvm01, up to -Parallelism parts at a time, within the room the VM has under Azure's 25. On the T2 host, one Run
      Command at a time, each gone before the next one goes (R871: there, parallel Run Commands' deletes failed, and the
      host's next start didn't get its goal state). A delete Azure doesn't finish in -HostDeleteWaitSeconds is asked for once
      more; after a second one, the host gets no more parts in this export, and the rest wait for the next.
    - At -Minutes it stops: what wasn't read by then stays on the VM, and its document is in Pending.
    Outcomes per VM: Exported, Partial, Nothing, OldRunner, OldBundle, Failed, TimedOut, NoRoom, and the -ExportHost's own
    NoRunner and NotRunning.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $ExportHost,

        [switch] $Final,

        [AllowEmptyCollection()]
        [object[]] $Pending = @(),

        [ValidateRange(1, 60)]
        [int] $Minutes = 8,

        [ValidateRange(1, 20)]
        [int] $Parallelism = 10,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 10,

        [ValidateRange(0, 1800)]
        [int] $HostDeleteWaitSeconds = 300,

        [ValidateRange(60, 900)]
        [int] $ExportSeconds = 600,

        [ValidateRange(30, 900)]
        [int] $PartSeconds = 120
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroup = Get-DemoResourceGroupName -Config $Config
    $apiVersion = Get-DemoRunCommandApiVersion
    $startedUtc = Get-DemoUtcNow
    $stamp = $startedUtc.ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $deadline = $startedUtc.AddMinutes($Minutes)
    $urlOf = { param([string] $Vm, [string] $Name) '{0}/{1}?api-version={2}' -f (Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroup -VmName $Vm), $Name, $apiVersion }
    $hosts = [System.Collections.Generic.List[object]]::new()
    $work = [System.Collections.Generic.List[object]]::new()
    $documents = [ordered]@{}
    $pendingOut = [System.Collections.Generic.List[object]]::new()
    $leftover = [System.Collections.Generic.List[string]]::new()
    $addDocument = {
        param([object] $HostState, [AllowNull()] [System.Collections.IDictionary] $Reference)
        $id = if ($null -ne $Reference) { [string]$Reference['documentId'] } else { '' }
        if (-not $id -or $documents.Contains($id)) {
            return
        }
        $HostState.Sequence++
        $documents[$id] = [pscustomobject]@{ Reference = $Reference; Vm = $HostState.Vm; Sequence = $HostState.Sequence; Lines = [string[]]::new([int]$Reference['parts']); Gone = $false }
        for ($part = 1; $part -le [int]$Reference['parts']; $part++) {
            $HostState.Queue.Add([pscustomobject]@{ DocumentId = $id; Part = $part })
        }
    }
    # Deletes a Run Command once it's read, or its time is up, without waiting; deleting one whose script still runs stops
    # it. On the T2 host, its slot stays taken until Azure no longer lists it.
    $remove = {
        param([object] $HostState, [string] $Name)
        $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', (& $urlOf $HostState.Vm $Name)) -AllowFailure
        if ($HostState.OneAtATime -and $HostDeleteWaitSeconds -gt 0) {
            $HostState.Deleting.Add([pscustomobject]@{ Name = $Name; SinceUtc = (Get-DemoUtcNow); Round = 1 })
        }
        else {
            $HostState.Free++
        }
    }
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-rca'
    $finished = $false
    try {
        foreach ($entry in @($ExportHost)) {
            $hostState = [pscustomobject]@{
                Vm = [string]$entry.Vm; Targets = @($entry.Targets); OneAtATime = [bool]$entry.OneAtATime; Outcome = [string]$entry.Outcome; Message = [string]$entry.Message
                Export = ''; ExportDone = $true; Queue = [System.Collections.Generic.List[object]]::new(); InFlight = [System.Collections.Generic.List[object]]::new()
                Deleting = [System.Collections.Generic.List[object]]::new(); Free = 0; Sequence = 0; Blocked = $false
            }
            $hosts.Add($hostState)
            $earlier = @($Pending | Where-Object { $null -ne $_ -and [string](Get-DemoMemberValue -InputObject $_ -Name 'vm') -eq $hostState.Vm })
            if ($hostState.Outcome) {
                foreach ($item in $earlier) {
                    $pendingOut.Add($item)
                }
                continue
            }
            $room = Get-DemoRcaRunCommandRoom -Config $Config -VmName $hostState.Vm
            $refused = ''
            if ($room -ge 2) {
                $name = '{0}{1}-x-{2}' -f $script:RcaRunCommandPrefix, $hostState.Vm, $stamp
                $request = [ordered]@{ command = 'export'; sessionId = ''; final = [bool]$Final; timeoutSeconds = $ExportSeconds }
                $refused = Send-DemoRcaRunCommand -Config $Config -VmName $hostState.Vm -Name $name -Request $request -TimeoutSeconds ($ExportSeconds + 120) -Directory $directory
            }
            if ($room -lt 2 -or $refused) {
                $hostState.Outcome = if ($room -ge 0 -and $room -lt 2) { 'NoRoom' } else { 'Failed' }
                $hostState.Message = if ($room -lt 0) { '{0}''s Run Commands couldn''t be listed, so nothing was exported from it.' -f $hostState.Vm } elseif ($room -lt 2) { '{0} already has 24 or 25 managed Run Commands, the most a VM takes, so nothing was exported from it.' -f $hostState.Vm } else { 'Azure didn''t accept the export''s Run Command on {0}: {1}' -f $hostState.Vm, $refused }
                foreach ($item in $earlier) {
                    $pendingOut.Add($item)
                }
                continue
            }
            $hostState.Export = $name
            $hostState.ExportDone = $false
            $hostState.Free = $room - 1
            foreach ($item in $earlier) {
                & $addDocument $hostState $item
            }
            $work.Add($hostState)
        }

        while ($work.Count -gt 0) {
            $busy = $false
            $late = (Get-DemoUtcNow) -ge $deadline
            foreach ($hostState in $work) {
                if (-not $hostState.ExportDone) {
                    $view = Get-DemoRunCommandState -SubscriptionId $subscriptionId -Url (& $urlOf $hostState.Vm $hostState.Export)
                    $ended = $view.Found -and ($view.ExecutionState -in $script:RcaTerminalStates -or $view.ProvisioningState -eq 'Failed')
                    if ($ended) {
                        $hostState.ExportDone = $true
                        & $remove $hostState $hostState.Export
                        $out = ConvertFrom-DemoRcaRunOutput -Output $view.Output
                        if ($out.OldBundle) {
                            $hostState.Outcome = 'OldBundle'
                            $hostState.Message = '{0}''s bootstrap bundle predates the RCA export, so nothing was exported from it; ./scripts/deploy.ps1 sends the current one.' -f $hostState.Vm
                        }
                        elseif ($out.OldRunner -or $out.Status -eq 'Not supported') {
                            $hostState.Outcome = 'OldRunner'
                            $hostState.Message = '{0}''s workload runner predates the RCA export, so nothing was exported from it; ./scripts/deploy.ps1 updates it.' -f $hostState.Vm
                        }
                        elseif ($out.Status -eq 'Not selected') {
                            $hostState.Outcome = 'Nothing'
                            $hostState.Message = '{0}: {1}' -f $hostState.Vm, $out.Message
                        }
                        elseif ($out.Status -eq 'Pass') {
                            $index = ConvertFrom-DemoRcaExportIndex -Line $out.Line
                            if ($index.Valid) {
                                $hostState.Outcome = if (@($index.Documents).Count -gt 0) { 'Exported' } else { 'Nothing' }
                                $hostState.Message = '{0}: nothing new was captured since the last export.' -f $hostState.Vm
                                foreach ($reference in @($index.Documents)) {
                                    & $addDocument $hostState (ConvertTo-DemoRcaReference -InputObject $reference -Vm $hostState.Vm -ExportedUtc (Get-DemoUtcNow))
                                }
                            }
                            else {
                                $hostState.Outcome = 'Failed'
                                $hostState.Message = '{0}''s export ran, but {1}.' -f $hostState.Vm, $index.Why
                            }
                        }
                        else {
                            $hostState.Outcome = 'Failed'
                            $detail = if ($out.Status) { $out.Message } else { 'its Run Command ended {0} with no result line' -f $view.ExecutionState }
                            $hostState.Message = '{0}''s export failed: {1}' -f $hostState.Vm, $detail
                        }
                    }
                    elseif ($late -or $view.NotFound) {
                        $hostState.ExportDone = $true
                        if (-not $view.NotFound) {
                            & $remove $hostState $hostState.Export
                        }
                        $hostState.Outcome = if ($view.NotFound) { 'Failed' } else { 'TimedOut' }
                        $hostState.Message = if ($view.NotFound) { '{0}''s export Run Command was gone before it ended, so nothing was exported from it.' -f $hostState.Vm } else { '{0}''s export didn''t end in time, so what its observer captured stays on it until the next export.' -f $hostState.Vm }
                    }
                }
                foreach ($item in @($hostState.Deleting.ToArray())) {
                    $read = Get-DemoRunCommandState -SubscriptionId $subscriptionId -Url (& $urlOf $hostState.Vm $item.Name)
                    if ($read.NotFound) {
                        $null = $hostState.Deleting.Remove($item)
                        $hostState.Free++
                        continue
                    }
                    if (((Get-DemoUtcNow) - $item.SinceUtc).TotalSeconds -lt $HostDeleteWaitSeconds) {
                        continue
                    }
                    if ($item.Round -lt 2) {
                        Write-DemoLog -Level Warning -Message ('{0}: Azure didn''t delete the Run Command {1} in {2} seconds, so it''s deleted once more.' -f $hostState.Vm, $item.Name, $HostDeleteWaitSeconds)
                        $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', (& $urlOf $hostState.Vm $item.Name)) -AllowFailure
                        $item.Round = 2
                        $item.SinceUtc = Get-DemoUtcNow
                        continue
                    }
                    $null = $hostState.Deleting.Remove($item)
                    $hostState.Blocked = $true
                    $leftover.Add(('{0}/{1}' -f $hostState.Vm, $item.Name))
                }
                foreach ($flight in @($hostState.InFlight.ToArray())) {
                    $view = Get-DemoRunCommandState -SubscriptionId $subscriptionId -Url (& $urlOf $hostState.Vm $flight.Name)
                    $ended = $view.Found -and ($view.ExecutionState -in $script:RcaTerminalStates -or $view.ProvisioningState -eq 'Failed')
                    if (-not $ended -and -not $late -and -not $view.NotFound) {
                        continue
                    }
                    $null = $hostState.InFlight.Remove($flight)
                    if ($view.NotFound) {
                        $hostState.Free++
                        continue
                    }
                    & $remove $hostState $flight.Name
                    if (-not $ended) {
                        continue
                    }
                    $document = $documents[$flight.DocumentId]
                    $out = ConvertFrom-DemoRcaRunOutput -Output $view.Output
                    if ($out.Status -eq 'Pass' -and (Test-DemoRcaPartLine -Line $out.Line -Document $document.Reference -Part $flight.Part)) {
                        $document.Lines[$flight.Part - 1] = $out.Line
                    }
                    elseif ($out.Status -eq 'Fail' -and $out.Message -match 'exit code 1\b') {
                        # The runner says the document or the part doesn't exist (rca/README.md, The runner's commands).
                        $document.Gone = $true
                    }
                }
                $limit = if ($hostState.OneAtATime) { 1 } else { $Parallelism }
                while (-not $late -and -not $hostState.Blocked -and $hostState.Queue.Count -gt 0 -and $hostState.Free -gt 0 -and ($hostState.InFlight.Count + $hostState.Deleting.Count + [int]($hostState.OneAtATime -and -not $hostState.ExportDone)) -lt $limit) {
                    $item = $hostState.Queue[0]
                    $hostState.Queue.RemoveAt(0)
                    $document = $documents[$item.DocumentId]
                    if ($document.Gone) {
                        continue
                    }
                    $name = '{0}{1}-{2:d2}{3:d2}-{4}' -f $script:RcaRunCommandPrefix, $hostState.Vm, $document.Sequence, $item.Part, $stamp
                    $request = [ordered]@{ command = 'part'; documentId = $item.DocumentId; part = $item.Part; timeoutSeconds = $PartSeconds }
                    if (-not (Send-DemoRcaRunCommand -Config $Config -VmName $hostState.Vm -Name $name -Request $request -TimeoutSeconds ($PartSeconds + 60) -Directory $directory)) {
                        $hostState.InFlight.Add([pscustomobject]@{ Name = $name; DocumentId = $item.DocumentId; Part = $item.Part })
                        $hostState.Free--
                    }
                }
                if (-not $hostState.ExportDone -or $hostState.InFlight.Count -gt 0 -or ($hostState.Queue.Count -gt 0 -and -not $late -and -not $hostState.Blocked)) {
                    $busy = $true
                }
            }
            if (-not $busy -or $late) {
                break
            }
            Start-Sleep -Seconds $PollSeconds
        }
        $finished = $true
    }
    finally {
        Remove-DemoPrivateDirectory -Path $directory -Confirm:$false | Out-Null
        if (-not $finished -and -not (Test-DemoRunCancelled)) {
            # An error stopped the export: what it still has on a VM goes, so no part of the evidence stays in an instance
            # view. A stopped run (Ctrl+C) leaves them; the next export deletes them (Get-DemoRcaRunCommandRoom).
            foreach ($hostState in $work) {
                foreach ($name in @(@($hostState.InFlight | ForEach-Object { $_.Name }) + @(if (-not $hostState.ExportDone) { $hostState.Export }))) {
                    $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', (& $urlOf $hostState.Vm $name)) -AllowFailure
                }
            }
        }
    }

    $lines = [ordered]@{}
    $vms = @{}
    $goneBy = @{}
    foreach ($id in @($documents.Keys)) {
        $document = $documents[$id]
        if (@($document.Lines | Where-Object { [string]::IsNullOrEmpty($_) }).Count -eq 0) {
            $lines[$id] = [string[]]$document.Lines
            $vms[$id] = $document.Vm
        }
        elseif ($document.Gone) {
            $goneBy[$document.Vm] = 1 + [int]$goneBy[$document.Vm]
        }
        else {
            $pendingOut.Add($document.Reference)
        }
    }
    $answers = foreach ($hostState in $hosts) {
        $left = @($pendingOut | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'vm') -eq $hostState.Vm }).Count
        $whole = @($documents.Values | Where-Object { $_.Vm -eq $hostState.Vm -and $lines.Contains([string]$_.Reference['documentId']) })
        $gone = [int]$goneBy[$hostState.Vm]
        $outcome = $hostState.Outcome
        $message = $hostState.Message
        if ($outcome -eq 'Nothing' -and $whole.Count -gt 0) {
            # Nothing new, but an earlier save's documents fetched again.
            $outcome = 'Exported'
        }
        if ($outcome -in 'Exported', 'Nothing' -and ($left -gt 0 -or $gone -gt 0)) {
            $outcome = 'Partial'
        }
        if ($outcome -in 'Exported', 'Partial') {
            $partCount = 0
            foreach ($document in $whole) {
                $partCount += [int]$document.Reference['parts']
            }
            $message = '{0}: {1} document(s) in {2} part(s).' -f $hostState.Vm, $whole.Count, $partCount
            if ($left -gt 0) {
                $message = '{0} {1} document(s) weren''t fetched whole in time; they stay on {2} for the next save.' -f $message, $left, $hostState.Vm
            }
            if ($gone -gt 0) {
                $message = '{0} {1} document(s) weren''t on {2} any more (the runner keeps an exported document 7 days).' -f $message, $gone, $hostState.Vm
            }
            if ($hostState.Blocked) {
                $message = '{0} Azure didn''t delete a Run Command on {1} twice, so it got no more parts (R871).' -f $message, $hostState.Vm
            }
        }
        [pscustomobject]@{ Vm = $hostState.Vm; Targets = $hostState.Targets; Outcome = $outcome; Message = $message }
    }
    return [pscustomobject]@{ Hosts = @($answers); Lines = $lines; Vms = $vms; Pending = $pendingOut.ToArray(); Leftover = $leftover.ToArray() }
}

function Get-DemoRcaPendingPath {
    # The pending list of an environment's RCA evidence: out/history-pending/rca-pending-<resource group>.json. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $Directory = (Join-Path -Path $script:RepoRoot -ChildPath 'out/history-pending')
    )

    return (Join-Path -Path $Directory -ChildPath ('rca-pending-{0}.json' -f (Get-DemoResourceGroupName -Config $Config)))
}

function Read-DemoRcaPending {
    <#
    .SYNOPSIS
    The RCA evidence documents an earlier history save didn't take (Save-DemoRcaPending): Path, Found, Documents (their
    references, each with its VM), and Expired (how many are past the 7 days the runner keeps an exported document, which
    the next save can't fetch any more). A file that can't be read lists none. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $Directory = (Join-Path -Path $script:RepoRoot -ChildPath 'out/history-pending')
    )

    $path = Get-DemoRcaPendingPath -Config $Config -Directory $Directory
    $answer = [pscustomobject]@{ Path = $path; Found = $false; Documents = @(); Expired = 0 }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $answer
    }
    $answer.Found = $true
    try {
        $file = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
    }
    catch {
        Write-DemoLog -Level Warning -Message ('{0} isn''t JSON, so the RCA evidence it listed is left out: {1}' -f $path, $_.Exception.Message)
        return $answer
    }
    if ($file -isnot [System.Collections.IDictionary] -or [string]$file['kind'] -cne 'DbHubDemo.RcaPending' -or $file['documents'] -isnot [System.Collections.IList]) {
        return $answer
    }
    $cutoff = (Get-DemoUtcNow).AddDays(-$script:RcaKeepDays)
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $file['documents']) {
        $reference = ConvertTo-DemoRcaReference -InputObject $item
        if ($null -eq $reference) {
            continue
        }
        if ((ConvertTo-DemoUtcDateTime -Value $reference['exportedUtc']) -lt $cutoff) {
            $answer.Expired++
            continue
        }
        $kept.Add($reference)
    }
    $answer.Documents = $kept.ToArray()
    return $answer
}

function New-DemoRcaEvidenceDocument {
    # One RCA_EVIDENCE document (rca/transport.schema.json, parameter) as compact JSON: the part lines, the session ($null
    # for the scripts' saves, whose documents any run writes), and the export's status and message. Pure. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds JSON in memory only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string[]] $Line,

        [ValidateSet('Pass', 'Fail', 'Warning', 'Manual action required', 'Not supported', 'Not selected')]
        [string] $Status = 'Pass',

        [AllowEmptyString()]
        [string] $Message = ''
    )

    if ($Message.Length -gt 500) {
        $Message = $Message.Substring(0, 497) + '...'
    }
    return (ConvertTo-Json -InputObject ([ordered]@{ kind = 'ContosoCare.RcaEvidenceParts'; version = 1; sessionId = $null; parts = @($Line); status = $Status; message = $Message }) -Depth 4 -Compress)
}

function Invoke-DemoRcaScriptExport {
    <#
    .SYNOPSIS
    The Incident RCA's evidence for a history save by the operator's scripts (ADR 0031): runs the export on the VMs
    (Invoke-DemoRcaExport, with -Final at a session's end), with the documents an earlier save didn't take
    (Read-DemoRcaPending), checks each document fetched whole (Expand-DemoRcaDocument), and returns Evidence (one
    RCA_EVIDENCE document, compact JSON, at most 64 parts and 262,144 bytes, whole documents only; '' when there's none),
    Documents (the references it holds), Pending (those left for the next save), PendingFound, and Results
    (<prefix>.RCA.EXPORT and the <prefix>.RCA.CAPTURE.<target> results). Never throws, except for a stop of the run.
    Internal.

    .DESCRIPTION
    The scripts export with '--session none': a document of no session goes into any run's history, and the control's
    runbook takes it with its session too (rca/README.md, RCA_EVIDENCE). A document fetched whole that doesn't decode is
    reported and dropped: fetching it again gives the same bytes. <prefix>.RCA.EXPORT is Pass when documents were exported,
    Not selected when there were none, and a Warning when a VM's export didn't work (a runner or bootstrap bundle from before
    the export, a failure, no room, a time-out), a document didn't decode or wasn't fetched whole, or one is past the limits.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('STOP', 'DEPLOY', 'FABRIC')]
        [string] $CheckPrefix,

        [switch] $Final,

        [AllowNull()]
        [object] $State = $null,

        [AllowNull()]
        [System.Collections.IDictionary] $Power = $null,

        [ValidateRange(1, 60)]
        [int] $Minutes = 8,

        [string] $PendingDirectory = (Join-Path -Path $script:RepoRoot -ChildPath 'out/history-pending'),

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 10
    )

    $checkId = '{0}.RCA.EXPORT' -f $CheckPrefix
    $answer = [pscustomobject]@{ Evidence = ''; Documents = @(); Pending = @(); PendingFound = $false; Results = @() }
    # What an earlier save didn't take stays listed whatever happens here (Read-DemoRcaPending never throws).
    $earlier = Read-DemoRcaPending -Config $Config -Directory $PendingDirectory
    $answer.PendingFound = $earlier.Found
    $answer.Pending = @($earlier.Documents)
    try {
        if ($null -eq $State) {
            $State = Get-DemoDeploymentState -Config $Config
        }
        if ($null -eq $Power) {
            $Power = @{}
            foreach ($vm in @('sqlvm01', (Get-DemoHostVmName -Config $Config))) {
                $Power[$vm] = Get-DemoVmPowerState -SubscriptionId ([string]$Config['subscriptionId']) -ResourceGroupName (Get-DemoResourceGroupName -Config $Config) -VmName $vm
            }
        }
        $exportHosts = @(Get-DemoRcaExportHost -Config $Config -State $State -Power $Power)
        $run = Invoke-DemoRcaExport -Config $Config -ExportHost $exportHosts -Final:$Final -Pending @($earlier.Documents) -Minutes $Minutes -PollSeconds $PollSeconds
    }
    catch {
        if ($_.Exception -is [System.Management.Automation.PipelineStoppedException] -or ($_.Exception -is [System.OperationCanceledException] -and (Test-DemoRunCancelled))) {
            throw
        }
        $answer.Results = @(New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('The RCA evidence wasn''t exported: {0}' -f (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'What the observer captured stays on the VMs (the runner keeps it 7 days), and the next history save exports it.' -DocUrl $script:RcaRunCommandDoc)
        return $answer
    }

    # Each document fetched whole, checked, in the order the export listed them; whole documents only, at most 64 parts.
    $notes = [System.Collections.Generic.List[string]]::new()
    $parsed = [System.Collections.Generic.List[object]]::new()
    $parts = [System.Collections.Generic.List[string]]::new()
    $taken = [System.Collections.Generic.List[object]]::new()
    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($item in @($run.Pending)) {
        $pending.Add($item)
    }
    $overLimit = 0
    foreach ($id in @($run.Lines.Keys)) {
        $lines = [string[]]$run.Lines[$id]
        $expanded = Expand-DemoRcaDocument -Line $lines
        if (-not $expanded.Ok) {
            $notes.Add(('{0} was skipped: {1}.' -f $id, $expanded.Why))
            continue
        }
        $reference = ConvertTo-DemoRcaReference -InputObject ([ordered]@{ documentId = $id; parts = $lines.Count; sha256 = $lines[0].Split(' ')[4] }) -Vm ([string]$run.Vms[$id])
        $grown = @($parts) + $lines
        if ($parts.Count + $lines.Count -gt $script:RcaMaxParts -or [System.Text.Encoding]::UTF8.GetByteCount((New-DemoRcaEvidenceDocument -Line $grown -Message ('x' * 500))) -gt $script:RcaEvidenceFileBytes) {
            $overLimit++
            $pending.Add($reference)
            continue
        }
        foreach ($text in $lines) {
            $parts.Add($text)
        }
        $taken.Add($reference)
        $parsed.Add($expanded.Document)
    }

    $hosts = @($run.Hosts)
    $troubled = @($hosts | Where-Object { [string]$_.Outcome -in 'OldRunner', 'OldBundle', 'Failed', 'TimedOut', 'NoRoom', 'Partial' })
    $status = 'Pass'
    if ($troubled.Count -gt 0 -or $notes.Count -gt 0 -or $earlier.Expired -gt 0) {
        $status = 'Warning'
    }
    elseif ($taken.Count -eq 0) {
        $status = 'Not selected'
    }
    $message = if ($taken.Count -gt 0) {
        '{0} RCA evidence document(s), {1} part(s), for the history run.' -f $taken.Count, $parts.Count
    }
    elseif (@($hosts | Where-Object { [string]$_.Outcome -ne 'NoRunner' }).Count -eq 0) {
        'No workload runner was deployed, so there''s no RCA evidence to export.'
    }
    elseif ($status -eq 'Not selected' -and @($hosts | Where-Object { [string]$_.Outcome -eq 'NotRunning' }).Count -eq 0) {
        'No new RCA evidence: the observer captured nothing since the last export.'
    }
    else {
        'No RCA evidence was exported.'
    }
    # What each VM said, except a VM without a runner, and one with nothing new when nothing came at all.
    $extra = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $hosts) {
        $outcome = [string]$item.Outcome
        if ([string]$item.Message -and $outcome -ne 'NoRunner' -and -not ($outcome -eq 'Nothing' -and $status -eq 'Not selected')) {
            $extra.Add([string]$item.Message)
        }
    }
    foreach ($note in $notes) {
        $extra.Add($note)
    }
    if ($overLimit -gt 0) {
        $extra.Add(('{0} document(s) are past the 64 parts one run takes; the next history save adds them.' -f $overLimit))
    }
    if ($earlier.Expired -gt 0) {
        $extra.Add(('{0} document(s) that an earlier save didn''t take are past the 7 days the runner keeps them, so they''re lost.' -f $earlier.Expired))
    }
    if ($extra.Count -gt 0) {
        $message = '{0} {1}' -f $message, ($extra -join ' ')
    }
    $message = Protect-DemoText -Text $message
    $fix = ''
    if ($status -eq 'Warning') {
        $fix = 'What wasn''t exported stays on the VMs (the runner keeps it 7 days), and the next history save (./scripts/stop-demo.ps1 -SaveHistory, deploy.ps1''s snapshot, or {0}) exports it.' -f $script:RcaRunAgain
        if (@($troubled | Where-Object { [string]$_.Outcome -in 'OldRunner', 'OldBundle' }).Count -gt 0) {
            $fix = 'Run ./scripts/deploy.ps1, which updates the runner and its bootstrap bundle on the VMs. {0}' -f $fix
        }
    }
    $evidence = [ordered]@{
        documents = @($taken | ForEach-Object { [string]$_['documentId'] })
        parts     = $parts.Count
        pending   = $pending.Count
        hosts     = @($hosts | ForEach-Object { '{0}: {1}' -f $_.Vm, $(if ($_.Outcome) { $_.Outcome } else { 'Exported' }) })
        leftover  = @($run.Leftover)
    }
    $results = [System.Collections.Generic.List[object]]::new()
    $results.Add((New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status $status -Message $message -Evidence $evidence -Remediation $fix -DocUrl $script:RcaRunCommandDoc))
    foreach ($item in (Get-DemoRcaCaptureResult -Document $parsed.ToArray() -ExportHost $hosts -CheckPrefix $CheckPrefix)) {
        $results.Add($item)
    }
    if ($parts.Count -gt 0) {
        $answer.Evidence = New-DemoRcaEvidenceDocument -Line $parts.ToArray() -Status $status -Message $message
    }
    $answer.Documents = $taken.ToArray()
    $answer.Pending = $pending.ToArray()
    $answer.Results = $results.ToArray()
    return $answer
}

function Send-DemoRcaEvidenceFile {
    <#
    .SYNOPSIS
    Stages one RCA_EVIDENCE document in the demo lakehouse's Files/rca/inbox for NB_DatabaseHub_LiveActivity's
    RCA_EVIDENCE_FILE (rca/README.md), through OneLake's ADLS Gen2 API with the operator's Storage token
    (Send-DemoOneLakeFile): the workspace role deploy gave them writes it, and nothing is granted. The name is
    <yyyyMMddTHHmmssZ>-script-<8 hex>.json, which the notebook's clean-up reads for its day-old sweep. Returns Path (''
    when it wasn't staged) and Error. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $Evidence
    )

    $workspaceId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')
    $lakehouseId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'lakehouseId')
    if ($workspaceId -notmatch $script:OneLakeGuidPattern -or $lakehouseId -notmatch $script:OneLakeGuidPattern) {
        return [pscustomobject]@{ Path = ''; Error = 'the demo lakehouse isn''t resolved' }
    }
    $size = [System.Text.Encoding]::UTF8.GetByteCount($Evidence)
    if ($size -gt $script:RcaEvidenceFileBytes) {
        return [pscustomobject]@{ Path = ''; Error = ('it''s {0:N0} bytes, more than the 262,144 the notebook reads' -f $size) }
    }
    $path = '{0}/{1}-script-{2}.json' -f $script:RcaInbox, (Get-DemoUtcNow).ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture), [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        $token = Get-DemoStorageToken -SubscriptionId ([string]$Config['subscriptionId'])
        $sent = Send-DemoOneLakeFile -WorkspaceId $workspaceId -LakehouseId $lakehouseId -Path $path -Content $Evidence -Token $token
    }
    catch {
        return [pscustomobject]@{ Path = ''; Error = (Protect-DemoText -Text $_.Exception.Message) }
    }
    if ([string]$sent.Status -ne 'Pass') {
        # A file it began to write goes, so nothing is left in Files/.
        $null = Remove-DemoRcaEvidenceFile -Config $Config -Path $path -Confirm:$false
        return [pscustomobject]@{ Path = ''; Error = [string]$sent.Error }
    }
    return [pscustomobject]@{ Path = $path; Error = '' }
}

function Remove-DemoRcaEvidenceFile {
    <#
    .SYNOPSIS
    Deletes a staged RCA_EVIDENCE_FILE (Path - Delete; one the notebook deleted already counts), then Files/rca/inbox and
    Files/rca when they're empty: a folder's delete without recurse leaves one that still holds a file, such as another
    run's. Returns $true when the file is gone. Never throws. Internal.
    https://learn.microsoft.com/rest/api/storageservices/datalakestoragegen2/path/delete
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $Path
    )

    if ($Path -cnotmatch $script:RcaEvidenceFilePattern -or -not $PSCmdlet.ShouldProcess($Path, 'Delete the staged RCA evidence')) {
        return $false
    }
    $workspaceId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')
    $lakehouseId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'lakehouseId')
    try {
        $token = Get-DemoStorageToken -SubscriptionId ([string]$Config['subscriptionId'])
        $deleted = Remove-DemoOneLakeFile -WorkspaceId $workspaceId -LakehouseId $lakehouseId -Path $Path -Token $token
        if ([string]$deleted.Status -ne 'Pass') {
            Write-DemoLog -Level Warning -Message ('The staged RCA evidence {0} wasn''t deleted ({1}); the notebook''s next run deletes it a day later at the latest, and the deployment notebook''s purge with Files/rca/inbox.' -f $Path, $deleted.Error)
            return $false
        }
        foreach ($folder in $script:RcaInbox, 'Files/rca') {
            $answer = Invoke-DemoOneLakeRequest -Method Delete -WorkspaceId $workspaceId -Path ('{0}/{1}' -f $lakehouseId.ToLowerInvariant(), $folder) -Query 'recursive=false' -Token $token
            if ($answer.StatusCode -notin 200, 202, 204, 404) {
                break
            }
        }
        return $true
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The staged RCA evidence {0} wasn''t deleted ({1}); the notebook''s next run deletes it a day later at the latest.' -f $Path, (Protect-DemoText -Text $_.Exception.Message))
        return $false
    }
}

function Invoke-DemoRcaNotebookRun {
    <#
    .SYNOPSIS
    Runs NB_DatabaseHub_LiveActivity on demand (Invoke-DemoFabricNotebookRun) with the RCA evidence staged as
    RCA_EVIDENCE_FILE (Send-DemoRcaEvidenceFile) when there's some and the workspace's copy of the notebook knows the
    parameter, and deletes the staged file once the job has ended (Remove-DemoRcaEvidenceFile). Returns Run (the run's
    record), RcaSent, RcaSaved (sent, and the run completed), RcaFile, and RcaNote (why it wasn't sent or saved). Internal.

    .DESCRIPTION
    - A copy of the notebook from before the Incident RCA (Test-DemoFabricNotebookParameter: Known, without the parameter)
      would ignore the file, so none is staged, and RcaNote says so; one whose definition can't be read gets it, as with
      POSTGRES_METRICS.
    - The file goes once the job has ended (Completed, Failed, Cancelled, Deduped), or when the run didn't start; a job that
      still runs reads it and deletes it itself, and the notebook's day-old sweep or the deployment notebook's purge takes
      one that nothing deleted.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Parameter,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [AllowEmptyString()]
        [string] $Evidence = '',

        [ValidateRange(1, 60)]
        [int] $TimeoutMinutes = 15,

        [System.Collections.IDictionary] $RunOption = @{}
    )

    $answer = [pscustomobject]@{ Run = $null; RcaSent = $false; RcaSaved = $false; RcaFile = ''; RcaNote = '' }
    if ($Evidence) {
        $workspaceId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')
        $knows = Test-DemoFabricNotebookParameter -WorkspaceId $workspaceId -Name 'NB_DatabaseHub_LiveActivity' -Parameter 'RCA_EVIDENCE_FILE' -Token $Token
        if ([bool]$knows.Known -and -not [bool]$knows.Has) {
            $answer.RcaNote = 'the workspace''s NB_DatabaseHub_LiveActivity is from before the Incident RCA (2026-11-20), so it would ignore it'
        }
        else {
            $staged = Send-DemoRcaEvidenceFile -Config $Config -Evidence $Evidence
            if ($staged.Path) {
                $Parameter['RCA_EVIDENCE_FILE'] = $staged.Path
                $answer.RcaSent = $true
                $answer.RcaFile = $staged.Path
            }
            else {
                $answer.RcaNote = 'it couldn''t be staged in the lakehouse ({0})' -f $staged.Error
            }
        }
    }
    $ended = $true
    try {
        $answer.Run = Invoke-DemoFabricNotebookRun -Config $Config -Name 'NB_DatabaseHub_LiveActivity' -Parameter $Parameter -Token $Token -TimeoutMinutes $TimeoutMinutes @RunOption
        $jobStatus = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $answer.Run -Name 'evidence') -Name 'status')
        $ended = [string]$answer.Run.status -ne 'Warning' -or $jobStatus -in 'Completed', 'Failed', 'Cancelled', 'Deduped'
    }
    finally {
        if ($answer.RcaFile -and $ended) {
            $null = Remove-DemoRcaEvidenceFile -Config $Config -Path $answer.RcaFile -Confirm:$false
        }
    }
    $answer.RcaSaved = $answer.RcaSent -and [string]$answer.Run.status -eq 'Pass'
    if ($answer.RcaSent -and -not $answer.RcaSaved) {
        $answer.RcaNote = if ($ended) { 'the history run didn''t complete' } else { 'the history run was still going when the wait ended' }
    }
    return $answer
}

function Save-DemoRcaPending {
    <#
    .SYNOPSIS
    After a history save by the scripts: keeps in out/history-pending/rca-pending-<resource group>.json the references of
    the RCA evidence documents the save didn't take (the export's Pending) or didn't confirm (its Documents, unless
    -Saved), so the next save fetches them again; the runner keeps an exported document for 7 days. Deletes the file once
    nothing is left. Returns <prefix>.RCA.PENDING, a Warning that says what's kept, why, and what adds it, or $null when
    nothing is left. The file holds document IDs, part counts, SHA-256s, VM names, and times: none of the evidence. Never
    throws. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [ValidateSet('STOP', 'DEPLOY', 'FABRIC')]
        [string] $CheckPrefix,

        [AllowNull()]
        [object] $Export,

        [switch] $Saved,

        [AllowEmptyString()]
        [string] $Why = '',

        [string] $Directory = (Join-Path -Path $script:RepoRoot -ChildPath 'out/history-pending')
    )

    if ($null -eq $Export) {
        return $null
    }
    $keep = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $documentList = Get-DemoMemberValue -InputObject $Export -Name 'Documents'
    $pendingList = Get-DemoMemberValue -InputObject $Export -Name 'Pending'
    $unsaved = 0
    foreach ($item in @(@($pendingList) + @(if (-not $Saved) { @($documentList) }))) {
        $reference = ConvertTo-DemoRcaReference -InputObject $item
        if ($null -ne $reference -and $seen.Add([string]$reference['documentId'])) {
            $keep.Add($reference)
        }
    }
    if (-not $Saved) {
        $unsaved = @($documentList | Where-Object { $null -ne $_ }).Count
    }
    $path = Get-DemoRcaPendingPath -Config $Config -Directory $Directory
    $checkId = '{0}.RCA.PENDING' -f $CheckPrefix
    if ($keep.Count -eq 0) {
        # Only a list this export read (PendingFound) is deleted: the documents it listed were fetched and taken, or dropped.
        if ([bool](Get-DemoMemberValue -InputObject $Export -Name 'PendingFound') -and (Test-Path -LiteralPath $path -PathType Leaf) -and $PSCmdlet.ShouldProcess($path, 'Delete the RCA evidence''s pending list')) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        return $null
    }
    if (-not $PSCmdlet.ShouldProcess($path, 'Keep the RCA evidence''s pending list')) {
        return $null
    }
    $shown = $path
    $root = $script:RepoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $shown = './' + $path.Substring($root.Length).Replace('\', '/')
    }
    try {
        $null = New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force
        $content = ConvertTo-Json -InputObject ([ordered]@{ kind = 'DbHubDemo.RcaPending'; version = 1; documents = $keep.ToArray() }) -Depth 4
        [System.IO.File]::WriteAllText($path, $content, [System.Text.UTF8Encoding]::new($false))
    }
    catch {
        return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message ('{0} RCA evidence document(s) weren''t saved, and their list couldn''t be kept either ({1}).' -f $keep.Count, (Protect-DemoText -Text $_.Exception.Message)) -Remediation 'The runner keeps them on the VMs for 7 days; the control''s next session doesn''t fetch them, so run ./scripts/stop-demo.ps1 -SaveHistory at the end of the next session.' -DocUrl $script:RcaRunCommandDoc)
    }
    $vms = @($keep | ForEach-Object { [string]$_['vm'] } | Select-Object -Unique) -join ' and '
    $reason = if ($unsaved -gt 0 -and $Why) { ': {0}' -f $Why } else { '' }
    $message = '{0} RCA evidence document(s) aren''t in the history yet{1}. The runner keeps them on {2} for 7 days, and {3} lists them.' -f $keep.Count, $reason, $vms, $shown
    $fix = 'The next history save adds them while the VMs run: ./scripts/stop-demo.ps1 -SaveHistory at the end of a session, deploy.ps1''s snapshot, or {0}.' -f $script:RcaRunAgain
    return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status 'Warning' -Message $message -Evidence ([ordered]@{ path = $shown; documents = @($keep | ForEach-Object { [string]$_['documentId'] }); unsaved = $unsaved }) -Remediation $fix -DocUrl $script:RcaRunCommandDoc)
}
