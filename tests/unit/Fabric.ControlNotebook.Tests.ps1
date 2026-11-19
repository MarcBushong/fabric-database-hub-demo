BeforeAll {
    # The session control notebook (ADR 0026; ADR 0020 before it): fabric/control/NB_DatabaseHub_Control.ipynb. Its
    # requests are checked against the runbook's own validation (automation/runbooks/DbHubControl.Common.ps1), its KQL
    # against scripts/modules/DbHubDemo/Kql/Live.*.kql, and its Run all against a stand-in for the vault, the webhook and the
    # runbook behind it, the Fabric REST API, and a clock, so a whole session runs offline in a second.
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    Import-Module -Name (Join-Path -Path $repoRoot -ChildPath 'scripts/modules/DbHubDemo/DbHubDemo.psd1') -Force
    $script:path = Join-Path -Path $repoRoot -ChildPath 'fabric/control/NB_DatabaseHub_Control.ipynb'
    $script:raw = [System.IO.File]::ReadAllText($script:path)
    $script:notebook = $script:raw | ConvertFrom-Json -AsHashtable -Depth 64
    $script:cells = @($script:notebook['cells'] | ForEach-Object { [pscustomobject]@{ Type = $_['cell_type']; Id = $_['id']; Metadata = $_['metadata']; Cell = $_; Source = (@($_['source']) -join '') } })
    $script:code = @($script:cells | Where-Object Type -EQ 'code')
    $script:allCode = ($script:code | ForEach-Object Source) -join "`n"
    $script:parameters = @($script:code | Where-Object { @($_.Metadata['tags']) -contains 'parameters' })

    $config = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
    $config['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
    $script:config = $config
    $script:settingsJson = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $config } {
        ConvertTo-Json -InputObject (Get-DemoActivityControlRunbookSetting -Config $Config -Name (Get-DemoActivityControlName -Config $Config) -IdentityClientId '99999999-9999-9999-9999-999999999999') -Depth 16 -Compress
    }
    $settings = $script:settingsJson | ConvertFrom-Json -AsHashtable
    $session = InModuleScope -ModuleName DbHubDemo -Parameters @{ Setting = $settings } { Get-DemoActivityControlSessionRule -Setting $Setting }
    $script:catalogJson = ConvertTo-Json -InputObject ([ordered]@{ targets = @($settings['targets'].Keys); scenarios = $settings['scenarios']; profiles = $settings['profiles']; minDurationMinutes = $settings['minDurationMinutes']; maxDurationMinutes = $settings['maxDurationMinutes']; session = $session }) -Depth 8 -Compress
    . (Join-Path -Path $repoRoot -ChildPath 'automation/runbooks/DbHubControl.Common.ps1')
    $script:runbookSettings = ConvertFrom-DbHubSetting -Json $script:settingsJson

    $script:python = $null
    foreach ($candidate in 'python3', 'python') {
        $command = Get-Command -Name $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            $PSNativeCommandUseErrorActionPreference = $false
            $null = & $command.Source --version 2>&1
            if ($LASTEXITCODE -eq 0) {
                $script:python = $command.Source
                break
            }
        }
    }
    # The helpers that use pandas need a Python 3 that has it; DBHUB_TEST_PYTHON can name one (Phase 25b).
    $script:pandasPython = if ($env:DBHUB_TEST_PYTHON) { $env:DBHUB_TEST_PYTHON } else { $script:python }

    function Get-Cell([string] $Heading) {
        @($script:code | Where-Object { $_.Source.StartsWith($Heading) })[0].Source
    }

    function Get-KqlFileBody([string] $Name) {
        $lines = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath ('scripts/modules/DbHubDemo/Kql/{0}' -f $Name))
        (@($lines | Where-Object { $_.Trim() -and $_ -notmatch '^\s*//' }) -join "`n").Trim()
    }

    # The notebook as deploy.ps1 imports it, for a demo whose VMs shut down at 19:00 in the zone given.
    function Get-FilledNotebook([string] $Zone = 'UTC', [string] $Prefix = '') {
        $filledConfig = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $filledConfig['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $filledConfig['autoShutdownTime'] = '1900'
        $filledConfig['autoShutdownTimeZone'] = $Zone
        if ($Prefix) {
            $filledConfig['prefix'] = $Prefix
        }
        $definition = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $filledConfig } {
            $controlName = Get-DemoActivityControlName -Config $Config
            $setting = Get-DemoActivityControlRunbookSetting -Config $Config -Name $controlName -IdentityClientId '99999999-9999-9999-9999-999999999999'
            Get-DemoActivityControlNotebook -Name $controlName -Setting $setting -TenantId 'AAAAAAAA-0000-0000-0000-000000000001' -DemoWorkspaceId 'BBBBBBBB-0000-0000-0000-000000000002' -DemoLakehouseId 'CCCCCCCC-0000-0000-0000-000000000003' -DemoLakehouseName 'LH_DatabaseHub'
        }
        $file = Join-Path -Path $TestDrive -ChildPath ('filled-{0}{1}.ipynb' -f ($Zone -replace '[^A-Za-z]', ''), $Prefix)
        [System.IO.File]::WriteAllBytes($file, [System.Convert]::FromBase64String($definition.Definition['parts'][0]['payload']))
        return $file
    }

    # The filled notebook with the live view of 76cdb12 (2026-11-16), from before it read the session's status again: a
    # copy deployed before, beside runbooks that add a host's failure to the status.
    function Get-OldLiveViewNotebook {
        $old = @'
# Live view: read-only telemetry queries and each beat as it begins, until the session's end (WAIT_FOR_END) or for
# WATCH_MINUTES.
refresh = min(max(int(REFRESH_SECONDS), 30), 300)
view_end = None
if FOLLOWING and WAIT_FOR_END and (LAST_STATUS or {}).get("phase") == "running":
    view_end = parse_utc(LAST_STATUS.get("runEndUtc"))
elif GO and MODE != "check" and (FOLLOWING or JOBS):
    view_end = dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=max(int(WATCH_MINUTES), 0))
if view_end is not None:
    announced, telemetry = set(), True
    while True:
        now = dt.datetime.now(dt.timezone.utc)
        for beat in BEATS:
            key = (beat["target"], beat["scenario"], beat["startUtc"])
            if beat["startUtc"] <= now and key not in announced:
                announced.add(key)
                if now - beat["startUtc"] < dt.timedelta(seconds=refresh * 2):
                    print("Now: %s %s, until %s; in Database Hub from about %s." % (beat["target"], beat["title"], clock(beat["endUtc"], CATALOG),
                          clock(beat["startUtc"] + dt.timedelta(minutes=T4_SHOWS_MINUTES if beat["target"] == "T4" else SQL_SHOWS_MINUTES), CATALOG)))
        if telemetry:
            frames, message = live_snapshot(LOOKBACK_MINUTES)
            print("=== %s UTC, the last %d minutes" % (now.strftime("%H:%M"), int(LOOKBACK_MINUTES)))
            if frames is None:
                print(message)
                telemetry = False
            else:
                show_snapshot(frames)
        left = (view_end - dt.datetime.now(dt.timezone.utc)).total_seconds()
        if left <= 0:
            break
        time.sleep(min(refresh, left))
'@
        $notebook = Get-Content -LiteralPath (Get-FilledNotebook -Zone 'UTC') -Raw | ConvertFrom-Json -AsHashtable
        $cell = @($notebook['cells'] | Where-Object { $_['cell_type'] -eq 'code' -and ($_['source'] -join '').StartsWith('# Live view:') })
        $cell.Count | Should -Be 1
        $lines = $old.Replace("`r`n", "`n").TrimEnd("`n") -split "`n"
        $cell[0]['source'] = @(for ($index = 0; $index -lt $lines.Count; $index++) { if ($index -lt $lines.Count - 1) { $lines[$index] + "`n" } else { $lines[$index] } })
        $file = Join-Path -Path $TestDrive -ChildPath 'filled-old-live-view.ipynb'
        [System.IO.File]::WriteAllText($file, (ConvertTo-Json -InputObject $notebook -Depth 32), [System.Text.UTF8Encoding]::new($false))
        return $file
    }

    # Runs every code cell of a filled notebook with stand-ins (no network call leaves the process) and returns what it sent,
    # the histories it saved (reference runs) or started as jobs, the order of both, and what it printed.
    $script:simulator = Join-Path -Path $TestDrive -ChildPath 'simulate_control.py'
    Set-Content -LiteralPath $script:simulator -Encoding utf8NoBOM -Value @'
import contextlib
import datetime as real_dt
import io
import json
import sys
import types

UTC = real_dt.timezone.utc
notebook = json.load(open(sys.argv[1], encoding="utf-8"))
scenario = sys.argv[2]
code = ["".join(cell["source"]) for cell in notebook["cells"] if cell["cell_type"] == "code"]


class Clock:
    now = real_dt.datetime.fromisoformat(sys.argv[3].replace("Z", "+00:00"))
    mono = 1000.0


class FakeDateTime(real_dt.datetime):
    @classmethod
    def now(cls, tz=None):
        return Clock.now if tz is None else Clock.now.astimezone(tz)


fake_dt = types.ModuleType("fake_datetime")
fake_dt.datetime, fake_dt.timedelta, fake_dt.timezone = FakeDateTime, real_dt.timedelta, real_dt.timezone
fake_time = types.ModuleType("fake_time")


def _sleep(seconds):
    Clock.now += real_dt.timedelta(seconds=float(seconds))
    Clock.mono += float(seconds)


fake_time.sleep, fake_time.monotonic = _sleep, lambda: Clock.mono


def iso(value):
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


SENT, JOBS, REFS, VALIDATORS, ORDER, REFUSED, JOBREADS, STOPS, STATUSREADS, SECRET_URL = [], [], [], [], [], [0], [0], [0], [0], "https://example.webhook.azure-" + "automation.net/webhooks?token=" + "x" * 40
VAULT = {"dbhub-session-status": "{}", "dbhub-session-metrics": "{}", "dbhub-activity-webhook": SECRET_URL}
RUNBOOK = {"session": None, "accepted": None, "minutes": 0}
# The control notebook's default lakehouse, which deploy.ps1 attaches: none in "unbound" and "full".
LAKEHOUSE = "" if scenario in ("unbound", "full") else "cccccccc-0000-0000-0000-000000000003"


def running_status(session_id, accepted, minutes):
    end = accepted + real_dt.timedelta(minutes=minutes)
    dispatch = accepted + real_dt.timedelta(minutes=4)
    return {"schemaVersion": 1, "sessionId": session_id, "phase": "running", "acceptedUtc": iso(accepted), "runEndUtc": iso(end),
            "autoStopUtc": iso(end + real_dt.timedelta(minutes=10)), "durationMinutes": minutes, "plannedMinutes": minutes,
            "names": {"resourceGroup": "rg-dbhub-demo", "deploymentId": "abc123", "sqlVm": "sqlvm01", "t2Guest": "arcsql01",
                      "t3Server": "azuresql01-abc123", "t3Database": "ContosoCare", "t4Server": "pgflex01-abc123", "t4Replica": "pgreplica01-abc123"},
            "dispatchUtc": {"T1": iso(dispatch), "T3": iso(dispatch), "T2": iso(dispatch + real_dt.timedelta(minutes=6)), "T4": iso(dispatch + real_dt.timedelta(minutes=5))},
            "t4": {"state": "Ready", "sku": "Standard_D4ds_v5", "tier": "GeneralPurpose"},
            "replica": {"state": "Ready", "note": "", "fix": ""},
            "replicaLag": {"planned": True, "note": "Read replica lag climbs to about 3 minutes, twice.", "fix": ""},
            "steps": [{"step": "Plan", "state": "Pass", "atUtc": iso(accepted), "message": "The showcase runs %d minutes on every target." % minutes, "fix": ""},
                      {"step": "Activity", "state": "Pass", "atUtc": iso(dispatch), "message": "T1: showcase for %d minutes" % minutes, "fix": ""}],
            "message": "The session runs until %s UTC." % iso(end)}


if scenario in ("active", "stopnow"):
    RUNBOOK.update(session="a" * 32, accepted=Clock.now - real_dt.timedelta(minutes=20), minutes=90)
    VAULT["dbhub-session-status"] = json.dumps(running_status("a" * 32, RUNBOOK["accepted"], 90))
if scenario == "leftover":
    earlier = Clock.now - real_dt.timedelta(days=1)
    # The runbook writes the metrics compact (ConvertTo-Json -Compress).
    VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": "e" * 32, "capturedUtc": iso(earlier), "startUtc": iso(earlier - real_dt.timedelta(minutes=100)),
                                                 "endUtc": iso(earlier), "windowMinutes": 100, "intervalMinutes": 1, "servers": [], "series": [{"metric": "cpu_percent"}]}, separators=(",", ":"))


def runbook(body):
    action = body["action"]
    if action == "session":
        if scenario == "refused":
            VAULT["dbhub-session-status"] = json.dumps({"sessionId": body["sessionId"], "phase": "refused", "message": "A run is already active: it ends at 15:00.",
                                                        "steps": [{"step": "Start", "state": "Fail", "atUtc": iso(Clock.now), "message": "A run is already active: it ends at 15:00.", "fix": "Wait until it ends, or run the notebook's Stop now cell first."}]})
            return
        RUNBOOK.update(session=body["sessionId"], accepted=Clock.now, minutes=body["durationMinutes"])
        VAULT["dbhub-session-status"] = json.dumps({"sessionId": body["sessionId"], "phase": "starting", "acceptedUtc": iso(Clock.now), "steps": []})
    elif action == "stop":
        session = body.get("sessionId") or ""
        VAULT["dbhub-session-status"] = json.dumps({"sessionId": session, "phase": "stopped", "stoppedBy": "Stop now", "failed": [],
                                                    "done": ["T4's read replica deleted", "T4 stopped", "sqlvm01 deallocated"], "metrics": {"status": "Pass", "message": "Azure Monitor metrics for the history."}})
        if session:
            accepted = RUNBOOK["accepted"] or Clock.now
            VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": session, "capturedUtc": iso(Clock.now), "startUtc": iso(accepted), "endUtc": iso(Clock.now),
                                                         "windowMinutes": 90, "intervalMinutes": 1, "servers": [], "series": [{"metric": "cpu_percent"}]}, separators=(",", ":"))


HOST_WARNING = {"step": "Host", "state": "Warning", "message": "T2: archost01 is deallocated, so T2 has no activity now.",
                "fix": "The session's other targets go on. For T2: set STOP_NOW = True and Run all, then Run all again, which starts archost01 again; ./scripts/status.ps1 shows its state."}


def vault_read(name):
    if name == "dbhub-session-status":
        STATUSREADS[0] += 1
    if name == "dbhub-session-status" and RUNBOOK["session"]:
        current = json.loads(VAULT[name])
        if current.get("phase") == "starting" and Clock.now - RUNBOOK["accepted"] >= real_dt.timedelta(seconds=60):
            VAULT[name] = json.dumps(running_status(RUNBOOK["session"], RUNBOOK["accepted"], RUNBOOK["minutes"]))
        elif scenario == "hostfail" and current.get("phase") == "running" and Clock.now - RUNBOOK["accepted"] >= real_dt.timedelta(minutes=40) \
                and not any(step.get("step") == "Host" for step in current.get("steps") or []):
            # DbHub-Monitor's re-check (2026-11-16): the same status, with the host that stopped, and the new runCommands field.
            current["steps"].append(dict(HOST_WARNING, atUtc=iso(Clock.now)))
            current["runCommands"] = [{"vm": "archost01", "name": "DbHubControl-archost01-x", "targets": ["T2"]}]
            VAULT[name] = json.dumps(current)
    return VAULT[name]


class Credentials:
    def getSecret(self, vault, name):
        return vault_read(name)

    def getToken(self, audience):
        return "simulated-" + audience


class Notebook:
    """notebookutils.notebook: a reference run takes 4 minutes, in "refail" it fails as Fabric's lakehouse check would.
    The validator (NB_DatabaseHub_Deployment) takes 70 seconds: in "valfail" it fails, in "valslow" it passes its timeout."""
    def run(self, path, timeout_seconds=90, arguments=None, workspace=""):
        arguments = dict(arguments or {})
        if path == "NB_DatabaseHub_Deployment":
            VALIDATORS.append({"path": path, "timeout": timeout_seconds, "workspace": workspace, "args": arguments})
            ORDER.append("validator")
            if scenario == "valfail":
                raise RuntimeError("Notebook execution failed in cell 12: the telemetry endpoint didn't answer.")
            if scenario == "valslow":
                _sleep(timeout_seconds)
                raise RuntimeError("The notebook run didn't finish in %d seconds." % timeout_seconds)
            _sleep(70)
            return ""
        REFS.append({"path": path, "timeout": timeout_seconds, "workspace": workspace, "args": arguments})
        ORDER.append("history:" + str(arguments.get("SESSION_ID", ""))[:8])
        if scenario == "refail":
            raise RuntimeError("The referenced notebook's default lakehouse differs from the caller's.")
        if scenario in ("queued", "queuedjob"):
            # Live, 2026-11-16: Fabric's reference run failed on a cell's result, and the job then queued behind this session.
            raise RuntimeError("Unrecognized token 'REDACTED': was expecting (JSON String, Number, Array, Object or token 'null', 'true' or 'false')")
        _sleep(240)
        return ""


class Response:
    def __init__(self, status, body=None, location=""):
        self.status_code, self._body, self.headers = status, body, {"Location": location} if location else {}
        self.content = b"" if body is None else json.dumps(body).encode("utf-8")

    def json(self):
        if self._body is None:
            raise ValueError("no body")
        return self._body


fake_requests = types.ModuleType("requests")


class RequestException(Exception):
    pass


fake_requests.RequestException = RequestException
FABRIC = "https://api.fabric.microsoft.com/v1"


def post(url, data=None, headers=None, timeout=None, json=None):
    if url == SECRET_URL:
        body = __import__("json").loads(data)
        SENT.append(body)
        ORDER.append("sent:" + body["action"])
        runbook(body)
        return Response(202, {"JobIds": ["job-%d" % len(SENT)]})
    if "arcdataservices.com" in url:
        return Response(401, {})
    raise AssertionError("unexpected POST " + url)


def request(method, url, json=None, headers=None, timeout=None):
    # No capacity call: the control never checks, starts, or pauses the capacity (the user, 2026-11-14).
    assert url.startswith(FABRIC + "/"), url
    if method == "GET" and "/items?type=" in url:
        names = {"Notebook": [("NB_DatabaseHub_LiveActivity", "nb-1")], "Report": [("RPT_DatabaseHub_History", "RPT-1")], "KQLDashboard": []}[url.split("type=")[1]]
        return Response(200, {"value": [{"displayName": name, "id": item} for name, item in names]})
    if method == "POST" and url.endswith("/items/nb-1/jobs/instances?jobType=RunNotebook"):
        if scenario == "full":
            REFUSED[0] += 1
            return Response(430, {"errorCode": "TooManyRequestsForCapacity", "message": "This Spark job can't be run because you have hit a Spark compute or API rate limit."})
        JOBS.append({key: value["value"] for key, value in json["executionData"]["parameters"].items()})
        ORDER.append("job:" + JOBS[-1].get("SESSION_ID", "")[:8])
        return Response(202, None, FABRIC + "/workspaces/x/items/nb-1/jobs/instances/run-%d" % len(JOBS))
    if method == "GET" and "/jobs/instances/run-" in url:
        JOBREADS[0] += 1
        return Response(200, {"status": "NotStarted" if scenario in ("queued", "queuedjob") else "Completed"})
    raise AssertionError("unexpected %s %s" % (method, url))


fake_requests.post, fake_requests.request = post, request


def stop_session():
    # notebookutils.session.stop(): no code runs after it, so it must be the notebook's last statement.
    STOPS[0] += 1
    ORDER.append("session.stop")

sys.modules["requests"] = fake_requests
sys.modules["pandas"] = types.ModuleType("pandas")
# Run all in the notebook editor is an interactive session; "queuedjob" is a scheduled or pipeline run.
namespace = {"notebookutils": types.SimpleNamespace(credentials=Credentials(), notebook=Notebook(), session=types.SimpleNamespace(stop=stop_session),
                                                   runtime=types.SimpleNamespace(context={"currentWorkspaceId": "dddddddd-0000-0000-0000-000000000004", "defaultLakehouseId": LAKEHOUSE,
                                                                                          "isForInteractive": scenario != "queuedjob"}))}
buffer = io.StringIO()
error = ""
with contextlib.redirect_stdout(buffer):
    try:
        exec(code[0], namespace)
        namespace.update({"stopnow": {"STOP_NOW": True}, "check": {"MODE": "check"}, "nowait": {"WAIT_FOR_END": False}}.get(scenario, {}))
        for index, source in enumerate(code[1:], start=1):
            exec(source, namespace)
            if index == 2:
                namespace["dt"], namespace["time"] = fake_dt, fake_time
    except Exception as failure:
        error = "%s: %s" % (type(failure).__name__, failure)
printed = buffer.getvalue()
print(json.dumps({"sent": SENT, "jobs": JOBS, "refs": REFS, "validators": VALIDATORS, "order": ORDER, "refused": REFUSED[0], "jobReads": JOBREADS[0], "stops": STOPS[0], "statusReads": STATUSREADS[0], "vaultMetrics": VAULT["dbhub-session-metrics"], "printed": printed, "error": error, "leaked": SECRET_URL.split("token=")[1] in printed}))
'@

    function Invoke-Simulation([string] $Path, [string] $Scenario, [string] $Start) {
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $script:simulator $Path $Scenario $Start 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($output -join "`n")
        }
        return (($output | Select-Object -Last 1) | ConvertFrom-Json)
    }
}

Describe 'NB_DatabaseHub_Control' {
    It 'is nbformat 4.5 in the form the nbstripout hook writes: no outputs, no execution counts, cell IDs 0 to N-1' {
        $script:notebook['nbformat'] | Should -Be 4
        $script:notebook['nbformat_minor'] | Should -Be 5
        $script:cells.Id | Should -Be @(0..($script:cells.Count - 1) | ForEach-Object { [string]$_ })
        foreach ($cell in $script:code) {
            @($cell.Cell['outputs']).Count | Should -Be 0
            $cell.Cell['execution_count'] | Should -BeNullOrEmpty
        }
        $script:raw | Should -Not -Match "`r"
        $script:notebook['metadata'].Contains('widgets') | Should -BeFalse
    }

    It 'runs on the PySpark kernel, and its repository copy names no lakehouse: deploy.ps1 attaches the demo''s at import' {
        $script:notebook['metadata']['kernelspec']['name'] | Should -Be 'synapse_pyspark'
        $script:notebook['metadata']['language_info']['name'] | Should -BeExactly 'python'
        $script:notebook['metadata'].Contains('dependencies') | Should -BeFalse
        # The notebook itself reads and writes no table: the activity notebook saves the history, in this session.
        $script:raw | Should -Not -Match 'default_lakehouse|saveAsTable|spark\.sql|spark\.read'
        foreach ($cell in $script:code) {
            $cell.Metadata['microsoft']['language'] | Should -Be 'python'
            $cell.Metadata['microsoft']['language_group'] | Should -Be 'synapse_pyspark'
        }
    }

    It 'has one parameters cell, first among the code cells: Run all runs a whole session with nothing to edit, and the environment values are empty in the repository' {
        $script:parameters.Count | Should -Be 1
        $script:code[0].Id | Should -Be $script:parameters[0].Id
        $source = $script:parameters[0].Source
        # The user (2026-11-14): one notebook, one Run all, that does everything; nothing to switch first.
        $source | Should -Match '(?m)^MODE = "session"\s'
        $source | Should -Match '(?m)^WAIT_FOR_END = True\s'
        $source | Should -Match '(?m)^DURATION_MINUTES = 90\s'
        $source | Should -Not -Match '(?m)^CONFIRM = '
        foreach ($switchName in 'STOP_NOW', 'RESET_NOW') {
            $source | Should -Match ('(?m)^{0} = False\s*$' -f $switchName)
        }
        foreach ($target in 'T1', 'T2', 'T3', 'T4') {
            $source | Should -Match ('(?m)^\s+\{{"target": "{0}", "scenario": "showcase"\}},\s*$' -f $target)
        }
        $source | Should -Match '(?m)^WATCH_MINUTES = 30\s'
        foreach ($empty in 'KEY_VAULT_URL', 'CATALOG_JSON', 'SHOWCASE_JSON', 'TENANT_ID', 'DEMO_WORKSPACE_ID', 'DEMO_LAKEHOUSE_ID') {
            $source | Should -Match ('(?m)^{0} = ""' -f $empty)
        }
        $source | Should -Match '(?m)^WEBHOOK_SECRET_NAME = "dbhub-activity-webhook"'
        $source | Should -Match '(?m)^STATUS_SECRET_NAME = "dbhub-session-status"'
        $source | Should -Match '(?m)^METRICS_SECRET_NAME = "dbhub-session-metrics"'
    }

    It 'holds no secret, and sets only the secrets'' names' {
        foreach ($pattern in 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.', '(?i)webhooks\?token=[A-Za-z0-9%]', '(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{20,}', '(?i)\b(?:password|pwd)\s*=\s*[^\s;"''{]+') {
            $script:raw | Should -Not -Match $pattern
        }
        foreach ($cell in $script:cells) {
            Protect-DemoText -Text $cell.Source | Should -BeExactly $cell.Source
        }
        foreach ($assignment in [regex]::Matches($script:allCode, '(?m)^\s*([A-Z_]*(?:TOKEN|SECRET|PASSWORD|WEBHOOK)[A-Z_]*)\s*=\s*["'']([^"'']+)["'']')) {
            $assignment.Groups[1].Value | Should -Match '_NAME$'
        }
    }

    It 'reads the webhook URL from Key Vault for one request, and the session''s status and metrics as JSON, and never prints, returns, or keeps a secret' {
        @([regex]::Matches($script:allCode, 'getSecret\(')).Count | Should -Be 2
        $script:allCode | Should -Match 'url = utils\.credentials\.getSecret\(KEY_VAULT_URL, WEBHOOK_SECRET_NAME\)'
        $script:allCode | Should -Match '(?s)finally:\s+url = None'
        $script:allCode | Should -Match 'text = utils\.credentials\.getSecret\(KEY_VAULT_URL, name\)'
        foreach ($use in [regex]::Matches($script:allCode, '(?<!def )\bread_secret_json\(([^)]*)\)')) {
            $use.Groups[1].Value | Should -BeIn @('STATUS_SECRET_NAME', 'METRICS_SECRET_NAME')
        }
        $script:allCode | Should -Not -MatchExactly '(?m)\bprint\([^\n]*\b(url|token|getSecret|getToken)\b'
        $script:allCode | Should -Not -MatchExactly '(?m)^\s*return[^\n]*\burl\b'
        # The status's and metrics' values are parsed, never printed: read_secret_json prints nothing itself.
        [regex]::Match($script:allCode, '(?ms)^def read_secret_json\(.*?(?=^def )').Value | Should -Not -Match '\bprint\('
        foreach ($function in 'send_request', 'read_secret_json') {
            $body = [regex]::Match($script:allCode, ('(?ms)^def {0}\(.*?(?=^def )' -f $function)).Value
            $body | Should -Match 'type\(error\)\.__name__' -Because 'an error prints its type only'
            $body | Should -Not -Match '\b(str|repr|redact)\(error\)|%\s*error\b|\+\s*error\b'
        }
    }

    It 'asks only for the pbi and kusto tokens, and sends requests only to documented hosts' {
        foreach ($use in [regex]::Matches($script:allCode, '(?<!def )\bget_token\(([^)]*)\)')) {
            $use.Groups[1].Value | Should -BeIn @('"pbi"', '"kusto"', 'audience')
        }
        $script:allCode | Should -Match 'if audience not in \("pbi", "kusto"\):'
        $script:allCode | Should -Match 'if not url\.startswith\(FABRIC_API \+ "/"\):'
        $script:allCode | Should -Not -Match 'mssparkutils|management\.azure\.com|api\.github\.com|workflow_dispatch'
        $allowed = '^(adx\.centralus\.arcdataservices\.com|dataexplorer\.azure\.com|powerbi\.com|learn\.microsoft\.com|api\.fabric\.microsoft\.com|app\.fabric\.microsoft\.com)$'
        foreach ($url in [regex]::Matches($script:raw, 'https://([^/"''\s\\)]+)')) {
            if ($url.Groups[1].Value -match '[<\[]|azure-automation\\?\.net|vault\\?\.azure\\?\.net') {
                continue
            }
            $url.Groups[1].Value | Should -Match $allowed
        }
    }

    It 'marks every cell that sends a request to the webhook as resource-changing' {
        $flagged = 0
        foreach ($cell in $script:code) {
            $topLevel = [regex]::Replace($cell.Source, '(?ms)^def \w+\(.*?(?=^\S|\z)', '')
            if ($topLevel -match '\b(send_request|finish_session)\(') {
                $flagged++
                $cell.Source | Should -Match '^# Resource-changing:'
            }
        }
        $flagged | Should -Be 3 -Because 'the start, the end, and Stop now and Reset'
        (Get-Cell '# Resource-changing: Stop now and Reset') | Should -Match '(?m)^if STOP_NOW:'
        (Get-Cell '# Resource-changing: Stop now and Reset') | Should -Match '(?m)^if RESET_NOW:'
    }

    It 'queries the same KQL as Kql/<File>' -ForEach @(
        @{ Variable = 'CPU_SUMMARY_BODY'; File = 'Live.CpuSummary.kql' }
        @{ Variable = 'WAITS_BODY'; File = 'Live.WaitDeltas.kql' }
        @{ Variable = 'GAUGES_BODY'; File = 'Live.CounterGauges.kql' }
    ) {
        $body = [regex]::Match($script:allCode, ('(?s){0} = """(.*?)"""' -f $Variable)).Groups[1].Value.Trim()
        $body | Should -Not -BeNullOrEmpty
        $body | Should -BeExactly (Get-KqlFileBody $File)
        @($body -split "`n" | Where-Object { $_ -match '^\s*\|\s*where\b' })[0] | Should -Match 'SampleTimeUTC'
    }

    It 'compiles as Python 3.10, the oldest Fabric Spark runtime language level' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $check = Join-Path -Path $TestDrive -ChildPath 'compile_cells.py'
        Set-Content -LiteralPath $check -Encoding utf8NoBOM -Value @'
import ast, json, sys
notebook = json.load(open(sys.argv[1], encoding="utf-8"))
for index, cell in enumerate(notebook["cells"]):
    if cell["cell_type"] == "code":
        ast.parse("".join(cell["source"]), filename="cell-%d" % index, feature_version=(3, 10))
print("ok")
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $check $script:path 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
    }

    It 'builds only requests that the runbook accepts, and refuses what the runbook refuses' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # Helpers part 1 has no network calls and needs no pandas, so any Python 3 runs it.
        $helpers = Join-Path -Path $TestDrive -ChildPath 'helpers_part1.py'
        Set-Content -LiteralPath $helpers -Encoding utf8NoBOM -Value (Get-Cell '# Helpers, part 1')
        $catalogFile = Join-Path -Path $TestDrive -ChildPath 'catalog.json'
        Set-Content -LiteralPath $catalogFile -Encoding utf8NoBOM -Value $script:catalogJson
        $driver = Join-Path -Path $TestDrive -ChildPath 'build_requests.py'
        Set-Content -LiteralPath $driver -Encoding utf8NoBOM -Value @'
import json, sys
exec(open(sys.argv[1], encoding="utf-8").read())
catalog = load_catalog(open(sys.argv[2], encoding="utf-8").read())
sid = "0123456789abcdef0123456789abcdef"
cases = [
    ("run", dict(activities=[{"target": "T1", "scenario": "blocking-chain"}], duration_minutes=20)),
    ("run", dict(activities=[{"target": "T1", "scenario": "deadlock-storm", "intensity": 8, "concurrency": 3},
                             {"target": "T2", "scenario": "baseline"}, {"target": "T3", "scenario": "cpu-pressure"}], duration_minutes=120)),
    ("stop", dict()),
    ("reset", dict(reset_targets=["T2"])),
    ("reset", dict()),
    ("run", dict(activities=[{"target": "T1", "scenario": "baseline"}], duration_minutes=4)),
    ("run", dict(activities=[{"target": "T1", "scenario": "baseline"}], duration_minutes=20.5)),
    ("run", dict(activities=[{"target": "T1", "scenario": "drop-database"}], duration_minutes=20)),
    ("run", dict(activities=[{"target": "T1", "scenario": "baseline"}, {"target": "T1", "scenario": "cpu-pressure"}], duration_minutes=20)),
    ("run", dict(activities=[{"target": "T1", "scenario": "blocking-chain", "concurrency": 5}], duration_minutes=20)),
    ("run", dict(activities=[{"target": "T1", "scenario": "baseline", "sql": "select 1"}], duration_minutes=20)),
    ("reset", dict(reset_targets=["T1", "T1"])),
    ("run", dict(activities=[{"target": "T1", "scenario": "cpu-pressure"}, {"target": "T3", "scenario": "blocking-chain"}], duration_minutes=10)),
    ("run", dict(activities='[{"target": "T1", "scenario": "cpu-pressure"}, {"target": "T3", "scenario": "blocking-chain"}]', duration_minutes=10)),
    ("reset", dict(reset_targets='["T1", "T3"]')),
    ("reset", dict(reset_targets="")),
    ("run", dict(activities="T1 cpu-pressure", duration_minutes=10)),
    ("run", dict(activities='{"target": "T1", "scenario": "baseline"}', duration_minutes=10)),
    ("run", dict(activities='["T1"]', duration_minutes=10)),
    ("run", dict(activities=[{"target": t, "scenario": "showcase"} for t in ("T1", "T2", "T3", "T4")], duration_minutes=90)),
    ("run", dict(activities=[{"target": "T1", "scenario": "showcase"}, {"target": "T2", "scenario": "off"}], duration_minutes=120)),
    ("run", dict(activities=[{"target": "T1", "scenario": "showcase", "intensity": 5}], duration_minutes=90)),
    ("run", dict(activities=[{"target": "T1", "scenario": "off"}], duration_minutes=20)),
    ("run", dict(activities=[{"target": "T1", "scenario": "business-day"}], duration_minutes=20)),
    ("session", dict(session_id=sid, duration_minutes=90)),
    ("capture", dict(session_id=sid)),
    ("stop", dict(session_id=sid)),
    ("session", dict(duration_minutes=90)),
    ("session", dict(session_id=sid, duration_minutes=20)),
    ("session", dict(session_id=sid.upper(), duration_minutes=90)),
    ("run", dict(activities=[{"target": "T1", "scenario": "baseline"}], duration_minutes=20, session_id=sid)),
]
out = []
for action, kwargs in cases:
    try:
        out.append({"ok": True, "body": json.dumps(build_request(action, catalog=catalog, **kwargs), separators=(",", ":"))})
    except ValueError as error:
        out.append({"ok": False, "error": str(error)})
print(json.dumps(out))
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $driver $helpers $catalogFile 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $results = ($output | Select-Object -Last 1) | ConvertFrom-Json
        @($results | ForEach-Object ok) | Should -Be @($true, $true, $true, $true, $true, $false, $false, $false, $false, $false, $false, $false, $true, $true, $true, $true, $false, $false, $false, $true, $true, $false, $false, $false, $true, $true, $true, $false, $false, $false, $false)
        # A list parameter passed as JSON text, as the Fabric job API and pipelines pass it, builds the same request.
        $results[13].body | Should -BeExactly $results[12].body
        $results[14].body | Should -BeExactly '{"action":"reset","requestedBy":"notebook","targets":["T1","T3"]}'
        $results[15].body | Should -BeExactly '{"action":"reset","requestedBy":"notebook"}'
        $results[16].error | Should -Match 'ACTIVITIES must be a list, or a JSON array as text'
        $results[17].error | Should -Match 'ACTIVITIES must be a list, or a JSON array as text'
        $results[18].error | Should -Match 'Each activity is an object'
        $results[19].body | Should -BeExactly '{"action":"run","requestedBy":"notebook","durationMinutes":90,"activities":[{"target":"T1","scenario":"showcase"},{"target":"T2","scenario":"showcase"},{"target":"T3","scenario":"showcase"},{"target":"T4","scenario":"showcase"}]}'
        $results[21].error | Should -Match 'don''t apply to showcase'
        $results[22].error | Should -Match 'at least one activity that isn''t off'
        $results[23].error | Should -Match 'isn''t in the catalog: use showcase, baseline, off'
        # The session (ADR 0026): its ID, and the showcase's minutes from the session's minimum to its maximum.
        $results[24].body | Should -BeExactly '{"action":"session","requestedBy":"notebook","sessionId":"0123456789abcdef0123456789abcdef","durationMinutes":90}'
        $results[25].body | Should -BeExactly '{"action":"capture","requestedBy":"notebook","sessionId":"0123456789abcdef0123456789abcdef"}'
        $results[26].body | Should -BeExactly '{"action":"stop","requestedBy":"notebook","sessionId":"0123456789abcdef0123456789abcdef"}'
        $results[27].error | Should -Match 'session needs a session ID'
        $results[28].error | Should -Match 'DURATION_MINUTES must be a whole number from 30 to 120'
        $results[29].error | Should -Match '32 lowercase hexadecimal'
        $results[30].error | Should -Match 'Only session, capture, and stop take a session ID'
        foreach ($result in @($results | Where-Object ok)) {
            $request = Test-DbHubControlRequest -WebhookData ([pscustomobject]@{ RequestBody = $result.body }) -Settings $script:runbookSettings
            $request.Reason | Should -BeNullOrEmpty -Because $result.body
            $request.Valid | Should -BeTrue
        }
        # What the notebook refuses, the runbook refuses too, sent as raw JSON past the notebook.
        foreach ($body in @(
                '{"action":"run","activities":[{"target":"T1","scenario":"baseline"}],"durationMinutes":4}'
                '{"action":"run","activities":[{"target":"T1","scenario":"baseline"}],"durationMinutes":20.5}'
                '{"action":"run","activities":[{"target":"T1","scenario":"drop-database"}],"durationMinutes":20}'
                '{"action":"run","activities":[{"target":"T1","scenario":"baseline"},{"target":"T1","scenario":"cpu-pressure"}],"durationMinutes":20}'
                '{"action":"run","activities":[{"target":"T1","scenario":"blocking-chain","concurrency":5}],"durationMinutes":20}'
                '{"action":"run","activities":[{"target":"T1","scenario":"baseline","sql":"select 1"}],"durationMinutes":20}'
                '{"action":"reset","targets":["T1","T1"]}'
                '{"action":"run","activities":[{"target":"T1","scenario":"showcase","intensity":5}],"durationMinutes":90}'
                '{"action":"run","activities":[{"target":"T1","scenario":"off"}],"durationMinutes":20}'
                '{"action":"run","activities":[{"target":"T1","scenario":"business-day"}],"durationMinutes":20}'
                '{"action":"session","durationMinutes":90}'
                '{"action":"session","sessionId":"0123456789abcdef0123456789abcdef","durationMinutes":20}'
                '{"action":"session","sessionId":"0123456789ABCDEF0123456789ABCDEF","durationMinutes":90}'
            )) {
            (Test-DbHubControlRequest -WebhookData ([pscustomobject]@{ RequestBody = $body }) -Settings $script:runbookSettings).Valid | Should -BeFalse -Because $body
        }
    }

    It 'plans a session as the runbook does: before the VMs'' auto-shutdown, after whole showcase cycles when it''s cut short, and refused under 30 minutes' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $filled = Get-FilledNotebook -Zone 'UTC'
        $driver = Join-Path -Path $TestDrive -ChildPath 'plan.py'
        Set-Content -LiteralPath $driver -Encoding utf8NoBOM -Value @'
import datetime as dt, json, sys
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
ns = {}
exec(cells[0], ns)
exec(cells[1], ns)
catalog = ns["load_catalog"](ns["CATALOG_JSON"])
out = {}
for label, hour, minute in (("morning", 9, 0), ("capped", 17, 45), ("short", 18, 20), ("late", 18, 40)):
    plan = ns["session_plan"](dt.datetime(2026, 11, 14, hour, minute, tzinfo=dt.timezone.utc), 90, catalog)
    out[label] = {"minutes": plan["minutes"], "ok": plan["ok"], "end": plan["endUtc"].strftime("%H:%M"), "lines": ns["plan_lines"](plan, catalog)}
print(json.dumps(out))
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $driver $filled 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $plan = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $plan.morning.minutes | Should -Be 90
        $plan.morning.lines[0] | Should -Match 'runs 90 minutes, until 10:30 \(UTC\)\. The VMs'' nightly auto-shutdown is at 19:00, and a session always ends before it; to move it, set autoShutdownTime in config/demo.config.json and run \./scripts/deploy\.ps1'
        # 17:45: 75 minutes to 19:00, less the 2-minute margin, is 73, so two whole 30-minute cycles end at 18:45.
        $plan.capped.minutes | Should -Be 60
        $plan.capped.end | Should -Be '18:45'
        $plan.capped.lines[0] | Should -Match 'runs 60 of the 90 minutes asked: it ends at 18:45 \(UTC\), before the VMs'' nightly auto-shutdown at 19:00, when the activity on the VMs ends\. It ends after 2 whole 30-minute showcase cycles, so no beat is cut off\.'
        $plan.capped.lines[1] | Should -Match 'Run all earlier, or set autoShutdownTime'
        # 18:20 is the runbook test's case: 38 minutes become one whole cycle, as Start-DbHubSession plans it.
        $plan.short.minutes | Should -Be 30
        $plan.short.lines[0] | Should -Match 'after 1 whole 30-minute showcase cycle,'
        $plan.late.ok | Should -BeFalse
        $plan.late.lines[0] | Should -Match 'Nothing is started: the VMs'' nightly auto-shutdown is at 19:00 \(UTC\), too soon for a session of at least 30 minutes'
    }

    It 'lists the showcase''s beats as the runner plans them: cycles from each target''s start, T4''s tier, and its replica' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $filled = Get-FilledNotebook -Zone 'UTC'
        $driver = Join-Path -Path $TestDrive -ChildPath 'beats.py'
        Set-Content -LiteralPath $driver -Encoding utf8NoBOM -Value @'
import datetime as dt, json, sys
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
ns = {}
exec(cells[0], ns)
exec(cells[1], ns)
showcase = ns["load_showcase"](ns["SHOWCASE_JSON"])
anchor = dt.datetime(2026, 11, 14, 14, 0, tzinfo=dt.timezone.utc)
end = anchor + dt.timedelta(minutes=90)
def offsets(tier, replica, target="T4"):
    beats = ns["showcase_beats"](showcase, {target: anchor}, end, tier, replica)
    return sorted("%s@%d" % (beat["scenario"], (beat["startUtc"] - anchor).total_seconds() // 60) for beat in beats)
out = {"gp": offsets("GeneralPurpose", True), "gpNoReplica": offsets("GeneralPurpose", False), "burstable": offsets("Burstable", False),
       "unknown": offsets("", False), "t2": offsets("", False, "T2")}
beats = ns["showcase_beats"](showcase, {"T4": anchor}, end, "GeneralPurpose", True)
out["signal"] = next(beat["signal"] for beat in beats if beat["scenario"] == "replica-lag")
out["short"] = len(ns["showcase_beats"](showcase, {"T1": anchor}, anchor + dt.timedelta(minutes=31), "", False))
print(json.dumps(out))
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $driver $filled 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $beats = ($output | Select-Object -Last 1) | ConvertFrom-Json
        # General Purpose with its replica: replica-lag takes the even cycle's missing-index slot (2026-11-14).
        @($beats.gp) | Should -Contain 'replica-lag@50'
        @($beats.gp) | Should -Contain 'missing-index@20'
        @($beats.gp) | Should -Contain 'missing-index@80'
        @($beats.gp) | Should -Not -Contain 'missing-index@50'
        @($beats.gp) | Should -Contain 'locking-blocking@40'
        @($beats.gp) | Should -Contain 'idle-in-transaction@10'
        @($beats.gpNoReplica) | Should -Contain 'missing-index@50'
        @($beats.gpNoReplica) | Should -Not -Contain 'replica-lag@50'
        # Burstable, and an unknown tier as the runner treats it: no General Purpose slot, CPU in odd cycles only.
        foreach ($tier in 'burstable', 'unknown') {
            @($beats.$tier) | Should -Contain 'cpu-pressure@8'
            @($beats.$tier) | Should -Not -Contain 'cpu-pressure@38'
            @($beats.$tier | Where-Object { $_ -match '^(missing-index|replica-lag)@' }) | Should -BeNullOrEmpty
        }
        @($beats.t2) | Should -Contain 'parallel-scans@22'
        @($beats.t2) | Should -Contain 'tempdb-contention@52'
        $beats.signal | Should -Match 'Read replica lag'
        # A beat the session's end cuts to under 3 minutes isn't listed: T1's first cycle only, for a 31-minute session.
        $beats.short | Should -Be 4
    }

    It 'plans the Database Agent beat in T3''s second cycle, and the guide gives the one-time agent selection and its times (2026-11-18)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $filled = Get-FilledNotebook -Zone 'UTC'
        $driver = Join-Path -Path $TestDrive -ChildPath 'agent-beat.py'
        Set-Content -LiteralPath $driver -Encoding utf8NoBOM -Value @'
import datetime as dt, json, sys
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
ns = {}
exec(cells[0], ns)
exec(cells[1], ns)
showcase, catalog = ns["load_showcase"](ns["SHOWCASE_JSON"]), ns["load_catalog"](ns["CATALOG_JSON"])
anchor = dt.datetime(2026, 11, 14, 14, 0, tzinfo=dt.timezone.utc)
status = {"sessionId": "a" * 32, "acceptedUtc": "2026-11-14T13:56:00Z", "runEndUtc": "2026-11-14T15:30:00Z",
          "names": {"t3Server": "azuresql01-abc123", "t3Database": "ContosoCare", "t2Guest": "arcsql01"}}
out = {}
for label, minutes in (("whole", 90), ("cut", 45)):
    beats = ns["showcase_beats"](showcase, {"T3": anchor}, anchor + dt.timedelta(minutes=minutes))
    agent = [beat for beat in beats if beat.get("agent")]
    out[label] = {"agents": len(agent), "lines": ns["guide_lines"](status, showcase, catalog, {"databaseHub": "https://app.fabric.microsoft.com/workloads/fdh/databaseHub"}, beats)}
    if agent:
        out[label].update({"scenario": agent[0]["scenario"], "cycle": agent[0]["cycle"],
                           "regress": (agent[0]["regressUtc"] - anchor).total_seconds() / 60, "respond": (agent[0]["respondUtc"] - anchor).total_seconds() / 60})
print(json.dumps(out))
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $driver $filled 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $out = ($output | Select-Object -Last 1) | ConvertFrom-Json
        # One beat a session: plan-regression in cycle 2 (minutes 30-60), regressing at 10% and responding at 85% of it.
        $out.whole.agents | Should -Be 1
        $out.whole.scenario | Should -Be 'plan-regression'
        $out.whole.cycle | Should -Be 2
        $out.whole.regress | Should -Be 33
        $out.whole.respond | Should -Be 55.5
        $text = $out.whole.lines -join "`n"
        $text | Should -Match 'Once per deployment, if it isn''t done yet: Database Hub > Manage agents > Database agent settings: Enabled on, select azuresql01-abc123/ContosoCare, Agent policy: Flag long-running queries, Force last known good plans, and Flag high CPU'
        $text | Should -Match '14:33  T3''s lookup regresses to a scanning plan'
        $text | Should -Match '14:48  From about now, the agent''s issue on azuresql01-abc123/ContosoCare, a new one each session'
        $text | Should -Match 'Explain why, then Analyze slow query'
        $text | Should -Match '14:55  Respond: this Run all forces the last good plan through Query Store'
        $text | Should -Match 'Optimization: arcsql01, ready to migrate'
        $text | Should -Match '\[What changed\] What changed in my databases\?'
        $text | Should -Not -Match 'cuts the beat short'
        # A 45-minute session cuts the beat to 15 minutes, so the response can come before the agent's issue.
        $out.cut.agents | Should -Be 1
        ($out.cut.lines -join "`n") | Should -Match 'This session''s end cuts the beat short'
    }

    It 'says when T3''s response runs, and checks T3''s CPU before and after it once its telemetry arrives (2026-11-18)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $filled = Get-FilledNotebook -Zone 'UTC'
        $driver = Join-Path -Path $TestDrive -ChildPath 'agent-view.py'
        Set-Content -LiteralPath $driver -Encoding utf8NoBOM -Value @'
import contextlib, datetime as dt, io, json, sys, types
fake_requests = types.ModuleType("requests")
fake_requests.RequestException = Exception
sys.modules["requests"], sys.modules["pandas"] = fake_requests, types.ModuleType("pandas")
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
ns = {}
for index in range(3):
    exec(cells[index], ns)
ns["CATALOG"] = ns["load_catalog"](ns["CATALOG_JSON"])
respond = dt.datetime(2026, 11, 14, 14, 55, 30, tzinfo=dt.timezone.utc)
beat = {"agent": True, "regressUtc": respond - dt.timedelta(minutes=22.5), "respondUtc": respond}

def run(cpu, minutes, telemetry=True):
    calls = []
    def fake(start, end):
        calls.append([(start - respond).total_seconds() / 60, (end - respond).total_seconds() / 60])
        return cpu(start)
    ns["t3_cpu"] = fake
    state, buffer = {}, io.StringIO()
    with contextlib.redirect_stdout(buffer):
        for minute in minutes:
            ns["agent_view"](beat, respond + dt.timedelta(minutes=minute), state, telemetry)
    return {"printed": buffer.getvalue(), "result": list(state.get("result") or []), "calls": calls,
            "summary": ns["agent_summary"](beat, state, respond + dt.timedelta(minutes=40))}

out = {"early": run(lambda start: (50.0, ""), [-1]),
       "drop": run(lambda start: (80.0, "") if start < respond else (12.0, ""), [0, 5, 9, 10]),
       "flat": run(lambda start: (30.0, ""), [9]),
       "late": run(lambda start: (80.0, "") if start < respond else (None, ""), [9, 15, 21]),
       "refused": run(lambda start: (None, "HTTP 401."), [9]),
       "noTelemetry": run(lambda start: (50.0, ""), [1], telemetry=False),
       "before": ns["agent_summary"](beat, {}, respond - dt.timedelta(minutes=1)),
       "none": ns["agent_summary"](None, {}, respond)}
print(json.dumps(out))
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $driver $filled 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $out = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $out.early.printed | Should -BeNullOrEmpty
        @($out.early.calls).Count | Should -Be 0
        # At the response, a line; the CPU only once the minutes after it can be in the telemetry, and only once.
        $out.drop.printed | Should -Match 'Now: T3 Respond, the Database Agent loop''s manual response: T3''s run forces the last good plan through Query Store'
        $out.drop.result | Should -Be @('Pass', 'T3''s CPU fell from 80% before the response to 12% after it: the last good plan is back.')
        ($out.drop.calls | ForEach-Object { $_ -join '..' }) | Should -Be @('1..6', '-8..-1')
        $out.drop.summary[0] | Should -Match '^The Database Agent loop: T3''s response ran at 14:55 \(the last good plan forced through Query Store, FORCE_LAST_GOOD_PLAN back on\)\. Pass: T3''s CPU fell'
        $out.flat.result[0] | Should -Be 'Warning'
        $out.flat.result[1] | Should -Match 'didn''t fall after the response \(30% before, 30% after\)'
        # Telemetry arrives 3 to 15 minutes late: it waits up to 20 minutes after the response, then says so.
        @($out.late.calls).Count | Should -Be 3
        $out.late.result[0] | Should -Be 'Warning'
        $out.late.result[1] | Should -Match 'isn''t in the telemetry yet'
        $out.refused.result[1] | Should -Match 'isn''t in the telemetry: HTTP 401\.'
        $out.noTelemetry.result[0] | Should -Be 'Note'
        @($out.noTelemetry.calls).Count | Should -Be 0
        $out.before[0] | Should -Match 'the session ended before T3''s response at 14:55'
        @($out.none).Count | Should -Be 0
    }

    It 'runs a whole session on Run all: the start, the guide, the end, the stop, and its history, with one session ID' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'session' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.leaked | Should -BeFalse
        @($report.sent | ForEach-Object action) | Should -Be @('session', 'stop')
        $report.sent[0].sessionId | Should -Match '^[0-9a-f]{32}$'
        $report.sent[1].sessionId | Should -Be $report.sent[0].sessionId
        foreach ($body in $report.sent) {
            $text = ConvertTo-Json -InputObject $body -Compress
            (Test-DbHubControlRequest -WebhookData ([pscustomobject]@{ RequestBody = $text }) -Settings $script:runbookSettings).Valid | Should -BeTrue -Because $text
        }
        # The history: one reference run of the activity notebook in this notebook's own Spark session, after the stop,
        # with the session's ID, beats, window, T4's metrics, and the demo's workspace and lakehouse; no Spark job.
        @($report.jobs).Count | Should -Be 0
        @($report.refs).Count | Should -Be 1
        $ref = $report.refs[0]
        $ref.path | Should -BeExactly 'NB_DatabaseHub_LiveActivity'
        $ref.workspace | Should -Be 'bbbbbbbb-0000-0000-0000-000000000002'
        $ref.timeout | Should -Be 1800
        $job = $ref.args
        $job.WORKSPACE_ID | Should -Be 'bbbbbbbb-0000-0000-0000-000000000002'
        $job.LAKEHOUSE_ID | Should -Be 'cccccccc-0000-0000-0000-000000000003'
        $job.SESSION_ID | Should -Be $report.sent[0].sessionId
        ($job.SESSION_PLAN | ConvertFrom-Json).beats.Count | Should -BeGreaterThan 20
        # The Database Agent beat carries when its run regresses and responds, for the history's database_agent finding.
        $agentBeats = @(($job.SESSION_PLAN | ConvertFrom-Json).beats | Where-Object { $_.PSObject.Properties.Name -contains 'agent' -and $_.agent })
        $agentBeats.Count | Should -Be 1
        $agentBeats[0].target | Should -Be 'T3'
        $agentBeats[0].scenario | Should -Be 'plan-regression'
        ([datetime]$agentBeats[0].respondUtc).ToUniversalTime().ToString('HH:mm') | Should -Be '14:59'
        ([datetime]$agentBeats[0].regressUtc) | Should -BeLessThan ([datetime]$agentBeats[0].respondUtc)
        ($job.POSTGRES_METRICS | ConvertFrom-Json).sessionId | Should -Be $job.SESSION_ID
        ([datetime]$job.WINDOW_START_UTC).ToUniversalTime() | Should -Be ([datetime]::new(2026, 11, 14, 13, 55, 0, [System.DateTimeKind]::Utc))
        $job.RESOURCE_GROUP | Should -Be 'rg-dbhub-demo'
        $job.T1_VM_NAME | Should -Be 'sqlvm01'
        @($report.order) | Should -Be @('sent:session', 'validator', 'sent:stop', ('history:{0}' -f $job.SESSION_ID.Substring(0, 8)))
        $report.printed | Should -Match 'This session runs 90 minutes, until 15:30 \(UTC\)'
        # The capacity runs this notebook, so it isn't checked; the stand-in fails on any capacity call. ("Capacity maxed
        # out" is a showcase scenario.)
        $report.printed | Should -Not -Match '(?i)workspace''s capacity|capacity \S+ is (Active|Inactive|Paused)|resume it'
        $report.printed | Should -Match '=== The presenter''s guide: session [0-9a-f]{8}'
        $report.printed | Should -Match 'Database Hub: https://app\.fabric\.microsoft\.com/workloads/fdh/databaseHub\?ctid=aaaaaaaa-0000-0000-0000-000000000001'
        $report.printed | Should -Match 'The history report: https://app\.fabric\.microsoft\.com/groups/bbbbbbbb-0000-0000-0000-000000000002/reports/rpt-1'
        $report.printed | Should -Match 'T4''s read replica pgreplica01-abc123'
        $report.printed | Should -Match '\[Investigate\] Investigate what happened on sqlvm01 between 14:04 and 14:14 UTC\.'
        $report.printed | Should -Match 'Now: T4 Read replica lag'
        # The Database Agent loop (2026-11-18): the one-time selection in the guide, the response, and the summary's line.
        $report.printed | Should -Match 'Database Hub > Manage agents > Database agent settings: Enabled on, select azuresql01-abc123/ContosoCare'
        $report.printed | Should -Match 'Now: T3 Respond, the Database Agent loop''s manual response'
        $report.printed | Should -Match 'The Database Agent loop: T3''s response ran at 14:59 '
        $report.printed | Should -Match 'Stopped: T4''s read replica deleted, T4 stopped'
        $report.printed | Should -Match 'Waiting \d+ minutes for the last telemetry to arrive'
        $report.printed | Should -Match 'NB_DatabaseHub_LiveActivity runs in this notebook''s Spark session to save session [0-9a-f]{8}''s history\.'
        $report.printed | Should -Match 'Pass: the history is saved'
    }

    It 'saves the history of another environment''s session with that environment''s names, not the activity notebook''s defaults' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # The activity notebook's defaults name the owner's environment (rg-dbhub-demo), and its import fills only the
        # workspace and the lakehouse, so the history must say which resource group its telemetry comes from.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC' -Prefix 'contoso') -Scenario 'session' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.refs).Count | Should -Be 1
        $report.refs[0].args.RESOURCE_GROUP | Should -Be 'rg-contoso-demo'
        $report.refs[0].args.T2_MACHINE_NAME | Should -Be 'arcsql01'
        $report.refs[0].args.T3_SERVER_PREFIX | Should -Not -BeNullOrEmpty
    }

    It 'checks readiness once the session runs: NB_DatabaseHub_Deployment, read-only, in this notebook''s Spark session, before the guide (2026-11-18)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # Run all does everything (the user), so every session fills the Insights app's Readiness page (validation_results).
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC' -Prefix 'contoso') -Scenario 'session' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.validators).Count | Should -Be 1
        $run = $report.validators[0]
        $run.path | Should -BeExactly 'NB_DatabaseHub_Deployment'
        $run.workspace | Should -Be 'bbbbbbbb-0000-0000-0000-000000000002'
        $run.timeout | Should -Be 300
        # Read-only: its results saved, its cleanup off, and this environment's names rather than the validator's defaults.
        @($run.args.PSObject.Properties.Name | Sort-Object) | Should -Be @('CONFIRM', 'LAKEHOUSE_ID', 'PURGE_DEMO_TABLES', 'RESOURCE_GROUP', 'SAVE_RESULTS', 'T1_VM_NAME', 'T2_MACHINE_NAME', 'T3_SERVER_PREFIX', 'WORKSPACE_ID')
        $run.args.SAVE_RESULTS | Should -BeTrue
        $run.args.CONFIRM | Should -BeFalse
        $run.args.PURGE_DEMO_TABLES | Should -BeFalse
        $run.args.WORKSPACE_ID | Should -Be 'bbbbbbbb-0000-0000-0000-000000000002'
        $run.args.LAKEHOUSE_ID | Should -Be 'cccccccc-0000-0000-0000-000000000003'
        $run.args.RESOURCE_GROUP | Should -Be 'rg-contoso-demo'
        $line = 'Readiness: NB_DatabaseHub_Deployment ran its read-only checks in 1 minute; the Insights app''s Readiness page shows each one, worst first, after its next refresh.'
        $report.printed | Should -Match ([regex]::Escape($line))
        $report.printed.IndexOf('Pass: the session runs until') | Should -BeLessThan $report.printed.IndexOf($line)
        $report.printed.IndexOf($line) | Should -BeLessThan $report.printed.IndexOf('=== The presenter''s guide')
    }

    It 'goes on with the session, the Database Agent beat, and its history when the readiness check <Case>' -ForEach @(
        @{ Case = 'fails'; Scenario = 'valfail'; Printed = 'Warning: readiness wasn''t checked: NB_DatabaseHub_Deployment didn''t finish in this session (RuntimeError: Notebook execution failed in cell 12: the telemetry endpoint didn''t answer). The session goes on. Fix: run NB_DatabaseHub_Deployment in the demo workspace while the session runs; the Insights app''s Readiness page shows its checks.' }
        @{ Case = 'runs past its 5 minutes'; Scenario = 'valslow'; Printed = 'Warning: readiness wasn''t checked: NB_DatabaseHub_Deployment didn''t finish in this session (RuntimeError: The notebook run didn''t finish in 300 seconds). The session goes on.' }
    ) {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario $Scenario -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.validators).Count | Should -Be 1
        $report.printed | Should -Match ([regex]::Escape($Printed))
        @($report.sent | ForEach-Object action) | Should -Be @('session', 'stop')
        @($report.order) | Should -Be @('sent:session', 'validator', 'sent:stop', ('history:{0}' -f $report.sent[0].sessionId.Substring(0, 8)))
        $report.printed | Should -Match '=== The presenter''s guide: session [0-9a-f]{8}'
        $report.printed | Should -Match 'Now: T3 Respond, the Database Agent loop''s manual response'
        $report.printed | Should -Match 'Pass: the history is saved'
    }

    It 'says why readiness wasn''t checked when this notebook can''t run it in its own Spark session, and how to check it' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'unbound' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.validators).Count | Should -Be 0
        $report.printed | Should -Match ([regex]::Escape('Readiness: not checked in this Run all, because this notebook''s default lakehouse isn''t the demo''s (none is attached; ./scripts/deploy.ps1 attaches it). Fix: run NB_DatabaseHub_Deployment in the demo workspace while the session runs; the Insights app''s Readiness page shows its checks.'))
        @($report.sent | ForEach-Object action) | Should -Be @('session', 'stop')
    }

    It 'runs Run all in <Case>' -ForEach @(
        @{ Case = 'a session that already runs: it follows that one and ends it, rather than start another'; Scenario = 'active'; Start = '2026-11-14T14:00:00Z'; Sent = @('stop'); Refs = 1; Jobs = 0; Validators = 1; Printed = 'A session already runs \(session aaaaaaaa, until 15:10, UTC\): this Run all follows it' }
        @{ Case = 'the evening, too close to the auto-shutdown: nothing starts, and it says how to change it'; Scenario = 'late'; Start = '2026-11-14T18:45:00Z'; Sent = @(); Refs = 0; Jobs = 0; Validators = 0; Printed = 'Nothing is started: .* too soon for a session of at least 30 minutes\.\s+Fix: Run all again earlier in the day, or set autoShutdownTime' }
        @{ Case = 'the late afternoon: it says before it starts when the session ends and why'; Scenario = 'capped'; Start = '2026-11-14T17:45:00Z'; Sent = @('session', 'stop'); Refs = 1; Jobs = 0; Validators = 1; Printed = 'This session runs 60 of the 90 minutes asked: it ends at 18:45' }
        @{ Case = 'an earlier session''s metrics in the vault: its history is saved right after the start is sent'; Scenario = 'leftover'; Start = '2026-11-14T14:00:00Z'; Sent = @('session', 'stop'); Refs = 2; Jobs = 0; Validators = 1; Printed = 'An earlier session \(eeeeeeee, .*\) left its metrics in the vault: its history is saved right after this session''s start is sent, while the VMs start\.' }
        @{ Case = 'Stop now: it ends the session that runs, its history saved too'; Scenario = 'stopnow'; Start = '2026-11-14T14:00:00Z'; Sent = @('stop'); Refs = 1; Jobs = 0; Validators = 0; Printed = '=== Stop now: stopping session aaaaaaaa ===' }
        @{ Case = 'MODE "check": the plan and the checks, and nothing sent'; Scenario = 'check'; Start = '2026-11-14T14:00:00Z'; Sent = @(); Refs = 0; Jobs = 0; Validators = 0; Printed = 'MODE is "check", so nothing was sent\.' }
        @{ Case = 'WAIT_FOR_END False: the session goes on, and its auto-stop ends it'; Scenario = 'nowait'; Start = '2026-11-14T14:00:00Z'; Sent = @('session'); Refs = 0; Jobs = 0; Validators = 1; Printed = 'The session goes on until 15:30 \(UTC\)\. Its auto-stop at 15:40' }
        @{ Case = 'a runbook that refuses the session: the reason and the fix'; Scenario = 'refused'; Start = '2026-11-14T14:00:00Z'; Sent = @('session'); Refs = 0; Jobs = 0; Validators = 0; Printed = '(?s)A run is already active.*Fix: Wait until it ends, or run the notebook''s Stop now cell first\..*Nothing runs: A run is already active' }
        @{ Case = 'a notebook without the demo''s lakehouse: the history runs as a job in the demo workspace, and it says why'; Scenario = 'unbound'; Start = '2026-11-14T14:00:00Z'; Sent = @('session', 'stop'); Refs = 0; Jobs = 1; Validators = 0; Printed = 'NB_DatabaseHub_LiveActivity runs as a job in the demo workspace instead, because this notebook''s default lakehouse isn''t the demo''s \(none is attached; \./scripts/deploy\.ps1 attaches it\)\.' }
        @{ Case = 'a reference run that fails: the history runs as a job, with the reason'; Scenario = 'refail'; Start = '2026-11-14T14:00:00Z'; Sent = @('session', 'stop'); Refs = 1; Jobs = 1; Validators = 1; Printed = 'runs as a job in the demo workspace instead, because it didn''t finish in this session \(RuntimeError: The referenced notebook''s default lakehouse differs' }
    ) {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario $Scenario -Start $Start
        $report.error | Should -BeNullOrEmpty
        $report.leaked | Should -BeFalse
        @($report.sent | ForEach-Object action) | Should -Be $Sent
        @($report.refs).Count | Should -Be $Refs
        @($report.jobs).Count | Should -Be $Jobs
        @($report.validators).Count | Should -Be $Validators -Because 'the readiness check runs once per Run all that follows a running session'
        $report.printed | Should -Match $Printed
        $report.printed | Should -Not -Match 'Warning: the session''s history wasn''t saved'
        if ($Scenario -eq 'leftover') {
            # Its metrics are read before the start, and its history saved right after the start is sent.
            $session = $report.sent[0].sessionId
            @($report.order) | Should -Be @('sent:session', 'history:eeeeeeee', 'validator', 'sent:stop', ('history:{0}' -f $session.Substring(0, 8)))
            $report.refs[0].args.SESSION_ID | Should -Be ('e' * 32)
            $report.refs[0].args.PSObject.Properties.Name | Should -Contain 'POSTGRES_METRICS'
            $report.refs[1].args.SESSION_ID | Should -Be $session
        }
        if ($Scenario -in 'unbound', 'refail') {
            $report.jobs[0].SESSION_ID | Should -Be $report.sent[0].sessionId
            $report.jobs[0].PSObject.Properties.Name | Should -Contain 'POSTGRES_METRICS'
            $report.printed | Should -Match 'Pass: the history is saved'
        }
        if ($Scenario -in 'active', 'stopnow') {
            $report.sent[0].sessionId | Should -Be ('a' * 32)
        }
    }

    It 'says when a full capacity refuses the history job (HTTP 430), and how the history still gets saved' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # Learn: notebook jobs started through the API aren't queued, so a capacity whose Spark cores are all in use refuses
        # them with HTTP 430. That's only the fallback: with the demo's lakehouse attached, the history needs no job at all.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'full' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.sent | ForEach-Object action) | Should -Be @('session', 'stop')
        @($report.refs).Count | Should -Be 0
        @($report.jobs).Count | Should -Be 0
        $report.refused | Should -Be 3
        $report.printed | Should -Match 'Warning: the session''s history wasn''t saved: the capacity refused the job 3 times: TooManyRequestsForCapacity \(HTTP 430\), because all its Spark cores are in use, this notebook''s session among them\.'
        $report.printed | Should -Match ('Fix: the next Run all saves it first, while its metrics are in the control vault .*SESSION_ID = "{0}"' -f $report.sent[0].sessionId)
        $report.printed | Should -Not -Match 'Pass: the history is saved'
    }

    It 'starts the history job without waiting when Fabric queues it, and an interactive Run all then ends its own Spark session (2026-11-16 live finding)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # Live on an F4: Run all waited 30 minutes for a job that Fabric held back until Run all's own session ended.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'queued' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.sent | ForEach-Object action) | Should -Be @('session', 'stop')
        @($report.refs).Count | Should -Be 1
        @($report.jobs).Count | Should -Be 1
        $report.jobs[0].SESSION_ID | Should -Be $report.sent[0].sessionId
        $report.jobReads | Should -Be 1 -Because 'one look at the job, and no wait while this session holds the capacity'
        $report.printed | Should -Match 'runs as a job in the demo workspace instead, because it didn''t finish in this session \(RuntimeError: Unrecognized token'
        $report.printed | Should -Match 'The history job is queued: Fabric starts it once this notebook''s Spark session ends \(a small capacity, such as an F2 or F4, runs one Spark session at a time\), and Run all ends the session when it finishes\. Its result: NB_DatabaseHub_LiveActivity''s run in the demo workspace''s Monitor hub'
        $report.printed | Should -Not -Match 'Warning: the history job is|Pass: the history is saved'
        $report.stops | Should -Be 1
        $report.order[-1] | Should -Be 'session.stop' -Because 'no code runs after notebookutils.session.stop()'
        $report.printed | Should -Match 'This notebook''s Spark session ends now, so Fabric can start the queued history job'
        # The same document, but never the vault secret's own text: Fabric redacts a secret's exact text in the output.
        foreach ($sent in $report.refs[0].args.POSTGRES_METRICS, $report.jobs[0].POSTGRES_METRICS) {
            $sent | Should -Not -BeExactly $report.vaultMetrics
            ($sent | ConvertFrom-Json).sessionId | Should -Be $report.sent[0].sessionId
            ($sent | ConvertFrom-Json | ConvertTo-Json -Depth 8 -Compress) | Should -BeExactly ($report.vaultMetrics | ConvertFrom-Json | ConvertTo-Json -Depth 8 -Compress)
        }
    }

    It 'leaves the Spark session of <Case> alone' -TestCases @(
        @{ Case = 'a scheduled run, which ends by itself, with its history job queued'; Scenario = 'queuedjob'; Printed = 'The history job is queued: Fabric starts it once' }
        @{ Case = 'a Run all whose history job already finished'; Scenario = 'refail'; Printed = 'Pass: the history is saved' }
    ) {
        param($Scenario, $Printed)
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario $Scenario -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.jobs).Count | Should -Be 1
        $report.jobReads | Should -Be 1
        $report.printed | Should -Match ([regex]::Escape($Printed))
        $report.stops | Should -Be 0
        $report.printed | Should -Not -Match 'Spark session ends now'
    }

    It 'ends Run all with the step that can end its Spark session, because no code runs after notebookutils.session.stop()' {
        $last = $script:code[-1].Source.TrimEnd()
        $last | Should -Match '\nend_session_for_history\(\)$'
        @([regex]::Matches($script:allCode, 'session\.stop\(\)')).Count | Should -Be 1
        $script:allCode | Should -Match '(?m)^    utils\.session\.stop\(\)\n    return True$'
    }
    It 'prints a host''s failure that DbHub-Monitor adds while the session runs, with its fix, reading the status at most every 5 minutes (2026-11-16)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'hostfail' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.printed | Should -Match 'Host\s+Warning T2: archost01 is deallocated, so T2 has no activity now\.\s+Fix: The session''s other targets go on\. For T2: set STOP_NOW = True and Run all, then Run all again'
        @([regex]::Matches($report.printed, 'archost01 is deallocated')).Count | Should -Be 1
        $report.printed | Should -Match 'Pass: the history is saved'
        # The same session with the live view from before (76cdb12): what the re-reads cost, and an old notebook with the
        # new runbooks, which runs as before and only doesn't show the host live.
        $old = Invoke-Simulation -Path (Get-OldLiveViewNotebook) -Scenario 'hostfail' -Start '2026-11-14T14:00:00Z'
        $old.error | Should -BeNullOrEmpty
        $old.printed | Should -Match 'Pass: the history is saved'
        $old.printed | Should -Not -Match 'archost01 is deallocated'
        ($report.statusReads - $old.statusReads) | Should -BeLessOrEqual 19 -Because 'a 90-minute live view reads the status at most every 5 minutes'
        ($report.statusReads - $old.statusReads) | Should -BeGreaterThan 10
    }

    It 'shows nothing new from a status that runbooks from before 2026-11-16 wrote, which has no host steps and no runCommands' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'session' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.printed | Should -Not -Match '\bHost\b'
        $report.printed | Should -Match 'Pass: the history is saved'
    }
    It 'says in the demo''s own time zone when the session ends (needs Python''s time zone data)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $PSNativeCommandUseErrorActionPreference = $false
        $null = & $script:python -c 'import zoneinfo; zoneinfo.ZoneInfo("America/New_York")' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because 'this Python has no time zone data (pip install tzdata); Fabric''s runtime has it'
            return
        }
        # 22:45 UTC on 2026-11-14 is 17:45 in New York (EST): 73 minutes before 19:00, less the margin.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'Eastern Standard Time') -Scenario 'capped' -Start '2026-11-14T22:45:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.printed | Should -Match 'This session runs 60 of the 90 minutes asked: it ends at 18:45 \(Eastern Standard Time\), before the VMs'' nightly auto-shutdown at 19:00'
    }

    It 'prints the job ID, never the webhook URL, whatever the webhook answers (needs pandas)' {
        $interpreter = $script:pandasPython
        if (-not $interpreter) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        $PSNativeCommandUseErrorActionPreference = $false
        $null = & $interpreter -c 'import pandas' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Set-ItResult -Skipped -Because 'pandas is not installed for that Python (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            return
        }
        $part1 = Join-Path -Path $TestDrive -ChildPath 'part1.py'
        $part2 = Join-Path -Path $TestDrive -ChildPath 'part2.py'
        Set-Content -LiteralPath $part1 -Encoding utf8NoBOM -Value (Get-Cell '# Helpers, part 1')
        Set-Content -LiteralPath $part2 -Encoding utf8NoBOM -Value (Get-Cell '# Helpers, part 2')
        $driver = Join-Path -Path $TestDrive -ChildPath 'send.py'
        Set-Content -LiteralPath $driver -Encoding utf8NoBOM -Value @'
import contextlib, io, json, secrets, sys, types

# A stand-in for requests and notebookutils: no network call leaves this test.
fake_requests = types.ModuleType("requests")
class RequestException(Exception):
    pass
fake_requests.RequestException = RequestException
state = {"mode": "accepted", "url": None}
class Response:
    def __init__(self, status, body):
        self.status_code = status
        self._body = body
    def json(self):
        return self._body
def post(url, data=None, headers=None, timeout=None, json=None):
    state["url"] = url
    if state["mode"] == "accepted":
        return Response(202, {"JobIds": ["11111111-0000-0000-0000-000000000001"]})
    if state["mode"] == "expired":
        return Response(400, {})
    raise RequestException("connection to %s failed" % url)
fake_requests.post = post
sys.modules["requests"] = fake_requests

secret_url = "https://example.webhook.wus3.azure-" + "automation.net/webhooks?token=" + secrets.token_urlsafe(30)
class Credentials:
    def getSecret(self, vault, name):
        return secret_url
    def getToken(self, audience):
        return "not-a-token"
notebookutils = types.SimpleNamespace(credentials=Credentials())

namespace = {"notebookutils": notebookutils, "KEY_VAULT_URL": "https://kv-test-ctl-abc123.vault.azure.net/", "WEBHOOK_SECRET_NAME": "dbhub-activity-webhook",
             "RESOURCE_GROUP": "rg-dbhub-demo", "DEMO_DATABASE": "ContosoCare", "T1_VM_NAME": "sqlvm01", "T2_MACHINE_NAME": "arcsql01", "T3_SERVER_PREFIX": "azuresql01-"}
exec(open(sys.argv[1], encoding="utf-8").read(), namespace)
exec(open(sys.argv[2], encoding="utf-8").read(), namespace)
report = {}
for mode in ("accepted", "expired", "unreachable"):
    state["mode"] = mode
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        returned = namespace["send_request"]({"action": "stop", "requestedBy": "notebook"})
    report[mode] = {"printed": buffer.getvalue(), "returned": returned, "posted": state["url"] == secret_url}
token = secret_url.split("token=")[1]
report["leaked"] = any(token in json.dumps(item) for item in report.values() if isinstance(item, dict))
frame = namespace["kusto_frame"]({"Tables": [{"Columns": [{"ColumnName": "Target", "ColumnType": "string"}, {"ColumnName": "Bucket", "ColumnType": "datetime"}],
                                              "Rows": [["T1", "2026-10-23T20:15:00Z"]]}]})
report["frame"] = [list(frame.columns), str(frame["Bucket"].dt.tz)]
print(json.dumps(report))
'@
        $output = & $interpreter $driver $part1 $part2 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $report = ($output | Select-Object -Last 1) | ConvertFrom-Json
        $report.leaked | Should -BeFalse
        $report.accepted.posted | Should -BeTrue
        $report.accepted.printed | Should -Match 'Accepted \(HTTP 202\): Automation job 11111111-0000-0000-0000-000000000001'
        @($report.accepted.returned) | Should -Be @('11111111-0000-0000-0000-000000000001')
        $report.expired.printed | Should -Match 'HTTP 400: the webhook has expired or is disabled'
        $report.unreachable.printed | Should -Match 'couldn''t be reached \(RequestException\)'
        $report.unreachable.printed | Should -Not -Match 'azure-automation'
        $report.frame[0] | Should -Be @('Target', 'Bucket')
        $report.frame[1] | Should -Be 'UTC'
    }
}

Describe 'The notebook deploy.ps1 imports' {
    It 'fills the parameters cell with the environment''s names, the vault and its secrets'' names, the demo''s workspace, and the runbook''s rules, and nothing secret' {
        $notebookDefinition = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $script:config; Json = $script:settingsJson } {
            Get-DemoActivityControlNotebook -Name (Get-DemoActivityControlName -Config $Config) -Setting ($Json | ConvertFrom-Json -AsHashtable) -TenantId 'AAAAAAAA-0000-0000-0000-000000000001' -DemoWorkspaceId 'BBBBBBBB-0000-0000-0000-000000000002'
        }
        $name = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $script:config } { Get-DemoActivityControlName -Config $Config }
        $notebookDefinition.DisplayName | Should -Be 'NB_DatabaseHub_Control'
        $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($notebookDefinition.Definition['parts'][0]['payload']))
        $filled = $text | ConvertFrom-Json -AsHashtable -Depth 64
        $source = (@(@($filled['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]['source']) -join '')
        $source | Should -Match ('(?m)^KEY_VAULT_URL = "{0}"\s+#' -f [regex]::Escape($name.KeyVaultUri))
        $source | Should -Match '(?m)^RESOURCE_GROUP = "rg-dbhub-demo"'
        $source | Should -Match '(?m)^T2_MACHINE_NAME = "arcsql01"'
        $source | Should -Match '(?m)^STATUS_SECRET_NAME = "dbhub-session-status"'
        $source | Should -Match '(?m)^METRICS_SECRET_NAME = "dbhub-session-metrics"'
        $source | Should -Match '(?m)^TENANT_ID = "aaaaaaaa-0000-0000-0000-000000000001"'
        $source | Should -Match '(?m)^DEMO_WORKSPACE_ID = "bbbbbbbb-0000-0000-0000-000000000002"'
        $source | Should -Match '(?m)^MODE = "session"'
        $catalogLine = [regex]::Match($source, '(?m)^CATALOG_JSON = (".*")$').Groups[1].Value
        $catalog = ($catalogLine | ConvertFrom-Json) | ConvertFrom-Json -AsHashtable
        @($catalog['targets']) | Should -Be @('T1', 'T2', 'T3', 'T4')
        $catalog['scenarios'].Contains('blocking-chain') | Should -BeTrue
        $catalog['scenarios'].Contains('idle-in-transaction') | Should -BeTrue
        $catalog['maxDurationMinutes'] | Should -Be 120
        $catalog['profiles']['showcase']['maxMinutes'] | Should -Be 120
        $catalog['profiles']['showcase']['cycleMinutes'] | Should -Be 30
        @($catalog['profiles']['showcase']['targets']) | Should -Be @('T1', 'T2', 'T3', 'T4')
        # The session's rules, as the runbook applies them, and the auto-shutdown's zone by its IANA name for Python.
        $catalog['session']['minMinutes'] | Should -Be 30
        $catalog['session']['shutdownMarginMinutes'] | Should -Be 2
        $catalog['session']['autoShutdownTime'] | Should -Be ([string]$script:config['autoShutdownTime'])
        $catalog['session']['autoShutdownIana'] | Should -Not -BeNullOrEmpty
        $showcaseLine = [regex]::Match($source, '(?m)^SHOWCASE_JSON = (".*")$').Groups[1].Value
        $showcase = ($showcaseLine | ConvertFrom-Json) | ConvertFrom-Json -AsHashtable
        $profileFile = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'scenarios/activity-profiles.json') -Raw | ConvertFrom-Json -AsHashtable
        @($showcase['incidents']).Count | Should -Be @($profileFile['profiles']['showcase']['incidents']).Count
        $showcase['scenarios']['replica-lag']['t4']['signal'] | Should -Match 'Read replica lag'
        $showcase['scenarios']['blocking-chain']['sql']['surface'] | Should -Be 'Performance'
        $text | Should -Not -Match '(?i)webhooks\?token='
        @($filled['cells'] | Where-Object { $_['cell_type'] -eq 'code' } | ForEach-Object { @($_['outputs']).Count } | Where-Object { $_ -gt 0 }) | Should -BeNullOrEmpty
        # Without the demo's lakehouse, the copy names none, and the history runs as a job (the fallback).
        $source | Should -Match '(?m)^DEMO_LAKEHOUSE_ID = ""'
        $filled['metadata'].Contains('dependencies') | Should -BeFalse
    }

    It 'attaches the demo''s lakehouse as the copy''s default lakehouse, so its history can run in the notebook''s own session' {
        $notebookDefinition = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $script:config; Json = $script:settingsJson } {
            Get-DemoActivityControlNotebook -Name (Get-DemoActivityControlName -Config $Config) -Setting ($Json | ConvertFrom-Json -AsHashtable) -TenantId 'AAAAAAAA-0000-0000-0000-000000000001' -DemoWorkspaceId 'BBBBBBBB-0000-0000-0000-000000000002' -DemoLakehouseId 'CCCCCCCC-0000-0000-0000-000000000003' -DemoLakehouseName 'LH_DatabaseHub'
        }
        $notebookDefinition.LakehouseRebound | Should -BeTrue
        $filled = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($notebookDefinition.Definition['parts'][0]['payload'])) | ConvertFrom-Json -AsHashtable -Depth 64
        $binding = $filled['metadata']['dependencies']['lakehouse']
        $binding['default_lakehouse'] | Should -Be 'cccccccc-0000-0000-0000-000000000003'
        $binding['default_lakehouse_workspace_id'] | Should -Be 'bbbbbbbb-0000-0000-0000-000000000002'
        $binding['default_lakehouse_name'] | Should -Be 'LH_DatabaseHub'
        @($binding['known_lakehouses'] | ForEach-Object { $_['id'] }) | Should -Be @('cccccccc-0000-0000-0000-000000000003')
        $source = (@(@($filled['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]['source']) -join '')
        $source | Should -Match '(?m)^DEMO_LAKEHOUSE_ID = "cccccccc-0000-0000-0000-000000000003"\s+#'
        $source | Should -Match '(?m)^DEMO_WORKSPACE_ID = "bbbbbbbb-0000-0000-0000-000000000002"'
        # The binding goes only into the uploaded copy: the repository's notebook stays unbound (ADR 0021).
        $script:notebook['metadata'].Contains('dependencies') | Should -BeFalse
    }

    It 'converts the auto-shutdown''s Windows time zone to its IANA name, and falls back to UTC for one it doesn''t know' {
        InModuleScope -ModuleName DbHubDemo {
            $base = @{ minSessionMinutes = 30; shutdownMarginMinutes = 2; autoStopBufferMinutes = 10; autoShutdownTime = '1900' }
            $iana = ''
            $known = [System.TimeZoneInfo]::TryConvertWindowsIdToIanaId('Eastern Standard Time', [ref]$iana)
            $rule = Get-DemoActivityControlSessionRule -Setting ($base + @{ autoShutdownTimeZone = 'Eastern Standard Time' })
            $rule['autoShutdownTimeZone'] | Should -Be 'Eastern Standard Time'
            if ($known) {
                $rule['autoShutdownIana'] | Should -Be 'America/New_York'
            }
            (Get-DemoActivityControlSessionRule -Setting ($base + @{ autoShutdownTimeZone = 'Europe/Paris' }))['autoShutdownIana'] | Should -BeIn @('Europe/Paris')
            (Get-DemoActivityControlSessionRule -Setting ($base + @{ autoShutdownTimeZone = 'Not A Zone' }))['autoShutdownIana'] | Should -Be 'UTC'
        }
    }
}
