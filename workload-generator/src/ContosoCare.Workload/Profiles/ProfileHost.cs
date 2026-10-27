using System.Globalization;
using System.Text.Json;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Runs;
using ContosoCare.Workload.Sql;

namespace ContosoCare.Workload.Profiles;

/// <summary>Where a target's desired activity profile is kept.</summary>
internal interface IProfileStore
{
    string Description { get; }

    Task<ProfileState> GetAsync(CancellationToken cancellationToken);

    Task SetAsync(string profileName, string setBy, DateTimeOffset? expiresAt, ProfileParameters? parameters, CancellationToken cancellationToken);
}

/// <summary>T1 and T2: demo.activity_profile in the local ContosoCare database.</summary>
internal sealed class SqlProfileStore(SqlConnectionOpener opener) : IProfileStore
{
    public string Description => "demo.activity_profile on " + opener.Endpoint.Describe();

    public async Task<ProfileState> GetAsync(CancellationToken cancellationToken)
    {
        await using var connection = await opener.OpenAsync(SessionNames.ForControl("profile"), cancellationToken).ConfigureAwait(false);
        return await new DemoDatabase(connection).GetProfileAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task SetAsync(string profileName, string setBy, DateTimeOffset? expiresAt, ProfileParameters? parameters, CancellationToken cancellationToken)
    {
        await using var connection = await opener.OpenAsync(SessionNames.ForControl("profile"), cancellationToken).ConfigureAwait(false);
        await new DemoDatabase(connection).SetProfileAsync(profileName, setBy, expiresAt, parameters, cancellationToken).ConfigureAwait(false);
    }
}

/// <summary>
/// T3 and T4: a JSON file on T1 (ADR 0010, ADR 0019), so polling the profile never connects to a remote database: T3's
/// serverless database can auto-pause and a stopped T4 isn't retried while the profile is off. Writes go to a
/// temporary file that replaces the old one.
/// </summary>
internal sealed class FileProfileStore(string path) : IProfileStore
{
    /// <summary>T3's profile file (the default for every command that takes --profile-file).</summary>
    public static string DefaultPath => DefaultPathFor(DemoTarget.T3);

    /// <summary>T3 keeps activity.json; T4 (Phase 24) has its own file, activity-t4.json, next to it.</summary>
    public static string DefaultPathFor(DemoTarget target) => System.IO.Path.Combine(
        OperatingSystem.IsWindows() ? Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData) : "/var/lib",
        "DbHubDemo",
        target == DemoTarget.T4 ? "activity-t4.json" : "activity.json");

    public string FilePath => path;

    public string Description => "profile file " + path;

    public async Task<ProfileState> GetAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(path))
        {
            return ProfileState.Off(DateTimeOffset.UnixEpoch);
        }

        var json = await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false);
        var content = JsonSerializer.Deserialize(json, CatalogJsonContext.Default.ProfileFileContent)
            ?? throw new InvalidOperationException($"The profile file {path} is empty.");
        return new ProfileState(content.Profile, content.SetAt, content.SetBy, content.ExpiresAt, content.Parameters);
    }

    public async Task SetAsync(string profileName, string setBy, DateTimeOffset? expiresAt, ProfileParameters? parameters, CancellationToken cancellationToken)
    {
        var directory = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var content = new ProfileFileContent { Profile = profileName, SetAt = DateTimeOffset.UtcNow, SetBy = setBy, ExpiresAt = expiresAt, Parameters = parameters };
        var temporary = path + ".tmp";
        await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(content, CatalogJsonContext.Default.ProfileFileContent), cancellationToken).ConfigureAwait(false);
        File.Move(temporary, path, overwrite: true);
    }
}

/// <summary>One target the profile host serves: how it runs and resets scenarios, and where its profile lives.</summary>
internal sealed record ProfileTarget(DemoTarget Target, IScenarioExecutor Executor, IProfileStore Store);

/// <summary>What a lane does on its target besides reading the profile: start a bounded run, reset before a profile, and recover runs an earlier host left Running. The seam for tests.</summary>
internal interface ILaneWork
{
    Task<RunResult> RunAsync(RunPlan plan, CancellationToken cancellationToken);

    Task<IReadOnlyList<CheckRecord>> ResetAsync(string requestedBy, CancellationToken cancellationToken);

    /// <summary>Ends this machine's profile runs that started before <paramref name="startedBefore"/> and have no live session; null when sessions can't be seen.</summary>
    Task<IReadOnlyList<string>?> RecoverOrphanedRunsAsync(DateTimeOffset startedBefore, CancellationToken cancellationToken);
}

/// <summary>A lane's real work: the target's scenario executor for runs and resets (SQL Server or, since Phase 24, PostgreSQL), and the recovery of runs an earlier host left Running where the executor supports it (SQL Server).</summary>
internal sealed class ExecutorLaneWork(IScenarioExecutor executor) : ILaneWork
{
    public Task<RunResult> RunAsync(RunPlan plan, CancellationToken cancellationToken) => executor.RunAsync(plan, cancellationToken);

    public Task<IReadOnlyList<CheckRecord>> ResetAsync(string requestedBy, CancellationToken cancellationToken) =>
        executor.ResetAsync(new ResetOptions(requestedBy, 30, KillSessions: true, KeepProfile: true, UndoRemediation: false, Reseed: false), cancellationToken);

    public Task<IReadOnlyList<string>?> RecoverOrphanedRunsAsync(DateTimeOffset startedBefore, CancellationToken cancellationToken) =>
        executor is IOrphanedRunRecovery recovery
            ? recovery.RecoverOrphanedProfileRunsAsync(Environment.MachineName, startedBefore, cancellationToken)
            : Task.FromResult<IReadOnlyList<string>?>(null);
}

/// <summary>The profile host's timings and bounds (Phase 25b, after Phase 25a's T1 lane stopped serving without a trace).</summary>
internal sealed record ProfileHostOptions
{
    /// <summary>How often each lane reads its profile (activity-profiles.json's pollSeconds).</summary>
    public required TimeSpan Poll { get; init; }

    /// <summary>
    /// The longest a lane waits for its profile: T1's and T2's connect retry window (45 s), one more connect timeout
    /// (30 s), and demo.usp_profile_get's 60-second command timeout, with margin. T3's profile is a file.
    /// </summary>
    public TimeSpan StoreTimeout { get; init; } = TimeSpan.FromSeconds(150);

    /// <summary>The longest a reset before a profile may take: a connect (75 s) and demo.usp_reset's command timeout (690 s), with margin.</summary>
    public TimeSpan ResetTimeout { get; init; } = TimeSpan.FromSeconds(780);

    /// <summary>How much longer than its limit a lane waits for a bounded call that ignores its cancellation, before it stops waiting.</summary>
    public TimeSpan CallGrace { get; init; } = TimeSpan.FromSeconds(5);

    /// <summary>
    /// A lane that hasn't finished a poll for this long, outside a bounded reset, is stalled, and the supervisor replaces
    /// it. It's above the longest bounded poll (<see cref="StoreTimeout"/> plus <see cref="Poll"/>).
    /// </summary>
    public TimeSpan StallLimit { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>How often the supervisor checks the lanes and writes the heartbeat file.</summary>
    public TimeSpan SupervisorInterval { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>The wait before a lane's first restart within an hour; it doubles with each further restart in that hour.</summary>
    public TimeSpan FirstRestartDelay { get; init; } = TimeSpan.FromSeconds(10);

    public TimeSpan MaximumRestartDelay { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>
    /// The wait before an activity that was refused is tried again: another run of its scenario was still Running
    /// (demo.usp_run_begin's error 50108), the database already ran four runs (50109), or the target couldn't be reached.
    /// </summary>
    public TimeSpan RefusedRetryDelay { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>How many times one activity is started at most; the activity's window bounds the retries too.</summary>
    public int MaximumStartAttempts { get; init; } = 40;

    /// <summary>How long a stopping host waits for its runs to end cleanly.</summary>
    public TimeSpan ShutdownWait { get; init; } = TimeSpan.FromSeconds(90);

    /// <summary>host-lanes.json, or null to write none.</summary>
    public string? StateFilePath { get; init; }

    public static ProfileHostOptions From(ActivityProfilesDefinition definitions, string? stateFilePath) => new()
    {
        Poll = TimeSpan.FromSeconds(definitions.PollSeconds),
        SupervisorInterval = TimeSpan.FromSeconds(Math.Clamp(definitions.PollSeconds, 5, 30)),
        StateFilePath = stateFilePath,
    };
}

/// <summary>
/// The long-running, service-style process (ADR 0010): every poll it reads each target's desired profile, starts the
/// bounded runs the schedule wants (baseline chunks, incident windows), and stops runs the profile no longer
/// wants. Every run is clamped to its scenario's maximum, the profile's expiry, and --not-after. Ctrl+C, SIGTERM,
/// or --not-after end the process after its runs stop cleanly.
/// <para>
/// Phase 25b: each target is served by a lane whose every await is bounded and which survives any failure of one
/// poll. A supervisor restarts a lane that ended or stopped finishing its polls (after a backoff), and writes
/// host-lanes.json, the heartbeat that <c>status</c> reads. A replaced lane never touches the shared state again: its
/// runs, started activities, and last profile belong to the lane, not to the generation of its loop.
/// </para>
/// </summary>
internal sealed class ProfileHost(
    ActivityProfilesDefinition definitions,
    ScenarioCatalog catalog,
    RunnerLog log,
    TimeProvider time,
    ProfileHostOptions? options = null,
    Func<ProfileTarget, ILaneWork>? workFactory = null)
{
    private readonly ProfileHostOptions options = options ?? ProfileHostOptions.From(definitions, null);
    private readonly Func<ProfileTarget, ILaneWork> workFactory = workFactory ?? (t => new ExecutorLaneWork(t.Executor));
    private int stateWriteFailures;

    public async Task RunAsync(IReadOnlyList<ProfileTarget> targets, DateTimeOffset? notAfter, CancellationToken cancellationToken)
    {
        var hostStarted = time.GetUtcNow();
        var (processId, processStarted) = CurrentProcess();
        log.Info(
            "profile.host-started",
            "Profile host started.",
            ("targets", string.Join(",", targets.Select(t => t.Target))),
            ("notAfter", notAfter),
            ("pollSeconds", definitions.PollSeconds),
            ("stallLimit", options.StallLimit),
            ("stateFile", options.StateFilePath));
        var lanes = targets.Select(t => new Lane(t, workFactory(t), hostStarted)).ToList();
        foreach (var lane in lanes)
        {
            lock (lane.Gate)
            {
                StartLoop(lane, notAfter, hostStarted, cancellationToken);
            }
        }

        var reason = "cancelled";
        while (!cancellationToken.IsCancellationRequested)
        {
            var now = time.GetUtcNow();
            if (notAfter is { } limit && now >= limit - RunLimits.ShutdownMargin)
            {
                log.Info("profile.not-after", "Stopping before --not-after (the next auto-shutdown).", ("targets", string.Join(",", targets.Select(t => t.Target))));
                reason = "not-after";
                break;
            }

            Supervise(lanes, notAfter, now, cancellationToken);
            WriteState(lanes, processId, processStarted, hostStarted, notAfter, null, null);
            try
            {
                await Task.Delay(options.SupervisorInterval, time, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        await StopLanesAsync(lanes).ConfigureAwait(false);
        WriteState(lanes, processId, processStarted, hostStarted, notAfter, time.GetUtcNow(), reason);
        log.Info("profile.host-stopped", "Profile host stopped.", ("reason", reason));
    }

    /// <summary>Restarts a lane whose loop ended, or that hasn't finished a poll within the stall limit (outside a bounded reset).</summary>
    private void Supervise(List<Lane> lanes, DateTimeOffset? notAfter, DateTimeOffset now, CancellationToken hostToken)
    {
        foreach (var lane in lanes)
        {
            if (hostToken.IsCancellationRequested)
            {
                return;
            }

            lock (lane.Gate)
            {
                if (lane.RestartDueAt is { } due)
                {
                    if (now >= due)
                    {
                        StartLoop(lane, notAfter, now, hostToken);
                    }

                    continue;
                }

                if (lane.Loop is { IsCompleted: true } loop)
                {
                    // A lane's loop only returns when its token is cancelled; anything else is a crash.
                    var error = loop.Exception?.GetBaseException();
                    var reason = error is null ? "its loop ended unexpectedly" : $"its loop failed with {error.GetType().Name}: {error.Message}";
                    log.Error("profile.lane-crashed", "A target's profile lane stopped; the supervisor restarts it.", ("target", lane.Target.Target), ("generation", lane.Generation), ("error", reason));
                    if (error is not null)
                    {
                        log.Debug("profile.lane-crashed-detail", error.ToString(), ("target", lane.Target.Target));
                    }

                    ScheduleRestart(lane, reason, now);
                    continue;
                }

                var stallAt = lane.LastPollAt + options.StallLimit;
                if (lane.BusyUntil is { } busy && busy > stallAt)
                {
                    stallAt = busy;
                }

                if (now >= stallAt)
                {
                    var reason = string.Create(CultureInfo.InvariantCulture, $"no poll finished for {(now - lane.LastPollAt).TotalSeconds:0} s; it was {lane.Operation} since {HostLaneStatus.Format(lane.OperationSince)}");
                    log.Error("profile.lane-stalled", "A target's profile lane stopped finishing its polls; the supervisor replaces it.", ("target", lane.Target.Target), ("generation", lane.Generation), ("reason", reason));
                    ScheduleRestart(lane, reason, now);
                }
            }
        }
    }

    /// <summary>Retires the lane's loop (it can't touch the lane again) and schedules a new one after a backoff. Call under the lane's lock.</summary>
    private void ScheduleRestart(Lane lane, string reason, DateTimeOffset now)
    {
        lane.ActiveGeneration = 0;
        CancelInBackground(lane.LoopCancellation);
        lane.Loop = null;
        lane.LoopCancellation = null;
        lane.Restarts++;
        lane.RecentRestarts.RemoveAll(t => now - t > TimeSpan.FromHours(1));
        lane.RecentRestarts.Add(now);
        var delay = TimeSpan.FromTicks(Math.Min(options.MaximumRestartDelay.Ticks, options.FirstRestartDelay.Ticks << Math.Min(lane.RecentRestarts.Count - 1, 16)));
        lane.RestartDueAt = now + delay;
        lane.LastRestartAt = now;
        lane.LastRestartReason = Shorten(reason);
        lane.BusyUntil = null;
        lane.SetOperation("waiting to restart", now);
        log.Warn("profile.lane-restart-scheduled", "The lane restarts after a backoff.", ("target", lane.Target.Target), ("delay", delay), ("restartsLastHour", lane.RecentRestarts.Count));
    }

    /// <summary>Starts a new generation of the lane's loop on the thread pool. Call under the lane's lock.</summary>
    private void StartLoop(Lane lane, DateTimeOffset? notAfter, DateTimeOffset now, CancellationToken hostToken)
    {
        var generation = ++lane.Generation;
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(hostToken);
        lane.ActiveGeneration = generation;
        lane.LoopCancellation = cancellation;
        lane.RestartDueAt = null;
        lane.LastPollAt = now;
        lane.BusyUntil = null;
        lane.SetOperation("starting", now);
        lane.Loop = Task.Run(() => ServeAsync(lane, generation, notAfter, hostToken, cancellation.Token), CancellationToken.None);
        if (generation > 1)
        {
            log.Info("profile.lane-restarted", "The lane is serving its target again.", ("target", lane.Target.Target), ("generation", generation), ("restarts", lane.Restarts));
        }
    }

    private async Task ServeAsync(Lane lane, int generation, DateTimeOffset? notAfter, CancellationToken hostToken, CancellationToken laneToken)
    {
        while (!laneToken.IsCancellationRequested)
        {
            try
            {
                await PollAsync(lane, generation, notAfter, hostToken, laneToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (laneToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !laneToken.IsCancellationRequested)
            {
                // A lane outlives any failure of one poll: it logs it and polls again (Phase 25b).
                if (!NoteFailure(lane, generation, "profile.poll-failed", "A poll failed; the lane carries on.", ex))
                {
                    return;
                }
            }

            lock (lane.Gate)
            {
                if (!lane.IsCurrent(generation))
                {
                    return;
                }

                var now = time.GetUtcNow();
                lane.LastPollAt = now;
                lane.BusyUntil = null;
                lane.SetOperation("waiting for the next poll", now);
            }

            try
            {
                await Task.Delay(options.Poll, time, laneToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private async Task PollAsync(Lane lane, int generation, DateTimeOffset? notAfter, CancellationToken hostToken, CancellationToken laneToken)
    {
        var target = lane.Target.Target;
        var now = time.GetUtcNow();
        lock (lane.Gate)
        {
            if (!lane.IsCurrent(generation))
            {
                return;
            }

            Reap(lane, now);
            lane.SetOperation("reading the profile", now);
        }

        ProfileState state;
        try
        {
            state = await BoundedAsync(token => lane.Target.Store.GetAsync(token), options.StoreTimeout, "Reading the profile", laneToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (!laneToken.IsCancellationRequested)
        {
            // Runs keep going as they are; nothing new starts until the profile can be read.
            NoteFailure(lane, generation, "profile.read-failed", "Couldn't read the activity profile; retrying.", ex);
            return;
        }

        now = time.GetUtcNow();
        IReadOnlyList<PlannedActivity> planned;
        try
        {
            planned = ProfileScheduler.Plan(state, target, now, definitions, catalog, notAfter);
        }
        catch (ScenarioRequestException ex)
        {
            log.Warn("profile.invalid", "The activity profile isn't valid; nothing runs.", ("target", target), ("error", ex.Message));
            planned = [];
        }

        var reset = false;
        lock (lane.Gate)
        {
            if (!lane.IsCurrent(generation))
            {
                return;
            }

            lane.Profile = state.Name;
            if (state.SetAt != lane.LastSetAt)
            {
                lane.LastSetAt = state.SetAt;
                log.Info("profile.changed", "Activity profile read.", ("target", target), ("profile", state.Name), ("setBy", state.SetBy), ("expiresAt", state.ExpiresAt));
                if (state.Parameters?.ResetBefore == true && planned.Count > 0)
                {
                    // The reset ends every demo session on the target, so this lane's runs are told to stop first.
                    reset = true;
                    foreach (var active in lane.Running.Values)
                    {
                        active.StopRequested = true;
                        CancelInBackground(active.Cancellation);
                    }

                    lane.BusyUntil = now + options.ResetTimeout + TimeSpan.FromSeconds(30);
                    lane.SetOperation("resetting before the profile", now);
                }
            }
        }

        if (reset)
        {
            await ResetBeforeProfileAsync(lane, state, laneToken).ConfigureAwait(false);
            now = time.GetUtcNow();
        }

        // Before the lane's first start, and again after a refusal for a Running run of the same scenario, end the runs that
        // an earlier host on this machine left Running (Phase 25a: 50108 right after the task restarted).
        bool recover;
        lock (lane.Gate)
        {
            if (!lane.IsCurrent(generation))
            {
                return;
            }

            recover = lane.RecoverOrphans && planned.Any(a => !lane.Started.ContainsKey(a.Key) && a.CanStart(now, definitions));
            if (recover)
            {
                lane.RecoverOrphans = false;
                lane.SetOperation("recovering runs an earlier host left Running", now);
            }
        }

        if (recover)
        {
            await RecoverOrphansAsync(lane, laneToken).ConfigureAwait(false);
            now = time.GetUtcNow();
        }

        lock (lane.Gate)
        {
            if (!lane.IsCurrent(generation))
            {
                return;
            }

            lane.BusyUntil = null;
            lane.SetOperation("starting and stopping runs", now);
            Apply(lane, state, planned, now, notAfter, hostToken);
            if (lane.ConsecutiveFailures > 0)
            {
                log.Info("profile.poll-recovered", "The lane completes its polls again.", ("target", target), ("failures", lane.ConsecutiveFailures));
                lane.ConsecutiveFailures = 0;
            }
        }
    }

    /// <summary>Stops the runs the profile no longer wants and starts the ones it wants. Call under the lane's lock.</summary>
    private void Apply(Lane lane, ProfileState state, IReadOnlyList<PlannedActivity> planned, DateTimeOffset now, DateTimeOffset? notAfter, CancellationToken hostToken)
    {
        var target = lane.Target.Target;
        var wanted = planned.Select(a => a.Key).ToHashSet(StringComparer.Ordinal);
        foreach (var (key, active) in lane.Running)
        {
            if (!wanted.Contains(key) && !active.StopRequested)
            {
                active.StopRequested = true;
                log.Info("profile.stopping-run", "The profile no longer wants this activity; stopping it.", ("target", target), ("activity", key));
                CancelInBackground(active.Cancellation);
            }
        }

        foreach (var activity in planned)
        {
            if (lane.Started.ContainsKey(activity.Key) || !activity.CanStart(now, definitions))
            {
                continue;
            }

            if (lane.Retries.TryGetValue(activity.Key, out var retry) && retry.NotBefore > now)
            {
                continue;
            }

            // demo.usp_run_begin allows one Running run per scenario (50108), and a run that's ending is still Running
            // until it's recorded, so the activity waits until that run has ended (Phase 25a, finding F1).
            if (lane.Running.Values.Any(r => string.Equals(r.ScenarioId, activity.ScenarioId, StringComparison.Ordinal)))
            {
                if (lane.Deferred.Add(activity.Key))
                {
                    log.Info("profile.start-deferred", "A run of the same scenario is still ending on this target; the activity starts once it has ended.", ("target", target), ("activity", activity.Key));
                }

                continue;
            }

            lane.Deferred.Remove(activity.Key);
            lane.Started[activity.Key] = activity.End;
            StartActivity(lane, state, activity, notAfter, hostToken);
        }

        foreach (var key in lane.Started.Where(s => s.Value < now - TimeSpan.FromDays(1)).Select(s => s.Key).ToList())
        {
            lane.Started.Remove(key);
        }

        lane.Deferred.RemoveWhere(key => !wanted.Contains(key));
        foreach (var key in lane.Retries.Keys.Where(key => !wanted.Contains(key) && !lane.Running.ContainsKey(key)).ToList())
        {
            lane.Retries.Remove(key);
        }
    }

    /// <summary>Starts one activity's run on the thread pool, so no part of it runs on the lane's poll. Call under the lane's lock.</summary>
    private void StartActivity(Lane lane, ProfileState state, PlannedActivity activity, DateTimeOffset? notAfter, CancellationToken hostToken)
    {
        var target = lane.Target.Target;
        RunPlan plan;
        try
        {
            var scenario = catalog.Get(activity.ScenarioId);
            var request = new RunRequest
            {
                ScenarioId = activity.ScenarioId,
                Target = target,
                Duration = TimeSpan.FromSeconds(Math.Floor((activity.End - time.GetUtcNow()).TotalSeconds)),
                Concurrency = activity.Concurrency,
                Intensity = activity.Intensity,
                Parameters = activity.Parameters,
                AutoCleanup = activity.AutoCleanup,
                NotAfter = notAfter,
                RequestedBy = "profile:" + state.Name,
                ProfileName = state.Name,
            };
            plan = RunBounds.Plan(scenario, request, time.GetUtcNow());
        }
        catch (ScenarioRequestException ex)
        {
            log.Warn("profile.activity-skipped", "An activity can't run within its bounds; skipped.", ("target", target), ("activity", activity.Key), ("reason", ex.Message));
            return;
        }

        // The run's token follows the host's, not the lane's: replacing a stalled lane doesn't stop its runs.
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(hostToken);
        log.Info("profile.starting-run", "Starting a scheduled activity.", ("target", target), ("activity", activity.Key), ("until", activity.End));
        var work = lane.Work;
        var task = Task.Run(() => work.RunAsync(plan, cancellation.Token), CancellationToken.None);
        lane.Running[activity.Key] = new ActiveRun(task, cancellation, activity.ScenarioId);
    }

    private async Task ResetBeforeProfileAsync(Lane lane, ProfileState state, CancellationToken laneToken)
    {
        var target = lane.Target.Target;
        try
        {
            var checks = await BoundedAsync(token => lane.Work.ResetAsync("profile:" + state.Name, token), options.ResetTimeout, "Resetting before the profile", laneToken).ConfigureAwait(false);
            log.Info("profile.reset", "Reset before the profile's first activity.", ("target", target), ("checks", string.Join(", ", checks.Select(c => c.CheckId + "=" + c.Status))));
        }
        catch (Exception ex) when (!laneToken.IsCancellationRequested)
        {
            log.Warn("profile.reset-failed", "Reset before the profile failed; continuing.", ("target", target), ("error", Describe(ex)));
        }
    }

    private async Task RecoverOrphansAsync(Lane lane, CancellationToken laneToken)
    {
        var target = lane.Target.Target;
        try
        {
            var recovered = await BoundedAsync(token => lane.Work.RecoverOrphanedRunsAsync(lane.HostStartedAt, token), options.StoreTimeout, "Recovering runs an earlier host left Running", laneToken).ConfigureAwait(false);
            if (recovered is null)
            {
                log.Debug("profile.orphans-unchecked", "The lane can't see other sessions, so it left any Running runs as they are.", ("target", target));
            }
            else if (recovered.Count > 0)
            {
                log.Info("profile.orphans-recovered", "Ended runs that an earlier profile host left Running, so their scenarios can run again.", ("target", target), ("runs", string.Join(",", recovered)));
            }
        }
        catch (Exception ex) when (!laneToken.IsCancellationRequested)
        {
            log.Warn("profile.orphans-failed", "Couldn't check for runs an earlier host left Running; carrying on.", ("target", target), ("error", Describe(ex)));
        }
    }

    /// <summary>Records the runs that ended, and schedules a bounded retry for an activity that was refused for a reason that passes. Call under the lane's lock.</summary>
    private void Reap(Lane lane, DateTimeOffset now)
    {
        var target = lane.Target.Target;
        foreach (var key in lane.Running.Where(r => r.Value.Task.IsCompleted).Select(r => r.Key).ToList())
        {
            var active = lane.Running[key];
            lane.Running.Remove(key);
            if (active.Task.IsCompletedSuccessfully)
            {
                var result = active.Task.Result;
                log.Info("profile.run-finished", "A scheduled activity finished.", ("target", target), ("activity", key), ("runId", result.RunId), ("status", result.Status));
                if (result.CanRetryRefusal && !active.StopRequested)
                {
                    ScheduleStartRetry(lane, key, result, now);
                }
                else
                {
                    lane.Retries.Remove(key);
                }
            }
            else
            {
                log.Error("profile.run-crashed", "A scheduled activity ended with an unexpected error.", ("target", target), ("activity", key), ("error", active.Task.Exception is { } failure ? Describe(failure.GetBaseException()) : "cancelled"));
            }

            active.Cancellation.Dispose();
        }
    }

    private void ScheduleStartRetry(Lane lane, string key, RunResult result, DateTimeOffset now)
    {
        var target = lane.Target.Target;
        if (!lane.Started.TryGetValue(key, out var end))
        {
            return;
        }

        var attempts = (lane.Retries.TryGetValue(key, out var previous) ? previous.Attempts : 0) + 1;
        if (attempts >= options.MaximumStartAttempts || end - now < TimeSpan.FromSeconds(definitions.MinimumRunSeconds) + options.RefusedRetryDelay)
        {
            log.Warn("profile.start-gave-up", "The activity was refused again and isn't tried any more.", ("target", target), ("activity", key), ("attempts", attempts), ("reason", result.Outcome));
            return;
        }

        lane.Started.Remove(key);
        lane.Retries[key] = new StartRetry(attempts, now + options.RefusedRetryDelay);
        if (result.RefusalReason == "running-run")
        {
            lane.RecoverOrphans = true;
        }

        if (attempts == 1 || attempts % 10 == 0)
        {
            log.Info("profile.start-retry", "The activity was refused; it's tried again after a short wait.", ("target", target), ("activity", key), ("attempt", attempts), ("reason", result.Outcome), ("retryAt", now + options.RefusedRetryDelay));
        }
    }

    /// <summary>Counts a failed poll and logs the first and every 30th in a row. Returns false when the lane's loop was replaced.</summary>
    private bool NoteFailure(Lane lane, int generation, string eventName, string message, Exception exception)
    {
        int failures;
        lock (lane.Gate)
        {
            if (!lane.IsCurrent(generation))
            {
                return false;
            }

            failures = ++lane.ConsecutiveFailures;
            lane.LastError = Shorten(Describe(exception));
            lane.LastErrorAt = time.GetUtcNow();
        }

        if (failures == 1 || failures % 30 == 0)
        {
            log.Warn(eventName, message, ("target", lane.Target.Target), ("store", lane.Target.Store.Description), ("failures", failures), ("error", Describe(exception)));
        }

        return true;
    }

    /// <summary>
    /// Awaits a call for at most <paramref name="limit"/>: its token asks it to stop at the limit, and the wait itself ends
    /// shortly after even if the call ignores that. An abandoned call's eventual failure is observed, never left unobserved.
    /// </summary>
    private async Task<T> BoundedAsync<T>(Func<CancellationToken, Task<T>> call, TimeSpan limit, string operation, CancellationToken laneToken)
    {
        var bound = CancellationTokenSource.CreateLinkedTokenSource(laneToken);
        bound.CancelAfter(limit);
        Task<T> task;
        try
        {
            task = call(bound.Token);
        }
        catch
        {
            bound.Dispose();
            throw;
        }

        try
        {
            return await task.WaitAsync(limit + options.CallGrace, time, laneToken).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is TimeoutException || (ex is OperationCanceledException && bound.IsCancellationRequested && !laneToken.IsCancellationRequested))
        {
            throw new TimeoutException(string.Create(CultureInfo.InvariantCulture, $"{operation} took longer than {limit.TotalSeconds:0} s; the lane stopped waiting for it."), ex);
        }
        finally
        {
            if (task.IsCompleted)
            {
                bound.Dispose();
            }
            else
            {
                _ = task.ContinueWith(
                    t =>
                    {
                        _ = t.Exception;
                        bound.Dispose();
                    },
                    CancellationToken.None,
                    TaskContinuationOptions.ExecuteSynchronously,
                    TaskScheduler.Default);
            }
        }
    }

    /// <summary>Stops every lane, then every run, and waits a bounded time for the runs to end cleanly.</summary>
    private async Task StopLanesAsync(List<Lane> lanes)
    {
        var runs = new List<Task>();
        var now = time.GetUtcNow();
        foreach (var lane in lanes)
        {
            lock (lane.Gate)
            {
                lane.ActiveGeneration = 0;
                lane.RestartDueAt = null;
                CancelInBackground(lane.LoopCancellation);
                lane.Stopped = true;
                lane.SetOperation("stopped", now);
                foreach (var active in lane.Running.Values)
                {
                    active.StopRequested = true;
                    CancelInBackground(active.Cancellation);
                    runs.Add(active.Task);
                }
            }
        }

        await Task.WhenAny(Task.WhenAll(runs), Task.Delay(options.ShutdownWait, time, CancellationToken.None)).ConfigureAwait(false);
        foreach (var lane in lanes)
        {
            lock (lane.Gate)
            {
                Reap(lane, time.GetUtcNow());
            }
        }
    }

    private void WriteState(List<Lane> lanes, int processId, DateTimeOffset? processStarted, DateTimeOffset hostStarted, DateTimeOffset? notAfter, DateTimeOffset? stoppedAt, string? stopReason)
    {
        if (options.StateFilePath is not { } path)
        {
            return;
        }

        var now = time.GetUtcNow();
        var records = new List<HostLaneRecord>();
        foreach (var lane in lanes)
        {
            lock (lane.Gate)
            {
                records.Add(lane.Snapshot(now));
            }
        }

        var document = new HostLanesDocument
        {
            ProcessId = processId,
            ProcessStartedAt = processStarted,
            HostStartedAt = hostStarted,
            HeartbeatAt = now,
            NotAfter = notAfter,
            PollSeconds = (int)options.Poll.TotalSeconds,
            HeartbeatSeconds = (int)Math.Ceiling(options.SupervisorInterval.TotalSeconds),
            StallLimitSeconds = (int)options.StallLimit.TotalSeconds,
            StoppedAt = stoppedAt,
            StopReason = stopReason,
            RunnerVersion = Program.GetVersion(),
            Lanes = records,
        };
        try
        {
            HostLanesFile.Write(path, document);
            stateWriteFailures = 0;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            if (stateWriteFailures++ % 30 == 0)
            {
                log.Warn("profile.state-write-failed", "Couldn't write the host's heartbeat file; status can't see the lanes.", ("path", path), ("error", ex.Message));
            }
        }
    }

    private static void CancelInBackground(CancellationTokenSource? cancellation)
    {
        if (cancellation is null)
        {
            return;
        }

        // Never on the caller's thread: a cancellation callback (SqlCommand.Cancel) can block.
        _ = Task.Run(() =>
        {
            try
            {
                cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // The run already ended and was recorded.
            }
            catch (AggregateException)
            {
                // A callback failed; the run's own bounds still end it.
            }
        });
    }

    private static (int ProcessId, DateTimeOffset? StartedAt) CurrentProcess()
    {
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        try
        {
            return (process.Id, new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero));
        }
        catch (Exception ex) when (ex is InvalidOperationException or NotSupportedException or System.ComponentModel.Win32Exception)
        {
            return (process.Id, null);
        }
    }

    private static string Describe(Exception exception) => Redactor.Redact(exception.GetType().Name + ": " + exception.Message);

    private static string Shorten(string text) => text.Length <= 300 ? text : text[..297] + "...";

    internal static string Describe(ProfileState state, DateTimeOffset now, ActivityProfilesDefinition definitions, ScenarioCatalog catalog)
    {
        var end = ProfileScheduler.EffectiveEnd(state, definitions, catalog, null);
        var active = state.Name != "off" && now < end;
        return string.Create(CultureInfo.InvariantCulture, $"{state.Name} ({(active ? "active until " + end.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture) : "inactive")}; set by {state.SetBy} at {state.SetAt.UtcDateTime:yyyy-MM-ddTHH:mm:ssZ})");
    }

    /// <summary>True when the profile wants activity now: it isn't off and hasn't ended.</summary>
    internal static bool IsActive(ProfileState state, DateTimeOffset now, ActivityProfilesDefinition definitions, ScenarioCatalog catalog)
    {
        try
        {
            return state.Name != "off" && now < ProfileScheduler.EffectiveEnd(state, definitions, catalog, null);
        }
        catch (ScenarioRequestException)
        {
            return false;
        }
    }

    private sealed class ActiveRun(Task<RunResult> task, CancellationTokenSource cancellation, string scenarioId)
    {
        public Task<RunResult> Task { get; } = task;

        public CancellationTokenSource Cancellation { get; } = cancellation;

        public string ScenarioId { get; } = scenarioId;

        public bool StopRequested { get; set; }
    }

    private sealed record StartRetry(int Attempts, DateTimeOffset NotBefore);

    /// <summary>One target's lane: the state every generation of its loop shares. Guarded by <see cref="Gate"/>.</summary>
    private sealed class Lane(ProfileTarget target, ILaneWork work, DateTimeOffset created)
    {
        public Lock Gate { get; } = new();

        public ProfileTarget Target { get; } = target;

        public ILaneWork Work { get; } = work;

        public Dictionary<string, ActiveRun> Running { get; } = new(StringComparer.Ordinal);

        public Dictionary<string, DateTimeOffset> Started { get; } = new(StringComparer.Ordinal);

        public Dictionary<string, StartRetry> Retries { get; } = new(StringComparer.Ordinal);

        public HashSet<string> Deferred { get; } = new(StringComparer.Ordinal);

        public List<DateTimeOffset> RecentRestarts { get; } = [];

        public DateTimeOffset? LastSetAt { get; set; }

        /// <summary>When the host started: runs this machine's profiles started before it belong to an earlier host.</summary>
        public DateTimeOffset HostStartedAt { get; } = created;

        /// <summary>True until the lane has looked for runs an earlier host left Running, and again after a 50108 refusal.</summary>
        public bool RecoverOrphans { get; set; } = true;

        public int Generation { get; set; }

        /// <summary>The generation whose loop may act for the lane; 0 while none may (restarting or stopped).</summary>
        public int ActiveGeneration { get; set; }

        public Task? Loop { get; set; }

        public CancellationTokenSource? LoopCancellation { get; set; }

        public DateTimeOffset LastPollAt { get; set; } = created;

        public DateTimeOffset? BusyUntil { get; set; }

        public string Operation { get; private set; } = "starting";

        public DateTimeOffset OperationSince { get; private set; } = created;

        public DateTimeOffset? RestartDueAt { get; set; }

        public int Restarts { get; set; }

        public DateTimeOffset? LastRestartAt { get; set; }

        public string? LastRestartReason { get; set; }

        public int ConsecutiveFailures { get; set; }

        public string? LastError { get; set; }

        public DateTimeOffset? LastErrorAt { get; set; }

        public string? Profile { get; set; }

        public bool Stopped { get; set; }

        public bool IsCurrent(int generation) => ActiveGeneration == generation && !Stopped;

        public void SetOperation(string operation, DateTimeOffset now)
        {
            if (Operation != operation)
            {
                Operation = operation;
                OperationSince = now;
            }
        }

        public HostLaneRecord Snapshot(DateTimeOffset now) => new()
        {
            Target = Target.Target.ToString(),
            State = Stopped ? "Stopped" : RestartDueAt is not null ? "Restarting" : BusyUntil is { } busy && busy > now ? "Busy" : "Serving",
            Generation = Generation,
            Restarts = Restarts,
            RecentRestarts = [.. RecentRestarts.Where(t => now - t <= TimeSpan.FromHours(1))],
            LastRestartAt = LastRestartAt,
            LastRestartReason = LastRestartReason,
            RestartDueAt = RestartDueAt,
            LastPollAt = LastPollAt,
            Operation = Operation,
            OperationSince = OperationSince,
            BusyUntil = BusyUntil,
            ConsecutiveFailures = ConsecutiveFailures,
            LastError = LastError,
            LastErrorAt = LastErrorAt,
            Profile = Profile,
            RunningRuns = Running.Count,
        };
    }
}
