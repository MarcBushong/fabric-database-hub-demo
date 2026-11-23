using System.Text;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.Store;
using Xunit;
using static ContosoCare.Workload.Tests.RcaSimulation;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The v1 pin (unit 2's integration plan, section 1): what <c>rca export</c> stores and prints for one deterministic
/// simulation, byte for byte: each evidence document's gzip SHA-256, every part line, and the index line
/// (<c>DBHUBDEMO-RCA-INDEX</c>), for a control session and for <c>--session none</c>, with exports that aren't final and
/// one that is. The sidecar's store, its sealing, and Query Store's reads must never change them.
/// </summary>
/// <remarks>
/// The expected values were taken at edd01c86, the last commit before the sidecar's contract, by building and running this
/// file in a temporary worktree there. A gzip header's OS byte is zlib's OS_CODE for the platform that wrote it (0x0A on
/// Windows, 0x03 on Linux), so the pin holds Windows' bytes and sets that one byte before comparing elsewhere; every other
/// header byte is checked. Each document's JSON SHA-256 is pinned too, which no platform or compression library changes.
/// </remarks>
public sealed class RcaV1PinTests : IDisposable
{
    public const string Session = "5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21";

    /// <summary>The export while T4's span is still open: the runbook's 30-minute re-check.</summary>
    public static readonly DateTimeOffset T4Midway = At(17, 10, 0);

    /// <summary>
    /// The observer's options for the pin: the tests' cadences, and a slow-sample threshold no simulated sample reaches, so
    /// a busy machine can't halve a cadence and change what's captured.
    /// </summary>
    internal static readonly ObserverOptions PinOptions = Options() with { SlowSample = TimeSpan.FromHours(1) };

    // Taken at edd01c86, the last commit before the sidecar's contract, on Windows (arm64) with .NET SDK 10.0.403.
    private static readonly string[] SessionPin =
    [
        """export 1 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T165000Z-sqlvm01-0001","parts":2,"sha256":"88227ad9103103ae4e9c78a611979eaf54df7edfd11b4ae7bc708fabe04a1d79"}],"status":"Pass","message":"1 evidence document, 2 parts, for session 5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21."}""",
        """export 1 20261120T165000Z-sqlvm01-0001 json 874975c5fc5450044400f6e8e3e25ea80489331e51992903fd635c6673637dab""",
        """export 1 20261120T165000Z-sqlvm01-0001 gzip 88227ad9103103ae4e9c78a611979eaf54df7edfd11b4ae7bc708fabe04a1d79 3062 bytes 2 parts""",
        """export 1 20261120T165000Z-sqlvm01-0001 part 1 7afc122a05baf4361dd61ef28942fc592513fec1f89bcfbfd1832262ac2c4480""",
        """export 1 20261120T165000Z-sqlvm01-0001 part 2 22754de8176f7a78d9943f72185771e393d79fb43892a334eea8f53c5fb5e178""",
        """export 2 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T170000Z-sqlvm01-0002","parts":1,"sha256":"f84685feb45b073320f1e07c3f5afe43538327e5af8f7fc2b9d3c8ae18dcc172"}],"status":"Pass","message":"1 evidence document, 1 parts, for session 5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21."}""",
        """export 2 20261120T170000Z-sqlvm01-0002 json e5c95db4ef883e51ceb4e14b780f7c67c969b22e9a8263795cfa8eddc3439c7d""",
        """export 2 20261120T170000Z-sqlvm01-0002 gzip f84685feb45b073320f1e07c3f5afe43538327e5af8f7fc2b9d3c8ae18dcc172 1842 bytes 1 parts""",
        """export 2 20261120T170000Z-sqlvm01-0002 part 1 083e8c2b65de0743e50475f3419e450db97eb3b79ac55713ca9c9b8ab7732338""",
        """export 3 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T170952Z-sqlvm01-0003","parts":2,"sha256":"70e3be0649bfda478d3bb83325e0a6d418768b8555ee285ebcae049a23a7eb25"}],"status":"Pass","message":"1 evidence document, 2 parts, for session 5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21."}""",
        """export 3 20261120T170952Z-sqlvm01-0003 json 0bbebad725b5abd861ea0c62aaeff3820e47566d2c0786db7906a344369477c9""",
        """export 3 20261120T170952Z-sqlvm01-0003 gzip 70e3be0649bfda478d3bb83325e0a6d418768b8555ee285ebcae049a23a7eb25 2629 bytes 2 parts""",
        """export 3 20261120T170952Z-sqlvm01-0003 part 1 b2e1b0bc55c8856d19a6a55fea63daf3d18df5300231191687f43be5088d4ce1""",
        """export 3 20261120T170952Z-sqlvm01-0003 part 2 f6e197f07ce88294783663bb208a50815a732fd29223991209b7fc9cf27b0051""",
    ];

    private static readonly string[] SessionlessPin =
    [
        """export 1 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T165000Z-sqlvm01-0001","parts":2,"sha256":"7d67e8307a0224f2ad8221aeda0e42a6533e7f2bf543fc797ef6941df1543656"}],"status":"Pass","message":"1 evidence document, 2 parts, for no control session."}""",
        """export 1 20261120T165000Z-sqlvm01-0001 json c1265761986275204b1b8aeb9150b3cd5de0b4eb93baa6b4468a979868b1bda1""",
        """export 1 20261120T165000Z-sqlvm01-0001 gzip 7d67e8307a0224f2ad8221aeda0e42a6533e7f2bf543fc797ef6941df1543656 3041 bytes 2 parts""",
        """export 1 20261120T165000Z-sqlvm01-0001 part 1 d2ec7519ed14b6a64706113da7b2cc4379a698f050ec5586610d975655d3d158""",
        """export 1 20261120T165000Z-sqlvm01-0001 part 2 e102d7d41fef2bcccc12f6daafe5ac03a268f8430e73ea5f74f422f3e7ce1d10""",
        """export 2 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T170000Z-sqlvm01-0002","parts":1,"sha256":"a330406e9aa7a3a1685e76da8fd18264a2fe897f1e998f06beb6c4062e0f6417"}],"status":"Pass","message":"1 evidence document, 1 parts, for no control session."}""",
        """export 2 20261120T170000Z-sqlvm01-0002 json 0f676ccf71ec66ab565d4a64e4e1ac132af284ef81fb321a6b7a2a2d2aa8baa9""",
        """export 2 20261120T170000Z-sqlvm01-0002 gzip a330406e9aa7a3a1685e76da8fd18264a2fe897f1e998f06beb6c4062e0f6417 1820 bytes 1 parts""",
        """export 2 20261120T170000Z-sqlvm01-0002 part 1 b68830de3183782cff89c8d98058bd8c3b5620b9ce79ae37eec860940ebdef66""",
        """export 3 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T170952Z-sqlvm01-0003","parts":2,"sha256":"5f562e7c00bd320f0f667bd0ee088f08cf41088ad5e4deb9751c92e060535590"}],"status":"Pass","message":"1 evidence document, 2 parts, for no control session."}""",
        """export 3 20261120T170952Z-sqlvm01-0003 json 6943f72b33e739f0e3f5ee8058ef206e3584d408741fe7bf8a22ae6a34f913bb""",
        """export 3 20261120T170952Z-sqlvm01-0003 gzip 5f562e7c00bd320f0f667bd0ee088f08cf41088ad5e4deb9751c92e060535590 2607 bytes 2 parts""",
        """export 3 20261120T170952Z-sqlvm01-0003 part 1 5d5cb6f0eec3f2634d9ba0bff7f58d4b6be2d9c2f12e00d8a7a64f598fae3699""",
        """export 3 20261120T170952Z-sqlvm01-0003 part 2 d8329e30b3de529bb1f3889c12404a271f24cb1f9a0961c59bdc65c036decb28""",
    ];

    private readonly string root = Path.Combine(Path.GetTempPath(), "rca-pin-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public async Task AControlSessionsExportsAreThePinnedBytes() =>
        AssertPinned(SessionPin, await RunAsync(root, Session, null, null, TestContext.Current.CancellationToken), "session");

    [Fact]
    public async Task ASessionlessExportsAreThePinnedBytes() =>
        AssertPinned(SessionlessPin, await RunAsync(root, null, null, null, TestContext.Current.CancellationToken), "none");

    /// <summary>The expected lines of a control session's run (<see cref="Session"/>), for tests that add to the pin's simulation.</summary>
    internal static IReadOnlyList<string> SessionLines => SessionPin;

    /// <summary>
    /// The pin's simulation, in a new store under <paramref name="root"/>: T1 and T3 in one span from 16:50 to 17:05,
    /// exported once it's closed (not final); then T4 and its read replica in a second span from 17:00 to 17:20, exported
    /// at 17:10 while it's open (not final), and once it's closed (final). The observers are the defaults unless a test
    /// passes its own, built on the same connectors and the run's store. Returns what the pin compares, one line each.
    /// </summary>
    internal static async Task<List<string>> RunAsync(
        string root,
        string? session,
        Func<ManualTime, EvidenceStore, IReadOnlyList<TargetObserver>>? sqlObservers,
        Func<ManualTime, EvidenceStore, ReplicaLink, IReadOnlyList<TargetObserver>>? pgObservers,
        CancellationToken cancellationToken)
    {
        var clock = new ManualTime(T1From);
        var store = new EvidenceStore(root, clock, host: "sqlvm01");
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0");
        var lines = new List<string>();

        var sql = store.Open(T1From);
        await DriveAsync(
            sqlObservers?.Invoke(clock, store) ?? [new SqlTargetObserver("T1", DemoTarget.T1, RcaSimulation.T1(clock), PinOptions, RunnerLog.Null), new SqlTargetObserver("T3", DemoTarget.T3, T1AsT3(clock), PinOptions, RunnerLog.Null)],
            sql,
            clock,
            T1From,
            T1To,
            cancellationToken);
        sql.Close(T1To);
        clock.Set(T1To.AddSeconds(30));
        Record(lines, "export 1", exporter.Export(session, final: false, TimeSpan.Zero), exporter, store);

        var pg = store.Open(T4From);
        var link = new ReplicaLink();
        var observers = pgObservers?.Invoke(clock, store, link) ?? [new PgPrimaryObserver(T4Primary(clock), PinOptions, RunnerLog.Null, link), new PgReplicaObserver(T4Replica(clock), PinOptions, RunnerLog.Null, link)];
        clock.Set(T4From);
        foreach (var observer in observers)
        {
            pg.Began(observer.Target, T4From);
            await observer.BeginAsync(pg, T4From, cancellationToken);
        }

        await TickAsync(observers, clock, T4From, T4Midway, cancellationToken);
        clock.Set(T4Midway);
        Record(lines, "export 2", exporter.Export(session, final: false, TimeSpan.Zero), exporter, store);

        await TickAsync(observers, clock, T4Midway, T4To, cancellationToken);
        clock.Set(T4To);
        foreach (var observer in observers)
        {
            await observer.EndAsync(T4To, cancellationToken);
            pg.Ended(observer.Target, T4To);
        }

        pg.Close(T4To);
        clock.Set(T4To.AddMinutes(2));
        Record(lines, "export 3", exporter.Export(session, final: true, TimeSpan.Zero), exporter, store);
        return lines;
    }

    /// <summary>Fails with every line that differs, and writes the actual lines to a file, from which the pin is taken again.</summary>
    internal static void AssertPinned(string[] expected, List<string> actual, string name)
    {
        if (expected.SequenceEqual(actual, StringComparer.Ordinal))
        {
            return;
        }

        var file = Path.Combine(Path.GetTempPath(), "rca-v1-pin-" + name + ".txt");
        File.WriteAllLines(file, actual.Select(l => "        \"\"\"" + l + "\"\"\","), new UTF8Encoding(false));
        var differ = Enumerable.Range(0, Math.Max(expected.Length, actual.Count))
            .Where(i => i >= expected.Length || i >= actual.Count || !string.Equals(expected[i], actual[i], StringComparison.Ordinal))
            .Select(i => $"line {i + 1}: expected {(i < expected.Length ? expected[i] : "(none)")}, got {(i < actual.Count ? actual[i] : "(none)")}");
        Assert.Fail($"v1's export changed ({name}); the actual lines are in {file}.\n" + string.Join('\n', differ));
    }

    private static async Task TickAsync(IReadOnlyList<TargetObserver> observers, ManualTime clock, DateTimeOffset from, DateTimeOffset to, CancellationToken cancellationToken)
    {
        for (var now = from; now < to; now = now.AddSeconds(1))
        {
            clock.Set(now);
            foreach (var observer in observers)
            {
                await observer.TickAsync(now, cancellationToken);
            }
        }
    }

    /// <summary>One export's lines: its index line, then each document's JSON SHA-256, gzip SHA-256 and size, and each part line's SHA-256.</summary>
    private static void Record(List<string> lines, string name, ExportResult result, Exporter exporter, EvidenceStore store)
    {
        var index = result.IndexLine();
        var documents = new List<string>();
        foreach (var document in result.Documents)
        {
            var gzip = store.ReadDocument(document.DocumentId)!;
            Assert.Equal(document.Sha256, PartCodec.Sha256(gzip));
            Assert.Equal(document.Parts, PartCodec.PartCount(gzip.Length));
            var canonical = Canonical(gzip);
            var sha256 = PartCodec.Sha256(canonical);
            index = index.Replace(document.Sha256, sha256, StringComparison.Ordinal);
            documents.Add($"{name} {document.DocumentId} json {PartCodec.Sha256(PartCodec.Gunzip(gzip))}");
            documents.Add($"{name} {document.DocumentId} gzip {sha256} {canonical.Length} bytes {document.Parts} parts");
            for (var i = 1; i <= document.Parts; i++)
            {
                Assert.Equal(PartCodec.Line(document.DocumentId, gzip, i), exporter.Part(document.DocumentId, i));
                documents.Add($"{name} {document.DocumentId} part {i} {PartCodec.Sha256(Encoding.ASCII.GetBytes(PartCodec.Line(document.DocumentId, canonical, i)))}");
            }
        }

        lines.Add($"{name} {index}");
        lines.AddRange(documents);
    }

    /// <summary>The gzip with Windows' OS byte: the header is otherwise checked as .NET writes it (no time, no name, the best compression).</summary>
    private static byte[] Canonical(byte[] gzip)
    {
        Assert.True(gzip.Length > 18, "A gzip stream has a 10-byte header and an 8-byte trailer.");
        Assert.Equal(new byte[] { 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02 }, gzip[..9]);
        var copy = (byte[])gzip.Clone();
        copy[9] = 0x0A;
        return copy;
    }
}
