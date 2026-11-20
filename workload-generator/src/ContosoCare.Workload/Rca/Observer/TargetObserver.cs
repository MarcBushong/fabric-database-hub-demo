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
/// One target's observer: one connection, one statement at a time, the sentinel for the whole session, and the detail
/// capture its triggers start. Blind (ADR 0031): it sees what a DBA's tools see, and its cadence follows what it sees.
/// </summary>
internal abstract class TargetObserver(string target, DemoTarget gate, ICaptureConnector connector, ObserverOptions options, RunnerLog log, string fix)
{
    private readonly Dictionary<string, DateTimeOffset> refusedUntil = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTimeOffset> noted = new(StringComparer.Ordinal);
    private ICaptureConnection? connection;
    private DateTimeOffset nextConnect;
    private bool connectFailing;

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

    /// <summary>Starts observing: the sink of the current span, then the target's own setup.</summary>
    public async Task BeginAsync(ICaptureSink sink, DateTimeOffset now, CancellationToken cancellationToken)
    {
        Sink = sink;
        Cadence = new Cadence(Options.SlowSample);
        Ids = new EpisodeIds(Target);
        ObservingSince = now;
        refusedUntil.Clear();
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

    /// <summary>Ends observing: the last reads, open episodes closed, the event session dropped, the connection closed.</summary>
    public async Task EndAsync(DateTimeOffset now, CancellationToken cancellationToken)
    {
        try
        {
            await StopAsync(now, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            Sink.Watermark(Target, now);
            await DisconnectAsync().ConfigureAwait(false);
            Log.Info("rca.observed", "The RCA observer stopped capturing this target.", ("target", Target));
            Sink = NullSink.Instance;
        }
    }

    protected abstract Task StartAsync(DateTimeOffset now, CancellationToken cancellationToken);

    protected abstract Task StopAsync(DateTimeOffset now, CancellationToken cancellationToken);

    /// <summary>
    /// Runs one catalog block. Null when it failed, after the failure was noted: a permission refusal is an
    /// RCA.CAPTURE.&lt;target&gt; Warning with its fix and isn't tried again for a while; a lost connection is reopened
    /// later. With <paramref name="timed"/>, its duration feeds the self-throttling.
    /// </summary>
    protected async Task<IReadOnlyList<CaptureValues>?> RunAsync(string blockId, DateTimeOffset now, CancellationToken cancellationToken, int[]? parameter = null, bool timed = true, bool longRunning = false, string? text = null)
    {
        if (refusedUntil.TryGetValue(blockId, out var until) && now < until)
        {
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
            var rows = await open.QueryAsync(blockId, text ?? CaptureCatalog.Get(blockId), parameter, longRunning ? Options.LongStatementTimeout : Options.StatementTimeout, cancellationToken).ConfigureAwait(false);
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
