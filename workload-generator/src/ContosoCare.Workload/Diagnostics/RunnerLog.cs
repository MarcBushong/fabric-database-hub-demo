using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace ContosoCare.Workload.Diagnostics;

internal enum LogFormat
{
    Text,
    Json,
}

internal enum LogLevel
{
    Debug,
    Information,
    Warning,
    Error,
}

/// <summary>
/// Redacts secrets before anything is written. The rules mirror Protect-DemoText in the DbHubDemo PowerShell
/// module: JWTs, bearer tokens, SAS signatures, account keys, connection-string passwords, secret-named JSON
/// properties, GitHub tokens, and product keys.
/// </summary>
internal static partial class Redactor
{
    public static string Redact(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return text ?? string.Empty;
        }

        var result = JwtPattern().Replace(text, "[REDACTED:jwt]");
        result = BearerPattern().Replace(result, "$1[REDACTED]");
        result = SasSignaturePattern().Replace(result, "$1[REDACTED]");
        result = AccountKeyPattern().Replace(result, "$1[REDACTED]");
        result = ConnectionPasswordPattern().Replace(result, "$1[REDACTED]");
        result = AccessTokenPattern().Replace(result, "$1[REDACTED]");
        result = JsonSecretPattern().Replace(result, "$1[REDACTED]$2");
        result = GitHubTokenPattern().Replace(result, "[REDACTED:github-token]");
        result = ProductKeyPattern().Replace(result, "[REDACTED:product-key]");
        return result;
    }

    [GeneratedRegex(@"eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*")]
    private static partial Regex JwtPattern();

    [GeneratedRegex(@"(?i)(\bbearer\s+)[A-Za-z0-9._~+/=-]{8,}")]
    private static partial Regex BearerPattern();

    [GeneratedRegex(@"(?i)((?:^|[?&;\s""'])sig=)[^&\s""']+")]
    private static partial Regex SasSignaturePattern();

    [GeneratedRegex(@"(?i)(AccountKey=)[^;\s""']+")]
    private static partial Regex AccountKeyPattern();

    [GeneratedRegex(@"(?i)(\b(?:password|pwd)\s*=\s*)[^;\s""']+")]
    private static partial Regex ConnectionPasswordPattern();

    [GeneratedRegex(@"(?i)(\baccess[ _]?token\s*=\s*)[^;\s""']+")]
    private static partial Regex AccessTokenPattern();

    [GeneratedRegex(@"(?i)(""(?:adminPassword|password|accessToken|access_token|refreshToken|clientSecret|client_secret|productKey|sasToken|sasUrl|token)""\s*:\s*"")[^""]*("")")]
    private static partial Regex JsonSecretPattern();

    [GeneratedRegex(@"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b")]
    private static partial Regex GitHubTokenPattern();

    [GeneratedRegex(@"\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b")]
    private static partial Regex ProductKeyPattern();
}

/// <summary>
/// Structured, redacted logging to standard error (and optionally a file): one line per event with an event name
/// and key-value fields, as text or JSON lines. Standard output stays free for command results.
/// </summary>
internal sealed class RunnerLog : IDisposable
{
    private readonly TextWriter writer;
    private readonly TextWriter? file;
    private readonly LogFormat format;
    private readonly LogLevel minimum;
    private readonly Lock gate = new();

    public RunnerLog(TextWriter writer, LogFormat format = LogFormat.Text, LogLevel minimum = LogLevel.Information, string? filePath = null)
    {
        this.writer = writer;
        this.format = format;
        this.minimum = minimum;
        if (!string.IsNullOrWhiteSpace(filePath))
        {
            var directory = Path.GetDirectoryName(Path.GetFullPath(filePath));
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }

            file = new StreamWriter(new FileStream(filePath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite), new UTF8Encoding(false)) { AutoFlush = true };
        }
    }

    public static RunnerLog Null { get; } = new(TextWriter.Null);

    public void Debug(string eventName, string message, params (string Key, object? Value)[] fields) => Write(LogLevel.Debug, eventName, message, fields);

    public void Info(string eventName, string message, params (string Key, object? Value)[] fields) => Write(LogLevel.Information, eventName, message, fields);

    public void Warn(string eventName, string message, params (string Key, object? Value)[] fields) => Write(LogLevel.Warning, eventName, message, fields);

    public void Error(string eventName, string message, params (string Key, object? Value)[] fields) => Write(LogLevel.Error, eventName, message, fields);

    public void Write(LogLevel level, string eventName, string message, IReadOnlyList<(string Key, object? Value)> fields)
    {
        if (level < minimum)
        {
            return;
        }

        var line = format == LogFormat.Json
            ? FormatJson(DateTimeOffset.UtcNow, level, eventName, message, fields)
            : FormatText(DateTimeOffset.UtcNow, level, eventName, message, fields);
        lock (gate)
        {
            // Logging never ends a run or a profile lane (Phase 25b): a closed pipe or a full disk loses the line instead.
            try
            {
                writer.WriteLine(line);
            }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException)
            {
                WriteFailures++;
            }

            try
            {
                file?.WriteLine(line);
            }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException)
            {
                WriteFailures++;
            }
        }
    }

    /// <summary>How many lines couldn't be written to standard error or the log file.</summary>
    public int WriteFailures { get; private set; }

    internal static string FormatText(DateTimeOffset time, LogLevel level, string eventName, string message, IReadOnlyList<(string Key, object? Value)> fields)
    {
        var builder = new StringBuilder();
        builder.Append(time.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture))
            .Append(' ')
            .Append(level switch { LogLevel.Debug => "DBG", LogLevel.Information => "INF", LogLevel.Warning => "WRN", _ => "ERR" })
            .Append(' ')
            .Append(eventName)
            .Append(' ')
            .Append(Redactor.Redact(message));
        foreach (var (key, value) in fields)
        {
            var text = Redactor.Redact(FormatValue(value));
            builder.Append(' ').Append(key).Append('=');
            if (text.Contains(' ', StringComparison.Ordinal) || text.Length == 0)
            {
                builder.Append('"').Append(text.Replace("\"", "'", StringComparison.Ordinal)).Append('"');
            }
            else
            {
                builder.Append(text);
            }
        }

        return builder.ToString();
    }

    internal static string FormatJson(DateTimeOffset time, LogLevel level, string eventName, string message, IReadOnlyList<(string Key, object? Value)> fields)
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer))
        {
            json.WriteStartObject();
            json.WriteString("time", time.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture));
            json.WriteString("level", level.ToString());
            json.WriteString("event", eventName);
            json.WriteString("message", Redactor.Redact(message));
            foreach (var (key, value) in fields)
            {
                json.WriteString(key, Redactor.Redact(FormatValue(value)));
            }

            json.WriteEndObject();
        }

        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    private static string FormatValue(object? value) => value switch
    {
        null => string.Empty,
        DateTimeOffset time => time.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture),
        DateTime time => time.ToString("yyyy-MM-ddTHH:mm:ss.fff", CultureInfo.InvariantCulture),
        TimeSpan span => span.TotalSeconds.ToString("0.###", CultureInfo.InvariantCulture) + "s",
        IFormattable formattable => formattable.ToString(null, CultureInfo.InvariantCulture),
        _ => value.ToString() ?? string.Empty,
    };

    public void Dispose()
    {
        file?.Dispose();
    }
}
