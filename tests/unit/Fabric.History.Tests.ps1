# F35 design (i)'s groundwork (2026-11-22): fabric/history/kept_value.py reduces the shared rule for the history's
# overlapping saves (the app's snapshotValues) to a kept value per row. These tests run it on the shared cases, which
# fabric/app/src/data/kept-value-cases.test.ts writes from the TypeScript rule, and read its kept values per bin as the
# model would: each bin must have the TypeScript rule's value. Python 3 only, no pandas; DBHUB_TEST_PYTHON can name one.
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

    # Runs Python code with the module loaded as kept_value, and returns what it prints as JSON.
    function Invoke-KeptValuePython([string] $Code) {
        $path = Join-Path -Path $TestDrive -ChildPath ('check-{0}.py' -f [guid]::NewGuid().ToString('N'))
        $prelude = @(
            'import importlib.util, json, math, sys'
            'sys.dont_write_bytecode = True'
            'spec = importlib.util.spec_from_file_location("kept_value", sys.argv[1])'
            'kept_value = importlib.util.module_from_spec(spec)'
            'spec.loader.exec_module(kept_value)'
        )
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
        captured, start, end = saves[save]
        rows.append(dict(TargetKey=target, AnalysisKey=analysis, Metric=metric, Bucket=ms(bin_seconds), CapturedAt=ms(captured), WindowStart=ms(start), WindowEnd=ms(end), Value=value))
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
]))
'@
        $at = [System.DateTimeOffset]::new(2026, 11, 21, 15, 30, 0, [System.TimeSpan]::Zero).ToUnixTimeMilliseconds()
        # A fraction of 1 or 7 digits reads as the app's Date reads it, cut to whole milliseconds; on Python 3.10, Fabric
        # Runtime 1.2's, fromisoformat alone refused both (201a6666's review of 88ece0f9).
        @($result) | Should -Be @($at, $at, ($at + 99 * 60000 + 30107), ($at + 99 * 60000 + 30100), ($at + 99 * 60000 + 30107), ($at + 99 * 60000 + 30999), $at, $at, 1763739000000, $null, $null, 3, 5, 1, 5, 15)
    }
}
