using System.CommandLine;
using System.Globalization;
using System.Text.Json.Nodes;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Cosmos;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Sql;

namespace ContosoCare.Workload.Cli;

/// <summary>T5's status, warmup, and setup: the same commands and output shapes as the other targets, on Azure Cosmos DB for NoSQL through the runner's REST client.</summary>
internal static partial class CommandLine
{
    /// <summary>
    /// T5's live view: the activity profile, recent runs and stop requests from T1's run store, the account (whether its
    /// container answers, and its partition key, or that the container doesn't exist now: it exists only during a session),
    /// the live requests, request units, and 429s per second that its Running runs report, and the profile host's lane
    /// last. The run store is local, so this works while the account doesn't answer.
    /// </summary>
    private static async Task<int> StatusT5Async(ParseResult parseResult, CosmosEndpoint endpoint, CosmosRunStore store, int runCount, string? profileFile, string? hostStateFile, bool json, CancellationToken cancellationToken)
    {
        using var client = CosmosClient(endpoint);
        var status = await ReadStatusT5Async(client, store, new FileProfileStore(profileFile ?? FileProfileStore.DefaultPathFor(DemoTarget.T5)), runCount, hostStateFile ?? HostLanesFile.DefaultPath, cancellationToken).ConfigureAwait(false);
        var output = parseResult.InvocationConfiguration.Output;
        if (json)
        {
            output.WriteLine(StatusT5Node(status).ToJsonString(OutputOptions));
            return ExitCodes.Success;
        }

        WriteStatusT5Text(output, status);
        return ExitCodes.Success;
    }

    /// <summary>What <c>status --target T5</c> shows, read once for the JSON and the text.</summary>
    internal static async Task<T5Status> ReadStatusT5Async(CosmosRestClient client, CosmosRunStore store, IProfileStore profiles, int runCount, string hostStateFile, CancellationToken cancellationToken)
    {
        var profile = await profiles.GetAsync(cancellationToken).ConfigureAwait(false);
        var document = await store.ReadAsync(cancellationToken).ConfigureAwait(false);
        var account = await CosmosAccountStatus.ReadAsync(client, document.Runs!, TimeProvider.System, cancellationToken).ConfigureAwait(false);
        var now = DateTimeOffset.UtcNow;
        var description = ProfileHost.Describe(profile, now, ActivityProfilesDefinition.Default, ScenarioCatalog.Default);
        var host = HostLaneStatus.ForThisMachine(hostStateFile, DemoTarget.T5, ProfileHost.IsActive(profile, now, ActivityProfilesDefinition.Default, ScenarioCatalog.Default));
        return new T5Status(client.Endpoint, profile, description, [.. document.Runs!.Take(runCount)], document.StopRequests!, account, host);
    }

    /// <summary>
    /// <c>status --target T5 --json</c>: target, profile, runs, stopRequests, account, and host, in that order. The host
    /// block is last, as on T1 to T4, so the tail of the output that a Run Command keeps still holds it (validation's
    /// WORKLOAD.T5.HOST), with the account's live rates just before it.
    /// </summary>
    internal static JsonObject StatusT5Node(T5Status status) => new()
    {
        ["target"] = nameof(DemoTarget.T5),
        ["profile"] = new JsonObject
        {
            ["name"] = status.Profile.Name,
            ["setAt"] = DemoDatabase.Format(status.Profile.SetAt),
            ["setBy"] = status.Profile.SetBy,
            ["expiresAt"] = status.Profile.ExpiresAt is { } expires ? DemoDatabase.Format(expires) : null,
            ["description"] = status.ProfileDescription,
        },
        ["runs"] = new JsonArray([.. status.Runs.Select(r => RunNode(r.ToRunRecord()))]),
        ["stopRequests"] = new JsonArray([.. status.StopRequests.Select(s => (JsonNode)new JsonObject
        {
            ["scenario"] = s.Scenario,
            ["requestedAt"] = DemoDatabase.Format(s.RequestedAt),
            ["requestedBy"] = s.RequestedBy,
            ["scope"] = s.Scope,
            ["runId"] = s.RunId,
        })]),
        ["account"] = AccountNode(status.Account),
        ["host"] = status.Host.ToNode(),
    };

    /// <summary>
    /// <c>status --target T5 --json</c>'s account: <c>reachable</c> when the account answered, <c>containerExists</c>
    /// (null when it didn't), the container's partition key, the <c>error</c> when it didn't answer, and a <c>note</c> when
    /// the container doesn't exist now, which isn't an error: it exists only during a session.
    /// </summary>
    internal static JsonObject AccountNode(CosmosAccountStatus account) => new()
    {
        ["endpoint"] = account.Endpoint,
        ["database"] = CosmosEndpoint.DatabaseName,
        ["container"] = CosmosEndpoint.ContainerName,
        ["reachable"] = account.Reachable,
        ["containerExists"] = account.Container is not null ? true : account.ContainerMissing ? false : (bool?)null,
        ["partitionKey"] = account.Container is { } container
            ? new JsonObject
            {
                ["paths"] = new JsonArray([.. container.PartitionKeyPaths.Select(p => (JsonNode)p)]),
                ["kind"] = container.PartitionKeyKind,
                ["version"] = container.PartitionKeyVersion,
            }
            : null,
        ["error"] = account.Error is null ? null : Redactor.Redact(account.Error),
        ["note"] = account.ContainerMissing ? CosmosAccountStatus.ContainerMissingNote : null,
        ["live"] = new JsonObject
        {
            ["requestsPerSecond"] = account.Live.RequestsPerSecond,
            ["ruPerSecond"] = account.Live.RuPerSecond,
            ["throttledPerSecond"] = account.Live.ThrottledPerSecond,
            ["throttledLastMinute"] = account.Live.ThrottledLastMinute,
            ["updatedAt"] = account.Live.UpdatedAt is { } updated ? DemoDatabase.Format(updated) : null,
        },
    };

    internal static void WriteStatusT5Text(TextWriter output, T5Status status)
    {
        var account = status.Account;
        var live = account.Live;
        output.WriteLine($"Target:   {status.Endpoint.Describe()}");
        output.WriteLine($"Profile:  {status.ProfileDescription}");
        output.WriteLine($"Host:     [{status.Host.Status}] {status.Host.Message}");
        output.WriteLine(account.Container is { } container
            ? $"Account:  {account.Endpoint} answers; {CosmosEndpoint.DatabaseName}/{CosmosEndpoint.ContainerName} is partitioned on {container.DescribePartitionKey()}"
            : account.ContainerMissing
                ? $"Account:  {account.Endpoint} answers; {CosmosAccountStatus.ContainerMissingNote}"
                : $"Account:  {account.Endpoint} doesn't answer: {account.Error}");
        output.WriteLine(live.UpdatedAt is { } updated
            ? string.Create(CultureInfo.InvariantCulture, $"Live:     {live.RequestsPerSecond:0.0} requests/s, {live.RuPerSecond:0.0} RU/s, {live.ThrottledPerSecond:0.0} throttled (429)/s; {live.ThrottledLastMinute} throttled in the last minute (updated {DemoDatabase.Format(updated)})")
            : "Live:     no Running run is reporting rates");
        foreach (var stop in status.StopRequests)
        {
            output.WriteLine($"Stop:     {stop.Scenario ?? "?"} ({stop.Scope}{(stop.RunId is null ? string.Empty : " " + stop.RunId)}) requested at {DemoDatabase.Format(stop.RequestedAt)} by {stop.RequestedBy}");
        }

        output.WriteLine("Runs:");
        foreach (var run in status.Runs)
        {
            output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"  {run.RunId,-28} {run.ScenarioId,-20} {run.Status,-9} started {DemoDatabase.Format(run.StartedAt)} deadline {DemoDatabase.Format(run.DeadlineAt)}{(run.ProfileName is null ? string.Empty : " profile " + run.ProfileName)}"));
        }
    }

    private static async Task<int> WarmupT5Async(ParseResult parseResult, CosmosEndpoint endpoint, bool json, CancellationToken cancellationToken)
    {
        using var client = CosmosClient(endpoint);
        var check = await CosmosAccount.WarmupAsync(client, TimeProvider.System, cancellationToken).ConfigureAwait(false);
        WriteChecks(parseResult, DemoTarget.T5, "warmup", [check], json);
        return ExitCodes.FromStatuses([check.Status]);
    }

    /// <summary>
    /// T5's setup: it checks the container (contosocare/patient-events, partitioned on /patientId), which exists only during
    /// a session (start-demo.ps1 or deploy.ps1 creates it, so its check fails between sessions), and, with --seed-scale,
    /// upserts the patient profile documents. It creates nothing else: no database, container, or role (the template,
    /// the operator scripts, and deploy.ps1 do), and there are no scripts. Idempotent.
    /// </summary>
    private static async Task<int> SetupT5Async(ParseResult parseResult, CosmosEndpoint endpoint, int? seedScale, bool json, CancellationToken cancellationToken)
    {
        if (seedScale is < 1 or > 50)
        {
            throw new ScenarioRequestException("--seed-scale must be between 1 and 50.");
        }

        using var client = CosmosClient(endpoint);
        var (container, info) = await CosmosAccount.VerifyContainerAsync(client, SessionNames.ForControl("setup"), TimeProvider.System, cancellationToken).ConfigureAwait(false);
        var checks = new List<CheckRecord> { container };
        if (seedScale is not { } scale)
        {
            checks.Add(new CheckRecord("seed", "Not selected", "No --seed-scale: the patient documents stay as they are (healthy-baseline writes its own as it runs)."));
        }
        else if (info is null || !info.HasExpectedPartitionKey)
        {
            checks.Add(new CheckRecord("seed", "Fail", string.Create(CultureInfo.InvariantCulture, $"Not seeded at scale {scale}: the container isn't usable (see the container check).")));
        }
        else
        {
            checks.Add(await CosmosAccount.SeedAsync(client, scale, TimeProvider.System, cancellationToken).ConfigureAwait(false));
        }

        WriteChecks(parseResult, DemoTarget.T5, "setup", checks, json);
        return ExitCodes.FromStatuses(checks.Select(c => c.Status));
    }

    /// <summary>What <c>status --target T5</c> shows.</summary>
    internal sealed record T5Status(
        CosmosEndpoint Endpoint,
        ProfileState Profile,
        string ProfileDescription,
        IReadOnlyList<CosmosRunEntry> Runs,
        IReadOnlyList<CosmosStopEntry> StopRequests,
        CosmosAccountStatus Account,
        HostLaneVerdict Host);
}
