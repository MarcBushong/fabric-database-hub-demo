using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.Store;

/// <summary>
/// Writes one observation span: a JSON-lines file per target, appended and flushed line by line so the export (another
/// process) reads complete lines while the observer writes, at most <see cref="EvidenceStore.TargetCap"/> bytes per
/// target; span.json with the targets' intervals and watermarks; and the span's answer key.
/// </summary>
internal sealed class SpanWriter : ICaptureSpan
{
    private static readonly TimeSpan PersistEvery = TimeSpan.FromSeconds(5);

    private readonly EvidenceStore store;
    private readonly SpanFile span;
    private readonly Lock gate = new();
    private readonly Dictionary<string, TargetFile> files = new(StringComparer.Ordinal);
    private DateTimeOffset lastPersist = DateTimeOffset.MinValue;
    private bool closed;

    public SpanWriter(EvidenceStore store, string directory, SpanFile span)
    {
        this.store = store;
        this.span = span;
        Directory = directory;
    }

    public string Directory { get; }

    public string Id => span.SpanId;

    public static string FileFor(string directory, string target) => Path.Combine(directory, target + ".jsonl");

    public void Write(CaptureRow row)
    {
        var line = StoredLines.Row(row);
        lock (gate)
        {
            Append(row.Target, line, note: false);
        }
    }

    public void Note(CaptureNote note)
    {
        var line = StoredLines.Note(note);
        lock (gate)
        {
            Append(note.Target, line, note: true);
        }
    }

    public void Watermark(string target, DateTimeOffset complete)
    {
        lock (gate)
        {
            var state = Target(target);
            if (state.WatermarkUtc is null || complete > state.WatermarkUtc)
            {
                state.WatermarkUtc = complete;
            }

            Persist(force: false);
        }
    }

    public void Began(string target, DateTimeOffset at)
    {
        lock (gate)
        {
            Target(target).Intervals.Add(new SpanInterval { From = at });
            Persist(force: true);
        }
    }

    public void Ended(string target, DateTimeOffset at)
    {
        lock (gate)
        {
            var state = Target(target);
            if (state.Intervals.LastOrDefault() is { To: null } open)
            {
                open.To = at;
            }

            if (state.WatermarkUtc is null || at > state.WatermarkUtc)
            {
                state.WatermarkUtc = at;
            }

            Persist(force: true);
        }
    }

    public void Close(DateTimeOffset at)
    {
        lock (gate)
        {
            if (closed)
            {
                return;
            }

            foreach (var state in span.Targets.Values)
            {
                if (state.Intervals.LastOrDefault() is { To: null } open)
                {
                    open.To = at;
                }
            }

            span.ClosedUtc = at;
            foreach (var file in files.Values)
            {
                file.Stream.Dispose();
            }

            files.Clear();
            closed = true;
            Persist(force: true);
        }

        store.Closed(this);
    }

    /// <summary>One row of the answer key (rca_answer_key): the workload's own runs and their events, kept apart from the capture.</summary>
    public void AppendAnswerKey(CaptureRow row)
    {
        if (!string.Equals(row.Table, "rca_answer_key", StringComparison.Ordinal))
        {
            throw new InvalidOperationException("Only answer-key rows go into the answer key.");
        }

        var line = StoredLines.Row(row);
        lock (gate)
        {
            using var stream = new FileStream(Path.Combine(Directory, EvidenceStore.AnswerKeyFile), FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            stream.Write(line);
        }
    }

    /// <summary>Writes span.json now, or at most every 5 seconds for a watermark. Call under the lock.</summary>
    internal void Persist(bool force)
    {
        var now = store.Time.GetUtcNow();
        if (!force && now - lastPersist < PersistEvery)
        {
            return;
        }

        EvidenceStore.WriteJson(Path.Combine(Directory, "span.json"), span, RcaStoreJsonContext.Default.SpanFile);
        lastPersist = now;
    }

    private SpanTarget Target(string target)
    {
        if (!span.Targets.TryGetValue(target, out var state))
        {
            span.Targets[target] = state = new SpanTarget();
        }

        return state;
    }

    private void Append(string target, byte[] line, bool note)
    {
        if (closed)
        {
            return;
        }

        if (!files.TryGetValue(target, out var file))
        {
            var path = FileFor(Directory, target);
            var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            files[target] = file = new TargetFile(stream, stream.Length);
        }

        if (file.Bytes + line.Length > store.TargetCap)
        {
            if (file.Capped)
            {
                return;
            }

            // One note past the cap says why the rest is missing.
            file.Capped = true;
            line = StoredLines.Note(new CaptureNote(NoteKind.Gap, target, store.Time.GetUtcNow(), $"The observer's store reached its {store.TargetCap / (1024 * 1024)} MB for {target}; nothing after this was captured for it in this span."));
        }
        else if (file.Capped && !note)
        {
            return;
        }

        file.Stream.Write(line);
        file.Stream.Flush();
        file.Bytes += line.Length;
    }

    private sealed class TargetFile(FileStream stream, long bytes)
    {
        public FileStream Stream { get; } = stream;

        public long Bytes { get; set; } = bytes;

        public bool Capped { get; set; }
    }
}
