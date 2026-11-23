using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.Sidecar;
using Json.Schema;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The sidecar's codec (rca/README.md, The sidecar, Part lines, and Limits): the encoder against the contract's three
/// fixture sidecars and sidecar.schema.json; the same bytes from the same draft; the reducer at a document's 64 KiB and
/// in its cut order (L1); a host's session budget (L2); the page index for 0 to 17 sidecars (L6); and the part lines.
/// </summary>
public sealed class RcaSidecarCodecTests
{
    private const string Session = "5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21";

    private const string Target = "T3";

    private const int Intervals = 8;

    private const int Plans = 2;

    private static readonly DateTimeOffset Window = new(2026, 11, 20, 15, 0, 0, TimeSpan.Zero);

    /// <summary>A host name that makes the contract's longest sidecar ID, 88 characters.</summary>
    private static readonly string LongestHost = new('h', 58);

    private static readonly string[] Fixtures = ["t3-plan-regression", "t4-query-store", "t4-connection-surge"];

    private static readonly string[] IndexProperties = ["kind", "version", "page", "pages", "documents", "status"];

    private static readonly string[] WaitCategories = ["CPU", "Buffer IO", "Parallelism", "Lock", "Network IO", "Memory"];

    private static readonly string[] VmTargets = ["T1", "T3", "T4", "T4-replica", "T5"];

    private static readonly string[] GuestTargets = ["T2"];

    private static readonly string[] GuestTargetsAndT5 = ["T2", "T5"];

    // A registry of its own: JsonSchema.Net registers a schema by its $id, once per registry.
    private static readonly Lazy<JsonSchema> SidecarSchema = new(() =>
        JsonSchema.FromText(File.ReadAllText(RepositoryPaths.Combine("rca", "sidecar.schema.json")), new BuildOptions { SchemaRegistry = new SchemaRegistry() }));

    private static readonly Lazy<Regex> SidecarPartLine = new(() => new Regex(TransportPattern("sidecarPartLine"), RegexOptions.CultureInvariant));

    private static readonly Lazy<Regex> EvidencePartLine = new(() => new Regex(RcaSchemas.PartLinePattern(), RegexOptions.CultureInvariant));

    /// <summary>Base64's alphabet at random: text that gzip barely shrinks, to size a sidecar to the byte.</summary>
    private static readonly Lazy<string> PaddingText = new(() =>
    {
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        var random = new Random(1234);
        return new string([.. Enumerable.Range(0, 64_000).Select(_ => alphabet[random.Next(alphabet.Length)])]);
    });

    private static readonly ConcurrentDictionary<(int Bytes, int Seed), SidecarDraft> SizedDrafts = new();

    [Theory]
    [InlineData("t3-plan-regression")]
    [InlineData("t4-query-store")]
    [InlineData("t4-connection-surge")]
    public void AFixtureSidecarAsADraftEncodesToItsDocumentAndItsParts(string fixture)
    {
        var expected = JsonNode.Parse(File.ReadAllText(FixturePath(fixture, ".sidecar.json")))!;
        var draft = FixtureDraft(fixture);

        var json = SidecarDocument.Write(draft);

        AssertSameDocument(expected, json);
        Assert.Empty(RcaSchemas.Errors(SidecarSchema, Encoding.UTF8.GetString(json)));

        // The fixture's part lines carry the same document as the runner's. Their bytes are illustrative (rca/fixtures):
        // the fixtures' generator wrote doubles with ".0" and gzipped at the default level.
        var fixtureLines = File.ReadAllLines(FixturePath(fixture, ".sidecar-parts.txt")).Where(l => l.Length > 0).ToList();
        AssertPartLines(draft.DocumentId, fixtureLines);
        AssertSameDocument(expected, PartCodec.Gunzip(Decode(fixtureLines)));
        var gzip = PartCodec.Gzip(json);
        var lines = SidecarParts.Lines(draft.DocumentId, gzip);
        AssertPartLines(draft.DocumentId, lines);
        Assert.Equal(gzip, Decode([.. lines.Reverse()]));
    }

    [Fact]
    public void TheSameDraftGivesTheSameBytesAndTheSameSha256()
    {
        var reducer = new SidecarReducer();
        foreach (var fixture in Fixtures)
        {
            var draft = FixtureDraft(fixture);
            var json = SidecarDocument.Write(draft);

            // Built again, and with its tables and each row's values added in reverse: the same bytes.
            Assert.Equal(json, SidecarDocument.Write(FixtureDraft(fixture)));
            Assert.Equal(json, SidecarDocument.Write(Reversed(draft)));
            var reduced = reducer.Reduce(draft, SidecarBudget.MultiTargetSessionBytes);
            Assert.Empty(reduced.Cuts);
            Assert.Equal(json, reduced.Json);
            Assert.Equal(PartCodec.Gzip(json), reduced.Gzip);
            Assert.Equal(PartCodec.Sha256(reduced.Gzip), reduced.Sha256);
        }

        // With cuts of every kind.
        var budget = Gzip(Generated(Intervals, 12, Plans)).Length / 3;
        var first = reducer.Reduce(Generated(Intervals, 12, Plans), budget);
        var second = new SidecarReducer().Reduce(Generated(Intervals, 12, Plans), budget);
        Assert.NotEmpty(first.Cuts);
        Assert.Equal(first.Cuts, second.Cuts);
        Assert.Equal(first.Json, second.Json);
        Assert.Equal(first.Gzip, second.Gzip);
        Assert.Equal(first.Sha256, second.Sha256);
    }

    [Fact]
    public void ASidecarAt64KiBOfGzipIsKeptWholeAndOneByteOverIsCutToFit()
    {
        var reducer = new SidecarReducer();
        var at = Sized(SidecarBudget.DocumentBytes);
        var over = Sized(SidecarBudget.DocumentBytes + 1);

        var whole = reducer.Reduce(at, int.MaxValue);

        Assert.Empty(whole.Cuts);
        Assert.Equal(SidecarDocument.Write(at), whole.Json);
        Assert.Equal(65_536, whole.Gzip.Length);
        Assert.Equal(28, whole.Parts);
        Assert.Equal(SidecarParts.MaximumIdLength, at.DocumentId.Length);
        AssertPartLines(at.DocumentId, SidecarParts.Lines(at.DocumentId, whole.Gzip));

        var cut = reducer.Reduce(over, int.MaxValue);

        Assert.InRange(cut.Gzip.Length, 1, 65_536);
        Assert.InRange(cut.Parts, 1, 28);
        Assert.StartsWith("wait categories past each plan's three largest", Assert.Single(CutLines(cut)), StringComparison.Ordinal);
        var view = new SidecarView(cut.Json);
        AssertCutsAreGaps(cut, view);
        Assert.Empty(RcaSchemas.Errors(SidecarSchema, Encoding.UTF8.GetString(cut.Json)));

        // Only waits went: each plan keeps three of its wait categories, with every interval's rows of each, and every
        // statistic and plan summary stays.
        var kept = view.Table(RcaContract.QueryWaits);
        Assert.InRange(kept.Count, 1, over.Tables[RcaContract.QueryWaits].Count - 1);
        foreach (var plan in kept.GroupBy(w => ((long)w["query_id"]!, (long)w["plan_id"]!)))
        {
            var categories = plan.GroupBy(w => (string)w["wait_category"]!).ToList();
            Assert.InRange(categories.Count, 1, 3);
            Assert.All(categories, c => Assert.Equal(
                over.Tables[RcaContract.QueryWaits].Count(w => ((long)w.Get("query_id")!, (long)w.Get("plan_id")!) == plan.Key && (string)w.Get("wait_category")! == c.Key),
                c.Count()));
        }

        Assert.Equal(over.Tables[RcaContract.QueryStats].Count, view.Table(RcaContract.QueryStats).Count);
        Assert.All(view.Table(RcaContract.QueryPlans), p => Assert.NotNull(p["plan_summary"]));
    }

    [Fact]
    public void TheFirstCutKeepsEachPlansThreeLargestWaitCategoriesInEveryInterval()
    {
        // T3's plan waits on CPU most, across 40 intervals; Buffer IO, Lock, and Parallelism tie for the other two places,
        // which go to the categories that sort first; Network IO's one spike is the largest row, but not a largest
        // category. T4's waits are its events: two of Lock's, LWLock's, and IO's, whose events count apart.
        var t3 = new List<(string Category, string? Event, Func<int, double> Waited)>
        {
            ("CPU", null, i => 100 + i), ("Buffer IO", null, _ => 50), ("Lock", null, _ => 50), ("Parallelism", null, _ => 50),
            ("Network IO", null, i => i == 7 ? 1_400 : 0),
        };
        var t4 = new List<(string Category, string? Event, Func<int, double> Waited)>
        {
            ("Lock", "transactionid", _ => 40), ("Lock", "tuple", _ => 30), ("LWLock", "LockManager", _ => 20), ("IO", "WALSync", _ => 10),
        };
        var draft = Waiting(40, ("T3", t3), ("T4", t4));

        var reduced = new SidecarReducer().Reduce(draft, Gzip(draft).Length - 1);

        Assert.Collection(
            reduced.Cuts,
            cut => Assert.StartsWith("T3: " + SidecarReducer.GapPrefix + "wait categories past each plan's three largest", cut, StringComparison.Ordinal),
            cut => Assert.StartsWith("T4: " + SidecarReducer.GapPrefix + "wait events past each plan's three largest", cut, StringComparison.Ordinal));
        var waits = new SidecarView(reduced.Json).Table(RcaContract.QueryWaits);
        Assert.Equal(
            ["T3 Buffer IO  40", "T3 CPU  40", "T3 Lock  40", "T4 LWLock LockManager 40", "T4 Lock transactionid 40", "T4 Lock tuple 40"],
            waits.GroupBy(w => $"{w["target"]} {w["wait_category"]} {w.GetValueOrDefault("wait_event")}").Select(g => g.Key + " " + g.Count().ToString(CultureInfo.InvariantCulture)).Order(StringComparer.Ordinal));
    }

    [Fact]
    public void AForcedPlanThatEventsNameKeepsItsSummaryLongest()
    {
        // T3's fixture: plan 31 is the last good plan, forced, and every tuning event names it. At every budget, from one
        // byte under the whole to the floor, it never loses its summary while another plan keeps its own, and at some
        // budget it keeps its summary after the regressed plan 58 has lost its own.
        var draft = FixtureDraft("t3-plan-regression");
        var reducer = new SidecarReducer();
        var outlived = false;
        for (var budget = Gzip(draft).Length - 1; budget >= SidecarBudget.MinimumDocumentBytes; budget -= 4)
        {
            var plans = new SidecarView(reducer.Reduce(draft, budget).Json).Table(RcaContract.QueryPlans);
            var forced = plans.Where(p => (long)p["plan_id"]! == 31).Select(p => p.GetValueOrDefault("plan_summary")).ToList();
            var others = plans.Where(p => (long)p["plan_id"]! != 31).ToList();
            if (forced.Any(s => s is null))
            {
                Assert.All(others, p => Assert.Null(p.GetValueOrDefault("plan_summary")));
            }

            outlived |= forced.All(s => s is not null) && others.Any(p => (long)p["plan_id"]! == 58 && p.GetValueOrDefault("plan_summary") is null);
        }

        Assert.True(outlived, "No budget left plan 31's summary after plan 58's was cut.");
    }

    [Fact]
    public void TheReducerCutsInTheContractsOrderAndEachOnlyAsFarAsItMust()
    {
        var reducer = new SidecarReducer();
        var draft = Generated(Intervals, 12, Plans);

        // The lowest-ranked query, 11, has a forced plan, and a plan an event names: their summaries go last.
        draft.Tables[RcaContract.QueryPlans].Single(p => (long)p.Get("plan_id")! == 10_111L).Set("is_forced_plan", true).Set("forcing_type", "AUTO");
        draft.Tables[RcaContract.QueryEvents].Add(Row(RcaContract.QueryEvents, Window.AddMinutes(20))
            .Set("event_time_utc", Window.AddMinutes(20))
            .Set("kind", "tuning")
            .Set("query_id", 1011L)
            .Set("plan_id", 10_110L)
            .Set("state", "Active")
            .Set("detail", "FORCE_LAST_GOOD_PLAN for query 1011: plan 10110."));
        static bool Kept(Dictionary<string, object?> plan) => QueryIndex(plan) == 11;
        var whole = Gzip(draft).Length;
        var statistics = draft.Tables[RcaContract.QueryStats].Count;
        Assert.InRange(whole, 8 * 1024, SidecarBudget.DocumentBytes);

        // 1. A byte less than the whole: each plan's wait categories past its three largest, and nothing else.
        var waits = reducer.Reduce(draft, whole - 1);
        Assert.StartsWith("wait categories past each plan's three largest", Assert.Single(CutLines(waits)), StringComparison.Ordinal);

        // 2. A byte less than that: plan summaries too, the lowest-ranked queries' first, except the forced and the
        // named plans, and still every statistic.
        var summaries = reducer.Reduce(draft, waits.Gzip.Length - 1);
        Assert.Collection(
            CutLines(summaries),
            line => Assert.StartsWith("wait categories past each plan's three largest", line, StringComparison.Ordinal),
            line => Assert.StartsWith("plan summaries left out for ", line, StringComparison.Ordinal));
        var summarized = new SidecarView(summaries.Json);
        var plans = summarized.Table(RcaContract.QueryPlans);
        Assert.All(plans.Where(Kept), p => Assert.NotNull(p["plan_summary"]));
        var nulled = plans.Where(p => !Kept(p) && p["plan_summary"] is null).Select(QueryIndex).ToList();
        var described = plans.Where(p => !Kept(p) && p["plan_summary"] is not null).Select(QueryIndex).ToList();
        Assert.NotEmpty(nulled);
        Assert.NotEmpty(described);
        Assert.True(nulled.Min() >= described.Max(), "A higher-ranked query's plan lost its summary before a lower-ranked query's.");
        Assert.Equal(statistics, summarized.Table(RcaContract.QueryStats).Count);

        // 3. A third of the whole: every plan summary, then the lowest-ranked queries, all of a query's rows in its interval.
        var budget = whole / 3;
        var queries = reducer.Reduce(draft, budget);
        Assert.InRange(queries.Gzip.Length, 1, budget);
        Assert.Collection(
            CutLines(queries),
            line => Assert.StartsWith("wait categories past each plan's three largest", line, StringComparison.Ordinal),
            line => Assert.StartsWith("every plan summary left out", line, StringComparison.Ordinal),
            line => Assert.StartsWith("the lowest-ranked queries left out", line, StringComparison.Ordinal));
        var view = new SidecarView(queries.Json);
        var stats = view.Table(RcaContract.QueryStats);
        Assert.InRange(stats.Count, 1, statistics - 1);
        foreach (var interval in stats.GroupBy(s => (DateTimeOffset)s["interval_start_utc"]!))
        {
            // In each interval the top-ranked queries stay: query 0, 1, and on, none missing in between.
            var left = interval.Select(QueryIndex).Distinct().Order().ToList();
            Assert.Equal(Enumerable.Range(0, left.Count), left);
        }

        // A query's waits go with its interval's statistics, and its plans with its last interval, except a forced plan and a
        // plan an event names.
        var queried = stats.Select(s => ((DateTimeOffset)s["interval_start_utc"]!, QueryIndex(s))).ToHashSet();
        Assert.All(view.Table(RcaContract.QueryWaits), w => Assert.Contains(((DateTimeOffset)w["interval_start_utc"]!, QueryIndex(w)), queried));
        Assert.DoesNotContain(11, stats.Select(QueryIndex));
        Assert.Equal([10_110L, 10_111L], view.Table(RcaContract.QueryPlans).Where(Kept).Select(p => (long)p["plan_id"]!).Order());
        Assert.All(view.Table(RcaContract.QueryPlans).Where(p => !Kept(p)), p => Assert.Contains(QueryIndex(p), stats.Select(QueryIndex)));
        foreach (var reduced in new[] { waits, summaries, queries })
        {
            AssertCutsAreGaps(reduced, new SidecarView(reduced.Json));
            Assert.Empty(RcaSchemas.Errors(SidecarSchema, Encoding.UTF8.GetString(reduced.Json)));
        }
    }

    [Fact]
    public void AHostsSessionBudgetIs64KiBWhenItObservesSeveralTargetsAnd32KiBWhenItObservesOne()
    {
        Assert.Equal(64 * 1024, SidecarBudget.ForHost(VmTargets));
        Assert.Equal(32 * 1024, SidecarBudget.ForHost(GuestTargets));
        Assert.Equal(32 * 1024, SidecarBudget.ForHost(GuestTargetsAndT5));
        var reducer = new SidecarReducer();

        foreach (var (budget, size) in new[] { (SidecarBudget.ForHost(VmTargets), 40_000), (SidecarBudget.ForHost(GuestTargets), 20_000) })
        {
            var draft = Sized(size);
            var used = budget - size;

            // At the budget: the session's earlier sidecars on this host left exactly this one's size.
            var at = reducer.Reduce(draft, budget - used);
            Assert.Empty(at.Cuts);
            Assert.Equal(size, at.Gzip.Length);

            // A byte over it: cut, in the contract's order, to what's left.
            var over = reducer.Reduce(draft, budget - used - 1);
            Assert.StartsWith("wait categories past each plan's three largest", CutLines(over)[0], StringComparison.Ordinal);
            Assert.InRange(over.Gzip.Length, 1, size - 1);
            AssertCutsAreGaps(over, new SidecarView(over.Json));
        }

        // A sidecar that T1's VM keeps whole is cut to 32 KiB in T2's guest.
        var large = Sized(40_000);
        Assert.Empty(reducer.Reduce(large, SidecarBudget.MultiTargetSessionBytes).Cuts);
        Assert.InRange(reducer.Reduce(large, SidecarBudget.SingleTargetSessionBytes).Gzip.Length, 1, SidecarBudget.SingleTargetSessionBytes);

        // Two sidecars of one session on T1's VM: the second gets what the first left, and the two fit the host's budget.
        var first = reducer.Reduce(large, SidecarBudget.MultiTargetSessionBytes);
        var second = reducer.Reduce(Sized(40_000, seed: 12), SidecarBudget.MultiTargetSessionBytes - first.Gzip.Length);
        Assert.NotEmpty(second.Cuts);
        Assert.InRange(first.Gzip.Length + second.Gzip.Length, 1, SidecarBudget.MultiTargetSessionBytes);

        // The budget used up: the sidecar still holds its coverage, which says what was left out.
        var spent = reducer.Reduce(large, 0);
        var view = new SidecarView(spent.Json);
        Assert.InRange(spent.Gzip.Length, 1, SidecarBudget.MinimumDocumentBytes);
        Assert.Equal("READ_WRITE", Assert.Single(view.Table(RcaContract.QueryCoverage))["state"]);
        AssertCutsAreGaps(spent, view);
        Assert.Empty(RcaSchemas.Errors(SidecarSchema, Encoding.UTF8.GetString(spent.Json)));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(8)]
    [InlineData(9)]
    [InlineData(17)]
    public void TheIndexListsEightSidecarsAPageWithinALineAndExitCode2ForNone(int count)
    {
        var sidecars = Enumerable.Range(0, count).Select(Sealed).ToList();
        Assert.All(sidecars, s => Assert.Equal(SidecarParts.MaximumIdLength, s.DocumentId.Length));
        var catalog = new FakeCatalog(sidecars, expiredUnread: 99_999);
        var pages = (count + 7) / 8;
        var offered = new List<string>();

        for (var page = 1; page <= pages + 1; page++)
        {
            var index = SidecarIndex.Page(catalog, page, sealedNow: []);
            var line = index.Line();

            Assert.Equal(page, index.Page);
            Assert.Equal(pages, index.Pages);
            Assert.Equal(count == 0 ? 2 : 0, index.ExitCode);
            Assert.InRange(line.Length, 1, RcaContract.MaximumLineLength);
            Assert.StartsWith(SidecarParts.IndexMarker + " {", line, StringComparison.Ordinal);
            var json = line[(SidecarParts.IndexMarker.Length + 1)..];
            Assert.Empty(RcaSchemas.Errors(RcaSchemas.Transport, json));
            Assert.Equal(page, JsonNode.Parse(json)!["page"]!.GetValue<int>());
            Assert.Equal(pages, JsonNode.Parse(json)!["pages"]!.GetValue<int>());
            Assert.Equal(page <= pages ? Math.Min(8, count - ((page - 1) * 8)) : 0, index.Documents.Count);
            offered.AddRange(index.Documents.Select(d => d.DocumentId));
        }

        // Every sidecar once, the oldest sealed first.
        Assert.Equal(sidecars.Select(s => s.DocumentId), offered);
    }

    [Fact]
    public void TheIndexMarksWhatThisCallSealedAsNewAndCountsWhatExpiredUnread()
    {
        var fixture = JsonNode.Parse(File.ReadAllText(FixturePath("sidecar-index", ".json")))!.AsObject();
        var listed = fixture["documents"]!.AsArray().Select(d => d!.AsObject()).ToList();
        var sidecars = listed.Select((d, i) => new SealedSidecar(
            d["documentId"]!.GetValue<string>(), d["sessionId"]?.GetValue<string>(), "span-" + i.ToString(CultureInfo.InvariantCulture), "sqlvm01", i + 1,
            Window, Window.AddMinutes(15), Window.AddMinutes(16 + i), d["parts"]!.GetValue<int>(), d["sha256"]!.GetValue<string>(), false, null)).ToList();
        var fresh = listed.Where(d => d["state"]!.GetValue<string>() == SidecarIndex.New).Select(d => d["documentId"]!.GetValue<string>()).ToList();

        var index = SidecarIndex.Page(new FakeCatalog(sidecars), 1, fresh);

        var actual = JsonNode.Parse(index.Line()[(SidecarParts.IndexMarker.Length + 1)..])!.AsObject();
        foreach (var property in IndexProperties)
        {
            Assert.True(JsonNode.DeepEquals(fixture[property], actual[property]), $"{property}: expected {fixture[property]?.ToJsonString()}, got {actual[property]?.ToJsonString()}");
        }

        Assert.StartsWith("3 sidecars: 1 new, and 2 pending", index.Message, StringComparison.Ordinal);

        // What expired unread is counted once, as a Warning, even with nothing to fetch.
        var catalog = new FakeCatalog(sidecars, expiredUnread: 2);
        var first = SidecarIndex.Page(catalog, 1, []);
        Assert.Equal("Warning", first.Status);
        Assert.Contains("2 sidecars expired unread", first.Message, StringComparison.Ordinal);
        var again = SidecarIndex.Page(catalog, 1, []);
        Assert.Equal("Pass", again.Status);
        Assert.DoesNotContain("expired", again.Message, StringComparison.Ordinal);
        var expired = SidecarIndex.Page(new FakeCatalog([], expiredUnread: 1), 1, []);
        Assert.Equal((2, "Warning"), (expired.ExitCode, expired.Status));
        Assert.Contains("1 sidecar expired unread", expired.Message, StringComparison.Ordinal);
        var nothing = SidecarIndex.Page(new FakeCatalog([]), 1, []);
        Assert.Equal((2, "Not selected", 0), (nothing.ExitCode, nothing.Status, nothing.Pages));
    }

    [Fact]
    public void RcaPartPrintsASealedSidecarsPartAndNothingForAnUnknownDocumentOrPart()
    {
        var draft = FixtureDraft("t3-plan-regression");
        var gzip = PartCodec.Gzip(SidecarDocument.Write(draft));
        var lines = SidecarParts.Lines(draft.DocumentId, gzip);
        var catalog = new FakeCatalog([], gzips: new Dictionary<string, byte[]>(StringComparer.Ordinal) { [draft.DocumentId] = gzip });

        Assert.Equal<string?>(lines, Enumerable.Range(1, lines.Count).Select(i => SidecarParts.Part(catalog, draft.DocumentId, i)));
        Assert.Null(SidecarParts.Part(catalog, draft.DocumentId, 0));
        Assert.Null(SidecarParts.Part(catalog, draft.DocumentId, lines.Count + 1));
        Assert.Null(SidecarParts.Part(catalog, "20261120T165000Z-sqlvm01-0009-sidecar", 1));

        // An evidence document's ID never reaches the sidecars' store, and a sidecar's part line never carries one.
        var evidenceId = draft.DocumentId[..^SidecarParts.Suffix.Length];
        Assert.Null(SidecarParts.Part(catalog, evidenceId, 1));
        Assert.Throws<ArgumentException>(() => SidecarParts.Line(evidenceId, gzip, 1));
    }

    [Fact]
    public void TheEncoderRefusesWhatASidecarNeverHoldsAndTheReducerGivesEachTargetItsCoverage()
    {
        var draft = FixtureDraft("t4-query-store");
        Assert.Throws<ArgumentException>(() => SidecarDocument.Write(draft with { DocumentId = draft.DocumentId[..^SidecarParts.Suffix.Length] }));
        var evidence = new Dictionary<string, List<CaptureRow>>(draft.Tables, StringComparer.Ordinal)
        {
            [RcaContract.Sessions] = [new CaptureRow(RcaContract.Sessions, "T4", Window, "test").Set("target", "T4")],
        };
        Assert.Throws<ArgumentException>(() => SidecarDocument.Write(draft with { Tables = evidence }));
        var uncovered = draft.Tables.Where(t => t.Key != RcaContract.QueryCoverage).ToDictionary(t => t.Key, t => t.Value, StringComparer.Ordinal);
        Assert.Throws<ArgumentException>(() => SidecarDocument.Write(draft with { Tables = uncovered }));

        // A target the draft has no coverage row for gets one that says so, so the sidecar is whole.
        var reduced = new SidecarReducer().Reduce(draft with { Tables = uncovered }, SidecarBudget.MultiTargetSessionBytes);
        var coverage = new SidecarView(reduced.Json).Table(RcaContract.QueryCoverage);
        Assert.Equal(["T4", "T4-replica"], coverage.Select(r => (string)r["target"]!));
        Assert.All(coverage, r => Assert.Equal(SidecarReducer.NoReadGap, r["gaps"]));
        Assert.Empty(RcaSchemas.Errors(SidecarSchema, Encoding.UTF8.GetString(reduced.Json)));
    }

    private static string FixturePath(string name, string suffix) => RepositoryPaths.Combine("rca", "fixtures", name + suffix);

    private static string TransportPattern(string definition)
    {
        using var schema = JsonDocument.Parse(File.ReadAllText(RepositoryPaths.Combine("rca", "transport.schema.json")));
        return schema.RootElement.GetProperty("$defs").GetProperty(definition).GetProperty("pattern").GetString()!;
    }

    private static DateTimeOffset Utc(JsonNode? node) => DateTimeOffset.Parse(node!.GetValue<string>(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);

    private static byte[] Gzip(SidecarDraft draft) => PartCodec.Gzip(SidecarDocument.Write(draft));

    private static string Id(DateTimeOffset start, string host, int sequence) =>
        string.Create(CultureInfo.InvariantCulture, $"{start.UtcDateTime:yyyyMMdd'T'HHmmss'Z'}-{host}-{sequence:D4}-sidecar");

    private static int QueryIndex(Dictionary<string, object?> row) => (int)((long)row["query_id"]! - 1000);

    /// <summary>The document equals the fixture: every field, table, string, and header time the same.</summary>
    private static void AssertSameDocument(JsonNode expected, byte[] json)
    {
        var actual = JsonNode.Parse(json)!;
        Assert.True(JsonNode.DeepEquals(expected, actual), $"Expected {expected.ToJsonString()}{Environment.NewLine}Actual {actual.ToJsonString()}");
    }

    /// <summary>Each line is a sidecar's part line of one document, never an evidence document's: within 3,400 ASCII characters.</summary>
    private static void AssertPartLines(string documentId, IReadOnlyList<string> lines)
    {
        Assert.All(lines, line =>
        {
            Assert.Matches(SidecarPartLine.Value, line);
            Assert.DoesNotMatch(EvidencePartLine.Value, line);
            Assert.False(line.StartsWith(RcaContract.PartMarker + " ", StringComparison.Ordinal));
            Assert.True(line.Length <= RcaContract.MaximumLineLength, $"A part line of {line.Length} characters.");
            Assert.All(line, c => Assert.True(c < 128));
            Assert.Equal(documentId, line.Split(' ')[2]);
            Assert.EndsWith("/" + lines.Count.ToString(CultureInfo.InvariantCulture), line.Split(' ')[3], StringComparison.Ordinal);
        });
    }

    /// <summary>A sidecar's gzip from its part lines, in any order: each part once, under one SHA-256 the bytes match.</summary>
    private static byte[] Decode(IReadOnlyList<string> lines)
    {
        var parts = lines.Select(l => l.Split(' ')).ToList();
        Assert.All(parts, p =>
        {
            Assert.Equal(6, p.Length);
            Assert.Equal(SidecarParts.Marker, p[0]);
            Assert.Equal("1", p[1]);
        });
        Assert.Single(parts.Select(p => p[2]).Distinct());
        Assert.Single(parts.Select(p => p[4]).Distinct());
        var ordered = parts
            .Select(p => (Index: int.Parse(p[3].Split('/')[0], CultureInfo.InvariantCulture), Count: int.Parse(p[3].Split('/')[1], CultureInfo.InvariantCulture), Data: p[5]))
            .OrderBy(p => p.Index)
            .ToList();
        Assert.Equal(Enumerable.Range(1, ordered[0].Count), ordered.Select(p => p.Index));
        var gzip = ordered.SelectMany(p => Convert.FromBase64String(p.Data)).ToArray();
        Assert.Equal(parts[0][4], PartCodec.Sha256(gzip));
        return gzip;
    }

    /// <summary>Each cut's line, after its target and the budget's prefix.</summary>
    private static List<string> CutLines(ReducedSidecar reduced) =>
        [.. reduced.Cuts.Select(c =>
        {
            Assert.StartsWith(Target + ": " + SidecarReducer.GapPrefix, c, StringComparison.Ordinal);
            return c[(Target.Length + 2 + SidecarReducer.GapPrefix.Length)..];
        })];

    /// <summary>Each cut is a line of its target's coverage gaps, in the order the cuts were made, and no other budget line is there.</summary>
    private static void AssertCutsAreGaps(ReducedSidecar reduced, SidecarView view)
    {
        Assert.NotEmpty(reduced.Cuts);
        var coverage = view.Table(RcaContract.QueryCoverage);
        foreach (var target in reduced.Cuts.Select(c => c[..c.IndexOf(':', StringComparison.Ordinal)]).Distinct(StringComparer.Ordinal))
        {
            var gaps = ((string?)Assert.Single(coverage, r => (string)r["target"]! == target)["gaps"] ?? string.Empty)
                .Split('\n')
                .Where(l => l.StartsWith(SidecarReducer.GapPrefix, StringComparison.Ordinal));
            Assert.Equal(reduced.Cuts.Where(c => c.StartsWith(target + ": ", StringComparison.Ordinal)).Select(c => c[(target.Length + 2)..]), gaps);
        }
    }

    /// <summary>A fixture sidecar as the draft the sealer would hand the reducer: its header, and its rows by table.</summary>
    private static SidecarDraft FixtureDraft(string fixture)
    {
        var view = new SidecarView(File.ReadAllBytes(FixturePath(fixture, ".sidecar.json")));
        var tables = new Dictionary<string, List<CaptureRow>>(StringComparer.Ordinal);
        foreach (var (name, _) in view.Root["tables"]!.AsObject())
        {
            tables[name] = [.. view.Table(name).Select(values =>
            {
                var at = (DateTimeOffset)(values.GetValueOrDefault("captured_at_utc") ?? values.GetValueOrDefault("event_time_utc") ?? values["window_start_utc"])!;
                var row = new CaptureRow(name, (string)values["target"]!, at, "fixture");
                foreach (var (column, value) in values)
                {
                    row.Set(column, value);
                }

                return row;
            })];
        }

        var producer = view.Root["producer"]!;
        return new SidecarDraft(
            view.Root["documentId"]!.GetValue<string>(),
            view.Root["sessionId"]?.GetValue<string>(),
            producer["host"]!.GetValue<string>(),
            view.Root["sequence"]!.GetValue<int>(),
            view.Root["final"]!.GetValue<bool>(),
            Utc(view.Root["windowStartUtc"]),
            Utc(view.Root["windowEndUtc"]),
            Utc(view.Root["exportedUtc"]),
            producer["version"]!.GetValue<string>(),
            [.. view.Root["targets"]!.AsArray().Select(t => t!.GetValue<string>())],
            tables);
    }

    /// <summary>The draft with its tables, and each row's values, added in the reverse order.</summary>
    private static SidecarDraft Reversed(SidecarDraft draft)
    {
        var tables = new Dictionary<string, List<CaptureRow>>(StringComparer.Ordinal);
        foreach (var (name, rows) in draft.Tables.Reverse())
        {
            tables[name] = [.. rows.Select(row =>
            {
                var copy = new CaptureRow(row.Table, row.Target, row.At, row.Source);
                foreach (var (column, value) in row.Values.Reverse())
                {
                    copy.Set(column, value);
                }

                return copy;
            })];
        }

        return draft with { Tables = tables };
    }

    /// <summary>
    /// A T3 sidecar of <paramref name="intervals"/> Query Store intervals, each read with every plan of every query: query
    /// q's plans lead every top list ahead of query q + 1's, so query 0 is the top-ranked in each interval. Each plan has
    /// three waits an interval and a summary, the target its merged coverage, and <paramref name="padding"/> characters of
    /// events' text tune the size. Its ID is the contract's longest.
    /// </summary>
    private static SidecarDraft Generated(int intervals, int queries, int plans, int padding = 0, int seed = 11)
    {
        var random = new Random(seed);
        var queryHashes = Enumerable.Range(0, queries).Select(_ => Hash(random)).ToList();
        var planHashes = Enumerable.Range(0, queries * plans).Select(_ => Hash(random)).ToList();
        var statements = Enumerable.Range(0, queries)
            .Select(q => string.Create(CultureInfo.InvariantCulture, $"SELECT t.{Word(random)}, t.{Word(random)} FROM care.{Word(random)} AS t WHERE t.{Word(random)} = @p{q} AND t.{Word(random)} <> ?"))
            .ToList();
        var summaries = Enumerable.Range(0, queries * plans)
            .Select(_ => string.Create(CultureInfo.InvariantCulture, $"Index Seek on [care].[{Word(random)}].[ix_{Word(random)}] ({random.Next(50, 99)} % of the cost); Key Lookup on [care].[{Word(random)}].[pk_{Word(random)}]; {string.Join(' ', Enumerable.Range(0, 12).Select(_ => Word(random)))}."))
            .ToList();
        var end = Window.AddMinutes(15 * intervals);
        var stats = new List<CaptureRow>();
        var waits = new List<CaptureRow>();
        for (var i = 0; i < intervals; i++)
        {
            var from = Window.AddMinutes(15 * i);
            var to = from.AddMinutes(15);
            var read = to.AddMinutes(2).AddMilliseconds(random.Next(1, 999));
            for (var q = 0; q < queries; q++)
            {
                for (var p = 0; p < plans; p++)
                {
                    var cpu = Math.Round(((queries - q) * 10_000.0) + ((plans - p) * 1_000.0) + random.Next(0, 900) + (random.Next(0, 1000) / 1000.0), 3);
                    stats.Add(Row(RcaContract.QueryStats, read)
                        .Set("captured_at_utc", read)
                        .Set("interval_start_utc", from)
                        .Set("interval_end_utc", to)
                        .Set("query_id", 1000L + q)
                        .Set("plan_id", (10L * (1000 + q)) + p)
                        .Set("query_hash", queryHashes[q])
                        .Set("plan_hash", planHashes[(q * plans) + p])
                        .Set("statement_text", statements[q])
                        .Set("executions", (long)random.Next(1, 5_000))
                        .Set("aborted_executions", 0L)
                        .Set("cpu_ms", cpu)
                        .Set("duration_ms", Math.Round(cpu * 1.25, 3))
                        .Set("max_duration_ms", Math.Round(random.NextDouble() * 500, 3))
                        .Set("logical_reads", Math.Round(cpu * 7))
                        .Set("physical_reads", (double)random.Next(0, 100))
                        .Set("row_count", (double)random.Next(0, 10_000))
                        .Set("max_dop", 1L)
                        .Set("wait_ms", Math.Round(cpu / 10, 3))
                        .Set("first_execution_utc", from.AddMilliseconds(random.Next(0, 60_000)))
                        .Set("last_execution_utc", to.AddMilliseconds(-random.Next(1, 60_000))));
                    for (var w = 0; w < 3; w++)
                    {
                        // Three categories an interval, turning over from one interval to the next: across the sidecar, a
                        // plan waits in more than three.
                        waits.Add(Row(RcaContract.QueryWaits, read)
                            .Set("captured_at_utc", read)
                            .Set("interval_start_utc", from)
                            .Set("interval_end_utc", to)
                            .Set("query_id", 1000L + q)
                            .Set("plan_id", (10L * (1000 + q)) + p)
                            .Set("wait_category", WaitCategories[(q + p + w + i) % WaitCategories.Length])
                            .Set("wait_ms", Math.Round(random.NextDouble() * 10_000, 3))
                            .Set("max_wait_ms", Math.Round(random.NextDouble() * 100, 3)));
                    }
                }
            }
        }

        var planRows = new List<CaptureRow>();
        for (var q = 0; q < queries; q++)
        {
            for (var p = 0; p < plans; p++)
            {
                planRows.Add(Row(RcaContract.QueryPlans, Window.AddMinutes(2))
                    .Set("captured_at_utc", Window.AddMinutes(2))
                    .Set("query_id", 1000L + q)
                    .Set("plan_id", (10L * (1000 + q)) + p)
                    .Set("query_hash", queryHashes[q])
                    .Set("plan_hash", planHashes[(q * plans) + p])
                    .Set("statement_text", statements[q])
                    .Set("compiled_utc", Window.AddHours(-3))
                    .Set("last_compiled_utc", Window.AddHours(-3))
                    .Set("last_execution_utc", end.AddMinutes(-1))
                    .Set("compiles", 1L)
                    .Set("is_forced_plan", false)
                    .Set("forcing_type", "NONE")
                    .Set("force_failures", 0L)
                    .Set("plans_for_query", (long)plans)
                    .Set("estimated_cost", Math.Round(random.NextDouble() * 50, 4))
                    .Set("is_parallel", false)
                    .Set("plan_summary", summaries[(q * plans) + p]));
            }
        }

        var text = PaddingText.Value[..padding];
        var events = Enumerable.Range(0, (padding + 999) / 1000)
            .Select(i => Row(RcaContract.QueryEvents, Window.AddSeconds(30 + i))
                .Set("event_time_utc", Window.AddSeconds(30 + i))
                .Set("kind", "state")
                .Set("detail", text.Substring(i * 1000, Math.Min(1000, padding - (i * 1000)))))
            .ToList();
        var coverage = Row(RcaContract.QueryCoverage, Window)
            .Set("window_start_utc", Window)
            .Set("window_end_utc", end)
            .Set("state", "READ_WRITE")
            .Set("capture_mode", "AUTO")
            .Set("interval_minutes", 15L)
            .Set("read_from_utc", Window)
            .Set("read_to_utc", end)
            .Set("backfill", false)
            .Set("sources", "RCA-SQL-10,RCA-SQL-11,RCA-SQL-14,RCA-SQL-15");
        var tables = new Dictionary<string, List<CaptureRow>>(StringComparer.Ordinal)
        {
            [RcaContract.QueryStats] = stats,
            [RcaContract.QueryWaits] = waits,
            [RcaContract.QueryPlans] = planRows,
            [RcaContract.QueryEvents] = events,
            [RcaContract.QueryCoverage] = [coverage],
        };
        return new SidecarDraft(Id(Window, LongestHost, 1), Session, "sqlvm01", 1, false, Window, end, end.AddMinutes(3), "1.0.0", [Target], tables);

        static string Hash(Random random) => "0x" + random.NextInt64().ToString("X16", CultureInfo.InvariantCulture);

        static string Word(Random random) => new([.. Enumerable.Range(0, random.Next(5, 10)).Select(_ => (char)('a' + random.Next(26)))]);
    }

    /// <summary>A generated sidecar of exactly <paramref name="gzipBytes"/> of gzip: as many queries as fit, then events' text to the byte.</summary>
    private static SidecarDraft Sized(int gzipBytes, int seed = 11) => SizedDrafts.GetOrAdd((gzipBytes, seed), key =>
    {
        for (var attempt = 0; attempt < 8; attempt++)
        {
            var variant = key.Seed + (100 * attempt);
            int Size(int queries, int padding) => Gzip(Generated(Intervals, queries, Plans, padding, variant)).Length;

            var (low, high) = (1, 2);
            while (Size(high, 0) <= key.Bytes)
            {
                (low, high) = (high, high * 2);
            }

            while (high - low > 1)
            {
                var middle = (low + high) / 2;
                (low, high) = Size(middle, 0) <= key.Bytes ? (middle, high) : (low, middle);
            }

            var (from, to) = (0, 256);
            while (Size(low, to) < key.Bytes && to < PaddingText.Value.Length)
            {
                to = Math.Min(to * 2, PaddingText.Value.Length);
            }

            while (from < to)
            {
                var middle = (from + to) / 2;
                (from, to) = Size(low, middle) >= key.Bytes ? (from, middle) : (middle + 1, to);
            }

            for (var padding = Math.Max(0, from - 4); padding <= Math.Min(from + 48, PaddingText.Value.Length); padding++)
            {
                if (Size(low, padding) == key.Bytes)
                {
                    return Generated(Intervals, low, Plans, padding, variant);
                }
            }
        }

        throw new InvalidOperationException($"No generated sidecar comes to exactly {key.Bytes} bytes of gzip.");
    });

    private static CaptureRow Row(string table, DateTimeOffset at) => new CaptureRow(table, Target, at, "test").Set("target", Target);

    /// <summary>
    /// A sidecar of one plan's waits on each target, an interval at a time, with each target's coverage: a category
    /// (on T4, an event) has a row in each interval it waited in.
    /// </summary>
    private static SidecarDraft Waiting(int intervals, params (string Target, List<(string Category, string? Event, Func<int, double> Waited)> Waits)[] plans)
    {
        var random = new Random(5);
        var waits = new List<CaptureRow>();
        var coverage = new List<CaptureRow>();
        foreach (var (target, categories) in plans)
        {
            for (var i = 0; i < intervals; i++)
            {
                var from = Window.AddMinutes(15 * i);
                foreach (var (category, waitEvent, waited) in categories.Where(c => c.Waited(i) > 0))
                {
                    waits.Add(new CaptureRow(RcaContract.QueryWaits, target, from.AddMinutes(17), "test")
                        .Set("captured_at_utc", from.AddMinutes(17))
                        .Set("target", target)
                        .Set("interval_start_utc", from)
                        .Set("interval_end_utc", from.AddMinutes(15))
                        .Set("query_id", 1000L)
                        .Set("plan_id", target == "T4" ? 0L : 10_000L)
                        .Set("login_name", target == "T4" ? "contosocare_runner" : null)
                        .Set("wait_category", category)
                        .Set("wait_event", waitEvent)
                        .Set("wait_ms", waited(i))
                        .Set("max_wait_ms", Math.Round(random.NextDouble() * 100, 6)));
                }
            }

            coverage.Add(new CaptureRow(RcaContract.QueryCoverage, target, Window, "test")
                .Set("target", target)
                .Set("window_start_utc", Window)
                .Set("window_end_utc", Window.AddMinutes(15 * intervals))
                .Set("backfill", false));
        }

        var tables = new Dictionary<string, List<CaptureRow>>(StringComparer.Ordinal)
        {
            [RcaContract.QueryWaits] = waits,
            [RcaContract.QueryCoverage] = coverage,
        };
        var end = Window.AddMinutes(15 * intervals);
        return new SidecarDraft(Id(Window, "sqlvm01", 1), Session, "sqlvm01", 1, true, Window, end, end.AddMinutes(3), "1.0.0", [.. plans.Select(p => p.Target)], tables);
    }

    private static SealedSidecar Sealed(int i)
    {
        var start = Window.AddMinutes(15 * i);
        return new SealedSidecar(
            Id(start, LongestHost, i + 1), Session, "span-" + i.ToString(CultureInfo.InvariantCulture), LongestHost, i + 1,
            start, start.AddMinutes(15), start.AddMinutes(16), 28, PartCodec.Sha256(BitConverter.GetBytes(i)), false, null);
    }

    /// <summary>A sidecar decoded for assertions: each table's rows with strings resolved and times as UTC.</summary>
    private sealed class SidecarView
    {
        public SidecarView(byte[] json)
        {
            Root = JsonNode.Parse(json)!.AsObject();
            Epoch = Utc(Root["epochUtc"]);
            Strings = [.. Root["strings"]!.AsArray().Select(s => s!.GetValue<string>())];
        }

        public JsonObject Root { get; }

        public DateTimeOffset Epoch { get; }

        public List<string> Strings { get; }

        public List<Dictionary<string, object?>> Table(string name)
        {
            if (Root["tables"]![name] is not JsonObject table)
            {
                return [];
            }

            var types = RcaContract.Table(name).Columns.ToDictionary(c => c.Name, c => c.Type, StringComparer.Ordinal);
            var count = table["rows"]!.GetValue<int>();
            var rows = Enumerable.Range(0, count).Select(_ => new Dictionary<string, object?>(StringComparer.Ordinal)).ToList();
            foreach (var (column, values) in table["columns"]!.AsObject())
            {
                var array = values!.AsArray();
                Assert.Equal(count, array.Count);
                for (var i = 0; i < count; i++)
                {
                    rows[i][column] = array[i] is not { } value ? null : types[column] switch
                    {
                        "string" => Strings[value.GetValue<int>()],
                        "timestamp" => Epoch.AddMilliseconds(value.GetValue<long>()),
                        "long" or "integer" => value.GetValue<long>(),
                        "double" => value.GetValue<double>(),
                        "boolean" => value.GetValue<bool>(),
                        _ => throw new InvalidOperationException($"{name}.{column} has an unknown type."),
                    };
                }
            }

            return rows;
        }
    }

    /// <summary>The store as the index and <c>rca part</c> read it: its offerable sidecars, their gzip, and what expired unread.</summary>
    private sealed class FakeCatalog(IReadOnlyList<SealedSidecar> sidecars, int expiredUnread = 0, Dictionary<string, byte[]>? gzips = null) : ISidecarCatalog
    {
        private int expired = expiredUnread;

        public IReadOnlyList<SealedSidecar> Offerable() => sidecars;

        public byte[]? ReadGzip(string documentId) => gzips?.GetValueOrDefault(documentId);

        public int TakeExpiredCount() => Interlocked.Exchange(ref expired, 0);
    }
}
