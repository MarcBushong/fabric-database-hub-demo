using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Xml.Linq;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>One field of an Extended Events event: its value, the text of a mapped value, and an XML payload.</summary>
internal sealed record XeValue(string? Value, string? Text, XElement? Xml);

/// <summary>One event from the observer's ring buffer (RCA-XE-02, RCA-XE-04) or from system_health (RCA-SQL-12).</summary>
internal sealed record XeEvent(string Name, DateTimeOffset At, IReadOnlyDictionary<string, XeValue> Data, IReadOnlyDictionary<string, string> Actions, string Fingerprint)
{
    public string? Field(string name) => Data.TryGetValue(name, out var value) ? value.Value : null;

    /// <summary>A mapped field's text (lock modes, escalation causes), or its value.</summary>
    public string? FieldText(string name) => Data.TryGetValue(name, out var value) ? value.Text ?? value.Value : null;

    public string? Action(string name) => Actions.TryGetValue(name, out var value) ? value : null;

    public long? FieldLong(string name) => long.TryParse(Field(name), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) ? parsed : null;

    public long? ActionLong(string name) => long.TryParse(Action(name), NumberStyles.Integer, CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
}

/// <summary>What one read of the ring buffer returned.</summary>
internal sealed record XeRead(IReadOnlyList<XeEvent> Events, bool Truncated, long Dropped);

/// <summary>
/// The events a source returned that the observer already kept (or left out), by fingerprint, so it writes none of them
/// twice however long the source keeps returning it: the ring buffer holds an event until 5,000 newer ones or its memory
/// push it out. Forgetting keeps the memory bounded: an event before the newest forgotten one is never new again, nor one
/// forgotten in that same millisecond, while another event of that millisecond still is.
/// </summary>
internal sealed class SeenEvents
{
    private readonly Dictionary<string, DateTimeOffset> seen = new(StringComparer.Ordinal);

    // The fingerprints forgotten at exactly ForgottenThrough: the only events of that millisecond that aren't new.
    private readonly HashSet<string> boundary = new(StringComparer.Ordinal);

    /// <summary>The newest time of an event forgotten so far: an event before it is never taken as new, nor one forgotten at it.</summary>
    public DateTimeOffset ForgottenThrough { get; private set; } = DateTimeOffset.MinValue;

    public int Count => seen.Count;

    /// <summary>True the first time an event is offered; false when it was offered before, or was forgotten, or is older than what was.</summary>
    public bool Add(XeEvent item) =>
        (item.At > ForgottenThrough || (item.At == ForgottenThrough && !boundary.Contains(item.Fingerprint)))
        && seen.TryAdd(item.Fingerprint, item.At);

    /// <summary>Forgets the events <paramref name="forget"/> picks, by fingerprint and event time.</summary>
    public void Forget(Func<string, DateTimeOffset, bool> forget)
    {
        foreach (var (fingerprint, at) in seen.Where(e => forget(e.Key, e.Value)).ToList())
        {
            seen.Remove(fingerprint);
            if (at > ForgottenThrough)
            {
                ForgottenThrough = at;
                boundary.Clear();
            }

            if (at == ForgottenThrough)
            {
                boundary.Add(fingerprint);
            }
        }
    }

    public void Clear()
    {
        seen.Clear();
        boundary.Clear();
        ForgottenThrough = DateTimeOffset.MinValue;
    }
}

/// <summary>A deadlock graph reduced to what the rules read (rca/README.md, Deadlocks).</summary>
internal sealed record DeadlockSummary(bool InDatabase, long? Victim, ReducedName VictimName, string? VictimLogin, string? VictimHost, string? VictimModule, string? FirstObject, int Processes, int Resources, string Json);

/// <summary>
/// Reads the Extended Events XML the observer's session returns (RCA-XE-02, RCA-XE-04) and system_health's deadlock
/// reports (RCA-SQL-12), and reduces a deadlock graph to the JSON the rules read: the victim, each process's session,
/// what it holds and wants, and its module and statement for the workload's own sessions only; each resource's type,
/// object, index, mode, holder, and waiter. The formats: the ring_buffer target's XML
/// (https://learn.microsoft.com/sql/relational-databases/extended-events/targets-for-extended-events-in-sql-server#ring_buffer-target)
/// and the deadlock graph's (https://learn.microsoft.com/sql/relational-databases/sql-server-deadlocks-guide#deadlock-information-tools).
/// </summary>
internal static class ExtendedEvents
{
    /// <summary>The deadlock JSON's cap (rca/README.md, Deadlocks).</summary>
    public const int DeadlockJsonLength = 4000;

    /// <summary>Parses a ring buffer target's XML.</summary>
    public static XeRead ParseRingBuffer(string? xml)
    {
        if (string.IsNullOrWhiteSpace(xml))
        {
            return new XeRead([], false, 0);
        }

        var root = XElement.Parse(xml);
        var events = root.Elements("event").Select(ParseEvent).ToList();
        return new XeRead(events, (string?)root.Attribute("truncated") == "1", long.TryParse((string?)root.Attribute("droppedCount"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var dropped) ? dropped : 0);
    }

    /// <summary>Parses one event element (the ring buffer's, or the event_data RCA-SQL-12 returns).</summary>
    public static XeEvent ParseEvent(XElement element)
    {
        var name = (string?)element.Attribute("name") ?? string.Empty;
        var at = DateTimeOffset.TryParse((string?)element.Attribute("timestamp"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed) ? parsed : DateTimeOffset.MinValue;
        var data = new Dictionary<string, XeValue>(StringComparer.Ordinal);
        foreach (var field in element.Elements("data"))
        {
            var key = (string?)field.Attribute("name");
            if (key is null)
            {
                continue;
            }

            var value = field.Element("value");
            var xml = value?.Elements().FirstOrDefault();
            data[key] = new XeValue(xml is null ? value?.Value : null, field.Element("text")?.Value, xml);
        }

        var actions = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var action in element.Elements("action"))
        {
            var key = (string?)action.Attribute("name");
            if (key is not null && action.Element("value")?.Value is { } value)
            {
                actions[key] = value;
            }
        }

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(element.ToString(SaveOptions.DisableFormatting)));
        return new XeEvent(name, at, data, actions, Convert.ToHexStringLower(hash)[..24]);
    }

    /// <summary>
    /// Reduces a deadlock graph (<c>&lt;deadlock&gt;</c>). <paramref name="inDatabase"/> says whether a process ran in
    /// ContosoCare: the observer keeps a graph only then.
    /// </summary>
    public static DeadlockSummary ReduceDeadlock(XElement deadlock, Func<XElement, bool> inDatabase)
    {
        var processes = deadlock.Element("process-list")?.Elements("process").ToList() ?? [];
        var spids = new Dictionary<string, long?>(StringComparer.Ordinal);
        foreach (var process in processes)
        {
            spids[(string?)process.Attribute("id") ?? string.Empty] = LongAttribute(process, "spid");
        }

        var victimId = (string?)deadlock.Element("victim-list")?.Element("victimProcess")?.Attribute("id");
        long? victim = victimId is not null && spids.TryGetValue(victimId, out var victimSpid) ? victimSpid : null;
        var resources = new List<ResourceView>();
        var holds = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var resource in deadlock.Element("resource-list")?.Elements() ?? [])
        {
            var owners = resource.Element("owner-list")?.Elements("owner").ToList() ?? [];
            var waiters = resource.Element("waiter-list")?.Elements("waiter").ToList() ?? [];
            foreach (var owner in owners)
            {
                var id = (string?)owner.Attribute("id");
                if (id is not null && (string?)owner.Attribute("mode") is { } mode)
                {
                    holds.TryAdd(id, mode);
                }
            }

            var ownerId = owners.Select(o => (string?)o.Attribute("id")).FirstOrDefault(id => id is not null);
            var waiterId = waiters.Select(w => (string?)w.Attribute("id")).FirstOrDefault(id => id is not null);
            resources.Add(new ResourceView(
                ResourceType(resource.Name.LocalName),
                ObjectName((string?)resource.Attribute("objectname")),
                TextNormalizer.Name((string?)resource.Attribute("indexname")),
                (string?)resource.Attribute("mode"),
                ownerId is not null && spids.TryGetValue(ownerId, out var holder) ? holder : null,
                waiterId is not null && spids.TryGetValue(waiterId, out var waiter) ? waiter : null));
        }

        var views = new List<ProcessView>();
        var anyInDatabase = false;
        ProcessView? victimView = null;
        foreach (var process in processes)
        {
            anyInDatabase |= inDatabase(process);
            var id = (string?)process.Attribute("id") ?? string.Empty;
            var name = ApplicationNames.Reduce((string?)process.Attribute("clientapp"));
            var frame = process.Element("executionStack")?.Elements("frame").FirstOrDefault();
            var module = process.Element("executionStack")?.Elements("frame").Select(f => FrameModule((string?)f.Attribute("procname"))).FirstOrDefault(m => m is not null);
            var statement = TextNormalizer.Statement(frame?.Value is { Length: > 0 } text && !string.Equals(text.Trim(), "unknown", StringComparison.OrdinalIgnoreCase) ? text : process.Element("inputbuf")?.Value);
            var view = new ProcessView(
                spids.GetValueOrDefault(id),
                name,
                name.IsDemo ? module : null,
                name.IsDemo ? statement : null,
                holds.GetValueOrDefault(id),
                (string?)process.Attribute("lockMode"),
                TextNormalizer.Name((string?)process.Attribute("waitresource")),
                name.IsDemo ? TextNormalizer.Name((string?)process.Attribute("loginname")) : null,
                name.IsDemo ? TextNormalizer.Name((string?)process.Attribute("hostname")) : null);
            views.Add(view);
            if (victimId is not null && string.Equals(id, victimId, StringComparison.Ordinal))
            {
                victimView = view;
            }
        }

        var json = DeadlockJson(victim, views, resources);
        return new DeadlockSummary(
            anyInDatabase,
            victim,
            victimView?.Name ?? ReducedName.Other,
            victimView?.Login,
            victimView?.Host,
            victimView?.Module,
            resources.Select(r => r.Object).FirstOrDefault(o => o is not null),
            views.Count,
            resources.Count,
            json);
    }

    /// <summary>The module of an execution stack frame: <c>ContosoCare.demo.usp_x</c> becomes <c>[demo].[usp_x]</c>; ad hoc frames have none.</summary>
    internal static string? FrameModule(string? procname)
    {
        if (string.IsNullOrWhiteSpace(procname) || procname is "adhoc" or "unknown")
        {
            return null;
        }

        var parts = procname.Split('.');
        return parts.Length >= 2 ? TextNormalizer.Name($"[{parts[^2]}].[{parts[^1]}]") : TextNormalizer.Name(procname);
    }

    /// <summary>A resource's object, <c>ContosoCare.care.inventory</c>, as <c>[care].[inventory]</c>.</summary>
    internal static string? ObjectName(string? objectName)
    {
        if (string.IsNullOrWhiteSpace(objectName))
        {
            return null;
        }

        var parts = objectName.Split('.');
        return parts.Length >= 2 ? TextNormalizer.Name($"[{parts[^2].Trim('[', ']')}].[{parts[^1].Trim('[', ']')}]") : TextNormalizer.Name(objectName);
    }

    private static string ResourceType(string element) => element switch
    {
        "keylock" => "KEY",
        "pagelock" => "PAGE",
        "ridlock" => "RID",
        "objectlock" => "OBJECT",
        "hobtlock" => "HOBT",
        "xactlock" => "XACT",
        "databaselock" => "DATABASE",
        "applicationlock" => "APPLICATION",
        "metadatalock" => "METADATA",
        "allocunitlock" => "ALLOCATION_UNIT",
        "filelock" => "FILE",
        "extentlock" => "EXTENT",
        "exchangeEvent" => "EXCHANGE",
        "threadpool" => "THREADPOOL",
        "resourceWait" => "MEMORY",
        _ => element.ToUpperInvariant(),
    };

    private static long? LongAttribute(XElement element, string name) =>
        long.TryParse((string?)element.Attribute(name), NumberStyles.Integer, CultureInfo.InvariantCulture, out var value) ? value : null;

    /// <summary>The graph as compact JSON of at most 4,000 characters: statements shorten first, then later processes and resources go.</summary>
    private static string DeadlockJson(long? victim, List<ProcessView> processes, List<ResourceView> resources)
    {
        foreach (var (statementLength, keep) in new[] { (600, int.MaxValue), (200, int.MaxValue), (80, 8), (0, 6), (0, 4), (0, 2) })
        {
            var json = Write(victim, processes, resources, statementLength, keep);
            if (json.Length <= DeadlockJsonLength)
            {
                return json;
            }
        }

        return Write(victim, [], [], 0, 0);
    }

    private static string Write(long? victim, List<ProcessView> processes, List<ResourceView> resources, int statementLength, int keep)
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer, new JsonWriterOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }))
        {
            json.WriteStartObject();
            if (victim is { } v)
            {
                json.WriteNumber("victim", v);
            }
            else
            {
                json.WriteNull("victim");
            }

            json.WriteStartArray("processes");
            foreach (var process in processes.Take(keep))
            {
                json.WriteStartObject();
                WriteNumber(json, "session", process.Session);
                WriteString(json, "program", process.Name.Program);
                WriteString(json, "runToken", process.Name.RunToken);
                WriteString(json, "module", process.Module);
                if (statementLength > 0 && process.Statement is { } statement)
                {
                    json.WriteString("statement", statement.Length <= statementLength ? statement : statement[..(statementLength - 3)] + "...");
                }

                WriteString(json, "holds", process.Holds);
                WriteString(json, "wants", process.Wants);
                WriteString(json, "waitResource", process.WaitResource);
                json.WriteEndObject();
            }

            json.WriteEndArray();
            json.WriteStartArray("resources");
            foreach (var resource in resources.Take(keep))
            {
                json.WriteStartObject();
                json.WriteString("type", resource.Type);
                WriteString(json, "object", resource.Object);
                WriteString(json, "index", resource.Index);
                WriteString(json, "mode", resource.Mode);
                WriteNumber(json, "holder", resource.Holder);
                WriteNumber(json, "waiter", resource.Waiter);
                json.WriteEndObject();
            }

            json.WriteEndArray();
            json.WriteEndObject();
        }

        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    private static void WriteString(Utf8JsonWriter json, string name, string? value)
    {
        if (value is not null)
        {
            json.WriteString(name, value);
        }
    }

    private static void WriteNumber(Utf8JsonWriter json, string name, long? value)
    {
        if (value is { } number)
        {
            json.WriteNumber(name, number);
        }
    }

    private sealed record ProcessView(long? Session, ReducedName Name, string? Module, string? Statement, string? Holds, string? Wants, string? WaitResource, string? Login, string? Host);

    private sealed record ResourceView(string Type, string? Object, string? Index, string? Mode, long? Holder, long? Waiter);
}
