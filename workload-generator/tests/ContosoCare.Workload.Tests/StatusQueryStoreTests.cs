using System.Text.Json.Nodes;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Sql;
using Microsoft.SqlServer.TransactSql.ScriptDom;
using Xunit;
using CommandLineDefinition = ContosoCare.Workload.Cli.CommandLine;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// Query Store's state in T1 to T3's <c>status --json</c> (2026-11-23), which validate.ps1's T1.QUERYSTORE and
/// T2.QUERYSTORE read: last but one, before the host node, so a Run Command's output tail keeps both.
/// </summary>
public sealed class StatusQueryStoreTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 23, 15, 0, 0, TimeSpan.Zero);

    private static JsonObject Status(QueryStoreRead queryStore)
    {
        var profile = new ProfileState("showcase", Now.AddMinutes(-30), "tester", Now.AddHours(1), null);
        var run = new RunRecord("20261123150000-t1-a1b2c3", "healthy-baseline", "T1", "Running", Now.AddMinutes(-5), Now.AddMinutes(25), null, 1800, 4, 3, null, "showcase", "profile:showcase");
        var host = new HostLaneVerdict("Pass", "The profile host polls T1.", new HostLanesRead("host-lanes.json", null, null), null, null, Now);
        return CommandLineDefinition.SqlStatusNode(DemoTarget.T1, profile, "showcase until 16:00", [run], [], [], new SpaceHeadroom(900, 400), queryStore, host);
    }

    [Fact]
    public void StatusJsonPutsQueryStoreLastButOneBeforeTheHost()
    {
        var json = Status(new QueryStoreRead(new QueryStoreState("READ_WRITE", "READ_WRITE", 0, "AUTO", 15, 12, 1024), null));

        Assert.Equal(["target", "profile", "runs", "stopRequests", "demoSessions", "dataHeadroomMb", "logHeadroomMb", "queryStore", "host"], json.Select(p => p.Key));
        var queryStore = json["queryStore"]!.AsObject();
        Assert.Equal(["actualState", "desiredState", "readonlyReason", "captureMode", "intervalMinutes", "storageMb", "maxStorageMb"], queryStore.Select(p => p.Key));
        Assert.Equal("READ_WRITE", queryStore["actualState"]!.GetValue<string>());
        Assert.Equal("READ_WRITE", queryStore["desiredState"]!.GetValue<string>());
        Assert.Equal(0, queryStore["readonlyReason"]!.GetValue<long>());
        Assert.Equal("AUTO", queryStore["captureMode"]!.GetValue<string>());
        Assert.Equal(15, queryStore["intervalMinutes"]!.GetValue<long>());
        Assert.Equal(12, queryStore["storageMb"]!.GetValue<long>());
        Assert.Equal(1024, queryStore["maxStorageMb"]!.GetValue<long>());
    }

    [Fact]
    public void StatusJsonSaysWhyQueryStoreWasntReadWithinItsBound()
    {
        var json = Status(new QueryStoreRead(null, "300: VIEW DATABASE STATE permission denied in database 'ContosoCare'. " + new string('x', 400)));

        var queryStore = json["queryStore"]!.AsObject();
        Assert.Equal(["error"], queryStore.Select(p => p.Key));
        var error = queryStore["error"]!.GetValue<string>();
        Assert.StartsWith("300: VIEW DATABASE STATE permission denied", error, StringComparison.Ordinal);
        Assert.Equal(CommandLineDefinition.QueryStoreErrorLength, error.Length);
        Assert.Equal("host", json.Last().Key);
    }

    [Fact]
    public void StatusTextSaysQueryStoresStateAndWhyItsReadOnly()
    {
        Assert.Equal("READ_WRITE (AUTO capture, 15-minute intervals, 12 of 1024 MB)", CommandLineDefinition.QueryStoreText(new QueryStoreRead(new QueryStoreState("READ_WRITE", "READ_WRITE", 0, "AUTO", 15, 12, 1024), null)));
        Assert.Equal("READ_ONLY, desired READ_WRITE, read-only reason 65536 (AUTO capture, 15-minute intervals, 1024 of 1024 MB)", CommandLineDefinition.QueryStoreText(new QueryStoreRead(new QueryStoreState("READ_ONLY", "READ_WRITE", 65536, "AUTO", 15, 1024, 1024), null)));
        Assert.Equal("not read: 300: refused", CommandLineDefinition.QueryStoreText(new QueryStoreRead(null, "300: refused")));
    }

    /// <summary>T3's status row, which validate.ps1's T3.QUERYSTORE reads (Test-DemoT3): Query Store's state, its desired state, the read-only reason, the capture mode, and the storage against its limit, each from sys.database_query_store_options.</summary>
    [Fact]
    public void T3sStatusRowReadsQueryStoresStateColumns()
    {
        var path = RepositoryPaths.Combine("database", "azuresql", "900-status.sql");
        var parser = new TSql160Parser(initialQuotedIdentifiers: true);
        using var reader = new StringReader(File.ReadAllText(path));
        var script = (TSqlScript)parser.Parse(reader, out var errors);
        Assert.Empty(errors);
        var select = script.Batches.SelectMany(b => b.Statements).OfType<SelectStatement>().Last();
        var columns = ((QuerySpecification)select.QueryExpression).SelectElements.OfType<SelectScalarExpression>().ToDictionary(c => c.ColumnName.Value, c => c.Expression, StringComparer.Ordinal);
        var expected = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["query_store_state"] = "actual_state_desc",
            ["query_store_desired_state"] = "desired_state_desc",
            ["query_store_readonly_reason"] = "readonly_reason",
            ["query_store_capture_mode"] = "query_capture_mode_desc",
            ["query_store_storage_mb"] = "current_storage_size_mb",
            ["query_store_max_storage_mb"] = "max_storage_size_mb",
        };
        foreach (var (alias, column) in expected)
        {
            Assert.True(columns.TryGetValue(alias, out var expression), alias);
            var subquery = (QuerySpecification)((ScalarSubquery)expression).QueryExpression;
            Assert.Equal(column, ((ColumnReferenceExpression)((SelectScalarExpression)subquery.SelectElements[0]).Expression).MultiPartIdentifier.Identifiers.Last().Value);
            var source = (NamedTableReference)subquery.FromClause.TableReferences[0];
            Assert.Equal("sys.database_query_store_options", string.Join('.', source.SchemaObject.Identifiers.Select(i => i.Value)));
        }
    }
}
