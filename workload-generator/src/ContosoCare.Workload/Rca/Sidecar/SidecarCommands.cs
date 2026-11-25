using System.Globalization;
using System.Text;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.Store;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>
/// What <c>rca sidecar-export</c> and <c>rca ack</c> do (rca/README.md, The runner's commands), apart from their options
/// and printing.
/// </summary>
internal static class SidecarCommands
{
    /// <summary>The index's note when a final export's wait ran out while the observer still captured: its last reads wait for the next export.</summary>
    public const string StillCapturing = "The observer was still capturing here, so its last Query Store reads wait for the next sidecar export.";

    /// <summary>The file in <c>sidecars\</c> that keeps the index an export's first page produced, for its later pages.</summary>
    public const string IndexFile = "index.json";

    /// <summary>What the ack line keeps free for ", and N more." after the IDs it lists.</summary>
    private const int MoreRoom = 24;

    /// <summary>
    /// <c>rca sidecar-export</c>. Its first page (<paramref name="page"/> 1) is the export: under the export's lock, with
    /// <paramref name="final"/>, a bounded wait for the observer to end its spans; then the spans whose sidecars need a
    /// session bound to <paramref name="sessionId"/> as <c>rca export</c> binds a span it takes from (<see cref="Bind"/>);
    /// then every span's new rows sealed; then the index of the sidecars to fetch, with what the export couldn't do, kept
    /// in <see cref="IndexFile"/>, and its first page. A later page is a page of that kept index, with no wait, no bind,
    /// and no sealing, whatever <paramref name="final"/> says, so a caller that sends <c>--final</c> with every page waits
    /// once (the review of 54cb2a9d). Without a kept index it's a page of the store's offerable sidecars as they are, still
    /// sealing nothing. A host with no store has nothing to fetch, and the store isn't created.
    /// </summary>
    public static SidecarIndexPage Export(SidecarRuntime runtime, string? sessionId, bool final, TimeSpan finalWait, int page)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        ArgumentOutOfRangeException.ThrowIfLessThan(page, 1);
        var store = runtime.Evidence;
        if (!Directory.Exists(store.Root))
        {
            return SidecarIndex.Page(NoStore.Instance, page, []);
        }

        if (page > 1)
        {
            var index = KeptIndex(runtime) ?? SidecarIndex.Snapshot(new Listing(runtime.Store), [], [], store.Time.GetUtcNow());
            return SidecarIndex.Page(index, page, documentId => File.Exists(runtime.Store.DocumentPath(documentId)));
        }

        using var exclusive = store.Lock(TimeSpan.FromSeconds(60));
        var problems = new List<string>();
        if (final && !store.WaitForSpans(finalWait))
        {
            problems.Add(StillCapturing);
        }

        Bind(runtime, sessionId);
        var sealing = runtime.Sealer.SealAll();
        problems.AddRange(sealing.Problems);
        var produced = SidecarIndex.Snapshot(runtime.Store, sealing.SealedIds, problems, store.Time.GetUtcNow());
        Keep(runtime, produced);
        return SidecarIndex.Page(produced, 1);
    }

    /// <summary>
    /// A sidecar export that comes before <c>rca export</c> binds the span as that export would (call under the export's
    /// lock; it takes the sidecar store's lock itself): a span not bound yet that's still capturing, holds unsealed sidecar
    /// rows, or has sidecars sealed before any bind takes the caller's session, or none, in its export.json. So its
    /// sidecars are sealed with that session, or take it before they're first offered, and a later <c>rca export</c>
    /// keeps it for the span's documents, as it keeps an earlier export's. A finished span with no sidecar is left to
    /// <c>rca export</c>.
    /// </summary>
    public static void Bind(SidecarRuntime runtime, string? sessionId)
    {
        ArgumentNullException.ThrowIfNull(runtime);

        // Under the sidecar store's lock (the review of 54cb2a9d): the ledger's read rebuilds and writes one it can't read,
        // which only the lock's holder may do, beside a sealing that holds it; and no sealing takes a span's rows between
        // this read and the span's bind.
        using var sealing = runtime.Store.Lock();
        var provisional = runtime.Store.ReadLedger().Sidecars.Where(s => !s.Bound).Select(s => s.SpanId).ToHashSet(StringComparer.Ordinal);
        foreach (var span in runtime.Evidence.Spans())
        {
            if (span.Export.Bound || (span.Finished && !EvidenceStore.HoldsUnsealedRows(span.Directory) && !provisional.Contains(span.Id)))
            {
                continue;
            }

            span.Export.Bound = true;
            span.Export.SessionId = sessionId;
            EvidenceStore.WriteExport(span);
        }
    }

    /// <summary>
    /// <c>rca ack</c>: marks the sidecars <paramref name="documents"/> names (comma-separated) as written into the history,
    /// and returns the exit code and the one line to print. An ID this runner doesn't hold (acknowledged and deleted,
    /// expired, or never sealed here) needs nothing more: exit code 0, and the line names it. Anything that isn't a
    /// sidecar's ID is refused, and nothing is acknowledged: exit code 1. A host with no store holds none of them.
    /// </summary>
    public static (int ExitCode, string Line) Acknowledge(SidecarRuntime runtime, string documents)
    {
        ArgumentNullException.ThrowIfNull(runtime);
        ArgumentNullException.ThrowIfNull(documents);
        var ids = documents.Split(',').Select(d => d.Trim()).Where(d => d.Length > 0).Distinct(StringComparer.Ordinal).ToList();
        var bad = ids.Find(d => !SidecarParts.IsSidecarId(d));
        if (ids.Count == 0 || bad is not null)
        {
            var shown = bad is null ? "no ID" : "'" + Redactor.Redact(bad.Length <= 100 ? bad : bad[..97] + "...") + "'";
            return (1, $"rca ack: --document takes sidecars' IDs, comma-separated (transport.schema.json, sidecarId), and {shown} isn't one; nothing was acknowledged.");
        }

        var result = Directory.Exists(runtime.Evidence.Root) ? runtime.Store.Acknowledge(ids) : new SidecarAcknowledgement([], [], ids);
        return (0, Line(result));
    }

    /// <summary>The line of an <c>rca ack</c> that failed: nothing was acknowledged, and the next save sends the IDs again.</summary>
    public static string Failed(string reason)
    {
        var line = "rca ack: failed, so nothing was acknowledged; the next save sends these IDs again: " + Redactor.Redact(reason);
        return line.Length <= RcaContract.MaximumLineLength ? line : line[..(RcaContract.MaximumLineLength - 3)] + "...";
    }

    /// <summary>
    /// What <c>rca ack</c> did, on one line of at most 3,400 characters: how many it acknowledged now and before, and the
    /// IDs this runner doesn't hold, as many as fit.
    /// </summary>
    public static string Line(SidecarAcknowledgement result)
    {
        ArgumentNullException.ThrowIfNull(result);
        var line = new StringBuilder(string.Create(CultureInfo.InvariantCulture, $"rca ack: {Count(result.Acknowledged.Count)} acknowledged as written into the history now, and {Count(result.Already.Count)} before."));
        if (result.Unknown.Count == 0)
        {
            return line.ToString();
        }

        line.Append(CultureInfo.InvariantCulture, $" {Count(result.Unknown.Count)} this runner doesn't hold, acknowledged and deleted, expired, or never sealed here, so {(result.Unknown.Count == 1 ? "it needs" : "they need")} nothing more: ");
        var listed = 0;
        foreach (var id in result.Unknown)
        {
            // Room for this ID, and for what says how many more weren't listed.
            if (line.Length + id.Length + 2 + MoreRoom > RcaContract.MaximumLineLength)
            {
                break;
            }

            line.Append(listed == 0 ? string.Empty : ", ").Append(id);
            listed++;
        }

        if (listed < result.Unknown.Count)
        {
            line.Append(CultureInfo.InvariantCulture, $"{(listed == 0 ? string.Empty : ", and ")}{result.Unknown.Count - listed} more");
        }

        return line.Append('.').ToString();
    }

    private static string Count(int count) => string.Create(CultureInfo.InvariantCulture, $"{count} sidecar{(count == 1 ? string.Empty : "s")}");

    /// <summary>A host with no store: no sidecar, and nothing expired.</summary>
    private sealed class NoStore : ISidecarCatalog
    {
        public static readonly NoStore Instance = new();

        public IReadOnlyList<SealedSidecar> Offerable() => [];

        public byte[]? ReadGzip(string documentId) => null;

        public int TakeExpiredCount() => 0;
    }

    /// <summary>
    /// The store's offerable sidecars as they are, for a later page without a kept index: what expired unread isn't taken,
    /// so the next export's first page still counts it.
    /// </summary>
    private sealed class Listing(SidecarStore store) : ISidecarCatalog
    {
        public IReadOnlyList<SealedSidecar> Offerable() => store.Offerable();

        public byte[]? ReadGzip(string documentId) => store.ReadGzip(documentId);

        public int TakeExpiredCount() => 0;
    }

    /// <summary>
    /// Keeps the index an export's first page produced (call under the export's lock), written whole through a temporary
    /// file. When it can't be written, the older one goes too, so a later page lists the store as it is rather than another
    /// export's index.
    /// </summary>
    private static void Keep(SidecarRuntime runtime, SidecarIndexSnapshot index)
    {
        var path = Path.Combine(runtime.Store.Directory, IndexFile);
        try
        {
            runtime.Store.EnsureFolder();
            EvidenceStore.WriteJson(path, index, SidecarIndexJsonContext.Default.SidecarIndexSnapshot);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            runtime.Log.Warn("rca.sidecar-index-unkept", "Couldn't keep the sidecar export's index for its later pages; they list the sidecars as they are.", ("error", Redactor.Redact(ex.Message)));
            try
            {
                File.Delete(path);
            }
            catch (Exception deleteFailed) when (deleteFailed is IOException or UnauthorizedAccessException)
            {
                runtime.Log.Debug("rca.sidecar-index-unkept-detail", deleteFailed.Message);
            }
        }
    }

    /// <summary>The index the last export's first page kept, or null when there's none, or none this runner can read whole.</summary>
    private static SidecarIndexSnapshot? KeptIndex(SidecarRuntime runtime)
    {
        try
        {
            var index = EvidenceStore.ReadJson(Path.Combine(runtime.Store.Directory, IndexFile), SidecarIndexJsonContext.Default.SidecarIndexSnapshot);
            return SidecarIndex.IsValid(index) ? index : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            runtime.Log.Debug("rca.sidecar-index-unread", ex.Message);
            return null;
        }
    }
}
