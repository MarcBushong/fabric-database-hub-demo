using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;

namespace ContosoCare.Workload.Profiles;

/// <summary>
/// The profile host's heartbeat (Phase 25b): <c>host-lanes.json</c>, next to T3's profile file. The host's supervisor
/// rewrites it every few seconds with each target lane's state, so <c>status</c> and <c>profile get</c>, in another
/// process on the same machine, can tell a serving lane from a stalled, restarting, or stopped one. Nothing in it is
/// secret: errors are redacted, and the runner holds no credential.
/// </summary>
internal sealed record HostLanesDocument
{
    public int SchemaVersion { get; init; } = 1;

    public int ProcessId { get; init; }

    public DateTimeOffset? ProcessStartedAt { get; init; }

    public DateTimeOffset HostStartedAt { get; init; }

    public DateTimeOffset HeartbeatAt { get; init; }

    public DateTimeOffset? NotAfter { get; init; }

    public int PollSeconds { get; init; }

    public int HeartbeatSeconds { get; init; }

    public int StallLimitSeconds { get; init; }

    public DateTimeOffset? StoppedAt { get; init; }

    /// <summary><c>not-after</c> (the next auto-shutdown) or <c>cancelled</c> (Ctrl+C, SIGTERM, or the task stopped).</summary>
    public string? StopReason { get; init; }

    public string? RunnerVersion { get; init; }

    public List<HostLaneRecord>? Lanes { get; init; }
}

/// <summary>One target's lane in <see cref="HostLanesDocument"/>.</summary>
internal sealed record HostLaneRecord
{
    public string Target { get; init; } = string.Empty;

    /// <summary><c>Serving</c>, <c>Busy</c> (a bounded reset before a profile), <c>Restarting</c>, or <c>Stopped</c>.</summary>
    public string State { get; init; } = string.Empty;

    public int Generation { get; init; }

    public int Restarts { get; init; }

    /// <summary>When the lane was restarted in the last hour.</summary>
    public List<DateTimeOffset>? RecentRestarts { get; init; }

    public DateTimeOffset? LastRestartAt { get; init; }

    public string? LastRestartReason { get; init; }

    public DateTimeOffset? RestartDueAt { get; init; }

    /// <summary>When the lane last finished a poll (read the profile, started and stopped runs).</summary>
    public DateTimeOffset LastPollAt { get; init; }

    public string Operation { get; init; } = string.Empty;

    public DateTimeOffset OperationSince { get; init; }

    public DateTimeOffset? BusyUntil { get; init; }

    public int ConsecutiveFailures { get; init; }

    public string? LastError { get; init; }

    public DateTimeOffset? LastErrorAt { get; init; }

    public string? Profile { get; init; }

    public int RunningRuns { get; init; }
}

/// <summary>What reading <c>host-lanes.json</c> found: the document, or why there's none.</summary>
internal sealed record HostLanesRead(string Path, HostLanesDocument? Document, string? Error);

/// <summary>Writes and reads <c>host-lanes.json</c>.</summary>
internal static class HostLanesFile
{
    public const string FileName = "host-lanes.json";

    public static string DefaultPath => System.IO.Path.Combine(System.IO.Path.GetDirectoryName(FileProfileStore.DefaultPath)!, FileName);

    /// <summary>Writes the document to a temporary file that then replaces the old one, so a reader never sees half of it.</summary>
    public static void Write(string path, HostLanesDocument document)
    {
        var directory = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(document, CatalogJsonContext.Default.HostLanesDocument));
        File.Move(temporary, path, overwrite: true);
    }

    public static HostLanesRead Read(string path)
    {
        if (!File.Exists(path))
        {
            return new HostLanesRead(path, null, null);
        }

        try
        {
            // Shared for writing and deleting, so the host can replace the file while it's being read.
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var document = JsonSerializer.Deserialize(stream, CatalogJsonContext.Default.HostLanesDocument);
            return document is null ? new HostLanesRead(path, null, "the file is empty") : new HostLanesRead(path, document, null);
        }
        catch (FileNotFoundException)
        {
            return new HostLanesRead(path, null, null);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            return new HostLanesRead(path, null, Redactor.Redact(ex.Message));
        }
    }
}

/// <summary>A lane's ADR 0012 status for <c>status</c> and <c>profile get</c>, with the facts behind it.</summary>
internal sealed record HostLaneVerdict(string Status, string Message, HostLanesRead Read, HostLaneRecord? Lane, bool? ProcessAlive, DateTimeOffset Now)
{
    /// <summary>The <c>host</c> node of <c>status --json</c> and <c>profile get --json</c>; it's written last, so a Run Command's output tail keeps it.</summary>
    public JsonObject ToNode()
    {
        var document = Read.Document;
        var node = new JsonObject
        {
            ["status"] = Status,
            ["message"] = Message,
            ["file"] = Read.Path,
        };
        if (document is not null)
        {
            node["processId"] = document.ProcessId;
            node["hostStartedAt"] = HostLaneStatus.Format(document.HostStartedAt);
            node["heartbeatAt"] = HostLaneStatus.Format(document.HeartbeatAt);
            node["heartbeatAgeSeconds"] = (int)Math.Max(0, (Now - document.HeartbeatAt).TotalSeconds);
            node["processAlive"] = ProcessAlive;
            node["stoppedAt"] = document.StoppedAt is { } stopped ? HostLaneStatus.Format(stopped) : null;
            node["stopReason"] = document.StopReason;
        }

        if (Lane is { } lane)
        {
            node["lane"] = new JsonObject
            {
                ["state"] = lane.State,
                ["generation"] = lane.Generation,
                ["restarts"] = lane.Restarts,
                ["restartsLastHour"] = HostLaneStatus.RestartsLastHour(lane, Now),
                ["lastRestartReason"] = lane.LastRestartReason,
                ["lastPollAt"] = HostLaneStatus.Format(lane.LastPollAt),
                ["lastPollAgeSeconds"] = (int)Math.Max(0, (Now - lane.LastPollAt).TotalSeconds),
                ["operation"] = lane.Operation,
                ["consecutiveFailures"] = lane.ConsecutiveFailures,
                ["lastError"] = lane.LastError,
                ["runningRuns"] = lane.RunningRuns,
            };
        }

        return node;
    }
}

/// <summary>
/// Turns <c>host-lanes.json</c> into an ADR 0012 status for one target (Phase 25b): Pass while its lane polls; Warning
/// while it's slow, restarting, recently restarted, failing to read its profile, or while no host runs and no profile
/// is active; Fail when a profile is active but nothing runs it (the host ended without a clean stop, or its heartbeat
/// is stale), or when the lane keeps failing (three restarts within an hour); Not selected when the host doesn't
/// serve the target and its profile is off.
/// </summary>
internal static class HostLaneStatus
{
    public const int RestartsMeaningFailure = 3;

    public static HostLaneVerdict Evaluate(HostLanesRead read, DemoTarget target, bool profileActive, DateTimeOffset now, DateTimeOffset bootedAt, Func<int, DateTimeOffset?, bool?> isAlive)
    {
        var name = target.ToString();
        var active = profileActive ? $"{name}'s active profile" : $"a profile set for {name}";
        if (read.Document is not { } document)
        {
            return new HostLaneVerdict(
                "Warning",
                read.Error is null
                    ? $"No profile host heartbeat ({read.Path}): the DbHubDemo-Workload task isn't hosting the profiles on this machine, or its runner predates Phase 25b, so {active} may not run."
                    : $"The profile host's heartbeat ({read.Path}) couldn't be read: {read.Error}",
                read,
                null,
                null,
                now);
        }

        if (document.HostStartedAt < bootedAt - TimeSpan.FromMinutes(1))
        {
            return new HostLaneVerdict("Warning", $"The profile host hasn't started since this machine booted at {Format(bootedAt)} (the DbHubDemo-Workload task starts it about two minutes after a boot), so {active} isn't running yet.", read, null, null, now);
        }

        if (document.StoppedAt is { } stopped)
        {
            var why = document.StopReason == "not-after" ? "before the next auto-shutdown" : "when it was stopped";
            return profileActive
                ? new HostLaneVerdict("Warning", $"The profile host stopped at {Format(stopped)} ({why}), so {active} isn't running until the DbHubDemo-Workload task starts the host again (at the next boot).", read, null, null, now)
                : new HostLaneVerdict("Pass", $"The profile host stopped at {Format(stopped)} ({why}); {name}'s profile is off.", read, null, null, now);
        }

        var alive = isAlive(document.ProcessId, document.ProcessStartedAt);
        var heartbeatAge = now - document.HeartbeatAt;
        if (alive == false)
        {
            return new HostLaneVerdict(
                profileActive ? "Fail" : "Warning",
                $"The profile host (process {document.ProcessId}) ended without a clean stop; its last heartbeat was {Age(heartbeatAge)} ago, so {active} doesn't run until the DbHubDemo-Workload task starts it again.",
                read,
                null,
                alive,
                now);
        }

        var staleAfter = TimeSpan.FromSeconds(Math.Max(60, 3 * document.HeartbeatSeconds));
        if (heartbeatAge > staleAfter)
        {
            return new HostLaneVerdict(
                profileActive ? "Fail" : "Warning",
                $"The profile host's heartbeat is {Age(heartbeatAge)} old (process {document.ProcessId}): its supervisor isn't running, so a stalled lane isn't replaced and {active} may not run.",
                read,
                null,
                alive,
                now);
        }

        var lanes = document.Lanes ?? [];
        var lane = lanes.FirstOrDefault(l => string.Equals(l.Target, name, StringComparison.OrdinalIgnoreCase));
        if (lane is null)
        {
            var serves = lanes.Count == 0 ? "no target" : string.Join(" and ", lanes.Select(l => l.Target));
            return new HostLaneVerdict(
                profileActive ? "Warning" : "Not selected",
                $"The profile host on this machine serves {serves}, not {name}, so {active} doesn't run here.",
                read,
                null,
                alive,
                now);
        }

        var recent = RestartsLastHour(lane, now);
        var reason = lane.LastRestartReason ?? "no reason recorded";
        if (lane.State == "Restarting")
        {
            var due = lane.RestartDueAt is { } at ? " at " + Format(at) : " shortly";
            return new HostLaneVerdict(
                recent >= RestartsMeaningFailure ? "Fail" : "Warning",
                $"The host is restarting the {name} lane ({reason}); it resumes{due}. Restarts in the last hour: {recent}.",
                read,
                lane,
                alive,
                now);
        }

        if (recent >= RestartsMeaningFailure)
        {
            return new HostLaneVerdict("Fail", $"The {name} lane keeps failing: the host restarted it {recent} times in the last hour (last: {reason}).", read, lane, alive, now);
        }

        var pollAge = now - lane.LastPollAt;
        var busy = lane.BusyUntil is { } until && until > now;
        if (!busy && pollAge > TimeSpan.FromSeconds(Math.Max(60, document.StallLimitSeconds)))
        {
            return new HostLaneVerdict("Warning", $"The {name} lane hasn't finished a poll for {Age(pollAge)} ({lane.Operation} since {Format(lane.OperationSince)}); the host's supervisor replaces it.", read, lane, alive, now);
        }

        if (!busy && pollAge > TimeSpan.FromSeconds(Math.Max(60, 3 * document.PollSeconds)))
        {
            return new HostLaneVerdict("Warning", $"The {name} lane is slow: its last poll finished {Age(pollAge)} ago ({lane.Operation}).", read, lane, alive, now);
        }

        if (recent > 0)
        {
            var when = lane.LastRestartAt is { } restarted ? " at " + Format(restarted) : string.Empty;
            return new HostLaneVerdict("Warning", $"The host restarted the {name} lane {recent} time(s) in the last hour (last{when}: {reason}); it's serving again.", read, lane, alive, now);
        }

        if (lane.ConsecutiveFailures > 0)
        {
            return new HostLaneVerdict("Warning", $"The {name} lane's last {lane.ConsecutiveFailures} poll(s) failed: {lane.LastError ?? "no error recorded"}", read, lane, alive, now);
        }

        var doing = busy ? $"; it's resetting the target before the profile until {Format(lane.BusyUntil!.Value)}" : string.Empty;
        var history = lane.Restarts > 0 ? string.Create(CultureInfo.InvariantCulture, $"; restarted {lane.Restarts} time(s) since {Format(document.HostStartedAt)}") : string.Empty;
        return new HostLaneVerdict("Pass", $"The profile host (process {document.ProcessId}, up since {Format(document.HostStartedAt)}) serves {name}: its last poll finished {Age(pollAge)} ago{doing}{history}.", read, lane, alive, now);
    }

    /// <summary>Whether the process that wrote the heartbeat is still running: false when it's gone or the ID now belongs to another process, null when that can't be read.</summary>
    public static bool? IsProcessAlive(int processId, DateTimeOffset? startedAt)
    {
        try
        {
            using var process = Process.GetProcessById(processId);
            if (startedAt is not { } expected)
            {
                return true;
            }

            var actual = new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero);
            return Math.Abs((actual - expected).TotalSeconds) < 5;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException)
        {
            return null;
        }
    }

    /// <summary>When this machine booted: now minus the time since the system started.</summary>
    public static DateTimeOffset BootedAt(DateTimeOffset now) => now - TimeSpan.FromMilliseconds(Environment.TickCount64);

    /// <summary>The verdict for <c>status</c> and <c>profile get</c> on this machine.</summary>
    public static HostLaneVerdict ForThisMachine(string path, DemoTarget target, bool profileActive)
    {
        var now = DateTimeOffset.UtcNow;
        return Evaluate(HostLanesFile.Read(path), target, profileActive, now, BootedAt(now), IsProcessAlive);
    }

    public static int RestartsLastHour(HostLaneRecord lane, DateTimeOffset now) =>
        (lane.RecentRestarts ?? []).Count(t => now - t <= TimeSpan.FromHours(1));

    internal static string Format(DateTimeOffset value) => value.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture);

    internal static string Age(TimeSpan age)
    {
        if (age < TimeSpan.Zero)
        {
            age = TimeSpan.Zero;
        }

        return age.TotalSeconds < 120
            ? string.Create(CultureInfo.InvariantCulture, $"{age.TotalSeconds:0} s")
            : age.TotalMinutes < 120
                ? string.Create(CultureInfo.InvariantCulture, $"{age.TotalMinutes:0.#} min")
                : string.Create(CultureInfo.InvariantCulture, $"{age.TotalHours:0.#} h");
    }
}
