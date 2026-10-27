using ContosoCare.Workload.Runs;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>The session plans of the Phase 25b orchestrations that don't need a server: the blocking chain's shape and the slow client's pace.</summary>
public sealed class OrchestrationTests
{
    [Theory]
    [InlineData(3, 1, 2)]
    [InlineData(4, 2, 6)]
    [InlineData(6, 4, 20)]
    public void AChainHasOneLinkPerLevelBelowTheHeadForEachBranch(int depth, int branches, int expected)
    {
        var links = ChainTopology.Links(depth, branches);

        Assert.Equal(expected, links.Count);
        Assert.Equal(Enumerable.Range(1, expected), links.Select(l => l.Index));
        Assert.All(links, l => Assert.InRange(l.Level, 2, depth));
        Assert.All(links, l => Assert.InRange(l.Branch, 1, branches));
        Assert.Equal(links.Count, links.Select(l => (l.Level, l.Branch)).Distinct().Count());
    }

    [Fact]
    public void EachLevelStartsTwoSecondsAfterTheOneAboveIt()
    {
        var links = ChainTopology.Links(5, 2);

        foreach (var link in links)
        {
            Assert.Equal(TimeSpan.FromSeconds(2 * (link.Level - 1)), link.StartDelay);
        }

        // Every level starts after the level it waits for.
        Assert.True(links.Where(l => l.Level == 3).Min(l => l.StartDelay) > links.Where(l => l.Level == 2).Max(l => l.StartDelay));
    }

    [Theory]
    [InlineData(2, 1)]
    [InlineData(7, 1)]
    [InlineData(4, 0)]
    [InlineData(4, 5)]
    public void AChainOutsideItsBoundsIsRefused(int depth, int branches)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => ChainTopology.Links(depth, branches));
    }

    [Theory]
    [InlineData(1, 100)]
    [InlineData(5, 500)]
    [InlineData(10, 1000)]
    [InlineData(0, 100)]
    [InlineData(99, 1000)]
    public void TheSlowClientPausesLongerAtHigherIntensity(int intensity, int expectedMilliseconds)
    {
        Assert.Equal(TimeSpan.FromMilliseconds(expectedMilliseconds), SlowConsumer.PauseFor(intensity));
        Assert.Equal(25, SlowConsumer.RowsPerPause);
    }

    [Fact]
    public void PairAndChainLabelsArentSummedAsCounters()
    {
        var outcomes = new List<WorkerOutcome>
        {
            new("side2", 1, 51, new Dictionary<string, object?> { ["pair"] = 1, ["side"] = (byte)2, ["deadlock_victim"] = 3 }, null, false),
            new("side2", 2, 52, new Dictionary<string, object?> { ["pair"] = 2, ["side"] = (byte)2, ["deadlock_victim"] = 2 }, null, false),
            new("link", 1, 53, new Dictionary<string, object?> { ["level"] = 2, ["branch"] = 1, ["longest_wait_ms"] = 900 }, null, false),
            new("link", 2, 54, new Dictionary<string, object?> { ["level"] = 3, ["branch"] = 1, ["longest_wait_ms"] = 1200 }, null, false),
        };

        var summary = ScenarioRunner.Summarize(outcomes);

        Assert.Contains("side2 x2: deadlock_victim=5", summary, StringComparison.Ordinal);
        Assert.Contains("link x2: longest_wait_ms=1200", summary, StringComparison.Ordinal);
        Assert.DoesNotContain("pair=", summary, StringComparison.Ordinal);
        Assert.DoesNotContain("level=", summary, StringComparison.Ordinal);
    }
}
