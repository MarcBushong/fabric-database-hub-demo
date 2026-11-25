using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using ContosoCare.Workload.Diagnostics;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>One sidecar the index offers (transport.schema.json, sidecarRef).</summary>
internal sealed record SidecarRef(string DocumentId, string? SessionId, int Parts, string Sha256, string State);

/// <summary>
/// The index an export's first page produced (<c>rca sidecar-export --page 1</c>): every offerable sidecar, the oldest
/// sealed first, each new or pending, with how many expired unread and what the export couldn't do. Every page of that
/// export is a slice of it, so a later page lists what the first page's index did, with the same states, status, and
/// message, and never seals or waits again. Kept in <c>sidecars\index.json</c> (SidecarCommands).
/// </summary>
internal sealed class SidecarIndexSnapshot
{
    public int Version { get; set; } = 1;

    public DateTimeOffset ProducedUtc { get; set; }

    public List<SidecarRef> Documents { get; set; } = [];

    public int Expired { get; set; }

    public List<string> Problems { get; set; } = [];
}

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
/// unread, and says what the export couldn't do. <c>new</c> is a sidecar the export sealed; <c>pending</c> one sealed
/// earlier and not acknowledged yet, offered again. An export's index is taken once (<see cref="Snapshot"/>) and every
/// page is a slice of it. A page past the last is empty, with the true number of pages. A failure is a page of its own
/// (<see cref="Failed"/>), whose exit code is 1, never 2's nothing to fetch.
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
    /// An export's index: the store's offerable sidecars now, and how many expired unread since the last time they were
    /// counted (taken, so the next export doesn't count them again). <paramref name="sealedNow"/> are the IDs the export
    /// sealed, new in the index, and <paramref name="problems"/> what it couldn't do (a span not sealed, the observer still
    /// capturing), each a sentence of every page's message, which makes the pages a Warning.
    /// </summary>
    public static SidecarIndexSnapshot Snapshot(ISidecarCatalog catalog, IReadOnlyCollection<string> sealedNow, IReadOnlyList<string>? problems, DateTimeOffset producedUtc)
    {
        ArgumentNullException.ThrowIfNull(catalog);
        ArgumentNullException.ThrowIfNull(sealedNow);
        var offerable = catalog.Offerable();
        var expired = catalog.TakeExpiredCount();
        var fresh = sealedNow.ToHashSet(StringComparer.Ordinal);
        return new SidecarIndexSnapshot
        {
            ProducedUtc = producedUtc,
            Documents = [.. offerable.Select(s => new SidecarRef(s.DocumentId, s.SessionId, s.Parts, s.Sha256, fresh.Contains(s.DocumentId) ? New : Pending))],
            Expired = expired,
            Problems = [.. problems ?? []],
        };
    }

    /// <summary>Page <paramref name="page"/> (from 1) of the store's index now: <see cref="Snapshot"/>, then that page of it.</summary>
    public static SidecarIndexPage Page(ISidecarCatalog catalog, int page, IReadOnlyCollection<string> sealedNow, IReadOnlyList<string>? problems = null)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(page, 1);
        return Page(Snapshot(catalog, sealedNow, problems, default), page);
    }

    /// <summary>
    /// Page <paramref name="page"/> (from 1) of an export's index. A sidecar on the page that <paramref name="available"/>
    /// says is gone since (acknowledged and deleted, or expired) is left out, and the pages stay the index's, so no page
    /// shifts onto another's sidecars.
    /// </summary>
    public static SidecarIndexPage Page(SidecarIndexSnapshot index, int page, Func<string, bool>? available = null)
    {
        ArgumentNullException.ThrowIfNull(index);
        ArgumentOutOfRangeException.ThrowIfLessThan(page, 1);
        var offerable = index.Documents;
        var pages = (offerable.Count + PageSize - 1) / PageSize;
        var documents = page > pages
            ? []
            : offerable.Skip((page - 1) * PageSize).Take(PageSize).Where(d => available?.Invoke(d.DocumentId) ?? true).ToList();

        var newCount = offerable.Count(d => d.State == New);
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

        if (index.Expired > 0)
        {
            message.Append(CultureInfo.InvariantCulture, $" {Plural(index.Expired, "sidecar")} expired unread: sealed more than 30 days ago and never acknowledged, so {(index.Expired == 1 ? "its" : "their")} Query Store evidence isn't in the history.");
        }

        foreach (var problem in index.Problems)
        {
            message.Append(' ').Append(problem);
        }

        var status = index.Expired > 0 || index.Problems.Count > 0 ? "Warning" : offerable.Count == 0 ? "Not selected" : "Pass";
        return Fitted(new SidecarIndexPage(page, pages, documents, status, message.ToString()));
    }

    /// <summary>
    /// Whether a kept index is one this runner wrote: version 1, and every sidecar's ref as the contract has it, so a page
    /// of it is always the contract's line.
    /// </summary>
    public static bool IsValid(SidecarIndexSnapshot? index) =>
        index is { Version: 1, Documents: not null, Problems: not null }
        && index.Expired >= 0
        && index.Documents.TrueForAll(d => d is not null
            && SidecarParts.IsSidecarId(d.DocumentId)
            && (d.SessionId is null || (d.SessionId.Length == 32 && d.SessionId.All(char.IsAsciiHexDigitLower)))
            && d.Parts is >= 1 and <= 99
            && d.Sha256 is { Length: 64 } && d.Sha256.All(char.IsAsciiHexDigitLower)
            && d.State is New or Pending)
        && index.Problems.TrueForAll(p => p is not null);

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

[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip,
    WriteIndented = true)]
[JsonSerializable(typeof(SidecarIndexSnapshot))]
internal sealed partial class SidecarIndexJsonContext : JsonSerializerContext;
