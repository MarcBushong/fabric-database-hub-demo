using ContosoCare.Workload.Rca.Observer;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The capture triggers' timing (rca/README.md, Capture triggers) and the self-throttling (ADR 0031): pure logic, so the
/// cadence is tested without a database.
/// </summary>
public sealed class RcaTriggerTests
{
    private static readonly DateTimeOffset T0 = new(2026, 11, 20, 16, 52, 30, TimeSpan.Zero);

    [Fact]
    public void BlockingStartsFromTheSentinelAndEnds60SecondsAfterTheLastBlockedSample()
    {
        var trigger = new EpisodeTrigger(new EpisodeIds("T1"), TimeSpan.FromSeconds(60));

        Assert.Equal(EpisodeChange.None, trigger.Observe(T0.AddSeconds(-30), false, true, () => "none"));
        Assert.Equal(EpisodeChange.Started, trigger.Observe(T0, true, false, () => "processes_blocked 7 >= 1"));
        Assert.Equal("T1-20261120T165230Z", trigger.Current!.Id);
        Assert.Equal("processes_blocked 7 >= 1", trigger.Current.StartDetail);

        // Detail samples every 10 s: blocked until 17:00:40, then clear.
        var lastBlocked = T0.AddSeconds(490);
        for (var at = T0.AddSeconds(10); at <= lastBlocked; at = at.AddSeconds(10))
        {
            Assert.Equal(EpisodeChange.None, trigger.Observe(at, true, false, () => string.Empty, canStart: false));
        }

        for (var at = lastBlocked.AddSeconds(10); at < lastBlocked.AddSeconds(60); at = at.AddSeconds(10))
        {
            Assert.Equal(EpisodeChange.None, trigger.Observe(at, false, true, () => string.Empty, canStart: false));
        }

        Assert.Equal(EpisodeChange.Ended, trigger.Observe(lastBlocked.AddSeconds(60), false, true, () => string.Empty, canStart: false));
        Assert.Equal(new DateTimeOffset(2026, 11, 20, 17, 1, 40, TimeSpan.Zero), lastBlocked.AddSeconds(60));
        Assert.NotNull(trigger.Finish());
        Assert.Null(trigger.Current);
    }

    [Fact]
    public void ADetailSampleNeverStartsAnEpisode()
    {
        var trigger = new EpisodeTrigger(new EpisodeIds("T1"), TimeSpan.FromSeconds(60));

        Assert.Equal(EpisodeChange.None, trigger.Observe(T0, true, false, () => "x", canStart: false));
        Assert.Null(trigger.Current);
    }

    [Fact]
    public void ReplayStallsNeedBothSignalsAndEndAfterThreeSamplesUnderFiveSeconds()
    {
        var trigger = new EpisodeTrigger(new EpisodeIds("T4-replica"), quietFor: null, clearSamples: 3);
        static bool Stalled(double since, double bytes) => since >= 30 && bytes > 0;

        // An idle primary: nothing to replay, however long since the last replayed transaction.
        Assert.Equal(EpisodeChange.None, trigger.Observe(T0, Stalled(600, 0), false, () => "idle"));
        Assert.Equal(EpisodeChange.None, trigger.Observe(T0.AddSeconds(30), Stalled(15.4, 15300), false, () => "early"));
        Assert.Equal(EpisodeChange.Started, trigger.Observe(T0.AddSeconds(60), Stalled(45.4, 45900), false, () => "stalled"));

        Assert.Equal(EpisodeChange.None, trigger.Observe(T0.AddSeconds(65), false, 0.9 < 5, () => string.Empty, canStart: false));
        Assert.Equal(EpisodeChange.None, trigger.Observe(T0.AddSeconds(70), false, 12 < 5, () => string.Empty, canStart: false));
        Assert.Equal(EpisodeChange.None, trigger.Observe(T0.AddSeconds(75), false, 0.4 < 5, () => string.Empty, canStart: false));
        Assert.Equal(EpisodeChange.None, trigger.Observe(T0.AddSeconds(80), false, 0.4 < 5, () => string.Empty, canStart: false));
        Assert.Equal(EpisodeChange.Ended, trigger.Observe(T0.AddSeconds(85), false, 0.4 < 5, () => string.Empty, canStart: false));
    }

    [Fact]
    public void ConnectionsStartAt80PercentAndEndAfter60SecondsUnder70()
    {
        var trigger = new EpisodeTrigger(new EpisodeIds("T4"), TimeSpan.FromSeconds(60));
        const double limit = 47;

        Assert.Equal(EpisodeChange.None, trigger.Observe(T0, 37 >= 0.8 * limit, 37 < 0.7 * limit, () => "x"));
        Assert.Equal(EpisodeChange.Started, trigger.Observe(T0.AddSeconds(30), 38 >= 0.8 * limit, 38 < 0.7 * limit, () => "x"));

        // 75 % is under the start but not under the end: the episode goes on, and its quiet time starts over.
        Assert.Equal(EpisodeChange.None, trigger.Observe(T0.AddSeconds(40), 35 >= 0.8 * limit, 35 < 0.7 * limit, () => "x"));
        Assert.Equal(EpisodeChange.None, trigger.Observe(T0.AddSeconds(50), 20 >= 0.8 * limit, 20 < 0.7 * limit, () => "x"));
        Assert.Equal(EpisodeChange.None, trigger.Observe(T0.AddSeconds(90), 20 >= 0.8 * limit, 20 < 0.7 * limit, () => "x"));
        Assert.Equal(EpisodeChange.Ended, trigger.Observe(T0.AddSeconds(100), 20 >= 0.8 * limit, 20 < 0.7 * limit, () => "x"));
    }

    [Fact]
    public void EpisodesOnOneTargetGetDistinctIds()
    {
        var ids = new EpisodeIds("T3");

        Assert.Equal("T3-20261120T165230Z", ids.Next(T0.AddMilliseconds(400)));
        Assert.Equal("T3-20261120T165231Z", ids.Next(T0));
        Assert.Equal("T4-replica-20261120T165230Z", new EpisodeIds("T4-replica").Next(T0));
    }

    [Fact]
    public void ASlowSampleHalvesTheCadenceAndThreeInARowStopDetail()
    {
        var cadence = new Cadence(TimeSpan.FromSeconds(2));

        Assert.Equal(CadenceChange.None, cadence.Record(TimeSpan.FromMilliseconds(40)));
        Assert.Equal(CadenceChange.Slowed, cadence.Record(TimeSpan.FromSeconds(2.5)));
        Assert.Equal(TimeSpan.FromSeconds(60), cadence.Scale(TimeSpan.FromSeconds(30)));
        Assert.Equal(CadenceChange.Slowed, cadence.Record(TimeSpan.FromSeconds(3)));
        Assert.False(cadence.DetailStopped);
        Assert.Equal(CadenceChange.DetailStopped, cadence.Record(TimeSpan.FromSeconds(10)));
        Assert.True(cadence.DetailStopped);
        Assert.Equal(TimeSpan.FromSeconds(240), cadence.Scale(TimeSpan.FromSeconds(30)));

        // Three quick samples in a row win back one step at a time; detail stays stopped.
        Assert.Equal(CadenceChange.None, cadence.Record(TimeSpan.FromMilliseconds(5)));
        Assert.Equal(CadenceChange.None, cadence.Record(TimeSpan.FromMilliseconds(5)));
        Assert.Equal(CadenceChange.Recovered, cadence.Record(TimeSpan.FromMilliseconds(5)));
        Assert.Equal(4, cadence.Factor);
        Assert.True(cadence.DetailStopped);
    }

    [Fact]
    public void TheCadenceNeverSlowsBeyondEightTimes()
    {
        var cadence = new Cadence(TimeSpan.FromSeconds(2));
        for (var i = 0; i < 10; i++)
        {
            cadence.Record(TimeSpan.FromSeconds(5));
        }

        Assert.Equal(8, cadence.Factor);
    }

    [Fact]
    public void CumulativeCountersAreDiffedAndARestartIsNoDelta()
    {
        var deltas = new CounterDeltas();

        Assert.Null(deltas.Next("deadlocks", 10));
        Assert.Equal(0, deltas.Next("deadlocks", 10));
        Assert.Equal(3, deltas.Next("deadlocks", 13));
        Assert.Null(deltas.Next("deadlocks", 2));
        Assert.Equal(1, deltas.Next("deadlocks", 3));
        Assert.Null(deltas.Next("lock_timeouts", null));
    }

    [Fact]
    public void TheMedianIsTheMiddleValue()
    {
        Assert.Equal(0, Median.Of([]));
        Assert.Equal(2, Median.Of([5, 1, 2]));
        Assert.Equal(2.5, Median.Of([4, 1, 2, 3]));
    }
}
