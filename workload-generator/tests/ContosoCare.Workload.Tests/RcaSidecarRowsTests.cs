using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.Store;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// A span keeps the sidecar's rows beside its evidence files until they're sealed (rca/README.md, The sidecar), under a
/// name no evidence export reads: edd01c86's Exporter, and with it every older runner, takes each <c>*.jsonl</c> in a span
/// as a target's file, so sidecar rows there would end up in an evidence document.
/// </summary>
public sealed class RcaSidecarRowsTests : IDisposable
{
    private const string Session = "5f1c0e7a9b2d4c6e8f0a1b3c5d7e9f21";

    private static readonly DateTimeOffset From = new(2026, 11, 24, 8, 0, 0, TimeSpan.Zero);

    private readonly string root = Path.Combine(Path.GetTempPath(), "rca-rows-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void TheEvidenceExportsGlobNeverTakesTheSidecarsRowFile()
    {
        // Exporter.Read's glob for a span's target files at edd01c86, which an older runner keeps using after a rollback.
        var folder = Directory.CreateDirectory(Path.Combine(root, "glob")).FullName;
        File.WriteAllText(Path.Combine(folder, RcaContract.SidecarRowsFile("T3")), "{}");
        File.WriteAllText(Path.Combine(folder, "T3.jsonl"), "{}");

        var taken = Directory.GetFiles(folder, "*.jsonl").Select(Path.GetFileName).ToList();

        Assert.Equal("sidecar-T3.rows", RcaContract.SidecarRowsFile("T3"));
        Assert.Equal(["T3.jsonl"], taken);
    }

    [Fact]
    public void ASpansSidecarRowsChangeNothingTheEvidenceExportWrites()
    {
        var plain = Export(Path.Combine(root, "plain"), withSidecarRows: false);
        var beside = Export(Path.Combine(root, "beside"), withSidecarRows: true);

        Assert.NotEmpty(plain);
        Assert.Equal(plain, beside);
    }

    private static List<string> Export(string storeRoot, bool withSidecarRows)
    {
        var clock = new ManualTime(From);
        var store = new EvidenceStore(storeRoot, clock, host: "sqlvm01");
        var span = store.Open(From);
        span.Began("T1", From);
        for (var i = 0; i < 4; i++)
        {
            var at = From.AddSeconds(30 * (i + 1));
            span.Write(new CaptureRow(RcaContract.Resource, "T1", at, "RCA-SQL-01", sentinel: true)
                .Set("at_utc", at)
                .Set("target", "T1")
                .Set("source", "RCA-SQL-01")
                .Set("metric", "cpu_percent")
                .Set("value", 20.0 + i));
        }

        span.Watermark("T1", From.AddMinutes(2));
        span.Ended("T1", From.AddMinutes(2));
        if (withSidecarRows)
        {
            File.WriteAllText(Path.Combine(span.Directory, RcaContract.SidecarRowsFile("T3")), """{"table":"rca_query_stats","target":"T3"}""" + "\n");
        }

        span.Close(From.AddMinutes(2));
        clock.Set(From.AddMinutes(4));
        var result = new Exporter(store, RunnerLog.Null, "1.0.0").Export(Session, final: true, TimeSpan.Zero);
        return [.. result.Documents.Select(d => d.DocumentId + " " + d.Parts + " " + d.Sha256)];
    }
}
