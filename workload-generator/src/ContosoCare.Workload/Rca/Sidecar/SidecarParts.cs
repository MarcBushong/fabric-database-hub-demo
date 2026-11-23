using System.Globalization;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Rca.Export;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>
/// A sidecar's part lines (rca/README.md, Part lines; transport.schema.json, sidecarPartLine): its gzip sliced into
/// contiguous parts of at most 2,400 bytes, each printed as
/// <c>DBHUBDEMO-RCAS 1 &lt;documentId&gt; &lt;index&gt;/&lt;count&gt; &lt;sha256&gt; &lt;base64&gt;</c>, at most 3,400 characters,
/// ASCII only. Their marker isn't the evidence document's, so a piece that takes only <c>DBHUBDEMO-RCA</c> and a space
/// never takes one, and a sidecar's ID always ends in <c>-sidecar</c>.
/// </summary>
internal static partial class SidecarParts
{
    /// <summary>The marker of a sidecar's part line.</summary>
    public const string Marker = "DBHUBDEMO-RCAS";

    /// <summary>The marker of <c>rca sidecar-export</c>'s index line.</summary>
    public const string IndexMarker = "DBHUBDEMO-RCAS-INDEX";

    /// <summary>What ends a sidecar's document ID, after the evidence document's form.</summary>
    public const string Suffix = "-sidecar";

    /// <summary>The longest sidecar ID the contract allows (sidecar.schema.json, documentId).</summary>
    public const int MaximumIdLength = 88;

    /// <summary>True for a sidecar's document ID: <c>&lt;yyyyMMddTHHmmssZ&gt;-&lt;host&gt;-&lt;sequence, 4 digits&gt;-sidecar</c>.</summary>
    public static bool IsSidecarId(string? documentId) =>
        documentId is not null && documentId.Length <= MaximumIdLength && SidecarId().IsMatch(documentId);

    /// <summary>Part <paramref name="index"/> (from 1) of a sidecar's gzip as its line.</summary>
    public static string Line(string documentId, byte[] gzip, int index, string? sha256 = null)
    {
        ArgumentNullException.ThrowIfNull(gzip);
        if (!IsSidecarId(documentId))
        {
            throw new ArgumentException($"'{documentId}' isn't a sidecar's document ID.", nameof(documentId));
        }

        var count = PartCodec.PartCount(gzip.Length);
        if (count > RcaContract.MaximumParts)
        {
            throw new InvalidOperationException($"A sidecar of {gzip.Length} bytes would take {count} parts; a part line counts to {RcaContract.MaximumParts}.");
        }

        if (index < 1 || index > count)
        {
            throw new ArgumentOutOfRangeException(nameof(index), $"The sidecar has parts 1 to {count}.");
        }

        var offset = (index - 1) * RcaContract.PartBytes;
        var length = Math.Min(RcaContract.PartBytes, gzip.Length - offset);
        var line = string.Create(CultureInfo.InvariantCulture, $"{Marker} {RcaContract.PartFormat} {documentId} {index}/{count} {sha256 ?? PartCodec.Sha256(gzip)} {Convert.ToBase64String(gzip, offset, length)}");
        return line.Length <= RcaContract.MaximumLineLength ? line : throw new InvalidOperationException("A sidecar's part line would exceed 3,400 characters.");
    }

    /// <summary>Every part line of a sidecar's gzip, in order.</summary>
    public static IReadOnlyList<string> Lines(string documentId, byte[] gzip)
    {
        ArgumentNullException.ThrowIfNull(gzip);
        var sha256 = PartCodec.Sha256(gzip);
        return [.. Enumerable.Range(1, PartCodec.PartCount(gzip.Length)).Select(i => Line(documentId, gzip, i, sha256))];
    }

    /// <summary>
    /// <c>rca part</c> for a sidecar: part <paramref name="index"/> of a sealed sidecar's line, or null when the store has no
    /// sidecar by that ID or the sidecar has no such part.
    /// </summary>
    public static string? Part(ISidecarCatalog catalog, string documentId, int index)
    {
        ArgumentNullException.ThrowIfNull(catalog);
        if (!IsSidecarId(documentId))
        {
            return null;
        }

        var gzip = catalog.ReadGzip(documentId);
        return gzip is null || gzip.Length == 0 || index < 1 || index > PartCodec.PartCount(gzip.Length) ? null : Line(documentId, gzip, index);
    }

    // transport.schema.json's sidecarId, anchored at the very end: .NET's $ also matches before a final newline.
    [GeneratedRegex(@"\A[0-9]{8}T[0-9]{6}Z-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{4}-sidecar\z", RegexOptions.CultureInvariant)]
    private static partial Regex SidecarId();
}
