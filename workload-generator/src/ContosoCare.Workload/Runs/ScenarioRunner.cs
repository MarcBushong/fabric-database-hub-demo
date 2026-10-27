using System.Collections.Concurrent;
using System.Data;
using System.Globalization;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Sql;
using Microsoft.Data.SqlClient;

namespace ContosoCare.Workload.Runs;

/// <summary>What one session of a run did: the counters its procedure returned, or why it stopped.</summary>
internal sealed record WorkerOutcome(string Role, int Index, int? SessionId, IReadOnlyDictionary<string, object?> Metrics, string? Error, bool Cancelled)
{
    /// <summary>True when the session was still ending when the run was recorded, so its counters are missing (Phase 25b).</summary>
    public bool Unfinished { get; init; }
}

/// <summary>
/// The sessions a run started (Phase 25b): each worker's task, and its session once it has one. A run that the watchdog
/// stops waiting for, or whose orchestration fails, still records every session that ran, instead of "No sessions ran."
/// </summary>
internal sealed class WorkerTracker
{
    private readonly Lock gate = new();
    private readonly List<(string Role, int Index, Task<WorkerOutcome> Task)> workers = [];
    private readonly Dictionary<(string Role, int Index), int> sessions = [];

    public Task<WorkerOutcome> Track(string role, int index, Task<WorkerOutcome> task)
    {
        lock (gate)
        {
            workers.Add((role, index, task));
        }

        return task;
    }

    public void NoteSession(string role, int index, int sessionId)
    {
        lock (gate)
        {
            sessions[(role, index)] = sessionId;
        }
    }

    /// <summary>Each worker's own outcome when it ended; otherwise what's known about it: its session, and why it has no counters.</summary>
    public IReadOnlyList<WorkerOutcome> Collect()
    {
        lock (gate)
        {
            var outcomes = new List<WorkerOutcome>();
            foreach (var (role, index, task) in workers)
            {
                int? session = sessions.TryGetValue((role, index), out var id) ? id : null;
                if (task.IsCompletedSuccessfully)
                {
                    outcomes.Add(task.Result);
                }
                else if (task.IsFaulted)
                {
                    var error = task.Exception!.GetBaseException();
                    outcomes.Add(new WorkerOutcome(role, index, session, new Dictionary<string, object?>(), Redactor.Redact(error.GetType().Name + ": " + error.Message), false));
                }
                else
                {
                    outcomes.Add(new WorkerOutcome(role, index, session, new Dictionary<string, object?>(), null, true) { Unfinished = true });
                }
            }

            return outcomes;
        }
    }
}

/// <summary>The result of one scenario run.</summary>
internal sealed record RunResult
{
    public required string RunId { get; init; }

    public required string ScenarioId { get; init; }

    public required DemoTarget Target { get; init; }

    /// <summary>Completed, Cancelled, TimedOut, Failed (as in demo.scenario_runs), or Refused when it never started.</summary>
    public required string Status { get; init; }

    /// <summary>The ADR 0012 status: Pass, Warning, or Fail.</summary>
    public required string Result { get; init; }

    public required string Outcome { get; init; }

    public DateTimeOffset? StartedAt { get; init; }

    public DateTimeOffset? EndedAt { get; init; }

    public DateTimeOffset? DeadlineAt { get; init; }

    public int DurationSeconds { get; init; }

    public int Concurrency { get; init; }

    public int Intensity { get; init; }

    public IReadOnlyDictionary<string, string> Parameters { get; init; } = new Dictionary<string, string>();

    public IReadOnlyList<string> Adjustments { get; init; } = [];

    public IReadOnlyList<int> SessionIds { get; init; } = [];

    public IReadOnlyList<WorkerOutcome> Workers { get; init; } = [];

    public IReadOnlyList<CheckRecord> Checks { get; init; } = [];

    public IReadOnlyList<string> ExpectedSymptoms { get; init; } = [];

    /// <summary>
    /// Why a Refused run never started: <c>connect</c>, <c>running-run</c> (demo.usp_run_begin's 50108: its scenario
    /// already has a Running run), <c>run-limit</c> (50109: four runs are Running in the database), <c>sql</c>, or <c>request</c>.
    /// </summary>
    public string? RefusalReason { get; init; }

    /// <summary>The SQL error number behind a refusal, when there was one.</summary>
    public int? SqlErrorNumber { get; init; }

    /// <summary>True for a refusal that passes by itself, so the profile host tries the activity again, bounded (Phase 25b).</summary>
    public bool CanRetryRefusal => Status == "Refused" && RefusalReason is "connect" or "running-run" or "run-limit";
}

/// <summary>Runs bounded scenarios on one target and resets it: the T-SQL runner for T1 to T3, the PostgreSQL runner for T4.</summary>
internal interface IScenarioExecutor
{
    /// <summary>A description of the target that's safe to log.</summary>
    string Description { get; }

    Task<RunResult> RunAsync(RunPlan plan, CancellationToken cancellationToken);

    Task<IReadOnlyList<CheckRecord>> ResetAsync(ResetOptions options, CancellationToken cancellationToken);
}

/// <summary>An executor that can end the profile runs an earlier host process left Running (Phase 25b): the T-SQL runner. The profile host skips the recovery for the others.</summary>
internal interface IOrphanedRunRecovery
{
    /// <summary>Ends <paramref name="machineName"/>'s profile runs that started before <paramref name="startedBefore"/> and have no live session; null when sessions can't be seen.</summary>
    Task<IReadOnlyList<string>?> RecoverOrphanedProfileRunsAsync(string machineName, DateTimeOffset startedBefore, CancellationToken cancellationToken);
}

/// <summary>
/// Runs one bounded scenario: registers it in demo.scenario_runs, opens its tagged sessions, and enforces the
/// runner's two layers of the bounds (ADR 0010). Layer 2: every command has a timeout, and the run's commands are
/// cancelled 60 seconds after the deadline. Layer 3, the watchdog: if sessions still haven't ended 15 seconds
/// later, it asks the server to KILL this run's sessions, and only those (demo.usp_kill_demo_sessions).
/// </summary>
internal sealed class ScenarioRunner(SqlConnectionOpener opener, RunnerLog log, TimeProvider time) : IScenarioExecutor, IOrphanedRunRecovery
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);
    private static readonly TimeSpan StopCheckInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan GracefulStopWindow = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan KillAfterCancel = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan GiveUpAfterKill = TimeSpan.FromSeconds(30);

    public string Description => opener.Endpoint.Describe();

    public async Task<IReadOnlyList<CheckRecord>> ResetAsync(ResetOptions options, CancellationToken cancellationToken)
    {
        await using var connection = await opener.OpenAsync(SessionNames.ForControl("reset"), cancellationToken).ConfigureAwait(false);
        return await new DemoDatabase(connection).ResetAsync(options, cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<string>?> RecoverOrphanedProfileRunsAsync(string machineName, DateTimeOffset startedBefore, CancellationToken cancellationToken)
    {
        await using var connection = await opener.OpenAsync(SessionNames.ForControl("profile-recover"), cancellationToken).ConfigureAwait(false);
        return await new DemoDatabase(connection).RecoverOrphanedProfileRunsAsync(machineName, startedBefore, cancellationToken).ConfigureAwait(false);
    }

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
            ("server", opener.Endpoint.Server),
            ("duration", plan.Duration),
            ("concurrency", plan.Concurrency),
            ("intensity", plan.Intensity),
            ("parameters", string.Join(",", parameters.Select(p => p.Key + "=" + p.Value))));
        foreach (var adjustment in plan.Adjustments)
        {
            log.Warn("run.adjusted", adjustment, ("runId", runId));
        }

        var checks = new List<CheckRecord>();
        SqlConnection control;
        try
        {
            control = await opener.OpenAsync(SessionNames.ForControl(runId), cancellationToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is SqlException or InvalidOperationException or TimeoutException or ScenarioRequestException)
        {
            return Refused(plan, runId, parameters, $"Can't connect to {plan.Target}: {ex.Message}", checks, ex is ScenarioRequestException ? "request" : "connect", (ex as SqlException)?.Number);
        }

        await using (control.ConfigureAwait(false))
        {
            var database = new DemoDatabase(control);
            RunRegistration registration;
            try
            {
                if (plan.ResetBefore)
                {
                    var reset = await database.ResetAsync(new ResetOptions(plan.RequestedBy, 30, KillSessions: true, KeepProfile: true, UndoRemediation: false, Reseed: false), cancellationToken).ConfigureAwait(false);
                    checks.AddRange(reset.Select(r => r with { CheckId = "reset-before:" + r.CheckId }));
                    log.Info("run.reset", "Reset before the run.", ("runId", runId), ("checks", string.Join(", ", reset.Select(r => r.CheckId + "=" + r.Status))));
                }

                if (plan.Scenario.FreeSpace is { } requirement && opener.Endpoint.IsLocal)
                {
                    var files = await database.GetFilePathsAsync(cancellationToken).ConfigureAwait(false);
                    checks.Add(FreeSpace.Check(plan.Scenario, plan.Parameters, requirement, files, FreeSpace.AvailableBytes));
                }

                registration = await database.BeginRunAsync(
                    runId,
                    plan.Scenario.Id,
                    plan.Target,
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
                return Refused(plan, runId, parameters, ex.Message, checks, "request", null);
            }
            catch (SqlException ex)
            {
                var reason = ex.Number switch
                {
                    50108 => "running-run",
                    50109 => "run-limit",
                    _ => "sql",
                };
                return Refused(plan, runId, parameters, $"SQL error {ex.Number}: {ex.Message}", checks, reason, ex.Number);
            }

            return await ExecuteAsync(plan, runId, applicationName, parameters, registration, database, checks, cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task<RunResult> ExecuteAsync(
        RunPlan plan,
        string runId,
        string applicationName,
        Dictionary<string, string> parameters,
        RunRegistration registration,
        DemoDatabase database,
        List<CheckRecord> checks,
        CancellationToken cancellationToken)
    {
        var started = time.GetUtcNow();
        var deadline = started + TimeSpan.FromSeconds(registration.EffectiveDurationSeconds);
        var hardDeadline = deadline + RunLimits.Grace;
        log.Info("run.started", "Run registered; sessions starting.", ("runId", runId), ("applicationName", applicationName), ("deadline", registration.DeadlineAt));

        using var stop = new CancellationTokenSource();
        using var abort = new CancellationTokenSource();
        var context = new RunContext(plan, runId, applicationName, deadline, hardDeadline, new ConcurrentQueue<RunEvent>(), new WorkerTracker(), stop.Token, abort.Token);
        var work = plan.Scenario.Orchestration switch
        {
            "locking" => RunLockingAsync(context),
            "chain" => RunChainAsync(context),
            "pairs" => RunPairsAsync(context),
            "slow-consumer" => RunSlowConsumersAsync(context),
            "capacity" => RunCapacityAsync(context),
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
                await TryAsync(() => database.StopAsync("run", runId, null, plan.RequestedBy, setProfileOff: false, CancellationToken.None), "stop").ConfigureAwait(false);
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
                log.Warn("run.watchdog", "Sessions didn't end after cancellation; asking the server to kill this run's ContosoCare.Demo/ sessions only.", ("runId", runId));
                var summary = await TryAsync(() => database.KillRunSessionsAsync(runId, pastDeadlineOnly: false, plan.RequestedBy, CancellationToken.None), "kill").ConfigureAwait(false);
                if (summary is not null)
                {
                    checks.Add(new CheckRecord(
                        "watchdog-kill",
                        summary.CanViewSessions && summary.Failed == 0 ? "Warning" : "Manual action required",
                        summary.CanViewSessions
                            ? string.Create(CultureInfo.InvariantCulture, $"The watchdog killed {summary.Killed} session(s) of this run; {summary.Failed} could not be killed.")
                            : "The watchdog couldn't see other sessions (needs VIEW SERVER STATE or VIEW DATABASE STATE); run reset as an administrator."));
                }

                giveUpAt = now + GiveUpAfterKill;
            }

            if (giveUpAt is { } giveUp && now >= giveUp)
            {
                log.Error("run.abandoned", "Sessions still haven't ended; recording the run and leaving them to reset.", ("runId", runId));
                break;
            }
        }

        // When the runner stopped waiting (the watchdog gave up) or the orchestration failed, the tracker still knows
        // every session that ran; "No sessions ran." stays for runs that opened none (Phase 25a finding).
        IReadOnlyList<WorkerOutcome> outcomes = work.IsCompletedSuccessfully ? await work.ConfigureAwait(false) : context.Workers.Collect();
        await FlushEventsAsync(database, runId, context.Events).ConfigureAwait(false);

        // Sessions often notice a stop request before the next poll does.
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

        var outcome = Summarize(outcomes);
        if (errors.Count > 0)
        {
            outcome = $"{errors.Count} session(s) failed: {Redactor.Redact(errors[0].Error)} {outcome}";
        }

        var unfinished = outcomes.Count(o => o.Unfinished);
        if (unfinished > 0)
        {
            outcome = string.Create(CultureInfo.InvariantCulture, $"{unfinished} of {outcomes.Count} session(s) were still ending when the run was recorded, so their counters are missing. {outcome}");
        }

        if (cancelledByCaller)
        {
            outcome = "Stopped by its caller (the profile host or Ctrl+C). " + outcome;
        }

        if (watchdog)
        {
            outcome = "The watchdog had to end this run's sessions. " + outcome;
        }

        var sessionIds = outcomes.Where(o => o.SessionId is not null).Select(o => o.SessionId!.Value).Distinct().Order().ToList();
        await TryAsync(() => database.EndRunAsync(runId, status, outcome, DescribeSessions(outcomes), CancellationToken.None), "end").ConfigureAwait(false);

        // After the run is recorded as ended, so the cleanup never races a Running run of the same scenario.
        if (plan.AutoCleanup)
        {
            var cleanup = await TryAsync(() => database.CleanupScenarioAsync(plan.Scenario.Id, CancellationToken.None), "cleanup").ConfigureAwait(false);
            checks.Add(cleanup ?? new CheckRecord("auto-cleanup", "Warning", "Auto-cleanup couldn't run; reset empties the scratch tables."));
        }
        else
        {
            checks.Add(new CheckRecord("auto-cleanup", "Not selected", "Auto-cleanup is off; reset empties the scratch tables."));
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

    private RunResult Refused(RunPlan plan, string runId, Dictionary<string, string> parameters, string reason, List<CheckRecord> checks, string refusalReason, int? sqlErrorNumber)
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
            SqlErrorNumber = sqlErrorNumber,
        };
    }

    private async Task<IReadOnlyList<WorkerOutcome>> RunWorkersAsync(RunContext context)
    {
        var tasks = new List<Task<WorkerOutcome>>();
        for (var worker = 1; worker <= context.Plan.Concurrency; worker++)
        {
            var parameters = new List<SqlParameter>
            {
                Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64),
                Parameter("@worker", SqlDbType.Int, worker),
                Parameter("@intensity", SqlDbType.TinyInt, (byte)context.Plan.Intensity),
            };
            parameters.AddRange(ScenarioSqlParameters(context.Plan));
            tasks.Add(RunProcedureAsync(context, "worker", worker, context.Plan.Scenario.Procedure, parameters, TimeSpan.Zero));
        }

        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>The scenario parameters that map to procedure parameters (sqlParameter in scenario.json), as SQL parameters.</summary>
    private static IEnumerable<SqlParameter> ScenarioSqlParameters(RunPlan plan)
    {
        foreach (var (name, value) in plan.Parameters)
        {
            if (plan.Scenario.Parameters[name].SqlParameter is { } sqlName)
            {
                yield return value.Type switch
                {
                    "integer" => Parameter(sqlName, SqlDbType.Int, checked((int)value.Integer)),
                    "boolean" => Parameter(sqlName, SqlDbType.Bit, value.Boolean),
                    _ => Parameter(sqlName, SqlDbType.VarChar, value.Text ?? string.Empty, 64),
                };
            }
        }
    }

    private async Task<IReadOnlyList<WorkerOutcome>> RunLockingAsync(RunContext context)
    {
        var plan = context.Plan;
        var hotRows = (int)plan.Parameters["hotRows"].Integer;
        var holdSeconds = (int)plan.Parameters["holdSeconds"].Integer;
        var pauseSeconds = (int)plan.Parameters["pauseSeconds"].Integer;
        var normalWorkers = (int)plan.Parameters["normalWorkers"].Integer;
        var deadlockRounds = plan.Parameters["deadlock"].Boolean ? (int)plan.Parameters["deadlockRounds"].Integer : 0;
        var holder = new IdleHolder(
            "SET XACT_ABORT ON; BEGIN TRANSACTION; EXEC demo.usp_scenario_locking_acquire @run_id = @run_id, @hot_rows = @hot_rows;",
            () => [Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64), Parameter("@hot_rows", SqlDbType.Int, hotRows)],
            "Head blocker session (idle open transaction).",
            lockedRows => string.Create(CultureInfo.InvariantCulture, $"{lockedRows} hot Billing work items locked; the session now sits idle with its transaction open."));

        var tasks = new List<Task<WorkerOutcome>>
        {
            plan.Parameters["holder"].Text == "active-wait"
                ? RunActiveHolderAsync(context, hotRows, holdSeconds, pauseSeconds)
                : RunIdleHolderAsync(context, holder, holdSeconds, pauseSeconds),
        };

        // The contenders start two seconds later, so they find the hot rows already locked.
        for (var worker = 1; worker <= plan.Concurrency; worker++)
        {
            tasks.Add(RunProcedureAsync(
                context,
                "contender",
                worker,
                "demo.usp_scenario_locking_contend",
                [Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64), Parameter("@worker", SqlDbType.Int, worker), Parameter("@hot_rows", SqlDbType.Int, hotRows)],
                TimeSpan.FromSeconds(2)));
        }

        for (var worker = 1; worker <= normalWorkers; worker++)
        {
            tasks.Add(RunProcedureAsync(
                context,
                "normal",
                worker,
                "demo.usp_scenario_healthy_baseline",
                [Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64), Parameter("@worker", SqlDbType.Int, worker), Parameter("@intensity", SqlDbType.TinyInt, (byte)plan.Intensity)],
                TimeSpan.Zero));
        }

        if (deadlockRounds > 0)
        {
            foreach (var side in new byte[] { 1, 2 })
            {
                tasks.Add(RunProcedureAsync(
                    context,
                    "deadlock",
                    side,
                    "demo.usp_scenario_locking_deadlock",
                    [Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64), Parameter("@side", SqlDbType.TinyInt, side), Parameter("@rounds", SqlDbType.Int, deadlockRounds)],
                    TimeSpan.FromSeconds(5)));
            }
        }

        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>
    /// A deep blocking chain (Phase 25b): the head blocker as an idle open transaction, then for each branch one link per
    /// level from 2 to depth, each starting 2 seconds after the level above so it finds its parent already holding; the
    /// optional lock escalator; and the normal workers.
    /// </summary>
    private async Task<IReadOnlyList<WorkerOutcome>> RunChainAsync(RunContext context)
    {
        var plan = context.Plan;
        var depth = (int)plan.Parameters["depth"].Integer;
        var holdSeconds = (int)plan.Parameters["holdSeconds"].Integer;
        var pauseSeconds = (int)plan.Parameters["pauseSeconds"].Integer;
        var normalWorkers = (int)plan.Parameters["normalWorkers"].Integer;
        var holder = new IdleHolder(
            "SET XACT_ABORT ON; BEGIN TRANSACTION; EXEC demo.usp_scenario_chain_acquire @run_id = @run_id;",
            () => [Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64)],
            "Head blocker of the chain (idle open transaction).",
            _ => "The chain's head row is locked; the session now sits idle with its transaction open, and the links queue behind it.");

        var tasks = new List<Task<WorkerOutcome>> { RunIdleHolderAsync(context, holder, holdSeconds, pauseSeconds) };
        foreach (var link in ChainTopology.Links(depth, plan.Concurrency))
        {
            tasks.Add(RunProcedureAsync(
                context,
                "link",
                link.Index,
                "demo.usp_scenario_chain_link",
                [Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64), Parameter("@level", SqlDbType.Int, link.Level), Parameter("@branch", SqlDbType.Int, link.Branch)],
                link.StartDelay));
        }

        if (plan.Parameters["escalation"].Boolean)
        {
            tasks.Add(RunProcedureAsync(
                context,
                "escalator",
                1,
                "demo.usp_scenario_chain_escalate",
                [
                    Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64),
                    Parameter("@rows", SqlDbType.Int, (int)plan.Parameters["escalationRows"].Integer),
                    Parameter("@hold_seconds", SqlDbType.Int, (int)plan.Parameters["escalationHoldSeconds"].Integer),
                    Parameter("@every_seconds", SqlDbType.Int, (int)plan.Parameters["escalationEverySeconds"].Integer),
                ],
                TimeSpan.Zero));
        }

        for (var worker = 1; worker <= normalWorkers; worker++)
        {
            tasks.Add(RunProcedureAsync(
                context,
                "normal",
                worker,
                "demo.usp_scenario_healthy_baseline",
                [Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64), Parameter("@worker", SqlDbType.Int, worker), Parameter("@intensity", SqlDbType.TinyInt, (byte)plan.Intensity)],
                TimeSpan.Zero));
        }

        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>Pairs of sessions (Phase 25b): for each of the concurrency pairs, side 1 and side 2 run the procedure at once.</summary>
    private async Task<IReadOnlyList<WorkerOutcome>> RunPairsAsync(RunContext context)
    {
        var tasks = new List<Task<WorkerOutcome>>();
        for (var pair = 1; pair <= context.Plan.Concurrency; pair++)
        {
            foreach (var side in new byte[] { 1, 2 })
            {
                var parameters = new List<SqlParameter>
                {
                    Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64),
                    Parameter("@pair", SqlDbType.Int, pair),
                    Parameter("@side", SqlDbType.TinyInt, side),
                    Parameter("@intensity", SqlDbType.TinyInt, (byte)context.Plan.Intensity),
                };
                parameters.AddRange(ScenarioSqlParameters(context.Plan));
                tasks.Add(RunProcedureAsync(context, "side" + side.ToString(CultureInfo.InvariantCulture), pair, context.Plan.Scenario.Procedure, parameters, TimeSpan.Zero));
            }
        }

        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>Capacity maxed (Phase 25b): concurrency CPU sessions and ioWorkers IO sessions run the procedure with their role.</summary>
    private async Task<IReadOnlyList<WorkerOutcome>> RunCapacityAsync(RunContext context)
    {
        var plan = context.Plan;
        var tasks = new List<Task<WorkerOutcome>>();
        foreach (var (role, count) in new[] { ("cpu", plan.Concurrency), ("io", (int)plan.Parameters["ioWorkers"].Integer) })
        {
            for (var worker = 1; worker <= count; worker++)
            {
                var parameters = new List<SqlParameter>
                {
                    Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64),
                    Parameter("@worker", SqlDbType.Int, worker),
                    Parameter("@intensity", SqlDbType.TinyInt, (byte)plan.Intensity),
                    Parameter("@role", SqlDbType.VarChar, role, 8),
                };
                parameters.AddRange(ScenarioSqlParameters(plan));
                tasks.Add(RunProcedureAsync(context, role, worker, plan.Scenario.Procedure, parameters, TimeSpan.Zero));
            }
        }

        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    private async Task<IReadOnlyList<WorkerOutcome>> RunSlowConsumersAsync(RunContext context)
    {
        var tasks = new List<Task<WorkerOutcome>>();
        for (var worker = 1; worker <= context.Plan.Concurrency; worker++)
        {
            tasks.Add(RunSlowConsumerAsync(context, worker));
        }

        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    /// <summary>
    /// A client that reads slowly on purpose (Phase 25b): it runs the scenario's wide query and reads
    /// <see cref="SlowConsumer.RowsPerPause"/> rows, then pauses (<see cref="SlowConsumer.PauseFor"/>), so the server waits
    /// on the network (ASYNC_NETWORK_IO). At the deadline or on a stop request it cancels the query (an attention); while
    /// the run lasts, it runs the query again.
    /// </summary>
    private Task<WorkerOutcome> RunSlowConsumerAsync(RunContext context, int worker) =>
        context.Workers.Track("consumer", worker, RunSlowConsumerCoreAsync(context, worker));

    private async Task<WorkerOutcome> RunSlowConsumerCoreAsync(RunContext context, int worker)
    {
        var plan = context.Plan;
        var rowsPerQuery = (int)plan.Parameters["rowsPerQuery"].Integer;
        var pause = SlowConsumer.PauseFor(plan.Intensity);
        int? sessionId = null;
        long rowsRead = 0;
        long longestQueryMs = 0;
        var queries = 0;
        var cancels = 0;
        Dictionary<string, object?> Metrics() => new(StringComparer.Ordinal)
        {
            ["queries"] = queries,
            ["rows_read"] = rowsRead,
            ["cancelled_queries"] = cancels,
            ["longest_query_ms"] = longestQueryMs,
        };

        try
        {
            await using var connection = await opener.OpenAsync(context.ApplicationName, context.Abort).ConfigureAwait(false);
            sessionId = connection.ServerProcessId;
            context.Workers.NoteSession("consumer", worker, connection.ServerProcessId);
            context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "consumer-started", sessionId, string.Create(CultureInfo.InvariantCulture, $"Slow consumer {worker}: {SlowConsumer.RowsPerPause} rows, then a {pause.TotalMilliseconds:0} ms pause.")));
            while (!context.Stop.IsCancellationRequested && time.GetUtcNow() < context.Deadline - TimeSpan.FromSeconds(2))
            {
                var started = time.GetUtcNow();
                var cancelled = false;
                await using (var command = connection.CreateCommand())
                {
                    command.CommandType = CommandType.StoredProcedure;
#pragma warning disable CA2100 // The procedure name comes from the embedded scenario catalog, validated against ^demo\.usp_scenario_.
                    command.CommandText = plan.Scenario.Procedure;
#pragma warning restore CA2100
                    command.CommandTimeout = CommandTimeoutSeconds(context);
                    command.Parameters.Add(Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64));
                    command.Parameters.Add(Parameter("@worker", SqlDbType.Int, worker));
                    command.Parameters.Add(Parameter("@rows", SqlDbType.Int, rowsPerQuery));
                    var reader = await command.ExecuteReaderAsync(CommandBehavior.SequentialAccess, context.Abort).ConfigureAwait(false);
                    try
                    {
                        var inBatch = 0;
                        while (await reader.ReadAsync(context.Abort).ConfigureAwait(false))
                        {
                            rowsRead++;
                            if (++inBatch < SlowConsumer.RowsPerPause)
                            {
                                continue;
                            }

                            inBatch = 0;
                            await WaitUntilAsync(time.GetUtcNow() + pause, context).ConfigureAwait(false);
                            if (context.Stop.IsCancellationRequested || time.GetUtcNow() >= context.Deadline)
                            {
                                // An attention: the server stops sending and ends the request.
                                command.Cancel();
                                cancelled = true;
                                break;
                            }
                        }
                    }
                    finally
                    {
                        try
                        {
                            await reader.DisposeAsync().ConfigureAwait(false);
                        }
                        catch (SqlException) when (cancelled)
                        {
                            // Closing a reader after an attention can report the cancellation; that's the expected end.
                        }
                    }
                }

                queries++;
                if (cancelled)
                {
                    cancels++;
                }

                longestQueryMs = Math.Max(longestQueryMs, (long)(time.GetUtcNow() - started).TotalMilliseconds);
            }

            context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "consumer-ended", sessionId, string.Create(CultureInfo.InvariantCulture, $"Slow consumer {worker} read {rowsRead} rows in {queries} queries.")));
            return new WorkerOutcome("consumer", worker, sessionId, Metrics(), null, false);
        }
        catch (Exception ex) when (IsCancellation(ex, context))
        {
            return new WorkerOutcome("consumer", worker, sessionId, Metrics(), null, true);
        }
        catch (SqlException ex)
        {
            return new WorkerOutcome("consumer", worker, sessionId, Metrics(), Describe(ex), false);
        }
        catch (InvalidOperationException ex)
        {
            return new WorkerOutcome("consumer", worker, sessionId, Metrics(), Redactor.Redact(ex.Message), false);
        }
    }

    /// <summary>
    /// The head blocker as an application that forgot to commit: it opens a transaction, runs the holder's acquire
    /// command, and then sits idle (status sleeping, one open transaction) for holdSeconds, never past the deadline. Then
    /// it rolls back, the watchdog rollback, pauses, and repeats until the deadline or a stop request.
    /// </summary>
    private Task<WorkerOutcome> RunIdleHolderAsync(RunContext context, IdleHolder holder, int holdSeconds, int pauseSeconds) =>
        context.Workers.Track("holder", 1, RunIdleHolderCoreAsync(context, holder, holdSeconds, pauseSeconds));

    private async Task<WorkerOutcome> RunIdleHolderCoreAsync(RunContext context, IdleHolder holder, int holdSeconds, int pauseSeconds)
    {
        SqlConnection? connection = null;
        int? sessionId = null;
        var cycles = 0;
        var lockedRows = 0;
        long heldMs = 0;
        try
        {
            connection = await opener.OpenAsync(context.ApplicationName, context.Abort).ConfigureAwait(false);
            sessionId = connection.ServerProcessId;
            context.Workers.NoteSession("holder", 1, connection.ServerProcessId);
            context.Events.Enqueue(new RunEvent(time.GetUtcNow(), "holder-connected", sessionId, holder.ConnectedDetail));
            while (!context.Stop.IsCancellationRequested && time.GetUtcNow() < context.Deadline - TimeSpan.FromSeconds(5))
            {
                await using (var acquire = connection.CreateCommand())
                {
                    acquire.CommandType = CommandType.Text;
#pragma warning disable CA2100 // The holder's command is a constant in this class; its values are parameters.
                    acquire.CommandText = holder.AcquireSql;
#pragma warning restore CA2100
                    acquire.CommandTimeout = CommandTimeoutSeconds(context);
                    foreach (var parameter in holder.Parameters())
                    {
                        acquire.Parameters.Add(parameter);
                    }

                    await using var reader = await acquire.ExecuteReaderAsync(context.Abort).ConfigureAwait(false);
                    if (await reader.ReadAsync(context.Abort).ConfigureAwait(false))
                    {
                        lockedRows = reader.GetInt32(1);
                    }
                }

                var acquiredAt = time.GetUtcNow();
                context.Events.Enqueue(new RunEvent(acquiredAt, "holder-acquired", sessionId, holder.AcquiredDetail(lockedRows)));
                var holdUntil = Earlier(acquiredAt + TimeSpan.FromSeconds(holdSeconds), context.Deadline);
                await WaitUntilAsync(holdUntil, context).ConfigureAwait(false);

                await RollbackAsync(connection, CancellationToken.None).ConfigureAwait(false);
                var releasedAt = time.GetUtcNow();
                heldMs += (long)(releasedAt - acquiredAt).TotalMilliseconds;
                cycles++;
                context.Events.Enqueue(new RunEvent(releasedAt, "holder-rolled-back", sessionId, string.Create(CultureInfo.InvariantCulture, $"Rolled back after {(releasedAt - acquiredAt).TotalSeconds:0.0} s (the watchdog rollback; the holder never commits).")));

                var resumeAt = releasedAt + TimeSpan.FromSeconds(pauseSeconds);
                if (context.Stop.IsCancellationRequested || resumeAt >= context.Deadline - TimeSpan.FromSeconds(5))
                {
                    break;
                }

                await WaitUntilAsync(resumeAt, context).ConfigureAwait(false);
            }

            return new WorkerOutcome("holder", 1, sessionId, HolderMetrics("idle-transaction", cycles, lockedRows, heldMs), null, false);
        }
        catch (Exception ex) when (IsCancellation(ex, context))
        {
            return new WorkerOutcome("holder", 1, sessionId, HolderMetrics("idle-transaction", cycles, lockedRows, heldMs), null, true);
        }
        catch (SqlException ex)
        {
            return new WorkerOutcome("holder", 1, sessionId, HolderMetrics("idle-transaction", cycles, lockedRows, heldMs), Describe(ex), false);
        }
        finally
        {
            if (connection is { } open)
            {
                if (open.State == ConnectionState.Open)
                {
                    await TryAsync(() => RollbackAsync(open, CancellationToken.None), "holder-rollback").ConfigureAwait(false);
                }

                // Closing the connection ends the session; the server rolls back anything still open.
                await open.DisposeAsync().ConfigureAwait(false);
            }
        }
    }

    /// <summary>The head blocker as one T-SQL call per cycle (demo.usp_scenario_locking_hold): the procedure itself holds and rolls back.</summary>
    private Task<WorkerOutcome> RunActiveHolderAsync(RunContext context, int hotRows, int holdSeconds, int pauseSeconds) =>
        context.Workers.Track("holder", 1, RunActiveHolderCoreAsync(context, hotRows, holdSeconds, pauseSeconds));

    private async Task<WorkerOutcome> RunActiveHolderCoreAsync(RunContext context, int hotRows, int holdSeconds, int pauseSeconds)
    {
        var cycles = 0;
        long heldMs = 0;
        var lockedRows = 0;
        int? sessionId = null;
        try
        {
            await using var connection = await opener.OpenAsync(context.ApplicationName, context.Abort).ConfigureAwait(false);
            sessionId = connection.ServerProcessId;
            context.Workers.NoteSession("holder", 1, connection.ServerProcessId);
            while (!context.Stop.IsCancellationRequested && time.GetUtcNow() < context.Deadline - TimeSpan.FromSeconds(5))
            {
                await using (var hold = connection.CreateCommand())
                {
                    hold.CommandType = CommandType.StoredProcedure;
                    hold.CommandText = "demo.usp_scenario_locking_hold";
                    hold.CommandTimeout = CommandTimeoutSeconds(context);
                    hold.Parameters.Add(Parameter("@run_id", SqlDbType.VarChar, context.RunId, 64));
                    hold.Parameters.Add(Parameter("@hold_seconds", SqlDbType.Int, holdSeconds));
                    hold.Parameters.Add(Parameter("@hot_rows", SqlDbType.Int, hotRows));
                    await using var reader = await hold.ExecuteReaderAsync(context.Abort).ConfigureAwait(false);
                    if (await reader.ReadAsync(context.Abort).ConfigureAwait(false))
                    {
                        lockedRows = reader.GetInt32(1);
                        heldMs += reader.GetInt32(2);
                    }
                }

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
        catch (SqlException ex)
        {
            return new WorkerOutcome("holder", 1, sessionId, HolderMetrics("active-wait", cycles, lockedRows, heldMs), Describe(ex), false);
        }
    }

    /// <summary>One session running one bounded procedure; it never throws, so one failure can't hide the others' outcomes.</summary>
    private Task<WorkerOutcome> RunProcedureAsync(RunContext context, string role, int index, string procedure, IReadOnlyList<SqlParameter> parameters, TimeSpan startDelay) =>
        context.Workers.Track(role, index, RunProcedureCoreAsync(context, role, index, procedure, parameters, startDelay));

    private async Task<WorkerOutcome> RunProcedureCoreAsync(RunContext context, string role, int index, string procedure, IReadOnlyList<SqlParameter> parameters, TimeSpan startDelay)
    {
        int? sessionId = null;
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

            await using var connection = await opener.OpenAsync(context.ApplicationName, context.Abort).ConfigureAwait(false);
            sessionId = connection.ServerProcessId;
            context.Workers.NoteSession(role, index, connection.ServerProcessId);
            context.Events.Enqueue(new RunEvent(time.GetUtcNow(), role + "-started", sessionId, string.Create(CultureInfo.InvariantCulture, $"{role} {index}: {procedure}")));
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.StoredProcedure;
#pragma warning disable CA2100 // The procedure name comes from the embedded scenario catalog, validated against ^demo\.usp_scenario_.
            command.CommandText = procedure;
#pragma warning restore CA2100
            command.CommandTimeout = CommandTimeoutSeconds(context);
            foreach (var parameter in parameters)
            {
                command.Parameters.Add(parameter);
            }

            var metrics = new Dictionary<string, object?>(StringComparer.Ordinal);
            await using (var reader = await command.ExecuteReaderAsync(context.Abort).ConfigureAwait(false))
            {
                if (await reader.ReadAsync(context.Abort).ConfigureAwait(false))
                {
                    for (var i = 0; i < reader.FieldCount; i++)
                    {
                        metrics[reader.GetName(i)] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                    }
                }
            }

            context.Events.Enqueue(new RunEvent(time.GetUtcNow(), role + "-ended", sessionId, string.Create(CultureInfo.InvariantCulture, $"{role} {index} finished.")));
            return new WorkerOutcome(role, index, sessionId, metrics, null, false);
        }
        catch (Exception ex) when (IsCancellation(ex, context))
        {
            return new WorkerOutcome(role, index, sessionId, new Dictionary<string, object?>(), null, true);
        }
        catch (SqlException ex)
        {
            return new WorkerOutcome(role, index, sessionId, new Dictionary<string, object?>(), Describe(ex), false);
        }
        catch (InvalidOperationException ex)
        {
            return new WorkerOutcome(role, index, sessionId, new Dictionary<string, object?>(), Redactor.Redact(ex.Message), false);
        }
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

    private static async Task RollbackAsync(SqlConnection connection, CancellationToken cancellationToken)
    {
        await using var rollback = connection.CreateCommand();
        rollback.CommandType = CommandType.Text;
        rollback.CommandText = "IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;";
        rollback.CommandTimeout = 30;
        await rollback.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task FlushEventsAsync(DemoDatabase database, string runId, ConcurrentQueue<RunEvent> events)
    {
        while (events.TryDequeue(out var runEvent))
        {
            log.Info("run.event", runEvent.Detail ?? runEvent.Name, ("runId", runId), ("event", runEvent.Name), ("session", runEvent.SessionId), ("at", runEvent.At));
            await TryAsync(() => database.RecordEventAsync(runId, runEvent, CancellationToken.None), "event").ConfigureAwait(false);
        }
    }

    private async Task<CheckRecord> VerifySessionsClosedAsync(DemoDatabase database, string runId, string requestedBy)
    {
        var sessions = await TryAsync(() => database.GetDemoSessionsAsync(runId, CancellationToken.None), "verify").ConfigureAwait(false);
        if (sessions is null)
        {
            return new CheckRecord("run-sessions-closed", "Pass", "The runner closed every session of this run (it can't see other sessions on the server, so it didn't double-check there).");
        }

        if (sessions.Count == 0)
        {
            return new CheckRecord("run-sessions-closed", "Pass", "No session of this run remains on the server, so none can hold a demo transaction open.");
        }

        var kill = await TryAsync(() => database.KillRunSessionsAsync(runId, pastDeadlineOnly: false, requestedBy, CancellationToken.None), "kill").ConfigureAwait(false);
        return new CheckRecord(
            "run-sessions-closed",
            kill is { Failed: 0 } ? "Warning" : "Manual action required",
            string.Create(CultureInfo.InvariantCulture, $"{sessions.Count} session(s) of this run were still open; the watchdog killed {kill?.Killed ?? 0}. Run reset to verify."));
    }

    private async Task<T?> TryAsync<T>(Func<Task<T>> action, string what)
    {
        try
        {
            return await action().ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is SqlException or InvalidOperationException or IOException)
        {
            log.Warn("run.control-error", "A bookkeeping call failed; the run continues within its bounds.", ("operation", what), ("error", ex.Message));
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

    private int CommandTimeoutSeconds(RunContext context)
    {
        var remaining = context.HardDeadline - time.GetUtcNow();
        return Math.Max(30, (int)Math.Ceiling(remaining.TotalSeconds) + 30);
    }

    private static bool IsCancellation(Exception exception, RunContext context) =>
        (context.Abort.IsCancellationRequested || context.Stop.IsCancellationRequested)
        && exception is OperationCanceledException or SqlException or InvalidOperationException;

    private static string Describe(SqlException exception) =>
        Redactor.Redact(string.Create(CultureInfo.InvariantCulture, $"SQL error {exception.Number}: {exception.Message}"));

    private static Dictionary<string, object?> HolderMetrics(string mode, int cycles, int lockedRows, long heldMs) => new(StringComparer.Ordinal)
    {
        ["mode"] = mode,
        ["hold_cycles"] = cycles,
        ["locked_rows"] = lockedRows,
        ["held_ms"] = heldMs,
    };

    private static SqlParameter Parameter(string name, SqlDbType type, object value, int size = 0)
    {
        var parameter = new SqlParameter(name, type) { Value = value };
        if (size > 0)
        {
            parameter.Size = size;
        }

        return parameter;
    }

    private static DateTimeOffset Earlier(DateTimeOffset a, DateTimeOffset b) => a <= b ? a : b;

    /// <summary>Totals per role: counters are summed, longest_ and avg_ values and sizes keep their maximum.</summary>
    internal static string Summarize(IReadOnlyList<WorkerOutcome> outcomes)
    {
        var parts = new List<string>();
        foreach (var group in outcomes.GroupBy(o => o.Role, StringComparer.Ordinal))
        {
            var values = new SortedDictionary<string, decimal>(StringComparer.Ordinal);
            foreach (var outcome in group)
            {
                foreach (var (key, value) in outcome.Metrics)
                {
                    if (key is "worker" or "session_id" or "side" or "pair" or "level" or "branch" or "stop_requested" || !TryNumber(value, out var number))
                    {
                        continue;
                    }

                    var keepMaximum = key.StartsWith("longest_", StringComparison.Ordinal) || key.StartsWith("avg_", StringComparison.Ordinal) || key is "scratch_mb" or "locked_rows";
                    values[key] = values.TryGetValue(key, out var current) ? (keepMaximum ? Math.Max(current, number) : current + number) : number;
                }
            }

            var stopped = group.Count(o => o.Cancelled && !o.Unfinished);
            var ending = group.Count(o => o.Unfinished);
            var notes = new List<string>();
            if (stopped > 0)
            {
                notes.Add(string.Create(CultureInfo.InvariantCulture, $"{stopped} stopped by the runner"));
            }

            if (ending > 0)
            {
                notes.Add(string.Create(CultureInfo.InvariantCulture, $"{ending} still ending"));
            }

            var description = string.Join(", ", values.Select(v => string.Create(CultureInfo.InvariantCulture, $"{v.Key}={v.Value:0.##}")));
            parts.Add(string.Create(CultureInfo.InvariantCulture, $"{group.Key} x{group.Count()}{(notes.Count > 0 ? " (" + string.Join(", ", notes) + ")" : string.Empty)}: {(description.Length > 0 ? description : "no counters")}"));
        }

        return parts.Count == 0 ? "No sessions ran." : string.Join("; ", parts) + ".";
    }

    internal static string DescribeSessions(IReadOnlyList<WorkerOutcome> outcomes)
    {
        var text = string.Join(";", outcomes
            .Where(o => o.SessionId is not null)
            .GroupBy(o => o.Role, StringComparer.Ordinal)
            .Select(g => g.Key + "=" + string.Join(",", g.Select(o => o.SessionId!.Value.ToString(CultureInfo.InvariantCulture)).Distinct(StringComparer.Ordinal))));
        return text.Length <= 400 ? text : text[..400];
    }

    private static bool TryNumber(object? value, out decimal number)
    {
        switch (value)
        {
            case int i:
                number = i;
                return true;
            case long l:
                number = l;
                return true;
            case short s:
                number = s;
                return true;
            case byte b:
                number = b;
                return true;
            case decimal d:
                number = d;
                return true;
            case bool flag:
                number = flag ? 1 : 0;
                return true;
            default:
                number = 0;
                return false;
        }
    }

    private sealed record RunContext(
        RunPlan Plan,
        string RunId,
        string ApplicationName,
        DateTimeOffset Deadline,
        DateTimeOffset HardDeadline,
        ConcurrentQueue<RunEvent> Events,
        WorkerTracker Workers,
        CancellationToken Stop,
        CancellationToken Abort);

    /// <summary>An idle head blocker: the command that opens its transaction and locks its rows, a parameter factory (new SqlParameter objects for each cycle), and its event texts.</summary>
    private sealed record IdleHolder(string AcquireSql, Func<IReadOnlyList<SqlParameter>> Parameters, string ConnectedDetail, Func<int, string> AcquiredDetail);
}

/// <summary>One link of a blocking chain: its level (2 to depth), branch, the index that labels its session, and when it starts.</summary>
internal readonly record struct ChainLink(int Level, int Branch, int Index, TimeSpan StartDelay);

/// <summary>The shape of a blocking chain (Phase 25b): which links run under the head blocker, and in what order they start.</summary>
internal static class ChainTopology
{
    public const int MaximumDepth = 6;

    public const int MaximumBranches = 4;

    /// <summary>Levels 2 to depth for each branch, level by level; each level starts 2 seconds after the one above it.</summary>
    public static IReadOnlyList<ChainLink> Links(int depth, int branches)
    {
        if (depth is < 3 or > MaximumDepth)
        {
            throw new ArgumentOutOfRangeException(nameof(depth), depth, "A chain is 3 to 6 sessions deep, the head blocker included.");
        }

        if (branches is < 1 or > MaximumBranches)
        {
            throw new ArgumentOutOfRangeException(nameof(branches), branches, "A chain has 1 to 4 branches.");
        }

        var links = new List<ChainLink>();
        for (var level = 2; level <= depth; level++)
        {
            for (var branch = 1; branch <= branches; branch++)
            {
                links.Add(new ChainLink(level, branch, links.Count + 1, TimeSpan.FromSeconds(2 * (level - 1))));
            }
        }

        return links;
    }
}

/// <summary>The slow client's reading pace (Phase 25b).</summary>
internal static class SlowConsumer
{
    /// <summary>Rows read between pauses.</summary>
    public const int RowsPerPause = 25;

    /// <summary>The pause after each batch of rows: 100 ms at intensity 1 up to 1 second at 10.</summary>
    public static TimeSpan PauseFor(int intensity) => TimeSpan.FromMilliseconds(100 * Math.Clamp(intensity, 1, 10));
}

/// <summary>The runner's free-space check for T1 and T2: the volumes that hold ContosoCare's files (on T2, the guest's VHDX).</summary>
internal static class FreeSpace
{
    public static CheckRecord Check(
        ScenarioDefinition scenario,
        IReadOnlyDictionary<string, ParameterValue> parameters,
        FreeSpaceRequirement requirement,
        IEnumerable<string> filePaths,
        Func<string, long?> availableBytes)
    {
        long neededMb = requirement.MarginMb;
        if (requirement.DataMbFromParameter is { } name && parameters.TryGetValue(name, out var value))
        {
            neededMb += value.Integer;
        }

        var roots = filePaths.Select(Path.GetPathRoot).Where(r => !string.IsNullOrEmpty(r)).Select(r => r!).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        foreach (var root in roots)
        {
            if (availableBytes(root) is not { } free)
            {
                continue;
            }

            var freeMb = free / (1024 * 1024);
            if (freeMb < neededMb)
            {
                throw new ScenarioRequestException(string.Create(
                    CultureInfo.InvariantCulture,
                    $"Only {freeMb} MB free on {root}; {scenario.Id} needs {neededMb} MB (its scratch data plus a {requirement.MarginMb} MB margin). On T2 this is the guest's VHDX."));
            }
        }

        return new CheckRecord("free-space", "Pass", string.Create(CultureInfo.InvariantCulture, $"At least {neededMb} MB free on {string.Join(", ", roots)}."));
    }

    public static long? AvailableBytes(string root)
    {
        try
        {
            return new DriveInfo(root).AvailableFreeSpace;
        }
        catch (Exception ex) when (ex is IOException or ArgumentException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
