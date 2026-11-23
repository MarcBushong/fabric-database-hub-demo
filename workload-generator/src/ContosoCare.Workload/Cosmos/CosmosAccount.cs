using System.Globalization;
using System.Text.Json;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Sql;

namespace ContosoCare.Workload.Cosmos;

/// <summary>T5's control requests: the container's definition, warmup, setup's container check and seed, and reset.</summary>
internal static class CosmosAccount
{
    /// <summary>How long warmup keeps retrying writes that T5 throttles (for example during ru-storm) before it reports so.</summary>
    internal static readonly TimeSpan WarmupThrottleLimit = TimeSpan.FromSeconds(20);

    /// <summary>Setup writes the seed with this many requests at once.</summary>
    internal const int SeedWriters = 4;

    /// <summary>The most 429s one seed document waits out (each at most 2 seconds) before setup gives up.</summary>
    internal const int SeedThrottleRetries = 100;

    private const int TransientRetries = 3;

    /// <summary>
    /// Reads the container's definition; a 429 or a transient error is tried again a few times, and anything else throws a
    /// <see cref="CosmosException"/>: a 404 (any substatus, 1013 too while a create is still in progress) throws
    /// <see cref="CosmosFailure.NotFound"/> with <see cref="CosmosEndpoint.ContainerMissingMessage"/>, because the
    /// container exists only during a session.
    /// </summary>
    public static async Task<CosmosContainerInfo> ReadContainerAsync(CosmosRestClient client, string tag, TimeProvider time, CancellationToken cancellationToken)
    {
        var response = await ReadContainerResponseAsync(client, tag, time, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == 404)
        {
            throw new CosmosException(CosmosFailure.NotFound, CosmosEndpoint.ContainerMissingMessage, response.StatusCode, response.SubStatus, response.ActivityId);
        }

        return response.IsSuccess ? Parse(response, client) : throw response.ToException("Reading T5's container", client.Endpoint.Host);
    }

    /// <summary>
    /// warmup on T5: a Microsoft Entra token, the container's definition, then an upsert and a point read of the warmup
    /// document (<c>{ id: "warmup", patientId: "p-warmup" }</c>). Pass with the time it took and the request units it
    /// cost; a Warning when T5 kept throttling the writes for 20 seconds (access works then, but the throughput is used up).
    /// A container that doesn't exist now throws with <see cref="CosmosEndpoint.ContainerMissingMessage"/>.
    /// </summary>
    public static async Task<CheckRecord> WarmupAsync(CosmosRestClient client, TimeProvider time, CancellationToken cancellationToken)
    {
        var started = time.GetUtcNow();
        var tag = SessionNames.ForControl("warmup");
        var container = await ReadContainerAsync(client, tag, time, cancellationToken).ConfigureAwait(false);
        var document = CosmosDocuments.Warmup(time.GetUtcNow(), tag);
        var upsert = await WithRetriesAsync(t => client.UpsertAsync(tag, CosmosDocuments.WarmupPatientId, document, t), WarmupThrottleLimit, time, cancellationToken).ConfigureAwait(false);
        if (upsert.IsThrottled)
        {
            return new CheckRecord("warmup", "Warning", string.Create(CultureInfo.InvariantCulture, $"T5 answered and access works, but it throttled the warmup document's writes (HTTP 429, request rate too large) for {WarmupThrottleLimit.TotalSeconds:0} s: the container's throughput is used up, for example by ru-storm. Try again after the storm."));
        }

        if (!upsert.IsSuccess)
        {
            throw upsert.ToException("Writing the warmup document", client.Endpoint.Host);
        }

        var read = await WithRetriesAsync(t => client.ReadAsync(tag, CosmosDocuments.WarmupPatientId, CosmosDocuments.WarmupId, t), WarmupThrottleLimit, time, cancellationToken).ConfigureAwait(false);
        if (!read.IsSuccess && !read.IsThrottled)
        {
            throw read.ToException("Reading the warmup document", client.Endpoint.Host);
        }

        var elapsed = time.GetUtcNow() - started;
        return new CheckRecord("warmup", "Pass", string.Create(
            CultureInfo.InvariantCulture,
            $"T5 answered in {elapsed.TotalSeconds:0.0} s: a Microsoft Entra token, the container's definition (partition key {container.DescribePartitionKey()}), and an upsert and a point read of the warmup document ({upsert.RequestCharge + read.RequestCharge:0.##} RU)."));
    }

    /// <summary>
    /// setup's check of the container: it exists, partitioned on <c>/patientId</c>. The runner never creates or changes it:
    /// it exists only during a session, and start-demo.ps1 (or deploy.ps1) creates it through Azure Resource Manager.
    /// </summary>
    public static async Task<(CheckRecord Check, CosmosContainerInfo? Container)> VerifyContainerAsync(CosmosRestClient client, string tag, TimeProvider time, CancellationToken cancellationToken)
    {
        var response = await ReadContainerResponseAsync(client, tag, time, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == 404)
        {
            return (new CheckRecord("container", "Fail", $"T5 ({client.Endpoint.Host}) has no container {CosmosEndpoint.DatabaseName}/{CosmosEndpoint.ContainerName} now (HTTP 404): it exists only during a session, so ./scripts/start-demo.ps1 (or deploy.ps1) creates it, through Azure Resource Manager. The runner never does."), null);
        }

        if (!response.IsSuccess)
        {
            throw response.ToException("Reading T5's container", client.Endpoint.Host);
        }

        var container = Parse(response, client);
        return container.HasExpectedPartitionKey
            ? (new CheckRecord("container", "Pass", $"{CosmosEndpoint.DatabaseName}/{CosmosEndpoint.ContainerName} exists, partitioned on {container.DescribePartitionKey()}."), container)
            : (new CheckRecord("container", "Fail", $"{CosmosEndpoint.DatabaseName}/{CosmosEndpoint.ContainerName} is partitioned on {container.DescribePartitionKey()}, not {CosmosEndpoint.PartitionKeyPath}, so the demo's documents can't be written. A partition key can't change: delete the container and run deploy.ps1, whose template creates it."), container);
    }

    /// <summary>
    /// setup --seed-scale on T5: upserts scale x 100 patient profile documents (<c>id: "patient"</c>, <c>p-0001</c> and
    /// on), four at a time, waiting out 429s. Upserts make it idempotent: running it again rewrites the same documents.
    /// </summary>
    public static async Task<CheckRecord> SeedAsync(CosmosRestClient client, int scale, TimeProvider time, CancellationToken cancellationToken)
    {
        var tag = SessionNames.ForControl("setup");
        var count = scale * 100;
        var next = 0;
        var meter = new CosmosRunMeter();
        using var failed = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);

        async Task WriteAsync()
        {
            while (true)
            {
                var number = Interlocked.Increment(ref next);
                if (number > count)
                {
                    return;
                }

                var patientId = HealthyBaselineMix.PatientId(number);
                var document = CosmosDocuments.Patient(patientId, number, time.GetUtcNow(), tag, HealthyBaselineMix.ProfilePayloadLength);
                for (var attempt = 1; ; attempt++)
                {
                    var response = await client.UpsertAsync(tag, patientId, document, failed.Token).ConfigureAwait(false);
                    meter.Record(response);
                    if (response.IsSuccess)
                    {
                        break;
                    }

                    if ((response.IsThrottled && attempt <= SeedThrottleRetries) || (response.IsTransient && attempt <= TransientRetries))
                    {
                        await Task.Delay(response.IsThrottled ? RuStorm.RetryWait(response.RetryAfter) : TimeSpan.FromSeconds(attempt), time, failed.Token).ConfigureAwait(false);
                        continue;
                    }

                    throw response.ToException("Seeding " + patientId, client.Endpoint.Host);
                }
            }
        }

        var writers = Enumerable.Range(0, SeedWriters).Select(_ => Task.Run(
            async () =>
            {
                try
                {
                    await WriteAsync().ConfigureAwait(false);
                }
                catch (CosmosException)
                {
                    // The first failure ends the other writers too.
                    await failed.CancelAsync().ConfigureAwait(false);
                    throw;
                }
            },
            CancellationToken.None)).ToList();
        try
        {
            await Task.WhenAll(writers).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // Another writer failed; its CosmosException is the one to report.
        }

        if (writers.Select(w => w.Exception?.GetBaseException()).OfType<CosmosException>().FirstOrDefault() is { } failure)
        {
            throw failure;
        }

        cancellationToken.ThrowIfCancellationRequested();
        var totals = meter.Sample(time.GetUtcNow());
        return new CheckRecord("seed", "Pass", string.Create(
            CultureInfo.InvariantCulture,
            $"T5 has {count} patient profile documents ({HealthyBaselineMix.PatientId(1)} to {HealthyBaselineMix.PatientId(count)}, id 'patient') at scale {scale}: {totals.RequestCharge:0.#} RU{(totals.Throttled > 0 ? string.Create(CultureInfo.InvariantCulture, $", {totals.Throttled} throttled write(s) waited out") : string.Empty)}."));
    }

    /// <summary>Sends a request again after a 429 (for up to <paramref name="throttleLimit"/>) or a transient error (three times); returns the last answer.</summary>
    internal static async Task<CosmosResponse> WithRetriesAsync(Func<CancellationToken, Task<CosmosResponse>> send, TimeSpan throttleLimit, TimeProvider time, CancellationToken cancellationToken)
    {
        var started = time.GetUtcNow();
        for (var attempt = 1; ; attempt++)
        {
            var response = await send(cancellationToken).ConfigureAwait(false);
            if (response.IsThrottled && time.GetUtcNow() - started < throttleLimit)
            {
                await Task.Delay(RuStorm.RetryWait(response.RetryAfter), time, cancellationToken).ConfigureAwait(false);
                continue;
            }

            if (response.IsTransient && attempt <= TransientRetries)
            {
                await Task.Delay(TimeSpan.FromSeconds(attempt), time, cancellationToken).ConfigureAwait(false);
                continue;
            }

            return response;
        }
    }

    private static Task<CosmosResponse> ReadContainerResponseAsync(CosmosRestClient client, string tag, TimeProvider time, CancellationToken cancellationToken) =>
        WithRetriesAsync(t => client.ReadContainerAsync(tag, t), TimeSpan.FromSeconds(10), time, cancellationToken);

    private static CosmosContainerInfo Parse(CosmosResponse response, CosmosRestClient client)
    {
        try
        {
            return CosmosContainerInfo.Parse(response.Body);
        }
        catch (JsonException ex)
        {
            throw new CosmosException(CosmosFailure.Request, $"T5 ({client.Endpoint.Host}) answered the container read with a body that isn't a container definition: {ex.Message}", response.StatusCode, response.SubStatus, response.ActivityId, ex);
        }
    }
}

/// <summary>
/// reset on T5 (no sessions to kill): every Running run is marked Cancelled, reset waits for their runners to record their
/// end (each ru-storm run deletes its storm documents first), closes the records of runners whose process is gone,
/// checks that no run is left Running, and deletes any ru-storm document left over, for example after T1 was deallocated
/// mid-storm (<see cref="StormCleanup"/>); when T5's container doesn't exist now (it exists only during a session), no
/// storm document is left, which is a Pass. The rest of the data stays: healthy-baseline and setup only overwrite bounded
/// sets of documents (database/cosmosdb/README.md). Idempotent.
/// </summary>
internal static class CosmosReset
{
    /// <summary>How long reset's own storm cleanup may take.</summary>
    internal static readonly TimeSpan StormCleanupLimit = TimeSpan.FromMinutes(3);

    public static async Task<IReadOnlyList<CheckRecord>> RunAsync(CosmosRunStore store, CosmosRestClient client, ResetOptions options, TimeProvider time, CancellationToken cancellationToken)
    {
        var checks = new List<CheckRecord>();
        var wait = TimeSpan.FromSeconds(Math.Clamp(options.WaitSeconds, 0, 300));
        var owner = CosmosRunOwner.Current;

        // 1. Stop.
        var cancelled = await store.StopAsync("all", null, null, options.RequestedBy, cancellationToken).ConfigureAwait(false);
        checks.Add(new CheckRecord("runs-stopped", "Pass", string.Create(CultureInfo.InvariantCulture, $"Stop requested for every T5 run; {cancelled} Running run(s) marked Cancelled. Their writers stop within a few seconds.")));

        // 2. Wait for their runners to record the end; a runner whose process is gone never will, so its record is closed.
        var closed = (await store.CloseAbandonedRunsAsync(owner.Machine, HostLaneStatus.IsProcessAlive, cancellationToken).ConfigureAwait(false)).Count;
        var until = time.GetUtcNow() + wait;
        var open = Open(await store.ReadAsync(cancellationToken).ConfigureAwait(false));
        while (open.Count > 0 && time.GetUtcNow() < until)
        {
            if (!options.KeepProfile && open.Any(r => r.Status == CosmosRunStatus.Running))
            {
                // A profile host that read the profile just before it was set off started this run after the stop.
                await store.StopAsync("all", null, null, options.RequestedBy, cancellationToken).ConfigureAwait(false);
            }

            await Task.Delay(TimeSpan.FromSeconds(1), time, cancellationToken).ConfigureAwait(false);
            open = Open(await store.ReadAsync(cancellationToken).ConfigureAwait(false));
        }

        closed += (await store.CloseAbandonedRunsAsync(owner.Machine, HostLaneStatus.IsProcessAlive, cancellationToken).ConfigureAwait(false)).Count;
        open = Open(await store.ReadAsync(cancellationToken).ConfigureAwait(false));

        // 3. Verify.
        var running = open.Count(r => r.Status == CosmosRunStatus.Running);
        var ending = open.Count - running;
        var closedNote = closed > 0 ? string.Create(CultureInfo.InvariantCulture, $" Reset closed {closed} run record(s) whose runner's process was gone.") : string.Empty;
        checks.Add(running > 0
            ? new CheckRecord("no-running-runs", options.KeepProfile ? "Warning" : "Fail", string.Create(CultureInfo.InvariantCulture, $"{running} T5 run(s) are Running again: a profile host started them after the stop.{(options.KeepProfile ? " --keep-profile kept T5's profile, so its host goes on starting runs." : " Run reset again.")}{closedNote}"))
            : ending > 0
                ? new CheckRecord("no-running-runs", "Warning", string.Create(CultureInfo.InvariantCulture, $"No T5 run is Running, but {ending} stopped run(s) hadn't recorded their end after {wait.TotalSeconds:0} s: their writers stop at their next request, and a record left open is closed after its deadline.{closedNote}"))
                : new CheckRecord("no-running-runs", "Pass", "No T5 run is Running, and every run's writers have stopped." + closedNote));

        // 4. Storm documents a run left behind (its process ended mid-storm, or its cleanup ran out of time).
        var cleanup = await StormCleanup.RunAsync(client, SessionNames.ForControl("reset"), time, StormCleanupLimit, cancellationToken).ConfigureAwait(false);
        checks.Add(cleanup.ToCheck("storm-documents-removed"));

        // 5. Optional steps: T5 has no remediation and no seed state.
        checks.Add(options.UndoRemediation
            ? new CheckRecord("remediation-undone", "Not supported", "T5 has no remediation to undo: its scenarios only write bounded sets of documents.")
            : new CheckRecord("remediation-undone", "Not selected", "The missing-index remediation script applies to T1 to T3 only."));
        checks.Add(options.Reseed
            ? new CheckRecord("reseeded", "Not supported", "T5 keeps no seed state to repeat: run 'setup --target T5 --seed-scale <n>' again, which rewrites the same patient documents.")
            : new CheckRecord("reseeded", "Not selected", "Patient documents kept; healthy-baseline overwrites a bounded set of them."));
        return checks;
    }

    private static List<CosmosRunEntry> Open(CosmosRunStoreDocument document) => [.. document.Runs!.Where(r => r.EndedAt is null)];
}

/// <summary>What deleting ru-storm's documents did. <paramref name="ContainerMissing"/>: T5's container doesn't exist now (it exists only during a session), so there was nothing to delete.</summary>
internal sealed record StormCleanupResult(int Deleted, bool Complete, double RequestCharge, TimeSpan Elapsed, string? Error, bool ContainerMissing = false)
{
    /// <summary>The check's message when the container doesn't exist now.</summary>
    public const string ContainerMissingMessage = "T5's container doesn't exist now (it exists only during a session), so no storm document is left.";

    public CheckRecord ToCheck(string checkId)
    {
        var partitions = RuStorm.PartitionName(1) + " to " + RuStorm.PartitionName(RuStorm.MaximumHotPartitions);
        if (ContainerMissing)
        {
            return new CheckRecord(checkId, "Pass", Deleted == 0
                ? ContainerMissingMessage
                : string.Create(CultureInfo.InvariantCulture, $"Deleted {Deleted} ru-storm document(s) from {partitions}; then {ContainerMissingMessage}"));
        }

        if (Complete)
        {
            return new CheckRecord(checkId, "Pass", Deleted == 0
                ? $"No ru-storm document is left in {partitions}."
                : string.Create(CultureInfo.InvariantCulture, $"Deleted {Deleted} ru-storm document(s) from {partitions} in {Elapsed.TotalSeconds:0.0} s ({RequestCharge:0.#} RU, paced to {StormCleanup.RequestUnitsPerSecond:0} RU/s): no storm document is left."));
        }

        return new CheckRecord(checkId, "Warning", string.Create(
            CultureInfo.InvariantCulture,
            $"Deleted {Deleted} ru-storm document(s) in {Elapsed.TotalSeconds:0.0} s, then stopped: {Error ?? "its time limit ran out"}. Some may be left in {partitions} (400 at most); 'reset --target T5' deletes them, and so does the next ru-storm run."));
    }
}

/// <summary>
/// Deletes ru-storm's documents. In each of its hot partitions, p-storm-01 to p-storm-04, a single-partition query finds the
/// documents tagged <c>kind: "ru-storm"</c> (100 at most per partition, 400 in all), and each is deleted (Delete Document).
/// The deletes are paced by their own request charge to 200 RU/s, half the container's 400, so neither the cleanup nor the
/// baseline beside it is throttled; a 429 waits the server's retry-after. With nothing left it costs four small queries,
/// so it's idempotent and cheap to repeat. It stops at its time limit and reports what may be left. A container that
/// doesn't exist now (404 with substatus 1003: it exists only during a session) holds no storm document, so the cleanup
/// is complete.
/// </summary>
internal static class StormCleanup
{
    /// <summary>The cleanup's pace.</summary>
    public const double RequestUnitsPerSecond = 200;

    /// <summary>Finds a page of storm documents in one partition.</summary>
    internal const string Query = "SELECT TOP 100 c.id FROM c WHERE c.kind = @kind";

    /// <summary>Pages per partition at most: far more than the 100 documents the storm writes there.</summary>
    private const int MaximumPages = 20;

    private const int TransientRetries = 3;

    public static async Task<StormCleanupResult> RunAsync(CosmosRestClient client, string tag, TimeProvider time, TimeSpan limit, CancellationToken cancellationToken)
    {
        var started = time.GetUtcNow();
        var until = started + limit;
        var deleted = 0;
        double charge = 0;

        // A request is never started past the limit, and a request in flight at the limit is cancelled soon after.
        using var hardStop = new CancellationTokenSource(limit + TimeSpan.FromSeconds(5), time);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, hardStop.Token);

        // Sends one request: a 429 waits the server's retry-after, a transient error is tried again, and each answer's
        // request units pace the next request. Null once the limit has passed.
        async Task<CosmosResponse?> SendAsync(Func<CancellationToken, Task<CosmosResponse>> send)
        {
            for (var attempt = 1; ; attempt++)
            {
                if (time.GetUtcNow() >= until)
                {
                    return null;
                }

                var response = await send(linked.Token).ConfigureAwait(false);
                charge += response.RequestCharge;
                if (response.IsThrottled)
                {
                    await Task.Delay(RuStorm.RetryWait(response.RetryAfter), time, linked.Token).ConfigureAwait(false);
                    continue;
                }

                if (response.IsTransient && attempt <= TransientRetries)
                {
                    await Task.Delay(TimeSpan.FromSeconds(attempt), time, linked.Token).ConfigureAwait(false);
                    continue;
                }

                if (response.RequestCharge > 0)
                {
                    await Task.Delay(TimeSpan.FromSeconds(response.RequestCharge / RequestUnitsPerSecond), time, linked.Token).ConfigureAwait(false);
                }

                return response;
            }
        }

        StormCleanupResult Result(bool complete, string? error) => new(deleted, complete, Math.Round(charge, 2), time.GetUtcNow() - started, error);

        StormCleanupResult NoContainer() => Result(true, null) with { ContainerMissing = true };

        try
        {
            for (var number = 1; number <= RuStorm.MaximumHotPartitions; number++)
            {
                var partition = RuStorm.PartitionName(number);
                var emptied = false;
                for (var page = 0; page < MaximumPages && !emptied; page++)
                {
                    var query = await SendAsync(t => client.QueryAsync(tag, partition, Query, [new KeyValuePair<string, string>("@kind", RuStorm.Kind)], RuStorm.DocumentsPerPartition, t)).ConfigureAwait(false);
                    if (query is null)
                    {
                        return Result(false, null);
                    }

                    if (query.IsContainerMissing)
                    {
                        return NoContainer();
                    }

                    if (!query.IsSuccess)
                    {
                        throw query.ToException("Finding ru-storm's documents in " + partition, client.Endpoint.Host);
                    }

                    var ids = DocumentIds(query.Body);
                    emptied = ids.Count == 0;
                    foreach (var id in ids)
                    {
                        var response = await SendAsync(t => client.DeleteAsync(tag, partition, id, t)).ConfigureAwait(false);
                        if (response is null)
                        {
                            return Result(false, null);
                        }

                        if (response.IsSuccess)
                        {
                            deleted++;
                        }
                        else if (response.IsContainerMissing)
                        {
                            return NoContainer();
                        }
                        else if (response.StatusCode != 404)
                        {
                            throw response.ToException($"Deleting {id} in {partition}", client.Endpoint.Host);
                        }
                    }
                }

                if (!emptied)
                {
                    return Result(false, string.Create(CultureInfo.InvariantCulture, $"{partition} still had storm documents after {MaximumPages} pages"));
                }
            }

            return Result(true, null);
        }
        catch (CosmosException ex)
        {
            return Result(false, ex.Message);
        }
        catch (JsonException ex)
        {
            return Result(false, "a query's answer couldn't be read: " + ex.Message);
        }
        catch (OperationCanceledException) when (hardStop.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
        {
            return Result(false, null);
        }
    }

    /// <summary>The IDs in a query's page: <c>{ "Documents": [ { "id": ... } ] }</c>.</summary>
    internal static IReadOnlyList<string> DocumentIds(string body)
    {
        using var document = JsonDocument.Parse(body);
        if (!document.RootElement.TryGetProperty("Documents", out var documents) || documents.ValueKind != JsonValueKind.Array)
        {
            return [];
        }

        return [.. documents.EnumerateArray()
            .Where(d => d.ValueKind == JsonValueKind.Object && d.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String)
            .Select(d => d.GetProperty("id").GetString()!)];
    }
}

/// <summary>The sum of the Running runs' recent rates, for <c>status</c>.</summary>
internal sealed record CosmosLiveTotals(double RequestsPerSecond, double RuPerSecond, double ThrottledPerSecond, long ThrottledLastMinute, DateTimeOffset? UpdatedAt)
{
    /// <summary>A run's rates count while it's Running and its runner updated them within this long.</summary>
    public static readonly TimeSpan Freshness = TimeSpan.FromSeconds(30);

    public static CosmosLiveTotals Sum(IEnumerable<CosmosRunEntry> runs, DateTimeOffset now)
    {
        var live = runs
            .Where(r => r.Status == CosmosRunStatus.Running && r.EndedAt is null && r.Live is { } rates && now - rates.UpdatedAt <= Freshness)
            .Select(r => r.Live!)
            .ToList();
        return new CosmosLiveTotals(
            Math.Round(live.Sum(l => l.RequestsPerSecond), 2),
            Math.Round(live.Sum(l => l.RuPerSecond), 2),
            Math.Round(live.Sum(l => l.ThrottledPerSecond), 2),
            live.Sum(l => l.ThrottledLastMinute),
            live.Count == 0 ? null : live.Max(l => l.UpdatedAt));
    }
}

/// <summary>
/// What <c>status --target T5</c> shows of the account: whether its container answers, its partition key, and the live
/// rates; or, when the account answers that the container doesn't exist now (<see cref="ContainerMissing"/>), that it
/// exists only during a session, which isn't an error.
/// </summary>
internal sealed record CosmosAccountStatus(string Endpoint, bool Reachable, CosmosContainerInfo? Container, string? Error, CosmosLiveTotals Live)
{
    /// <summary>What status says when T5's container doesn't exist now.</summary>
    public const string ContainerMissingNote = "T5's container doesn't exist now: it exists only during a session (./scripts/start-demo.ps1 or the control notebook's Run all creates it).";

    /// <summary>True when the account answered that T5's container doesn't exist now: it exists only during a session.</summary>
    public bool ContainerMissing { get; init; }

    public static async Task<CosmosAccountStatus> ReadAsync(CosmosRestClient client, IEnumerable<CosmosRunEntry> runs, TimeProvider time, CancellationToken cancellationToken)
    {
        CosmosContainerInfo? container = null;
        string? error = null;
        var missing = false;
        try
        {
            container = await CosmosAccount.ReadContainerAsync(client, SessionNames.ForControl("status"), time, cancellationToken).ConfigureAwait(false);
        }
        catch (CosmosException ex) when (ex.Failure == CosmosFailure.NotFound)
        {
            missing = true;
        }
        catch (CosmosException ex)
        {
            error = Redactor.Redact(ex.Message);
        }

        return new CosmosAccountStatus(client.Endpoint.Host, container is not null || missing, container, error, CosmosLiveTotals.Sum(runs, time.GetUtcNow())) { ContainerMissing = missing };
    }
}
