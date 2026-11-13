using System.Collections.Concurrent;
using System.Data;
using System.Globalization;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Runs;
using ContosoCare.Workload.Sql;
using Npgsql;

namespace ContosoCare.Workload.Postgres;

/// <summary>
/// Runs one bounded scenario on T4 (Phase 24, ADR 0010, ADR 0019) with the same bounds and result as the T-SQL
/// runner: it registers the run in demo.scenario_runs (the database layer clamps the duration), opens tagged sessions
/// (ContosoCare.Demo/&lt;scenario&gt;/&lt;run&gt;) with statement, lock, and idle-in-transaction timeouts that end before
/// the run's hard deadline, and calls each scenario's short step function in a loop until the deadline or a stop
/// request; every step raises SQLSTATE CC001 once the run has ended. Layer 2: the run's commands are cancelled 60
/// seconds after the deadline. Layer 3, the watchdog: sessions still open 15 seconds later are ended with
/// pg_terminate_backend through demo.usp_kill_demo_sessions, which touches this run's sessions only. With
/// <paramref name="replica"/>, T4's read replica (ADR 0025): replica-lag's report runs there, and reset ends the demo's
/// sessions there too.
/// </summary>
internal sealed class PgScenarioRunner(PgConnectionOpener opener, RunnerLog log, TimeProvider time, PgConnectionOpener? replica = null) : IScenarioExecutor
{
    /// <summary>Raised by demo.usp_run_assert_running once a run is stopped or past its deadline.</summary>
    internal const string RunEndedState = "CC001";

    private const string QueryCanceledState = "57014";
    private const string LockNotAvailableState = "55P03";
    private const string DeadlockDetectedState = "40P01";
    private const string IdleInTransactionTimeoutState = "25P03";
    private const string TooManyConnectionsState = "53300";

    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan StopCheckInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan GracefulStopWindow = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan KillAfterCancel = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan GiveUpAfterKill = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan HoldPollInterval = TimeSpan.FromMilliseconds(250);
    private static readonly TimeSpan LagCheckInterval = TimeSpan.FromSeconds(5);

    public string Description => replica is null ? opener.Endpoint.Describe() : opener.Endpoint.Describe() + "; " + replica.Endpoint.Describe();

    public async Task<RunResult> RunAsync(RunPlan plan, CancellationToken cancellationToken)
    {
        var runId = SessionNames.NewRunId(time.GetUtcNow(), plan.Target);
        var applicationName = SessionNames.ForRun(plan.Scenario.Id, runId);
        var parameters = plan.Parameters.ToDictionary(p => p.Key, p => p.Value.ToString(), StringComparer.Ordinal);
        log.Info(
            "run.planned",
            "Scenario run planned.",
            ("runId", runId),
            ("scenario", plan.Scenario.Id),
            ("target", plan.Target),
            ("server", opener.Endpoint.Host),
            ("duration", plan.Duration),
            ("concurrency", plan.Concurrency),
            ("intensity", plan.Intensity),
            ("parameters", string.Join(",", parameters.Select(p => p.Key + "=" + p.Value))));
        foreach (var adjustment in plan.Adjustments)
        {
            log.Warn("run.adjusted", adjustment, ("runId", runId));
        }

        var checks = new List<CheckRecord>();
        if (plan.Target != DemoTarget.T4)
        {
            return Refused(plan, runId, parameters, "The PostgreSQL runner drives T4 only.", checks, "request");
        }

        if (plan.Scenario.Id == ReplicaLag.ScenarioId)
        {
            if (replica is null)
            {
                return Refused(plan, runId, parameters, ReplicaLag.NoReplicaReason, checks, "request");
            }

            var problem = await CheckReplicaAsync(runId, cancellationToken).ConfigureAwait(false);
            if (problem is { } refusal)
            {
                return Refused(plan, runId, parameters, refusal.Reason, checks, refusal.RefusalReason);
            }
        }

        NpgsqlConnection control;
        try
        {
            control = await opener.OpenAsync(SessionNames.ForControl(runId), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is NpgsqlException or InvalidOperationException or ScenarioRequestException or ArgumentException or Azure.Identity.AuthenticationFailedException or Azure.Identity.CredentialUnavailableException)
        {
            return Refused(plan, runId, parameters, $"Can't connect to T4: {PgConnectionOpener.Describe(ex)}", checks, ex is ScenarioRequestException or ArgumentException ? "request" : "connect");
        }

        await using (control.ConfigureAwait(false))
        {
            var database = new PgDemoDatabase(control);
            RunRegistration registration;
            try
            {
                if (plan.ResetBefore)
                {
                    var reset = await database.ResetAsync(new ResetOptions(plan.RequestedBy, 30, KillSessions: true, KeepProfile: true, UndoRemediation: false, Reseed: false), time, cancellationToken).ConfigureAwait(false);
                    checks.AddRange(reset.Select(r => r with { CheckId = "reset-before:" + r.CheckId }));
                    if (replica is not null)
                    {
                        checks.Add(await PgReplicaSessions.EndAsync(replica, "reset-before:replica-sessions-ended", ReplicaSessionScope.All, kill: true, time, cancellationToken).ConfigureAwait(false));
                    }

                    log.Info("run.reset", "Reset before the run.", ("runId", runId), ("checks", string.Join(", ", checks.Select(r => r.CheckId + "=" + r.Status))));
                }

                registration = await database.BeginRunAsync(
                    runId,
                    plan.Scenario.Id,
                    plan.DurationSeconds,
                    plan.Concurrency,
                    plan.Intensity,
                    plan.ParametersJson(),
                    plan.Scenario.ExpectedSymptomsSummary(),
                    plan.RequestedBy,
                    plan.ProfileName,
                    cancellationToken).ConfigureAwait(false);
            }
            catch (ScenarioRequestException ex)
            {
                return Refused(plan, runId, parameters, ex.Message, checks, "request");
            }
            catch (PostgresException ex)
            {
                return Refused(plan, runId, parameters, PgConnectionOpener.Describe(ex), checks, RegistrationRefusalReason(ex));
            }

            return await ExecuteAsync(plan, runId, applicationName, parameters, registration, database, checks, cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task<IReadOnlyList<CheckRecord>> ResetAsync(ResetOptions options, CancellationToken cancellationToken)
    {
        List<CheckRecord> checks;
        await using (var connection = await opener.OpenAsync(SessionNames.ForControl("reset"), cancellationToken).ConfigureAwait(false))
        {
            checks = [.. await new PgDemoDatabase(connection).ResetAsync(options, time, cancellationToken).ConfigureAwait(false)];
        }

        // T4's read replica (ADR 0025): the demo's sessions there end too. A replica that isn't there never fails T4's reset.
        if (replica is not null)
        {
            checks.Add(await PgReplicaSessions.EndAsync(replica, "replica-sessions-ended", ReplicaSessionScope.All, options.KillSessions, time, cancellationToken).ConfigureAwait(false));
        }

        return checks;
    }

    private async Task<RunResult> ExecuteAsync(
        RunPlan plan,
        string runId,
        string applicationName,
        Dictionary<string, string> parameters,
        RunRegistration registration,
        PgDemoDatabase database,
        List<CheckRecord> checks,
        CancellationToken cancellationToken)
    {
        var started = time.GetUtcNow();
        var deadline = started + TimeSpan.FromSeconds(registration.EffectiveDurationSeconds);
        var hardDeadline = deadline + RunLimits.Grace;
        log.Info("run.started", "Run registered; sessions starting.", ("runId", runId), ("applicationName", applicationName), ("deadline", registration.DeadlineAt));

        using var stop = new CancellationTokenSource();
        using var abort = new CancellationTokenSource();
        var context = new RunContext(plan, runId, applicationName, deadline, hardDeadline, new ConcurrentQueue<RunEvent>(), stop.Token, abort.Token);
        var work = plan.Scenario.Id switch
        {
            "locking-blocking" => RunLockingAsync(context),
            "connection-surge" => RunConnectionSurgeAsync(context, database),
            "idle-in-transaction" => RunIdleInTransactionAsync(context),
            "io-pressure" => RunIoAsync(context),
            ReplicaLag.ScenarioId => RunReplicaLagAsync(context),
            _ => RunWorkersAsync(context),
        };

        var cancelledByCaller = false;
        var stopRequested = false;
        var watchdog = false;
        var lastStopCheck = DateTimeOffset.MinValue;
        DateTimeOffset? abortAt = null;
        DateTimeOffset? killAt = null;
        DateTimeOffset? giveUpAt = null;

        while (!work.IsCompleted)
        {
            await Task.WhenAny(work, Task.Delay(PollInterval, time, CancellationToken.None)).ConfigureAwait(false);
            if (work.IsCompleted)
            {
                break;
            }

            var now = time.GetUtcNow();
            await FlushEventsAsync(database, runId, context.Events).ConfigureAwait(false);

            if (cancellationToken.IsCancellationRequested && !cancelledByCaller)
            {
                cancelledByCaller = true;
                log.Info("run.cancelling", "Cancellation requested; asking the run's sessions to stop.", ("runId", runId));
                await TryAsync(() => database.StopAsync("run", runId, null, plan.RequestedBy, CancellationToken.None), "stop").ConfigureAwait(false);
                await stop.CancelAsync().ConfigureAwait(false);
                abortAt ??= now + TimeSpan.FromSeconds(15);
            }
            else if (!stop.IsCancellationRequested && now - lastStopCheck >= StopCheckInterval)
            {
                lastStopCheck = now;
                if (await TryAsync(() => database.IsStopRequestedAsync(runId, CancellationToken.None), "stop-check").ConfigureAwait(false))
                {
                    stopRequested = true;
                    log.Info("run.stop-requested", "A stop was requested; the run's sessions are ending.", ("runId", runId));
                    await stop.CancelAsync().ConfigureAwait(false);
                    abortAt ??= now + GracefulStopWindow;
                }
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
                log.Warn("run.watchdog", "Sessions are still running past their limit; cancelling their commands.", ("runId", runId));
                await abort.CancelAsync().ConfigureAwait(false);
                killAt = now + KillAfterCancel;
            }

            if (killAt is { } killTime && now >= killTime && giveUpAt is null)
            {
                log.Warn("run.watchdog", "Sessions didn't end after cancellation; ending this run's ContosoCare.Demo/ sessions only (pg_terminate_backend).", ("runId", runId));
                var summary = await TryAsync(() => database.KillRunSessionsAsync(runId, pastDeadlineOnly: false, plan.RequestedBy, CancellationToken.None), "kill").ConfigureAwait(false);
                if (summary is not null)
                {
                    checks.Add(new CheckRecord(
                        "watchdog-kill",
                        summary.Failed == 0 ? "Warning" : "Manual action required",
                        string.Create(CultureInfo.InvariantCulture, $"The watchdog ended {summary.Killed} session(s) of this run; {summary.Failed} could not be ended.")));
                }

                giveUpAt = now + GiveUpAfterKill;
            }

            if (giveUpAt is { } giveUp && now >= giveUp)
            {
                log.Error("run.abandoned", "Sessions still haven't ended; recording the run and leaving them to reset.", ("runId", runId));
                break;
            }
        }

        IReadOnlyList<WorkerOutcome> outcomes = work.IsCompletedSuccessfully ? await work.ConfigureAwait(false) : [];
        await FlushEventsAsync(database, runId, context.Events).ConfigureAwait(false);

        if (!cancelledByCaller && !stopRequested && time.GetUtcNow() < deadline)
        {
            stopRequested = await TryAsync(() => database.IsStopRequestedAsync(runId, CancellationToken.None), "stop-check").ConfigureAwait(false);
        }

        var errors = outcomes.Where(o => o.Error is not null).ToList();
        var status = !work.IsCompleted
            ? "TimedOut"
            : errors.Count > 0 ? "Failed"
            : cancelledByCaller || stopRequested ? "Cancelled"
            : watchdog ? "TimedOut"
            : "Completed";

        checks.Add(await VerifySessionsClosedAsync(database, runId, plan.RequestedBy).ConfigureAwait(false));
        if (replica is not null && plan.Scenario.Id == ReplicaLag.ScenarioId)
        {
            // The run's sessions on the replica, which T4's pg_stat_activity doesn't show; any left are ended there.
            checks.Add(await PgReplicaSessions.EndAsync(replica, "run-replica-sessions-closed", ReplicaSessionScope.Run(runId), kill: true, time, CancellationToken.None).ConfigureAwait(false));
        }

        var outcome = ScenarioRunner.Summarize(outcomes);
        if (errors.Count > 0)
        {
            outcome = $"{errors.Count} session(s) failed: {Redactor.Redact(errors[0].Error)} {outcome}";
        }

        if (watchdog)
        {
            outcome = "The watchdog had to end this run's sessions. " + outcome;
        }

        var sessionIds = outcomes.Where(o => o.SessionId is not null).Select(o => o.SessionId!.Value).Distinct().Order().ToList();
        await TryAsync(() => database.EndRunAsync(runId, status, outcome, ScenarioRunner.DescribeSessions(outcomes), CancellationToken.None), "end").ConfigureAwait(false);

        if (plan.AutoCleanup)
        {
            var cleanup = await TryAsync(() => database.CleanupScenarioAsync(plan.Scenario.Id, CancellationToken.None), "cleanup").ConfigureAwait(false);
            checks.Add(cleanup ?? new CheckRecord("auto-cleanup", "Warning", "Auto-cleanup couldn't run; reset empties the scratch table."));
        }
        else
        {
            checks.Add(new CheckRecord("auto-cleanup", "Not selected", "Auto-cleanup is off; reset empties the scratch table."));
        }

        var ended = time.GetUtcNow();
        var result = status switch
        {
            "Completed" or "Cancelled" => "Pass",
            "TimedOut" => "Warning",
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
            SessionIds = sessionIds,
            Workers = outcomes,
            Checks = checks,
            ExpectedSymptoms = plan.Scenario.ExpectedSymptoms,
        };
    }

    // Scenario orchestrations ----------------------------------------------------------------------------------------------

    /// <summary>healthy-baseline, cpu-pressure, and missing-index: N sessions call the step back to back, pausing by intensity.</summary>
    private async Task<IReadOnlyList<WorkerOutcome>> RunWorkersAsync(RunContext context)
    {
        var plan = context.Plan;
        var tasks = new List<Task<WorkerOutcome>>();
        for (var worker = 1; worker <= plan.Concurrency; worker++)
        {
            var index = worker;
            var turn = 0;
            tasks.Add(plan.Scenario.Id switch
            {
                "cpu-pressure" => StepLoopAsync(context, "worker", index, (c, t) => CpuStepAsync(c, context, index, plan.Parameters["variant"].Text ?? "problem", t), Pause(plan.Intensity, 2000, 0), TimeSpan.Zero),
                "missing-index" => StepLoopAsync(context, "worker", index, (c, t) => MissingIndexStepAsync(c, context, index, turn++, time.GetUtcNow(), t), Pause(plan.Intensity, 1000, 20), TimeSpan.Zero),
                _ => StepLoopAsync(context, "worker", index, (c, t) => BaselineStepAsync(c, context, index, t), Pause(plan.Intensity, 2000, 100), TimeSpan.Zero),
            });
        }

        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>io-pressure: the first session grows the scratch set (32 MB a step), then every session reads and updates it.</summary>
    private async Task<IReadOnlyList<WorkerOutcome>> RunIoAsync(RunContext context)
    {
        var plan = context.Plan;
        var scratchMb = (int)plan.Parameters["scratchMb"].Integer;
        var tasks = new List<Task<WorkerOutcome>>
        {
            StepLoopAsync(
                context,
                "grower",
                1,
                async (c, t) =>
                {
                    var metrics = await QueryRowAsync(c, "SELECT rows_added, scratch_mb FROM demo.usp_scenario_io_pressure_grow(@run_id, @scratch_mb, 32);", t, ("run_id", context.RunId), ("scratch_mb", scratchMb)).ConfigureAwait(false);
                    return metrics.TryGetValue("rows_added", out var added) && added is int rows && rows == 0 ? throw new StepLoopDoneException() : metrics;
                },
                _ => TimeSpan.Zero,
                TimeSpan.Zero),
        };
        for (var worker = 1; worker <= plan.Concurrency; worker++)
        {
            var index = worker;
            tasks.Add(StepLoopAsync(
                context,
                "worker",
                index,
                (c, t) => QueryRowAsync(c, "SELECT pages_read, pages_updated, elapsed_ms FROM demo.usp_scenario_io_pressure(@run_id, @worker, @scratch_mb);", t, ("run_id", context.RunId), ("worker", index), ("scratch_mb", scratchMb)),
                Pause(plan.Intensity, 3000, 0),
                TimeSpan.FromSeconds(2)));
        }

        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>
    /// locking-blocking: the head blocker (an idle open transaction, or one active call that waits), billing clerks that
    /// queue on its row locks, normal baseline sessions beside them, and an optional bounded deadlock pair.
    /// </summary>
    private async Task<IReadOnlyList<WorkerOutcome>> RunLockingAsync(RunContext context)
    {
        var plan = context.Plan;
        var hotRows = (int)plan.Parameters["hotRows"].Integer;
        var holdSeconds = (int)plan.Parameters["holdSeconds"].Integer;
        var pauseSeconds = (int)plan.Parameters["pauseSeconds"].Integer;
        var normalWorkers = (int)plan.Parameters["normalWorkers"].Integer;
        var deadlockRounds = plan.Parameters["deadlock"].Boolean ? (int)plan.Parameters["deadlockRounds"].Integer : 0;

        var tasks = new List<Task<WorkerOutcome>>
        {
            plan.Parameters["holder"].Text == "active-wait"
                ? RunActiveHolderAsync(context, hotRows, holdSeconds, pauseSeconds)
                : RunIdleHolderAsync(
                    context,
                    "holder",
                    1,
                    (c, t) => QueryRowAsync(c, "SELECT run_id, locked_rows FROM demo.usp_scenario_locking_acquire(@run_id, @rows);", t, ("run_id", context.RunId), ("rows", hotRows)),
                    holdSeconds,
                    pauseSeconds,
                    isolation: null),
        };

        for (var worker = 1; worker <= plan.Concurrency; worker++)
        {
            var index = worker;
            tasks.Add(StepLoopAsync(
                context,
                "contender",
                index,
                (c, t) => InRolledBackTransactionAsync(c, "SELECT updates, waited_ms FROM demo.usp_scenario_locking_contend(@run_id, @worker, @rows);", t, ("run_id", context.RunId), ("worker", index), ("rows", hotRows)),
                _ => TimeSpan.FromSeconds(1),
                TimeSpan.FromSeconds(2)));
        }

        for (var worker = 1; worker <= normalWorkers; worker++)
        {
            var index = worker;
            tasks.Add(StepLoopAsync(context, "normal", index, (c, t) => BaselineStepAsync(c, context, index, t), Pause(plan.Intensity, 2000, 100), TimeSpan.Zero));
        }

        if (deadlockRounds > 0)
        {
            tasks.AddRange(Enumerable.Range(1, 2).Select(side => RunDeadlockSideAsync(context, side, deadlockRounds)));
        }

        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>
    /// connection-surge: opens connections a few at a time until only headroom slots stay free below max_connections,
    /// then fills that headroom for a few seconds at most and tries overshoot more, which the server refuses (SQLSTATE
    /// 53300: Failed connections in Database Hub), and frees the headroom again (SurgeBurst, 2026-11-03). Holds the rest
    /// (pinging now and then), releases them all, and pauses. Repeats until the deadline. Refusals are capped per minute
    /// and per run (SurgeBounds), and a sign-in failure ends the surge, so it never repeats a failed sign-in.
    /// </summary>
    private async Task<IReadOnlyList<WorkerOutcome>> RunConnectionSurgeAsync(RunContext context, PgDemoDatabase database)
    {
        var plan = context.Plan;
        var headroom = (int)plan.Parameters["headroom"].Integer;
        var overshoot = (int)plan.Parameters["overshoot"].Integer;
        var holdSeconds = (int)plan.Parameters["holdSeconds"].Integer;
        var pauseSeconds = (int)plan.Parameters["pauseSeconds"].Integer;
        var ceiling = (int)plan.Parameters["maxConnections"].Integer;
        var rampPerSecond = Math.Max(1, plan.Concurrency);
        var ping = TimeSpan.FromMilliseconds(Pause(plan.Intensity, 15000, 1000)(0).TotalMilliseconds);

        var waves = 0;
        var peak = 0;
        var refused = 0;
        var failedOther = 0;
        long pings = 0;
        long longestBurstMs = 0;
        var bounds = new SurgeBounds(time);
        var capped = false;
        var held = new List<NpgsqlConnection>();
        try
        {
            while (!context.Stop.IsCancellationRequested && time.GetUtcNow() < context.Deadline - TimeSpan.FromSeconds(5))
            {
                // A wave starts only while one more refusal is allowed: its ramp can meet the limit too, when other sessions
                // opened connections meanwhile. Otherwise it waits for the minute, or for the run's end once its cap is used.
                if (bounds.Allowance(1) == 0)
                {
                    var next = bounds.NextAllowedAt();
                    if (!capped)
                    {
                        capped = true;
                        context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "surge-capped", null, string.Create(CultureInfo.InvariantCulture, $"{bounds.RefusedInRun} attempt(s) refused so far, the cap ({SurgeBounds.MaxRefusedPerMinute} in any minute, {SurgeBounds.MaxRefusedPerRun} a run); {(next is null ? "no more waves in this run" : "the next wave waits for the minute")}.")));
                    }

                    await WaitUntilAsync(next is { } at ? Earlier(at, context.Deadline) : context.Deadline, context).ConfigureAwait(false);
                    continue;
                }

                capped = false;
                var (max, reserved, open) = await database.GetConnectionLimitsAsync(context.Abort).ConfigureAwait(false);
                var room = Math.Max(0, max - reserved - headroom - open);
                var target = Math.Min(ceiling, room);
                // The cap stops this wave before the server's limit, so nothing can be past it.
                var limited = ceiling < room;
                waves++;
                context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "surge-started", null, string.Create(CultureInfo.InvariantCulture, $"Wave {waves}: {open} client connection(s) open, max_connections {max}, {reserved} reserved; opening {target}, leaving {headroom} free{(limited ? $"; maxConnections ({ceiling}) stops it before the limit, so nothing is past it" : $", then up to {overshoot} past the limit")}.")));

                while (held.Count < target && !context.Stop.IsCancellationRequested && time.GetUtcNow() < context.Deadline - TimeSpan.FromSeconds(5))
                {
                    var batch = Math.Min(rampPerSecond, target - held.Count);
                    for (var i = 0; i < batch; i++)
                    {
                        try
                        {
                            held.Add(await opener.OpenAsync(context.ApplicationName, context.Abort, Limits(context), retry: false).ConfigureAwait(false));
                        }
                        catch (PostgresException ex) when (ex.SqlState == TooManyConnectionsState)
                        {
                            refused++;
                            bounds.RecordRefused();
                            target = held.Count;
                            break;
                        }
                    }

                    peak = Math.Max(peak, held.Count);
                    await WaitUntilAsync(time.GetUtcNow() + TimeSpan.FromSeconds(1), context).ConfigureAwait(false);
                }

                // Past the limit: the headroom is filled for SurgeBounds.MaxBurst at most, the next attempts are refused, and
                // the headroom is free again for the hold, so reset and the other T4 lanes (whose opens retry 53300) get in.
                var allowance = limited ? 0 : bounds.Allowance(overshoot);
                if (allowance > 0 && !context.Stop.IsCancellationRequested && time.GetUtcNow() + SurgeBounds.MaxBurst < context.Deadline - TimeSpan.FromSeconds(5))
                {
                    var burst = await SurgeBurst.RunAsync(
                        token => opener.OpenAsync(context.ApplicationName, token, Limits(context), retry: false),
                        bounds,
                        allowance,
                        headroom + allowance + SurgeBurst.Slack,
                        SurgeBounds.MaxBurst,
                        time,
                        context.Abort).ConfigureAwait(false);
                    refused += burst.Refused;
                    failedOther += burst.Failed;
                    peak = Math.Max(peak, held.Count + burst.Opened);
                    longestBurstMs = Math.Max(longestBurstMs, (long)burst.HeldFor.TotalMilliseconds);
                    context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "surge-overshoot", null, string.Create(CultureInfo.InvariantCulture, $"Wave {waves}: filled {burst.Opened} free slot(s) for {burst.HeldFor.TotalSeconds:0.0} s; {burst.Refused} attempt(s) past the limit refused (too many connections); the headroom is free again.{(burst.Error is null ? string.Empty : " Stopped early: " + burst.Error)}")));
                    if (burst.SignInFailed)
                    {
                        return [new WorkerOutcome("surge", 1, null, SurgeMetrics(waves, peak, refused, failedOther, pings, longestBurstMs), "A sign-in failed during the surge, so it stopped and doesn't try again: " + burst.Error, false)];
                    }
                }

                peak = Math.Max(peak, held.Count);
                context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "surge-holding", null, string.Create(CultureInfo.InvariantCulture, $"Wave {waves}: holding {held.Count} connection(s); {refused} attempt(s) refused so far (too many connections).")));

                var holdUntil = Earlier(time.GetUtcNow() + TimeSpan.FromSeconds(holdSeconds), context.Deadline);
                var ended = false;
                while (time.GetUtcNow() < holdUntil && !context.Stop.IsCancellationRequested && !ended)
                {
                    foreach (var connection in held)
                    {
                        try
                        {
                            await QueryRowAsync(connection, "SELECT facilities FROM demo.usp_scenario_connection_surge(@run_id, 0);", context.Abort, ("run_id", context.RunId)).ConfigureAwait(false);
                            pings++;
                        }
                        catch (PostgresException ex) when (ex.SqlState == RunEndedState)
                        {
                            ended = true;
                            break;
                        }
                    }

                    if (!ended)
                    {
                        await WaitUntilAsync(Earlier(time.GetUtcNow() + ping, holdUntil), context).ConfigureAwait(false);
                    }
                }

                await ReleaseAsync(held).ConfigureAwait(false);
                context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "surge-released", null, string.Create(CultureInfo.InvariantCulture, $"Wave {waves}: every surge connection closed.")));
                var resumeAt = time.GetUtcNow() + TimeSpan.FromSeconds(pauseSeconds);
                if (ended || context.Stop.IsCancellationRequested || resumeAt >= context.Deadline - TimeSpan.FromSeconds(10))
                {
                    break;
                }

                await WaitUntilAsync(resumeAt, context).ConfigureAwait(false);
            }

            return [new WorkerOutcome("surge", 1, null, SurgeMetrics(waves, peak, refused, failedOther, pings, longestBurstMs), null, false)];
        }
        catch (Exception ex) when (IsCancellation(ex, context))
        {
            return [new WorkerOutcome("surge", 1, null, SurgeMetrics(waves, peak, refused, failedOther, pings, longestBurstMs), null, true)];
        }
        catch (Exception ex) when (ex is NpgsqlException or InvalidOperationException)
        {
            return [new WorkerOutcome("surge", 1, null, SurgeMetrics(waves, peak, refused, failedOther, pings, longestBurstMs), PgConnectionOpener.Describe(ex), false)];
        }
        finally
        {
            await ReleaseAsync(held).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// idle-in-transaction: sessions that each lock a slice of Submitted claims in a REPEATABLE READ transaction and then
    /// sit idle in it (blocking, holding back the xmin horizon) for holdSeconds, always rolling back; writers that
    /// queue behind them; and the baseline beside them.
    /// </summary>
    private async Task<IReadOnlyList<WorkerOutcome>> RunIdleInTransactionAsync(RunContext context)
    {
        var plan = context.Plan;
        var rows = (int)plan.Parameters["rowsPerSession"].Integer;
        var holdSeconds = (int)plan.Parameters["holdSeconds"].Integer;
        var pauseSeconds = (int)plan.Parameters["pauseSeconds"].Integer;
        var writers = (int)plan.Parameters["blockedWriters"].Integer;
        var normalWorkers = (int)plan.Parameters["normalWorkers"].Integer;

        var tasks = new List<Task<WorkerOutcome>>();
        for (var worker = 1; worker <= plan.Concurrency; worker++)
        {
            var index = worker;
            tasks.Add(RunIdleHolderAsync(
                context,
                "idle",
                index,
                (c, t) => QueryRowAsync(c, "SELECT locked_rows FROM demo.usp_scenario_idle_in_transaction(@run_id, @worker, @rows);", t, ("run_id", context.RunId), ("worker", index), ("rows", rows)),
                holdSeconds,
                pauseSeconds,
                IsolationLevel.RepeatableRead));
        }

        for (var writer = 1; writer <= writers; writer++)
        {
            var idleWorker = ((writer - 1) % plan.Concurrency) + 1;
            var index = writer;
            tasks.Add(StepLoopAsync(
                context,
                "writer",
                index,
                (c, t) => InRolledBackTransactionAsync(c, "SELECT updates, waited_ms FROM demo.usp_scenario_idle_writer(@run_id, @worker, @rows);", t, ("run_id", context.RunId), ("worker", idleWorker), ("rows", rows)),
                _ => TimeSpan.FromSeconds(1),
                TimeSpan.FromSeconds(3)));
        }

        for (var worker = 1; worker <= normalWorkers; worker++)
        {
            var index = worker;
            tasks.Add(StepLoopAsync(context, "normal", index, (c, t) => BaselineStepAsync(c, context, index, t), Pause(plan.Intensity, 2000, 100), TimeSpan.Zero));
        }

        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>
    /// replica-lag (ADR 0025): each cycle, a report on T4's read replica holds demo.replica_lag_marks for the cycle's hold
    /// (ReplicaLag.ReportSql). Once the replica's pg_locks shows it holding the table, the writer on T4 takes the table's
    /// ACCESS EXCLUSIVE lock in one short call, then commits a mark every markIntervalMs. Replaying that lock waits for
    /// the report, up to max_standby_streaming_delay, so the replica's lag (the time since its last replayed transaction)
    /// climbs until the report ends by itself or recovery cancels it (SQLSTATE 40001), both the expected end of a cycle.
    /// Replay then catches up; the writer goes on for ReplicaLag.RecoveryWindow, so the lag visibly drops, and the run
    /// pauses. Every session is this run's: a monitor and each cycle's report on the replica, and the writer on T4.
    /// Source: https://www.postgresql.org/docs/current/hot-standby.html#HOT-STANDBY-CONFLICT
    /// </summary>
    private async Task<IReadOnlyList<WorkerOutcome>> RunReplicaLagAsync(RunContext context)
    {
        var plan = context.Plan;
        var holdSeconds = (int)plan.Parameters["holdSeconds"].Integer;
        var pauseSeconds = (int)plan.Parameters["pauseSeconds"].Integer;
        var markInterval = TimeSpan.FromMilliseconds(plan.Parameters["markIntervalMs"].Integer);
        var totals = new ReplicaLagTotals();
        int? writerSession = null;
        NpgsqlConnection? monitor = null;
        NpgsqlConnection? writer = null;
        try
        {
            monitor = await replica!.OpenAsync(context.ApplicationName, context.Abort, Limits(context)).ConfigureAwait(false);
            var state = await QueryRowAsync(monitor, ReplicaLag.ReplicaStateSql, context.Abort).ConfigureAwait(false);
            var delayMs = state.TryGetValue("max_standby_streaming_delay_ms", out var delay) ? delay as long? : null;
            var lag = state.TryGetValue("replay_lag_seconds", out var seconds) ? seconds as decimal? : null;
            context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "replica-ready", null, string.Create(CultureInfo.InvariantCulture, $"T4's read replica {replica.Endpoint.Host} is in recovery (monitor pid {monitor.ProcessID} there): max_standby_streaming_delay {ReplicaLag.DescribeDelay(delayMs)}, replay lag {(lag is { } current ? current.ToString("0.0", CultureInfo.InvariantCulture) + " s" : "unknown")}. Each cycle holds the report up to {holdSeconds} s.")));
            if (delayMs is { } limit && limit >= 0 && limit < holdSeconds * 1000L)
            {
                context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "replica-delay-short", null, string.Create(CultureInfo.InvariantCulture, $"max_standby_streaming_delay ({ReplicaLag.DescribeDelay(limit)}) is shorter than holdSeconds ({holdSeconds} s): recovery cancels each report at that point, so the lag climbs to about that much.")));
            }

            writer = await opener.OpenAsync(context.ApplicationName, context.Abort, Limits(context)).ConfigureAwait(false);
            writerSession = writer.ProcessID;
            context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "writer-connected", writerSession, string.Create(CultureInfo.InvariantCulture, $"The writer on T4: {plan.Scenario.Procedure}, a mark every {markInterval.TotalMilliseconds:0} ms while a report holds the table, and for {ReplicaLag.RecoveryWindow.TotalSeconds:0} s after.")));
            while (!context.Stop.IsCancellationRequested)
            {
                var hold = ReplicaLag.CycleHold(holdSeconds, time.GetUtcNow(), context.Deadline);
                if (hold is null)
                {
                    break;
                }

                totals.Cycles++;
                if (await RunReplicaLagCycleAsync(context, writer, monitor, hold.Value, markInterval, delayMs, totals).ConfigureAwait(false))
                {
                    break;
                }

                var resumeAt = time.GetUtcNow() + TimeSpan.FromSeconds(pauseSeconds);
                if (context.Stop.IsCancellationRequested || ReplicaLag.CycleHold(holdSeconds, resumeAt, context.Deadline) is null)
                {
                    break;
                }

                await WaitUntilAsync(resumeAt, context).ConfigureAwait(false);
            }

            return [new WorkerOutcome("writer", 1, writerSession, totals.ToMetrics(), totals.Error, false)];
        }
        catch (Exception ex) when (IsCancellation(ex, context))
        {
            return [new WorkerOutcome("writer", 1, writerSession, totals.ToMetrics(), null, true)];
        }
        catch (Exception ex) when (ex is NpgsqlException or InvalidOperationException or IOException or ScenarioRequestException or Azure.Identity.AuthenticationFailedException)
        {
            return [new WorkerOutcome("writer", 1, writerSession, totals.ToMetrics(), PgConnectionOpener.Describe(ex), false)];
        }
        finally
        {
            if (writer is not null)
            {
                await writer.DisposeAsync().ConfigureAwait(false);
            }

            if (monitor is not null)
            {
                await monitor.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    /// <summary>One replica-lag cycle (<see cref="RunReplicaLagAsync"/>). True once the run has ended (CC001) or a report failed.</summary>
    private async Task<bool> RunReplicaLagCycleAsync(RunContext context, NpgsqlConnection writer, NpgsqlConnection monitor, TimeSpan hold, TimeSpan markInterval, long? standbyDelayMs, ReplicaLagTotals totals)
    {
        var cycle = totals.Cycles;
        var report = await replica!.OpenAsync(context.ApplicationName, context.Abort, ReplicaLag.ReportLimits(hold, context.HardDeadline - time.GetUtcNow())).ConfigureAwait(false);
        await using (report.ConfigureAwait(false))
        {
            var reportSession = report.ProcessID;
            using var reportStop = CancellationTokenSource.CreateLinkedTokenSource(context.Stop, context.Abort);
            var reportStarted = time.GetUtcNow();
            var reportTask = RunReplicaReportAsync(report, hold, reportStop.Token);
            try
            {
                // (a) The report holds the table before T4 takes its lock: replaying a lock that came first would only make
                // the report wait for a moment.
                if (!await WaitForReportHoldAsync(monitor, reportSession, reportTask, context).ConfigureAwait(false))
                {
                    await reportStop.CancelAsync().ConfigureAwait(false);
                    var missed = await reportTask.ConfigureAwait(false);
                    if (missed.Kind == ReplicaReportEndKind.Failed)
                    {
                        totals.Error = "The report on T4's read replica failed: " + missed.Detail;
                        return true;
                    }

                    if (!context.Stop.IsCancellationRequested)
                    {
                        context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "replica-report-no-lock", null, string.Create(CultureInfo.InvariantCulture, $"Cycle {cycle}: the report on the replica (pid {reportSession}) didn't hold demo.replica_lag_marks within {ReplicaLag.LockWait.TotalSeconds:0} s{(missed.Detail is null ? string.Empty : ": " + missed.Detail)}. The cycle is skipped.")));
                    }

                    return false;
                }

                // (b) T4: the lock once, a short call, then a mark every interval while the report holds the table. The
                // replica's lag is read every LagCheckInterval, and once more just before the report ends.
                DateTimeOffset? lockedAt = null;
                decimal? peakLag = null;
                var runEnded = false;
                var lastLagCheck = DateTimeOffset.MaxValue;
                var nextLagCheck = DateTimeOffset.MaxValue;
                while (!reportTask.IsCompleted && !context.Stop.IsCancellationRequested)
                {
                    var step = await ReplicaLagStepAsync(writer, context, takeLock: lockedAt is null, totals).ConfigureAwait(false);
                    if (step == ReplicaLagStep.RunEnded)
                    {
                        runEnded = true;
                        break;
                    }

                    var now = time.GetUtcNow();
                    if (step == ReplicaLagStep.Locked)
                    {
                        lockedAt = now;
                        lastLagCheck = ReplicaLag.LastLagCheck(reportStarted + hold, now, standbyDelayMs);
                        nextLagCheck = NextLagCheck(now, lastLagCheck);
                        context.Events.Enqueue(new RunEvent(now, "replica-lag-locked", writer.ProcessID, string.Create(CultureInfo.InvariantCulture, $"Cycle {cycle}: the report on the replica (pid {reportSession}) holds demo.replica_lag_marks for up to {hold.TotalSeconds:0} s, and T4 took its ACCESS EXCLUSIVE lock (mark {totals.LastMarkId}): replaying that lock waits for the report.")));
                    }
                    else if (lockedAt is not null && now >= nextLagCheck)
                    {
                        peakLag = Larger(peakLag, await ReplayLagAsync(monitor, context).ConfigureAwait(false));
                        nextLagCheck = NextLagCheck(time.GetUtcNow(), lastLagCheck);
                    }

                    await WaitUntilOrAsync(time.GetUtcNow() + markInterval, reportTask, context).ConfigureAwait(false);
                }

                // (c) The report's end: by itself after the hold, recovery cancelled it, or the run is ending (a stop
                // request, the deadline, or CC001 from the step), which cancels it now.
                if (runEnded)
                {
                    await reportStop.CancelAsync().ConfigureAwait(false);
                }

                var end = await reportTask.ConfigureAwait(false);
                totals.RecordHold(end, peakLag);
                if (lockedAt is null && end.Kind != ReplicaReportEndKind.Stopped)
                {
                    context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "replica-lag-no-lock", writer.ProcessID, string.Create(CultureInfo.InvariantCulture, $"Cycle {cycle}: T4 couldn't take its lock on demo.replica_lag_marks while the report held it ({totals.LockTimeouts} lock_timeout(s) so far), so the replica's lag didn't climb.")));
                }

                var (name, detail) = DescribeReportEnd(cycle, reportSession, end, peakLag);
                context.Events.Enqueue(new RunEvent(time.GetUtcNow(), name, null, detail));
                if (end.Kind == ReplicaReportEndKind.Failed)
                {
                    totals.Error = "The report on T4's read replica failed: " + end.Detail;
                    return true;
                }

                if (runEnded)
                {
                    return true;
                }

                // (d) Marks for the recovery window, so the lag drops to about the mark interval before the pause.
                var recoverUntil = Earlier(time.GetUtcNow() + ReplicaLag.RecoveryWindow, context.Deadline);
                var recovering = false;
                while (!context.Stop.IsCancellationRequested && time.GetUtcNow() < recoverUntil)
                {
                    if (await ReplicaLagStepAsync(writer, context, takeLock: false, totals).ConfigureAwait(false) == ReplicaLagStep.RunEnded)
                    {
                        return true;
                    }

                    recovering = true;
                    await WaitUntilAsync(Earlier(time.GetUtcNow() + markInterval, recoverUntil), context).ConfigureAwait(false);
                }

                if (recovering && !context.Stop.IsCancellationRequested)
                {
                    var after = await ReplayLagAsync(monitor, context).ConfigureAwait(false);
                    context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "replica-lag-recovered", null, string.Create(CultureInfo.InvariantCulture, $"Cycle {cycle}: after {ReplicaLag.RecoveryWindow.TotalSeconds:0} s of marks, the replica's replay lag is {(after is { } value ? value.ToString("0.0", CultureInfo.InvariantCulture) + " s" : "unknown")}.")));
                }

                return false;
            }
            finally
            {
                if (!reportTask.IsCompleted)
                {
                    await reportStop.CancelAsync().ConfigureAwait(false);
                }

                // Never throws: RunReplicaReportAsync turns every end into a ReplicaReportEnd.
                await reportTask.ConfigureAwait(false);
            }
        }
    }

    /// <summary>The cycle's report on the replica (ReplicaLag.ReportSql), and how it ended; never an exception.</summary>
    private async Task<ReplicaReportEnd> RunReplicaReportAsync(NpgsqlConnection report, TimeSpan hold, CancellationToken cancellationToken)
    {
        var started = time.GetUtcNow();
        try
        {
            await QueryRowAsync(report, ReplicaLag.ReportSql, cancellationToken, ("hold_seconds", hold.TotalSeconds)).ConfigureAwait(false);
            return new ReplicaReportEnd(ReplicaReportEndKind.Completed, time.GetUtcNow() - started, null);
        }
        catch (PostgresException ex) when (ex.SqlState == ReplicaLag.RecoveryConflictState)
        {
            return new ReplicaReportEnd(ReplicaReportEndKind.RecoveryConflict, time.GetUtcNow() - started, PgConnectionOpener.Describe(ex));
        }
        catch (Exception ex) when (cancellationToken.IsCancellationRequested && ex is OperationCanceledException or NpgsqlException or InvalidOperationException)
        {
            return new ReplicaReportEnd(ReplicaReportEndKind.Stopped, time.GetUtcNow() - started, null);
        }
        catch (PostgresException ex) when (ex.SqlState is QueryCanceledState or LockNotAvailableState)
        {
            // Its statement_timeout or lock_timeout, or a stop or reset that cancelled it from another session.
            return new ReplicaReportEnd(ReplicaReportEndKind.Cancelled, time.GetUtcNow() - started, PgConnectionOpener.Describe(ex));
        }
        catch (Exception ex) when (ex is NpgsqlException or InvalidOperationException or IOException or TimeoutException or OperationCanceledException)
        {
            return new ReplicaReportEnd(ReplicaReportEndKind.Failed, time.GetUtcNow() - started, PgConnectionOpener.Describe(ex));
        }
    }

    /// <summary>Waits until the report's session holds demo.replica_lag_marks (pg_locks on the replica), at most ReplicaLag.LockWait.</summary>
    private async Task<bool> WaitForReportHoldAsync(NpgsqlConnection monitor, int reportSession, Task reportTask, RunContext context)
    {
        var until = time.GetUtcNow() + ReplicaLag.LockWait;
        while (!reportTask.IsCompleted && !context.Stop.IsCancellationRequested)
        {
            var row = await QueryRowAsync(monitor, ReplicaLag.ReportHoldsSql, context.Abort, ("pid", reportSession)).ConfigureAwait(false);
            if (row.TryGetValue("holding", out var holding) && holding is true)
            {
                return true;
            }

            if (time.GetUtcNow() >= until)
            {
                return false;
            }

            await WaitUntilOrAsync(time.GetUtcNow() + HoldPollInterval, reportTask, context).ConfigureAwait(false);
        }

        return false;
    }

    /// <summary>One call of the step on T4: a mark, with the table's lock first when <paramref name="takeLock"/>.</summary>
    private static async Task<ReplicaLagStep> ReplicaLagStepAsync(NpgsqlConnection writer, RunContext context, bool takeLock, ReplicaLagTotals totals)
    {
        try
        {
            var metrics = await QueryRowAsync(writer, ReplicaLag.StepSql, context.Abort, ("run_id", context.RunId), ("take_lock", takeLock)).ConfigureAwait(false);
            totals.Marks += metrics.TryGetValue("marks_written", out var marks) && marks is int written ? written : 0;
            totals.LastMarkId = metrics.TryGetValue("last_mark_id", out var mark) && mark is long id ? id : totals.LastMarkId;
            if (!takeLock)
            {
                return ReplicaLagStep.Marked;
            }

            totals.Locks++;
            return ReplicaLagStep.Locked;
        }
        catch (PostgresException ex) when (ex.SqlState == RunEndedState)
        {
            return ReplicaLagStep.RunEnded;
        }
        catch (PostgresException ex) when (ex.SqlState == LockNotAvailableState && takeLock && !context.Abort.IsCancellationRequested)
        {
            // lock_timeout on T4 (the function's 5 s): the next interval tries again while the report still holds the table.
            totals.LockTimeouts++;
            return ReplicaLagStep.LockTimedOut;
        }
    }

    /// <summary>The replica's replay lag now, in seconds; null when the monitor can't read it.</summary>
    private async Task<decimal?> ReplayLagAsync(NpgsqlConnection monitor, RunContext context)
    {
        try
        {
            var row = await QueryRowAsync(monitor, ReplicaLag.ReplicaStateSql, context.Abort).ConfigureAwait(false);
            return row.TryGetValue("replay_lag_seconds", out var lag) ? lag as decimal? : null;
        }
        catch (Exception ex) when ((ex is NpgsqlException or InvalidOperationException) && !context.Abort.IsCancellationRequested)
        {
            log.Warn("run.replica-lag-unread", "The replica's replay lag couldn't be read; the run goes on.", ("runId", context.RunId), ("error", PgConnectionOpener.Describe(ex)));
            return null;
        }
    }

    /// <summary>Waits like <see cref="WaitUntilAsync"/>, and also ends when <paramref name="other"/> completes.</summary>
    private async Task WaitUntilOrAsync(DateTimeOffset until, Task other, RunContext context)
    {
        var wait = until - time.GetUtcNow();
        if (wait <= TimeSpan.Zero || other.IsCompleted)
        {
            return;
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(context.Stop, context.Abort);
        var delay = Task.Delay(wait, time, linked.Token);
        await Task.WhenAny(delay, other).ConfigureAwait(false);
        await linked.CancelAsync().ConfigureAwait(false);
        try
        {
            await delay.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // The other task ended first, or a stop request ended the wait; the caller checks both.
        }

        context.Abort.ThrowIfCancellationRequested();
    }

    /// <summary>A cycle's end as a run event: its name and detail.</summary>
    private static (string Name, string Detail) DescribeReportEnd(int cycle, int reportSession, ReplicaReportEnd end, decimal? peakLag)
    {
        var held = end.Elapsed.TotalSeconds;
        var lag = peakLag is { } value ? string.Create(CultureInfo.InvariantCulture, $"; replay lag reached {value:0.0} s or more") : string.Empty;
        return end.Kind switch
        {
            ReplicaReportEndKind.Completed => ("replica-report-ended", string.Create(CultureInfo.InvariantCulture, $"Cycle {cycle}: the report on the replica (pid {reportSession}) ended by itself after {held:0.0} s{lag}, and replay resumed.")),
            ReplicaReportEndKind.RecoveryConflict => ("replica-report-recovery-cancel", string.Create(CultureInfo.InvariantCulture, $"Cycle {cycle}: recovery cancelled the report (pid {reportSession}) after {held:0.0} s, at max_standby_streaming_delay (SQLSTATE 40001, conflict with recovery){lag}, and replay resumed.")),
            ReplicaReportEndKind.Stopped => ("replica-report-stopped", string.Create(CultureInfo.InvariantCulture, $"Cycle {cycle}: the report (pid {reportSession}) was cancelled after {held:0.0} s, because the run is ending{lag}.")),
            ReplicaReportEndKind.Cancelled => ("replica-report-cancelled", string.Create(CultureInfo.InvariantCulture, $"Cycle {cycle}: the report (pid {reportSession}) ended after {held:0.0} s: {end.Detail}{lag}.")),
            _ => ("replica-report-failed", string.Create(CultureInfo.InvariantCulture, $"Cycle {cycle}: the report (pid {reportSession}) failed after {held:0.0} s: {end.Detail}")),
        };
    }

    private static decimal? Larger(decimal? a, decimal? b) => a is null ? b : b is null ? a : Math.Max(a.Value, b.Value);

    /// <summary>The next read of the replica's lag: LagCheckInterval from now, or <paramref name="last"/>, just before the report's planned end, when that comes first.</summary>
    private static DateTimeOffset NextLagCheck(DateTimeOffset now, DateTimeOffset last) => now < last ? Earlier(now + LagCheckInterval, last) : now + LagCheckInterval;

    // Building blocks -----------------------------------------------------------------------------------------------------

    /// <summary>
    /// A session that opens a transaction, runs one locking step, then sits idle in that transaction until holdSeconds
    /// (never past the deadline), rolls back, pauses, and repeats. Its idle_in_transaction_session_timeout ends it
    /// server-side if the runner ever stops watching.
    /// </summary>
    private async Task<WorkerOutcome> RunIdleHolderAsync(
        RunContext context,
        string role,
        int index,
        Func<NpgsqlConnection, CancellationToken, Task<IReadOnlyDictionary<string, object?>>> acquire,
        int holdSeconds,
        int pauseSeconds,
        IsolationLevel? isolation)
    {
        NpgsqlConnection? connection = null;
        int? sessionId = null;
        var cycles = 0;
        var lockedRows = 0;
        long heldMs = 0;
        try
        {
            connection = await opener.OpenAsync(context.ApplicationName, context.Abort, Limits(context)).ConfigureAwait(false);
            sessionId = connection.ProcessID;
            context.Events.Enqueue(new RunEvent(time.GetUtcNow(), role + "-connected", sessionId, string.Create(CultureInfo.InvariantCulture, $"{role} {index}: a session that sits idle in an open transaction.")));
            while (!context.Stop.IsCancellationRequested && time.GetUtcNow() < context.Deadline - TimeSpan.FromSeconds(5))
            {
                await using (var begin = connection.CreateCommand())
                {
                    begin.CommandText = isolation == IsolationLevel.RepeatableRead ? "BEGIN ISOLATION LEVEL REPEATABLE READ;" : "BEGIN;";
                    await begin.ExecuteNonQueryAsync(context.Abort).ConfigureAwait(false);
                }

                try
                {
                    var metrics = await acquire(connection, context.Abort).ConfigureAwait(false);
                    lockedRows = metrics.TryGetValue("locked_rows", out var locked) && locked is int count ? count : lockedRows;
                }
                catch (PostgresException ex) when (ex.SqlState == RunEndedState)
                {
                    await RollbackAsync(connection).ConfigureAwait(false);
                    break;
                }

                var acquiredAt = time.GetUtcNow();
                context.Events.Enqueue(new RunEvent(acquiredAt, role + "-acquired", sessionId, string.Create(CultureInfo.InvariantCulture, $"{lockedRows} row(s) locked; the session now sits idle in its open transaction.")));
                await WaitUntilAsync(Earlier(acquiredAt + TimeSpan.FromSeconds(holdSeconds), context.Deadline), context).ConfigureAwait(false);
                await RollbackAsync(connection).ConfigureAwait(false);
                var releasedAt = time.GetUtcNow();
                heldMs += (long)(releasedAt - acquiredAt).TotalMilliseconds;
                cycles++;
                context.Events.Enqueue(new RunEvent(releasedAt, role + "-rolled-back", sessionId, string.Create(CultureInfo.InvariantCulture, $"Rolled back after {(releasedAt - acquiredAt).TotalSeconds:0.0} s (the holder never commits).")));

                var resumeAt = releasedAt + TimeSpan.FromSeconds(pauseSeconds);
                if (context.Stop.IsCancellationRequested || resumeAt >= context.Deadline - TimeSpan.FromSeconds(5))
                {
                    break;
                }

                await WaitUntilAsync(resumeAt, context).ConfigureAwait(false);
            }

            return new WorkerOutcome(role, index, sessionId, HolderMetrics("idle-transaction", cycles, lockedRows, heldMs), null, false);
        }
        catch (Exception ex) when (IsCancellation(ex, context))
        {
            return new WorkerOutcome(role, index, sessionId, HolderMetrics("idle-transaction", cycles, lockedRows, heldMs), null, true);
        }
        catch (Exception ex) when (ex is NpgsqlException or InvalidOperationException)
        {
            return new WorkerOutcome(role, index, sessionId, HolderMetrics("idle-transaction", cycles, lockedRows, heldMs), PgConnectionOpener.Describe(ex), false);
        }
        finally
        {
            if (connection is not null)
            {
                if (connection.State == ConnectionState.Open)
                {
                    await TryAsync(() => RollbackAsync(connection), "holder-rollback").ConfigureAwait(false);
                }

                // Closing the connection ends the session; the server rolls back anything still open.
                await connection.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    /// <summary>The head blocker as one active call per cycle: demo.usp_scenario_locking_hold locks and waits; the runner rolls back.</summary>
    private async Task<WorkerOutcome> RunActiveHolderAsync(RunContext context, int hotRows, int holdSeconds, int pauseSeconds)
    {
        var cycles = 0;
        long heldMs = 0;
        var lockedRows = 0;
        int? sessionId = null;
        try
        {
            await using var connection = await opener.OpenAsync(context.ApplicationName, context.Abort, Limits(context)).ConfigureAwait(false);
            sessionId = connection.ProcessID;
            while (!context.Stop.IsCancellationRequested && time.GetUtcNow() < context.Deadline - TimeSpan.FromSeconds(5))
            {
                IReadOnlyDictionary<string, object?> metrics;
                try
                {
                    metrics = await InRolledBackTransactionAsync(connection, "SELECT run_id, locked_rows, held_ms FROM demo.usp_scenario_locking_hold(@run_id, @rows, @hold_seconds);", context.Abort, ("run_id", context.RunId), ("rows", hotRows), ("hold_seconds", holdSeconds)).ConfigureAwait(false);
                }
                catch (PostgresException ex) when (ex.SqlState == RunEndedState)
                {
                    break;
                }

                lockedRows = metrics.TryGetValue("locked_rows", out var locked) && locked is int count ? count : lockedRows;
                heldMs += metrics.TryGetValue("held_ms", out var held) && held is int ms ? ms : 0;
                cycles++;
                var resumeAt = time.GetUtcNow() + TimeSpan.FromSeconds(pauseSeconds);
                if (context.Stop.IsCancellationRequested || resumeAt >= context.Deadline - TimeSpan.FromSeconds(5))
                {
                    break;
                }

                await WaitUntilAsync(resumeAt, context).ConfigureAwait(false);
            }

            return new WorkerOutcome("holder", 1, sessionId, HolderMetrics("active-wait", cycles, lockedRows, heldMs), null, false);
        }
        catch (Exception ex) when (IsCancellation(ex, context))
        {
            return new WorkerOutcome("holder", 1, sessionId, HolderMetrics("active-wait", cycles, lockedRows, heldMs), null, true);
        }
        catch (Exception ex) when (ex is NpgsqlException or InvalidOperationException)
        {
            return new WorkerOutcome("holder", 1, sessionId, HolderMetrics("active-wait", cycles, lockedRows, heldMs), PgConnectionOpener.Describe(ex), false);
        }
    }

    /// <summary>One side of the bounded deadlock: lock one inventory row, wait two seconds, lock the other; the detector picks a victim.</summary>
    private async Task<WorkerOutcome> RunDeadlockSideAsync(RunContext context, int side, int rounds)
    {
        int? sessionId = null;
        var victims = 0;
        var completed = 0;
        try
        {
            await WaitUntilAsync(time.GetUtcNow() + TimeSpan.FromSeconds(5), context).ConfigureAwait(false);
            await using var connection = await opener.OpenAsync(context.ApplicationName, context.Abort, Limits(context)).ConfigureAwait(false);
            sessionId = connection.ProcessID;
            for (var round = 1; round <= rounds && !context.Stop.IsCancellationRequested && time.GetUtcNow() < context.Deadline - TimeSpan.FromSeconds(15); round++)
            {
                await using (var begin = connection.CreateCommand())
                {
                    begin.CommandText = "BEGIN;";
                    await begin.ExecuteNonQueryAsync(context.Abort).ConfigureAwait(false);
                }

                try
                {
                    await QueryRowAsync(connection, "SELECT locked_inventory_id FROM demo.usp_scenario_locking_deadlock(@run_id, @side, 1);", context.Abort, ("run_id", context.RunId), ("side", side)).ConfigureAwait(false);
                    await WaitUntilAsync(time.GetUtcNow() + TimeSpan.FromSeconds(2), context).ConfigureAwait(false);
                    await QueryRowAsync(connection, "SELECT locked_inventory_id FROM demo.usp_scenario_locking_deadlock(@run_id, @side, 2);", context.Abort, ("run_id", context.RunId), ("side", side)).ConfigureAwait(false);
                    completed++;
                }
                catch (PostgresException ex) when (ex.SqlState == DeadlockDetectedState)
                {
                    victims++;
                    context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "deadlock-victim", sessionId, string.Create(CultureInfo.InvariantCulture, $"Side {side}, round {round}: chosen as the deadlock victim (SQLSTATE 40P01).")));
                }
                catch (PostgresException ex) when (ex.SqlState == RunEndedState)
                {
                    await RollbackAsync(connection).ConfigureAwait(false);
                    break;
                }

                await RollbackAsync(connection).ConfigureAwait(false);
                await WaitUntilAsync(time.GetUtcNow() + TimeSpan.FromSeconds(5), context).ConfigureAwait(false);
            }

            return new WorkerOutcome("deadlock", side, sessionId, new Dictionary<string, object?>(StringComparer.Ordinal) { ["side"] = side, ["deadlock_victims"] = victims, ["rounds_completed"] = completed }, null, false);
        }
        catch (Exception ex) when (IsCancellation(ex, context))
        {
            return new WorkerOutcome("deadlock", side, sessionId, new Dictionary<string, object?>(StringComparer.Ordinal) { ["side"] = side, ["deadlock_victims"] = victims }, null, true);
        }
        catch (Exception ex) when (ex is NpgsqlException or InvalidOperationException)
        {
            return new WorkerOutcome("deadlock", side, sessionId, new Dictionary<string, object?>(StringComparer.Ordinal) { ["side"] = side }, PgConnectionOpener.Describe(ex), false);
        }
    }

    /// <summary>
    /// One session calling a step in a loop until the deadline or a stop request, pausing between calls. Counters the
    /// step returns are summed; a statement or lock timeout is counted and the loop goes on; CC001 ends the loop.
    /// </summary>
    private async Task<WorkerOutcome> StepLoopAsync(
        RunContext context,
        string role,
        int index,
        Func<NpgsqlConnection, CancellationToken, Task<IReadOnlyDictionary<string, object?>>> step,
        Func<int, TimeSpan> pause,
        TimeSpan startDelay)
    {
        int? sessionId = null;
        var totals = new SortedDictionary<string, object?>(StringComparer.Ordinal);
        long steps = 0;
        long timeouts = 0;
        try
        {
            if (startDelay > TimeSpan.Zero)
            {
                await WaitUntilAsync(time.GetUtcNow() + startDelay, context).ConfigureAwait(false);
                if (context.Stop.IsCancellationRequested)
                {
                    return new WorkerOutcome(role, index, null, new Dictionary<string, object?>(), null, true);
                }
            }

            await using var connection = await opener.OpenAsync(context.ApplicationName, context.Abort, Limits(context)).ConfigureAwait(false);
            sessionId = connection.ProcessID;
            context.Events.Enqueue(new RunEvent(time.GetUtcNow(), role + "-started", sessionId, string.Create(CultureInfo.InvariantCulture, $"{role} {index}: {context.Plan.Scenario.Procedure}")));
            while (!context.Stop.IsCancellationRequested && time.GetUtcNow() < context.Deadline)
            {
                try
                {
                    var metrics = await step(connection, context.Abort).ConfigureAwait(false);
                    steps++;
                    Accumulate(totals, metrics);
                }
                catch (StepLoopDoneException)
                {
                    break;
                }
                catch (PostgresException ex) when (ex.SqlState == RunEndedState)
                {
                    break;
                }
                catch (PostgresException ex) when (ex.SqlState is QueryCanceledState or LockNotAvailableState && !context.Abort.IsCancellationRequested)
                {
                    timeouts++;
                    await TryAsync(() => RollbackAsync(connection), "step-rollback").ConfigureAwait(false);
                }

                await WaitUntilAsync(time.GetUtcNow() + pause(index), context).ConfigureAwait(false);
            }

            context.Events.Enqueue(new RunEvent(time.GetUtcNow(), role + "-ended", sessionId, string.Create(CultureInfo.InvariantCulture, $"{role} {index} finished after {steps} step(s).")));
            return new WorkerOutcome(role, index, sessionId, Finish(totals, steps, timeouts), null, false);
        }
        catch (Exception ex) when (IsCancellation(ex, context))
        {
            return new WorkerOutcome(role, index, sessionId, Finish(totals, steps, timeouts), null, true);
        }
        catch (Exception ex) when (ex is NpgsqlException or InvalidOperationException)
        {
            return new WorkerOutcome(role, index, sessionId, Finish(totals, steps, timeouts), PgConnectionOpener.Describe(ex), false);
        }
    }

    private static Task<IReadOnlyDictionary<string, object?>> BaselineStepAsync(NpgsqlConnection connection, RunContext context, int worker, CancellationToken cancellationToken) =>
        QueryRowAsync(connection, "SELECT statements, rows_read, rows_written FROM demo.usp_scenario_healthy_baseline(@run_id, @worker, @intensity);", cancellationToken, ("run_id", context.RunId), ("worker", worker), ("intensity", context.Plan.Intensity));

    private static Task<IReadOnlyDictionary<string, object?>> CpuStepAsync(NpgsqlConnection connection, RunContext context, int worker, string variant, CancellationToken cancellationToken) =>
        QueryRowAsync(connection, "SELECT executions, pairs_compared, overlap_pairs, elapsed_ms FROM demo.usp_scenario_cpu_pressure(@run_id, @worker, @variant);", cancellationToken, ("run_id", context.RunId), ("worker", worker), ("variant", variant));

    /// <summary>
    /// missing-index on T4 (2026-11-04): the SQL Server targets' two lookups, claims aging by payer since a date and visits
    /// by reason code at a facility. The step function only checks that the run still runs (so a stop ends the loop, as
    /// in every step); the lookup goes as the runner's own top-level parameterized statement, so Query Store
    /// (pg_qs.query_capture_mode top) captures it and autonomous tuning can recommend its index. Neither payer_code nor
    /// reason_code has an index (database/postgresql/010-schema.sql). Read-only; the turn alternates the lookups and
    /// varies their values.
    /// </summary>
    private static async Task<IReadOnlyDictionary<string, object?>> MissingIndexStepAsync(NpgsqlConnection connection, RunContext context, int worker, int turn, DateTimeOffset now, CancellationToken cancellationToken)
    {
        await QueryRowAsync(connection, "SELECT checked FROM demo.usp_scenario_missing_index(@run_id);", cancellationToken, ("run_id", context.RunId)).ConfigureAwait(false);
        var (sql, parameters) = MissingIndexLookup(worker, turn, now);
        return await QueryRowAsync(connection, sql, cancellationToken, parameters).ConfigureAwait(false);
    }

    /// <summary>The lookup a missing-index turn sends on T4, and its parameters. Pure.</summary>
    internal static (string Sql, (string Name, object Value)[] Parameters) MissingIndexLookup(int worker, int turn, DateTimeOffset now)
    {
        if (turn % 2 == 0)
        {
            return (
                "SELECT count(*)::bigint AS rows_found FROM care.claims WHERE payer_code = @payer AND submitted_on >= @since;",
                [("payer", MissingIndexPayers[((turn / 2) + worker) % MissingIndexPayers.Length]), ("since", DateOnly.FromDateTime(now.UtcDateTime.AddDays(-30)))]);
        }

        return (
            "SELECT count(*)::bigint AS rows_found FROM care.appointments WHERE reason_code = @reason AND facility_id = @facility;",
            [("reason", string.Create(CultureInfo.InvariantCulture, $"R{((turn * 7) + worker) % 50:000}")), ("facility", 1 + ((turn + worker) % 20))]);
    }

    /// <summary>The payers database/postgresql/020-seed.sql gives claims.</summary>
    private static readonly string[] MissingIndexPayers = ["CONTOSO-HMO", "FABRIKAM-PPO", "NORTHWIND-MED", "SELF-PAY", "TAILSPIN-INS"];

    /// <summary>Runs a step in a transaction that's always rolled back (locking contenders, writers, the active holder).</summary>
    private static async Task<IReadOnlyDictionary<string, object?>> InRolledBackTransactionAsync(NpgsqlConnection connection, string sql, CancellationToken cancellationToken, params (string Name, object Value)[] parameters)
    {
        await using (var begin = connection.CreateCommand())
        {
            begin.CommandText = "BEGIN;";
            await begin.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
        }

        try
        {
            return await QueryRowAsync(connection, sql, cancellationToken, parameters).ConfigureAwait(false);
        }
        finally
        {
            if (connection.State == ConnectionState.Open)
            {
                await RollbackAsync(connection).ConfigureAwait(false);
            }
        }
    }

    /// <summary>Runs a step and returns its first row as named values.</summary>
    internal static async Task<IReadOnlyDictionary<string, object?>> QueryRowAsync(NpgsqlConnection connection, string sql, CancellationToken cancellationToken, params (string Name, object Value)[] parameters)
    {
        await using var command = connection.CreateCommand();
#pragma warning disable CA2100 // Every caller passes a constant; values travel as parameters.
        command.CommandText = sql;
#pragma warning restore CA2100
        command.CommandTimeout = 0;
        foreach (var (name, value) in parameters)
        {
            command.Parameters.Add(new NpgsqlParameter(name, value));
        }

        var metrics = new Dictionary<string, object?>(StringComparer.Ordinal);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false);
        if (await reader.ReadAsync(cancellationToken).ConfigureAwait(false))
        {
            for (var i = 0; i < reader.FieldCount; i++)
            {
                metrics[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
            }
        }

        return metrics;
    }

    private static async Task RollbackAsync(NpgsqlConnection connection)
    {
        await using var rollback = connection.CreateCommand();
        rollback.CommandText = "ROLLBACK;";
        rollback.CommandTimeout = 30;
        await rollback.ExecuteNonQueryAsync(CancellationToken.None).ConfigureAwait(false);
    }

    private static async Task ReleaseAsync(List<NpgsqlConnection> connections)
    {
        foreach (var connection in connections)
        {
            await connection.DisposeAsync().ConfigureAwait(false);
        }

        connections.Clear();
    }

    private PgSessionLimits Limits(RunContext context) => PgSessionLimits.ForRun(context.HardDeadline - time.GetUtcNow());

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

    private async Task FlushEventsAsync(PgDemoDatabase database, string runId, ConcurrentQueue<RunEvent> events)
    {
        while (events.TryDequeue(out var runEvent))
        {
            log.Info("run.event", runEvent.Detail ?? runEvent.Name, ("runId", runId), ("event", runEvent.Name), ("session", runEvent.SessionId), ("at", runEvent.At));
            await TryAsync(() => database.RecordEventAsync(runId, runEvent, CancellationToken.None), "event").ConfigureAwait(false);
        }
    }

    private async Task<CheckRecord> VerifySessionsClosedAsync(PgDemoDatabase database, string runId, string requestedBy)
    {
        var sessions = await TryAsync(() => database.GetDemoSessionsAsync(runId, CancellationToken.None), "verify").ConfigureAwait(false);
        if (sessions is null)
        {
            return new CheckRecord("run-sessions-closed", "Warning", "The runner closed every session of this run, but couldn't read pg_stat_activity to double-check.");
        }

        if (sessions.Count == 0)
        {
            return new CheckRecord("run-sessions-closed", "Pass", "No session of this run remains on the server, so none can hold a demo transaction open.");
        }

        var kill = await TryAsync(() => database.KillRunSessionsAsync(runId, pastDeadlineOnly: false, requestedBy, CancellationToken.None), "kill").ConfigureAwait(false);
        return new CheckRecord(
            "run-sessions-closed",
            kill is { Failed: 0 } ? "Warning" : "Manual action required",
            string.Create(CultureInfo.InvariantCulture, $"{sessions.Count} session(s) of this run were still open; the watchdog ended {kill?.Killed ?? 0}. Run reset to verify."));
    }

    /// <summary>
    /// Why demo.usp_run_begin refused a run, in the T-SQL runner's terms, so the profile host retries a refusal that
    /// passes by itself (CC002: the scenario's earlier run is still Running, or four runs are). Phase 25d, live: after
    /// a host restart, and under T1's capacity-max, T4's baseline was refused and not tried again until its next slot.
    /// </summary>
    internal static string RegistrationRefusalReason(PostgresException exception) => exception.SqlState switch
    {
        "CC002" when exception.MessageText.StartsWith("Four runs", StringComparison.Ordinal) => "run-limit",
        "CC002" => "running-run",
        _ => "sql",
    };

    /// <summary>
    /// Before a replica-lag run registers: T4's read replica answers and is in recovery. Null when it's ready; otherwise
    /// why not, with the refusal reason: connect, which the profile host tries again (bounded), or request.
    /// </summary>
    private async Task<(string Reason, string RefusalReason)?> CheckReplicaAsync(string runId, CancellationToken cancellationToken)
    {
        var host = replica!.Endpoint.Host;
        try
        {
            await using var connection = await replica.OpenAsync(SessionNames.ForControl(runId), cancellationToken, retry: false).ConfigureAwait(false);
            var state = await QueryRowAsync(connection, ReplicaLag.ReplicaStateSql, cancellationToken).ConfigureAwait(false);
            return state.TryGetValue("in_recovery", out var recovering) && recovering is true
                ? null
                : ($"{host} isn't a read replica: pg_is_in_recovery() is false there, so it may have been promoted. replica-lag needs T4's read replica, which start-demo.ps1 creates.", "request");
        }
        catch (ScenarioRequestException ex)
        {
            return (ex.Message, "request");
        }
        catch (Exception ex) when (PgReplicaSessions.IsConnectFailure(ex) && !cancellationToken.IsCancellationRequested)
        {
            return PgReplicaSessions.IsHostNotFound(ex)
                ? ($"T4's read replica {host} isn't there: its name doesn't resolve. It exists only during a session that start-demo.ps1 started with it.", "connect")
                : ($"Can't connect to T4's read replica {host}: {PgConnectionOpener.Describe(ex)}", "connect");
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
        catch (Exception ex) when (ex is NpgsqlException or InvalidOperationException or IOException)
        {
            log.Warn("run.control-error", "A bookkeeping call failed; the run continues within its bounds.", ("operation", what), ("error", PgConnectionOpener.Describe(ex)));
            return default;
        }
    }

    private async Task TryAsync(Func<Task> action, string what)
    {
        await TryAsync(async () =>
        {
            await action().ConfigureAwait(false);
            return true;
        }, what).ConfigureAwait(false);
    }

    private static bool IsCancellation(Exception exception, RunContext context) =>
        (context.Abort.IsCancellationRequested || context.Stop.IsCancellationRequested)
        && exception is OperationCanceledException or NpgsqlException or InvalidOperationException;

    /// <summary>The pause between steps: <paramref name="slowMs"/> at intensity 1 down to <paramref name="fastMs"/> at 10 (demo.fn_pause's rule).</summary>
    internal static Func<int, TimeSpan> Pause(int intensity, int slowMs, int fastMs)
    {
        var level = Math.Clamp(intensity, 1, 10);
        var milliseconds = slowMs - ((slowMs - fastMs) * (level - 1) / 9);
        return _ => TimeSpan.FromMilliseconds(milliseconds);
    }

    internal static void Accumulate(SortedDictionary<string, object?> totals, IReadOnlyDictionary<string, object?> metrics)
    {
        foreach (var (key, value) in metrics)
        {
            if (key is "run_id")
            {
                continue;
            }

            var keepMaximum = key.StartsWith("longest_", StringComparison.Ordinal) || key is "scratch_mb" or "locked_rows" or "elapsed_ms" or "waited_ms";
            decimal number;
            switch (value)
            {
                case int i:
                    number = i;
                    break;
                case long l:
                    number = l;
                    break;
                case short s:
                    number = s;
                    break;
                case decimal d:
                    number = d;
                    break;
                default:
                    continue;
            }

            if (keepMaximum)
            {
                totals[key] = totals.TryGetValue(key, out var current) && current is decimal existing ? Math.Max(existing, number) : number;
            }
            else
            {
                totals[key] = totals.TryGetValue(key, out var current) && current is decimal existing ? existing + number : number;
            }
        }
    }

    private static Dictionary<string, object?> Finish(SortedDictionary<string, object?> totals, long steps, long timeouts)
    {
        var metrics = new Dictionary<string, object?>(totals, StringComparer.Ordinal) { ["steps"] = steps };
        if (timeouts > 0)
        {
            metrics["timeouts"] = timeouts;
        }

        return metrics;
    }

    private static Dictionary<string, object?> HolderMetrics(string mode, int cycles, int lockedRows, long heldMs) => new(StringComparer.Ordinal)
    {
        ["mode"] = mode,
        ["hold_cycles"] = cycles,
        ["locked_rows"] = lockedRows,
        ["held_ms"] = heldMs,
    };

    private static Dictionary<string, object?> SurgeMetrics(int waves, int peak, int refused, int failedOther, long pings, long longestBurstMs) => new(StringComparer.Ordinal)
    {
        ["waves"] = waves,
        ["longest_connections_held"] = peak,
        ["connections_refused"] = refused,
        ["connections_failed_other"] = failedOther,
        ["pings"] = pings,
        ["longest_burst_ms"] = longestBurstMs,
    };

    private static DateTimeOffset Earlier(DateTimeOffset a, DateTimeOffset b) => a <= b ? a : b;

    private sealed record RunContext(
        RunPlan Plan,
        string RunId,
        string ApplicationName,
        DateTimeOffset Deadline,
        DateTimeOffset HardDeadline,
        ConcurrentQueue<RunEvent> Events,
        CancellationToken Stop,
        CancellationToken Abort);

    /// <summary>Ends a step loop normally (the io-pressure grower when the scratch set is full).</summary>
    private sealed class StepLoopDoneException : Exception;

    /// <summary>How a replica-lag report ended.</summary>
    private enum ReplicaReportEndKind
    {
        /// <summary>pg_sleep finished: the report ended by itself after its hold.</summary>
        Completed,

        /// <summary>Recovery cancelled it at max_standby_streaming_delay (SQLSTATE 40001).</summary>
        RecoveryConflict,

        /// <summary>The run cancelled it: a stop request, the deadline, or the watchdog.</summary>
        Stopped,

        /// <summary>Its own statement_timeout or lock_timeout, or a stop or reset from another session (SQLSTATE 57014 or 55P03).</summary>
        Cancelled,

        /// <summary>Anything else, such as a replica that went away.</summary>
        Failed,
    }

    /// <summary>What one call of replica-lag's step on T4 came to.</summary>
    private enum ReplicaLagStep
    {
        Marked,
        Locked,
        LockTimedOut,
        RunEnded,
    }

    private sealed record ReplicaReportEnd(ReplicaReportEndKind Kind, TimeSpan Elapsed, string? Detail);

    /// <summary>replica-lag's counters, which become the writer's metrics; the longest_ ones are maxima.</summary>
    private sealed class ReplicaLagTotals
    {
        public int Cycles { get; set; }

        public int Locks { get; set; }

        public int LockTimeouts { get; set; }

        public long Marks { get; set; }

        public long LastMarkId { get; set; }

        /// <summary>Why the run failed: a report that ended for a reason other than its hold, recovery, a stop, or a timeout.</summary>
        public string? Error { get; set; }

        private long HeldMs { get; set; }

        private long LongestHoldMs { get; set; }

        private long LongestLagMs { get; set; }

        private int RecoveryCancels { get; set; }

        public void RecordHold(ReplicaReportEnd end, decimal? peakLag)
        {
            var held = (long)end.Elapsed.TotalMilliseconds;
            HeldMs += held;
            LongestHoldMs = Math.Max(LongestHoldMs, held);
            if (peakLag is { } lag)
            {
                LongestLagMs = Math.Max(LongestLagMs, (long)(lag * 1000));
            }

            if (end.Kind == ReplicaReportEndKind.RecoveryConflict)
            {
                RecoveryCancels++;
            }
        }

        public Dictionary<string, object?> ToMetrics() => new(StringComparer.Ordinal)
        {
            ["cycles"] = Cycles,
            ["locks_taken"] = Locks,
            ["lock_timeouts"] = LockTimeouts,
            ["marks_written"] = Marks,
            ["held_ms"] = HeldMs,
            ["longest_hold_ms"] = LongestHoldMs,
            ["longest_lag_ms"] = LongestLagMs,
            ["recovery_cancels"] = RecoveryCancels,
        };
    }
}
