using System.Globalization;
using System.Text;
using System.Text.Json;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.Store;

namespace ContosoCare.Workload.Rca.Export;

/// <summary>One document an export made: what the runbook fetches part by part (transport.schema.json, documentRef).</summary>
internal sealed record ExportedDocument(string DocumentId, int Parts, string Sha256);

/// <summary>What <c>rca export</c> prints after <c>DBHUBDEMO-RCA-INDEX</c> (transport.schema.json, exportIndex).</summary>
internal sealed record ExportResult(IReadOnlyList<ExportedDocument> Documents, string Status, string Message)
{
    public string IndexLine()
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer))
        {
            json.WriteStartObject();
            json.WriteString("kind", RcaContract.ExportIndexKind);
            json.WriteNumber("version", RcaContract.Version);
            json.WriteStartArray("documents");
            foreach (var document in Documents)
            {
                json.WriteStartObject();
                json.WriteString("documentId", document.DocumentId);
                json.WriteNumber("parts", document.Parts);
                json.WriteString("sha256", document.Sha256);
                json.WriteEndObject();
            }

            json.WriteEndArray();
            json.WriteString("status", Status);
            json.WriteString("message", Message);
            json.WriteEndObject();
        }

        return RcaContract.IndexMarker + " " + Encoding.UTF8.GetString(buffer.ToArray());
    }
}

/// <summary>
/// <c>rca export</c> (rca/README.md, The runner's commands): reduces what the observer captured since the previous
/// export into evidence documents, one per observation span with something new, stores their gzip for <c>rca part</c>,
/// and returns the index. Each target's window starts where its previous one ended, so a host's documents never
/// overlap for a target. The first export that takes from a span binds it to the caller's session, and later exports
/// keep that session for it: the runbook exports what an earlier session's stop left behind with that session's ID.
/// A control session's documents share its budget over its exports; a sessionless export (<c>--session none</c>) has
/// the budget to itself. A span that can't be exported is a Warning in the index, and the others still export.
/// With <c>--final</c> it waits a bounded time for the observer to end its spans, so the session's last capture is in.
/// </summary>
internal sealed class Exporter(EvidenceStore store, RunnerLog log, string producerVersion)
{
    /// <summary>A host that observes several targets (T1's VM) aims at 64 KiB a session, one that observes one (T2's guest) at 32 KiB: 96 KiB in all.</summary>
    public const int MultiTargetBudget = 64 * 1024;

    public const int SingleTargetBudget = 32 * 1024;

    /// <summary>What the detection tables leave for the answer key, so their budget never depends on it.</summary>
    public const int AnswerKeyReserve = 6 * 1024;

    /// <summary>The least the detection tables get, even when the session's budget is used up: coverage and capture episodes.</summary>
    public const int MinimumBudget = 2 * 1024;

    public const int MaximumDocuments = 16;

    public ExportResult Export(string? sessionId, bool final, TimeSpan finalWait)
    {
        if (!Directory.Exists(store.Root) || store.Spans().Count == 0)
        {
            return new ExportResult([], "Not selected", "Nothing to export: the RCA observer hasn't captured anything on this host.");
        }

        using var exclusive = store.Lock(TimeSpan.FromSeconds(60));
        var now = store.Time.GetUtcNow();
        store.Cleanup(now, log);
        var notes = new List<string>();
        if (final && !WaitForSpans(finalWait))
        {
            notes.Add("The observer was still capturing here, so what it captured after its last complete time stays for the next export.");
        }

        now = store.Time.GetUtcNow();
        var ledger = store.ReadLedger();
        var documents = new List<ExportedDocument>();
        var failures = new List<string>();
        var warnings = new List<string>();
        var cuts = 0;
        var late = 0;
        var sessionless = 0;
        foreach (var span in store.Spans())
        {
            if (span.Export.Complete)
            {
                continue;
            }

            if (documents.Count >= MaximumDocuments)
            {
                notes.Add("More spans wait for the next export.");
                break;
            }

            try
            {
                if (ExportSpan(span, sessionId, final, now, ledger, sessionless) is not { } exported)
                {
                    continue;
                }

                documents.Add(exported.Document);
                sessionless += exported.SessionlessBytes;
                warnings.AddRange(exported.Warnings);
                cuts += exported.Cuts;
                late += exported.LateRows;
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                // One span the export can't make a document of never keeps the others from exporting, or from the index.
                failures.Add($"Span {span.Id} couldn't be exported ({ex.Message}); the next export tries it again.");
                log.Warn("rca.export-span-failed", "Couldn't export an observation span; the others still export.", ("span", span.Id), ("error", Redactor.Redact(ex.GetType().Name + ": " + ex.Message)));
                log.Debug("rca.export-span-failed-detail", ex.ToString(), ("span", span.Id));
            }
        }

        if (documents.Count == 0)
        {
            return failures.Count > 0
                ? new ExportResult([], "Fail", Message("No evidence document was exported.", [.. failures, .. notes], warnings))
                : new ExportResult([], "Not selected", Message("Nothing new to export: the RCA observer captured nothing since the previous export.", notes, warnings));
        }

        try
        {
            store.WriteLedger(ledger);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            failures.Add($"The export's ledger couldn't be saved ({ex.Message}), so the next export may count this session's budget from before this export.");
            log.Warn("rca.ledger-failed", "Couldn't save the RCA export's ledger.", ("error", Redactor.Redact(ex.Message)));
        }

        var summary = string.Create(CultureInfo.InvariantCulture, $"{documents.Count} evidence document{(documents.Count == 1 ? string.Empty : "s")}, {documents.Sum(d => d.Parts)} parts, for {(sessionId is null ? "no control session" : "session " + sessionId)}.");
        if (cuts > 0)
        {
            notes.Add(string.Create(CultureInfo.InvariantCulture, $"{cuts} export budget cut(s), recorded as gaps in RCA Coverage."));
        }

        if (late > 0)
        {
            notes.Add(string.Create(CultureInfo.InvariantCulture, $"{late} row(s) arrived after their window was exported."));
        }

        var status = failures.Count > 0 || warnings.Count > 0 || late > 0 || notes.Any(n => n.StartsWith("The observer was still", StringComparison.Ordinal)) ? "Warning" : "Pass";
        return new ExportResult(documents, status, Message(summary, [.. failures, .. notes], warnings));
    }
    /// <summary>Prints part <paramref name="index"/> of a stored document, or null when the document or part doesn't exist.</summary>
    public string? Part(string documentId, int index)
    {
        var gzip = store.ReadDocument(documentId);
        return gzip is null || index < 1 || index > PartCodec.PartCount(gzip.Length) ? null : PartCodec.Line(documentId, gzip, index);
    }

    /// <summary>
    /// Exports one span's new capture as a document; null when it has nothing new. When it throws, nothing about the span
    /// is marked exported, so the next export takes the same window again.
    /// </summary>
    /// <param name="sessionless">What sessionless documents took of this export's budget so far.</param>
    private SpanExported? ExportSpan(SpanInfo span, string? sessionId, bool final, DateTimeOffset now, SessionLedger ledger, int sessionless)
    {
        var session = span.Export.Bound ? span.Export.SessionId : sessionId;
        var plan = Read(span, now);
        if (plan.Captures.Count == 0 && plan.AnswerKey.Count == 0)
        {
            if (span.Finished)
            {
                span.Export.Complete = true;
                span.Export.LastExportUtc ??= now;
                EvidenceStore.WriteExport(span);
            }

            return null;
        }

        var captures = plan.Captures.Count > 0 ? plan.Captures : Empty(span, now);
        var key = session ?? "none";
        if (!ledger.Sessions.TryGetValue(key, out var use))
        {
            ledger.Sessions[key] = use = new SessionUse();
        }

        // A control session's documents share its budget over all of its exports. Outside one (--session none) there's no
        // session to add them up to, so each export has the budget to itself.
        var sessionBudget = span.Span.Targets.Keys.Count(t => t != "T5") > 1 ? MultiTargetBudget : SingleTargetBudget;
        var spent = session is null ? sessionless : use.Bytes;
        var detectionBudget = Math.Max(MinimumBudget, (int)Math.Min(RcaContract.MaximumDocumentBytes, sessionBudget - spent) - AnswerKeyReserve);
        var sequence = use.Sequence + 1;
        var windowStart = captures.Min(c => c.From);
        var windowEnd = captures.Max(c => c.To);
        var documentId = string.Create(CultureInfo.InvariantCulture, $"{EvidenceDocument.Second(windowStart).UtcDateTime:yyyyMMdd'T'HHmmss'Z'}-{store.Host}-{sequence:D4}");
        var header = new DocumentHeader(documentId, session, store.Host, producerVersion, now, sequence, final, windowStart, windowEnd, [.. captures.Select(c => c.Target).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)]);
        var reduced = Reducer.Reduce(captures, tables => PartCodec.Gzip(EvidenceDocument.Write(header, tables, [])).Length, detectionBudget);
        var answerKey = plan.AnswerKey.ToList();
        var gzip = PartCodec.Gzip(EvidenceDocument.Write(header, reduced.Tables, answerKey));
        while (gzip.Length > RcaContract.MaximumDocumentBytes && answerKey.Count > 0)
        {
            // The answer key never shapes the detection tables: when it's over its reserve, it's what gives way.
            var dropped = answerKey.Count - (answerKey.Count / 2);
            answerKey = answerKey.Count > 1 ? answerKey[..(answerKey.Count / 2)] : [];
            log.Warn("rca.answer-key-cut", "The answer key didn't fit its document; part of it was left out.", ("document", documentId), ("rows", dropped));
            gzip = PartCodec.Gzip(EvidenceDocument.Write(header, reduced.Tables, answerKey));
        }

        store.WriteDocument(documentId, gzip);
        var parts = PartCodec.PartCount(gzip.Length);
        var sha256 = PartCodec.Sha256(gzip);
        span.Export.Bound = true;
        span.Export.SessionId = session;
        foreach (var (target, through) in plan.Through)
        {
            if (!span.Export.Targets.TryGetValue(target, out var state))
            {
                span.Export.Targets[target] = state = new TargetExport();
            }

            state.ThroughUtc = through;
            state.ReadBytes = plan.ReadBytes.GetValueOrDefault(target);
        }

        span.Export.AnswerKeyBytes = plan.AnswerKeyEnd;
        span.Export.LastExportUtc = now;
        span.Export.Documents.Add(documentId);
        span.Export.Complete = span.Finished && plan.ConsumedAll;
        EvidenceStore.WriteExport(span);

        // The span is exported from here on: nothing below can fail.
        use.Sequence = sequence;
        use.Bytes += gzip.Length;
        use.Parts += parts;
        use.LastExportUtc = now;
        log.Info("rca.exported", "Exported an evidence document.", ("document", documentId), ("session", key), ("parts", parts), ("bytes", gzip.Length), ("cuts", reduced.Cuts.Count));
        return new SpanExported(new ExportedDocument(documentId, parts, sha256), session is null ? gzip.Length : 0, reduced.Warnings, reduced.Cuts.Count, plan.Captures.Sum(c => c.LateRows));
    }
    private static string Message(string summary, List<string> notes, List<string> warnings)
    {
        var text = new StringBuilder(summary);
        foreach (var note in notes)
        {
            text.Append(' ').Append(note);
        }

        foreach (var warning in warnings.Distinct(StringComparer.Ordinal))
        {
            text.Append(" RCA.CAPTURE Warning: ").Append(warning);
        }

        var message = Redactor.Redact(text.ToString());
        return message.Length <= 500 ? message : message[..497] + "...";
    }

    /// <summary>Waits until every span is closed or its process is gone, at most <paramref name="wait"/>; false when one is still open.</summary>
    private bool WaitForSpans(TimeSpan wait)
    {
        var deadline = store.Time.GetUtcNow() + wait;
        while (true)
        {
            if (store.Spans().All(s => s.Export.Complete || s.Finished))
            {
                return true;
            }

            if (store.Time.GetUtcNow() >= deadline)
            {
                return false;
            }

            Thread.Sleep(TimeSpan.FromMilliseconds(500));
        }
    }

    /// <summary>A zero-length window for each of the span's targets: a document for answer-key rows that came after the capture.</summary>
    private static List<TargetCapture> Empty(SpanInfo span, DateTimeOffset now) =>
        [.. span.Span.Targets.Keys.Order(StringComparer.Ordinal).Select(t =>
        {
            var at = span.Export.Targets.TryGetValue(t, out var state) && state.ThroughUtc is { } through ? through : now;
            return new TargetCapture(t, at, at, [], [], [], 0, t == "T5");
        })];

    /// <summary>What a span has for this export: each target's window and rows, the new answer-key rows, and how far each file was read.</summary>
    private static SpanPlan Read(SpanInfo span, DateTimeOffset now)
    {
        var plan = new SpanPlan();
        var targets = span.Span.Targets.Keys
            .Concat(Directory.GetFiles(span.Directory, "*.jsonl").Select(Path.GetFileNameWithoutExtension).Where(n => n is not null && n != Path.GetFileNameWithoutExtension(EvidenceStore.AnswerKeyFile)).Select(n => n!))
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal);
        plan.ConsumedAll = true;
        foreach (var target in targets)
        {
            var state = span.Span.Targets.GetValueOrDefault(target) ?? new SpanTarget();
            var exported = span.Export.Targets.GetValueOrDefault(target);
            var lines = new List<(object Item, long Start, long End)>();
            long read = 0;
            foreach (var (line, start, end) in StoredLines.ReadLines(SpanWriter.FileFor(span.Directory, target)))
            {
                read = end;
                if (StoredLines.Parse(line, target) is { } item)
                {
                    lines.Add((item, start, end));
                }
            }

            static DateTimeOffset At(object item) => item is CaptureRow row ? row.At : ((CaptureNote)item).At;
            var from = exported?.ThroughUtc ?? state.Intervals.FirstOrDefault()?.From ?? span.Span.StartedUtc;
            var lastAt = lines.Count == 0 ? (DateTimeOffset?)null : lines.Max(l => At(l.Item));
            DateTimeOffset to;
            if (span.Finished)
            {
                var end = state.Intervals.LastOrDefault()?.To ?? state.WatermarkUtc ?? span.Span.ClosedUtc ?? from;
                to = lastAt is { } last && last >= end ? last.AddMilliseconds(1) : end;
            }
            else
            {
                to = state.WatermarkUtc is { } watermark && watermark < now ? watermark : state.WatermarkUtc is null ? from : now;
            }

            var lateRows = lines.Count(l => exported is not null && l.Start >= exported.ReadBytes && At(l.Item) < from);
            var inWindow = lines.Where(l => At(l.Item) >= from && At(l.Item) < to).Select(l => l.Item).ToList();
            if (lines.Any(l => At(l.Item) >= to))
            {
                plan.ConsumedAll = false;
            }

            if (to <= from && inWindow.Count == 0)
            {
                continue;
            }

            var observed = state.Intervals.Select(i => (i.From, i.To ?? to)).ToList();
            plan.Captures.Add(new TargetCapture(target, from, to, [.. inWindow.OfType<CaptureRow>()], [.. inWindow.OfType<CaptureNote>()], observed, lateRows, target == "T5"));
            plan.Through[target] = to;
            plan.ReadBytes[target] = read;
        }

        var answerKeyPath = Path.Combine(span.Directory, EvidenceStore.AnswerKeyFile);
        plan.AnswerKeyEnd = span.Export.AnswerKeyBytes;
        foreach (var (line, _, end) in StoredLines.ReadLines(answerKeyPath, span.Export.AnswerKeyBytes))
        {
            plan.AnswerKeyEnd = end;
            if (StoredLines.Parse(line, "answer-key") is CaptureRow row)
            {
                plan.AnswerKey.Add(row);
            }
        }

        return plan;
    }

    /// <summary>What one span's export made: its document, what it took of a sessionless budget, and what the index's message counts.</summary>
    private sealed record SpanExported(ExportedDocument Document, int SessionlessBytes, IReadOnlyList<string> Warnings, int Cuts, int LateRows);
    private sealed class SpanPlan
    {
        public List<TargetCapture> Captures { get; } = [];

        public List<CaptureRow> AnswerKey { get; } = [];

        public Dictionary<string, DateTimeOffset> Through { get; } = new(StringComparer.Ordinal);

        public Dictionary<string, long> ReadBytes { get; } = new(StringComparer.Ordinal);

        public long AnswerKeyEnd { get; set; }

        public bool ConsumedAll { get; set; }
    }
}
