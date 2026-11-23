using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using ContosoCare.Workload.Rca.Sidecar;
using ContosoCare.Workload.Rca.Store;
using Xunit;
using static ContosoCare.Workload.Tests.RcaSimulation;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// Evidence identity (T1a's spec): a failed or slow Query Store read changes no evidence byte. The v1 pin's simulation
/// runs with every observer's Query Store reads wired to the store-backed sink (T1's and T3's, A1's; T4's and its
/// replica's, A2's), and the reads timing out, refused, or slowed: v1's exports still match the pin, and the sidecar's
/// merged coverage keeps the failures as its gaps. A1's shared seam (<see cref="ISidecarAccess"/>) is what turns a
/// failed block into the reader's gap.
/// </summary>
public sealed class RcaSidecarEvidenceIdentityTests : IDisposable
{
    private const string Fault = "the identity test's fault";

    private static readonly HashSet<string> QueryStoreBlocks = new(StringComparer.Ordinal)
    {
        "RCA-SQL-10", "RCA-SQL-11", "RCA-SQL-14", "RCA-SQL-15", "RCA-AZ-03", "RCA-AZ-04",
        "RCA-PG-13", "RCA-PG-14", "RCA-PG-15", "RCA-PG-16", "RCA-PG-17",
    };

    private readonly string root = Path.Combine(Path.GetTempPath(), "rca-identity-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Theory]
    [InlineData("timeout")]
    [InlineData("permission")]
    public async Task FailingQueryStoreReadsChangeNoEvidenceByteAndStayAsTheSidecarsGaps(string failure)
    {
        var kind = failure == "timeout" ? CaptureFailureKind.Timeout : CaptureFailureKind.Permission;
        var lines = await RunAsync(RcaV1PinTests.PinOptions, block => new CaptureException(kind, Fault), TimeSpan.Zero);

        RcaV1PinTests.AssertPinned([.. RcaV1PinTests.SessionLines], lines, "identity-" + failure);
        var coverage = Seal().SelectMany(d => d.Tables[RcaContract.QueryCoverage]).ToDictionary(r => r.Target, StringComparer.Ordinal);
        foreach (var target in new[] { "T1", "T3", "T4", "T4-replica" })
        {
            Assert.Contains(Fault, (string?)coverage[target].Get("gaps") ?? string.Empty, StringComparison.Ordinal);
        }
    }

    [Fact]
    public async Task SlowQueryStoreReadsChangeNoEvidenceByte()
    {
        // Each connection's first three Query Store blocks take longer than a slow sample; were their time counted, three
        // in a row would stop the observer's detail capture, and every document after would differ.
        var options = RcaV1PinTests.PinOptions with { SlowSample = TimeSpan.FromSeconds(1) };

        var lines = await RunAsync(options, _ => null, TimeSpan.FromSeconds(1.2));

        RcaV1PinTests.AssertPinned([.. RcaV1PinTests.SessionLines], lines, "identity-slow");
    }

    /// <summary>The pin's simulation for a control session, with every observer's Query Store reads wired and their blocks faulted or slowed.</summary>
    private Task<List<string>> RunAsync(ObserverOptions options, Func<string, CaptureException?> fault, TimeSpan delay) =>
        RcaV1PinTests.RunAsync(
            root,
            RcaV1PinTests.Session,
            (clock, store) =>
            {
                var sink = Sink(store);
                return
                [
                    new SqlTargetObserver("T1", DemoTarget.T1, new FaultyConnector(RcaSimulation.T1(clock), fault, delay), options, RunnerLog.Null, sink),
                    new SqlTargetObserver("T3", DemoTarget.T3, new FaultyConnector(T1AsT3(clock), fault, delay), options, RunnerLog.Null, sink),
                ];
            },
            (clock, store, link) =>
            {
                // T4's reads on azure_sys (RCA-PG-14, 15) answer nothing. The primary's RCA-PG-13, 16, and 17 and the replica's
                // RCA-PG-13 run quietly on the observer's own connection, so a fault there is one A1's seam must keep out of
                // the evidence.
                var sink = Sink(store);
                var azureSys = new FaultyConnector(new ScriptedConnector((_, _) => []) { ParameterAnswer = (_, _) => [] }, fault, delay);
                return
                [
                    new PgPrimaryObserver(new FaultyConnector(T4Primary(clock), fault, delay), options, RunnerLog.Null, link, sink, new PgQueryStoreSource(azureSys, new QueryWatermark(store.Root, "T4"), sink)),
                    new PgReplicaObserver(new FaultyConnector(T4Replica(clock), fault, delay), options, RunnerLog.Null, link, sink),
                ];
            },
            TestContext.Current.CancellationToken);

    private static StoreSidecarSink Sink(EvidenceStore store) => new(new SidecarSealer(new SidecarStore(store, SidecarRig.Budget), new CapturingReducer(), "1.0.0"));

    /// <summary>Seals what the run's spans hold, as the next export would, and returns the drafts the reducer got.</summary>
    private List<SidecarDraft> Seal()
    {
        var reducer = new CapturingReducer();
        var sealer = new SidecarSealer(new SidecarStore(new EvidenceStore(root, new ManualTime(T4To.AddMinutes(5)), host: "sqlvm01"), SidecarRig.Budget), reducer, "1.0.0");
        Assert.NotEmpty(sealer.SealAll().Sealed);
        return [.. reducer.Calls.Select(c => c.Draft)];
    }

    /// <summary>
    /// A connection whose Query Store blocks fail as <paramref name="fault"/> says, and whose first three of them each
    /// take <paramref name="delay"/>; every other block is the inner connector's.
    /// </summary>
    private sealed class FaultyConnector(ICaptureConnector inner, Func<string, CaptureException?> fault, TimeSpan delay) : ICaptureConnector
    {
        private int slowed;

        public string Description => inner.Description;

        public async Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken) => new Connection(this, await inner.OpenAsync(cancellationToken));

        private async Task BeforeAsync(string blockId, CancellationToken cancellationToken)
        {
            if (!QueryStoreBlocks.Contains(blockId))
            {
                return;
            }

            if (delay > TimeSpan.Zero && Interlocked.Increment(ref slowed) <= 3)
            {
                await Task.Delay(delay, cancellationToken);
            }

            if (fault(blockId) is { } failure)
            {
                throw failure;
            }
        }

        private sealed class Connection(FaultyConnector owner, ICaptureConnection connection) : ICaptureConnection
        {
            public async Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken)
            {
                await owner.BeforeAsync(blockId, cancellationToken);
                return await connection.QueryAsync(blockId, text, parameter, timeout, cancellationToken);
            }

            public async Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken)
            {
                await owner.BeforeAsync(blockId, cancellationToken);
                return await connection.QueryAsync(blockId, text, parameters, timeout, cancellationToken);
            }

            public ValueTask DisposeAsync() => connection.DisposeAsync();
        }
    }
}
