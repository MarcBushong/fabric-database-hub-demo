using System.CommandLine;
using System.Globalization;
using System.Text.Json.Nodes;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Postgres;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Sql;

namespace ContosoCare.Workload.Cli;

/// <summary>T4's status, warmup, and setup (Phase 24, ADR 0019): the same commands and output shapes as T1 to T3, on PostgreSQL.</summary>
internal static partial class CommandLine
{
    /// <summary>
    /// T4's live view: the activity profile, recent runs, stop requests, the demo's sessions with their waits and
    /// blockers, and the server's counters (connections against max_connections, sessions by state and by wait event
    /// type, blocked sessions, the oldest transaction, deadlocks): the live query data Database Hub doesn't show for
    /// PostgreSQL (its PostgreSQL monitoring is metrics-only).
    /// </summary>
    private static async Task<int> StatusT4Async(ParseResult parseResult, PgEndpoint endpoint, int runCount, string? profileFile, string? hostStateFile, bool json, RunnerLog log, CancellationToken cancellationToken)
    {
        await using var connection = await new PgConnectionOpener(endpoint, log).OpenAsync(SessionNames.ForControl("status"), cancellationToken).ConfigureAwait(false);
        var database = new PgDemoDatabase(connection);
        var profile = await new FileProfileStore(profileFile ?? FileProfileStore.DefaultPathFor(DemoTarget.T4)).GetAsync(cancellationToken).ConfigureAwait(false);
        var runs = await database.GetRunsAsync(runCount, runningOnly: false, cancellationToken).ConfigureAwait(false);
        var flags = await database.GetStopFlagsAsync(cancellationToken).ConfigureAwait(false);
        var sessions = await database.GetDemoSessionsAsync(null, cancellationToken).ConfigureAwait(false);
        var server = await database.GetServerViewAsync(cancellationToken).ConfigureAwait(false);
        var now = DateTimeOffset.UtcNow;
        var description = ProfileHost.Describe(profile, now, ActivityProfilesDefinition.Default, ScenarioCatalog.Default);
        var host = HostLaneStatus.ForThisMachine(hostStateFile ?? HostLanesFile.DefaultPath, DemoTarget.T4, ProfileHost.IsActive(profile, now, ActivityProfilesDefinition.Default, ScenarioCatalog.Default));
        var output = parseResult.InvocationConfiguration.Output;
        if (json)
        {
            var document = new JsonObject
            {
                ["target"] = "T4",
                ["profile"] = new JsonObject
                {
                    ["name"] = profile.Name,
                    ["setAt"] = DemoDatabase.Format(profile.SetAt),
                    ["setBy"] = profile.SetBy,
                    ["expiresAt"] = profile.ExpiresAt is { } expires ? DemoDatabase.Format(expires) : null,
                    ["description"] = description,
                },
                ["runs"] = new JsonArray([.. runs.Select(RunNode)]),
                ["stopRequests"] = new JsonArray([.. flags.Select(f => (JsonNode)new JsonObject { ["scenario"] = f.ScenarioId, ["requestedAt"] = f.RequestedAt is { } at ? DemoDatabase.Format(at) : null, ["requestedBy"] = f.RequestedBy })]),
                ["demoSessions"] = new JsonArray([.. sessions.Select(PgSessionNode)]),
                ["server"] = ServerNode(server),

                // Last, as on T1 to T3 (Phase 25b): the tail of the output that a Run Command keeps holds it and the
                // server block before it (validation's WORKLOAD.T4.HOST, status.ps1's STATUS.T4.LIVE).
                ["host"] = host.ToNode(),
            };
            output.WriteLine(document.ToJsonString(OutputOptions));
            return ExitCodes.Success;
        }

        output.WriteLine($"Target:      {endpoint.Describe()}");
        output.WriteLine($"Profile:     {description}");
        output.WriteLine($"Host:        [{host.Status}] {host.Message}");
        output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"Connections: {server.ClientConnections} of {server.MaxConnections} ({server.ReservedConnections} reserved; {server.AvailableConnections} left for applications)"));
        output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"Sessions:    {server.Active} active, {server.Idle} idle, {server.IdleInTransaction} idle in transaction, {server.Blocked} blocked{(server.CanReadAllStats ? string.Empty : " (other roles' sessions show partial detail without pg_read_all_stats)")}"));
        output.WriteLine("Waits:       " + (server.ActiveByWaitEventType.Count == 0 ? "no active sessions" : string.Join(", ", server.ActiveByWaitEventType.Select(w => string.Create(CultureInfo.InvariantCulture, $"{w.Key} {w.Value}")))));
        output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"Oldest:      transaction {Seconds(server.LongestTransactionSeconds)}, running query {Seconds(server.LongestQuerySeconds)}; deadlocks since the statistics reset: {server.Deadlocks}"));
        output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"Demo:        {sessions.Count} live demo session(s), {sessions.Count(s => s.OpenTransaction)} with an open transaction, {sessions.Count(s => s.BlockedBy is not null)} blocked"));
        foreach (var session in sessions.Where(s => s.BlockedBy is not null || s.State.StartsWith("idle in transaction", StringComparison.Ordinal)).Take(20))
        {
            output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"  pid {session.Pid,-6} {session.State,-22} {(session.WaitEventType is null ? "-" : session.WaitEventType + ":" + session.WaitEvent),-28} {(session.BlockedBy is { } blocker ? "blocked by " + blocker.ToString(CultureInfo.InvariantCulture) : string.Empty)} {session.ApplicationName}"));
        }

        foreach (var flag in flags)
        {
            output.WriteLine($"Stop:        {flag.ScenarioId} requested at {(flag.RequestedAt is { } at ? DemoDatabase.Format(at) : "?")} by {flag.RequestedBy}");
        }

        output.WriteLine("Runs:");
        foreach (var record in runs)
        {
            output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"  {record.RunId,-28} {record.ScenarioId,-20} {record.Status,-9} started {DemoDatabase.Format(record.StartedAt)} deadline {DemoDatabase.Format(record.DeadlineAt)}{(record.ProfileName is null ? string.Empty : " profile " + record.ProfileName)}"));
        }

        return ExitCodes.Success;
    }

    private static async Task<int> WarmupT4Async(ParseResult parseResult, PgEndpoint endpoint, bool json, RunnerLog log, CancellationToken cancellationToken)
    {
        var started = DateTimeOffset.UtcNow;
        await using var connection = await new PgConnectionOpener(endpoint, log).OpenAsync(SessionNames.ForControl("warmup"), cancellationToken).ConfigureAwait(false);
        await using (var command = connection.CreateCommand())
        {
            command.CommandText = "SELECT count(*) FROM care.facilities; SELECT count(*) FROM demo.fn_scenario_catalog();";
            command.CommandTimeout = 60;
            await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
            while (await reader.NextResultAsync(cancellationToken).ConfigureAwait(false))
            {
            }
        }

        var elapsed = DateTimeOffset.UtcNow - started;
        var check = new CheckRecord("warmup", "Pass", string.Create(CultureInfo.InvariantCulture, $"T4 answered in {elapsed.TotalSeconds:0.0} s (connect with a Microsoft Entra token and a light query)."));
        WriteChecks(parseResult, DemoTarget.T4, "warmup", [check], json);
        return ExitCodes.Success;
    }

    /// <summary>
    /// T4's setup, as a Microsoft Entra administrator (the P6 group's role, --user): the runner's own role first
    /// (pgaadauth_create_principal_with_oid, in the postgres database), then the schema, seed, control objects, and
    /// scenario steps in contosocare, and the runner's grants. Idempotent.
    /// </summary>
    private static async Task<int> SetupT4Async(ParseResult parseResult, PgEndpoint endpoint, bool includeBaseSchema, int? seedScale, Guid? runnerObjectId, string runnerRole, bool json, RunnerLog log, CancellationToken cancellationToken)
    {
        if (seedScale is < 1 or > 50)
        {
            throw new ScenarioRequestException("--seed-scale must be between 1 and 50.");
        }

        var checks = new List<CheckRecord>();
        if (runnerObjectId is { } objectId)
        {
            await using var postgres = await new PgConnectionOpener(endpoint.WithUser(endpoint.User, "postgres"), log).OpenAsync(SessionNames.ForControl("setup"), cancellationToken, PgSessionLimits.Setup).ConfigureAwait(false);
            checks.Add(await PgScripts.EnsureEntraRoleAsync(postgres, runnerRole, objectId, cancellationToken).ConfigureAwait(false));
        }

        await using var connection = await new PgConnectionOpener(endpoint, log).OpenAsync(SessionNames.ForControl("setup"), cancellationToken, PgSessionLimits.Setup).ConfigureAwait(false);
        var scripts = includeBaseSchema ? PgScripts.BaseSchema.Concat(PgScripts.DemoObjects) : PgScripts.DemoObjects;
        foreach (var script in scripts)
        {
            var batches = await PgScripts.ApplyAsync(connection, script, log, cancellationToken).ConfigureAwait(false);
            checks.Add(new CheckRecord("script:" + script, "Pass", string.Create(CultureInfo.InvariantCulture, $"Applied {script} ({batches} batches).")));
        }

        if (seedScale is { } scale)
        {
            checks.Add(await PgScripts.SeedAsync(connection, scale, force: false, cancellationToken).ConfigureAwait(false));
        }

        if (runnerObjectId is not null || await PgScripts.RoleExistsAsync(connection, runnerRole, cancellationToken).ConfigureAwait(false))
        {
            // Every setup grants again once the role exists, so tables a newer runner adds are covered too.
            checks.AddRange(await PgScripts.GrantRunnerAsync(connection, runnerRole, cancellationToken).ConfigureAwait(false));
        }

        checks.Add(await PgScripts.VerifyScenarioFunctionsAsync(connection, ScenarioCatalog.Default.All, cancellationToken).ConfigureAwait(false));
        WriteChecks(parseResult, DemoTarget.T4, "setup", checks, json);
        return ExitCodes.FromStatuses(checks.Select(c => c.Status));
    }

    private static JsonNode PgSessionNode(PgDemoSession session) => new JsonObject
    {
        ["sessionId"] = session.Pid,
        ["applicationName"] = session.ApplicationName,
        ["status"] = session.State,
        ["openTransactions"] = session.OpenTransaction ? 1 : 0,
        ["blockedBy"] = session.BlockedBy,
        ["waitType"] = session.WaitEventType is null ? null : session.WaitEventType + ":" + session.WaitEvent,
        ["transactionSeconds"] = session.TransactionSeconds,
        ["stateSeconds"] = session.StateSeconds,
    };

    private static JsonObject ServerNode(PgServerView server) => new()
    {
        ["maxConnections"] = server.MaxConnections,
        ["reservedConnections"] = server.ReservedConnections,
        ["clientConnections"] = server.ClientConnections,
        ["availableConnections"] = server.AvailableConnections,
        ["active"] = server.Active,
        ["idle"] = server.Idle,
        ["idleInTransaction"] = server.IdleInTransaction,
        ["blocked"] = server.Blocked,
        ["longestTransactionSeconds"] = server.LongestTransactionSeconds,
        ["longestQuerySeconds"] = server.LongestQuerySeconds,
        ["deadlocks"] = server.Deadlocks,
        ["canReadAllStats"] = server.CanReadAllStats,
        ["activeByWaitEventType"] = new JsonObject([.. server.ActiveByWaitEventType.Select(w => KeyValuePair.Create(w.Key, (JsonNode?)w.Value))]),
    };

    private static string Seconds(decimal? value) => value is { } seconds ? seconds.ToString("0.0", CultureInfo.InvariantCulture) + " s" : "none";
}
