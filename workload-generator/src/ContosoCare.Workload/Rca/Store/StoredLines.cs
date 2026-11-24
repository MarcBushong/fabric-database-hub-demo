using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.Store;

/// <summary>
/// The evidence store's lines: one JSON object per line, a row (<c>r</c>, its table) or a coverage note (<c>n</c>, its
/// kind), with its time in milliseconds since the Unix epoch. A row's values are typed by rca/history-tables.json:
/// timestamps as milliseconds too.
/// </summary>
internal static class StoredLines
{
    private static readonly JsonWriterOptions WriterOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public static byte[] Row(CaptureRow row)
    {
        var table = RcaContract.Table(row.Table);
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer, WriterOptions))
        {
            json.WriteStartObject();
            json.WriteString("r", row.Table);
            json.WriteNumber("at", row.At.ToUnixTimeMilliseconds());
            json.WriteString("src", row.Source);
            if (row.Sentinel)
            {
                json.WriteNumber("s", 1);
            }

            json.WriteStartObject("v");
            foreach (var (name, value) in row.Values)
            {
                var column = table.Column(name) ?? throw new InvalidOperationException($"{row.Table} has no column '{name}' (rca/history-tables.json).");
                WriteValue(json, column, value);
            }

            json.WriteEndObject();
            json.WriteEndObject();
        }

        buffer.WriteByte((byte)'\n');
        return buffer.ToArray();
    }

    public static byte[] Note(CaptureNote note)
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer, WriterOptions))
        {
            json.WriteStartObject();
            json.WriteString("n", note.Kind switch { NoteKind.Gap => "gap", NoteKind.Source => "source", _ => "warning" });
            json.WriteNumber("at", note.At.ToUnixTimeMilliseconds());
            json.WriteString("text", note.Text);
            json.WriteEndObject();
        }

        buffer.WriteByte((byte)'\n');
        return buffer.ToArray();
    }

    /// <summary>Parses one line of a target's file; null for a line that isn't one (a write cut short).</summary>
    public static object? Parse(string line, string target)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            var at = DateTimeOffset.FromUnixTimeMilliseconds(root.GetProperty("at").GetInt64());
            if (root.TryGetProperty("n", out var noteKind))
            {
                var kind = noteKind.GetString() switch { "gap" => NoteKind.Gap, "source" => NoteKind.Source, _ => NoteKind.Warning };
                return new CaptureNote(kind, target, at, root.GetProperty("text").GetString() ?? string.Empty);
            }

            var tableName = root.GetProperty("r").GetString()!;
            var table = RcaContract.Table(tableName);
            var row = new CaptureRow(tableName, target, at, root.TryGetProperty("src", out var source) ? source.GetString() ?? string.Empty : string.Empty, root.TryGetProperty("s", out var sentinel) && sentinel.GetInt32() == 1);
            foreach (var property in root.GetProperty("v").EnumerateObject())
            {
                if (table.Column(property.Name) is { } column)
                {
                    row.Set(property.Name, ReadValue(column, property.Value));
                }
            }

            return row;
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
            return null;
        }
    }

    internal static void WriteValue(Utf8JsonWriter json, RcaColumn column, object? value)
    {
        if (value is null)
        {
            json.WriteNull(column.Name);
            return;
        }

        switch (column.Type)
        {
            case "string":
                json.WriteString(column.Name, value as string ?? Convert.ToString(value, CultureInfo.InvariantCulture));
                break;
            case "timestamp":
                json.WriteNumber(column.Name, value is DateTimeOffset time ? time.ToUnixTimeMilliseconds() : throw new InvalidOperationException($"{column.Name} is a timestamp; got {value.GetType().Name}."));
                break;
            case "long" or "integer":
                json.WriteNumber(column.Name, value switch
                {
                    long number => number,
                    int number => number,
                    short number => number,
                    _ => throw new InvalidOperationException($"{column.Name} is an integer; got {value.GetType().Name}."),
                });
                break;
            case "double":
                json.WriteNumber(column.Name, value switch
                {
                    double number => number,
                    float number => number,
                    decimal number => (double)number,
                    long number => number,
                    int number => number,
                    _ => throw new InvalidOperationException($"{column.Name} is a number; got {value.GetType().Name}."),
                });
                break;
            case "boolean":
                json.WriteBoolean(column.Name, value is bool flag ? flag : throw new InvalidOperationException($"{column.Name} is a boolean; got {value.GetType().Name}."));
                break;
            default:
                throw new InvalidOperationException($"{column.Name} has the type {column.Type}, which the document doesn't carry.");
        }
    }

    private static object? ReadValue(RcaColumn column, JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        return column.Type switch
        {
            "string" => value.GetString(),
            "timestamp" => DateTimeOffset.FromUnixTimeMilliseconds(value.GetInt64()),
            "long" or "integer" => value.GetInt64(),
            "double" => value.GetDouble(),
            "boolean" => value.GetBoolean(),
            _ => null,
        };
    }

    /// <summary>Reads a file's complete lines from <paramref name="offset"/> on, with each line's end offset; a last line without its newline waits for the writer.</summary>
    public static IEnumerable<(string Line, long Start, long End)> ReadLines(string path, long offset = 0)
    {
        if (!File.Exists(path))
        {
            yield break;
        }

        byte[] bytes;
        using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
        {
            if (offset >= stream.Length)
            {
                yield break;
            }

            stream.Seek(offset, SeekOrigin.Begin);
            bytes = new byte[stream.Length - offset];
            var read = 0;
            while (read < bytes.Length)
            {
                var n = stream.Read(bytes, read, bytes.Length - read);
                if (n == 0)
                {
                    break;
                }

                read += n;
            }

            if (read < bytes.Length)
            {
                Array.Resize(ref bytes, read);
            }
        }

        var start = 0;
        for (var i = 0; i < bytes.Length; i++)
        {
            if (bytes[i] != (byte)'\n')
            {
                continue;
            }

            if (i > start)
            {
                yield return (Encoding.UTF8.GetString(bytes, start, i - start), offset + start, offset + i + 1);
            }

            start = i + 1;
        }
    }
}
