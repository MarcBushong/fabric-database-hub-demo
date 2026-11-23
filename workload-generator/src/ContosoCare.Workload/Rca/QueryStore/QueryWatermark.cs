using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using ContosoCare.Workload.Profiles;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// The span store's side of a backfill (rca/README.md, Pending publication), which the sidecar's store-backed sink
/// provides: the span this process captures into now, and a sink into an earlier span's sidecar, so a backfill's rows
/// keep the session and span they belong to.
/// </summary>
internal interface ISidecarSpans
{
    /// <summary>The ID of the span this process captures into now, or null when none is open.</summary>
    string? CurrentSpan { get; }

    /// <summary>A sink that appends to the sidecar of the span with this ID, or null when the store no longer has the span.</summary>
    ISidecarSink? ForSpan(string spanId);
}

/// <summary>
/// One span's time that Query Store hadn't published when it was read (an interval shows only once it ends): from the end
/// of the last interval read to the observer's end. <see cref="ToUtc"/> is null while the observer that recorded it still
/// runs: a range whose process is gone ends one interval after it was last recorded.
/// </summary>
internal sealed class PendingRange
{
    public string SpanId { get; set; } = string.Empty;

    /// <summary>When the observation that recorded the range began: a span can observe T4 more than once.</summary>
    public DateTimeOffset ObservedFromUtc { get; set; }

    /// <summary>The control session, once something knows it; the span's own binding (export.json) is what counts.</summary>
    public string? SessionId { get; set; }

    public DateTimeOffset FromUtc { get; set; }

    public DateTimeOffset? ToUtc { get; set; }

    /// <summary>When the range was last recorded: each read moves it on, and the observer's end closes it.</summary>
    public DateTimeOffset RecordedUtc { get; set; }

    /// <summary>
    /// When T4 had started (pg_postmaster_start_time()) as of the range's last record: a backfill that finds it started
    /// since knows the window Query Store held in memory at the stop shows by now or never will.
    /// </summary>
    public DateTimeOffset? ServerStartedUtc { get; set; }
}

/// <summary>What <c>rca\query-watermark\&lt;target&gt;.json</c> holds.</summary>
internal sealed class QueryWatermarkState
{
    public int Version { get; set; } = 1;

    public string Target { get; set; } = string.Empty;

    /// <summary>The end of the newest interval any read took, on this host.</summary>
    public DateTimeOffset? ThroughUtc { get; set; }

    /// <summary>When T4 had started as of the newest read on this host.</summary>
    public DateTimeOffset? ServerStartedUtc { get; set; }

    public List<PendingRange> Pending { get; set; } = [];
}

/// <summary>
/// The unread-interval watermark of one target's Query Store (rca/README.md, Pending publication): a file in the evidence
/// store's folder, beside the spans and outside them, so span retention never deletes it. The observer and an export are
/// separate processes, so every change takes the file's lock, reads, changes, and writes it whole. A file that can't be
/// parsed counts as empty: its ranges are lost, and the coverage of the sessions they belonged to still says pending.
/// </summary>
internal sealed class QueryWatermark
{
    public const string Folder = "query-watermark";

    private static readonly TimeSpan LockWait = TimeSpan.FromSeconds(10);

    public QueryWatermark(string storeRoot, string target)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(storeRoot);
        if (target.Length == 0 || !target.All(c => char.IsAsciiLetterOrDigit(c) || c == '-'))
        {
            throw new ArgumentException($"'{target}' isn't a target's key.", nameof(target));
        }

        Target = target;
        Directory = Path.Combine(Path.GetFullPath(storeRoot), Folder);
        FilePath = Path.Combine(Directory, target + ".json");
    }

    public string Target { get; }

    public string Directory { get; }

    public string FilePath { get; }

    /// <summary>The state as the file has it now (an empty one when there's none).</summary>
    public QueryWatermarkState Read()
    {
        using var held = Lock();
        return Load();
    }

    /// <summary>Reads the state, lets <paramref name="change"/> change it, and writes it back, all under the file's lock.</summary>
    public QueryWatermarkState Update(Action<QueryWatermarkState> change)
    {
        ArgumentNullException.ThrowIfNull(change);
        using var held = Lock();
        var state = Load();
        change(state);
        state.Version = 1;
        state.Target = Target;
        var temporary = FilePath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(state, QueryWatermarkJsonContext.Default.QueryWatermarkState), new UTF8Encoding(false));
        FileReplace.Replace(temporary, FilePath, FileReplace.Move);
        return state;
    }

    private QueryWatermarkState Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                using var stream = new FileStream(FilePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                if (JsonSerializer.Deserialize(stream, QueryWatermarkJsonContext.Default.QueryWatermarkState) is { Version: 1 } state && string.Equals(state.Target, Target, StringComparison.Ordinal))
                {
                    state.Pending.RemoveAll(p => string.IsNullOrEmpty(p.SpanId));
                    return state;
                }
            }
        }
        catch (JsonException)
        {
        }

        return new QueryWatermarkState { Target = Target };
    }

    private FileStream Lock()
    {
        System.IO.Directory.CreateDirectory(Directory);
        var path = Path.Combine(Directory, Target + ".lock");
        var deadline = DateTimeOffset.UtcNow + LockWait;
        while (true)
        {
            try
            {
                return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
            }
            catch (IOException) when (DateTimeOffset.UtcNow < deadline)
            {
                Thread.Sleep(50);
            }
        }
    }
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    WriteIndented = true)]
[JsonSerializable(typeof(QueryWatermarkState))]
internal sealed partial class QueryWatermarkJsonContext : JsonSerializerContext;
