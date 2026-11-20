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
using ContosoCare.Workload.Rca.Store;
using ContosoCare.Workload.Sql;
using Microsoft.Data.SqlClient;

namespace ContosoCare.Workload.Cli;

/// <summary>
/// The Incident RCA's commands (ADR 0031, rca/README.md): <c>rca export</c> reduces what the observer captured into
/// evidence documents and prints their index on one line; <c>rca part</c> prints one part line of one document. Each
/// prints one line, under a managed Run Command's 4 KB.
/// </summary>
internal static partial class CommandLine
{
    private static Option<string?> RcaStoreOption() => new("--rca-store") { Description = "The Incident RCA observer's evidence store (ADR 0031). Defaults to C:\\ProgramData\\DbHubDemo\\rca (or /var/lib/DbHubDemo/rca), which only SYSTEM and Administrators can read." };

    private static Command RcaCommand()
    {
        var command = new Command("rca", "The Incident RCA evidence (ADR 0031): export what the observer lane of 'profile run' captured, and print its parts.");

        var export = new Command("export", "Reduce what the RCA observer captured since the previous export into evidence documents, and print their index: one line, DBHUBDEMO-RCA-INDEX <json>. Exit code 0, 2 when there's nothing to export, 1 when the export failed.");
        var session = new Option<string>("--session") { Description = "The control session's ID (32 lowercase hex, the resource group's DbHubSessionId), or none outside a control session.", Required = true };
        var final = new Option<bool>("--final") { Description = "The session's end: wait for the observer to end its capture (at most --wait-seconds), and mark the documents final." };
        var wait = new Option<int>("--wait-seconds") { Description = "With --final, how long to wait for the observer to end its capture (0 to 300).", DefaultValueFactory = _ => 60 };
        var exportStore = RcaStoreOption();
        export.Options.Add(session);
        export.Options.Add(final);
        export.Options.Add(wait);
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
                var result = new Exporter(store, log, Program.GetVersion()).Export(text == "none" ? null : text, parseResult.GetValue(final), TimeSpan.FromSeconds(Math.Clamp(parseResult.GetValue(wait), 0, 300)));
                output.WriteLine(result.IndexLine());
                return Task.FromResult(result.Documents.Count > 0 ? ExitCodes.Success : ExitCodes.ManualActionRequired);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or InvalidDataException)
            {
                log.Error("rca.export-failed", "The RCA export failed.", ("error", ex.Message));
                output.WriteLine(new ExportResult([], "Fail", Redactor.Redact("The RCA export failed: " + ex.Message)).IndexLine());
                return Task.FromResult(ExitCodes.Failure);
            }
        });

        var part = new Command("part", "Print one part line of an exported document: DBHUBDEMO-RCA 1 <documentId> <index>/<count> <sha256> <base64>. Exit code 0, or 1 when the document or part doesn't exist.");
        var document = new Option<string>("--document") { Description = "The document's ID, from the index 'rca export' printed.", Required = true };
        var index = new Option<int>("--part") { Description = "The part's index, from 1.", Required = true };
        var partStore = RcaStoreOption();
        part.Options.Add(document);
        part.Options.Add(index);
        part.Options.Add(partStore);
        part.SetAction(parseResult =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            var store = new EvidenceStore(parseResult.GetValue(partStore) ?? EvidenceStore.DefaultRoot, TimeProvider.System, secure: parseResult.GetValue(partStore) is null);
            var line = new Exporter(store, log, Program.GetVersion()).Part(parseResult.GetValue(document)!.Trim(), parseResult.GetValue(index));
            if (line is null)
            {
                parseResult.InvocationConfiguration.Error.WriteLine(Redactor.Redact($"No part {parseResult.GetValue(index)} of document '{parseResult.GetValue(document)}' is in the RCA store (documents are kept 7 days after their export)."));
                return ExitCodes.Failure;
            }

            parseResult.InvocationConfiguration.Output.WriteLine(line);
            return ExitCodes.Success;
        });

        command.Subcommands.Add(export);
        command.Subcommands.Add(part);
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
        private readonly List<Func<RunnerLog, ObserverOptions, IEnumerable<TargetObserver>>> factories = [];

        public List<DemoTarget> Noted { get; } = [];

        public Dictionary<DemoTarget, Func<string, CancellationToken, Task<IReadOnlyList<RunEvent>>>> EventReaders { get; } = [];

        /// <summary>T1, T2, or T3, with the runner's own sign-in.</summary>
        public void AddSql(TargetEndpoint endpoint, RunnerLog log)
        {
            factories.Add((l, o) => [new SqlTargetObserver(endpoint.Target.ToString(), endpoint.Target, new SqlCaptureConnector(endpoint, l), o, l)]);
            EventReaders[endpoint.Target] = (run, token) => Rca.AnswerKey.AnswerKeyRecorder.ReadSqlAsync(new SqlConnectionOpener(endpoint, log), run, token);
        }

        /// <summary>T4, and its read replica when the host has one.</summary>
        public void AddPostgres(PgEndpoint primary, PgEndpoint? replica, RunnerLog log)
        {
            factories.Add((l, o) =>
            {
                var link = new ReplicaLink();
                var observers = new List<TargetObserver> { new PgPrimaryObserver(new PgCaptureConnector(primary, l), o, l, link) };
                if (replica is not null)
                {
                    observers.Add(new PgReplicaObserver(new PgCaptureConnector(replica, l), o, l, link));
                }

                return observers;
            });
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

        public List<TargetObserver> Observers(RunnerLog log, ObserverOptions options) => [.. factories.SelectMany(f => f(log, options))];
    }

    /// <summary>
    /// Runs the profile host with the observer lane beside it (ADR 0031), unless --no-rca: the lane captures each target
    /// while the host says it's in a session, and ends its capture (the event session dropped) when the host stops.
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
        var recorder = new Rca.AnswerKey.AnswerKeyRecorder(store, observed.EventReaders, log);
        var host = new ProfileHost(ActivityProfilesDefinition.Default, ScenarioCatalog.Default, log, TimeProvider.System, options, answerKey: recorder);
        var observerOptions = new ObserverOptions();
        var lane = new ObserverLane(observed.Observers(log, observerOptions), observed.Noted, host, store, log, TimeProvider.System, observerOptions);
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
        }
    }
}
