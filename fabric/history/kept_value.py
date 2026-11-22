"""F35, design (i): the kept value of each row of the history's telemetry snapshots.

The history keeps every save, each at its own interval (1 to 1,440 minutes), so one minute can be in several saves. Each
interval is taken from its finest save, by the rows each save holds: a coarser save's point keeps only what the finer
saves' rows in its interval don't hold, so nothing counts twice and nothing is lost. This is the rule of the app's
snapshotValues (fabric/app/src/data/snapshot-value.ts, which follows finestPerInterval in finest-per-interval.ts),
reduced to one kept value per raw row:

- A point (a save's rows of a series at one bin) that no finer save's rows reach keeps each row's value.
- A point that finer saves' rows cover keeps None in each row.
- Otherwise, a total keeps what's left of it after the finer rows in its interval, never below 0, split across its rows
  by their values; a maximum or an average keeps each row's value only where it's higher than theirs, else None.
- Off the bin grid, and for a row with no bin, the newest capture's rows keep their values, the others None.

The model reads them per series and bin (bin_values): the sum of the kept values for a total, and for a maximum or an
average the highest of each save's sum. A bin whose rows all keep None has no value. That equals snapshotValues' value
for the bin, which the shared cases (fabric/history/kept-value-cases.json, written from the TypeScript rule) pin.

Pure: the standard library only, no Spark or pandas, so a notebook cell, a Livy statement, and the tests run the same
code. Rows are mappings with the history model's column names (TargetKey, AnalysisKey, Metric, Bucket, CapturedAt,
WindowStart, WindowEnd, Value); a time is a datetime (naive is UTC), a pandas Timestamp, an ISO 8601 text, or epoch
milliseconds. Not used by the notebook or the model yet: the owner decides on design (i) first.
"""

from __future__ import annotations

import bisect
import math
import re
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
    """A finer save's row in a coarser point's interval: its span, its save's rank there, and what it keeps and leaves taken."""

    __slots__ = ("save", "value", "start", "end", "rank", "kept", "taken")

    def __init__(self, save, value, start, end, rank):
        self.save = save
        self.value = value
        self.start = start
        self.end = end
        self.rank = rank
        self.kept = value
        self.taken = value


def _covers(spans, start, end) -> bool:
    """The spans cover [start, end): no gap point, the start or a span's end inside it, lies outside every span."""
    if not spans:
        return False
    points = [start] + [s.end for s in spans if s.end < end - EPSILON]
    return all(any(s.start <= x + EPSILON and s.end > x + EPSILON for s in spans) for x in points)


def _finer_than(save: _Save, than: _Save) -> bool:
    return save.grain < than.grain or (save.grain == than.grain and save.captured > than.captured)


def _sum(values) -> float:
    """A sum in order, from 0, as the TypeScript rule's reduce adds."""
    total = 0
    for value in values:
        total = total + value
    return total


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
    finer = [s for s in saves.reaching(start, end) if _finer_than(s, save) and s.row_from < end and s.row_to > start]
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
        piece_value = points.values[(at, captured)]
        piece_start = max(at, other.start)
        piece_end = min(at + other.grain * MINUTE, other.end)
        if piece_start >= piece_end:
            piece_start, piece_end = at, at + other.grain * MINUTE
        rank = 1 + sum(1 for q in finer if _finer_than(q, other))
        pieces.append(_Piece(other, piece_value, piece_start, piece_end, rank))
    # The first save's rows keep all they hold; each later save's, what finestPerInterval keeps of them against every
    # earlier save's rows.
    earlier = [p for p in pieces if p.rank == 1]
    for level in sorted({p.rank for p in pieces if p.rank > 1}):
        rows = [p for p in pieces if p.rank == level]
        for row in rows:
            under = [u for u in earlier if u.start < row.end and u.end > row.start]
            covered = _covers(under, row.start, row.end)
            if not under:
                row.kept = row.value
            elif covered:
                row.kept = 0
            else:
                row.kept = max(0, row.value - _sum(u.kept for u in under))
            row.taken = None if covered else row.value
        earlier = earlier + rows
    under = [u for u in earlier if u.start < end and u.end > start]
    if not under:
        return value
    if _covers(under, start, end):
        return None
    if adds:
        return max(0, value - _sum(u.kept for u in under))
    taken = [u.taken for u in under if u.taken is not None]
    return value if not taken or value > max(taken) else None


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

        # Each save's rows of the series: their first and last bin, and how many bins.
        seen = {}
        for i in indexes:
            at, captured = times[i]
            if at is not None and captured is not None:
                seen.setdefault(captured, set()).add(at)
        extents = {captured: (min(bins), max(bins), len(bins)) for captured, bins in seen.items()}

        saves = {}
        for i in indexes:
            captured = times[i][1]
            start = to_ms(rows[i].get("WindowStart"))
            end = to_ms(rows[i].get("WindowEnd"))
            extent = extents.get(captured) if captured is not None else None
            if captured is None or start is None or end is None or extent is None or captured in saves:
                continue
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
