using System.Text;
using System.Text.RegularExpressions;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>
/// The capture catalog (rca/capture/README.md), embedded from rca/capture/sqlserver.sql and postgresql.sql at build time:
/// the observer runs exactly these blocks, by ID, and nothing else. Full-line comments are left out of the text it
/// sends; the statements are as the files have them.
/// </summary>
internal static partial class CaptureCatalog
{
    private static readonly Lazy<IReadOnlyDictionary<string, string>> Blocks = new(Load);

    public static IReadOnlyDictionary<string, string> All => Blocks.Value;

    /// <summary>One block's statement text.</summary>
    public static string Get(string id) =>
        All.TryGetValue(id, out var text) ? text : throw new InvalidOperationException($"The capture catalog has no block {id}.");

    /// <summary>
    /// RCA-XE-05 for T3, which its comment gives as "the same statements with ON DATABASE and sys.database_event_sessions":
    /// a database-scoped event session is stopped and dropped like a server-scoped one.
    /// </summary>
    public static string DatabaseScopedDrop() => Get("RCA-XE-05")
        .Replace("sys.dm_xe_sessions", "sys.dm_xe_database_sessions", StringComparison.Ordinal)
        .Replace("sys.server_event_sessions", "sys.database_event_sessions", StringComparison.Ordinal)
        .Replace("ON SERVER", "ON DATABASE", StringComparison.Ordinal);

    /// <summary>Splits a catalog file into its blocks by their <c>-- name: &lt;ID&gt;</c> lines; full-line comments go.</summary>
    internal static Dictionary<string, string> Parse(string text)
    {
        var blocks = new Dictionary<string, string>(StringComparer.Ordinal);
        string? current = null;
        var body = new StringBuilder();
        foreach (var raw in text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            var name = NameLine().Match(raw);
            if (name.Success)
            {
                Add(blocks, current, body);
                current = name.Groups[1].Value;
                body.Clear();
                continue;
            }

            if (current is null || raw.TrimStart().StartsWith("--", StringComparison.Ordinal))
            {
                continue;
            }

            body.Append(raw).Append('\n');
        }

        Add(blocks, current, body);
        return blocks;
    }

    private static void Add(Dictionary<string, string> blocks, string? id, StringBuilder body)
    {
        if (id is null)
        {
            return;
        }

        var text = body.ToString().Trim();
        if (text.Length == 0 || !blocks.TryAdd(id, text))
        {
            throw new InvalidOperationException($"The capture catalog's block {id} is empty or appears twice.");
        }
    }

    private static Dictionary<string, string> Load()
    {
        var assembly = typeof(CaptureCatalog).Assembly;
        var all = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var file in new[] { "rca/capture/sqlserver.sql", "rca/capture/postgresql.sql" })
        {
            using var stream = assembly.GetManifestResourceStream(file) ?? throw new InvalidOperationException($"The runner was built without the capture catalog ({file}).");
            using var reader = new StreamReader(stream);
            foreach (var (id, text) in Parse(reader.ReadToEnd()))
            {
                all.Add(id, text);
            }
        }

        return all;
    }

    [GeneratedRegex(@"^-- name: (RCA-[A-Z]+-[0-9]{2})\s*$")]
    private static partial Regex NameLine();
}
