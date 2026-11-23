# F35's kept values (fabric/history/kept_value.py), the same text in NB_DatabaseHub_LiveActivity: overlapping saves, resolved when history is saved.
"""F35, design (i): the kept value of each row of the history's telemetry snapshots, worked out when history is saved.

The history keeps every save, each at its own interval (1 to 1,440 minutes), so one minute can be in several saves. Each
interval is taken from its finest save, by the rows each save holds: a coarser save's point keeps only what the finer
saves' rows in its interval don't hold, so nothing counts twice and nothing is lost. This is the rule of the app's
snapshotValues (fabric/app/src/data/snapshot-value.ts, which keeps each point as finestPerInterval does), reduced to one
kept value per raw row:

- A point (a save's rows of a series at one bin) that no finer save's rows reach keeps each row's value.
- A point that finer saves' rows cover keeps None in each row.
- Otherwise the finer saves' rows in its interval are taken as finestPerInterval takes them, the finest save first: each
  keeps the stretches that the earlier ones leave uncovered, a total splitting what's left of it across them by length.
  Then a total keeps what's left of it after the stretches that overlap the part of its interval its window keeps, never
  below 0, split across its rows by their values; a maximum or an average keeps each row's value only where it's higher
  than theirs, else None.
- Off the bin grid, and for a row with no bin, the newest capture's rows keep their values, the others None.

A save's step is the grain its rows declare (GrainMinutes, the column grain_minutes, which the notebook writes with each
save since F35); a save written before that keeps today's reading, from a SQL save's window or an Azure Monitor save's
window and bins.

The model reads the kept values per series and bin (bin_values): the sum for a total, and for a maximum or an average the
highest of each save's sum. A bin whose rows all keep None has no value. That equals snapshotValues' value for the bin,
which the shared cases (fabric/history/kept-value-cases.json, written from the TypeScript rule) pin.

The rule is the standard library only, so a notebook cell, a Livy statement, and the tests run the same code. Rows are
mappings with the history model's column names (TargetKey, AnalysisKey, Metric, Bucket, CapturedAt, WindowStart,
WindowEnd, Value, GrainMinutes); a time is a datetime (naive is UTC), a pandas Timestamp, an ISO 8601 text, or epoch
milliseconds.

The Spark part, at the end, stores them in the lakehouse's telemetry_snapshots: kept_value_step adds the columns where
they're missing and works out the rows not resolved yet, or one run's, with their neighborhoods, and MERGEs kept_value
and resolved_at_utc into them. NB_DatabaseHub_LiveActivity runs it on its own save, and the operator's scripts send this
file to Spark through Fabric's Livy API. It changes lakehouse data only.
"""

import bisect
import math
import random
import re
import time
import uuid
from datetime import datetime, timedelta, timezone

MINUTE = 60_000
# A millisecond's slack where intervals meet, as the TypeScript rule allows.
EPSILON = 1
# Azure Monitor's intervals, as the operator side's helpers choose them (PostgresHistoryHelpers.ps1, CosmosHistoryHelpers.ps1).
LADDER = (1, 5, 15, 30, 60, 180, 360, 720, 1440)
MONITOR_ANALYSES = frozenset({"postgresql", "cosmosdb"})
# The shared rule's lists (finest-per-interval.ts); the shared cases carry the TypeScript values, and the tests compare.
HOURLY_METRICS = frozenset({"ProvisionedThroughput", "ServiceAvailability"})
ADDITIVE_ANALYSES = frozenset({"wait_deltas", "counter_deltas", "storage_io"})
ADDITIVE_METRICS = frozenset({"TotalRequests", "ThrottledRequests", "TotalRequestUnits", "connections_failed"})
OFF_GRID_ANALYSES = frozenset({"wait_profile", "estate_pulse", "memory_clerks", "database_growth", "telemetry_coverage"})

_EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
_LOCAL_ISO = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?")
# A fraction of a second of any length, as the app's Date reads it: datetime.fromisoformat reads only 3 or 6 digits before
# Python 3.11 (Fabric Runtime 1.2 runs 3.10), so it's padded or cut to 6, which keeps Date's whole milliseconds (it cuts).
_FRACTION = re.compile(r"(\d{2}:\d{2}:\d{2})\.(\d+)")


def _js_round(value: float) -> int:
    """JavaScript's Math.round: halves round up, where Python's round() rounds them to even."""
    return math.floor(value + 0.5)


def to_ms(value) -> int | None:
    """A time as epoch milliseconds, read as the app's toDate reads it, or None."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value) if math.isfinite(value) else None
    if hasattr(value, "to_pydatetime"):
        # A pandas Timestamp: its nanoseconds since the epoch, UTC; NaT isn't equal to itself.
        if value != value:
            return None
        return int(value.value) // 1_000_000
    if isinstance(value, datetime):
        moment = value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)
        return (moment - _EPOCH) // timedelta(milliseconds=1)
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if _LOCAL_ISO.fullmatch(text):
            text += "Z"
        text = _FRACTION.sub(lambda match: match.group(1) + "." + (match.group(2) + "000000")[:6], text)
        try:
            moment = datetime.fromisoformat(text.replace("Z", "+00:00").replace("z", "+00:00"))
        except ValueError:
            return None
        return to_ms(moment)
    return None


def _number(value) -> float:
    """A row's value as JavaScript's Number reads it, a missing one (None, or pandas' NaN) as 0."""
    if value is None:
        return 0.0
    try:
        number = float(value)
    except (TypeError, ValueError):
        return math.nan
    return 0.0 if math.isnan(number) else number


def _text(value) -> str:
    return "" if value is None else str(value)


def declared_grain(value) -> int | None:
    """
    A row's declared grain in minutes, as the app's declaredGrain reads it: a whole number from 1 to 1,440, or None for
    anything else (a save written before F35 declares none).
    """
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            value = float(text)
        except ValueError:
            return None
    if hasattr(value, "item") and not isinstance(value, (int, float)):
        value = value.item()
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        return None
    return int(value) if value == math.floor(value) and 1 <= value <= 1440 else None


def sql_grain(start: int, end: int) -> int:
    """A SQL save's bin, by the notebook's own rule from its window (NB_DatabaseHub_LiveActivity: 1, 5, or 15 minutes)."""
    span = (end - start) / MINUTE
    return 1 if span <= 120 + 1e-6 else 5 if span <= 720 + 1e-6 else 15


def monitor_grain(start: int, end: int, bins) -> int:
    """
    An Azure Monitor save's step: the coarsest interval its window can hold its bins in, that each of its bins starts on
    (counted from midnight UTC, as the history helpers bucket them), hourly metrics aside.
    """
    minutes = {_js_round(at / MINUTE) for at in bins}
    if not minutes:
        return 60
    first = _js_round(start / MINUTE)
    last = _js_round(end / MINUTE)
    best = 1
    for step in LADDER:
        intervals = (math.ceil(last / step) * step - math.floor(first / step) * step) / step
        if intervals >= len(minutes) and all(minute % step == 0 for minute in minutes):
            best = step
    return best


class _Save:
    """One save of a series: its window, its grain, and what its rows cover."""

    __slots__ = ("captured", "start", "end", "grain", "row_from", "row_to", "dense")

    def __init__(self, captured, start, end, grain, row_from, row_to, dense):
        self.captured = captured
        self.start = start
        self.end = end
        self.grain = grain
        self.row_from = row_from
        self.row_to = row_to
        self.dense = dense


class _Piece:
    """A finer save's row in a coarser point's interval: its value, its span, and its save's rank there."""

    __slots__ = ("value", "start", "end", "rank")

    def __init__(self, value, start, end, rank):
        self.value = value
        self.start = start
        self.end = end
        self.rank = rank


def _finer_than(save: _Save, than: _Save) -> bool:
    return save.grain < than.grain or (save.grain == than.grain and save.captured > than.captured)


def _sum(values) -> float:
    """A sum in order, from 0, as the TypeScript rule's reduce adds."""
    total = 0
    for value in values:
        total = total + value
    return total


# Stretches, as finestPerInterval keeps them (finest-per-interval.ts): (start, end, value) tuples, sorted by start, that
# don't overlap each other.
def _overlapping(spans, start, end) -> list:
    """The stretches that overlap [start, end)."""
    lo, hi = 0, len(spans)
    while lo < hi:
        mid = (lo + hi) // 2
        if spans[mid][1] <= start:
            lo = mid + 1
        else:
            hi = mid
    found = []
    while lo < len(spans) and spans[lo][0] < end:
        found.append(spans[lo])
        lo += 1
    return found


def _insert(spans, span) -> None:
    lo, hi = 0, len(spans)
    while lo < hi:
        mid = (lo + hi) // 2
        if spans[mid][0] < span[0]:
            lo = mid + 1
        else:
            hi = mid
    spans.insert(lo, span)


def _gaps(spans, start, end) -> list:
    """The stretches of [start, end) that none of the (sorted) spans covers."""
    gaps = []
    at = start
    for span_start, span_end, _ in spans:
        if span_start > at:
            gaps.append((at, min(span_start, end)))
        at = max(at, span_end)
        if at >= end:
            break
    if at < end:
        gaps.append((at, end))
    return gaps


def _shares(total, lengths) -> list:
    """A total split across stretches by their length, in whole numbers when the total is one (largest remainders first)."""
    if len(lengths) == 1:
        return [total]
    whole_length = _sum(lengths)
    exact = [(total * length) / whole_length for length in lengths]
    if not (math.isfinite(total) and total == math.floor(total)):
        return exact
    whole = [float(math.floor(part)) for part in exact]
    left = total - _sum(whole)
    for index in sorted(range(len(exact)), key=lambda i: (-(exact[i] - whole[i]), i)):
        if left <= 0:
            break
        whole[index] += 1
        left -= 1
    return whole


class _Points:
    """
    A series' points, each save's value at a bin, in the rows' order, indexed by bin: each point then reads only the bins
    in its interval, where the TypeScript rule reads every point of the series, which made a long history's work grow
    with its square (201a6666's review of 88ece0f9). The points keep their order, so every sum adds as the rule's does.
    """

    __slots__ = ("values", "order", "keys_at", "times")

    def __init__(self):
        self.values = {}
        self.order = {}
        self.keys_at = {}
        self.times = []

    def add(self, at, captured, value) -> None:
        key = (at, captured)
        if key not in self.values:
            self.values[key] = 0
            self.order[key] = len(self.order)
            self.keys_at.setdefault(at, []).append(key)
        self.values[key] = self.values[key] + value

    def seal(self) -> None:
        self.times = sorted(self.keys_at)

    def within(self, start, end) -> list:
        """The points whose bin is in [start, end), in the rows' order."""
        first = bisect.bisect_left(self.times, start)
        last = bisect.bisect_left(self.times, end)
        keys = [key for at in self.times[first:last] for key in self.keys_at[at]]
        keys.sort(key=self.order.__getitem__)
        return keys


class _Saves:
    """
    A series' saves by capture, and in the order their rows start, so a point finds the saves whose rows can reach its
    interval by bisection, within the longest save's reach, instead of reading every save of the series (the review's
    finding, for a long history). Which saves reach it doesn't depend on their order.
    """

    __slots__ = ("by_capture", "ordered", "starts", "reach")

    def __init__(self, by_capture):
        self.by_capture = by_capture
        self.ordered = sorted(by_capture.values(), key=lambda save: save.row_from)
        self.starts = [save.row_from for save in self.ordered]
        self.reach = max((save.row_to - save.row_from for save in self.ordered), default=0)

    def reaching(self, start, end) -> list:
        """The saves whose rows start before end, and late enough to end after start."""
        return self.ordered[bisect.bisect_left(self.starts, start - self.reach):bisect.bisect_left(self.starts, end)]


def _own(bin_at, save, value, saves, points, adds):
    """What a save's point at a bin keeps of its value under the shared rule, or None when it's left out."""
    length = save.grain * MINUTE
    start = max(bin_at, save.start)
    end = min(bin_at + length, save.end)
    if start >= end:
        start, end = bin_at, bin_at + length
    # The finer saves whose rows reach any part of its interval, the part its window cuts off too: a finer row that straddles
    # the cut is taken against every one of them, as finestPerInterval takes it (the review of 4944e22d). The cover check and
    # the point's own remainder stay on the part its window keeps.
    finer = [s for s in saves.reaching(bin_at, bin_at + length) if _finer_than(s, save) and s.row_from < bin_at + length and s.row_to > bin_at]
    if not finer:
        return value
    if any(s.dense and s.row_from <= start + EPSILON and s.row_to >= end - EPSILON for s in finer):
        return None
    # The finer saves' rows in its interval, each ranked by its save: the finest first, then the newest.
    pieces = []
    for at, captured in points.within(bin_at, bin_at + length):
        other = saves.by_capture.get(captured)
        if other is None or other not in finer:
            continue
        piece_start = max(at, other.start)
        piece_end = min(at + other.grain * MINUTE, other.end)
        if piece_start >= piece_end:
            piece_start, piece_end = at, at + other.grain * MINUTE
        pieces.append(_Piece(points.values[(at, captured)], piece_start, piece_end, 1 + sum(1 for q in finer if _finer_than(q, other))))
    # What finestPerInterval keeps of each, against the stretches every earlier one kept: its whole span with nothing under
    # it, nothing when they cover it, and otherwise each stretch they leave uncovered, with a total's remainder split across
    # them by length and a maximum's or an average's value on each.
    pieces.sort(key=lambda piece: piece.rank)
    taken = []
    for piece in pieces:
        under = _overlapping(taken, piece.start, piece.end)
        if not under:
            _insert(taken, (piece.start, piece.end, piece.value))
            continue
        gaps = _gaps(under, piece.start, piece.end)
        if not gaps:
            continue
        if adds:
            left = max(0, piece.value - _sum(span[2] for span in under))
            for (gap_start, gap_end), part in zip(gaps, _shares(left, [gap_end - gap_start for gap_start, gap_end in gaps])):
                _insert(taken, (gap_start, gap_end, part))
        else:
            for gap_start, gap_end in gaps:
                _insert(taken, (gap_start, gap_end, piece.value))
    under = _overlapping(taken, start, end)
    if not under:
        return value
    if not _gaps(under, start, end):
        return None
    if adds:
        return max(0, value - _sum(span[2] for span in under))
    return value if value > max(span[2] for span in under) else None


def kept_values(rows) -> list:
    """Each row's kept value (a float, or None when it keeps nothing), in the rows' order. See the module's notes."""
    rows = list(rows)
    kept = [None] * len(rows)
    series = {}
    for index, row in enumerate(rows):
        series.setdefault((_text(row.get("TargetKey")), _text(row.get("AnalysisKey")), _text(row.get("Metric"))), []).append(index)
    # Azure Monitor saves' bins, over every metric of their target and analysis but the hourly ones.
    monitor_bins = {}
    for row in rows:
        at = to_ms(row.get("Bucket"))
        if at is None or _text(row.get("AnalysisKey")) not in MONITOR_ANALYSES or _text(row.get("Metric")) in HOURLY_METRICS:
            continue
        monitor_bins.setdefault((_text(row.get("TargetKey")), _text(row.get("AnalysisKey")), to_ms(row.get("CapturedAt"))), set()).add(at)

    for (target, analysis, metric), indexes in series.items():
        adds = analysis in ADDITIVE_ANALYSES or metric in ADDITIVE_METRICS
        monitor = analysis in MONITOR_ANALYSES
        hourly = metric in HOURLY_METRICS
        off_grid = analysis in OFF_GRID_ANALYSES
        times = {i: (to_ms(rows[i].get("Bucket")), to_ms(rows[i].get("CapturedAt"))) for i in indexes}

        by_bin = {}
        for i in indexes:
            by_bin.setdefault(times[i][0], []).append(i)

        # Each save's rows of the series: their first and last bin, and how many bins; and the grain it declares, from the
        # first of its rows that has one.
        seen = {}
        declared = {}
        for i in indexes:
            at, captured = times[i]
            if at is not None and captured is not None:
                seen.setdefault(captured, set()).add(at)
            grain = declared_grain(rows[i].get("GrainMinutes"))
            if captured is not None and grain is not None and captured not in declared:
                declared[captured] = grain
        extents = {captured: (min(bins), max(bins), len(bins)) for captured, bins in seen.items()}

        saves = {}
        for i in indexes:
            captured = times[i][1]
            start = to_ms(rows[i].get("WindowStart"))
            end = to_ms(rows[i].get("WindowEnd"))
            extent = extents.get(captured) if captured is not None else None
            if captured is None or start is None or end is None or extent is None or captured in saves:
                continue
            step = declared.get(captured)
            if step is None:
                step = monitor_grain(start, end, monitor_bins.get((target, analysis, captured), ())) if monitor else sql_grain(start, end)
            grain = max(60, step) if hourly else step
            first, last, count = extent
            saves[captured] = _Save(
                captured,
                start,
                end,
                grain,
                max(first, start),
                min(last + grain * MINUTE, end),
                count == _js_round((last - first) / (grain * MINUTE)) + 1,
            )
        reaching = _Saves(saves)

        # Each bin's value per save, its rows summed, indexed by bin.
        points = _Points()
        for i in indexes:
            at, captured = times[i]
            if at is not None and captured is not None:
                points.add(at, captured, _number(rows[i].get("Value")))
        points.seal()

        for bin_at, group in by_bin.items():
            if bin_at is None or off_grid:
                if bin_at is None and not off_grid and all(rows[i].get("Value") is None for i in group):
                    continue
                newest = max((times[i][1] if times[i][1] is not None else -math.inf) for i in group)
                for i in group:
                    if times[i][1] == newest:
                        kept[i] = _number(rows[i].get("Value"))
                continue
            captures = []
            for i in group:
                if times[i][1] not in captures:
                    captures.append(times[i][1])
            for captured in captures:
                save = saves.get(captured) if captured is not None else None
                if save is None:
                    continue
                value = points.values.get((bin_at, captured), 0)
                own = _own(bin_at, save, value, reaching, points, adds)
                if own is None:
                    continue
                members = [i for i in group if times[i][1] == captured]
                if own == value or not adds:
                    for i in members:
                        kept[i] = _number(rows[i].get("Value"))
                elif len(members) == 1:
                    kept[members[0]] = float(own)
                else:
                    # A total's remainder, split across the save's rows at the bin by their values (evenly when they sum to 0).
                    values = [_number(rows[i].get("Value")) for i in members]
                    whole = math.fsum(values)
                    for i, row_value in zip(members, values):
                        kept[i] = own * row_value / whole if whole else own / len(members)
    return kept


def bin_values(rows, kept) -> dict:
    """
    The model's read of the kept values, by (target, analysis, metric, bin in epoch milliseconds or None): the sum for a
    total, and for a maximum or an average the highest of each save's sum. A bin whose rows all keep None isn't there.
    """
    sums = {}
    for row, value in zip(rows, kept):
        if value is None:
            continue
        key = (_text(row.get("TargetKey")), _text(row.get("AnalysisKey")), _text(row.get("Metric")), to_ms(row.get("Bucket")))
        per_save = sums.setdefault(key, {})
        captured = to_ms(row.get("CapturedAt"))
        per_save[captured] = per_save.get(captured, 0) + value
    values = {}
    for key, per_save in sums.items():
        adds = key[1] in ADDITIVE_ANALYSES or key[2] in ADDITIVE_METRICS
        values[key] = math.fsum(per_save.values()) if adds else max(per_save.values())
    return values


# ---------------------------------------------------------------------------------------------------------------------
# The lakehouse: F35's columns in telemetry_snapshots, and the resolve that fills them. Spark SQL only, and lakehouse
# data only: no Azure or Fabric resource changes. A notebook cell and a Livy statement run it the same way.

KEPT_TABLE = "telemetry_snapshots"
# The columns F35 adds, in the order ALTER TABLE adds them, with their Spark SQL types.
KEPT_COLUMNS = (("grain_minutes", "INT"), ("kept_value", "DOUBLE"), ("resolved_at_utc", "TIMESTAMP"))
# How many times a commit is tried when another writer commits to the table at the same moment.
KEPT_ATTEMPTS = 5
# The days a chunk works out at once, and about how many rows a batch reads (a demo's day of history is about 31,000).
KEPT_CHUNK_DAYS = 7
KEPT_BATCH_ROWS = 400_000
# Delta's exceptions when a concurrent commit conflicts with this one (https://docs.delta.io/latest/concurrency-control.html).
_CONCURRENT_WRITES = ("ConcurrentAppendException", "ConcurrentDeleteReadException", "ConcurrentDeleteDeleteException",
                      "ConcurrentTransactionException", "MetadataChangedException")
_DAY_US = 86_400_000_000
_RUN_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9:._-]{0,199}")
_TABLE_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]{0,127}(\.[A-Za-z_][A-Za-z0-9_]{0,127}){0,2}")
# The rows the rule works out: binned rows of the grid's analyses, with a capture time and a window, and a value that's a
# number or none. Rows off the grid keep both columns null, and the model reads them by the release's rule.
_RESOLVABLE = ("t.target IS NOT NULL AND t.analysis IS NOT NULL AND t.metric IS NOT NULL AND t.bucket_utc IS NOT NULL "
               "AND t.captured_at_utc IS NOT NULL AND t.window_start_utc IS NOT NULL AND t.window_end_utc IS NOT NULL "
               "AND NOT isnan(t.value) AND t.analysis NOT IN (%s)" % ", ".join("'%s'" % name for name in sorted(OFF_GRID_ANALYSES)))
_UPDATE_SCHEMA = ("run_id STRING, captured_us BIGINT, target STRING, analysis STRING, metric STRING, bucket_us BIGINT, "
                  "resource_type STRING, resource_name STRING, instance_name STRING, database_name STRING, value DOUBLE, "
                  "kept_value DOUBLE, resolved_us BIGINT")


def _concurrent(error) -> bool:
    """Whether an error is Delta's report of a concurrent commit, whatever Python class carries it."""
    text = "%s %s" % (type(error).__name__, error)
    return any(name in text for name in _CONCURRENT_WRITES)


def _first_line(error, limit=400) -> str:
    text = ("%s: %s" % (type(error).__name__, error)).strip().splitlines()
    return (text[0] if text else type(error).__name__)[:limit]


class _SparkHistory:
    """telemetry_snapshots through Spark SQL: what the step reads and writes. Tests give kept_value_step another one."""

    def __init__(self, spark, table):
        if not _TABLE_NAME.fullmatch(table):
            raise ValueError("Not a table name: %r" % table)
        self.spark = spark
        self.table = table

    def columns(self):
        """The table's column names, in lower case, by DESCRIBE TABLE; None when there's no table."""
        if not self.spark.catalog.tableExists(self.table):
            return None
        return {str(row["col_name"]).strip().lower() for row in self.spark.sql("DESCRIBE TABLE %s" % self.table).collect() if row["col_name"]}

    def add_columns(self, columns):
        self.spark.sql("ALTER TABLE %s ADD COLUMNS (%s)" % (self.table, ", ".join("%s %s" % pair for pair in columns)))

    def profile(self, seed):
        """Per target, analysis, and UTC day of the bin: how many resolvable rows, and how many of them are seeds."""
        return [(row["target"], row["analysis"], int(row["day"]), int(row["n"]), int(row["seeds"])) for row in self.spark.sql(
            "SELECT t.target, t.analysis, unix_micros(t.bucket_utc) div %d AS day, count(*) AS n, count_if(%s) AS seeds "
            "FROM %s t WHERE %s GROUP BY t.target, t.analysis, unix_micros(t.bucket_utc) div %d"
            % (_DAY_US, seed, self.table, _RESOLVABLE, _DAY_US)).collect()]

    def read(self, items):
        """
        The rows of every save of an item's target and analysis that has a row in the item's range (whole saves, so each
        one's extent and step are its own), each with its item: items are (item, target, analysis, from, to), in epoch
        microseconds.
        """
        view = "kept_value_items_%s" % uuid.uuid4().hex[:12]
        self.spark.createDataFrame(list(items), "item INT, target STRING, analysis STRING, lo BIGINT, hi BIGINT").createOrReplaceTempView(view)
        try:
            return [row.asDict() for row in self.spark.sql(
                "SELECT c.item, t.target, t.analysis, t.metric, unix_micros(t.bucket_utc) AS bucket_us, "
                "unix_micros(t.captured_at_utc) AS captured_us, unix_micros(t.window_start_utc) AS start_us, "
                "unix_micros(t.window_end_utc) AS end_us, t.value, t.grain_minutes, t.run_id, t.resource_type, t.resource_name, "
                "t.instance_name, t.database_name, t.kept_value, unix_micros(t.resolved_at_utc) AS resolved_us "
                "FROM %s t JOIN (SELECT DISTINCT i.item, t.target, t.analysis, t.captured_at_utc FROM %s t JOIN %s i "
                "ON t.target = i.target AND t.analysis = i.analysis AND t.bucket_utc >= timestamp_micros(i.lo) "
                "AND t.bucket_utc < timestamp_micros(i.hi) WHERE %s) c "
                "ON t.target = c.target AND t.analysis = c.analysis AND t.captured_at_utc = c.captured_at_utc WHERE %s"
                % (self.table, self.table, view, _RESOLVABLE, _RESOLVABLE)).collect()]
        finally:
            self.spark.catalog.dropTempView(view)

    def merge(self, updates):
        """
        MERGEs kept_value and resolved_at_utc into the rows that match an update exactly, unless a later step already
        worked a row out. Returns how many rows it updated.
        """
        low = min(update[5] for update in updates)
        high = max(update[5] for update in updates) + 1
        view = "kept_value_updates_%s" % uuid.uuid4().hex[:12]
        self.spark.createDataFrame(updates, _UPDATE_SCHEMA).createOrReplaceTempView(view)
        try:
            result = self.spark.sql(
                "MERGE INTO %s AS t USING (SELECT run_id, target, analysis, metric, resource_type, resource_name, instance_name, "
                "database_name, value, kept_value, timestamp_micros(captured_us) AS captured_at_utc, "
                "timestamp_micros(bucket_us) AS bucket_utc, timestamp_micros(resolved_us) AS resolved_at_utc FROM %s) AS s "
                "ON t.bucket_utc >= timestamp_micros(%d) AND t.bucket_utc < timestamp_micros(%d) "
                "AND t.bucket_utc = s.bucket_utc AND t.captured_at_utc = s.captured_at_utc AND t.target = s.target "
                "AND t.analysis = s.analysis AND t.metric = s.metric AND t.run_id <=> s.run_id "
                "AND t.resource_type <=> s.resource_type AND t.resource_name <=> s.resource_name "
                "AND t.instance_name <=> s.instance_name AND t.database_name <=> s.database_name AND t.value <=> s.value "
                "WHEN MATCHED AND (t.resolved_at_utc IS NULL OR t.resolved_at_utc <= s.resolved_at_utc) "
                "THEN UPDATE SET kept_value = s.kept_value, resolved_at_utc = s.resolved_at_utc"
                % (self.table, view, low, high)).collect()
        finally:
            self.spark.catalog.dropTempView(view)
        first = result[0].asDict() if result else {}
        return int(first["num_updated_rows"]) if first.get("num_updated_rows") is not None else len(updates)

    def pending(self):
        """How many resolvable rows aren't worked out yet."""
        return int(self.spark.sql("SELECT count(*) AS n FROM %s t WHERE %s AND t.resolved_at_utc IS NULL" % (self.table, _RESOLVABLE)).collect()[0]["n"])


def _retrying(action, attempts, counter):
    """Runs action, again after a pause when Delta reports a concurrent commit, up to attempts times."""
    for attempt in range(1, attempts + 1):
        counter["attempts"] += 1
        try:
            return action()
        except Exception as error:
            if attempt == attempts or not _concurrent(error):
                raise
            time.sleep(min(30.0, 2.0 ** attempt) * (0.5 + random.random()))
    return None


def kept_columns_missing(spark, table=KEPT_TABLE, history=None):
    """F35's columns that the table lacks, by DESCRIBE TABLE, in KEPT_COLUMNS' order; None when there's no table."""
    names = (history or _SparkHistory(spark, table)).columns()
    return None if names is None else [name for name, _ in KEPT_COLUMNS if name not in names]


def add_kept_columns(spark, table=KEPT_TABLE, history=None):
    """Adds F35's missing columns with one ALTER TABLE ... ADD COLUMNS; returns the names it added. Lakehouse data only."""
    history = history or _SparkHistory(spark, table)
    missing = kept_columns_missing(spark, table, history)
    if not missing:
        return []
    types = dict(KEPT_COLUMNS)
    try:
        history.add_columns([(name, types[name]) for name in missing])
    except Exception:
        # Another run may have added them at the same moment: what's still missing decides.
        if kept_columns_missing(spark, table, history):
            raise
        return []
    return missing


def _plan(profile, chunk_days, batch_rows) -> list:
    """
    The batches to read: each a list of items (target, analysis, first day, day after the last), whose days are the seeds'
    days and the day either side, where a seed changes what the rows keep; a pair's contiguous days are cut into chunks of
    at most chunk_days, and items are grouped while their rows, with the day after each, stay under batch_rows.
    """
    pairs = {}
    for target, analysis, day, count, seeds in profile:
        entry = pairs.setdefault((target, analysis), ({}, set()))
        entry[0][day] = entry[0].get(day, 0) + count
        if seeds:
            entry[1].add(day)
    items = []
    for (target, analysis), (counts, seed_days) in sorted(pairs.items()):
        days = sorted({day + offset for day in seed_days for offset in (-1, 0, 1)})
        runs = []
        for day in days:
            if runs and day == runs[-1][1] and day - runs[-1][0] < chunk_days:
                runs[-1][1] = day + 1
            else:
                runs.append([day, day + 1])
        for first, after in runs:
            items.append((target, analysis, first, after, sum(counts.get(day, 0) for day in range(first, after + 1))))
    batches, batch, size = [], [], 0
    for target, analysis, first, after, estimate in items:
        if batch and size + estimate > batch_rows:
            batches.append(batch)
            batch, size = [], 0
        batch.append((target, analysis, first, after))
        size += estimate
    if batch:
        batches.append(batch)
    return batches


def _same(before, after) -> bool:
    return before is None and after is None or (before is not None and after is not None and float(before) == float(after))


def _work_out(rows, items, resolved_us) -> list:
    """
    The updates for a batch's rows: each item's rows go through kept_values together, and a row whose bin is on the
    item's days gets an update unless it's worked out already with the same kept value. One update for identical rows.
    """
    by_item = {}
    for row in rows:
        by_item.setdefault(row["item"], []).append(row)
    updates = {}
    for item, members in by_item.items():
        _, _, first, after = items[item]
        kept = kept_values([{
            "TargetKey": row["target"], "AnalysisKey": row["analysis"], "Metric": row["metric"], "Bucket": row["bucket_us"] // 1000,
            "CapturedAt": row["captured_us"] // 1000, "WindowStart": row["start_us"] // 1000, "WindowEnd": row["end_us"] // 1000,
            "Value": row["value"], "GrainMinutes": row["grain_minutes"],
        } for row in members])
        for row, value in zip(members, kept):
            if not first <= row["bucket_us"] // _DAY_US < after:
                continue
            if row["resolved_us"] is not None and _same(row["kept_value"], value):
                continue
            key = (row["run_id"], row["captured_us"], row["target"], row["analysis"], row["metric"], row["bucket_us"],
                   row["resource_type"], row["resource_name"], row["instance_name"], row["database_name"], row["value"])
            updates.setdefault(key, None if value is None else float(value))
    return [key + (value, resolved_us) for key, value in updates.items()]


def resolve_kept_values(spark, table=KEPT_TABLE, run_id=None, everything=False, history=None, chunk_days=KEPT_CHUNK_DAYS,
                        batch_rows=KEPT_BATCH_ROWS, attempts=KEPT_ATTEMPTS) -> dict:
    """
    Works out kept_value for the rows not resolved yet (or run_id's rows, or with everything, every row) and the rows
    around them whose kept value they change, and MERGEs it with resolved_at_utc, the time just before each read, into the
    table. Each batch reads its rows again and MERGEs again after Delta reports a concurrent commit, up to attempts
    times; a row that a later step already worked out isn't overwritten. Needs F35's columns. Returns what it did.
    """
    history = history or _SparkHistory(spark, table)
    if run_id is not None and not _RUN_ID.fullmatch(str(run_id)):
        raise ValueError("Not a run ID: %r" % (run_id,))
    scope = "everything" if everything else "run" if run_id is not None else "unresolved"
    seed = "true" if everything else "t.run_id = '%s'" % run_id if run_id is not None else "t.resolved_at_utc IS NULL"
    stats = {"scope": scope, "batches": 0, "read": 0, "resolved": 0, "attempts": 0}
    batches = _plan(history.profile(seed), chunk_days, batch_rows)
    for batch in batches:
        items = dict(enumerate(batch))

        def attempt(items=items):
            resolved_us = (datetime.now(timezone.utc) - _EPOCH) // timedelta(microseconds=1)
            rows = history.read([(item, target, analysis, first * _DAY_US, (after + 1) * _DAY_US)
                                 for item, (target, analysis, first, after) in items.items()])
            updates = _work_out(rows, items, resolved_us)
            return len(rows), history.merge(updates) if updates else 0

        read, resolved = _retrying(attempt, attempts, stats)
        stats["batches"] += 1
        stats["read"] += read
        stats["resolved"] += resolved
    return stats


def pending_kept_rows(spark, table=KEPT_TABLE, history=None) -> int:
    """How many rows the resolve still has to work out (binned rows of the grid's analyses with resolved_at_utc null)."""
    return (history or _SparkHistory(spark, table)).pending()


def kept_value_step(spark, table=KEPT_TABLE, add_columns=True, run_id=None, everything=False, history=None) -> dict:
    """
    F35's step, for a notebook cell or a Livy statement (print(json.dumps(kept_value_step(spark)))): DESCRIBE TABLE, then
    F35's missing columns added with add_columns, then the rows resolved (resolve_kept_values) once all three columns are
    there. Returns a JSON-ready dict: version, table, exists, missing (before the step), added, form ("Kept" when all three
    columns are there after it, which configure-powerbi.ps1 -SnapshotValueForm takes, else "Release"), scope, read,
    resolved, pending, attempts, seconds, and error, null when it finished. It never raises: rows it couldn't work out
    stay unresolved, and read as today's.
    """
    started = time.monotonic()
    scope = "everything" if everything else "run" if run_id is not None else "unresolved"
    result = {"version": 1, "table": table, "exists": False, "missing": [], "added": [], "form": "Release", "scope": scope,
              "read": 0, "resolved": 0, "pending": 0, "attempts": 0, "seconds": 0.0, "error": None}
    try:
        history = history or _SparkHistory(spark, table)
        missing = kept_columns_missing(spark, table, history)
        if missing is not None:
            result["exists"] = True
            result["missing"] = list(missing)
            if missing and add_columns:
                counter = {"attempts": 0}
                result["added"] = _retrying(lambda: add_kept_columns(spark, table, history), KEPT_ATTEMPTS, counter)
                missing = kept_columns_missing(spark, table, history)
            if not missing:
                result["form"] = "Kept"
                stats = resolve_kept_values(spark, table, run_id=run_id, everything=everything, history=history)
                result.update(read=stats["read"], resolved=stats["resolved"], attempts=stats["attempts"])
                result["pending"] = pending_kept_rows(spark, table, history)
    except Exception as error:
        result["error"] = _first_line(error)
    result["seconds"] = round(time.monotonic() - started, 1)
    return result
