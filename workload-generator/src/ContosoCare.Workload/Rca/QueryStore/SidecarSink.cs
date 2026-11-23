using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// Where the observer's sidecar rows go (rca/README.md, The sidecar): Query Store's evidence and T4's connection holders,
/// never the evidence document's store, so the evidence export stays as it was. The store-backed sink, which keeps them
/// beside each span's evidence files, replaces the default, which keeps nothing.
/// </summary>
internal interface ISidecarSink
{
    /// <summary>Keeps one row of a sidecar table; a row of any other table is refused.</summary>
    void Write(CaptureRow row);
}

/// <summary>The default sink: it checks each row's table and keeps nothing, until the store-backed sink is wired in.</summary>
internal sealed class NullSidecarSink : ISidecarSink
{
    public static NullSidecarSink Instance { get; } = new();

    public void Write(CaptureRow row)
    {
        ArgumentNullException.ThrowIfNull(row);
        if (!RcaContract.Table(row.Table).IsSidecar)
        {
            throw new InvalidOperationException($"{row.Table} is the evidence document's table, not the sidecar's.");
        }
    }
}
