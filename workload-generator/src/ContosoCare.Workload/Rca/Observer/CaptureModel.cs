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

    /// <summary>
    /// The capture's end that a session's stop recorded (rca export --end-capture), or null for none: the observer captures
    /// a target after it only once the target's profile is set after it (<see cref="IObservationGate.IsActiveAfter"/>).
    /// </summary>
    DateTimeOffset? CaptureEndedAt();
}

/// <summary>
/// Whether a target is in a session: the observer captures it then, for the whole session, and never reads why
/// (rca/README.md, Blind detection). The profile host answers from its lanes.
/// </summary>
internal interface IObservationGate
{
    bool IsActive(Catalog.DemoTarget target);

    /// <summary>
    /// After the capture's end at <paramref name="end"/>, which a session's stop records while the workload runs on until
    /// the VM stops: whether the target is in a session that began after it (its profile was set after it, and it's in a
    /// session as <see cref="IsActive"/> says). Nothing else captures a target after the end.
    /// </summary>
    bool IsActiveAfter(Catalog.DemoTarget target, DateTimeOffset end);

    /// <summary>
    /// After the capture's end: whether the answer key still has to record a fault run of the target that ended by then,
    /// so the span that the stop's export takes waits to close, capturing nothing, until it has (the review of 1ca916a9).
    /// </summary>
    bool HoldsAfter(Catalog.DemoTarget target, DateTimeOffset end);
}
