using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using ContosoCare.Workload.Diagnostics;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>One sidecar the index offers (transport.schema.json, sidecarRef).</summary>
internal sealed record SidecarRef(string DocumentId, string? SessionId, int Parts, string Sha256, string State);

/// <summary>
/// One page of what <c>rca sidecar-export</c> prints after <c>DBHUBDEMO-RCAS-INDEX</c> (transport.schema.json,
/// sidecarIndex): at most 8 sidecars, and one line of at most 3,400 characters.
/// </summary>
internal sealed record SidecarIndexPage(int Page, int Pages, IReadOnlyList<SidecarRef> Documents, string Status, string Message)
{
    private static readonly JsonWriterOptions Options = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// <summary>1 for a failure (Fail); otherwise 0, or 2 when nothing is offerable, new or pending: the line prints either way.</summary>
    public int ExitCode => Status == "Fail" ? 1 : Pages == 0 ? 2 : 0;

    /// <summary>The page as its one line: <c>DBHUBDEMO-RCAS-INDEX &lt;json&gt;</c>.</summary>
    public string Line()
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer, Options))
        {
            json.WriteStartObject();
            json.WriteString("kind", SidecarIndex.Kind);
            json.WriteNumber("version", SidecarIndex.Version);
            json.WriteNumber("page", Page);
            json.WriteNumber("pages", Pages);
            json.WriteStartArray("documents");
            foreach (var document in Documents)
            {
                json.WriteStartObject();
                json.WriteString("documentId", document.DocumentId);
                if (document.SessionId is null)
                {
                    json.WriteNull("sessionId");
                }
                else
                {
                    json.WriteString("sessionId", document.SessionId);
                }

                json.WriteNumber("parts", document.Parts);
                json.WriteString("sha256", document.Sha256);
                json.WriteString("state", document.State);
                json.WriteEndObject();
            }

            json.WriteEndArray();
            json.WriteString("status", Status);
            json.WriteString("message", Message);
            json.WriteEndObject();
        }

        return SidecarParts.IndexMarker + " " + Encoding.UTF8.GetString(buffer.ToArray());
    }
}

/// <summary>
/// <c>rca sidecar-export</c>'s index (rca/README.md, The runner's commands): the store's new and pending sidecars, the
/// oldest sealed first, a page at a time, with ADR 0012's status and a message that also counts the sidecars that expired
/// unread, and says what the export couldn't do. <c>new</c> is a sidecar this call sealed; <c>pending</c> one sealed
/// earlier and not acknowledged yet, offered again. A page past the last is empty, with the true number of pages. A
/// failure is a page of its own (<see cref="Failed"/>), whose exit code is 1, never 2's nothing to fetch.
/// </summary>
internal static class SidecarIndex
{
    public const string Kind = "ContosoCare.RcaSidecarIndex";

    public const int Version = 1;

    /// <summary>At most this many sidecars a page, so a page's line stays within 3,400 characters with the longest IDs.</summary>
    public const int PageSize = 8;

    public const string New = "new";

    public const string Pending = "pending";

    private const int MaximumMessage = 500;

    /// <summary>
    /// Page <paramref name="page"/> (from 1) of the store's offerable sidecars; <paramref name="sealedNow"/> are the IDs this
    /// call sealed, and <paramref name="problems"/> what it couldn't do (a span not sealed, the observer still capturing),
    /// each a sentence of the message and the page a Warning.
    /// </summary>
    public static SidecarIndexPage Page(ISidecarCatalog catalog, int page, IReadOnlyCollection<string> sealedNow, IReadOnlyList<string>? problems = null)
    {
        ArgumentNullException.ThrowIfNull(catalog);
        ArgumentNullException.ThrowIfNull(sealedNow);
        ArgumentOutOfRangeException.ThrowIfLessThan(page, 1);
        var offerable = catalog.Offerable();
        var expired = catalog.TakeExpiredCount();
        var fresh = sealedNow.ToHashSet(StringComparer.Ordinal);
        var pages = (offerable.Count + PageSize - 1) / PageSize;
        var documents = page > pages
            ? []
            : offerable.Skip((page - 1) * PageSize).Take(PageSize)
                .Select(s => new SidecarRef(s.DocumentId, s.SessionId, s.Parts, s.Sha256, fresh.Contains(s.DocumentId) ? New : Pending))
                .ToList();

        var newCount = offerable.Count(s => fresh.Contains(s.DocumentId));
        var message = new StringBuilder();
        if (offerable.Count == 0)
        {
            message.Append("Nothing to fetch: no sidecar here is new or waiting for an acknowledgement.");
        }
        else
        {
            message.Append(CultureInfo.InvariantCulture, $"{Plural(offerable.Count, "sidecar")}: {newCount} new, and {offerable.Count - newCount} pending, sealed earlier and not acknowledged yet.");
            if (page > pages)
            {
                message.Append(CultureInfo.InvariantCulture, $" Page {page} is past the last, {pages}.");
            }
            else if (pages > 1)
            {
                message.Append(CultureInfo.InvariantCulture, $" Page {page} of {pages}.");
            }
        }

        if (expired > 0)
        {
            message.Append(CultureInfo.InvariantCulture, $" {Plural(expired, "sidecar")} expired unread: sealed more than 30 days ago and never acknowledged, so {(expired == 1 ? "its" : "their")} Query Store evidence isn't in the history.");
        }

        foreach (var problem in problems ?? [])
        {
            message.Append(' ').Append(problem);
        }

        var status = expired > 0 || problems is { Count: > 0 } ? "Warning" : offerable.Count == 0 ? "Not selected" : "Pass";
        return Fitted(new SidecarIndexPage(page, pages, documents, status, message.ToString()));
    }

    /// <summary>A failure's page (exit code 1): no sidecar listed, and why, so the caller never takes it for nothing to fetch.</summary>
    public static SidecarIndexPage Failed(int page, string message) => Fitted(new SidecarIndexPage(Math.Max(1, page), 0, [], "Fail", message));

    /// <summary>The page with its message redacted and cut to 500 characters, and to what keeps its line within 3,400.</summary>
    private static SidecarIndexPage Fitted(SidecarIndexPage page)
    {
        var text = Redactor.Redact(page.Message);
        var result = page with { Message = text.Length <= MaximumMessage ? text : text[..(MaximumMessage - 3)] + "..." };

        // The page's refs are bounded (8, IDs of at most 88 characters), so only the message can make the line too long.
        var over = result.Line().Length - RcaContract.MaximumLineLength;
        return over <= 0 ? result : result with { Message = result.Message[..Math.Max(0, result.Message.Length - over - 3)] + "..." };
    }

    private static string Plural(int count, string noun) => string.Create(CultureInfo.InvariantCulture, $"{count} {noun}{(count == 1 ? string.Empty : "s")}");
}
