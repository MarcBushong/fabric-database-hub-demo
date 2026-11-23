using System.Globalization;
using System.Security.Principal;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using ContosoCare.Workload.Rca.Sidecar;
using ContosoCare.Workload.Rca.Store;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The sidecar store (rca/README.md, The sidecar): document IDs from the ledger's own sequence, offering until
/// acknowledged, acknowledgement and unknown IDs, retention at 30 days and the expired count, the spans' entries, the
/// ledger kept and rebuilt when it can't be read, the folder's ACLs, and an older runner's retention leaving it alone.
/// </summary>
public sealed class RcaSidecarStoreTests : IDisposable
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 20, 16, 50, 0, TimeSpan.Zero);

    private readonly string root = Path.Combine(Path.GetTempPath(), "rca-sidecar-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void ASidecarsIdIsItsWindowsStartItsHostAndTheHostsOwnSequence()
    {
        var rig = new SidecarRig(root, T0);
        var first = rig.Seal(rig.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T1", "T3"));
        var second = rig.Seal(rig.Observe(T0.AddHours(2), T0.AddHours(3), null, "T4"));

        Assert.Equal("20261120T165000Z-sqlvm01-0001-sidecar", first.DocumentId);
        Assert.Equal("20261120T185000Z-sqlvm01-0002-sidecar", second.DocumentId);
        Assert.True(SidecarStore.IsSidecarId(first.DocumentId));
        Assert.Equal((1, 2), (first.Sequence, second.Sequence));
        Assert.Equal((SidecarRig.Session, (string?)null), (first.SessionId, second.SessionId));
        Assert.Equal(new[] { first.DocumentId, second.DocumentId }, ReadLedger().Sidecars.Select(s => s.DocumentId));
        Assert.Equal(3, ReadLedger().NextSequence);
        Assert.True(File.Exists(Path.Combine(root, "sidecars", first.DocumentId + ".json.gz")));
        Assert.False(Directory.Exists(Path.Combine(root, "exports")));
        Assert.False(File.Exists(Path.Combine(root, "sidecars", "span.json")));
    }

    [Fact]
    public void TheSequenceWrapsAfter9999AndNeverTakesAnIdTheLedgerKeeps()
    {
        var rig = new SidecarRig(root, T0);
        rig.Store.EnsureFolder();
        var ledger = new SidecarLedger { NextSequence = 9999 };
        ledger.Sidecars.Add(new SidecarEntry { DocumentId = "20261120T185000Z-sqlvm01-0001-sidecar", SealedUtc = T0 });
        rig.Store.WriteLedger(ledger);

        var last = rig.Seal(rig.Observe(T0, T0.AddMinutes(30), null, "T1"));
        var wrapped = rig.Seal(rig.Observe(T0.AddHours(2), T0.AddHours(3), null, "T1"));

        Assert.Equal("20261120T165000Z-sqlvm01-9999-sidecar", last.DocumentId);
        Assert.Equal("20261120T185000Z-sqlvm01-0002-sidecar", wrapped.DocumentId);
    }

    [Fact]
    public void ASidecarNotAcknowledgedIsOfferedAgainWithTheSameBytes()
    {
        // F5: an rca ack that failed (an error, a deallocated VM, an old bundle) leaves the sidecar pending; the next index
        // offers it again, byte for byte, so the notebook answers already for one it wrote.
        var rig = new SidecarRig(root, T0);
        var sealedSidecar = rig.Seal(rig.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T1"));
        var offered = Assert.Single(rig.Store.Offerable());
        var bytes = rig.Store.ReadGzip(sealedSidecar.DocumentId)!;

        rig.Clock.Set(T0.AddDays(2));
        Assert.Empty(rig.Sealer.SealAll().Sealed);
        var again = Assert.Single(rig.Store.Offerable());

        Assert.Equal(offered, again);
        Assert.Equal(bytes, rig.Store.ReadGzip(again.DocumentId));
        Assert.Equal(again.Sha256, PartCodec.Sha256(bytes));
        Assert.Equal(again.Parts, PartCodec.PartCount(bytes.Length));
        Assert.Null(again.AcknowledgedUtc);
    }

    [Fact]
    public void AnUnacknowledgedSidecarExpires30DaysAfterItsSealingAndIsCountedOnce()
    {
        // F11, by the clock: offered at 29.9 days, deleted and counted as expired unread at 30.1.
        var rig = new SidecarRig(root, T0);
        var sealedSidecar = rig.Seal(rig.Observe(T0, T0.AddMinutes(30), null, "T1"));

        rig.Clock.Set(sealedSidecar.SealedUtc.AddDays(29.9));
        Assert.Single(rig.Store.Offerable());
        Assert.Equal(0, rig.Store.TakeExpiredCount());

        rig.Clock.Set(sealedSidecar.SealedUtc.AddDays(30.1));
        Assert.Empty(rig.Store.Offerable());
        Assert.Equal(1, rig.Store.TakeExpiredCount());
        Assert.Equal(0, rig.Store.TakeExpiredCount());
        Assert.Null(rig.Store.ReadGzip(sealedSidecar.DocumentId));
        Assert.Empty(ReadLedger().Sidecars);
    }

    [Fact]
    public void AcknowledgementMarksItsSidecarsReportsTheUnknownAndDeletesTheFileAtTheNextCleanup()
    {
        var rig = new SidecarRig(root, T0);
        var written = rig.Seal(rig.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T1"));
        var waiting = rig.Seal(rig.Observe(T0.AddHours(1), T0.AddHours(2), SidecarRig.Session, "T1"));
        var unknown = "20261120T165000Z-sqlvm01-0099-sidecar";

        var first = rig.Store.Acknowledge([written.DocumentId, unknown, "20261120T165000Z-sqlvm01-0001", written.DocumentId]);
        var second = rig.Store.Acknowledge([written.DocumentId]);

        Assert.Equal([written.DocumentId], first.Acknowledged);
        Assert.Equal([unknown, "20261120T165000Z-sqlvm01-0001"], first.Unknown);
        Assert.Empty(first.Already);
        Assert.Equal([written.DocumentId], second.Already);
        Assert.Equal(waiting.DocumentId, Assert.Single(rig.Store.Offerable()).DocumentId);
        Assert.Null(rig.Store.ReadGzip(written.DocumentId));

        // Its entry stays, with when it was acknowledged, so a late rca ack is still answered already, until 30 days after its sealing.
        Assert.Equal(T0.AddHours(2).AddMinutes(1), ReadLedger().Sidecars.Single(s => s.DocumentId == written.DocumentId).AcknowledgedUtc);
        rig.Clock.Set(written.SealedUtc.AddDays(30.1));
        rig.Store.Cleanup(rig.Clock.Now);
        Assert.DoesNotContain(ReadLedger().Sidecars, s => s.DocumentId == written.DocumentId);
        Assert.Equal([unknown], rig.Store.Acknowledge([unknown]).Unknown);
    }

    [Fact]
    public void ABacklogOf30DaysIsOfferedOldestSealedFirstEachOnceAndStaysInThatOrder()
    {
        // L4 and F8, the store's half: 17 sessions over 30 days, offered oldest sealed first, each once, in the same order
        // at every call; the oldest expires at 30 days and the rest keep their order. The index pages this list.
        var rig = new SidecarRig(root, T0);
        var sealedSidecars = new List<SealedSidecar>();
        for (var i = 0; i < 17; i++)
        {
            var start = T0.AddHours(i * 42);
            sealedSidecars.Add(rig.Seal(rig.Observe(start, start.AddMinutes(90), i % 3 == 0 ? null : SidecarRig.Session, "T1", "T3")));
        }

        var offered = rig.Store.Offerable();
        Assert.Equal(sealedSidecars.Select(s => s.DocumentId), offered.Select(s => s.DocumentId));
        Assert.Equal(17, offered.Select(s => s.DocumentId).Distinct().Count());
        Assert.Equal(offered, rig.Store.Offerable());
        Assert.Equal(offered.Select(s => s.DocumentId), offered.Chunk(8).SelectMany(page => page).Select(s => s.DocumentId));

        rig.Clock.Set(sealedSidecars[0].SealedUtc.AddDays(30.1));
        Assert.Equal(sealedSidecars.Skip(1).Select(s => s.DocumentId), rig.Store.Offerable().Select(s => s.DocumentId));
        Assert.Equal(1, rig.Store.TakeExpiredCount());
    }

    [Fact]
    public void ASpansEntryIsRecordedAtItsFirstRowAndStaysWhileItsFolderASidecarOrAPendingRangeNamesIt()
    {
        var rig = new SidecarRig(root, T0);
        var plain = rig.Open(T0, "T4");
        rig.Sink.Write(SidecarRig.Coverage("T4", T0, T0.AddMinutes(15)));

        // Recorded at its first row, before anything is sealed: a backfill after the folder's gone can find it.
        var recorded = ReadLedger().Spans[plain.Id];
        Assert.Equal((T0, false, (string?)null), (recorded.StartedUtc, recorded.Bound, recorded.SessionId));
        plain.Close(T0.AddMinutes(30));

        var pending = rig.Open(T0.AddHours(1), "T4");
        rig.Sink.Write(SidecarRig.Coverage("T4", T0.AddHours(1), T0.AddHours(1).AddMinutes(15)));
        pending.Close(T0.AddHours(2));
        new QueryWatermark(root, "T4").Update(state => state.Pending.Add(new PendingRange { SpanId = pending.Id, FromUtc = T0.AddHours(1).AddMinutes(45), ToUtc = T0.AddHours(2), RecordedUtc = T0.AddHours(2) }));
        foreach (var span in rig.Evidence.Spans())
        {
            rig.Bind(span, SidecarRig.Session);
        }

        Assert.Equal(2, rig.Sealer.SealAll().Sealed.Count);
        rig.Store.Acknowledge(rig.Store.Offerable().Select(s => s.DocumentId));
        Directory.Delete(plain.Directory, recursive: true);
        Directory.Delete(pending.Directory, recursive: true);

        rig.Clock.Set(T0.AddDays(31));
        rig.Store.Cleanup(rig.Clock.Now);

        var spans = ReadLedger().Spans;
        Assert.False(spans.ContainsKey(plain.Id));
        Assert.Equal((true, SidecarRig.Session), (spans[pending.Id].Bound, spans[pending.Id].SessionId));
    }

    [Fact]
    public void TodaysEvidenceStoreCleanupLeavesTheSidecarsAndTheWatermarkAlone()
    {
        // The rollback invariant (unit 2's plan, 2.3): the evidence store's retention deletes spans and exports\*.gz, and
        // nothing else, so sealed sidecars, the ledger, and T4's pending ranges survive it at 7.1 and 30.1 days.
        var rig = new SidecarRig(root, T0);
        var span = rig.Open(T0, "T1", "T3");
        for (var at = T0; at < T0.AddMinutes(10); at = at.AddSeconds(30))
        {
            span.Write(new CaptureRow(RcaContract.Resource, "T1", at, "RCA-SQL-09", sentinel: true).Set("at_utc", at).Set("target", "T1").Set("source", "RCA-SQL-09").Set("metric", "processes_blocked").Set("value", 0.0).Set("unit", "count"));
        }

        rig.Sink.Write(SidecarRig.Coverage("T1", T0, T0.AddMinutes(10)));
        span.Close(T0.AddMinutes(10));
        new QueryWatermark(root, "T4").Update(state => state.Pending.Add(new PendingRange { SpanId = span.Id, FromUtc = T0, ToUtc = T0.AddMinutes(10), RecordedUtc = T0.AddMinutes(10) }));
        rig.Clock.Set(T0.AddMinutes(11));
        Assert.Single(rig.Sealer.SealAll().Sealed);
        Assert.Single(new Exporter(rig.Evidence, RunnerLog.Null, "1.0.0").Export(null, final: true, TimeSpan.Zero).Documents);
        var before = Snapshot("sidecars", "query-watermark");

        Assert.Equal(1, rig.Evidence.Cleanup(T0.AddDays(7.1), RunnerLog.Null));
        Assert.Empty(rig.Evidence.Spans());
        Assert.Equal(before, Snapshot("sidecars", "query-watermark"));

        Assert.Equal(0, rig.Evidence.Cleanup(T0.AddDays(30.1), RunnerLog.Null));
        Assert.Equal(before, Snapshot("sidecars", "query-watermark"));
    }

    [Fact]
    public void AnUnreadableLedgerIsKeptAndRebuiltFromTheSealedSidecarsWhichAreOfferedAgain()
    {
        var rig = new SidecarRig(root, T0);
        var written = rig.Seal(rig.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T1"));
        rig.Store.Acknowledge([written.DocumentId]);
        rig.Store.Cleanup(rig.Clock.Now);
        var kept = rig.Seal(rig.Observe(T0.AddHours(1), T0.AddHours(2), SidecarRig.Session, "T1"));
        File.WriteAllText(Path.Combine(root, "sidecars", "ledger.json"), "{\"version\": 1, \"sidecars\": [", new UTF8Encoding(false));

        var offered = Assert.Single(rig.Store.Offerable());

        // The rebuilt entry is the document's own header; only the span it came from is unknown, which no reader needs.
        Assert.Equal(
            (kept.DocumentId, kept.SessionId, kept.Host, kept.Sequence, kept.WindowStartUtc, kept.WindowEndUtc, kept.SealedUtc, kept.Parts, kept.Sha256, (DateTimeOffset?)null),
            (offered.DocumentId, offered.SessionId, offered.Host, offered.Sequence, offered.WindowStartUtc, offered.WindowEndUtc, offered.SealedUtc, offered.Parts, offered.Sha256, offered.AcknowledgedUtc));
        var unreadable = Assert.Single(Directory.GetFiles(Path.Combine(root, "sidecars"), "ledger.json.unreadable-*"));
        Assert.Equal("{\"version\": 1, \"sidecars\": [", File.ReadAllText(unreadable));
        Assert.Equal(kept.DocumentId, Assert.Single(ReadLedger().Sidecars).DocumentId);
    }

    [Fact]
    public void AnUnreadableLedgersRebuildIsSavedAtOnceSoAnAcknowledgementOfNothingKeepsIt()
    {
        // Review, Medium 2: an rca ack of IDs the store doesn't hold writes nothing itself; the ledger rebuilt for it must
        // already be on disk, or the next read finds none and every pending sidecar is orphaned.
        var rig = new SidecarRig(root, T0);
        var sealedSidecar = rig.Seal(rig.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T1"));
        File.WriteAllText(Path.Combine(root, "sidecars", "ledger.json"), "{ not a ledger", new UTF8Encoding(false));

        var acknowledgement = rig.Store.Acknowledge(["20261120T165000Z-sqlvm01-0099-sidecar"]);

        Assert.Equal(["20261120T165000Z-sqlvm01-0099-sidecar"], acknowledgement.Unknown);
        var saved = ReadLedger();
        Assert.Equal(sealedSidecar.DocumentId, Assert.Single(saved.Sidecars).DocumentId);
        Assert.Equal(sealedSidecar.Sequence + 1, saved.NextSequence);
        Assert.Equal(sealedSidecar.DocumentId, Assert.Single(rig.Store.Offerable()).DocumentId);
    }

    [Fact]
    public void AMissingLedgerIsRebuiltFromTheSealedSidecarsWithTheirBudget()
    {
        // Review, Medium 2: a ledger that's gone while sealed sidecars remain is rebuilt from them, not started empty.
        var rig = new SidecarRig(root, T0);
        var sealedSidecar = rig.Seal(rig.Observe(T0, T0.AddMinutes(30), SidecarRig.Session, "T1"));
        File.Delete(Path.Combine(root, "sidecars", "ledger.json"));

        var offered = Assert.Single(rig.Store.Offerable());

        Assert.Equal((sealedSidecar.DocumentId, sealedSidecar.Sha256, (string?)SidecarRig.Session), (offered.DocumentId, offered.Sha256, offered.SessionId));
        Assert.Equal((long)rig.Store.ReadGzip(offered.DocumentId)!.Length, ReadLedger().Budgets[SidecarRig.Session].Bytes);
    }

    [Fact]
    public void TheFirstSealingWritesTheLedgerBeforeItsFirstSidecar()
    {
        // A missing ledger is rebuilt from the documents, so a sealing cut short after its document and before its ledger
        // must leave a ledger beside it: a rebuild would otherwise offer that document beside the same rows sealed again.
        var rig = new SidecarRig(root, T0);
        var span = rig.Open(T0, "T1");
        File.WriteAllBytes(SidecarSealer.FileFor(span.Directory, "T1"), StoredLines.Row(SidecarRig.Coverage("T1", T0, T0.AddMinutes(15))));
        span.Close(T0.AddMinutes(15));
        var ledgerPath = Path.Combine(root, "sidecars", "ledger.json");
        Assert.False(File.Exists(ledgerPath));
        var existed = false;
        rig.Sealer.Rotated = _ => existed = File.Exists(ledgerPath);

        rig.Seal(rig.Span(span.Id));

        Assert.True(existed);
    }

    [Fact]
    public void AnOrphanSidecarIsNeverOfferedGoes30DaysAfterItsWritingAndNothingElseIsSwept()
    {
        // Review, Medium 3 and Low 5: a document with no entry (a sealing cut short before its ledger was written) is never
        // offered, and the sweep deletes it 30 days after it was written; a file not named as a sidecar is never deleted.
        var rig = new SidecarRig(root, T0);
        rig.Store.EnsureFolder();
        rig.Store.WriteLedger(new SidecarLedger());
        var orphan = Path.Combine(root, "sidecars", "20261120T165000Z-sqlvm01-0042-sidecar.json.gz");
        var evidenceNamed = Path.Combine(root, "sidecars", "20261120T165000Z-sqlvm01-0042.json.gz");
        var other = Path.Combine(root, "sidecars", "notes.json.gz");
        foreach (var file in new[] { orphan, evidenceNamed, other })
        {
            File.WriteAllBytes(file, PartCodec.Gzip("{}"u8.ToArray()));
            File.SetLastWriteTimeUtc(file, T0.UtcDateTime);
        }

        rig.Clock.Set(T0.AddDays(29.9));
        Assert.Empty(rig.Store.Offerable());
        Assert.True(File.Exists(orphan));

        rig.Store.Cleanup(T0.AddDays(30.1));

        Assert.False(File.Exists(orphan));
        Assert.True(File.Exists(evidenceNamed));
        Assert.True(File.Exists(other));
    }

    [Fact]
    public void TheSidecarsFolderOfTheDefaultStoreIsOnlyForSystemAndAdministrators()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows() && IsElevated(), "The folder's ACLs are Windows', and a store only SYSTEM and Administrators may open needs an elevated test.");
#pragma warning disable CA1416 // Windows only: skipped above elsewhere.
        var store = new SidecarStore(new EvidenceStore(Path.Combine(root, "secure"), TimeProvider.System, secure: true), SidecarRig.Budget);

        store.EnsureFolder();

        var acl = new DirectoryInfo(store.Directory).GetAccessControl();
        var rules = acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<System.Security.AccessControl.FileSystemAccessRule>().ToList();
        Assert.True(acl.AreAccessRulesProtected);
        Assert.Equal(
            new[] { WellKnownSidType.BuiltinAdministratorsSid, WellKnownSidType.LocalSystemSid }.Select(s => new SecurityIdentifier(s, null).Value).Order(StringComparer.Ordinal),
            rules.Select(r => r.IdentityReference.Value).Distinct().Order(StringComparer.Ordinal));
#pragma warning restore CA1416
    }

    private static bool IsElevated()
    {
#pragma warning disable CA1416 // Called only on Windows.
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
#pragma warning restore CA1416
    }

    private SidecarLedger ReadLedger() => JsonSerializer.Deserialize(File.ReadAllText(Path.Combine(root, "sidecars", "ledger.json")), SidecarJsonContext.Default.SidecarLedger)!;

    /// <summary>Every file under the folders, with its bytes' SHA-256.</summary>
    private List<string> Snapshot(params string[] folders) =>
        [.. folders.SelectMany(f => Directory.GetFiles(Path.Combine(root, f), "*", SearchOption.AllDirectories))
            .Where(f => !f.EndsWith(".lock", StringComparison.Ordinal))
            .Order(StringComparer.Ordinal)
            .Select(f => Path.GetRelativePath(root, f) + " " + PartCodec.Sha256(File.ReadAllBytes(f)))];
}

/// <summary>
/// The sidecar's tests' rig: an evidence store on a manual clock, the sidecar store with a session budget (the default
/// rule unless a test sets its own), the sealer with a reducer that keeps every draft it gets, and the store-backed sink.
/// </summary>
internal sealed class SidecarRig
{
    public const string Session = "5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21";

    public SidecarRig(string root, DateTimeOffset start, string host = "sqlvm01", long targetCap = EvidenceStore.DefaultTargetCap, Func<IReadOnlyCollection<string>, int>? budget = null, RunnerLog? log = null)
    {
        Clock = new ManualTime(start);
        Evidence = new EvidenceStore(root, Clock, targetCap, host: host);
        Store = new SidecarStore(Evidence, budget ?? Budget, log);
        Sealer = new SidecarSealer(Store, Reducer, "1.0.0", log);
        Sink = new StoreSidecarSink(Sealer);
    }

    public ManualTime Clock { get; }

    public EvidenceStore Evidence { get; }

    public SidecarStore Store { get; }

    public CapturingReducer Reducer { get; } = new();

    public SidecarSealer Sealer { get; }

    public StoreSidecarSink Sink { get; }

    /// <summary>The per-host session budget the reducer's side keeps (Exporter.cs:56's rule): 64 KiB for several targets, 32 KiB for one.</summary>
    public static int Budget(IReadOnlyCollection<string> targets) => targets.Count(t => t != "T5") > 1 ? 64 * 1024 : 32 * 1024;

    public static CaptureRow Coverage(string target, DateTimeOffset from, DateTimeOffset to, string? sources = "RCA-SQL-10,RCA-SQL-15", string? gaps = null, bool backfill = false) =>
        new CaptureRow(RcaContract.QueryCoverage, target, to, "RCA-SQL-15")
            .Set("target", target)
            .Set("window_start_utc", from)
            .Set("window_end_utc", to)
            .Set("state", "READ_WRITE")
            .Set("capture_mode", "AUTO")
            .Set("interval_minutes", 15)
            .Set("read_from_utc", from)
            .Set("read_to_utc", to)
            .Set("backfill", backfill)
            .Set("sources", sources)
            .Set("gaps", gaps);

    public static CaptureRow Stats(string target, DateTimeOffset interval, long query, double cpu, string text = "SELECT ? FROM care.patients AS p WHERE p.patient_id = @id") =>
        new CaptureRow(RcaContract.QueryStats, target, interval.AddMinutes(17), "RCA-SQL-10")
            .Set("captured_at_utc", interval.AddMinutes(17))
            .Set("target", target)
            .Set("interval_start_utc", interval)
            .Set("interval_end_utc", interval.AddMinutes(15))
            .Set("query_id", query)
            .Set("plan_id", query * 10)
            .Set("executions", 100L)
            .Set("cpu_ms", cpu)
            .Set("statement_text", text);

    /// <summary>Opens a span observing <paramref name="targets"/>, as the observer lane does.</summary>
    public SpanWriter Open(DateTimeOffset at, params string[] targets)
    {
        Clock.Set(at);
        var span = Evidence.Open(at);
        foreach (var target in targets)
        {
            span.Began(target, at);
        }

        return span;
    }

    /// <summary>
    /// One closed observation: each target's Query Store read every 15 minutes (a coverage row and two queries' rows),
    /// bound to <paramref name="session"/> as an export binds it. The clock ends a minute after the span.
    /// </summary>
    public SpanInfo Observe(DateTimeOffset from, DateTimeOffset to, string? session, params string[] targets) => Bind(Capture(from, to, targets), session);

    /// <summary>One closed observation, as <see cref="Observe"/>, that no export has bound yet.</summary>
    public SpanInfo Capture(DateTimeOffset from, DateTimeOffset to, params string[] targets)
    {
        var span = Open(from, targets);
        for (var read = from; read < to; read = read.AddMinutes(15))
        {
            foreach (var target in targets)
            {
                Clock.Set(read.AddMinutes(2));
                Sink.Write(Stats(target, read.AddMinutes(-15), 412, 2400));
                Sink.Write(Stats(target, read.AddMinutes(-15), 377, 350));
                Sink.Write(Coverage(target, read, read.AddMinutes(15) < to ? read.AddMinutes(15) : to));
            }
        }

        foreach (var target in targets)
        {
            span.Ended(target, to);
        }

        span.Close(to);
        Clock.Set(to.AddMinutes(1));
        return Span(span.Id);
    }

    /// <summary>Binds a span to a session as an export does: its export.json, bound.</summary>
    public SpanInfo Bind(SpanInfo span, string? session)
    {
        span.Export.Bound = true;
        span.Export.SessionId = session;
        EvidenceStore.WriteExport(span);
        return Span(span.Id);
    }

    public SpanInfo Span(string id) => Evidence.Spans().Single(s => s.Id == id);

    public SealedSidecar Seal(SpanInfo span) => Sealer.SealSpan(span) ?? throw new InvalidOperationException("The span had nothing to seal.");
}

/// <summary>
/// A stand-in for T1c's reducer: it keeps each draft and its budget, cuts nothing, and encodes the draft as the contract
/// encodes a sidecar (rca/README.md, The evidence document's encoding): one string dictionary, times as milliseconds
/// after the window's start, all-null columns left out, and a coverage row for each target that has none, as T1c's
/// reducer adds it. The store's and the sealer's tests then work on a sidecar's real structure.
/// </summary>
internal sealed class CapturingReducer : ISidecarReducer
{
    public List<(SidecarDraft Draft, int Remaining)> Calls { get; } = [];

    public static byte[] Encode(SidecarDraft draft)
    {
        var epoch = SidecarStore.Second(draft.WindowStartUtc);
        var strings = new List<string>();
        var tables = new List<(string Name, List<(string Column, List<object?> Values)> Columns, int Rows)>();
        foreach (var table in RcaContract.SidecarTables)
        {
            var rows = draft.Tables.TryGetValue(table.Name, out var kept) ? kept : [];
            if (table.Name == RcaContract.QueryCoverage)
            {
                rows = [.. rows, .. draft.Targets.Where(t => !rows.Exists(r => r.Target == t)).Select(t => NoRead(draft, t))];
            }

            if (rows.Count == 0)
            {
                continue;
            }

            var columns = new List<(string, List<object?>)>();
            foreach (var column in table.Columns)
            {
                var values = rows.Select(r => Value(column, r.Get(column.Name), strings, epoch)).ToList();
                if (values.Exists(v => v is not null) || column.Required)
                {
                    columns.Add((column.Name, values));
                }
            }

            tables.Add((table.Name, columns, rows.Count));
        }

        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer, new JsonWriterOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            json.WriteStartObject();
            json.WriteString("kind", RcaContract.SidecarKind);
            json.WriteNumber("version", RcaContract.SidecarVersion);
            json.WriteString("documentId", draft.DocumentId);
            if (draft.SessionId is null)
            {
                json.WriteNull("sessionId");
            }
            else
            {
                json.WriteString("sessionId", draft.SessionId);
            }

            json.WriteStartObject("producer");
            json.WriteString("name", "ContosoCare.Workload");
            json.WriteString("version", draft.ProducerVersion);
            json.WriteString("host", draft.Host);
            json.WriteString("lane", "observer");
            json.WriteEndObject();
            json.WriteString("exportedUtc", Utc(draft.ExportedUtc));
            json.WriteNumber("sequence", draft.Sequence);
            json.WriteBoolean("final", draft.Final);
            json.WriteString("windowStartUtc", Utc(draft.WindowStartUtc));
            json.WriteString("windowEndUtc", Utc(draft.WindowEndUtc));
            json.WriteStartArray("targets");
            foreach (var target in draft.Targets)
            {
                json.WriteStringValue(target);
            }

            json.WriteEndArray();
            json.WriteString("epochUtc", Utc(epoch));
            json.WriteStartArray("strings");
            foreach (var text in strings)
            {
                json.WriteStringValue(text);
            }

            json.WriteEndArray();
            json.WriteStartObject("tables");
            foreach (var (name, columns, count) in tables)
            {
                json.WriteStartObject(name);
                json.WriteNumber("rows", count);
                json.WriteStartObject("columns");
                foreach (var (column, values) in columns)
                {
                    json.WriteStartArray(column);
                    foreach (var value in values)
                    {
                        switch (value)
                        {
                            case null:
                                json.WriteNullValue();
                                break;
                            case long number:
                                json.WriteNumberValue(number);
                                break;
                            case double number:
                                json.WriteNumberValue(number);
                                break;
                            case bool flag:
                                json.WriteBooleanValue(flag);
                                break;
                        }
                    }

                    json.WriteEndArray();
                }

                json.WriteEndObject();
                json.WriteEndObject();
            }

            json.WriteEndObject();
            json.WriteEndObject();
        }

        return buffer.ToArray();
    }

    public ReducedSidecar Reduce(SidecarDraft draft, int remainingSessionBytes)
    {
        Calls.Add((draft, remainingSessionBytes));
        var json = Encode(draft);
        var gzip = PartCodec.Gzip(json);
        return new ReducedSidecar(json, gzip, PartCodec.Sha256(gzip), PartCodec.PartCount(gzip.Length), []);
    }

    /// <summary>Each coverage row's gaps in a sealed sidecar, by target, in the document's order.</summary>
    public static List<(string Target, string? Gaps)> CoverageGaps(byte[] gzip)
    {
        var root = System.Text.Json.Nodes.JsonNode.Parse(PartCodec.Gunzip(gzip))!;
        var strings = root["strings"]!.AsArray().Select(s => s!.GetValue<string>()).ToList();
        var columns = root["tables"]![RcaContract.QueryCoverage]!["columns"]!;
        var targets = columns["target"]!.AsArray().Select(t => strings[t!.GetValue<int>()]).ToList();
        var gaps = columns["gaps"]?.AsArray().Select(g => g is null ? null : strings[g.GetValue<int>()]).ToList() ?? [.. targets.Select(_ => (string?)null)];
        return [.. targets.Zip(gaps)];
    }

    /// <summary>A table's row count in a sealed sidecar, 0 when it has none.</summary>
    public static int Rows(byte[] gzip, string table) =>
        System.Text.Json.Nodes.JsonNode.Parse(PartCodec.Gunzip(gzip))!["tables"]![table]?["rows"]?.GetValue<int>() ?? 0;

    private static CaptureRow NoRead(SidecarDraft draft, string target) =>
        new CaptureRow(RcaContract.QueryCoverage, target, draft.WindowStartUtc, "coverage")
            .Set("target", target)
            .Set("window_start_utc", draft.WindowStartUtc)
            .Set("window_end_utc", draft.WindowEndUtc)
            .Set("backfill", false)
            .Set("gaps", "No Query Store read of this target is recorded in this window.");

    private static object? Value(RcaColumn column, object? value, List<string> strings, DateTimeOffset epoch)
    {
        if (value is null)
        {
            return column.Required ? throw new InvalidOperationException($"{column.Name} is required.") : null;
        }

        switch (column.Type)
        {
            case "string":
                var text = value as string ?? Convert.ToString(value, CultureInfo.InvariantCulture)!;
                var index = strings.IndexOf(text);
                if (index < 0)
                {
                    strings.Add(text);
                    index = strings.Count - 1;
                }

                return (long)index;
            case "timestamp":
                return (long)Math.Round(((DateTimeOffset)value - epoch).TotalMilliseconds, MidpointRounding.AwayFromZero);
            case "long" or "integer":
                return Convert.ToInt64(value, CultureInfo.InvariantCulture);
            case "double":
                return Convert.ToDouble(value, CultureInfo.InvariantCulture);
            case "boolean":
                return (bool)value;
            default:
                throw new InvalidOperationException($"{column.Name}'s type {column.Type} isn't in documents.");
        }
    }

    private static string Utc(DateTimeOffset time) => time.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
}
