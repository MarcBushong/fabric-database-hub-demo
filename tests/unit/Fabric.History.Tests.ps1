# F35 design (i): fabric/history/kept_value.py reduces the shared rule for the history's overlapping saves (the app's
# snapshotValues) to a kept value per row, and stores it in the lakehouse when history is saved. These tests run the rule
# on the shared cases, which fabric/app/src/data/kept-value-cases.test.ts writes from the TypeScript rule, and read its
# kept values per bin as the model would: each bin must have the TypeScript rule's value. Then its Spark part,
# kept_value_step, on an in-memory table: through an object with _SparkHistory's methods, and through a fake Spark that
# answers its SQL. Python 3.10 or later, no pandas or Spark; DBHUB_TEST_PYTHON can name one.
BeforeAll {
    $repoRoot = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '../..'))
    $script:keptModule = Join-Path -Path $repoRoot -ChildPath 'fabric/history/kept_value.py'
    $script:keptCases = Join-Path -Path $repoRoot -ChildPath 'fabric/history/kept-value-cases.json'
    $script:python = $env:DBHUB_TEST_PYTHON
    if (-not $script:python) {
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
    }

    # An in-memory telemetry_snapshots for kept_value_step: rows with times in epoch microseconds, as _SparkHistory reads
    # them; Table has _SparkHistory's methods, and FakeSpark answers the SQL that _SparkHistory sends with the same rows.
    # history(days) builds a demo's mix: each day a 90-minute Run all session at 1 minute, a stop save at 5 minutes over
    # 12 hours, and an update's day save at 15 minutes over 24 hours, for T1's Lock waits and MaxCPU, with 5 % of the finer
    # bins missing; some saves declare their grain and some don't, as older ones.
    $script:fakes = @'
import random, re
from datetime import datetime, timedelta, timezone
DAY_US, EPOCH = 86_400_000_000, datetime(1970, 1, 1, tzinfo=timezone.utc)
KEY = ("run_id", "captured_us", "target", "analysis", "metric", "bucket_us", "resource_type", "resource_name", "instance_name", "database_name", "value")
us = lambda moment: (moment - EPOCH) // timedelta(microseconds=1)
def row(run, captured, start, end, analysis, metric, at, value, grain):
    return {"run_id": run, "captured_us": us(captured), "target": "T1", "analysis": analysis, "metric": metric, "bucket_us": None if at is None else us(at),
            "start_us": us(start), "end_us": us(end), "value": value, "grain_minutes": grain, "resource_type": "virtualMachines",
            "resource_name": "sqlvm01", "instance_name": "MSSQLSERVER", "database_name": None, "kept_value": None, "resolved_us": None}
def history(days, seed=7):
    rnd, rows, base = random.Random(seed), [], datetime(2026, 10, 1, tzinfo=timezone.utc)
    def save(run, captured, start, end, step, grain):
        for analysis, metric in (("wait_deltas", "Lock"), ("cpu", "MaxCPU")):
            at = start - timedelta(minutes=(start.hour * 60 + start.minute) % step, seconds=start.second)
            while at < end:
                if step == 15 or rnd.random() > 0.05:
                    rows.append(row(run, captured, start, end, analysis, metric, at, float(rnd.randint(0, 900)), grain))
                at += timedelta(minutes=step)
    for d in range(days):
        day = base + timedelta(days=d)
        s0 = day + timedelta(hours=15, minutes=14, seconds=23)
        save("session-%d" % d, s0 + timedelta(minutes=95), s0, s0 + timedelta(minutes=90), 1, 1 if d % 2 else None)
        stop = day + timedelta(hours=18, minutes=7)
        save("stop-%d" % d, stop + timedelta(seconds=30), stop - timedelta(hours=12), stop, 5, 5 if d % 2 else None)
        update = day + timedelta(hours=21, minutes=26)
        save("deploy-%d" % d, update + timedelta(minutes=7), update - timedelta(days=1), update, 15, 15 if d % 3 else None)
    return rows
def expected(rows):
    """kept_values over the whole table at once."""
    return kept_value.kept_values([{"TargetKey": r["target"], "AnalysisKey": r["analysis"], "Metric": r["metric"], "Bucket": None if r["bucket_us"] is None else r["bucket_us"] // 1000,
        "CapturedAt": r["captured_us"] // 1000, "WindowStart": r["start_us"] // 1000, "WindowEnd": r["end_us"] // 1000, "Value": r["value"], "GrainMinutes": r["grain_minutes"]} for r in rows])
def resolvable(r):
    return r["bucket_us"] is not None and r["captured_us"] is not None and r["start_us"] is not None and r["end_us"] is not None and r["analysis"] not in kept_value.OFF_GRID_ANALYSES
def differing(rows):
    """Resolvable rows that aren't worked out, or whose kept value isn't the whole table's."""
    return sum(1 for r, e in zip(rows, expected(rows)) if resolvable(r) and (r["resolved_us"] is None or not kept_value._same(r["kept_value"], e)))
class Table:
    def __init__(self, rows, columns=("grain_minutes", "kept_value", "resolved_at_utc"), conflicts=0):
        self.rows, self.conflicts, self.merges = rows, conflicts, 0
        self.names = ["run_id", "captured_at_utc", "analysis", "target", "metric", "bucket_utc", "value", "window_start_utc", "window_end_utc", "report_date_utc"] + list(columns)
    def columns(self):
        return set(self.names)
    def add_columns(self, columns):
        self.names += [name for name, _ in columns]
    def profile(self, seed):
        out = {}
        for r in filter(resolvable, self.rows):
            hit = seed == "true" or (seed == "t.resolved_at_utc IS NULL" and r["resolved_us"] is None) or seed == "t.run_id = '%s'" % r["run_id"]
            key = (r["target"], r["analysis"], r["bucket_us"] // DAY_US)
            n, s = out.get(key, (0, 0))
            out[key] = (n + 1, s + hit)
        return [k + v for k, v in out.items()]
    def read(self, items):
        found = []
        for item, target, analysis, lo, hi in items:
            members = [r for r in self.rows if resolvable(r) and r["target"] == target and r["analysis"] == analysis]
            saves = {r["captured_us"] for r in members if lo <= r["bucket_us"] < hi}
            found += [dict(r, item=item) for r in members if r["captured_us"] in saves]
        return found
    def merge(self, updates):
        self.merges += 1
        if self.conflicts:
            self.conflicts -= 1
            raise RuntimeError("An error occurred while calling o123.sql.\n: io.delta.exceptions.ConcurrentAppendException: Files were added to the root of the table by a concurrent update.")
        index, count = {}, 0
        for r in self.rows:
            index.setdefault(tuple(r[k] for k in KEY), []).append(r)
        assert len({u[:11] for u in updates}) == len(updates), "two source rows for one row"
        for u in updates:
            for r in index.get(u[:11], []):
                if r["resolved_us"] is None or r["resolved_us"] <= u[12]:
                    r["kept_value"], r["resolved_us"], count = u[11], u[12], count + 1
        return count
    def pending(self):
        return sum(1 for r in self.rows if resolvable(r) and r["resolved_us"] is None)
class Row(dict):
    def asDict(self):
        return dict(self)
class Frame:
    def __init__(self, spark, rows):
        self.spark, self.rows = spark, rows
    def collect(self):
        return [Row(r) for r in self.rows]
    def createOrReplaceTempView(self, name):
        self.spark.views[name] = self.rows
class Catalog:
    def __init__(self, spark):
        self.spark = spark
    def tableExists(self, name):
        return name == self.spark.name and self.spark.table is not None
    def dropTempView(self, name):
        del self.spark.views[name]
class FakeSpark:
    """Answers _SparkHistory's SQL from a Table, and keeps each statement."""
    def __init__(self, name, table):
        self.name, self.table, self.views, self.statements = name, table, {}, []
        self.catalog = Catalog(self)
    def createDataFrame(self, data, schema):
        names = [part.split()[0] for part in schema.split(", ")]
        return Frame(self, [dict(zip(names, values)) for values in data])
    def sql(self, text):
        self.statements.append(text)
        if text.startswith("DESCRIBE TABLE "):
            return Frame(self, [{"col_name": name, "data_type": "?", "comment": None} for name in self.table.names])
        if text.startswith("ALTER TABLE "):
            self.table.add_columns([tuple(part.split()) for part in re.search(r"ADD COLUMNS \((.*)\)$", text).group(1).split(", ")])
            return Frame(self, [])
        if text.startswith("SELECT t.target, t.analysis, unix_micros(t.bucket_utc) div "):
            seed = re.search(r"count_if\((.*?)\) AS seeds", text).group(1)
            return Frame(self, [dict(zip(("target", "analysis", "day", "n", "seeds"), values)) for values in self.table.profile(seed)])
        if text.startswith("SELECT c.item, "):
            items = self.views[re.search(r" JOIN (kept_value_items_\w+) i ", text).group(1)]
            return Frame(self, self.table.read([(i["item"], i["target"], i["analysis"], i["lo"], i["hi"]) for i in items]))
        if text.startswith("MERGE INTO "):
            updates = self.views[re.search(r" FROM (kept_value_updates_\w+)\) AS s ", text).group(1)]
            count = self.table.merge([tuple(u[k] for k in KEY[:1]) + (u["captured_us"],) + tuple(u[k] for k in KEY[2:]) + (u["kept_value"], u["resolved_us"]) for u in updates])
            return Frame(self, [{"num_affected_rows": count, "num_updated_rows": count, "num_deleted_rows": 0, "num_inserted_rows": 0}])
        if text.startswith("SELECT count(*) AS n FROM "):
            return Frame(self, [{"n": self.table.pending()}])
        raise AssertionError("unexpected SQL: " + text)
'@

    # Runs Python code with the module loaded as kept_value (and with -Fakes, the fakes above), and returns what it prints
    # last as JSON.
    function Invoke-KeptValuePython([string] $Code, [switch] $Fakes) {
        $path = Join-Path -Path $TestDrive -ChildPath ('check-{0}.py' -f [guid]::NewGuid().ToString('N'))
        $prelude = @(
            'import importlib.util, json, math, sys'
            'sys.dont_write_bytecode = True'
            'spec = importlib.util.spec_from_file_location("kept_value", sys.argv[1])'
            'kept_value = importlib.util.module_from_spec(spec)'
            'spec.loader.exec_module(kept_value)'
        )
        if ($Fakes) {
            $prelude += $script:fakes
        }
        Set-Content -LiteralPath $path -Encoding utf8NoBOM -Value (@($prelude) + @($Code))
        $PSNativeCommandUseErrorActionPreference = $false
        $output = @(& $script:python $path $script:keptModule $script:keptCases 2>&1 | ForEach-Object { [string]$_ })
        if ($LASTEXITCODE -ne 0) {
            throw ('Python failed: {0}' -f ($output -join "`n"))
        }
        return ($output[-1] | ConvertFrom-Json -AsHashtable)
    }
}

Describe 'F35 design (i): a kept value per row, against the TypeScript rule (fabric/history/kept_value.py)' {
    BeforeEach {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed (set DBHUB_TEST_PYTHON to a Python 3)'
        }
    }

    It 'gives every bin of the shared cases the TypeScript rule''s value, with the rule''s lists' {
        $result = Invoke-KeptValuePython @'
data = json.load(open(sys.argv[2], encoding="utf-8"))
base = kept_value.to_ms(data["base"])
ms = lambda seconds: None if seconds is None else base + kept_value._js_round(seconds * 1000)
problems = []
for name, mine in (("additiveAnalyses", kept_value.ADDITIVE_ANALYSES), ("additiveMetrics", kept_value.ADDITIVE_METRICS), ("hourlyMetrics", kept_value.HOURLY_METRICS), ("offGridAnalyses", kept_value.OFF_GRID_ANALYSES)):
    if sorted(mine) != data["lists"][name]:
        problems.append("the list %s is %s, and the TypeScript rule's %s" % (name, sorted(mine), data["lists"][name]))
bins = 0
rows_checked = 0
for case in data["cases"]:
    series = case["series"]
    saves = case["saves"]
    rows = []
    for index, bin_seconds, save, value in case["rows"]:
        target, analysis, metric = series[index]
        captured, start, end = saves[save][:3]
        row = dict(TargetKey=target, AnalysisKey=analysis, Metric=metric, Bucket=ms(bin_seconds), CapturedAt=ms(captured), WindowStart=ms(start), WindowEnd=ms(end), Value=value)
        if len(saves[save]) > 3:
            row["GrainMinutes"] = saves[save][3]
        rows.append(row)
    kept = kept_value.kept_values(rows)
    got = kept_value.bin_values(rows, kept)
    want = {tuple(series[b[0]]) + (ms(b[1]),): b[2] for b in case["bins"]}
    for key in set(got) | set(want):
        a, b = got.get(key), want.get(key)
        bins += 1
        if a is None or b is None or abs(a - b) > 1e-9 * max(1.0, abs(a), abs(b)):
            problems.append("%s, %s: the kept values give %s, the TypeScript rule %s" % (case["name"], key, a, b))
    for row, value in zip(rows, kept):
        rows_checked += 1
        if value is not None and value < 0:
            problems.append("%s: a row keeps %s, below 0" % (case["name"], value))
print(json.dumps({"cases": len(data["cases"]), "bins": bins, "rows": rows_checked, "problems": problems[:10], "count": len(problems)}))
'@
        $result['count'] | Should -Be 0 -Because (@($result['problems']) -join "`n")
        $result['cases'] | Should -BeGreaterOrEqual 45
        $result['bins'] | Should -BeGreaterThan 500
    }

    It 'keeps each row''s share: a total''s remainder split over two files by their values, a covered point None, a lone point whole' {
        $result = Invoke-KeptValuePython @'
day = dict(CapturedAt="2026-11-21T21:30:00Z", WindowStart="2026-11-20T21:26:00Z", WindowEnd="2026-11-21T21:26:00Z")
session = dict(CapturedAt="2026-11-21T16:00:00Z", WindowStart="2026-11-21T15:00:00Z", WindowEnd="2026-11-21T15:40:00Z")
rows = [dict(session, TargetKey="T3", AnalysisKey="storage_io", Metric="ReadMB", Bucket="2026-11-21T15:%02d:00Z" % m, Value=10) for m in range(40)]
for bucket, first, second in (("15:15", 200, 100), ("15:30", 200, 100), ("15:45", 80, 40)):
    rows.append(dict(day, TargetKey="T3", AnalysisKey="storage_io", Metric="ReadMB", Bucket="2026-11-21T%s:00Z" % bucket, Value=first))
    rows.append(dict(day, TargetKey="T3", AnalysisKey="storage_io", Metric="ReadMB", Bucket="2026-11-21T%s:00Z" % bucket, Value=second))
kept = kept_value.kept_values(rows)
print(json.dumps({"covered": kept[40:42], "split": kept[42:44], "whole": kept[44:46], "session": sorted(set(kept[:40]))}))
'@
        # 15:15 to 15:30 is all the session's: the day save's files keep nothing there.
        @($result['covered']) | Should -Be @($null, $null)
        # 15:30 to 15:45 has the session's minutes to 15:40: 300 - 100 = 200 is left, split 2:1 by the files' values.
        [double]$result['split'][0] | Should -BeExactly ([double](200 * 200 / 300))
        [double]$result['split'][1] | Should -BeExactly ([double](200 * 100 / 300))
        @($result['whole']) | Should -Be @(80, 40)
        @($result['session']) | Should -Be @(10)
    }

    It 'reads the history''s times as the app does: ISO text with or without its zone, datetimes, and epoch milliseconds' {
        $result = Invoke-KeptValuePython @'
from datetime import datetime, timezone
print(json.dumps([
    kept_value.to_ms("2026-11-21T15:30:00Z"),
    kept_value.to_ms("2026-11-21T15:30:00"),
    kept_value.to_ms("2026-11-21T17:09:30.107"),
    kept_value.to_ms("2026-11-21T17:09:30.1"),
    kept_value.to_ms("2026-11-21T17:09:30.1070000Z"),
    kept_value.to_ms("2026-11-21T17:09:30.9999999+00:00"),
    kept_value.to_ms(datetime(2026, 11, 21, 15, 30)),
    kept_value.to_ms(datetime(2026, 11, 21, 15, 30, tzinfo=timezone.utc)),
    kept_value.to_ms(1763739000000),
    kept_value.to_ms(None),
    kept_value.to_ms(""),
    kept_value._js_round(2.5),
    kept_value.monitor_grain(kept_value.to_ms("2026-11-20T21:26:00Z"), kept_value.to_ms("2026-11-21T21:26:00Z"), [kept_value.to_ms("2026-11-21T15:%02d:00Z" % m) for m in range(0, 60, 5)]),
    kept_value.sql_grain(0, 120 * 60000), kept_value.sql_grain(0, 121 * 60000), kept_value.sql_grain(0, 721 * 60000),
    [kept_value.declared_grain(value) for value in (15, "5", " 60 ", 15.0, 1440, 0, 2.5, 1441, None, True, "x", "")],
]))
'@
        $at = [System.DateTimeOffset]::new(2026, 11, 21, 15, 30, 0, [System.TimeSpan]::Zero).ToUnixTimeMilliseconds()
        # A fraction of 1 or 7 digits reads as the app's Date reads it, cut to whole milliseconds; on Python 3.10, Fabric
        # Runtime 1.2's, fromisoformat alone refused both (201a6666's review of 88ece0f9).
        @($result[0..15]) | Should -Be @($at, $at, ($at + 99 * 60000 + 30107), ($at + 99 * 60000 + 30100), ($at + 99 * 60000 + 30107), ($at + 99 * 60000 + 30999), $at, $at, 1763739000000, $null, $null, 3, 5, 1, 5, 15)
        # A declared grain is a whole number of minutes from 1 to 1,440, as the app's declaredGrain reads it; anything else
        # is none, and the save keeps today's reading.
        @($result[16]) | Should -Be @(15, 5, 60, 15, 1440, $null, $null, $null, $null, $null, $null, $null)
    }
}

Describe 'F35 design (i): kept_value_step works the lakehouse''s rows out (fabric/history/kept_value.py)' {
    BeforeEach {
        if (-not $script:python) {
            Set-ItResult -Skipped -Because 'Python 3 is not installed (set DBHUB_TEST_PYTHON to a Python 3)'
        }
    }

    It 'adds the columns, resolves a history to the rule''s values over the whole of it, after a concurrent commit, in chunks or not' {
        $result = Invoke-KeptValuePython -Fakes @'
rows = history(20)
table = Table(rows, columns=(), conflicts=1)
first = kept_value.kept_value_step(None, history=table)
after_first = differing(rows)
for r in rows:
    r["kept_value"], r["resolved_us"] = None, None
chunked = kept_value.resolve_kept_values(None, history=Table(rows), chunk_days=2, batch_rows=3000)
print(json.dumps({"first": first, "after_first": after_first, "merges": table.merges, "chunked": chunked, "after_chunked": differing(rows),
                  "resolvable": sum(map(resolvable, rows)), "again": kept_value.kept_value_step(None, history=Table(rows))}))
'@
        $first = $result['first']
        $first['error'] | Should -BeNullOrEmpty
        $first['exists'] | Should -BeTrue
        @($first['missing']) | Should -Be @('grain_minutes', 'kept_value', 'resolved_at_utc')
        @($first['added']) | Should -Be @('grain_minutes', 'kept_value', 'resolved_at_utc')
        $first['form'] | Should -Be 'Kept'
        $first['scope'] | Should -Be 'unresolved'
        # Delta's ConcurrentAppendException on the first MERGE: the batch is read again and merged again.
        $first['attempts'] | Should -Be 2
        $result['merges'] | Should -Be 2
        $first['resolved'] | Should -Be $result['resolvable']
        $first['pending'] | Should -Be 0
        $result['after_first'] | Should -Be 0
        # Two-day chunks in small batches read some saves twice, and write each row once, with the same values.
        $result['chunked']['batches'] | Should -BeGreaterThan 3
        $result['chunked']['read'] | Should -BeGreaterThan $result['resolvable']
        $result['chunked']['resolved'] | Should -Be $result['resolvable']
        $result['after_chunked'] | Should -Be 0
        # A second step finds nothing to do.
        $result['again']['resolved'] | Should -Be 0
        $result['again']['read'] | Should -Be 0
        $result['again']['pending'] | Should -Be 0
    }

    It 'works out a new save''s rows and only the rows around it whose kept value it changes, and never overwrites a later step''s' {
        $result = Invoke-KeptValuePython -Fakes @'
rows = history(10)
kept_value.kept_value_step(None, history=Table(rows))
before = {id(r): (r["kept_value"], r["resolved_us"]) for r in rows}
mid = datetime(2026, 10, 6, 9, 0, tzinfo=timezone.utc)
late = [row("session-late", mid + timedelta(hours=3), mid, mid + timedelta(minutes=120), "wait_deltas", "Lock", mid + timedelta(minutes=m), 5.0, 1) for m in range(120)]
rows += late
step = kept_value.kept_value_step(None, history=Table(rows), run_id="session-late")
changed = [r for r in rows if id(r) in before and before[id(r)] != (r["kept_value"], r["resolved_us"])]
# A step whose read is older than a row's resolved_at_utc leaves that row as the later step wrote it.
newest = max(r["resolved_us"] for r in rows)
guarded = Table(rows)
kept = guarded.merge([tuple(r[k] for k in KEY) + (-1.0, newest - 1) for r in late[:3]])
print(json.dumps({"step": step, "changed": len(changed), "days": sorted({r["bucket_us"] // DAY_US - us(mid) // DAY_US for r in changed}),
                  "analyses": sorted({r["analysis"] for r in changed}), "differ": differing(rows), "guarded": kept}))
'@
        $result['step']['scope'] | Should -Be 'run'
        $result['step']['error'] | Should -BeNullOrEmpty
        $result['step']['resolved'] | Should -Be (120 + $result['changed'])
        # The day save's and the stop save's points that the session's minutes reach, that morning, and nothing else.
        $result['changed'] | Should -BeGreaterThan 0
        @($result['days']) | Should -Be @(0)
        @($result['analyses']) | Should -Be @('wait_deltas')
        $result['differ'] | Should -Be 0
        $result['guarded'] | Should -Be 0
    }

    It 'leaves rows off the bin grid, and rows without a bin, a capture time, or a window, unresolved and out of pending' {
        $result = Invoke-KeptValuePython -Fakes @'
rows = history(2)
at = datetime(2026, 10, 1, 15, 0, tzinfo=timezone.utc)
odd = [row("session-0", at, at, at + timedelta(hours=1), "wait_profile", "LCK_M_X", None, 100.0, None),
       row("session-0", at, at, at + timedelta(hours=1), "memory_clerks", "MEMORYCLERK_SQLBUFFERPOOL", at, 2048.0, None),
       row("session-0", at, at, at + timedelta(hours=1), "estate_pulse", "LastSampleAgeMinutes", None, 3.0, None),
       row("session-0", at, at, at + timedelta(hours=1), "wait_deltas", "Lock", None, 7.0, None)]
odd[-1]["bucket_us"] = None
broken = row("session-0", at, at, at + timedelta(hours=1), "wait_deltas", "Lock", at, 9.0, None)
broken["start_us"] = None
rows += odd + [broken]
step = kept_value.kept_value_step(None, history=Table(rows))
print(json.dumps({"step": step, "untouched": [r["resolved_us"] is None and r["kept_value"] is None for r in odd + [broken]], "resolvable": sum(map(resolvable, rows))}))
'@
        $result['step']['resolved'] | Should -Be $result['resolvable']
        $result['step']['pending'] | Should -Be 0
        @($result['untouched']) | Should -Be @($true, $true, $true, $true, $true)
    }

    It 'runs through Spark SQL: DESCRIBE, one ALTER for the missing columns, a profile, the reads, and a MERGE on every key column' {
        $result = Invoke-KeptValuePython -Fakes @'
rows = history(3)
spark = FakeSpark("telemetry_snapshots_f35check", Table(rows, columns=("grain_minutes",)))
step = kept_value.kept_value_step(spark, table="telemetry_snapshots_f35check")
merge = [s for s in spark.statements if s.startswith("MERGE INTO ")]
kinds = ("DESCRIBE TABLE", "ALTER TABLE", "SELECT t.target", "SELECT c.item", "MERGE INTO", "SELECT count(*)")
print(json.dumps({"step": step, "kinds": [next((k for k in kinds if s.startswith(k)), s[:30]) for s in spark.statements], "merge": merge[0] if merge else "",
                  "alter": [s for s in spark.statements if s.startswith("ALTER")], "views": sorted(spark.views), "differ": differing(rows),
                  "missing": kept_value.kept_value_step(FakeSpark("other", None), table="other"), "bad": kept_value.kept_value_step(spark, table="x; DROP TABLE y")}))
'@
        $step = $result['step']
        $step['error'] | Should -BeNullOrEmpty
        @($step['missing']) | Should -Be @('kept_value', 'resolved_at_utc')
        @($step['added']) | Should -Be @('kept_value', 'resolved_at_utc')
        $step['form'] | Should -Be 'Kept'
        $step['pending'] | Should -Be 0
        $result['differ'] | Should -Be 0
        @($result['kinds']) | Should -Be @('DESCRIBE TABLE', 'DESCRIBE TABLE', 'ALTER TABLE', 'DESCRIBE TABLE', 'SELECT t.target', 'SELECT c.item', 'MERGE INTO', 'SELECT count(*)')
        @($result['alter']) | Should -Be @('ALTER TABLE telemetry_snapshots_f35check ADD COLUMNS (kept_value DOUBLE, resolved_at_utc TIMESTAMP)')
        # The temporary views are gone after the step.
        @($result['views']).Count | Should -Be 0
        $merge = $result['merge']
        $merge | Should -Match '^MERGE INTO telemetry_snapshots_f35check AS t USING \(SELECT .+ FROM kept_value_updates_[0-9a-f]{12}\) AS s ON t\.bucket_utc >= timestamp_micros\(\d+\) AND t\.bucket_utc < timestamp_micros\(\d+\) '
        foreach ($column in 'bucket_utc', 'captured_at_utc', 'target', 'analysis', 'metric') {
            $merge | Should -Match ([regex]::Escape(' AND t.{0} = s.{0}' -f $column))
        }
        foreach ($column in 'run_id', 'resource_type', 'resource_name', 'instance_name', 'database_name', 'value') {
            $merge | Should -Match ([regex]::Escape(' AND t.{0} <=> s.{0}' -f $column))
        }
        $merge | Should -Match ([regex]::Escape('WHEN MATCHED AND (t.resolved_at_utc IS NULL OR t.resolved_at_utc <= s.resolved_at_utc) THEN UPDATE SET kept_value = s.kept_value, resolved_at_utc = s.resolved_at_utc'))
        $merge | Should -Not -Match 'NOT MATCHED|DELETE|INSERT'
        # No table: nothing is created, and the model keeps the release's form. A name that isn't one is refused.
        $result['missing']['exists'] | Should -BeFalse
        $result['missing']['form'] | Should -Be 'Release'
        $result['missing']['error'] | Should -BeNullOrEmpty
        $result['bad']['form'] | Should -Be 'Release'
        $result['bad']['error'] | Should -Match 'Not a table name'
    }

    It 'keeps the release''s form without the columns it may not add, and reports an error without raising' {
        $result = Invoke-KeptValuePython -Fakes @'
rows = history(1)
kept = kept_value.kept_value_step(None, history=Table(rows, columns=()), add_columns=False)
class Broken(Table):
    def read(self, items):
        raise RuntimeError("Spark refused the read\nwith a long trace")
broken = kept_value.kept_value_step(None, history=Broken(rows))
print(json.dumps({"kept": kept, "broken": broken, "run": kept_value.kept_value_step(None, history=Table(rows), run_id="x' OR '1'='1")}))
'@
        $result['kept']['form'] | Should -Be 'Release'
        @($result['kept']['added']).Count | Should -Be 0
        $result['kept']['resolved'] | Should -Be 0
        $result['broken']['form'] | Should -Be 'Kept'
        $result['broken']['error'] | Should -Be 'RuntimeError: Spark refused the read'
        $result['run']['error'] | Should -Match 'Not a run ID'
    }
}
