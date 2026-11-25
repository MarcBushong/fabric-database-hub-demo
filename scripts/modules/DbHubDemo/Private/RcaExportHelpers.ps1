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
# The sidecar (2026-11-23, rca/README.md, The sidecar; rca/transport.schema.json, sidecarPartLine, sidecarRef, sidecarFile).
$script:RcaSidecarPartPattern = '^DBHUBDEMO-RCAS 1 [0-9]{8}T[0-9]{6}Z-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{4}-sidecar [1-9][0-9]?/[1-9][0-9]? [0-9a-f]{64} [A-Za-z0-9+/]+={0,2}$'
$script:RcaSidecarIdPattern = '^[0-9]{8}T[0-9]{6}Z-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{4}-sidecar$'
$script:RcaSessionPattern = '^[0-9a-f]{32}$'
# The scripts' own name for a staged sidecar payload: the contract's sidecarFile, with the lowercase suffix the notebook's
# sweep matches (NB_DatabaseHub_LiveActivity, RCA_SIDECAR_INBOX_FILE).
$script:RcaSidecarFilePattern = '^Files/rca/inbox/sidecar-[0-9]{8}T[0-9]{6}Z(-[a-z0-9][a-z0-9-]{0,63})?\.json$'
$script:RcaAcks = 'Files/rca/acks'
# The runner keeps an unacknowledged sidecar for 30 days after its sealing (rca/README.md, The sidecar).
$script:RcaSidecarKeepDays = 30
# rca sidecar-export's pages (8 sidecars each); the pages one save reads, and the IDs one 'rca ack' carries.
$script:RcaSidecarMaxPages = 16
$script:RcaSidecarAckChunk = 32
# The drain (F9): with the VMs running, at most 3 runs of the notebook carry sidecars in one save, the later ones within
# 15 minutes in all.
$script:RcaSidecarDrainRuns = 3
$script:RcaSidecarDrainMinutes = 15
$script:RcaSidecarNotebookFix = './scripts/configure-fabric.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity -RunLiveActivity'

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
    bootstrap bundle predates the Rca action), and Line. With -Sidecar (2026-11-23), a sidecar's Run Command: its line is
    DBHUBDEMO-RCAS-INDEX or DBHUBDEMO-RCAS, and OldBundle means a bundle from before the -Action it ran (RcaSidecarExport
    unless it says otherwise: RcaAck, or Rca for a sidecar's part). Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Output,

        [switch] $Sidecar,

        [ValidateSet('Rca', 'RcaSidecarExport', 'RcaAck')]
        [string] $Action
    )

    $indexMarker = if ($Sidecar) { 'DBHUBDEMO-RCAS-INDEX ' } else { 'DBHUBDEMO-RCA-INDEX ' }
    $partMarker = if ($Sidecar) { 'DBHUBDEMO-RCAS ' } else { 'DBHUBDEMO-RCA ' }
    # A VM-side control from before the action answers with its list of actions, which doesn't name it. The bundle from
    # before the sidecar's actions names Rca there, so a sidecar's action looks for its own name.
    $named = if ($Action) { $Action } elseif ($Sidecar) { 'RcaSidecarExport' } else { 'Rca' }
    $actionName = '\b{0}\b' -f $named
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
            $answer.OldBundle = $answer.Status -eq 'Fail' -and $answer.Message -match '^Unknown action' -and $answer.Message -notmatch $actionName
        }
        elseif ($text.StartsWith($indexMarker, [System.StringComparison]::Ordinal) -or $text.StartsWith($partMarker, [System.StringComparison]::Ordinal)) {
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
    # Whether a line is the part asked for: the contract's pattern (rca/transport.schema.json, partLine; with -Sidecar,
    # sidecarPartLine), at most 3,400 characters, and the document, index, count, and SHA-256 its export's index gave.
    # Pure. Internal.
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Line,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Document,

        [Parameter(Mandatory)]
        [int] $Part,

        [switch] $Sidecar
    )

    $pattern = if ($Sidecar) { $script:RcaSidecarPartPattern } else { $script:RcaPartPattern }
    if ([string]::IsNullOrEmpty($Line) -or $Line.Length -gt 3400 -or $Line -cnotmatch $pattern) {
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
    With -Sidecar (2026-11-23), a sidecar's DBHUBDEMO-RCAS lines, which decode to a ContosoCare.RcaSidecar. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Line,

        [switch] $Sidecar
    )

    $fail = { param([string] $Why) [pscustomobject]@{ Ok = $false; Why = $Why; Document = $null } }
    $pattern = if ($Sidecar) { $script:RcaSidecarPartPattern } else { $script:RcaPartPattern }
    $kind = if ($Sidecar) { 'ContosoCare.RcaSidecar' } else { 'ContosoCare.RcaEvidence' }
    $pieces = @{}
    $count = 0
    $sha = ''
    $id = ''
    foreach ($text in $Line) {
        if ([string]$text -cnotmatch $pattern) {
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
    if ($document -isnot [System.Collections.IDictionary] -or [string]$document['kind'] -cne $kind -or -not (Test-DemoRcaInteger -Value $document['version'] -Minimum 1 -Maximum 1) -or [string]$document['documentId'] -cne $id) {
        $what = if ($Sidecar) { 'a sidecar' } else { 'an evidence document' }
        return (& $fail ('it isn''t {0} of version 1 with its own ID (run ./scripts/deploy.ps1, which updates the runner and the scripts together)' -f $what))
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
    at most 3 times. Returns '' when Azure accepted it, otherwise its error. -Action RcaSidecarExport or RcaAck (2026-11-23)
    runs the sidecar's actions instead. Internal.
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
        [string] $Directory,

        [ValidateSet('Rca', 'RcaSidecarExport', 'RcaAck')]
        [string] $Action = 'Rca'
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $url = '{0}/{1}?api-version={2}' -f (Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName (Get-DemoResourceGroupName -Config $Config) -VmName $VmName), $Name, (Get-DemoRunCommandApiVersion)
    $body = [ordered]@{
        location   = [string]$Config['location']
        properties = [ordered]@{
            source                          = [ordered]@{ script = (Get-DemoWorkloadControlScript -Action $Action -Request $Request) }
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
    Deletes a staged RCA_EVIDENCE_FILE (Path - Delete), then Files/rca/inbox and Files/rca when they're empty: a folder's
    delete without recurse leaves one that still holds a file, such as another run's. Returns Deleted ($true when the file
    is gone) and Found ($true when it was still there, so this deleted it: NB_DatabaseHub_LiveActivity deletes it once it
    has written the evidence, and leaves it when it couldn't read or write it; review of 3b1348a). Never throws. Internal.
    https://learn.microsoft.com/rest/api/storageservices/datalakestoragegen2/path/delete
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $Path
    )

    $answer = [pscustomobject]@{ Deleted = $false; Found = $false }
    if ($Path -cnotmatch $script:RcaEvidenceFilePattern -or -not $PSCmdlet.ShouldProcess($Path, 'Delete the staged RCA evidence')) {
        return $answer
    }
    $workspaceId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')
    $lakehouseId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'lakehouseId')
    try {
        $token = Get-DemoStorageToken -SubscriptionId ([string]$Config['subscriptionId'])
        $deleted = Remove-DemoOneLakeFile -WorkspaceId $workspaceId -LakehouseId $lakehouseId -Path $Path -Token $token
        if ([string]$deleted.Status -ne 'Pass') {
            Write-DemoLog -Level Warning -Message ('The staged RCA evidence {0} wasn''t deleted ({1}); the notebook''s next run deletes it a day later at the latest, and the deployment notebook''s purge with Files/rca/inbox.' -f $Path, $deleted.Error)
            return $answer
        }
        $answer.Deleted = $true
        $answer.Found = [bool](Get-DemoMemberValue -InputObject $deleted -Name 'Found')
        foreach ($folder in $script:RcaInbox, 'Files/rca') {
            $folderAnswer = Invoke-DemoOneLakeRequest -Method Delete -WorkspaceId $workspaceId -Path ('{0}/{1}' -f $lakehouseId.ToLowerInvariant(), $folder) -Query 'recursive=false' -Token $token
            if ($folderAnswer.StatusCode -notin 200, 202, 204, 404) {
                break
            }
        }
        return $answer
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The staged RCA evidence {0} wasn''t deleted ({1}); the notebook''s next run deletes it a day later at the latest.' -f $Path, (Protect-DemoText -Text $_.Exception.Message))
        return $answer
    }
}

function Invoke-DemoRcaNotebookRun {
    <#
    .SYNOPSIS
    Runs NB_DatabaseHub_LiveActivity on demand (Invoke-DemoFabricNotebookRun) with the RCA evidence staged as
    RCA_EVIDENCE_FILE (Send-DemoRcaEvidenceFile) when there's some and the workspace's copy of the notebook knows the
    parameter, and deletes the staged file once the job has ended (Remove-DemoRcaEvidenceFile). Returns Run (the run's
    record), RcaSent, RcaSaved (sent, the run completed, and the notebook had deleted the file, which it does once it has
    written the evidence), RcaFile, RcaNote (why it wasn't sent or saved), and SidecarBatch (the save's sidecar batch that
    went with it, -Sidecar, 2026-11-23; $null when none did). Internal.

    .DESCRIPTION
    - A copy of the notebook from before the Incident RCA (Test-DemoFabricNotebookParameter: Known, without the parameter)
      would ignore the file, so none is staged, and RcaNote says so; one whose definition can't be read gets it, as with
      POSTGRES_METRICS.
    - The file goes once the job has ended (Completed, Failed, Cancelled, Deduped), or when the run didn't start; a job that
      still runs reads it and deletes it itself, and the notebook's day-old sweep or the deployment notebook's purge takes
      one that nothing deleted.
    - A job that completes doesn't mean the evidence was written (review of 3b1348a): the notebook never fails its run for
      it, and leaves the file when it couldn't read or write it (no Spark or lakehouse, a write that failed, SAVE_RESULTS
      false). So the evidence counts as saved only when the notebook had deleted the file (Path - Delete answers 404);
      otherwise RcaNote says it wasn't written, and the caller keeps its documents for the next save (Save-DemoRcaPending).
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

        [ValidateRange(1, 120)]
        [int] $TimeoutMinutes = 15,

        [System.Collections.IDictionary] $RunOption = @{},

        # The save's sidecars (2026-11-23, Invoke-DemoRcaSidecarFetch): their first batch goes with the run as
        # RCA_SIDECAR_FILE when the workspace's copy of the notebook declares it (Send-DemoRcaSidecarBatch), and the
        # notebook's acknowledgement is read once the job has ended (Complete-DemoRcaSidecarBatch).
        [AllowNull()]
        [object] $Sidecar = $null
    )

    $answer = [pscustomobject]@{ Run = $null; RcaSent = $false; RcaSaved = $false; RcaFile = ''; RcaNote = ''; SidecarBatch = $null }
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
    # The sidecars (2026-11-23): only for a copy of the notebook that declares RCA_SIDECAR_FILE; one whose definition can't
    # be read gets them, as with RCA_EVIDENCE_FILE. An older copy would ignore them, so they stay pending on the VMs.
    $sidecarBatch = $null
    if ($null -ne $Sidecar -and @($Sidecar.Fetched.Keys).Count -gt 0) {
        $knowsSidecar = Test-DemoFabricNotebookParameter -WorkspaceId ([string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')) -Name 'NB_DatabaseHub_LiveActivity' -Parameter 'RCA_SIDECAR_FILE' -Token $Token
        if ([bool]$knowsSidecar.Known -and -not [bool]$knowsSidecar.Has) {
            $Sidecar.NotebookOld = $true
        }
        else {
            $sidecarBatch = Send-DemoRcaSidecarBatch -Config $Config -Sidecar $Sidecar
            if ($null -ne $sidecarBatch -and $sidecarBatch.Path) {
                $Parameter['RCA_SIDECAR_FILE'] = $sidecarBatch.Path
            }
        }
        $answer.SidecarBatch = $sidecarBatch
    }
    $ended = $true
    $removed = $null
    try {
        $answer.Run = Invoke-DemoFabricNotebookRun -Config $Config -Name 'NB_DatabaseHub_LiveActivity' -Parameter $Parameter -Token $Token -TimeoutMinutes $TimeoutMinutes @RunOption
        $jobStatus = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $answer.Run -Name 'evidence') -Name 'status')
        $ended = [string]$answer.Run.status -ne 'Warning' -or $jobStatus -in 'Completed', 'Failed', 'Cancelled', 'Deduped'
    }
    finally {
        if ($answer.RcaFile -and $ended) {
            $removed = Remove-DemoRcaEvidenceFile -Config $Config -Path $answer.RcaFile -Confirm:$false
        }
        if ($null -ne $sidecarBatch) {
            Complete-DemoRcaSidecarBatch -Config $Config -Batch $sidecarBatch -Run $answer.Run
        }
    }
    # The notebook deletes the file once it has written the evidence; one this run deleted was left unwritten.
    $removedFound = [bool](Get-DemoMemberValue -InputObject $removed -Name 'Found')
    $taken = [bool](Get-DemoMemberValue -InputObject $removed -Name 'Deleted') -and -not $removedFound
    $answer.RcaSaved = $answer.RcaSent -and [string]$answer.Run.status -eq 'Pass' -and $taken
    if ($answer.RcaSent -and -not $answer.RcaSaved) {
        $answer.RcaNote = if (-not $ended) {
            'the history run was still going when the wait ended'
        }
        elseif ([string]$answer.Run.status -ne 'Pass') {
            'the history run didn''t complete'
        }
        elseif ($removedFound) {
            'NB_DatabaseHub_LiveActivity didn''t write it, and left the staged file, as it does when it writes none of the evidence (its RCA.EVIDENCE finding in analysis_findings says why)'
        }
        else {
            'the staged file couldn''t be checked, so whether NB_DatabaseHub_LiveActivity wrote it isn''t known (the next save writes only what isn''t in the history)'
        }
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

#region The sidecar (2026-11-23)
# Query Store's evidence and T4's connection holders travel in sidecars beside the evidence document (rca/README.md, The
# sidecar, Acknowledgement, and RCA_SIDECAR_FILE; rca/transport.schema.json's sidecar kinds). The scripts' saves
# (stop-demo.ps1 -SaveHistory, deploy.ps1's snapshot, configure-fabric.ps1 -RunLiveActivity) fetch them after the evidence
# document's export (Invoke-DemoRcaSidecarFetch), stage whole sidecars as RCA_SIDECAR_FILE for
# NB_DatabaseHub_LiveActivity (Send-DemoRcaSidecarBatch), read the notebook's acknowledgement (Read-DemoRcaSidecarAck), and
# acknowledge the written ones on the VMs with 'rca ack' (Complete-DemoRcaSidecarSave): at once while the VMs run, and at
# the next export with the VM running for the stop's save, whose VMs are deallocated before the notebook runs. The runner
# keeps a sidecar until it's acknowledged, or for 30 days after its sealing, and offers it again at every export, so
# nothing here can lose one: the PC's lists in out/history-pending say what waits and which acknowledgements are still to
# send, with IDs, VMs, sessions, and times only, none of the evidence.

function ConvertTo-DemoRcaSidecarReference {
    # One sidecar reference (documentId, sessionId, parts, sha256, vm) from a sidecar index (rca/transport.schema.json,
    # sidecarRef) or the PC's pending list, checked against the contract's patterns, or $null. Pure. Internal.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()]
        [object] $InputObject,

        [AllowEmptyString()]
        [string] $Vm = ''
    )

    $id = [string](Get-DemoMemberValue -InputObject $InputObject -Name 'documentId')
    $parts = Get-DemoMemberValue -InputObject $InputObject -Name 'parts'
    $sha = [string](Get-DemoMemberValue -InputObject $InputObject -Name 'sha256')
    $session = Get-DemoMemberValue -InputObject $InputObject -Name 'sessionId'
    if ($id -cnotmatch $script:RcaSidecarIdPattern -or -not (Test-DemoRcaInteger -Value $parts -Minimum 1 -Maximum 99) -or $sha -cnotmatch '^[0-9a-f]{64}$') {
        return $null
    }
    if ($null -ne $session -and ($session -isnot [string] -or $session -cnotmatch $script:RcaSessionPattern)) {
        return $null
    }
    $vmName = [string](Get-DemoMemberValue -InputObject $InputObject -Name 'vm')
    if (-not $vmName) {
        $vmName = $Vm
    }
    if ($vmName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$') {
        return $null
    }
    return [ordered]@{ documentId = $id; sessionId = $session; parts = [int]$parts; sha256 = $sha; vm = $vmName }
}

function ConvertFrom-DemoRcaSidecarIndex {
    <#
    .SYNOPSIS
    One page of 'rca sidecar-export''s index, 'DBHUBDEMO-RCAS-INDEX <json>' (rca/transport.schema.json, sidecarIndex):
    Valid, Why, Page, Pages, Documents (references with -Vm, ConvertTo-DemoRcaSidecarReference), Status, and Message. An
    index of another kind or version isn't used: its Why names ./scripts/deploy.ps1 (rca/README.md, Versioning). Pure.
    Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Line,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,14}$')]
        [string] $Vm
    )

    $answer = [pscustomobject]@{ Valid = $false; Why = ''; Page = 0; Pages = 0; Documents = @(); Status = ''; Message = '' }
    if (-not ([string]$Line).StartsWith('DBHUBDEMO-RCAS-INDEX ', [System.StringComparison]::Ordinal) -or $Line.Length -gt 3400) {
        $answer.Why = 'the sidecar export printed no index line'
        return $answer
    }
    try {
        $index = $Line.Substring(21) | ConvertFrom-Json -AsHashtable
    }
    catch {
        $answer.Why = 'its sidecar index line isn''t JSON'
        return $answer
    }
    if ($index -isnot [System.Collections.IDictionary] -or [string]$index['kind'] -cne 'ContosoCare.RcaSidecarIndex' -or -not (Test-DemoRcaInteger -Value $index['version'] -Minimum 1 -Maximum 1)) {
        $answer.Why = 'its sidecar index is of a kind or version these scripts don''t know (run ./scripts/deploy.ps1, which updates the runner and the scripts together)'
        return $answer
    }
    $list = $index['documents']
    $status = [string]$index['status']
    $message = $index['message']
    if (-not (Test-DemoRcaInteger -Value $index['page'] -Minimum 1 -Maximum 100000) -or -not (Test-DemoRcaInteger -Value $index['pages'] -Minimum 0 -Maximum 100000) -or $list -isnot [System.Collections.IList] -or $list.Count -gt 8 -or $status -cnotin $script:RcaStatuses -or $message -isnot [string] -or $message.Length -gt 500) {
        $answer.Why = 'its sidecar index doesn''t follow the contract'
        return $answer
    }
    $documents = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $list) {
        $reference = ConvertTo-DemoRcaSidecarReference -InputObject $item -Vm $Vm
        if ($null -eq $reference -or [string](Get-DemoMemberValue -InputObject $item -Name 'state') -cnotin 'new', 'pending' -or -not $seen.Add([string]$reference['documentId'])) {
            $answer.Why = 'its sidecar index lists a sidecar that doesn''t follow the contract'
            return $answer
        }
        $documents.Add($reference)
    }
    $answer.Valid = $true
    $answer.Page = [int]$index['page']
    $answer.Pages = [int]$index['pages']
    $answer.Documents = $documents.ToArray()
    $answer.Status = $status
    $answer.Message = Protect-DemoText -Text $message
    return $answer
}

function Get-DemoRcaSidecarIdTime {
    # When a sidecar's window began, from its ID (<windowStartUtc as yyyyMMddTHHmmssZ>-<host>-<sequence>-sidecar), as UTC,
    # or $null. The runner seals a sidecar once its window has begun and keeps it 30 days after its sealing, so this time
    # plus 30 days is the earliest it can expire unread (rca/README.md, The sidecar). Pure. Internal.
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [AllowEmptyString()]
        [string] $DocumentId
    )

    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ($DocumentId.Length -ge 16 -and [datetime]::TryParseExact($DocumentId.Substring(0, 16), "yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Format-DemoRcaSidecarTime {
    # A UTC time as the PC's lists keep it: yyyy-MM-ddTHH:mm:ssZ. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [datetime] $Value
    )

    return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-DemoRcaSidecarListPath {
    # The PC's two sidecar lists for an environment, in out/history-pending (2026-11-23): Pending
    # (rca-sidecar-pending-<resource group>.json: the sidecars that wait on the VMs, and why) and Acks
    # (rca-sidecar-acks-<resource group>.json: the acknowledgements still to send to the VMs that hold them). Pure. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $Directory = (Join-Path -Path $script:RepoRoot -ChildPath 'out/history-pending')
    )

    $group = Get-DemoResourceGroupName -Config $Config
    return [pscustomobject]@{
        Pending = (Join-Path -Path $Directory -ChildPath ('rca-sidecar-pending-{0}.json' -f $group))
        Acks    = (Join-Path -Path $Directory -ChildPath ('rca-sidecar-acks-{0}.json' -f $group))
    }
}

function Get-DemoRcaShownPath {
    # A path as the lines show it: ./<path in the repository> for one under it, otherwise as it is. Pure. Internal.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()]
        [string] $Path
    )

    $root = $script:RepoRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ('./' + $Path.Substring($root.Length).Replace('\', '/'))
    }
    return $Path
}

function Read-DemoRcaSidecarList {
    <#
    .SYNOPSIS
    The PC's sidecar lists (Get-DemoRcaSidecarListPath): Pending (by document ID: documentId, vm, sessionId, parts, sha256,
    reason, firstSeenUtc, expiresUtc), Acks (by document ID: documentId, vm, status, recordedUtc), Paths, Writable (each
    list this save may write back), and Problems (sentences for the save's line). Never throws. Internal.

    .DESCRIPTION
    A list is never lost: one that can't be parsed, or is of a kind or version these scripts don't know, is moved aside to
    <name>.unreadable-<yyyyMMddTHHmmssZ>.json, never deleted, and a new list starts; one that can't be moved stays as it is,
    and this save doesn't write over it. Its Problems sentence names both, and the save's line is a Warning. The runner
    keeps what an unreadable list named, so the next export offers it again.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [string] $Directory = (Join-Path -Path $script:RepoRoot -ChildPath 'out/history-pending')
    )

    $paths = Get-DemoRcaSidecarListPath -Config $Config -Directory $Directory
    $answer = [pscustomobject]@{ Paths = $paths; Pending = [ordered]@{}; Acks = [ordered]@{}; Writable = @{ Pending = $true; Acks = $true }; Problems = [System.Collections.Generic.List[string]]::new() }
    foreach ($which in 'Pending', 'Acks') {
        $path = [string]$paths.$which
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $entries = [ordered]@{}
        $why = ''
        try {
            $file = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
            $kind = if ($which -eq 'Pending') { 'DbHubDemo.RcaSidecarPending' } else { 'DbHubDemo.RcaSidecarAcks' }
            $member = if ($which -eq 'Pending') { 'sidecars' } else { 'acknowledgements' }
            if ($file -isnot [System.Collections.IDictionary] -or [string]$file['kind'] -cne $kind -or -not (Test-DemoRcaInteger -Value $file['version'] -Minimum 1 -Maximum 1) -or $file[$member] -isnot [System.Collections.IList]) {
                $why = 'it isn''t a {0} list of version 1' -f $kind
            }
            foreach ($item in @(if (-not $why) { $file[$member] })) {
                $id = [string](Get-DemoMemberValue -InputObject $item -Name 'documentId')
                if ($which -eq 'Pending') {
                    $reference = ConvertTo-DemoRcaSidecarReference -InputObject $item
                    $reason = Get-DemoMemberValue -InputObject $item -Name 'reason'
                    $seenUtc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $item -Name 'firstSeenUtc')
                    $expiresUtc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $item -Name 'expiresUtc')
                    if ($null -eq $reference -or $reason -isnot [string] -or $reason.Length -gt 500 -or $null -eq $seenUtc -or $null -eq $expiresUtc -or $entries.Contains($id)) {
                        $why = 'an entry doesn''t follow its format'
                        break
                    }
                    $reference['reason'] = $reason
                    $reference['firstSeenUtc'] = Format-DemoRcaSidecarTime -Value $seenUtc
                    $reference['expiresUtc'] = Format-DemoRcaSidecarTime -Value $expiresUtc
                    $entries[$id] = $reference
                    continue
                }
                $vm = [string](Get-DemoMemberValue -InputObject $item -Name 'vm')
                $status = [string](Get-DemoMemberValue -InputObject $item -Name 'status')
                $recordedUtc = ConvertTo-DemoUtcDateTime -Value (Get-DemoMemberValue -InputObject $item -Name 'recordedUtc')
                if ($id -cnotmatch $script:RcaSidecarIdPattern -or $vm -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,14}$' -or $status -cnotin 'written', 'already' -or $null -eq $recordedUtc -or $entries.Contains($id)) {
                    $why = 'an entry doesn''t follow its format'
                    break
                }
                $entries[$id] = [ordered]@{ documentId = $id; vm = $vm; status = $status; recordedUtc = (Format-DemoRcaSidecarTime -Value $recordedUtc) }
            }
        }
        catch {
            $why = 'it isn''t JSON ({0})' -f (Protect-DemoText -Text $_.Exception.Message)
        }
        if (-not $why) {
            $answer.$which = $entries
            continue
        }
        # Never deleted: kept aside, and a new list starts.
        $shown = Get-DemoRcaShownPath -Path $path
        $aside = '{0}.unreadable-{1}.json' -f ($path -replace '\.json$', ''), (Get-DemoUtcNow).ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture)
        try {
            Move-Item -LiteralPath $path -Destination $aside -ErrorAction Stop
            $answer.Problems.Add(('The PC''s list {0} couldn''t be read ({1}), so it was kept as {2} and a new one started; the runner keeps the sidecars it named, and offers them again.' -f $shown, $why, (Get-DemoRcaShownPath -Path $aside)))
            Write-DemoLog -Level Warning -Message ('{0} couldn''t be read ({1}); it was kept as {2}.' -f $shown, $why, $aside)
        }
        catch {
            $answer.Writable[$which] = $false
            $answer.Problems.Add(('The PC''s list {0} couldn''t be read ({1}) or moved aside ({2}), so it stays as it is and this save didn''t write it; the runner keeps the sidecars it named, and offers them again.' -f $shown, $why, (Protect-DemoText -Text $_.Exception.Message)))
        }
    }
    return $answer
}

function Save-DemoRcaSidecarList {
    <#
    .SYNOPSIS
    Writes the PC's sidecar lists back (Read-DemoRcaSidecarList's answer, as the save changed it): each list it may write,
    as indented UTF-8 JSON through a temporary file and a move, so a stopped run never leaves half a list; a list left
    empty is deleted. Returns the problems, as sentences for the save's line. Never throws. Internal.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]
        [object] $List
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    foreach ($which in 'Pending', 'Acks') {
        if (-not [bool]$List.Writable[$which]) {
            continue
        }
        $path = [string]$List.Paths.$which
        $entries = @($List.$which.Values)
        if (-not $PSCmdlet.ShouldProcess($path, 'Keep the RCA sidecars'' list')) {
            continue
        }
        try {
            if ($entries.Count -eq 0) {
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                }
                continue
            }
            $document = if ($which -eq 'Pending') {
                [ordered]@{ kind = 'DbHubDemo.RcaSidecarPending'; version = 1; sidecars = $entries }
            }
            else {
                [ordered]@{ kind = 'DbHubDemo.RcaSidecarAcks'; version = 1; acknowledgements = $entries }
            }
            $null = New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force
            $content = ConvertTo-Json -InputObject $document -Depth 5
            if ((Test-Path -LiteralPath $path -PathType Leaf) -and [System.IO.File]::ReadAllText($path) -ceq $content) {
                # Unchanged: a save with nothing new to say writes nothing.
                continue
            }
            $temporary = '{0}.tmp' -f $path
            [System.IO.File]::WriteAllText($temporary, $content, [System.Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $temporary -Destination $path -Force -ErrorAction Stop
        }
        catch {
            $problems.Add(('The PC''s list {0} couldn''t be written ({1}); the runner keeps every sidecar it hasn''t been told is written, and offers it again.' -f (Get-DemoRcaShownPath -Path $path), (Protect-DemoText -Text $_.Exception.Message)))
        }
    }
    return $problems.ToArray()
}

function Get-DemoRcaSidecarRoom {
    <#
    .SYNOPSIS
    For the sidecar's Run Commands on a VM: Room (how many more managed Run Commands Azure takes there, of its 25 per VM,
    or -1 when they couldn't be listed) and Busy (how many of the exports' DbHubDemo-Rca-* Azure still lists, one it's
    deleting included). As Get-DemoRcaRunCommandRoom does, those that have finished, or are more than an hour old, are
    deleted first, without waiting: their instance view holds evidence. Internal.
    https://learn.microsoft.com/rest/api/compute/virtual-machine-run-commands/list-by-virtual-machine
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
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
    $unknown = [pscustomobject]@{ Room = -1; Busy = 0 }
    $list = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'get', '--url', ('{0}?api-version={1}&$expand=instanceView' -f $base, $apiVersion)) -AllowFailure
    if ($list.ExitCode -ne 0) {
        return $unknown
    }
    try {
        $parsed = if ([string]::IsNullOrWhiteSpace([string]$list.StdOut)) { $null } else { [string]$list.StdOut | ConvertFrom-Json -Depth 32 }
    }
    catch {
        return $unknown
    }
    $values = Get-DemoMemberValue -InputObject $parsed -Name 'value'
    $count = 0
    $busy = 0
    foreach ($item in @($values)) {
        if ($null -eq $item) {
            continue
        }
        $count++
        $name = [string](Get-DemoMemberValue -InputObject $item -Name 'name')
        if (-not $name.StartsWith($script:RcaRunCommandPrefix, [System.StringComparison]::Ordinal) -or $name -notmatch '^[A-Za-z0-9-]{1,64}$') {
            continue
        }
        $busy++
        $properties = Get-DemoMemberValue -InputObject $item -Name 'properties'
        $execution = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $properties -Name 'instanceView') -Name 'executionState')
        if ([string](Get-DemoMemberValue -InputObject $properties -Name 'provisioningState') -ne 'Deleting' -and (Test-DemoRunCommandFinished -Name $name -ExecutionState $execution -NowUtc (Get-DemoUtcNow))) {
            $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', ('{0}/{1}?api-version={2}' -f $base, $name, $apiVersion)) -AllowFailure
        }
    }
    return [pscustomobject]@{ Room = [int][System.Math]::Max(0, 25 - $count); Busy = $busy }
}

function Invoke-DemoRcaSidecarRunCommand {
    <#
    .SYNOPSIS
    Runs the sidecar's managed Run Commands on the demo's VMs, as Invoke-DemoRcaExport runs the evidence document's: for
    each VM in -Plan (Vm, OneAtATime, Limit, and Steps, each with Key, Action, Request, Name, and TimeoutSeconds), its
    steps in order, at most Limit at a time. Returns, per VM: Vm, Outcome ('' when its steps were sent; NoRoom, Busy, or
    Failed when none was), Message, Results (by Key: State, Out, and Error), and Leftover. Internal.

    .DESCRIPTION
    - Each Run Command is created with 'az rest' (Send-DemoRcaRunCommand -Action), read from its instance view (the last
      4 KB, which holds the result line and the runner's one line; ConvertFrom-DemoRcaRunOutput -Sidecar), and deleted
      without waiting once it's read, so no part of the evidence stays in an instance view.
    - A step's State: Read (it ended, and Out is what it printed), Late (it hadn't ended at -Deadline, and was deleted),
      Gone (Azure no longer had it), Refused (Azure didn't accept it: Error), or Skipped (never sent: the deadline, or the
      VM's outcome).
    - On the T2 host (OneAtATime, R871), one Run Command at a time, each gone before the next goes, and nothing until Azure
      lists none of the exports' Run Commands there (an earlier export's that it's still deleting), at most
      -HostDeleteWaitSeconds (Busy otherwise). A delete Azure doesn't finish in -HostDeleteWaitSeconds is asked for once
      more; after a second, the host gets nothing more in this pass.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Plan,

        [Parameter(Mandatory)]
        [datetime] $Deadline,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 10,

        [ValidateRange(0, 1800)]
        [int] $HostDeleteWaitSeconds = 300
    )

    $subscriptionId = [string]$Config['subscriptionId']
    $resourceGroup = Get-DemoResourceGroupName -Config $Config
    $apiVersion = Get-DemoRunCommandApiVersion
    $urlOf = { param([string] $Vm, [string] $Name) '{0}/{1}?api-version={2}' -f (Get-DemoRunCommandBaseUrl -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroup -VmName $Vm), $Name, $apiVersion }
    $hosts = [System.Collections.Generic.List[object]]::new()
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
    $record = { param([object] $HostState, [object] $Step, [string] $State, [object] $Out = $null, [string] $Why = '') $HostState.Results[[string]$Step.Key] = [pscustomobject]@{ State = $State; Out = $Out; Error = $Why } }
    $directory = Initialize-DemoPrivateDirectory -Prefix 'dbhub-rcas'
    $finished = $false
    try {
        $waitUntil = (Get-DemoUtcNow).AddSeconds($HostDeleteWaitSeconds)
        foreach ($entry in @($Plan)) {
            $queue = [System.Collections.Generic.List[object]]::new()
            foreach ($step in @($entry.Steps)) {
                if ($null -ne $step) {
                    $queue.Add($step)
                }
            }
            $hosts.Add([pscustomobject]@{
                    Vm = [string]$entry.Vm; OneAtATime = [bool]$entry.OneAtATime; Limit = [System.Math]::Max(1, [int]$entry.Limit); Queue = $queue
                    InFlight = [System.Collections.Generic.List[object]]::new(); Deleting = [System.Collections.Generic.List[object]]::new(); Free = 0
                    Ready = $false; Done = ($queue.Count -eq 0); Blocked = $false; Outcome = ''; Message = ''; Results = [ordered]@{}; Leftover = [System.Collections.Generic.List[string]]::new()
                })
        }
        while ($true) {
            $late = (Get-DemoUtcNow) -ge $Deadline
            $busy = $false
            foreach ($hostState in $hosts) {
                if ($hostState.Done) {
                    continue
                }
                if (-not $hostState.Ready) {
                    $room = Get-DemoRcaSidecarRoom -Config $Config -VmName $hostState.Vm
                    if ($room.Room -lt 0) {
                        $hostState.Outcome = 'Failed'
                        $hostState.Message = '{0}''s Run Commands couldn''t be listed, so its sidecars wait for the next save.' -f $hostState.Vm
                    }
                    elseif ($room.Room -lt 1) {
                        $hostState.Outcome = 'NoRoom'
                        $hostState.Message = '{0} already has 25 managed Run Commands, the most a VM takes, so its sidecars wait for the next save.' -f $hostState.Vm
                    }
                    elseif ($hostState.OneAtATime -and $room.Busy -gt 0) {
                        if ($late -or (Get-DemoUtcNow) -ge $waitUntil) {
                            $hostState.Outcome = 'Busy'
                            $hostState.Message = 'Azure still lists an earlier export''s Run Commands on {0}, which takes one at a time (R871), so its sidecars wait for the next save.' -f $hostState.Vm
                        }
                        else {
                            $busy = $true
                            continue
                        }
                    }
                    if ($hostState.Outcome) {
                        $hostState.Done = $true
                        continue
                    }
                    $hostState.Ready = $true
                    $hostState.Free = $room.Room
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
                    $hostState.Leftover.Add(('{0}/{1}' -f $hostState.Vm, $item.Name))
                }
                foreach ($flight in @($hostState.InFlight.ToArray())) {
                    $view = Get-DemoRunCommandState -SubscriptionId $subscriptionId -Url (& $urlOf $hostState.Vm $flight.Step.Name)
                    $ended = $view.Found -and ($view.ExecutionState -in $script:RcaTerminalStates -or $view.ProvisioningState -eq 'Failed')
                    if (-not $ended -and -not $late -and -not $view.NotFound) {
                        continue
                    }
                    $null = $hostState.InFlight.Remove($flight)
                    if ($view.NotFound) {
                        $hostState.Free++
                        & $record $hostState $flight.Step 'Gone'
                        continue
                    }
                    & $remove $hostState $flight.Step.Name
                    if (-not $ended) {
                        & $record $hostState $flight.Step 'Late'
                        continue
                    }
                    & $record $hostState $flight.Step 'Read' (ConvertFrom-DemoRcaRunOutput -Output $view.Output -Sidecar -Action ([string]$flight.Step.Action))
                }
                $limit = if ($hostState.OneAtATime) { 1 } else { $hostState.Limit }
                while (-not $late -and -not $hostState.Blocked -and $hostState.Queue.Count -gt 0 -and $hostState.Free -gt 0 -and ($hostState.InFlight.Count + $(if ($hostState.OneAtATime) { $hostState.Deleting.Count } else { 0 })) -lt $limit) {
                    $step = $hostState.Queue[0]
                    $hostState.Queue.RemoveAt(0)
                    $refused = Send-DemoRcaRunCommand -Config $Config -VmName $hostState.Vm -Name ([string]$step.Name) -Request $step.Request -TimeoutSeconds ([int]$step.TimeoutSeconds + 60) -Directory $directory -Action ([string]$step.Action)
                    if ($refused) {
                        & $record $hostState $step 'Refused' $null $refused
                        continue
                    }
                    $hostState.InFlight.Add([pscustomobject]@{ Step = $step })
                    $hostState.Free--
                }
                if ($hostState.InFlight.Count -gt 0 -or ($hostState.Queue.Count -gt 0 -and -not $late -and -not $hostState.Blocked) -or ($hostState.OneAtATime -and $hostState.Deleting.Count -gt 0 -and $hostState.Queue.Count -gt 0 -and -not $late)) {
                    $busy = $true
                }
                else {
                    $hostState.Done = $true
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
            # An error stopped the pass: what it still has on a VM goes, so no part of the evidence stays in an instance view.
            foreach ($hostState in $hosts) {
                foreach ($flight in @($hostState.InFlight)) {
                    $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', (& $urlOf $hostState.Vm $flight.Step.Name)) -AllowFailure
                }
            }
        }
    }
    $answers = foreach ($hostState in $hosts) {
        # What a late or stopped pass never sent, or never read.
        foreach ($flight in @($hostState.InFlight)) {
            $null = Invoke-DemoAz -SubscriptionId $subscriptionId -ArgumentList @('rest', '--method', 'delete', '--url', (& $urlOf $hostState.Vm $flight.Step.Name)) -AllowFailure
            & $record $hostState $flight.Step 'Late'
        }
        foreach ($step in @($hostState.Queue)) {
            & $record $hostState $step 'Skipped'
        }
        [pscustomobject]@{ Vm = $hostState.Vm; Outcome = $hostState.Outcome; Message = $hostState.Message; Results = $hostState.Results; Leftover = $hostState.Leftover.ToArray() }
    }
    return @($answers)
}

function Get-DemoRcaSidecarOrder {
    # Sidecars in the order a save stages them: those of no session first, whose rows go under the save's own run (F7),
    # then the others, oldest first (their IDs start with their window's start). Pure. Internal.
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Reference = @()
    )

    return @(@($Reference | Where-Object { $null -ne $_ }) | Sort-Object -Stable -Property @{ Expression = { if ($null -eq $_['sessionId']) { 0 } else { 1 } } }, @{ Expression = { [string]$_['documentId'] } })
}

function Select-DemoRcaSidecarBatch {
    <#
    .SYNOPSIS
    The sidecars one notebook run takes (rca/README.md, Limits: RCA_SIDECAR_FILE): whole sidecars, at most -MaxParts parts
    in all, in the order given (Get-DemoRcaSidecarOrder); one that doesn't fit waits, and a smaller one after it can go.
    With -SessionBoundOnly (a drain's run, F9), only sidecars of a session: the notebook writes one of no session under
    the run that reads it, which must be the save's own (F7). -Exclude leaves out sidecars already taken. Returns their
    document IDs. Pure. Internal.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowEmptyCollection()]
        [object[]] $Reference = @(),

        [ValidateRange(1, 99)]
        [int] $MaxParts = 64,

        [switch] $SessionBoundOnly,

        [AllowEmptyCollection()]
        [string[]] $Exclude = @()
    )

    $taken = [System.Collections.Generic.List[string]]::new()
    $parts = 0
    foreach ($item in $Reference) {
        $id = [string]$item['documentId']
        if ($id -in $Exclude -or $taken.Contains($id) -or ($SessionBoundOnly -and $null -eq $item['sessionId'])) {
            continue
        }
        if ($parts + [int]$item['parts'] -le $MaxParts) {
            $taken.Add($id)
            $parts += [int]$item['parts']
        }
    }
    return $taken.ToArray()
}

function New-DemoRcaSidecarPayload {
    <#
    .SYNOPSIS
    One RCA_SIDECAR_FILE document (rca/transport.schema.json, sidecarParameter) as compact JSON: the part lines of whole
    sidecars, in the order given (-Line, by document ID), while the file stays within -MaxBytes of UTF-8 (262,144, what the
    notebook reads); a sidecar past it waits. sessionId is null: the scripts' saves fetch any session's sidecars, and the
    notebook writes each under its own session's run. Returns Json, Ids, Parts, Bytes, and Left (the sidecars past the
    bytes). Pure. Internal.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds JSON in memory only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Line,

        [ValidateRange(1024, 262144)]
        [int] $MaxBytes = 262144
    )

    $toJson = {
        param([string[]] $Parts, [int] $Count)
        $message = '{0} sidecar(s) for the history run.' -f $Count
        ConvertTo-Json -InputObject ([ordered]@{ kind = 'ContosoCare.RcaSidecarParts'; version = 1; sessionId = $null; parts = @($Parts); status = 'Pass'; message = $message }) -Depth 4 -Compress
    }
    $ids = [System.Collections.Generic.List[string]]::new()
    $left = [System.Collections.Generic.List[string]]::new()
    $parts = [System.Collections.Generic.List[string]]::new()
    $json = ''
    foreach ($id in @($Line.Keys)) {
        $grown = [string[]](@($parts) + @($Line[$id]))
        $candidate = & $toJson $grown ($ids.Count + 1)
        if ($grown.Count -gt $script:RcaMaxParts -or [System.Text.Encoding]::UTF8.GetByteCount($candidate) -gt $MaxBytes) {
            $left.Add([string]$id)
            continue
        }
        $ids.Add([string]$id)
        foreach ($text in @($Line[$id])) {
            $parts.Add([string]$text)
        }
        $json = $candidate
    }
    return [pscustomobject]@{ Json = $json; Ids = $ids.ToArray(); Parts = $parts.Count; Bytes = [System.Text.Encoding]::UTF8.GetByteCount($json); Left = $left.ToArray() }
}

function Invoke-DemoRcaSidecarFetch {
    <#
    .SYNOPSIS
    The Incident RCA's sidecars for a history save by the operator's scripts (2026-11-23, rca/README.md, The sidecar and
    Acknowledgement), after the evidence document's export (Invoke-DemoRcaScriptExport), on each VM whose runner the
    export reaches (Get-DemoRcaExportHost). Returns the save's sidecar state, which Invoke-DemoRcaNotebookRun stages and
    Complete-DemoRcaSidecarSave finishes. Never throws, except for a stop of the run. Internal.

    .DESCRIPTION
    In this order, on each VM (Invoke-DemoRcaSidecarRunCommand: managed Run Commands with the operator's sign-in):
    1. The acknowledgements an earlier save deferred to this VM (the PC's list): 'rca ack' (the RcaAck action), so the
       runner doesn't offer what's in the history already (F6). Those it takes leave the list; the rest stay, and go first
       at the next export (F5).
    2. 'rca sidecar-export --session none' (RcaSidecarExport; with --final for -Final, a session's last), page 1, then the
       pages its index counts, at most 16 (F8).
    3. 'rca part' (the Rca action's part command) for each part of the sidecars this save can stage, whole ones only: at
       most 64 parts for each of -Runs notebook runs, those of no session in the first run only (F7, F9); each sidecar
       checked whole against its SHA-256 and the contract (Expand-DemoRcaDocument -Sidecar).
    A VM whose bootstrap bundle predates the sidecar's actions answers "Unknown action" (OldBundle), and one whose runner
    predates them is OldRunner: nothing of that VM's is fetched, the evidence document goes on as before, and the save's
    line names ./scripts/deploy.ps1 (M2). Each VM's outcome is its own. At -Minutes it stops: what wasn't read waits on the
    VM, which offers it again at the next save.
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

        [ValidateRange(1, 3)]
        [int] $Runs = 1,

        [ValidateRange(1, 60)]
        [int] $Minutes = 8,

        [string] $PendingDirectory = (Join-Path -Path $script:RepoRoot -ChildPath 'out/history-pending'),

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 10,

        [ValidateRange(0, 1800)]
        [int] $HostDeleteWaitSeconds = 300
    )

    $startedUtc = Get-DemoUtcNow
    $sidecar = [pscustomobject]@{
        CheckPrefix = $CheckPrefix; Final = [bool]$Final; Runs = $Runs; StartedUtc = $startedUtc; PendingDirectory = $PendingDirectory
        List = $null; Hosts = [System.Collections.Generic.List[object]]::new(); Offered = [ordered]@{}; Fetched = [ordered]@{}
        Gone = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal); Reasons = [ordered]@{}
        Batches = [System.Collections.Generic.List[object]]::new(); NotebookOld = $false; Delivered = [System.Collections.Generic.List[string]]::new()
        Notes = [System.Collections.Generic.List[string]]::new(); Error = ''
    }
    $sidecar.List = Read-DemoRcaSidecarList -Config $Config -Directory $PendingDirectory
    foreach ($problem in $sidecar.List.Problems) {
        $sidecar.Notes.Add($problem)
    }
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
        foreach ($entry in @(Get-DemoRcaExportHost -Config $Config -State $State -Power $Power)) {
            $sidecar.Hosts.Add([pscustomobject]@{ Vm = [string]$entry.Vm; OneAtATime = [bool]$entry.OneAtATime; Outcome = [string]$entry.Outcome; Message = [string]$entry.Message; IndexComplete = $false; AckError = ''; RunnerWarning = '' })
        }
        $engine = @{ Config = $Config; Deadline = $startedUtc.AddMinutes($Minutes); PollSeconds = $PollSeconds; HostDeleteWaitSeconds = $HostDeleteWaitSeconds }
        $stamp = $startedUtc.ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        $hostOf = @{}
        foreach ($hostState in $sidecar.Hosts) {
            $hostOf[$hostState.Vm] = $hostState
        }
        $setOutcome = {
            param([object] $HostState, [object] $Pass)
            if ($Pass.Outcome) {
                $HostState.Outcome = $Pass.Outcome
                $HostState.Message = $Pass.Message
            }
        }

        # 1. The acknowledgements an earlier save deferred, first.
        $plan = @(foreach ($hostState in @($sidecar.Hosts | Where-Object { -not $_.Outcome })) {
                $ids = @($sidecar.List.Acks.Values | Where-Object { [string]$_['vm'] -eq $hostState.Vm } | ForEach-Object { [string]$_['documentId'] })
                if ($ids.Count -gt 0) {
                    New-DemoRcaSidecarAckPlan -Vm $hostState.Vm -OneAtATime:$hostState.OneAtATime -DocumentId $ids -Stamp $stamp
                }
            })
        foreach ($pass in @(if ($plan.Count -gt 0) { Invoke-DemoRcaSidecarRunCommand @engine -Plan $plan })) {
            $hostState = $hostOf[$pass.Vm]
            & $setOutcome $hostState $pass
            $vmPlan = @($plan | Where-Object { $_.Vm -eq $pass.Vm }) | Select-Object -First 1
            $ack = Get-DemoRcaSidecarAckAnswer -Pass $pass -Plan $vmPlan
            foreach ($id in $ack.Acked) {
                $null = $sidecar.List.Acks.Remove($id)
                $sidecar.Delivered.Add($id)
            }
            if ($ack.Outcome) {
                $hostState.Outcome = $ack.Outcome
                $hostState.Message = $ack.Message
            }
            $hostState.AckError = $ack.Why
        }

        # 2. The index, page 1, then the pages it counts.
        $pages = @{}
        for ($round = 1; $round -le 2; $round++) {
            $plan = @(foreach ($hostState in @($sidecar.Hosts | Where-Object { -not $_.Outcome })) {
                    $wanted = @(if ($round -eq 1) { 1 } elseif ([int]$pages[$hostState.Vm] -gt 1) { 2..([System.Math]::Min([int]$pages[$hostState.Vm], $script:RcaSidecarMaxPages)) })
                    if ($wanted.Count -gt 0) {
                        [pscustomobject]@{
                            Vm = $hostState.Vm; OneAtATime = $hostState.OneAtATime; Limit = 1
                            Steps = @(foreach ($page in $wanted) {
                                    [pscustomobject]@{ Key = ('index:{0}' -f $page); Action = 'RcaSidecarExport'; Request = [ordered]@{ sessionId = ''; final = [bool]$Final; page = $page; timeoutSeconds = 600 }; Name = ('{0}{1}-i{2:d2}-{3}' -f $script:RcaRunCommandPrefix, $hostState.Vm, $page, $stamp); TimeoutSeconds = 600 }
                                })
                        }
                    }
                })
            foreach ($pass in @(if ($plan.Count -gt 0) { Invoke-DemoRcaSidecarRunCommand @engine -Plan $plan })) {
                $hostState = $hostOf[$pass.Vm]
                & $setOutcome $hostState $pass
                if ($hostState.Outcome) {
                    continue
                }
                $complete = $true
                foreach ($key in @($pass.Results.Keys)) {
                    $read = Get-DemoRcaSidecarIndexAnswer -Vm $hostState.Vm -Result $pass.Results[$key]
                    if ($read.Outcome) {
                        $hostState.Outcome = $read.Outcome
                        $hostState.Message = $read.Message
                        $complete = $false
                        break
                    }
                    # The index's own Warning (8afcca24), sidecars the runner let expire unread: once per VM, as each page
                    # repeats it.
                    if ($read.Warning -and -not $hostState.RunnerWarning) {
                        $hostState.RunnerWarning = $read.Warning
                    }
                    if (-not $read.Complete) {
                        $complete = $false
                    }
                    if ($round -eq 1) {
                        $pages[$hostState.Vm] = $read.Pages
                    }
                    foreach ($reference in $read.Documents) {
                        if (-not $sidecar.Offered.Contains([string]$reference['documentId'])) {
                            $sidecar.Offered[[string]$reference['documentId']] = $reference
                        }
                    }
                }
                $more = [int]$pages[$hostState.Vm] -gt 1
                $hostState.IndexComplete = $complete -and ($round -eq 2 -or -not $more) -and [int]$pages[$hostState.Vm] -le $script:RcaSidecarMaxPages
                if ($complete -and $round -eq 2 -and [int]$pages[$hostState.Vm] -gt $script:RcaSidecarMaxPages) {
                    $sidecar.Notes.Add(('{0} offers more than {1} sidecars; this save read the first {1}, and the next saves take the rest.' -f $hostState.Vm, (8 * $script:RcaSidecarMaxPages)))
                }
            }
        }

        # 3. The parts of what this save can stage.
        $ordered = @(Get-DemoRcaSidecarOrder -Reference @($sidecar.Offered.Values))
        $planned = [System.Collections.Generic.List[string]]::new()
        for ($run = 1; $run -le $Runs; $run++) {
            $batch = @(Select-DemoRcaSidecarBatch -Reference $ordered -SessionBoundOnly:($run -gt 1) -Exclude $planned.ToArray())
            foreach ($id in $batch) {
                $planned.Add($id)
            }
        }
        foreach ($reference in $ordered) {
            if ([string]$reference['documentId'] -notin $planned) {
                $sidecar.Reasons[[string]$reference['documentId']] = 'past what this save''s history runs take (64 parts a run)'
            }
        }
        $sequence = 0
        $plan = @(foreach ($hostState in @($sidecar.Hosts | Where-Object { -not $_.Outcome })) {
                $steps = [System.Collections.Generic.List[object]]::new()
                foreach ($reference in @($ordered | Where-Object { $_['vm'] -eq $hostState.Vm -and [string]$_['documentId'] -in $planned })) {
                    $sequence++
                    for ($part = 1; $part -le [int]$reference['parts']; $part++) {
                        $steps.Add([pscustomobject]@{ Key = ('part:{0}:{1}' -f $reference['documentId'], $part); Action = 'Rca'; Request = [ordered]@{ command = 'part'; documentId = [string]$reference['documentId']; part = $part; timeoutSeconds = 120 }; Name = ('{0}{1}-s{2:d3}{3:d2}-{4}' -f $script:RcaRunCommandPrefix, $hostState.Vm, $sequence, $part, $stamp); TimeoutSeconds = 120 })
                    }
                }
                if ($steps.Count -gt 0) {
                    [pscustomobject]@{ Vm = $hostState.Vm; OneAtATime = $hostState.OneAtATime; Limit = 10; Steps = $steps.ToArray() }
                }
            })
        $lines = @{}
        foreach ($pass in @(if ($plan.Count -gt 0) { Invoke-DemoRcaSidecarRunCommand @engine -Plan $plan })) {
            $hostState = $hostOf[$pass.Vm]
            & $setOutcome $hostState $pass
            foreach ($key in @($pass.Results.Keys)) {
                $fields = $key.Split(':')
                $result = $pass.Results[$key]
                $out = $result.Out
                $reference = $sidecar.Offered[$fields[1]]
                if ($result.State -eq 'Read' -and [string]$out.Status -eq 'Pass' -and (Test-DemoRcaPartLine -Line ([string]$out.Line) -Document $reference -Part ([int]$fields[2]) -Sidecar)) {
                    if (-not $lines.ContainsKey($fields[1])) {
                        $lines[$fields[1]] = [string[]]::new([int]$reference['parts'])
                    }
                    $lines[$fields[1]][[int]$fields[2] - 1] = [string]$out.Line
                }
                elseif ($result.State -eq 'Read' -and [string]$out.Status -eq 'Fail' -and [string]$out.Message -match 'exit code 1\b') {
                    # The runner no longer has it (rca/README.md, The runner's commands): acknowledged, or past its 30 days.
                    $null = $sidecar.Gone.Add($fields[1])
                }
            }
        }
        foreach ($id in @($planned)) {
            if ($sidecar.Gone.Contains($id)) {
                continue
            }
            $got = [string[]]@()
            if ($lines.ContainsKey($id)) {
                $got = [string[]]$lines[$id]
            }
            if ($got.Count -eq 0 -or @($got | Where-Object { [string]::IsNullOrEmpty($_) }).Count -gt 0) {
                $vm = [string]$sidecar.Offered[$id]['vm']
                $why = if ($hostOf[$vm].Outcome) { [string]$hostOf[$vm].Message } else { 'it wasn''t fetched whole in time, so it waits on {0} for the next save' -f $vm }
                $sidecar.Reasons[$id] = $why
                continue
            }
            $expanded = Expand-DemoRcaDocument -Line $got -Sidecar
            if (-not $expanded.Ok) {
                $sidecar.Reasons[$id] = 'it was fetched, but {0}' -f $expanded.Why
                continue
            }
            $sidecar.Fetched[$id] = $got
        }
    }
    catch {
        if ($_.Exception -is [System.Management.Automation.PipelineStoppedException] -or ($_.Exception -is [System.OperationCanceledException] -and (Test-DemoRunCancelled))) {
            throw
        }
        $sidecar.Error = 'The RCA sidecars weren''t fetched: {0}' -f (Protect-DemoText -Text $_.Exception.Message)
    }
    # What the VMs took leaves the PC's list now, whatever the save does next.
    foreach ($problem in @(Save-DemoRcaSidecarList -List $sidecar.List -Confirm:$false)) {
        $sidecar.Notes.Add($problem)
    }
    return $sidecar
}

function New-DemoRcaSidecarAckPlan {
    # One VM's 'rca ack' steps for Invoke-DemoRcaSidecarRunCommand: the RcaAck action, at most 32 IDs a Run Command, one at
    # a time (the runner's ledger takes one writer). Pure. Internal.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory plan only; it changes no system state.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Vm,

        [switch] $OneAtATime,

        [Parameter(Mandatory)]
        [string[]] $DocumentId,

        [Parameter(Mandatory)]
        [string] $Stamp
    )

    $steps = [System.Collections.Generic.List[object]]::new()
    for ($start = 0; $start -lt $DocumentId.Count; $start += $script:RcaSidecarAckChunk) {
        $chunk = @($DocumentId[$start..([System.Math]::Min($DocumentId.Count, $start + $script:RcaSidecarAckChunk) - 1)])
        $number = $steps.Count + 1
        $steps.Add([pscustomobject]@{ Key = ('ack:{0}' -f $number); Action = 'RcaAck'; Request = [ordered]@{ documentIds = $chunk; timeoutSeconds = 120 }; Name = ('{0}{1}-k{2:d2}-{3}' -f $script:RcaRunCommandPrefix, $Vm, $number, $Stamp); TimeoutSeconds = 120; Ids = $chunk })
    }
    return [pscustomobject]@{ Vm = $Vm; OneAtATime = [bool]$OneAtATime; Limit = 1; Steps = $steps.ToArray() }
}

function Get-DemoRcaSidecarAckAnswer {
    # What one VM's 'rca ack' steps did (New-DemoRcaSidecarAckPlan, Invoke-DemoRcaSidecarRunCommand): Acked (the IDs the
    # runner took), Why (why the rest weren't, or ''), and Outcome and Message for a VM that can't take them (OldBundle,
    # OldRunner). Pure. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [object] $Pass,

        [AllowNull()]
        [object] $Plan
    )

    $answer = [pscustomobject]@{ Acked = @(); Why = ''; Outcome = ''; Message = '' }
    $acked = [System.Collections.Generic.List[string]]::new()
    if ($Pass.Outcome) {
        $answer.Why = [string]$Pass.Message
        return $answer
    }
    # Into a variable first: Get-DemoMemberValue returns the array whole, and @() around the call would nest it.
    $steps = Get-DemoMemberValue -InputObject $Plan -Name 'Steps'
    foreach ($step in @($steps)) {
        if ($null -eq $step) {
            continue
        }
        $result = $Pass.Results[[string]$step.Key]
        $out = Get-DemoMemberValue -InputObject $result -Name 'Out'
        if ([string](Get-DemoMemberValue -InputObject $result -Name 'State') -eq 'Read' -and [string]$out.Status -eq 'Pass') {
            foreach ($id in @($step.Ids)) {
                $acked.Add([string]$id)
            }
            continue
        }
        if ($null -ne $out -and [bool]$out.OldBundle) {
            $answer.Outcome = 'OldBundle'
            $answer.Message = '{0}''s bootstrap bundle predates the RCA sidecar, so nothing of its sidecars was fetched or acknowledged; ./scripts/deploy.ps1 sends the current one.' -f $Pass.Vm
        }
        elseif ($null -ne $out -and ([bool]$out.OldRunner -or [string]$out.Status -eq 'Not supported')) {
            $answer.Outcome = 'OldRunner'
            $answer.Message = '{0}''s workload runner predates the RCA sidecar, so nothing of its sidecars was fetched or acknowledged; ./scripts/deploy.ps1 updates it.' -f $Pass.Vm
        }
        if (-not $answer.Why) {
            $state = [string](Get-DemoMemberValue -InputObject $result -Name 'State')
            $answer.Why = if ($answer.Message) { $answer.Message } elseif ($state -eq 'Read' -and [string]$out.Message) { [string]$out.Message } elseif ($state -eq 'Refused') { 'Azure didn''t accept its Run Command: {0}' -f [string]$result.Error } elseif ($state -eq 'Read') { 'its Run Command printed no result line' } else { 'its Run Command didn''t end in time' }
        }
        if ($answer.Outcome) {
            break
        }
    }
    $answer.Acked = $acked.ToArray()
    return $answer
}

function Get-DemoRcaSidecarIndexAnswer {
    # What one page of 'rca sidecar-export' said on a VM (Invoke-DemoRcaSidecarRunCommand's result): Pages and Documents,
    # or Outcome and Message when the VM's sidecars can't be fetched now (OldBundle, OldRunner, Failed, TimedOut); a VM
    # with nothing to fetch (exit code 2, Not selected) has none. The index line's own status stands, with exit code 2 too
    # (rca/README.md, The runner's commands, since 8afcca24): Warning is its message when it isn't Pass or Not selected,
    # a count of sidecars the runner let expire unread, whether the control script's result says Not selected (exit code
    # 2) or Warning. A Warning with no line it can read has the result's message, and Complete false, since the VM's
    # index isn't known whole then. Pure. Internal.
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Vm,

        [AllowNull()]
        [object] $Result
    )

    $answer = [pscustomobject]@{ Pages = 0; Documents = @(); Outcome = ''; Message = ''; Warning = ''; Complete = $true }
    $state = [string](Get-DemoMemberValue -InputObject $Result -Name 'State')
    $out = Get-DemoMemberValue -InputObject $Result -Name 'Out'
    if ($state -ne 'Read') {
        $answer.Outcome = if ($state -in 'Late', 'Skipped') { 'TimedOut' } else { 'Failed' }
        $answer.Message = switch ($state) {
            'Refused' { 'Azure didn''t accept the sidecar export''s Run Command on {0}: {1}' -f $Vm, [string]$Result.Error }
            'Gone' { '{0}''s sidecar export Run Command was gone before it ended, so its sidecars wait for the next save.' -f $Vm }
            default { '{0}''s sidecar export didn''t end in time, so its sidecars wait on it for the next save.' -f $Vm }
        }
        return $answer
    }
    if ([bool]$out.OldBundle) {
        $answer.Outcome = 'OldBundle'
        $answer.Message = '{0}''s bootstrap bundle predates the RCA sidecar, so no sidecar was fetched from it; ./scripts/deploy.ps1 sends the current one.' -f $Vm
        return $answer
    }
    if ([bool]$out.OldRunner -or [string]$out.Status -eq 'Not supported') {
        $answer.Outcome = 'OldRunner'
        $answer.Message = '{0}''s workload runner predates the RCA sidecar, so no sidecar was fetched from it; ./scripts/deploy.ps1 updates it.' -f $Vm
        return $answer
    }
    $status = [string]$out.Status
    if ($status -notin 'Pass', 'Warning', 'Not selected') {
        $answer.Outcome = 'Failed'
        $answer.Message = '{0}''s sidecar export failed: {1}' -f $Vm, $(if ([string]$out.Message) { [string]$out.Message } else { 'its Run Command printed no result line' })
        return $answer
    }
    $bound = { param([string] $Text) if ($Text.Length -gt 300) { $Text.Substring(0, 297) + '...' } else { $Text } }
    $line = [string]$out.Line
    $index = ConvertFrom-DemoRcaSidecarIndex -Line $line -Vm $Vm
    if (-not $index.Valid) {
        if ($status -eq 'Not selected') {
            # Nothing to fetch, with no line, or one that adds nothing it can read.
            return $answer
        }
        if ($status -eq 'Warning') {
            $answer.Warning = & $bound $(if ([string]$out.Message) { [string]$out.Message } else { 'its sidecar export ended with a Warning, and no index line' })
            $answer.Complete = $false
            return $answer
        }
        $answer.Outcome = 'Failed'
        $answer.Message = '{0}''s sidecar export ran, but {1}.' -f $Vm, $index.Why
        return $answer
    }
    $answer.Pages = $index.Pages
    $answer.Documents = $index.Documents
    if ([string]$index.Status -notin 'Pass', 'Not selected') {
        $answer.Warning = & $bound $(if ([string]$index.Message) { [string]$index.Message } else { 'its sidecar index''s status is {0}' -f $index.Status })
    }
    return $answer
}

function Send-DemoRcaSidecarBatch {
    <#
    .SYNOPSIS
    Stages the save's next sidecar batch for NB_DatabaseHub_LiveActivity's RCA_SIDECAR_FILE (rca/README.md,
    RCA_SIDECAR_FILE): the whole sidecars it fetched and hasn't staged, in its order, at most 64 parts and 262,144 bytes
    (Select-DemoRcaSidecarBatch, New-DemoRcaSidecarPayload), those of no session in the save's first run only (F7). One
    ContosoCare.RcaSidecarParts document goes to Files/rca/inbox/sidecar-<yyyyMMddTHHmmssZ>-script-<8 hex>.json, the name
    the notebook's sidecar sweep matches and its day-old sweep of evidence files never does, through OneLake's ADLS Gen2
    API with the operator's Storage token (Send-DemoOneLakeFile), as Send-DemoRcaEvidenceFile stages the evidence: nothing
    is granted. Records the batch (Number, Path, Ids, Parts, Bytes, Ack, Note) in -Sidecar and returns it, or $null when
    nothing is left to stage. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [object] $Sidecar
    )

    $staged = @(foreach ($item in $Sidecar.Batches) { @($item.Ids) })
    $remaining = @(Get-DemoRcaSidecarOrder -Reference @(foreach ($id in @($Sidecar.Fetched.Keys)) { if ($id -notin $staged) { $Sidecar.Offered[$id] } }))
    $ids = @(Select-DemoRcaSidecarBatch -Reference $remaining -SessionBoundOnly:($Sidecar.Batches.Count -gt 0))
    if ($ids.Count -eq 0) {
        return $null
    }
    $lines = [ordered]@{}
    foreach ($id in $ids) {
        $lines[$id] = $Sidecar.Fetched[$id]
    }
    $payload = New-DemoRcaSidecarPayload -Line $lines
    foreach ($id in $payload.Left) {
        $Sidecar.Reasons[$id] = 'past the 262,144 bytes a history run reads'
    }
    if (@($payload.Ids).Count -eq 0) {
        return $null
    }
    $batch = [pscustomobject]@{ Number = ($Sidecar.Batches.Count + 1); Path = ''; Ids = @($payload.Ids); Parts = $payload.Parts; Bytes = $payload.Bytes; Ack = $null; Note = '' }
    $Sidecar.Batches.Add($batch)
    $workspaceId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')
    $lakehouseId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'lakehouseId')
    if ($workspaceId -notmatch $script:OneLakeGuidPattern -or $lakehouseId -notmatch $script:OneLakeGuidPattern) {
        $batch.Note = 'not staged: the demo lakehouse isn''t resolved'
        return $batch
    }
    $path = '{0}/sidecar-{1}-script-{2}.json' -f $script:RcaInbox, (Get-DemoUtcNow).ToString("yyyyMMdd'T'HHmmss'Z'", [System.Globalization.CultureInfo]::InvariantCulture), [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        $token = Get-DemoStorageToken -SubscriptionId ([string]$Config['subscriptionId'])
        $sent = Send-DemoOneLakeFile -WorkspaceId $workspaceId -LakehouseId $lakehouseId -Path $path -Content $payload.Json -Token $token
    }
    catch {
        $batch.Note = 'not staged: {0}' -f (Protect-DemoText -Text $_.Exception.Message)
        return $batch
    }
    if ([string]$sent.Status -ne 'Pass') {
        # A file it began to write goes, so nothing is left in Files/.
        $null = Remove-DemoRcaSidecarFile -Config $Config -Path $path -Confirm:$false
        $batch.Note = 'not staged: {0}' -f [string]$sent.Error
        return $batch
    }
    $batch.Path = $path
    return $batch
}

function Remove-DemoRcaSidecarFile {
    <#
    .SYNOPSIS
    Deletes a staged sidecar payload that no run read (Path - Delete): one whose run didn't start or was deduplicated,
    or one this save couldn't finish staging. The notebook deletes the payloads it reads once every sidecar in them is in
    the history, and keeps one with a skipped sidecar until later runs write it, or for 30 days (rca/README.md,
    Acknowledgement), so the scripts never delete one a run read. Returns $true when it's gone. Never throws. Internal.
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

    if ($Path -cnotmatch $script:RcaSidecarFilePattern -or -not $PSCmdlet.ShouldProcess($Path, 'Delete the staged RCA sidecars')) {
        return $false
    }
    try {
        $token = Get-DemoStorageToken -SubscriptionId ([string]$Config['subscriptionId'])
        $deleted = Remove-DemoOneLakeFile -WorkspaceId ([string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')) -LakehouseId ([string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'lakehouseId')) -Path $Path -Token $token
        return ([string]$deleted.Status -eq 'Pass')
    }
    catch {
        Write-DemoLog -Level Warning -Message ('The staged RCA sidecars {0} weren''t deleted ({1}); the notebook''s sweep deletes them 30 days after staging.' -f $Path, (Protect-DemoText -Text $_.Exception.Message))
        return $false
    }
}

function Read-DemoRcaSidecarAck {
    <#
    .SYNOPSIS
    The notebook's acknowledgement of a staged sidecar payload (rca/README.md, Acknowledgement; rca/transport.schema.json,
    ack), Files/rca/acks/<the payload's name without .json>.ack.json, read through OneLake's ADLS Gen2 API (Path - Read)
    with the operator's Storage token, as the payload was staged. Returns Found, Valid, Why (why it counts as missing),
    and Documents (by ID: Status and Reason). Never throws. Internal.

    .DESCRIPTION
    It's valid only when it's a version 1 ContosoCare.RcaAck that names the staged payload and lists exactly its
    sidecars, each once, as written, already, or skipped. One that names another payload or other sidecars is stale, and
    counts as missing, so nothing in the payload is acknowledged (F4). The notebook writes none when its run doesn't save
    results or can't read the payload; that's missing too (F3).
    https://learn.microsoft.com/rest/api/storageservices/datalakestoragegen2/path/read
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $DocumentId
    )

    $answer = [pscustomobject]@{ Found = $false; Valid = $false; Why = ''; Documents = [ordered]@{} }
    $workspaceId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'workspaceId')
    $lakehouseId = [string](Get-DemoMemberValue -InputObject $Config['fabric'] -Name 'lakehouseId')
    if ($Path -cnotmatch $script:RcaSidecarFilePattern -or $workspaceId -notmatch $script:OneLakeGuidPattern -or $lakehouseId -notmatch $script:OneLakeGuidPattern) {
        $answer.Why = 'their acknowledgement couldn''t be looked for'
        return $answer
    }
    $name = $Path.Substring($Path.LastIndexOf('/') + 1)
    $ackPath = '{0}/{1}.ack.json' -f $script:RcaAcks, $name.Substring(0, $name.Length - 5)
    try {
        $token = Get-DemoStorageToken -SubscriptionId ([string]$Config['subscriptionId'])
        $response = Invoke-DemoOneLakeRequest -Method Get -WorkspaceId $workspaceId -Path ('{0}/{1}' -f $lakehouseId.ToLowerInvariant(), $ackPath) -Token $token
    }
    catch {
        $answer.Why = 'their acknowledgement couldn''t be read ({0})' -f (Protect-DemoText -Text $_.Exception.Message)
        return $answer
    }
    if ($response.StatusCode -eq 404) {
        $answer.Why = 'the notebook wrote no acknowledgement of them (its run failed, timed out, or didn''t save its results)'
        return $answer
    }
    if ($response.StatusCode -ne 200) {
        $answer.Why = 'their acknowledgement couldn''t be read ({0})' -f (Get-DemoOneLakeError -Response $response)
        return $answer
    }
    $answer.Found = $true
    try {
        $ack = [string]$response.Content | ConvertFrom-Json -AsHashtable
    }
    catch {
        $answer.Why = 'their acknowledgement isn''t JSON'
        return $answer
    }
    if ($ack -isnot [System.Collections.IDictionary] -or [string]$ack['kind'] -cne 'ContosoCare.RcaAck' -or -not (Test-DemoRcaInteger -Value $ack['version'] -Minimum 1 -Maximum 1) -or $ack['documents'] -isnot [System.Collections.IList] -or $ack['runId'] -isnot [string] -or $ack['runId'].Length -lt 1 -or $ack['runId'].Length -gt 200) {
        $answer.Why = 'their acknowledgement isn''t a ContosoCare.RcaAck of version 1'
        return $answer
    }
    if ([string]$ack['payload'] -cne $Path) {
        $answer.Why = 'their acknowledgement names another payload'
        return $answer
    }
    $documents = [ordered]@{}
    foreach ($item in $ack['documents']) {
        $id = [string](Get-DemoMemberValue -InputObject $item -Name 'documentId')
        $status = [string](Get-DemoMemberValue -InputObject $item -Name 'status')
        $reason = Get-DemoMemberValue -InputObject $item -Name 'reason'
        if ($id -cnotmatch $script:RcaSidecarIdPattern -or [string](Get-DemoMemberValue -InputObject $item -Name 'kind') -cne 'ContosoCare.RcaSidecar' -or $status -cnotin 'written', 'already', 'skipped' -or ($null -ne $reason -and $reason -isnot [string]) -or $documents.Contains($id)) {
            $answer.Why = 'their acknowledgement doesn''t follow the contract'
            return $answer
        }
        $documents[$id] = [pscustomobject]@{ Status = $status; Reason = $(if ($reason) { Protect-DemoText -Text ([string]$reason) } else { '' }) }
    }
    $expected = @($DocumentId | Sort-Object -Unique)
    if ($documents.Count -ne $expected.Count -or @($expected | Where-Object { -not $documents.Contains($_) }).Count -gt 0) {
        $answer.Why = 'their acknowledgement lists other sidecars than were sent'
        return $answer
    }
    $answer.Valid = $true
    $answer.Documents = $documents
    return $answer
}

function Complete-DemoRcaSidecarBatch {
    <#
    .SYNOPSIS
    After the notebook run a staged sidecar batch went with (Send-DemoRcaSidecarBatch): its acknowledgement, read once the
    job has ended (Read-DemoRcaSidecarAck), in the batch's Ack, and its Note when the batch isn't acknowledged. A payload
    whose run didn't start, or was deduplicated, wasn't read by any run, so it's deleted; any other stays for the notebook,
    which deletes it once its sidecars are in the history. Never throws. Internal.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [Parameter(Mandatory)]
        [object] $Batch,

        [AllowNull()]
        [object] $Run
    )

    if (-not $Batch.Path) {
        return
    }
    $status = [string](Get-DemoMemberValue -InputObject $Run -Name 'status')
    $job = [string](Get-DemoMemberValue -InputObject (Get-DemoMemberValue -InputObject $Run -Name 'evidence') -Name 'status')
    if ($null -eq $Run) {
        $Batch.Note = 'not read: the history run didn''t complete'
        return
    }
    if (($status -ne 'Warning' -and -not $job) -or $job -eq 'Deduped') {
        $null = Remove-DemoRcaSidecarFile -Config $Config -Path $Batch.Path -Confirm:$false
        $Batch.Note = if ($job -eq 'Deduped') { 'not read: the history run was deduplicated' } else { 'not read: the history run didn''t start' }
        return
    }
    if ($job -notin 'Completed', 'Failed', 'Cancelled') {
        $Batch.Note = 'not acknowledged: the history run was still going when the wait ended'
        return
    }
    $Batch.Ack = Read-DemoRcaSidecarAck -Config $Config -Path $Batch.Path -DocumentId @($Batch.Ids)
    if (-not [bool]$Batch.Ack.Valid) {
        $Batch.Note = 'not acknowledged: {0}' -f $Batch.Ack.Why
    }
}

function Invoke-DemoRcaSidecarDrain {
    <#
    .SYNOPSIS
    With the VMs running (deploy.ps1's snapshot, configure-fabric.ps1 -RunLiveActivity), runs NB_DatabaseHub_LiveActivity
    again for the sidecars the save fetched and its first run couldn't take (F9): RCA_ONLY with SAVE_RESULTS false, which
    writes only the sidecars, each under its own session's run, and acknowledges them, with no second snapshot of the
    history (rca/README.md, RCA_SIDECAR_FILE). Each run takes the next batch (Send-DemoRcaSidecarBatch), sidecars of a
    session only (F7). It runs while the last run's acknowledgement was valid, at most 3 runs in the save in all, and
    starts none 15 minutes after the first of them. Never throws, except for a stop of the run. Internal.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Sidecar,

        [Parameter(Mandatory)]
        [securestring] $Token,

        [System.Collections.IDictionary] $Parameter = @{},

        [ValidateRange(1, 300)]
        [int] $PollSeconds = 20
    )

    if ($null -eq $Sidecar) {
        return
    }
    $deadline = (Get-DemoUtcNow).AddMinutes($script:RcaSidecarDrainMinutes)
    while ($Sidecar.Batches.Count -gt 0 -and $Sidecar.Batches.Count -lt [System.Math]::Min($Sidecar.Runs, $script:RcaSidecarDrainRuns)) {
        $last = $Sidecar.Batches[$Sidecar.Batches.Count - 1]
        if (-not $last.Path -or $null -eq $last.Ack -or -not [bool]$last.Ack.Valid) {
            break
        }
        $minutes = [int][System.Math]::Floor(($deadline - (Get-DemoUtcNow)).TotalMinutes)
        if ($minutes -lt 1) {
            break
        }
        $batch = Send-DemoRcaSidecarBatch -Config $Config -Sidecar $Sidecar
        if ($null -eq $batch -or -not $batch.Path) {
            break
        }
        $runParameter = [ordered]@{}
        foreach ($name in 'CONFIRM', 'STOP_ACTIVITY', 'KEY_VAULT_URL', 'RESOURCE_GROUP', 'WINDOW_MINUTES') {
            if ($Parameter.Contains($name)) {
                $runParameter[$name] = $Parameter[$name]
            }
        }
        $runParameter['SAVE_RESULTS'] = $false
        $runParameter['RCA_ONLY'] = $true
        $runParameter['RCA_SIDECAR_FILE'] = $batch.Path
        $run = $null
        try {
            $run = Invoke-DemoFabricNotebookRun -Config $Config -Name 'NB_DatabaseHub_LiveActivity' -Parameter $runParameter -Token $Token -TimeoutMinutes ([System.Math]::Min(120, $minutes)) -PollSeconds $PollSeconds
        }
        catch {
            if ($_.Exception -is [System.Management.Automation.PipelineStoppedException] -or ($_.Exception -is [System.OperationCanceledException] -and (Test-DemoRunCancelled))) {
                throw
            }
            Write-DemoLog -Level Warning -Message ('A history run for the RCA sidecars that wait didn''t complete: {0}' -f (Protect-DemoText -Text $_.Exception.Message))
        }
        Complete-DemoRcaSidecarBatch -Config $Config -Batch $batch -Run $run
    }
}

function Complete-DemoRcaSidecarSave {
    <#
    .SYNOPSIS
    The end of a save's sidecars (2026-11-23): acknowledges on the VMs what the notebook says is in the history, keeps the
    rest pending in the PC's list with why, and returns <prefix>.RCA.SIDECAR, or $null without a fetch. Never throws,
    except for a stop of the run. Internal.

    .DESCRIPTION
    - Acknowledged: the sidecars a payload's acknowledgement (Read-DemoRcaSidecarAck) says are written or already were
      (F1). With -Now, while the VMs run (deploy.ps1's snapshot, configure-fabric.ps1 -RunLiveActivity), 'rca ack' tells
      their VMs at once, and what a VM didn't take goes to the PC's list (F5). Without it (stop-demo.ps1 -SaveHistory,
      whose VMs are deallocated before the notebook runs), they all go to the PC's list, by VM, and the next export with
      that VM running sends them first (F6).
    - Pending, in the PC's list: every other sidecar the VMs offered, with why: skipped by the notebook (its reason), no
      acknowledgement or a stale one (F3, F4), past what this save's runs take (F9), an older notebook, a VM that couldn't
      be read (-Why when no run took them). One its VM, read whole, no longer offers leaves the list; one past the 30 days
      the runner keeps it expired unread (F11).
    - The line: Pass when nothing is left pending; a Warning when something is, with the command that takes it, or when a
      VM's runner or bundle predates the sidecar (./scripts/deploy.ps1), a list couldn't be read or written, or a sidecar
      expired unread, by the PC's list or by a VM's runner, whose index says so itself (8afcca24); Not selected when there
      was nothing to fetch and nothing waits.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Config,

        [AllowNull()]
        [object] $Sidecar,

        [switch] $Now,

        [AllowEmptyString()]
        [string] $Why = '',

        [ValidateRange(1, 60)]
        [int] $Minutes = 5,

        [ValidateRange(1, 60)]
        [int] $PollSeconds = 10,

        [ValidateRange(0, 1800)]
        [int] $HostDeleteWaitSeconds = 300
    )

    if ($null -eq $Sidecar) {
        return $null
    }
    $checkId = '{0}.RCA.SIDECAR' -f $Sidecar.CheckPrefix
    $nowUtc = Get-DemoUtcNow
    $list = $Sidecar.List
    $trim = { param([string] $Text) if ($Text.Length -gt 500) { $Text.Substring(0, 497) + '...' } else { $Text } }
    $vmOf = { param([string] $Id) [string]$Sidecar.Offered[$Id]['vm'] }

    # What each run's acknowledgement says.
    $acknowledged = [ordered]@{}
    $written = 0
    $already = 0
    $skipped = 0
    $sent = 0
    $runs = 0
    $stagedIds = [System.Collections.Generic.List[string]]::new()
    foreach ($batch in $Sidecar.Batches) {
        if ($batch.Path) {
            $runs++
            $sent += @($batch.Ids).Count
        }
        $valid = $null -ne $batch.Ack -and [bool]$batch.Ack.Valid
        foreach ($id in @($batch.Ids)) {
            $stagedIds.Add($id)
            if (-not $valid) {
                $Sidecar.Reasons[$id] = if ($batch.Note) { $batch.Note } else { 'not acknowledged' }
                continue
            }
            $entry = $batch.Ack.Documents[$id]
            if ($entry.Status -eq 'written') {
                $acknowledged[$id] = 'written'
                $written++
            }
            elseif ($entry.Status -eq 'already') {
                $acknowledged[$id] = 'already'
                $already++
            }
            else {
                $skipped++
                $Sidecar.Reasons[$id] = & $trim ('skipped by the notebook ({0})' -f $(if ($entry.Reason) { $entry.Reason } else { 'no reason given' }))
            }
        }
    }
    foreach ($id in @($Sidecar.Fetched.Keys)) {
        if ($id -in $stagedIds -or ($Sidecar.Reasons.Contains($id) -and [string]$Sidecar.Reasons[$id] -like 'past the 262,144 bytes*')) {
            continue
        }
        $Sidecar.Reasons[$id] = if ($Sidecar.NotebookOld) {
            'not sent: the workspace''s NB_DatabaseHub_LiveActivity doesn''t know RCA_SIDECAR_FILE yet'
        }
        elseif ($Sidecar.Batches.Count -eq 0) {
            & $trim ('not sent: {0}' -f $(if ($Why) { $Why } else { 'no history run took them' }))
        }
        else {
            'past what this save''s history runs take (64 parts a run)'
        }
    }

    # Acknowledged on the VMs now, or deferred to the next export with each VM running.
    $toVm = [ordered]@{}
    foreach ($id in @($acknowledged.Keys)) {
        $vm = & $vmOf $id
        if (-not $toVm.Contains($vm)) {
            $toVm[$vm] = [System.Collections.Generic.List[string]]::new()
        }
        $toVm[$vm].Add($id)
    }
    $sentNow = [System.Collections.Generic.List[string]]::new()
    $ackTrouble = [System.Collections.Generic.List[string]]::new()
    if ($Now -and $toVm.Count -gt 0) {
        $stamp = $nowUtc.ToString('yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        $plan = @(foreach ($vm in @($toVm.Keys)) {
                $hostState = @($Sidecar.Hosts | Where-Object { $_.Vm -eq $vm }) | Select-Object -First 1
                New-DemoRcaSidecarAckPlan -Vm $vm -OneAtATime:($null -ne $hostState -and [bool]$hostState.OneAtATime) -DocumentId $toVm[$vm].ToArray() -Stamp $stamp
            })
        $passes = @()
        try {
            $passes = @(Invoke-DemoRcaSidecarRunCommand -Config $Config -Plan $plan -Deadline $nowUtc.AddMinutes($Minutes) -PollSeconds $PollSeconds -HostDeleteWaitSeconds $HostDeleteWaitSeconds)
        }
        catch {
            if ($_.Exception -is [System.Management.Automation.PipelineStoppedException] -or ($_.Exception -is [System.OperationCanceledException] -and (Test-DemoRunCancelled))) {
                throw
            }
            $ackTrouble.Add(('The acknowledgements weren''t sent to the VMs ({0}); they go first at the next export.' -f (Protect-DemoText -Text $_.Exception.Message)))
        }
        foreach ($pass in $passes) {
            $vmPlan = @($plan | Where-Object { $_.Vm -eq $pass.Vm }) | Select-Object -First 1
            $ack = Get-DemoRcaSidecarAckAnswer -Pass $pass -Plan $vmPlan
            foreach ($id in $ack.Acked) {
                $sentNow.Add($id)
            }
            if ($ack.Why) {
                $ackTrouble.Add(('{0} acknowledgement(s) didn''t reach {1} ({2}); they go first at the next export there.' -f ($toVm[$pass.Vm].Count - @($ack.Acked).Count), $pass.Vm, $ack.Why.TrimEnd('.')))
            }
        }
    }
    $deferred = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($acknowledged.Keys)) {
        if ($sentNow.Contains($id)) {
            $null = $list.Acks.Remove($id)
            continue
        }
        $list.Acks[$id] = [ordered]@{ documentId = $id; vm = (& $vmOf $id); status = $acknowledged[$id]; recordedUtc = (Format-DemoRcaSidecarTime -Value $nowUtc) }
        $deferred.Add($id)
    }
    foreach ($entry in @($list.Acks.Values)) {
        # Moot 30 days on: the runner has deleted the sidecar by then.
        $recordedUtc = ConvertTo-DemoUtcDateTime -Value $entry['recordedUtc']
        if ($null -ne $recordedUtc -and $nowUtc -ge $recordedUtc.AddDays($script:RcaSidecarKeepDays)) {
            $null = $list.Acks.Remove([string]$entry['documentId'])
        }
    }

    # The pending list: what the VMs still offer, and what an earlier save listed on a VM this one didn't read whole.
    $complete = @($Sidecar.Hosts | Where-Object { $_.IndexComplete } | ForEach-Object { $_.Vm })
    $expired = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($list.Pending.Values)) {
        $id = [string]$entry['documentId']
        if ($acknowledged.Contains($id) -or $Sidecar.Gone.Contains($id)) {
            $null = $list.Pending.Remove($id)
            continue
        }
        if ($Sidecar.Offered.Contains($id)) {
            continue
        }
        $vm = [string]$entry['vm']
        if ($vm -in $complete) {
            # Its VM, read whole, no longer offers it: acknowledged another way, or past the runner's 30 days.
            if ($nowUtc -ge (ConvertTo-DemoUtcDateTime -Value $entry['expiresUtc'])) {
                $expired.Add($id)
            }
            $null = $list.Pending.Remove($id)
            continue
        }
        if ($nowUtc -ge (ConvertTo-DemoUtcDateTime -Value $entry['firstSeenUtc']).AddDays($script:RcaSidecarKeepDays)) {
            # Seen more than 30 days ago, so sealed before that: the runner has deleted it.
            $expired.Add($id)
            $null = $list.Pending.Remove($id)
            continue
        }
        $hostState = @($Sidecar.Hosts | Where-Object { $_.Vm -eq $vm }) | Select-Object -First 1
        if ($null -ne $hostState -and $hostState.Outcome -and $hostState.Message) {
            $entry['reason'] = & $trim ('not fetched: {0}' -f $hostState.Message)
        }
    }
    foreach ($reference in @($Sidecar.Offered.Values)) {
        $id = [string]$reference['documentId']
        if ($acknowledged.Contains($id) -or $Sidecar.Gone.Contains($id)) {
            continue
        }
        $reason = & $trim $(if ($Sidecar.Reasons.Contains($id)) { [string]$Sidecar.Reasons[$id] } else { 'not fetched: this save ended first' })
        if ($list.Pending.Contains($id)) {
            $list.Pending[$id]['reason'] = $reason
            continue
        }
        $window = Get-DemoRcaSidecarIdTime -DocumentId $id
        $list.Pending[$id] = [ordered]@{
            documentId = $id; vm = [string]$reference['vm']; sessionId = $reference['sessionId']; parts = [int]$reference['parts']; sha256 = [string]$reference['sha256']
            reason = $reason; firstSeenUtc = (Format-DemoRcaSidecarTime -Value $nowUtc); expiresUtc = (Format-DemoRcaSidecarTime -Value $(if ($null -ne $window) { $window.AddDays($script:RcaSidecarKeepDays) } else { $nowUtc.AddDays($script:RcaSidecarKeepDays) }))
        }
    }
    $notes = [System.Collections.Generic.List[string]]::new()
    foreach ($note in $Sidecar.Notes) {
        $notes.Add($note)
    }
    foreach ($problem in @(Save-DemoRcaSidecarList -List $list -Confirm:$false)) {
        $notes.Add($problem)
    }

    # The line.
    $pending = @($list.Pending.Values)
    $troubled = @($Sidecar.Hosts | Where-Object { [string]$_.Outcome -in 'OldBundle', 'OldRunner', 'Failed', 'TimedOut', 'NoRoom', 'Busy' })
    $fetched = @($Sidecar.Fetched.Keys)
    $vmsOf = { param([string[]] $Ids) @($Ids | ForEach-Object { & $vmOf $_ } | Select-Object -Unique) -join ' and ' }
    $sentences = [System.Collections.Generic.List[string]]::new()
    if ($fetched.Count -gt 0) {
        $lead = '{0} RCA sidecar(s) fetched from {1}' -f $fetched.Count, (& $vmsOf $fetched)
        if ($runs -gt 0) {
            $lead += ', {0} sent with {1} history run(s)' -f $sent, $runs
        }
        if ($written + $already -gt 0) {
            $lead += ': {0} written, {1} already in the history' -f $written, $already
        }
        $sentences.Add($lead + '.')
    }
    if ($sentNow.Count -gt 0) {
        $sentences.Add(('{0} acknowledged on {1}, which won''t offer them again.' -f $sentNow.Count, (& $vmsOf $sentNow.ToArray())))
    }
    if ($deferred.Count -gt 0) {
        $where = if ($Now) { 'wait for the next export on {0}, which sends them first' } else { 'wait for the next export on {0}, which sends them first, since the stop deallocated the VMs before the notebook ran' }
        $sentences.Add(('{0} acknowledgement(s) {1} ({2} lists them).' -f $deferred.Count, ($where -f (& $vmsOf $deferred.ToArray())), (Get-DemoRcaShownPath -Path ([string]$list.Paths.Acks))))
    }
    if ($Sidecar.Delivered.Count -gt 0) {
        $sentences.Add(('{0} acknowledgement(s) an earlier save deferred went to the VMs first.' -f $Sidecar.Delivered.Count))
    }
    foreach ($item in $ackTrouble) {
        $sentences.Add($item)
    }
    foreach ($hostState in $Sidecar.Hosts) {
        if ([string]$hostState.Outcome -in 'OldBundle', 'OldRunner', 'Failed', 'TimedOut', 'NoRoom', 'Busy', 'NotRunning' -and $hostState.Message) {
            $sentences.Add([string]$hostState.Message)
        }
        elseif ($hostState.AckError -and -not $hostState.Outcome) {
            $sentences.Add(('The acknowledgements an earlier save deferred didn''t all reach {0} ({1}); they go first at the next export there.' -f $hostState.Vm, $hostState.AckError.TrimEnd('.')))
        }
        # What its runner's index said itself (8afcca24): sidecars it let expire unread, which no save can take now.
        $runnerWarning = [string](Get-DemoMemberValue -InputObject $hostState -Name 'RunnerWarning')
        if ($runnerWarning) {
            $sentences.Add(('{0}''s runner says: {1}.' -f $hostState.Vm, $runnerWarning.TrimEnd('.')))
        }
    }
    if ($pending.Count -gt 0) {
        $groups = @($pending | Group-Object -Property { [string]$_['reason'] } | Sort-Object -Property Count -Descending)
        $said = @($groups | Select-Object -First 3 | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name }) -join '; '
        if ($groups.Count -gt 3) {
            $said += '; and {0} more' -f (@($groups | Select-Object -Skip 3 | Measure-Object -Property Count -Sum).Sum)
        }
        $sentences.Add(('{0} sidecar(s) wait on the VMs, which keep them: {1} ({2} lists them).' -f $pending.Count, $said, (Get-DemoRcaShownPath -Path ([string]$list.Paths.Pending))))
    }
    if ($expired.Count -gt 0) {
        $sentences.Add(('{0} sidecar(s) on the PC''s list are past the runner''s 30 days: deleted unread, unless a Run all saved and acknowledged them first.' -f $expired.Count))
    }
    if ($Sidecar.Error) {
        $sentences.Add($Sidecar.Error)
    }
    foreach ($note in $notes) {
        $sentences.Add($note)
    }
    $status = 'Pass'
    $ackFailed = $ackTrouble.Count -gt 0 -or @($Sidecar.Hosts | Where-Object { $_.AckError }).Count -gt 0
    $runnerWarned = @($Sidecar.Hosts | Where-Object { [string](Get-DemoMemberValue -InputObject $_ -Name 'RunnerWarning') })
    if ($pending.Count -gt 0 -or $expired.Count -gt 0 -or $troubled.Count -gt 0 -or $notes.Count -gt 0 -or $Sidecar.Error -or $ackFailed -or $runnerWarned.Count -gt 0) {
        $status = 'Warning'
    }
    elseif ($fetched.Count -eq 0 -and $Sidecar.Delivered.Count -eq 0 -and $deferred.Count -eq 0 -and @($Sidecar.Offered.Keys).Count -eq 0) {
        $status = 'Not selected'
    }
    if ($sentences.Count -eq 0 -or $fetched.Count -eq 0) {
        $lead = if (@($Sidecar.Hosts | Where-Object { [string]$_.Outcome -ne 'NoRunner' }).Count -eq 0) {
            'No workload runner was deployed, so there''s no RCA sidecar to fetch.'
        }
        elseif (@($Sidecar.Offered.Keys).Count -eq 0 -and @($Sidecar.Hosts | Where-Object { -not $_.Outcome }).Count -gt 0) {
            'No RCA sidecar to fetch: the VMs offered none.'
        }
        else {
            'No RCA sidecar was fetched.'
        }
        $sentences.Insert(0, $lead)
    }
    $message = Protect-DemoText -Text ($sentences -join ' ')
    $fixes = [System.Collections.Generic.List[string]]::new()
    if ($status -eq 'Warning') {
        if ($Sidecar.NotebookOld) {
            $fixes.Add(('Update the workspace''s NB_DatabaseHub_LiveActivity, which doesn''t know RCA_SIDECAR_FILE yet: {0}, which imports that notebook alone, edited or not, and saves the history again with the sidecars.' -f $script:RcaSidecarNotebookFix))
        }
        if (@($troubled | Where-Object { [string]$_.Outcome -in 'OldBundle', 'OldRunner' }).Count -gt 0) {
            $fixes.Add('Run ./scripts/deploy.ps1, which updates the runner and its bootstrap bundle on the VMs.')
        }
        if ($pending.Count -gt 0 -or $ackFailed -or @($troubled | Where-Object { [string]$_.Outcome -notin 'OldBundle', 'OldRunner' }).Count -gt 0) {
            $fixes.Add($(if ($Sidecar.CheckPrefix -eq 'STOP') { 'The next history save takes what waits: {0} while the VMs run, again while this line says sidecars wait, or ./scripts/stop-demo.ps1 -SaveHistory at the end of the next session.' -f $script:RcaRunAgain } else { 'The next history save takes what waits: {0} while the VMs run, again while this line says sidecars wait.' -f $script:RcaRunAgain }))
        }
        if ($expired.Count -gt 0 -or $runnerWarned.Count -gt 0) {
            $fixes.Add('Save the history within 30 days of each session, before the runner deletes its sidecars: ./scripts/stop-demo.ps1 -SaveHistory at the end of a session from the scripts; after Run all sessions, whose sidecars Run all saves but only the next Run all''s start acknowledges, a Run all within 30 days, or ./scripts/start-demo.ps1, then ./scripts/stop-demo.ps1 -SaveHistory.')
        }
    }
    $evidence = [ordered]@{
        fetched      = $fetched.Count
        sent         = $sent
        runs         = $runs
        written      = $written
        already      = $already
        skipped      = $skipped
        acknowledged = $sentNow.Count
        deferred     = $deferred.Count
        delivered    = $Sidecar.Delivered.Count
        pending      = $pending.Count
        expired      = $expired.Count
        runner       = @($runnerWarned | ForEach-Object { '{0}: {1}' -f $_.Vm, [string]$_.RunnerWarning })
        hosts        = @($Sidecar.Hosts | ForEach-Object { '{0}: {1}' -f $_.Vm, $(if ($_.Outcome) { $_.Outcome } elseif ($_.IndexComplete) { 'Read' } else { 'Partial' }) })
        payloads     = @($Sidecar.Batches | Where-Object { $_.Path } | ForEach-Object { [string]$_.Path })
    }
    return (New-DemoResult -CheckId $checkId -Area 'workload' -Target 'subscription' -Status $status -Message $message -Evidence $evidence -Remediation ($fixes -join ' ') -DocUrl $script:RcaRunCommandDoc)
}
#endregion
