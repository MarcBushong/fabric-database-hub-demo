using System.Globalization;
using System.Text.Json.Nodes;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Sql;

namespace ContosoCare.Workload.Cli;

/// <summary>T1 to T3's <c>status --json</c>, with Query Store's state (2026-11-23).</summary>
internal static partial class CommandLine
{
    /// <summary>The longest error a status's queryStore node carries: the relay on the VM keeps the node whole.</summary>
    internal const int QueryStoreErrorLength = 200;

    /// <summary>
    /// <c>status --json</c> on T1 to T3: target, profile, runs, stopRequests, demoSessions, dataHeadroomMb, logHeadroomMb,
    /// queryStore, and host, in that order. The host node is last and Query Store's state last but one, so the tail a Run
    /// Command keeps holds them; the relay on the VM also reads queryStore from the whole output before it cuts it
    /// (vm/bootstrap/Invoke-DemoWorkloadControl.ps1), for validate.ps1's T1.QUERYSTORE and T2.QUERYSTORE.
    /// </summary>
    internal static JsonObject SqlStatusNode(DemoTarget target, ProfileState profile, string profileDescription, IEnumerable<RunRecord> runs, IEnumerable<StopFlag> flags, IReadOnlyList<DemoSession>? sessions, SpaceHeadroom space, QueryStoreRead queryStore, HostLaneVerdict host) => new()
    {
        ["target"] = target.ToString(),
        ["profile"] = new JsonObject
        {
            ["name"] = profile.Name,
            ["setAt"] = DemoDatabase.Format(profile.SetAt),
            ["setBy"] = profile.SetBy,
            ["expiresAt"] = profile.ExpiresAt is { } expires ? DemoDatabase.Format(expires) : null,
            ["description"] = profileDescription,
        },
        ["runs"] = new JsonArray([.. runs.Select(RunNode)]),
        ["stopRequests"] = new JsonArray([.. flags.Select(f => (JsonNode)new JsonObject { ["scenario"] = f.ScenarioId, ["requestedAt"] = f.RequestedAt is { } at ? DemoDatabase.Format(at) : null, ["requestedBy"] = f.RequestedBy })]),
        ["demoSessions"] = sessions is null ? null : new JsonArray([.. sessions.Select(s => (JsonNode)new JsonObject { ["sessionId"] = s.SessionId, ["applicationName"] = s.ProgramName, ["status"] = s.Status, ["openTransactions"] = s.OpenTransactions, ["blockedBy"] = s.BlockingSessionId, ["waitType"] = s.WaitType })]),
        ["dataHeadroomMb"] = space.DataHeadroomMb,
        ["logHeadroomMb"] = space.LogHeadroomMb,
        ["queryStore"] = QueryStoreNode(queryStore),

        // Last, so the tail of the output that a Run Command keeps still holds it (validation's WORKLOAD.<target>.HOST).
        ["host"] = host.ToNode(),
    };

    /// <summary>
    /// <c>status --json</c>'s queryStore: the database's Query Store state (actual and desired), the read-only reason, the
    /// capture mode, the interval, and the storage against its limit; or the error that kept them from being read, at
    /// most <see cref="QueryStoreErrorLength"/> characters.
    /// </summary>
    internal static JsonObject QueryStoreNode(QueryStoreRead read) => read.State is { } state
        ? new JsonObject
        {
            ["actualState"] = state.ActualState,
            ["desiredState"] = state.DesiredState,
            ["readonlyReason"] = state.ReadonlyReason,
            ["captureMode"] = state.CaptureMode,
            ["intervalMinutes"] = state.IntervalMinutes,
            ["storageMb"] = state.StorageMb,
            ["maxStorageMb"] = state.MaxStorageMb,
        }
        : new JsonObject { ["error"] = Bounded(Redactor.Redact(read.Error ?? "Query Store's state wasn't read."), QueryStoreErrorLength) };

    /// <summary>One line for the text status: "READ_WRITE (AUTO capture, 15-minute intervals, 12 of 1024 MB)".</summary>
    internal static string QueryStoreText(QueryStoreRead read) => read.State is { } state
        ? string.Create(CultureInfo.InvariantCulture, $"{state.ActualState ?? "unknown"}{(state.ActualState != state.DesiredState && state.DesiredState is not null ? $", desired {state.DesiredState}" : string.Empty)}{(state.ReadonlyReason is > 0 ? $", read-only reason {state.ReadonlyReason}" : string.Empty)} ({state.CaptureMode ?? "unknown"} capture, {state.IntervalMinutes?.ToString(CultureInfo.InvariantCulture) ?? "?"}-minute intervals, {state.StorageMb?.ToString(CultureInfo.InvariantCulture) ?? "?"} of {state.MaxStorageMb?.ToString(CultureInfo.InvariantCulture) ?? "?"} MB)")
        : $"not read: {Bounded(Redactor.Redact(read.Error ?? "unknown"), QueryStoreErrorLength)}";

    private static string Bounded(string text, int length) => text.Length <= length ? text : string.Concat(text.AsSpan(0, length - 3), "...");
}
