using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// Who holds T4's client connections during a connection episode (RCA-PG-17; rca/README.md, Who holds T4's connections):
/// the block's groups of application, role, and state, reduced as Names says, into RCA Connections rows, counts and never
/// sessions. The workload's own connections keep their program, run token, and role (<see cref="ApplicationNames"/>
/// decides which are the workload's); every other application's are summed per state, with no name or role; the
/// observer's own are left out. One sample's rows share its time: the workload's first, the largest groups first.
/// </summary>
internal static class ConnectionHolders
{
    public const string Block = "RCA-PG-17";

    public static IReadOnlyList<CaptureRow> Rows(string target, IReadOnlyList<CaptureValues> rows, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var at = rows.Select(r => r.Time("captured_at")).FirstOrDefault(t => t is not null) ?? now;
        var groups = new Dictionary<(string? Program, string? RunToken, string? Login, string State), Holders>();
        foreach (var row in rows)
        {
            var name = ApplicationNames.Reduce(row.Text("application_name"));
            if (name.IsObserver)
            {
                continue;
            }

            var state = row.Text("state") is { Length: > 0 } reported ? reported : "unknown";
            (string? Program, string? RunToken, string? Login, string State) key = name.IsDemo
                ? (name.Program, name.RunToken, TextNormalizer.Name(row.Text("usename")), state)
                : (null, null, null, state);
            if (!groups.TryGetValue(key, out var group))
            {
                groups[key] = group = new Holders(name.IsDemo);
            }

            group.Add(row);
        }

        return [.. groups
            .OrderByDescending(g => g.Value.IsDemo)
            .ThenByDescending(g => g.Value.Connections)
            .ThenBy(g => g.Key.Program, StringComparer.Ordinal)
            .ThenBy(g => g.Key.RunToken, StringComparer.Ordinal)
            .ThenBy(g => g.Key.Login, StringComparer.Ordinal)
            .ThenBy(g => g.Key.State, StringComparer.Ordinal)
            .Select(g => new CaptureRow(RcaContract.Connections, target, at, Block)
                .Set("captured_at_utc", at)
                .Set("target", target)
                .Set("program_name", g.Key.Program)
                .Set("run_token", g.Key.RunToken)
                .Set("login_name", g.Key.Login)
                .Set("state", g.Key.State)
                .Set("connections", g.Value.Connections)
                .Set("waiting_lock", g.Value.WaitingLock)
                .Set("oldest_state_s", g.Value.OldestState)
                .Set("oldest_connection_s", g.Value.OldestConnection)
                .Set("is_demo", g.Value.IsDemo))];
    }

    private sealed class Holders(bool isDemo)
    {
        public bool IsDemo { get; } = isDemo;

        public long Connections { get; private set; }

        public long? WaitingLock { get; private set; }

        public double? OldestState { get; private set; }

        public double? OldestConnection { get; private set; }

        public void Add(CaptureValues row)
        {
            Connections += row.Long("connections") ?? 0;
            if (row.Long("waiting_lock") is { } waiting)
            {
                WaitingLock = (WaitingLock ?? 0) + waiting;
            }

            OldestState = Larger(OldestState, row.Double("oldest_state_s"));
            OldestConnection = Larger(OldestConnection, row.Double("oldest_connection_s"));
        }

        private static double? Larger(double? a, double? b) => a is null ? b : b is null ? a : Math.Max(a.Value, b.Value);
    }
}
