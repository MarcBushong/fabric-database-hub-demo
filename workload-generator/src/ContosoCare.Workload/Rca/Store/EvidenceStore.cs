using System.Globalization;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.Store;

/// <summary>One observation span in the store, as the export lists it.</summary>
internal sealed record SpanInfo(string Directory, SpanFile Span, SpanExport Export)
{
    public string Id => Span.SpanId;

    /// <summary>True when the process that wrote the span is gone without closing it (the VM stopped mid-session).</summary>
    public bool Orphaned => Span.ClosedUtc is null && !EvidenceStore.IsAlive(Span.ProcessId, Span.ProcessStartedUtc);

    public bool Finished => Span.ClosedUtc is not null || Orphaned;

    /// <summary>
    /// Where the span's evidence ends, which its sidecar's window shares: its close, at the evidence's own end even when a
    /// sidecar's last reads came after it; for a span whose process is gone, its targets' last interval end or watermark;
    /// null while it's open.
    /// </summary>
    public DateTimeOffset? EvidenceEndUtc =>
        Span.ClosedUtc ?? (Orphaned ? Span.Targets.Values.Select(t => t.Intervals.LastOrDefault()?.To ?? t.WatermarkUtc).Max() : null);
}

/// <summary>
/// The local evidence store (ADR 0031): <c>C:\ProgramData\DbHubDemo\rca\</c>, SYSTEM and Administrators only, one folder
/// per observation span with a JSON-lines file per target (at most 20 MB each), the span's answer key, and what the
/// export took; the exported documents' gzip in <c>exports\</c>; and the capture's end that the last session's stop
/// recorded (<c>capture-end.json</c>). A span is deleted 7 days after its export took all of it, and one never exported
/// after 30 days, but never while it holds sidecar rows not sealed yet; an exported document after 7 days.
/// </summary>
internal sealed class EvidenceStore : ICaptureStore
{
    public const string AnswerKeyFile = "answer-key.jsonl";

    public const long DefaultTargetCap = 20L * 1024 * 1024;

    /// <summary>A span's files of sidecar rows not sealed yet, a taken-aside one's included (rca/README.md, The sidecar).</summary>
    public const string UnsealedRowsPattern = "sidecar-*" + RcaContract.SidecarRowsExtension;

    public static readonly TimeSpan Retention = TimeSpan.FromDays(7);

    public static readonly TimeSpan UnexportedRetention = TimeSpan.FromDays(30);

    private readonly Lock gate = new();
    private SpanWriter? current;
    private (SpanWriter Writer, DateTimeOffset At)? lastClosed;
    private (DateTime WrittenUtc, long Length, DateTimeOffset? EndedUtc)? captureEnd;

    public EvidenceStore(string root, TimeProvider? time = null, long targetCap = DefaultTargetCap, bool secure = false, string? host = null)
    {
        Root = Path.GetFullPath(root);
        Time = time ?? TimeProvider.System;
        TargetCap = targetCap;
        Host = Hosts.Normalize(host ?? Environment.MachineName);
        Secure = secure;
    }

    /// <summary>C:\ProgramData\DbHubDemo\rca on Windows, /var/lib/DbHubDemo/rca elsewhere: next to the profile files.</summary>
    public static string DefaultRoot => Path.Combine(Path.GetDirectoryName(FileProfileStore.DefaultPath)!, "rca");

    public string Root { get; }

    public TimeProvider Time { get; }

    public long TargetCap { get; }

    /// <summary>The host's name as the evidence carries it: lowercase, letters, digits, and single hyphens.</summary>
    public string Host { get; }

    /// <summary>True for the default store, whose folder is restricted to SYSTEM and Administrators.</summary>
    public bool Secure { get; }

    public string ExportsDirectory => Path.Combine(Root, "exports");

    public string LockPath => Path.Combine(Root, "export.lock");

    public string LedgerPath => Path.Combine(Root, "sessions.json");

    /// <summary>capture-end.json: the capture's end that the last session's stop recorded (rca export --end-capture).</summary>
    public string CaptureEndPath => Path.Combine(Root, "capture-end.json");

    /// <summary>The span this process has open, if any: the answer key's runs go into it.</summary>
    public SpanWriter? Current
    {
        get
        {
            lock (gate)
            {
                return current;
            }
        }
    }

    /// <summary>True while the process is the one that wrote the span: same ID and the same start time.</summary>
    internal static bool IsAlive(int processId, DateTimeOffset? started)
    {
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById(processId);
            if (started is not { } expected)
            {
                return !process.HasExited;
            }

            var actual = new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero);
            return !process.HasExited && Math.Abs((actual - expected).TotalSeconds) < 2;
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException)
        {
            return false;
        }
    }

    /// <summary>
    /// Creates the store's folder; on Windows the default store's folder allows only SYSTEM and Administrators, with
    /// inheritance off (https://learn.microsoft.com/dotnet/api/system.io.filesystemaclextensions.create and
    /// https://learn.microsoft.com/dotnet/api/system.security.accesscontrol.objectsecurity.setaccessruleprotection).
    /// </summary>
    public void EnsureRoot()
    {
        if (Directory.Exists(Root))
        {
            if (Secure && OperatingSystem.IsWindows())
            {
                Restrict(Root);
            }

            return;
        }

        if (Secure && OperatingSystem.IsWindows())
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Root)!);
            new DirectoryInfo(Root).Create(Restricted());
        }
        else
        {
            Directory.CreateDirectory(Root);
        }
    }

    /// <summary>Opens a new span for this process.</summary>
    public SpanWriter Open(DateTimeOffset at)
    {
        EnsureRoot();
        Cleanup(at, RunnerLog.Null);
        var id = at.UtcDateTime.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        var directory = Path.Combine(Root, id);
        for (var n = 2; Directory.Exists(directory); n++)
        {
            directory = Path.Combine(Root, id + "-" + n.ToString(CultureInfo.InvariantCulture));
        }

        Directory.CreateDirectory(directory);
        var (processId, processStarted) = CurrentProcess();
        var span = new SpanFile { SpanId = Path.GetFileName(directory), Host = Host, ProcessId = processId, ProcessStartedUtc = processStarted, StartedUtc = at };
        var writer = new SpanWriter(this, directory, span);
        writer.Persist(force: true);
        lock (gate)
        {
            current = writer;
        }

        return writer;
    }

    internal void Closed(SpanWriter writer)
    {
        lock (gate)
        {
            if (ReferenceEquals(current, writer))
            {
                current = null;
                lastClosed = (writer, Time.GetUtcNow());
            }
        }
    }

    ICaptureSpan ICaptureStore.Open(DateTimeOffset at) => Open(at);

    DateTimeOffset? ICaptureStore.CaptureEndedAt() => CaptureEndedAt();

    /// <summary>
    /// Adds one answer-key row to the span this process has open, or to the one it closed in the last hour (a run that
    /// ended as its session did). False when there's neither: the row is dropped.
    /// </summary>
    public bool AppendAnswerKey(CaptureRow row)
    {
        SpanWriter? writer;
        lock (gate)
        {
            writer = current ?? (lastClosed is { } closed && Time.GetUtcNow() - closed.At < TimeSpan.FromHours(1) ? closed.Writer : null);
        }

        if (writer is null)
        {
            return false;
        }

        writer.AppendAnswerKey(row);
        return true;
    }

    /// <summary>Every span in the store, oldest first.</summary>
    public IReadOnlyList<SpanInfo> Spans()
    {
        if (!Directory.Exists(Root))
        {
            return [];
        }

        var spans = new List<SpanInfo>();
        foreach (var directory in Directory.GetDirectories(Root).Order(StringComparer.Ordinal))
        {
            var spanPath = Path.Combine(directory, "span.json");
            if (!File.Exists(spanPath))
            {
                continue;
            }

            var span = ReadJson(spanPath, RcaStoreJsonContext.Default.SpanFile);
            if (span is null)
            {
                continue;
            }

            spans.Add(new SpanInfo(directory, span, ReadJson(Path.Combine(directory, "export.json"), RcaStoreJsonContext.Default.SpanExport) ?? new SpanExport()));
        }

        return spans;
    }

    /// <summary>
    /// Retention: a span the export took all of goes 7 days after that export; a span never exported, 30 days after it
    /// started; an exported document's gzip, 7 days after the export wrote it. A span that still holds sidecar rows not
    /// sealed yet stays until they are, whoever runs this: an export after its sealing, or a span's opening, which takes no
    /// lock and seals nothing.
    /// </summary>
    public int Cleanup(DateTimeOffset now, RunnerLog log)
    {
        var deleted = 0;
        foreach (var span in Spans())
        {
            var expired = span.Export.Complete && span.Export.LastExportUtc is { } exported
                ? now - exported >= Retention
                : span.Export.LastExportUtc is null && span.Finished && now - span.Span.StartedUtc >= UnexportedRetention;
            if (!expired)
            {
                continue;
            }

            if (HoldsUnsealedRows(span.Directory))
            {
                log.Info("rca.retention-held", "Kept an expired observation span: its sidecar rows aren't sealed yet.", ("span", span.Id));
                continue;
            }

            try
            {
                Directory.Delete(span.Directory, recursive: true);
                deleted++;
                log.Info("rca.retention", "Deleted an observation span the retention period ended.", ("span", span.Id), ("exported", span.Export.LastExportUtc));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                log.Warn("rca.retention-failed", "Couldn't delete an expired observation span; the next export tries again.", ("span", span.Id), ("error", ex.Message));
            }
        }

        if (Directory.Exists(ExportsDirectory))
        {
            foreach (var file in Directory.GetFiles(ExportsDirectory, "*.gz"))
            {
                if (now - new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero) >= Retention)
                {
                    try
                    {
                        File.Delete(file);
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                        log.Debug("rca.retention-failed", ex.Message, ("file", Path.GetFileName(file)));
                    }
                }
            }
        }

        return deleted;
    }

    public SessionLedger ReadLedger() => ReadJson(LedgerPath, RcaStoreJsonContext.Default.SessionLedger) ?? new SessionLedger();

    public void WriteLedger(SessionLedger ledger) => WriteJson(LedgerPath, ledger, RcaStoreJsonContext.Default.SessionLedger);

    /// <summary>
    /// True when a span's folder holds sidecar rows not sealed yet: a <c>sidecar-&lt;target&gt;.rows</c>, or one the sealer
    /// took aside (<c>sidecar-&lt;target&gt;.&lt;tag&gt;.rows</c>), since the sealer deletes what it sealed.
    /// </summary>
    public static bool HoldsUnsealedRows(string spanDirectory) =>
        Directory.Exists(spanDirectory) && Directory.EnumerateFiles(spanDirectory, UnsealedRowsPattern).Any();

    /// <summary>
    /// Waits until every span is exported whole or finished (closed, or its process gone), at most
    /// <paramref name="wait"/>; false when one is still open. A target's capture ends with the observer's last reads, its
    /// sidecar's included, so a final export of either kind takes them.
    /// </summary>
    public bool WaitForSpans(TimeSpan wait)
    {
        var deadline = Time.GetUtcNow() + wait;
        while (true)
        {
            if (Spans().All(s => s.Export.Complete || s.Finished))
            {
                return true;
            }

            if (Time.GetUtcNow() >= deadline)
            {
                return false;
            }

            Thread.Sleep(TimeSpan.FromMilliseconds(500));
        }
    }

    /// <summary>
    /// Records the capture's end (rca export --end-capture, a session's stop): the observer lane of 'profile run' reads it
    /// at its next tick and ends its capture, as a profile's end does, while the workload runs on. A second stop of the same
    /// session keeps the end its first recorded, untouched, so the fault runs that ended between the two never hold the span
    /// again (the review of 1ca916a9). Returns the end in effect. Call under the export's lock.
    /// </summary>
    public DateTimeOffset EndCapture(DateTimeOffset at, string? sessionId)
    {
        EnsureRoot();
        if (sessionId is not null && ReadJson(CaptureEndPath, RcaStoreJsonContext.Default.CaptureEndFile) is { SessionId: { } recorded } existing && string.Equals(recorded, sessionId, StringComparison.Ordinal))
        {
            return existing.EndedUtc;
        }

        WriteJson(CaptureEndPath, new CaptureEndFile { EndedUtc = at, SessionId = sessionId }, RcaStoreJsonContext.Default.CaptureEndFile);
        return at;
    }

    /// <summary>
    /// The capture's end the last session's stop recorded, or null for none. The file is read again only when it changed,
    /// so the observer's loops can ask at every tick; one that can't be read keeps what was read last.
    /// </summary>
    public DateTimeOffset? CaptureEndedAt()
    {
        var file = new FileInfo(CaptureEndPath);
        if (!file.Exists)
        {
            lock (gate)
            {
                captureEnd = null;
            }

            return null;
        }

        lock (gate)
        {
            if (captureEnd is { } known && known.WrittenUtc == file.LastWriteTimeUtc && known.Length == file.Length)
            {
                return known.EndedUtc;
            }
        }

        try
        {
            var ended = ReadJson(CaptureEndPath, RcaStoreJsonContext.Default.CaptureEndFile)?.EndedUtc;
            lock (gate)
            {
                captureEnd = (file.LastWriteTimeUtc, file.Length, ended);
            }

            return ended;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            lock (gate)
            {
                return captureEnd?.EndedUtc;
            }
        }
    }

    public static void WriteExport(SpanInfo span) => WriteJson(Path.Combine(span.Directory, "export.json"), span.Export, RcaStoreJsonContext.Default.SpanExport);

    /// <summary>The gzip of an exported document, or null when it isn't (or no longer) in the store.</summary>
    public byte[]? ReadDocument(string documentId)
    {
        var path = DocumentPath(documentId);
        return path is not null && File.Exists(path) ? File.ReadAllBytes(path) : null;
    }

    public void WriteDocument(string documentId, byte[] gzip)
    {
        Directory.CreateDirectory(ExportsDirectory);
        var path = DocumentPath(documentId) ?? throw new InvalidOperationException($"'{documentId}' isn't a document ID.");
        File.WriteAllBytes(path + ".tmp", gzip);
        FileReplace.Replace(path + ".tmp", path, FileReplace.Move);
    }

    /// <summary>Takes the store's export lock: one export at a time. Waits up to <paramref name="wait"/>.</summary>
    public FileStream Lock(TimeSpan wait)
    {
        EnsureRoot();
        var deadline = DateTimeOffset.UtcNow + wait;
        while (true)
        {
            try
            {
                return new FileStream(LockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
            }
            catch (IOException) when (DateTimeOffset.UtcNow < deadline)
            {
                Thread.Sleep(100);
            }
        }
    }

    internal static T? ReadJson<T>(string path, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type)
        where T : class
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                if (!File.Exists(path))
                {
                    return null;
                }

                using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                return JsonSerializer.Deserialize(stream, type);
            }
            catch (JsonException)
            {
                return null;
            }
            catch (Exception ex) when ((ex is IOException or UnauthorizedAccessException) && attempt < 5)
            {
                Thread.Sleep(25 * attempt);
            }
        }
    }

    internal static void WriteJson<T>(string path, T value, System.Text.Json.Serialization.Metadata.JsonTypeInfo<T> type)
    {
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(value, type), new UTF8Encoding(false));
        FileReplace.Replace(temporary, path, FileReplace.Move);
    }

    private string? DocumentPath(string documentId) =>
        documentId.Length is > 0 and <= 80 && documentId.All(c => char.IsAsciiLetterOrDigit(c) || c == '-') ? Path.Combine(ExportsDirectory, documentId + ".gz") : null;

    private static (int ProcessId, DateTimeOffset? Started) CurrentProcess()
    {
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        try
        {
            return (process.Id, new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero));
        }
        catch (Exception ex) when (ex is InvalidOperationException or NotSupportedException or System.ComponentModel.Win32Exception)
        {
            return (process.Id, null);
        }
    }

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
}

/// <summary>Host names as the evidence carries them (evidence.schema.json, producer.host).</summary>
internal static class Hosts
{
    public static string Normalize(string name)
    {
        var builder = new StringBuilder();
        foreach (var c in name.ToLowerInvariant())
        {
            if (char.IsAsciiLetterOrDigit(c))
            {
                builder.Append(c);
            }
            else if (builder.Length > 0 && builder[^1] != '-')
            {
                builder.Append('-');
            }
        }

        var text = builder.ToString().Trim('-');
        if (text.Length > 40)
        {
            text = text[..40].TrimEnd('-');
        }

        return text.Length == 0 ? "host" : text;
    }
}
