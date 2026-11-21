using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>
/// T1 and T2 (SQL Server 2022) and T3 (Azure SQL Database). The sentinel every 30 s for the whole session: the counters
/// (RCA-SQL-09) and the observer's event session (RCA-XE-02, or RCA-XE-04 on T3). A blocked process starts blocking
/// detail (RCA-SQL-01, 02 every 10 s) until 60 s without one; an error rate's jump takes one RCA-SQL-01 sample; a
/// deadlock count that rose with no graph reads system_health (RCA-SQL-12, T1 and T2). On T3, RCA-AZ-01 every 30
/// minutes and at the end. The event session ContosoCare_RCA is created at the start (after dropping one left behind)
/// and dropped at the end (ADR 0010's amendment). On T3 it's database-scoped
/// (https://learn.microsoft.com/azure/azure-sql/database/xevent-db-diff-from-svr).
/// </summary>
internal sealed partial class SqlTargetObserver(string target, DemoTarget gate, ICaptureConnector connector, ObserverOptions options, RunnerLog log)
    : TargetObserver(target, gate, connector, options, log, FixFor(gate))
{
    private const string DatabaseName = "ContosoCare";

    // How long a truncated read keeps remembering an event it left out: the ring buffer may still hold it (ReadEventsAsync).
    private static readonly TimeSpan EventMemory = TimeSpan.FromMinutes(20);

    // The fields the observer reads from each event (RCA-XE-00 lists what the server has; a missing one isn't captured).
    private static readonly Dictionary<string, string[]> Fields = new(StringComparer.Ordinal)
    {
        ["error_reported"] = ["error_number", "severity", "message", "is_intercepted"],
        ["lock_escalation"] = ["escalation_cause", "escalated_lock_count", "mode", "object_id"],
        ["xml_deadlock_report"] = ["xml_report"],
        ["database_xml_deadlock_report"] = ["xml_report"],
    };

    private readonly bool databaseScoped = gate == DemoTarget.T3;
    private readonly CounterDeltas deltas = new();
    private readonly Dictionary<long, string> objects = [];
    private readonly SeenEvents bufferEvents = new();
    private readonly SeenEvents healthEvents = new();
    private readonly SortedDictionary<DateTimeOffset, int> errorMinutes = [];
    private EpisodeTrigger blocking = null!;
    private EpisodeTrigger errors = null!;
    private Dictionary<string, HashSet<string>> eventFields = new(StringComparer.Ordinal);
    private bool eventSession;
    private long eventsDropped;
    private long? databaseId;
    private DateTimeOffset nextSentinel;
    private DateTimeOffset nextDetail;
    private DateTimeOffset nextResourceStats;
    private DateTimeOffset lastEventRead;
    private DateTimeOffset resourceStatsRead;
    private DateTimeOffset resourceStatsKept;
    private DateTimeOffset nextErrorMinute;
    private DateTimeOffset? deadlockSince;
    private DateTimeOffset deadlockSeen;
    private DateTimeOffset lastSentinel;
    private bool pendingErrorSample;
    private readonly List<(CaptureRow Row, long? ObjectId, string? Named, string? Cause, long? Count, string? Mode)> pendingEscalations = [];

    // Who ran each of the workload's sessions a blocking sample showed, by session and run token: lock_escalation's
    // actions have no login or host (RCA-XE-01), so an escalation takes them from its session's sample.
    private readonly Dictionary<(long Session, string Token), (string? Login, string? Host)> whoRan = [];

    public override async Task<DateTimeOffset> TickAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var tickStarted = now;
        if (now >= nextSentinel)
        {
            await SentinelAsync(now, cancellationToken).ConfigureAwait(false);
            nextSentinel = now + Every(Options.Sentinel);
        }

        if (blocking.Current is not null && !Cadence.DetailStopped && now >= nextDetail)
        {
            await BlockingSampleAsync(now, detail: true, cancellationToken).ConfigureAwait(false);
            nextDetail = now + Every(Options.BlockingDetail);
        }

        if (databaseScoped && now >= nextResourceStats)
        {
            await ResourceStatsAsync(now, cancellationToken).ConfigureAwait(false);
            nextResourceStats = now + Options.ResourceStats;
        }

        FlushEscalations();

        Sink.Watermark(Target, Earliest(tickStarted - Options.ClockSkew, eventSession ? lastEventRead - Options.EventLatency : null, databaseScoped ? resourceStatsRead - Options.EventLatency - TimeSpan.FromSeconds(15) : null));
        return Earliest(nextSentinel, blocking.Current is not null && !Cadence.DetailStopped ? nextDetail : null, databaseScoped ? nextResourceStats : null);
    }

    protected override async Task StartAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        blocking = new EpisodeTrigger(Ids, Options.QuietFor);
        errors = new EpisodeTrigger(Ids, Options.ErrorQuietFor);
        deltas.Clear();
        bufferEvents.Clear();
        healthEvents.Clear();
        errorMinutes.Clear();
        whoRan.Clear();
        nextSentinel = now;
        nextDetail = now;
        lastEventRead = now;
        lastSentinel = now;
        resourceStatsRead = now;
        resourceStatsKept = now;
        nextResourceStats = now + Options.ResourceStats;
        nextErrorMinute = Minute(now) + TimeSpan.FromMinutes(1);
        deadlockSince = null;
        eventsDropped = 0;
        await CreateEventSessionAsync(now, cancellationToken).ConfigureAwait(false);
    }

    protected override async Task StopAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        if (eventSession)
        {
            await ReadEventsAsync(now, cancellationToken).ConfigureAwait(false);
        }

        if (databaseScoped)
        {
            await ResourceStatsAsync(now, cancellationToken).ConfigureAwait(false);
        }

        FlushEscalations();
        Close(blocking, now);
        Close(errors, now);
        await DropEventSessionAsync(now, cancellationToken).ConfigureAwait(false);
    }

    private static string FixFor(DemoTarget target) => target switch
    {
        DemoTarget.T2 => "The fix: ./scripts/deploy.ps1 rebuilds T2 from Arc Jumpstart's image, where the runner's SYSTEM is a sysadmin (a guest whose SQL Server setup wizard was kept has no server permission for it).",
        DemoTarget.T3 => "The fix: ./scripts/deploy.ps1 makes T1's managed identity dbo of ContosoCare again through the administrators group, which holds VIEW DATABASE STATE and CREATE ANY DATABASE EVENT SESSION.",
        _ => "The fix: ./scripts/deploy.ps1 sets the runner up again as SYSTEM, a sysadmin through BUILTIN\\Administrators.",
    };

    private static DateTimeOffset Minute(DateTimeOffset at) => new(at.UtcDateTime.Ticks - (at.UtcDateTime.Ticks % TimeSpan.TicksPerMinute), TimeSpan.Zero);

    private async Task CreateEventSessionAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        eventSession = false;

        // A session a runner that stopped left behind goes first (RCA-XE-05), then the fields the events carry (RCA-XE-00).
        await DropEventSessionAsync(now, cancellationToken).ConfigureAwait(false);
        var fields = await RunAsync("RCA-XE-00", now, cancellationToken, timed: false, longRunning: true).ConfigureAwait(false);
        eventFields = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
        foreach (var row in fields ?? [])
        {
            if (row.Text("event_name") is { } name && row.Text("column_name") is { } column)
            {
                if (!eventFields.TryGetValue(name, out var set))
                {
                    eventFields[name] = set = new HashSet<string>(StringComparer.Ordinal);
                }

                set.Add(column);
            }
        }

        var create = databaseScoped ? "RCA-XE-03" : "RCA-XE-01";
        if (await RunAsync(create, now, cancellationToken, timed: false, longRunning: true).ConfigureAwait(false) is null)
        {
            Gap(now, $"{Target}'s event session wasn't created, so errors, attentions, and lock escalations aren't captured{(databaseScoped ? " and deadlocks only as counts" : "; deadlocks come from system_health (RCA-SQL-12)")}.");
            return;
        }

        eventSession = true;
        Source(now, create);
        foreach (var (name, wanted) in Fields)
        {
            if (databaseScoped == (name == "xml_deadlock_report"))
            {
                continue;
            }

            if (fields is not null && eventFields.TryGetValue(name, out var have))
            {
                foreach (var field in wanted.Where(f => !have.Contains(f)))
                {
                    Gap(now, $"{name} has no {field} field on {Target}, so it isn't captured.");
                }
            }
        }
    }

    private async Task DropEventSessionAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var dropped = await RunAsync("RCA-XE-05", now, cancellationToken, timed: false, longRunning: true, text: databaseScoped ? CaptureCatalog.DatabaseScopedDrop() : null).ConfigureAwait(false);
        if (dropped is null)
        {
            GapOnce(now, "drop", $"{Target}'s event session ContosoCare_RCA couldn't be dropped now; the next observer start or the runner's reset drops it.");
        }

        eventSession = false;
    }

    /// <summary>The sentinel: RCA-SQL-09's counters, then the event session's new events.</summary>
    private async Task SentinelAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var counters = await RunAsync("RCA-SQL-09", now, cancellationToken).ConfigureAwait(false);
        if (counters is not null)
        {
            var at = counters.Select(r => r.Time("captured_at_utc")).FirstOrDefault(t => t is not null) ?? now;
            var readings = Counters(counters);
            foreach (var (metric, (value, cumulative, unit)) in readings)
            {
                var reading = cumulative ? deltas.Next(metric, value) : value;
                Resource(at, "RCA-SQL-09", metric, reading, unit, sentinel: true);
                if (metric == "deadlocks" && reading > 0 && deadlockSince is null)
                {
                    deadlockSince = lastSentinel;
                    deadlockSeen = now;
                }
            }

            if (readings.TryGetValue("processes_blocked", out var blocked))
            {
                var count = blocked.Value ?? 0;
                var change = blocking.Observe(at, count > 0, count <= 0, () => string.Create(CultureInfo.InvariantCulture, $"processes_blocked {count:0} >= 1: blocking detail (RCA-SQL-01, RCA-SQL-02) every {Seconds(Every(Options.BlockingDetail))} s."));
                Report(blocking, change, at, $"processes_blocked 0 for {Duration(Options.QuietFor)}: {BackToSentinel}");
                if (change == EpisodeChange.Started)
                {
                    nextDetail = now;
                }
            }
            else
            {
                GapOnce(now, "processes-blocked", $"{Target} returned no Processes blocked counter, so its blocking detail can't start.");
            }

            lastSentinel = at;
        }

        if (eventSession)
        {
            await ReadEventsAsync(now, cancellationToken).ConfigureAwait(false);
        }

        if (pendingErrorSample)
        {
            // An error episode's start takes one RCA-SQL-01 sample (rca/README.md, Capture triggers).
            pendingErrorSample = false;
            await BlockingSampleAsync(now, detail: false, cancellationToken).ConfigureAwait(false);
        }

        await DeadlockFallbackAsync(now, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>RCA-SQL-09's rows as metrics (rca/README.md, Resource metrics): per-second counters are cumulative, so they're diffed.</summary>
    private static Dictionary<string, (double? Value, bool Cumulative, string Unit)> Counters(IReadOnlyList<CaptureValues> rows)
    {
        double? Pick(string counter, params string[] instances)
        {
            foreach (var instance in instances)
            {
                var row = rows.FirstOrDefault(r => string.Equals(r.Text("counter_name"), counter, StringComparison.OrdinalIgnoreCase) && string.Equals(r.Text("instance_name") ?? string.Empty, instance, StringComparison.OrdinalIgnoreCase));
                if (row is not null)
                {
                    return row.Double("cntr_value");
                }
            }

            return null;
        }

        var readings = new Dictionary<string, (double?, bool, string)>(StringComparer.Ordinal);
        void Add(string metric, double? value, bool cumulative, string unit = "count")
        {
            if (value is not null)
            {
                readings[metric] = (value, cumulative, unit);
            }
        }

        Add("processes_blocked", Pick("Processes blocked", string.Empty, "_Total"), false);
        Add("memory_grants_pending", Pick("Memory Grants Pending", string.Empty, "_Total"), false);
        Add("memory_grants_outstanding", Pick("Memory Grants Outstanding", string.Empty, "_Total"), false);
        Add("active_transactions", Pick("Active Transactions", DatabaseName, "_Total", string.Empty), false);
        Add("user_connections", Pick("User Connections", string.Empty, "_Total"), false);
        Add("lock_timeouts", Pick("Lock Timeouts/sec", "_Total", string.Empty), true);
        Add("deadlocks", Pick("Number of Deadlocks/sec", "_Total", string.Empty), true);
        Add("table_lock_escalations", Pick("Table Lock Escalations/sec", string.Empty, "_Total"), true);
        Add("attentions", Pick("SQL Attention rate", string.Empty, "_Total"), true);
        Add("log_flushes", Pick("Log Flushes/sec", DatabaseName, "_Total"), true);
        Add("log_flush_wait_ms", Pick("Log Flush Wait Time", DatabaseName, "_Total"), true, "ms");
        return readings;
    }

    /// <summary>RCA-SQL-01 and RCA-SQL-02: one blocking sample, a row per session in the chains.</summary>
    private async Task BlockingSampleAsync(DateTimeOffset now, bool detail, CancellationToken cancellationToken)
    {
        var sessions = await RunAsync("RCA-SQL-01", now, cancellationToken).ConfigureAwait(false);
        if (sessions is null)
        {
            return;
        }

        IReadOnlyList<CaptureValues> locks = [];
        if (detail)
        {
            locks = await RunAsync("RCA-SQL-02", now, cancellationToken).ConfigureAwait(false) ?? [];
        }

        var at = sessions.Select(r => r.Time("captured_at_utc")).FirstOrDefault(t => t is not null) ?? now;
        var source = detail ? "RCA-SQL-01,RCA-SQL-02" : "RCA-SQL-01";
        foreach (var row in SqlSessions.Build(Target, at, sessions, locks, source))
        {
            Write(row);
        }

        Learn(sessions, locks);
        if (detail)
        {
            var blocked = sessions.Count(r => (r.Long("blocking_session_id") ?? 0) != 0);
            var change = blocking.Observe(at, blocked > 0, blocked == 0, () => string.Empty, canStart: false);
            Report(blocking, change, at, $"processes_blocked 0 for {Duration(Options.QuietFor)}: {BackToSentinel}");
        }
    }

    /// <summary>Object names by ID (for lock escalations) and ContosoCare's database ID (for deadlock graphs), from what RCA-SQL-01 and 02 returned.</summary>
    private void Learn(IReadOnlyList<CaptureValues> sessions, IReadOnlyList<CaptureValues> locks)
    {
        foreach (var row in sessions)
        {
            if (ApplicationNames.Reduce(row.Text("program_name")) is { IsDemo: true, RunToken: { } token } && row.Long("session_id") is { } session)
            {
                whoRan[(session, token)] = (TextNormalizer.Name(row.Text("login_name")), TextNormalizer.Name(row.Text("host_name")));
            }
        }

        foreach (var row in locks)
        {
            if (string.Equals(row.Text("resource_type"), "OBJECT", StringComparison.Ordinal) && row.Long("resource_associated_entity_id") is { } id && TextNormalizer.Name(row.Text("object_name")) is { } name)
            {
                objects[id] = name;
            }
        }

        if (databaseId is null)
        {
            foreach (var row in sessions)
            {
                if (row.Text("wait_resource") is { } resource && DatabaseIdInResource().Match(resource) is { Success: true } match)
                {
                    databaseId = long.Parse(match.Groups["db"].Value, CultureInfo.InvariantCulture);
                    break;
                }
            }
        }
    }

    /// <summary>Reads the event session's ring buffer and keeps the events it hasn't kept yet.</summary>
    private async Task ReadEventsAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var result = await RunAsync(databaseScoped ? "RCA-XE-04" : "RCA-XE-02", now, cancellationToken, longRunning: true).ConfigureAwait(false);
        if (result is null)
        {
            return;
        }

        if (result.Count == 0)
        {
            // The session is gone (a reset dropped it): create it again, and say what may be missing.
            Gap(now, $"{Target}'s event session wasn't there at {now:HH:mm:ss} UTC; the observer created it again, so events just before may be missing.");
            await CreateEventSessionAsync(now, cancellationToken).ConfigureAwait(false);
            return;
        }

        XeRead read;
        try
        {
            read = ExtendedEvents.ParseRingBuffer(result[0].Text("target_data"));
        }
        catch (System.Xml.XmlException ex)
        {
            GapOnce(now, "xe-xml", $"{Target}'s event session returned XML the observer couldn't read: {Redactor.Redact(ex.Message)}");
            return;
        }

        lastEventRead = now;
        if (read.Dropped > eventsDropped)
        {
            Gap(now, string.Create(CultureInfo.InvariantCulture, $"{Target}'s event session dropped {read.Dropped - eventsDropped} event(s): its ring buffer was full."));
            eventsDropped = read.Dropped;
        }

        if (read.Truncated)
        {
            GapOnce(now, "xe-truncated", $"{Target}'s ring buffer held more than the 4 MB of XML a read returns, so events that didn't fit may be missing.");
        }

        var returned = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in read.Events.OrderBy(e => e.At))
        {
            returned.Add(item.Fingerprint);
            if (item.At < ObservingSince || !bufferEvents.Add(item))
            {
                continue;
            }

            Keep(item, databaseScoped ? "RCA-XE-03,RCA-XE-04" : "RCA-XE-01,RCA-XE-02");
        }

        // The ring buffer drops its oldest events first and never returns one again, so an event a complete read left out
        // is gone for good. A truncated read leaves out whatever didn't fit, from whichever end (Learn doesn't say), and
        // the buffer may still hold it, so then only events older than EventMemory are forgotten. An event the buffer
        // still returns is never written twice.
        bufferEvents.Forget((fingerprint, at) => !returned.Contains(fingerprint) && (!read.Truncated || at < now - EventMemory));

        EvaluateErrors(now);
    }

    /// <summary>One event as an RCA Events row; the workload's own sessions keep their text, login, and host.</summary>
    private void Keep(XeEvent item, string source)
    {
        var name = ApplicationNames.Reduce(item.Action("client_app_name"));
        if (name.IsObserver)
        {
            return;
        }

        var row = new CaptureRow(RcaContract.Events, Target, item.At, source)
            .Set("event_time_utc", item.At)
            .Set("target", Target)
            .Set("event_name", item.Name)
            .Set("session_id", item.ActionLong("session_id"))
            .Set("program_name", name.Program)
            .Set("run_token", name.RunToken)
            .Set("login_name", name.IsDemo ? TextNormalizer.Name(item.Action("username")) : null)
            .Set("host_name", name.IsDemo ? TextNormalizer.Name(item.Action("client_hostname")) : null)
            .Set("module_name", name.IsDemo ? Module(item.Action("sql_text")) : null)
            .Set("event_count", 1L);
        switch (item.Name)
        {
            case "error_reported":
                errorMinutes[Minute(item.At)] = errorMinutes.GetValueOrDefault(Minute(item.At)) + 1;
                row.Set("kind", "error")
                    .Set("code", item.Field("error_number"))
                    .Set("severity", item.FieldLong("severity") is { } severity ? (int)severity : null)
                    .Set("intercepted", bool.TryParse(item.Field("is_intercepted"), out var intercepted) ? intercepted : null)
                    .Set("detail", TextNormalizer.Message(item.Field("message")) ?? $"Error {item.Field("error_number") ?? "?"}.");
                break;
            case "attention":
                row.Set("kind", "attention")
                    .Set("detail", "The client cancelled the request, or its time-out expired (an attention).");
                break;
            case "lock_escalation":
                var lockMode = item.FieldText("mode");
                var count = item.FieldLong("escalated_lock_count") ?? item.FieldLong("hobt_lock_count");
                row.Set("kind", "escalation")
                    .Set("lock_mode", lockMode);
                // The same tick's blocking sample (RCA-SQL-01, 02) may name the object and who ran the session: resolved at the tick's end.
                pendingEscalations.Add((row, item.FieldLong("object_id"), TextNormalizer.Name(item.Field("object_name")), item.FieldText("escalation_cause"), count, lockMode));
                return;
            case "xml_deadlock_report" or "database_xml_deadlock_report":
                if (!KeepDeadlock(item, row))
                {
                    return;
                }

                break;
            default:
                return;
        }

        Write(row);
    }

    /// <summary>A lock escalation in plain words: <c>Lock threshold: 6,248 locks escalated to an X lock on the table.</c></summary>
    internal static string EscalationDetail(string? cause, long? count, string? mode, long? unknownObject)
    {
        var locks = count is { } c ? c.ToString("N0", CultureInfo.InvariantCulture) : "?";
        var table = mode is { Length: > 0 } m ? $"{(m[0] is 'A' or 'E' or 'F' or 'H' or 'I' or 'L' or 'M' or 'N' or 'O' or 'R' or 'S' or 'X' ? "an" : "a")} {m} lock on the table" : "a lock on the table";
        var id = unknownObject is { } objectId ? string.Create(CultureInfo.InvariantCulture, $" (object ID {objectId})") : string.Empty;
        return $"{cause ?? "Lock escalation"}: {locks} locks escalated to {table}{id}.";
    }

    /// <summary>Writes the escalations held for their object's name: named when a blocking sample showed the object, by ID otherwise.</summary>
    private void FlushEscalations()
    {
        foreach (var (row, objectId, named, cause, count, mode) in pendingEscalations)
        {
            var known = named ?? (objectId is { } id && objects.TryGetValue(id, out var name) ? name : null);
            if (row.Get("login_name") is null && row.Get("session_id") is long session && row.Get("run_token") is string token && whoRan.TryGetValue((session, token), out var who))
            {
                row.Set("login_name", who.Login).Set("host_name", who.Host);
            }

            Write(row.Set("object_name", known).Set("detail", EscalationDetail(cause, count, mode, known is null ? objectId : null)));
        }

        pendingEscalations.Clear();
    }

    private bool KeepDeadlock(XeEvent item, CaptureRow row)
    {
        var graph = item.Data.TryGetValue("xml_report", out var report) ? report.Xml ?? Parse(report.Value) : null;
        if (graph is null)
        {
            return false;
        }

        if (graph.Name.LocalName != "deadlock")
        {
            graph = graph.Descendants("deadlock").FirstOrDefault() ?? graph;
        }

        var summary = ExtendedEvents.ReduceDeadlock(graph, InDatabase);
        if (!summary.InDatabase)
        {
            return false;
        }

        deadlockSince = null;
        row.Set("kind", "deadlock")
            .Set("session_id", summary.Victim)
            .Set("program_name", summary.VictimName.Program)
            .Set("run_token", summary.VictimName.RunToken)
            .Set("login_name", summary.VictimLogin)
            .Set("host_name", summary.VictimHost)
            .Set("module_name", summary.VictimModule)
            .Set("object_name", summary.FirstObject)
            .Set("deadlock_json", summary.Json)
            .Set("detail", string.Create(CultureInfo.InvariantCulture, $"Deadlock: session {(summary.Victim is { } v ? v.ToString(CultureInfo.InvariantCulture) : "?")} was chosen as the victim; {summary.Processes} processes, {summary.Resources} resources."));
        return true;
    }

    private bool InDatabase(XElement process)
    {
        if (databaseScoped)
        {
            return true;
        }

        if ((string?)process.Attribute("currentdbname") is { } name)
        {
            return string.Equals(name, DatabaseName, StringComparison.OrdinalIgnoreCase);
        }

        return databaseId is { } id && long.TryParse((string?)process.Attribute("currentdb"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var current) && current == id;
    }

    /// <summary>The errors trigger: a minute with 10 errors or more and 3 times the median of the 10 minutes before.</summary>
    private void EvaluateErrors(DateTimeOffset now)
    {
        var complete = Minute(now - Options.EventLatency);
        while (nextErrorMinute <= complete)
        {
            var minute = nextErrorMinute - TimeSpan.FromMinutes(1);
            var count = errorMinutes.GetValueOrDefault(minute);
            var before = new List<double>();
            for (var m = minute - TimeSpan.FromMinutes(10); m < minute; m += TimeSpan.FromMinutes(1))
            {
                if (m >= Minute(ObservingSince))
                {
                    before.Add(errorMinutes.GetValueOrDefault(m));
                }
            }

            var median = Median.Of(before);
            var hot = count >= 10 && count >= 3 * median;
            var change = errors.Observe(nextErrorMinute, hot, !hot, () => string.Create(CultureInfo.InvariantCulture, $"errors {count} in the minute from {minute:HH:mm} UTC >= 10 and 3 times the median ({median:0.#}) of the minutes before: one blocking sample (RCA-SQL-01)."));
            Report(errors, change, nextErrorMinute, $"errors under 10 a minute, or 3 times their median, for {Duration(Options.ErrorQuietFor)}: {BackToSentinel}");
            if (change == EpisodeChange.Started)
            {
                pendingErrorSample = true;
            }

            nextErrorMinute += TimeSpan.FromMinutes(1);
        }

        foreach (var old in errorMinutes.Keys.Where(m => m < now - TimeSpan.FromMinutes(30)).ToList())
        {
            errorMinutes.Remove(old);
        }
    }

    /// <summary>
    /// A deadlock count that rose with no graph by the next sentinel (the event session dispatches within 5 s): system_health's
    /// deadlocks (RCA-SQL-12, T1 and T2), or a gap on T3.
    /// </summary>
    private async Task DeadlockFallbackAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        if (deadlockSince is not { } since || now - deadlockSeen < Options.Sentinel)
        {
            return;
        }

        deadlockSince = null;
        if (databaseScoped)
        {
            Gap(now, $"{Target}'s deadlock count rose with no graph from its event session.");
            return;
        }

        var rows = await RunAsync("RCA-SQL-12", now, cancellationToken, timed: false, longRunning: true).ConfigureAwait(false);
        var kept = 0;
        foreach (var row in rows ?? [])
        {
            if (Parse(row.Text("event_xml")) is not { } element)
            {
                continue;
            }

            var item = ExtendedEvents.ParseEvent(element);
            if (item.At < since - Options.EventLatency || !healthEvents.Add(item))
            {
                continue;
            }

            var deadlock = new CaptureRow(RcaContract.Events, Target, item.At, "RCA-SQL-12")
                .Set("event_time_utc", item.At)
                .Set("target", Target)
                .Set("event_name", item.Name)
                .Set("event_count", 1L);
            if (KeepDeadlock(item, deadlock))
            {
                Write(deadlock);
                kept++;
            }
        }

        if (rows is not null && kept == 0)
        {
            Gap(now, $"{Target}'s deadlock count rose, and neither its event session nor system_health had a graph in ContosoCare.");
        }

        // system_health keeps its deadlocks for days; each read takes only those after the count rose, so the older ones go.
        healthEvents.Forget((_, at) => at < now - EventMemory);
    }

    /// <summary>T3's 15-second resource rows (RCA-AZ-01): every row not kept yet, by end_time, with no deadband.</summary>
    private async Task ResourceStatsAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        var rows = await RunAsync("RCA-AZ-01", now, cancellationToken, longRunning: true).ConfigureAwait(false);
        if (rows is null)
        {
            return;
        }

        resourceStatsRead = now;
        foreach (var row in rows)
        {
            if (row.Time("end_time") is not { } end || end <= resourceStatsKept)
            {
                continue;
            }

            Resource(end, "RCA-AZ-01", "avg_cpu_percent", row.Double("avg_cpu_percent"), "percent", sentinel: false);
            Resource(end, "RCA-AZ-01", "avg_log_write_percent", row.Double("avg_log_write_percent"), "percent", sentinel: false);
            Resource(end, "RCA-AZ-01", "avg_data_io_percent", row.Double("avg_data_io_percent"), "percent", sentinel: false);
            Resource(end, "RCA-AZ-01", "max_worker_percent", row.Double("max_worker_percent"), "percent", sentinel: false);
            Resource(end, "RCA-AZ-01", "max_session_percent", row.Double("max_session_percent"), "percent", sentinel: false);
            resourceStatsKept = end;
        }
    }

    /// <summary>The module an event's SQL text calls, when it's a call: <c>EXEC demo.usp_x ...</c> becomes <c>[demo].[usp_x]</c>.</summary>
    internal static string? Module(string? sqlText)
    {
        if (string.IsNullOrWhiteSpace(sqlText) || CallPattern().Match(sqlText) is not { Success: true } match)
        {
            return null;
        }

        return TextNormalizer.Name($"[{match.Groups["schema"].Value.Trim('[', ']')}].[{match.Groups["name"].Value.Trim('[', ']')}]");
    }

    private static XElement? Parse(string? xml)
    {
        if (string.IsNullOrWhiteSpace(xml))
        {
            return null;
        }

        try
        {
            return XElement.Parse(xml);
        }
        catch (System.Xml.XmlException)
        {
            return null;
        }
    }

    [GeneratedRegex(@"^\s*(?:\{\s*call\s+|exec(?:ute)?\s+(?:@\w+\s*=\s*)?)?(?:(?:\[[^\]]+\]|[A-Za-z_][\w$#@]*)\.)?(?<schema>\[[^\]]+\]|[A-Za-z_][\w$#@]*)\.(?<name>\[[^\]]+\]|[A-Za-z_][\w$#@]*)(?:;\d+)?\s*(?:$|[\s(,;}@])", RegexOptions.IgnoreCase)]
    private static partial Regex CallPattern();

    [GeneratedRegex(@"^\s*(?:[A-Z_]+:\s*)?(?<db>\d+):")]
    private static partial Regex DatabaseIdInResource();
}
