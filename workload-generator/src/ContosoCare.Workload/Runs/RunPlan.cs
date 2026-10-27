using System.Globalization;
using System.Text.Json;
using ContosoCare.Workload.Catalog;

namespace ContosoCare.Workload.Runs;

/// <summary>What someone asked for: <c>run</c> options, or an activity the profile host wants.</summary>
internal sealed record RunRequest
{
    public required string ScenarioId { get; init; }

    public required DemoTarget Target { get; init; }

    public TimeSpan? Duration { get; init; }

    public int? Concurrency { get; init; }

    public int? Intensity { get; init; }

    public IReadOnlyDictionary<string, string> Parameters { get; init; } = new Dictionary<string, string>(StringComparer.Ordinal);

    public bool ResetBefore { get; init; }

    public bool AutoCleanup { get; init; } = true;

    /// <summary>The run must end <see cref="RunLimits.ShutdownMargin"/> before this time, typically the next auto-shutdown.</summary>
    public DateTimeOffset? NotAfter { get; init; }

    public string RequestedBy { get; init; } = "runner";

    public string? ProfileName { get; init; }
}

/// <summary>A request after the bounds are applied: everything a run needs, with every adjustment explained.</summary>
internal sealed record RunPlan
{
    public required ScenarioDefinition Scenario { get; init; }

    public required DemoTarget Target { get; init; }

    public required TimeSpan Duration { get; init; }

    public required int Concurrency { get; init; }

    public required int Intensity { get; init; }

    public required IReadOnlyDictionary<string, ParameterValue> Parameters { get; init; }

    public required bool ResetBefore { get; init; }

    public required bool AutoCleanup { get; init; }

    public DateTimeOffset? NotAfter { get; init; }

    public required string RequestedBy { get; init; }

    public string? ProfileName { get; init; }

    public required IReadOnlyList<string> Adjustments { get; init; }

    public int DurationSeconds => (int)Math.Floor(Duration.TotalSeconds);

    /// <summary>The run's parameters as stored in demo.scenario_runs.parameters (no secrets: there are none to store).</summary>
    public string ParametersJson()
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer))
        {
            json.WriteStartObject();
            json.WriteNumber("durationSeconds", DurationSeconds);
            json.WriteNumber("concurrency", Concurrency);
            json.WriteNumber("intensity", Intensity);
            json.WriteBoolean("resetBefore", ResetBefore);
            json.WriteBoolean("autoCleanup", AutoCleanup);
            if (NotAfter is { } notAfter)
            {
                json.WriteString("notAfter", notAfter.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture));
            }

            json.WriteStartObject("parameters");
            foreach (var (name, value) in Parameters)
            {
                switch (value.Type)
                {
                    case "integer":
                        json.WriteNumber(name, value.Integer);
                        break;
                    case "boolean":
                        json.WriteBoolean(name, value.Boolean);
                        break;
                    default:
                        json.WriteString(name, value.Text);
                        break;
                }
            }

            json.WriteEndObject();
            json.WriteEndObject();
        }

        return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
    }
}

/// <summary>
/// The runner's layer of the bounds (ADR 0010): the duration is clamped to the scenario's maximum, the global cap,
/// and the time left before --not-after; concurrency and intensity to the scenario's ranges. The T-SQL layer
/// (demo.usp_run_begin) applies the same caps again, and the watchdog enforces the deadline.
/// </summary>
internal static class RunBounds
{
    public static RunPlan Plan(ScenarioDefinition scenario, RunRequest request, DateTimeOffset now)
    {
        if (!scenario.AppliesTo(request.Target))
        {
            throw new ScenarioRequestException($"Scenario '{scenario.Id}' doesn't apply to {request.Target}.");
        }

        var adjustments = new List<string>();
        var minimum = TimeSpan.FromSeconds(RunLimits.MinimumDurationSeconds);
        var duration = request.Duration ?? TimeSpan.FromSeconds(scenario.Duration.DefaultSeconds);
        if (duration < minimum)
        {
            throw new ScenarioRequestException($"--duration must be at least {RunLimits.MinimumDurationSeconds} seconds.");
        }

        var maximum = TimeSpan.FromSeconds(Math.Min(scenario.Duration.MaxSeconds, RunLimits.GlobalMaximumSeconds));
        if (duration > maximum)
        {
            adjustments.Add(string.Create(CultureInfo.InvariantCulture, $"Duration clamped from {duration.TotalSeconds:0} s to the scenario's maximum of {maximum.TotalSeconds:0} s."));
            duration = maximum;
        }

        if (request.NotAfter is { } notAfter)
        {
            var window = notAfter - RunLimits.ShutdownMargin - now;
            if (window < minimum)
            {
                throw new ScenarioRequestException(string.Create(
                    CultureInfo.InvariantCulture,
                    $"Not enough time before --not-after {notAfter.UtcDateTime:yyyy-MM-ddTHH:mm:ssZ}: a run must end {RunLimits.ShutdownMargin.TotalMinutes:0} minutes before it and last at least {RunLimits.MinimumDurationSeconds} seconds."));
            }

            if (duration > window)
            {
                var clamped = TimeSpan.FromSeconds(Math.Floor(window.TotalSeconds));
                adjustments.Add(string.Create(CultureInfo.InvariantCulture, $"Duration clamped from {duration.TotalSeconds:0} s to {clamped.TotalSeconds:0} s, to end before --not-after (the next auto-shutdown)."));
                duration = clamped;
            }
        }

        var concurrency = Clamp("Concurrency", request.Concurrency ?? scenario.Concurrency.Default, scenario.Concurrency, adjustments);
        var intensity = Clamp("Intensity", request.Intensity ?? scenario.Intensity.Default, scenario.Intensity, adjustments);
        var parameters = ScenarioCatalog.ResolveParameters(scenario, request.Target, request.Parameters);

        return new RunPlan
        {
            Scenario = scenario,
            Target = request.Target,
            Duration = duration,
            Concurrency = concurrency,
            Intensity = intensity,
            Parameters = parameters,
            ResetBefore = request.ResetBefore,
            AutoCleanup = request.AutoCleanup,
            NotAfter = request.NotAfter,
            RequestedBy = request.RequestedBy,
            ProfileName = request.ProfileName,
            Adjustments = adjustments,
        };
    }

    private static int Clamp(string name, int value, RangeLimits range, List<string> adjustments)
    {
        var clamped = Math.Clamp(value, range.Min, range.Max);
        if (clamped != value)
        {
            adjustments.Add(string.Create(CultureInfo.InvariantCulture, $"{name} clamped from {value} to {clamped} (allowed {range.Min} to {range.Max})."));
        }

        return clamped;
    }
}

/// <summary>Parses durations such as <c>600</c>, <c>90s</c>, <c>10m</c>, <c>1h</c>, or <c>00:10:00</c>.</summary>
internal static class DurationText
{
    public static bool TryParse(string? text, out TimeSpan duration)
    {
        duration = default;
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        text = text.Trim();
        var unit = char.ToLowerInvariant(text[^1]);
        var multiplier = unit switch { 's' => 1, 'm' => 60, 'h' => 3600, _ => 0 };
        var number = multiplier == 0 ? text : text[..^1];
        if (multiplier == 0 && text.Contains(':', StringComparison.Ordinal))
        {
            if (TimeSpan.TryParse(text, CultureInfo.InvariantCulture, out duration) && duration > TimeSpan.Zero)
            {
                return true;
            }

            return false;
        }

        if (double.TryParse(number, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && value > 0 && value * Math.Max(multiplier, 1) <= TimeSpan.FromDays(1).TotalSeconds)
        {
            duration = TimeSpan.FromSeconds(value * Math.Max(multiplier, 1));
            return true;
        }

        return false;
    }

    /// <summary>Parses an ISO 8601 time with an explicit offset or Z; local times without an offset are refused as ambiguous.</summary>
    public static bool TryParseInstant(string? text, out DateTimeOffset instant)
    {
        instant = default;
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        text = text.Trim();
        var hasOffset = text.EndsWith('Z') || text.EndsWith('z') || System.Text.RegularExpressions.Regex.IsMatch(text, @"[+-]\d{2}:?\d{2}$");
        return hasOffset && DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out instant);
    }
}
