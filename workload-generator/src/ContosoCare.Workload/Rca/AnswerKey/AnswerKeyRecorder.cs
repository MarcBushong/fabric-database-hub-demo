using System.Collections.Concurrent;
using System.Data;
using System.Globalization;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Postgres;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.Store;
using ContosoCare.Workload.Runs;
using ContosoCare.Workload.Sql;

namespace ContosoCare.Workload.Rca.AnswerKey;

/// <summary>Where the profile host reports the fault runs it ran, for the answer key.</summary>
internal interface IAnswerKeySink
{
    void RunEnded(DemoTarget target, RunResult result);

    /// <summary>True while a run of the target is still being recorded, so its observation span stays open until it is.</summary>
    bool IsPending(DemoTarget target);

    /// <summary>
    /// True while a run of the target that ended by <paramref name="endedBy"/> is still being recorded: after the capture's
    /// end (rca export --end-capture), the stop's span waits to close for those runs only, not for runs that end later. A
    /// run counts only by the end its runner gave it.
    /// </summary>
    bool IsPending(DemoTarget target, DateTimeOffset endedBy);
}

/// <summary>
/// The answer key (ADR 0031): the runner's own fault runs and the events they reported, in each span's
/// answer-key.jsonl, apart from the capture. The export puts them in the document's answerKey section with its own
/// string dictionary; the notebook writes them only to rca_answer_key, which only the scoreboard and the tests read.
/// The observer never reads them. Each run carries the same run token as its sessions in the capture, so grading can
/// check that a blind finding names the injected run's sessions.
/// </summary>
internal sealed class AnswerKeyRecorder(EvidenceStore store, IReadOnlyDictionary<DemoTarget, Func<string, CancellationToken, Task<IReadOnlyList<RunEvent>>>> events, RunnerLog log) : IAnswerKeySink
{
    private const string Table = "rca_answer_key";

    private static readonly TimeSpan EventReadLimit = TimeSpan.FromSeconds(60);

    // Each run being recorded, with its target and the end its runner gave it.
    private readonly ConcurrentDictionary<long, (DemoTarget Target, DateTimeOffset? EndedAt)> pending = new();
    private long recordings;

    /// <summary>
    /// Whether the answer key records a run: one that started. A refused run never did, so it has neither a start nor an
    /// end, and nothing of it is recorded. The profile host holds the stop's span for these runs only (ProfileHost.HoldsAfter).
    /// </summary>
    internal static bool Records(RunResult result) => result.StartedAt is not null && result.Status != "Refused";

    public void RunEnded(DemoTarget target, RunResult result)
    {
        if (!Records(result))
        {
            return;
        }

        var key = Interlocked.Increment(ref recordings);
        pending[key] = (target, result.EndedAt);
        _ = Task.Run(async () =>
        {
            try
            {
                await RecordAsync(target, result).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                log.Warn("rca.answer-key-failed", "Couldn't record a run in the answer key.", ("target", target), ("runId", result.RunId), ("error", Redactor.Redact(ex.Message)));
            }
            finally
            {
                pending.TryRemove(key, out _);
            }
        });
    }

    public bool IsPending(DemoTarget target) => pending.Values.Any(p => p.Target == target);

    public bool IsPending(DemoTarget target, DateTimeOffset endedBy) => pending.Values.Any(p => p.Target == target && p.EndedAt is { } ended && ended <= endedBy);

    /// <summary>The run's answer-key rows: the run, then the events it reported (demo.scenario_run_events), its start event left out.</summary>
    internal static List<CaptureRow> Rows(DemoTarget target, RunResult result, IReadOnlyList<RunEvent> runEvents)
    {
        var token = ApplicationNames.RunToken(result.RunId);
        var started = result.StartedAt!.Value;
        var parameters = string.Join("; ", new[] { $"concurrency={result.Concurrency}", $"intensity={result.Intensity}" }.Concat(result.Parameters.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => $"{p.Key}={p.Value}")));
        var rows = new List<CaptureRow>
        {
            Row(target, started)
                .Set("kind", "run")
                .Set("end_time_utc", result.EndedAt)
                .Set("scenario", result.ScenarioId)
                .Set("scenario_run_id", result.RunId)
                .Set("run_token", token)
                .Set("outcome", result.Status switch { "Cancelled" => "Stopped", var status => status })
                .Set("detail", Clean(parameters)),
        };
        foreach (var item in runEvents.Where(e => !string.Equals(e.Name, "run-begin", StringComparison.Ordinal)))
        {
            rows.Add(Row(target, item.At)
                .Set("kind", "run-event")
                .Set("scenario", result.ScenarioId)
                .Set("scenario_run_id", result.RunId)
                .Set("run_token", token)
                .Set("event_name", item.Name)
                .Set("detail", Clean(item.Detail)));
        }

        return rows;
    }

    /// <summary>demo.scenario_run_events of one run on SQL Server or Azure SQL Database (the runner's own bookkeeping, not the capture).</summary>
    internal static async Task<IReadOnlyList<RunEvent>> ReadSqlAsync(SqlConnectionOpener opener, string runId, CancellationToken cancellationToken)
    {
        await using var connection = await opener.OpenAsync(SessionNames.ForControl("rca-key"), cancellationToken).ConfigureAwait(false);
        await using var command = connection.CreateCommand();
        command.CommandType = CommandType.Text;
        command.CommandTimeout = 30;
        // The observer's marker, after the first keyword: Query Store's reads leave it out (rca/README.md, What the capture leaves out, 1).
        command.CommandText = "SELECT /* dbhubdemo:rca-observer */ TOP (200) event_time, event_name, session_id, detail FROM demo.scenario_run_events WHERE run_id = @run_id ORDER BY event_time;";
        command.Parameters.Add("@run_id", SqlDbType.VarChar, 64).Value = runId;
        var events = new List<RunEvent>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            events.Add(new RunEvent(
                new DateTimeOffset(DateTime.SpecifyKind(reader.GetDateTime(0), DateTimeKind.Utc)),
                reader.GetString(1),
                reader.IsDBNull(2) ? null : Convert.ToInt32(reader.GetValue(2), CultureInfo.InvariantCulture),
                reader.IsDBNull(3) ? null : reader.GetString(3)));
        }

        return events;
    }

    /// <summary>The same on T4.</summary>
    internal static async Task<IReadOnlyList<RunEvent>> ReadPgAsync(PgConnectionOpener opener, string runId, CancellationToken cancellationToken)
    {
        await using var connection = await opener.OpenAsync(SessionNames.ForControl("rca-key"), cancellationToken).ConfigureAwait(false);
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT event_time, event_name, session_id, detail FROM demo.scenario_run_events WHERE run_id = @run_id ORDER BY event_time LIMIT 200;";
        command.Parameters.Add(new Npgsql.NpgsqlParameter("run_id", runId));
        command.CommandTimeout = 30;
        var events = new List<RunEvent>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        while (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            events.Add(new RunEvent(
                new DateTimeOffset(DateTime.SpecifyKind(reader.GetDateTime(0), DateTimeKind.Utc)),
                reader.GetString(1),
                reader.IsDBNull(2) ? null : Convert.ToInt32(reader.GetValue(2), CultureInfo.InvariantCulture),
                reader.IsDBNull(3) ? null : reader.GetString(3)));
        }

        return events;
    }

    private static CaptureRow Row(DemoTarget target, DateTimeOffset at) =>
        new CaptureRow(Table, target.ToString(), at, "runner").Set("target", target.ToString()).Set("event_time_utc", at);

    private static string? Clean(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        var redacted = Redactor.Redact(text.Trim());
        return redacted.Length <= TextNormalizer.DetailLength ? redacted : redacted[..(TextNormalizer.DetailLength - 3)] + "...";
    }

    private async Task RecordAsync(DemoTarget target, RunResult result)
    {
        IReadOnlyList<RunEvent> runEvents = [];
        if (events.TryGetValue(target, out var read))
        {
            using var bound = new CancellationTokenSource(EventReadLimit);
            try
            {
                runEvents = await read(result.RunId, bound.Token).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                log.Warn("rca.answer-key-events", "Couldn't read a run's events for the answer key; the run itself is recorded.", ("target", target), ("runId", result.RunId), ("error", Redactor.Redact(ex.Message)));
            }
        }

        foreach (var row in Rows(target, result, runEvents))
        {
            if (!store.AppendAnswerKey(row))
            {
                log.Debug("rca.answer-key-dropped", "No observation span was open for a run's answer key.", ("target", target), ("runId", result.RunId));
                return;
            }
        }
    }
}
