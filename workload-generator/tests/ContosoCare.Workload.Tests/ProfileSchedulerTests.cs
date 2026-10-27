using ContosoCare.Workload.Catalog;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>Activity profile schedules: what runs when, and that nothing outlives the profile or --not-after.</summary>
public sealed class ProfileSchedulerTests
{
    private static readonly ActivityProfilesDefinition Definitions = ActivityProfilesDefinition.Default;
    private static readonly ScenarioCatalog Catalog = ScenarioCatalog.Default;
    private static readonly DateTimeOffset SetAt = new(2026, 10, 20, 15, 2, 0, TimeSpan.Zero);

    private static ProfileState State(string name, DateTimeOffset? expiresAt = null, ProfileParameters? parameters = null) =>
        new(name, SetAt, "test", expiresAt ?? SetAt.AddHours(8), parameters);

    [Fact]
    public void OffPlansNothing()
    {
        Assert.Empty(ProfileScheduler.Plan(State("off"), DemoTarget.T1, SetAt.AddMinutes(10), Definitions, Catalog, null));
    }

    [Fact]
    public void BaselineRunsInChunksAlignedToWhenTheProfileWasSet()
    {
        var now = SetAt.AddMinutes(47);

        var activity = Assert.Single(ProfileScheduler.Plan(State("baseline"), DemoTarget.T2, now, Definitions, Catalog, null));

        Assert.Equal("healthy-baseline", activity.ScenarioId);
        Assert.Equal(SetAt.AddMinutes(30), activity.Start);
        Assert.Equal(SetAt.AddMinutes(60), activity.End);
        Assert.True(activity.IsBaseline);
        Assert.Equal(Definitions.Baseline.Concurrency, activity.Concurrency);
    }

    [Fact]
    public void T3HasALighterBaseline()
    {
        var activity = Assert.Single(ProfileScheduler.Plan(State("baseline"), DemoTarget.T3, SetAt.AddMinutes(1), Definitions, Catalog, null));

        Assert.Equal(Definitions.Baseline.ByTarget["T3"].Concurrency, activity.Concurrency);
        Assert.Equal(Definitions.Baseline.ByTarget["T3"].Intensity, activity.Intensity);
    }

    [Fact]
    public void NothingRunsAfterTheProfileExpires()
    {
        var state = State("business-day", SetAt.AddHours(1));

        Assert.Empty(ProfileScheduler.Plan(state, DemoTarget.T1, SetAt.AddHours(1).AddSeconds(1), Definitions, Catalog, null));
    }

    [Fact]
    public void TheLastBaselineChunkStopsAtTheExpiry()
    {
        var state = State("baseline", SetAt.AddMinutes(40));

        var activity = Assert.Single(ProfileScheduler.Plan(state, DemoTarget.T1, SetAt.AddMinutes(35), Definitions, Catalog, null));

        Assert.Equal(SetAt.AddMinutes(40), activity.End);
    }

    [Fact]
    public void ExpiryIsCappedAtTheProfileMaximum()
    {
        var state = State("baseline", SetAt.AddDays(3));

        var end = ProfileScheduler.EffectiveEnd(state, Definitions, Catalog, null);

        Assert.Equal(SetAt.AddMinutes(Definitions.Profiles["baseline"].MaxDurationMinutes), end);
    }

    [Fact]
    public void NotAfterEndsEverythingTwoMinutesEarly()
    {
        var notAfter = SetAt.AddMinutes(20);

        var activity = Assert.Single(ProfileScheduler.Plan(State("baseline"), DemoTarget.T1, SetAt.AddMinutes(5), Definitions, Catalog, notAfter));

        Assert.Equal(notAfter - RunLimits.ShutdownMargin, activity.End);
        Assert.Empty(ProfileScheduler.Plan(State("baseline"), DemoTarget.T1, notAfter.AddMinutes(-1), Definitions, Catalog, notAfter));
    }

    [Theory]
    [InlineData("T1", 12, "locking-blocking")]
    [InlineData("T1", 41, "locking-blocking")]
    [InlineData("T2", 6, "cpu-pressure")]
    [InlineData("T2", 21, "missing-index")]
    [InlineData("T2", 36, "io-pressure")]
    [InlineData("T2", 51, "inefficient-query")]
    [InlineData("T3", 16, "resource-governance")]
    [InlineData("T3", 46, "log-rate-pressure")]
    public void BusinessDayRunsEachTargetsIncidentsAtFixedMinutes(string target, int minute, string scenario)
    {
        var now = new DateTimeOffset(2026, 10, 20, 16, minute, 0, TimeSpan.Zero);

        var activities = ProfileScheduler.Plan(State("business-day"), Enum.Parse<DemoTarget>(target), now, Definitions, Catalog, null);

        var incident = Assert.Single(activities, a => !a.IsBaseline);
        Assert.Equal(scenario, incident.ScenarioId);
        Assert.Contains(activities, a => a.IsBaseline);
        Assert.True(incident.End - incident.Start <= TimeSpan.FromSeconds(Catalog.Get(scenario).Duration.MaxSeconds));
    }

    [Theory]
    [InlineData("T1", 25)]
    [InlineData("T2", 0)]
    [InlineData("T3", 30)]
    public void BusinessDayIsQuietBetweenIncidents(string target, int minute)
    {
        var now = new DateTimeOffset(2026, 10, 20, 16, minute, 0, TimeSpan.Zero);

        var activities = ProfileScheduler.Plan(State("business-day"), Enum.Parse<DemoTarget>(target), now, Definitions, Catalog, null);

        Assert.All(activities, a => Assert.True(a.IsBaseline));
    }

    [Fact]
    public void BusinessDayIncidentKeysAreStableWithinAWindow()
    {
        var first = ProfileScheduler.Plan(State("business-day"), DemoTarget.T1, new DateTimeOffset(2026, 10, 20, 16, 11, 0, TimeSpan.Zero), Definitions, Catalog, null);
        var later = ProfileScheduler.Plan(State("business-day"), DemoTarget.T1, new DateTimeOffset(2026, 10, 20, 16, 16, 30, TimeSpan.Zero), Definitions, Catalog, null);
        var nextHour = ProfileScheduler.Plan(State("business-day"), DemoTarget.T1, new DateTimeOffset(2026, 10, 20, 17, 11, 0, TimeSpan.Zero), Definitions, Catalog, null);

        Assert.Equal(first.Single(a => !a.IsBaseline).Key, later.Single(a => !a.IsBaseline).Key);
        Assert.NotEqual(first.Single(a => !a.IsBaseline).Key, nextHour.Single(a => !a.IsBaseline).Key);
    }

    [Fact]
    public void TheSecondT1WindowAddsTheBoundedDeadlock()
    {
        var activities = ProfileScheduler.Plan(State("business-day"), DemoTarget.T1, new DateTimeOffset(2026, 10, 20, 16, 41, 0, TimeSpan.Zero), Definitions, Catalog, null);

        Assert.Equal("true", activities.Single(a => !a.IsBaseline).Parameters["deadlock"]);
    }

    [Fact]
    public void IncidentRunsOnceForItsDuration()
    {
        var parameters = new ProfileParameters { DurationSeconds = 300, Concurrency = 4, Parameters = new Dictionary<string, string> { ["variant"] = "healthy" } };
        var state = State("incident:cpu-pressure", ProfileScheduler.ComputeExpiry(ProfileName.Parse("incident:cpu-pressure", Catalog), parameters, SetAt, null, Definitions, Catalog), parameters);

        var during = ProfileScheduler.Plan(state, DemoTarget.T2, SetAt.AddMinutes(2), Definitions, Catalog, null);
        var after = ProfileScheduler.Plan(state, DemoTarget.T2, SetAt.AddMinutes(5).AddSeconds(1), Definitions, Catalog, null);

        var incident = Assert.Single(during, a => !a.IsBaseline);
        Assert.Equal("cpu-pressure", incident.ScenarioId);
        Assert.Equal(SetAt.AddMinutes(5), incident.End);
        Assert.Equal(4, incident.Concurrency);
        Assert.Equal("healthy", incident.Parameters["variant"]);
        Assert.Contains(during, a => a.IsBaseline && a.End == SetAt.AddMinutes(5));
        Assert.Empty(after);
    }

    [Fact]
    public void IncidentCanRunWithoutTheBaseline()
    {
        var parameters = new ProfileParameters { WithBaseline = false };

        var activities = ProfileScheduler.Plan(State("incident:locking-blocking", null, parameters), DemoTarget.T1, SetAt.AddMinutes(1), Definitions, Catalog, null);

        Assert.All(activities, a => Assert.False(a.IsBaseline));
    }

    [Fact]
    public void IncidentDurationIsCappedAtTheScenarioMaximum()
    {
        var parameters = new ProfileParameters { DurationSeconds = 7200 };
        var name = ProfileName.Parse("incident:log-rate-pressure", Catalog);

        var expiry = ProfileScheduler.ComputeExpiry(name, parameters, SetAt, null, Definitions, Catalog);

        Assert.Equal(SetAt.AddSeconds(Catalog.Get("log-rate-pressure").Duration.MaxSeconds), expiry);
    }

    [Fact]
    public void AnActivityWithTooLittleTimeLeftIsWantedButNotStarted()
    {
        var notAfter = SetAt.AddMinutes(30);
        var now = notAfter - RunLimits.ShutdownMargin - TimeSpan.FromSeconds(30);

        var activity = Assert.Single(ProfileScheduler.Plan(State("baseline"), DemoTarget.T1, now, Definitions, Catalog, notAfter));

        Assert.False(activity.CanStart(now, Definitions));
        Assert.True(activity.CanStart(now - TimeSpan.FromMinutes(5), Definitions));
    }

    [Theory]
    [InlineData("off", "Off")]
    [InlineData("baseline", "Baseline")]
    [InlineData("business-day", "BusinessDay")]
    [InlineData("incident:io-pressure", "Incident")]
    public void ProfileNamesParse(string text, string kind)
    {
        Assert.Equal(Enum.Parse<ProfileKind>(kind), ProfileName.Parse(text, Catalog).Kind);
    }

    [Theory]
    [InlineData("incident:")]
    [InlineData("incident:no-such")]
    [InlineData("Baseline")]
    [InlineData(null)]
    public void BadProfileNamesAreRefused(string? text)
    {
        Assert.Throws<ScenarioRequestException>(() => ProfileName.Parse(text, Catalog));
    }
}
