using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Sql;

namespace ContosoCare.Workload.Cosmos;

/// <summary>The statuses a T5 run goes through, as in demo.scenario_runs.</summary>
internal static class CosmosRunStatus
{
    public const string Running = "Running";
    public const string Completed = "Completed";
    public const string Cancelled = "Cancelled";
    public const string TimedOut = "TimedOut";
    public const string Failed = "Failed";
}

/// <summary>T5's run store: its recent runs and its last stop requests.</summary>
internal sealed record CosmosRunStoreDocument
{
    public int SchemaVersion { get; init; } = 1;

    public List<CosmosRunEntry>? Runs { get; init; }

    public List<CosmosStopEntry>? StopRequests { get; init; }
}

/// <summary>One T5 run, as demo.scenario_runs records a run on the other targets, plus its counters and live rates.</summary>
internal sealed record CosmosRunEntry
{
    public required string RunId { get; init; }

    public required string ScenarioId { get; init; }

    public required string Target { get; init; }

    /// <summary>Running, Completed, Cancelled, TimedOut, or Failed.</summary>
    public required string Status { get; init; }

    public required DateTimeOffset StartedAt { get; init; }

    public required DateTimeOffset DeadlineAt { get; init; }

    /// <summary>When a stop marked it Cancelled, or when it ended.</summary>
    public DateTimeOffset? StoppedAt { get; init; }

    /// <summary>When its runner recorded its end; null while it runs or is still ending.</summary>
    public DateTimeOffset? EndedAt { get; init; }

    public required int MaxDurationSeconds { get; init; }

    public required int Concurrency { get; init; }

    public required int Intensity { get; init; }

    public string? ParametersJson { get; init; }

    public string? RequestedBy { get; init; }

    public string? ProfileName { get; init; }

    /// <summary>The machine whose runner registered it.</summary>
    public string? Machine { get; init; }

    /// <summary>The runner's process and its start time, so a run whose process is gone can be told from one that's still running.</summary>
    public int? ProcessId { get; init; }

    public DateTimeOffset? ProcessStartedAt { get; init; }

    public string? Outcome { get; init; }

    public CosmosRunCounters? Counters { get; init; }

    /// <summary>The runner's recent rates, which it updates every 5 seconds while the run lasts.</summary>
    public CosmosLiveRates? Live { get; init; }

    /// <summary>The shape every target's <c>status</c> shows (RunNode).</summary>
    public RunRecord ToRunRecord() => new(RunId, ScenarioId, Target, Status, StartedAt, DeadlineAt, StoppedAt, MaxDurationSeconds, Concurrency, Intensity, Outcome, ProfileName, RequestedBy);
}

/// <summary>A run's totals: requests (429s included), 429s, request units, and failed requests.</summary>
internal sealed record CosmosRunCounters
{
    public long Requests { get; init; }

    public long Throttled { get; init; }

    public double RequestCharge { get; init; }

    public long Errors { get; init; }
}

/// <summary>A run's recent rates (<see cref="LiveRateWindow"/>).</summary>
internal sealed record CosmosLiveRates
{
    public double RequestsPerSecond { get; init; }

    public double RuPerSecond { get; init; }

    public double ThrottledPerSecond { get; init; }

    public long ThrottledLastMinute { get; init; }

    public DateTimeOffset UpdatedAt { get; init; }
}

/// <summary>A stop request: <c>run</c> (one run), <c>scenario</c>, or <c>all</c> (scenario <c>*</c>).</summary>
internal sealed record CosmosStopEntry
{
    public required string Scope { get; init; }

    public string? Scenario { get; init; }

    public string? RunId { get; init; }

    public required DateTimeOffset RequestedAt { get; init; }

    public string? RequestedBy { get; init; }
}

/// <summary>Which runner registered a run: its machine and its process.</summary>
internal sealed record CosmosRunOwner(string Machine, int ProcessId, DateTimeOffset? ProcessStartedAt)
{
    public static CosmosRunOwner Current { get; } = ForThisProcess();

    private static CosmosRunOwner ForThisProcess()
    {
        using var process = Process.GetCurrentProcess();
        DateTimeOffset? started = null;
        try
        {
            started = new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero);
        }
        catch (Exception ex) when (ex is InvalidOperationException or NotSupportedException or Win32Exception)
        {
            // Without its start time, a recycled process ID could look alive; the run's deadline still closes it.
        }

        return new CosmosRunOwner(Environment.MachineName, process.Id, started);
    }
}

/// <summary>What a run asks the store for when it registers.</summary>
internal sealed record CosmosRunStart(
    string RunId,
    string ScenarioId,
    int DurationSeconds,
    int ScenarioMaxSeconds,
    int Concurrency,
    int Intensity,
    string ParametersJson,
    string RequestedBy,
    string? ProfileName)
{
    public CosmosRunOwner Owner { get; init; } = CosmosRunOwner.Current;
}

/// <summary>A registration the store refused: <c>running-run</c>, <c>run-limit</c>, or <c>request</c>, as demo.usp_run_begin refuses one.</summary>
internal sealed class CosmosRunRefusedException(string reason, string message) : Exception(message)
{
    public string Reason { get; } = reason;
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    WriteIndented = true)]
[JsonSerializable(typeof(CosmosRunStoreDocument))]
internal sealed partial class CosmosJsonContext : JsonSerializerContext;

/// <summary>
/// T5's runs and stop requests in a JSON file on T1 (<c>t5-runs.json</c>, next to the profile files), because T5 has no
/// database-side control tables. It plays demo.usp_run_begin, usp_stop, and usp_run_end: at most one Running run per
/// scenario and four in all, a Running run past its deadline (and the runner's grace) is TimedOut, and a stop marks
/// Running runs Cancelled, which their runner sees within 2 seconds. It keeps the 50 most recent runs and the last 10
/// stop requests. Every change happens under an exclusive lock file and writes a temporary file that replaces the old
/// one (<see cref="FileReplace"/>), as the profile file does, so readers never see half of it and need no lock.
/// </summary>
internal sealed class CosmosRunStore(string path, TimeProvider? timeProvider = null, TimeSpan? lockTimeout = null)
{
    public const string FileName = "t5-runs.json";

    public const int MaximumRuns = 50;

    public const int MaximumStopRequests = 10;

    /// <summary>demo.usp_run_begin's limit: four Running runs at most.</summary>
    public const int MaximumRunning = 4;

    /// <summary>How long a writer waits for another writer's lock on the store before it gives up.</summary>
    internal static readonly TimeSpan DefaultLockTimeout = TimeSpan.FromSeconds(10);

    private readonly TimeProvider time = timeProvider ?? TimeProvider.System;

    private readonly TimeSpan lockWait = lockTimeout ?? DefaultLockTimeout;

    /// <summary>C:\ProgramData\DbHubDemo\t5-runs.json on Windows, /var/lib/DbHubDemo/t5-runs.json elsewhere: next to the profile files.</summary>
    public static string DefaultPath => Path.Combine(Path.GetDirectoryName(FileProfileStore.DefaultPath)!, FileName);

    public string FilePath => path;

    public string LockPath => path + ".lock";

    public string Description => "T5 run store " + path;

    /// <summary>The store as it is, newest runs first; empty when there's no file yet. No lock: writers replace the file whole.</summary>
    public async Task<CosmosRunStoreDocument> ReadAsync(CancellationToken cancellationToken)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.Asynchronous);
                var document = await JsonSerializer.DeserializeAsync(stream, CosmosJsonContext.Default.CosmosRunStoreDocument, cancellationToken).ConfigureAwait(false);
                return Normalize(document);
            }
            catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
            {
                return Normalize(null);
            }
            catch (Exception ex) when ((ex is IOException or UnauthorizedAccessException) && attempt < 5)
            {
                // On Windows the replace and a read can meet for a moment; the next try sees the new file.
                await Task.Delay(TimeSpan.FromMilliseconds(25 * attempt), cancellationToken).ConfigureAwait(false);
            }
        }
    }

    /// <summary>One run, or null when the store doesn't have it.</summary>
    public async Task<CosmosRunEntry?> GetRunAsync(string runId, CancellationToken cancellationToken) =>
        (await ReadAsync(cancellationToken).ConfigureAwait(false)).Runs!.FirstOrDefault(r => string.Equals(r.RunId, runId, StringComparison.Ordinal));

    /// <summary>
    /// Registers a run, as demo.usp_run_begin does: first a Running run past its deadline and grace becomes TimedOut, then
    /// the run is refused when its scenario already has a Running run (running-run) or four runs are Running (run-limit).
    /// The duration is clamped to the scenario's maximum and the global cap. Returns the deadline.
    /// </summary>
    public async Task<RunRegistration> BeginRunAsync(CosmosRunStart start, CancellationToken cancellationToken)
    {
        if (!SessionNames.IsValidRunId(start.RunId))
        {
            throw new ScenarioRequestException("A run ID is 1 to 40 lowercase letters, digits, and hyphens.");
        }

        if (start.DurationSeconds < 10)
        {
            throw new ScenarioRequestException("A run lasts at least 10 seconds.");
        }

        var (registration, refusal) = await UpdateAsync<(RunRegistration?, CosmosRunRefusedException?)>(
            (runs, _, now) =>
            {
                RecoverStale(runs, now, RunLimits.Grace);
                if (runs.Any(r => string.Equals(r.RunId, start.RunId, StringComparison.Ordinal)))
                {
                    return (null, new CosmosRunRefusedException("request", "A run with this ID is already in T5's run store."));
                }

                if (runs.Any(r => r.Status == CosmosRunStatus.Running && string.Equals(r.ScenarioId, start.ScenarioId, StringComparison.Ordinal)))
                {
                    return (null, new CosmosRunRefusedException("running-run", $"Scenario '{start.ScenarioId}' already has a Running run on T5. Stop it first (stop --target T5 --scenario {start.ScenarioId})."));
                }

                if (runs.Count(r => r.Status == CosmosRunStatus.Running) >= MaximumRunning)
                {
                    return (null, new CosmosRunRefusedException("run-limit", "Four runs are already Running on T5, the most the demo allows. Stop one first."));
                }

                var effective = Math.Min(start.DurationSeconds, Math.Min(start.ScenarioMaxSeconds, RunLimits.GlobalMaximumSeconds));
                var deadline = now + TimeSpan.FromSeconds(effective);
                runs.Insert(0, new CosmosRunEntry
                {
                    RunId = start.RunId,
                    ScenarioId = start.ScenarioId,
                    Target = nameof(DemoTarget.T5),
                    Status = CosmosRunStatus.Running,
                    StartedAt = now,
                    DeadlineAt = deadline,
                    MaxDurationSeconds = effective,
                    Concurrency = start.Concurrency,
                    Intensity = start.Intensity,
                    ParametersJson = DemoDatabase.Truncate(start.ParametersJson, 2000),
                    RequestedBy = DemoDatabase.Truncate(start.RequestedBy, 128),
                    ProfileName = start.ProfileName,
                    Machine = start.Owner.Machine,
                    ProcessId = start.Owner.ProcessId,
                    ProcessStartedAt = start.Owner.ProcessStartedAt,
                });
                return (new RunRegistration(deadline, effective), null);
            },
            cancellationToken).ConfigureAwait(false);

        return registration ?? throw refusal!;
    }

    /// <summary>The run's counters and recent rates, while it lasts.</summary>
    public Task UpdateProgressAsync(string runId, CosmosRunCounters counters, CosmosLiveRates live, CancellationToken cancellationToken) =>
        UpdateAsync(
            (runs, _, _) =>
            {
                var index = runs.FindIndex(r => string.Equals(r.RunId, runId, StringComparison.Ordinal));
                if (index >= 0 && runs[index].EndedAt is null)
                {
                    runs[index] = runs[index] with { Counters = counters, Live = live };
                }

                return true;
            },
            cancellationToken);

    /// <summary>Records how a run ended, as demo.usp_run_end does: a run a stop marked Cancelled stays Cancelled.</summary>
    public Task EndRunAsync(string runId, string status, string? outcome, CosmosRunCounters counters, CancellationToken cancellationToken)
    {
        if (status is not (CosmosRunStatus.Completed or CosmosRunStatus.Cancelled or CosmosRunStatus.TimedOut or CosmosRunStatus.Failed))
        {
            throw new ArgumentException("A run ends Completed, Cancelled, TimedOut, or Failed.", nameof(status));
        }

        return UpdateAsync(
            (runs, _, now) =>
            {
                var index = runs.FindIndex(r => string.Equals(r.RunId, runId, StringComparison.Ordinal));
                if (index >= 0)
                {
                    var run = runs[index];
                    runs[index] = run with
                    {
                        Status = run.Status == CosmosRunStatus.Cancelled ? CosmosRunStatus.Cancelled : status,
                        StoppedAt = run.StoppedAt ?? now,
                        EndedAt = now,
                        Outcome = Append(run.Outcome, outcome),
                        Counters = counters,
                        Live = null,
                    };
                }

                return index >= 0;
            },
            cancellationToken);
    }

    /// <summary>
    /// Marks Running runs Cancelled, as demo.usp_stop does: one run (<c>run</c>), every run of a scenario
    /// (<c>scenario</c>), or every run (<c>all</c>). Their runners see it within 2 seconds and end. The request is recorded.
    /// Returns how many runs it marked.
    /// </summary>
    public Task<int> StopAsync(string scope, string? runId, string? scenarioId, string requestedBy, CancellationToken cancellationToken)
    {
        if (scope is not ("run" or "scenario" or "all") || (scope == "run" && runId is null) || (scope == "scenario" && scenarioId is null))
        {
            throw new ArgumentException("A stop's scope is run (with a run ID), scenario (with a scenario ID), or all.", nameof(scope));
        }

        return UpdateAsync(
            (runs, stops, now) =>
            {
                var note = string.Create(CultureInfo.InvariantCulture, $"Stop requested by {requestedBy} at {DemoDatabase.Format(now)}.");
                var cancelled = 0;
                for (var i = 0; i < runs.Count; i++)
                {
                    var run = runs[i];
                    var matches = scope switch
                    {
                        "run" => string.Equals(run.RunId, runId, StringComparison.Ordinal),
                        "scenario" => string.Equals(run.ScenarioId, scenarioId, StringComparison.Ordinal),
                        _ => true,
                    };
                    if (matches && run.Status == CosmosRunStatus.Running)
                    {
                        runs[i] = run with { Status = CosmosRunStatus.Cancelled, StoppedAt = now, Outcome = Append(run.Outcome, note) };
                        cancelled++;
                    }
                }

                // First, so the newest request stays first even when two share a timestamp.
                stops.Insert(0, new CosmosStopEntry
                {
                    Scope = scope,
                    Scenario = scope switch
                    {
                        "all" => "*",
                        "run" => runs.FirstOrDefault(r => string.Equals(r.RunId, runId, StringComparison.Ordinal))?.ScenarioId,
                        _ => scenarioId,
                    },
                    RunId = scope == "run" ? runId : null,
                    RequestedAt = now,
                    RequestedBy = DemoDatabase.Truncate(requestedBy, 128),
                });
                return cancelled;
            },
            cancellationToken);
    }

    /// <summary>
    /// Ends the runs that an earlier profile host on <paramref name="machine"/> started and left Running (a task restart, a
    /// redeploy, a deallocated VM), so their scenarios can run again at once: profile runs that started before
    /// <paramref name="startedBefore"/> and whose process is gone. Returns them as recovered.
    /// </summary>
    public Task<IReadOnlyList<CosmosRunEntry>> RecoverOrphanedProfileRunsAsync(string machine, DateTimeOffset startedBefore, Func<int, DateTimeOffset?, bool?> isAlive, CancellationToken cancellationToken) =>
        UpdateAsync<IReadOnlyList<CosmosRunEntry>>(
            (runs, _, now) =>
            {
                var recovered = new List<CosmosRunEntry>();
                for (var i = 0; i < runs.Count; i++)
                {
                    var run = runs[i];
                    if (run.Status == CosmosRunStatus.Running
                        && run.EndedAt is null
                        && string.Equals(run.Machine, machine, StringComparison.OrdinalIgnoreCase)
                        && run.RequestedBy is not null && run.RequestedBy.StartsWith("profile:", StringComparison.Ordinal)
                        && run.StartedAt < startedBefore
                        && IsGone(run, isAlive))
                    {
                        runs[i] = run with
                        {
                            Status = CosmosRunStatus.Cancelled,
                            StoppedAt = run.StoppedAt ?? now,
                            EndedAt = now,
                            Live = null,
                            Outcome = Append(run.Outcome, "Recovered: the profile host that started it stopped (a task restart or a redeploy) before it recorded the end, and its process is gone."),
                        };
                        recovered.Add(runs[i]);
                    }
                }

                return recovered;
            },
            cancellationToken);

    /// <summary>
    /// For reset: closes the stopped runs on <paramref name="machine"/> whose runner's process is gone, so they'll never record
    /// their end themselves. Returns their run IDs.
    /// </summary>
    public Task<IReadOnlyList<string>> CloseAbandonedRunsAsync(string machine, Func<int, DateTimeOffset?, bool?> isAlive, CancellationToken cancellationToken) =>
        UpdateAsync<IReadOnlyList<string>>(
            (runs, _, now) =>
            {
                var closed = new List<string>();
                for (var i = 0; i < runs.Count; i++)
                {
                    var run = runs[i];
                    if (run.EndedAt is null
                        && run.Status != CosmosRunStatus.Running
                        && string.Equals(run.Machine, machine, StringComparison.OrdinalIgnoreCase)
                        && IsGone(run, isAlive))
                    {
                        runs[i] = run with { StoppedAt = run.StoppedAt ?? now, EndedAt = now, Live = null, Outcome = Append(run.Outcome, "Closed by reset: its runner's process is gone, so it never recorded its end.") };
                        closed.Add(run.RunId);
                    }
                }

                return closed;
            },
            cancellationToken);

    /// <summary>Running runs past their deadline and <paramref name="grace"/> become TimedOut; stopped runs whose runner never recorded the end are closed.</summary>
    internal static void RecoverStale(List<CosmosRunEntry> runs, DateTimeOffset now, TimeSpan grace)
    {
        for (var i = 0; i < runs.Count; i++)
        {
            var run = runs[i];
            if (run.EndedAt is not null || run.DeadlineAt + grace >= now)
            {
                continue;
            }

            runs[i] = run.Status == CosmosRunStatus.Running
                ? run with
                {
                    Status = CosmosRunStatus.TimedOut,
                    StoppedAt = run.StoppedAt ?? now,
                    EndedAt = now,
                    Live = null,
                    Outcome = Append(run.Outcome, "Recovered: the run passed its deadline without recording an end, so its runner ended without recording it."),
                }
                : run with { EndedAt = now, Live = null, Outcome = Append(run.Outcome, "Recovered: its runner ended without recording the end.") };
        }
    }

    private static bool IsGone(CosmosRunEntry run, Func<int, DateTimeOffset?, bool?> isAlive) =>
        run.ProcessId is not { } processId || isAlive(processId, run.ProcessStartedAt) == false;

    private static string? Append(string? outcome, string? note)
    {
        var text = string.Join(" ", new[] { outcome, note }.Where(t => !string.IsNullOrWhiteSpace(t)));
        return text.Length == 0 ? null : DemoDatabase.Truncate(text, 1000);
    }

    private static CosmosRunStoreDocument Normalize(CosmosRunStoreDocument? document) => new()
    {
        SchemaVersion = document?.SchemaVersion ?? 1,
        Runs = [.. (document?.Runs ?? []).OrderByDescending(r => r.StartedAt)],
        StopRequests = [.. (document?.StopRequests ?? []).OrderByDescending(s => s.RequestedAt)],
    };

    /// <summary>Applies a change under the lock and writes the result: the 50 most recent runs (never one that's still open) and the last 10 stop requests.</summary>
    private async Task<T> UpdateAsync<T>(Func<List<CosmosRunEntry>, List<CosmosStopEntry>, DateTimeOffset, T> change, CancellationToken cancellationToken)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        await using var gate = await LockAsync(cancellationToken).ConfigureAwait(false);
        var current = await ReadCurrentAsync(cancellationToken).ConfigureAwait(false);
        var runs = current.Runs!;
        var stops = current.StopRequests!;
        var result = change(runs, stops, time.GetUtcNow());
        var kept = runs
            .OrderByDescending(r => r.EndedAt is null)
            .ThenByDescending(r => r.StartedAt)
            .Take(Math.Max(MaximumRuns, runs.Count(r => r.EndedAt is null)))
            .OrderByDescending(r => r.StartedAt);
        var document = new CosmosRunStoreDocument
        {
            Runs = [.. kept],
            StopRequests = [.. stops.OrderByDescending(s => s.RequestedAt).Take(MaximumStopRequests)],
        };
        var temporary = path + ".tmp";
        await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(document, CosmosJsonContext.Default.CosmosRunStoreDocument), cancellationToken).ConfigureAwait(false);
        await FileReplace.ReplaceAsync(temporary, path, FileReplace.Move, cancellationToken).ConfigureAwait(false);
        return result;
    }

    /// <summary>The stored content under the lock; empty when there's no file or it can't be read as one (the write replaces it).</summary>
    private async Task<CosmosRunStoreDocument> ReadCurrentAsync(CancellationToken cancellationToken)
    {
        try
        {
            return await ReadAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (JsonException)
        {
            return Normalize(null);
        }
    }

    /// <summary>Opens the lock file exclusively, retrying while another writer holds it, for the lock timeout at most.</summary>
    private async Task<FileStream> LockAsync(CancellationToken cancellationToken)
    {
        var deadline = DateTimeOffset.UtcNow + lockWait;
        while (true)
        {
            try
            {
                return new FileStream(LockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.None);
            }
            catch (Exception ex) when ((ex is IOException or UnauthorizedAccessException) && DateTimeOffset.UtcNow < deadline)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(50), cancellationToken).ConfigureAwait(false);
            }
        }
    }
}
