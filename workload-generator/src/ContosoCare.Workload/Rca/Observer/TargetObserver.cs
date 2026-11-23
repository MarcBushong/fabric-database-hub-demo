using System.Globalization;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>The observer's timings and bounds (ADR 0031; rca/README.md, Capture triggers). Tests shorten them.</summary>
internal sealed record ObserverOptions
{
    /// <summary>The sentinel's cadence, for the whole session.</summary>
    public TimeSpan Sentinel { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>Blocking detail (RCA-SQL-01, 02; RCA-PG-01, 02, 11) and T4's connection detail (RCA-PG-10).</summary>
    public TimeSpan BlockingDetail { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>Replay detail on the replica (RCA-PG-01, 02, 06, 07, 08) and on T4 (RCA-PG-04, 05).</summary>
    public TimeSpan ReplayDetail { get; init; } = TimeSpan.FromSeconds(5);

    /// <summary>How long without a blocked process, a lock waiter, or a busy connection count before an episode ends.</summary>
    public TimeSpan QuietFor { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>How long errors stay under their threshold before an error episode ends.</summary>
    public TimeSpan ErrorQuietFor { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>RCA-AZ-01 on T3: every 30 minutes and at the session's end.</summary>
    public TimeSpan ResourceStats { get; init; } = TimeSpan.FromMinutes(30);

    /// <summary>A sample slower than this halves the cadence; three in a row stop detail capture.</summary>
    public TimeSpan SlowSample { get; init; } = TimeSpan.FromSeconds(2);

    public TimeSpan StatementTimeout { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>Reading the ring buffer, creating or dropping the event session, system_health's files, and RCA-AZ-01.</summary>
    public TimeSpan LongStatementTimeout { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>The wait before a target that didn't answer is tried again.</summary>
    public TimeSpan Reconnect { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>The wait before a block refused for a permission is tried again.</summary>
    public TimeSpan PermissionRetry { get; init; } = TimeSpan.FromMinutes(10);

    /// <summary>The event session's dispatch latency (MAX_DISPATCH_LATENCY = 5 SECONDS), plus the clocks' skew.</summary>
    public TimeSpan EventLatency { get; init; } = TimeSpan.FromSeconds(7);

    /// <summary>The servers' clocks and the VM's may differ this much.</summary>
    public TimeSpan ClockSkew { get; init; } = TimeSpan.FromSeconds(2);

    /// <summary>How long ending an observation may take when the host stops.</summary>
    public TimeSpan EndTimeout { get; init; } = TimeSpan.FromSeconds(30);
}

/// <summary>
/// A sidecar reader's block as it came back (rca/README.md, The sidecar): its rows, or why it has none, which the reader
/// says in the sidecar's own coverage. None of it reaches the evidence document.
/// </summary>
internal sealed record QuietResult(IReadOnlyList<CaptureValues>? Rows, CaptureFailureKind? Failure, string? Message)
{
    public bool Succeeded => Rows is not null;

    /// <summary>
    /// The failure in its own words: <see cref="Message"/> without the observer's fix that a refusal's message ends with,
    /// so a reader can give a block its own fix (a block that needs a permission the target's general fix doesn't give).
    /// </summary>
    public string? Error { get; init; }

    public static QuietResult Of(IReadOnlyList<CaptureValues> rows) => new(rows, null, null);

    public static QuietResult Failed(CaptureFailureKind kind, string message) => new(null, kind, message) { Error = message };

    /// <summary>A refusal: its error, and in <see cref="Message"/> the observer's fix after it.</summary>
    public static QuietResult Refused(string error, string fix) => new(null, CaptureFailureKind.Permission, $"{error} {fix}") { Error = error };
}

/// <summary>
/// What a sidecar reader (Query Store's, T4's connection holders') may use of its target's observer: its one connection,
/// run quietly, and its self-throttling's state, which the reader follows. Nothing the reader does through it changes
/// the evidence document: a failure comes back to the reader and never becomes an RCA Coverage gap or an
/// RCA.CAPTURE.&lt;target&gt; Warning; a block's time never feeds the self-throttling; and it never opens a connection,
/// so when the observer connects, and what the evidence says about it, stay the evidence capture's.
/// </summary>
internal interface ISidecarAccess
{
    /// <summary>The target's key, as the evidence has it.</summary>
    string Target { get; }

    /// <summary>The self-throttling's factor: 1, or 2, 4, or 8 while samples are slow, by which the sentinel's interval is multiplied.</summary>
    int Factor { get; }

    /// <summary>True once three slow samples in a row stopped detail capture for the rest of the observation.</summary>
    bool DetailStopped { get; }

    /// <summary>
    /// Runs one catalog block with its parameters and a timeout of its own (at least 1 s, at most the long statement
    /// timeout), on the observer's open connection. A failure is the result's, never an exception, but the observer's
    /// cancellation.
    /// </summary>
    Task<QuietResult> RunAsync(string blockId, DateTimeOffset now, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken);
}

/// <summary>
/// One target's observer: one connection, one statement at a time, the sentinel for the whole session, and the detail
/// capture its triggers start. Blind (ADR 0031): it sees what a DBA's tools see, and its cadence follows what it sees.
/// </summary>
internal abstract class TargetObserver(string target, DemoTarget gate, ICaptureConnector connector, ObserverOptions options, RunnerLog log, string fix)
{
    private readonly Dictionary<string, DateTimeOffset> refusedUntil = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTimeOffset> quietRefusedUntil = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTimeOffset> noted = new(StringComparer.Ordinal);
    private ICaptureConnection? connection;
    private DateTimeOffset nextConnect;
    private bool connectFailing;
    private QuietAccess? sidecarAccess;

    // A connection a sidecar read found lost and closed: the evidence capture's next block notes it (RunCoreAsync).
    private CaptureException? quietLoss;

    // EndAsync's hook and the lane's clock, and whether the evidence's own end has run (EvidenceEnded).
    private Action<DateTimeOffset>? evidenceEndedHook;
    private TimeProvider? evidenceEndClock;
    private bool evidenceEndDone;

    /// <summary>The target's key in the evidence: T1, T2, T3, T4, or T4-replica.</summary>
    public string Target { get; } = target;

    /// <summary>The target whose session this observer follows (the replica follows T4's).</summary>
    public DemoTarget Gate { get; } = gate;

    /// <summary>
    /// True for a target that exists only for part of a session (T4's read replica, created after the session starts):
    /// the observer joins the span once the target first answers, so its coverage starts when it existed.
    /// </summary>
    public virtual bool BeginsOnConnect => false;

    protected ObserverOptions Options { get; } = options;

    protected RunnerLog Log { get; } = log;

    protected ICaptureSink Sink { get; private set; } = NullSink.Instance;

    protected Cadence Cadence { get; private set; } = new();

    protected EpisodeIds Ids { get; private set; } = new(target);

    protected DateTimeOffset ObservingSince { get; private set; }

    /// <summary>What a sidecar reader of this target may use of its observer: see <see cref="ISidecarAccess"/>.</summary>
    protected ISidecarAccess SidecarAccess => sidecarAccess ??= new QuietAccess(this);

    /// <summary>Starts observing: the sink of the current span, then the target's own setup.</summary>
    public async Task BeginAsync(ICaptureSink sink, DateTimeOffset now, CancellationToken cancellationToken)
    {
        Sink = sink;
        Cadence = new Cadence(Options.SlowSample);
        Ids = new EpisodeIds(Target);
        ObservingSince = now;
        refusedUntil.Clear();
        quietRefusedUntil.Clear();
        quietLoss = null;
        noted.Clear();
        nextConnect = now;
        Log.Info("rca.observing", "The RCA observer is capturing this target for the session.", ("target", Target), ("connector", connector.Description));
        await StartAsync(now, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Runs the work that's due; returns when the next work is due.</summary>
    public abstract Task<DateTimeOffset> TickAsync(DateTimeOffset now, CancellationToken cancellationToken);

    /// <summary>Opens the connection ahead of observing (<see cref="BeginsOnConnect"/>); false while the target doesn't answer, tried again after a while.</summary>
    public async Task<bool> ProbeAsync(DateTimeOffset now, CancellationToken cancellationToken) => await ConnectionAsync(now, cancellationToken).ConfigureAwait(false) is not null;

    /// <summary>Closes a connection a probe opened when observing never began (the session ended first).</summary>
    public Task ReleaseAsync() => DisconnectAsync();

    /// <summary>
    /// Ends observing: the last reads, open episodes closed, the event session dropped, the connection closed. When the
    /// evidence's own end is done, before a sidecar reader's end reads, which may take a while (Query Store's, up to their
    /// bound), or else as the evidence's end returns, its end time is taken once: <paramref name="clock"/>'s, the lane's,
    /// or else <paramref name="now"/>. The evidence's last watermark is written at it and <paramref name="evidenceEnded"/>
    /// gets it, each once, whichever of them fails. The lane releases the target at it once this returns, so the span's
    /// end, its watermark, and RCA Coverage's window are the evidence's own, as without a sidecar, and a sidecar's last
    /// rows still have their span. The lane passes its clock with the hook: the end's event read keeps events up to when
    /// it ran, after <paramref name="now"/>.
    /// </summary>
    public async Task EndAsync(DateTimeOffset now, CancellationToken cancellationToken, Action<DateTimeOffset>? evidenceEnded = null, TimeProvider? clock = null)
    {
        evidenceEndedHook = evidenceEnded;
        evidenceEndClock = clock;
        evidenceEndDone = false;
        try
        {
            await StopAsync(now, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            try
            {
                EvidenceEnded(now);
            }
            finally
            {
                evidenceEndClock = null;
                await DisconnectAsync().ConfigureAwait(false);
                Log.Info("rca.observed", "The RCA observer stopped capturing this target.", ("target", Target));
                Sink = NullSink.Instance;
            }
        }
    }

    /// <summary>
    /// The evidence's own end is done (StopAsync's evidence part): its end time, taken once (EndAsync's clock, or else
    /// <paramref name="now"/>); its last watermark at it; then EndAsync's hook with it, in a finally, so each runs once
    /// whichever fails, and a failure follows them (the hook's, when both fail). A subclass calls it before its sidecar
    /// reads' end, so they don't move the span's end; EndAsync calls it otherwise.
    /// </summary>
    protected void EvidenceEnded(DateTimeOffset now)
    {
        if (evidenceEndDone)
        {
            return;
        }

        evidenceEndDone = true;
        var hook = evidenceEndedHook;
        evidenceEndedHook = null;
        var end = evidenceEndClock?.GetUtcNow() ?? now;
        try
        {
            Sink.Watermark(Target, end);
        }
        finally
        {
            hook?.Invoke(end);
        }
    }

    protected abstract Task StartAsync(DateTimeOffset now, CancellationToken cancellationToken);

    protected abstract Task StopAsync(DateTimeOffset now, CancellationToken cancellationToken);

    /// <summary>
    /// Runs one catalog block. Null when it failed, after the failure was noted: a permission refusal is an
    /// RCA.CAPTURE.&lt;target&gt; Warning with its fix and isn't tried again for a while; a lost connection is reopened
    /// later. With <paramref name="timed"/>, its duration feeds the self-throttling.
    /// </summary>
    protected Task<IReadOnlyList<CaptureValues>?> RunAsync(string blockId, DateTimeOffset now, CancellationToken cancellationToken, int[]? parameter = null, bool timed = true, bool longRunning = false, string? text = null) =>
        RunCoreAsync(blockId, now, (open, statement, timeout) => open.QueryAsync(blockId, statement, parameter, timeout, cancellationToken), timed, longRunning, text, cancellationToken);

    /// <summary>
    /// Runs one catalog block with its parameters (T-SQL's by name, PostgreSQL's by position), as the other RunAsync runs
    /// one: the sidecar's Query Store reads take a since, a flag, and lists (rca/capture/README.md).
    /// </summary>
    protected Task<IReadOnlyList<CaptureValues>?> RunAsync(string blockId, DateTimeOffset now, CaptureParameters parameters, CancellationToken cancellationToken, bool timed = true, bool longRunning = false, string? text = null) =>
        RunCoreAsync(blockId, now, (open, statement, timeout) => open.QueryAsync(blockId, statement, parameters, timeout, cancellationToken), timed, longRunning, text, cancellationToken);

    private async Task<IReadOnlyList<CaptureValues>?> RunCoreAsync(string blockId, DateTimeOffset now, Func<ICaptureConnection, string, TimeSpan, Task<IReadOnlyList<CaptureValues>>> query, bool timed, bool longRunning, string? text, CancellationToken cancellationToken)
    {
        if (refusedUntil.TryGetValue(blockId, out var until) && now < until)
        {
            return null;
        }

        if (quietLoss is { } lost && connection is null)
        {
            // A sidecar read found the connection lost and closed it (RunQuietlyAsync). This block notes the loss and waits
            // to reconnect exactly as it would have had it found the connection lost itself, as it would without the
            // sidecar's reads: the evidence never shows that a sidecar read came first.
            quietLoss = null;
            GapOnce(now, "connection:" + blockId, $"{Target} didn't answer {blockId}: {lost.Message}");
            nextConnect = now + Options.Reconnect;
            return null;
        }

        var open = await ConnectionAsync(now, cancellationToken).ConfigureAwait(false);
        if (open is null)
        {
            return null;
        }

        var started = System.Diagnostics.Stopwatch.GetTimestamp();
        try
        {
            var rows = await query(open, text ?? CaptureCatalog.Get(blockId), longRunning ? Options.LongStatementTimeout : Options.StatementTimeout).ConfigureAwait(false);
            if (timed)
            {
                Throttle(blockId, System.Diagnostics.Stopwatch.GetElapsedTime(started), now);
            }

            return rows;
        }
        catch (CaptureException ex)
        {
            if (timed && ex.Kind == CaptureFailureKind.Timeout)
            {
                Throttle(blockId, System.Diagnostics.Stopwatch.GetElapsedTime(started), now);
            }

            switch (ex.Kind)
            {
                case CaptureFailureKind.Permission:
                    refusedUntil[blockId] = now + Options.PermissionRetry;
                    Warn(now, $"{blockId} was refused a permission on {Target}, so it isn't captured: {ex.Message} {fix}");
                    break;
                case CaptureFailureKind.Connection:
                    GapOnce(now, "connection:" + blockId, $"{Target} didn't answer {blockId}: {ex.Message}");
                    await DisconnectAsync().ConfigureAwait(false);
                    nextConnect = now + Options.Reconnect;
                    break;
                default:
                    GapOnce(now, "failed:" + blockId, $"{blockId} failed on {Target}: {ex.Message}");
                    break;
            }

            return null;
        }
    }

    protected void Write(CaptureRow row) => Sink.Write(row);

    /// <summary>
    /// Runs one catalog block for a sidecar reader (<see cref="ISidecarAccess"/>), on the connection the evidence capture
    /// opened, and never opens one. Its failure goes back to the reader, with no RCA Coverage gap and no RCA.CAPTURE
    /// Warning: a refusal with the fix, and the block isn't tried again for a while (apart from the evidence's blocks); a
    /// lost connection is closed, and the evidence capture's next block notes the loss as if it had found it.
    /// </summary>
    private async Task<QuietResult> RunQuietlyAsync(string blockId, DateTimeOffset now, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken)
    {
        if (quietRefusedUntil.TryGetValue(blockId, out var until) && now < until)
        {
            return QuietResult.Refused(string.Create(CultureInfo.InvariantCulture, $"it was refused a permission on {Target}, so it's tried again at {until:HH:mm:ss} UTC."), fix);
        }

        if (connection is not { } open)
        {
            return QuietResult.Failed(CaptureFailureKind.Connection, $"{Target} had no open connection then: the evidence capture reconnects, and the read waits for it.");
        }

        try
        {
            var bounded = timeout < TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : timeout > Options.LongStatementTimeout ? Options.LongStatementTimeout : timeout;
            return QuietResult.Of(await open.QueryAsync(blockId, CaptureCatalog.Get(blockId), parameters, bounded, cancellationToken).ConfigureAwait(false));
        }
        catch (CaptureException ex)
        {
            switch (ex.Kind)
            {
                case CaptureFailureKind.Permission:
                    quietRefusedUntil[blockId] = now + Options.PermissionRetry;
                    return QuietResult.Refused(ex.Message, fix);
                case CaptureFailureKind.Connection:
                    await DisconnectAsync().ConfigureAwait(false);
                    quietLoss = ex;
                    break;
            }

            return QuietResult.Failed(ex.Kind, ex.Message);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException && (ex is not OperationCanceledException || !cancellationToken.IsCancellationRequested))
        {
            return QuietResult.Failed(CaptureFailureKind.Other, Redactor.Redact(ex.GetType().Name + ": " + ex.Message));
        }
    }

    protected void Gap(DateTimeOffset at, string text) => Sink.Note(new CaptureNote(NoteKind.Gap, Target, at, TextNormalizer.Detail(text) ?? "A gap the observer couldn't describe."));

    /// <summary>A gap, at most once every 10 minutes for the same key, so a failure that lasts doesn't fill the store.</summary>
    protected void GapOnce(DateTimeOffset at, string key, string text)
    {
        if (noted.TryGetValue(key, out var last) && at - last < TimeSpan.FromMinutes(10))
        {
            return;
        }

        noted[key] = at;
        Gap(at, text);
        Log.Warn("rca.gap", text, ("target", Target));
    }

    protected void Source(DateTimeOffset at, string blockId) => Sink.Note(new CaptureNote(NoteKind.Source, Target, at, blockId));

    /// <summary>An RCA.CAPTURE.&lt;target&gt; Warning: the export reports it, and the coverage row says it as a gap.</summary>
    protected void Warn(DateTimeOffset at, string text)
    {
        if (noted.TryGetValue("warning:" + text, out var last) && at - last < TimeSpan.FromMinutes(10))
        {
            return;
        }

        noted["warning:" + text] = at;
        Sink.Note(new CaptureNote(NoteKind.Warning, Target, at, TextNormalizer.Detail(text) ?? "A capture problem the observer couldn't describe."));
        Log.Warn("rca.capture", text, ("checkId", "RCA.CAPTURE." + Target));
    }

    /// <summary>Writes an episode's start or end as the trigger reported it; an ended episode is finished.</summary>
    protected void Report(EpisodeTrigger trigger, EpisodeChange change, DateTimeOffset at, string endDetail)
    {
        if (change == EpisodeChange.Started && trigger.Current is { } started)
        {
            EpisodeEvent(started.Start, "escalated", started.Id, started.StartDetail);
            Log.Info("rca.escalated", started.StartDetail, ("target", Target), ("episode", started.Id));
        }
        else if (change == EpisodeChange.Ended && trigger.Finish() is { } ended)
        {
            EpisodeEvent(at, "relaxed", ended.Id, endDetail);
            Log.Info("rca.relaxed", endDetail, ("target", Target), ("episode", ended.Id));
        }
    }

    /// <summary>Ends an open episode because observing stopped (the session's end), and says so.</summary>
    protected void Close(EpisodeTrigger trigger, DateTimeOffset at)
    {
        if (trigger.Finish() is { } open)
        {
            EpisodeEvent(at, "relaxed", open.Id, "The session ended while this episode was open: the observer stopped capturing.");
        }
    }

    /// <summary>A capture row of kind capture: an episode's start (escalated) or end (relaxed).</summary>
    protected void EpisodeEvent(DateTimeOffset at, string eventName, string code, string detail) =>
        Write(new CaptureRow(RcaContract.Events, Target, at, "observer")
            .Set("event_time_utc", at)
            .Set("target", Target)
            .Set("kind", "capture")
            .Set("event_name", eventName)
            .Set("code", code)
            .Set("event_count", 1L)
            .Set("detail", TextNormalizer.Detail(detail)));

    /// <summary>One counter's delta from the sentinel (RCA-PG-03 and others): a count over the interval since the previous sample.</summary>
    internal void Counter(DateTimeOffset at, string source, string metric, double? delta) => Resource(at, source, metric, delta, "count", sentinel: true);

    /// <summary>One counter or gauge reading in RCA Resource.</summary>
    protected void Resource(DateTimeOffset at, string source, string metric, double? value, string unit, bool sentinel)
    {
        if (value is not { } reading || !double.IsFinite(reading))
        {
            return;
        }

        Write(new CaptureRow(RcaContract.Resource, Target, at, source, sentinel)
            .Set("at_utc", at)
            .Set("target", Target)
            .Set("source", source)
            .Set("metric", metric)
            .Set("value", reading)
            .Set("unit", unit));
    }

    protected TimeSpan Every(TimeSpan interval) => Cadence.Scale(interval);

    protected static string Seconds(TimeSpan interval) => interval.TotalSeconds.ToString("0", CultureInfo.InvariantCulture);

    /// <summary>A quiet time as an episode's end says it: <c>60 s</c>, or <c>5 minutes</c>.</summary>
    protected static string Duration(TimeSpan interval) =>
        interval >= TimeSpan.FromMinutes(2) && interval.Seconds == 0 ? string.Create(CultureInfo.InvariantCulture, $"{interval.TotalMinutes:0} minutes") : Seconds(interval) + " s";

    /// <summary>How an episode's end says capture went back: <c>back to the 30-s sentinel.</c></summary>
    protected string BackToSentinel => $"back to the {Seconds(Options.Sentinel)}-s sentinel.";

    protected static DateTimeOffset Earliest(params DateTimeOffset?[] times) => times.Where(t => t is not null).Select(t => t!.Value).DefaultIfEmpty(DateTimeOffset.MaxValue).Min();

    private void Throttle(string blockId, TimeSpan elapsed, DateTimeOffset now)
    {
        switch (Cadence.Record(elapsed))
        {
            case CadenceChange.Slowed:
                GapOnce(now, "slowed:" + Cadence.Factor.ToString(CultureInfo.InvariantCulture), string.Create(CultureInfo.InvariantCulture, $"{blockId} took {elapsed.TotalSeconds:0.0} s on {Target}, so the observer halved its cadence there: the sentinel every {Every(Options.Sentinel).TotalSeconds:0} s."));
                break;
            case CadenceChange.DetailStopped:
                Warn(now, string.Create(CultureInfo.InvariantCulture, $"Three samples in a row took over {Options.SlowSample.TotalSeconds:0} s on {Target}, so the observer stopped its detail capture there for the rest of the session; the sentinel goes on every {Every(Options.Sentinel).TotalSeconds:0} s."));
                break;
            case CadenceChange.Recovered:
                Gap(now, string.Create(CultureInfo.InvariantCulture, $"Samples on {Target} are quick again: the sentinel every {Every(Options.Sentinel).TotalSeconds:0} s."));
                break;
        }
    }

    private async Task<ICaptureConnection?> ConnectionAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        if (connection is not null)
        {
            return connection;
        }

        if (now < nextConnect)
        {
            return null;
        }

        try
        {
            connection = await connector.OpenAsync(cancellationToken).ConfigureAwait(false);
            if (connectFailing)
            {
                Gap(now, $"{Target} answers again; capture goes on.");
                connectFailing = false;
            }

            return connection;
        }
        catch (CaptureException ex)
        {
            nextConnect = now + Options.Reconnect;
            connectFailing = true;
            if (ex.Kind == CaptureFailureKind.Permission)
            {
                Warn(now, $"The observer couldn't sign in to {Target}: {ex.Message} {fix}");
            }
            else
            {
                GapOnce(now, "connect", $"The observer couldn't connect to {Target}; it tries again every {Options.Reconnect.TotalSeconds:0} s: {ex.Message}");
            }

            return null;
        }
    }

    private async Task DisconnectAsync()
    {
        var open = connection;
        connection = null;
        if (open is not null)
        {
            try
            {
                await open.DisposeAsync().ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                Log.Debug("rca.disconnect-failed", Redactor.Redact(ex.Message), ("target", Target));
            }
        }
    }

    /// <summary>A sidecar reader's access to this observer: its quiet run, and its self-throttling's state as it is now.</summary>
    private sealed class QuietAccess(TargetObserver owner) : ISidecarAccess
    {
        public string Target => owner.Target;

        public int Factor => owner.Cadence.Factor;

        public bool DetailStopped => owner.Cadence.DetailStopped;

        public Task<QuietResult> RunAsync(string blockId, DateTimeOffset now, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken) =>
            owner.RunQuietlyAsync(blockId, now, parameters, timeout, cancellationToken);
    }

    private sealed class NullSink : ICaptureSink
    {
        public static readonly NullSink Instance = new();

        public void Write(CaptureRow row)
        {
        }

        public void Note(CaptureNote note)
        {
        }

        public void Watermark(string target, DateTimeOffset complete)
        {
        }
    }
}
