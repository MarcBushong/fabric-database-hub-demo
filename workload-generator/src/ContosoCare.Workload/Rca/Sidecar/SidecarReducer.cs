using System.Globalization;
using System.Text;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>
/// The sidecar's reducer (rca/README.md, Limits): encodes a draft as a sidecar and fits it to the smaller of a
/// document's 64 KiB of gzip and what's left of its host's session budget. Over that, it cuts in the contract's order,
/// each kind of cut only as far as the document needs:
/// <list type="number">
/// <item>waits past each plan's first three, by time waited;</item>
/// <item>plan summaries, set to null, the lowest-ranked queries' plans first;</item>
/// <item>the lowest-ranked queries: all of a query's rows in its interval, and its plans' rows once it has none left,
/// unless a plan is forced or an event names it.</item>
/// </list>
/// Past those, only so that a sidecar always fits: the connection samples thinned, keeping each target's first, peak,
/// and last, and then everything but the coverage. It never cuts coverage: each cut is a line in its target's
/// rca_query_coverage gaps (<see cref="GapPrefix"/>) and in <see cref="ReducedSidecar.Cuts"/>.
/// <para>
/// A query's rank in its interval is its best place in the top lists the reads rank by (rca/README.md, Query Store),
/// from the latest read of each plan: CPU, duration, logical reads, and waits on SQL Server; total time, blocks, and
/// sampled waits on PostgreSQL. Ties go to the lower plan_id, as the reads' do. The same draft gives the same bytes.
/// </para>
/// </summary>
internal sealed class SidecarReducer : ISidecarReducer
{
    /// <summary>How each cut's line in a coverage row's gaps begins.</summary>
    public const string GapPrefix = "the sidecar's budget: ";

    /// <summary>A coverage row's gaps for a target the draft has no coverage row for.</summary>
    public const string NoReadGap = "No Query Store read of this target is recorded in this window.";

    private const int KeptWaits = 3;

    private static readonly string[] SqlServerLists = ["cpu_ms", "duration_ms", "logical_reads", "wait_ms"];

    private static readonly string[] PostgresLists = ["duration_ms", "logical_reads", "wait_ms"];

    private static readonly Dictionary<string, string> TableNames = new(StringComparer.Ordinal)
    {
        [RcaContract.QueryStats] = "RCA Query Stats",
        [RcaContract.QueryWaits] = "RCA Query Waits",
        [RcaContract.QueryPlans] = "RCA Query Plans",
        [RcaContract.QueryEvents] = "RCA Query Events",
        [RcaContract.Connections] = "RCA Connections",
    };

    public ReducedSidecar Reduce(SidecarDraft draft, int remainingSessionBytes)
    {
        ArgumentNullException.ThrowIfNull(draft);
        var budget = SidecarBudget.ForDocument(remainingSessionBytes);
        var tables = new Dictionary<string, List<CaptureRow>>(StringComparer.Ordinal);
        foreach (var (name, rows) in draft.Tables)
        {
            tables[name] = [.. rows];
        }

        EnsureCoverage(draft, tables);
        var cuts = new List<Cut>();
        var current = Measure(draft, tables, cuts);
        if (current.Fits(budget))
        {
            return Result(current, cuts);
        }

        Ranking? ranking = null;
        var steps = new List<Func<Dictionary<string, List<CaptureRow>>, Step>>
        {
            WaitsPastTheFirstThree,
            t => PlanSummaries(t, ranking ??= Ranking.Of(t)),
            t => LowestRankedQueries(t, ranking ??= Ranking.Of(t)),
            ThinConnections,
            OnlyCoverage,
        };

        foreach (var next in steps)
        {
            var step = next(tables);
            if (step.Units == 0)
            {
                continue;
            }

            // The whole step first: when even that doesn't fit, it's taken whole and the next kind of cut follows.
            var whole = step.Apply(step.Units);
            var measured = Measure(draft, whole.Tables, [.. cuts, .. whole.Cuts]);
            if (!measured.Fits(budget))
            {
                tables = whole.Tables;
                cuts.AddRange(whole.Cuts);
                current = measured;
                continue;
            }

            // Otherwise the fewest units that fit: the measure falls as units go, and the result is always one that fits.
            var (low, high, best, bestMeasured) = (1, step.Units, whole, measured);
            while (low < high)
            {
                var middle = low + ((high - low) / 2);
                var trial = step.Apply(middle);
                var trialMeasured = Measure(draft, trial.Tables, [.. cuts, .. trial.Cuts]);
                if (trialMeasured.Fits(budget))
                {
                    (high, best, bestMeasured) = (middle, trial, trialMeasured);
                }
                else
                {
                    low = middle + 1;
                }
            }

            cuts.AddRange(best.Cuts);
            return Result(bestMeasured, cuts);
        }

        // Only the coverage is left, and it's still over: it stays, since it says what was cut.
        return Result(current, cuts);
    }

    private static ReducedSidecar Result(Measured measured, List<Cut> cuts)
    {
        if (measured.Json is null || measured.Gzip is null)
        {
            throw new InvalidOperationException("The sidecar is past a document's limits even with only its coverage.");
        }

        return new ReducedSidecar(measured.Json, measured.Gzip, PartCodec.Sha256(measured.Gzip), PartCodec.PartCount(measured.Gzip.Length), [.. cuts.Select(c => c.Target + ": " + c.Line)]);
    }

    private static Measured Measure(SidecarDraft draft, Dictionary<string, List<CaptureRow>> tables, IReadOnlyList<Cut> cuts)
    {
        var withGaps = WithGaps(draft, tables, cuts);

        // Past a document's 20,000 rows or strings is over budget too: the encoder refuses it, so it isn't measured.
        if (!SidecarDocument.WithinLimits(withGaps))
        {
            return new Measured(null, null);
        }

        var json = SidecarDocument.Write(draft with { Tables = withGaps });
        return new Measured(json, PartCodec.Gzip(json));
    }

    /// <summary>A coverage row for each of the draft's targets that has none, so the sidecar is whole and says so.</summary>
    private static void EnsureCoverage(SidecarDraft draft, Dictionary<string, List<CaptureRow>> tables)
    {
        var coverage = tables.TryGetValue(RcaContract.QueryCoverage, out var rows) ? rows : [];
        var covered = coverage.Select(TargetOf).ToHashSet(StringComparer.Ordinal);
        var missing = draft.Targets.Distinct(StringComparer.Ordinal).Where(t => !covered.Contains(t)).Order(StringComparer.Ordinal).ToList();
        if (missing.Count == 0 && rows is not null)
        {
            return;
        }

        tables[RcaContract.QueryCoverage] = [.. coverage, .. missing.Select(t => NewCoverage(draft, t, NoReadGap))];
    }

    private static CaptureRow NewCoverage(SidecarDraft draft, string target, string gaps) =>
        new CaptureRow(RcaContract.QueryCoverage, target, draft.WindowStartUtc, "coverage")
            .Set("target", target)
            .Set("window_start_utc", draft.WindowStartUtc)
            .Set("window_end_utc", draft.WindowEndUtc)
            .Set("backfill", false)
            .Set("gaps", gaps);

    /// <summary>The tables with each target's cut lines added to its coverage row's gaps, in the order the cuts were made.</summary>
    private static Dictionary<string, List<CaptureRow>> WithGaps(SidecarDraft draft, Dictionary<string, List<CaptureRow>> tables, IReadOnlyList<Cut> cuts)
    {
        var result = new Dictionary<string, List<CaptureRow>>(tables, StringComparer.Ordinal);
        if (cuts.Count == 0)
        {
            return result;
        }

        var lines = cuts.GroupBy(c => c.Target, StringComparer.Ordinal).ToDictionary(g => g.Key, g => g.Select(c => c.Line).ToList(), StringComparer.Ordinal);
        var coverage = new List<CaptureRow>();
        var done = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in result.GetValueOrDefault(RcaContract.QueryCoverage) ?? [])
        {
            var target = TargetOf(row);
            if (lines.TryGetValue(target, out var targetLines) && done.Add(target))
            {
                coverage.Add(Copy(row).Set("gaps", JoinGaps(row.Get("gaps") as string, targetLines)));
            }
            else
            {
                coverage.Add(row);
            }
        }

        foreach (var target in lines.Keys.Where(t => !done.Contains(t)).Order(StringComparer.Ordinal))
        {
            coverage.Add(NewCoverage(draft, target, JoinGaps(null, lines[target])));
        }

        result[RcaContract.QueryCoverage] = coverage;
        return result;
    }

    /// <summary>
    /// A coverage row's gaps, one per line, with the cut lines last. Within a dictionary string's 4,000 characters, the
    /// cut lines always stay: the earlier lines give way first, counted in a line of their own.
    /// </summary>
    private static string JoinGaps(string? existing, IReadOnlyList<string> cutLines)
    {
        var tail = string.Join('\n', cutLines);
        var room = RcaContract.MaximumStringLength - 40 - tail.Length;
        var earlier = string.IsNullOrEmpty(existing) ? [] : existing.Split('\n');
        var builder = new StringBuilder();
        var i = 0;
        for (; i < earlier.Length; i++)
        {
            var line = (builder.Length == 0 ? string.Empty : "\n") + earlier[i];
            if (builder.Length + line.Length + 1 > room)
            {
                break;
            }

            builder.Append(line);
        }

        if (i < earlier.Length)
        {
            builder.Append(builder.Length == 0 ? string.Empty : "\n").Append(CultureInfo.InvariantCulture, $"... and {earlier.Length - i} more.");
        }

        return builder.Length == 0 ? tail : builder.Append('\n').Append(tail).ToString();
    }

    /// <summary>1. Waits past each plan's first three, by time waited: per target, login, query, and plan, across the sidecar's intervals.</summary>
    private static Step WaitsPastTheFirstThree(Dictionary<string, List<CaptureRow>> tables)
    {
        var waits = Rows(tables, RcaContract.QueryWaits);
        var drop = new HashSet<int>();
        foreach (var plan in waits.Select((Row, Index) => (Row, Index)).GroupBy(w => (Target: TargetOf(w.Row), Login: Login(w.Row), Query: Id(w.Row, "query_id"), Plan: Id(w.Row, "plan_id"))))
        {
            drop.UnionWith(plan
                .OrderByDescending(w => Number(w.Row, "wait_ms"))
                .ThenBy(w => Time(w.Row, "interval_start_utc"))
                .ThenBy(w => w.Row.At)
                .ThenBy(w => w.Index)
                .Skip(KeptWaits)
                .Select(w => w.Index));
        }

        if (drop.Count == 0)
        {
            return Step.None;
        }

        return new Step(1, _ =>
        {
            var result = new Dictionary<string, List<CaptureRow>>(tables, StringComparer.Ordinal)
            {
                [RcaContract.QueryWaits] = [.. waits.Where((_, i) => !drop.Contains(i))],
            };
            var cuts = waits.Select((row, i) => (Target: TargetOf(row), Dropped: drop.Contains(i)))
                .GroupBy(w => w.Target, StringComparer.Ordinal)
                .Where(g => g.Any(w => w.Dropped))
                .OrderBy(g => g.Key, StringComparer.Ordinal)
                .Select(g => new Cut(g.Key, GapPrefix + string.Create(CultureInfo.InvariantCulture, $"waits past each plan's first three, by time waited, left out: {g.Count(w => w.Dropped)} of {g.Count()} RCA Query Waits rows.")))
                .ToList();
            return (result, cuts);
        });
    }

    /// <summary>2. Plan summaries set to null, plan by plan: the lowest-ranked queries' plans first, and within a query, its lowest-ranked plans.</summary>
    private static Step PlanSummaries(Dictionary<string, List<CaptureRow>> tables, Ranking ranking)
    {
        var plans = Rows(tables, RcaContract.QueryPlans);
        var order = plans.Where(p => p.Get("plan_summary") is not null)
            .Select(PlanKey)
            .Distinct()
            .OrderByDescending(k => ranking.Queries.GetValueOrDefault((k.Target, k.Query), int.MaxValue))
            .ThenByDescending(k => ranking.Plans.TryGetValue(k, out var standing) ? standing.Rank : int.MaxValue)
            .ThenBy(k => ranking.Plans.TryGetValue(k, out var standing) ? standing.Metric : 0)
            .ThenBy(k => k.Target, StringComparer.Ordinal)
            .ThenByDescending(k => k.Query)
            .ThenByDescending(k => k.Plan)
            .ToList();
        if (order.Count == 0)
        {
            return Step.None;
        }

        return new Step(order.Count, units =>
        {
            var cut = order.Take(units).ToHashSet();
            var result = new Dictionary<string, List<CaptureRow>>(tables, StringComparer.Ordinal)
            {
                [RcaContract.QueryPlans] = [.. plans.Select(p => cut.Contains(PlanKey(p)) && p.Get("plan_summary") is not null ? Copy(p).Set("plan_summary", null) : p)],
            };
            var cuts = order.GroupBy(k => k.Target, StringComparer.Ordinal)
                .Where(g => g.Any(cut.Contains))
                .OrderBy(g => g.Key, StringComparer.Ordinal)
                .Select(g =>
                {
                    var left = g.Count(cut.Contains);
                    var of = g.Count();
                    return new Cut(g.Key, GapPrefix + (left == of
                        ? string.Create(CultureInfo.InvariantCulture, $"every plan summary left out: {Plural(of, "plan")}.")
                        : string.Create(CultureInfo.InvariantCulture, $"plan summaries left out for {left} of {of} plans, the lowest-ranked queries' first.")));
                })
                .ToList();
            return (result, cuts);
        });
    }

    /// <summary>3. The lowest-ranked queries, one interval at a time: all of a query's rows in its interval.</summary>
    private static Step LowestRankedQueries(Dictionary<string, List<CaptureRow>> tables, Ranking ranking)
    {
        if (ranking.Units.Count == 0)
        {
            return Step.None;
        }

        var stats = Rows(tables, RcaContract.QueryStats);
        var waits = Rows(tables, RcaContract.QueryWaits);
        var plans = Rows(tables, RcaContract.QueryPlans);
        var events = Rows(tables, RcaContract.QueryEvents);
        var queried = stats.Select(r => (TargetOf(r), Id(r, "query_id"))).ToHashSet();
        return new Step(ranking.Units.Count, units =>
        {
            var cut = ranking.Units.Take(units).ToHashSet();
            var statsKept = stats.Where(r => !cut.Contains(Unit(r))).ToList();
            var waitsKept = waits.Where(r => !cut.Contains(Unit(r))).ToList();
            var left = statsKept.Select(r => (TargetOf(r), Id(r, "query_id"))).ToHashSet();
            var plansKept = plans.Where(p =>
            {
                var query = (TargetOf(p), Id(p, "query_id"));
                return !queried.Contains(query) || left.Contains(query) || p.Get("is_forced_plan") is true || events.Any(e => NamesPlan(e, p));
            }).ToList();
            var result = new Dictionary<string, List<CaptureRow>>(tables, StringComparer.Ordinal)
            {
                [RcaContract.QueryStats] = statsKept,
                [RcaContract.QueryWaits] = waitsKept,
                [RcaContract.QueryPlans] = plansKept,
            };
            var cuts = new List<Cut>();
            foreach (var target in cut.Select(u => u.Target).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal))
            {
                var mine = cut.Where(u => u.Target == target).ToList();
                var statsLeftOut = stats.Count(r => TargetOf(r) == target) - statsKept.Count(r => TargetOf(r) == target);
                var waitsLeftOut = waits.Count(r => TargetOf(r) == target) - waitsKept.Count(r => TargetOf(r) == target);
                var plansLeftOut = plans.Count(r => TargetOf(r) == target) - plansKept.Count(r => TargetOf(r) == target);
                var from = mine.Min(u => u.Start).UtcDateTime;
                var to = mine.Max(u => u.End).UtcDateTime;
                cuts.Add(new Cut(target, GapPrefix + string.Create(CultureInfo.InvariantCulture, $"the lowest-ranked queries left out in {mine.Count} of {ranking.Units.Count(u => u.Target == target)} query intervals, from {from:HH:mm} to {to:HH:mm} UTC, all their rows: {statsLeftOut} RCA Query Stats, {waitsLeftOut} RCA Query Waits, and {plansLeftOut} RCA Query Plans rows.")));
            }

            return (result, cuts);
        });

        static bool NamesPlan(CaptureRow queryEvent, CaptureRow plan) =>
            TargetOf(queryEvent) == TargetOf(plan)
            && queryEvent.Get("query_id") is long query && query == Id(plan, "query_id")
            && (queryEvent.Get("plan_id") is not long id || id == Id(plan, "plan_id"));
    }

    /// <summary>Past the contract's cuts: each target's connection samples halved, its first, peak, and last always kept.</summary>
    private static Step ThinConnections(Dictionary<string, List<CaptureRow>> tables)
    {
        var rows = Rows(tables, RcaContract.Connections);
        var samples = rows.GroupBy(TargetOf, StringComparer.Ordinal)
            .OrderBy(g => g.Key, StringComparer.Ordinal)
            .Select(g =>
            {
                var times = g.Select(r => Time(r, "captured_at_utc")).Distinct().Order().ToList();
                var peak = g.GroupBy(r => Time(r, "captured_at_utc")).OrderByDescending(s => s.Sum(r => Id(r, "connections"))).ThenBy(s => s.Key).First().Key;
                return (Target: g.Key, Times: times, Fixed: new HashSet<DateTimeOffset> { times[0], times[^1], peak });
            })
            .ToList();
        var rounds = samples.Count == 0 ? 0 : samples.Max(s => s.Times.Count > s.Fixed.Count ? (int)Math.Ceiling(Math.Log2(s.Times.Count)) : 0);
        if (rounds == 0)
        {
            return Step.None;
        }

        return new Step(rounds, units =>
        {
            var stride = 1L << units;
            var keep = samples.ToDictionary(
                s => s.Target,
                s => s.Times.Where((t, i) => i % stride == 0 || s.Fixed.Contains(t)).ToHashSet(),
                StringComparer.Ordinal);
            var kept = rows.Where(r => keep[TargetOf(r)].Contains(Time(r, "captured_at_utc"))).ToList();
            var result = new Dictionary<string, List<CaptureRow>>(tables, StringComparer.Ordinal) { [RcaContract.Connections] = kept };
            var cuts = samples.Where(s => keep[s.Target].Count < s.Times.Count)
                .Select(s => new Cut(s.Target, GapPrefix + string.Create(CultureInfo.InvariantCulture, $"connection samples thinned to {keep[s.Target].Count} of {s.Times.Count} sample times, the first, the peak, and the last kept: {rows.Count(r => TargetOf(r) == s.Target) - kept.Count(r => TargetOf(r) == s.Target)} RCA Connections rows left out.")))
                .ToList();
            return (result, cuts);
        });
    }

    /// <summary>Past every other cut: only the coverage rows, which say what the sidecar left out and why.</summary>
    private static Step OnlyCoverage(Dictionary<string, List<CaptureRow>> tables)
    {
        var others = tables.Where(t => t.Key != RcaContract.QueryCoverage && t.Value.Count > 0).ToList();
        if (others.Count == 0)
        {
            return Step.None;
        }

        return new Step(1, _ =>
        {
            var result = new Dictionary<string, List<CaptureRow>>(StringComparer.Ordinal) { [RcaContract.QueryCoverage] = Rows(tables, RcaContract.QueryCoverage) };
            var cuts = others.SelectMany(t => t.Value.Select(r => (Target: TargetOf(r), Table: t.Key)))
                .GroupBy(r => r.Target, StringComparer.Ordinal)
                .OrderBy(g => g.Key, StringComparer.Ordinal)
                .Select(g =>
                {
                    var counts = RcaContract.SidecarTables.Select(t => (Name: t.Name, Rows: g.Count(r => r.Table == t.Name))).Where(t => t.Rows > 0)
                        .Select(t => string.Create(CultureInfo.InvariantCulture, $"{t.Rows} {TableNames.GetValueOrDefault(t.Name, t.Name)}"))
                        .ToList();
                    var list = counts.Count switch
                    {
                        1 => counts[0],
                        2 => counts[0] + " and " + counts[1],
                        _ => string.Join(", ", counts.Take(counts.Count - 1)) + ", and " + counts[^1],
                    };
                    return new Cut(g.Key, GapPrefix + $"only the coverage kept: {list} rows left out.");
                })
                .ToList();
            return (result, cuts);
        });
    }

    private static List<CaptureRow> Rows(Dictionary<string, List<CaptureRow>> tables, string table) => tables.TryGetValue(table, out var rows) ? rows : [];

    private static string TargetOf(CaptureRow row) => row.Get("target") as string ?? row.Target;

    private static string? Login(CaptureRow row) => row.Get("login_name") as string;

    private static long Id(CaptureRow row, string column) => row.Get(column) switch
    {
        long value => value,
        int value => value,
        _ => 0,
    };

    private static double Number(CaptureRow row, string column) => row.Get(column) switch
    {
        double value when double.IsFinite(value) => value,
        long value => value,
        int value => value,
        _ => 0,
    };

    private static DateTimeOffset Time(CaptureRow row, string column) => row.Get(column) is DateTimeOffset time ? time : row.At;

    private static bool IsPostgres(string target) => target.StartsWith("T4", StringComparison.Ordinal);

    private static (string Target, long Query, long Plan) PlanKey(CaptureRow row) => (TargetOf(row), Id(row, "query_id"), Id(row, "plan_id"));

    private static QueryUnit Unit(CaptureRow row) => new(TargetOf(row), Time(row, "interval_start_utc"), Time(row, "interval_end_utc"), Id(row, "query_id"));

    private static string Plural(int count, string noun) => string.Create(CultureInfo.InvariantCulture, $"{count} {noun}{(count == 1 ? string.Empty : "s")}");

    private static CaptureRow Copy(CaptureRow row)
    {
        var copy = new CaptureRow(row.Table, row.Target, row.At, row.Source, row.Sentinel);
        foreach (var (column, value) in row.Values)
        {
            copy.Set(column, value);
        }

        return copy;
    }

    /// <summary>One cut: its target and its line in that target's coverage gaps.</summary>
    private sealed record Cut(string Target, string Line);

    /// <summary>A measured candidate: its JSON and gzip, or neither when its tables are past a document's limits.</summary>
    private sealed record Measured(byte[]? Json, byte[]? Gzip)
    {
        public bool Fits(int budget) => Gzip is not null && Gzip.Length <= budget;
    }

    /// <summary>One kind of cut: how many units it can take, and the tables and cut lines with the first n of them taken.</summary>
    private sealed record Step(int Units, Func<int, (Dictionary<string, List<CaptureRow>> Tables, List<Cut> Cuts)> Apply)
    {
        public static Step None { get; } = new(0, _ => throw new InvalidOperationException("Nothing to cut."));
    }

    /// <summary>One query's rows in one interval on one target: what the third cut takes, one at a time.</summary>
    private readonly record struct QueryUnit(string Target, DateTimeOffset Start, DateTimeOffset End, long Query);

    /// <summary>A plan's best rank in any interval, and its largest total of the target's first list (CPU, or total time).</summary>
    private readonly record struct PlanStanding(int Rank, double Metric);

    /// <summary>The queries' and plans' ranks in their intervals, from the latest read of each plan.</summary>
    private sealed class Ranking
    {
        /// <summary>Every query's interval, the lowest-ranked first: the order the third cut takes them in.</summary>
        public List<QueryUnit> Units { get; private set; } = [];

        public Dictionary<(string Target, long Query, long Plan), PlanStanding> Plans { get; } = new();

        /// <summary>Each query's best rank in any interval.</summary>
        public Dictionary<(string Target, long Query), int> Queries { get; } = new();

        public static Ranking Of(Dictionary<string, List<CaptureRow>> tables)
        {
            var ranking = new Ranking();
            var latest = new Dictionary<(QueryUnit Unit, string? Login, long Plan), CaptureRow>();
            foreach (var row in Rows(tables, RcaContract.QueryStats))
            {
                var key = (Unit(row), Login(row), Id(row, "plan_id"));
                if (!latest.TryGetValue(key, out var seen) || Time(row, "captured_at_utc") >= Time(seen, "captured_at_utc"))
                {
                    latest[key] = row;
                }
            }

            var rank = new Dictionary<QueryUnit, int>();
            var metric = new Dictionary<QueryUnit, double>();
            foreach (var interval in latest.Keys.GroupBy(k => (k.Unit.Target, k.Unit.Start, k.Unit.End)))
            {
                var keys = interval.ToList();
                var lists = IsPostgres(interval.Key.Target) ? PostgresLists : SqlServerLists;
                var place = keys.ToDictionary(k => k, _ => int.MaxValue);
                foreach (var column in lists)
                {
                    var position = 0;
                    foreach (var key in keys.Where(k => Number(latest[k], column) > 0)
                        .OrderByDescending(k => Number(latest[k], column))
                        .ThenBy(k => k.Plan)
                        .ThenBy(k => k.Unit.Query)
                        .ThenBy(k => k.Login, StringComparer.Ordinal))
                    {
                        position++;
                        place[key] = Math.Min(place[key], position);
                    }
                }

                foreach (var key in keys)
                {
                    rank[key.Unit] = Math.Min(rank.GetValueOrDefault(key.Unit, int.MaxValue), place[key]);
                    metric[key.Unit] = metric.GetValueOrDefault(key.Unit) + Number(latest[key], lists[0]);
                }

                foreach (var plan in keys.GroupBy(k => (k.Unit.Target, k.Unit.Query, k.Plan)))
                {
                    var standing = new PlanStanding(plan.Min(k => place[k]), plan.Sum(k => Number(latest[k], lists[0])));
                    ranking.Plans[plan.Key] = ranking.Plans.TryGetValue(plan.Key, out var before)
                        ? new PlanStanding(Math.Min(before.Rank, standing.Rank), Math.Max(before.Metric, standing.Metric))
                        : standing;
                }
            }

            // A query's waits in an interval without its statistics rank last.
            foreach (var row in Rows(tables, RcaContract.QueryWaits))
            {
                var unit = Unit(row);
                if (!rank.ContainsKey(unit))
                {
                    rank[unit] = int.MaxValue;
                    metric[unit] = 0;
                }
            }

            foreach (var (unit, place) in rank)
            {
                ranking.Queries[(unit.Target, unit.Query)] = Math.Min(ranking.Queries.GetValueOrDefault((unit.Target, unit.Query), int.MaxValue), place);
            }

            ranking.Units = [.. rank.Keys
                .OrderByDescending(u => rank[u])
                .ThenBy(u => metric[u])
                .ThenBy(u => u.Start)
                .ThenBy(u => u.End)
                .ThenBy(u => u.Target, StringComparer.Ordinal)
                .ThenByDescending(u => u.Query)];
            return ranking;
        }
    }
}
