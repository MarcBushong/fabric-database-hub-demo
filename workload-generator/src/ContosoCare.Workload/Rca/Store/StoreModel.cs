using System.Text.Json.Serialization;

namespace ContosoCare.Workload.Rca.Store;

/// <summary>An observation span's own record (span.json), which the observer writes: who captured it, when, and how far it's complete.</summary>
internal sealed class SpanFile
{
    public int Version { get; set; } = 1;

    public string SpanId { get; set; } = string.Empty;

    public string Host { get; set; } = string.Empty;

    public int ProcessId { get; set; }

    public DateTimeOffset? ProcessStartedUtc { get; set; }

    public DateTimeOffset StartedUtc { get; set; }

    public DateTimeOffset? ClosedUtc { get; set; }

    public Dictionary<string, SpanTarget> Targets { get; set; } = new(StringComparer.Ordinal);
}

/// <summary>One target in a span: when it was observed, and the time before which every row of it is written.</summary>
internal sealed class SpanTarget
{
    public List<SpanInterval> Intervals { get; set; } = [];

    public DateTimeOffset? WatermarkUtc { get; set; }
}

internal sealed class SpanInterval
{
    public DateTimeOffset From { get; set; }

    public DateTimeOffset? To { get; set; }
}

/// <summary>What the export took from a span (export.json), which only the export writes.</summary>
internal sealed class SpanExport
{
    public int Version { get; set; } = 1;

    /// <summary>The control session the span's documents belong to, once an export bound it; null for none.</summary>
    public string? SessionId { get; set; }

    public bool Bound { get; set; }

    public Dictionary<string, TargetExport> Targets { get; set; } = new(StringComparer.Ordinal);

    public long AnswerKeyBytes { get; set; }

    public DateTimeOffset? LastExportUtc { get; set; }

    /// <summary>True when the span is closed (or its process is gone) and the export took all of it: retention may delete it 7 days later.</summary>
    public bool Complete { get; set; }

    public List<string> Documents { get; set; } = [];
}

internal sealed class TargetExport
{
    /// <summary>The end of the last window exported for the target: the next document starts here.</summary>
    public DateTimeOffset? ThroughUtc { get; set; }

    /// <summary>How far into the target's file the last export read.</summary>
    public long ReadBytes { get; set; }
}

/// <summary>
/// The capture's end (capture-end.json), which a session's stop records with <c>rca export --end-capture</c>: the observer
/// captures nothing from then on, until a profile is set after it. Only the export writes it, under the store's lock.
/// </summary>
internal sealed class CaptureEndFile
{
    public int Version { get; set; } = 1;

    public DateTimeOffset EndedUtc { get; set; }

    /// <summary>The control session whose stop recorded it, or null outside one.</summary>
    public string? SessionId { get; set; }
}

/// <summary>Each session's exports from this host (sessions.json): the next sequence and the gzip already exported, for the budget.</summary>
internal sealed class SessionLedger
{
    public int Version { get; set; } = 1;

    public Dictionary<string, SessionUse> Sessions { get; set; } = new(StringComparer.Ordinal);
}

internal sealed class SessionUse
{
    public int Sequence { get; set; }

    public long Bytes { get; set; }

    public int Parts { get; set; }

    public DateTimeOffset? LastExportUtc { get; set; }
}

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    WriteIndented = true)]
[JsonSerializable(typeof(SpanFile))]
[JsonSerializable(typeof(SpanExport))]
[JsonSerializable(typeof(SessionLedger))]
[JsonSerializable(typeof(CaptureEndFile))]
internal sealed partial class RcaStoreJsonContext : JsonSerializerContext;
