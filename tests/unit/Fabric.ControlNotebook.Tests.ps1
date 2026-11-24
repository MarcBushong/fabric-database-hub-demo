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

    # DBHUB_TEST_PYTHON, when it's set, is the Python 3 every case uses, so the suite needs none on PATH (the review of
    # 40ff59bb: with it alone, 93 cases were skipped); otherwise python3 or python on PATH.
    $script:python = $null
    foreach ($candidate in @(@($env:DBHUB_TEST_PYTHON) + @('python3', 'python') | Where-Object { $_ })) {
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

    # The notebook as deploy.ps1 imports it, for a demo whose VMs shut down at 19:00 in the zone given; -ControlProblem is
    # what deploy.ps1 found missing in the session control (F29).
    function Get-FilledNotebook([string] $Zone = 'UTC', [string] $Prefix = '', [string] $ControlProblem = '') {
        $filledConfig = Get-DemoConfig -Path (Join-Path -Path $repoRoot -ChildPath 'config/demo.config.example.json')
        $filledConfig['subscriptionId'] = '11111111-2222-3333-4444-555555555555'
        $filledConfig['autoShutdownTime'] = '1900'
        $filledConfig['autoShutdownTimeZone'] = $Zone
        if ($Prefix) {
            $filledConfig['prefix'] = $Prefix
        }
        $definition = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $filledConfig; Problem = $ControlProblem } {
            $controlName = Get-DemoActivityControlName -Config $Config
            $setting = Get-DemoActivityControlRunbookSetting -Config $Config -Name $controlName -IdentityClientId '99999999-9999-9999-9999-999999999999'
            Get-DemoActivityControlNotebook -Name $controlName -Setting $setting -TenantId 'AAAAAAAA-0000-0000-0000-000000000001' -DemoWorkspaceId 'BBBBBBBB-0000-0000-0000-000000000002' -DemoLakehouseId 'CCCCCCCC-0000-0000-0000-000000000003' -DemoLakehouseName 'LH_DatabaseHub' -ControlProblem $Problem
        }
        $file = Join-Path -Path $TestDrive -ChildPath ('filled-{0}{1}{2}.ipynb' -f ($Zone -replace '[^A-Za-z]', ''), $Prefix, $(if ($ControlProblem) { '-problem' } else { '' }))
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
import base64
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
# The control notebook's default lakehouse, which deploy.ps1 attaches: none in "unbound", "full", "leftoverjob",
# "rcaleftoverjob", and "sessionqsfull".
LAKEHOUSE = "" if scenario in ("unbound", "full", "leftoverjob", "rcaleftoverjob", "sessionqsfull") else "cccccccc-0000-0000-0000-000000000003"
# The Incident RCA (ADR 0031): the metrics secret's earlier versions, which hold the bundles the runbook wrote; the demo
# lakehouse's files (notebookutils.fs); what the activity notebook found staged; and the versions read.
VERSIONS, FILES, FOLDERS, STAGED, VAULTREADS = {}, {}, set(), [], []
# A session's history that runs as a job, with its evidence staged (re-check of d2067d69): the reference run fails, and the
# job's state at Run all's look is queued, Completed after its notebook deleted the file, Completed with the file left (a
# copy from before the Incident RCA), or Failed; or Completed with the staged file's check raising (review of 37a546bc).
RCA_JOB_SCENARIOS = ("rcajobqueued", "rcajobdone", "rcajobold", "rcajobfailed", "rcajobunchecked")
RCA_SCENARIOS = ("sessionrca", "sessionrcaold", "earlierrca", "leftoverrca", "bundlefail", "sessionrcalate", "sessionrcapinfail", "takenoverrca") + RCA_JOB_SCENARIOS + ("sessionqs",)
FIXTURE = json.load(open(sys.argv[4] + "/rca/fixtures/rca-evidence.parameter.json", encoding="utf-8")) if len(sys.argv) > 4 else {"parts": []}
BUNDLE_PARTS = {"1" * 32: FIXTURE["parts"][:2], "2" * 32: FIXTURE["parts"][2:], "3" * 32: FIXTURE["parts"][:2]}
DOCUMENT_REFS = [{"documentId": part.split()[2], "parts": int(part.split()[3].split("/")[1]), "sha256": part.split()[4]} for part in FIXTURE["parts"][::2]]
# The Incident RCA's sidecars on Run all's path (2026-11-23): the stop's sidecar bundle and its index, versions of the
# metrics secret, and the metrics' rcaSidecars pointer (rca/fixtures); the activity notebook's definition, which declares
# RCA_SIDECAR_FILE unless it's from before the sidecar ("sessionqsold"); the payloads it read; and its acknowledgements in
# Files/rca/acks, which it writes as B's notebook does: every sidecar written, one skipped ("sessionqsskip"), or none
# ("sessionqsnoack"). Its definition is read through Get Item Definition's long-running operation in "sessionqs".
SIDECAR_STOP_SCENARIOS = ("sessionqs", "sessionqsold", "sessionqsskip", "sessionqsnoack", "sessionqsjob", "sessionqsfull", "sessionqslate", "sessionqslateindex",
                          "sessionqsbadversion", "sessionqsbadindex", "sessionqsnullindex")
FIXTURES = (sys.argv[4] + "/rca/fixtures/") if len(sys.argv) > 4 else ""
SIDECAR_BUNDLE = json.load(open(FIXTURES + "sidecar-bundle.json", encoding="utf-8")) if FIXTURES else {}
SIDECAR_INDEX = json.load(open(FIXTURES + "sidecar-bundle-index.json", encoding="utf-8")) if FIXTURES else {}
SIDECAR_POINTER = json.load(open(FIXTURES + "metrics-rca-sidecars-member.json", encoding="utf-8")) if FIXTURES else {}
SIDECARS, DEFREADS, PUTS = [], [], []
BASE = "abfss://bbbbbbbb-0000-0000-0000-000000000002@onelake.dfs.fabric.microsoft.com/cccccccc-0000-0000-0000-000000000003/"


def sidecar_pointer(session):
    """The metrics' rcaSidecars pointer that a runbook with Run all's sidecar path writes last, after the sidecar bundle and
    its index, which it writes as earlier versions of the metrics secret."""
    VERSIONS[SIDECAR_INDEX["bundles"][0]] = json.dumps(dict(SIDECAR_BUNDLE, sessionId=session))
    VERSIONS[SIDECAR_POINTER["index"]] = json.dumps(dict(SIDECAR_INDEX, sessionId=session))
    return dict(SIDECAR_POINTER)


def activity_definition(declares):
    """NB_DatabaseHub_LiveActivity's definition (Items - Get Item Definition): its parameters, RCA_SIDECAR_FILE among them
    when it's from the sidecar on."""
    source = 'RCA_EVIDENCE_FILE = ""\nRCA_ONLY = False\n' + ('RCA_SIDECAR_FILE = ""\n' if declares else "")
    return {"definition": {"parts": [{"path": "notebook-content.py", "payload": base64.b64encode(source.encode("utf-8")).decode("ascii"), "payloadType": "InlineBase64"},
                                     {"path": ".platform", "payload": base64.b64encode(b"{}").decode("ascii"), "payloadType": "InlineBase64"}]}}


def acknowledge(payload, documents):
    """An acknowledgement in Files/rca/acks (rca/transport.schema.json, ack), as the activity notebook writes it."""
    FOLDERS.add(BASE + "Files/rca/acks")
    name = "Files/rca/acks/%s.ack.json" % payload.rsplit("/", 1)[1][:-len(".json")]
    FILES[BASE + name] = json.dumps({"kind": "ContosoCare.RcaAck", "version": 1, "payload": payload, "runId": "run-1", "documents": [
        dict({"documentId": document, "kind": "ContosoCare.RcaSidecar", "status": status}, **({"reason": "its SHA-256 doesn't match"} if status == "skipped" else {}))
        for document, status in documents]})
    return name


def acks_sent_later(result, by):
    """Option 2 (2026-11-23): the session's next warm export, a re-check's or else the stop's, sends what its start left
    (T2's host answers by then), and writes rcaAcks again, only moving IDs from left to sent."""
    sent = list(result["sent"]) + [item for item in result["left"] if item not in result["sent"]]
    return {"kind": "ContosoCare.RcaAckResult", "version": 1, "sent": sent, "left": [], "status": "Pass",
            "message": "%d sidecar acknowledgement(s) sent: %d before the start's sidecar fetch, %d at %s." % (
                len(sent), len(result["sent"]), len(sent) - len(result["sent"]), by)}


def rca_bundle_index(session, bundles):
    """The rca member the runbook writes (rca/transport.schema.json, bundleIndex), for the bundles given."""
    for version in bundles:
        VERSIONS[version] = json.dumps({"kind": "ContosoCare.RcaBundle", "version": 1, "sessionId": session, "parts": BUNDLE_PARTS[version]})
    return {"kind": "ContosoCare.RcaBundleIndex", "version": 1, "sessionId": session, "bundles": bundles,
            "documents": [ref for ref in DOCUMENT_REFS if any(ref["documentId"] in part for version in bundles for part in BUNDLE_PARTS[version])],
            "status": "Pass", "message": "%d evidence document(s) from sqlvm01." % len(bundles)}


class FileSystem:
    """notebookutils.fs over the demo lakehouse, in memory."""
    def mkdirs(self, path):
        FOLDERS.add(path)
        return True

    def put(self, path, content, overwrite=False):
        FILES[path] = content
        if path.startswith(BASE + "Files/rca/inbox/sidecar-"):
            PUTS.append({"name": path[len(BASE):], "document": json.loads(content)})
        return True

    def exists(self, path):
        if scenario == "rcajobunchecked" and path.endswith(".json"):
            # OneLake didn't answer the staged file's check (review of 37a546bc).
            raise OSError("OneLake didn't answer")
        return path in FILES or path in FOLDERS

    def ls(self, path):
        prefix = path.rstrip("/") + "/"
        return [types.SimpleNamespace(name=name[len(prefix):]) for name in sorted(FILES) if name.startswith(prefix) and "/" not in name[len(prefix):]]

    def head(self, path, max_bytes=102400):
        if path not in FILES:
            raise FileNotFoundError(path)
        return FILES[path][:max_bytes]

    def rm(self, path, recurse=False):
        if scenario == "qsacksrmfail" and path.endswith("/sidecar-20261001T120000Z-runall-1a2b3c4d.ack.json"):
            # OneLake refuses to delete the acknowledgement more than 30 days old.
            raise OSError("OneLake refused the delete")
        FILES.pop(path, None)
        return True


def running_status(session_id, accepted, minutes):
    end = accepted + real_dt.timedelta(minutes=minutes)
    dispatch = accepted + real_dt.timedelta(minutes=4)
    return {"schemaVersion": 1, "sessionId": session_id, "phase": "running", "acceptedUtc": iso(accepted), "runEndUtc": iso(end),
            "autoStopUtc": iso(end + real_dt.timedelta(minutes=10)), "durationMinutes": minutes, "plannedMinutes": minutes,
            "names": {"resourceGroup": "rg-dbhub-demo", "deploymentId": "abc123", "sqlVm": "sqlvm01", "hostVm": "archost01", "t2Guest": "arcsql01",
                      "t3Server": "azuresql01-abc123", "t3Database": "ContosoCare", "t4Server": "pgflex01-abc123", "t4Replica": "pgreplica01-abc123"},
            "dispatchUtc": {"T1": iso(dispatch), "T3": iso(dispatch), "T2": iso(dispatch + real_dt.timedelta(minutes=6)), "T4": iso(dispatch + real_dt.timedelta(minutes=5))},
            "t4": {"state": "Ready", "sku": "Standard_D4ds_v5", "tier": "GeneralPurpose"},
            "replica": {"state": "Ready", "note": "", "fix": ""},
            "replicaLag": {"planned": True, "note": "Read replica lag climbs to about 3 minutes, twice.", "fix": ""},
            "steps": [{"step": "Plan", "state": "Pass", "atUtc": iso(accepted), "message": "The showcase runs %d minutes on every target." % minutes, "fix": ""},
                      {"step": "Activity", "state": "Pass", "atUtc": iso(dispatch), "message": "T1: showcase for %d minutes" % minutes, "fix": ""}],
            "message": "The session runs until %s UTC." % iso(end)}


def cold_start_steps(status, accepted):
    """A cold start (2026-11-24): the session's start brought sqlvm01 and T2's host up (the runbook's vm-start progress,
    "<vm> is starting."), and started T4, which isn't a VM. Returns what the validator must hear: when each target came up,
    T3 at its activity's dispatch, which resumes it. In "coldstartrefused", Azure refused the T2 host's start, so it has no
    Start step and T2 no activity, and T3's activity wasn't sent either; in "coldstartwording", the Start steps say it in
    words this notebook doesn't know (the review of 40ff59bb)."""
    sql, host = iso(accepted + real_dt.timedelta(seconds=5)), iso(accepted + real_dt.timedelta(seconds=20))
    steps = [{"step": "Start", "state": "Info", "atUtc": sql, "message": "sqlvm01 is starting.", "fix": ""},
             {"step": "Start", "state": "Info", "atUtc": host, "message": "archost01 is starting.", "fix": ""}]
    cold = {"T1": sql, "T2": host, "T3": status["dispatchUtc"]["T3"]}
    if scenario == "coldstartrefused":
        steps, cold = steps[:1], {"T1": sql}
        del status["dispatchUtc"]["T2"], status["dispatchUtc"]["T3"]
    if scenario == "coldstartwording":
        cold = {}
        for step in steps:
            step["message"] = "Starting %s." % step["message"].split()[0]
    status["steps"][1:1] = steps + [{"step": "T4", "state": "Info", "atUtc": iso(accepted + real_dt.timedelta(seconds=30)), "message": "T4 (pgflex01-abc123) is starting.", "fix": ""}]
    return json.dumps(cold, sort_keys=True)


# The cold starts (2026-11-24): T2's guest never sends telemetry (the review of 40ff59bb) in COLD_SCENARIOS but "coldstart",
# where it reports at once, and the three in T2_FIRST_SAMPLE. Its checks again come at 14:30 and 14:40 for a session from
# 14:00 (20 and 30 minutes after T2's dispatch at 14:10, the review of d6d69832): in "coldstartfail"; also when the status
# can't be read at the first ("coldstartunread"); with a live view that ends too soon ("coldstartshort"), a session the
# app stops first ("coldstartstopped"), a validator that fails each time ("coldstartrecheckfail"), or an answer of a kind
# this notebook doesn't know ("coldstartforeign"); in a 30-minute session, once, at its end ("coldstart30"); with checks
# again that hold the live view up almost 5 minutes each ("coldstartslow"); and both in a 33-minute session, whose first
# check again, at 14:30, runs past its end at 14:33, when the one that decides is due ("coldstart33").
COLD_SCENARIOS = ("coldstart", "coldstartfail", "coldstartunread", "coldstartshort", "coldstartstopped", "coldstartrecheckfail", "coldstartforeign",
                  "coldstartrefused", "coldstartwording", "coldstartgrace", "coldstartlate", "coldstart30", "coldstartslow", "coldstart33")
# When T2's first sample shows, in minutes after the session's start, where it's late but healthy: before the first check
# again ("coldstartgrace"), and after it, before the one that decides ("coldstartlate"; the review of d6d69832).
T2_FIRST_SAMPLE = {"coldstartgrace": 25, "coldstartlate": 35}


def t2_reports():
    """Whether T2's guest has sent telemetry since the session's start, by now."""
    if scenario not in COLD_SCENARIOS or scenario == "coldstart":
        return True
    first = T2_FIRST_SAMPLE.get(scenario)
    return first is not None and Clock.now >= RUNBOOK["accepted"] + real_dt.timedelta(minutes=first)


def validator_answer(arguments):
    """NB_DatabaseHub_Deployment's answer to Run all (notebookutils.notebook.exit, since 2026-11-24), as its per-target cell
    decides it: a target that the session's start brought up, with no telemetry since, is a Warning, not known yet, until
    TELEMETRY_DECIDE_UTC, and a Fail from then (the review of d6d69832). T1 and T3 report; T2 as t2_reports says."""
    cold = json.loads(arguments.get("COLD_START_UTC") or "{}")
    decide = arguments.get("TELEMETRY_DECIDE_UTC") or ""
    decide = real_dt.datetime.fromisoformat(decide.replace("Z", "+00:00")) if decide else None
    telemetry, pending = {}, []
    for target in ("T1", "T2", "T3"):
        if target != "T2" or t2_reports():
            telemetry[target] = {"status": "Pass", "message": "%s reports performance telemetry from 3 tables." % target}
        elif target in cold and decide is not None and Clock.now < decide:
            telemetry[target] = {"status": "Warning", "message": "No telemetry from T2 arcsql01 since this session's cold start yet, so whether it reports can't be known yet."}
            pending.append(target)
        else:
            telemetry[target] = {"status": "Fail", "message": "No telemetry from T2 arcsql01 in the last 60 minutes."}
    return json.dumps({"kind": "DbHubDemo.Other" if scenario == "coldstartforeign" else "DbHubDemo.Readiness", "version": 1, "runId": "run-%d" % len(VALIDATORS),
                       "telemetry": telemetry, "pending": pending})


def with_t5(status, dispatch, minutes=75):
    """T5 in the session (2026-11-18): its account, its showcase sent with sqlvm01's, and when it's back at its baseline after
    its last ru-storm (2026-11-19: the runbook's t5.endUtc, here 75 minutes after its dispatch for a session that ends 86 after)."""
    status["names"]["t5Account"] = "cosmos01-abc123"
    status["dispatchUtc"]["T5"] = iso(dispatch)
    status["t5"] = {"endUtc": iso(dispatch + real_dt.timedelta(minutes=minutes))}
    return status


# What a session's stop keeps of its plan since 2026-11-19 (the runbook's Write-DbHubStopStatus).
PLAN_FIELDS = ("acceptedUtc", "runEndUtc", "dispatchUtc", "t4", "replicaLag", "t5")


def stopped_status(session_id, ended, running=None, kept=None):
    """The status the runbook's Stop now writes: what it did and, since 2026-11-19, the session's plan from running (the
    status it replaces) and whether it kept it (planKept; kept=False: the status it replaced wasn't this session's). A
    runbook from before then writes neither (running and kept None)."""
    status = {"schemaVersion": 1, "sessionId": session_id, "phase": "stopped", "updatedUtc": iso(ended), "stoppedBy": "Stop now",
              "done": ["T4's read replica deleted", "T4 stopped", "sqlvm01 deallocated"], "failed": [], "metrics": {"status": "Pass", "message": "Azure Monitor metrics for the history."}}
    if running is not None:
        status.update({key: running[key] for key in PLAN_FIELDS if key in running}, planKept=True)
    elif kept is not None:
        status["planKept"] = kept
    return status


def cosmos_document(session, start, end):
    return {"version": 1, "sessionId": session, "capturedBy": "control", "capturedUtc": iso(end), "startUtc": iso(start), "endUtc": iso(end),
            "windowMinutes": int((end - start).total_seconds() // 60), "intervalMinutes": 1, "accounts": [{"target": "T5", "resourceName": "cosmos01-abc123"}],
            "series": [{"resourceName": "cosmos01-abc123", "metric": "ThrottledRequests", "aggregation": "Count", "unit": "Count", "statusCode": "429",
                        "intervalMinutes": 1, "points": [[iso(start + real_dt.timedelta(minutes=10)), 120]]}]}


if scenario in ("active", "stopnow"):
    RUNBOOK.update(session="a" * 32, accepted=Clock.now - real_dt.timedelta(minutes=20), minutes=90)
    VAULT["dbhub-session-status"] = json.dumps(running_status("a" * 32, RUNBOOK["accepted"], 90))
if scenario in ("leftover", "leftoverplan", "leftoverjob"):
    earlier = Clock.now - real_dt.timedelta(days=1)
    # The runbook writes the metrics compact (ConvertTo-Json -Compress).
    VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": "e" * 32, "capturedUtc": iso(earlier), "startUtc": iso(earlier - real_dt.timedelta(minutes=100)),
                                                 "endUtc": iso(earlier), "windowMinutes": 100, "intervalMinutes": 1, "servers": [], "series": [{"metric": "cpu_percent"}]}, separators=(",", ":"))
    if scenario == "leftoverplan":
        # Its stop, which keeps its plan (2026-11-19): it ran its 90 minutes, accepted 10 minutes after its metrics start.
        VAULT["dbhub-session-status"] = json.dumps(stopped_status("e" * 32, earlier, running_status("e" * 32, earlier - real_dt.timedelta(minutes=90), 90)))
if scenario in ("stoppedend", "stoppedold"):
    # The app's Stop now cancelled the run that was ending session bbbb... while it waited for the telemetry (2026-11-19):
    # the runbook had stopped it and kept its metrics, 5 minutes ago ("stoppedold": 10 days ago). A runbook from before
    # 2026-11-19 wrote its stopped status, with no plan.
    ended = Clock.now - (real_dt.timedelta(days=10) if scenario == "stoppedold" else real_dt.timedelta(minutes=5))
    VAULT["dbhub-session-status"] = json.dumps(stopped_status("b" * 32, ended))
    VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": "b" * 32, "capturedUtc": iso(ended), "startUtc": iso(ended - real_dt.timedelta(minutes=90)),
                                                 "endUtc": iso(ended), "windowMinutes": 90, "intervalMinutes": 1, "servers": [], "series": [{"metric": "cpu_percent"}]}, separators=(",", ":"))
if scenario in ("stoppedplan", "stoppedplannometrics"):
    # The same, with the stop of a runbook from 2026-11-19 on, which keeps the session's plan: it ran its 90 minutes, and
    # its metrics start 10 minutes before it ("stoppedplannometrics": the vault's metrics are an earlier session's).
    ended = Clock.now - real_dt.timedelta(minutes=5)
    VAULT["dbhub-session-status"] = json.dumps(stopped_status("b" * 32, ended, running_status("b" * 32, ended - real_dt.timedelta(minutes=90), 90)))
    VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": ("b" if scenario == "stoppedplan" else "f") * 32, "capturedUtc": iso(ended),
                                                 "startUtc": iso(ended - real_dt.timedelta(minutes=100)), "endUtc": iso(ended), "windowMinutes": 100, "intervalMinutes": 1,
                                                 "servers": [], "series": [{"metric": "cpu_percent"}]}, separators=(",", ":"))
if scenario == "stoppedstart":
    # Stopped during its start, 5 minutes ago, before it had an end: T1 and T3 had their activity, and the vault's metrics
    # are an earlier session's.
    ended = Clock.now - real_dt.timedelta(minutes=5)
    starting = running_status("b" * 32, ended - real_dt.timedelta(minutes=12), 90)
    starting.update(phase="starting", runEndUtc="", dispatchUtc={key: starting["dispatchUtc"][key] for key in ("T1", "T3")})
    VAULT["dbhub-session-status"] = json.dumps(stopped_status("b" * 32, ended, starting))
    VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": "f" * 32, "capturedUtc": iso(ended - real_dt.timedelta(days=1)), "startUtc": iso(ended - real_dt.timedelta(days=1, minutes=100)),
                                                 "endUtc": iso(ended - real_dt.timedelta(days=1)), "windowMinutes": 100, "intervalMinutes": 1, "servers": [], "series": [{"metric": "cpu_percent"}]}, separators=(",", ":"))
if scenario == "stoppedlost":
    # A runbook from 2026-11-19 on stopped it when the status it replaced was another session's, so it kept no plan.
    ended = Clock.now - real_dt.timedelta(minutes=5)
    VAULT["dbhub-session-status"] = json.dumps(stopped_status("b" * 32, ended, kept=False))
    VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": "b" * 32, "capturedUtc": iso(ended), "startUtc": iso(ended - real_dt.timedelta(minutes=90)),
                                                 "endUtc": iso(ended), "windowMinutes": 90, "intervalMinutes": 1, "servers": [], "series": [{"metric": "cpu_percent"}]}, separators=(",", ":"))
if scenario == "takenoverstop":
    # Session dddd...'s end passed 5 minutes ago, and its end's stop hasn't come: a start-demo.ps1 session took over from it
    # (2026-11-20), and the app's Stop now runs now, inside the takeover window.
    RUNBOOK.update(session="d" * 32, accepted=Clock.now - real_dt.timedelta(minutes=95), minutes=90)
    VAULT["dbhub-session-status"] = json.dumps(running_status("d" * 32, RUNBOOK["accepted"], 90))
if scenario == "takenoveragain":
    # Session dddd...'s end, 5 minutes ago, found a start-demo.ps1 session that took over, and stopped nothing (2026-11-20);
    # Stop now again, inside the takeover window.
    ended = Clock.now - real_dt.timedelta(minutes=5)
    RUNBOOK.update(session="d" * 32, accepted=ended - real_dt.timedelta(minutes=90), minutes=90)
    taken = stopped_status("d" * 32, ended, running_status("d" * 32, RUNBOOK["accepted"], 90))
    taken.update(stoppedBy="session end", takenOver={"by": "start-demo", "autoStopUtc": iso(ended + real_dt.timedelta(hours=3))},
                 done=["nothing stopped: a start-demo.ps1 session took over from this one", "busy marker cleared"])
    VAULT["dbhub-session-status"] = json.dumps(taken)
if scenario == "endedrunning":
    # Session cccc...'s end passed 10 minutes ago, and nothing stopped it: the run that was ending it was cancelled first.
    RUNBOOK.update(session="c" * 32, accepted=Clock.now - real_dt.timedelta(minutes=100), minutes=90)
    VAULT["dbhub-session-status"] = json.dumps(running_status("c" * 32, RUNBOOK["accepted"], 90))
if scenario == "leftovercosmos":
    # T5's metrics alone (2026-11-18): an empty T4 document carries them as its cosmos member.
    earlier = Clock.now - real_dt.timedelta(days=1)
    VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": "e" * 32, "capturedBy": "control", "capturedUtc": iso(earlier), "startUtc": iso(earlier - real_dt.timedelta(minutes=100)),
                                                 "endUtc": iso(earlier), "windowMinutes": 100, "intervalMinutes": 1, "servers": [], "series": [],
                                                 "cosmos": cosmos_document("e" * 32, earlier - real_dt.timedelta(minutes=100), earlier)}, separators=(",", ":"))
if scenario in ("leftoverrca", "rcaleftoverjob"):
    # The Incident RCA's evidence alone (ADR 0031): an empty T4 document carries the bundle index as its rca member.
    earlier = Clock.now - real_dt.timedelta(days=1)
    VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": "e" * 32, "capturedBy": "control", "capturedUtc": iso(earlier), "startUtc": iso(earlier - real_dt.timedelta(minutes=100)),
                                                 "endUtc": iso(earlier), "windowMinutes": 100, "intervalMinutes": 1, "servers": [], "series": [],
                                                 "rca": rca_bundle_index("e" * 32, ["1" * 32, "2" * 32])}, separators=(",", ":"))


def runbook(body):
    action = body["action"]
    if action == "session":
        if scenario == "refused":
            VAULT["dbhub-session-status"] = json.dumps({"sessionId": body["sessionId"], "phase": "refused", "message": "A run is already active: it ends at 15:00.",
                                                        "steps": [{"step": "Start", "state": "Fail", "atUtc": iso(Clock.now), "message": "A run is already active: it ends at 15:00.", "fix": "Wait until it ends, or run the notebook's Stop now cell first."}]})
            return
        RUNBOOK.update(session=body["sessionId"], accepted=Clock.now, minutes=body["durationMinutes"], acks=body.get("rcaAcks"))
        VAULT["dbhub-session-status"] = json.dumps({"sessionId": body["sessionId"], "phase": "starting", "acceptedUtc": iso(Clock.now), "steps": []})
        if scenario == "qsacksearly" and body.get("rcaAcks"):
            # T2c-1's runbook (a114c727) first writes a result before it sends anything, then the real one with its step.
            starting = json.loads(VAULT["dbhub-session-status"])
            starting["rcaAcks"] = {"kind": "ContosoCare.RcaAckResult", "version": 1, "sent": [], "left": body["rcaAcks"]["documents"], "status": "Warning",
                                   "message": "None of the %d sidecar acknowledgement(s) was sent: not yet: the start sends them before its exports." % len(body["rcaAcks"]["documents"])}
            VAULT["dbhub-session-status"] = json.dumps(starting)
    elif action == "stop":
        session = body.get("sessionId") or ""
        if not session and scenario in ("takenoverstop", "takenoveragain"):
            # A stop with no session ID writes the stopped status of the session the group names (DbHubSessionId).
            session = json.loads(VAULT["dbhub-session-status"]).get("sessionId") or ""
        replaced = json.loads(VAULT["dbhub-session-status"])
        VAULT["dbhub-session-status"] = json.dumps({"sessionId": session, "phase": "stopped", "stoppedBy": "Stop now", "failed": [],
                                                    "done": ["T4's read replica deleted", "T4 stopped", "sqlvm01 deallocated"], "metrics": {"status": "Pass", "message": "Azure Monitor metrics for the history."}})
        if (scenario in ("takenover", "takenoverrca") or (scenario == "takenoverstop" and body.get("sessionId"))) and session:
            # A start-demo.ps1 session took over from this one (2026-11-20): the runbook stops nothing at its end, and says
            # when that session's auto-stop stops the demo (Complete-DbHubTakenOverSession). With the RCA (takenoverrca),
            # that end exports the session's evidence, as a stop does (the RCA release's merge).
            until = iso(Clock.now + real_dt.timedelta(hours=3))
            VAULT["dbhub-session-status"] = json.dumps({"sessionId": session, "phase": "stopped", "stoppedBy": "session end", "failed": [],
                                                        "done": ["nothing stopped: a start-demo.ps1 session took over from this one, and its auto-stop stops the demo at " + until,
                                                                 "the history's metrics saved to the control vault", "busy marker cleared"],
                                                        "metrics": {"status": "Pass", "message": "Azure Monitor metrics for the history."},
                                                        "takenOver": {"by": "start-demo", "autoStopUtc": until}})
        if session and replaced.get("sessionId") == session and replaced.get("rcaAcks"):
            # The stop keeps the start's acknowledgement result from the status it replaces (Write-DbHubStopStatus), as its
            # session's re-checks left it; with "qsacksstop" it sends what's still left first (T2's host is warm by then).
            stopped = json.loads(VAULT["dbhub-session-status"])
            stopped["rcaAcks"] = replaced["rcaAcks"]
            if scenario == "qsacksstop":
                stopped["rcaAcks"] = acks_sent_later(replaced["rcaAcks"], "the stop")
            VAULT["dbhub-session-status"] = json.dumps(stopped)
        if session and scenario in RCA_SCENARIOS:
            # A runbook with the Incident RCA (ADR 0031): the stop's export, and each target's capture line, for the notebook.
            stopped = json.loads(VAULT["dbhub-session-status"])
            stopped.update(rca={"sessionId": session, "bundles": ["1" * 32, "2" * 32], "final": True, "status": "Pass"},
                           rcaLines=[{"step": "RCA.EXPORT", "status": "Pass", "message": "2 evidence documents in 4 parts from sqlvm01.", "fix": ""},
                                     {"step": "RCA.CAPTURE.T1", "status": "Pass", "message": "T1: captured from 16:50 to 17:05 UTC.", "fix": ""}])
            if scenario == "earlierrca":
                stopped["rcaEarlier"] = json.loads(VAULT["dbhub-session-status"]).get("rcaEarlier") or RUNNING_EARLIER[0]
            VAULT["dbhub-session-status"] = json.dumps(stopped)
        if session:
            accepted = RUNBOOK["accepted"] or Clock.now
            document = {"version": 1, "sessionId": session, "capturedUtc": iso(Clock.now), "startUtc": iso(accepted), "endUtc": iso(Clock.now),
                        "windowMinutes": 90, "intervalMinutes": 1, "servers": [], "series": [{"metric": "cpu_percent"}]}
            if scenario == "sessioncosmos":
                document["cosmos"] = cosmos_document(session, accepted, Clock.now)
            if scenario in RCA_SCENARIOS and scenario != "leftoverrca":
                document["rca"] = rca_bundle_index(session, ["1" * 32, "2" * 32])
            if scenario in SIDECAR_STOP_SCENARIOS:
                document["rcaSidecars"] = sidecar_pointer(session)
                # A pointer this notebook can't use: another version, or an index that isn't a version's ID (a trailing line
                # feed, which the contract's anchors refuse); and one that names no sidecar (a null index).
                if scenario == "sessionqsbadversion":
                    document["rcaSidecars"]["version"] = 2
                if scenario == "sessionqsbadindex":
                    document["rcaSidecars"]["index"] += "\n"
                if scenario == "sessionqsnullindex":
                    document["rcaSidecars"].update(index=None, documents=0, status="Not selected", message="No sidecar this session.")
            VAULT["dbhub-session-metrics"] = json.dumps(document, separators=(",", ":"))
            if scenario in SIDECAR_STOP_SCENARIOS:
                # A runbook with Run all's sidecar path names the metrics' final version too ("sessionqslate" and
                # "sessionqslateindex": the vault refuses it, and the stop's sidecar bundle, or its index, is the latest).
                pin_metrics("9" * 32)
                if scenario == "sessionqslate":
                    VAULT["dbhub-session-metrics"] = VERSIONS[SIDECAR_INDEX["bundles"][0]]
                if scenario == "sessionqslateindex":
                    VAULT["dbhub-session-metrics"] = VERSIONS[SIDECAR_POINTER["index"]]
            if scenario in ("sessionrcalate", "sessionrcapinfail"):
                # A runbook from 2026-11-20 on names the metrics' final version in the stop's status (review of 15ad76d) ...
                pin_metrics("4" * 32)
                if scenario == "sessionrcalate":
                    # ... because a re-check's bundle, written right after it, can be the secret's latest version.
                    late_bundle(session)


def pin_metrics(version):
    """The stop's status names the metrics' version that the stop wrote (metrics.version), which Get Secret reads by its ID."""
    VERSIONS[version] = VAULT["dbhub-session-metrics"]
    stopped = json.loads(VAULT["dbhub-session-status"])
    stopped["metrics"]["version"] = version
    VAULT["dbhub-session-status"] = json.dumps(stopped)


def late_bundle(session):
    """A re-check's evidence bundle written after the stop's version of the metrics: the secret's latest."""
    VAULT["dbhub-session-metrics"] = json.dumps({"kind": "ContosoCare.RcaBundle", "version": 1, "sessionId": session, "parts": FIXTURE["parts"][:2]}, separators=(",", ":"))


if scenario in ("stoppedlate", "leftoverlate"):
    # A stopped session whose status names its metrics' version, and a re-check's bundle after it as the latest: Stop now
    # when no session runs ("stoppedlate"), and the next Run all's pre-check ("leftoverlate").
    session = ("b" if scenario == "stoppedlate" else "e") * 32
    ended = Clock.now - (real_dt.timedelta(minutes=5) if scenario == "stoppedlate" else real_dt.timedelta(days=1))
    VAULT["dbhub-session-status"] = json.dumps(stopped_status(session, ended, running_status(session, ended - real_dt.timedelta(minutes=90), 90)))
    VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": session, "capturedUtc": iso(ended), "startUtc": iso(ended - real_dt.timedelta(minutes=100)),
                                                 "endUtc": iso(ended), "windowMinutes": 100, "intervalMinutes": 1, "servers": [], "series": [{"metric": "cpu_percent"}]}, separators=(",", ":"))
    pin_metrics("5" * 32)
    late_bundle(session)
if scenario in ("leftoverqs", "stoppedqs", "earlierqs"):
    # Run all's sidecar path in an earlier session's history: its metrics, with the pointer to its sidecars, kept in the
    # vault a day ago, saved as a leftover by the pre-check ("leftoverqs", the runbook's status from before 2026-11-14 had
    # no plan); 5 minutes ago, by Stop now when no session runs ("stoppedqs"); or, without T4's series, so the pre-check
    # doesn't save its history, with the evidence of an even earlier session that its start exported, saved alone
    # ("earlierqs").
    session = ("e" if scenario == "leftoverqs" else "b") * 32
    ended = Clock.now - (real_dt.timedelta(days=1) if scenario == "leftoverqs" else real_dt.timedelta(minutes=5))
    if scenario != "leftoverqs":
        status = stopped_status(session, ended, running_status(session, ended - real_dt.timedelta(minutes=90), 90))
        if scenario == "earlierqs":
            status["rcaEarlier"] = rca_bundle_index("d" * 32, ["3" * 32])
        VAULT["dbhub-session-status"] = json.dumps(status)
    VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": session, "capturedUtc": iso(ended), "startUtc": iso(ended - real_dt.timedelta(minutes=100)),
                                                 "endUtc": iso(ended), "windowMinutes": 100, "intervalMinutes": 1, "servers": [],
                                                 "series": [] if scenario == "earlierqs" else [{"metric": "cpu_percent"}],
                                                 "rcaSidecars": sidecar_pointer(session)}, separators=(",", ":"))
    if scenario != "leftoverqs":
        pin_metrics("5" * 32)
# Run all's acknowledgements from earlier saves ("qsacks"), which the next start carries as rcaAcks: one whose sidecars
# the start sends, one with only a skipped sidecar, one with a sidecar the start's runbook leaves for the next (T2's), one
# more than 30 days old, the scripts' own, which Run all never reads, and one naming another payload, which counts as
# missing.
QS_IDS = ["20261113T140000Z-sqlvm01-0001-sidecar", "20261113T141500Z-sqlvm01-0002-sidecar", "20261113T143000Z-sqlvm01-0003-sidecar",
          "20261113T144500Z-arcsql01-0001-sidecar", "20261113T150000Z-sqlvm01-0004-sidecar"]
if scenario in ("qsacks", "qsacksearly", "qsacksrmfail", "qsacksrecheck", "qsacksstop", "qsacksstepped"):
    acknowledge("Files/rca/inbox/sidecar-20261113T150000Z-runall-0a1b2c3d.json", [(QS_IDS[0], "written"), (QS_IDS[1], "already"), (QS_IDS[2], "skipped")])
    acknowledge("Files/rca/inbox/sidecar-20261113T155000Z-runall-6c7d8e9f.json", [(QS_IDS[2], "skipped")])
    acknowledge("Files/rca/inbox/sidecar-20261113T160000Z-runall-4e5f6a7b.json", [(QS_IDS[1], "already"), (QS_IDS[3], "written")])
    # More than 30 days old by the time in its name: the runner kept its sidecar no longer, so it goes unsent.
    acknowledge("Files/rca/inbox/sidecar-20261001T120000Z-runall-1a2b3c4d.json", [("20261001T110000Z-sqlvm01-0009-sidecar", "written")])
    acknowledge("Files/rca/inbox/sidecar-20261113T170000Z-script-8c9d0e1f.json", [(QS_IDS[4], "written")])
    other = acknowledge("Files/rca/inbox/sidecar-20261113T180000Z-runall-2a3b4c5d.json", [(QS_IDS[4], "written")])
    FILES[BASE + other] = FILES[BASE + other].replace("2a3b4c5d", "99999999")
# Whole acknowledgements, the oldest first ("qsackswhole"): 40 sidecars, then 30, which would pass the 64 a start takes,
# then 1, which waits behind them. Older than all of them, one that lists 65, more than the contract's 64, of which 3 are
# written: it doesn't follow the contract, so none of it rides, and it holds nothing back.
WHOLE_IDS = ["20261113T%02d%02d00Z-sqlvm01-%04d-sidecar" % (10 + n // 60, n % 60, n) for n in range(71)]
OVER_IDS = ["20261112T%02d%02d00Z-sqlvm01-%04d-sidecar" % (10 + n // 60, n % 60, n) for n in range(65)]
if scenario == "qsackswhole":
    acknowledge("Files/rca/inbox/sidecar-20261113T140000Z-runall-0f0f0f0f.json", [(item, "written" if n < 3 else "skipped") for n, item in enumerate(OVER_IDS)])
    acknowledge("Files/rca/inbox/sidecar-20261113T150000Z-runall-0a0a0a0a.json", [(item, "written") for item in WHOLE_IDS[:40]])
    acknowledge("Files/rca/inbox/sidecar-20261113T160000Z-runall-0b0b0b0b.json", [(item, "written") for item in WHOLE_IDS[40:70]])
    acknowledge("Files/rca/inbox/sidecar-20261113T170000Z-runall-0c0c0c0c.json", [(WHOLE_IDS[70], "written")])
# A session that stopped with its acknowledgement result final, its T2 ID sent after its start (option 2), outside the
# follow of a Run all: Stop now 5 minutes later ("stoppedqsacks"), and the next day's Run all ("qsacksprecheck"). Two of
# Run all's acknowledgements are done by its result, and one, a later save's, rides on the next start.
if scenario in ("stoppedqsacks", "qsacksprecheck"):
    session = ("b" if scenario == "stoppedqsacks" else "e") * 32
    ended = Clock.now - (real_dt.timedelta(minutes=5) if scenario == "stoppedqsacks" else real_dt.timedelta(days=1))
    earlier_status = stopped_status(session, ended, running_status(session, ended - real_dt.timedelta(minutes=90), 90))
    earlier_status["rcaAcks"] = acks_sent_later({"sent": [QS_IDS[0], QS_IDS[1]], "left": [QS_IDS[3]]}, "the stop")
    VAULT["dbhub-session-status"] = json.dumps(earlier_status)
    if scenario == "stoppedqsacks":
        VAULT["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": session, "capturedUtc": iso(ended), "startUtc": iso(ended - real_dt.timedelta(minutes=100)),
                                                     "endUtc": iso(ended), "windowMinutes": 100, "intervalMinutes": 1, "servers": [], "series": [{"metric": "cpu_percent"}]}, separators=(",", ":"))
    acknowledge("Files/rca/inbox/sidecar-20261113T150000Z-runall-0a1b2c3d.json", [(QS_IDS[0], "written"), (QS_IDS[1], "already"), (QS_IDS[2], "skipped")])
    acknowledge("Files/rca/inbox/sidecar-20261113T160000Z-runall-4e5f6a7b.json", [(QS_IDS[1], "already"), (QS_IDS[3], "written")])
    acknowledge("Files/rca/inbox/sidecar-20261113T190000Z-runall-5d6e7f80.json", [(QS_IDS[4], "written")])


# The status a session's start writes when it exported an earlier session's evidence (its rcaEarlier; ADR 0031).
RUNNING_EARLIER = [None]
# A cold start's: when the runbook's start brought each target up, as the validator must hear it (COLD_START_UTC).
COLD_START = [""]


HOST_WARNING = {"step": "Host", "state": "Warning", "message": "T2: archost01 is deallocated, so T2 has no activity now.",
                "fix": "The session's other targets go on. For T2: set STOP_NOW = True and Run all, then Run all again, which starts archost01 again; ./scripts/status.ps1 shows its state."}


def vault_read(name):
    if name == "dbhub-session-status":
        STATUSREADS[0] += 1
    if name == "dbhub-session-status" and scenario == "coldstartunread" and RUNBOOK["accepted"] \
            and real_dt.timedelta(minutes=29, seconds=30) <= Clock.now - RUNBOOK["accepted"] < real_dt.timedelta(minutes=31, seconds=30):
        # The control vault doesn't answer at T2's first check again, so the status can't say the session ended.
        raise RuntimeError("Key Vault didn't answer.")
    if name == "dbhub-session-status" and RUNBOOK["session"]:
        current = json.loads(VAULT[name])
        if current.get("phase") == "starting" and Clock.now - RUNBOOK["accepted"] >= real_dt.timedelta(seconds=60):
            status = running_status(RUNBOOK["session"], RUNBOOK["accepted"], RUNBOOK["minutes"])
            if scenario in COLD_SCENARIOS:
                COLD_START[0] = cold_start_steps(status, RUNBOOK["accepted"])
            if scenario == "sessioncosmos":
                status = with_t5(status, RUNBOOK["accepted"] + real_dt.timedelta(minutes=4))
            if scenario == "t2late":
                # T2's Run Command hadn't ended when the session started (2026-11-20): a guest after a cold start.
                status["dispatchPending"] = ["T2"]
                status["steps"].append({"step": "Times", "state": "Info", "atUtc": iso(Clock.now), "fix": "",
                                        "message": "T2: its activity isn't set on archost01 yet (a VM or guest that has just started can take minutes), so T2's times count from when it is; the live view says when."})
            if scenario == "earlierrca":
                # The start exported session dddd...'s evidence, which its own stop didn't (ADR 0031).
                RUNNING_EARLIER[0] = status["rcaEarlier"] = rca_bundle_index("d" * 32, ["3" * 32])
            if RUNBOOK.get("acks"):
                # A runbook with Run all's sidecar path acknowledges them on their VMs before its exports: T2's didn't answer.
                documents = RUNBOOK["acks"]["documents"]
                sent, left = [item for item in documents if "-arcsql01-" not in item], [item for item in documents if "-arcsql01-" in item]
                status["rcaAcks"] = {"kind": "ContosoCare.RcaAckResult", "version": 1, "sent": sent, "left": left, "status": "Warning" if left else "Pass",
                                     "message": "%d sidecars acknowledged on sqlvm01, before the start's exports%s" % (
                                         len(sent), ("; %d left: arcsql01 didn't answer." % len(left)) if left else ".")}
                if scenario in ("qsacksearly", "qsacksstepped"):
                    # T2c-1's real result comes with its RCA.SIDECAR.ACK step, which the status's steps print.
                    status["rcaAcks"]["message"] = ("%d of %d sidecar acknowledgement(s) sent before the start's exports (%d on sqlvm01); the rest "
                                                    "weren't: arcsql01 didn't answer." % (len(sent), len(documents), len(sent)))
                    status["steps"].append({"step": "RCA.SIDECAR.ACK", "state": status["rcaAcks"]["status"], "atUtc": iso(Clock.now),
                                            "message": status["rcaAcks"]["message"], "fix": "The control notebook keeps them, and the next Run all's start sends them again."})
            VAULT[name] = json.dumps(status)
        elif scenario == "t2late" and current.get("phase") == "running" and current.get("dispatchPending") \
                and Clock.now - RUNBOOK["accepted"] >= real_dt.timedelta(minutes=22):
            # The start's follow-up (Wait-DbHubSessionDispatch): T2's activity was set 12 minutes after its dispatch.
            current["dispatchUtc"]["T2"] = iso(RUNBOOK["accepted"] + real_dt.timedelta(minutes=22))
            current["dispatchPending"] = []
            current["steps"].append({"step": "Times", "state": "Info", "atUtc": iso(Clock.now), "fix": "",
                                     "message": "T2: its activity was set on archost01 12 minutes after Azure accepted the Run Command that sends it, so T2's times count from then."})
            VAULT[name] = json.dumps(current)
        elif scenario == "hostfail" and current.get("phase") == "running" and Clock.now - RUNBOOK["accepted"] >= real_dt.timedelta(minutes=40) \
                and not any(step.get("step") == "Host" for step in current.get("steps") or []):
            # DbHub-Monitor's re-check (2026-11-16): the same status, with the host that stopped, and the new runCommands field.
            current["steps"].append(dict(HOST_WARNING, atUtc=iso(Clock.now)))
            current["runCommands"] = [{"vm": "archost01", "name": "DbHubControl-archost01-x", "targets": ["T2"]}]
            VAULT[name] = json.dumps(current)
        elif scenario in ("qsacksrecheck", "qsacksstepped") and current.get("phase") == "running" and Clock.now - RUNBOOK["accepted"] >= real_dt.timedelta(minutes=40) \
                and (current.get("rcaAcks") or {}).get("left"):
            # Option 2 (2026-11-23): the session's re-check sends what its start left, and writes rcaAcks again, with no step;
            # in "qsacksstepped", the start's step stays in the status's steps.
            current["rcaAcks"] = acks_sent_later(current["rcaAcks"], "a re-check")
            VAULT[name] = json.dumps(current)
        elif scenario == "coldstartstopped" and current.get("phase") == "running" and Clock.now - RUNBOOK["accepted"] >= real_dt.timedelta(minutes=10):
            # The app's Stop now ends the session 10 minutes in, before T2's first 15 minutes have passed.
            VAULT[name] = json.dumps(stopped_status(RUNBOOK["session"], Clock.now, current))
    return VAULT[name]


class Py4JJavaError(Exception):
    """What notebookutils raises when Key Vault refuses a read (live on dbhubra, 2026-11-21)."""


class Credentials:
    def getSecret(self, vault, name):
        # "nocontrol", "nocontrolstop", and "novault": the vault refuses every read (F29: on dbhubra, the session control's
        # setup stopped at its template, so nobody was given its secrets).
        if scenario in ("nocontrol", "nocontrolstop", "novault"):
            raise Py4JJavaError("An error occurred while calling z:notebookutils.credentials.getSecret: Forbidden")
        return vault_read(name)

    def getToken(self, audience):
        return "simulated-" + audience


class Notebook:
    """notebookutils.notebook: a reference run takes 4 minutes, in "refail" it fails as Fabric's lakehouse check would.
    The validator (NB_DatabaseHub_Deployment) takes 70 seconds and answers (validator_answer) as of its start, since it
    decides in its per-target cell, before its summary and its save: in "valfail" it fails, in "valslow" it passes its
    timeout, in "coldstartrecheckfail" it fails when it's run again, and in "coldstartslow" and "coldstart33" it takes 290
    seconds when it's run again."""
    def run(self, path, timeout_seconds=90, arguments=None, workspace=""):
        arguments = dict(arguments or {})
        if path == "NB_DatabaseHub_Deployment":
            VALIDATORS.append({"path": path, "timeout": timeout_seconds, "workspace": workspace, "args": arguments, "at": iso(Clock.now)})
            ORDER.append("validator")
            if scenario == "valfail" or (scenario == "coldstartrecheckfail" and len(VALIDATORS) > 1):
                raise RuntimeError("Notebook execution failed in cell 12: the telemetry endpoint didn't answer.")
            if scenario == "valslow":
                _sleep(timeout_seconds)
                raise RuntimeError("The notebook run didn't finish in %d seconds." % timeout_seconds)
            answer = validator_answer(arguments) if "COLD_START_UTC" in arguments else ""
            _sleep(290 if scenario in ("coldstartslow", "coldstart33") and len(VALIDATORS) > 1 else 70)
            VALIDATORS[-1]["ended"] = iso(Clock.now)
            return answer
        REFS.append({"path": path, "timeout": timeout_seconds, "workspace": workspace, "args": arguments})
        ORDER.append("history:" + str(arguments.get("SESSION_ID", ""))[:8])
        if scenario in ("refail", "sessionqsjob") or scenario in RCA_JOB_SCENARIOS:
            raise RuntimeError("The referenced notebook's default lakehouse differs from the caller's.")
        if scenario in ("queued", "queuedjob"):
            # Live, 2026-11-16: Fabric's reference run failed on a cell's result, and the job then queued behind this session.
            raise RuntimeError("Unrecognized token 'REDACTED': was expecting (JSON String, Number, Array, Object or token 'null', 'true' or 'false')")
        _sleep(240)
        sidecar = [name for name in FILES if arguments.get("RCA_SIDECAR_FILE") and name.endswith("/" + arguments["RCA_SIDECAR_FILE"])]
        if sidecar:
            # The activity notebook's sidecar cell, before section 3 (B, 2026-11-23): it writes each sidecar once,
            # acknowledges the payload in Files/rca/acks, and deletes it only when every sidecar is written or already was.
            document = json.loads(FILES[sidecar[0]])
            SIDECARS.append({"name": arguments["RCA_SIDECAR_FILE"], "session": arguments.get("SESSION_ID", ""), "document": document})
            documents = sorted({part.split()[2] for part in document["parts"]})
            if scenario != "sessionqsnoack":
                statuses = [(item, "skipped" if scenario == "sessionqsskip" and item == documents[-1] else "written") for item in documents]
                acknowledge(arguments["RCA_SIDECAR_FILE"], statuses)
                if all(status != "skipped" for _, status in statuses):
                    del FILES[sidecar[0]]
        staged = [name for name in FILES if arguments.get("RCA_EVIDENCE_FILE") and name.endswith("/" + arguments["RCA_EVIDENCE_FILE"])]
        if staged:
            # The activity notebook reads the staged evidence; since the Incident RCA it deletes the file and answers with
            # RCA.EVIDENCE, and a copy from before it does neither ("sessionrcaold").
            document = json.loads(FILES[staged[0]])
            STAGED.append({"name": arguments["RCA_EVIDENCE_FILE"], "document": document})
            if scenario != "sessionrcaold":
                del FILES[staged[0]]
                documents = sorted({part.split()[2] for part in document["parts"]})
                return "RCA.EVIDENCE Pass: Wrote %d evidence document(s) from sqlvm01." % len(documents)
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
    if method == "GET" and ".vault.azure.net/secrets/" in url:
        # Key Vault's Get Secret for one of the metrics secret's earlier versions (ADR 0031), with the keyvault token.
        assert (headers or {}).get("Authorization") == "Bearer simulated-keyvault", headers
        name, version = __import__("re").search(r"/secrets/([^/?]+)/([0-9a-f]{32})\?api-version=2025-07-01$", url).groups()
        VAULTREADS.append("%s/%s" % (name, version[:8]))
        if scenario == "bundlefail" and version == "2" * 32:
            return Response(403, {"error": {"code": "Forbidden", "message": "The user doesn't have secrets get permission."}})
        if scenario == "sessionrcapinfail" and version == "4" * 32:
            return Response(403, {"error": {"code": "Forbidden", "message": "The user doesn't have secrets get permission."}})
        if scenario in ("sessionqslate", "sessionqslateindex") and version == "9" * 32:
            return Response(403, {"error": {"code": "Forbidden", "message": "The user doesn't have secrets get permission."}})
        return Response(200, {"value": VERSIONS[version], "id": url.split("?")[0]})
    # No capacity call: the control never checks, starts, or pauses the capacity (the user, 2026-11-14).
    assert url.startswith(FABRIC + "/"), url
    if method == "GET" and "/items?type=" in url:
        names = {"Notebook": [("NB_DatabaseHub_LiveActivity", "nb-1")], "Report": [("RPT_DatabaseHub_History", "RPT-1")], "KQLDashboard": []}[url.split("type=")[1]]
        return Response(200, {"value": [{"displayName": name, "id": item} for name, item in names]})
    if method == "POST" and url == FABRIC + "/workspaces/bbbbbbbb-0000-0000-0000-000000000002/items/nb-1/getDefinition":
        # Items - Get Item Definition: in "sessionqs" a long-running operation, which runs at its first look.
        DEFREADS.append("definition")
        if scenario == "sessionqs":
            return Response(202, None, FABRIC + "/operations/op-1")
        return Response(200, activity_definition(scenario != "sessionqsold"))
    if method == "GET" and url == FABRIC + "/operations/op-1":
        DEFREADS.append("state")
        return Response(200, {"status": "Running" if DEFREADS.count("state") < 2 else "Succeeded"})
    if method == "GET" and url == FABRIC + "/operations/op-1/result":
        DEFREADS.append("result")
        return Response(200, activity_definition(True))
    if method == "POST" and url.endswith("/items/nb-1/jobs/instances?jobType=RunNotebook"):
        if scenario in ("full", "sessionqsfull"):
            REFUSED[0] += 1
            return Response(430, {"errorCode": "TooManyRequestsForCapacity", "message": "This Spark job can't be run because you have hit a Spark compute or API rate limit."})
        JOBS.append({key: value["value"] for key, value in json["executionData"]["parameters"].items()})
        ORDER.append("job:" + JOBS[-1].get("SESSION_ID", "")[:8])
        return Response(202, None, FABRIC + "/workspaces/x/items/nb-1/jobs/instances/run-%d" % len(JOBS))
    if method == "GET" and "/jobs/instances/run-" in url:
        JOBREADS[0] += 1
        if scenario in ("queued", "queuedjob", "rcajobqueued", "sessionqsjob"):
            return Response(200, {"status": "NotStarted"})
        if scenario == "rcajobfailed":
            return Response(200, {"status": "Failed", "failureReason": {"message": "Notebook execution failed in cell 4."}})
        if scenario == "rcajobdone":
            # The job ran, and its notebook deleted the staged evidence once it had written it.
            staged = JOBS[int(url.rsplit("-", 1)[1]) - 1].get("RCA_EVIDENCE_FILE") or ""
            for name in [name for name in FILES if staged and name.endswith("/" + staged)]:
                del FILES[name]
        return Response(200, {"status": "Completed"})
    raise AssertionError("unexpected %s %s" % (method, url))


fake_requests.post, fake_requests.request = post, request


def stop_session():
    # notebookutils.session.stop(): no code runs after it, so it must be the notebook's last statement.
    STOPS[0] += 1
    ORDER.append("session.stop")

sys.modules["requests"] = fake_requests
sys.modules["pandas"] = types.ModuleType("pandas")
# Run all in the notebook editor is an interactive session; "queuedjob" is a scheduled or pipeline run.
namespace = {"notebookutils": types.SimpleNamespace(credentials=Credentials(), notebook=Notebook(), session=types.SimpleNamespace(stop=stop_session), fs=FileSystem(),
                                                   runtime=types.SimpleNamespace(context={"currentWorkspaceId": "dddddddd-0000-0000-0000-000000000004", "defaultLakehouseId": LAKEHOUSE,
                                                                                          "isForInteractive": scenario != "queuedjob"}))}
class Printed(io.StringIO):
    """What the notebook prints, with the simulated time of each line about a beat or readiness (the review of d6d69832)."""
    def __init__(self):
        super().__init__()
        self.timed = []

    def write(self, text):
        if text.startswith(("Now:", "Readiness", "Warning: the telemetry", "Warning: no ", "  HUB.TELEMETRY", "  Not known yet")):
            self.timed.append([iso(Clock.now), text])
        return super().write(text)


buffer = Printed()
error = ""
with contextlib.redirect_stdout(buffer):
    try:
        exec(code[0], namespace)
        namespace.update({"stopnow": {"STOP_NOW": True}, "stoppedend": {"STOP_NOW": True}, "stoppedold": {"STOP_NOW": True}, "endedrunning": {"STOP_NOW": True},
                          "stoppedplan": {"STOP_NOW": True}, "stoppedplannometrics": {"STOP_NOW": True}, "stoppedstart": {"STOP_NOW": True}, "stoppedlost": {"STOP_NOW": True},
                          "takenoverstop": {"STOP_NOW": True}, "takenoveragain": {"STOP_NOW": True}, "nocontrolstop": {"STOP_NOW": True},
                          "stoppedlate": {"STOP_NOW": True}, "stoppedqs": {"STOP_NOW": True}, "stoppedqsacks": {"STOP_NOW": True},
                          "check": {"MODE": "check"}, "nowait": {"WAIT_FOR_END": False},
                          "askedshort": {"DURATION_MINUTES": 20}, "askedlong": {"DURATION_MINUTES": 150},
                          "askedfraction": {"DURATION_MINUTES": 45.5}, "askednone": {"DURATION_MINUTES": None}, "askedtext": {"DURATION_MINUTES": "abc"},
                          "askedstring": {"DURATION_MINUTES": "90"}, "coldstartshort": {"WAIT_FOR_END": False, "WATCH_MINUTES": 5},
                          "coldstart30": {"DURATION_MINUTES": 30}, "coldstart33": {"DURATION_MINUTES": 33}}.get(scenario, {}))
        for index, source in enumerate(code[1:], start=1):
            exec(source, namespace)
            if index == 2:
                namespace["dt"], namespace["time"] = fake_dt, fake_time
    except Exception as failure:
        error = "%s: %s" % (type(failure).__name__, failure)
printed = buffer.getvalue()
print(json.dumps({"sent": SENT, "jobs": JOBS, "refs": REFS, "validators": VALIDATORS, "order": ORDER, "refused": REFUSED[0], "jobReads": JOBREADS[0], "stops": STOPS[0], "statusReads": STATUSREADS[0], "vaultMetrics": VAULT["dbhub-session-metrics"], "printed": printed, "error": error, "leaked": SECRET_URL.split("token=")[1] in printed,
                  "staged": STAGED, "files": sorted(FILES), "vaultReads": VAULTREADS, "sidecars": SIDECARS, "defReads": DEFREADS, "puts": PUTS, "coldStart": COLD_START[0], "timed": buffer.timed,
                  "acks": {name[len(BASE):]: json.loads(text) for name, text in FILES.items() if name.startswith(BASE + "Files/rca/acks/")}}))
'@

    function Invoke-Simulation([string] $Path, [string] $Scenario, [string] $Start) {
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $script:simulator $Path $Scenario $Start $repoRoot 2>&1
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
        foreach ($target in 'T1', 'T2', 'T3', 'T4', 'T5') {
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

    It 'asks only for the pbi, kusto, and keyvault tokens, and sends requests only to documented hosts' {
        foreach ($use in [regex]::Matches($script:allCode, '(?<!def )\bget_token\(([^)]*)\)')) {
            $use.Groups[1].Value | Should -BeIn @('"pbi"', '"kusto"', '"keyvault"', 'audience')
        }
        $script:allCode | Should -Match 'if audience not in \("pbi", "kusto", "keyvault"\):'
        # The keyvault token reads only the metrics secret's earlier versions, which hold the Incident RCA's evidence
        # (ADR 0031): Key Vault's Get Secret, by version, in one function.
        @([regex]::Matches($script:allCode, 'get_token\("keyvault"\)')).Count | Should -Be 1
        [regex]::Match($script:allCode, '(?ms)^def read_secret_version\(.*?(?=^def )').Value | Should -Match 'get_token\("keyvault"\)'
        $script:allCode | Should -Match 'address = "%s/secrets/%s/%s\?api-version=%s" % \(KEY_VAULT_URL\.rstrip\("/"\), name, version, KEY_VAULT_API_VERSION\)'
        $script:allCode | Should -Match '(?m)^KEY_VAULT_API_VERSION = "2025-07-01"$'
        foreach ($use in [regex]::Matches($script:allCode, '(?<!def )\bread_secret_version\(([^,)]*)')) {
            $use.Groups[1].Value | Should -BeIn @('METRICS_SECRET_NAME', 'name')
        }
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
# From the Insights app's Manage (ADR 0029): the Fabric job API sets REQUESTED_BY, and every request carries it.
REQUESTED_BY = "app/ops@contoso.example"
for action, kwargs in [("session", dict(session_id=sid, duration_minutes=90)), ("reset", dict(reset_targets=["T1"]))]:
    out.append({"ok": True, "body": json.dumps(build_request(action, catalog=catalog, **kwargs), separators=(",", ":"))})
REQUESTED_BY = "app/Ops Person"
try:
    out.append({"ok": True, "body": json.dumps(build_request("stop", catalog=catalog))})
except ValueError as error:
    out.append({"ok": False, "error": str(error)})
# A whole number however it arrives (the review of F33): DURATION_MINUTES, intensity, and concurrency as text or as a whole
# float go as the int; anything else is refused, as before.
REQUESTED_BY = "notebook"
for action, kwargs in [
    ("session", dict(session_id=sid, duration_minutes="90")),
    ("session", dict(session_id=sid, duration_minutes=" 90 ")),
    ("session", dict(session_id=sid, duration_minutes=90.0)),
    ("run", dict(activities=[{"target": "T1", "scenario": "deadlock-storm", "intensity": "8", "concurrency": 3.0}], duration_minutes="20")),
    ("session", dict(session_id=sid, duration_minutes=45.5)),
    ("session", dict(session_id=sid, duration_minutes=None)),
    ("session", dict(session_id=sid, duration_minutes="abc")),
    ("session", dict(session_id=sid, duration_minutes=True)),
    ("session", dict(session_id=sid, duration_minutes="20")),
    ("session", dict(session_id=sid, duration_minutes=150.0)),
    ("session", dict(session_id=sid, duration_minutes="9_0")),
    ("session", dict(session_id=sid, duration_minutes="\u0669\u0660")),
    ("run", dict(activities=[{"target": "T1", "scenario": "cpu-pressure", "intensity": 8.5}], duration_minutes=20)),
    ("run", dict(activities=[{"target": "T1", "scenario": "cpu-pressure", "intensity": True}], duration_minutes=20)),
]:
    try:
        out.append({"ok": True, "body": json.dumps(build_request(action, catalog=catalog, **kwargs), separators=(",", ":"))})
    except ValueError as error:
        out.append({"ok": False, "error": str(error)})
# The plan and the request read a session's DURATION_MINUTES the same way (session_minutes): at 09:00, with the day ahead,
# the plan goes ahead exactly when the request is built, and for the same minutes.
nine = dt.datetime(2026, 11, 14, 9, 0, tzinfo=dt.timezone.utc)
values = (list(range(-5, 201)) + [minutes + 0.5 for minutes in range(25, 125)] + [float(minutes) for minutes in range(25, 125)] +
          [str(minutes) for minutes in range(25, 125)] +
          [" 30 ", "+90", "90.0", "120.", "", "abc", "1e2", "9_0", None, True, False, [90], float("nan"), float("inf")])
disagree = []
for value in values:
    plan = session_plan(nine, value, catalog)
    try:
        built = build_request("session", duration_minutes=value, catalog=catalog, session_id=sid)["durationMinutes"]
    except ValueError:
        built = None
    if plan["ok"] != (built is not None) or (built is not None and (type(built) is not int or built != plan["asked"])):
        disagree.append(repr(value))
print(json.dumps({"values": len(values), "disagree": disagree}))
print(json.dumps(out))
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $driver $helpers $catalogFile 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $results = ($output | Select-Object -Last 1) | ConvertFrom-Json
        @($results | ForEach-Object ok) | Should -Be @($true, $true, $true, $true, $true, $false, $false, $false, $false, $false, $false, $false, $true, $true, $true, $true, $false, $false, $false, $true, $true, $false, $false, $false, $true, $true, $true, $false, $false, $false, $false, $true, $true, $false, $true, $true, $true, $true, $false, $false, $false, $false, $false, $false, $false, $false, $false, $false)
        # A whole number however it arrives (the review of F33): it goes as the int, and the runbook accepts it (below).
        foreach ($index in 34, 35, 36) {
            $results[$index].body | Should -BeExactly '{"action":"session","requestedBy":"notebook","sessionId":"0123456789abcdef0123456789abcdef","durationMinutes":90}'
        }
        $results[37].body | Should -BeExactly '{"action":"run","requestedBy":"notebook","durationMinutes":20,"activities":[{"target":"T1","scenario":"deadlock-storm","intensity":8,"concurrency":3}]}'
        # A fraction, None, text that isn't a whole number, a bool, or a whole number outside the bounds, as before.
        foreach ($index in 38..45) {
            $results[$index].error | Should -Match 'DURATION_MINUTES must be a whole number from 30 to 120'
        }
        $results[46].error | Should -Match 'intensity must be a whole number from 1 to 10'
        $results[47].error | Should -Match 'intensity must be a whole number from 1 to 10'
        $agreement = ($output | Select-Object -Last 2 | Select-Object -First 1) | ConvertFrom-Json
        $agreement.values | Should -BeGreaterThan 500
        @($agreement.disagree) | Should -BeNullOrEmpty -Because 'the plan and the request read DURATION_MINUTES the same way (session_minutes)'
        # Run from the Insights app's Manage (ADR 0029): REQUESTED_BY names the verified caller, within the runbook's name rule.
        $results[31].body | Should -BeExactly '{"action":"session","requestedBy":"app/ops@contoso.example","sessionId":"0123456789abcdef0123456789abcdef","durationMinutes":90}'
        $results[32].body | Should -BeExactly '{"action":"reset","requestedBy":"app/ops@contoso.example","targets":["T1"]}'
        $results[33].error | Should -Match 'requested_by must be 1-64 letters, digits'
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

    It 'plans a session as the runbook does: before the VMs'' auto-shutdown, after whole showcase cycles when it''s cut short, and refused under 30 minutes, naming the duration asked when that''s why (F33)' {
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
# The duration asked, outside 30 to 120 minutes (F33): at 14:20, at 18:40 too, and with no auto-shutdown configured.
for label, hour, minute, asked, rules in (("asked20", 14, 20, 20, {}), ("asked20late", 18, 40, 20, {}), ("asked150", 9, 0, 150, {}),
                                          ("asked20none", 14, 20, 20, {"autoShutdownTime": ""})):
    shown = dict(catalog, session=dict(catalog.get("session") or {}, **rules))
    plan = ns["session_plan"](dt.datetime(2026, 11, 14, hour, minute, tzinfo=dt.timezone.utc), asked, shown)
    out[label] = {"ok": plan["ok"], "out": plan["durationOut"], "lines": ns["plan_lines"](plan, shown)}
# DURATION_MINUTES however it arrives (the review of F33): a whole number as an int, a whole float, or text of one; anything
# else is refused before the request, and quoted as it was given.
for label, value in (("fraction", 45.5), ("none", None), ("text", "abc"), ("bool", True), ("fraction20", 20.5), ("text20", "20"),
                     ("float150", 150.0)):
    plan = ns["session_plan"](dt.datetime(2026, 11, 14, 14, 20, tzinfo=dt.timezone.utc), value, catalog)
    out[label] = {"ok": plan["ok"], "out": plan["durationOut"], "lines": ns["plan_lines"](plan, catalog)}
out["fractionLate"] = ns["plan_lines"](ns["session_plan"](dt.datetime(2026, 11, 14, 18, 40, tzinfo=dt.timezone.utc), 45.5, catalog), catalog)
nine = dt.datetime(2026, 11, 14, 9, 0, tzinfo=dt.timezone.utc)
out["as90"] = [ns["plan_lines"](ns["session_plan"](nine, value, catalog), catalog) == out["morning"]["lines"] for value in ("90", " 90 ", 90.0)]
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
        # F33 (live, 2026-11-21): 20 minutes asked at 14:20 was refused as if the auto-shutdown at 19:00 were too soon.
        $plan.asked20.ok | Should -BeFalse
        $plan.asked20.out | Should -Be 'short'
        @($plan.asked20.lines) | Should -Be @('Nothing is started: a session runs at least 30 minutes, and you asked for 20.', 'Fix: set DURATION_MINUTES to 30 or more, then Run all again.')
        # Named only when it's what leaves too little time, as at 18:40.
        @($plan.asked20late.lines) | Should -Be @('Nothing is started: a session runs at least 30 minutes, and you asked for 20. The VMs'' nightly auto-shutdown at 19:00 (UTC) is too soon for one now, too.', 'Fix: set DURATION_MINUTES to 30 or more, and Run all again earlier in the day, or set autoShutdownTime in config/demo.config.json and run ./scripts/deploy.ps1.')
        # Over the showcase's 120: before, it read "runs 120 of the 150 minutes asked ... before the VMs' nightly
        # auto-shutdown", and then the session's request failed; the runbook refuses it too.
        $plan.asked150.ok | Should -BeFalse
        $plan.asked150.out | Should -Be 'long'
        @($plan.asked150.lines) | Should -Be @('Nothing is started: a session runs at most 120 minutes, and you asked for 150.', 'Fix: set DURATION_MINUTES to 120 or less, then Run all again.')
        # Without an auto-shutdown, it read "This session runs 20 minutes" while it sent nothing.
        @($plan.asked20none.lines) | Should -Be @('Nothing is started: a session runs at least 30 minutes, and you asked for 20.', 'Fix: set DURATION_MINUTES to 30 or more, then Run all again.')
        # The review of F33: the plan read DURATION_MINUTES with int(), so 45.5 was "This session runs 45 minutes" and the
        # request then raised a ValueError; None and "abc" raised in the plan; True was "you asked for 1". Now a value that
        # isn't a whole number is refused before anything is sent, quoted as it was given.
        $notWhole = 'Fix: set DURATION_MINUTES to a whole number from 30 to 120, then Run all again.'
        foreach ($case in @(@('fraction', '45.5'), @('none', 'None'), @('text', '"abc"'), @('bool', 'True'), @('fraction20', '20.5'))) {
            $result = $plan.($case[0])
            $result.ok | Should -BeFalse -Because $case[0]
            $result.out | Should -Be 'notWhole' -Because $case[0]
            @($result.lines) | Should -Be @(('Nothing is started: a session runs a whole number of minutes, from 30 to 120, and you asked for {0}.' -f $case[1]), $notWhole) -Because $case[0]
        }
        # A whole number given as text or as a float, outside the bounds: the bound it's past, quoted as it was given.
        $plan.text20.out | Should -Be 'short'
        @($plan.text20.lines) | Should -Be @('Nothing is started: a session runs at least 30 minutes, and you asked for "20".', 'Fix: set DURATION_MINUTES to 30 or more, then Run all again.')
        $plan.float150.out | Should -Be 'long'
        @($plan.float150.lines) | Should -Be @('Nothing is started: a session runs at most 120 minutes, and you asked for 150.0.', 'Fix: set DURATION_MINUTES to 120 or less, then Run all again.')
        # The auto-shutdown is named too when it also leaves too little time.
        @($plan.fractionLate) | Should -Be @('Nothing is started: a session runs a whole number of minutes, from 30 to 120, and you asked for 45.5. The VMs'' nightly auto-shutdown at 19:00 (UTC) is too soon for one now, too.', 'Fix: set DURATION_MINUTES to a whole number from 30 to 120, and Run all again earlier in the day, or set autoShutdownTime in config/demo.config.json and run ./scripts/deploy.ps1.')
        # "90", " 90 ", and 90.0 plan as 90 does.
        @($plan.as90) | Should -Be @($true, $true, $true)
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
        # Since 2026-11-20 (the owner's request): it says first that the beat needs it and nothing else does, and links the steps.
        $text | Should -Match '\n  Required once for the Database Agent beat; everything else works without it\. Once per deployment, if it isn''t done yet: Database Hub > Agent \(preview\) > Manage agents > Database agent settings: Enabled on\. All databases start selected, and the selection is saved for the tenant\. Saving works whether T3 is awake or paused, and needs Azure write access on T3 \(the account that deployed the demo has it\); the agent raises issues on T3 only while it''s awake, as now\. Step by step: docs/database-agents\.md in the demo''s repository\.\n'
        # Live, 2026-11-20: deleted databases can stay in the list for a while, and a Save fails while any selected database
        # fails its check; a Save with nothing selected worked (the reset), then one row at a time saved the databases that
        # exist. The selection is the tenant's, so it's cleared only where nobody else uses Database Agents.
        $text | Should -Match '\n    If only you use Database Agents in this tenant: clear the selection and Save \(the reset\), then check azuresql01-abc123/ContosoCare and Save; with several ContosoCare rows, which show no server, check one at a time and Save, keeping each that saves\. Then each kept row''s Agent policy \(the gear\): Flag long-running queries, Force last known good plans, and Flag high CPU; Apply, then Save\.\n'
        $text | Should -Not -Match '(?i)are paused|while T3 is awake' -Because 'paused databases saved fine on 2026-11-20; only the agent''s issues need T3 awake'
        $text | Should -Match '\n    If others use Database Agents in this tenant: don''t clear or uncheck their databases; select azuresql01-abc123/ContosoCare with the same Agent policy in addition, then Apply and Save\. If Save fails on one of their databases, ask whoever manages Database Agents in the tenant to add T3\.\n'
        $text | Should -Match '14:33  T3''s lookup regresses to a scanning plan'
        $text | Should -Match '14:48  From about now, the agent''s issue on azuresql01-abc123/ContosoCare, a new one each session'
        $text | Should -Match 'Explain why, then Analyze slow query'
        $text | Should -Match '14:55  Respond: this Run all forces the last good plan through Query Store'
        $text | Should -Match 'Optimization: the card in What needs attention; arcsql01 in Estate, ready to migrate'
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

    It 'says whether T3''s regression started, from T3''s CPU after the agent beat''s switch, once and before the response (F26)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $filled = Get-FilledNotebook -Zone 'UTC'
        $driver = Join-Path -Path $TestDrive -ChildPath 'agent-regression.py'
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
regress = dt.datetime(2026, 11, 21, 21, 17, 0, tzinfo=dt.timezone.utc)
beat = {"agent": True, "regressUtc": regress, "respondUtc": regress + dt.timedelta(minutes=22.5)}

def run(cpu, minutes, telemetry=True):
    calls = []
    def fake(start, end):
        calls.append([(start - regress).total_seconds() / 60, (end - regress).total_seconds() / 60])
        return cpu
    ns["t3_cpu"] = fake
    state, buffer = {}, io.StringIO()
    with contextlib.redirect_stdout(buffer):
        for minute in minutes:
            ns["agent_regression"](beat, regress + dt.timedelta(minutes=minute), state, telemetry)
    return {"printed": buffer.getvalue(), "result": list(state.get("regression") or []), "calls": calls,
            "summary": ns["agent_summary"](beat, state, regress + dt.timedelta(minutes=40))}

out = {"flat": run((6.0, ""), [5, 9, 10, 12]),
       "runs": run((97.0, ""), [9]),
       "late": run((None, ""), [9, 15, 20, 21]),
       "noTelemetry": run((6.0, ""), [9], telemetry=False),
       "afterResponse": run((6.0, ""), [23])}
print(json.dumps(out))
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $driver $filled 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $out = ($output | Select-Object -Last 1) | ConvertFrom-Json
        # Live (dbhubfn at bf010ed): the switch didn't hold and T3's CPU stayed at 6%. Its telemetry is read once, for the 5
        # minutes from a minute after the switch, as soon as it can be in.
        ($out.flat.calls | ForEach-Object { $_ -join '..' }) | Should -Be @('1..6')
        $out.flat.result[0] | Should -Be 'Warning'
        $out.flat.result[1] | Should -Be 'T3''s regression didn''t start: its CPU was 6% in the 5 minutes after the switch at 21:17, so Database Agents has no issue to raise this session, and the response at 21:39 has nothing to fix. T3''s run says why: its plan-switch-unverified event in demo.scenario_run_events. Fix: the next session runs the beat again.'
        ($out.flat.printed.Trim() -split "`n").Count | Should -Be 1
        $out.flat.summary[0] | Should -Be ('The Database Agent loop''s regression: Warning: ' + $out.flat.result[1])
        $out.flat.summary[1] | Should -Match '^The Database Agent loop: T3''s response ran at 21:39 '
        $out.runs.result | Should -Be @('Pass', 'T3''s regression runs: its CPU was 97% in the 5 minutes after the switch at 21:17, and Database Agents raises its issue about 15 minutes after it started.')
        @($out.runs.summary).Count | Should -Be 1
        # Telemetry that doesn't come: asked again until 20 minutes after the switch, then nothing, since the response says so.
        @($out.late.calls).Count | Should -Be 3
        $out.late.printed | Should -BeNullOrEmpty
        @($out.late.result).Count | Should -Be 0
        @($out.noTelemetry.calls).Count | Should -Be 0
        @($out.afterResponse.calls).Count | Should -Be 0
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
        $report.printed | Should -Match 'Required once for the Database Agent beat; everything else works without it\. Once per deployment, if it isn''t done yet: Database Hub > Agent \(preview\) > Manage agents > Database agent settings: Enabled on\. All databases start selected'
        $report.printed | Should -Match 'If only you use Database Agents in this tenant: clear the selection and Save \(the reset\), then check azuresql01-abc123/ContosoCare'
        $report.printed | Should -Match 'If others use Database Agents in this tenant: don''t clear or uncheck their databases; select azuresql01-abc123/ContosoCare'
        $report.printed | Should -Match 'Now: T3 Respond, the Database Agent loop''s manual response'
        $report.printed | Should -Match 'The Database Agent loop: T3''s response ran at 14:59 '
        $report.printed | Should -Match 'Stopped: T4''s read replica deleted, T4 stopped'
        $report.printed | Should -Match 'Waiting \d+ minutes for the last telemetry to arrive'
        $report.printed | Should -Match 'NB_DatabaseHub_LiveActivity runs in this notebook''s Spark session to save session [0-9a-f]{8}''s history\.'
        $report.printed | Should -Match 'Pass: the history is saved'
    }

    It 'says that a start-demo.ps1 session took over at the session''s end, stops nothing, and still saves the session''s history (2026-11-20)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'takenover' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.sent | ForEach-Object action) | Should -Be @('session', 'stop')
        $report.printed | Should -Match 'Taken over: a start-demo\.ps1 session runs the demo now, so nothing was stopped; its auto-stop stops it at \d\d:\d\d \(UTC\), and Stop now again, or \./scripts/stop-demo\.ps1, stops it sooner\. This session''s history is saved below\.'
        $report.printed | Should -Match 'Done: the history''s metrics saved to the control vault\.'
        $report.printed | Should -Not -Match 'Stopped: nothing stopped'
        $report.printed | Should -Not -Match 'the VMs and T4 are already stopped'
        $report.printed | Should -Match 'Waiting \d+ minutes for the last telemetry to arrive \(until \d\d:\d\d\)\.'
        @($report.refs).Count | Should -Be 1 -Because 'the session''s history is saved as at any end'
        $report.refs[0].args.SESSION_ID | Should -Be $report.sent[0].sessionId
    }
    It 'saves a taken-over session''s Incident RCA evidence with its history, and says what its end exported (the RCA release''s merge)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'takenoverrca' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.sent | ForEach-Object action) | Should -Be @('session', 'stop')
        $report.printed | Should -Match 'Taken over: a start-demo\.ps1 session runs the demo now, so nothing was stopped'
        $report.printed | Should -Match 'RCA\.EXPORT Pass: 2 evidence documents in 4 parts from sqlvm01\.'
        $report.printed | Should -Match 'RCA\.CAPTURE\.T1 Pass: T1: captured from 16:50 to 17:05 UTC\.'
        $report.printed | Should -Not -Match 'the control''s runbook is from before'
        @($report.refs).Count | Should -Be 1
        $report.refs[0].args.SESSION_ID | Should -Be $report.sent[0].sessionId
        $report.refs[0].args.RCA_EVIDENCE_FILE | Should -Be $report.staged[0].name
        $report.staged[0].document.sessionId | Should -Be $report.sent[0].sessionId
    }
    It 'stops everything when Stop now comes inside a taken-over session''s end, and when it comes again after that end (the re-review of 2026-11-20)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # The app's Stop now 5 minutes after the session's planned end, before its end's stop came: the runbook takes it for
        # that end, so the notebook sends a stop with no session ID, which stops the start-demo.ps1 session too.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'takenoverstop' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.sent | ForEach-Object action) | Should -Be @('stop', 'stop')
        $report.sent[0].sessionId | Should -Be ('d' * 32)
        $report.sent[1].PSObject.Properties.Name | Should -Not -Contain 'sessionId' -Because 'the runbook never takes a stop with no session ID for a session''s end'
        $report.printed | Should -Match 'A start-demo\.ps1 session took over from this one, so Stop now stops that session too\.'
        $report.printed | Should -Match 'Stopped: T4''s read replica deleted, T4 stopped, sqlvm01 deallocated\.'
        $report.printed | Should -Not -Match 'Taken over: '
        $report.printed | Should -Match 'the VMs and T4 are already stopped'
        @($report.refs).Count | Should -Be 1 -Because 'the session''s history is saved as at any Stop now'
        # Stop now again, after an end that stopped nothing: the status says stopped, so its stop has no session ID.
        $again = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'takenoveragain' -Start '2026-11-14T14:00:00Z'
        $again.error | Should -BeNullOrEmpty
        @($again.sent | ForEach-Object action) | Should -Be @('stop')
        $again.sent[0].PSObject.Properties.Name | Should -Not -Contain 'sessionId'
        $again.printed | Should -Match 'No session runs \(its status says stopped\), so Stop now stops whatever runs\.'
    }

    It 'says Run all starts nothing because the session control isn''t set up, with deploy.ps1''s fix, not the vault''s permissions (F29, live 2026-11-21)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # What deploy.ps1 found on dbhubra (Get-DemoControlGap's Problem), filled into CONTROL_PROBLEM at import.
        $problem = './scripts/deploy.ps1 found on 2026-11-21 11:40 UTC that Run all can''t start a session: the session control''s Azure Automation account aa-dbhub-control isn''t in rg-dbhub-control: Azure refused it because the subscription''s quota for Azure Automation accounts in westus3 is used up. Fix: Free an Automation account in westus3: ./scripts/destroy.ps1 on a demo environment you no longer use deletes its two. Then run ./scripts/deploy.ps1 again. Meanwhile ./scripts/start-demo.ps1 runs a session from a PC, and ./scripts/stop-demo.ps1 stops the demo.'
        $path = Get-FilledNotebook -Zone 'UTC' -ControlProblem $problem
        $report = Invoke-Simulation -Path $path -Scenario 'nocontrol' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.sent | Should -BeNullOrEmpty
        $report.printed | Should -Match ('Manual action required: Run all starts nothing: the secret dbhub-session-status couldn''t be read \(Py4JJavaError\): the session control isn''t set up\. {0}' -f [regex]::Escape($problem))
        $report.printed | Should -Not -Match 'Key Vault Secrets User|the control vault didn''t answer|managed private endpoint'
        @($report.refs).Count | Should -Be 0
        # Stop now: the webhook's URL can't be read either, and it says why once, with the same fix.
        $stop = Invoke-Simulation -Path $path -Scenario 'nocontrolstop' -Start '2026-11-14T14:00:00Z'
        $stop.error | Should -BeNullOrEmpty
        $stop.sent | Should -BeNullOrEmpty
        $stop.printed | Should -Match 'The session''s status couldn''t be read, so Stop now asks the session control to stop whatever runs\.'
        $stop.printed | Should -Match ('Manual action required: the webhook URL couldn''t be read from Key Vault \(Py4JJavaError\): the session control isn''t set up\. {0}' -f [regex]::Escape($problem))
        $stop.printed | Should -Not -Match 'Key Vault Secrets User|No session runs'
        ([regex]::Matches($stop.printed, [regex]::Escape($problem))).Count | Should -Be 1
        # Without what deploy.ps1 found (a control that's set up), the vault's answer, as before.
        $vault = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'novault' -Start '2026-11-14T14:00:00Z'
        $vault.error | Should -BeNullOrEmpty
        $vault.sent | Should -BeNullOrEmpty
        $vault.printed | Should -Match 'Manual action required: the control vault didn''t answer: the secret dbhub-session-status couldn''t be read \(Py4JJavaError\): you need Key Vault Secrets User on it'
        $vault.printed | Should -Not -Match 'isn''t set up'
        # And a problem that a later fix made stale changes nothing when the vault answers (it only explains a failure).
        $fixed = Invoke-Simulation -Path $path -Scenario 'session' -Start '2026-11-14T14:00:00Z'
        $fixed.error | Should -BeNullOrEmpty
        @($fixed.sent | ForEach-Object action) | Should -Contain 'session'
        $fixed.printed | Should -Not -Match 'isn''t set up'
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
        @($run.args.PSObject.Properties.Name | Sort-Object) | Should -Be @('COLD_START_UTC', 'CONFIRM', 'LAKEHOUSE_ID', 'PURGE_DEMO_TABLES', 'RESOURCE_GROUP', 'SAVE_RESULTS', 'T1_VM_NAME', 'T2_MACHINE_NAME', 'T3_SERVER_PREFIX', 'TELEMETRY_DECIDE_UTC', 'TELEMETRY_RECHECK_UTC', 'TELEMETRY_WAIT_UNTIL_UTC', 'WARM_START_TARGETS', 'WORKSPACE_ID')
        $run.args.SAVE_RESULTS | Should -BeTrue
        $run.args.CONFIRM | Should -BeFalse
        $run.args.PURGE_DEMO_TABLES | Should -BeFalse
        $run.args.WORKSPACE_ID | Should -Be 'bbbbbbbb-0000-0000-0000-000000000002'
        $run.args.LAKEHOUSE_ID | Should -Be 'cccccccc-0000-0000-0000-000000000003'
        $run.args.RESOURCE_GROUP | Should -Be 'rg-contoso-demo'
        # A warm start (2026-11-24): the session's start brought no VM up, so the validator waits for nothing, and a target
        # without telemetry stays a Fail, which says the VM was already running only of the targets whose activity the session
        # sent to it (the review of 40ff59bb).
        $run.args.COLD_START_UTC | Should -BeExactly '{}'
        $run.args.WARM_START_TARGETS | Should -BeExactly 'T1,T2,T3'
        $run.args.TELEMETRY_WAIT_UNTIL_UTC | Should -BeExactly ''
        $run.args.TELEMETRY_RECHECK_UTC | Should -BeExactly ''
        $run.args.TELEMETRY_DECIDE_UTC | Should -BeExactly ''
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

    Context 'Readiness on a cold start (2026-11-24)' {
        BeforeAll {
            # Live, 2026-11-24 on dbhubfb: a cold start's readiness ran 6.5 minutes after the session started the VMs, before
            # T2's nested guest sent its first sample, and printed Fail HUB.TELEMETRY.T2. Here the runbook's start brings
            # sqlvm01 and T2's host up (its Start steps) and starts T4, which isn't a VM; T1's and T3's activity goes out at
            # 14:04, and T2's at 14:10, once its host runs. The simulator's COLD_SCENARIOS say what each scenario adds: T2's
            # guest never reports, or reports late, and what can keep Run all from checking it again (the reviews of 40ff59bb
            # and d6d69832).
            $script:hiso = { param($Value) if ($Value -is [datetime]) { ([DateTimeOffset]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$Value } }
            $script:coldRuns, $script:coldChecks, $script:coldSkip = @{}, $null, 'Python 3 is not installed'
            if (-not $script:python) {
                return
            }
            $hfilled = Get-FilledNotebook -Zone 'UTC'
            foreach ($hscenario in 'coldstart', 'coldstartfail', 'coldstartunread', 'coldstartshort', 'coldstartstopped', 'coldstartrecheckfail', 'coldstartforeign',
                'coldstartrefused', 'coldstartwording', 'coldstartgrace', 'coldstartlate', 'coldstart30', 'coldstartslow', 'coldstart33') {
                $script:coldRuns[$hscenario] = Invoke-Simulation -Path $hfilled -Scenario $hscenario -Start '2026-11-14T14:00:00Z'
            }
            $script:coldSkip = 'pandas is not installed for that Python (set DBHUB_TEST_PYTHON to a Python 3 with pandas)'
            $PSNativeCommandUseErrorActionPreference = $false
            $null = & $script:pandasPython -c 'import pandas' 2>&1
            if ($LASTEXITCODE -ne 0) {
                return
            }
            # NB_DatabaseHub_Deployment's own parameters, helpers, per-target, and summary cells, with a clock, a telemetry
            # endpoint whose rows each target's model gives for the time of the query (Kusto v1, through the notebook's
            # kusto_frame), and notebookutils for its answer to Run all. Unless a case says otherwise, the session started T1 at
            # 10:00:00, T2's host at 10:00:10, and T3 at 10:04:00, the checks start at 10:06:30, and Run all checks again at
            # 10:24:10 and 10:34:10, the last deciding. The control cases take what Run all passed in the simulations above.
            $hcontrol = Join-Path -Path $TestDrive -ChildPath 'cold-start.json'
            $hpassed = [ordered]@{}
            foreach ($hscenario in 'coldstartfail', 'coldstartrefused', 'coldstartwording') {
                $hrun = $script:coldRuns[$hscenario].validators[0]
                $hpassed[$hscenario] = [ordered]@{ at = & $script:hiso $hrun.at }
                foreach ($hname in 'COLD_START_UTC', 'WARM_START_TARGETS', 'TELEMETRY_RECHECK_UTC', 'TELEMETRY_DECIDE_UTC') {
                    $hpassed[$hscenario][$hname] = & $script:hiso $hrun.args.$hname
                }
            }
            [System.IO.File]::WriteAllText($hcontrol, (ConvertTo-Json -InputObject $hpassed -Depth 4), [System.Text.UTF8Encoding]::new($false))
            $harness = Join-Path -Path $TestDrive -ChildPath 'cold_start_validator.py'
            Set-Content -LiteralPath $harness -Encoding utf8NoBOM -Value @'
import contextlib, datetime as real_dt, io, json, sys, types

UTC = real_dt.timezone.utc
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
PARAMS = next(cell for cell in cells if cell.startswith("# Parameters cell"))
HELPERS = next(cell for cell in cells if cell.startswith("# Helpers:"))
PER_TARGET = next(cell for cell in cells if cell.startswith("# Per-target validation"))
SUMMARY = next(cell for cell in cells if cell.startswith("# Validation summary"))
FROM_CONTROL = json.load(open(sys.argv[2], encoding="utf-8"))
NAMES = {"T1": ("virtualMachines", "sqlvm01"), "T2": ("machines", "arcsql01"), "T3": ("servers/databases", "azuresql01-abc123/ContosoCare")}
CPU, CONNECTIONS = "SqlServerCPUUtilization", "SqlServerConnections"
RECHECK, DECIDE = "2026-11-24T10:24:10Z,2026-11-24T10:34:10Z", "2026-11-24T10:34:10Z"


def at(text):
    return real_dt.datetime.fromisoformat(text.replace("Z", "+00:00"))


def iso(value):
    return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def steady(now):
    return [(CPU, now - real_dt.timedelta(seconds=60))]


def never(now):
    return []


def arrives(when):
    return lambda now: [(CPU, at(when) - real_dt.timedelta(seconds=10))] if now >= at(when) else []


def only(when):
    return lambda now: [(CPU, at(when))]


def connections(now):
    return [(CONNECTIONS, now - real_dt.timedelta(seconds=60))]


def run(cold, wait_seconds, samples, now="2026-11-24T10:06:30Z", fail_after=None, warm="", reference=True, recheck=RECHECK, decide=DECIDE):
    clock, slept, queries, timeouts, exits = [at(now)], [0.0], [], [], []
    ns = {}
    exec(PARAMS, ns)
    ns.update(COLD_START_UTC=cold, WARM_START_TARGETS=warm, SAVE_RESULTS=False, T3_SERVER_PREFIX="azuresql01-",
              TELEMETRY_RECHECK_UTC=recheck, TELEMETRY_DECIDE_UTC=decide,
              TELEMETRY_WAIT_UNTIL_UTC="" if wait_seconds is None else iso(clock[0] + real_dt.timedelta(seconds=wait_seconds)))
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        exec(HELPERS, ns)

        def sleep(seconds):
            assert seconds >= 0, seconds
            clock[0] += real_dt.timedelta(seconds=seconds)
            slept[0] += seconds

        def post(kql, timeout=None):
            queries.append(iso(clock[0]))
            timeouts.append(timeout)
            assert len(queries) <= 40, "the wait doesn't end"
            if fail_after is not None and len(queries) > fail_after:
                return 503, None, "HTTP 503."
            rows = [[target, NAMES[target][0], NAMES[target][1], table, 10, iso(last), 1]
                    for target, model in sorted(samples.items()) for table, last in model(clock[0])]
            columns = [("Target", "string"), ("ResourceType", "string"), ("ResourceName", "string"), ("TableName", "string"), ("Rows", "long"),
                       ("LastSampleUTC", "datetime"), ("Instances", "long")]
            return 200, ns["kusto_frame"]({"Tables": [{"Columns": [{"ColumnName": name, "ColumnType": kind} for name, kind in columns], "Rows": rows}]}), ""

        utils = types.SimpleNamespace(notebook=types.SimpleNamespace(exit=exits.append), runtime=types.SimpleNamespace(context={"isReferenceRun": reference}))
        ns.update(utc_now=lambda: clock[0], time=types.SimpleNamespace(sleep=sleep), _post_kql=post, _notebookutils=lambda: utils)
        exec(PER_TARGET, ns)
        exec(SUMMARY, ns)
    results = {item["check_id"][-2:]: {"status": item["status"], "message": item["message"], "evidence": item["evidence"], "remediation": item["remediation"]}
               for item in ns["RESULTS"] if item["check_id"].startswith("HUB.TELEMETRY.T")}
    return {"results": results, "slept": slept[0], "queries": len(queries), "timeouts": timeouts, "printed": buffer.getvalue(),
            "answers": [json.loads(value) for value in exits]}


def control(name, silent):
    """What Run all passed in a simulation, run 2 minutes after the latest start it names (when it ran there, without one),
    with the silent targets sending nothing and the others reporting."""
    passed = FROM_CONTROL[name]
    starts = [at(value) for value in json.loads(passed["COLD_START_UTC"]).values()]
    when = iso(max(starts) + real_dt.timedelta(minutes=2)) if starts else passed["at"]
    samples = {target: never if target in silent else steady for target in ("T1", "T2", "T3")}
    return run(passed["COLD_START_UTC"], None, samples, now=when, warm=passed["WARM_START_TARGETS"],
               recheck=passed["TELEMETRY_RECHECK_UTC"], decide=passed["TELEMETRY_DECIDE_UTC"])


def post_timeouts():
    """The notebook's own _post_kql, with requests.post standing in: the timeout it's given is the request's."""
    ns, seen = {}, []
    exec(PARAMS, ns)
    with contextlib.redirect_stdout(io.StringIO()):
        exec(HELPERS, ns)

    class Response:
        status_code = 200

        def json(self):
            return {"Tables": []}

    def fake_post(url, json=None, headers=None, timeout=None):
        seen.append(timeout)
        return Response()

    ns.update(requests=types.SimpleNamespace(post=fake_post, RequestException=OSError), get_token=lambda audience: "not-a-token")
    ns["_post_kql"]("print 1", timeout=12.5)
    ns["_post_kql"]("print 1")
    return seen


COLD = json.dumps({"T1": "2026-11-24T10:00:00Z", "T2": "2026-11-24T10:00:10Z", "T3": "2026-11-24T10:04:00Z"})
T1T2 = json.dumps({"T1": "2026-11-24T10:00:00Z", "T2": "2026-11-24T10:00:10Z"})
print(json.dumps({
    "arrives": run(COLD, 120, {"T1": steady, "T2": arrives("2026-11-24T10:07:30Z"), "T3": steady}),
    "late": run(COLD, 120, {"T1": steady, "T2": never, "T3": steady}),
    "look": run(COLD, None, {"T1": steady, "T2": never, "T3": steady}, now="2026-11-24T10:24:10Z", recheck="2026-11-24T10:34:10Z"),
    "settle": run(COLD, None, {"T1": steady, "T2": never, "T3": steady}, now="2026-11-24T10:34:10Z", recheck=""),
    "latepass": run(COLD, None, {"T1": steady, "T2": arrives("2026-11-24T10:30:00Z"), "T3": steady}, now="2026-11-24T10:34:10Z", recheck=""),
    "two": run(COLD, None, {"T1": never, "T2": never, "T3": steady}),
    "unreachable": run(COLD, None, {"T1": steady, "T2": never, "T3": steady}, recheck="", decide="2026-11-24T10:40:10Z"),
    "notreference": run(COLD, None, {"T1": steady, "T2": never, "T3": steady}, reference=False),
    "t1stale": run(T1T2, None, {"T1": only("2026-11-24T09:20:00Z"), "T2": steady, "T3": steady}),
    "t1edition": run(T1T2, None, {"T1": connections, "T2": steady, "T3": steady}),
    "flaky": run(COLD, 120, {"T1": steady, "T2": never, "T3": steady}, fail_after=1),
    "warm": run("{}", None, {"T1": steady, "T2": never, "T3": never}, warm="T1,T2,T3", recheck="", decide=""),
    "refused": run(json.dumps({"T1": "2026-11-24T10:00:00Z"}), None, {"T1": steady, "T2": never, "T3": never}),
    "badwarm": run("{}", None, {"T1": steady, "T2": never, "T3": steady}, warm="T2,T9", recheck="", decide=""),
    "expired": run(json.dumps({"T2": "2026-11-24T09:45:00Z"}), 120, {"T1": steady, "T2": never, "T3": steady}, recheck="", decide="2026-11-24T10:05:00Z"),
    "manual": run("", None, {"T1": steady, "T2": never, "T3": steady}, warm="T1,T2,T3", recheck="", decide=""),
    "garbage": run("T2 at ten", 120, {"T1": steady, "T2": never, "T3": steady}, warm="T2"),
    "baddecide": run(COLD, 120, {"T1": steady, "T2": never, "T3": steady}, decide="soon"),
    "badrecheck": run(COLD, 120, {"T1": steady, "T2": never, "T3": steady}, recheck="10:24"),
    "control": control("coldstartfail", ("T2",)),
    "controlrefused": control("coldstartrefused", ("T2", "T3")),
    "controlwording": control("coldstartwording", ("T2",)),
    "postTimeouts": post_timeouts(),
}))
'@
            $output = & $script:pandasPython $harness (Join-Path -Path $repoRoot -ChildPath 'fabric/notebooks/NB_DatabaseHub_Deployment.ipynb') $hcontrol 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ($output -join "`n")
            }
            $script:coldChecks = ($output | Select-Object -Last 1) | ConvertFrom-Json
        }

        It 'tells the validator what the session''s start did, and when Run all checks again a target that hasn''t reported: 20 and 30 minutes after the later of its VM''s start and its activity''s dispatch (review of d6d69832)' {
            if (-not $script:coldRuns['coldstart']) {
                Set-ItResult -Skipped -Because $script:coldSkip
                return
            }
            $report = $script:coldRuns['coldstart']
            $report.error | Should -BeNullOrEmpty
            @($report.validators).Count | Should -Be 1
            $run = $report.validators[0]
            $report.coldStart | Should -Match '^\{"T1": "2026-11-14T14:00:05Z", "T2": "2026-11-14T14:00:20Z", "T3": "2026-11-14T14:04:00Z"\}$'
            $run.args.COLD_START_UTC | Should -BeExactly $report.coldStart
            $run.args.WARM_START_TARGETS | Should -BeExactly ''
            # T2's activity went out at 14:10, once its host ran, after its host's start at 14:00:20: Run all checks it again 20
            # minutes after that, and 30, which decides (FIRST_SAMPLE_MINUTES).
            $run.args.TELEMETRY_RECHECK_UTC | Should -BeExactly '2026-11-14T14:30:00Z,2026-11-14T14:40:00Z'
            & $script:hiso $run.args.TELEMETRY_DECIDE_UTC | Should -Be '2026-11-14T14:40:00Z'
            # Within the validator's 5 minutes: its other checks and its save come after the wait.
            (([DateTimeOffset]$run.args.TELEMETRY_WAIT_UNTIL_UTC) - ([DateTimeOffset]$run.at)).TotalSeconds | Should -Be 120
            $run.timeout | Should -Be 300
            $report.printed | Should -Match ([regex]::Escape('Readiness: NB_DatabaseHub_Deployment ran its read-only checks in 1 minute; the Insights app''s Readiness page shows each one, worst first, after its next refresh.' + "`n"))
            @($report.sent | ForEach-Object action) | Should -Be @('session', 'stop')
            # T1 with its own anchor: Azure refused the T2 host's start, and T3's activity wasn't sent, so T1's activity at 14:04,
            # after sqlvm01's start at 14:00:05, sets the times.
            $refused = $script:coldRuns['coldstartrefused'].validators[0].args
            $refused.TELEMETRY_RECHECK_UTC | Should -BeExactly '2026-11-14T14:24:00Z,2026-11-14T14:34:00Z'
            & $script:hiso $refused.TELEMETRY_DECIDE_UTC | Should -Be '2026-11-14T14:34:00Z'
            # A 30-minute session: its live view ends at 14:30, before the 30 minutes, so its one check again then decides.
            $half = $script:coldRuns['coldstart30'].validators[0].args
            & $script:hiso $half.TELEMETRY_RECHECK_UTC | Should -Be '2026-11-14T14:30:00Z'
            & $script:hiso $half.TELEMETRY_DECIDE_UTC | Should -Be '2026-11-14T14:30:00Z'
            # A live view that ends at 14:06, before the 20 minutes: no check again, and a check by hand after the 30.
            $none = $script:coldRuns['coldstartshort'].validators[0].args
            $none.TELEMETRY_RECHECK_UTC | Should -BeExactly ''
            & $script:hiso $none.TELEMETRY_DECIDE_UTC | Should -Be '2026-11-14T14:40:00Z'
        }

        It 'makes a cold-started target that hasn''t reported a Warning that says it can''t be known yet, or a Pass when it reports within the wait (needs pandas)' {
            if (-not $script:coldChecks) {
                Set-ItResult -Skipped -Because $script:coldSkip
                return
            }
            $hv = $script:coldChecks
            # T2's first sample comes a minute into the wait: the wait looks every 30 seconds and ends there, a Pass.
            $hv.arrives.results.T2.status | Should -Be 'Pass'
            $hv.arrives.slept | Should -Be 60
            $hv.arrives.queries | Should -Be 3
            $hv.arrives.printed | Should -Match ([regex]::Escape('Waiting at most 120 seconds for the first telemetry sample since this session''s cold start: T2 arcsql01.'))
            # It doesn't come before the wait's end: a Warning, not known yet, with when its first sample is due, and when Run
            # all checks it again; nothing says there's nothing to do (the reviews of 40ff59bb and d6d69832).
            $hv.late.slept | Should -Be 110
            $hv.late.queries | Should -Be 5
            $hv.late.results.T2.status | Should -Be 'Warning'
            $hv.late.results.T2.message | Should -BeExactly 'No telemetry from T2 arcsql01 since this session''s cold start yet, so whether it reports can''t be known yet: the session started T2''s host VM 8 minutes ago, and its first sample is due by 10:34 UTC. This check waited 110 seconds for it.'
            $hv.late.results.T2.remediation | Should -BeExactly 'Run all in NB_DatabaseHub_Control checks it again at 10:24 UTC, and at 10:34 UTC if it hasn''t reported by then, which decides, and saves its Pass or Fail here. If Run all doesn''t get there, run this notebook, or ./scripts/validate.ps1 -Area Telemetry -Target T2, after 10:34 UTC while the session runs.'
            $hv.late.results.T2.evidence | Should -BeExactly '{"coldStartUtc": "2026-11-24T10:00:10+00:00", "decideUtc": "2026-11-24T10:34:10+00:00", "minutesSinceColdStart": 8, "recheckUtc": ["2026-11-24T10:24:10+00:00", "2026-11-24T10:34:10+00:00"], "waitedSeconds": 110}'
            foreach ($case in 'arrives', 'late') {
                $hv.$case.results.T1.status | Should -Be 'Pass'
                $hv.$case.results.T3.status | Should -Be 'Pass'
            }
            # Run all's live view ends too soon to check it again: the Warning says so, with when to check it by hand.
            $hv.unreachable.results.T2.status | Should -Be 'Warning'
            $hv.unreachable.results.T2.remediation | Should -BeExactly 'Run all''s live view ends too soon to check it again: run this notebook, or ./scripts/validate.ps1 -Area Telemetry -Target T2, after 10:40 UTC while the session runs.'
            # T1 too: a sample from before the session started its VM, and none since, is the cold start's Warning, not a stale VM's.
            $hv.t1stale.results.T1.status | Should -Be 'Warning'
            $hv.t1stale.results.T1.message | Should -BeExactly 'No telemetry from T1 sqlvm01 since this session''s cold start yet, so whether it reports can''t be known yet: the session started T1''s VM 6 minutes ago, and its first sample is due by 10:34 UTC.'
            $hv.t1stale.results.T2.status | Should -Be 'Pass'
            # A T1 that sends only client connections since its start has reported: its edition's Warning, as before, and
            # nothing to check again (the review of 40ff59bb).
            $hv.t1edition.results.T1.status | Should -Be 'Warning'
            $hv.t1edition.results.T1.message | Should -BeExactly 'T1 sqlvm01 sends only SqlServerConnections, not performance data. On Azure VMs, Developer, Express, and Evaluation editions send only client connections; T1 needs Standard or Enterprise.'
            @($hv.t1edition.answers[0].pending) | Should -BeNullOrEmpty
            # The endpoint fails the wait's first look: the first answer stands for every target, and the wait ends.
            $hv.flaky.slept | Should -Be 30
            $hv.flaky.queries | Should -Be 2
            $hv.flaky.results.T1.status | Should -Be 'Pass'
            $hv.flaky.results.T2.message | Should -Match 'This check waited 30 seconds for it\.$'
        }

        It 'names in each saved Warning the times Run all checks it again at, and keeps to them (review of d6d69832, needs pandas)' {
            if (-not $script:coldChecks) {
                Set-ItResult -Skipped -Because $script:coldSkip
                return
            }
            $hv = $script:coldChecks
            # Two targets without telemetry, whose own starts differ: both Warnings name the same times, Run all's.
            foreach ($target in 'T1', 'T2') {
                $hv.two.results.$target.status | Should -Be 'Warning'
                $hv.two.results.$target.remediation | Should -BeExactly ('Run all in NB_DatabaseHub_Control checks it again at 10:24 UTC, and at 10:34 UTC if it hasn''t reported by then, which decides, and saves its Pass or Fail here. If Run all doesn''t get there, run this notebook, or ./scripts/validate.ps1 -Area Telemetry -Target {0}, after 10:34 UTC while the session runs.' -f $target)
            }
            @($hv.two.answers[0].pending) | Should -Be @('T1', 'T2')
            # At the first check again, the Warning names the one left, which decides.
            $hv.look.results.T2.message | Should -BeExactly 'No telemetry from T2 arcsql01 since this session''s cold start yet, so whether it reports can''t be known yet: the session started T2''s host VM 24 minutes ago, and its first sample is due by 10:34 UTC.'
            $hv.look.results.T2.remediation | Should -BeExactly 'Run all in NB_DatabaseHub_Control checks it again at 10:34 UTC, which decides, and saves its Pass or Fail here. If Run all doesn''t get there, run this notebook, or ./scripts/validate.ps1 -Area Telemetry -Target T2, after 10:34 UTC while the session runs.'
            # Run all: the Warning that its readiness saved names the times it then checks T2 again at, to the second.
            $hfail = $script:coldRuns['coldstartfail'].validators
            @($hfail).Count | Should -Be 3
            & $script:hiso $hfail[1].at | Should -Be '2026-11-14T14:30:00Z'
            & $script:hiso $hfail[2].at | Should -Be '2026-11-14T14:40:00Z'
            $hv.control.results.T2.status | Should -Be 'Warning'
            $hv.control.results.T2.remediation | Should -BeExactly 'Run all in NB_DatabaseHub_Control checks it again at 14:30 UTC, and at 14:40 UTC if it hasn''t reported by then, which decides, and saves its Pass or Fail here. If Run all doesn''t get there, run this notebook, or ./scripts/validate.ps1 -Area Telemetry -Target T2, after 14:40 UTC while the session runs.'
            $script:coldRuns['coldstartfail'].printed | Should -Match ([regex]::Escape('Not known yet: T2, with no telemetry since this session''s cold start, so its check is a Warning for now. Run all checks it again at 14:30 (UTC), and at 14:40 if it hasn''t reported by then, which decides, and saves its Pass or Fail there.'))
            $hv.control.results.T1.status | Should -Be 'Pass'
            $hv.control.results.T3.status | Should -Be 'Pass'
        }

        It 'checks a target it waited for again at those times: a Pass as soon as it has reported, and a Fail only at the last, which decides (reviews of 40ff59bb and d6d69832, needs pandas)' {
            if (-not $script:coldChecks) {
                Set-ItResult -Skipped -Because $script:coldSkip
                return
            }
            # The validator's side: until the time that decides, a target without telemetry is a Warning, which its answer to
            # Run all lists; from then, it's a Fail, and a late but healthy one is a Pass.
            $hv = $script:coldChecks
            @($hv.late.answers).Count | Should -Be 1
            $answer = $hv.late.answers[0]
            $answer.kind | Should -BeExactly 'DbHubDemo.Readiness'
            $answer.version | Should -Be 1
            $answer.runId | Should -Match '^\d{8}T\d{6}Z-[0-9a-f]{8}$'
            @($answer.pending) | Should -Be @('T2')
            $answer.telemetry.T2.status | Should -Be 'Warning'
            $answer.telemetry.T2.message | Should -BeExactly $hv.late.results.T2.message
            $answer.telemetry.T1.status | Should -Be 'Pass'
            $hv.settle.slept | Should -Be 0
            $hv.settle.results.T2.status | Should -Be 'Fail'
            $hv.settle.results.T2.message | Should -BeExactly 'No telemetry from T2 arcsql01 in the last 60 minutes. This session started T2''s host VM 34 minutes ago, and its first sample was due by 10:34 UTC.'
            $hv.settle.answers[0].telemetry.T2.status | Should -Be 'Fail'
            @($hv.settle.answers[0].pending) | Should -BeNullOrEmpty
            $hv.latepass.results.T2.status | Should -Be 'Pass'
            # It answers only Run all's reference run: not a run by hand, nor one outside a reference run.
            @($hv.notreference.answers).Count | Should -Be 0
            $hv.notreference.results.T2.status | Should -Be 'Warning'
            @($hv.manual.answers).Count | Should -Be 0

            # Run all's side: T2 never reports, so a Warning at its first check again, and a Fail at the one that decides, each
            # with no wait, the parameters it passed at readiness, and the times left.
            $report = $script:coldRuns['coldstartfail']
            $report.error | Should -BeNullOrEmpty
            $first, $look, $decide = $report.validators
            & $script:hiso $look.args.TELEMETRY_RECHECK_UTC | Should -Be '2026-11-14T14:40:00Z'
            $decide.args.TELEMETRY_RECHECK_UTC | Should -BeExactly ''
            foreach ($again in $look, $decide) {
                $again.args.TELEMETRY_WAIT_UNTIL_UTC | Should -BeExactly ''
                foreach ($name in $first.args.PSObject.Properties.Name | Where-Object { $_ -notin 'TELEMETRY_WAIT_UNTIL_UTC', 'TELEMETRY_RECHECK_UTC' }) {
                    $again.args.$name | Should -Be $first.args.$name -Because $name
                }
            }
            $report.printed | Should -Match ([regex]::Escape(("Readiness again at 14:30 (UTC), for the telemetry of T2 since this session's cold start (NB_DatabaseHub_Deployment; the Insights app's Readiness page shows each check, with its fix, after its next refresh):`n" +
                        "  HUB.TELEMETRY.T2 Warning: No telemetry from T2 arcsql01 since this session's cold start yet, so whether it reports can't be known yet.`n" +
                        '  Not known yet: T2. Run all checks it again at 14:40 (UTC), which decides.')))
            $report.printed | Should -Match ([regex]::Escape(("Readiness again at 14:40 (UTC), for the telemetry of T2 since this session's cold start (NB_DatabaseHub_Deployment; the Insights app's Readiness page shows each check, with its fix, after its next refresh):`n" +
                        '  HUB.TELEMETRY.T2 Fail: No telemetry from T2 arcsql01 in the last 60 minutes.')))
            @($report.order) | Should -Be @('sent:session', 'validator', 'validator', 'validator', 'sent:stop', ('history:{0}' -f $report.sent[0].sessionId.Substring(0, 8)))
            $report.printed | Should -Match 'Pass: the history is saved'
            # A late but healthy T2, whose first sample shows at 14:35: still a Warning at 14:30, and a Pass at 14:40.
            $late = $script:coldRuns['coldstartlate']
            $late.error | Should -BeNullOrEmpty
            @($late.validators).Count | Should -Be 3
            $late.printed | Should -Match ([regex]::Escape(("Readiness again at 14:40 (UTC), for the telemetry of T2 since this session's cold start (NB_DatabaseHub_Deployment; the Insights app's Readiness page shows each check, with its fix, after its next refresh):`n" +
                        '  HUB.TELEMETRY.T2 Pass: T2 reports performance telemetry from 3 tables.')))
            $late.printed | Should -Not -Match 'HUB\.TELEMETRY\.T2 Fail'
            # Its first sample shows at 14:25: a Pass at 14:30, and no check after that.
            $grace = $script:coldRuns['coldstartgrace']
            $grace.error | Should -BeNullOrEmpty
            @($grace.validators).Count | Should -Be 2
            $grace.printed | Should -Match ([regex]::Escape(("Readiness again at 14:30 (UTC), for the telemetry of T2 since this session's cold start (NB_DatabaseHub_Deployment; the Insights app's Readiness page shows each check, with its fix, after its next refresh):`n" +
                        '  HUB.TELEMETRY.T2 Pass: T2 reports performance telemetry from 3 tables.')))
            $grace.printed | Should -Not -Match 'Readiness again at 14:40'
            # A status it can't read at 14:30 doesn't say the session ended: it checks T2 again all the same.
            $unread = $script:coldRuns['coldstartunread']
            $unread.error | Should -BeNullOrEmpty
            @($unread.validators).Count | Should -Be 3
            $unread.printed | Should -Match ([regex]::Escape('  HUB.TELEMETRY.T2 Fail: No telemetry from T2 arcsql01 in the last 60 minutes.'))
        }

        It 'fits a short session: one check again at the end of a 30-minute session''s live view, which decides; and the one that decides runs even when the check before it ends past the live view''s end (review of d6d69832)' {
            if (-not $script:coldRuns['coldstart30']) {
                Set-ItResult -Skipped -Because $script:coldSkip
                return
            }
            $report = $script:coldRuns['coldstart30']
            $report.error | Should -BeNullOrEmpty
            @($report.validators).Count | Should -Be 2
            & $script:hiso $report.validators[1].at | Should -Be '2026-11-14T14:30:00Z'
            $report.validators[1].args.TELEMETRY_RECHECK_UTC | Should -BeExactly ''
            $report.printed | Should -Match ([regex]::Escape('Run all checks it again at 14:30 (UTC), which decides, and saves its Pass or Fail there.'))
            $report.printed | Should -Match ([regex]::Escape(("Readiness again at 14:30 (UTC), for the telemetry of T2 since this session's cold start (NB_DatabaseHub_Deployment; the Insights app's Readiness page shows each check, with its fix, after its next refresh):`n" +
                        '  HUB.TELEMETRY.T2 Fail: No telemetry from T2 arcsql01 in the last 60 minutes.')))
            @($report.order) | Should -Be @('sent:session', 'validator', 'validator', 'sent:stop', ('history:{0}' -f $report.sent[0].sessionId.Substring(0, 8)))
            $report.printed | Should -Match 'Pass: the history is saved'
            # A 33-minute session: its checks again at 14:30 and at its end, 14:33, which decides. The first takes until 14:34:50,
            # past the live view's end, and the one that decides still runs then, before the session's end.
            $over = $script:coldRuns['coldstart33']
            $over.error | Should -BeNullOrEmpty
            $over.validators[0].args.TELEMETRY_RECHECK_UTC | Should -BeExactly '2026-11-14T14:30:00Z,2026-11-14T14:33:00Z'
            @($over.validators).Count | Should -Be 3
            & $script:hiso $over.validators[2].at | Should -Be (& $script:hiso $over.validators[1].ended)
            $over.printed | Should -Match ([regex]::Escape('  HUB.TELEMETRY.T2 Fail: No telemetry from T2 arcsql01 in the last 60 minutes.'))
            @($over.order) | Should -Be @('sent:session', 'validator', 'validator', 'validator', 'sent:stop', ('history:{0}' -f $over.sent[0].sessionId.Substring(0, 8)))
        }

        It 'says when a target it waited for can''t be checked again: a live view that ends too soon, a session that ended first, a validator that fails, or an answer it can''t read (reviews of 40ff59bb and d6d69832)' {
            if (-not $script:coldRuns['coldstartshort']) {
                Set-ItResult -Skipped -Because $script:coldSkip
                return
            }
            # WAIT_FOR_END False and WATCH_MINUTES 5: the live view ends at 14:06, before 14:30, and the session goes on.
            $short = $script:coldRuns['coldstartshort']
            $short.error | Should -BeNullOrEmpty
            @($short.validators).Count | Should -Be 1
            $short.printed | Should -Match ([regex]::Escape('Warning: no check again is scheduled for T2: the live view ends at 14:06 (UTC), before Run all would check it again. Fix: run NB_DatabaseHub_Deployment, or ./scripts/validate.ps1 -Area Telemetry -Target T2, after 14:40 (UTC) while the session runs.'))
            @($short.sent | ForEach-Object action) | Should -Be @('session')
            # The app stopped the session 10 minutes in: T2's result can't be known, so no check again and no Fail.
            $stopped = $script:coldRuns['coldstartstopped']
            $stopped.error | Should -BeNullOrEmpty
            @($stopped.validators).Count | Should -Be 1
            $stopped.printed | Should -Match ([regex]::Escape('Readiness: the telemetry of T2 wasn''t checked again: the session ended before 14:30 (UTC), so its check stays a Warning on the Insights app''s Readiness page; the next session''s readiness checks it.'))
            $stopped.printed | Should -Not -Match 'Readiness again'
            # The validator fails each time it's run again: a Warning with the time left, then one with the fix, and the
            # session goes on to its end and its history.
            $failed = $script:coldRuns['coldstartrecheckfail']
            $failed.error | Should -BeNullOrEmpty
            @($failed.validators).Count | Should -Be 3
            $failed.printed | Should -Match ([regex]::Escape('Warning: the telemetry of T2 wasn''t checked again at 14:30 (UTC): NB_DatabaseHub_Deployment didn''t finish in this session (RuntimeError: Notebook execution failed in cell 12: the telemetry endpoint didn''t answer). Run all checks it again at 14:40, which decides.'))
            $failed.printed | Should -Match ([regex]::Escape('Warning: the telemetry of T2 wasn''t checked again: NB_DatabaseHub_Deployment didn''t finish in this session (RuntimeError: Notebook execution failed in cell 12: the telemetry endpoint didn''t answer), so its check stays a Warning on the Insights app''s Readiness page. The session goes on. Fix: run NB_DatabaseHub_Deployment, or ./scripts/validate.ps1 -Area Telemetry -Target T2, while the session runs.'))
            @($failed.sent | ForEach-Object action) | Should -Be @('session', 'stop')
            $failed.printed | Should -Match 'Pass: the history is saved'
            # Its first answer can't be read (a kind this notebook doesn't know): no check again, and a line that says so
            # instead of the promise its Warnings hold (the review of d6d69832).
            $foreign = $script:coldRuns['coldstartforeign']
            $foreign.error | Should -BeNullOrEmpty
            @($foreign.validators).Count | Should -Be 1
            $foreign.printed | Should -Match ([regex]::Escape('Warning: no check again is scheduled: NB_DatabaseHub_Deployment''s answer couldn''t be read, so Run all doesn''t know whether T1, T2 and T3, which this session''s start brought up, had reported. Fix: if the Insights app''s Readiness page shows a HUB.TELEMETRY check of T1, T2 and T3 as a Warning, run NB_DatabaseHub_Deployment, or ./scripts/validate.ps1 -Area Telemetry -Target T1, T2, T3, after 14:40 (UTC) while the session runs.'))
            $foreign.printed | Should -Not -Match 'Not known yet|Readiness again'
        }

        It 'keeps a warm start''s Fail, and says a VM was already running only of a target whose activity the session sent to it, without saying more: not after a refused start, a skipped T3, or Start steps it can''t read (reviews of 40ff59bb and d6d69832, needs pandas)' {
            if (-not $script:coldChecks) {
                Set-ItResult -Skipped -Because $script:coldSkip
                return
            }
            $hv = $script:coldChecks
            $missing = @{ T2 = 'No telemetry from T2 arcsql01 in the last 60 minutes.'; T3 = 'No telemetry from T3 azuresql01-<id>/ContosoCare in the last 60 minutes.' }
            # Run all's side: Azure refused the T2 host's start, so it has no Start step and T2 no activity, and T3's activity
            # wasn't sent: neither is cold or warm. Start steps it can't read make no target warm.
            $refused = $script:coldRuns['coldstartrefused'].validators[0].args
            $refused.COLD_START_UTC | Should -BeExactly '{"T1": "2026-11-14T14:00:05Z"}'
            $refused.WARM_START_TARGETS | Should -BeExactly ''
            $wording = $script:coldRuns['coldstartwording'].validators[0].args
            $wording.COLD_START_UTC | Should -BeExactly '{}'
            $wording.WARM_START_TARGETS | Should -BeExactly ''
            foreach ($case in 'controlrefused', 'controlwording') {
                $hv.$case.results.T2.status | Should -Be 'Fail'
                $hv.$case.results.T2.message | Should -BeExactly $missing.T2 -Because $case
            }
            $hv.controlrefused.results.T3.message | Should -BeExactly $missing.T3
            $hv.controlrefused.results.T1.status | Should -Be 'Pass'
            # The validator's side: a warm start's Fail stays a Fail, and says the VM was already running, and no more: one
            # that ./scripts/start-demo.ps1 started minutes before counts as already running too (the review of d6d69832).
            $hv.warm.slept | Should -Be 0
            $hv.warm.queries | Should -Be 1
            $hv.warm.results.T2.status | Should -Be 'Fail'
            $hv.warm.results.T2.message | Should -BeExactly ($missing.T2 + ' This session didn''t start T2''s host VM: it was already running.')
            $hv.warm.results.T3.status | Should -Be 'Fail'
            $hv.warm.results.T3.message | Should -BeExactly ($missing.T3 + ' This session didn''t start T1''s VM, which runs T3''s activity: it was already running.')
            # Neither cold nor warm, after a refused start and a skipped T3: no note. WARM_START_TARGETS it can't read: none.
            $hv.refused.results.T2.message | Should -BeExactly $missing.T2
            $hv.refused.results.T3.message | Should -BeExactly $missing.T3
            $hv.badwarm.results.T2.message | Should -BeExactly $missing.T2
            $hv.badwarm.printed | Should -Match 'WARM_START_TARGETS isn''t a list of T1, T2, and T3, so no target counts as already running\.'
            # Its first sample was due before this check: a Fail, without waiting.
            $hv.expired.slept | Should -Be 0
            $hv.expired.results.T2.status | Should -Be 'Fail'
            $hv.expired.results.T2.message | Should -BeExactly ($missing.T2 + ' This session started T2''s host VM 21 minutes ago, and its first sample was due by 10:05 UTC.')
            # The notebook run by hand, or with a COLD_START_UTC, TELEMETRY_DECIDE_UTC, or TELEMETRY_RECHECK_UTC it can't read:
            # today's Fail, word for word, whatever WARM_START_TARGETS says.
            foreach ($case in 'manual', 'garbage', 'baddecide', 'badrecheck') {
                $hv.$case.slept | Should -Be 0
                $hv.$case.results.T2.status | Should -Be 'Fail'
                $hv.$case.results.T2.message | Should -BeExactly $missing.T2 -Because $case
            }
            $hv.garbage.printed | Should -Match 'COLD_START_UTC isn''t JSON of targets and UTC times, so telemetry is checked as usual\.'
            foreach ($case in 'baddecide', 'badrecheck') {
                $hv.$case.printed | Should -Match ('TELEMETRY_DECIDE_UTC or TELEMETRY_RECHECK_UTC isn''t a UTC time, so the targets the session''s start brought up are checked as usual\.') -Because $case
            }
        }

        It 'ends each look at the telemetry by the wait''s deadline, within Run all''s 5 minutes for the validator (review of 40ff59bb, needs pandas)' {
            if (-not $script:coldChecks) {
                Set-ItResult -Skipped -Because $script:coldSkip
                return
            }
            $hv = $script:coldChecks
            # The deadline is 120 seconds after the first look: each look after it gets the seconds left, and none starts in
            # its last 10 seconds. The first look is the cell's usual query.
            $hv.late.timeouts.Count | Should -Be 5
            $hv.late.timeouts[0] | Should -BeNullOrEmpty
            @($hv.late.timeouts[1..4]) | Should -Be @(90, 60, 30, 10)
            $hv.arrives.timeouts.Count | Should -Be 3
            @($hv.arrives.timeouts[1..2]) | Should -Be @(90, 60)
            # The notebook's own _post_kql gives the request the timeout it's given, and 180 seconds otherwise, as before.
            @($hv.postTimeouts) | Should -Be @(12.5, 180)
        }

        It 'announces every beat that began while a check again held the live view up, as soon as it ends: no sleep after one (review of d6d69832)' {
            if (-not $script:coldRuns['coldstartslow']) {
                Set-ItResult -Skipped -Because $script:coldSkip
                return
            }
            # Each check again takes 290 seconds here: from 14:30:00 to 14:34:50, and from 14:40:00 to 14:44:50.
            $report = $script:coldRuns['coldstartslow']
            $report.error | Should -BeNullOrEmpty
            @($report.validators).Count | Should -Be 3
            $printedAt = {
                param([string] $Start)
                @($report.timed | Where-Object { $_[1].StartsWith($Start) } | ForEach-Object { & $script:hiso $_[0] })
            }
            foreach ($beat in 'Now: T2 Parallelism waits, until 14:39', 'Now: T1 Deep blocking chain and lock escalation, until 14:44', 'Now: T3 Plan regression (automatic plan correction), until 15:04') {
                & $printedAt $beat | Should -Be @(& $script:hiso $report.validators[1].ended) -Because $beat
            }
            & $printedAt 'Now: T2 CPU pressure, until 14:54' | Should -Be @(& $script:hiso $report.validators[2].ended)
        }
    }

    It 'shows T5 in the guide and the live view, ends its ru-storms by its own end, and hands its metrics to the history as COSMOS_METRICS (2026-11-18)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'sessioncosmos' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.leaked | Should -BeFalse
        $report.printed | Should -Match ([regex]::Escape('The targets: T1 sqlvm01 | T2 arcsql01 | T3 azuresql01-abc123/ContosoCare | T4 pgflex01-abc123 | T4''s read replica pgreplica01-abc123 | T5 cosmos01-abc123'))
        $report.printed | Should -Match 'Estate: View Microsoft SQL, then View PostgreSQL, then View Azure Cosmos DB \| Performance: the real-time dashboards for Microsoft SQL and PostgreSQL, and Azure Cosmos DB with T5''s account selected \| Optimization: '
        # The user (2026-11-18): every Run all leaves T5 back at its baseline, with no ru-storm still running, at its end.
        $report.printed | Should -Match 'T5: its last ru-storm ends, and T5 is back at its baseline with no throttled requests \(429s\), by 15:19, before the session ends at 15:30; every Run all repeats its storms from the first\.'
        $report.printed | Should -Match 'T5 is Azure Cosmos DB: show it in Estate \(View: Azure Cosmos DB, cosmos01-abc123\) and on Performance: Peak Norm RU % at 100% and Throttled Requests \(429s\) during each ru-storm'
        $report.printed | Should -Match '(?m)^  14:07-14:17  T5  RU storm \(request rate too from about 14:08  Performance: T5: Normalized RU consumption'
        $report.printed | Should -Match 'Now: T5 RU storm \(request rate too large\), until 14:17; in Database Hub from about 14:08\.'
        $report.printed | Should -Match 'The history''s metrics: Azure Monitor metrics for the history\.'
        # Its beats: two ru-storms in each 30-minute cycle from its dispatch at 14:04, the last one back at its baseline by 15:19.
        $job = $report.refs[0].args
        $storms = @(($job.SESSION_PLAN | ConvertFrom-Json).beats | Where-Object target -EQ 'T5')
        @($storms | ForEach-Object { ([datetime]$_.startUtc).ToUniversalTime().ToString('HH:mm') }) | Should -Be @('14:07', '14:22', '14:37', '14:52', '15:07')
        @($storms | ForEach-Object scenario | Select-Object -Unique) | Should -Be @('ru-storm')
        ([datetime]$storms[-1].endUtc).ToUniversalTime() | Should -BeLessOrEqual ([datetime]::new(2026, 11, 14, 15, 19, 0, [System.DateTimeKind]::Utc))
        # T5's metrics go as their own parameter, and T4's without them.
        $cosmos = $job.COSMOS_METRICS | ConvertFrom-Json
        $cosmos.sessionId | Should -Be $job.SESSION_ID
        $cosmos.series[0].statusCode | Should -Be '429'
        ($job.POSTGRES_METRICS | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'cosmos'
        ($job.POSTGRES_METRICS | ConvertFrom-Json).sessionId | Should -Be $job.SESSION_ID
    }

    It 'leaves T5''s ACTIVITIES entry out when T5 isn''t one of the demo''s targets, and lists T5''s beats only until its own end' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $filled = Get-FilledNotebook -Zone 'UTC'
        $driver = Join-Path -Path $TestDrive -ChildPath 't5.py'
        Set-Content -LiteralPath $driver -Encoding utf8NoBOM -Value @'
import datetime as dt, json, sys
cells = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
ns = {}
exec(cells[0], ns)
exec(cells[1], ns)
catalog = ns["load_catalog"](ns["CATALOG_JSON"])
showcase = ns["load_showcase"](ns["SHOWCASE_JSON"])
without = dict(catalog, targets=[target for target in catalog["targets"] if target != "T5"])
out = {"with": [item["target"] for item in ns["known_activities"](ns["ACTIVITIES"], catalog)],
       "without": [item["target"] for item in ns["known_activities"](ns["ACTIVITIES"], without)],
       "request": ns["build_request"]("run", ns["known_activities"](ns["ACTIVITIES"], without), 90, catalog=without)["activities"]}
anchor = dt.datetime(2026, 11, 14, 14, 0, tzinfo=dt.timezone.utc)
end = anchor + dt.timedelta(minutes=90)
def storms(target_ends):
    return ["%s@%d" % (beat["scenario"], (beat["startUtc"] - anchor).total_seconds() // 60)
            for beat in ns["showcase_beats"](showcase, {"T5": anchor}, end, "", False, target_ends=target_ends)]
out["full"] = storms(None)
out["cut"] = storms({"T5": anchor + dt.timedelta(minutes=78)})
# A ru-storm runs only whole, with its 2 minutes of recovery before the profile's end, as the runner plans it (2026-11-19).
out["fits"] = {str(minutes): [int((beat["startUtc"] - anchor).total_seconds() // 60) for beat in ns["showcase_beats"](showcase, {"T5": anchor}, anchor + dt.timedelta(minutes=minutes))] for minutes in (87, 88)}
out["signal"] = ns["showcase_beats"](showcase, {"T5": anchor}, end)[0]["signal"]
status = {"acceptedUtc": "2026-11-14T14:00:00Z", "runEndUtc": "2026-11-14T15:30:00Z", "dispatchUtc": {"T5": "2026-11-14T14:00:00Z"},
          "t5": {"endUtc": "2026-11-14T15:18:00Z"}}
out["status"] = ["%s@%s" % (beat["scenario"], beat["startUtc"].strftime("%H:%M")) for beat in ns["status_beats"](status, showcase)]
out["shows"] = [ns["shows_minutes"](target) for target in ("T1", "T4", "T5")]
print(json.dumps(out))
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $driver $filled 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $t5 = ($output | Select-Object -Last 1) | ConvertFrom-Json
        @($t5.with) | Should -Be @('T1', 'T2', 'T3', 'T4', 'T5')
        @($t5.without) | Should -Be @('T1', 'T2', 'T3', 'T4') -Because 'a demo without T5 (t5Enabled false) runs the default ACTIVITIES as before'
        @($t5.request | ForEach-Object target) | Should -Be @('T1', 'T2', 'T3', 'T4')
        @($t5.full) | Should -Be @('ru-storm@3', 'ru-storm@18', 'ru-storm@33', 'ru-storm@48', 'ru-storm@63', 'ru-storm@78')
        @($t5.cut) | Should -Be @('ru-storm@3', 'ru-storm@18', 'ru-storm@33', 'ru-storm@48', 'ru-storm@63') -Because 'T5''s showcase ends at minute 78, where its sixth storm would start'
        @($t5.fits.'87' | ForEach-Object { [int]$_ }) | Should -Be @(3, 18, 33, 48, 63) -Because 'the sixth storm, minutes 78 to 86, and its 2 minutes of recovery don''t end by minute 87, so the runner skips it rather than clip it'
        @($t5.fits.'88' | ForEach-Object { [int]$_ }) | Should -Be @(3, 18, 33, 48, 63, 78)
        $t5.signal | Should -Match '^T5: Normalized RU consumption'
        @($t5.status) | Should -Be @('ru-storm@14:03', 'ru-storm@14:18', 'ru-storm@14:33', 'ru-storm@14:48', 'ru-storm@15:03') -Because 'the status''s t5.endUtc, 15:18, ends T5''s beats'
        @($t5.shows) | Should -Be @(3, 1, 1)
    }

    It 'runs Run all in <Case>' -ForEach @(
        @{ Case = 'a session that already runs: it follows that one and ends it, rather than start another'; Scenario = 'active'; Start = '2026-11-14T14:00:00Z'; Sent = @('stop'); Refs = 1; Jobs = 0; Validators = 1; Printed = 'A session already runs \(session aaaaaaaa, until 15:10, UTC\): this Run all follows it' }
        @{ Case = 'the evening, too close to the auto-shutdown: nothing starts, and it says how to change it'; Scenario = 'late'; Start = '2026-11-14T18:45:00Z'; Sent = @(); Refs = 0; Jobs = 0; Validators = 0; Printed = 'Nothing is started: .* too soon for a session of at least 30 minutes\.\s+Fix: Run all again earlier in the day, or set autoShutdownTime' }
        @{ Case = 'a duration under a session''s 30 minutes: nothing starts, and it names the duration, not the auto-shutdown (F33, live 2026-11-21)'; Scenario = 'askedshort'; Start = '2026-11-14T14:20:00Z'; Sent = @(); Refs = 0; Jobs = 0; Validators = 0; Printed = 'Nothing is started: a session runs at least 30 minutes, and you asked for 20\.\s+Fix: set DURATION_MINUTES to 30 or more, then Run all again\.' }
        @{ Case = 'a duration over a session''s 120 minutes: nothing starts, and it names the duration, rather than a plan cut short by the auto-shutdown and a request that fails (F33)'; Scenario = 'askedlong'; Start = '2026-11-14T09:00:00Z'; Sent = @(); Refs = 0; Jobs = 0; Validators = 0; Printed = 'Nothing is started: a session runs at most 120 minutes, and you asked for 150\.\s+Fix: set DURATION_MINUTES to 120 or less, then Run all again\.' }
        @{ Case = 'a duration that isn''t a whole number: nothing starts, and it quotes the duration, rather than plan 45 minutes and then fail the request (F33''s review)'; Scenario = 'askedfraction'; Start = '2026-11-14T14:20:00Z'; Sent = @(); Refs = 0; Jobs = 0; Validators = 0; Printed = 'Nothing is started: a session runs a whole number of minutes, from 30 to 120, and you asked for 45\.5\.\s+Fix: set DURATION_MINUTES to a whole number from 30 to 120, then Run all again\.' }
        @{ Case = 'no duration: nothing starts, and it says so, rather than a TypeError (F33''s review)'; Scenario = 'askednone'; Start = '2026-11-14T14:20:00Z'; Sent = @(); Refs = 0; Jobs = 0; Validators = 0; Printed = 'Nothing is started: a session runs a whole number of minutes, from 30 to 120, and you asked for None\.\s+Fix: set DURATION_MINUTES to a whole number from 30 to 120, then Run all again\.' }
        @{ Case = 'a duration that isn''t a number: nothing starts, and it quotes it, rather than a ValueError (F33''s review)'; Scenario = 'askedtext'; Start = '2026-11-14T14:20:00Z'; Sent = @(); Refs = 0; Jobs = 0; Validators = 0; Printed = 'Nothing is started: a session runs a whole number of minutes, from 30 to 120, and you asked for "abc"\.\s+Fix: set DURATION_MINUTES to a whole number from 30 to 120, then Run all again\.' }
        @{ Case = 'a duration given as text, as a pipeline or the Fabric job API can pass it: the session runs it (F33''s review)'; Scenario = 'askedstring'; Start = '2026-11-14T14:00:00Z'; Sent = @('session', 'stop'); Refs = 1; Jobs = 0; Validators = 1; Printed = 'This session runs 90 minutes, until 15:30 \(UTC\)\.' }
        @{ Case = 'the late afternoon: it says before it starts when the session ends and why'; Scenario = 'capped'; Start = '2026-11-14T17:45:00Z'; Sent = @('session', 'stop'); Refs = 1; Jobs = 0; Validators = 1; Printed = 'This session runs 60 of the 90 minutes asked: it ends at 18:45' }
        @{ Case = 'an earlier session''s metrics in the vault: its history is saved right after the start is sent'; Scenario = 'leftover'; Start = '2026-11-14T14:00:00Z'; Sent = @('session', 'stop'); Refs = 2; Jobs = 0; Validators = 1; Printed = 'An earlier session \(eeeeeeee, .*\) left its metrics in the vault: its history is saved right after this session''s start is sent, while the VMs start\.' }
        @{ Case = 'an earlier session''s T5 metrics alone in the vault: its history is saved with them (2026-11-18)'; Scenario = 'leftovercosmos'; Start = '2026-11-14T14:00:00Z'; Sent = @('session', 'stop'); Refs = 2; Jobs = 0; Validators = 1; Printed = 'An earlier session \(eeeeeeee, .*\) left its metrics in the vault: its history is saved right after this session''s start is sent, while the VMs start\.' }
        @{ Case = 'an earlier session''s metrics and its stopped status, which keeps its plan: its history is saved with its beats (2026-11-19)'; Scenario = 'leftoverplan'; Start = '2026-11-14T14:00:00Z'; Sent = @('session', 'stop'); Refs = 2; Jobs = 0; Validators = 1; Printed = 'An earlier session \(eeeeeeee, .*\) left its metrics in the vault: its history is saved right after this session''s start is sent, while the VMs start\.' }
        @{ Case = 'an earlier session''s metrics without its plan, and no demo lakehouse: its history runs as a job, and the Warning says "unless it''s saved already" (2026-11-19)'; Scenario = 'leftoverjob'; Start = '2026-11-14T14:00:00Z'; Sent = @('session', 'stop'); Refs = 0; Jobs = 2; Validators = 0; Printed = 'NB_DatabaseHub_LiveActivity runs as a job in the demo workspace to save session eeeeeeee''s history\.' }
        @{ Case = 'Stop now: it ends the session that runs, its history saved too'; Scenario = 'stopnow'; Start = '2026-11-14T14:00:00Z'; Sent = @('stop'); Refs = 1; Jobs = 0; Validators = 0; Printed = '=== Stop now: stopping session aaaaaaaa ===' }
        @{ Case = 'Stop now after the run ending a session was cut off before its history: that session''s history is saved once its telemetry is in (2026-11-19)'; Scenario = 'stoppedend'; Start = '2026-11-14T14:00:00Z'; Sent = @('stop'); Refs = 1; Jobs = 0; Validators = 0; Printed = 'Session bbbbbbbb already stopped: its history is saved here too, in case the run that was ending it stopped before it saved it \(NB_DatabaseHub_LiveActivity skips a session already saved\)\.\s+Waiting 11 minutes for its last telemetry to arrive \(until 14:10\)\.' }
        @{ Case = 'Stop now after the run ending a session was cut off, its plan in its stopped status: its history is saved with its beats (2026-11-19)'; Scenario = 'stoppedplan'; Start = '2026-11-14T14:00:00Z'; Sent = @('stop'); Refs = 1; Jobs = 0; Validators = 0; Printed = 'Session bbbbbbbb already stopped: its history is saved here too, in case the run that was ending it stopped before it saved it' }
        @{ Case = 'Stop now when the vault''s metrics are an earlier session''s and the plan is in the stopped status: its history is saved with its beats, without T4''s metrics (2026-11-19)'; Scenario = 'stoppedplannometrics'; Start = '2026-11-14T14:00:00Z'; Sent = @('stop'); Refs = 1; Jobs = 0; Validators = 0; Printed = 'Session bbbbbbbb already stopped: its history is saved here too.*\s+Waiting 11 minutes for its last telemetry to arrive \(until 14:10\)\.' }
        @{ Case = 'Stop now after a session stopped during its start, before it had an end: its window ends at its stop, with no beats and no Warning (2026-11-19)'; Scenario = 'stoppedstart'; Start = '2026-11-14T14:00:00Z'; Sent = @('stop'); Refs = 1; Jobs = 0; Validators = 0; Printed = 'Session bbbbbbbb already stopped: its history is saved here too.*\s+Waiting 11 minutes for its last telemetry to arrive \(until 14:10\)\.' }
        @{ Case = 'Stop now after a stop that didn''t find the session''s plan: its history is saved without its beats, and the Warning names no fix (2026-11-19)'; Scenario = 'stoppedlost'; Start = '2026-11-14T14:00:00Z'; Sent = @('stop'); Refs = 1; Jobs = 0; Validators = 0; Printed = 'Session bbbbbbbb already stopped: its history is saved here too' }
        @{ Case = 'Stop now after a session''s end passed with no stop recorded: it ends that session as its end would, its history saved (2026-11-19)'; Scenario = 'endedrunning'; Start = '2026-11-14T14:00:00Z'; Sent = @('stop'); Refs = 1; Jobs = 0; Validators = 0; Printed = '=== Stop now: stopping session cccccccc ===' }
        @{ Case = 'Stop now when the last session stopped more than 7 days ago: it stops whatever runs, and saves no history'; Scenario = 'stoppedold'; Start = '2026-11-14T14:00:00Z'; Sent = @('stop'); Refs = 0; Jobs = 0; Validators = 0; Printed = 'No session runs \(its status says stopped\), so Stop now stops whatever runs\.' }
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
        # ConvertFrom-Json reads the times as dates.
        $utc = { param($Value) ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture) }
        # The Warning of a history saved again without its beats (2026-11-19): what's there, and its session row.
        $beatless = 'without its beats, because {0}: its beats'' correlation, its Database Agent finding, and its beats'' rows in scenario_runs are there only if an earlier save of it wrote them\. Its session row says it''s saved, so it isn''t analyzed again\. {1}'
        $noFix = 'Only its status had its beats, so they can''t be saved now\.'
        if ($Scenario -in 'leftover', 'leftoverplan') {
            # Its metrics are read before the start, and its history saved right after the start is sent.
            $session = $report.sent[0].sessionId
            @($report.order) | Should -Be @('sent:session', 'history:eeeeeeee', 'validator', 'sent:stop', ('history:{0}' -f $session.Substring(0, 8)))
            $report.refs[0].args.SESSION_ID | Should -Be ('e' * 32)
            $report.refs[0].args.PSObject.Properties.Name | Should -Contain 'POSTGRES_METRICS'
            $report.refs[1].args.SESSION_ID | Should -Be $session
            $plan = $report.refs[0].args.SESSION_PLAN | ConvertFrom-Json
            $plan.sessionId | Should -Be ('e' * 32)
        }
        if ($Scenario -eq 'leftover') {
            # No status names it, so its plan is its window from its metrics, with no beats (2026-11-19): its session row says
            # it's saved, so no later Run all analyzes it again, and a Warning says so once.
            @($plan.beats).Count | Should -Be 0
            (& $utc $plan.startUtc) | Should -Be '2026-11-13T12:20:00Z'
            (& $utc $plan.endUtc) | Should -Be '2026-11-13T14:00:00Z'
            ([regex]::Matches($report.printed, ('Warning: session eeeeeeee''s history is saved ' + ($beatless -f 'no status names it', $noFix)))).Count | Should -Be 1
        }
        if ($Scenario -eq 'leftoverjob') {
            # A job's answer isn't read here, so its Warning says "unless it's saved already", once, as it starts.
            $report.jobs[0].SESSION_ID | Should -Be ('e' * 32)
            @(($report.jobs[0].SESSION_PLAN | ConvertFrom-Json).beats).Count | Should -Be 0
            ([regex]::Matches($report.printed, ('Warning: unless session eeeeeeee''s history is saved already, that job saves it ' + ($beatless -f 'no status names it', $noFix)))).Count | Should -Be 1
            $report.printed | Should -Not -Match 'Warning: session eeeeeeee''s history is saved without its beats'
            $report.jobs[1].SESSION_ID | Should -Be $report.sent[0].sessionId
        }
        if ($Scenario -eq 'leftoverplan') {
            # Its plan from its stopped status (2026-11-19): its beats, the Database Agent beat, and its own window.
            @($plan.beats).Count | Should -BeGreaterThan 20
            @($plan.beats | Where-Object { $_.PSObject.Properties.Name -contains 'agent' -and $_.agent }).Count | Should -Be 1
            (& $utc $plan.startUtc) | Should -Be '2026-11-13T12:30:00Z'
            (& $utc $plan.endUtc) | Should -Be '2026-11-13T14:00:00Z'
            (& $utc $report.refs[0].args.WINDOW_START_UTC) | Should -Be '2026-11-13T12:25:00Z'
            $report.printed | Should -Not -Match 'without its beats'
        }
        if ($Scenario -eq 'leftovercosmos') {
            # T5's alone: COSMOS_METRICS, and no POSTGRES_METRICS for an empty T4 document.
            $report.refs[0].args.SESSION_ID | Should -Be ('e' * 32)
            $report.refs[0].args.PSObject.Properties.Name | Should -Not -Contain 'POSTGRES_METRICS'
            $cosmos = $report.refs[0].args.COSMOS_METRICS | ConvertFrom-Json
            $cosmos.sessionId | Should -Be ('e' * 32)
            @($cosmos.accounts | ForEach-Object resourceName) | Should -Be @('cosmos01-abc123')
        }
        if ($Scenario -in 'unbound', 'refail') {
            $report.jobs[0].SESSION_ID | Should -Be $report.sent[0].sessionId
            $report.jobs[0].PSObject.Properties.Name | Should -Contain 'POSTGRES_METRICS'
            $report.printed | Should -Match 'Pass: the history is saved'
        }
        if ($Scenario -in 'active', 'stopnow') {
            $report.sent[0].sessionId | Should -Be ('a' * 32)
        }
        if ($Scenario -in 'askedshort', 'askedlong', 'askedfraction', 'askednone', 'askedtext') {
            # The duration asked is the cause (F33): neither the auto-shutdown nor a plan cut short by it is named, and no
            # plan says a session runs (the review of F33: 45.5 read "This session runs 45 minutes", then the request failed).
            $report.printed | Should -Not -Match 'too soon|minutes asked|This session runs'
        }
        if ($Scenario -eq 'askedstring') {
            # "90" goes as the int 90, which the runbook accepts (Test-DbHubControlRequest), not as text.
            $report.sent[0].durationMinutes | Should -BeOfType ([long])
            $report.sent[0].durationMinutes | Should -Be 90
        }
        if ($Scenario -eq 'stoppedend') {
            # A plain stop for whatever runs, then that session's history, with its metrics and window, after its telemetry.
            $report.sent[0].PSObject.Properties.Name | Should -Not -Contain 'sessionId'
            @($report.order) | Should -Be @('sent:stop', 'history:bbbbbbbb')
            $report.refs[0].args.SESSION_ID | Should -Be ('b' * 32)
            $report.refs[0].args.PSObject.Properties.Name | Should -Contain 'POSTGRES_METRICS'
            # Its window from its metrics, five minutes either side (ConvertFrom-Json reads the times as dates).
            ([datetime]$report.refs[0].args.WINDOW_START_UTC).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-11-14T12:20:00Z'
            ([datetime]$report.refs[0].args.WINDOW_END_UTC).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') | Should -Be '2026-11-14T14:00:00Z'
            # A runbook from before 2026-11-19 stopped it, so its status has no plan: its window from its metrics, with no
            # beats, and a Warning once, with the fix.
            $plan = $report.refs[0].args.SESSION_PLAN | ConvertFrom-Json
            @($plan.beats).Count | Should -Be 0
            (& $utc $plan.startUtc) | Should -Be '2026-11-14T12:25:00Z'
            (& $utc $plan.endUtc) | Should -Be '2026-11-14T13:55:00Z'
            ([regex]::Matches($report.printed, ('Warning: session bbbbbbbb''s history is saved ' + ($beatless -f 'the runbooks that stopped it are older than 2026-11-19 and kept no plan in its status', 'Fix: \./scripts/deploy\.ps1 republishes the runbooks, so a session''s stop keeps its plan\.')))).Count | Should -Be 1
        }
        if ($Scenario -eq 'stoppedstart') {
            # As its end would save it: no beats, since it had no end, and its window from its start to its stop.
            $plan = $report.refs[0].args.SESSION_PLAN | ConvertFrom-Json
            @($plan.beats).Count | Should -Be 0
            (& $utc $plan.startUtc) | Should -Be '2026-11-14T13:43:00Z'
            (& $utc $plan.endUtc) | Should -Be '2026-11-14T13:55:00Z'
            (& $utc $report.refs[0].args.WINDOW_START_UTC) | Should -Be '2026-11-14T13:38:00Z'
            $report.refs[0].args.PSObject.Properties.Name | Should -Not -Contain 'POSTGRES_METRICS'
            $report.printed | Should -Not -Match 'without its beats|no metrics for it'
        }
        if ($Scenario -eq 'stoppedlost') {
            $plan = $report.refs[0].args.SESSION_PLAN | ConvertFrom-Json
            @($plan.beats).Count | Should -Be 0
            ([regex]::Matches($report.printed, ('Warning: session bbbbbbbb''s history is saved ' + ($beatless -f 'the runbook didn''t find its plan when it stopped it \(another session''s status had replaced it, or it couldn''t be read\)', $noFix)))).Count | Should -Be 1
            $report.printed | Should -Not -Match 'deploy\.ps1 republishes'
        }
        if ($Scenario -in 'stoppedplan', 'stoppedplannometrics') {
            # Its plan from its stopped status (2026-11-19): its beats, the Database Agent beat, and its own window, not its
            # metrics' (from 10 minutes before it).
            @($report.order) | Should -Be @('sent:stop', 'history:bbbbbbbb')
            $report.refs[0].args.SESSION_ID | Should -Be ('b' * 32)
            $plan = $report.refs[0].args.SESSION_PLAN | ConvertFrom-Json
            @($plan.beats).Count | Should -BeGreaterThan 20
            @($plan.beats | Where-Object { $_.PSObject.Properties.Name -contains 'agent' -and $_.agent }).Count | Should -Be 1
            (& $utc $plan.startUtc) | Should -Be '2026-11-14T12:25:00Z'
            (& $utc $report.refs[0].args.WINDOW_START_UTC) | Should -Be '2026-11-14T12:20:00Z'
            $report.printed | Should -Not -Match 'without its beats|no metrics for it'
            # T4's metrics when the vault's are this session's.
            ($report.refs[0].args.PSObject.Properties.Name -contains 'POSTGRES_METRICS') | Should -Be ($Scenario -eq 'stoppedplan')
        }
        if ($Scenario -eq 'endedrunning') {
            $report.sent[0].sessionId | Should -Be ('c' * 32)
            $report.refs[0].args.SESSION_ID | Should -Be ('c' * 32)
        }
        if ($Scenario -eq 'stoppedold') {
            $report.printed | Should -Not -Match 'already stopped'
        }
    }

    It 'passes the Incident RCA''s evidence to the history in <Case> (ADR 0031)' -ForEach @(
        @{ Case = 'a session''s end: the bundles read from the metrics secret''s earlier versions, staged, and the file gone after the run'; Scenario = 'sessionrca'; Refs = 1 }
        @{ Case = 'a session whose activity notebook is from before the Incident RCA: a Warning with the fix, and the file deleted'; Scenario = 'sessionrcaold'; Refs = 1 }
        @{ Case = 'a session whose start exported an earlier session''s evidence: that evidence saved alone under its ID'; Scenario = 'earlierrca'; Refs = 2 }
        @{ Case = 'an earlier session whose metrics hold only its evidence: saved right after the start, as a leftover'; Scenario = 'leftoverrca'; Refs = 2 }
        @{ Case = 'a bundle the vault refuses: the whole documents it could read, and which it couldn''t'; Scenario = 'bundlefail'; Refs = 1 }
    ) {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario $Scenario -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.leaked | Should -BeFalse
        @($report.refs).Count | Should -Be $Refs
        $session = $report.sent[0].sessionId
        $fixture = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'rca/fixtures/rca-evidence.parameter.json') -Raw | ConvertFrom-Json
        # The staged file: one RCA_EVIDENCE document (rca/transport.schema.json, parameter) per history, named in the inbox.
        foreach ($staged in @($report.staged)) {
            $staged.name | Should -Match '^Files/rca/inbox/\d{8}T\d{6}Z-[0-9a-f]{8}-[0-9a-f]{8}\.json$'
            $staged.document.kind | Should -Be 'ContosoCare.RcaEvidenceParts'
            $staged.document.version | Should -Be 1
            @($staged.document.parts).Count | Should -BeLessOrEqual 64
        }
        # Nothing is left in the inbox: the activity notebook deletes what it reads, and the control what it doesn't.
        @($report.files) | Should -BeNullOrEmpty
        $report.printed | Should -Not -Match 'Bearer|simulated-keyvault'
        switch ($Scenario) {
            'sessionrca' {
                $report.refs[0].args.SESSION_ID | Should -Be $session
                $report.refs[0].args.RCA_EVIDENCE_FILE | Should -Be $report.staged[0].name
                @($report.staged[0].document.parts) | Should -Be @($fixture.parts)
                $report.staged[0].document.sessionId | Should -Be $session
                @($report.vaultReads) | Should -Be @('dbhub-session-metrics/11111111', 'dbhub-session-metrics/22222222')
                $report.printed | Should -Match 'RCA\.EXPORT Pass: 2 evidence documents in 4 parts from sqlvm01\.'
                $report.printed | Should -Match 'RCA\.CAPTURE\.T1 Pass: T1: captured from 16:50 to 17:05 UTC\.'
                $report.printed | Should -Match ('Session {0}''s RCA evidence: 2 document\(s\) in 4 part\(s\), passed to its history\.' -f $session.Substring(0, 8))
                $report.printed | Should -Match 'Pass: the history is saved; the report and the Insights app show it after their next refresh\.\s+RCA\.EVIDENCE Pass: Wrote 2 evidence document\(s\) from sqlvm01\.'
            }
            'sessionrcaold' {
                $report.refs[0].args.RCA_EVIDENCE_FILE | Should -Be $report.staged[0].name
                $report.printed | Should -Match 'RCA\.EVIDENCE Warning: NB_DatabaseHub_LiveActivity in the demo workspace didn''t read the session''s RCA evidence: its copy is from before the Incident RCA \(ADR 0031\)\. Fix: \./scripts/deploy\.ps1 updates it when fabric\.importNotebooks is true, or \./scripts/configure-fabric\.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity updates it alone; then Run all again saves the evidence' -Because 'Run all''s line for an older notebook is labeled RCA.EVIDENCE, as its other evidence lines are'
            }
            'earlierrca' {
                # The session's own evidence first, then the earlier session's alone: RCA_ONLY, with SAVE_RESULTS False, so a
                # copy of the activity notebook from before the Incident RCA saves nothing.
                $report.refs[0].args.SESSION_ID | Should -Be $session
                $report.refs[1].args.SESSION_ID | Should -Be ('d' * 32)
                $report.refs[1].args.RCA_ONLY | Should -BeTrue
                $report.refs[1].args.SAVE_RESULTS | Should -BeFalse
                $report.refs[1].args.RCA_EVIDENCE_FILE | Should -Be $report.staged[1].name
                @($report.staged[1].document.parts) | Should -Be @($fixture.parts[0..1])
                $report.staged[1].document.sessionId | Should -Be ('d' * 32)
                $report.refs[1].args.PSObject.Properties.Name | Should -Not -Contain 'SESSION_PLAN'
                $report.printed | Should -Match 'Session dddddddd''s RCA evidence, which a later session''s start exported from the VMs, is saved under that session''s ID\.'
            }
            'leftoverrca' {
                @($report.order) | Should -Be @('sent:session', 'history:eeeeeeee', 'validator', 'sent:stop', ('history:{0}' -f $session.Substring(0, 8)))
                $report.refs[0].args.SESSION_ID | Should -Be ('e' * 32)
                $report.refs[0].args.RCA_EVIDENCE_FILE | Should -Be $report.staged[0].name
                $report.refs[0].args.PSObject.Properties.Name | Should -Not -Contain 'POSTGRES_METRICS'
                $report.refs[0].args.PSObject.Properties.Name | Should -Not -Contain 'COSMOS_METRICS'
                $report.printed | Should -Match 'An earlier session \(eeeeeeee, .*\) left its metrics in the vault'
            }
            'bundlefail' {
                @($report.staged[0].document.parts) | Should -Be @($fixture.parts[0..1])
                $report.staged[0].document.status | Should -Be 'Warning'
                $report.printed | Should -Match ('Session {0}''s RCA evidence: 1 document\(s\) in 2 part\(s\), passed to its history \(bundle 22222222: the control vault answered HTTP 403; 20261120T170000Z-sqlvm01-0002: its bundles don''t hold all its parts\)\.' -f $session.Substring(0, 8))
            }
        }
    }

    It 'reads the metrics'' version that the stop wrote, by its ID, when a re-check''s bundle is the latest, in <Case> (review of 15ad76d)' -ForEach @(
        @{ Case = 'a session''s end'; Scenario = 'sessionrcalate'; Refs = 1; Session = '' }
        @{ Case = 'a session''s end whose version the vault refuses: the latest, with a Warning'; Scenario = 'sessionrcapinfail'; Refs = 1; Session = '' }
        @{ Case = 'Stop now after a session that already stopped'; Scenario = 'stoppedlate'; Refs = 1; Session = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
        @{ Case = 'the next Run all''s pre-check of an earlier session'; Scenario = 'leftoverlate'; Refs = 2; Session = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }
    ) {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario $Scenario -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.leaked | Should -BeFalse
        @($report.refs).Count | Should -Be $Refs
        $expected = $(if ($Session) { $Session } else { $report.sent[0].sessionId })
        $report.refs[0].args.SESSION_ID | Should -Be $expected
        # T4's metrics, from the version the stop wrote, not the re-check's bundle after it.
        $report.refs[0].args.PSObject.Properties.Name | Should -Contain 'POSTGRES_METRICS'
        ($report.refs[0].args.POSTGRES_METRICS | ConvertFrom-Json).sessionId | Should -Be $expected
        $report.printed | Should -Not -Match 'Bearer|simulated-keyvault'
        switch ($Scenario) {
            'sessionrcalate' {
                @($report.vaultReads) | Should -Be @('dbhub-session-metrics/44444444', 'dbhub-session-metrics/11111111', 'dbhub-session-metrics/22222222')
                $fixture = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'rca/fixtures/rca-evidence.parameter.json') -Raw | ConvertFrom-Json
                $report.refs[0].args.RCA_EVIDENCE_FILE | Should -Be $report.staged[0].name
                @($report.staged[0].document.parts) | Should -Be @($fixture.parts)
                $report.printed | Should -Not -Match 'Warning: the history''s metrics version'
            }
            'sessionrcapinfail' {
                $report.printed | Should -Match 'Warning: the history''s metrics version 44444444, which the stop wrote, couldn''t be read \(the control vault answered HTTP 403\), so the vault''s latest is used\.'
                $report.refs[0].args.RCA_EVIDENCE_FILE | Should -Be $report.staged[0].name
            }
            'stoppedlate' {
                @($report.vaultReads) | Should -Be @('dbhub-session-metrics/55555555')
                @($report.order) | Should -Be @('sent:stop', 'history:bbbbbbbb')
            }
            'leftoverlate' {
                @($report.vaultReads) | Should -Be @('dbhub-session-metrics/55555555')
                $report.printed | Should -Match 'An earlier session \(eeeeeeee, .*\) left its metrics in the vault: its history is saved right after this session''s start is sent'
            }
        }
    }

    It 'says what became of the Incident RCA''s evidence that a history job got, as far as Run all can tell: <Case> (ADR 0031, re-check of d2067d69)' -ForEach @(
        @{ Case = 'a job queued until Run all''s Spark session ends'; Scenario = 'rcajobqueued'; Files = 1; Says = 'RCA\.EVIDENCE Warning: Run all can''t tell whether session {0}''s RCA evidence is saved: the history job is queued until this notebook''s Spark session ends\. Fix: once the job has run, the job''s run in the demo workspace''s Monitor hub has its RCA\.EVIDENCE line; when it isn''t Pass, or the job failed, Run all again saves the evidence while its index is in the control vault \(until the next session ends\)\.' }
        @{ Case = 'a job that ended and deleted the file'; Scenario = 'rcajobdone'; Files = 0; Says = 'Pass: the history is saved; the report and the Insights app show it after their next refresh\.\s+RCA\.EVIDENCE Pass: the history job read session {0}''s RCA evidence and deleted its file, as it does once it has written it; the job''s run in the demo workspace''s Monitor hub has its RCA\.EVIDENCE line, with any document it skipped\.' }
        @{ Case = 'a job that ended and left the file'; Scenario = 'rcajobold'; Files = 0; Says = 'RCA\.EVIDENCE Warning: the history job ended without writing session {0}''s RCA evidence: NB_DatabaseHub_LiveActivity in the demo workspace is from before the Incident RCA, or it wrote none of it \(the job''s run in the demo workspace''s Monitor hub has its RCA\.EVIDENCE line\)\. Fix: when its copy is from before the Incident RCA, \./scripts/deploy\.ps1 updates it when fabric\.importNotebooks is true, or \./scripts/configure-fabric\.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity updates it alone; then Run all again saves the evidence' }
        @{ Case = 'a job that ended, whose staged file couldn''t be checked (review of 37a546bc)'; Scenario = 'rcajobunchecked'; Files = 1; Says = 'RCA\.EVIDENCE Warning: Run all can''t tell whether session {0}''s RCA evidence is saved: the history job is Completed, but whether it deleted its staged file couldn''t be checked\. Fix: the job''s run in the demo workspace''s Monitor hub has its RCA\.EVIDENCE line; when it isn''t Pass, Run all again saves the evidence while its index is in the control vault \(until the next session ends\)\.' }
        @{ Case = 'a job that failed'; Scenario = 'rcajobfailed'; Files = 0; Says = 'Warning: the history job is Failed: Notebook execution failed in cell 4\.[^\n]*\s+RCA\.EVIDENCE Warning: session {0}''s RCA evidence wasn''t saved: the history job is Failed, so nothing read it\. Fix: Run all again saves the evidence while its index is in the control vault \(until the next session ends\)\.' }
        @{ Case = 'an earlier session''s history saved as a job that Run all doesn''t look at'; Scenario = 'rcaleftoverjob'; Files = 1; Says = 'RCA\.EVIDENCE Warning: Run all can''t tell whether session eeeeeeee''s RCA evidence is saved: Run all doesn''t wait for the history job\. Fix: once the job has run' }
    ) {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # At d2067d69, Run all printed nothing about the evidence on the job path, and the inbox's day-old sweep later deleted a
        # file the job left.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario $Scenario -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.leaked | Should -BeFalse
        $job = @($report.jobs | Where-Object { $_.PSObject.Properties.Name -contains 'RCA_EVIDENCE_FILE' })
        $job.Count | Should -Be 1
        $job[0].RCA_EVIDENCE_FILE | Should -Match '^Files/rca/inbox/\d{8}T\d{6}Z-[0-9a-f]{8}-[0-9a-f]{8}\.json$'
        $report.printed | Should -Match ($Says -f $report.sent[0].sessionId.Substring(0, 8))
        @([regex]::Matches($report.printed, '(?m)^RCA\.EVIDENCE (Pass|Warning):')).Count | Should -Be 1
        # A job that will still run keeps its file; one that ended, or won't run, leaves nothing in the inbox.
        @($report.files).Count | Should -Be $Files
        if ($Files -gt 0) {
            $report.files[0] | Should -BeLike ('*/' + $job[0].RCA_EVIDENCE_FILE)
        }
    }

    It 'says when the control''s runbook is from before the Incident RCA, and passes no evidence (ADR 0031)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # The simulator's runbook writes a stop status without rca or rcaLines, as a runbook from before ADR 0031 does.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'capped' -Start '2026-11-14T17:45:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.printed | Should -Match 'RCA\.EXPORT Warning: the Incident RCA''s evidence wasn''t exported: the control''s runbook is from before it \(ADR 0031\)\. Fix: \./scripts/deploy\.ps1 republishes the runbooks; the evidence stays on the VMs, and the next session''s start exports it\.'
        $report.refs[0].args.PSObject.Properties.Name | Should -Not -Contain 'RCA_EVIDENCE_FILE'
        @($report.staged) | Should -BeNullOrEmpty
        @($report.vaultReads) | Should -BeNullOrEmpty
    }

    It 'passes the Query Store sidecars to the history, and reads what its acknowledgement says, in <Case> (2026-11-23, Run all''s path for the sidecars)' -ForEach @(
        @{ Case = 'a session''s end: the pointer, the index, and the bundle read by version, staged whole, the payload gone, and the acknowledgement kept for the next start'; Scenario = 'sessionqs' }
        @{ Case = 'a session''s end whose acknowledgement skips a sidecar: a Warning, and the payload stays'; Scenario = 'sessionqsskip' }
        @{ Case = 'a session''s end whose activity notebook writes no acknowledgement: a Warning, and the payload stays'; Scenario = 'sessionqsnoack' }
        @{ Case = 'a session''s end whose history is a queued job: Run all can''t tell yet, and the payload stays for the job'; Scenario = 'sessionqsjob' }
        @{ Case = 'a session''s end whose history job the capacity refuses: the payload nothing read goes'; Scenario = 'sessionqsfull' }
        @{ Case = 'an earlier session''s history, which the pre-check saves as a leftover'; Scenario = 'leftoverqs' }
        @{ Case = 'Stop now after a session that already stopped'; Scenario = 'stoppedqs' }
        @{ Case = 'an even earlier session''s evidence saved alone, when the pre-check doesn''t save the earlier session''s history'; Scenario = 'earlierqs' }
    ) {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario $Scenario -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.leaked | Should -BeFalse
        $report.printed | Should -Not -Match 'Bearer|simulated-keyvault|couldn''t stage'
        $bundle = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'rca/fixtures/sidecar-bundle.json') -Raw | ConvertFrom-Json
        $session = switch ($Scenario) { 'leftoverqs' { 'e' * 32 } { $_ -in 'stoppedqs', 'earlierqs' } { 'b' * 32 } default { $report.sent[0].sessionId } }
        # One payload for the history that took the sidecars: rca/transport.schema.json's sidecarParameter, with every part
        # line of the stop's sidecar bundle, the session's whole sidecars. Every run that got it got the same one.
        @($report.puts).Count | Should -Be 1
        $payload = $report.puts[0].name
        $payload | Should -Match '^Files/rca/inbox/sidecar-\d{8}T\d{6}Z-runall-[0-9a-f]{8}\.json$'
        foreach ($run in @(@($report.refs | ForEach-Object args) + @($report.jobs) | Where-Object { $_.PSObject.Properties.Name -contains 'RCA_SIDECAR_FILE' })) {
            $run.RCA_SIDECAR_FILE | Should -BeExactly $payload
        }
        # Every history that ran, or was asked to, got it; the refused job in "sessionqsfull" never started.
        $got = @(@($report.refs | ForEach-Object args) + @($report.jobs) | Where-Object { $_.PSObject.Properties.Name -contains 'RCA_SIDECAR_FILE' })
        $got.Count | Should -Be $(if ($Scenario -eq 'sessionqsjob') { 2 } elseif ($Scenario -eq 'sessionqsfull') { 0 } else { 1 })
        $report.puts[0].document.kind | Should -Be 'ContosoCare.RcaSidecarParts'
        $report.puts[0].document.sessionId | Should -Be $session
        @($report.puts[0].document.parts) | Should -Be @($bundle.parts)
        Test-Json -Json ($report.puts[0].document | ConvertTo-Json -Depth 8 -Compress) -SchemaFile (Join-Path -Path $repoRoot -ChildPath 'rca/transport.schema.json') | Should -BeTrue
        $report.printed | Should -Match ('Session {0}''s Query Store evidence: 2 sidecar\(s\) in 3 part\(s\), passed to its history\.' -f $session.Substring(0, 8))
        @([regex]::Matches($report.printed, '(?m)^RCA\.SIDECAR (Pass|Warning):')).Count | Should -Be 1
        $inbox = @($report.files | Where-Object { $_ -like '*/Files/rca/inbox/*' })
        $what = 'session {0}''s 2 Query Store sidecar\(s\)' -f $session.Substring(0, 8)
        switch ($Scenario) {
            'sessionqs' {
                # The metrics' version the stop names, the evidence's bundles as before, then the sidecars' index and the
                # bundle it lists, each by version.
                @($report.vaultReads) | Should -Be @('dbhub-session-metrics/99999999', 'dbhub-session-metrics/11111111', 'dbhub-session-metrics/22222222',
                    'dbhub-session-metrics/a0bd446e', 'dbhub-session-metrics/8af9856a')
                # The activity notebook's definition, once, through Get Item Definition's long-running operation.
                @($report.defReads) | Should -Be @('definition', 'state', 'state', 'result')
                $report.refs[0].args.SESSION_ID | Should -Be $session
                $report.refs[0].args.RCA_SIDECAR_FILE | Should -BeExactly $payload
                # The evidence goes with it, exactly as before.
                $report.refs[0].args.RCA_EVIDENCE_FILE | Should -BeExactly $report.staged[0].name
                $fixture = Get-Content -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'rca/fixtures/rca-evidence.parameter.json') -Raw | ConvertFrom-Json
                @($report.staged[0].document.parts) | Should -Be @($fixture.parts)
                $report.printed | Should -Match ('Session {0}''s RCA evidence: 2 document\(s\) in 4 part\(s\), passed to its history\.\s+Session {0}''s Query Store evidence: 2 sidecar\(s\) in 3 part\(s\), passed to its history\.' -f $session.Substring(0, 8))
                $report.printed | Should -Match ('Pass: the history is saved; the report and the Insights app show it after their next refresh\.\s+RCA\.EVIDENCE Pass: Wrote 2 evidence document\(s\) from sqlvm01\.\s+RCA\.SIDECAR Pass: the history took {0}: 2 written, 0 already in it\. The next session''s start acknowledges them on the VMs, which then stop offering them\.' -f $what)
                $inbox | Should -BeNullOrEmpty
                @($report.acks.PSObject.Properties.Name) | Should -Be @(('Files/rca/acks/{0}.ack.json' -f ($payload -replace '^Files/rca/inbox/|\.json$', '')))
            }
            'sessionqsskip' {
                $report.printed | Should -Match ('RCA\.SIDECAR Warning: the history took 1 of {0} \(1 written, 0 already in it\) and skipped 1: 20261120T170000Z-sqlvm01-0002-sidecar: its SHA-256 doesn''t match\. The skipped ones stay on the VMs, which offer them again at the next session''s exports, and the payload stays until a later run writes them\.' -f $what)
                $inbox | Should -Be @($report.files | Where-Object { $_ -like ('*/' + $payload) })
                $inbox.Count | Should -Be 1
            }
            'sessionqsnoack' {
                $report.printed | Should -Match ('RCA\.SIDECAR Warning: NB_DatabaseHub_LiveActivity didn''t acknowledge {0}: it wrote no acknowledgement of them, so they stay pending on the VMs, which offer them again at the next session''s exports, and their payload stays\. Fix: its RCA\.SIDECAR finding in analysis_findings says why; when its copy in the demo workspace is from before the RCA sidecar, \./scripts/configure-fabric\.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity -RunLiveActivity updates it\.' -f $what)
                $inbox.Count | Should -Be 1
                $inbox[0] | Should -BeLike ('*/' + $payload)
            }
            'sessionqsjob' {
                $report.jobs[0].RCA_SIDECAR_FILE | Should -BeExactly $payload
                $report.printed | Should -Match ('RCA\.SIDECAR Warning: Run all can''t tell yet whether {0} are saved: the history job is queued until this notebook''s Spark session ends\. Fix: none needed: the next session''s start acknowledges on the VMs those the job''s acknowledgement says it wrote' -f $what)
                $inbox.Count | Should -Be 1
                $inbox[0] | Should -BeLike ('*/' + $payload)
            }
            'sessionqsfull' {
                @($report.jobs) | Should -BeNullOrEmpty
                $report.printed | Should -Match ('RCA\.SIDECAR Warning: {0} weren''t saved: the history didn''t start, so nothing read them, and their payload is deleted\. Fix: none needed: they stay on the VMs, which offer them again at the next session''s exports, and Run all again saves them while their index is in the control vault' -f $what)
                $inbox | Should -BeNullOrEmpty
            }
            'leftoverqs' {
                @($report.order) | Should -Be @('sent:session', 'history:eeeeeeee', 'validator', 'sent:stop', ('history:{0}' -f $report.sent[0].sessionId.Substring(0, 8)))
                $report.refs[0].args.RCA_SIDECAR_FILE | Should -BeExactly $payload
                $report.refs[1].args.PSObject.Properties.Name | Should -Not -Contain 'RCA_SIDECAR_FILE' -Because 'a later history of the same Run all doesn''t pass the same sidecars again'
                $report.printed | Should -Match ('RCA\.SIDECAR Pass: the history took {0}: 2 written, 0 already in it\.' -f $what)
            }
            'stoppedqs' {
                @($report.order) | Should -Be @('sent:stop', 'history:bbbbbbbb')
                $report.refs[0].args.SESSION_ID | Should -Be $session
                $report.refs[0].args.RCA_SIDECAR_FILE | Should -BeExactly $payload
                @($report.vaultReads) | Should -Be @('dbhub-session-metrics/55555555', 'dbhub-session-metrics/a0bd446e', 'dbhub-session-metrics/8af9856a')
            }
            'earlierqs' {
                # The earlier session's history isn't saved (it has no T4 series), so its sidecars go with the even earlier
                # session's evidence, saved alone: the activity notebook writes each under its own session.
                $report.refs[0].args.SESSION_ID | Should -Be ('d' * 32)
                $report.refs[0].args.RCA_ONLY | Should -BeTrue
                $report.refs[0].args.RCA_EVIDENCE_FILE | Should -Not -BeNullOrEmpty
                $report.refs[0].args.RCA_SIDECAR_FILE | Should -BeExactly $payload
                $report.refs[1].args.PSObject.Properties.Name | Should -Not -Contain 'RCA_SIDECAR_FILE'
                $report.printed | Should -Match 'RCA\.EVIDENCE Pass: Wrote 1 evidence document\(s\) from sqlvm01\.'
            }
        }
    }

    It 'stages no sidecar when the workspace''s activity notebook doesn''t declare RCA_SIDECAR_FILE, and says how to update it (2026-11-23)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # fabric.importNotebooks false keeps the workspace's copy of the activity notebook, which may be from before the sidecar.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'sessionqsold' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.defReads) | Should -Be @('definition')
        @($report.puts) | Should -BeNullOrEmpty
        $report.refs[0].args.PSObject.Properties.Name | Should -Not -Contain 'RCA_SIDECAR_FILE'
        # Nothing is read for sidecars that no history takes.
        @($report.vaultReads) | Should -Be @('dbhub-session-metrics/99999999')
        $report.printed | Should -Match ('RCA\.SIDECAR Warning: session {0}''s Query Store evidence \(2 sidecar\(s\)\) wasn''t passed to its history: NB_DatabaseHub_LiveActivity in the demo workspace doesn''t declare RCA_SIDECAR_FILE, because its copy is from before the RCA sidecar \(fabric\.importNotebooks false keeps it\)\. The sidecars stay on the VMs, which offer them again at the next session''s exports\. Fix: \./scripts/configure-fabric\.ps1 -SkipHubChecks -Notebook NB_DatabaseHub_LiveActivity -RunLiveActivity updates it; the next Run all then saves them\.' -f $report.sent[0].sessionId.Substring(0, 8))
        @([regex]::Matches($report.printed, '(?m)^RCA\.SIDECAR ')).Count | Should -Be 1
        @($report.files) | Should -BeNullOrEmpty
    }

    It 'acknowledges on the next start what Run all''s acknowledgements say was written, and deletes each once the start''s status says it sent all of it (2026-11-23)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'qsacks' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $ids = @('20261113T140000Z-sqlvm01-0001-sidecar', '20261113T141500Z-sqlvm01-0002-sidecar', '20261113T144500Z-arcsql01-0001-sidecar')
        # The start's rcaAcks: written and already, oldest acknowledgement first, each once; never a skipped sidecar, the
        # scripts' -script- acknowledgement, or one that names another payload.
        @($report.sent | ForEach-Object action) | Should -Be @('session', 'stop')
        $report.sent[0].rcaAcks.kind | Should -Be 'ContosoCare.RcaAckRequest'
        $report.sent[0].rcaAcks.version | Should -Be 1
        @($report.sent[0].rcaAcks.documents) | Should -Be $ids
        Test-Json -Json ($report.sent[0].rcaAcks | ConvertTo-Json -Depth 4 -Compress) -SchemaFile (Join-Path -Path $repoRoot -ChildPath 'rca/transport.schema.json') | Should -BeTrue
        $report.sent[1].PSObject.Properties.Name | Should -Not -Contain 'rcaAcks'
        # The start's status sent the first two and left T2's: the acknowledgement it sent all of goes, and so does one with
        # only a skipped sidecar, which has none to send; the rest stay.
        $report.printed | Should -Match 'RCA\.SIDECAR\.ACK Warning: 2 sidecars acknowledged on sqlvm01, before the start''s exports; 1 left: arcsql01 didn''t answer\.\s+Run all''s sidecar acknowledgements: 2 done and deleted, 1 kept until this session''s re-checks or its stop, or the next start, send the rest\.'
        @([regex]::Matches($report.printed, '(?m)^RCA\.SIDECAR\.ACK ')).Count | Should -Be 1
        # The one more than 30 days old is gone too, unsent.
        @($report.acks.PSObject.Properties.Name | Sort-Object) | Should -Be @(
            'Files/rca/acks/sidecar-20261113T160000Z-runall-4e5f6a7b.ack.json'
            'Files/rca/acks/sidecar-20261113T170000Z-script-8c9d0e1f.ack.json'
            'Files/rca/acks/sidecar-20261113T180000Z-runall-2a3b4c5d.ack.json'
        )
    }

    It 'shows the session''s acknowledgement result again when a later export sends what its start left, and deletes what it completes: <Case> (option 2, 2026-11-23)' -ForEach @(
        @{ Case = 'a re-check during the session, which the live view reads'; Scenario = 'qsacksrecheck'; By = 'a re-check'; Kept = 'until this session''s re-checks or its stop, or the next start, send the rest'; First = 'RCA\.SIDECAR\.ACK Warning: 2 sidecars acknowledged on sqlvm01, before the start''s exports; 1 left: arcsql01 didn''t answer\.' }
        @{ Case = 'the stop, whose status is final'; Scenario = 'qsacksstop'; By = 'the stop'; Kept = 'for the next start'; First = 'RCA\.SIDECAR\.ACK Warning: 2 sidecars acknowledged on sqlvm01, before the start''s exports; 1 left: arcsql01 didn''t answer\.' }
        @{ Case = 'a re-check after a start whose step said its result, which doesn''t stand for the later one'; Scenario = 'qsacksstepped'; By = 'a re-check'; Kept = 'until this session''s re-checks or its stop, or the next start, send the rest'; First = 'RCA\.SIDECAR\.ACK Warning 2 of 3 sidecar acknowledgement\(s\) sent before the start''s exports \(2 on sqlvm01\); the rest weren''t: arcsql01 didn''t answer\.' }
    ) {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # The start leaves T2's ID (its host didn't answer); the session's next warm export sends it, and writes rcaAcks again,
        # only moving IDs from left to sent. The stopped status keeps the last result (Write-DbHubStopStatus).
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario $Scenario -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.sent[0].rcaAcks.documents) | Should -Be @('20261113T140000Z-sqlvm01-0001-sidecar', '20261113T141500Z-sqlvm01-0002-sidecar', '20261113T144500Z-arcsql01-0001-sidecar')
        # The start's own result first, as before.
        $report.printed | Should -Match $First
        $report.printed | Should -Match 'Run all''s sidecar acknowledgements: 2 done and deleted, 1 kept until this session''s re-checks or its stop, or the next start, send the rest\.'
        # Then the later export's, once: the acknowledgement it completes goes, and the stop's copy of it shows nothing new.
        $later = 'RCA.SIDECAR.ACK Pass: 3 sidecar acknowledgement(s) sent: 2 before the start''s sidecar fetch, 1 at {0}.' -f $By
        $report.printed | Should -Match ('{0}\s+Run all''s sidecar acknowledgements: 1 done and deleted, 0 kept {1}\.' -f [regex]::Escape($later), [regex]::Escape($Kept))
        @([regex]::Matches($report.printed, 'RCA\.SIDECAR\.ACK')).Count | Should -Be 2
        $stop = $report.printed.IndexOf('=== The session''s end: stopping session')
        $stop | Should -BeGreaterThan 0
        if ($Scenario -eq 'qsacksstop') {
            $report.printed.IndexOf($later) | Should -BeGreaterThan $stop -Because 'finish_session reads the stopped status''s result'
        }
        else {
            $report.printed.IndexOf($later) | Should -BeLessThan $stop -Because 'the live view reads the re-check''s result while the session runs'
        }
        @($report.acks.PSObject.Properties.Name | Sort-Object) | Should -Be @(
            'Files/rca/acks/sidecar-20261113T170000Z-script-8c9d0e1f.ack.json'
            'Files/rca/acks/sidecar-20261113T180000Z-runall-2a3b4c5d.ack.json'
        )
    }

    It 'deletes, quietly, what a stopped session''s final acknowledgement result says was sent, outside that session''s follow: <Case> (option 2, 2026-11-23)' -ForEach @(
        @{ Case = 'Stop now when the session stopped already'; Scenario = 'stoppedqsacks' }
        @{ Case = 'the next Run all''s pre-check, before its start carries them again'; Scenario = 'qsacksprecheck' }
    ) {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # The stopped status's rcaAcks is final: its stop sent T2's ID, which its start left. Two of Run all's acknowledgements
        # are done by it, and a later save's rides on the next start.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario $Scenario -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $done = 'Run all''s sidecar acknowledgements: 2 done and deleted, 1 kept for the next start.'
        $report.printed | Should -Match ([regex]::Escape($done))
        switch ($Scenario) {
            'stoppedqsacks' {
                $report.printed | Should -Not -Match 'RCA\.SIDECAR\.ACK' -Because 'Stop now doesn''t follow that session'
                @($report.acks.PSObject.Properties.Name) | Should -Be @('Files/rca/acks/sidecar-20261113T190000Z-runall-5d6e7f80.ack.json')
            }
            'qsacksprecheck' {
                # Before this start's request, which then carries only the later save's sidecar; only its result shows.
                $report.printed.IndexOf($done) | Should -BeLessThan $report.printed.IndexOf(': asking the runbook to start it.')
                @($report.sent[0].rcaAcks.documents) | Should -Be @('20261113T150000Z-sqlvm01-0004-sidecar')
                @([regex]::Matches($report.printed, '(?m)^RCA\.SIDECAR\.ACK ')).Count | Should -Be 1
                $report.printed | Should -Match 'RCA\.SIDECAR\.ACK Pass: 1 sidecars acknowledged on sqlvm01, before the start''s exports\.'
                # Strict mode refuses .Name on an empty property list, so the names are read one by one.
                @($report.acks.PSObject.Properties | ForEach-Object -MemberName Name) | Should -BeNullOrEmpty
            }
        }
    }

    It 'sends whole acknowledgements, the oldest first, at most 64 sidecars on a start, and the rest wait in order (2026-11-23)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # Acknowledgements of 40, 30, and 1 sidecars: the 30 would pass 64, and the 1 waits behind them.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'qsackswhole' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $ids = @(0..39 | ForEach-Object { '20261113T10{0:d2}00Z-sqlvm01-{0:d4}-sidecar' -f $_ })
        @($report.sent[0].rcaAcks.documents) | Should -Be $ids
        $report.printed | Should -Match 'RCA\.SIDECAR\.ACK Pass: 40 sidecars acknowledged on sqlvm01, before the start''s exports\.\s+Run all''s sidecar acknowledgements: 1 done and deleted, 2 kept until this session''s re-checks or its stop, or the next start, send the rest\.'
        # The one that lists more than 64 sidecars doesn't follow the contract: none of it rides, it holds nothing back,
        # and it stays for the activity notebook's sweep.
        @($report.acks.PSObject.Properties.Name | Sort-Object) | Should -Be @(
            'Files/rca/acks/sidecar-20261113T140000Z-runall-0f0f0f0f.ack.json'
            'Files/rca/acks/sidecar-20261113T160000Z-runall-0b0b0b0b.ack.json'
            'Files/rca/acks/sidecar-20261113T170000Z-runall-0c0c0c0c.ack.json'
        )
    }

    It 'sends the start''s acknowledgements when one more than 30 days old can''t be deleted (2026-11-23)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'qsacksrmfail' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        @($report.sent[0].rcaAcks.documents) | Should -Be @('20261113T140000Z-sqlvm01-0001-sidecar', '20261113T141500Z-sqlvm01-0002-sidecar', '20261113T144500Z-arcsql01-0001-sidecar')
        $report.printed | Should -Not -Match 'couldn''t be read|weren''t all settled'
        $report.printed | Should -Match 'Run all''s sidecar acknowledgements: 2 done and deleted, 1 kept until this session''s re-checks or its stop, or the next start, send the rest\.'
        # It stays, unsent, for a later read or the activity notebook's sweep.
        @($report.acks.PSObject.Properties.Name) | Should -Contain 'Files/rca/acks/sidecar-20261001T120000Z-runall-1a2b3c4d.ack.json'
    }

    It 'waits for the start''s final acknowledgement result: an early one that sent nothing yet says nothing and deletes nothing (review of 90b4718c)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # T2c-1's runbook writes a result with nothing sent ("not yet") before it sends, then the real one with its step.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 'qsacksearly' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.printed | Should -Not -Match 'None of the \d+ sidecar acknowledgement'
        # Once: the real result's step, which the status's steps print; the notebook adds only what it deleted.
        @([regex]::Matches($report.printed, 'RCA\.SIDECAR\.ACK')).Count | Should -Be 1
        $report.printed | Should -Match 'RCA\.SIDECAR\.ACK Warning 2 of 3 sidecar acknowledgement\(s\) sent before the start''s exports \(2 on sqlvm01\); the rest weren''t: arcsql01 didn''t answer\.'
        $report.printed | Should -Match 'Run all''s sidecar acknowledgements: 2 done and deleted, 1 kept until this session''s re-checks or its stop, or the next start, send the rest\.'
        @($report.acks.PSObject.Properties.Name | Sort-Object) | Should -Be @(
            'Files/rca/acks/sidecar-20261113T160000Z-runall-4e5f6a7b.ack.json'
            'Files/rca/acks/sidecar-20261113T170000Z-script-8c9d0e1f.ack.json'
            'Files/rca/acks/sidecar-20261113T180000Z-runall-2a3b4c5d.ack.json'
        )
    }

    It 'says when the metrics'' sidecar pointer is one it can''t use, and nothing when it names no sidecar: <Case> (review of 90b4718c)' -ForEach @(
        @{ Case = 'another version'; Scenario = 'sessionqsbadversion'; Why = 'it''s ContosoCare\.RcaSidecarPointer version 2, not ContosoCare\.RcaSidecarPointer version 1' }
        @{ Case = 'an index that isn''t a version''s ID'; Scenario = 'sessionqsbadindex'; Why = 'its index isn''t a version''s ID' }
        @{ Case = 'a null index'; Scenario = 'sessionqsnullindex'; Why = '' }
    ) {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario $Scenario -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        # Nothing is read for sidecars, staged, or passed.
        @($report.defReads) | Should -BeNullOrEmpty
        @($report.puts) | Should -BeNullOrEmpty
        @($report.vaultReads) | Should -Be @('dbhub-session-metrics/99999999')
        $report.refs[0].args.PSObject.Properties.Name | Should -Not -Contain 'RCA_SIDECAR_FILE'
        if ($Why) {
            $report.printed | Should -Match ('RCA\.SIDECAR Warning: session {0}''s metrics point to its Query Store sidecars in a form this notebook doesn''t read \({1}\), so they weren''t passed to its history\. They stay on the VMs, which offer them again at the next session''s exports\. Fix: \./scripts/deploy\.ps1 updates the runbooks and this notebook together\.' -f $report.sent[0].sessionId.Substring(0, 8), $Why)
            @([regex]::Matches($report.printed, '(?m)^RCA\.SIDECAR ')).Count | Should -Be 1
        }
        else {
            $report.printed | Should -Not -Match 'RCA\.SIDECAR'
        }
    }

    It 'never takes the Query Store sidecars'' <Case> for the metrics: no ContosoCare.Rca* version is (2026-11-23)' -ForEach @(
        @{ Case = 'bundle'; Scenario = 'sessionqslate' }
        @{ Case = 'bundle index'; Scenario = 'sessionqslateindex' }
    ) {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        # The vault refuses the metrics' version the stop names, and the stop's sidecar bundle, or its index, is the
        # secret's latest: a control notebook from before the sidecar took it for the metrics.
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario $Scenario -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.printed | Should -Match 'Warning: the history''s metrics version 99999999, which the stop wrote, couldn''t be read \(the control vault answered HTTP 403\), so the vault''s latest is used; it''s the Query Store sidecars'' bundle or index, so the history has no T4 or T5 metrics and no RCA evidence\.'
        $report.refs[0].args.PSObject.Properties.Name | Should -Not -Contain 'POSTGRES_METRICS'
        $report.refs[0].args.PSObject.Properties.Name | Should -Not -Contain 'RCA_SIDECAR_FILE'
        @($report.puts) | Should -BeNullOrEmpty
    }

    It 'builds the start''s rcaAcks within the request''s limits: whole acknowledgements, the oldest first, distinct sidecar IDs, at most 64, and within 4,096 bytes (2026-11-23)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $helpers = Join-Path -Path $TestDrive -ChildPath 'helpers_part1_acks.py'
        Set-Content -LiteralPath $helpers -Encoding utf8NoBOM -Value (Get-Cell '# Helpers, part 1')
        $catalogFile = Join-Path -Path $TestDrive -ChildPath 'catalog_acks.json'
        Set-Content -LiteralPath $catalogFile -Encoding utf8NoBOM -Value $script:catalogJson
        $driver = Join-Path -Path $TestDrive -ChildPath 'build_acks.py'
        Set-Content -LiteralPath $driver -Encoding utf8NoBOM -Value @'
import json, sys
exec(open(sys.argv[1], encoding="utf-8").read())
catalog = load_catalog(open(sys.argv[2], encoding="utf-8").read())
sid = "0123456789abcdef0123456789abcdef"
ids = ["20261120T%02d%02d00Z-sqlvm01-%04d-sidecar" % (10 + n // 60, n % 60, n) for n in range(80)]
long_ids = ["20261120T%02d%02d00Z-%s-%04d-sidecar" % (10 + n // 60, n % 60, "x" * 40, n) for n in range(64)]
out = []
for kwargs in (dict(rca_acks=[ids[0], ids[1], ids[0]]), dict(rca_acks=ids), dict(rca_acks=long_ids), dict(rca_acks=[]),
               dict(rca_acks=["20261120T100000Z-sqlvm01-0001"]), dict(rca_acks=json.dumps(ids[:2])),
               # Acknowledgements go whole, the oldest first: 40, then 30, which would pass 64, so it and the 1 after it wait.
               dict(rca_acks=[ids[:40], ids[40:70], [ids[70]]]),
               # One whose sidecars an earlier one already carries adds only the others.
               dict(rca_acks=[[ids[0], ids[1]], [ids[1], ids[2]]]),
               # The contract's anchors: a trailing line feed isn't a sidecar ID.
               dict(rca_acks=[ids[0] + "\n"]),
               # One too big to fit on its own, by count or by bytes, is skipped, so it holds back none after it.
               dict(rca_acks=[ids[:70], ids[70:72]]),
               dict(rca_acks=[long_ids, [ids[0]]])):
    try:
        body = build_request("session", catalog=catalog, session_id=sid, duration_minutes=90, **kwargs)
        out.append({"ok": True, "body": body, "bytes": len(json.dumps(body, separators=(",", ":")).encode("utf-8"))})
    except ValueError as error:
        out.append({"ok": False, "error": str(error)})
try:
    build_request("stop", catalog=catalog, rca_acks=[ids[0]])
    out.append({"ok": True})
except ValueError as error:
    out.append({"ok": False, "error": str(error)})
# Run all's part 2 hands the start its pending acknowledgements, each whole, when it's given none.
pending_rca_acks = lambda: [[ids[5], ids[6]], [ids[7]]]
out.append({"ok": True, "body": build_request("session", catalog=catalog, session_id=sid, duration_minutes=90)})
out.append({"ok": True, "body": build_request("stop", catalog=catalog)})
print(json.dumps(out))
'@
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:python $driver $helpers $catalogFile 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $results = ($output | Select-Object -Last 1) | ConvertFrom-Json
        @($results | ForEach-Object ok) | Should -Be @($true, $true, $true, $true, $false, $true, $true, $true, $false, $true, $true, $false, $true, $true)
        $id = { param([int] $Number) '20261120T{0:d2}{1:d2}00Z-sqlvm01-{2:d4}-sidecar' -f (10 + [int][math]::Floor($Number / 60)), ($Number % 60), $Number }
        @($results[0].body.rcaAcks.documents) | Should -Be @((& $id 0), (& $id 1))
        @($results[1].body.rcaAcks.documents).Count | Should -Be 64
        @($results[1].body.rcaAcks.documents)[63] | Should -Be (& $id 63)
        # Long host names: as many as 4,096 bytes hold, the rest for a later start.
        $results[2].bytes | Should -BeLessOrEqual 4096
        @($results[2].body.rcaAcks.documents).Count | Should -BeGreaterThan 40
        @($results[2].body.rcaAcks.documents).Count | Should -BeLessThan 64
        $results[3].body.PSObject.Properties.Name | Should -Not -Contain 'rcaAcks'
        $results[4].error | Should -Match 'rca_acks takes sidecar IDs only'
        @($results[5].body.rcaAcks.documents) | Should -Be @((& $id 0), (& $id 1))
        @($results[6].body.rcaAcks.documents) | Should -Be @(0..39 | ForEach-Object { & $id $_ })
        @($results[7].body.rcaAcks.documents) | Should -Be @((& $id 0), (& $id 1), (& $id 2))
        $results[8].error | Should -Match 'rca_acks takes sidecar IDs only'
        @($results[9].body.rcaAcks.documents) | Should -Be @((& $id 70), (& $id 71))
        @($results[10].body.rcaAcks.documents) | Should -Be @((& $id 0))
        $results[11].error | Should -Match 'Only a session''s start acknowledges sidecars'
        @($results[12].body.rcaAcks.documents) | Should -Be @((& $id 5), (& $id 6), (& $id 7))
        $results[13].body.PSObject.Properties.Name | Should -Not -Contain 'rcaAcks'
        foreach ($result in @($results | Where-Object { $_.ok -and $_.body -and $_.body.PSObject.Properties.Name -contains 'rcaAcks' })) {
            Test-Json -Json ($result.body.rcaAcks | ConvertTo-Json -Depth 4 -Compress) -SchemaFile (Join-Path -Path $repoRoot -ChildPath 'rca/transport.schema.json') | Should -BeTrue
        }
    }

    It 'completes a session''s history that a cancel cut off before scenario_runs, with its plan, and the next Run all doesn''t analyze it again (2026-11-19, needs pandas)' {
        # The app's Stop now cancels the control's run while it saves a session's history, then runs Stop now. Each Run all
        # here runs every code cell of the imported control notebook against stand-ins for the vault, the webhook and its
        # runbook, Fabric, and a clock; its reference runs of NB_DatabaseHub_LiveActivity run that notebook's setup,
        # section 3, and persist cells against a lakehouse in memory, with stand-ins for its telemetry.
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
        $harness = Join-Path -Path $TestDrive -ChildPath 'resave_history.py'
        Set-Content -LiteralPath $harness -Encoding utf8NoBOM -Value @'
import contextlib, datetime as real_dt, io, json, re, sys, types
import pandas as pd

UTC = real_dt.timezone.utc
CONTROL = ["".join(cell["source"]) for cell in json.load(open(sys.argv[1], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
ACTIVITY = ["".join(cell["source"]) for cell in json.load(open(sys.argv[2], encoding="utf-8"))["cells"] if cell["cell_type"] == "code"]
SETUP = [cell for cell in ACTIVITY if cell.startswith(("# Parameters cell", "# Helpers, part"))]
SESSION_CELL = next(cell for cell in ACTIVITY if cell.startswith("# This session"))
PERSIST = next(cell for cell in ACTIVITY if cell.startswith("# Persist:"))

spark_types = types.ModuleType("pyspark.sql.types")
for name in ("StringType", "BooleanType", "TimestampType", "DoubleType", "LongType", "IntegerType", "DateType"):
    setattr(spark_types, name, type(name, (), {}))
spark_types.StructField = lambda name, kind, nullable: name
spark_types.StructType = list
pyspark_sql = types.ModuleType("pyspark.sql")
pyspark_sql.types = spark_types
sys.modules.update({"pyspark": types.ModuleType("pyspark"), "pyspark.sql": pyspark_sql, "pyspark.sql.types": spark_types})


class Clock:
    now = None
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


SECRET_URL = "https://example.webhook.azure-" + "automation.net/webhooks?token=" + "x" * 40
PLAN_FIELDS = ("acceptedUtc", "runEndUtc", "dispatchUtc", "t4", "replicaLag", "t5")
STATE = {}


def running_status(session_id, accepted, minutes):
    end = accepted + real_dt.timedelta(minutes=minutes)
    dispatch = accepted + real_dt.timedelta(minutes=4)
    return {"schemaVersion": 1, "sessionId": session_id, "phase": "running", "acceptedUtc": iso(accepted), "runEndUtc": iso(end),
            "autoStopUtc": iso(end + real_dt.timedelta(minutes=10)), "durationMinutes": minutes, "plannedMinutes": minutes,
            "names": {"resourceGroup": "rg-dbhub-demo", "deploymentId": "abc123", "sqlVm": "sqlvm01", "t2Guest": "arcsql01",
                      "t3Server": "azuresql01-abc123", "t3Database": "ContosoCare", "t4Server": "pgflex01-abc123", "t4Replica": "pgreplica01-abc123"},
            "dispatchUtc": {"T1": iso(dispatch), "T3": iso(dispatch), "T2": iso(dispatch + real_dt.timedelta(minutes=6)), "T4": iso(dispatch + real_dt.timedelta(minutes=5))},
            "t4": {"state": "Ready", "sku": "Standard_D4ds_v5", "tier": "GeneralPurpose"}, "replica": {"state": "Ready", "note": "", "fix": ""},
            "replicaLag": {"planned": True, "note": "", "fix": ""}, "steps": [], "message": ""}


def runbook(body):
    """The runbook behind the webhook: a session's start, whose status runs a minute later (vault_read), and its stop,
    which writes its stopped status and its metrics. The stopped status keeps the session's plan since 2026-11-19
    (Write-DbHubStopStatus); "oldRunbook" writes it as a runbook from before then did. A stop for no session changes
    nothing here."""
    vault = STATE["vault"]
    if body["action"] == "session":
        STATE.update(session=body["sessionId"], accepted=Clock.now, minutes=body["durationMinutes"])
        STATE["sessions"].append(body["sessionId"])
        vault["dbhub-session-status"] = json.dumps({"sessionId": body["sessionId"], "phase": "starting", "acceptedUtc": iso(Clock.now), "steps": []})
    elif body["action"] == "stop" and body.get("sessionId") and body["sessionId"] == STATE["session"]:
        running = json.loads(vault["dbhub-session-status"])
        stopped = {"schemaVersion": 1, "sessionId": body["sessionId"], "phase": "stopped", "updatedUtc": iso(Clock.now), "stoppedBy": "Stop now",
                   "done": ["T4 stopped", "sqlvm01 deallocated"], "failed": [], "metrics": {"status": "Pass", "message": "Azure Monitor metrics for the history."}}
        if not STATE["oldRunbook"]:
            stopped.update({key: running[key] for key in PLAN_FIELDS if key in running}, planKept=True)
        vault["dbhub-session-status"] = json.dumps(stopped)
        vault["dbhub-session-metrics"] = json.dumps({"version": 1, "sessionId": body["sessionId"], "capturedUtc": iso(Clock.now),
                                                     "startUtc": iso(STATE["accepted"] - real_dt.timedelta(minutes=10)), "endUtc": iso(Clock.now),
                                                     "windowMinutes": 100, "intervalMinutes": 1, "servers": [], "series": [{"metric": "cpu_percent"}]}, separators=(",", ":"))
        STATE["session"] = None


def vault_read(name):
    vault = STATE["vault"]
    if name == "dbhub-session-status" and STATE["session"]:
        current = json.loads(vault[name])
        if current.get("phase") == "starting" and Clock.now - STATE["accepted"] >= real_dt.timedelta(seconds=60):
            vault[name] = json.dumps(running_status(STATE["session"], STATE["accepted"], STATE["minutes"]))
    return vault[name]


class Response:
    def __init__(self, status, body=None):
        self.status_code, self._body, self.headers = status, body, {}
        self.content = b"" if body is None else json.dumps(body).encode("utf-8")

    def json(self):
        if self._body is None:
            raise ValueError("no body")
        return self._body


fake_requests = types.ModuleType("requests")


class RequestException(Exception):
    pass


def post(url, data=None, headers=None, timeout=None, json=None):
    if url == SECRET_URL:
        body = __import__("json").loads(data)
        STATE["sent"].append(body["action"])
        runbook(body)
        return Response(202, {"JobIds": ["job-%d" % len(STATE["sent"])]})
    if "arcdataservices.com" in url:
        return Response(401, {})
    raise AssertionError("unexpected POST " + url)


def request(method, url, json=None, headers=None, timeout=None):
    if method == "GET" and url.startswith("https://api.fabric.microsoft.com/v1/") and "/items?type=" in url:
        names = {"Notebook": [("NB_DatabaseHub_LiveActivity", "nb-1")], "Report": [("RPT_DatabaseHub_History", "RPT-1")], "KQLDashboard": []}[url.split("type=")[1]]
        return Response(200, {"value": [{"displayName": name, "id": item} for name, item in names]})
    raise AssertionError("unexpected %s %s" % (method, url))


fake_requests.RequestException, fake_requests.post, fake_requests.request = RequestException, post, request
sys.modules["requests"] = fake_requests


class Cancelled(BaseException):
    """The app's Stop now cancels the control's run where it is; no except Exception in either notebook catches it."""


class NotebookExit(BaseException):
    """notebookutils.notebook.exit: ends the activity notebook's run, and its value goes back to notebook.run's caller."""


class Rows:
    def __init__(self, lake, rows):
        self.lake, self.rows = lake, rows

    def filter(self, condition):
        column, value = re.fullmatch(r"(\w+) = '([^']*)'", condition).groups()
        return Rows(self.lake, [row for row in self.rows if row.get(column) == value])

    def limit(self, count):
        return Rows(self.lake, self.rows[:count])

    def count(self):
        return len(self.rows)


class Lake:
    def __init__(self):
        self.tables, self.log, self.cancel_at, self.columns = {}, [], None, {}
        self.catalog = types.SimpleNamespace(tableExists=lambda name: name in self.tables)
        self.conf = types.SimpleNamespace(get=lambda key: "UTC", set=lambda key, value: None)

    def table(self, name):
        rows = Rows(self, self.tables[name])
        rows.schema = types.SimpleNamespace(fields=[types.SimpleNamespace(name=column) for column, _ in self.columns[name]])
        return rows

    def createDataFrame(self, data, schema):
        lake, rows = self, [dict(zip(schema, values)) for values in data]

        class Writer:
            def format(self, name):
                return self

            def mode(self, name):
                return self

            def option(self, key, value):
                return self

            def saveAsTable(self, table):
                if table == lake.cancel_at:
                    raise Cancelled(table)
                lake.log.append("append %s %d" % (table, len(rows)))
                lake.tables.setdefault(table, []).extend(rows)

        return types.SimpleNamespace(coalesce=lambda count: types.SimpleNamespace(write=Writer()))

    def sql(self, statement):
        result = []
        delete = re.fullmatch(r"DELETE FROM (\w+) WHERE run_id = '([^']*)'", statement)
        if delete:
            table = self.tables[delete.group(1)]
            table[:] = [row for row in table if row.get("run_id") != delete.group(2)]
        elif statement.startswith("CREATE TABLE IF NOT EXISTS "):
            self.tables.setdefault(statement.split()[5], [])
        elif statement.startswith("SELECT COUNT(*) AS n FROM "):
            result = [{"n": 0}]
        elif statement.startswith("DESCRIBE DETAIL "):
            result = [{"numFiles": 1}]
        else:
            raise AssertionError("unexpected statement: " + statement)
        return types.SimpleNamespace(collect=lambda: result)


def run_activity(arguments):
    """NB_DatabaseHub_LiveActivity as notebookutils.notebook.run runs it: its parameters cell with the arguments over it, its
    helpers, section 3, what sections 4 to 8 add (stand-ins: T1's CPU, a finding, and from the plan each beat's
    correlation and the Database Agent beat's finding), and the persist cell. Returns its exit value."""
    lake, ns = STATE["lake"], {}
    exec(SETUP[0], ns)
    ns.update(arguments)
    for cell in SETUP[1:]:
        with contextlib.redirect_stdout(io.StringIO()):
            exec(cell, ns)
    lake.columns = ns["TABLE_COLUMNS"]

    def leave(value):
        raise NotebookExit(value)

    def incident_rows():
        recorded = [ns["_incident_row"]("request:" + row["request_id"], "Recorded request", row["target"], "blocking", row["window_start_utc"],
                                        row["window_end_utc"], 3.0, scenario=row["profile"].split(":", 1)[1], request_id=row["request_id"])
                    for row in ns["SESSION_REQUESTS"] if row["profile"].startswith("incident:")]
        start = pd.Timestamp(ns["WINDOW_START"])
        detected = [] if recorded else [ns["_incident_row"]("detected:T1:blocking:" + start.strftime("%Y%m%dT%H%M"), "Detected signal", "T1", "blocking",
                                                            start, start + pd.Timedelta(minutes=10), 3.0)]
        return recorded, detected

    def merge(session, recorded, detected):
        table = lake.tables["incident_windows"]
        for row in recorded + detected:
            table[:] = [item for item in table if item["incident_key"] != row["incident_key"]] + [dict(row)]
        lake.log.append("merge incident_windows %d" % len(recorded + detected))
        return len(recorded + detected), 0

    ns.update(_spark=lambda: lake, runtime_context=lambda: {"defaultLakehouseId": "lakehouse"}, incident_window_rows=incident_rows,
              merge_incident_windows=merge, _notebookutils=lambda: types.SimpleNamespace(notebook=types.SimpleNamespace(exit=leave)))
    plan = json.loads(arguments.get("SESSION_PLAN") or "{}")
    record = {"session": str(arguments.get("SESSION_ID") or ""), "plan": bool(plan), "beats": len(plan.get("beats") or []),
              "analyzed": False, "cut": False, "exit": "", "writes": []}
    STATE["runs"].append(record)
    before = len(lake.log)
    lake.cancel_at, STATE["cancelAt"] = STATE["cancelAt"], None
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            exec(SESSION_CELL, ns)
            record["analyzed"] = True
            start = pd.Timestamp(ns["WINDOW_START"])
            cpu = pd.DataFrame({"Target": "T1", "Bucket": [start + pd.Timedelta(minutes=minute) for minute in range(6)],
                                "AvgCPU": [20.0, 85.0, 90.0, 30.0, 25.0, 20.0]})
            ns["add_snapshot"]("cpu", cpu, ns["WINDOW_START"], ns["WINDOW_END"], metrics=["AvgCPU"], units={"AvgCPU": "percent"})
            ns["add_finding"]("consumption", "T1", "Warning", "T1's CPU peaked at 90%.", "cpu")
            for request_id, beat in ns["session_beats"](ns["SESSION"]) if ns["SESSION"] else []:
                if beat.get("agent"):
                    ns["add_finding"]("database_agent", beat["target"], "Pass", "Database Agent loop on %s." % beat["target"], request_id, request_id=request_id)
                elif beat["target"] in ns["SELECTED_TARGETS"]:
                    ns["add_finding"]("correlation", beat["target"], "Pass", "%s on %s: expected signal observed." % (beat["scenario"], beat["target"]),
                                      request_id, request_id=request_id)
            exec(PERSIST, ns)
    except NotebookExit as value:
        record["exit"] = str(value)
    except Cancelled:
        record["cut"] = True
        raise
    finally:
        lake.cancel_at = None
        record["writes"] = [entry for entry in lake.log[before:]]
    return record["exit"]


class Notebook:
    def run(self, path, timeout_seconds=90, arguments=None, workspace=""):
        if path == "NB_DatabaseHub_Deployment":
            _sleep(70)
            return ""
        assert path == "NB_DatabaseHub_LiveActivity", path
        _sleep(240)
        return run_activity(dict(arguments or {}))


class Credentials:
    def getSecret(self, vault, name):
        return vault_read(name)

    def getToken(self, audience):
        return "simulated-" + audience


def run_all(start, overrides=None, cancel_at=None):
    """One Run all of the control notebook at start, its parameters overridden as the app's job API passes them."""
    Clock.now = start
    STATE.update(sent=[], cancelAt=cancel_at)
    runs = len(STATE["runs"])
    context = {"currentWorkspaceId": "dddddddd-0000-0000-0000-000000000004", "defaultLakehouseId": "cccccccc-0000-0000-0000-000000000003", "isForInteractive": True}
    namespace = {"notebookutils": types.SimpleNamespace(credentials=Credentials(), notebook=Notebook(), session=types.SimpleNamespace(stop=lambda: None),
                                                       runtime=types.SimpleNamespace(context=context))}
    buffer, cancelled, error = io.StringIO(), False, ""
    with contextlib.redirect_stdout(buffer):
        try:
            exec(CONTROL[0], namespace)
            namespace.update(overrides or {})
            for index, source in enumerate(CONTROL[1:], start=1):
                exec(source, namespace)
                if index == 2:
                    namespace["dt"], namespace["time"] = fake_dt, fake_time
        except Cancelled:
            cancelled = True
        except Exception as failure:
            error = "%s: %s" % (type(failure).__name__, failure)
    return {"sent": list(STATE["sent"]), "printed": buffer.getvalue(), "cancelled": cancelled, "error": error, "runs": STATE["runs"][runs:]}


def lake_state():
    tables = STATE["lake"].tables
    return {"counts": {name: len(rows) for name, rows in sorted(tables.items())},
            "requests": sorted(str(row["request_id"]) for row in tables.get("scenario_runs", [])),
            "agentFindings": sum(1 for row in tables.get("analysis_findings", []) if row["analysis"] == "database_agent"),
            "runIds": sorted({row["run_id"] for rows in tables.values() for row in rows})}


def flow(old_runbook=False, cancel_at="scenario_runs"):
    """A session whose end the app's Stop now cancels while it saves the history, the app's Stop now right after, and the
    next day's Run all, whose pre-check finds the session's metrics in the vault."""
    STATE.update(lake=Lake(), runs=[], sessions=[], session=None, oldRunbook=old_runbook,
                 vault={"dbhub-activity-webhook": SECRET_URL, "dbhub-session-status": "{}", "dbhub-session-metrics": "{}"})
    # Three days ago, so the activity notebook's real clock, which ends its window at its now, is past every time here.
    day = real_dt.datetime.now(UTC).replace(hour=10, minute=0, second=0, microsecond=0) - real_dt.timedelta(days=3)
    report = {"first": run_all(day, cancel_at=cancel_at)}
    report["session"], report["cut"] = STATE["sessions"][0], lake_state()
    report["stop"] = run_all(Clock.now + real_dt.timedelta(minutes=1), {"STOP_NOW": True})
    report["saved"] = lake_state()
    report["later"] = run_all(day + real_dt.timedelta(days=1), {"WAIT_FOR_END": False, "WATCH_MINUTES": 0})
    report["final"] = lake_state()
    return report


print(json.dumps({"plan": flow(), "oldRunbook": flow(old_runbook=True), "whole": flow(cancel_at=None)}, default=str))
'@
        $activity = Join-Path -Path $repoRoot -ChildPath 'fabric/notebooks/NB_DatabaseHub_LiveActivity.ipynb'
        $output = & $interpreter $harness (Get-FilledNotebook -Zone 'UTC') $activity 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $report = ($output | Select-Object -Last 1) | ConvertFrom-Json
        foreach ($name in 'plan', 'oldRunbook', 'whole') {
            foreach ($run in 'first', 'stop', 'later') {
                $report.$name.$run.error | Should -BeNullOrEmpty -Because ('{0}, {1}' -f $name, $run)
            }
        }
        $beatRows = { param($State, [string] $Session) @($State.requests | Where-Object { $_ -match ('^session:{0}:\d\d$' -f $Session) }).Count }

        # The session's end: its stop, then its history, which the cancel cuts off before scenario_runs.
        $plan = $report.plan
        $session = $plan.session
        $plan.first.cancelled | Should -BeTrue
        @($plan.first.sent) | Should -Be @('session', 'stop')
        @($plan.first.runs).Count | Should -Be 1
        $plan.first.runs[0].cut | Should -BeTrue
        $plan.first.runs[0].beats | Should -BeGreaterThan 20
        @($plan.cut.requests) | Should -BeNullOrEmpty
        $plan.cut.agentFindings | Should -Be 1

        # Stop now's save, with the plan from the session's stopped status: it keeps what the cut-off run saved and writes
        # the session's row and its beats' rows, the session's row last.
        @($plan.stop.sent) | Should -Be @('stop')
        @($plan.stop.runs).Count | Should -Be 1
        $plan.stop.runs[0].session | Should -Be $session
        $plan.stop.runs[0].beats | Should -Be $plan.first.runs[0].beats
        $plan.stop.runs[0].analyzed | Should -BeTrue
        @($plan.stop.runs[0].writes | Where-Object { $_ -like 'append *' }) | Should -Be @(('append scenario_runs {0}' -f @($plan.saved.requests).Count))
        @($plan.saved.requests) | Should -Contain ('session:{0}' -f $session)
        (& $beatRows $plan.saved $session) | Should -BeGreaterThan 10
        $plan.saved.counts.telemetry_snapshots | Should -Be $plan.cut.counts.telemetry_snapshots
        $plan.saved.counts.analysis_findings | Should -Be $plan.cut.counts.analysis_findings
        $plan.saved.counts.incident_windows | Should -Be $plan.cut.counts.incident_windows
        $plan.saved.agentFindings | Should -Be 1
        @($plan.saved.runIds) | Should -Be @('session-' + $session)
        $plan.stop.printed | Should -Match 'Pass: the history is saved; the report and the Insights app show it'
        $plan.stop.printed | Should -Not -Match 'without its beats'

        # The next day's pre-check finds the session's metrics, and the activity notebook ends at section 3: saved.
        @($plan.later.sent) | Should -Be @('session')
        @($plan.later.runs).Count | Should -Be 1
        $plan.later.runs[0].session | Should -Be $session
        $plan.later.runs[0].analyzed | Should -BeFalse
        $plan.later.runs[0].exit | Should -Be ('Session {0} is already saved.' -f $session)
        @($plan.later.runs[0].writes) | Should -BeNullOrEmpty
        $plan.later.printed | Should -Match ('An earlier session \({0}, ' -f $session.Substring(0, 8))
        $plan.later.printed | Should -Not -Match 'without its beats'
        (ConvertTo-Json -InputObject $plan.final -Depth 4 -Compress) | Should -BeExactly (ConvertTo-Json -InputObject $plan.saved -Depth 4 -Compress)

        # A runbook from before 2026-11-19 stopped the session, so its status has no plan: Stop now saves it with its window
        # from its metrics, no beats, and its session row, and says so once; the next day it isn't analyzed again.
        $old = $report.oldRunbook
        $session = $old.session
        $old.first.runs[0].cut | Should -BeTrue
        $old.stop.runs[0].plan | Should -BeTrue
        $old.stop.runs[0].beats | Should -Be 0
        $old.stop.runs[0].analyzed | Should -BeTrue
        @($old.saved.requests) | Should -Be @('session:' + $session)
        $old.saved.agentFindings | Should -Be 1 -Because 'the cut-off run saved the findings its plan gave it'
        $old.saved.counts.analysis_findings | Should -Be $old.cut.counts.analysis_findings
        $warning = 'Warning: session {0}''s history is saved without its beats, because the runbooks that stopped it are older than 2026-11-19 and kept no plan in its status: its beats'' correlation, its Database Agent finding, and its beats'' rows in scenario_runs are there only if an earlier save of it wrote them.' -f $session.Substring(0, 8)
        ([regex]::Matches($old.stop.printed, [regex]::Escape($warning))).Count | Should -Be 1
        $old.stop.printed | Should -Match 'Fix: \./scripts/deploy\.ps1 republishes the runbooks, so a session''s stop keeps its plan\.'
        $old.later.runs[0].analyzed | Should -BeFalse
        $old.later.runs[0].exit | Should -Be ('Session {0} is already saved.' -f $session)
        $old.later.printed | Should -Not -Match 'without its beats'

        # A session's end that isn't cut off saves it whole, its session row last, and the next day's pre-check finds it
        # saved, as before.
        $whole = $report.whole
        $session = $whole.session
        $whole.first.cancelled | Should -BeFalse
        @($whole.first.runs).Count | Should -Be 1
        $whole.first.runs[0].writes[-1] | Should -Match '^append scenario_runs \d+$'
        @($whole.cut.requests) | Should -Contain ('session:{0}' -f $session)
        (& $beatRows $whole.cut $session) | Should -BeGreaterThan 10
        $whole.stop.runs[0].analyzed | Should -BeFalse
        $whole.later.runs[0].analyzed | Should -BeFalse
        (ConvertTo-Json -InputObject $whole.final -Depth 4 -Compress) | Should -BeExactly (ConvertTo-Json -InputObject $whole.cut -Depth 4 -Compress)
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

    It 'holds T2''s beats while its activity isn''t set, then counts them, and the history''s, from when it was (2026-11-20)' {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed'
            return
        }
        $report = Invoke-Simulation -Path (Get-FilledNotebook -Zone 'UTC') -Scenario 't2late' -Start '2026-11-14T14:00:00Z'
        $report.error | Should -BeNullOrEmpty
        $report.printed | Should -Match 'T2: its activity isn''t set on its VM yet \(a guest that has just started can take minutes\), so its times above come later by as much; the live view prints them once it''s set\.'
        $report.printed | Should -Match 'Times\s+Info\s+T2: its activity was set on archost01 12 minutes after Azure accepted the Run Command that sends it'
        $moved = $report.printed.IndexOf('T2''s beats count from when its activity was set: ')
        $moved | Should -BeGreaterThan 0
        $firstT2 = [regex]::Match($report.printed, 'Now: T2 ')
        $firstT2.Success | Should -BeTrue
        $firstT2.Index | Should -BeGreaterThan $moved -Because 'no T2 beat is announced before its activity is set'
        $report.printed | Should -Match 'Pass: the history is saved'
        $plan = $report.refs[0].args.SESSION_PLAN | ConvertFrom-Json
        $accepted = ([datetime]$plan.startUtc).ToUniversalTime()
        $t2 = @($plan.beats | Where-Object target -EQ 'T2')
        $t2.Count | Should -BeGreaterThan 0
        (([datetime]$t2[0].startUtc).ToUniversalTime() - $accepted).TotalMinutes | Should -Be 24 -Because 'T2''s first beat starts 2 minutes into its showcase, set 22 minutes after the session was accepted'
        $t1 = @($plan.beats | Where-Object target -EQ 'T1')
        (([datetime]$t1[0].startUtc).ToUniversalTime() - $accepted).TotalMinutes | Should -Be 4 -Because 'T1''s times didn''t move'
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
             "RESOURCE_GROUP": "rg-dbhub-demo", "DEMO_DATABASE": "ContosoCare", "T1_VM_NAME": "sqlvm01", "T2_MACHINE_NAME": "arcsql01", "T3_SERVER_PREFIX": "azuresql01-",
             "CONTROL_PROBLEM": ""}
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
        @($catalog['targets']) | Should -Be @('T1', 'T2', 'T3', 'T4', 'T5')
        $catalog['scenarios'].Contains('blocking-chain') | Should -BeTrue
        $catalog['scenarios'].Contains('idle-in-transaction') | Should -BeTrue
        $catalog['scenarios'].Contains('ru-storm') | Should -BeTrue
        $catalog['maxDurationMinutes'] | Should -Be 120
        $catalog['profiles']['showcase']['maxMinutes'] | Should -Be 120
        $catalog['profiles']['showcase']['cycleMinutes'] | Should -Be 30
        @($catalog['profiles']['showcase']['targets']) | Should -Be @('T1', 'T2', 'T3', 'T4', 'T5')
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
        $showcase['scenarios']['ru-storm']['t5']['signal'] | Should -Match '^T5: Normalized RU consumption'
        $text | Should -Not -Match '(?i)webhooks\?token='
        @($filled['cells'] | Where-Object { $_['cell_type'] -eq 'code' } | ForEach-Object { @($_['outputs']).Count } | Where-Object { $_ -gt 0 }) | Should -BeNullOrEmpty
        # Without the demo's lakehouse, the copy names none, and the history runs as a job (the fallback).
        $source | Should -Match '(?m)^DEMO_LAKEHOUSE_ID = ""'
        $filled['metadata'].Contains('dependencies') | Should -BeFalse
        # Nothing missing in the session control: no problem, which also clears one an earlier run put there (F29).
        $source | Should -Match '(?m)^CONTROL_PROBLEM = ""\s+#'
    }

    It 'fills CONTROL_PROBLEM with what deploy.ps1 found missing in the session control, as a Python string (F29)' {
        $problem = './scripts/deploy.ps1 found on 2026-11-21 11:40 UTC that Run all can''t start a session: the session control''s Azure Automation account aa-dbhub-control isn''t in rg-dbhub-control: Azure refused it because the subscription''s quota for Azure Automation accounts in westus3 is used up. Fix: Free an Automation account in westus3 ("destroy.ps1" on an old environment). Then run ./scripts/deploy.ps1 again.'
        $notebookDefinition = InModuleScope -ModuleName DbHubDemo -Parameters @{ Config = $script:config; Json = $script:settingsJson; Problem = $problem } {
            Get-DemoActivityControlNotebook -Name (Get-DemoActivityControlName -Config $Config) -Setting ($Json | ConvertFrom-Json -AsHashtable) -TenantId 'AAAAAAAA-0000-0000-0000-000000000001' -ControlProblem $Problem
        }
        $filled = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($notebookDefinition.Definition['parts'][0]['payload'])) | ConvertFrom-Json -AsHashtable -Depth 64
        $source = (@(@($filled['cells'] | Where-Object { @($_['metadata']['tags']) -contains 'parameters' })[0]['source']) -join '')
        $line = [regex]::Match($source, '(?m)^CONTROL_PROBLEM = (".*?[^\\]")\s+# what deploy\.ps1 found missing').Groups[1].Value
        $line | Should -Not -BeNullOrEmpty
        ($line | ConvertFrom-Json) | Should -BeExactly $problem
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
