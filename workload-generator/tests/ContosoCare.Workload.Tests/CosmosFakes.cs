using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Azure.Core;
using ContosoCare.Workload.Cosmos;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// A clock that runs <paramref name="factor"/> times faster than real time, timers included, so a 30-second run takes a
/// second or two. Assertions on it allow for the real timer resolution (about 16 ms on Windows) scaled by the factor.
/// </summary>
internal sealed class AcceleratedTime(double factor) : TimeProvider
{
    private readonly DateTimeOffset start = new(2026, 11, 18, 16, 0, 0, TimeSpan.Zero);
    private readonly long origin = Stopwatch.GetTimestamp();

    public double Factor => factor;

    public override long TimestampFrequency => Stopwatch.Frequency;

    public override DateTimeOffset GetUtcNow() => start + TimeSpan.FromTicks((long)(Stopwatch.GetElapsedTime(origin).Ticks * factor));

    public override long GetTimestamp() => origin + (long)((Stopwatch.GetTimestamp() - origin) * factor);

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) =>
        new ScaledTimer(new Timer(callback, state, Shrink(dueTime), Shrink(period)), this);

    /// <summary>The real time a fake span takes.</summary>
    public TimeSpan Shrink(TimeSpan fake) => fake == Timeout.InfiniteTimeSpan || fake <= TimeSpan.Zero ? fake : TimeSpan.FromTicks(Math.Max(1, (long)(fake.Ticks / factor)));

    private sealed class ScaledTimer(Timer timer, AcceleratedTime time) : ITimer
    {
        public bool Change(TimeSpan dueTime, TimeSpan period) => timer.Change(time.Shrink(dueTime), time.Shrink(period));

        public void Dispose() => timer.Dispose();

        public ValueTask DisposeAsync() => timer.DisposeAsync();
    }
}

/// <summary>A token built at run time, never a literal: it doesn't look like a JWT, so the redactor wouldn't hide a leak of it.</summary>
internal sealed class FakeTokens : ICosmosTokenSource
{
    private int calls;

    public string Token { get; } = "test-token-" + Guid.NewGuid().ToString("N");

    public int Calls => Volatile.Read(ref calls);

    public ValueTask<string> GetTokenAsync(CancellationToken cancellationToken)
    {
        Interlocked.Increment(ref calls);
        return ValueTask.FromResult(Token);
    }
}

/// <summary>A Microsoft Entra credential that answers each scope with <paramref name="respond"/> and records the scopes asked for.</summary>
internal sealed class FakeCredential(Func<string, AccessToken> respond) : TokenCredential
{
    public ConcurrentQueue<string> Scopes { get; } = new();

    public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) => Respond(requestContext);

    public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) => ValueTask.FromResult(Respond(requestContext));

    private AccessToken Respond(TokenRequestContext context)
    {
        var scope = context.Scopes.Single();
        Scopes.Enqueue(scope);
        return respond(scope);
    }
}

/// <summary>One request the fake account received, with the fake time it arrived.</summary>
internal sealed record RecordedRequest(DateTimeOffset At, string Method, string Path, IReadOnlyDictionary<string, string> Headers, string? Body)
{
    public string? Header(string name) => Headers.TryGetValue(name, out var value) ? value : null;

    /// <summary>The partition key header's value: <c>["p-0001"]</c> gives p-0001.</summary>
    public string? PartitionKey => Header("x-ms-documentdb-partitionkey") is { } header ? JsonNode.Parse(header)!.AsArray().Single()!.GetValue<string>() : null;

    public bool IsUpsert => Method == "POST" && Header("x-ms-documentdb-is-upsert") == "True";

    public bool IsQuery => Method == "POST" && Header("x-ms-documentdb-isquery") == "True";

    public string? DocumentId => Path.StartsWith(FakeCosmosAccount.DocumentsPath + "/", StringComparison.Ordinal) ? Path[(FakeCosmosAccount.DocumentsPath.Length + 1)..] : null;
}

/// <summary>
/// A Cosmos DB account behind an HttpMessageHandler: the container's definition, and upserts, point reads, queries, and
/// deletes on documents kept in memory, with the documented status codes and headers. Every Nth upsert to a storm
/// partition can answer 429, and every request can fail with a status or an exception.
/// </summary>
internal sealed class FakeCosmosAccount(TimeProvider? time = null) : HttpMessageHandler
{
    public const string ContainerPath = "/dbs/contosocare/colls/patient-events";
    public const string DocumentsPath = ContainerPath + "/docs";

    private readonly TimeProvider clock = time ?? TimeProvider.System;
    private readonly ConcurrentDictionary<(string Partition, string Id), JsonObject> documents = new();
    private int stormWrites;
    private int throttled;
    private bool containerMissing;

    public ConcurrentQueue<RecordedRequest> Requests { get; } = new();

    /// <summary>Every Nth upsert to a p-storm partition answers 429; 0 never does.</summary>
    public int ThrottleEvery { get; init; }

    public int RetryAfterMs { get; init; } = 100;

    public string PartitionKeyPath { get; init; } = "/patientId";

    /// <summary>
    /// When true, the container doesn't exist (it exists only during a session): its read answers 404, and every document
    /// request 404 with substatus 1003 (the owner resource doesn't exist). A test can create or delete it mid-run.
    /// </summary>
    public bool ContainerMissing
    {
        get => Volatile.Read(ref containerMissing);
        set => Volatile.Write(ref containerMissing, value);
    }

    /// <summary>When set, every request answers this status (403 for a data-plane role that isn't effective yet).</summary>
    public HttpStatusCode? FailWith { get; set; }

    /// <summary>When set, every request throws it (a name that doesn't resolve).</summary>
    public Exception? ThrowWith { get; set; }

    public int Throttled => Volatile.Read(ref throttled);

    public IReadOnlyList<(string Partition, string Id)> Keys => [.. documents.Keys];



    public void Put(string partition, string id, string? kind = null) =>
        documents[(partition, id)] = new JsonObject { ["id"] = id, ["patientId"] = partition, ["type"] = "test", ["kind"] = kind };

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
        var recorded = new RecordedRequest(clock.GetUtcNow(), request.Method.Method, Uri.UnescapeDataString(request.RequestUri!.AbsolutePath), Headers(request), body);
        Requests.Enqueue(recorded);
        if (ThrowWith is { } exception)
        {
            throw exception;
        }

        if (FailWith is { } status)
        {
            return Respond(status, """{"code":"Forbidden","message":"Request blocked by Auth: the principal doesn't have the required RBAC permissions.\r\nActivityId: 00000000-0000-0000-0000-000000000000"}""", 0, subStatus: 5301);
        }

        if (recorded.Method == "GET" && recorded.Path == ContainerPath)
        {
            return ContainerMissing
                ? Respond(HttpStatusCode.NotFound, """{"code":"NotFound","message":"Resource Not Found."}""", 1, subStatus: 1003)
                : Respond(HttpStatusCode.OK, $$$"""{"id":"patient-events","partitionKey":{"paths":["{{{PartitionKeyPath}}}"],"kind":"Hash","version":2},"indexingPolicy":{"excludedPaths":[{"path":"/payload/*"}]}}""", 1);
        }

        if (ContainerMissing && recorded.Path.StartsWith(DocumentsPath, StringComparison.Ordinal))
        {
            return Respond(HttpStatusCode.NotFound, """{"code":"NotFound","message":"Message: {\"Errors\":[\"Owner resource does not exist\"]}"}""", 1, subStatus: 1003);
        }

        var partition = recorded.PartitionKey;
        if (recorded.IsQuery && recorded.Path == DocumentsPath)
        {
            return Query(partition!, JsonNode.Parse(body!)!.AsObject());
        }

        if (recorded.IsUpsert && recorded.Path == DocumentsPath)
        {
            return Upsert(partition!, JsonNode.Parse(body!)!.AsObject());
        }

        if (recorded.DocumentId is { } id && partition is not null)
        {
            switch (recorded.Method)
            {
                case "GET":
                    return documents.TryGetValue((partition, id), out var found)
                        ? Respond(HttpStatusCode.OK, found.ToJsonString(), 1)
                        : Respond(HttpStatusCode.NotFound, """{"code":"NotFound","message":"Entity with the specified id does not exist in the system."}""", 1);
                case "DELETE":
                    return documents.TryRemove((partition, id), out _)
                        ? Respond(HttpStatusCode.NoContent, null, 6.1)
                        : Respond(HttpStatusCode.NotFound, """{"code":"NotFound","message":"Entity with the specified id does not exist in the system."}""", 1);
            }
        }

        return Respond(HttpStatusCode.BadRequest, """{"code":"BadRequest","message":"The fake account doesn't know this request."}""", 0);
    }

    private HttpResponseMessage Upsert(string partition, JsonObject document)
    {
        var id = document["id"]!.GetValue<string>();
        if (document["patientId"]?.GetValue<string>() != partition)
        {
            return Respond(HttpStatusCode.BadRequest, """{"code":"BadRequest","message":"PartitionKey extracted from document doesn't match the one specified in the header."}""", 0);
        }

        if (partition.StartsWith("p-storm-", StringComparison.Ordinal) && ThrottleEvery > 0 && Interlocked.Increment(ref stormWrites) % ThrottleEvery == 0)
        {
            Interlocked.Increment(ref throttled);
            return Respond((HttpStatusCode)429, """{"code":"429","message":"Message: {\"Errors\":[\"Request rate is large.\"]}"}""", 0, RetryAfterMs, 3200);
        }

        documents[(partition, id)] = document;
        return Respond(HttpStatusCode.OK, document.ToJsonString(), 8.38);
    }

    private HttpResponseMessage Query(string partition, JsonObject body)
    {
        var text = body["query"]!.GetValue<string>();
        var parameters = body["parameters"]!.AsArray().ToDictionary(p => p!["name"]!.GetValue<string>(), p => p!["value"]!.GetValue<string>());
        IEnumerable<JsonObject> rows = documents.Where(d => d.Key.Partition == partition).Select(d => d.Value);
        if (text.Contains("c.kind = @kind", StringComparison.Ordinal))
        {
            rows = rows.Where(d => d["kind"]?.GetValue<string>() == parameters["@kind"]).Take(100);
        }
        else
        {
            rows = rows.Take(5);
        }

        var page = new JsonArray([.. rows.Select(d => (JsonNode)new JsonObject { ["id"] = d["id"]!.GetValue<string>() })]);
        return Respond(HttpStatusCode.OK, new JsonObject { ["_rid"] = "fake", ["Documents"] = page, ["_count"] = page.Count }.ToJsonString(), 2.79);
    }

    private static Dictionary<string, string> Headers(HttpRequestMessage request)
    {
        // The raw values, as the runner added them and as they go on the wire.
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (name, values) in request.Headers.NonValidated)
        {
            headers[name] = values.ToString();
        }

        if (request.Content is not null)
        {
            foreach (var (name, values) in request.Content.Headers.NonValidated)
            {
                headers[name] = values.ToString();
            }
        }

        return headers;
    }

    private static HttpResponseMessage Respond(HttpStatusCode status, string? body, double charge, int? retryAfterMs = null, int? subStatus = null)
    {
        var response = new HttpResponseMessage(status) { Content = body is null ? new ByteArrayContent([]) : new StringContent(body, Encoding.UTF8, "application/json") };
        response.Headers.TryAddWithoutValidation("x-ms-request-charge", charge.ToString(CultureInfo.InvariantCulture));
        response.Headers.TryAddWithoutValidation("x-ms-activity-id", Guid.NewGuid().ToString());
        if (retryAfterMs is { } milliseconds)
        {
            response.Headers.TryAddWithoutValidation("x-ms-retry-after-ms", milliseconds.ToString(CultureInfo.InvariantCulture));
        }

        if (subStatus is { } sub)
        {
            response.Headers.TryAddWithoutValidation("x-ms-substatus", sub.ToString(CultureInfo.InvariantCulture));
        }

        return response;
    }


    /// <summary>The document a request's body carried.</summary>
    public static JsonObject Body(RecordedRequest request) => JsonNode.Parse(request.Body!)!.AsObject();

}
