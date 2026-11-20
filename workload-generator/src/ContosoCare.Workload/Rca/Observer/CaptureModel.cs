namespace ContosoCare.Workload.Rca.Observer;

/// <summary>
/// One row the observer captured for a detection table (rca/history-tables.json): its table, target, primary time, the
/// capture IDs that produced it (for RCA Coverage's sources), and its values by column name. Timestamps are
/// <see cref="DateTimeOffset"/> in UTC; strings are already normalized and redacted.
/// </summary>
internal sealed class CaptureRow(string table, string target, DateTimeOffset at, string source, bool sentinel = false)
{
    private readonly Dictionary<string, object?> values = new(StringComparer.Ordinal);

    public string Table { get; } = table;

    public string Target { get; } = target;

    public DateTimeOffset At { get; } = at;

    /// <summary>The capture IDs behind the row, comma-separated (rca/capture/README.md).</summary>
    public string Source { get; } = source;

    /// <summary>True for the sentinel's own samples, which tell RCA Coverage that the sentinel ran.</summary>
    public bool Sentinel { get; } = sentinel;

    public IReadOnlyDictionary<string, object?> Values => values;

    public CaptureRow Set(string column, object? value)
    {
        values[column] = value;
        return this;
    }

    public object? Get(string column) => values.TryGetValue(column, out var value) ? value : null;
}

/// <summary>What a note tells RCA Coverage.</summary>
internal enum NoteKind
{
    /// <summary>Something wasn't captured, with why: one line of the coverage row's gaps.</summary>
    Gap,

    /// <summary>A capture ID that ran without a row of its own (the event session's creation).</summary>
    Source,

    /// <summary>A problem the export reports as an RCA.CAPTURE.&lt;target&gt; Warning, with its fix; also a gap.</summary>
    Warning,
}

/// <summary>A coverage note for one target at one time.</summary>
internal sealed record CaptureNote(NoteKind Kind, string Target, DateTimeOffset At, string Text);

/// <summary>Where one observation span's capture goes: the local evidence store (rca/README.md, The flow).</summary>
internal interface ICaptureSink
{
    void Write(CaptureRow row);

    void Note(CaptureNote note);

    /// <summary>Every row of <paramref name="target"/> before <paramref name="complete"/> has been written: the export may take them.</summary>
    void Watermark(string target, DateTimeOffset complete);
}

/// <summary>One observation span: from the first observed target's activity to the last one's end.</summary>
internal interface ICaptureSpan : ICaptureSink
{
    void Began(string target, DateTimeOffset at);

    void Ended(string target, DateTimeOffset at);

    void Close(DateTimeOffset at);
}

/// <summary>Opens observation spans.</summary>
internal interface ICaptureStore
{
    ICaptureSpan Open(DateTimeOffset at);
}

/// <summary>
/// Whether a target is in a session: the observer captures it then, for the whole session, and never reads why
/// (rca/README.md, Blind detection). The profile host answers from its lanes.
/// </summary>
internal interface IObservationGate
{
    bool IsActive(Catalog.DemoTarget target);
}
