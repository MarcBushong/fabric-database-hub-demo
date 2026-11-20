using System.Globalization;
using System.Text.RegularExpressions;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>
/// RCA Sessions rows from SQL Server's blocking sample (RCA-SQL-01 and RCA-SQL-02): one row per session in a chain,
/// with the lock it waits for and the lock it holds that others wait for. Only the workload's own sessions keep their
/// text, login, host, and program; any other session keeps its ID, status, waits, and locks.
/// </summary>
internal static class SqlSessions
{
    private static readonly HashSet<string> BlockingTableModes = new(StringComparer.Ordinal) { "S", "U", "X", "SIX" };

    public static IEnumerable<CaptureRow> Build(string target, DateTimeOffset at, IReadOnlyList<CaptureValues> sessions, IReadOnlyList<CaptureValues> locks, string source)
    {
        var contested = locks.Where(l => !Granted(l)).Select(Resource).ToHashSet(StringComparer.Ordinal);
        foreach (var session in sessions)
        {
            if (session.Long("session_id") is not { } id)
            {
                continue;
            }

            var name = ApplicationNames.Reduce(session.Text("program_name"));
            if (name.IsObserver)
            {
                continue;
            }

            var mine = locks.Where(l => l.Long("request_session_id") == id).ToList();
            var waiting = mine.FirstOrDefault(l => !Granted(l));
            var held = mine.FirstOrDefault(l => Granted(l) && contested.Contains(Resource(l)))
                ?? mine.FirstOrDefault(l => Granted(l) && string.Equals(l.Text("resource_type"), "OBJECT", StringComparison.Ordinal) && BlockingTableModes.Contains(l.Text("request_mode") ?? string.Empty));
            var shown = waiting ?? held;
            var row = new CaptureRow(RcaContract.Sessions, target, at, source)
                .Set("captured_at_utc", at)
                .Set("target", target)
                .Set("session_id", id)
                .Set("blocked_by", session.Long("blocking_session_id") is { } blocker && blocker != 0 ? blocker.ToString(CultureInfo.InvariantCulture) : null)
                .Set("status", session.Text("request_status") ?? session.Text("session_status"))
                .Set("wait_type", session.Text("wait_type"))
                .Set("wait_ms", session.Long("wait_time_ms"))
                .Set("wait_resource", TextNormalizer.Name(session.Text("wait_resource")))
                .Set("lock_resource_type", shown?.Text("resource_type"))
                .Set("lock_object", TextNormalizer.Name(shown?.Text("object_name")))
                .Set("lock_index", TextNormalizer.Name(shown?.Text("index_name")))
                .Set("lock_mode_wanted", waiting?.Text("request_mode"))
                .Set("lock_mode_held", held?.Text("request_mode"))
                .Set("open_transactions", session.Long("open_transaction_count") is { } open ? (int)Math.Clamp(open, int.MinValue, int.MaxValue) : null)
                .Set("transaction_age_ms", session.Long("transaction_age_ms"))
                .Set("idle_ms", session.Long("idle_ms"))
                .Set("is_demo", name.IsDemo);
            if (name.IsDemo)
            {
                var buffer = session.Text("input_buffer");
                row.Set("login_name", TextNormalizer.Name(session.Text("login_name")))
                    .Set("host_name", TextNormalizer.Name(session.Text("host_name")))
                    .Set("program_name", name.Program)
                    .Set("run_token", name.RunToken)
                    .Set("module_name", TextNormalizer.Name(session.Text("module_name")))
                    .Set("statement_text", TextNormalizer.Statement(session.Text("statement_text")))
                    .Set("input_buffer", string.Equals(session.Text("input_buffer_type"), "RPC Event", StringComparison.OrdinalIgnoreCase) ? TextNormalizer.RpcName(buffer) : TextNormalizer.Statement(buffer));
            }

            yield return row;
        }
    }

    private static bool Granted(CaptureValues row) => string.Equals(row.Text("request_status"), "GRANTED", StringComparison.OrdinalIgnoreCase);

    private static string Resource(CaptureValues row) => string.Join('|', row.Text("resource_type"), row.Text("resource_associated_entity_id"), row.Text("resource_description"));
}

/// <summary>What the replica's replay waits for, from RCA-PG-01 and RCA-PG-02 (pg_blocking_pids returns nothing for the startup process on a standby).</summary>
internal sealed record ReplayConflict(string? StartupWait, string? Relation, string? WantedMode, DateTimeOffset? WaitStart, long? Holder, string? HolderMode, ReducedName HolderName, string? HolderStatement);

/// <summary>
/// RCA Sessions rows from PostgreSQL's blocking sample (RCA-PG-01, RCA-PG-02, RCA-PG-11) on T4 or its replica: the
/// sessions that wait on a lock and the ones they wait for. A transactionid wait names no table, so a head blocker's
/// object is the table its open transaction locked most strongly (RCA-PG-11).
/// </summary>
internal static partial class PgSessions
{
    // From the weakest relation lock mode a transaction's writes take to the strongest.
    private static readonly string[] ModeStrength = ["RowShareLock", "RowExclusiveLock", "ShareUpdateExclusiveLock", "ShareLock", "ShareRowExclusiveLock", "ExclusiveLock", "AccessExclusiveLock"];

    /// <summary>The pids others wait on that wait on no one: RCA-PG-11's $1.</summary>
    public static int[] Heads(IReadOnlyList<CaptureValues> activity, IReadOnlyList<CaptureValues> locks)
    {
        var blockedBy = BlockedBy(activity, locks);
        var blockers = blockedBy.Values.SelectMany(v => v).ToHashSet();
        return [.. blockers.Where(pid => !blockedBy.TryGetValue(pid, out var own) || own.Count == 0).Select(pid => (int)pid).Order()];
    }

    public static IEnumerable<CaptureRow> Build(string target, DateTimeOffset at, IReadOnlyList<CaptureValues> activity, IReadOnlyList<CaptureValues> locks, IReadOnlyList<CaptureValues> relations, string source)
    {
        var blockedBy = BlockedBy(activity, locks);
        var blockers = blockedBy.Values.SelectMany(v => v).ToHashSet();
        foreach (var session in activity)
        {
            if (session.Long("pid") is not { } pid)
            {
                continue;
            }

            var waitsOn = blockedBy.GetValueOrDefault(pid) ?? [];
            if (waitsOn.Count == 0 && !blockers.Contains(pid))
            {
                continue;
            }

            var name = ApplicationNames.Reduce(session.Text("application_name"));
            if (name.IsObserver)
            {
                continue;
            }

            var waiting = locks.FirstOrDefault(l => l.Long("waiting_pid") == pid);
            var held = locks.FirstOrDefault(l => l.Long("holding_pid") == pid);
            var state = session.Text("state");
            var row = new CaptureRow(RcaContract.Sessions, target, at, source)
                .Set("captured_at_utc", at)
                .Set("target", target)
                .Set("session_id", pid)
                .Set("blocked_by", waitsOn.Count > 0 ? string.Join(',', waitsOn.Select(p => p.ToString(CultureInfo.InvariantCulture))) : null)
                .Set("status", state)
                .Set("wait_type", Wait(session))
                .Set("wait_ms", waiting?.Time("waitstart") is { } started ? (long)Math.Max(0, (at - started).TotalMilliseconds) : null)
                .Set("lock_resource_type", (waiting ?? held)?.Text("locktype"))
                .Set("lock_object", TextNormalizer.Name(waiting?.Text("relation") ?? held?.Text("relation") ?? Strongest(relations, pid)))
                .Set("lock_mode_wanted", waiting?.Text("waiting_mode"))
                .Set("lock_mode_held", held?.Text("held_mode"))
                .Set("open_transactions", session.Get("xact_age_s") is null ? 0 : 1)
                .Set("transaction_age_ms", Milliseconds(session.Double("xact_age_s")))
                .Set("idle_ms", state is not null && state.StartsWith("idle", StringComparison.Ordinal) ? Milliseconds(session.Double("state_age_s")) : null)
                .Set("backend_type", session.Text("backend_type"))
                .Set("is_demo", name.IsDemo);
            if (name.IsDemo)
            {
                var query = session.Text("query");
                row.Set("login_name", TextNormalizer.Name(session.Text("usename")))
                    .Set("program_name", name.Program)
                    .Set("run_token", name.RunToken)
                    .Set("module_name", Module(query))
                    .Set("statement_text", TextNormalizer.Statement(query));
            }

            yield return row;
        }
    }

    /// <summary>The replica's startup process, the lock it waits for, and the session that holds it.</summary>
    public static ReplayConflict? Conflict(IReadOnlyList<CaptureValues> activity, IReadOnlyList<CaptureValues> locks)
    {
        var startup = activity.FirstOrDefault(a => string.Equals(a.Text("backend_type"), "startup", StringComparison.Ordinal));
        if (startup is null)
        {
            return null;
        }

        var wait = locks.FirstOrDefault(l => l.Long("waiting_pid") == startup.Long("pid"));
        var holder = wait?.Long("holding_pid") is { } holderPid ? activity.FirstOrDefault(a => a.Long("pid") == holderPid) : null;
        var name = ApplicationNames.Reduce(holder?.Text("application_name"));
        return new ReplayConflict(
            Wait(startup),
            TextNormalizer.Name(wait?.Text("relation")),
            wait?.Text("waiting_mode"),
            wait?.Time("waitstart"),
            wait?.Long("holding_pid"),
            wait?.Text("held_mode"),
            name.IsObserver ? ReducedName.Other : name,
            name.IsDemo && !name.IsObserver ? TextNormalizer.Statement(holder?.Text("query")) : null);
    }

    /// <summary>A session's wait as <c>wait_event_type:wait_event</c>.</summary>
    public static string? Wait(CaptureValues session)
    {
        var type = session.Text("wait_event_type");
        var name = session.Text("wait_event");
        return type is null && name is null ? null : $"{type}:{name}";
    }

    /// <summary>The function a statement calls, as PostgreSQL's DBA reads it: <c>demo.f($1)</c> calls <c>demo.f</c>; a table after INTO or TABLE isn't one.</summary>
    internal static string? Module(string? query)
    {
        if (string.IsNullOrWhiteSpace(query) || FunctionCall().Match(query) is not { Success: true } match)
        {
            return null;
        }

        return TextNormalizer.Name(match.Groups["name"].Value);
    }

    /// <summary>Who each pid waits on: pg_blocking_pids, or, when that's empty (a standby's startup process), the holders RCA-PG-02 found.</summary>
    private static Dictionary<long, List<long>> BlockedBy(IReadOnlyList<CaptureValues> activity, IReadOnlyList<CaptureValues> locks)
    {
        var result = new Dictionary<long, List<long>>();
        foreach (var session in activity)
        {
            if (session.Long("pid") is not { } pid)
            {
                continue;
            }

            var pids = session.Longs("blocked_by").Where(p => p != pid).Distinct().ToList();
            if (pids.Count == 0)
            {
                pids = [.. locks.Where(l => l.Long("waiting_pid") == pid && l.Long("holding_pid") is not null).Select(l => l.Long("holding_pid")!.Value).Distinct()];
            }

            result[pid] = pids;
        }

        return result;
    }

    private static string? Strongest(IReadOnlyList<CaptureValues> relations, long pid) =>
        relations.Where(r => r.Long("pid") == pid && r.Text("relation") is not null)
            .OrderByDescending(r => Array.IndexOf(ModeStrength, r.Text("mode") ?? string.Empty))
            .ThenBy(r => r.Text("relation"), StringComparer.Ordinal)
            .Select(r => r.Text("relation"))
            .FirstOrDefault();

    private static long? Milliseconds(double? seconds) => seconds is { } s ? (long)Math.Round(s * 1000, MidpointRounding.AwayFromZero) : null;

    [GeneratedRegex(@"(?<!\b(?:into|table)\s+)\b(?<name>[A-Za-z_][\w$]*\.[A-Za-z_][\w$]*)\s*\(", RegexOptions.IgnoreCase)]
    private static partial Regex FunctionCall();
}
