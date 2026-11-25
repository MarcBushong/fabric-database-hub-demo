using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>
/// Writes a sidecar, version 1 (rca/sidecar.schema.json; rca/README.md, The sidecar), encoded as the evidence document
/// is, for the sidecar's own tables only:
/// <list type="bullet">
/// <item>the header's fields, with UTC times in milliseconds as the evidence document writes them;</item>
/// <item>each table's columns in history-tables.json's order, a column left out when all its values are null and it
/// isn't required;</item>
/// <item>one string dictionary, each string once, in the order first used;</item>
/// <item>times as milliseconds after <c>epochUtc</c>, the window's start to the second;</item>
/// <item>a table left out when it has no rows, except rca_query_coverage, which a sidecar always holds.</item>
/// </list>
/// Nothing else: never an evidence table, and nothing the workload records about itself. Rows keep the draft's order,
/// so the same draft gives the same bytes.
/// </summary>
internal static class SidecarDocument
{
    private static readonly JsonWriterOptions Options = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private static readonly Lazy<IReadOnlyList<RcaTable>> Tables = new(() => RcaContract.SidecarTables);

    /// <summary>The draft as a sidecar's UTF-8 JSON, without white space.</summary>
    public static byte[] Write(SidecarDraft draft)
    {
        ArgumentNullException.ThrowIfNull(draft);
        Check(draft);
        var epoch = EvidenceDocument.Second(draft.WindowStartUtc);
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer, Options))
        {
            json.WriteStartObject();
            json.WriteString("kind", RcaContract.SidecarKind);
            json.WriteNumber("version", RcaContract.SidecarVersion);
            json.WriteString("documentId", draft.DocumentId);
            if (draft.SessionId is null)
            {
                json.WriteNull("sessionId");
            }
            else
            {
                json.WriteString("sessionId", draft.SessionId);
            }

            json.WriteStartObject("producer");
            json.WriteString("name", "ContosoCare.Workload");
            json.WriteString("version", draft.ProducerVersion);
            json.WriteString("host", draft.Host);
            json.WriteString("lane", "observer");
            json.WriteEndObject();
            json.WriteString("exportedUtc", EvidenceDocument.Utc(draft.ExportedUtc));
            json.WriteNumber("sequence", draft.Sequence);
            json.WriteBoolean("final", draft.Final);
            json.WriteString("windowStartUtc", EvidenceDocument.Utc(draft.WindowStartUtc));
            json.WriteString("windowEndUtc", EvidenceDocument.Utc(draft.WindowEndUtc));
            json.WriteStartArray("targets");
            foreach (var target in draft.Targets.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal))
            {
                json.WriteStringValue(target);
            }

            json.WriteEndArray();
            json.WriteString("epochUtc", EvidenceDocument.Utc(epoch));

            var strings = new SidecarStrings();
            var encoded = new List<(string Name, List<(string Name, List<object?> Values)> Columns, int Rows)>();
            foreach (var table in Tables.Value)
            {
                if (draft.Tables.TryGetValue(table.Name, out var rows) && rows.Count > 0)
                {
                    encoded.Add((table.Name, Encode(table, rows, strings, epoch), rows.Count));
                }
            }

            json.WriteStartArray("strings");
            foreach (var text in strings.Values)
            {
                json.WriteStringValue(text);
            }

            json.WriteEndArray();
            json.WriteStartObject("tables");
            foreach (var (name, columns, count) in encoded)
            {
                WriteTable(json, name, columns, count);
            }

            json.WriteEndObject();
            json.WriteEndObject();
        }

        return buffer.ToArray();
    }

    /// <summary>
    /// True when the tables fit a document: at most 20,000 rows a table and 20,000 distinct strings, past which
    /// <see cref="Write"/> refuses them. The reducer checks it before it measures, and cuts on while it's false.
    /// </summary>
    public static bool WithinLimits(IReadOnlyDictionary<string, List<CaptureRow>> tables)
    {
        ArgumentNullException.ThrowIfNull(tables);
        var strings = new HashSet<string>(StringComparer.Ordinal);
        foreach (var table in Tables.Value)
        {
            if (!tables.TryGetValue(table.Name, out var rows))
            {
                continue;
            }

            if (rows.Count > RcaContract.MaximumRows)
            {
                return false;
            }

            foreach (var column in table.Columns.Where(c => c.Type == "string"))
            {
                foreach (var row in rows)
                {
                    if (row.Get(column.Name) is { } value && strings.Add(SidecarStrings.Text(value)) && strings.Count > RcaContract.MaximumStrings)
                    {
                        return false;
                    }
                }
            }
        }

        return true;
    }

    private static void Check(SidecarDraft draft)
    {
        if (!SidecarParts.IsSidecarId(draft.DocumentId))
        {
            throw new ArgumentException($"'{draft.DocumentId}' isn't a sidecar's document ID (<window start>-<host>-<sequence>-sidecar).", nameof(draft));
        }

        if (draft.Targets.Count == 0)
        {
            throw new ArgumentException("A sidecar covers at least one target.", nameof(draft));
        }

        foreach (var name in draft.Tables.Keys)
        {
            if (!Tables.Value.Any(t => string.Equals(t.Name, name, StringComparison.Ordinal)))
            {
                throw new ArgumentException($"{name} isn't one of the sidecar's tables: a sidecar never holds an evidence table.", nameof(draft));
            }
        }

        if (!draft.Tables.TryGetValue(RcaContract.QueryCoverage, out var coverage) || coverage.Count == 0)
        {
            throw new ArgumentException("A sidecar holds an rca_query_coverage row for each of its targets, and this draft has none.", nameof(draft));
        }
    }

    private static List<(string Name, List<object?> Values)> Encode(RcaTable table, List<CaptureRow> rows, SidecarStrings strings, DateTimeOffset epoch)
    {
        if (rows.Count > RcaContract.MaximumRows)
        {
            throw new InvalidOperationException($"{table.Name} has {rows.Count} rows; a sidecar holds at most {RcaContract.MaximumRows}.");
        }

        var columns = new List<(string, List<object?>)>();
        foreach (var column in table.Columns)
        {
            var values = new List<object?>(rows.Count);
            var any = false;
            foreach (var row in rows)
            {
                var value = Convert(column, row.Get(column.Name), strings, epoch);
                if (value is null && column.Required)
                {
                    throw new InvalidOperationException($"{table.Name}.{column.Name} is required, and a row has no value.");
                }

                any |= value is not null;
                values.Add(value);
            }

            if (any || column.Required)
            {
                columns.Add((column.Name, values));
            }
        }

        return columns;
    }

    private static object? Convert(RcaColumn column, object? value, SidecarStrings strings, DateTimeOffset epoch)
    {
        if (value is null)
        {
            return null;
        }

        return column.Type switch
        {
            "string" => strings.Index(value),
            "timestamp" => value is DateTimeOffset time ? (long)Math.Round((time - epoch).TotalMilliseconds, MidpointRounding.AwayFromZero) : throw new InvalidOperationException($"{column.Name} isn't a time."),
            "integer" => value switch
            {
                long number => (long)Math.Clamp(number, int.MinValue, int.MaxValue),
                int number => (long)number,
                _ => throw new InvalidOperationException($"{column.Name} isn't an integer."),
            },
            "long" => value switch
            {
                long number => number,
                int number => (long)number,
                _ => throw new InvalidOperationException($"{column.Name} isn't an integer."),
            },
            "double" => value switch
            {
                double number when double.IsFinite(number) => number,
                long number => (double)number,
                int number => (double)number,
                _ => null,
            },
            "boolean" => value is bool flag ? flag : throw new InvalidOperationException($"{column.Name} isn't a boolean."),
            _ => throw new InvalidOperationException($"{column.Name}'s type {column.Type} isn't in documents."),
        };
    }

    private static void WriteTable(Utf8JsonWriter json, string name, List<(string Name, List<object?> Values)> columns, int rows)
    {
        json.WriteStartObject(name);
        json.WriteNumber("rows", rows);
        json.WriteStartObject("columns");
        foreach (var (column, values) in columns)
        {
            json.WriteStartArray(column);
            foreach (var value in values)
            {
                switch (value)
                {
                    case null:
                        json.WriteNullValue();
                        break;
                    case int index:
                        json.WriteNumberValue(index);
                        break;
                    case long number:
                        json.WriteNumberValue(number);
                        break;
                    case double number:
                        json.WriteNumberValue(number);
                        break;
                    case bool flag:
                        json.WriteBooleanValue(flag);
                        break;
                }
            }

            json.WriteEndArray();
        }

        json.WriteEndObject();
        json.WriteEndObject();
    }

    /// <summary>The sidecar's string dictionary: each distinct string once, in the order first used, at most 4,000 characters each.</summary>
    private sealed class SidecarStrings
    {
        private readonly Dictionary<string, int> indexes = new(StringComparer.Ordinal);

        public List<string> Values { get; } = [];

        /// <summary>A value as the dictionary holds it: its text, cut to 4,000 characters.</summary>
        public static string Text(object value)
        {
            var text = value as string ?? System.Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty;
            return text.Length > RcaContract.MaximumStringLength ? text[..(RcaContract.MaximumStringLength - 3)] + "..." : text;
        }

        public int Index(object value)
        {
            var text = Text(value);
            if (indexes.TryGetValue(text, out var index))
            {
                return index;
            }

            if (Values.Count >= RcaContract.MaximumStrings)
            {
                throw new InvalidOperationException($"A sidecar holds at most {RcaContract.MaximumStrings} strings.");
            }

            indexes[text] = Values.Count;
            Values.Add(text);
            return Values.Count - 1;
        }
    }
}
