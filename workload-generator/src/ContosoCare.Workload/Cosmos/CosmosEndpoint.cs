using System.Globalization;
using System.Text.RegularExpressions;
using Azure;
using Azure.Core;
using Azure.Identity;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;

namespace ContosoCare.Workload.Cosmos;

/// <summary>
/// Where the runner sends T5's requests: an Azure Cosmos DB for NoSQL account whose local (key) authentication is off, so
/// every request carries a Microsoft Entra token from T1's managed identity. Holds no secret: the token is fetched when a
/// request is sent and lives only in that request's Authorization header.
/// </summary>
internal sealed partial record CosmosEndpoint(string Host, string? ManagedIdentityClientId = null)
{
    /// <summary>The only database the runner ever works in on T5 (the template creates it).</summary>
    public const string DatabaseName = "contosocare";

    /// <summary>The only container the runner ever writes to on T5 (the template creates it).</summary>
    public const string ContainerName = "patient-events";

    /// <summary>The container's partition key (Hash, version 2).</summary>
    public const string PartitionKeyPath = "/patientId";

    /// <summary>The scope a token falls back to when Microsoft Entra ID doesn't know the account's own resource URI (AADSTS500011), as the SDK's scope provider does.</summary>
    public const string FallbackScope = "https://cosmos.azure.com/.default";

    /// <summary>The scope a token is asked for first: the account's own resource URI.</summary>
    public string AccountScope => string.Create(CultureInfo.InvariantCulture, $"https://{Host}/.default");

    /// <summary>The account's gateway: HTTPS on port 443 only, the one port T1's network security group lets out.</summary>
    public Uri BaseUri => new(string.Create(CultureInfo.InvariantCulture, $"https://{Host}/"));

    /// <summary>The documents' resource path: <c>dbs/contosocare/colls/patient-events/docs</c>.</summary>
    public static string DocumentsPath => $"dbs/{DatabaseName}/colls/{ContainerName}/docs";

    /// <summary>The container's resource path: <c>dbs/contosocare/colls/patient-events</c>.</summary>
    public static string ContainerPath => $"dbs/{DatabaseName}/colls/{ContainerName}";

    public static CosmosEndpoint Create(string? server, string? managedIdentityClientId)
    {
        if (string.IsNullOrWhiteSpace(server))
        {
            throw new ScenarioRequestException("T5 needs --server, the Cosmos DB account's host name (for example cosmos01-abc123.documents.azure.com).");
        }

        var host = server.Trim().ToLowerInvariant();
        if (!HostPattern().IsMatch(host))
        {
            throw new ScenarioRequestException("--server must be the Cosmos DB account's host name, such as cosmos01-abc123.documents.azure.com: no scheme, port, or path.");
        }

        if (managedIdentityClientId is not null && !Guid.TryParse(managedIdentityClientId, out _))
        {
            throw new ScenarioRequestException("--managed-identity-client-id must be the client ID (a GUID) of a user-assigned identity.");
        }

        return new CosmosEndpoint(host, managedIdentityClientId);
    }

    /// <summary>A description that's safe to log (no credentials exist in this record).</summary>
    public string Describe() => string.Create(
        CultureInfo.InvariantCulture,
        $"T5 {Host}/{DatabaseName}/{ContainerName} (Microsoft Entra, {(ManagedIdentityClientId is null ? "system-assigned identity" : "user-assigned identity " + ManagedIdentityClientId)})");

    [GeneratedRegex(@"^[a-z0-9][a-z0-9-]{1,42}[a-z0-9]\.documents\.azure\.com$")]
    private static partial Regex HostPattern();
}

/// <summary>Why a request to T5 failed, which decides whether a run is refused for a reason that passes by itself.</summary>
internal enum CosmosFailure
{
    /// <summary>The account couldn't be reached: its name didn't resolve, the connection or TLS failed, or it didn't answer in time.</summary>
    Unreachable,

    /// <summary>The managed identity gave no Microsoft Entra token.</summary>
    Token,

    /// <summary>HTTP 401 or 403: the identity has no data-plane role on the account, or a new assignment isn't effective yet.</summary>
    Forbidden,

    /// <summary>HTTP 404: the database or the container doesn't exist.</summary>
    NotFound,

    /// <summary>HTTP 429: request rate too large.</summary>
    Throttled,

    /// <summary>HTTP 408, 410, 449, or 5xx: a transient service error.</summary>
    Transient,

    /// <summary>Any other refusal (400, 409, 413, ...).</summary>
    Request,
}

/// <summary>A failed request to T5. The message is redacted and safe to show; it never holds the token or the Authorization header.</summary>
internal sealed class CosmosException(CosmosFailure failure, string message, int? statusCode = null, int? subStatus = null, string? activityId = null, Exception? innerException = null)
    : Exception(Redactor.Redact(message), innerException)
{
    public CosmosFailure Failure { get; } = failure;

    public int? StatusCode { get; } = statusCode;

    public int? SubStatus { get; } = subStatus;

    public string? ActivityId { get; } = activityId;

    /// <summary>
    /// A run's refusal reason: <c>connect</c>, which the profile host tries again (the account can't be reached yet, or
    /// T1's data-plane role isn't effective yet), or <c>request</c> when the container is missing or the request is wrong.
    /// </summary>
    public string RefusalReason => Failure is CosmosFailure.NotFound or CosmosFailure.Request ? "request" : "connect";
}

/// <summary>Where a Microsoft Entra token for T5 comes from: T1's managed identity, or a fake in tests.</summary>
internal interface ICosmosTokenSource
{
    ValueTask<string> GetTokenAsync(CancellationToken cancellationToken);
}

/// <summary>
/// Microsoft Entra tokens for T5, reused until five minutes before they expire; requests that need one at the same moment
/// share one refresh. It asks for the account's own scope (<c>https://&lt;host&gt;/.default</c>) first; when Microsoft
/// Entra ID doesn't know that resource (AADSTS500011), it asks for <c>https://cosmos.azure.com/.default</c> and keeps
/// it, as the Cosmos DB SDK does. A failure becomes a <see cref="CosmosException"/> with a redacted message.
/// </summary>
internal sealed class CosmosTokenProvider(TokenCredential credential, CosmosEndpoint endpoint, TimeProvider? timeProvider = null) : ICosmosTokenSource
{
    /// <summary>A token is refreshed this long before it expires.</summary>
    internal static readonly TimeSpan RefreshMargin = TimeSpan.FromMinutes(5);

    /// <summary>The longest one token request may take.</summary>
    internal static readonly TimeSpan RequestLimit = TimeSpan.FromSeconds(60);

    private readonly TimeProvider time = timeProvider ?? TimeProvider.System;
    private readonly Lock gate = new();
    private volatile CachedToken? cached;
    private Task<CachedToken>? refreshing;
    private volatile bool fallback;

    /// <summary>The scope it asks for now: the account's own, or the fallback after AADSTS500011.</summary>
    public string Scope => fallback ? CosmosEndpoint.FallbackScope : endpoint.AccountScope;

    /// <summary>T1's managed identity: system-assigned, or the user-assigned one with the endpoint's client ID.</summary>
    public static CosmosTokenProvider ForManagedIdentity(CosmosEndpoint endpoint) => new(
        endpoint.ManagedIdentityClientId is null
            ? new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned)
            : new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(endpoint.ManagedIdentityClientId)),
        endpoint);

    public async ValueTask<string> GetTokenAsync(CancellationToken cancellationToken)
    {
        if (Fresh(cached) is { } token)
        {
            return token;
        }

        Task<CachedToken> task;
        lock (gate)
        {
            if (Fresh(cached) is { } current)
            {
                return current;
            }

            if (refreshing is null || refreshing.IsCompleted)
            {
                // On the thread pool, so no part of the credential's call runs under the lock.
                refreshing = Task.Run(RefreshAsync, CancellationToken.None);
            }

            task = refreshing;
        }

        return (await task.WaitAsync(cancellationToken).ConfigureAwait(false)).Token;
    }

    /// <summary>True when a failure says Microsoft Entra ID has no resource for the requested scope (AADSTS500011).</summary>
    internal static bool IsUnknownResource(Exception exception)
    {
        for (var current = exception; current is not null; current = current.InnerException)
        {
            if (current.Message.Contains("AADSTS500011", StringComparison.Ordinal))
            {
                return true;
            }
        }

        return false;
    }

    private string? Fresh(CachedToken? token) => token is not null && token.ExpiresOn - RefreshMargin > time.GetUtcNow() ? token.Token : null;

    private async Task<CachedToken> RefreshAsync()
    {
        using var limit = new CancellationTokenSource(RequestLimit);
        try
        {
            AccessToken token;
            try
            {
                token = await credential.GetTokenAsync(new TokenRequestContext([Scope]), limit.Token).ConfigureAwait(false);
            }
            catch (Exception ex) when (!fallback && IsUnknownResource(ex))
            {
                fallback = true;
                token = await credential.GetTokenAsync(new TokenRequestContext([CosmosEndpoint.FallbackScope]), limit.Token).ConfigureAwait(false);
            }

            var entry = new CachedToken(token.Token, token.ExpiresOn);
            cached = entry;
            return entry;
        }
        catch (Exception ex) when (ex is AuthenticationFailedException or CredentialUnavailableException or RequestFailedException or HttpRequestException or InvalidOperationException or OperationCanceledException)
        {
            var detail = ex is OperationCanceledException
                ? string.Create(CultureInfo.InvariantCulture, $"the managed identity didn't answer within {RequestLimit.TotalSeconds:0} s.")
                : ex.Message;
            throw new CosmosException(CosmosFailure.Token, $"Couldn't get a Microsoft Entra token for T5 ({endpoint.Host}) from the VM's managed identity: {Shorten(detail)}", innerException: ex);
        }
    }

    private static string Shorten(string text)
    {
        var line = text.ReplaceLineEndings(" ").Trim();
        return line.Length <= 400 ? line : line[..397] + "...";
    }

    private sealed record CachedToken(string Token, DateTimeOffset ExpiresOn);
}
