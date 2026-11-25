using System.Globalization;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using ContosoCare.Workload.Rca.Store;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>
/// The store-backed sidecar sink (rca/README.md, The sidecar), in place of <see cref="NullSidecarSink"/>: the observer's
/// sidecar rows go to the open span's <c>sidecar-&lt;target&gt;.rows</c> (never <c>.jsonl</c>, which every evidence export
/// reads as a target's file), beside its evidence files, one line each, opened for each row with FileShare.Delete so the
/// sealer can take the file aside while the observer writes. An evidence table's row is refused. At most the store's 20
/// MB a target for each file: past it only the coverage rows go on, each saying so. It's A2's <see cref="ISidecarSpans"/>
/// too: an earlier span's sink for T4's backfill, which goes to the span's folder while it's there, and once it's gone,
/// straight into a sealed sidecar with the span's session from the ledger.
/// </summary>
internal sealed class StoreSidecarSink : ISidecarSink, ISidecarSpans
{
    private readonly SidecarSealer sealer;
    private readonly RunnerLog log;
    private readonly Lock gate = new();
    private readonly HashSet<string> recorded = new(StringComparer.Ordinal);

    public StoreSidecarSink(SidecarSealer sealer, RunnerLog? log = null)
    {
        ArgumentNullException.ThrowIfNull(sealer);
        this.sealer = sealer;
        this.log = log ?? RunnerLog.Null;
    }

    /// <inheritdoc/>
    public string? CurrentSpan
    {
        get
        {
            if (Evidence.Current is not { } span)
            {
                return null;
            }

            Record(span.Id);
            return span.Id;
        }
    }

    private EvidenceStore Evidence => sealer.Store.Evidence;

    /// <summary>Keeps a row in the open span; with no span open (the observer isn't capturing), it's dropped.</summary>
    public void Write(CaptureRow row)
    {
        Refuse(row);
        if (Evidence.Current is not { } span)
        {
            log.Debug("rca.sidecar-no-span", "A sidecar row came with no observation span open; it was dropped.", ("table", row.Table), ("target", row.Target));
            return;
        }

        Record(span.Id);
        Append(span.Directory, row);
    }

    /// <inheritdoc/>
    public ISidecarSink? ForSpan(string spanId)
    {
        if (string.IsNullOrEmpty(spanId) || !spanId.All(c => char.IsAsciiLetterOrDigit(c) || c == '-'))
        {
            return null;
        }

        if (Evidence.Current is { } current && string.Equals(current.Id, spanId, StringComparison.Ordinal))
        {
            return this;
        }

        var directory = Path.Combine(Evidence.Root, spanId);
        if (File.Exists(Path.Combine(directory, "span.json")))
        {
            Record(spanId);
            return new SpanSink(this, directory);
        }

        return sealer.Knows(spanId) ? new BackfillSink(sealer, spanId) : null;
    }

    /// <summary>A row of the evidence document's tables is refused, as <see cref="NullSidecarSink"/> refuses it; so is a target that isn't a key.</summary>
    private static void Refuse(CaptureRow row)
    {
        ArgumentNullException.ThrowIfNull(row);
        if (!RcaContract.Table(row.Table).IsSidecar)
        {
            throw new InvalidOperationException($"{row.Table} is the evidence document's table, not the sidecar's.");
        }

        if (row.Target.Length == 0 || !row.Target.All(c => char.IsAsciiLetterOrDigit(c) || c == '-'))
        {
            throw new InvalidOperationException($"'{row.Target}' isn't a target's key.");
        }
    }

    /// <summary>Records the span in the ledger once per process, when the store's lock is free; a busy lock waits for the next row.</summary>
    private void Record(string spanId)
    {
        lock (gate)
        {
            if (recorded.Contains(spanId))
            {
                return;
            }
        }

        bool done;
        try
        {
            done = sealer.Record(spanId);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Debug("rca.sidecar-record-failed", ex.Message, ("span", spanId));
            return;
        }

        if (done)
        {
            lock (gate)
            {
                recorded.Add(spanId);
            }
        }
    }

    private void Append(string directory, CaptureRow row)
    {
        var path = SidecarSealer.FileFor(directory, row.Target);
        var line = StoredLines.Row(row);
        lock (gate)
        {
            var length = File.Exists(path) ? new FileInfo(path).Length : 0;
            if (length + line.Length > Evidence.TargetCap)
            {
                if (row.Table != RcaContract.QueryCoverage)
                {
                    return;
                }

                line = StoredLines.Row(Capped(row));
            }

            using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
            stream.Write(line);
        }
    }

    /// <summary>A coverage row past the file's cap, with a gap that says what the cap left out.</summary>
    private CaptureRow Capped(CaptureRow row)
    {
        var copy = new CaptureRow(row.Table, row.Target, row.At, row.Source, row.Sentinel);
        foreach (var (column, value) in row.Values)
        {
            copy.Set(column, value);
        }

        var gap = string.Create(CultureInfo.InvariantCulture, $"The observer's store reached its {Evidence.TargetCap / (1024 * 1024)} MB of sidecar rows for {row.Target} in this span; only its coverage rows were kept after that.");
        var gaps = copy.Get("gaps") as string;
        copy.Set("gaps", string.IsNullOrEmpty(gaps) ? gap : gaps + "\n" + gap);
        return copy;
    }

    /// <summary>An earlier span's sink while its folder is there: its rows wait in the span for the next sealing.</summary>
    private sealed class SpanSink(StoreSidecarSink owner, string directory) : ISidecarSink
    {
        public void Write(CaptureRow row)
        {
            Refuse(row);
            owner.Append(directory, row);
        }
    }

    /// <summary>
    /// A gone span's sink: T4's backfill writes a range's rows, then its coverage row last, so each coverage row seals
    /// what came before it into one sidecar, straight away. When sealing fails, the rows are dropped and the failure goes
    /// to the reader, whose range then stays pending for the next read.
    /// </summary>
    private sealed class BackfillSink(SidecarSealer sealer, string spanId) : ISidecarSink
    {
        private readonly List<CaptureRow> rows = [];

        public void Write(CaptureRow row)
        {
            Refuse(row);
            rows.Add(row);
            if (row.Table != RcaContract.QueryCoverage)
            {
                return;
            }

            try
            {
                sealer.SealBackfill(spanId, rows);
            }
            finally
            {
                rows.Clear();
            }
        }
    }
}
