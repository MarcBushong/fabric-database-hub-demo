using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// Every statement the observer sends to contosocare on T4, as it sends them, for RCA-PG-14's leave-out by text (its $7;
/// rca/README.md, What the capture leaves out): the capture catalog's PostgreSQL blocks, and the snapshot clear each block
/// runs after. Nothing else: its connections open silently (<see cref="PgCaptureConnector.Startup"/>), their limits in the
/// startup packet rather than SET statements and with no type loading, since the workload sends those too, under the same
/// role, and Query Store keeps one row per role and query.
/// RCA-PG-14 compares these with Query Store's texts once comments are stripped and white space collapsed, and only for
/// the rows of the observer's own role, so a block's earlier versions that differ only there are the same statement:
/// edd01c86's, before the observer's marker, which Query Store may still keep for the queries it saw then. A runner test
/// fails when one of edd01c86's blocks no longer compares equal to one of these. It's built from the runner's own catalog
/// and code, never from the answer key or what the workload plans.
/// </summary>
internal static class PgObserverStatements
{
    /// <summary>The list, in a fixed order: the catalog's blocks by ID, then the snapshot clear.</summary>
    public static IReadOnlyList<string> All { get; } = Build();

    private static string[] Build() =>
        [.. CaptureCatalog.All
            .Where(b => b.Key.StartsWith("RCA-PG-", StringComparison.Ordinal))
            .OrderBy(b => b.Key, StringComparer.Ordinal)
            .Select(b => b.Value)
            .Append(PgCaptureConnector.ClearSnapshot)
            .Where(s => s.Length > 0)
            .Distinct(StringComparer.Ordinal)];
}