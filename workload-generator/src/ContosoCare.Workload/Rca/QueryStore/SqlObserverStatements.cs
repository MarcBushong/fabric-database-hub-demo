using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// The observer's own SQL Server statements as earlier runners sent them, before they carried its marker (rca/README.md,
/// What the capture leaves out, 1 and 3). The release's runner sends its catalog blocks without the marker, as ad hoc
/// batches; Query Store keeps each of their statements as a query of its own (<see cref="HarnessText.Statements"/>), and
/// the first read after an update reaches them, 2 hours back. <see cref="HarnessStatements.IsRunners"/> takes them for the
/// runner's by their text in <see cref="HarnessText.Normalize"/>'s form, which drops comments, so a block today's observer
/// sends with the marker gives its earlier form without it. RCA-XE-00, the one of those blocks that has changed since, has
/// its earlier forms here by themselves. Built from the runner's own catalog, never from what the workload plans or
/// reports. A runner test fails when a statement of those blocks, as edd01c86 or a later release sent it, isn't matched.
/// </summary>
internal static class SqlObserverStatements
{
    /// <summary>
    /// The SQL Server blocks the release's runner sends: on T3, RCA-XE-03 and 04 instead of 01 and 02, and RCA-XE-05's
    /// database-scoped form (<see cref="CaptureCatalog.DatabaseScopedDrop"/>).
    /// </summary>
    internal static readonly IReadOnlyList<string> Blocks =
    [
        "RCA-SQL-01", "RCA-SQL-02", "RCA-SQL-09", "RCA-SQL-12", "RCA-AZ-01",
        "RCA-XE-00", "RCA-XE-01", "RCA-XE-02", "RCA-XE-03", "RCA-XE-04", "RCA-XE-05",
    ];

    /// <summary>
    /// RCA-XE-00's earlier forms, each the block as the runner sent it: edd01c86's join to sys.dm_xe_objects, which took
    /// about 30 s of CPU at each observer start until 2026-11-23, and f16b9cb9's, which reads sys.dm_xe_object_columns alone.
    /// </summary>
    internal static readonly IReadOnlyList<string> EarlierRcaXe00 =
    [
        """
        SET NOCOUNT ON;
        SELECT
            event_name  = o.name,
            column_name = c.name,
            c.type_name,
            c.column_type
        FROM sys.dm_xe_objects AS o
        JOIN sys.dm_xe_object_columns AS c ON c.object_name = o.name AND c.object_package_guid = o.package_guid
        WHERE o.object_type = N'event'
          AND o.name IN (N'error_reported', N'attention', N'lock_escalation', N'xml_deadlock_report', N'database_xml_deadlock_report')
          AND c.column_type = N'data'
        ORDER BY o.name, c.name;
        """,
        """
        SET NOCOUNT ON;
        SELECT
            event_name  = c.object_name,
            column_name = c.name,
            c.type_name,
            c.column_type
        FROM sys.dm_xe_object_columns AS c
        WHERE c.object_name IN (N'error_reported', N'attention', N'lock_escalation', N'xml_deadlock_report', N'database_xml_deadlock_report')
          AND c.column_type = N'data'
        ORDER BY c.object_name, c.name;
        """,
    ];

    /// <summary>Every statement of those blocks, as today's catalog has them, and of RCA-XE-00's earlier forms, as Query Store keeps it.</summary>
    public static IReadOnlyList<string> All { get; } = Build();

    /// <summary>A block today's catalog no longer has gives nothing here, so the runner's test fails until its earlier forms are listed, as RCA-XE-00's are.</summary>
    private static string[] Build()
    {
        var catalog = CaptureCatalog.All;
        var batches = Blocks.Where(catalog.ContainsKey).Select(id => catalog[id]).ToList();
        if (catalog.ContainsKey("RCA-XE-05"))
        {
            batches.Add(CaptureCatalog.DatabaseScopedDrop());
        }

        return [.. batches.Concat(EarlierRcaXe00).SelectMany(HarnessText.Statements).Distinct(StringComparer.Ordinal)];
    }
}
