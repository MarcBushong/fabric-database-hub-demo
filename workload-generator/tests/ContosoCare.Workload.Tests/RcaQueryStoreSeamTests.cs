using System.Data;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.QueryStore;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The seams the sidecar's reads share (rca/README.md, The sidecar): a block's parameters, the observer's run with them,
/// the sink that takes only the sidecar's tables, and Query Store's schedule.
/// </summary>
public sealed class RcaQueryStoreSeamTests
{
    private static readonly DateTimeOffset Since = new(2026, 11, 24, 8, 0, 0, TimeSpan.Zero);

    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    private static readonly string[] Visits = ["visits"];

    private static readonly int[] TwoPids = [1, 2];

    private static readonly int[] OnePid = [7];

    private static readonly long[] TwoQueries = [1L, 2L];

    [Fact]
    public void NamedParametersEachNeedANameOfTheirOwnThatStartsWithAt()
    {
        var parameters = CaptureParameters.Named(("@since", Since), ("@final", true));

        Assert.True(parameters.IsNamed);
        Assert.Equal(true, parameters.Value("@FINAL"));
        Assert.Null(parameters.Value("@plans"));
        Assert.Throws<ArgumentException>(() => CaptureParameters.Named(("since", Since)));
        Assert.Throws<ArgumentException>(() => CaptureParameters.Named(("@since", Since), ("@Since", Since)));
    }

    [Fact]
    public void PositionalParametersKeepTheirOrderAndAnArrayStaysOneValue()
    {
        string[] functions = ["usp_a", "usp_b"];
        var parameters = CaptureParameters.Positional("contosocare", Since, functions, Array.Empty<string>(), Visits);

        Assert.False(parameters.IsNamed);
        Assert.Equal(5, parameters.Count);
        Assert.Same(functions, parameters[2].Value);
        Assert.Same(TwoPids, Assert.Single(CaptureParameters.Positional(TwoPids)).Value);
        Assert.Empty(CaptureParameters.None);
    }

    [Fact]
    public async Task AConnectionWithoutTheParametersMethodRunsBlocksWithNoneOrPidsAndRefusesOthers()
    {
        var old = new PidsOnlyConnection();
        ICaptureConnection connection = old;

        await connection.QueryAsync("RCA-PG-10", "SELECT 1;", CaptureParameters.None, Timeout, CancellationToken.None);
        await connection.QueryAsync("RCA-PG-11", "SELECT 1;", CaptureParameters.Positional(OnePid), Timeout, CancellationToken.None);
        await Assert.ThrowsAsync<NotSupportedException>(() => connection.QueryAsync("RCA-PG-14", "SELECT 1;", CaptureParameters.Positional("contosocare", Since), Timeout, CancellationToken.None));

        Assert.Equal(["RCA-PG-10", "RCA-PG-11"], old.Calls.Select(c => c.BlockId));
        Assert.Null(old.Calls[0].Parameter);
        Assert.Equal([7], old.Calls[1].Parameter!);
    }

    [Fact]
    public void TSqlParametersStateTheirTypesAndTimesAreUtc()
    {
        var since = SqlCaptureConnector.Bind("@since", Since.ToOffset(TimeSpan.FromHours(-5)));
        Assert.Equal(SqlDbType.DateTimeOffset, since.SqlDbType);
        Assert.Equal(TimeSpan.Zero, ((DateTimeOffset)since.Value).Offset);
        Assert.Equal(Since, (DateTimeOffset)since.Value);
        Assert.Equal(SqlDbType.Bit, SqlCaptureConnector.Bind("@final", true).SqlDbType);
        var plans = SqlCaptureConnector.Bind("@plans", "1,2");
        Assert.Equal(SqlDbType.NVarChar, plans.SqlDbType);
        Assert.Equal(-1, plans.Size);
        Assert.Equal(DBNull.Value, SqlCaptureConnector.Bind("@with_plan", null).Value);
        Assert.Throws<ArgumentException>(() => SqlCaptureConnector.Bind("@queries", TwoQueries));
    }

    [Fact]
    public async Task AnObserverRunsABlockWithItsParametersAsTheCatalogHasIt()
    {
        var connector = new ScriptedConnector((_, _) => []);
        connector.ParameterAnswer = (block, parameters) => [RcaTestKit.Row(("block", block), ("final", parameters.Value("@final")))];
        var observer = new ProbeObserver(connector);

        var rows = await observer.Run("RCA-SQL-10", Since, CaptureParameters.Named(("@since", Since), ("@final", false)));

        var call = Assert.Single(connector.ParameterCalls);
        Assert.Equal("RCA-SQL-10", call.BlockId);
        Assert.Equal(Since, call.Parameters.Value("@since"));
        Assert.Equal(CaptureCatalog.Get("RCA-SQL-10"), Assert.Single(connector.Calls).Text);
        Assert.Equal(false, Assert.Single(rows!).Get("final"));
    }

    [Fact]
    public void TheDefaultSinkTakesOnlyTheSidecarsTables()
    {
        foreach (var table in RcaContract.SidecarTables)
        {
            NullSidecarSink.Instance.Write(new CaptureRow(table.Name, "T1", Since, "RCA-SQL-10"));
        }

        Assert.Throws<InvalidOperationException>(() => NullSidecarSink.Instance.Write(new CaptureRow(RcaContract.Sessions, "T1", Since, "RCA-SQL-01")));
        Assert.Throws<InvalidOperationException>(() => NullSidecarSink.Instance.Write(new CaptureRow("rca_unknown", "T1", Since, "RCA-SQL-01")));
        Assert.DoesNotContain(RcaContract.Tables, t => t.IsSidecar);
        Assert.Equal(6, RcaContract.SidecarTables.Count);
    }

    [Fact]
    public void TheScheduleReadsTwoMinutesAfterEachIntervalEndsAndLooksBackTwoHours()
    {
        var schedule = QueryStoreSchedule.Default;
        var at = new DateTimeOffset(2026, 11, 24, 10, 3, 0, TimeSpan.Zero);

        Assert.Equal(new DateTimeOffset(2026, 11, 24, 10, 15, 0, TimeSpan.Zero), schedule.IntervalEnd(at));
        Assert.Equal(new DateTimeOffset(2026, 11, 24, 10, 30, 0, TimeSpan.Zero), schedule.IntervalEnd(at.AddMinutes(12)));
        Assert.Equal(new DateTimeOffset(2026, 11, 24, 10, 17, 0, TimeSpan.Zero), schedule.NextRead(at));
        Assert.Equal(new DateTimeOffset(2026, 11, 24, 10, 17, 0, TimeSpan.Zero), schedule.NextRead(at.AddMinutes(13)));
        Assert.Equal(new DateTimeOffset(2026, 11, 24, 10, 32, 0, TimeSpan.Zero), schedule.NextRead(at.AddMinutes(14)));
        Assert.Equal(schedule.NextRead(at), schedule.NextRead(at.ToOffset(TimeSpan.FromHours(-5))));
        Assert.Equal(at.AddHours(-2), schedule.FirstSince(at));
        Assert.Equal(TimeSpan.FromMinutes(5), schedule.WithInterval(TimeSpan.FromMinutes(5)).Interval);
        Assert.Same(schedule, schedule.WithInterval(TimeSpan.FromMinutes(15)));
        Assert.Throws<ArgumentOutOfRangeException>(() => new QueryStoreSchedule(TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(2), TimeSpan.Zero));
    }

    /// <summary>A connection from before the parameters method: it implements only the pids' one.</summary>
    private sealed class PidsOnlyConnection : ICaptureConnection
    {
        public List<(string BlockId, int[]? Parameter)> Calls { get; } = [];

        public Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken)
        {
            Calls.Add((blockId, parameter));
            return Task.FromResult<IReadOnlyList<CaptureValues>>([]);
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    /// <summary>An observer that only runs what the test asks.</summary>
    private sealed class ProbeObserver(ICaptureConnector connector) : TargetObserver("T1", DemoTarget.T1, connector, new ObserverOptions(), RunnerLog.Null, "the fix")
    {
        public Task<IReadOnlyList<CaptureValues>?> Run(string blockId, DateTimeOffset now, CaptureParameters parameters) => RunAsync(blockId, now, parameters, CancellationToken.None);

        public override Task<DateTimeOffset> TickAsync(DateTimeOffset now, CancellationToken cancellationToken) => Task.FromResult(now);

        protected override Task StartAsync(DateTimeOffset now, CancellationToken cancellationToken) => Task.CompletedTask;

        protected override Task StopAsync(DateTimeOffset now, CancellationToken cancellationToken) => Task.CompletedTask;
    }
}
