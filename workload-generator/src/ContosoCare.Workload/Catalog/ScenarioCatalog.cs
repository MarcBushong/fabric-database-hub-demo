using System.Globalization;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ContosoCare.Workload.Catalog;

/// <summary>The demo targets (architecture.md): T1 SQL Server on an Azure VM, T2 Arc-enabled SQL Server, T3 Azure SQL Database, T4 Azure Database for PostgreSQL flexible server (Phase 24).</summary>
internal enum DemoTarget
{
    T1,
    T2,
    T3,
    T4,
}

/// <summary>One scenario definition, loaded from <c>scenarios/&lt;id&gt;/scenario.json</c> (embedded in the runner at build time).</summary>
internal sealed record ScenarioDefinition
{
    public required string Id { get; init; }

    public required string Title { get; init; }

    public required string Summary { get; init; }

    /// <summary>
    /// <c>workers</c>: N sessions run <see cref="Procedure"/>. <c>locking</c>: a holder, contenders, normal workers, and an optional deadlock pair.
    /// <c>chain</c>: a head blocker, chained links, an optional lock escalator, and normal workers. <c>pairs</c>: N pairs of sessions.
    /// <c>slow-consumer</c>: N sessions whose client reads slowly. <c>capacity</c>: N CPU sessions and ioWorkers IO sessions.
    /// </summary>
    public required string Orchestration { get; init; }

    public required string Procedure { get; init; }

    public required DurationLimits Duration { get; init; }

    public required RangeLimits Concurrency { get; init; }

    public required RangeLimits Intensity { get; init; }

    public required TargetApplicability Targets { get; init; }

    public Dictionary<string, ParameterDefinition> Parameters { get; init; } = [];

    public FreeSpaceRequirement? FreeSpace { get; init; }

    public required List<HubSignal> ExpectedHubSignals { get; init; }

    public required List<string> ExpectedSymptoms { get; init; }

    public List<string> QueryLevelEvidence { get; init; } = [];

    public required string Reset { get; init; }

    /// <summary>A one-line summary for <c>demo.scenario_runs.expected_symptoms</c> (400 characters at most).</summary>
    public string ExpectedSymptomsSummary()
    {
        var text = string.Join("; ", ExpectedSymptoms);
        return text.Length <= 400 ? text : text[..397] + "...";
    }

    public bool AppliesTo(DemoTarget target) => Targets.Applicable.Contains(target.ToString(), StringComparer.Ordinal);
}

internal sealed record DurationLimits
{
    public required int DefaultSeconds { get; init; }

    public required int MaxSeconds { get; init; }
}

internal sealed record RangeLimits
{
    public required int Default { get; init; }

    public required int Min { get; init; }

    public required int Max { get; init; }

    public required string Description { get; init; }
}

internal sealed record TargetApplicability
{
    public required List<string> Applicable { get; init; }

    public required List<string> Default { get; init; }

    public Dictionary<string, string> Notes { get; init; } = [];
}

internal sealed record HubSignal
{
    public required string Signal { get; init; }

    public required string Surface { get; init; }

    public string? Note { get; init; }
}

/// <summary>Local free space the runner checks before it starts a run, on T1 and T2 where it shares the machine with SQL Server.</summary>
internal sealed record FreeSpaceRequirement
{
    /// <summary>A parameter whose value (MB) is added to <see cref="MarginMb"/>.</summary>
    public string? DataMbFromParameter { get; init; }

    public required int MarginMb { get; init; }
}

internal sealed record ParameterDefinition
{
    public required string Type { get; init; }

    public required JsonElement Default { get; init; }

    public long? Minimum { get; init; }

    public long? Maximum { get; init; }

    public List<string>? Enum { get; init; }

    public Dictionary<string, JsonElement>? DefaultByTarget { get; init; }

    /// <summary>The procedure parameter that receives the value, for example <c>@variant</c>. Null for runner-only parameters.</summary>
    public string? SqlParameter { get; init; }

    public required string Description { get; init; }
}

/// <summary>A resolved, validated parameter value.</summary>
internal readonly record struct ParameterValue(string Type, long Integer, bool Boolean, string? Text)
{
    public object SqlValue => Type switch
    {
        "integer" => Integer,
        "boolean" => Boolean,
        _ => Text ?? string.Empty,
    };

    public override string ToString() => Type switch
    {
        "integer" => Integer.ToString(CultureInfo.InvariantCulture),
        "boolean" => Boolean ? "true" : "false",
        _ => Text ?? string.Empty,
    };
}

/// <summary>Thrown when a request doesn't fit a scenario's definition or the run bounds. The message is safe to show.</summary>
internal sealed class ScenarioRequestException(string message) : Exception(message);

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    ReadCommentHandling = JsonCommentHandling.Skip,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    WriteIndented = true)]
[JsonSerializable(typeof(ScenarioDefinition))]
[JsonSerializable(typeof(ActivityProfilesDefinition))]
[JsonSerializable(typeof(ProfileParameters))]
[JsonSerializable(typeof(ProfileFileContent))]
[JsonSerializable(typeof(Profiles.HostLanesDocument))]
internal sealed partial class CatalogJsonContext : JsonSerializerContext;

/// <summary>The scenario catalog embedded in the runner, keyed by scenario ID.</summary>
internal sealed class ScenarioCatalog
{
    private const string ResourcePrefix = "scenarios/";
    private static readonly Lazy<ScenarioCatalog> Embedded = new(LoadEmbedded);
    private readonly Dictionary<string, ScenarioDefinition> scenarios;

    internal ScenarioCatalog(IEnumerable<ScenarioDefinition> definitions)
    {
        scenarios = new Dictionary<string, ScenarioDefinition>(StringComparer.Ordinal);
        foreach (var definition in definitions)
        {
            Validate(definition);
            if (!scenarios.TryAdd(definition.Id, definition))
            {
                throw new InvalidOperationException($"Scenario '{definition.Id}' is defined twice.");
            }
        }
    }

    public static ScenarioCatalog Default => Embedded.Value;

    public IReadOnlyList<ScenarioDefinition> All => [.. scenarios.Values.OrderBy(s => s.Id, StringComparer.Ordinal)];

    public ScenarioDefinition Get(string id)
    {
        if (scenarios.TryGetValue(id, out var definition))
        {
            return definition;
        }

        throw new ScenarioRequestException($"Unknown scenario '{id}'. Known scenarios: {string.Join(", ", scenarios.Keys.Order(StringComparer.Ordinal))}.");
    }

    public bool Contains(string id) => scenarios.ContainsKey(id);

    public static ScenarioDefinition Parse(string json)
    {
        var parsed = JsonSerializer.Deserialize(json, CatalogJsonContext.Default.ScenarioDefinition)
            ?? throw new InvalidOperationException("A scenario file is empty.");

        // The source-generated deserializer sets missing init-only properties to null instead of running their
        // initializers, so optional collections are normalized here.
        return parsed with
        {
            Parameters = parsed.Parameters ?? [],
            QueryLevelEvidence = parsed.QueryLevelEvidence ?? [],
            Targets = parsed.Targets with { Notes = parsed.Targets.Notes ?? [] },
        };
    }

    /// <summary>
    /// Resolves <c>--param name=value</c> pairs against the definition: unknown names, wrong types, and values outside
    /// the declared range or enum are refused; missing ones get their default for the target.
    /// </summary>
    public static IReadOnlyDictionary<string, ParameterValue> ResolveParameters(
        ScenarioDefinition scenario,
        DemoTarget target,
        IReadOnlyDictionary<string, string> requested)
    {
        foreach (var name in requested.Keys)
        {
            if (!scenario.Parameters.ContainsKey(name))
            {
                var known = scenario.Parameters.Count == 0 ? "none" : string.Join(", ", scenario.Parameters.Keys.Order(StringComparer.Ordinal));
                throw new ScenarioRequestException($"Scenario '{scenario.Id}' has no parameter '{name}'. Its parameters: {known}.");
            }
        }

        var resolved = new SortedDictionary<string, ParameterValue>(StringComparer.Ordinal);
        foreach (var (name, definition) in scenario.Parameters)
        {
            ParameterValue value;
            if (requested.TryGetValue(name, out var text))
            {
                value = ParseValue(scenario.Id, name, definition, text);
            }
            else
            {
                var defaultElement = definition.DefaultByTarget is not null && definition.DefaultByTarget.TryGetValue(target.ToString(), out var targetDefault)
                    ? targetDefault
                    : definition.Default;
                value = FromJson(scenario.Id, name, definition, defaultElement);
            }

            CheckRange(scenario.Id, name, definition, value);
            resolved[name] = value;
        }

        return resolved;
    }

    private static ParameterValue ParseValue(string scenarioId, string name, ParameterDefinition definition, string text)
    {
        switch (definition.Type)
        {
            case "integer":
                if (!long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var number))
                {
                    throw new ScenarioRequestException($"Parameter '{name}' of '{scenarioId}' must be an integer.");
                }

                return new ParameterValue("integer", number, false, null);
            case "boolean":
                if (!bool.TryParse(text, out var flag))
                {
                    throw new ScenarioRequestException($"Parameter '{name}' of '{scenarioId}' must be true or false.");
                }

                return new ParameterValue("boolean", 0, flag, null);
            default:
                return new ParameterValue("string", 0, false, text);
        }
    }

    private static ParameterValue FromJson(string scenarioId, string name, ParameterDefinition definition, JsonElement element)
    {
        return definition.Type switch
        {
            "integer" when element.ValueKind == JsonValueKind.Number && element.TryGetInt64(out var number) => new ParameterValue("integer", number, false, null),
            "boolean" when element.ValueKind is JsonValueKind.True or JsonValueKind.False => new ParameterValue("boolean", 0, element.GetBoolean(), null),
            "string" when element.ValueKind == JsonValueKind.String => new ParameterValue("string", 0, false, element.GetString()),
            _ => throw new InvalidOperationException($"The default of parameter '{name}' in '{scenarioId}' doesn't match its type '{definition.Type}'."),
        };
    }

    private static void CheckRange(string scenarioId, string name, ParameterDefinition definition, ParameterValue value)
    {
        if (definition.Type == "integer")
        {
            if ((definition.Minimum is { } min && value.Integer < min) || (definition.Maximum is { } max && value.Integer > max))
            {
                throw new ScenarioRequestException(
                    $"Parameter '{name}' of '{scenarioId}' must be between {definition.Minimum?.ToString(CultureInfo.InvariantCulture) ?? "-"} and {definition.Maximum?.ToString(CultureInfo.InvariantCulture) ?? "-"}.");
            }
        }
        else if (definition.Type == "string" && definition.Enum is { Count: > 0 } allowed && !allowed.Contains(value.Text ?? string.Empty, StringComparer.Ordinal))
        {
            throw new ScenarioRequestException($"Parameter '{name}' of '{scenarioId}' must be one of: {string.Join(", ", allowed)}.");
        }
    }

    private static void Validate(ScenarioDefinition definition)
    {
        if (definition.Duration.DefaultSeconds < RunLimits.MinimumDurationSeconds
            || definition.Duration.DefaultSeconds > definition.Duration.MaxSeconds
            || definition.Duration.MaxSeconds > RunLimits.GlobalMaximumSeconds)
        {
            throw new InvalidOperationException($"Scenario '{definition.Id}' has an invalid duration range.");
        }

        foreach (var range in new[] { definition.Concurrency, definition.Intensity })
        {
            if (range.Min < 1 || range.Min > range.Default || range.Default > range.Max || range.Max > 64)
            {
                throw new InvalidOperationException($"Scenario '{definition.Id}' has an invalid concurrency or intensity range.");
            }
        }

        if (definition.Intensity.Max > RunLimits.MaximumIntensity)
        {
            throw new InvalidOperationException($"Scenario '{definition.Id}' allows an intensity above {RunLimits.MaximumIntensity}.");
        }

        if (definition.Orchestration is not ("workers" or "locking" or "chain" or "pairs" or "slow-consumer" or "capacity"))
        {
            throw new InvalidOperationException($"Scenario '{definition.Id}' has an unknown orchestration '{definition.Orchestration}'.");
        }

        foreach (var (name, parameter) in definition.Parameters)
        {
            // Throws when the default doesn't match the type or the range.
            CheckRange(definition.Id, name, parameter, FromJson(definition.Id, name, parameter, parameter.Default));
        }
    }

    private static ScenarioCatalog LoadEmbedded()
    {
        var assembly = typeof(ScenarioCatalog).Assembly;
        var definitions = new List<ScenarioDefinition>();
        foreach (var name in assembly.GetManifestResourceNames().Where(IsScenarioResource).Order(StringComparer.Ordinal))
        {
            definitions.Add(Parse(ReadResource(assembly, name)));
        }

        if (definitions.Count == 0)
        {
            throw new InvalidOperationException("The runner was built without its scenario catalog (scenarios/*/scenario.json).");
        }

        return new ScenarioCatalog(definitions);
    }

    private static bool IsScenarioResource(string name)
    {
        var normalized = name.Replace('\\', '/');
        return normalized.StartsWith(ResourcePrefix, StringComparison.Ordinal) && normalized.EndsWith("/scenario.json", StringComparison.Ordinal);
    }

    internal static string ReadResource(Assembly assembly, string name)
    {
        using var stream = assembly.GetManifestResourceStream(name) ?? throw new InvalidOperationException($"Missing embedded resource '{name}'.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}

/// <summary>Hard limits shared by the runner and the T-SQL layer (demo.usp_run_begin).</summary>
internal static class RunLimits
{
    /// <summary>The global cap, the same as the CHECK constraint on demo.scenario_runs.max_duration_seconds and the '*' control row.</summary>
    public const int GlobalMaximumSeconds = 14400;

    public const int MinimumDurationSeconds = 30;

    public const int MaximumIntensity = 10;

    /// <summary>How far before an auto-shutdown (--not-after) a run must end.</summary>
    public static readonly TimeSpan ShutdownMargin = TimeSpan.FromMinutes(2);

    /// <summary>Time after the deadline before the runner's watchdog cancels commands (layer 2).</summary>
    public static readonly TimeSpan Grace = TimeSpan.FromSeconds(60);
}
