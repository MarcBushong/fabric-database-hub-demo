using ContosoCare.Workload.Rca.Export;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>
/// The sidecar's budgets (rca/README.md, Limits), apart from the evidence documents' so that Query Store never crowds
/// them out, with the same split between the hosts: 64 KiB of gzip a session on a host that observes several targets
/// (T1's VM), 32 KiB on one that observes one (T2's guest), counting the span's targets other than T5 as the evidence
/// export does. One sidecar is at most 64 KiB of gzip, 28 parts.
/// </summary>
internal static class SidecarBudget
{
    /// <summary>A session's sidecars on a host that observes several targets.</summary>
    public const int MultiTargetSessionBytes = Exporter.MultiTargetBudget;

    /// <summary>A session's sidecars on a host that observes one target.</summary>
    public const int SingleTargetSessionBytes = Exporter.SingleTargetBudget;

    /// <summary>One sidecar's gzip at most.</summary>
    public const int DocumentBytes = RcaContract.MaximumDocumentBytes;

    /// <summary>One sidecar's parts at most: 64 KiB in parts of 2,400 bytes.</summary>
    public const int DocumentParts = (DocumentBytes + RcaContract.PartBytes - 1) / RcaContract.PartBytes;

    /// <summary>
    /// The least a sidecar gets, even when its host's session budget is used up: room for its coverage rows, which say
    /// what was cut and why.
    /// </summary>
    public const int MinimumDocumentBytes = Exporter.MinimumBudget;

    /// <summary>A session's sidecar budget on a host whose span observes <paramref name="spanTargets"/>.</summary>
    public static int ForHost(IEnumerable<string> spanTargets)
    {
        ArgumentNullException.ThrowIfNull(spanTargets);
        return spanTargets.Distinct(StringComparer.Ordinal).Count(t => t != "T5") > 1 ? MultiTargetSessionBytes : SingleTargetSessionBytes;
    }

    /// <summary>What one sidecar may take: the smaller of a document's 64 KiB and what's left of its host's session budget, and never less than the minimum.</summary>
    public static int ForDocument(int remainingSessionBytes) => Math.Max(MinimumDocumentBytes, Math.Min(DocumentBytes, remainingSessionBytes));
}
