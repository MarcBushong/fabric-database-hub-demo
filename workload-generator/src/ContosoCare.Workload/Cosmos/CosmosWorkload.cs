using System.Buffers;
using System.Globalization;
using System.Text;
using System.Text.Json;
using ContosoCare.Workload.Runs;

namespace ContosoCare.Workload.Cosmos;

/// <summary>
/// The documents the runner writes to T5's <c>contosocare/patient-events</c> (database/cosmosdb/README.md). Every one
/// has <c>id</c>, <c>patientId</c> (the partition key), <c>type</c>, <c>at</c>, and <c>source</c> (the run's tag) at the
/// top level, where they're indexed; the bulk is one top-level string, <c>payload</c>, which the container's indexing
/// policy leaves out (<c>/payload/*</c>), so a document's size changes its storage and RU, not its index.
/// </summary>
internal static class CosmosDocuments
{
    /// <summary>The longest payload: 16 KB, ru-storm's largest documentKb.</summary>
    public const int MaximumPayloadLength = 16 * 1024;

    /// <summary>The warmup document's partition (<c>{ id: "warmup", patientId: "p-warmup" }</c>).</summary>
    public const string WarmupPatientId = "p-warmup";

    public const string WarmupId = "warmup";

    private static readonly string Filler = BuildFiller();

    /// <summary>A patient's profile document (<c>id: "patient"</c>): setup seeds it, and healthy-baseline updates it.</summary>
    public static byte[] Patient(string patientId, int number, DateTimeOffset at, string source, int payloadLength) =>
        Write(HealthyBaselineMix.ProfileId, patientId, "patient", at, source, payloadLength, json =>
        {
            json.WriteString("facility", string.Create(CultureInfo.InvariantCulture, $"F{(number % 12) + 1:00}"));
            json.WriteString("ward", string.Create(CultureInfo.InvariantCulture, $"W{(number % 8) + 1}"));
            json.WriteString("status", PatientStatuses[number % PatientStatuses.Length]);
        });

    /// <summary>One of healthy-baseline's events for a patient: <c>hb-ev-0</c> to <c>hb-ev-19</c>, overwritten in turn.</summary>
    public static byte[] Event(string id, string patientId, string type, long sequence, DateTimeOffset at, string source, int payloadLength) =>
        Write(id, patientId, type, at, source, payloadLength, json => json.WriteNumber("sequence", sequence));

    /// <summary>One of ru-storm's bedside-monitor readings in a hot partition (<c>storm-01-000</c> to <c>storm-01-099</c> in p-storm-01), overwritten in turn and tagged <c>kind: "ru-storm"</c>, which its cleanup finds them by.</summary>
    public static byte[] StormReading(string id, string patientId, int writer, long sequence, DateTimeOffset at, string source, int payloadLength) =>
        Write(id, patientId, "monitor-reading", at, source, payloadLength, json =>
        {
            json.WriteString("kind", RuStorm.Kind);
            json.WriteString("device", string.Create(CultureInfo.InvariantCulture, $"bedside-monitor-{writer:00}"));
            json.WriteNumber("sequence", sequence);
        });

    /// <summary>The warmup document: <c>{ id: "warmup", patientId: "p-warmup", type: "warmup", at, source }</c>.</summary>
    public static byte[] Warmup(DateTimeOffset at, string source) => Write(WarmupId, WarmupPatientId, "warmup", at, source, 0, null);

    internal static string FormatTime(DateTimeOffset value) => value.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture);

    private static readonly string[] PatientStatuses = ["admitted", "in-treatment", "observation", "discharge-planned"];

    private static byte[] Write(string id, string patientId, string type, DateTimeOffset at, string source, int payloadLength, Action<Utf8JsonWriter>? fields)
    {
        var buffer = new ArrayBufferWriter<byte>(512 + payloadLength);
        using (var json = new Utf8JsonWriter(buffer))
        {
            json.WriteStartObject();
            json.WriteString("id", id);
            json.WriteString("patientId", patientId);
            json.WriteString("type", type);
            json.WriteString("at", FormatTime(at));
            json.WriteString("source", source);
            fields?.Invoke(json);
            if (payloadLength > 0)
            {
                json.WriteString("payload", Filler.AsSpan(0, Math.Min(payloadLength, MaximumPayloadLength)));
            }

            json.WriteEndObject();
        }

        return buffer.WrittenSpan.ToArray();
    }

    private static string BuildFiller()
    {
        const string sample = "ContosoCare bedside sample: heart rate, SpO2, blood pressure, respiration, temperature. ";
        var builder = new StringBuilder(MaximumPayloadLength + sample.Length);
        while (builder.Length < MaximumPayloadLength)
        {
            builder.Append(sample);
        }

        return builder.ToString(0, MaximumPayloadLength);
    }
}

internal enum CosmosOperationKind
{
    Read,
    Upsert,
    Query,
}

/// <summary>One request of healthy-baseline on T5: what it does, to which patient, and to which document.</summary>
internal readonly record struct CosmosOperation(CosmosOperationKind Kind, string PatientId, string? DocumentId, string? Type);

/// <summary>
/// healthy-baseline on T5: a steady mix over 500 patients (<c>p-0001</c> to <c>p-0500</c>): 40% point reads, 40% upserts,
/// and 20% single-partition queries for a patient's latest events. Upserts overwrite a bounded set: each patient's
/// profile document (<c>patient</c>) and 20 events (<c>hb-ev-0</c> to <c>hb-ev-19</c>), about 0.7 to 0.9 KB each, so
/// storage stays bounded without deletes.
/// </summary>
internal static class HealthyBaselineMix
{
    public const string ScenarioId = "healthy-baseline";

    public const int Patients = 500;

    public const int EventsPerPatient = 20;

    /// <summary>The profile document's ID in each patient's partition.</summary>
    public const string ProfileId = "patient";

    /// <summary>The query: a patient's five latest documents, within its partition.</summary>
    public const string Query = "SELECT TOP 5 c.id, c.type, c.at FROM c WHERE c.patientId = @p ORDER BY c._ts DESC";

    /// <summary>The profile document's payload: setup's seed and the baseline write the same size.</summary>
    public const int ProfilePayloadLength = 512;

    private static readonly string[] EventTypes = ["vitals", "medication", "lab-result", "nursing-note", "bed-move"];

    public static string PatientId(int number) => string.Create(CultureInfo.InvariantCulture, $"p-{number:0000}");

    public static string EventId(int slot) => string.Create(CultureInfo.InvariantCulture, $"hb-ev-{slot}");

    /// <summary>
    /// The next request. <paramref name="next"/> returns a number from 0 to its argument minus 1 (a random source);
    /// <paramref name="turn"/> counts the worker's requests and rotates the event slot an upsert overwrites.
    /// </summary>
    public static CosmosOperation Next(Func<int, int> next, long turn)
    {
        var patient = PatientId(next(Patients) + 1);
        var roll = next(100);
        if (roll < 40)
        {
            return new CosmosOperation(CosmosOperationKind.Read, patient, next(2) == 0 ? ProfileId : EventId(next(EventsPerPatient)), null);
        }

        if (roll < 80)
        {
            return next(5) == 0
                ? new CosmosOperation(CosmosOperationKind.Upsert, patient, ProfileId, "patient")
                : new CosmosOperation(CosmosOperationKind.Upsert, patient, EventId((int)(turn % EventsPerPatient)), EventTypes[turn % EventTypes.Length]);
        }

        return new CosmosOperation(CosmosOperationKind.Query, patient, null, null);
    }

    /// <summary>An event's payload: 512 to 704 characters, so each document is about 0.7 to 0.9 KB.</summary>
    public static int EventPayloadLength(long turn) => 512 + ((int)(turn % 4) * 64);

    /// <summary>The patient's number in <c>p-0001</c>.</summary>
    public static int PatientNumber(string patientId) => int.Parse(patientId.AsSpan(2), NumberStyles.None, CultureInfo.InvariantCulture);
}

/// <summary>Where a storm is at a moment of its run: in a wave (writing) or in the calm after it, and how long until that changes.</summary>
internal readonly record struct StormPhase(bool Storm, int Wave, TimeSpan Remaining);

/// <summary>ru-storm's parameters (scenarios/ru-storm/scenario.json).</summary>
internal sealed record StormSettings(int StormSeconds, int CalmSeconds, int DocumentKb, int HotPartitions)
{
    public static StormSettings From(RunPlan plan) => new(
        (int)plan.Parameters["stormSeconds"].Integer,
        (int)plan.Parameters["calmSeconds"].Integer,
        (int)plan.Parameters["documentKb"].Integer,
        (int)plan.Parameters["hotPartitions"].Integer);

    public string Partitions => HotPartitions == 1 ? RuStorm.PartitionName(1) : RuStorm.PartitionName(1) + " to " + RuStorm.PartitionName(HotPartitions);
}

/// <summary>
/// ru-storm: a bedside-monitor integration stuck in a retry loop floods one patient's partition. Waves of upserts to
/// one to four hot logical partitions (<c>p-storm-01</c> to <c>p-storm-04</c>), each over a fixed set of 100 document IDs
/// (<c>storm-01-000</c> to <c>storm-01-099</c> in p-storm-01), from every writer, then a calm with no storm writes;
/// repeated until the run ends. Each writer sends 100 requests a second at most, and after a 429 waits the server's
/// x-ms-retry-after-ms, from 10 ms to 2 seconds, so it never hammers without bound. Every storm document is tagged
/// <c>kind: "ru-storm"</c>; at its end the run deletes them (<see cref="StormCleanup"/>), and so does reset.
/// </summary>
internal static class RuStorm
{
    public const string ScenarioId = "ru-storm";

    /// <summary>The tag on every storm document, which the cleanup queries for.</summary>
    public const string Kind = "ru-storm";

    /// <summary>The hot partitions are p-storm-01 to p-storm-04, ru-storm's own: nothing else writes there.</summary>
    public const int MaximumHotPartitions = 4;

    /// <summary>The documents in each hot partition: storm-&lt;pp&gt;-000 to storm-&lt;pp&gt;-099, 400 at most in all.</summary>
    public const int DocumentsPerPartition = 100;

    /// <summary>One writer starts a request at most every 10 ms: 100 requests a second.</summary>
    public static readonly TimeSpan MinimumInterval = TimeSpan.FromMilliseconds(10);

    public static readonly TimeSpan MinimumRetryAfter = TimeSpan.FromMilliseconds(10);

    public static readonly TimeSpan MaximumRetryAfter = TimeSpan.FromSeconds(2);

    /// <summary>The wait after a 429 when the server didn't say how long (it normally does).</summary>
    public static readonly TimeSpan DefaultRetryAfter = TimeSpan.FromMilliseconds(100);

    /// <summary>A hot partition's patient ID: p-storm-01 to p-storm-04.</summary>
    public static string PartitionName(int number) => string.Create(CultureInfo.InvariantCulture, $"p-storm-{number:00}");

    /// <summary>The hot partition (1 to hotPartitions) a writer writes to: writer 1 to p-storm-01, writer 2 to p-storm-02, and so on.</summary>
    public static int PartitionNumberFor(int writer, int hotPartitions) => ((writer - 1) % Math.Clamp(hotPartitions, 1, MaximumHotPartitions)) + 1;

    public static string PartitionFor(int writer, int hotPartitions) => PartitionName(PartitionNumberFor(writer, hotPartitions));

    /// <summary>The document a write overwrites: one of the 100 in its partition, <c>storm-&lt;pp&gt;-&lt;nnn&gt;</c>. Each writer cycles through all 100 from its own offset, so the set never grows.</summary>
    public static string DocumentId(int partitionNumber, int writer, long sequence) =>
        string.Create(CultureInfo.InvariantCulture, $"storm-{partitionNumber:00}-{(sequence + ((writer - 1) * 13L)) % DocumentsPerPartition:000}");

    /// <summary>The wave and phase <paramref name="elapsed"/> into the run: a storm of stormSeconds, then a calm of calmSeconds; with no calm, one storm after another.</summary>
    public static StormPhase PhaseAt(TimeSpan elapsed, int stormSeconds, int calmSeconds)
    {
        if (elapsed < TimeSpan.Zero)
        {
            elapsed = TimeSpan.Zero;
        }

        var storm = TimeSpan.FromSeconds(Math.Max(1, stormSeconds));
        var cycle = storm + TimeSpan.FromSeconds(Math.Max(0, calmSeconds));
        var index = elapsed.Ticks / cycle.Ticks;
        var into = elapsed - TimeSpan.FromTicks(cycle.Ticks * index);
        return into < storm
            ? new StormPhase(true, (int)index + 1, storm - into)
            : new StormPhase(false, (int)index + 1, cycle - into);
    }

    /// <summary>The pause after each write: about 200 ms at intensity 1, none at 10.</summary>
    public static TimeSpan PauseFor(int intensity) => CosmosPacing.Pause(intensity, 200, 0);

    /// <summary>The wait after a 429: the server's x-ms-retry-after-ms, from 10 ms to 2 seconds.</summary>
    public static TimeSpan RetryWait(TimeSpan? retryAfter)
    {
        var wait = retryAfter ?? DefaultRetryAfter;
        return wait < MinimumRetryAfter ? MinimumRetryAfter : wait > MaximumRetryAfter ? MaximumRetryAfter : wait;
    }

    /// <summary>A storm document's payload, so the whole document is about documentKb KB.</summary>
    public static int PayloadLength(int documentKb) => Math.Clamp((documentKb * 1024) - 320, 200, CosmosDocuments.MaximumPayloadLength);
}

/// <summary>Pacing by intensity, the rule demo.fn_pause follows on the SQL targets: the pause shrinks evenly from intensity 1 to 10.</summary>
internal static class CosmosPacing
{
    /// <summary><paramref name="slowMs"/> at intensity 1, <paramref name="fastMs"/> at 10.</summary>
    public static TimeSpan Pause(int intensity, int slowMs, int fastMs)
    {
        var level = Math.Clamp(intensity, 1, 10);
        return TimeSpan.FromMilliseconds(slowMs - ((slowMs - fastMs) * (level - 1) / 9));
    }

    /// <summary>healthy-baseline's pause: about one request a second per worker at intensity 1, about 20 at 10, as on the SQL targets.</summary>
    public static TimeSpan BaselinePause(int intensity) => Pause(intensity, 1000, 50);
}

/// <summary>A run's totals at a moment.</summary>
internal readonly record struct CosmosMeterSample(DateTimeOffset At, long Requests, long Throttled, double RequestCharge, long Errors)
{
    public CosmosRunCounters ToCounters() => new() { Requests = Requests, Throttled = Throttled, RequestCharge = Math.Round(RequestCharge, 2), Errors = Errors };
}

/// <summary>A run's request counters, which every writer adds to at once: requests (429s included), 429s, request units, and errors.</summary>
internal sealed class CosmosRunMeter
{
    private long requests;
    private long throttled;
    private long errors;
    private long milliRequestUnits;

    public void Record(CosmosResponse response)
    {
        Interlocked.Increment(ref requests);
        if (response.IsThrottled)
        {
            Interlocked.Increment(ref throttled);
        }

        Interlocked.Add(ref milliRequestUnits, (long)Math.Round(response.RequestCharge * 1000));
    }

    /// <summary>A failed request: one that got no answer (the account couldn't be reached, or no token), or an error answer (5xx, 403, ...), which <see cref="Record"/> already counted as a request.</summary>
    public void RecordError() => Interlocked.Increment(ref errors);

    public CosmosMeterSample Sample(DateTimeOffset at) => new(
        at,
        Interlocked.Read(ref requests),
        Interlocked.Read(ref throttled),
        Interlocked.Read(ref milliRequestUnits) / 1000.0,
        Interlocked.Read(ref errors));
}

/// <summary>
/// A run's recent rates for <c>status</c>: requests, request units, and 429s per second over the last 10 seconds, and
/// the 429s in the last minute, from the samples the runner takes every 5 seconds.
/// </summary>
internal sealed class LiveRateWindow(DateTimeOffset start)
{
    public static readonly TimeSpan Recent = TimeSpan.FromSeconds(10);

    public static readonly TimeSpan Minute = TimeSpan.FromMinutes(1);

    private readonly List<CosmosMeterSample> samples = [new CosmosMeterSample(start, 0, 0, 0, 0)];

    public CosmosLiveRates Add(CosmosMeterSample sample)
    {
        samples.Add(sample);

        // Keep the newest sample that's at least a minute old, and every one after it.
        var minuteIndex = samples.FindLastIndex(s => s.At <= sample.At - Minute);
        if (minuteIndex > 0)
        {
            samples.RemoveRange(0, minuteIndex);
        }

        var recentIndex = samples.FindLastIndex(s => s.At <= sample.At - Recent);
        var recent = samples[recentIndex >= 0 ? recentIndex : 0];
        var seconds = (sample.At - recent.At).TotalSeconds;
        return new CosmosLiveRates
        {
            RequestsPerSecond = seconds > 0 ? Math.Round((sample.Requests - recent.Requests) / seconds, 2) : 0,
            RuPerSecond = seconds > 0 ? Math.Round((sample.RequestCharge - recent.RequestCharge) / seconds, 2) : 0,
            ThrottledPerSecond = seconds > 0 ? Math.Round((sample.Throttled - recent.Throttled) / seconds, 2) : 0,
            ThrottledLastMinute = sample.Throttled - samples[0].Throttled,
            UpdatedAt = sample.At,
        };
    }
}
