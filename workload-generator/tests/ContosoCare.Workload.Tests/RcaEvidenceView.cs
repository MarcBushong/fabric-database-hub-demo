using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using Json.Schema;

namespace ContosoCare.Workload.Tests;

/// <summary>The contract's schemas, loaded once per process (JsonSchema.Net registers a schema by its $id).</summary>
internal static class RcaSchemas
{
    public static readonly Lazy<JsonSchema> Evidence = new(() => JsonSchema.FromText(File.ReadAllText(RepositoryPaths.Combine("rca", "evidence.schema.json"))));

    public static readonly Lazy<JsonSchema> Transport = new(() => JsonSchema.FromText(File.ReadAllText(RepositoryPaths.Combine("rca", "transport.schema.json"))));

    public static string PartLinePattern()
    {
        using var schema = JsonDocument.Parse(File.ReadAllText(RepositoryPaths.Combine("rca", "transport.schema.json")));
        return schema.RootElement.GetProperty("$defs").GetProperty("partLine").GetProperty("pattern").GetString()!;
    }

    /// <summary>The schema's errors for a JSON text, or an empty list when it's valid.</summary>
    public static List<string> Errors(Lazy<JsonSchema> schema, string json)
    {
        using var document = JsonDocument.Parse(json);
        var result = schema.Value.Evaluate(document.RootElement, new EvaluationOptions { OutputFormat = OutputFormat.List });
        return result.IsValid ? [] : [.. (result.Details ?? []).Where(d => d.Errors is not null).SelectMany(d => d.Errors!.Select(e => $"{d.InstanceLocation}: {e.Key}: {e.Value}"))];
    }
}

/// <summary>An evidence document decoded for assertions: each table's rows with strings resolved and times as UTC.</summary>
internal sealed class EvidenceView
{
    public EvidenceView(string json)
    {
        Json = json;
        Root = JsonNode.Parse(json)!.AsObject();
        Epoch = DateTimeOffset.Parse(Root["epochUtc"]!.GetValue<string>(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal);
        Strings = [.. Root["strings"]!.AsArray().Select(s => s!.GetValue<string>())];
        AnswerKeyStrings = [.. Root["answerKey"]!["strings"]!.AsArray().Select(s => s!.GetValue<string>())];
    }

    public string Json { get; }

    public JsonObject Root { get; }

    public DateTimeOffset Epoch { get; }

    public List<string> Strings { get; }

    public List<string> AnswerKeyStrings { get; }

    public List<Dictionary<string, object?>> Table(string name) => Rows(Root["tables"]![name]?.AsObject(), Strings, name);

    public List<Dictionary<string, object?>> AnswerKey() => Rows(Root["answerKey"]!["tables"]!["rca_answer_key"]?.AsObject(), AnswerKeyStrings, "rca_answer_key");

    private List<Dictionary<string, object?>> Rows(JsonObject? table, List<string> strings, string name)
    {
        if (table is null)
        {
            return [];
        }

        var types = Rca.RcaContract.Table(name).Columns.ToDictionary(c => c.Name, c => c.Type);
        var count = table["rows"]!.GetValue<int>();
        var rows = Enumerable.Range(0, count).Select(_ => new Dictionary<string, object?>(StringComparer.Ordinal)).ToList();
        foreach (var (column, values) in table["columns"]!.AsObject())
        {
            var array = values!.AsArray();
            for (var i = 0; i < count; i++)
            {
                var value = array[i];
                rows[i][column] = value is null ? null : types[column] switch
                {
                    "string" => strings[value.GetValue<int>()],
                    "timestamp" => Epoch.AddMilliseconds(value.GetValue<long>()),
                    "long" or "integer" => value.GetValue<long>(),
                    "double" => value.GetValue<double>(),
                    "boolean" => value.GetValue<bool>(),
                    _ => value.ToJsonString(),
                };
            }
        }

        return rows;
    }
}
