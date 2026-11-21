using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.Export;

/// <summary>What a document says about itself (rca/README.md, The evidence document).</summary>
internal sealed record DocumentHeader(
    string DocumentId,
    string? SessionId,
    string Host,
    string ProducerVersion,
    DateTimeOffset ExportedUtc,
    int Sequence,
    bool Final,
    DateTimeOffset WindowStartUtc,
    DateTimeOffset WindowEndUtc,
    IReadOnlyList<string> Targets);

/// <summary>
/// Writes an evidence document, version 1 (rca/evidence.schema.json): the detection tables in columns with one string
/// dictionary, times as milliseconds after <c>epochUtc</c> (the window's start), a column left out when all its values
/// are null and it isn't required, a table left out when it has no rows (rca_coverage never is); and the answer key in
/// its own section, with its own dictionary, so it never shares a string with the detection tables.
/// </summary>
internal static class EvidenceDocument
{
    public const string AnswerKeyTable = "rca_answer_key";

    private static readonly JsonWriterOptions Options = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static byte[] Write(DocumentHeader header, IReadOnlyDictionary<string, List<CaptureRow>> detection, IReadOnlyList<CaptureRow> answerKey)
    {
        var epoch = Second(header.WindowStartUtc);
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer, Options))
        {
            json.WriteStartObject();
            json.WriteString("kind", RcaContract.DocumentKind);
            json.WriteNumber("version", RcaContract.Version);
            json.WriteString("documentId", header.DocumentId);
            if (header.SessionId is null)
            {
                json.WriteNull("sessionId");
            }
            else
            {
                json.WriteString("sessionId", header.SessionId);
            }

            json.WriteStartObject("producer");
            json.WriteString("name", "ContosoCare.Workload");
            json.WriteString("version", header.ProducerVersion);
            json.WriteString("host", header.Host);
            json.WriteString("lane", "observer");
            json.WriteEndObject();
            json.WriteString("exportedUtc", Utc(header.ExportedUtc));
            json.WriteNumber("sequence", header.Sequence);
            json.WriteBoolean("final", header.Final);
            json.WriteString("windowStartUtc", Utc(header.WindowStartUtc));
            json.WriteString("windowEndUtc", Utc(header.WindowEndUtc));
            json.WriteStartArray("targets");
            foreach (var target in header.Targets)
            {
                json.WriteStringValue(target);
            }

            json.WriteEndArray();
            json.WriteString("epochUtc", Utc(epoch));

            var strings = new StringTable();
            var tables = new List<(RcaTable Table, List<CaptureRow> Rows)>();
            foreach (var table in RcaContract.Tables.Where(t => t.IsDetection))
            {
                if (detection.TryGetValue(table.Name, out var rows) && (rows.Count > 0 || table.Name == RcaContract.Coverage))
                {
                    tables.Add((table, rows));
                }
            }

            var encoded = tables.Select(t => (t.Table.Name, Columns: Encode(t.Table, t.Rows, strings, epoch), t.Rows.Count)).ToList();
            WriteStrings(json, "strings", strings);
            json.WriteStartObject("tables");
            foreach (var (name, columns, count) in encoded)
            {
                WriteTable(json, name, columns, count);
            }

            json.WriteEndObject();

            var keyStrings = new StringTable();
            var keyTable = RcaContract.Table(AnswerKeyTable);
            var keyColumns = answerKey.Count > 0 ? Encode(keyTable, answerKey, keyStrings, epoch) : null;
            json.WriteStartObject("answerKey");
            WriteStrings(json, "strings", keyStrings);
            json.WriteStartObject("tables");
            if (keyColumns is not null)
            {
                WriteTable(json, AnswerKeyTable, keyColumns, answerKey.Count);
            }

            json.WriteEndObject();
            json.WriteEndObject();
            json.WriteEndObject();
        }

        return buffer.ToArray();
    }

    /// <summary>A UTC time as the contract's fixtures have it: milliseconds always (the schema's pattern allows 1 to 7 digits).</summary>
    public static string Utc(DateTimeOffset time) => time.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    /// <summary>A time truncated to its second.</summary>
    public static DateTimeOffset Second(DateTimeOffset time) => new(time.UtcDateTime.Ticks - (time.UtcDateTime.Ticks % TimeSpan.TicksPerSecond), TimeSpan.Zero);

    /// <summary>
    /// True when the detection tables fit a document: at most 20,000 rows a table and 20,000 distinct strings, past which
    /// <see cref="Write"/> refuses them. The reducer checks it before it measures, and cuts on while it's false.
    /// </summary>
    public static bool WithinLimits(IReadOnlyDictionary<string, List<CaptureRow>> detection)
    {
        var strings = new HashSet<string>(StringComparer.Ordinal);
        foreach (var table in RcaContract.Tables.Where(t => t.IsDetection))
        {
            if (!detection.TryGetValue(table.Name, out var rows))
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
                    if (row.Get(column.Name) is { } value && strings.Add(StringTable.Text(value)) && strings.Count > RcaContract.MaximumStrings)
                    {
                        return false;
                    }
                }
            }
        }

        return true;
    }

    private static List<(string Name, string Type, List<object?> Values)> Encode(RcaTable table, IReadOnlyList<CaptureRow> rows, StringTable strings, DateTimeOffset epoch)
    {
        if (rows.Count > RcaContract.MaximumRows)
        {
            throw new InvalidOperationException($"{table.Name} has {rows.Count} rows; a document holds at most {RcaContract.MaximumRows}.");
        }

        var columns = new List<(string, string, List<object?>)>();
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
                columns.Add((column.Name, column.Type, values));
            }
        }

        return columns;
    }

    private static object? Convert(RcaColumn column, object? value, StringTable strings, DateTimeOffset epoch)
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

    private static void WriteStrings(Utf8JsonWriter json, string name, StringTable strings)
    {
        json.WriteStartArray(name);
        foreach (var text in strings.Values)
        {
            json.WriteStringValue(text);
        }

        json.WriteEndArray();
    }

    private static void WriteTable(Utf8JsonWriter json, string name, List<(string Name, string Type, List<object?> Values)> columns, int rows)
    {
        json.WriteStartObject(name);
        json.WriteNumber("rows", rows);
        json.WriteStartObject("columns");
        foreach (var (column, _, values) in columns)
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

    /// <summary>A section's string dictionary: each distinct string once, in the order first used, at most 4,000 characters each.</summary>
    private sealed class StringTable
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
                throw new InvalidOperationException($"A document holds at most {RcaContract.MaximumStrings} strings.");
            }

            indexes[text] = Values.Count;
            Values.Add(text);
            return Values.Count - 1;
        }
    }
}
