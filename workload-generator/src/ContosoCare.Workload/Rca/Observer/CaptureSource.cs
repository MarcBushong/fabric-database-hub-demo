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

/// <summary>One open connection to one target: the observer runs one statement at a time on it.</summary>
internal interface ICaptureConnection : IAsyncDisposable
{
    /// <summary>Runs a catalog block and returns its rows. <paramref name="parameter"/> is RCA-PG-11's $1, the head blockers' pids.</summary>
    Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken);
}

/// <summary>Opens connections to one target with the runner's existing sign-in and the observer's own application name.</summary>
internal interface ICaptureConnector
{
    /// <summary>A description that's safe to log.</summary>
    string Description { get; }

    Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken);
}
