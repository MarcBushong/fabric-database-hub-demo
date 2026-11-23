using System.Globalization;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>Why a capture statement failed, which decides what the observer does next.</summary>
internal enum CaptureFailureKind
{
    /// <summary>The identity lacks a permission the block needs: an RCA.CAPTURE.&lt;target&gt; Warning with its fix.</summary>
    Permission,

    /// <summary>The statement ran past its timeout or a lock timeout: a slow sample.</summary>
    Timeout,

    /// <summary>The target can't be reached now (stopped, resuming, a replica that doesn't exist yet): try again later.</summary>
    Connection,

    /// <summary>Anything else: recorded as a gap.</summary>
    Other,
}

/// <summary>A capture statement that failed, already described safely (redacted, no secret).</summary>
internal sealed class CaptureException(CaptureFailureKind kind, string message, Exception? inner = null) : Exception(message, inner)
{
    public CaptureFailureKind Kind { get; } = kind;
}

/// <summary>One result row: column name to value, with database nulls as null.</summary>
internal sealed class CaptureValues(IReadOnlyDictionary<string, object?> values)
{
    public IReadOnlyDictionary<string, object?> Raw => values;

    public bool Has(string column) => values.ContainsKey(column);

    public object? Get(string column) => values.TryGetValue(column, out var value) ? value : null;

    public string? Text(string column) => Get(column) switch
    {
        null => null,
        string text => text,
        byte[] bytes => "0x" + Convert.ToHexString(bytes),
        IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
        var other => other.ToString(),
    };

    public long? Long(string column) => Get(column) switch
    {
        null => null,
        long value => value,
        int value => value,
        short value => value,
        byte value => value,
        decimal value => (long)Math.Round(value, MidpointRounding.AwayFromZero),
        double value => double.IsFinite(value) ? (long)Math.Round(value, MidpointRounding.AwayFromZero) : null,
        float value => float.IsFinite(value) ? (long)Math.Round(value, MidpointRounding.AwayFromZero) : null,
        string text when long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) => parsed,
        _ => null,
    };

    public double? Double(string column) => Get(column) switch
    {
        null => null,
        double value => double.IsFinite(value) ? value : null,
        float value => float.IsFinite(value) ? value : null,
        decimal value => (double)value,
        long value => value,
        int value => value,
        short value => value,
        byte value => value,
        string text when double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) => parsed,
        _ => null,
    };

    public bool? Bool(string column) => Get(column) switch
    {
        null => null,
        bool value => value,
        string text when bool.TryParse(text, out var parsed) => parsed,
        _ => null,
    };

    /// <summary>A time the server returned: SQL Server's datetime2 (SYSUTCDATETIME, UTC) or PostgreSQL's timestamptz.</summary>
    public DateTimeOffset? Time(string column) => Get(column) switch
    {
        null => null,
        DateTimeOffset value => value.ToUniversalTime(),
        DateTime value => new DateTimeOffset(DateTime.SpecifyKind(value.Kind == DateTimeKind.Local ? value.ToUniversalTime() : value, DateTimeKind.Utc)),
        _ => null,
    };

    public IReadOnlyList<long> Longs(string column) => Get(column) switch
    {
        int[] values => [.. values.Select(v => (long)v)],
        long[] values => values,
        _ => [],
    };
}

/// <summary>One parameter of a capture block: T-SQL's by name (<c>@since</c>), PostgreSQL's by position (<c>$1</c>, then <c>$2</c>), with no name.</summary>
internal sealed record CaptureParameter(string? Name, object? Value);

/// <summary>
/// A capture block's parameters, so the block runs exactly as the catalog has it: T-SQL's bound by name, PostgreSQL's by
/// position in this order. Values are plain values (a time, a flag, a string, an array of numbers or strings).
/// </summary>
internal sealed class CaptureParameters : IReadOnlyList<CaptureParameter>
{
    private readonly List<CaptureParameter> items;

    private CaptureParameters(List<CaptureParameter> items) => this.items = items;

    public static CaptureParameters None { get; } = new([]);

    public int Count => items.Count;

    /// <summary>True for T-SQL's named parameters; false for PostgreSQL's positional ones, or none.</summary>
    public bool IsNamed => items.Count > 0 && items[0].Name is not null;

    public CaptureParameter this[int index] => items[index];

    /// <summary>T-SQL's: each name starts with @ and appears once.</summary>
    public static CaptureParameters Named(params (string Name, object? Value)[] values)
    {
        var list = new List<CaptureParameter>(values.Length);
        foreach (var (name, value) in values)
        {
            if (name is not ['@', _, ..] || list.Exists(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase)))
            {
                throw new ArgumentException($"A T-SQL capture parameter needs a name of its own that starts with @ ('{name}').", nameof(values));
            }

            list.Add(new CaptureParameter(name, value));
        }

        return new CaptureParameters(list);
    }

    /// <summary>PostgreSQL's: the first value is <c>$1</c>.</summary>
    public static CaptureParameters Positional(params object?[] values) => new([.. values.Select(v => new CaptureParameter(null, v))]);

    /// <summary>A named parameter's value, or null when there's none of that name.</summary>
    public object? Value(string name) => items.Find(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase))?.Value;

    public IEnumerator<CaptureParameter> GetEnumerator() => items.GetEnumerator();

    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
}

/// <summary>One open connection to one target: the observer runs one statement at a time on it.</summary>
internal interface ICaptureConnection : IAsyncDisposable
{
    /// <summary>Runs a catalog block and returns its rows. <paramref name="parameter"/> is RCA-PG-11's $1, the head blockers' pids.</summary>
    Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken);

    /// <summary>
    /// Runs a catalog block with its parameters: T-SQL's by name, PostgreSQL's by position. A connection that takes only the
    /// first method's runs a block with none, or with one array of pids, and refuses others.
    /// </summary>
    Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, CaptureParameters parameters, TimeSpan timeout, CancellationToken cancellationToken) =>
        parameters.Count switch
        {
            0 => QueryAsync(blockId, text, (int[]?)null, timeout, cancellationToken),
            1 when !parameters.IsNamed && parameters[0].Value is int[] pids => QueryAsync(blockId, text, pids, timeout, cancellationToken),
            _ => throw new NotSupportedException($"This capture connection can't bind {blockId}'s parameters."),
        };
}

/// <summary>Opens connections to one target with the runner's existing sign-in and the observer's own application name.</summary>
internal interface ICaptureConnector
{
    /// <summary>A description that's safe to log.</summary>
    string Description { get; }

    Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken);
}
