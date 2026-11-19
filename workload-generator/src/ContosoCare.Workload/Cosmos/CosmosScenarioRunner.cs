using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Runs;
using ContosoCare.Workload.Sql;

namespace ContosoCare.Workload.Cosmos;

/// <summary>
/// Runs one bounded scenario on T5, Azure Cosmos DB for NoSQL, with the same bounds and result as the other runners. T5
/// has no database-side control tables, so the run is registered in T1's run store (<see cref="CosmosRunStore"/>), which
/// refuses a second Running run of a scenario and a fifth Running run, as demo.usp_run_begin does. The runner first reads
/// the container, so an account it can't reach or a data-plane role that isn't effective yet is a refusal the profile host
/// tries again. Then its writers send tagged REST requests (User-Agent <c>ContosoCare.Demo/&lt;scenario&gt;/&lt;run&gt;</c>) to
/// <c>contosocare/patient-events</c> only, until the deadline or a stop: the runner reads its run's status every 2
/// seconds (a stop marks it Cancelled) and records its counters and rates every 5. Each request may take 30 seconds;
/// 60 seconds after the deadline the runner cancels the requests still in flight, and 15 seconds later it records the
/// run as TimedOut and stops waiting. There are no server-side sessions to end. Both scenarios write bounded, fixed sets
/// of documents; ru-storm deletes its own when it ends, however it ends (<see cref="StormCleanup"/>), so every run
/// starts from the same data.
/// </summary>
internal sealed class CosmosScenarioRunner(CosmosRestClient client, CosmosRunStore store, RunnerLog log, TimeProvider time) : IScenarioExecutor, IOrphanedRunRecovery
{
    /// <summary>The scenarios T5 runs.</summary>
    public static readonly IReadOnlySet<string> Scenarios = new HashSet<string>([HealthyBaselineMix.ScenarioId, RuStorm.ScenarioId], StringComparer.Ordinal);

    /// <summary>A writer gives up after this many failed requests in a row (with backoff, a minute or more of failures).</summary>
    internal const int MaximumConsecutiveErrors = 20;

    /// <summary>The longest ru-storm's cleanup may take at the end of a run: far more than its 400 documents need at 200 RU/s.</summary>
    internal static readonly TimeSpan StormCleanupLimit = TimeSpan.FromMinutes(2);

    /// <summary>The cleanup's limit when the run's caller stopped it (Ctrl+C, SIGTERM, the profile host stopping), within the process's termination grace; reset deletes what's left.</summary>
    internal static readonly TimeSpan StormCleanupOnShutdown = TimeSpan.FromSeconds(20);

    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan StopCheckInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan ProgressInterval = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan GracefulStopWindow = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan GiveUpAfterAbort = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan MaximumBackoff = TimeSpan.FromSeconds(5);

    public string Description => client.Endpoint.Describe();

    public CosmosRunStore Store => store;

    public async Task<RunResult> RunAsync(RunPlan plan, CancellationToken cancellationToken)
    {
        var runId = SessionNames.NewRunId(time.GetUtcNow(), plan.Target);
        var tag = SessionNames.ForRun(plan.Scenario.Id, runId);
        var parameters = plan.Parameters.ToDictionary(p => p.Key, p => p.Value.ToString(), StringComparer.Ordinal);
        log.Info(
            "run.planned",
            "Scenario run planned.",
            ("runId", runId),
            ("scenario", plan.Scenario.Id),
            ("target", plan.Target),
            ("server", client.Endpoint.Host),
            ("duration", plan.Duration),
            ("concurrency", plan.Concurrency),
            ("intensity", plan.Intensity),
            ("parameters", string.Join(",", parameters.Select(p => p.Key + "=" + p.Value))));
        foreach (var adjustment in plan.Adjustments)
        {
            log.Warn("run.adjusted", adjustment, ("runId", runId));
        }

        var checks = new List<CheckRecord>();
        if (plan.Target != DemoTarget.T5)
        {
            return Refused(plan, runId, parameters, "The Cosmos DB runner drives T5 only.", checks, "request");
        }

        if (!Scenarios.Contains(plan.Scenario.Id))
        {
            return Refused(plan, runId, parameters, $"T5 has no workload for '{plan.Scenario.Id}'; it runs {string.Join(" and ", Scenarios.Order(StringComparer.Ordinal))}.", checks, "request");
        }

        try
        {
            var container = await CosmosAccount.ReadContainerAsync(client, SessionNames.ForControl(runId), time, cancellationToken).ConfigureAwait(false);
            if (!container.HasExpectedPartitionKey)
            {
                return Refused(plan, runId, parameters, $"T5's container {CosmosEndpoint.DatabaseName}/{CosmosEndpoint.ContainerName} is partitioned on {container.DescribePartitionKey()}, not {CosmosEndpoint.PartitionKeyPath}; run setup --target T5 for the fix.", checks, "request");
            }
        }
        catch (CosmosException ex)
        {
            return Refused(plan, runId, parameters, ex.Message, checks, ex.RefusalReason);
        }

        RunRegistration registration;
        try
        {
            if (plan.ResetBefore)
            {
                var reset = await CosmosReset.RunAsync(store, client, new ResetOptions(plan.RequestedBy, 30, KillSessions: true, KeepProfile: true, UndoRemediation: false, Reseed: false), time, cancellationToken).ConfigureAwait(false);
                checks.AddRange(reset.Select(r => r with { CheckId = "reset-before:" + r.CheckId }));
                log.Info("run.reset", "Reset before the run.", ("runId", runId), ("checks", string.Join(", ", reset.Select(r => r.CheckId + "=" + r.Status))));
            }

            registration = await store.BeginRunAsync(
                new CosmosRunStart(runId, plan.Scenario.Id, plan.DurationSeconds, plan.Scenario.Duration.MaxSeconds, plan.Concurrency, plan.Intensity, plan.ParametersJson(), plan.RequestedBy, plan.ProfileName),
                cancellationToken).ConfigureAwait(false);
        }
        catch (CosmosRunRefusedException ex)
        {
            return Refused(plan, runId, parameters, ex.Message, checks, ex.Reason);
        }
        catch (ScenarioRequestException ex)
        {
            return Refused(plan, runId, parameters, ex.Message, checks, "request");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            // A lock another writer holds too long passes; a file the runner may not write doesn't.
            return Refused(plan, runId, parameters, $"T5's run store ({store.FilePath}) couldn't be updated: {ex.Message}", checks, ex is UnauthorizedAccessException ? "request" : "connect");
        }

        return await ExecuteAsync(plan, runId, tag, parameters, registration, checks, cancellationToken).ConfigureAwait(false);
    }

    public Task<IReadOnlyList<CheckRecord>> ResetAsync(ResetOptions options, CancellationToken cancellationToken) =>
        CosmosReset.RunAsync(store, client, options, time, cancellationToken);

    /// <summary>
    /// Ends this machine's profile runs that an earlier host left Running, whose process is gone. A recovered ru-storm never
    /// deleted its documents, so they're deleted now, and the next session starts from the baseline's data.
    /// </summary>
    public async Task<IReadOnlyList<string>?> RecoverOrphanedProfileRunsAsync(string machineName, DateTimeOffset startedBefore, CancellationToken cancellationToken)
    {
        var recovered = await store.RecoverOrphanedProfileRunsAsync(machineName, startedBefore, HostLaneStatus.IsProcessAlive, cancellationToken).ConfigureAwait(false);
        if (recovered.Any(r => r.ScenarioId == RuStorm.ScenarioId))
        {
            var cleanup = await StormCleanup.RunAsync(client, SessionNames.ForControl("profile-recover"), time, StormCleanupLimit, cancellationToken).ConfigureAwait(false);
            log.Info("run.cleanup", "Deleted the documents of a storm whose runner ended mid-run.", ("deleted", cleanup.Deleted), ("complete", cleanup.Complete), ("requestCharge", cleanup.RequestCharge), ("error", cleanup.Error));
        }

        return [.. recovered.Select(r => r.RunId)];
    }

    private async Task<RunResult> ExecuteAsync(
        RunPlan plan,
        string runId,
        string tag,
        Dictionary<string, string> parameters,
        RunRegistration registration,
        List<CheckRecord> checks,
        CancellationToken cancellationToken)
    {
        var started = time.GetUtcNow();
        var deadline = started + TimeSpan.FromSeconds(registration.EffectiveDurationSeconds);
        var hardDeadline = deadline + RunLimits.Grace;
        var storm = plan.Scenario.Id == RuStorm.ScenarioId ? StormSettings.From(plan) : null;
        log.Info("run.started", "Run registered; writers starting.", ("runId", runId), ("tag", tag), ("deadline", registration.DeadlineAt));

        using var stop = new CancellationTokenSource();
        using var abort = new CancellationTokenSource();
        var meter = new CosmosRunMeter();
        var context = new RunContext(plan, runId, tag, started, deadline, storm, meter, new WorkerTracker(), stop.Token, abort.Token);
        var work = RunWorkersAsync(context);
        var rates = new LiveRateWindow(started);

        var cancelledByCaller = false;
        var stopRequested = false;
        var watchdog = false;
        var lastStopCheck = DateTimeOffset.MinValue;
        var lastProgress = started;
        StormPhase? lastPhase = null;
        DateTimeOffset? abortAt = null;
        DateTimeOffset? giveUpAt = null;

        while (!work.IsCompleted)
        {
            await Task.WhenAny(work, Task.Delay(PollInterval, time, CancellationToken.None)).ConfigureAwait(false);
            if (work.IsCompleted)
            {
                break;
            }

            var now = time.GetUtcNow();
            if (storm is not null && !stop.IsCancellationRequested)
            {
                var phase = RuStorm.PhaseAt(now - started, storm.StormSeconds, storm.CalmSeconds);
                if (lastPhase is not { } previous || previous.Storm != phase.Storm || previous.Wave != phase.Wave)
                {
                    lastPhase = phase;
                    log.Info(
                        "run.wave",
                        phase.Storm
                            ? string.Create(CultureInfo.InvariantCulture, $"Storm wave {phase.Wave}: {plan.Concurrency} writer(s) on {storm.Partitions} for up to {storm.StormSeconds} s.")
                            : string.Create(CultureInfo.InvariantCulture, $"Calm after wave {phase.Wave}: no storm writes for {storm.CalmSeconds} s."),
                        ("runId", runId));
                }
            }

            if (cancellationToken.IsCancellationRequested && !cancelledByCaller)
            {
                cancelledByCaller = true;
                log.Info("run.cancelling", "Cancellation requested; asking the run's writers to stop.", ("runId", runId));
                await TryAsync(() => store.StopAsync("run", runId, null, plan.RequestedBy, CancellationToken.None), "stop").ConfigureAwait(false);
                await stop.CancelAsync().ConfigureAwait(false);
                abortAt ??= now + TimeSpan.FromSeconds(15);
            }
            else if (!stop.IsCancellationRequested && now - lastStopCheck >= StopCheckInterval)
            {
                lastStopCheck = now;
                if (await IsStopRequestedAsync(runId).ConfigureAwait(false))
                {
                    stopRequested = true;
                    log.Info("run.stop-requested", "A stop was requested; the run's writers are ending.", ("runId", runId));
                    await stop.CancelAsync().ConfigureAwait(false);
                    abortAt ??= now + GracefulStopWindow;
                }
            }

            if (now - lastProgress >= ProgressInterval)
            {
                lastProgress = now;
                var sample = meter.Sample(now);
                var live = rates.Add(sample);
                await TryAsync(() => store.UpdateProgressAsync(runId, sample.ToCounters(), live, CancellationToken.None), "progress").ConfigureAwait(false);
            }

            if (!stop.IsCancellationRequested && now >= deadline)
            {
                await stop.CancelAsync().ConfigureAwait(false);
            }

            if (abortAt is null && now >= hardDeadline)
            {
                abortAt = now;
            }

            if (abortAt is { } cancelAt && now >= cancelAt && !abort.IsCancellationRequested)
            {
                watchdog = !cancelledByCaller && !stopRequested;
                log.Warn("run.watchdog", "Writers are still running past their limit; cancelling their requests.", ("runId", runId));
                await abort.CancelAsync().ConfigureAwait(false);
                giveUpAt = now + GiveUpAfterAbort;
            }

            if (giveUpAt is { } giveUp && now >= giveUp)
            {
                log.Error("run.abandoned", "Writers still haven't ended; recording the run without them.", ("runId", runId));
                break;
            }
        }

        IReadOnlyList<WorkerOutcome> outcomes = work.IsCompletedSuccessfully ? await work.ConfigureAwait(false) : context.Workers.Collect();

        // A run whose writers all ended before its deadline may have been stopped since the last check.
        if (!cancelledByCaller && !stopRequested && time.GetUtcNow() < deadline)
        {
            stopRequested = await IsStopRequestedAsync(runId).ConfigureAwait(false);
        }

        var errors = outcomes.Where(o => o.Error is not null).ToList();
        var status = !work.IsCompleted
            ? CosmosRunStatus.TimedOut
            : errors.Count > 0 ? CosmosRunStatus.Failed
            : cancelledByCaller || stopRequested ? CosmosRunStatus.Cancelled
            : watchdog ? CosmosRunStatus.TimedOut
            : CosmosRunStatus.Completed;

        var ended = time.GetUtcNow();
        var totals = meter.Sample(ended);
        var waves = storm is null ? 0 : RuStorm.PhaseAt(Earlier(ended, deadline) - started, storm.StormSeconds, storm.CalmSeconds).Wave;
        var outcome = string.Create(
            CultureInfo.InvariantCulture,
            $"{totals.Requests} request(s), {totals.RequestCharge:0.##} RU, {totals.Throttled} throttled (429), {totals.Errors} error(s){(storm is null ? string.Empty : string.Create(CultureInfo.InvariantCulture, $", {waves} storm wave(s) on {storm.Partitions}"))}. {ScenarioRunner.Summarize(outcomes)}");
        if (errors.Count > 0)
        {
            outcome = $"{errors.Count} writer(s) failed: {Redactor.Redact(errors[0].Error)} {outcome}";
        }

        var unfinished = outcomes.Count(o => o.Unfinished);
        if (cancelledByCaller)
        {
            outcome = "Stopped by its caller (the profile host or Ctrl+C). " + outcome;
        }

        if (watchdog)
        {
            outcome = "The watchdog had to cancel this run's requests. " + outcome;
        }

        checks.Add(unfinished == 0
            ? new CheckRecord("run-requests-ended", "Pass", "Every writer of this run stopped; none of its requests is still in flight.")
            : new CheckRecord("run-requests-ended", "Warning", string.Create(CultureInfo.InvariantCulture, $"{unfinished} of {outcomes.Count} writer(s) were still ending when the run was recorded; their requests time out within {CosmosRestClient.RequestTimeout.TotalSeconds:0} s.")));
        if (storm is not null)
        {
            checks.Add(totals.Throttled > 0
                ? new CheckRecord("throttled", "Pass", string.Create(CultureInfo.InvariantCulture, $"{totals.Throttled} request(s) were throttled (HTTP 429) in {waves} storm wave(s); every writer waited the server's retry-after ({RuStorm.MinimumRetryAfter.TotalMilliseconds:0} ms to {RuStorm.MaximumRetryAfter.TotalSeconds:0} s) before its next write."))
                : status == CosmosRunStatus.Completed
                    ? new CheckRecord("throttled", "Warning", "No request was throttled: the storm didn't use up the container's throughput. Raise --concurrency, --intensity, or --param documentKb, or check that patient-events has 400 RU/s of manual throughput.")
                    : new CheckRecord("throttled", "Not selected", "The run ended before a storm wave was throttled."));
        }

        // ru-storm deletes its storm documents however it ended, before the run is recorded as ended, so reset's wait and
        // the next run see the container as the baseline left it.
        if (storm is null)
        {
            checks.Add(new CheckRecord("auto-cleanup", "Not selected", "Nothing to clean up: healthy-baseline overwrites a bounded set of documents (database/cosmosdb/README.md)."));
        }
        else if (!plan.AutoCleanup)
        {
            checks.Add(new CheckRecord("auto-cleanup", "Not selected", "Auto-cleanup is off, so the storm documents stay (400 at most) until 'reset --target T5' or the next ru-storm run deletes them."));
        }
        else
        {
            var cleanup = await StormCleanup.RunAsync(client, tag, time, cancelledByCaller ? StormCleanupOnShutdown : StormCleanupLimit, CancellationToken.None).ConfigureAwait(false);
            log.Info("run.cleanup", "Deleted the storm's documents.", ("runId", runId), ("deleted", cleanup.Deleted), ("complete", cleanup.Complete), ("requestCharge", cleanup.RequestCharge), ("elapsed", cleanup.Elapsed), ("error", cleanup.Error));
            checks.Add(cleanup.ToCheck("auto-cleanup"));
            outcome += string.Create(CultureInfo.InvariantCulture, $" Cleanup: {cleanup.Deleted} storm document(s) deleted ({cleanup.RequestCharge:0.#} RU){(cleanup.Complete ? string.Empty : ", some may be left")}.");
        }

        await TryAsync(() => store.EndRunAsync(runId, status, outcome, totals.ToCounters(), CancellationToken.None), "end").ConfigureAwait(false);

        ended = time.GetUtcNow();
        var result = status switch
        {
            CosmosRunStatus.Completed or CosmosRunStatus.Cancelled => "Pass",
            CosmosRunStatus.TimedOut => "Warning",
            _ => "Fail",
        };
        log.Info("run.ended", "Run ended.", ("runId", runId), ("status", status), ("result", result), ("elapsed", ended - started), ("outcome", outcome));

        return new RunResult
        {
            RunId = runId,
            ScenarioId = plan.Scenario.Id,
            Target = plan.Target,
            Status = status,
            Result = result,
            Outcome = outcome,
            StartedAt = started,
            EndedAt = ended,
            DeadlineAt = registration.DeadlineAt,
            DurationSeconds = registration.EffectiveDurationSeconds,
            Concurrency = plan.Concurrency,
            Intensity = plan.Intensity,
            Parameters = parameters,
            Adjustments = plan.Adjustments,
            Workers = outcomes,
            Checks = checks,
            ExpectedSymptoms = plan.Scenario.ExpectedSymptoms,
        };
    }

    private async Task<IReadOnlyList<WorkerOutcome>> RunWorkersAsync(RunContext context)
    {
        var tasks = new List<Task<WorkerOutcome>>();
        for (var index = 1; index <= context.Plan.Concurrency; index++)
        {
            tasks.Add(context.Storm is null
                ? context.Workers.Track("worker", index, BaselineWorkerAsync(context, index))
                : context.Workers.Track("writer", index, StormWriterAsync(context, index)));
        }

        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>
    /// healthy-baseline on T5: one worker's steady mix (<see cref="HealthyBaselineMix"/>), pausing between requests by
    /// intensity, about one request a second at 1 and about 20 at 10, as on the SQL targets.
    /// </summary>
    private async Task<WorkerOutcome> BaselineWorkerAsync(RunContext context, int worker)
    {
        var counters = new WorkerCounters();
        var pause = CosmosPacing.BaselinePause(context.Plan.Intensity);
        long turn = 0;
        try
        {
            await Task.Yield();
            while (!context.Stop.IsCancellationRequested && time.GetUtcNow() < context.Deadline)
            {
                var operation = HealthyBaselineMix.Next(RandomNumberGenerator.GetInt32, turn);
                var now = time.GetUtcNow();
                Func<CancellationToken, Task<CosmosResponse>> send;
                switch (operation.Kind)
                {
                    case CosmosOperationKind.Read:
                        counters.Reads++;
                        send = t => client.ReadAsync(context.Tag, operation.PatientId, operation.DocumentId!, t);
                        break;
                    case CosmosOperationKind.Upsert:
                        counters.Upserts++;
                        var document = operation.DocumentId == HealthyBaselineMix.ProfileId
                            ? CosmosDocuments.Patient(operation.PatientId, HealthyBaselineMix.PatientNumber(operation.PatientId), now, context.Tag, HealthyBaselineMix.ProfilePayloadLength)
                            : CosmosDocuments.Event(operation.DocumentId!, operation.PatientId, operation.Type!, turn, now, context.Tag, HealthyBaselineMix.EventPayloadLength(turn));
                        send = t => client.UpsertAsync(context.Tag, operation.PatientId, document, t);
                        break;
                    default:
                        counters.Queries++;
                        send = t => client.QueryAsync(context.Tag, operation.PatientId, HealthyBaselineMix.Query, [new KeyValuePair<string, string>("@p", operation.PatientId)], CosmosRestClient.MaxItemCount, t);
                        break;
                }

                var wait = await SendAsync(context, counters, send, operation.Kind == CosmosOperationKind.Read, pause).ConfigureAwait(false);
                turn++;
                await WaitUntilAsync(time.GetUtcNow() + wait, context).ConfigureAwait(false);
            }

            return new WorkerOutcome("worker", worker, null, counters.ToMetrics(), null, false);
        }
        catch (WriterFailedException ex)
        {
            return new WorkerOutcome("worker", worker, null, counters.ToMetrics(), ex.Message, false);
        }
        catch (Exception ex) when (IsCancellation(ex, context))
        {
            return new WorkerOutcome("worker", worker, null, counters.ToMetrics(), null, true);
        }
    }

    /// <summary>
    /// ru-storm: one writer's upserts to its hot partition during each storm wave, as fast as the pacing allows, at most
    /// 100 a second; after a 429 it waits the server's retry-after (10 ms to 2 seconds). In the calm it writes nothing.
    /// </summary>
    private async Task<WorkerOutcome> StormWriterAsync(RunContext context, int writer)
    {
        var settings = context.Storm!;
        var counters = new WorkerCounters();
        var partitionNumber = RuStorm.PartitionNumberFor(writer, settings.HotPartitions);
        var partition = RuStorm.PartitionName(partitionNumber);
        var payloadLength = RuStorm.PayloadLength(settings.DocumentKb);
        var pause = RuStorm.PauseFor(context.Plan.Intensity);
        var nextStart = DateTimeOffset.MinValue;
        long sequence = 0;
        try
        {
            await Task.Yield();
            while (!context.Stop.IsCancellationRequested && time.GetUtcNow() < context.Deadline)
            {
                var now = time.GetUtcNow();
                var phase = RuStorm.PhaseAt(now - context.Started, settings.StormSeconds, settings.CalmSeconds);
                if (!phase.Storm)
                {
                    // The calm: no storm writes, so normalized RU falls back and the 429s stop.
                    await WaitUntilAsync(Earlier(now + phase.Remaining, context.Deadline), context).ConfigureAwait(false);
                    continue;
                }

                if (now < nextStart)
                {
                    await WaitUntilAsync(nextStart, context).ConfigureAwait(false);
                    continue;
                }

                nextStart = now + RuStorm.MinimumInterval;
                var document = CosmosDocuments.StormReading(RuStorm.DocumentId(partitionNumber, writer, sequence), partition, writer, sequence, now, context.Tag, payloadLength);
                counters.Upserts++;
                var wait = await SendAsync(context, counters, t => client.UpsertAsync(context.Tag, partition, document, t), false, pause).ConfigureAwait(false);
                sequence++;
                var resumeAt = time.GetUtcNow() + wait;
                await WaitUntilAsync(resumeAt > nextStart ? resumeAt : nextStart, context).ConfigureAwait(false);
            }

            return new WorkerOutcome("writer", writer, null, counters.ToMetrics(), null, false);
        }
        catch (WriterFailedException ex)
        {
            return new WorkerOutcome("writer", writer, null, counters.ToMetrics(), ex.Message, false);
        }
        catch (Exception ex) when (IsCancellation(ex, context))
        {
            return new WorkerOutcome("writer", writer, null, counters.ToMetrics(), null, true);
        }
    }

    /// <summary>
    /// Sends one request and accounts for it; returns how long to wait before the next. A 429 waits the server's
    /// retry-after; a request that fails for a reason that passes (no answer, 408, 410, 449, 5xx) waits a backoff, and 20
    /// in a row end the writer; 401, 403, 404 (a missing container), and other refusals end it at once.
    /// </summary>
    private async Task<TimeSpan> SendAsync(RunContext context, WorkerCounters counters, Func<CancellationToken, Task<CosmosResponse>> send, bool missIsNormal, TimeSpan pause)
    {
        CosmosResponse response;
        try
        {
            response = await send(context.Abort).ConfigureAwait(false);
        }
        catch (CosmosException ex) when (ex.Failure is CosmosFailure.Unreachable or CosmosFailure.Token or CosmosFailure.Transient && !context.Abort.IsCancellationRequested)
        {
            context.Meter.RecordError();
            return Failed(counters, ex.Message);
        }

        context.Meter.Record(response);
        counters.Requests++;
        counters.RequestCharge += response.RequestCharge;
        if (response.IsThrottled)
        {
            counters.Throttled++;
            counters.ConsecutiveErrors = 0;
            return RuStorm.RetryWait(response.RetryAfter);
        }

        if (response.IsSuccess || (missIsNormal && response.IsDocumentMiss))
        {
            if (!response.IsSuccess)
            {
                counters.Misses++;
            }

            counters.ConsecutiveErrors = 0;
            return pause;
        }

        context.Meter.RecordError();
        var failure = response.ToException("A " + context.Plan.Scenario.Id + " request", client.Endpoint.Host);
        if (failure.Failure == CosmosFailure.Transient)
        {
            return Failed(counters, failure.Message);
        }

        counters.Errors++;
        throw new WriterFailedException(failure.Message);
    }

    /// <summary>Counts a failed request and returns the backoff before the next: 0.5, 1, 2, 4, then 5 seconds; throws once too many fail in a row.</summary>
    private static TimeSpan Failed(WorkerCounters counters, string message)
    {
        counters.Errors++;
        counters.ConsecutiveErrors++;
        if (counters.ConsecutiveErrors >= MaximumConsecutiveErrors)
        {
            throw new WriterFailedException(string.Create(CultureInfo.InvariantCulture, $"{counters.ConsecutiveErrors} requests in a row failed; the last: {message}"));
        }

        var backoff = TimeSpan.FromMilliseconds(500 * Math.Pow(2, Math.Min(counters.ConsecutiveErrors - 1, 4)));
        return backoff < MaximumBackoff ? backoff : MaximumBackoff;
    }

    /// <summary>True when the store says the run must stop: a stop marked it Cancelled, or it's gone from the store. A store that can't be read says nothing.</summary>
    private async Task<bool> IsStopRequestedAsync(string runId)
    {
        var read = await TryAsync(async () => (Read: true, Run: await store.GetRunAsync(runId, CancellationToken.None).ConfigureAwait(false)), "stop-check").ConfigureAwait(false);
        return read.Read && (read.Run is null || read.Run.Status != CosmosRunStatus.Running);
    }

    private async Task WaitUntilAsync(DateTimeOffset until, RunContext context)
    {
        var wait = until - time.GetUtcNow();
        if (wait <= TimeSpan.Zero)
        {
            return;
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(context.Stop, context.Abort);
        try
        {
            await Task.Delay(wait, time, linked.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!context.Abort.IsCancellationRequested)
        {
            // A stop request ends the wait early; the caller checks context.Stop.
        }
    }

    private RunResult Refused(RunPlan plan, string runId, Dictionary<string, string> parameters, string reason, List<CheckRecord> checks, string refusalReason)
    {
        log.Error("run.refused", "The run didn't start.", ("runId", runId), ("scenario", plan.Scenario.Id), ("target", plan.Target), ("reason", reason));
        return new RunResult
        {
            RunId = runId,
            ScenarioId = plan.Scenario.Id,
            Target = plan.Target,
            Status = "Refused",
            Result = "Fail",
            Outcome = Redactor.Redact(reason),
            DurationSeconds = plan.DurationSeconds,
            Concurrency = plan.Concurrency,
            Intensity = plan.Intensity,
            Parameters = parameters,
            Adjustments = plan.Adjustments,
            Checks = checks,
            ExpectedSymptoms = plan.Scenario.ExpectedSymptoms,
            RefusalReason = refusalReason,
        };
    }

    private async Task<T?> TryAsync<T>(Func<Task<T>> action, string what)
    {
        try
        {
            return await action().ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException)
        {
            log.Warn("run.control-error", "A run store call failed; the run continues within its bounds.", ("operation", what), ("store", store.FilePath), ("error", ex.Message));
            return default;
        }
    }

    private async Task TryAsync(Func<Task> action, string what)
    {
        await TryAsync(
            async () =>
            {
                await action().ConfigureAwait(false);
                return true;
            },
            what).ConfigureAwait(false);
    }

    private static bool IsCancellation(Exception exception, RunContext context) =>
        (context.Abort.IsCancellationRequested || context.Stop.IsCancellationRequested)
        && exception is OperationCanceledException or CosmosException;

    private static DateTimeOffset Earlier(DateTimeOffset a, DateTimeOffset b) => a <= b ? a : b;

    private sealed record RunContext(
        RunPlan Plan,
        string RunId,
        string Tag,
        DateTimeOffset Started,
        DateTimeOffset Deadline,
        StormSettings? Storm,
        CosmosRunMeter Meter,
        WorkerTracker Workers,
        CancellationToken Stop,
        CancellationToken Abort);

    /// <summary>One writer's counters, which its outcome reports (the run's outcome sums them by role).</summary>
    private sealed class WorkerCounters
    {
        public long Requests { get; set; }

        public long Throttled { get; set; }

        public long Errors { get; set; }

        public int ConsecutiveErrors { get; set; }

        public double RequestCharge { get; set; }

        public long Reads { get; set; }

        public long Misses { get; set; }

        public long Upserts { get; set; }

        public long Queries { get; set; }

        public Dictionary<string, object?> ToMetrics()
        {
            var metrics = new Dictionary<string, object?>(StringComparer.Ordinal)
            {
                ["requests"] = Requests,
                ["throttled"] = Throttled,
                ["errors"] = Errors,
                ["request_charge"] = Math.Round((decimal)RequestCharge, 2),
                ["upserts"] = Upserts,
            };
            if (Reads > 0 || Queries > 0)
            {
                metrics["reads"] = Reads;
                metrics["read_misses"] = Misses;
                metrics["queries"] = Queries;
            }

            return metrics;
        }
    }

    /// <summary>Ends a writer for a failure that won't pass by itself (or too many in a row); its message is redacted and safe to show.</summary>
    private sealed class WriterFailedException(string message) : Exception(Redactor.Redact(message));
}
