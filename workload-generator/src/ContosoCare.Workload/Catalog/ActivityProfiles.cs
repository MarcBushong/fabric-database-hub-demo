using System.Globalization;

namespace ContosoCare.Workload.Catalog;

/// <summary>Activity profile definitions, loaded from <c>scenarios/activity-profiles.json</c> (embedded at build time).</summary>
internal sealed record ActivityProfilesDefinition
{
    public required int PollSeconds { get; init; }

    public required int MinimumRunSeconds { get; init; }

    public required BaselineSettings Baseline { get; init; }

    public required Dictionary<string, ProfileDefinition> Profiles { get; init; }

    private static readonly Lazy<ActivityProfilesDefinition> Embedded = new(LoadEmbedded);

    public static ActivityProfilesDefinition Default => Embedded.Value;

    public static ActivityProfilesDefinition Parse(string json)
    {
        var parsed = System.Text.Json.JsonSerializer.Deserialize(json, CatalogJsonContext.Default.ActivityProfilesDefinition)
            ?? throw new InvalidOperationException("The activity profiles file is empty.");

        // The source-generated deserializer sets missing init-only properties to null instead of running their
        // initializers, so optional collections are normalized here.
        return parsed with
        {
            Baseline = parsed.Baseline with { ByTarget = parsed.Baseline.ByTarget ?? [] },
            Profiles = parsed.Profiles.ToDictionary(
                p => p.Key,
                p => p.Value with { Incidents = [.. (p.Value.Incidents ?? []).Select(i => i with { Parameters = i.Parameters ?? [] })] },
                StringComparer.Ordinal),
        };
    }

    public ProfileDefinition For(ProfileName name)
    {
        var key = name.Kind == ProfileKind.Incident ? "incident" : name.Value;
        return Profiles.TryGetValue(key, out var definition)
            ? definition
            : throw new InvalidOperationException($"No definition for activity profile '{key}'.");
    }

    public BaselineLoad BaselineFor(DemoTarget target)
    {
        return Baseline.ByTarget.TryGetValue(target.ToString(), out var load)
            ? load
            : new BaselineLoad { Concurrency = Baseline.Concurrency, Intensity = Baseline.Intensity };
    }

    private static ActivityProfilesDefinition LoadEmbedded()
    {
        var assembly = typeof(ActivityProfilesDefinition).Assembly;
        var name = assembly.GetManifestResourceNames().SingleOrDefault(n => n.Replace('\\', '/').EndsWith("scenarios/activity-profiles.json", StringComparison.Ordinal))
            ?? throw new InvalidOperationException("The runner was built without scenarios/activity-profiles.json.");
        return Parse(ScenarioCatalog.ReadResource(assembly, name));
    }
}

internal sealed record BaselineSettings
{
    public required string Scenario { get; init; }

    public required int ChunkMinutes { get; init; }

    public required int Concurrency { get; init; }

    public required int Intensity { get; init; }

    public Dictionary<string, BaselineLoad> ByTarget { get; init; } = [];
}

internal sealed record BaselineLoad
{
    public required int Concurrency { get; init; }

    public required int Intensity { get; init; }
}

internal sealed record ProfileDefinition
{
    public required string Description { get; init; }

    public required int DefaultDurationMinutes { get; init; }

    public required int MaxDurationMinutes { get; init; }

    public required bool Baseline { get; init; }

    public int CycleMinutes { get; init; }

    public List<IncidentSlot> Incidents { get; init; } = [];
}

internal sealed record IncidentSlot
{
    public required string Target { get; init; }

    public required string Scenario { get; init; }

    public required int StartMinute { get; init; }

    public required int DurationMinutes { get; init; }

    public int? Concurrency { get; init; }

    public int? Intensity { get; init; }

    public Dictionary<string, string> Parameters { get; init; } = [];
}

/// <summary>Options stored with a profile: what <c>profile set</c> received besides the name.</summary>
internal sealed record ProfileParameters
{
    public int? DurationSeconds { get; init; }

    public int? Concurrency { get; init; }

    public int? Intensity { get; init; }

    public Dictionary<string, string>? Parameters { get; init; }

    public bool? ResetBefore { get; init; }

    public bool? AutoCleanup { get; init; }

    public bool? WithBaseline { get; init; }
}

/// <summary>The T3 profile file (<c>C:\ProgramData\DbHubDemo\activity.json</c> on T1), so polling never wakes the serverless database.</summary>
internal sealed record ProfileFileContent
{
    public required string Profile { get; init; }

    public required DateTimeOffset SetAt { get; init; }

    public required string SetBy { get; init; }

    public DateTimeOffset? ExpiresAt { get; init; }

    public ProfileParameters? Parameters { get; init; }
}

/// <summary>JSON for <see cref="ProfileParameters"/>, as stored in demo.activity_profile.parameters.</summary>
internal static class ProfileParametersJson
{
    public static string Serialize(ProfileParameters parameters) =>
        System.Text.Json.JsonSerializer.Serialize(parameters, CompactContext.ProfileParameters);

    public static ProfileParameters? Parse(string json)
    {
        try
        {
            return System.Text.Json.JsonSerializer.Deserialize(json, CatalogJsonContext.Default.ProfileParameters);
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    private static CatalogJsonContext CompactContext { get; } = new(new System.Text.Json.JsonSerializerOptions(CatalogJsonContext.Default.Options) { WriteIndented = false });
}

internal enum ProfileKind
{
    Off,
    Baseline,
    BusinessDay,
    Incident,
}

/// <summary>A validated profile name: <c>off</c>, <c>baseline</c>, <c>business-day</c>, or <c>incident:&lt;scenario&gt;</c>.</summary>
internal readonly record struct ProfileName(ProfileKind Kind, string Value, string? ScenarioId)
{
    public const string IncidentPrefix = "incident:";

    public static ProfileName Parse(string? text, ScenarioCatalog catalog)
    {
        switch (text)
        {
            case "off":
                return new ProfileName(ProfileKind.Off, "off", null);
            case "baseline":
                return new ProfileName(ProfileKind.Baseline, "baseline", null);
            case "business-day":
                return new ProfileName(ProfileKind.BusinessDay, "business-day", null);
        }

        if (text is not null && text.StartsWith(IncidentPrefix, StringComparison.Ordinal))
        {
            var scenarioId = text[IncidentPrefix.Length..];
            if (catalog.Contains(scenarioId))
            {
                return new ProfileName(ProfileKind.Incident, text, scenarioId);
            }
        }

        throw new ScenarioRequestException($"Unknown activity profile '{text}'. Use off, baseline, business-day, or incident:<scenario> ({string.Join(", ", catalog.All.Select(s => s.Id))}).");
    }

    public override string ToString() => Value;
}

/// <summary>The profile currently set for a target.</summary>
internal sealed record ProfileState(string Name, DateTimeOffset SetAt, string SetBy, DateTimeOffset? ExpiresAt, ProfileParameters? Parameters)
{
    public static ProfileState Off(DateTimeOffset now) => new("off", now, "default", null, null);
}

/// <summary>One bounded run the profile wants right now: a baseline chunk or an incident window.</summary>
internal sealed record PlannedActivity
{
    public required string Key { get; init; }

    public required string ScenarioId { get; init; }

    public required DateTimeOffset Start { get; init; }

    public required DateTimeOffset End { get; init; }

    public required int Concurrency { get; init; }

    public required int Intensity { get; init; }

    public IReadOnlyDictionary<string, string> Parameters { get; init; } = new Dictionary<string, string>();

    public bool ResetBefore { get; init; }

    public bool AutoCleanup { get; init; } = true;

    public bool IsBaseline { get; init; }

    /// <summary>True when enough of the window is left to start a run; shorter remainders are skipped.</summary>
    public bool CanStart(DateTimeOffset now, ActivityProfilesDefinition definitions) =>
        End - now >= TimeSpan.FromSeconds(definitions.MinimumRunSeconds);
}

/// <summary>Pure schedule logic for activity profiles; the profile host runs what it returns.</summary>
internal static class ProfileScheduler
{
    /// <summary>When the profile stops: its expiry, capped at its maximum duration and before --not-after.</summary>
    public static DateTimeOffset EffectiveEnd(ProfileState state, ActivityProfilesDefinition definitions, ScenarioCatalog catalog, DateTimeOffset? notAfter)
    {
        var name = ProfileName.Parse(state.Name, catalog);
        if (name.Kind == ProfileKind.Off)
        {
            return state.SetAt;
        }

        var (defaultDuration, maxDuration) = Durations(name, state.Parameters, definitions, catalog);
        var end = state.ExpiresAt ?? state.SetAt + defaultDuration;
        var cap = state.SetAt + maxDuration;
        if (end > cap)
        {
            end = cap;
        }

        if (notAfter is { } limit && end > limit - RunLimits.ShutdownMargin)
        {
            end = limit - RunLimits.ShutdownMargin;
        }

        return end;
    }

    /// <summary>The expiry <c>profile set</c> stores: the requested (or default) duration, capped at the profile's maximum and before --not-after.</summary>
    public static DateTimeOffset ComputeExpiry(ProfileName name, ProfileParameters? parameters, DateTimeOffset now, DateTimeOffset? notAfter, ActivityProfilesDefinition definitions, ScenarioCatalog catalog)
    {
        var state = new ProfileState(name.Value, now, "planner", null, parameters);
        return EffectiveEnd(state, definitions, catalog, notAfter);
    }

    public static (TimeSpan Default, TimeSpan Max) Durations(ProfileName name, ProfileParameters? parameters, ActivityProfilesDefinition definitions, ScenarioCatalog catalog)
    {
        var profile = definitions.For(name);
        var max = TimeSpan.FromMinutes(profile.MaxDurationMinutes);
        TimeSpan requested;
        if (name.Kind == ProfileKind.Incident)
        {
            var scenario = catalog.Get(name.ScenarioId!);
            var scenarioMax = TimeSpan.FromSeconds(scenario.Duration.MaxSeconds);
            if (scenarioMax < max)
            {
                max = scenarioMax;
            }

            requested = parameters?.DurationSeconds is { } seconds ? TimeSpan.FromSeconds(seconds) : TimeSpan.FromSeconds(scenario.Duration.DefaultSeconds);
        }
        else
        {
            requested = parameters?.DurationSeconds is { } seconds ? TimeSpan.FromSeconds(seconds) : TimeSpan.FromMinutes(profile.DefaultDurationMinutes);
        }

        return (requested < max ? requested : max, max);
    }

    /// <summary>
    /// The activities the profile wants at <paramref name="now"/> on <paramref name="target"/>; each ends at its window's end.
    /// The host starts one only when <see cref="PlannedActivity.CanStart"/> (enough time is left), but keeps a running one
    /// for as long as it's returned here.
    /// </summary>
    public static IReadOnlyList<PlannedActivity> Plan(
        ProfileState state,
        DemoTarget target,
        DateTimeOffset now,
        ActivityProfilesDefinition definitions,
        ScenarioCatalog catalog,
        DateTimeOffset? notAfter)
    {
        var name = ProfileName.Parse(state.Name, catalog);
        if (name.Kind == ProfileKind.Off || now < state.SetAt)
        {
            return [];
        }

        var end = EffectiveEnd(state, definitions, catalog, notAfter);
        var activities = new List<PlannedActivity>();
        var profile = definitions.For(name);
        var parameters = state.Parameters;

        var withBaseline = profile.Baseline && (name.Kind != ProfileKind.Incident || parameters?.WithBaseline != false);
        if (withBaseline)
        {
            var chunk = TimeSpan.FromMinutes(definitions.Baseline.ChunkMinutes);
            var index = (now - state.SetAt).Ticks / chunk.Ticks;
            var start = state.SetAt + TimeSpan.FromTicks(chunk.Ticks * index);
            var stop = Min(start + chunk, end);
            var load = definitions.BaselineFor(target);
            if (name.Kind == ProfileKind.Incident)
            {
                // The baseline runs alongside the incident, for the incident's window only.
                var (incidentDuration, _) = Durations(name, parameters, definitions, catalog);
                stop = Min(stop, state.SetAt + incidentDuration);
            }

            if (stop > now)
            {
                activities.Add(new PlannedActivity
                {
                    Key = string.Create(CultureInfo.InvariantCulture, $"baseline:{start:yyyyMMddTHHmmssZ}"),
                    ScenarioId = definitions.Baseline.Scenario,
                    Start = start,
                    End = stop,
                    Concurrency = load.Concurrency,
                    Intensity = load.Intensity,
                    AutoCleanup = parameters?.AutoCleanup ?? true,
                    IsBaseline = true,
                });
            }
        }

        if (name.Kind == ProfileKind.BusinessDay)
        {
            var cycle = TimeSpan.FromMinutes(profile.CycleMinutes);
            var dayStart = new DateTimeOffset(now.UtcDateTime.Date, TimeSpan.Zero);
            var cycleStart = dayStart + TimeSpan.FromTicks(cycle.Ticks * ((now - dayStart).Ticks / cycle.Ticks));
            foreach (var slot in profile.Incidents.Where(s => string.Equals(s.Target, target.ToString(), StringComparison.Ordinal)))
            {
                var windowStart = cycleStart + TimeSpan.FromMinutes(slot.StartMinute);
                var windowEnd = Min(windowStart + TimeSpan.FromMinutes(slot.DurationMinutes), end);
                if (now >= windowStart && windowEnd > now)
                {
                    var scenario = catalog.Get(slot.Scenario);
                    activities.Add(new PlannedActivity
                    {
                        Key = string.Create(CultureInfo.InvariantCulture, $"incident:{slot.Scenario}:{windowStart:yyyyMMddTHHmmssZ}"),
                        ScenarioId = slot.Scenario,
                        Start = windowStart,
                        End = windowEnd,
                        Concurrency = slot.Concurrency ?? scenario.Concurrency.Default,
                        Intensity = slot.Intensity ?? scenario.Intensity.Default,
                        Parameters = slot.Parameters,
                        AutoCleanup = parameters?.AutoCleanup ?? true,
                    });
                }
            }
        }
        else if (name.Kind == ProfileKind.Incident)
        {
            var scenario = catalog.Get(name.ScenarioId!);
            var (duration, _) = Durations(name, parameters, definitions, catalog);
            var windowEnd = Min(state.SetAt + duration, end);
            if (windowEnd > now)
            {
                activities.Add(new PlannedActivity
                {
                    Key = string.Create(CultureInfo.InvariantCulture, $"incident:{scenario.Id}:{state.SetAt:yyyyMMddTHHmmssZ}"),
                    ScenarioId = scenario.Id,
                    Start = state.SetAt,
                    End = windowEnd,
                    Concurrency = parameters?.Concurrency ?? scenario.Concurrency.Default,
                    Intensity = parameters?.Intensity ?? scenario.Intensity.Default,
                    Parameters = parameters?.Parameters ?? new Dictionary<string, string>(),
                    ResetBefore = parameters?.ResetBefore ?? false,
                    AutoCleanup = parameters?.AutoCleanup ?? true,
                });
            }
        }

        return activities;
    }

    private static DateTimeOffset Min(DateTimeOffset a, DateTimeOffset b) => a <= b ? a : b;
}
