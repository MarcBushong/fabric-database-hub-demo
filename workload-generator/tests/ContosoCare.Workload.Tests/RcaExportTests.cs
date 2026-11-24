using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.Store;
using Xunit;
using static ContosoCare.Workload.Tests.RcaSimulation;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The local evidence store and <c>rca export</c> (ADR 0031, rca/README.md): documents that validate against
/// evidence.schema.json and carry the fixtures' facts, part lines and an index within the transport's limits, windows
/// that never overlap, the budget's cuts recorded as coverage gaps, the answer key kept apart, and retention.
/// </summary>
public sealed class RcaExportTests : IDisposable
{
    private const string Session = "5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21";

    private static readonly string[] T1HeadColumns = ["status", "open_transactions", "lock_resource_type", "lock_object", "lock_index", "lock_mode_held", "input_buffer", "module_name", "login_name", "host_name", "program_name", "is_demo"];

    private static readonly DateTimeOffset[] EscalatorSamples = [At(16, 52, 30), At(16, 54, 30), At(16, 56, 30), At(16, 58, 30)];

    private static readonly string[] T4HeadColumns = ["status", "wait_type", "backend_type", "lock_object", "lock_mode_held", "program_name", "login_name", "is_demo"];

    /// <summary>fc's case (2026-11-23), at 16:00 here: when the session was accepted, and when its start's export with no session ran.</summary>
    private static readonly DateTimeOffset SessionAccepted = At(16, 24, 29);

    private static readonly DateTimeOffset SessionlessExport = At(16, 25, 20);

    private readonly string root = Path.Combine(Path.GetTempPath(), "rca-store-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Theory]
    [InlineData("t1-blocking-chain")]
    [InlineData("t4-replica-lag")]
    public void TheFixturesPartsDecodeToTheirDocuments(string fixture)
    {
        var lines = File.ReadAllLines(RepositoryPaths.Combine("rca", "fixtures", fixture + ".parts.txt")).Where(l => l.Length > 0).ToList();
        var expected = JsonNode.Parse(File.ReadAllText(RepositoryPaths.Combine("rca", "fixtures", fixture + ".evidence.json")));

        var decoded = Assert.Single(PartCodec.Decode(lines));

        Assert.True(JsonNode.DeepEquals(expected, JsonNode.Parse(decoded.Json)));
        Assert.Equal(expected!["documentId"]!.GetValue<string>(), decoded.DocumentId);
    }

    [Theory]
    [InlineData("t1-blocking-chain")]
    [InlineData("t4-replica-lag")]
    public void AFixtureDocumentRoundTripsThroughTheEncoder(string fixture)
    {
        var node = JsonNode.Parse(File.ReadAllText(RepositoryPaths.Combine("rca", "fixtures", fixture + ".evidence.json")))!;
        var gzip = PartCodec.Gzip(System.Text.Encoding.UTF8.GetBytes(node.ToJsonString()));

        var lines = PartCodec.Lines(node["documentId"]!.GetValue<string>(), gzip);

        var pattern = new Regex(RcaSchemas.PartLinePattern());
        Assert.All(lines, line =>
        {
            Assert.True(line.Length <= RcaContract.MaximumLineLength);
            Assert.Matches(pattern, line);
            Assert.All(line, c => Assert.True(c < 128));
        });
        Assert.Equal(PartCodec.PartCount(gzip.Length), lines.Count);
        Assert.True(JsonNode.DeepEquals(node, JsonNode.Parse(Assert.Single(PartCodec.Decode(lines.Reverse())).Json)));
    }

    [Fact]
    public void AMissingOrBadPartIsRefused()
    {
        var bytes = new byte[9000];
        new Random(1).NextBytes(bytes);
        var lines = PartCodec.Lines("20261120T165000Z-sqlvm01-0001", PartCodec.Gzip(bytes)).ToList();
        Assert.Equal(4, lines.Count);
        Assert.All(lines, l => Assert.True(l.Length <= RcaContract.MaximumLineLength));

        Assert.Throws<InvalidDataException>(() => PartCodec.Decode(lines.Skip(1)));
        Assert.Throws<InvalidDataException>(() => PartCodec.Decode([.. lines, lines[1]]));
        var tampered = lines.ToList();
        tampered[0] = tampered[0][..^8] + (tampered[0].EndsWith("AAAAAAAA", StringComparison.Ordinal) ? "BBBBBBBB" : "AAAAAAAA");
        Assert.Throws<InvalidDataException>(() => PartCodec.Decode(tampered));
    }

    [Fact]
    public async Task T1sExportHasTheFixturesHeaderCoverageAndFacts()
    {
        var fixture = Fixture("t1-blocking-chain");
        var store = Store(T1From, out var clock);

        var view = await ExportT1Async(store, clock);

        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Evidence, view.Json));
        AssertSameHeader(fixture, view);
        Assert.Equal(CoverageLines(fixture), CoverageLines(view));
        AssertFacts(T1Facts(fixture), T1Facts(view));

        // Session 71 held an X lock on [care].[appointments], with session 74 waiting LCK_M_IS behind it, at least at these
        // samples (the fixture also shows two formations' first samples, before their escalation's event).
        foreach (var document in new[] { fixture, view })
        {
            var t1 = document.Table("rca_sessions").Where(r => (string?)r["target"] == "T1").ToList();
            var holds = Times(t1.Where(r => (long)r["session_id"]! == 71 && (string?)r.GetValueOrDefault("lock_mode_held") == "X" && (string?)r.GetValueOrDefault("lock_resource_type") == "OBJECT" && (string?)r.GetValueOrDefault("lock_object") == "[care].[appointments]"), "captured_at_utc");
            var behind = Times(t1.Where(r => (long)r["session_id"]! == 74 && (string?)r.GetValueOrDefault("blocked_by") == "71" && (string?)r.GetValueOrDefault("wait_type") == "LCK_M_IS"), "captured_at_utc");
            Assert.Superset(EscalatorSamples.ToHashSet(), holds.ToHashSet());
            Assert.Superset(EscalatorSamples.ToHashSet(), behind.ToHashSet());
        }
        Assert.Equal(fixture.Root["tables"]!.AsObject().Select(t => t.Key).Order(StringComparer.Ordinal), view.Root["tables"]!.AsObject().Select(t => t.Key).Order(StringComparer.Ordinal));
        AssertFacts([.. fixture.Table("rca_events").Select(Line)], [.. view.Table("rca_events").Select(Line)]);
    }

    [Fact]
    public async Task T4sExportHasTheFixturesHeaderAndFactsForThePrimaryAndTheReplica()
    {
        var fixture = Fixture("t4-replica-lag");
        var store = Store(T1From, out var clock);
        await ExportT1Async(store, clock);
        var span = store.Open(T4From);
        var link = new ReplicaLink();
        await DriveAsync([new PgPrimaryObserver(T4Primary(clock), Options(), RunnerLog.Null, link), new PgReplicaObserver(T4Replica(clock), Options(), RunnerLog.Null, link)], span, clock, T4From, T4To, TestContext.Current.CancellationToken);
        span.Close(T4To);
        clock.Set(T4To.AddMinutes(2));

        var result = new Exporter(store, RunnerLog.Null, "1.0.0").Export(Session, final: true, TimeSpan.Zero);

        var view = Decode(store, Assert.Single(result.Documents));
        Assert.Equal("Pass", result.Status);
        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Evidence, view.Json));
        AssertSameHeader(fixture, view);
        AssertFacts(T4Facts(fixture), T4Facts(view));

        // The fixture's episode text leaves out RCA-PG-01, which the trigger table (rca/README.md) and the fixture's own
        // coverage include: the observer names every block its replay detail runs.
        AssertFacts([.. fixture.Table("rca_events").Select(Line).Select(l => l.Replace("replay detail (RCA-PG-02, RCA-PG-06, RCA-PG-07)", "replay detail (RCA-PG-01, RCA-PG-02, RCA-PG-06, RCA-PG-07)", StringComparison.Ordinal))], [.. view.Table("rca_events").Select(Line)]);

        // The observer runs more of the catalog's blocks than the fixture shows (the WAL rate's RCA-PG-04, the replica's
        // own counters and WAL receiver): every source the fixture names is there, and both targets were captured.
        var expected = fixture.Table("rca_coverage").ToDictionary(r => (string)r["target"]!);
        foreach (var row in view.Table("rca_coverage"))
        {
            var target = (string)row["target"]!;
            Assert.Equal(true, row["captured"]);
            Assert.Null(row.GetValueOrDefault("gaps"));
            Assert.Equal(expected[target]["window_start_utc"], row["window_start_utc"]);
            Assert.Equal(expected[target]["window_end_utc"], row["window_end_utc"]);
            Assert.Superset(((string)expected[target]["sources"]!).Split(',').ToHashSet(), ((string)row["sources"]!).Split(',').ToHashSet());
        }
    }

    [Fact]
    public async Task TheIndexLineValidatesAgainstTheTransportSchemaAndItsPartsComeBack()
    {
        var store = Store(T1From, out var clock);
        var span = store.Open(T1From);
        await DriveAsync([T1Observer(RcaSimulation.T1(clock))], span, clock, T1From, T1To, TestContext.Current.CancellationToken);
        span.Close(T1To);
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0");

        var result = exporter.Export(Session, final: true, TimeSpan.Zero);

        var line = result.IndexLine();
        Assert.StartsWith(RcaContract.IndexMarker + " ", line, StringComparison.Ordinal);
        Assert.True(line.Length <= RcaContract.MaximumLineLength);
        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Transport, line[(RcaContract.IndexMarker.Length + 1)..]));
        var document = Assert.Single(result.Documents);
        var parts = Enumerable.Range(1, document.Parts).Select(i => exporter.Part(document.DocumentId, i)!).ToList();
        Assert.All(parts, part => Assert.Matches(new Regex(RcaSchemas.PartLinePattern()), part));
        Assert.Equal(document.Sha256, Assert.Single(PartCodec.Decode(parts)).Sha256);
        Assert.Null(exporter.Part(document.DocumentId, document.Parts + 1));
        Assert.Null(exporter.Part(document.DocumentId, 0));
        Assert.Null(exporter.Part("20261120T165000Z-nohost-0009", 1));
        Assert.Null(exporter.Part("..\\..\\secrets", 1));
    }

    [Fact]
    public void ExportsAreIncrementalAndATargetsWindowsNeverOverlap()
    {
        var store = Store(T1From, out var clock);
        var span = store.Open(T1From);
        span.Began("T1", T1From);
        WriteSentinel(span, T1From, T1From.AddMinutes(10));
        Watermark(span, clock, T1From.AddMinutes(10));
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0");

        var first = Decode(store, Assert.Single(exporter.Export(Session, final: false, TimeSpan.Zero).Documents));
        WriteSentinel(span, T1From.AddMinutes(10), T1From.AddMinutes(20));
        Watermark(span, clock, T1From.AddMinutes(20));
        var second = Decode(store, Assert.Single(exporter.Export(Session, final: false, TimeSpan.Zero).Documents));
        var nothing = exporter.Export(Session, final: false, TimeSpan.Zero);

        var firstWindow = Assert.Single(first.Table("rca_coverage"));
        var secondWindow = Assert.Single(second.Table("rca_coverage"));
        Assert.Equal(T1From, firstWindow["window_start_utc"]);
        Assert.Equal(T1From.AddMinutes(10), firstWindow["window_end_utc"]);
        Assert.Equal(firstWindow["window_end_utc"], secondWindow["window_start_utc"]);
        Assert.Equal(T1From.AddMinutes(20), secondWindow["window_end_utc"]);
        Assert.Equal(true, secondWindow["captured"]);
        Assert.Equal(20, first.Table("rca_resource").Count);
        Assert.Equal(20, second.Table("rca_resource").Count);
        Assert.Equal(1, first.Root["sequence"]!.GetValue<int>());
        Assert.Equal(2, second.Root["sequence"]!.GetValue<int>());
        Assert.Equal("20261120T170000Z-sqlvm01-0002", second.Root["documentId"]!.GetValue<string>());
        Assert.Empty(nothing.Documents);
        Assert.Equal("Not selected", nothing.Status);
    }

    [Fact]
    public void ASpanKeepsTheSessionItsFirstExportWasForAndAnUnboundOneTakesTheCallers()
    {
        var store = Store(T1From, out var clock);
        var span = store.Open(T1From);
        span.Began("T1", T1From);
        WriteSentinel(span, T1From, T1From.AddMinutes(5));
        Watermark(span, clock, T1From.AddMinutes(5));
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0");
        exporter.Export(Session, final: false, TimeSpan.Zero);
        WriteSentinel(span, T1From.AddMinutes(5), T1From.AddMinutes(8));
        span.Close(T1From.AddMinutes(8));
        var unbound = store.Open(T1From.AddMinutes(9));
        unbound.Began("T1", T1From.AddMinutes(9));
        WriteSentinel(unbound, T1From.AddMinutes(9), T1From.AddMinutes(11));
        unbound.Close(T1From.AddMinutes(11));
        clock.Set(T1From.AddMinutes(12));

        var later = exporter.Export(null, final: true, TimeSpan.Zero).Documents.Select(d => Decode(store, d)).ToList();

        Assert.Equal(2, later.Count);
        Assert.Equal(Session, later[0].Root["sessionId"]!.GetValue<string>());
        Assert.Null(later[1].Root["sessionId"]);
        Assert.Equal(2, later[0].Root["sequence"]!.GetValue<int>());
        Assert.Equal(1, later[1].Root["sequence"]!.GetValue<int>());
        Assert.All(store.Spans(), s => Assert.True(s.Export.Complete));
    }

    [Fact]
    public void ARowThatArrivesAfterItsWindowWasExportedIsLeftOutAndCounted()
    {
        var store = Store(T1From, out var clock);
        var span = store.Open(T1From);
        span.Began("T1", T1From);
        WriteSentinel(span, T1From, T1From.AddMinutes(5));
        Watermark(span, clock, T1From.AddMinutes(5));
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0");
        exporter.Export(Session, final: false, TimeSpan.Zero);

        span.Write(Resource(T1From.AddMinutes(2), 1));
        WriteSentinel(span, T1From.AddMinutes(5), T1From.AddMinutes(7));
        span.Close(T1From.AddMinutes(7));
        var result = exporter.Export(Session, final: true, TimeSpan.Zero);

        Assert.Equal("Warning", result.Status);
        Assert.Contains("1 row(s) arrived after their window was exported.", result.Message, StringComparison.Ordinal);
        var view = Decode(store, Assert.Single(result.Documents));
        Assert.Contains("1 row(s) arrived after their window was exported, so they were left out.", (string)Assert.Single(view.Table("rca_coverage"))["gaps"]!, StringComparison.Ordinal);
        Assert.DoesNotContain(view.Table("rca_resource"), r => (DateTimeOffset)r["at_utc"]! < T1From.AddMinutes(5));
    }

    [Fact]
    public void ASessionsExportAfterAnExportWithNoSessionStartsEveryTargetThereEvenOneWhoseWatermarkLags()
    {
        // fc: Run all started with the VM running, so its start's export had no session, and T3's resource stats, read every
        // 30 minutes, were complete only to 16:00. The re-check's document began there, and the runbook left all of it out
        // as from before the session, T1's first half hour of the session with it.
        var (store, clock, span, exporter) = StartWithTheVmRunning();
        ReadT3(span, clock, At(16, 0, 15), At(16, 30, 0));
        WriteSentinel(span, At(16, 25, 30), At(16, 56, 0));
        Mark(span, clock, "T1", At(16, 56, 0), At(16, 56, 5));
        clock.Set(At(16, 56, 10));

        var recheck = exporter.Export(Session, final: false, TimeSpan.Zero);

        Assert.Equal("Pass", recheck.Status);
        var view = Decode(store, Assert.Single(recheck.Documents));
        Assert.Equal("20261120T162520Z-sqlvm01-0002", view.Root["documentId"]!.GetValue<string>());
        // The runbook keeps a document of the session's only when it starts at most 2 minutes before the session was accepted.
        Assert.True(WindowStart(view) >= SessionAccepted.AddMinutes(-2));
        Assert.Equal(Every(At(16, 25, 30), At(16, 55, 30), 30), ResourceTimes(view, "T1"));
        Assert.Equal(Every(At(16, 25, 30), At(16, 29, 45), 15), ResourceTimes(view, "T3"));

        // What T3 reads after the re-check is the session's, and none of it is left out.
        ReadT3(span, clock, At(16, 30, 15), At(17, 0, 0));
        WriteSentinel(span, At(16, 56, 0), At(17, 26, 0));
        span.Close(At(17, 26, 0));
        clock.Set(At(17, 26, 10));
        var stop = Decode(store, Assert.Single(exporter.Export(Session, final: true, TimeSpan.Zero).Documents));
        Assert.Equal(Every(At(16, 30, 0), At(17, 0, 0), 15), ResourceTimes(stop, "T3"));
        Assert.Equal(Every(At(16, 56, 0), At(17, 25, 30), 30), ResourceTimes(stop, "T1"));
    }

    [Fact]
    public void InA30MinuteSessionTheStopIsTheFirstExportAndStartsAtTheExportWithNoSession()
    {
        // No re-check runs, so the stop's export began at T3's 16:00, and the runbook left out all of the VM's capture.
        var (store, clock, span, exporter) = StartWithTheVmRunning();
        ReadT3(span, clock, At(16, 0, 15), At(16, 30, 0));
        WriteSentinel(span, At(16, 25, 30), At(16, 55, 0));
        span.Close(At(16, 55, 0));
        clock.Set(At(16, 55, 10));

        var stop = exporter.Export(Session, final: true, TimeSpan.Zero);

        Assert.Equal("Pass", stop.Status);
        var view = Decode(store, Assert.Single(stop.Documents));
        Assert.Equal(SessionlessExport, WindowStart(view));
        Assert.Equal(Every(At(16, 25, 30), At(16, 54, 30), 30), ResourceTimes(view, "T1"));
        Assert.Equal(Every(At(16, 25, 30), At(16, 30, 0), 15), ResourceTimes(view, "T3"));
    }

    [Fact]
    public void ALaggingTargetWithNothingNewAtTheSessionsFirstExportStartsAtTheExportWithNoSessionAtItsNext()
    {
        var (store, clock, span, exporter) = StartWithTheVmRunning();
        WriteSentinel(span, At(16, 25, 30), At(16, 46, 0));
        Mark(span, clock, "T1", At(16, 46, 0), At(16, 46, 5));
        clock.Set(At(16, 46, 10));
        var recheck = Decode(store, Assert.Single(exporter.Export(Session, final: false, TimeSpan.Zero).Documents));
        Assert.Empty(ResourceTimes(recheck, "T3"));

        ReadT3(span, clock, At(16, 0, 15), At(16, 50, 0));
        WriteSentinel(span, At(16, 46, 0), At(17, 16, 0));
        span.Close(At(17, 16, 0));
        clock.Set(At(17, 16, 10));
        var stop = Decode(store, Assert.Single(exporter.Export(Session, final: true, TimeSpan.Zero).Documents));

        Assert.Equal(SessionlessExport, WindowStart(stop));
        Assert.Equal(Every(At(16, 25, 30), At(16, 50, 0), 15), ResourceTimes(stop, "T3"));
    }

    [Fact]
    public void AnExportWithNoSessionStillTakesALaggingTargetFromWhereItsLastWindowEnded()
    {
        // The scripts' saves export with no session too: what T3 reads after one of them goes into the next one whole.
        var (store, clock, span, exporter) = StartWithTheVmRunning();
        ReadT3(span, clock, At(16, 0, 15), At(16, 30, 0));
        clock.Set(At(16, 31, 0));

        var save = Decode(store, Assert.Single(exporter.Export(null, final: false, TimeSpan.Zero).Documents));

        Assert.Equal(At(16, 0, 0), WindowStart(save));
        Assert.Equal(Every(At(16, 0, 15), At(16, 29, 45), 15), ResourceTimes(save, "T3"));
    }

    [Fact]
    public void ATimeTheSentinelDidntSampleOrATargetWasntObservedIsAGapAndNotCaptured()
    {
        var store = Store(T1From, out var clock);
        var span = store.Open(T1From);
        span.Began("T1", T1From);
        WriteSentinel(span, T1From, T1From.AddMinutes(3));
        WriteSentinel(span, T1From.AddMinutes(6), T1From.AddMinutes(8));
        span.Ended("T1", T1From.AddMinutes(8));
        span.Began("T1", T1From.AddMinutes(12));
        WriteSentinel(span, T1From.AddMinutes(12), T1From.AddMinutes(14));
        span.Close(T1From.AddMinutes(14));
        clock.Set(T1From.AddMinutes(15));

        var view = Decode(store, Assert.Single(new Exporter(store, RunnerLog.Null, "1.0.0").Export(Session, final: true, TimeSpan.Zero).Documents));

        var coverage = Assert.Single(view.Table("rca_coverage"));
        Assert.Equal(false, coverage["captured"]);
        Assert.Equal(["Not observed from 16:58:00 to 17:02:00 UTC.", "The sentinel didn't sample from 16:52:30 to 16:56:00 UTC."], ((string)coverage["gaps"]!).Split('\n'));
    }

    [Fact]
    public void OverItsBudgetTheReducerCutsInReversePriorityAndSaysSoInCoverage()
    {
        var store = Store(T1From, out var clock);
        var span = store.Open(T1From);
        span.Began("T1", T1From);
        var random = new Random(7);
        span.Write(Capture(T1From.AddSeconds(5), "escalated", "T1-20261120T165005Z"));
        for (var at = T1From.AddSeconds(5); at < T1From.AddMinutes(60); at = at.AddSeconds(10))
        {
            for (var session = 0; session < 12; session++)
            {
                span.Write(new CaptureRow(RcaContract.Sessions, "T1", at, "RCA-SQL-01,RCA-SQL-02")
                    .Set("captured_at_utc", at).Set("target", "T1").Set("session_id", 60L + session).Set("blocked_by", session == 0 ? null : "60")
                    .Set("wait_type", "LCK_M_U").Set("wait_ms", (long)random.Next(100, 60000)).Set("is_demo", true)
                    .Set("statement_text", "UPDATE care.t" + random.Next(100000).ToString(CultureInfo.InvariantCulture) + " SET x = ? WHERE id = @id" + random.Next(100000).ToString(CultureInfo.InvariantCulture)));
            }
        }

        WriteSentinel(span, T1From, T1From.AddMinutes(60));
        span.Close(T1From.AddMinutes(60));
        clock.Set(T1From.AddMinutes(61));

        var result = new Exporter(store, RunnerLog.Null, "1.0.0").Export(Session, final: true, TimeSpan.Zero);

        var document = Assert.Single(result.Documents);
        Assert.True(store.ReadDocument(document.DocumentId)!.Length <= Exporter.SingleTargetBudget);
        Assert.True(document.Parts <= 14);
        Assert.Contains("export budget cut(s), recorded as gaps in RCA Coverage.", result.Message, StringComparison.Ordinal);
        var view = Decode(store, document);
        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Evidence, view.Json));
        var gaps = ((string)Assert.Single(view.Table("rca_coverage"))["gaps"]!).Split('\n');
        Assert.StartsWith("export budget: blocking samples thinned to 1 in 2 inside each chain formation", gaps[0], StringComparison.Ordinal);
        Assert.All(gaps, g => Assert.StartsWith("export budget: ", g, StringComparison.Ordinal));
        Assert.Contains(view.Table("rca_events"), e => (string?)e["kind"] == "capture");
        Assert.Equal(120, view.Table("rca_resource").Count);

        // The first, peak, and last samples of the chain always stay.
        var samples = view.Table("rca_sessions").Select(r => (DateTimeOffset)r["captured_at_utc"]!).Distinct().Order().ToList();
        Assert.Equal(T1From.AddSeconds(5), samples[0]);
        Assert.Equal(T1From.AddMinutes(60).AddSeconds(-5), samples[^1]);
    }

    [Fact]
    public void PastTheRowLimitTheReducerCutsInsteadOfThrowing()
    {
        // Review of 4e7817b: about 4 hours of sqlvm01's capture between exports passes 20,000 RCA Resource rows; the
        // reducer measured the document before it checked the limit, and the encoder threw.
        var store = Store(T1From, out var clock);
        var span = store.Open(T1From);
        span.Began("T1", T1From);
        for (var i = 0; i < 20_100; i++)
        {
            span.Write(Resource(T1From.AddSeconds(i), 0));
        }

        span.Close(T1From.AddSeconds(20_100));
        clock.Set(T1From.AddSeconds(20_100).AddMinutes(1));

        var result = new Exporter(store, RunnerLog.Null, "1.0.0").Export(Session, final: true, TimeSpan.Zero);

        var view = Decode(store, Assert.Single(result.Documents));
        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Evidence, view.Json));
        Assert.InRange(view.Table("rca_resource").Count, 1, 10_050);
        Assert.Contains("export budget: the sentinel's counter samples outside capture episodes thinned to 1 in 2", (string)Assert.Single(view.Table("rca_coverage"))["gaps"]!, StringComparison.Ordinal);
    }

    [Fact]
    public void PastTheStringLimitTheReducerCutsInsteadOfThrowing()
    {
        // 10,500 blocking rows, each with its own statement and wait resource: 21,000 strings, past a document's 20,000.
        var store = Store(T1From, out var clock);
        var span = store.Open(T1From);
        span.Began("T1", T1From);
        var random = new Random(11);
        for (var i = 0; i < 10_500; i++)
        {
            span.Write(Blocked(T1From.AddSeconds(i), random).Set("wait_resource", "KEY: 5:72057594045071360 (" + Hex(random, 6) + ")"));
        }

        WriteSentinel(span, T1From, T1From.AddSeconds(10_500));
        span.Close(T1From.AddSeconds(10_500));
        clock.Set(T1From.AddSeconds(10_500).AddMinutes(1));

        var result = new Exporter(store, RunnerLog.Null, "1.0.0").Export(Session, final: true, TimeSpan.Zero);

        var view = Decode(store, Assert.Single(result.Documents));
        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Evidence, view.Json));
        Assert.True(view.Strings.Count <= RcaContract.MaximumStrings);
        Assert.Contains("export budget: blocking samples thinned to 1 in 2", (string)Assert.Single(view.Table("rca_coverage"))["gaps"]!, StringComparison.Ordinal);
    }

    [Fact]
    public void EvenPastItsEssentialsTheReducerMakesADocumentThatFits()
    {
        // The last cuts: 21,000 deadlocks with their graphs, past the row limit after every other cut. The graphs go, then
        // the deadlocks are halved until the document fits its budget; the coverage row stays.
        var from = T1From;
        var rows = Enumerable.Range(0, 21_000).Select(i => new CaptureRow(RcaContract.Events, "T1", from.AddSeconds(i), "RCA-XE-01,RCA-XE-02")
            .Set("event_time_utc", from.AddSeconds(i)).Set("target", "T1").Set("kind", "deadlock").Set("event_name", "xml_deadlock_report")
            .Set("session_id", 60L + (i % 40)).Set("event_count", 1L).Set("deadlock_json", "{\"victim\":" + (60 + (i % 40)).ToString(CultureInfo.InvariantCulture) + ",\"n\":" + i.ToString(CultureInfo.InvariantCulture) + "}")
            .Set("detail", "Deadlock " + i.ToString(CultureInfo.InvariantCulture) + ": a victim was chosen.")).ToList();
        var to = from.AddSeconds(21_000);
        var capture = new TargetCapture("T1", from, to, rows, [], [(from, to)]);
        var header = new DocumentHeader("20261120T165000Z-sqlvm01-0001", Session, "sqlvm01", "1.0.0", to, 1, true, from, to, ["T1"]);
        int Measure(Dictionary<string, List<CaptureRow>> tables) => PartCodec.Gzip(EvidenceDocument.Write(header, tables, [])).Length;

        var reduced = Reducer.Reduce([capture], Measure, 20 * 1024);

        Assert.True(EvidenceDocument.WithinLimits(reduced.Tables));
        Assert.True(Measure(reduced.Tables) <= 20 * 1024);
        var deadlocks = reduced.Tables[RcaContract.Events];
        Assert.InRange(deadlocks.Count, 1, 10_500);
        Assert.All(deadlocks, d => Assert.Null(d.Get("deadlock_json")));
        Assert.Equal(from, deadlocks[0].At);
        var gaps = (string)Assert.Single(reduced.Tables[RcaContract.Coverage]).Get("gaps")!;
        Assert.Contains("export budget: the graphs of 21000 deadlock(s) left out", gaps, StringComparison.Ordinal);
        Assert.Contains("export budget: deadlock rows halved (10500 of 21000 kept).", gaps, StringComparison.Ordinal);
        Assert.Equal(21_000, rows.Count(r => r.Get("deadlock_json") is not null));
    }

    [Fact]
    public void AFailingSpanIsAWarningAndTheSpansAroundItStillExportAndAreIndexed()
    {
        // Review of 4e7817b: a span the export couldn't make a document of stopped the export, so the spans after it
        // waited forever, and the documents it had already written were marked exported but missing from the index.
        var store = Store(T1From, out var clock);
        SpanWriter Span(DateTimeOffset from, bool broken)
        {
            var span = store.Open(from);
            span.Began("T1", from);
            WriteSentinel(span, from, from.AddMinutes(5));
            if (broken)
            {
                // A row without its required metric: the encoder refuses the span's document.
                span.Write(new CaptureRow(RcaContract.Resource, "T1", from.AddMinutes(1), "RCA-SQL-09").Set("at_utc", from.AddMinutes(1)).Set("target", "T1").Set("source", "RCA-SQL-09").Set("value", 1.0));
            }

            span.Close(from.AddMinutes(5));
            return span;
        }

        var good = Span(T1From, broken: false);
        var bad = Span(T1From.AddMinutes(10), broken: true);
        var later = Span(T1From.AddMinutes(20), broken: false);
        clock.Set(T1From.AddMinutes(30));
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0");

        var result = exporter.Export(Session, final: true, TimeSpan.Zero);

        Assert.Equal("Warning", result.Status);
        Assert.Equal(["20261120T165000Z-sqlvm01-0001", "20261120T171000Z-sqlvm01-0002"], result.Documents.Select(d => d.DocumentId));
        Assert.All(result.Documents, d => Assert.Empty(RcaSchemas.Errors(RcaSchemas.Evidence, Decode(store, d).Json)));
        Assert.Contains($"Span {bad.Id} couldn't be exported (rca_resource.metric is required, and a row has no value.); the next export tries it again.", result.Message, StringComparison.Ordinal);
        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Transport, result.IndexLine()[(RcaContract.IndexMarker.Length + 1)..]));
        var spans = store.Spans().ToDictionary(s => s.Id);
        Assert.True(spans[good.Id].Export.Complete);
        Assert.False(spans[bad.Id].Export.Bound);
        Assert.Empty(spans[bad.Id].Export.Documents);
        Assert.True(spans[later.Id].Export.Complete);

        // With nothing else to export, the span that still fails is a Fail, and the command's exit code says so.
        var again = exporter.Export(Session, final: true, TimeSpan.Zero);
        var (exit, output, _) = CliHarness.Invoke("rca", "export", "--session", Session, "--rca-store", root);

        Assert.Equal("Fail", again.Status);
        Assert.Empty(again.Documents);
        Assert.StartsWith("No evidence document was exported. Span " + bad.Id, again.Message, StringComparison.Ordinal);
        Assert.Equal(1, exit);
        Assert.Contains("\"status\":\"Fail\"", output, StringComparison.Ordinal);
    }

    [Fact]
    public void ExportsOutsideAControlSessionEachHaveTheBudgetToThemselves()
    {
        // Review of 4e7817b: every rca export --session none added to one running total that was never reset, so after
        // about 56 KiB on sqlvm01 (24 KiB in T2's guest) each sessionless document was cut to the 2 KiB minimum.
        var store = Store(T1From, out var clock);
        var span = store.Open(T1From);
        span.Began("T1", T1From);
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0");
        var random = new Random(5);
        var sizes = new List<int>();
        for (var export = 0; export < 6; export++)
        {
            var from = T1From.AddMinutes(10 * export);
            WriteSentinel(span, from, from.AddMinutes(10));
            for (var i = 0; i < 600; i++)
            {
                span.Write(Blocked(from.AddSeconds(i), random));
            }

            Watermark(span, clock, from.AddMinutes(10));
            var document = Assert.Single(exporter.Export(null, final: false, TimeSpan.Zero).Documents);
            var view = Decode(store, document);

            Assert.Null(view.Root["sessionId"]);
            Assert.Equal(600, view.Table("rca_sessions").Count);
            Assert.Null(Assert.Single(view.Table("rca_coverage")).GetValueOrDefault("gaps"));
            sizes.Add(store.ReadDocument(document.DocumentId)!.Length);
        }

        // Together they're past what one session's budget allows on a host that observes one target.
        Assert.True(sizes.Sum() > Exporter.SingleTargetBudget, string.Join(", ", sizes));
    }

    [Fact]
    public void IdenticalEventsInAMinuteBecomeOneCountedRowAndOthersStayAsTheyAre()
    {
        var minute = new DateTimeOffset(2026, 11, 20, 16, 53, 0, TimeSpan.Zero);
        CaptureRow Error(int second, long session, string code = "1222") => new CaptureRow(RcaContract.Events, "T1", minute.AddSeconds(second), "RCA-XE-02")
            .Set("event_time_utc", minute.AddSeconds(second)).Set("target", "T1").Set("kind", "error").Set("event_name", "error_reported")
            .Set("session_id", session).Set("code", code).Set("severity", 16).Set("intercepted", true).Set("event_count", 1L).Set("detail", "Lock request time out period exceeded.");

        var rows = Reducer.Aggregate([Error(5, 64), Error(14, 65), Error(23, 64), Error(40, 66, "1205"), Error(70, 64), Capture(minute.AddSeconds(30), "escalated", "T1-x")]);

        Assert.Equal(4, rows.Count);
        var counted = Assert.Single(rows, r => (string?)r.Get("code") == "1222" && r.At == minute);
        Assert.Equal(3L, counted.Get("event_count"));
        Assert.Equal(minute, counted.Get("event_time_utc"));
        Assert.Null(counted.Get("session_id"));
        var next = Assert.Single(rows, r => (string?)r.Get("code") == "1222" && r.At != minute);
        Assert.Equal(minute.AddSeconds(70), next.At);
        Assert.Equal(64L, next.Get("session_id"));
        var single = Assert.Single(rows, r => (string?)r.Get("code") == "1205");
        Assert.Equal(minute.AddSeconds(40), single.At);
        Assert.Equal(66L, single.Get("session_id"));
    }

    [Fact]
    public void TheAnswerKeyStaysInItsOwnSectionWithItsOwnStrings()
    {
        var store = Store(T1From, out var clock);
        var span = store.Open(T1From);
        span.Began("T1", T1From);
        WriteSentinel(span, T1From, T1From.AddMinutes(5));
        var result = new Runs.RunResult
        {
            RunId = "20261120165200-t1-a1b2c3",
            ScenarioId = "blocking-chain",
            Target = DemoTarget.T1,
            Status = "Completed",
            Result = "Pass",
            Outcome = "Completed",
            StartedAt = T1From.AddMinutes(2),
            EndedAt = T1From.AddMinutes(4),
            Concurrency = 8,
            Intensity = 8,
            Parameters = new Dictionary<string, string>(StringComparer.Ordinal) { ["holdSeconds"] = "90", ["depth"] = "4" },
        };
        Sql.RunEvent[] events = [new(T1From.AddMinutes(2), "run-begin", 63, "Deadline."), new(T1From.AddMinutes(3), "lock-escalation", 71, "10000 rows updated in one statement; table lock: yes.")];
        foreach (var row in Rca.AnswerKey.AnswerKeyRecorder.Rows(DemoTarget.T1, result, events))
        {
            Assert.True(store.AppendAnswerKey(row));
        }

        span.Close(T1From.AddMinutes(5));
        clock.Set(T1From.AddMinutes(6));

        var view = Decode(store, Assert.Single(new Exporter(store, RunnerLog.Null, "1.0.0").Export(Session, final: true, TimeSpan.Zero).Documents));

        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Evidence, view.Json));
        var key = view.AnswerKey();
        Assert.Equal(2, key.Count);
        var run = Assert.Single(key, r => (string?)r["kind"] == "run");
        Assert.Equal("blocking-chain", run["scenario"]);
        Assert.Equal("20261120165200-t1-a1b2c3", run["scenario_run_id"]);
        Assert.Equal(ApplicationNames.RunToken("20261120165200-t1-a1b2c3"), run["run_token"]);
        Assert.Equal("Completed", run["outcome"]);
        Assert.Equal("concurrency=8; intensity=8; depth=4; holdSeconds=90", run["detail"]);
        Assert.Equal("lock-escalation", Assert.Single(key, r => (string?)r["kind"] == "run-event")["event_name"]);
        Assert.DoesNotContain(view.Strings, s => s.Contains("blocking-chain", StringComparison.Ordinal) || s.Contains("a1b2c3", StringComparison.Ordinal));
        Assert.Contains("blocking-chain", view.AnswerKeyStrings);
    }

    [Fact]
    public void RetentionDeletesASpan7DaysAfterItsExportAndAnUnexportedOneAfter30()
    {
        var store = Store(T1From, out var clock);
        var exported = store.Open(T1From);
        exported.Began("T1", T1From);
        WriteSentinel(exported, T1From, T1From.AddMinutes(2));
        exported.Close(T1From.AddMinutes(2));
        clock.Set(T1From.AddMinutes(3));
        var document = Assert.Single(new Exporter(store, RunnerLog.Null, "1.0.0").Export(Session, final: true, TimeSpan.Zero).Documents);
        File.SetLastWriteTimeUtc(Path.Combine(store.ExportsDirectory, document.DocumentId + ".gz"), clock.Now.UtcDateTime);
        var unexported = store.Open(T1From.AddHours(1));
        unexported.Began("T1", T1From.AddHours(1));
        unexported.Close(T1From.AddHours(2));

        Assert.Equal(0, store.Cleanup(T1From.AddDays(6), RunnerLog.Null));
        Assert.Equal(2, store.Spans().Count);
        Assert.NotNull(store.ReadDocument(document.DocumentId));
        Assert.Equal(1, store.Cleanup(T1From.AddDays(7).AddMinutes(4), RunnerLog.Null));
        Assert.Null(store.ReadDocument(document.DocumentId));
        Assert.Single(store.Spans());
        Assert.Equal(1, store.Cleanup(T1From.AddDays(31), RunnerLog.Null));
        Assert.Empty(store.Spans());
    }

    [Fact]
    public void ATargetsStoreFileStopsAtItsCapWithOneGap()
    {
        var clock = new ManualTime(T1From);
        var store = new EvidenceStore(root, clock, targetCap: 4096, host: "sqlvm01");
        var span = store.Open(T1From);
        span.Began("T1", T1From);

        WriteSentinel(span, T1From, T1From.AddHours(2));
        span.Close(T1From.AddHours(2));

        var path = SpanWriter.FileFor(span.Directory, "T1");
        Assert.Single(File.ReadAllLines(path), l => l.Contains("The observer's store reached its", StringComparison.Ordinal));
        Assert.True(new FileInfo(path).Length < 4096 + 512);
    }

    [Fact]
    public void TheDefaultStoreIsOnlyForSystemAndAdministrators()
    {
        Assert.SkipUnless(OperatingSystem.IsWindows(), "The store's folder permissions are Windows ACLs.");
#pragma warning disable CA1416 // Windows only: skipped above elsewhere.
        var store = new EvidenceStore(Path.Combine(root, "secure"), TimeProvider.System, secure: true);

        store.EnsureRoot();

        var folder = new DirectoryInfo(store.Root);
        try
        {
            var acl = folder.GetAccessControl();
            var rules = acl.GetAccessRules(true, true, typeof(System.Security.Principal.SecurityIdentifier)).Cast<System.Security.AccessControl.FileSystemAccessRule>().ToList();
            Assert.True(acl.AreAccessRulesProtected);
            Assert.Equal(
                new[] { System.Security.Principal.WellKnownSidType.BuiltinAdministratorsSid, System.Security.Principal.WellKnownSidType.LocalSystemSid }.Select(s => new System.Security.Principal.SecurityIdentifier(s, null).Value).Order(StringComparer.Ordinal),
                rules.Select(r => r.IdentityReference.Value).Distinct().Order(StringComparer.Ordinal));
            Assert.All(rules, r => Assert.Equal(System.Security.AccessControl.FileSystemRights.FullControl, r.FileSystemRights & System.Security.AccessControl.FileSystemRights.FullControl));
        }
        finally
        {
            // The test's own user isn't SYSTEM or an Administrator: give the folder back so it can be deleted.
            var open = new System.Security.AccessControl.DirectorySecurity();
            open.AddAccessRule(new System.Security.AccessControl.FileSystemAccessRule(System.Security.Principal.WindowsIdentity.GetCurrent().User!, System.Security.AccessControl.FileSystemRights.FullControl, System.Security.AccessControl.InheritanceFlags.ContainerInherit | System.Security.AccessControl.InheritanceFlags.ObjectInherit, System.Security.AccessControl.PropagationFlags.None, System.Security.AccessControl.AccessControlType.Allow));
            folder.SetAccessControl(open);
        }
#pragma warning restore CA1416
    }

    [Fact]
    public void TheExportCommandPrintsOneIndexLineAndItsExitCodeSaysWhatHappened()
    {
        var (bad, badOutput, _) = CliHarness.Invoke("rca", "export", "--session", "not-a-session", "--rca-store", root);
        var (none, noneOutput, _) = CliHarness.Invoke("rca", "export", "--session", "none", "--rca-store", root);
        var (missing, _, missingError) = CliHarness.Invoke("rca", "part", "--document", "20261120T165000Z-sqlvm01-0001", "--part", "1", "--rca-store", root);
        var noSession = CliHarness.ParseErrors("rca", "export");

        Assert.Equal(1, bad);
        Assert.Contains("\"status\":\"Fail\"", badOutput, StringComparison.Ordinal);
        Assert.Equal(2, none);
        Assert.Single(noneOutput.Split('\n', StringSplitOptions.RemoveEmptyEntries));
        Assert.StartsWith("DBHUBDEMO-RCA-INDEX {\"kind\":\"ContosoCare.RcaExportIndex\",\"version\":1,\"documents\":[],\"status\":\"Not selected\"", noneOutput, StringComparison.Ordinal);
        Assert.Empty(RcaSchemas.Errors(RcaSchemas.Transport, noneOutput.Trim()[(RcaContract.IndexMarker.Length + 1)..]));
        Assert.Equal(1, missing);
        Assert.Contains("No part 1", missingError, StringComparison.Ordinal);
        Assert.NotEmpty(noSession);
        Assert.False(Directory.Exists(root));
    }

    [Fact]
    public void TheExportAndPartCommandsHaveTheContractsShapes()
    {
        var start = DateTimeOffset.FromUnixTimeSeconds(DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 600);
        var store = Store(start, out _);
        var span = store.Open(start);
        span.Began("T1", start);
        WriteSentinel(span, start, start.AddMinutes(3));
        span.Close(start.AddMinutes(3));

        var (exit, output, _) = CliHarness.Invoke("rca", "export", "--session", Session, "--final", "--wait-seconds", "0", "--rca-store", root);
        var index = JsonNode.Parse(output.Trim()[(RcaContract.IndexMarker.Length + 1)..])!;
        var documentId = index["documents"]![0]!["documentId"]!.GetValue<string>();
        var (partExit, part, _) = CliHarness.Invoke("rca", "part", "--document", documentId, "--part", "1", "--rca-store", root);
        var (againExit, again, _) = CliHarness.Invoke("rca", "export", "--session", Session, "--final", "--wait-seconds", "0", "--rca-store", root);

        Assert.Equal(0, exit);
        Assert.Equal("Pass", index["status"]!.GetValue<string>());
        Assert.Equal(0, partExit);
        Assert.Matches(new Regex(RcaSchemas.PartLinePattern()), part.Trim());
        Assert.Single(part.Split('\n', StringSplitOptions.RemoveEmptyEntries));
        Assert.Equal(2, againExit);
        Assert.Contains("\"status\":\"Not selected\"", again, StringComparison.Ordinal);
    }

    /// <summary>Drives T1's simulation into the store, closes its span at 17:05, and exports it as the fixture's export 1.</summary>
    private static async Task<EvidenceView> ExportT1Async(EvidenceStore store, ManualTime clock)
    {
        var span = store.Open(T1From);
        await DriveAsync([T1Observer(RcaSimulation.T1(clock))], span, clock, T1From, T1To, TestContext.Current.CancellationToken);
        span.Close(T1To);
        clock.Set(T1To.AddSeconds(30));
        var result = new Exporter(store, RunnerLog.Null, "1.0.0").Export(Session, final: false, TimeSpan.Zero);
        Assert.Equal("Pass", result.Status);
        return Decode(store, Assert.Single(result.Documents));
    }

    private static EvidenceView Fixture(string name) => new(File.ReadAllText(RepositoryPaths.Combine("rca", "fixtures", name + ".evidence.json")));

    private static void AssertSameHeader(EvidenceView expected, EvidenceView actual)
    {
        foreach (var property in new[] { "kind", "version", "documentId", "sessionId", "producer", "sequence", "final", "windowStartUtc", "windowEndUtc", "targets", "epochUtc" })
        {
            Assert.True(JsonNode.DeepEquals(expected.Root[property], actual.Root[property]), $"{property}: expected {expected.Root[property]?.ToJsonString()}, got {actual.Root[property]?.ToJsonString()}");
        }
    }

    /// <summary>Every line that differs, in full, so one run shows all of them.</summary>
    private static void AssertFacts(List<string> expected, List<string> actual)
    {
        var differences = Enumerable.Range(0, Math.Max(expected.Count, actual.Count))
            .Where(i => i >= expected.Count || i >= actual.Count || !string.Equals(expected[i], actual[i], StringComparison.Ordinal))
            .Select(i => $"[{i}]{Environment.NewLine}  expected: {(i < expected.Count ? expected[i] : "(none)")}{Environment.NewLine}  actual:   {(i < actual.Count ? actual[i] : "(none)")}")
            .ToList();
        Assert.True(differences.Count == 0, string.Join(Environment.NewLine, differences));
    }

    private static List<string> CoverageLines(EvidenceView view) => [.. view.Table("rca_coverage").Select(Line)];

    /// <summary>One row as text, its columns in name order and nulls left out, for a readable comparison.</summary>
    private static string Line(Dictionary<string, object?> row) =>
        string.Join("; ", row.Where(c => c.Value is not null).OrderBy(c => c.Key, StringComparer.Ordinal).Select(c => c.Key + "=" + Text(c.Value)));

    private static string Text(object? value) => value switch
    {
        DateTimeOffset at => at.UtcDateTime.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture),
        double number => number.ToString("0.###", CultureInfo.InvariantCulture),
        _ => Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty,
    };

    /// <summary>
    /// What a blind RCA finds in T1's document (rca/fixtures/README.md): the samples, peak, formations, head blocker,
    /// branches, the escalating session, the escalations, the lock timeouts, and the capture episode. Taken the same way
    /// from the fixture and from the export, so the export reproduces the fixture's facts.
    /// </summary>
    private static List<string> T1Facts(EvidenceView view)
    {
        var sessions = view.Table("rca_sessions").Where(r => (string?)r["target"] == "T1").ToList();
        var blocked = sessions.Where(r => r.GetValueOrDefault("blocked_by") is not null).ToList();
        var chain = blocked.Where(r => (string?)r.GetValueOrDefault("wait_type") == "LCK_M_U").ToList();
        var samples = Times(sessions, "captured_at_utc");
        var peak = blocked.GroupBy(r => (DateTimeOffset)r["captured_at_utc"]!).OrderByDescending(g => g.Count()).ThenBy(g => g.Key).First();
        var facts = new List<string>
        {
            $"blocking samples {samples.Count} from {Text(samples[0])} to {Text(samples[^1])} in {Formations(samples)} formations",
            $"peak {peak.Count()} blocked at {Text(peak.Key)}",
        };

        var heads = Heads(sessions);
        facts.Add("heads " + string.Join(",", heads));
        var head = sessions.Where(r => (long)r["session_id"]! == 63).ToList();
        var first = head.OrderBy(r => (DateTimeOffset)r["captured_at_utc"]!).First();
        facts.Add(string.Join("; ", T1HeadColumns.Select(c => c + "=" + Text(first.GetValueOrDefault(c)))));
        facts.Add($"head idle up to {head.Max(r => (long?)r.GetValueOrDefault("idle_ms"))} ms; run tokens {string.Join(",", head.Select(r => r.GetValueOrDefault("run_token")).Distinct())}");
        facts.Add("edges at peak " + string.Join(",", peak.OrderBy(r => (long)r["session_id"]!).Select(r => $"{r["session_id"]}->{r["blocked_by"]} {r.GetValueOrDefault("wait_type")} {r.GetValueOrDefault("lock_mode_wanted")}")));
        facts.Add($"longest chain wait {chain.Max(r => (long?)r.GetValueOrDefault("wait_ms"))} ms");
        facts.Add("statements " + string.Join(" | ", chain.Select(r => r.GetValueOrDefault("statement_text")).Distinct().Order()));


        var events = view.Table("rca_events").Where(r => (string?)r["target"] == "T1").ToList();
        facts.Add("escalations " + string.Join(" | ", events.Where(e => (string?)e["kind"] == "escalation").Select(e => $"{Text(e["event_time_utc"])} {e.GetValueOrDefault("session_id")} {e.GetValueOrDefault("object_name")} {e.GetValueOrDefault("lock_mode")} {e.GetValueOrDefault("detail")}")));
        var timeouts = events.Where(e => (string?)e["kind"] == "error" && (string?)e.GetValueOrDefault("code") == "1222").ToList();
        facts.Add($"lock timeouts {timeouts.Sum(e => (long)e["event_count"]!)}: " + string.Join(",", timeouts.GroupBy(e => Minute((DateTimeOffset)e["event_time_utc"]!)).OrderBy(g => g.Key).Select(g => $"{Text(g.Key)} x{g.Sum(e => (long)e["event_count"]!)}")));
        facts.Add("timeout shape " + string.Join(" | ", timeouts.Select(e => $"{e.GetValueOrDefault("severity")} {e.GetValueOrDefault("intercepted")} {e.GetValueOrDefault("module_name")} {e.GetValueOrDefault("program_name")} {e.GetValueOrDefault("detail")}").Distinct()));
        facts.Add("episodes " + string.Join(" | ", events.Where(e => (string?)e["kind"] == "capture").Select(e => $"{e["event_name"]} {e["code"]} {Text(e["event_time_utc"])}")));
        return facts;
    }

    /// <summary>What a blind RCA finds in T4's document: the chain under the idle transaction, the replica's stall and what replay waited for, and the primary's shipping.</summary>
    private static List<string> T4Facts(EvidenceView view)
    {
        var sessions = view.Table("rca_sessions").Where(r => (string?)r["target"] == "T4").ToList();
        var blocked = sessions.Where(r => r.GetValueOrDefault("blocked_by") is not null).ToList();
        var samples = Times(sessions, "captured_at_utc");
        var facts = new List<string>
        {
            $"T4 blocking samples {samples.Count} from {Text(samples[0])} to {Text(samples[^1])} in {Formations(samples)} formations",
            "T4 heads " + string.Join(",", Heads(sessions)),
        };

        var head = sessions.Where(r => (long)r["session_id"]! == 20432).ToList();
        var first = head.OrderBy(r => (DateTimeOffset)r["captured_at_utc"]!).First();
        facts.Add(string.Join("; ", T4HeadColumns.Select(c => c + "=" + Text(first.GetValueOrDefault(c)))));
        facts.Add($"head idle up to {Text(head.Max(r => (long?)r.GetValueOrDefault("idle_ms")))} ms; locks on {string.Join(",", head.Select(r => r.GetValueOrDefault("lock_object")).Where(o => o is not null).Distinct().Order())}");
        facts.Add($"waiters {string.Join(",", blocked.Select(r => (long)r["session_id"]!).Distinct().Order())} on {string.Join(",", blocked.Select(r => r.GetValueOrDefault("wait_type")).Distinct())} up to {blocked.Max(r => (long?)r.GetValueOrDefault("wait_ms"))} ms");

        var replica = view.Table("rca_replica").Where(r => (string?)r["target"] == "T4-replica").OrderBy(r => (DateTimeOffset)r["at_utc"]!).ToList();
        var conflicts = replica.Where(r => r.GetValueOrDefault("conflict_wait_start_utc") is not null).ToList();
        facts.Add($"replay waited from {Text(conflicts.Min(r => (DateTimeOffset)r["conflict_wait_start_utc"]!))} for {string.Join(",", conflicts.Select(r => r.GetValueOrDefault("conflict_wanted_mode")).Distinct())} on {string.Join(",", conflicts.Select(r => r.GetValueOrDefault("conflict_relation")).Distinct())} behind {string.Join(",", conflicts.Select(r => $"{r.GetValueOrDefault("conflict_holder_session")} {r.GetValueOrDefault("conflict_holder_mode")} {r.GetValueOrDefault("conflict_holder_program")}").Distinct())}");
        var peak = replica.OrderByDescending(r => (double?)r.GetValueOrDefault("since_last_replayed_s") ?? 0).ThenBy(r => (DateTimeOffset)r["at_utc"]!).First();
        facts.Add($"peak {Text(peak["since_last_replayed_s"])} s at {Text(peak["at_utc"])} with {peak.GetValueOrDefault("received_not_replayed_bytes")} bytes");
        var resumed = replica.First(r => (DateTimeOffset)r["at_utc"]! > (DateTimeOffset)peak["at_utc"]! && (double?)r.GetValueOrDefault("since_last_replayed_s") < 5);
        facts.Add($"resumed at {Text(resumed["at_utc"])}");
        facts.Add($"cancelled {string.Join(",", replica.Select(r => r.GetValueOrDefault("conflicts_cancelled")).Where(v => v is not null).Distinct())}; max_standby_streaming_delay_s {string.Join(",", replica.Select(r => Text(r.GetValueOrDefault("max_standby_streaming_delay_s"))).Where(v => v.Length > 0).Distinct())}");
        var stalled = replica.Where(r => (double?)r.GetValueOrDefault("since_last_replayed_s") >= 30).ToList();
        facts.Add("stalled at " + string.Join(",", stalled.Select(r => $"{Text(r["at_utc"])}={Text(r["since_last_replayed_s"])}")));

        var primary = view.Table("rca_replica").Where(r => (string?)r["target"] == "T4").ToList();
        facts.Add("primary rows at " + string.Join(",", Times(primary, "at_utc").Select(t => Text(t))));
        facts.Add($"primary write lag up to {Text(primary.Max(r => (double?)r.GetValueOrDefault("write_lag_s")))} s, flush lag up to {Text(primary.Max(r => (double?)r.GetValueOrDefault("flush_lag_s")))} s, WAL {string.Join(",", primary.Select(r => Text(r.GetValueOrDefault("wal_bytes_per_s"))).Where(v => v.Length > 0).Distinct())} bytes/s");

        var events = view.Table("rca_events").Where(r => (string?)r["kind"] == "capture").ToList();
        facts.Add("episodes " + string.Join(" | ", events.Select(e => $"{e["target"]} {e["event_name"]} {e["code"]} {Text(e["event_time_utc"])}")));
        return facts;
    }

    /// <summary>The sessions that block others and wait on nobody, by session ID.</summary>
    private static List<long> Heads(List<Dictionary<string, object?>> sessions)
    {
        var blockers = sessions.Where(r => r.GetValueOrDefault("blocked_by") is string).Select(r => (string)r["blocked_by"]!).ToHashSet(StringComparer.Ordinal);
        return [.. sessions.Where(r => r.GetValueOrDefault("blocked_by") is null && blockers.Contains(Convert.ToString(r["session_id"], CultureInfo.InvariantCulture)!)).Select(r => (long)r["session_id"]!).Distinct().Order()];
    }

    private static List<DateTimeOffset> Times(IEnumerable<Dictionary<string, object?>> rows, string column) => [.. rows.Select(r => (DateTimeOffset)r[column]!).Distinct().Order()];

    /// <summary>Runs of samples at most 15 s apart.</summary>
    private static int Formations(List<DateTimeOffset> samples) => samples.Count == 0 ? 0 : 1 + samples.Zip(samples.Skip(1)).Count(p => p.Second - p.First > TimeSpan.FromSeconds(15));

    private static DateTimeOffset Minute(DateTimeOffset at) => new(at.Year, at.Month, at.Day, at.Hour, at.Minute, 0, TimeSpan.Zero);

    private EvidenceStore Store(DateTimeOffset start, out ManualTime clock)
    {
        clock = new ManualTime(start);
        return new EvidenceStore(root, clock, host: "sqlvm01");
    }

    private static EvidenceView Decode(EvidenceStore store, ExportedDocument document)
    {
        var gzip = store.ReadDocument(document.DocumentId)!;
        Assert.Equal(document.Sha256, PartCodec.Sha256(gzip));
        Assert.Equal(document.Parts, PartCodec.PartCount(gzip.Length));
        return new EvidenceView(System.Text.Encoding.UTF8.GetString(PartCodec.Gunzip(gzip)));
    }

    /// <summary>Moves the clock past the span's 5-second persist interval and sets the target's watermark, as the observer does each tick.</summary>
    private static void Watermark(SpanWriter span, ManualTime clock, DateTimeOffset complete)
    {
        clock.Set(complete.AddSeconds(10));
        span.Watermark("T1", complete);
        clock.Set(complete.AddMinutes(1));
    }

    private static void WriteSentinel(SpanWriter sink, DateTimeOffset from, DateTimeOffset to)
    {
        for (var at = from; at < to; at = at.AddSeconds(30))
        {
            sink.Write(Resource(at, 0));
        }
    }

    /// <summary>
    /// fc's start: the observer has captured T1 and T3 since 16:00 for activity outside a Run all session, and T3, whose
    /// resource stats it reads every 30 minutes, is complete only to 16:00. The session is accepted at 16:24:29, and its
    /// start's export, with no session because the VM ran before it, takes T1 to its watermark at 16:25:20.
    /// </summary>
    private (EvidenceStore Store, ManualTime Clock, SpanWriter Span, Exporter Exporter) StartWithTheVmRunning()
    {
        var store = Store(At(16, 0, 0), out var clock);
        var span = store.Open(At(16, 0, 0));
        span.Began("T1", At(16, 0, 0));
        span.Began("T3", At(16, 0, 0));
        Mark(span, clock, "T3", At(16, 0, 0), At(16, 0, 22));
        WriteSentinel(span, At(16, 0, 0), At(16, 25, 10));
        Mark(span, clock, "T1", At(16, 25, 10), At(16, 25, 15));
        clock.Set(SessionlessExport);
        var exporter = new Exporter(store, RunnerLog.Null, "1.0.0");
        Assert.Equal("20261120T160000Z-sqlvm01-0001", Assert.Single(exporter.Export(null, final: false, TimeSpan.Zero).Documents).DocumentId);
        return (store, clock, span, exporter);
    }

    /// <summary>Sets a target's watermark with the clock at <paramref name="now"/>, at least 5 s after the span last wrote span.json.</summary>
    private static void Mark(SpanWriter span, ManualTime clock, string target, DateTimeOffset complete, DateTimeOffset now)
    {
        clock.Set(now);
        span.Watermark(target, complete);
    }

    /// <summary>One read of T3's resource stats: a row every 15 s from <paramref name="from"/> to <paramref name="to"/>, and T3 complete to <paramref name="to"/> 22 s later.</summary>
    private static void ReadT3(SpanWriter span, ManualTime clock, DateTimeOffset from, DateTimeOffset to)
    {
        foreach (var at in Every(from, to, 15))
        {
            span.Write(Resource(at, 0, "T3"));
        }

        Mark(span, clock, "T3", to, to.AddSeconds(22));
    }

    private static List<DateTimeOffset> Every(DateTimeOffset from, DateTimeOffset to, int seconds)
    {
        var times = new List<DateTimeOffset>();
        for (var at = from; at <= to; at = at.AddSeconds(seconds))
        {
            times.Add(at);
        }

        return times;
    }

    private static List<DateTimeOffset> ResourceTimes(EvidenceView view, string target) =>
        [.. view.Table("rca_resource").Where(r => (string?)r["target"] == target).Select(r => (DateTimeOffset)r["at_utc"]!).Order()];

    private static DateTimeOffset WindowStart(EvidenceView view) =>
        DateTimeOffset.Parse(view.Root["windowStartUtc"]!.GetValue<string>(), CultureInfo.InvariantCulture);

    private static CaptureRow Resource(DateTimeOffset at, double value, string target = "T1") =>
        new CaptureRow(RcaContract.Resource, target, at, "RCA-SQL-09", sentinel: true)
            .Set("at_utc", at).Set("target", target).Set("source", "RCA-SQL-09").Set("metric", "processes_blocked").Set("value", value).Set("unit", "count");

    /// <summary>A session blocked by session 60, with a statement of its own: one string the dictionary can't share.</summary>
    private static CaptureRow Blocked(DateTimeOffset at, Random random) =>
        new CaptureRow(RcaContract.Sessions, "T1", at, "RCA-SQL-01,RCA-SQL-02")
            .Set("captured_at_utc", at).Set("target", "T1").Set("session_id", 61L).Set("blocked_by", "60").Set("wait_type", "LCK_M_U").Set("is_demo", true)
            .Set("statement_text", "UPDATE care.work_queues SET note = ? WHERE id = @id" + Hex(random, 8));

    private static string Hex(Random random, int bytes)
    {
        var buffer = new byte[bytes];
        random.NextBytes(buffer);
        return Convert.ToHexStringLower(buffer);
    }

    private static CaptureRow Capture(DateTimeOffset at, string name, string code) =>
        new CaptureRow(RcaContract.Events, "T1", at, "observer")
            .Set("event_time_utc", at).Set("target", "T1").Set("kind", "capture").Set("event_name", name).Set("code", code).Set("event_count", 1L).Set("detail", "processes_blocked 1 >= 1.");
}
