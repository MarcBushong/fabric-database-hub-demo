using System.Globalization;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.Store;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>What one sealing call made, and the spans it couldn't seal, with why (they're tried again at the next).</summary>
internal sealed record SidecarSealing(IReadOnlyList<SealedSidecar> Sealed, IReadOnlyList<string> Problems)
{
    /// <summary>The IDs this call sealed, which the page index lists as new (and every other offerable sidecar as pending).</summary>
    public IReadOnlyList<string> SealedIds => [.. Sealed.Select(s => s.DocumentId)];
}

/// <summary>
/// The sealer (rca/README.md, The sidecar): takes a span's sidecar rows out of its folder into one sealed sidecar in
/// <c>sidecars\</c>, recorded in the ledger. It first takes each <c>sidecar-&lt;target&gt;.rows</c> aside under a new
/// name, so the observer's appends during a seal go to a new file, and reads one only once no writer holds it; it
/// deletes what it sealed, so a <c>sidecar-*.rows</c> left in a span's folder always means unsealed rows. Each target's
/// per-read coverage rows become one (<see cref="SidecarCoverage"/>), and the reducer fits the document to its budgets.
/// A sidecar takes its span's session from the span's export.json; one sealed before any export bound its span takes the
/// session when the span is bound, before it's ever offered. The same rows always seal to the same bytes.
/// </summary>
internal sealed class SidecarSealer
{
    /// <summary>The span files' prefix, from the contract's name (<see cref="RcaContract.SidecarRowsFile"/>).</summary>
    public static readonly string FilePrefix = RcaContract.SidecarRowsFile("T1")[..^("T1" + RcaContract.SidecarRowsExtension).Length];

    /// <summary>Never <c>.jsonl</c>, which every evidence export reads as a target's file.</summary>
    public const string FileExtension = RcaContract.SidecarRowsExtension;

    /// <summary>A sidecar is at most 64 KiB of gzip (28 parts).</summary>
    public const int MaximumDocumentBytes = RcaContract.MaximumDocumentBytes;

    /// <summary>
    /// How far under its limits a sidecar sealed with no session stays, so it's still within a document's 64 KiB once a
    /// bind adds its session's 32 characters and, past the session's budget, the gap line that says so.
    /// </summary>
    public const int ProvisionalMargin = 512;

    private static readonly TimeSpan WriterWait = TimeSpan.FromSeconds(5);

    private readonly ISidecarReducer reducer;
    private readonly string producerVersion;
    private readonly RunnerLog log;

    /// <param name="store">The sidecar store, whose session budget the sealer fits each sidecar to.</param>
    /// <param name="reducer">Encodes a draft and fits it to its budgets.</param>
    /// <param name="producerVersion">The runner's version, which each sidecar names.</param>
    /// <param name="log">The runner's log.</param>
    public SidecarSealer(SidecarStore store, ISidecarReducer reducer, string producerVersion, RunnerLog? log = null)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(reducer);
        Store = store;
        this.reducer = reducer;
        this.producerVersion = producerVersion;
        this.log = log ?? RunnerLog.Null;
    }

    public SidecarStore Store { get; }

    /// <summary>Called after a span's files are taken aside and before they're read: the tests' way in, between the two.</summary>
    internal Action<SpanInfo>? Rotated { get; set; }

    /// <summary>A span's sidecar file for a target, where the observer appends: <c>sidecar-&lt;target&gt;.rows</c>.</summary>
    public static string FileFor(string spanDirectory, string target) => Path.Combine(spanDirectory, RcaContract.SidecarRowsFile(target));

    /// <summary>
    /// A sidecar file's target, and its tag once taken aside (<c>sidecar-&lt;target&gt;.&lt;tag&gt;.rows</c>); null for a
    /// file that isn't one. A target has no dot.
    /// </summary>
    public static (string Target, string? Tag)? ParseFile(string fileName)
    {
        if (!fileName.StartsWith(FilePrefix, StringComparison.Ordinal) || !fileName.EndsWith(FileExtension, StringComparison.Ordinal))
        {
            return null;
        }

        var name = fileName[FilePrefix.Length..^FileExtension.Length];
        var dot = name.IndexOf('.', StringComparison.Ordinal);
        var target = dot < 0 ? name : name[..dot];
        var tag = dot < 0 ? null : name[(dot + 1)..];
        return target.Length > 0 && IsKey(target) && (tag is null || (tag.Length > 0 && IsKey(tag))) ? (target, tag) : null;
    }

    /// <summary>
    /// Seals one span's new rows: its sidecar, or null when it had none. When the sealing fails, what it did first (a
    /// document a bind wrote again, files taken aside) is still recorded in the ledger before the failure goes on.
    /// </summary>
    public SealedSidecar? SealSpan(SpanInfo span)
    {
        ArgumentNullException.ThrowIfNull(span);
        using var exclusive = Store.Lock();
        var ledger = Store.ReadLedger();
        var done = new List<string>();
        SealedSidecar? sealedSidecar;
        try
        {
            sealedSidecar = Seal(ledger, span, done);
        }
        catch
        {
            CommitAfterFailure(ledger, done);
            throw;
        }

        Commit(ledger, done);
        return sealedSidecar;
    }

    /// <summary>Seals one span's new rows by its ID; null when it had none, or the store has no such span.</summary>
    public SealedSidecar? SealSpan(string spanId) => Store.Evidence.Spans().FirstOrDefault(s => string.Equals(s.Id, spanId, StringComparison.Ordinal)) is { } span ? SealSpan(span) : null;

    /// <summary>
    /// Retention, then one sidecar for each span with new rows, the oldest span first: at the observer's start, for spans a
    /// stop left unsealed, and at every export. A span that can't be sealed is a problem in the result and doesn't keep
    /// the others from sealing; its rows wait for the next call. Whatever fails, what was done is recorded.
    /// </summary>
    public SidecarSealing SealAll()
    {
        using var exclusive = Store.Lock();
        var ledger = Store.ReadLedger();
        var done = new List<string>();
        var made = new List<SealedSidecar>();
        var problems = new List<string>();
        try
        {
            Store.Cleanup(ledger, Store.Time.GetUtcNow());
            foreach (var span in Store.Evidence.Spans())
            {
                try
                {
                    if (Seal(ledger, span, done) is { } sealedSidecar)
                    {
                        made.Add(sealedSidecar);
                    }
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or InvalidDataException)
                {
                    problems.Add($"Span {span.Id}'s sidecar rows couldn't be sealed ({Redactor.Redact(ex.Message)}); the next sealing tries again.");
                    log.Warn("rca.sidecar-seal-failed", "Couldn't seal a span's sidecar rows; the others still seal.", ("span", span.Id), ("error", Redactor.Redact(ex.GetType().Name + ": " + ex.Message)));
                }
            }
        }
        catch
        {
            CommitAfterFailure(ledger, done);
            throw;
        }

        Commit(ledger, done);
        return new SidecarSealing(made, problems);
    }

    /// <summary>
    /// Records a span in the ledger, with its session and window, when it isn't yet: at its first sidecar row, so a
    /// backfill finds it after its folder is gone. It never waits for the lock: false when it couldn't record it now.
    /// </summary>
    internal bool Record(string spanId)
    {
        using var held = Store.TryLock();
        if (held is null)
        {
            return false;
        }

        var ledger = Store.ReadLedger();
        if (ledger.Spans.ContainsKey(spanId))
        {
            return true;
        }

        if (Span(spanId) is not { } span)
        {
            return false;
        }

        RecordSpan(ledger, span, Store.Time.GetUtcNow());
        Store.WriteLedger(ledger);
        return true;
    }

    /// <summary>True when the ledger knows the span, or can't be read to say; read without the lock, as the ledger is replaced whole.</summary>
    internal bool Knows(string spanId)
    {
        if (!File.Exists(Store.LedgerPath))
        {
            return false;
        }

        return EvidenceStore.ReadJson(Store.LedgerPath, SidecarJsonContext.Default.SidecarLedger) is not { Version: 1 } ledger || ledger.Spans.ContainsKey(spanId);
    }

    /// <summary>
    /// Seals a backfill's rows straight into <c>sidecars\</c> for a span whose folder is gone, with the span's session
    /// and targets from the ledger: T4's pending time read after the span's 7-day retention. The rows go through the
    /// store's line format first, as a span's rows do, so the same rows seal to the same bytes by either path.
    /// </summary>
    internal SealedSidecar? SealBackfill(string spanId, IReadOnlyList<CaptureRow> rows)
    {
        ArgumentNullException.ThrowIfNull(rows);
        var stored = rows.Select(r => StoredLines.Parse(System.Text.Encoding.UTF8.GetString(StoredLines.Row(r)).TrimEnd('\n'), r.Target)).OfType<CaptureRow>().ToList();
        using var exclusive = Store.Lock();
        var ledger = Store.ReadLedger();
        if (!ledger.Spans.TryGetValue(spanId, out var span))
        {
            throw new InvalidOperationException($"The sidecar ledger doesn't know span {spanId}.");
        }

        var sealedSidecar = stored.Count == 0 ? null : Write(ledger, spanId, stored, span.Bound ? span.SessionId : null, provisional: !span.Bound, final: true, backfill: true, span.Targets, Store.Time.GetUtcNow());
        Store.WriteLedger(ledger);
        return sealedSidecar;
    }

    /// <summary>Seals one span (under the lock): the files it sealed go in <paramref name="done"/>, deleted once the ledger is written.</summary>
    private SealedSidecar? Seal(SidecarLedger ledger, SpanInfo span, List<string> done)
    {
        var now = Store.Time.GetUtcNow();
        DeleteSealed(ledger, span.Directory);
        var files = TakeAside(ledger, span.Directory);
        if (files.Count == 0 && !ledger.Spans.ContainsKey(span.Id))
        {
            return null;
        }

        RecordSpan(ledger, span, now);
        if (span.Export.Bound)
        {
            Store.Bind(ledger, span.Id, span.Export.SessionId);
        }

        if (files.Count == 0)
        {
            return null;
        }

        Rotated?.Invoke(span);
        var rows = new List<CaptureRow>();
        var read = new List<string>();
        foreach (var (file, target) in files)
        {
            if (!Free(file))
            {
                log.Debug("rca.sidecar-file-busy", "A sidecar file was still being written; the next sealing takes it.", ("file", Path.GetFileName(file)));
                continue;
            }

            read.Add(file);
            foreach (var (line, _, _) in StoredLines.ReadLines(file))
            {
                if (StoredLines.Parse(line, target) is CaptureRow row && RcaContract.Table(row.Table).IsSidecar)
                {
                    rows.Add(row);
                }
            }
        }

        SealedSidecar? sealedSidecar = null;
        if (rows.Count > 0)
        {
            var session = span.Export.Bound ? span.Export.SessionId : null;
            sealedSidecar = Write(ledger, span.Id, rows, session, provisional: !span.Export.Bound, final: span.Finished, backfill: false, Targets(ledger, span.Id), now);
        }

        foreach (var file in read)
        {
            ledger.Sealed.Add(Path.GetRelativePath(Store.Evidence.Root, file));
            done.Add(file);
        }

        return sealedSidecar;
    }

    /// <summary>
    /// Makes one sidecar of a span's rows (under the lock): each target's coverage merged, the draft fitted to what's left
    /// of its budget by the reducer, the gzip written, and its entry and budget use recorded. A target with rows and no
    /// Query Store read of its own (who held T4's connections, say, before the next read) has no coverage row here: the
    /// reducer adds the one that says no read is recorded, and the target's rows set the window then.
    /// </summary>
    private SealedSidecar Write(SidecarLedger ledger, string spanId, IReadOnlyList<CaptureRow> rows, string? session, bool provisional, bool final, bool backfill, IReadOnlyCollection<string> spanTargets, DateTimeOffset now)
    {
        var groups = rows.GroupBy(r => r.Target, StringComparer.Ordinal).OrderBy(g => g.Key, StringComparer.Ordinal).ToList();
        var coverage = groups
            .Where(g => g.Any(r => r.Table == RcaContract.QueryCoverage))
            .Select(g => SidecarCoverage.Merge(g.Key, [.. g.Where(r => r.Table == RcaContract.QueryCoverage)], [.. g.Where(r => r.Table != RcaContract.QueryCoverage)]))
            .ToList();
        var unread = groups.Where(g => !g.Any(r => r.Table == RcaContract.QueryCoverage)).ToList();
        var windowStart = coverage.Select(c => c.WindowStart).Concat(unread.Select(g => g.Min(r => r.At))).Min();
        var windowEnd = coverage.Select(c => c.WindowEnd).Concat(unread.Select(g => g.Max(r => r.At).AddMilliseconds(1))).Max();
        var tables = new Dictionary<string, List<CaptureRow>>(StringComparer.Ordinal);
        foreach (var table in RcaContract.SidecarTables.Where(t => t.Name != RcaContract.QueryCoverage))
        {
            var kept = rows.Where(r => r.Table == table.Name).Select((r, i) => (Row: r, Index: i)).OrderBy(r => r.Row.At).ThenBy(r => r.Row.Target, StringComparer.Ordinal).ThenBy(r => r.Index).Select(r => r.Row).ToList();
            if (kept.Count > 0)
            {
                tables[table.Name] = kept;
            }
        }

        if (coverage.Count > 0)
        {
            tables[RcaContract.QueryCoverage] = [.. coverage.Select(c => c.Row())];
        }

        var (documentId, sequence) = Store.NextDocumentId(ledger, windowStart);
        var draft = new SidecarDraft(documentId, session, Store.Host, sequence, final, windowStart, windowEnd, now, producerVersion, [.. groups.Select(g => g.Key)], tables);
        var budget = SidecarStore.BudgetKey(session, spanId);
        var remaining = (int)Math.Clamp(Store.SessionBudget(spanTargets) - (ledger.Budgets.TryGetValue(budget, out var use) ? use.Bytes : 0L), 0L, int.MaxValue);
        if (provisional)
        {
            remaining = Math.Max(0, Math.Min(remaining, MaximumDocumentBytes) - ProvisionalMargin);
        }

        var reduced = reducer.Reduce(draft, remaining);
        if (reduced.Gzip is not { Length: > 0 } gzip || !string.Equals(reduced.Sha256, PartCodec.Sha256(gzip), StringComparison.Ordinal) || reduced.Parts != PartCodec.PartCount(gzip.Length))
        {
            throw new InvalidOperationException($"The reducer's sidecar {documentId} doesn't match its own SHA-256 and parts.");
        }

        Store.WriteDocument(documentId, gzip);
        var entry = new SidecarEntry
        {
            DocumentId = documentId,
            SessionId = session,
            Bound = !provisional,
            SpanId = spanId,
            Host = Store.Host,
            WindowStartUtc = windowStart,
            WindowEndUtc = windowEnd,
            Sequence = sequence,
            SealedUtc = now,
            Parts = reduced.Parts,
            Bytes = gzip.Length,
            Sha256 = reduced.Sha256,
            Backfill = backfill,
            Budget = budget,
        };
        ledger.Sidecars.Add(entry);
        SidecarStore.Use(ledger, budget, gzip.Length, now);
        log.Info("rca.sidecar-sealed", "Sealed a span's sidecar rows.", ("document", documentId), ("span", spanId), ("session", session ?? (provisional ? "unbound" : "none")), ("parts", reduced.Parts), ("bytes", gzip.Length), ("cuts", reduced.Cuts.Count));
        return SidecarStore.Sealed(entry);
    }

    /// <summary>Writes the ledger, then deletes the files the sealing took, then writes it again without them.</summary>
    private void Commit(SidecarLedger ledger, List<string> done)
    {
        Store.WriteLedger(ledger);
        if (done.Count == 0)
        {
            return;
        }

        foreach (var file in done)
        {
            try
            {
                File.Delete(file);
                ledger.Sealed.Remove(Path.GetRelativePath(Store.Evidence.Root, file));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // The ledger keeps its name: the next sealing deletes it before reading anything, so it's never sealed twice.
                log.Debug("rca.sidecar-delete-failed", ex.Message, ("file", Path.GetFileName(file)));
            }
        }

        Store.WriteLedger(ledger);
    }

    /// <summary>
    /// The commit after a sealing that failed, so what it did first is recorded. When the ledger can't be written either,
    /// the log says so and the sealing's own failure goes on: the next bind takes what a bind wrote from its file.
    /// </summary>
    private void CommitAfterFailure(SidecarLedger ledger, List<string> done)
    {
        try
        {
            Commit(ledger, done);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warn("rca.sidecar-ledger-failed", "The sidecar ledger couldn't be written after a sealing failed; the next sealing records it again.", ("error", Redactor.Redact(ex.Message)));
        }
    }

    /// <summary>
    /// Deletes the span's files an earlier sealing sealed but couldn't delete, before anything is read, so they're never
    /// sealed twice. It deletes only a file named as one taken aside to be sealed (<c>sidecar-&lt;target&gt;.&lt;tag&gt;.rows</c>):
    /// any other name the list holds for the span is dropped from it and left alone.
    /// </summary>
    private void DeleteSealed(SidecarLedger ledger, string directory)
    {
        var folder = Path.GetFullPath(directory);
        foreach (var relative in ledger.Sealed.ToList())
        {
            var path = Path.GetFullPath(Path.Combine(Store.Evidence.Root, relative));
            if (!string.Equals(Path.GetDirectoryName(path), folder, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            if (ParseFile(Path.GetFileName(path)) is not { Tag: not null })
            {
                ledger.Sealed.Remove(relative);
                log.Warn("rca.sidecar-sealed-name", "The sidecar ledger listed a file as sealed that isn't one taken aside to be sealed; it's left as it is.", ("file", Path.GetFileName(path)));
                continue;
            }

            try
            {
                File.Delete(path);
                ledger.Sealed.Remove(relative);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                throw new IOException($"A sidecar file already sealed couldn't be deleted ({ex.Message}), so this span isn't sealed again until it is.", ex);
            }
        }
    }

    /// <summary>
    /// Takes each live sidecar file of the span aside under a new tag, and returns them with any an earlier sealing took
    /// aside and didn't finish, by target, in the order they were taken.
    /// </summary>
    private List<(string File, string Target)> TakeAside(SidecarLedger ledger, string directory)
    {
        var files = new List<(string File, string Target, string Tag)>();
        if (!System.IO.Directory.Exists(directory))
        {
            return [];
        }

        foreach (var file in System.IO.Directory.GetFiles(directory, FilePrefix + "*" + FileExtension))
        {
            if (ParseFile(Path.GetFileName(file)) is not { } parsed)
            {
                continue;
            }

            if (parsed.Tag is { } tag)
            {
                files.Add((file, parsed.Target, tag));
                continue;
            }

            while (true)
            {
                var taken = string.Create(CultureInfo.InvariantCulture, $"r{ledger.NextRotation:D10}");
                ledger.NextRotation++;
                var aside = Path.Combine(directory, $"{FilePrefix}{parsed.Target}.{taken}{FileExtension}");
                if (File.Exists(aside))
                {
                    continue;
                }

                try
                {
                    // The observer opens its file for each row with FileShare.Delete, so the move works while it writes.
                    File.Move(file, aside);
                    files.Add((aside, parsed.Target, taken));
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    log.Debug("rca.sidecar-rotate-failed", ex.Message, ("file", Path.GetFileName(file)));
                }

                break;
            }
        }

        return [.. files.OrderBy(f => f.Target, StringComparer.Ordinal).ThenBy(f => f.Tag, StringComparer.Ordinal).Select(f => (f.File, f.Target))];
    }

    /// <summary>True once no writer holds the file: a writer that opened it before it was taken aside finishes its row first.</summary>
    private static bool Free(string file)
    {
        var deadline = DateTimeOffset.UtcNow + WriterWait;
        while (true)
        {
            try
            {
                using var exclusive = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.None);
                return true;
            }
            catch (FileNotFoundException)
            {
                return false;
            }
            catch (IOException) when (DateTimeOffset.UtcNow < deadline)
            {
                Thread.Sleep(20);
            }
            catch (IOException)
            {
                return false;
            }
        }
    }

    /// <summary>Records or updates a span's ledger entry from its span.json and export.json.</summary>
    private static void RecordSpan(SidecarLedger ledger, SpanInfo span, DateTimeOffset now)
    {
        if (!ledger.Spans.TryGetValue(span.Id, out var entry))
        {
            ledger.Spans[span.Id] = entry = new SidecarSpan { StartedUtc = span.Span.StartedUtc, RecordedUtc = now };
        }

        entry.EndedUtc = span.Span.ClosedUtc ?? entry.EndedUtc;
        entry.Targets = [.. entry.Targets.Union(span.Span.Targets.Keys, StringComparer.Ordinal).Order(StringComparer.Ordinal)];
        if (span.Export.Bound)
        {
            entry.Bound = true;
            entry.SessionId = span.Export.SessionId;
        }
    }

    private static List<string> Targets(SidecarLedger ledger, string spanId) => ledger.Spans.TryGetValue(spanId, out var span) ? span.Targets : [];

    /// <summary>A span by its ID from its own folder, or null when it has none.</summary>
    private SpanInfo? Span(string spanId)
    {
        if (!IsKey(spanId))
        {
            return null;
        }

        var directory = Path.Combine(Store.Evidence.Root, spanId);
        return EvidenceStore.ReadJson(Path.Combine(directory, "span.json"), RcaStoreJsonContext.Default.SpanFile) is { } span
            ? new SpanInfo(directory, span, EvidenceStore.ReadJson(Path.Combine(directory, "export.json"), RcaStoreJsonContext.Default.SpanExport) ?? new SpanExport())
            : null;
    }

    private static bool IsKey(string text) => text.Length > 0 && text.All(c => char.IsAsciiLetterOrDigit(c) || c == '-');
}
