using System.CommandLine;
using System.Data;
using System.Globalization;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Postgres;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Rca.Export;
using ContosoCare.Workload.Rca.Observer;
using ContosoCare.Workload.Rca.Sidecar;
using ContosoCare.Workload.Rca.Store;
using ContosoCare.Workload.Sql;
using Microsoft.Data.SqlClient;

namespace ContosoCare.Workload.Cli;

/// <summary>
/// The Incident RCA's commands (ADR 0031, rca/README.md): <c>rca export</c> reduces what the observer captured into
/// evidence documents and prints their index on one line; <c>rca part</c> prints one part line of one document, an
/// evidence document's or a sidecar's; <c>rca sidecar-export</c> seals Query Store's evidence into sidecars and prints one
/// page of their index; <c>rca ack</c> tells the runner which sidecars the history holds. Each prints one line, under a
/// managed Run Command's 4 KB.
/// </summary>
internal static partial class CommandLine
{
    private static Option<string?> RcaStoreOption() => new("--rca-store") { Description = "The Incident RCA observer's evidence store (ADR 0031). Defaults to C:\\ProgramData\\DbHubDemo\\rca (or /var/lib/DbHubDemo/rca), which only SYSTEM and Administrators can read." };

    private static Command RcaCommand()
    {
        var command = new Command("rca", "The Incident RCA evidence (ADR 0031): export what the observer lane of 'profile run' captured, and print its parts.");

        var export = new Command("export", "Reduce what the RCA observer captured since the previous export into evidence documents, and print their index: one line, DBHUBDEMO-RCA-INDEX <json>. Exit code 0 (with a Warning when a span couldn't be exported, which the next export tries again), 2 when there's nothing to export, 1 when nothing could be exported.");
        var session = new Option<string>("--session") { Description = "The control session's ID (32 lowercase hex, the resource group's DbHubSessionId), or none outside a control session.", Required = true };
        var final = new Option<bool>("--final") { Description = "The session's end: wait for the observer to end its capture (at most --wait-seconds), and mark the documents final." };
        var wait = new Option<int>("--wait-seconds") { Description = "With --final, how long to wait for the observer to end its capture (0 to 300).", DefaultValueFactory = _ => 60 };
        var endCapture = new Option<bool>("--end-capture") { Description = "A session's stop, which stops nothing on the VM: first record the capture's end, under the store's lock, so the observer lane of 'profile run' ends its capture within a second, as a profile's end does, while the workload runs on until the VM stops; only a profile set after it is captured again. Implies --final, whose wait then sees the capture end." };
        var exportStore = RcaStoreOption();
        export.Options.Add(session);
        export.Options.Add(final);
        export.Options.Add(wait);
        export.Options.Add(endCapture);
        export.Options.Add(exportStore);
        export.SetAction((parseResult, cancellationToken) =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            var output = parseResult.InvocationConfiguration.Output;
            var text = parseResult.GetValue(session)!.Trim();
            if (!string.Equals(text, "none", StringComparison.Ordinal) && !SessionIdPattern().IsMatch(text))
            {
                output.WriteLine(new ExportResult([], "Fail", "--session must be the control session's ID (32 lowercase hex) or none.").IndexLine());
                return Task.FromResult(ExitCodes.Failure);
            }

            try
            {
                var store = new EvidenceStore(parseResult.GetValue(exportStore) ?? EvidenceStore.DefaultRoot, TimeProvider.System, secure: parseResult.GetValue(exportStore) is null);

                // Every export seals the spans' new sidecar rows at its commit point; what it prints stays as it was.
                var sidecar = new SidecarRuntime(store, Program.GetVersion(), log);
                var result = new Exporter(store, log, Program.GetVersion(), () => sidecar.Sealer.SealAll()).Export(text == "none" ? null : text, parseResult.GetValue(final), TimeSpan.FromSeconds(Math.Clamp(parseResult.GetValue(wait), 0, 300)), parseResult.GetValue(endCapture));
                output.WriteLine(result.IndexLine());
                return Task.FromResult(result.Status == "Fail" ? ExitCodes.Failure : result.Documents.Count > 0 ? ExitCodes.Success : ExitCodes.ManualActionRequired);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or InvalidDataException)
            {
                log.Error("rca.export-failed", "The RCA export failed.", ("error", ex.Message));
                output.WriteLine(new ExportResult([], "Fail", Redactor.Redact("The RCA export failed: " + ex.Message)).IndexLine());
                return Task.FromResult(ExitCodes.Failure);
            }
        });

        var part = new Command("part", "Print one part line of an exported document: DBHUBDEMO-RCA 1 <documentId> <index>/<count> <sha256> <base64>, or, for a sidecar (an ID that ends in -sidecar), DBHUBDEMO-RCAS 1 and the same fields. Exit code 0, or 1 when the document or part doesn't exist.");
        var document = new Option<string>("--document") { Description = "The document's ID, from the index 'rca export' or 'rca sidecar-export' printed.", Required = true };
        var index = new Option<int>("--part") { Description = "The part's index, from 1.", Required = true };
        var partStore = RcaStoreOption();
        part.Options.Add(document);
        part.Options.Add(index);
        part.Options.Add(partStore);
        part.SetAction(parseResult =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            var store = new EvidenceStore(parseResult.GetValue(partStore) ?? EvidenceStore.DefaultRoot, TimeProvider.System, secure: parseResult.GetValue(partStore) is null);
            var documentId = parseResult.GetValue(document)!.Trim();
            var sidecar = SidecarParts.IsSidecarId(documentId);
            var line = sidecar
                ? SidecarParts.Part(new SidecarRuntime(store, Program.GetVersion(), log).Store, documentId, parseResult.GetValue(index))
                : new Exporter(store, log, Program.GetVersion()).Part(documentId, parseResult.GetValue(index));
            if (line is null)
            {
                parseResult.InvocationConfiguration.Error.WriteLine(Redactor.Redact(sidecar
                    ? $"No part {parseResult.GetValue(index)} of sidecar '{documentId}' is in the RCA store (a sidecar is kept until a save acknowledges it, or 30 days after its sealing)."
                    : $"No part {parseResult.GetValue(index)} of document '{parseResult.GetValue(document)}' is in the RCA store (documents are kept 7 days after their export)."));
                return ExitCodes.Failure;
            }

            parseResult.InvocationConfiguration.Output.WriteLine(line);
            return ExitCodes.Success;
        });

        var sidecarExport = new Command("sidecar-export", "Seal Query Store's evidence that the observer captured since the previous sealing into sidecars, one a span, and print one page of the sidecars to fetch, new and pending: one line, DBHUBDEMO-RCAS-INDEX <json>. Exit code 0; 2 when no sidecar is new or pending, with the line printed too, and its status standing (a Warning counts sidecars that expired unread); 1 when the export failed.");
        var sidecarSession = new Option<string>("--session") { Description = "The control session's ID (32 lowercase hex, the resource group's DbHubSessionId), or none outside a control session. A span no export has bound yet takes it, as 'rca export' binds one.", Required = true };
        var sidecarFinal = new Option<bool>("--final") { Description = "The session's end: first wait up to 60 seconds for the observer to end its capture, so its last Query Store reads are in." };
        var sidecarPage = new Option<int>("--page") { Description = "The page of the index to print, from 1: 8 sidecars a page, the oldest sealed first.", DefaultValueFactory = _ => 1 };
        var sidecarStore = RcaStoreOption();
        sidecarExport.Options.Add(sidecarSession);
        sidecarExport.Options.Add(sidecarFinal);
        sidecarExport.Options.Add(sidecarPage);
        sidecarExport.Options.Add(sidecarStore);
        sidecarExport.SetAction(parseResult =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            var output = parseResult.InvocationConfiguration.Output;
            var page = parseResult.GetValue(sidecarPage);
            var text = parseResult.GetValue(sidecarSession)!.Trim();
            SidecarIndexPage result;
            if (!string.Equals(text, "none", StringComparison.Ordinal) && !SessionIdPattern().IsMatch(text))
            {
                result = SidecarIndex.Failed(page, "--session must be the control session's ID (32 lowercase hex) or none.");
            }
            else if (page < 1)
            {
                result = SidecarIndex.Failed(1, "--page must be 1 or more.");
            }
            else
            {
                try
                {
                    var store = new EvidenceStore(parseResult.GetValue(sidecarStore) ?? EvidenceStore.DefaultRoot, TimeProvider.System, secure: parseResult.GetValue(sidecarStore) is null);
                    result = SidecarCommands.Export(new SidecarRuntime(store, Program.GetVersion(), log), text == "none" ? null : text, parseResult.GetValue(sidecarFinal), TimeSpan.FromSeconds(60), page);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    // Any failure is exit code 1 with a Fail line, never 2's nothing to fetch.
                    log.Error("rca.sidecar-export-failed", "The RCA sidecar export failed.", ("error", Redactor.Redact(ex.GetType().Name + ": " + ex.Message)));
                    result = SidecarIndex.Failed(page, "The sidecar export failed: " + ex.Message);
                }
            }

            output.WriteLine(result.Line());
            return result.ExitCode;
        });

        var ack = new Command("ack", "Mark sidecars as written into the history, so the runner offers them no more and deletes them, and print one result line. Exit code 0, also for an ID this runner no longer holds (acknowledged and deleted, or expired), which the line names; 1 when nothing could be acknowledged.");
        var ackDocuments = new Option<string>("--document") { Description = "The sidecars' IDs, comma-separated, as 'rca sidecar-export' listed them.", Required = true };
        var ackStore = RcaStoreOption();
        ack.Options.Add(ackDocuments);
        ack.Options.Add(ackStore);
        ack.SetAction(parseResult =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            var output = parseResult.InvocationConfiguration.Output;
            try
            {
                var store = new EvidenceStore(parseResult.GetValue(ackStore) ?? EvidenceStore.DefaultRoot, TimeProvider.System, secure: parseResult.GetValue(ackStore) is null);
                var (exitCode, line) = SidecarCommands.Acknowledge(new SidecarRuntime(store, Program.GetVersion(), log), parseResult.GetValue(ackDocuments)!);
                output.WriteLine(line);
                return exitCode;
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                log.Error("rca.ack-failed", "The RCA sidecars' acknowledgement failed.", ("error", Redactor.Redact(ex.GetType().Name + ": " + ex.Message)));
                output.WriteLine(SidecarCommands.Failed(ex.Message));
                return ExitCodes.Failure;
            }
        });

        command.Subcommands.Add(export);
        command.Subcommands.Add(part);
        command.Subcommands.Add(sidecarExport);
        command.Subcommands.Add(ack);
        return command;
    }

    /// <summary>
    /// reset on T1, T2, and T3 drops the observer's event session (ADR 0010's amendment): RCA-XE-05, or its
    /// database-scoped form on T3. An identity that can't see event sessions could never have created one: Not supported.
    /// </summary>
    private static async Task<CheckRecord> DropObserverSessionAsync(SqlConnection connection, DemoTarget target, CancellationToken cancellationToken)
    {
        try
        {
            await using var command = connection.CreateCommand();
            command.CommandType = CommandType.Text;
#pragma warning disable CA2100 // RCA-XE-05 from the runner's embedded capture catalog (rca/capture), never user input.
            command.CommandText = target == DemoTarget.T3 ? CaptureCatalog.DatabaseScopedDrop() : CaptureCatalog.Get("RCA-XE-05");
#pragma warning restore CA2100
            command.CommandTimeout = 60;
            await command.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
            return new CheckRecord("rca-session-dropped", "Pass", $"The RCA observer's event session ContosoCare_RCA isn't on {target}: dropped, or there was none.");
        }
        catch (SqlException ex) when (ex.Number is 297 or 300 or 262 or 229 or 230 or 15151 or 15247)
        {
            return new CheckRecord("rca-session-dropped", "Not supported", Redactor.Redact($"The runner's identity can't see or change event sessions on {target} (SQL error {ex.Number}), so the RCA observer couldn't have created one there."));
        }
        catch (SqlException ex)
        {
            return new CheckRecord("rca-session-dropped", "Warning", Redactor.Redact($"Couldn't drop the RCA observer's event session ContosoCare_RCA on {target} (SQL error {ex.Number}: {ex.Message}); the observer's next start drops it."));
        }
    }

    [GeneratedRegex("^[0-9a-f]{32}$")]
    private static partial Regex SessionIdPattern();

    /// <summary>The targets the observer lane of 'profile run' captures, and how the answer key reads each one's run events.</summary>
    private sealed class ObservedTargets
    {
        private readonly List<Func<RunnerLog, ObserverOptions, SidecarRuntime, IEnumerable<TargetObserver>>> factories = [];

        public List<DemoTarget> Noted { get; } = [];

        public Dictionary<DemoTarget, Func<string, CancellationToken, Task<IReadOnlyList<RunEvent>>>> EventReaders { get; } = [];

        /// <summary>T1, T2, or T3, with the runner's own sign-in; its observer reads Query Store into the sidecar too.</summary>
        public void AddSql(TargetEndpoint endpoint, RunnerLog log)
        {
            factories.Add((l, o, sidecar) => [sidecar.Sql(endpoint.Target.ToString(), endpoint.Target, new SqlCaptureConnector(endpoint, l), o, l)]);
            EventReaders[endpoint.Target] = (run, token) => Rca.AnswerKey.AnswerKeyRecorder.ReadSqlAsync(new SqlConnectionOpener(endpoint, log), run, token);
        }

        /// <summary>T4, and its read replica when the host has one; T4's observer reads Query Store from azure_sys into the sidecar too.</summary>
        public void AddPostgres(PgEndpoint primary, PgEndpoint? replica, RunnerLog log)
        {
            factories.Add((l, o, sidecar) => sidecar.Postgres(new PgCaptureConnector(primary, l), replica is null ? null : new PgCaptureConnector(replica, l), PgCaptureConnector.QueryStore(primary, l), o, l));
            EventReaders[DemoTarget.T4] = (run, token) => Rca.AnswerKey.AnswerKeyRecorder.ReadPgAsync(new PgConnectionOpener(primary, log), run, token);
        }

        /// <summary>T5, which has no observer: its coverage says where its evidence is.</summary>
        public void Note(DemoTarget target)
        {
            if (!Noted.Contains(target))
            {
                Noted.Add(target);
            }
        }

        public List<TargetObserver> Observers(RunnerLog log, ObserverOptions options, SidecarRuntime sidecar) => [.. factories.SelectMany(f => f(log, options, sidecar))];
    }

    /// <summary>
    /// Runs the profile host with the observer lane beside it (ADR 0031), unless --no-rca: the lane captures each target
    /// while the host says it's in a session, and ends its capture (the event session dropped) when the host stops. The
    /// sidecar seals what an earlier run left unsealed as the lane starts, and each span once it closes.
    /// </summary>
    private static async Task RunHostAsync(ProfileHostOptions options, IReadOnlyList<ProfileTarget> targets, DateTimeOffset? limit, ObservedTargets observed, string? storePath, bool noRca, RunnerLog log, CancellationToken cancellationToken)
    {
        if (noRca)
        {
            log.Info("rca.lane-off", "The RCA observer lane is off (--no-rca).");
            await new ProfileHost(ActivityProfilesDefinition.Default, ScenarioCatalog.Default, log, TimeProvider.System, options).RunAsync(targets, limit, cancellationToken).ConfigureAwait(false);
            return;
        }

        var store = new EvidenceStore(storePath ?? EvidenceStore.DefaultRoot, TimeProvider.System, secure: storePath is null);
        var sidecar = new SidecarRuntime(store, Program.GetVersion(), log);
        var recorder = new Rca.AnswerKey.AnswerKeyRecorder(store, observed.EventReaders, log);
        var host = new ProfileHost(ActivityProfilesDefinition.Default, ScenarioCatalog.Default, log, TimeProvider.System, options, answerKey: recorder);
        var observerOptions = new ObserverOptions();
        var lane = new ObserverLane(observed.Observers(log, observerOptions, sidecar), observed.Noted, host, store, log, TimeProvider.System, observerOptions);
        sidecar.Start();
        using var observing = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var laneTask = Task.Run(() => lane.RunAsync(observing.Token), CancellationToken.None);
        try
        {
            await host.RunAsync(targets, limit, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            await observing.CancelAsync().ConfigureAwait(false);
            try
            {
                await laneTask.WaitAsync(observerOptions.EndTimeout + TimeSpan.FromSeconds(15), CancellationToken.None).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                log.Warn("rca.lane-stop-timeout", "The RCA observer lane didn't end its capture in time; the next start drops what it left.");
            }

            // The last span's sealing, which its close queued; what doesn't finish waits for the next sealing.
            await sidecar.StopAsync(TimeSpan.FromSeconds(30)).ConfigureAwait(false);
        }
    }
}
