using System.Text.Json;
using ContosoCare.Workload.Catalog;

namespace ContosoCare.Workload.Rca;

/// <summary>One column of an Incident RCA history table: its name, its notebook type, and whether it may be null.</summary>
internal sealed record RcaColumn(string Name, string Type, bool Required);

/// <summary>
/// One Incident RCA history table (rca/history-tables.json): its lakehouse name, its role, the document that carries it
/// (the evidence document or the sidecar), and its columns in order.
/// </summary>
internal sealed record RcaTable(string Name, string Role, int Phase, string Document, IReadOnlyList<RcaColumn> Columns)
{
    public bool IsDetection => Role == "detection";

    /// <summary>True for a table the sidecar carries, which the evidence document never holds (rca/README.md, The sidecar).</summary>
    public bool IsSidecar => Document == "sidecar";

    public RcaColumn? Column(string name) => Columns.FirstOrDefault(c => string.Equals(c.Name, name, StringComparison.Ordinal));
}

/// <summary>
/// The Incident RCA contract (ADR 0031): the history tables' spec, embedded from rca/history-tables.json at build time,
/// so the export encodes exactly the columns and types the notebook, the model, and the app read. Each table names its
/// document: the evidence document, version 1 and unchanged, or the sidecar, its own kind with its own version.
/// </summary>
internal static class RcaContract
{
    /// <summary>The version of rca/history-tables.json this runner was built with: the file's own, not a document's.</summary>
    public const int ContractVersion = 2;

    /// <summary>The version of the evidence documents the runner writes, and of the export index and part lines.</summary>
    public const int Version = 1;

    /// <summary>The evidence document's kind (rca/README.md, The evidence document).</summary>
    public const string DocumentKind = "ContosoCare.RcaEvidence";

    public const string ExportIndexKind = "ContosoCare.RcaExportIndex";

    /// <summary>The part line's marker and format (rca/README.md, Part lines).</summary>
    public const string PartMarker = "DBHUBDEMO-RCA";

    public const string IndexMarker = "DBHUBDEMO-RCA-INDEX";

    public const int PartFormat = 1;

    /// <summary>A part line holds at most 2,400 bytes of gzip, 3,400 characters in all.</summary>
    public const int PartBytes = 2400;

    public const int MaximumLineLength = 3400;

    /// <summary>A document is at most 64 KiB of gzip (28 parts).</summary>
    public const int MaximumDocumentBytes = 64 * 1024;

    public const int MaximumParts = 99;

    /// <summary>At most 20,000 rows per table and 20,000 strings of at most 4,000 characters.</summary>
    public const int MaximumRows = 20000;

    public const int MaximumStrings = 20000;

    public const int MaximumStringLength = 4000;

    /// <summary>The detection tables Phase 1 writes, by lakehouse name.</summary>
    public const string Sessions = "rca_sessions";

    public const string Events = "rca_events";

    public const string Resource = "rca_resource";

    public const string Replica = "rca_replica";

    public const string Coverage = "rca_coverage";

    /// <summary>The sidecar's tables: Query Store's evidence on T1 to T4, and who holds T4's connections.</summary>
    public const string QueryStats = "rca_query_stats";

    public const string QueryWaits = "rca_query_waits";

    public const string QueryPlans = "rca_query_plans";

    public const string QueryEvents = "rca_query_events";

    public const string QueryCoverage = "rca_query_coverage";

    public const string Connections = "rca_connections";

    /// <summary>The sidecar's kind and version (rca/sidecar.schema.json).</summary>
    public const string SidecarKind = "ContosoCare.RcaSidecar";

    public const int SidecarVersion = 1;

    private static readonly Lazy<IReadOnlyList<RcaTable>> Loaded = new(Load);

    /// <summary>The evidence document's tables, which the evidence export writes: never a sidecar's.</summary>
    public static IReadOnlyList<RcaTable> Tables => [.. Loaded.Value.Where(t => !t.IsSidecar)];

    /// <summary>The sidecar's tables.</summary>
    public static IReadOnlyList<RcaTable> SidecarTables => [.. Loaded.Value.Where(t => t.IsSidecar)];

    /// <summary>Any table by its lakehouse name, the evidence document's or the sidecar's.</summary>
    public static RcaTable Table(string name) =>
        Loaded.Value.FirstOrDefault(t => string.Equals(t.Name, name, StringComparison.Ordinal))
        ?? throw new InvalidOperationException($"rca/history-tables.json has no table '{name}'.");

    private static List<RcaTable> Load()
    {
        var text = ScenarioCatalog.ReadResource(typeof(RcaContract).Assembly, "rca/history-tables.json");
        using var document = JsonDocument.Parse(text);
        var version = document.RootElement.GetProperty("version").GetInt32();
        if (version != ContractVersion)
        {
            throw new InvalidOperationException($"The runner was built with rca/history-tables.json version {version}; it reads version {ContractVersion}.");
        }

        var tables = new List<RcaTable>();
        foreach (var table in document.RootElement.GetProperty("tables").EnumerateArray())
        {
            var columns = new List<RcaColumn>();
            foreach (var column in table.GetProperty("columns").EnumerateArray())
            {
                columns.Add(new RcaColumn(
                    column.GetProperty("name").GetString()!,
                    column.GetProperty("type").GetString()!,
                    column.TryGetProperty("required", out var required) && required.GetBoolean()));
            }

            var carrier = table.GetProperty("document").GetString()!;
            if (carrier is not ("evidence" or "sidecar"))
            {
                throw new InvalidOperationException($"rca/history-tables.json's {table.GetProperty("name").GetString()} names an unknown document '{carrier}'.");
            }

            tables.Add(new RcaTable(table.GetProperty("name").GetString()!, table.GetProperty("role").GetString()!, table.GetProperty("phase").GetInt32(), carrier, columns));
        }

        return tables;
    }
}
