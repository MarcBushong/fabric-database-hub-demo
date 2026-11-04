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
    [InlineData("showcase", "Showcase")]
    [InlineData("incident:io-pressure", "Incident")]
    public void ProfileNamesParse(string text, string kind)
    {
        Assert.Equal(Enum.Parse<ProfileKind>(kind), ProfileName.Parse(text, Catalog).Kind);
    }

    [Theory]
    [InlineData("incident:")]
    [InlineData("incident:no-such")]
    [InlineData("Baseline")]
    [InlineData("Showcase")]
    [InlineData(null)]
    public void BadProfileNamesAreRefused(string? text)
    {
        Assert.Throws<ScenarioRequestException>(() => ProfileName.Parse(text, Catalog));
    }

    [Fact]
    public void TheShowcaseRunsNinetyMinutesByDefaultAndTwoHoursAtMost()
    {
        var name = ProfileName.Parse("showcase", Catalog);

        Assert.Equal(SetAt.AddMinutes(90), ProfileScheduler.ComputeExpiry(name, new ProfileParameters(), SetAt, null, Definitions, Catalog));
        Assert.Equal(SetAt.AddMinutes(120), ProfileScheduler.ComputeExpiry(name, new ProfileParameters { DurationSeconds = 4 * 3600 }, SetAt, null, Definitions, Catalog));
        var notAfter = SetAt.AddMinutes(50);
        Assert.Equal(notAfter - RunLimits.ShutdownMargin, ProfileScheduler.ComputeExpiry(name, null, SetAt, notAfter, Definitions, Catalog));
    }

    [Fact]
    public void TheShowcasesCyclesStartWhenTheTargetsProfileIsSet()
    {
        // Each target runs its own clock: its first slots start at the moment its profile was set, not at a UTC boundary.
        var state = State("showcase", SetAt.AddMinutes(90));

        var activities = ProfileScheduler.Plan(state, DemoTarget.T1, SetAt.AddMinutes(3), Definitions, Catalog, null);

        Assert.Contains(activities, a => a.IsBaseline);
        var blocking = Assert.Single(activities, a => a.ScenarioId == "blocking-chain");
        Assert.Equal(SetAt, blocking.Start);
        Assert.Equal(SetAt.AddMinutes(10), blocking.End);
        Assert.Equal("4", blocking.Parameters["depth"]);
        var flush = Assert.Single(activities, a => a.ScenarioId == "log-flush-waits");
        Assert.Equal(SetAt.AddMinutes(2), flush.Start);

        // Cycle 2 repeats the slots 30 minutes later.
        var later = ProfileScheduler.Plan(state, DemoTarget.T1, SetAt.AddMinutes(33), Definitions, Catalog, null);
        Assert.Equal(SetAt.AddMinutes(30), Assert.Single(later, a => a.ScenarioId == "blocking-chain").Start);
    }

    [Theory]
    [InlineData("T2", 23, "parallel-scans")]
    [InlineData("T2", 53, "tempdb-contention")]
    [InlineData("T2", 83, "parallel-scans")]
    [InlineData("T3", 14, "locking-blocking")]
    [InlineData("T3", 44, "deadlock-storm")]
    [InlineData("T4", 11, "idle-in-transaction")]
    [InlineData("T4", 41, "locking-blocking")]
    public void TheShowcaseAlternatesSomeSlotsBetweenOddAndEvenCycles(string target, int minute, string scenario)
    {
        var state = State("showcase", SetAt.AddMinutes(120));

        var activities = ProfileScheduler.Plan(state, Enum.Parse<DemoTarget>(target), SetAt.AddMinutes(minute), Definitions, Catalog, null);

        Assert.Contains(activities, a => a.ScenarioId == scenario);
    }

    [Theory]
    [InlineData(16, "slow-consumer")]
    [InlineData(46, "missing-index")]
    [InlineData(76, "plan-regression")]
    [InlineData(106, "missing-index")]
    public void TheShowcaseRunsAListedCycleOnly(int minute, string scenario)
    {
        var state = State("showcase", SetAt.AddMinutes(120));

        var incidents = ProfileScheduler.Plan(state, DemoTarget.T3, SetAt.AddMinutes(minute), Definitions, Catalog, null).Where(a => !a.IsBaseline).ToList();

        Assert.Contains(incidents, a => a.ScenarioId == scenario);
        Assert.True(incidents.Count <= 2, "at most two incidents at once on a target");
        Assert.DoesNotContain(incidents, a => a.ScenarioId == (scenario == "slow-consumer" ? "plan-regression" : "slow-consumer"));
    }

    [Theory]
    [InlineData("GeneralPurpose", 9, 20)]
    [InlineData("Burstable", 9, 14)]
    [InlineData(null, 9, 14)]
    [InlineData("MemoryOptimized", 9, 14)]
    public void TheShowcasePicksT4sCpuSlotByTier(string? tier, int minute, int endMinute)
    {
        var state = State("showcase", SetAt.AddMinutes(90), new ProfileParameters { Tier = tier });

        var cpu = Assert.Single(ProfileScheduler.Plan(state, DemoTarget.T4, SetAt.AddMinutes(minute), Definitions, Catalog, null), a => a.ScenarioId == "cpu-pressure");

        Assert.Equal(SetAt.AddMinutes(8), cpu.Start);
        Assert.Equal(SetAt.AddMinutes(endMinute), cpu.End);
    }

    [Fact]
    public void BurstableT4RestsItsCpuInEvenCycles()
    {
        var burstable = State("showcase", SetAt.AddMinutes(90), new ProfileParameters { Tier = "Burstable" });
        var generalPurpose = State("showcase", SetAt.AddMinutes(90), new ProfileParameters { Tier = "GeneralPurpose" });

        Assert.DoesNotContain(ProfileScheduler.Plan(burstable, DemoTarget.T4, SetAt.AddMinutes(39), Definitions, Catalog, null), a => a.ScenarioId == "cpu-pressure");
        Assert.Contains(ProfileScheduler.Plan(generalPurpose, DemoTarget.T4, SetAt.AddMinutes(39), Definitions, Catalog, null), a => a.ScenarioId == "cpu-pressure");
    }

    [Theory]
    [InlineData("GeneralPurpose", 4, 6)]
    [InlineData("GeneralPurpose", 2, 3)]
    [InlineData("GeneralPurpose", null, 3)]
    [InlineData("GeneralPurpose", 1, 3)]
    [InlineData("GeneralPurpose", 64, 16)]
    [InlineData("Burstable", 1, 2)]
    [InlineData("Burstable", 2, 4)]
    public void T4sCpuSlotScalesWithItsVCores(string tier, int? vcores, int sessions)
    {
        // The showcase's General Purpose slot has 3 sessions for Standard_D2ds_v5's 2 vCores, and the Burstable slot 2 for
        // Standard_B1ms's one: the same load per vCore on a larger size, never fewer than the slot's own, at most the
        // scenario's maximum (16).
        var state = State("showcase", SetAt.AddMinutes(90), new ProfileParameters { Tier = tier, VCores = vcores });

        var cpu = Assert.Single(ProfileScheduler.Plan(state, DemoTarget.T4, SetAt.AddMinutes(9), Definitions, Catalog, null), a => a.ScenarioId == "cpu-pressure");

        Assert.Equal(sessions, cpu.Concurrency);
    }

    [Fact]
    public void VCoresScaleOnlyT4sCpuBoundSlots()
    {
        var parameters = new ProfileParameters { Tier = "GeneralPurpose", VCores = 4 };
        var t4 = ProfileScheduler.Plan(State("showcase", SetAt.AddMinutes(90), parameters), DemoTarget.T4, SetAt.AddMinutes(1), Definitions, Catalog, null);
        var t1 = ProfileScheduler.Plan(State("showcase", SetAt.AddMinutes(90), parameters), DemoTarget.T1, SetAt.AddMinutes(10), Definitions, Catalog, null);
        var unscaledT1 = ProfileScheduler.Plan(State("showcase", SetAt.AddMinutes(90)), DemoTarget.T1, SetAt.AddMinutes(10), Definitions, Catalog, null);

        Assert.Equal(5, Assert.Single(t4, a => a.ScenarioId == "connection-surge").Concurrency);
        Assert.Equal(unscaledT1.Select(a => a.Concurrency), t1.Select(a => a.Concurrency));
    }

    [Theory]
    [InlineData(null, 1, true)]
    [InlineData("all", 2, true)]
    [InlineData("odd", 3, true)]
    [InlineData("odd", 4, false)]
    [InlineData("even", 2, true)]
    [InlineData("3", 3, true)]
    [InlineData("3", 1, false)]
    [InlineData("1,3", 3, true)]
    [InlineData("1,3", 2, false)]
    public void SlotsRunInTheirCycles(string? cycles, long cycle, bool runs)
    {
        Assert.Equal(runs, new IncidentSlot { Target = "T1", Scenario = "cpu-pressure", StartMinute = 0, DurationMinutes = 5, Cycles = cycles }.RunsInCycle(cycle));
    }

    [Fact]
    public void BusinessDayStillCountsItsCyclesFromUtcMidnight()
    {
        // A profile set at 15:02 still runs business-day's incidents at fixed minutes past the hour.
        var activities = ProfileScheduler.Plan(State("business-day"), DemoTarget.T2, new DateTimeOffset(2026, 10, 20, 16, 6, 0, TimeSpan.Zero), Definitions, Catalog, null);

        var incident = Assert.Single(activities, a => !a.IsBaseline);
        Assert.Equal(new DateTimeOffset(2026, 10, 20, 16, 5, 0, TimeSpan.Zero), incident.Start);
    }
}
