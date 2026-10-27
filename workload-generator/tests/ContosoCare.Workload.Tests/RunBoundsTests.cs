using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Runs;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>The runner's layer of the bounds: clamping to the scenario's limits, the global cap, and --not-after.</summary>
public sealed class RunBoundsTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 20, 17, 0, 0, TimeSpan.Zero);

    private static ScenarioDefinition Scenario(string id) => ScenarioCatalog.Default.Get(id);

    [Fact]
    public void DefaultsComeFromTheScenario()
    {
        var scenario = Scenario("cpu-pressure");

        var plan = RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T2 }, Now);

        Assert.Equal(TimeSpan.FromSeconds(scenario.Duration.DefaultSeconds), plan.Duration);
        Assert.Equal(scenario.Concurrency.Default, plan.Concurrency);
        Assert.Equal(scenario.Intensity.Default, plan.Intensity);
        Assert.Equal("problem", plan.Parameters["variant"].Text);
        Assert.Empty(plan.Adjustments);
    }

    [Fact]
    public void DurationIsClampedToTheScenarioMaximum()
    {
        var scenario = Scenario("locking-blocking");

        var plan = RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T1, Duration = TimeSpan.FromHours(3) }, Now);

        Assert.Equal(TimeSpan.FromSeconds(scenario.Duration.MaxSeconds), plan.Duration);
        Assert.Contains(plan.Adjustments, a => a.Contains("scenario's maximum", StringComparison.Ordinal));
    }

    [Fact]
    public void NoScenarioExceedsTheGlobalCap()
    {
        foreach (var scenario in ScenarioCatalog.Default.All)
        {
            foreach (var target in Enum.GetValues<DemoTarget>().Where(scenario.AppliesTo))
            {
                var plan = RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = target, Duration = TimeSpan.FromHours(24) }, Now);

                Assert.True(plan.Duration <= TimeSpan.FromSeconds(RunLimits.GlobalMaximumSeconds), $"{scenario.Id} on {target}");
            }
        }
    }

    [Fact]
    public void DurationEndsBeforeNotAfter()
    {
        var scenario = Scenario("healthy-baseline");
        var notAfter = Now.AddMinutes(12);

        var plan = RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T1, Duration = TimeSpan.FromHours(1), NotAfter = notAfter }, Now);

        Assert.Equal(TimeSpan.FromMinutes(10), plan.Duration);
        Assert.True(Now + plan.Duration <= notAfter - RunLimits.ShutdownMargin);
        Assert.Contains(plan.Adjustments, a => a.Contains("--not-after", StringComparison.Ordinal));
    }

    [Fact]
    public void ARunTooCloseToTheShutdownIsRefused()
    {
        var scenario = Scenario("healthy-baseline");

        var error = Assert.Throws<ScenarioRequestException>(() =>
            RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T1, NotAfter = Now.AddMinutes(2).AddSeconds(20) }, Now));

        Assert.Contains("Not enough time", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void TooShortARunIsRefused()
    {
        var scenario = Scenario("healthy-baseline");

        Assert.Throws<ScenarioRequestException>(() =>
            RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T1, Duration = TimeSpan.FromSeconds(5) }, Now));
    }

    [Theory]
    [InlineData(0, 1)]
    [InlineData(500, 16)]
    public void ConcurrencyIsClamped(int requested, int expected)
    {
        var scenario = Scenario("cpu-pressure");

        var plan = RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T2, Concurrency = requested }, Now);

        Assert.Equal(expected, plan.Concurrency);
        Assert.Contains(plan.Adjustments, a => a.StartsWith("Concurrency clamped", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData(-3, 1)]
    [InlineData(99, 10)]
    public void IntensityIsClamped(int requested, int expected)
    {
        var scenario = Scenario("missing-index");

        var plan = RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T2, Intensity = requested }, Now);

        Assert.Equal(expected, plan.Intensity);
    }

    [Fact]
    public void ParameterDefaultsCanDependOnTheTarget()
    {
        var scenario = Scenario("io-pressure");

        var t2 = RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T2 }, Now);
        var t3 = RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T3 }, Now);

        Assert.Equal(1024, t2.Parameters["scratchMb"].Integer);
        Assert.Equal(256, t3.Parameters["scratchMb"].Integer);
    }

    [Theory]
    [InlineData("scratchMb", "63")]
    [InlineData("scratchMb", "6145")]
    [InlineData("scratchMb", "lots")]
    public void ParameterRangesAndTypesAreEnforced(string name, string value)
    {
        var scenario = Scenario("io-pressure");
        var request = new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T2, Parameters = new Dictionary<string, string> { [name] = value } };

        Assert.Throws<ScenarioRequestException>(() => RunBounds.Plan(scenario, request, Now));
    }

    [Fact]
    public void BooleanAndEnumParametersAreParsed()
    {
        var scenario = Scenario("locking-blocking");
        var request = new RunRequest
        {
            ScenarioId = scenario.Id,
            Target = DemoTarget.T1,
            Parameters = new Dictionary<string, string> { ["deadlock"] = "true", ["holder"] = "active-wait", ["holdSeconds"] = "45" },
        };

        var plan = RunBounds.Plan(scenario, request, Now);

        Assert.True(plan.Parameters["deadlock"].Boolean);
        Assert.Equal("active-wait", plan.Parameters["holder"].Text);
        Assert.Equal(45, plan.Parameters["holdSeconds"].Integer);
    }

    [Fact]
    public void ParametersJsonRecordsWhatTheRunUsed()
    {
        var scenario = Scenario("cpu-pressure");
        var plan = RunBounds.Plan(scenario, new RunRequest { ScenarioId = scenario.Id, Target = DemoTarget.T2, Duration = TimeSpan.FromMinutes(5), NotAfter = Now.AddHours(2) }, Now);

        using var json = System.Text.Json.JsonDocument.Parse(plan.ParametersJson());

        Assert.Equal(300, json.RootElement.GetProperty("durationSeconds").GetInt32());
        Assert.Equal("problem", json.RootElement.GetProperty("parameters").GetProperty("variant").GetString());
        Assert.Equal("2026-10-20T19:00:00Z", json.RootElement.GetProperty("notAfter").GetString());
        Assert.True(plan.ParametersJson().Length <= 2000);
    }
}
