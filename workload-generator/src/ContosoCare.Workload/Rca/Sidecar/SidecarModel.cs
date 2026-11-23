using System.Text.Json.Serialization;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>
/// The sidecar store's ledger, <c>sidecars\ledger.json</c> (rca/README.md, The sidecar): every sidecar this host sealed
/// and still keeps, each session's use of its budget, the spans the sidecars and T4's pending ranges belong to, and the
/// next sequence. It's written whole and atomically under the store's lock. The scripts' golden guard reads only each
/// sidecar's <c>documentId</c> and <c>acknowledgedUtc</c>: a sidecar it lists with a null <c>acknowledgedUtc</c> waits for
/// the history.
/// </summary>
internal sealed class SidecarLedger
{
    public int Version { get; set; } = 1;

    /// <summary>The next sidecar's sequence on this host, from 1 to 9999 and then 1 again: the document IDs' fourth field.</summary>
    public int NextSequence { get; set; } = 1;

    /// <summary>The next tag for a span's sidecar file taken aside to be sealed, so the files sort in the order they were taken.</summary>
    public long NextRotation { get; set; } = 1;

    /// <summary>How many sidecars retention deleted unacknowledged since the last index said so.</summary>
    public int ExpiredUnread { get; set; }

    /// <summary>The sealed sidecars, the oldest sealed first.</summary>
    public List<SidecarEntry> Sidecars { get; set; } = [];

    /// <summary>Each budget's use (<see cref="SidecarEntry.Budget"/>): a session's, or a span's without a session.</summary>
    public Dictionary<string, SidecarBudgetUse> Budgets { get; set; } = new(StringComparer.Ordinal);

    /// <summary>The spans the sidecars belong to, by span ID, kept after a span's folder is gone, so a backfill finds its session.</summary>
    public Dictionary<string, SidecarSpan> Spans { get; set; } = new(StringComparer.Ordinal);

    /// <summary>Span files already in a sidecar whose deletion didn't finish (paths under the store's root): deleted before the next sealing.</summary>
    public List<string> Sealed { get; set; } = [];
}

/// <summary>One sealed sidecar: its document, where its rows came from, what it took of the budget, and whether the history has it.</summary>
internal sealed class SidecarEntry
{
    /// <summary><c>&lt;window start&gt;-&lt;host&gt;-&lt;sequence&gt;-sidecar</c> (transport.schema.json, sidecarId); its file is <c>sidecars\&lt;documentId&gt;.json.gz</c>.</summary>
    public string DocumentId { get; set; } = string.Empty;

    /// <summary>The control session the sidecar belongs to, or null for none.</summary>
    public string? SessionId { get; set; }

    /// <summary>
    /// False for a sidecar sealed from a span no export had bound yet: its document says no session until the span is
    /// bound, which comes before it's ever offered. True once its session is final.
    /// </summary>
    public bool Bound { get; set; }

    public string SpanId { get; set; } = string.Empty;

    public string Host { get; set; } = string.Empty;

    public DateTimeOffset WindowStartUtc { get; set; }

    public DateTimeOffset WindowEndUtc { get; set; }

    public int Sequence { get; set; }

    public DateTimeOffset SealedUtc { get; set; }

    public int Parts { get; set; }

    /// <summary>The gzip's size, which the budget counts.</summary>
    public long Bytes { get; set; }

    /// <summary>The lowercase hex SHA-256 of the gzip, as its part lines and the index name it.</summary>
    public string Sha256 { get; set; } = string.Empty;

    /// <summary>True for a sidecar of earlier pending time read into a span whose folder was gone.</summary>
    public bool Backfill { get; set; }

    /// <summary>The budget it counts against: its session's ID, or <c>span:&lt;spanId&gt;</c> without a session.</summary>
    public string Budget { get; set; } = string.Empty;

    /// <summary>When <c>rca ack</c> said the history has it, or null while it waits: it's never offered again once set.</summary>
    public DateTimeOffset? AcknowledgedUtc { get; set; }
}

/// <summary>One budget's use: the gzip of the sidecars sealed against it.</summary>
internal sealed class SidecarBudgetUse
{
    public long Bytes { get; set; }

    public int Sidecars { get; set; }

    public DateTimeOffset? LastSealedUtc { get; set; }
}

/// <summary>
/// One span as the sidecars know it, recorded at its first sidecar row or before: its session once an export bound it,
/// its window, and its targets, which set its host's budget.
/// </summary>
internal sealed class SidecarSpan
{
    public string? SessionId { get; set; }

    /// <summary>True once an export bound the span to its session (export.json), null session included.</summary>
    public bool Bound { get; set; }

    public DateTimeOffset StartedUtc { get; set; }

    public DateTimeOffset? EndedUtc { get; set; }

    /// <summary>The span's observed targets: more than one other than T5 means T1's VM and its 64 KiB budget.</summary>
    public List<string> Targets { get; set; } = [];

    public DateTimeOffset RecordedUtc { get; set; }
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    WriteIndented = true)]
[JsonSerializable(typeof(SidecarLedger))]
internal sealed partial class SidecarJsonContext : JsonSerializerContext;
