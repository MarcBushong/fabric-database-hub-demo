using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.Sidecar;

// The seam between the sidecar's store, sealer, and acknowledgement (T1a) and its encoder, reducer, page index, and
// part lines (T1c), fixed first so both build at once (rca/README.md, The sidecar). Change it only through the
// coordinator.

/// <summary>One sealed sidecar as the store's ledger records it: what the page index lists and the part lines read.</summary>
internal sealed record SealedSidecar(
    string DocumentId,
    string? SessionId,
    string SpanId,
    string Host,
    int Sequence,
    DateTimeOffset WindowStartUtc,
    DateTimeOffset WindowEndUtc,
    DateTimeOffset SealedUtc,
    int Parts,
    string Sha256,
    bool Backfill,
    DateTimeOffset? AcknowledgedUtc);

/// <summary>
/// What the sealer hands the reducer: one span's new rows by sidecar table, with each target's coverage rows already
/// merged into one, and the document's header.
/// </summary>
internal sealed record SidecarDraft(
    string DocumentId,
    string? SessionId,
    string Host,
    int Sequence,
    bool Final,
    DateTimeOffset WindowStartUtc,
    DateTimeOffset WindowEndUtc,
    DateTimeOffset ExportedUtc,
    string ProducerVersion,
    IReadOnlyList<string> Targets,
    IReadOnlyDictionary<string, List<CaptureRow>> Tables);

/// <summary>The reducer's result: the document within its budgets, and its cuts, each also a gap in its target's coverage row.</summary>
internal sealed record ReducedSidecar(byte[] Json, byte[] Gzip, string Sha256, int Parts, IReadOnlyList<string> Cuts);

/// <summary>Encodes a draft as a sidecar document and fits it to a document's 64 KiB and what's left of its host's session budget.</summary>
internal interface ISidecarReducer
{
    ReducedSidecar Reduce(SidecarDraft draft, int remainingSessionBytes);
}

/// <summary>What the page index and <c>rca part</c> read from the sidecar's store.</summary>
internal interface ISidecarCatalog
{
    /// <summary>New and pending sidecars, the oldest sealed first.</summary>
    IReadOnlyList<SealedSidecar> Offerable();

    /// <summary>A sealed sidecar's gzip, or null when the store has none by that ID.</summary>
    byte[]? ReadGzip(string documentId);

    /// <summary>How many sidecars expired unread since the last call.</summary>
    int TakeExpiredCount();
}
