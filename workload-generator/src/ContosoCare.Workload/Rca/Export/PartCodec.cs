using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace ContosoCare.Workload.Rca.Export;

/// <summary>One decoded document: its ID, the SHA-256 its parts named, and its JSON.</summary>
internal sealed record DecodedDocument(string DocumentId, string Sha256, string Json);

/// <summary>
/// The transport's part lines (rca/README.md, Part lines): a document's UTF-8 JSON, gzipped, sliced into contiguous parts
/// of at most 2,400 bytes, each printed as <c>DBHUBDEMO-RCA 1 &lt;documentId&gt; &lt;index&gt;/&lt;count&gt; &lt;sha256&gt; &lt;base64&gt;</c>:
/// at most 3,400 characters, ASCII only. Decoding checks every part is there once, concatenates them in order, checks
/// the SHA-256, and gunzips.
/// </summary>
internal static class PartCodec
{
    public static byte[] Gzip(byte[] json)
    {
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.SmallestSize, leaveOpen: true))
        {
            gzip.Write(json);
        }

        return output.ToArray();
    }

    public static byte[] Gunzip(byte[] gzip)
    {
        using var input = new GZipStream(new MemoryStream(gzip), CompressionMode.Decompress);
        using var output = new MemoryStream();
        input.CopyTo(output);
        return output.ToArray();
    }

    public static string Sha256(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));

    public static int PartCount(int gzipBytes) => Math.Max(1, (gzipBytes + RcaContract.PartBytes - 1) / RcaContract.PartBytes);

    /// <summary>Part <paramref name="index"/> (from 1) of a document's gzip as its line.</summary>
    public static string Line(string documentId, byte[] gzip, int index, string? sha256 = null)
    {
        var count = PartCount(gzip.Length);
        if (index < 1 || index > count)
        {
            throw new ArgumentOutOfRangeException(nameof(index), $"The document has parts 1 to {count}.");
        }

        var offset = (index - 1) * RcaContract.PartBytes;
        var length = Math.Min(RcaContract.PartBytes, gzip.Length - offset);
        var line = string.Create(CultureInfo.InvariantCulture, $"{RcaContract.PartMarker} {RcaContract.PartFormat} {documentId} {index}/{count} {sha256 ?? Sha256(gzip)} {Convert.ToBase64String(gzip, offset, length)}");
        return line.Length <= RcaContract.MaximumLineLength ? line : throw new InvalidOperationException("A part line would exceed 3,400 characters.");
    }

    public static IReadOnlyList<string> Lines(string documentId, byte[] gzip)
    {
        var sha256 = Sha256(gzip);
        return [.. Enumerable.Range(1, PartCount(gzip.Length)).Select(i => Line(documentId, gzip, i, sha256))];
    }

    /// <summary>Decodes part lines, grouped by document; a document with a missing, repeated, or bad part throws.</summary>
    public static IReadOnlyList<DecodedDocument> Decode(IEnumerable<string> lines)
    {
        var documents = new List<DecodedDocument>();
        foreach (var group in lines.Where(l => !string.IsNullOrWhiteSpace(l)).Select(Parse).GroupBy(p => p.DocumentId, StringComparer.Ordinal))
        {
            var parts = group.OrderBy(p => p.Index).ToList();
            var count = parts[0].Count;
            if (parts.Any(p => p.Count != count || !string.Equals(p.Sha256, parts[0].Sha256, StringComparison.Ordinal)) || !parts.Select(p => p.Index).SequenceEqual(Enumerable.Range(1, count)))
            {
                throw new InvalidDataException($"Document {group.Key} doesn't have each of its {count} parts exactly once, with one SHA-256.");
            }

            using var buffer = new MemoryStream();
            foreach (var part in parts)
            {
                var bytes = Convert.FromBase64String(part.Data);
                buffer.Write(bytes);
            }

            var gzip = buffer.ToArray();
            var hash = Sha256(gzip);
            if (!string.Equals(hash, parts[0].Sha256, StringComparison.Ordinal))
            {
                throw new InvalidDataException($"Document {group.Key}'s parts don't add up to the SHA-256 they name.");
            }

            documents.Add(new DecodedDocument(group.Key, hash, Encoding.UTF8.GetString(Gunzip(gzip))));
        }

        return documents;
    }

    private static Part Parse(string line)
    {
        var fields = line.Trim().Split(' ');
        if (fields.Length != 6 || fields[0] != RcaContract.PartMarker || fields[1] != "1")
        {
            throw new InvalidDataException("Not a DBHUBDEMO-RCA part line of format 1.");
        }

        var position = fields[3].Split('/');
        return new Part(fields[2], int.Parse(position[0], CultureInfo.InvariantCulture), int.Parse(position[1], CultureInfo.InvariantCulture), fields[4], fields[5]);
    }

    private sealed record Part(string DocumentId, int Index, int Count, string Sha256, string Data);
}
