using System.Globalization;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.QueryStore;
using ContosoCare.Workload.Rca.Store;

namespace ContosoCare.Workload.Rca.Sidecar;

/// <summary>What <c>rca ack</c> did with each document ID: acknowledged now, acknowledged before, or not a sidecar this host keeps.</summary>
internal sealed record SidecarAcknowledgement(IReadOnlyList<string> Acknowledged, IReadOnlyList<string> Already, IReadOnlyList<string> Unknown);

/// <summary>
/// The sidecar store (rca/README.md, The sidecar): <c>sidecars\</c> under the evidence store's root, with each sealed
/// sidecar's gzip (<c>&lt;documentId&gt;.json.gz</c>) and the ledger. It's never <c>exports\</c>, whose gzip an older
/// runner deletes after 7 days, and it has no span.json, so an older runner's retention leaves the folder alone. On the
/// default store it allows only SYSTEM and Administrators, as the store's root does. A sidecar stays until
/// <c>rca ack</c> says the history has it, or for 30 days after its sealing, when it expires unread. Every change to
/// the ledger happens under the store's lock, which the sealer, the index, and <c>rca ack</c> share across processes.
/// </summary>
internal sealed partial class SidecarStore : ISidecarCatalog
{
    public const string FolderName = "sidecars";

    public const string LedgerFile = "ledger.json";

    public const string DocumentSuffix = ".json.gz";

    /// <summary>The highest sequence; the next is 1 again, and the window's start keeps the IDs apart.</summary>
    public const int MaximumSequence = 9999;

    /// <summary>The longest sidecar ID the contract allows (sidecar.schema.json, documentId).</summary>
    public const int MaximumIdLength = 88;

    /// <summary>An unacknowledged sidecar expires this long after its sealing; an acknowledged one's entry goes then too.</summary>
    public static readonly TimeSpan Retention = TimeSpan.FromDays(30);

    private static readonly TimeSpan LockWait = TimeSpan.FromSeconds(30);

    private static readonly JsonSerializerOptions NoteJson = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private readonly RunnerLog log;

    /// <param name="evidence">The evidence store, whose root holds <c>sidecars\</c>.</param>
    /// <param name="sessionBudget">A session's budget on this host, from its span's targets (64 KiB for several, 32 KiB for one, as <c>Exporter.cs</c> counts them).</param>
    /// <param name="log">The runner's log.</param>
    public SidecarStore(EvidenceStore evidence, Func<IReadOnlyCollection<string>, int> sessionBudget, RunnerLog? log = null)
    {
        ArgumentNullException.ThrowIfNull(evidence);
        ArgumentNullException.ThrowIfNull(sessionBudget);
        Evidence = evidence;
        SessionBudget = sessionBudget;
        Directory = Path.Combine(evidence.Root, FolderName);
        this.log = log ?? RunnerLog.Null;
    }

    public EvidenceStore Evidence { get; }

    /// <summary>A session's budget on this host, from its span's targets: what the sealer fits a sidecar to, and what a bind checks.</summary>
    public Func<IReadOnlyCollection<string>, int> SessionBudget { get; }

    public string Directory { get; }

    public string LedgerPath => Path.Combine(Directory, LedgerFile);

    public string LockPath => Path.Combine(Directory, "ledger.lock");

    public TimeProvider Time => Evidence.Time;

    public string Host => Evidence.Host;

    /// <summary>A sidecar's document ID: the window's start to the second, the host, the sequence, and <c>-sidecar</c>.</summary>
    public static string DocumentId(DateTimeOffset windowStart, string host, int sequence) =>
        string.Create(CultureInfo.InvariantCulture, $"{Second(windowStart).UtcDateTime:yyyyMMdd'T'HHmmss'Z'}-{host}-{sequence:D4}-sidecar");

    /// <summary>True for an ID of the sidecar's form (transport.schema.json, sidecarId), at most 88 characters.</summary>
    public static bool IsSidecarId(string? documentId) => documentId is { Length: > 0 and <= MaximumIdLength } && SidecarIdPattern().IsMatch(documentId);

    /// <summary>The budget a sidecar counts against: its session's, or, without one, its span's alone.</summary>
    public static string BudgetKey(string? sessionId, string spanId) => sessionId ?? "span:" + spanId;

    /// <summary>A time truncated to its second.</summary>
    public static DateTimeOffset Second(DateTimeOffset time) => new(time.UtcDateTime.Ticks - (time.UtcDateTime.Ticks % TimeSpan.TicksPerSecond), TimeSpan.Zero);

    /// <summary>
    /// A sealed sidecar's JSON with its top-level <c>sessionId</c> set, where it was null: what the encoder writes for that
    /// session, since the session is in no other field. Null when the JSON has no top-level null <c>sessionId</c>.
    /// </summary>
    public static byte[]? BindJson(byte[] json, string sessionId)
    {
        ArgumentNullException.ThrowIfNull(json);
        var reader = new Utf8JsonReader(json);
        if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
        {
            return null;
        }

        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var isSession = reader.ValueTextEquals("sessionId"u8);
            if (!reader.Read())
            {
                return null;
            }

            if (isSession)
            {
                if (reader.TokenType != JsonTokenType.Null)
                {
                    return null;
                }

                var at = (int)reader.TokenStartIndex;
                return [.. json.AsSpan(0, at), .. Encoding.UTF8.GetBytes("\"" + sessionId + "\""), .. json.AsSpan(at + 4)];
            }

            reader.Skip();
        }

        return null;
    }

    /// <summary>Creates <c>sidecars\</c>; on the default store, it allows only SYSTEM and Administrators, with inheritance off.</summary>
    public void EnsureFolder()
    {
        Evidence.EnsureRoot();
        if (Evidence.Secure && OperatingSystem.IsWindows())
        {
            if (System.IO.Directory.Exists(Directory))
            {
                Restrict(Directory);
            }
            else
            {
                new DirectoryInfo(Directory).Create(Restricted());
            }

            return;
        }

        System.IO.Directory.CreateDirectory(Directory);
    }

    /// <summary>Takes the sidecar store's lock: one sealing, index, acknowledgement, or cleanup at a time, across processes.</summary>
    public FileStream Lock(TimeSpan? wait = null)
    {
        EnsureFolder();
        var deadline = DateTimeOffset.UtcNow + (wait ?? LockWait);
        while (true)
        {
            try
            {
                return new FileStream(LockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
            }
            catch (IOException) when (DateTimeOffset.UtcNow < deadline)
            {
                Thread.Sleep(50);
            }
        }
    }

    /// <summary>The lock if it's free now, else null: for the observer, which never waits on an export.</summary>
    public FileStream? TryLock()
    {
        EnsureFolder();
        try
        {
            return new FileStream(LockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
        }
        catch (IOException)
        {
            return null;
        }
    }

    /// <summary>
    /// The ledger, read under the lock. One that can't be read is kept beside it, never deleted, and rebuilt from the
    /// sealed documents, each offered again as not acknowledged (the history answers <c>already</c> for one it has); so
    /// is a ledger that's missing while sealed documents remain. A rebuilt ledger, or a new one, is written at once:
    /// whatever the caller does next, the next read finds it, and a sealing cut short leaves a ledger beside its
    /// document, never a document alone that a rebuild would offer beside the same rows sealed again.
    /// </summary>
    public SidecarLedger ReadLedger()
    {
        if (File.Exists(LedgerPath))
        {
            if (EvidenceStore.ReadJson(LedgerPath, SidecarJsonContext.Default.SidecarLedger) is { Version: 1 } ledger)
            {
                return ledger;
            }

            var kept = LedgerPath + ".unreadable-" + Time.GetUtcNow().UtcDateTime.ToString("yyyyMMdd'T'HHmmssfff'Z'", CultureInfo.InvariantCulture);
            File.Move(LedgerPath, kept, overwrite: false);
            log.Warn("rca.sidecar-ledger-unreadable", "The sidecar ledger couldn't be read; it's kept beside a new one rebuilt from the sealed sidecars, which are offered again.", ("kept", Path.GetFileName(kept)));
            return Saved(Rebuild());
        }

        if (HasDocuments())
        {
            log.Warn("rca.sidecar-ledger-missing", "The sidecar ledger was missing; it's rebuilt from the sealed sidecars, which are offered again.");
            return Saved(Rebuild());
        }

        return Saved(new SidecarLedger());
    }

    /// <summary>Writes the ledger whole, through a temporary file, as the evidence store writes its own. Call under the lock.</summary>
    public void WriteLedger(SidecarLedger ledger)
    {
        ArgumentNullException.ThrowIfNull(ledger);
        EnsureFolder();
        EvidenceStore.WriteJson(LedgerPath, ledger, SidecarJsonContext.Default.SidecarLedger);
    }

    /// <summary>A sealed sidecar's file, or null for an ID that isn't a sidecar's.</summary>
    public string? DocumentPath(string documentId) => IsSidecarId(documentId) ? Path.Combine(Directory, documentId + DocumentSuffix) : null;

    /// <summary>A sealed sidecar's gzip, or null when it isn't (or no longer) in the store.</summary>
    public byte[]? ReadDocument(string documentId) => DocumentPath(documentId) is { } path && File.Exists(path) ? File.ReadAllBytes(path) : null;

    /// <inheritdoc/>
    public byte[]? ReadGzip(string documentId) => ReadDocument(documentId);

    internal void WriteDocument(string documentId, byte[] gzip)
    {
        EnsureFolder();
        var path = DocumentPath(documentId) ?? throw new InvalidOperationException($"'{documentId}' isn't a sidecar's document ID.");
        File.WriteAllBytes(path + ".tmp", gzip);
        Profiles.FileReplace.Replace(path + ".tmp", path, Profiles.FileReplace.Move);
    }

    /// <summary>The next free document ID for a window's start, moving the ledger's sequence on. Call under the lock.</summary>
    public (string DocumentId, int Sequence) NextDocumentId(SidecarLedger ledger, DateTimeOffset windowStart)
    {
        ArgumentNullException.ThrowIfNull(ledger);
        var sequence = ledger.NextSequence is >= 1 and <= MaximumSequence ? ledger.NextSequence : 1;
        for (var tries = 0; tries < MaximumSequence; tries++)
        {
            var documentId = DocumentId(windowStart, Host, sequence);
            var next = (sequence % MaximumSequence) + 1;
            if (!ledger.Sidecars.Exists(s => string.Equals(s.DocumentId, documentId, StringComparison.Ordinal)))
            {
                ledger.NextSequence = next;
                return (documentId, sequence);
            }

            sequence = next;
        }

        throw new InvalidOperationException("Every sequence is taken for this window's start.");
    }

    /// <summary>
    /// New and pending sidecars, the oldest sealed first: every sidecar not acknowledged, after retention. A sidecar's
    /// bytes are final once it's offered, so one sealed before its span was bound takes the span's binding now, or no
    /// session when no export bound it.
    /// </summary>
    public IReadOnlyList<SealedSidecar> Offerable()
    {
        using var exclusive = Lock();
        var ledger = ReadLedger();
        Cleanup(ledger, Time.GetUtcNow());
        foreach (var spanId in ledger.Sidecars.Where(s => !s.Bound).Select(s => s.SpanId).Distinct(StringComparer.Ordinal).ToList())
        {
            var export = SpanExport(spanId);
            Bind(ledger, spanId, export is { Bound: true } ? export.SessionId : null);
        }

        WriteLedger(ledger);
        return [.. ledger.Sidecars
            .Where(s => s.AcknowledgedUtc is null)
            .OrderBy(s => s.SealedUtc)
            .ThenBy(s => s.DocumentId, StringComparer.Ordinal)
            .Select(Sealed)];
    }

    /// <inheritdoc/>
    public int TakeExpiredCount()
    {
        using var exclusive = Lock();
        var ledger = ReadLedger();
        Cleanup(ledger, Time.GetUtcNow());
        var expired = ledger.ExpiredUnread;
        ledger.ExpiredUnread = 0;
        WriteLedger(ledger);
        return expired;
    }

    /// <summary>
    /// Marks sidecars as written into the history: never offered again, and their files go at the next cleanup. An ID
    /// this host doesn't keep is reported, not an error.
    /// </summary>
    public SidecarAcknowledgement Acknowledge(IEnumerable<string> documentIds)
    {
        ArgumentNullException.ThrowIfNull(documentIds);
        using var exclusive = Lock();
        var ledger = ReadLedger();
        var now = Time.GetUtcNow();
        List<string> acknowledged = [], already = [], unknown = [];
        foreach (var documentId in documentIds.Select(d => d.Trim()).Where(d => d.Length > 0).Distinct(StringComparer.Ordinal))
        {
            var entry = ledger.Sidecars.Find(s => string.Equals(s.DocumentId, documentId, StringComparison.Ordinal));
            if (entry is null)
            {
                unknown.Add(documentId);
            }
            else if (entry.AcknowledgedUtc is null)
            {
                entry.AcknowledgedUtc = now;
                acknowledged.Add(documentId);
            }
            else
            {
                already.Add(documentId);
            }
        }

        if (acknowledged.Count > 0)
        {
            WriteLedger(ledger);
        }

        return new SidecarAcknowledgement(acknowledged, already, unknown);
    }

    /// <summary>Retention, under the store's lock: see <see cref="Cleanup(SidecarLedger, DateTimeOffset)"/>.</summary>
    public int Cleanup(DateTimeOffset now)
    {
        using var exclusive = Lock();
        var ledger = ReadLedger();
        var expired = Cleanup(ledger, now);
        WriteLedger(ledger);
        return expired;
    }

    /// <summary>
    /// Retention (call under the lock; the caller writes the ledger): an acknowledged sidecar's file is deleted, and its
    /// entry goes 30 days after its sealing, so a late <c>rca ack</c> is still answered; an unacknowledged one expires 30
    /// days after its sealing, deleted and counted as expired unread. A span's entry stays while its folder, a sidecar,
    /// or one of T4's pending ranges names it. Returns how many expired.
    /// </summary>
    public int Cleanup(SidecarLedger ledger, DateTimeOffset now)
    {
        ArgumentNullException.ThrowIfNull(ledger);
        var expired = 0;
        foreach (var entry in ledger.Sidecars.ToList())
        {
            var age = now - entry.SealedUtc;
            if (entry.AcknowledgedUtc is not null)
            {
                DeleteDocument(entry.DocumentId);
                if (age >= Retention)
                {
                    ledger.Sidecars.Remove(entry);
                }
            }
            else if (age >= Retention)
            {
                DeleteDocument(entry.DocumentId);
                ledger.Sidecars.Remove(entry);
                ledger.ExpiredUnread++;
                expired++;
                log.Warn("rca.sidecar-expired", "A sidecar no save acknowledged expired 30 days after its sealing, unread.", ("document", entry.DocumentId), ("session", entry.SessionId ?? "none"));
            }
        }

        if (System.IO.Directory.Exists(Directory))
        {
            // A document without an entry (a sealing cut short before its ledger was written) goes after the same 30 days;
            // only a file named as a sidecar is ever deleted.
            foreach (var file in System.IO.Directory.GetFiles(Directory, "*" + DocumentSuffix))
            {
                var documentId = Path.GetFileName(file)[..^DocumentSuffix.Length];
                if (IsSidecarId(documentId) && !ledger.Sidecars.Exists(s => string.Equals(s.DocumentId, documentId, StringComparison.Ordinal)) && now - new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero) >= Retention)
                {
                    DeleteFile(file);
                }
            }
        }

        foreach (var key in ledger.Budgets.Keys.ToList())
        {
            var use = ledger.Budgets[key];
            if (!ledger.Sidecars.Exists(s => string.Equals(s.Budget, key, StringComparison.Ordinal)) && (use.LastSealedUtc is not { } last || now - last >= Retention))
            {
                ledger.Budgets.Remove(key);
            }
        }

        if (NamedSpans(ledger) is { } named)
        {
            foreach (var spanId in ledger.Spans.Keys.Where(s => !named.Contains(s)).ToList())
            {
                ledger.Spans.Remove(spanId);
            }
        }

        return expired;
    }

    /// <summary>
    /// Gives the sidecars sealed before their span was bound the span's session (call under the lock): each document is
    /// written again with it, and its bytes move to that session's budget. <see cref="Offerable"/> settles every such
    /// sidecar before it lists any, so an offered sidecar's bytes never change.
    /// </summary>
    internal void Bind(SidecarLedger ledger, string spanId, string? sessionId)
    {
        foreach (var entry in ledger.Sidecars.Where(s => !s.Bound && string.Equals(s.SpanId, spanId, StringComparison.Ordinal)).ToList())
        {
            if (sessionId is not null)
            {
                BindDocument(ledger, entry, sessionId);
            }

            entry.Bound = true;
        }

        if (ledger.Spans.TryGetValue(spanId, out var span) && !span.Bound)
        {
            span.Bound = true;
            span.SessionId = sessionId;
        }
    }

    /// <summary>
    /// One sidecar's bind (call under the lock), the file first and its ledger entry after it.
    /// <list type="bullet">
    /// <item>A document with no session yet is written again with it.</item>
    /// <item>A document that has a session already is one a bind wrote and the ledger never recorded (a crash, or a failure
    /// before the ledger was written): the file is what counts, so the entry takes its hash, size, and parts.</item>
    /// <item>When the bind takes the session over this host's budget, the sidecar isn't cut again: each of its coverage
    /// rows gets a gap line that says by how much, and the log a warning. The transport pages what doesn't fit.</item>
    /// </list>
    /// </summary>
    private void BindDocument(SidecarLedger ledger, SidecarEntry entry, string sessionId)
    {
        var gzip = ReadDocument(entry.DocumentId);
        var json = gzip is null ? null : PartCodec.Gunzip(gzip);
        var (found, current) = json is null ? (false, null) : TopLevelSession(json);
        if (gzip is null || json is null || !found)
        {
            log.Warn("rca.sidecar-bind-failed", "A sidecar sealed before its span was bound couldn't take the span's session; it stays as it is.", ("document", entry.DocumentId), ("span", entry.SpanId));
            return;
        }

        var session = current ?? sessionId;
        var key = BudgetKey(session, entry.SpanId);
        var others = (ledger.Budgets.TryGetValue(key, out var use) ? use.Bytes : 0L) - (string.Equals(entry.Budget, key, StringComparison.Ordinal) ? entry.Bytes : 0L);
        var budget = SessionBudget(ledger.Spans.TryGetValue(entry.SpanId, out var span) ? span.Targets : []);
        byte[] bound;
        if (current is null)
        {
            var withSession = BindJson(json, sessionId)!;
            bound = PartCodec.Gzip(withSession);
            if (others + bound.Length > budget)
            {
                bound = WithOverBudgetNote(withSession, others, budget);
            }

            WriteDocument(entry.DocumentId, bound);
        }
        else
        {
            bound = gzip;
            if (!string.Equals(current, sessionId, StringComparison.Ordinal))
            {
                log.Warn("rca.sidecar-bind-session", "A sidecar sealed before its span was bound already names another session; it keeps that one.", ("document", entry.DocumentId), ("span", entry.SpanId));
            }
            else
            {
                log.Info("rca.sidecar-bind-recovered", "A sidecar's bind that the ledger never recorded is taken from its file.", ("document", entry.DocumentId), ("span", entry.SpanId));
            }
        }

        var excess = others + bound.Length - budget;
        if (excess > 0)
        {
            log.Warn("rca.sidecar-over-budget", "A session's sidecars exceed this host's budget: a span was sealed before the session's first export, so its sidecar wasn't cut to the session's budget. The transport pages what doesn't fit.", ("document", entry.DocumentId), ("session", session), ("bytes", excess));
        }

        Use(ledger, entry.Budget, -entry.Bytes, null);
        entry.Budget = key;
        Use(ledger, key, bound.Length, entry.SealedUtc);
        entry.SessionId = session;
        entry.Bytes = bound.Length;
        entry.Parts = PartCodec.PartCount(bound.Length);
        entry.Sha256 = PartCodec.Sha256(bound);
    }

    /// <summary>The gap line a bind adds to a sidecar that takes its session over this host's budget.</summary>
    internal static string OverBudgetLine(long excess) =>
        string.Create(CultureInfo.InvariantCulture, $"the session's sidecars exceed this host's budget by {excess} bytes: a span was sealed before the session's first export.");

    /// <summary>
    /// A sidecar's JSON with one more line in each of its coverage rows' gaps, the string dictionary taking the new texts
    /// (each distinct text once); null when it has no coverage table, or no room for another string.
    /// </summary>
    internal static byte[]? WithGapLine(byte[] json, string line)
    {
        ArgumentNullException.ThrowIfNull(json);
        if (JsonNode.Parse(json) is not JsonObject root
            || root["strings"] is not JsonArray strings
            || root["tables"]?[RcaContract.QueryCoverage] is not JsonObject coverage
            || coverage["columns"] is not JsonObject columns
            || coverage["rows"] is not JsonValue count
            || !count.TryGetValue<int>(out var rows)
            || RcaContract.Table(RcaContract.QueryCoverage).Columns[^1].Name != "gaps")
        {
            return null;
        }

        if (columns["gaps"] is not JsonArray gaps)
        {
            // The encoder leaves out a column whose values are all null; gaps is the table's last, so it goes last.
            gaps = new JsonArray(Enumerable.Repeat<JsonNode?>(null, rows).ToArray());
            columns["gaps"] = gaps;
        }

        var texts = strings.Select(s => s?.GetValue<string>()).ToList();
        for (var i = 0; i < rows && i < gaps.Count; i++)
        {
            var existing = gaps[i] is JsonValue value && value.TryGetValue<int>(out var index) && index >= 0 && index < texts.Count ? texts[index] : null;
            var text = existing is null ? line : existing + "\n" + line;
            if (text.Length > RcaContract.MaximumStringLength)
            {
                text = existing![..Math.Max(0, RcaContract.MaximumStringLength - line.Length - 5)] + "...\n" + line;
            }

            var at = texts.IndexOf(text);
            if (at < 0)
            {
                if (texts.Count >= RcaContract.MaximumStrings)
                {
                    return null;
                }

                strings.Add(text);
                texts.Add(text);
                at = texts.Count - 1;
            }

            gaps[i] = at;
        }

        return Encoding.UTF8.GetBytes(root.ToJsonString(NoteJson));
    }

    /// <summary>The bound document with its over-budget line, whose figure is the excess of the document as written.</summary>
    private static byte[] WithOverBudgetNote(byte[] json, long others, int budget)
    {
        var gzip = PartCodec.Gzip(json);
        var excess = others + gzip.Length - budget;
        for (var attempt = 0; attempt < 4; attempt++)
        {
            if (WithGapLine(json, OverBudgetLine(excess)) is not { } noted)
            {
                break;
            }

            gzip = PartCodec.Gzip(noted);
            var written = others + gzip.Length - budget;
            if (written == excess)
            {
                break;
            }

            excess = written;
        }

        return gzip;
    }

    /// <summary>A document's top-level sessionId: whether it has one, and its value (null for none).</summary>
    private static (bool Found, string? Session) TopLevelSession(byte[] json)
    {
        var reader = new Utf8JsonReader(json);
        if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject)
        {
            return (false, null);
        }

        while (reader.Read() && reader.TokenType == JsonTokenType.PropertyName)
        {
            var isSession = reader.ValueTextEquals("sessionId"u8);
            if (!reader.Read())
            {
                return (false, null);
            }

            if (isSession)
            {
                return reader.TokenType switch
                {
                    JsonTokenType.Null => (true, null),
                    JsonTokenType.String => (true, reader.GetString()),
                    _ => (false, null),
                };
            }

            reader.Skip();
        }

        return (false, null);
    }

    /// <summary>Adds <paramref name="bytes"/> (or takes them away) from a budget's use.</summary>
    internal static void Use(SidecarLedger ledger, string key, long bytes, DateTimeOffset? sealedUtc)
    {
        if (!ledger.Budgets.TryGetValue(key, out var use))
        {
            ledger.Budgets[key] = use = new SidecarBudgetUse();
        }

        use.Bytes = Math.Max(0, use.Bytes + bytes);
        if (sealedUtc is { } at)
        {
            use.Sidecars++;
            use.LastSealedUtc = use.LastSealedUtc is { } last && last > at ? last : at;
        }
        else if (bytes < 0)
        {
            use.Sidecars = Math.Max(0, use.Sidecars - 1);
        }
    }

    /// <summary>The span's export.json (the binding an export wrote), or null when the span's folder is gone.</summary>
    internal SpanExport? SpanExport(string spanId) =>
        spanId.Length > 0 && spanId.All(c => char.IsAsciiLetterOrDigit(c) || c == '-') && File.Exists(Path.Combine(Evidence.Root, spanId, "span.json"))
            ? EvidenceStore.ReadJson(Path.Combine(Evidence.Root, spanId, "export.json"), RcaStoreJsonContext.Default.SpanExport) ?? new SpanExport()
            : null;

    internal static SealedSidecar Sealed(SidecarEntry entry) =>
        new(entry.DocumentId, entry.SessionId, entry.SpanId, entry.Host, entry.Sequence, entry.WindowStartUtc, entry.WindowEndUtc, entry.SealedUtc, entry.Parts, entry.Sha256, entry.Backfill, entry.AcknowledgedUtc);

    /// <summary>The span IDs something still names: a span folder, a sidecar, or T4's pending ranges; null when the ranges can't be read.</summary>
    private HashSet<string>? NamedSpans(SidecarLedger ledger)
    {
        var named = new HashSet<string>(Evidence.Spans().Select(s => s.Id), StringComparer.Ordinal);
        named.UnionWith(ledger.Sidecars.Select(s => s.SpanId));
        var folder = Path.Combine(Evidence.Root, QueryWatermark.Folder);
        if (!System.IO.Directory.Exists(folder))
        {
            return named;
        }

        try
        {
            foreach (var file in System.IO.Directory.GetFiles(folder, "*.json"))
            {
                var target = Path.GetFileNameWithoutExtension(file);
                if (target.Length > 0 && target.All(c => char.IsAsciiLetterOrDigit(c) || c == '-'))
                {
                    named.UnionWith(new QueryWatermark(Evidence.Root, target).Read().Pending.Select(p => p.SpanId));
                }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }

        return named;
    }

    private void DeleteDocument(string documentId)
    {
        if (DocumentPath(documentId) is { } path && File.Exists(path))
        {
            DeleteFile(path);
        }
    }

    private void DeleteFile(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Debug("rca.sidecar-retention-failed", ex.Message, ("file", Path.GetFileName(path)));
        }
    }

    /// <summary>A ledger from the sealed documents' own headers: each kept, none acknowledged, its budget counted again; the spans start again.</summary>
    private SidecarLedger Rebuild()
    {
        var ledger = new SidecarLedger();
        if (!System.IO.Directory.Exists(Directory))
        {
            return ledger;
        }

        foreach (var file in System.IO.Directory.GetFiles(Directory, "*" + DocumentSuffix).Order(StringComparer.Ordinal))
        {
            var documentId = Path.GetFileName(file)[..^DocumentSuffix.Length];
            if (!IsSidecarId(documentId))
            {
                continue;
            }

            try
            {
                var gzip = File.ReadAllBytes(file);
                using var document = JsonDocument.Parse(PartCodec.Gunzip(gzip));
                var root = document.RootElement;
                var session = root.GetProperty("sessionId").ValueKind == JsonValueKind.String ? root.GetProperty("sessionId").GetString() : null;
                ledger.Sidecars.Add(new SidecarEntry
                {
                    DocumentId = documentId,
                    SessionId = session,
                    Bound = true,
                    Host = root.GetProperty("producer").GetProperty("host").GetString() ?? Host,
                    WindowStartUtc = Utc(root, "windowStartUtc"),
                    WindowEndUtc = Utc(root, "windowEndUtc"),
                    Sequence = root.GetProperty("sequence").GetInt32(),
                    SealedUtc = Utc(root, "exportedUtc"),
                    Parts = PartCodec.PartCount(gzip.Length),
                    Bytes = gzip.Length,
                    Sha256 = PartCodec.Sha256(gzip),
                    Budget = BudgetKey(session, documentId),
                });
            }
            catch (Exception ex) when (ex is IOException or InvalidDataException or JsonException or FormatException or KeyNotFoundException or InvalidOperationException)
            {
                // A document that can't be read stays where it is: retention deletes it as one without an entry.
                log.Debug("rca.sidecar-unreadable", ex.Message, ("document", documentId));
            }
        }

        ledger.Sidecars.Sort((a, b) => a.SealedUtc != b.SealedUtc ? a.SealedUtc.CompareTo(b.SealedUtc) : string.CompareOrdinal(a.DocumentId, b.DocumentId));
        foreach (var entry in ledger.Sidecars)
        {
            Use(ledger, entry.Budget, entry.Bytes, entry.SealedUtc);
        }

        ledger.NextSequence = ledger.Sidecars.Count == 0 ? 1 : (ledger.Sidecars.Max(s => s.Sequence) % MaximumSequence) + 1;
        return ledger;
    }

    /// <summary>True when <c>sidecars\</c> holds a document named as a sidecar.</summary>
    private bool HasDocuments() =>
        System.IO.Directory.Exists(Directory)
        && System.IO.Directory.EnumerateFiles(Directory, "*" + DocumentSuffix).Any(f => IsSidecarId(Path.GetFileName(f)[..^DocumentSuffix.Length]));

    /// <summary>Writes a ledger the read made, so the next read finds it, and returns it.</summary>
    private SidecarLedger Saved(SidecarLedger ledger)
    {
        WriteLedger(ledger);
        return ledger;
    }

    private static DateTimeOffset Utc(JsonElement root, string property) =>
        DateTimeOffset.Parse(root.GetProperty(property).GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static DirectorySecurity Restricted()
    {
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        foreach (var sid in new[] { new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null) })
        {
            security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        }

        return security;
    }

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static void Restrict(string path)
    {
        var info = new DirectoryInfo(path);
        var current = info.GetAccessControl();
        var rules = current.GetAccessRules(includeExplicit: true, includeInherited: true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().Select(r => ((SecurityIdentifier)r.IdentityReference).Value).Distinct().Order(StringComparer.Ordinal).ToList();
        var wanted = new[] { new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null).Value, new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null).Value }.Order(StringComparer.Ordinal).ToList();
        if (current.AreAccessRulesProtected && rules.SequenceEqual(wanted))
        {
            return;
        }

        info.SetAccessControl(Restricted());
    }

    [GeneratedRegex("^[0-9]{8}T[0-9]{6}Z-[a-z0-9]+(-[a-z0-9]+)*-[0-9]{4}-sidecar$")]
    private static partial Regex SidecarIdPattern();
}
