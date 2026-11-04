using System.Text.Json.Nodes;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Postgres;
using Npgsql;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// connection-surge's step past the limit (2026-11-03): the headroom is filled for a few seconds at most, the server
/// refuses only max_connections' overflow (SQLSTATE 53300), refusals are capped per minute and per run, a sign-in failure
/// ends the surge, and the other T4 lanes retry the refusal they meet meanwhile. The surge itself needs a PostgreSQL
/// server; these cover its bounds with a fake server.
/// </summary>
public sealed class ConnectionSurgeTests
{
    private static readonly DateTimeOffset Start = new(2026, 11, 3, 18, 0, 0, TimeSpan.Zero);

    [Fact]
    public async Task TheBurstFillsTheFreeSlotsThenIsRefusedAndClosesEverythingItOpened()
    {
        var time = new ManualTime(Start);
        var server = new FakeServer(freeSlots: 2);
        var bounds = new SurgeBounds(time);

        var result = await SurgeBurst.RunAsync(server.OpenAsync, bounds, allowance: 2, maxAttempts: 2 + 2 + SurgeBurst.Slack, SurgeBounds.MaxBurst, time, CancellationToken.None);

        Assert.Equal(2, result.Opened);
        Assert.Equal(2, result.Refused);
        Assert.Equal(0, result.Failed);
        Assert.False(result.SignInFailed);
        Assert.Equal(4, server.Attempts);
        Assert.All(server.Opened, connection => Assert.True(connection.Disposed));
        Assert.Equal(2, server.FreeSlots);
        Assert.Equal(2, bounds.RefusedInRun);
    }

    [Fact]
    public async Task TheBurstMakesNoMoreAttemptsThanItsAllowanceAndItsMaximum()
    {
        var time = new ManualTime(Start);
        var bounds = new SurgeBounds(time);

        // More free slots than the headroom: it stops at its maximum, refused or not.
        var roomy = new FakeServer(freeSlots: 50);
        var result = await SurgeBurst.RunAsync(roomy.OpenAsync, bounds, allowance: 2, maxAttempts: 6, SurgeBounds.MaxBurst, time, CancellationToken.None);
        Assert.Equal(6, roomy.Attempts);
        Assert.Equal(0, result.Refused);
        Assert.All(roomy.Opened, connection => Assert.True(connection.Disposed));

        // No free slot: exactly the allowance is refused.
        var full = new FakeServer(freeSlots: 0);
        result = await SurgeBurst.RunAsync(full.OpenAsync, bounds, allowance: 3, maxAttempts: 20, SurgeBounds.MaxBurst, time, CancellationToken.None);
        Assert.Equal(3, full.Attempts);
        Assert.Equal(3, result.Refused);
    }

    [Fact]
    public async Task TheHeadroomIsFilledNoLongerThanTheBurstsTimeLimit()
    {
        // Slow opens: each takes 2 seconds, so no attempt starts once 5 seconds have passed (a real open is also cut off at
        // the limit: see the next test).
        var time = new ManualTime(Start);
        var server = new FakeServer(freeSlots: 10) { OnOpen = () => time.Advance(TimeSpan.FromSeconds(2)) };

        var result = await SurgeBurst.RunAsync(server.OpenAsync, new SurgeBounds(time), allowance: 2, maxAttempts: 14, SurgeBounds.MaxBurst, time, CancellationToken.None);

        Assert.Equal(3, server.Attempts);
        Assert.Equal(0, result.Refused);
        Assert.Equal(0, result.Failed);
        Assert.All(server.Opened, connection => Assert.True(connection.Disposed));
    }

    [Fact]
    public async Task AnOpenThatHangsIsCutOffAtTheTimeLimitWithoutAFailure()
    {
        var server = new FakeServer(freeSlots: 1) { Hang = true };

        var result = await SurgeBurst.RunAsync(server.OpenAsync, new SurgeBounds(TimeProvider.System), allowance: 2, maxAttempts: 5, TimeSpan.FromMilliseconds(200), TimeProvider.System, CancellationToken.None);

        Assert.Equal(1, server.Attempts);
        Assert.Equal(0, result.Opened);
        Assert.Equal(0, result.Refused);
        Assert.Equal(0, result.Failed);
        Assert.Null(result.Error);
        Assert.True(result.HeldFor < TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task ASignInFailureStopsTheBurstAtOnceAndClosesWhatItOpened()
    {
        var time = new ManualTime(Start);
        var server = new FakeServer(freeSlots: 1) { FailWith = new PostgresException("password authentication failed for user \"contosocare_runner\"", "FATAL", "FATAL", "28P01"), FailAfter = 1 };

        var result = await SurgeBurst.RunAsync(server.OpenAsync, new SurgeBounds(time), allowance: 2, maxAttempts: 5, SurgeBounds.MaxBurst, time, CancellationToken.None);

        Assert.True(result.SignInFailed);
        Assert.Equal(1, result.Failed);
        Assert.Equal(0, result.Refused);
        Assert.Equal(2, server.Attempts);
        Assert.Contains("28P01", result.Error, StringComparison.Ordinal);
        Assert.All(server.Opened, connection => Assert.True(connection.Disposed));
    }

    [Fact]
    public async Task AnyOtherFailureStopsTheBurstWithoutCountingARefusal()
    {
        var time = new ManualTime(Start);
        var server = new FakeServer(freeSlots: 5) { FailWith = new PostgresException("the database system is starting up", "FATAL", "FATAL", "57P03"), FailAfter = 0 };

        var result = await SurgeBurst.RunAsync(server.OpenAsync, new SurgeBounds(time), allowance: 2, maxAttempts: 9, SurgeBounds.MaxBurst, time, CancellationToken.None);

        Assert.False(result.SignInFailed);
        Assert.Equal(1, result.Failed);
        Assert.Equal(0, result.Refused);
        Assert.Equal(1, server.Attempts);
    }

    [Theory]
    [InlineData("53300", "Refused")]
    [InlineData("28P01", "SignInFailed")]
    [InlineData("28000", "SignInFailed")]
    [InlineData("57P03", "Failed")]
    [InlineData("08006", "Failed")]
    public void OnlyTheConnectionLimitCountsAsRefused(string sqlState, string expected)
    {
        Assert.Equal(Enum.Parse<SurgeAttemptOutcome>(expected), SurgeBurst.Classify(new PostgresException("message", "FATAL", "FATAL", sqlState)));
        Assert.Equal(SurgeAttemptOutcome.Failed, SurgeBurst.Classify(new IOException("network")));
    }

    [Fact]
    public void RefusalsAreCappedPerMinuteAndPerRun()
    {
        var time = new ManualTime(Start);
        var bounds = new SurgeBounds(time);
        Assert.Equal(2, bounds.Allowance(2));
        for (var i = 0; i < SurgeBounds.MaxRefusedPerMinute; i++)
        {
            bounds.RecordRefused();
        }

        Assert.Equal(0, bounds.Allowance(2));
        Assert.Equal(Start + TimeSpan.FromMinutes(1), bounds.NextAllowedAt());
        time.Advance(TimeSpan.FromSeconds(59));
        Assert.Equal(0, bounds.Allowance(1));
        time.Advance(TimeSpan.FromSeconds(1));
        Assert.Equal(2, bounds.Allowance(2));

        // The run's cap: once it's used up, nothing more, whatever the minute allows.
        while (bounds.RefusedInRun < SurgeBounds.MaxRefusedPerRun)
        {
            time.Advance(TimeSpan.FromMinutes(1));
            for (var i = 0; i < SurgeBounds.MaxRefusedPerMinute && bounds.RefusedInRun < SurgeBounds.MaxRefusedPerRun; i++)
            {
                bounds.RecordRefused();
            }
        }

        time.Advance(TimeSpan.FromMinutes(5));
        Assert.Equal(0, bounds.Allowance(5));
        Assert.Null(bounds.NextAllowedAt());
    }

    [Fact]
    public async Task BurstsAcrossWavesStayWithinTheMinutesCap()
    {
        var time = new ManualTime(Start);
        var bounds = new SurgeBounds(time);
        var refused = 0;
        for (var wave = 0; wave < 4; wave++)
        {
            var allowance = bounds.Allowance(3);
            if (allowance == 0)
            {
                continue;
            }

            var server = new FakeServer(freeSlots: 0);
            refused += (await SurgeBurst.RunAsync(server.OpenAsync, bounds, allowance, 10, SurgeBounds.MaxBurst, time, CancellationToken.None)).Refused;
            time.Advance(TimeSpan.FromSeconds(10));
        }

        Assert.Equal(SurgeBounds.MaxRefusedPerMinute, refused);
    }

    [Fact]
    public void TheOtherT4LanesRetryTheConnectionLimitButNeverASignInFailure()
    {
        Assert.True(PgConnectionOpener.IsTransient(new PostgresException("sorry, too many clients already", "FATAL", "FATAL", "53300")));
        Assert.True(PgConnectionOpener.IsTransient(new PostgresException("remaining connection slots are reserved for roles with the SUPERUSER attribute", "FATAL", "FATAL", "53300")));
        Assert.False(PgConnectionOpener.IsTransient(new PostgresException("password authentication failed", "FATAL", "FATAL", "28P01")));
        Assert.True(PgConnectionOpener.RetryWindow > SurgeBounds.MaxBurst * 10, "a lane's retries outlast the burst");
    }

    [Fact]
    public void TheScenarioStatesTheSameFixedBounds()
    {
        var json = JsonNode.Parse(File.ReadAllText(RepositoryPaths.Combine("scenarios", "connection-surge", "scenario.json")))!;
        var overshoot = json["parameters"]!["overshoot"]!;
        Assert.True(overshoot["maximum"]!.GetValue<int>() <= SurgeBounds.MaxRefusedPerMinute);
        var description = overshoot["description"]!.GetValue<string>();
        Assert.Contains($"{SurgeBounds.MaxRefusedPerMinute} refused attempts in any minute", description, StringComparison.Ordinal);
        Assert.Contains($"{SurgeBounds.MaxRefusedPerRun} in a run", description, StringComparison.Ordinal);
        Assert.Contains($"{SurgeBounds.MaxBurst.TotalSeconds:0} seconds", json["parameters"]!["headroom"]!["description"]!.GetValue<string>(), StringComparison.Ordinal);
        var readme = File.ReadAllText(RepositoryPaths.Combine("scenarios", "connection-surge", "README.md"));
        Assert.Contains($"{SurgeBounds.MaxRefusedPerMinute} refused attempts in any minute and {SurgeBounds.MaxRefusedPerRun} in a run", readme, StringComparison.Ordinal);
        Assert.Contains($"{SurgeBounds.MaxBurst.TotalSeconds:0} seconds at most", readme, StringComparison.Ordinal);
        Assert.Equal((long?)overshoot["maximum"]!.GetValue<long>(), ScenarioCatalog.Default.Get("connection-surge").Parameters["overshoot"].Maximum);
    }

    private sealed class ManualTime(DateTimeOffset start) : TimeProvider
    {
        private long ticks;

        public override long TimestampFrequency => TimeSpan.TicksPerSecond;

        public void Advance(TimeSpan by) => Interlocked.Add(ref ticks, by.Ticks);

        public override DateTimeOffset GetUtcNow() => start + TimeSpan.FromTicks(Interlocked.Read(ref ticks));

        public override long GetTimestamp() => Interlocked.Read(ref ticks);
    }

    private sealed class FakeConnection : IAsyncDisposable
    {
        public bool Disposed { get; private set; }

        public ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }

    /// <summary>A server with a number of free slots: an open takes one, a closed connection gives it back, and none left is SQLSTATE 53300.</summary>
    private sealed class FakeServer(int freeSlots)
    {
        public int FreeSlots { get; private set; } = freeSlots;

        public int Attempts { get; private set; }

        public List<FakeConnection> Opened { get; } = [];

        public Action? OnOpen { get; init; }

        public bool Hang { get; init; }

        public Exception? FailWith { get; init; }

        public int FailAfter { get; init; }

        public async Task<IAsyncDisposable> OpenAsync(CancellationToken cancellationToken)
        {
            Attempts++;
            OnOpen?.Invoke();
            if (Hang)
            {
                await Task.Delay(Timeout.Infinite, cancellationToken);
            }

            if (FailWith is not null && Attempts > FailAfter)
            {
                throw FailWith;
            }

            if (FreeSlots == 0)
            {
                throw new PostgresException("sorry, too many clients already", "FATAL", "FATAL", "53300");
            }

            FreeSlots--;
            var connection = new ReturningConnection(this);
            Opened.Add(connection.Inner);
            return connection;
        }

        private sealed class ReturningConnection(FakeServer server) : IAsyncDisposable
        {
            public FakeConnection Inner { get; } = new();

            public async ValueTask DisposeAsync()
            {
                await Inner.DisposeAsync();
                server.FreeSlots++;
            }
        }
    }
}
