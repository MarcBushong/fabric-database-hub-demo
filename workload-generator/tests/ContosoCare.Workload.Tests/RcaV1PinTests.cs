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
/// The expected values were taken at ddc0a356, main with the release of 2026-11-24, by building and running this file in a
/// temporary worktree there. That release changed them from edd01c86's, the last commit before the sidecar's contract,
/// where they were first taken: among its changes, the simulation's sessions carry its realistic names. A gzip header's OS
/// byte is zlib's OS_CODE for the platform that wrote it (0x0A on Windows, 0x03 on Linux), so the pin holds Windows' bytes
/// and sets that one byte before comparing elsewhere; every other header byte is checked. Each document's JSON SHA-256 is
/// pinned too, which no platform or compression library changes.
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

    // Taken at ddc0a356, main with the release of 2026-11-24, on Windows (arm64) with .NET SDK 10.0.403.
    private static readonly string[] SessionPin =
    [
        """export 1 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T165000Z-sqlvm01-0001","parts":2,"sha256":"4a3dc977f5bc615d63f0383946ff5e2114214569f2f9724bc32063834c507657"}],"status":"Pass","message":"1 evidence document, 2 parts, for session 5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21."}""",
        """export 1 20261120T165000Z-sqlvm01-0001 json b23358a2783b4f38e16af911c060d395e381d86cef14e4f2f67e7658f59015a9""",
        """export 1 20261120T165000Z-sqlvm01-0001 gzip 4a3dc977f5bc615d63f0383946ff5e2114214569f2f9724bc32063834c507657 3063 bytes 2 parts""",
        """export 1 20261120T165000Z-sqlvm01-0001 part 1 6f05118804b95dde42fcd24e28dbb822155e01b3d425c2ebd0abb77c14de5f23""",
        """export 1 20261120T165000Z-sqlvm01-0001 part 2 452d4c9af2a3323882866e614baebf5d1d1b855071aa5010bd1a011fe5012790""",
        """export 2 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T170000Z-sqlvm01-0002","parts":1,"sha256":"456d4f1853c12e8c703fe898b75cafc35ca1cf4d1ccade867800a6133f916645"}],"status":"Pass","message":"1 evidence document, 1 parts, for session 5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21."}""",
        """export 2 20261120T170000Z-sqlvm01-0002 json 167c965bb6ec661bcbbcf058d5717d91c3a03cffe91f0471482c2ba51ad2f8f2""",
        """export 2 20261120T170000Z-sqlvm01-0002 gzip 456d4f1853c12e8c703fe898b75cafc35ca1cf4d1ccade867800a6133f916645 1848 bytes 1 parts""",
        """export 2 20261120T170000Z-sqlvm01-0002 part 1 75aab202c9ff7f9a08d9cf78611fa5ea502096f1b1a108ea0a4f45344f5ad009""",
        """export 3 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T170952Z-sqlvm01-0003","parts":2,"sha256":"29f0280e018ba6f1604a92cfa317d0b7db47350d03b3f266ec62cf6ec0c6b7ae"}],"status":"Pass","message":"1 evidence document, 2 parts, for session 5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21."}""",
        """export 3 20261120T170952Z-sqlvm01-0003 json 3663b65e6633242a4b02f3751df0a04908e1ff84f78bdc2cd33a5b4665d00e07""",
        """export 3 20261120T170952Z-sqlvm01-0003 gzip 29f0280e018ba6f1604a92cfa317d0b7db47350d03b3f266ec62cf6ec0c6b7ae 2636 bytes 2 parts""",
        """export 3 20261120T170952Z-sqlvm01-0003 part 1 2486268a1cf30c4ed2ac885ada7d6a1a100d89d57cab9b908f235622a92cad6b""",
        """export 3 20261120T170952Z-sqlvm01-0003 part 2 60754336f67da3c93478a94dc343020100bc4973af58d7e696096dd10d6b0641""",
    ];

    private static readonly string[] SessionlessPin =
    [
        """export 1 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T165000Z-sqlvm01-0001","parts":2,"sha256":"9d7f7c4e5628f83efc54473bf8fe3e9bd608eb81897c480e3dfedf7afc12818c"}],"status":"Pass","message":"1 evidence document, 2 parts, for no control session."}""",
        """export 1 20261120T165000Z-sqlvm01-0001 json 78f5eedbd7cbe8dac31bcd571b975df20fb62e22b64bce22eac9037028734f74""",
        """export 1 20261120T165000Z-sqlvm01-0001 gzip 9d7f7c4e5628f83efc54473bf8fe3e9bd608eb81897c480e3dfedf7afc12818c 3042 bytes 2 parts""",
        """export 1 20261120T165000Z-sqlvm01-0001 part 1 976b016eb7017a9a1f05939ec273f4d2a15b228448cafd6f7f3c934f780f833f""",
        """export 1 20261120T165000Z-sqlvm01-0001 part 2 f9b739c4d9335ef588d64efc5f44a70b25b5191789a101320742fa974e150e34""",
        """export 2 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T170000Z-sqlvm01-0002","parts":1,"sha256":"9c462c6dc7802f14b75885eee281301850c86cda8b5d2c250b685a33cbf1bfd8"}],"status":"Pass","message":"1 evidence document, 1 parts, for no control session."}""",
        """export 2 20261120T170000Z-sqlvm01-0002 json c31069a7aea0c1e1084c63e68c394ab29c6b9d699bbeda48a4402f22a4b839d7""",
        """export 2 20261120T170000Z-sqlvm01-0002 gzip 9c462c6dc7802f14b75885eee281301850c86cda8b5d2c250b685a33cbf1bfd8 1826 bytes 1 parts""",
        """export 2 20261120T170000Z-sqlvm01-0002 part 1 7b3e5038057392643fe316ecfb7546ce06490871566f2dd073142aafbc3630ac""",
        """export 3 DBHUBDEMO-RCA-INDEX {"kind":"ContosoCare.RcaExportIndex","version":1,"documents":[{"documentId":"20261120T170952Z-sqlvm01-0003","parts":2,"sha256":"a812e1e984bd493509b2b43bc856856cf732cdb910a8c366eb630041b59a9ccb"}],"status":"Pass","message":"1 evidence document, 2 parts, for no control session."}""",
        """export 3 20261120T170952Z-sqlvm01-0003 json cecf76cc8655aa788f43e628c61dca6702fe9785ae51521b83e139e442191e86""",
        """export 3 20261120T170952Z-sqlvm01-0003 gzip a812e1e984bd493509b2b43bc856856cf732cdb910a8c366eb630041b59a9ccb 2613 bytes 2 parts""",
        """export 3 20261120T170952Z-sqlvm01-0003 part 1 6b09370a47f43217edd0ee830917b862c4e03ea2885a93aa640fdcc5e09965f5""",
        """export 3 20261120T170952Z-sqlvm01-0003 part 2 59b74594c187329fc4674fd4cf0247bef1f9b42b2301c0a331212ee975df76cd""",
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
