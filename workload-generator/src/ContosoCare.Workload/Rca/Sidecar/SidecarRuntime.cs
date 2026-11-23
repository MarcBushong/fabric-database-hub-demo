using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using ContosoCare.Workload.Rca.Store;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>
/// The runner's sidecar over one evidence store (rca/README.md, The sidecar), as its commands and the observer lane use
/// it: T1a's store and sealer, with this reducer, and the observers' sink.
/// <list type="bullet">
/// <item>The observers take the sink: T1 to T3's read Query Store into it (A1's reader), and T4's, with its Query Store
/// source (A2's), the watermark of its unread time under the store's root.</item>
/// <item>It seals at the observer's start, the spans an earlier process left unsealed, and at each span's close, in the
/// background and one sealing at a time, so the lane never waits for it. Every export seals too: <c>rca export</c>'s
/// commit point, and <c>rca sidecar-export</c>.</item>
/// </list>
/// </summary>
internal sealed class SidecarRuntime
{
    private readonly RunnerLog log;
    private readonly Lock gate = new();
    private Task queue = Task.CompletedTask;

    /// <param name="evidence">The evidence store, whose root holds <c>sidecars\</c> and <c>query-watermark\</c>.</param>
    /// <param name="producerVersion">The runner's version, which each sidecar names.</param>
    /// <param name="log">The runner's log.</param>
    public SidecarRuntime(EvidenceStore evidence, string producerVersion, RunnerLog? log = null)
    {
        ArgumentNullException.ThrowIfNull(evidence);
        this.log = log ?? RunnerLog.Null;
        Store = new SidecarStore(evidence, SidecarBudget.ForHost, this.log);
        Sealer = new SidecarSealer(Store, new SidecarReducer(), producerVersion, this.log);
        Sink = new StoreSidecarSink(Sealer, this.log);
    }

    public EvidenceStore Evidence => Store.Evidence;

    /// <summary>The runner's log, for the commands that use this runtime.</summary>
    public RunnerLog Log => log;

    public SidecarStore Store { get; }

    public SidecarSealer Sealer { get; }

    /// <summary>Where the observers write their sidecar rows: the open span's <c>sidecar-&lt;target&gt;.rows</c>.</summary>
    public StoreSidecarSink Sink { get; }

    /// <summary>T1, T2, or T3's observer, which reads Query Store into the sidecar too.</summary>
    public SqlTargetObserver Sql(string target, DemoTarget gate, ICaptureConnector connector, ObserverOptions options, RunnerLog observerLog) =>
        new(target, gate, connector, options, observerLog, Sink);

    /// <summary>
    /// T4's observers: the primary, which reads Query Store from <paramref name="queryStore"/> (T4's azure_sys) and counts
    /// who holds its connections; and the replica, when the host has one, whose coverage says it records nothing in Query
    /// Store.
    /// </summary>
    public IReadOnlyList<TargetObserver> Postgres(ICaptureConnector primary, ICaptureConnector? replica, ICaptureConnector queryStore, ObserverOptions options, RunnerLog observerLog)
    {
        ArgumentNullException.ThrowIfNull(primary);
        ArgumentNullException.ThrowIfNull(queryStore);
        var link = new ReplicaLink();
        var source = new PgQueryStoreSource(queryStore, new QueryWatermark(Evidence.Root, "T4"), Sink);
        List<TargetObserver> observers = [new PgPrimaryObserver(primary, options, observerLog, link, Sink, source)];
        if (replica is not null)
        {
            observers.Add(new PgReplicaObserver(replica, options, observerLog, link, Sink));
        }

        return observers;
    }

    /// <summary>
    /// The observer's start: the spans an earlier process left with unsealed rows are sealed now, and each span this
    /// process closes once it's closed. Both in the background.
    /// </summary>
    public void Start()
    {
        Evidence.SpanClosed = spanId => Queue(() => Sealer.SealSpan(spanId));
        if (Directory.Exists(Evidence.Root))
        {
            Queue(() => Sealer.SealAll());
        }
    }

    /// <summary>The observer's end: no sealing at a span's close any more, and what's queued finishes, within <paramref name="wait"/>.</summary>
    public async Task StopAsync(TimeSpan wait)
    {
        Evidence.SpanClosed = null;
        Task last;
        lock (gate)
        {
            last = queue;
        }

        try
        {
            await last.WaitAsync(wait).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            log.Warn("rca.sidecar-seal-pending", "The observer's last sealing didn't end in time; its span's sidecar rows wait for the next sealing.");
        }
    }

    /// <summary>One sealing after the others, on the thread pool; a failure is logged, and its rows wait for the next.</summary>
    private void Queue(Action seal)
    {
        lock (gate)
        {
            queue = queue.ContinueWith(_ => Run(seal), CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default);
        }
    }

    private void Run(Action seal)
    {
        try
        {
            seal();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            log.Warn("rca.sidecar-seal-failed", "Couldn't seal the observer's sidecar rows; they wait in their span for the next sealing.", ("error", Redactor.Redact(ex.GetType().Name + ": " + ex.Message)));
            log.Debug("rca.sidecar-seal-failed-detail", ex.ToString());
        }
    }
}
