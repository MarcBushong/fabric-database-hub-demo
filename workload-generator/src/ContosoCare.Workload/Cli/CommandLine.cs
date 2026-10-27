using System.CommandLine;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Postgres;
using ContosoCare.Workload.Profiles;
using ContosoCare.Workload.Runs;
using ContosoCare.Workload.Sql;
using Microsoft.Data.SqlClient;

namespace ContosoCare.Workload.Cli;

/// <summary>Exit codes: 0 when every check passed (warnings included), 1 for a failure, 2 when a manual action is required.</summary>
internal static class ExitCodes
{
    public const int Success = 0;
    public const int Failure = 1;
    public const int ManualActionRequired = 2;

    public static int FromStatuses(IEnumerable<string> statuses)
    {
        var all = statuses.ToList();
        return all.Contains("Fail") ? Failure : all.Contains("Manual action required") ? ManualActionRequired : Success;
    }
}

/// <summary>The command line (System.CommandLine 2.0). Each command is a thin layer over the catalog, the runner, and the demo procedures.</summary>
internal static partial class CommandLine
{
    public static readonly string[] Statuses = ["Pass", "Fail", "Warning", "Manual action required", "Not supported", "Not selected"];

    private static readonly JsonSerializerOptions OutputOptions = new() { WriteIndented = true };

    public static RootCommand Build()
    {
        var root = new RootCommand("Contoso Care Operations workload runner for the Fabric Database Hub hybrid SQL demo (ADR 0010). Every session it opens is tagged ContosoCare.Demo/<scenario>/<run> and works only in the ContosoCare database.");
        root.Options.Add(GlobalOptions.LogFormat);
        root.Options.Add(GlobalOptions.LogFile);
        root.Options.Add(GlobalOptions.Verbose);

        root.Subcommands.Add(VersionCommand());
        root.Subcommands.Add(ScenariosCommand());
        root.Subcommands.Add(RunCommand());
        root.Subcommands.Add(StopCommand());
        root.Subcommands.Add(ResetCommand());
        root.Subcommands.Add(StatusCommand());
        root.Subcommands.Add(ProfileCommand());
        root.Subcommands.Add(WarmupCommand());
        root.Subcommands.Add(SetupCommand());
        return root;
    }

    private static Command VersionCommand()
    {
        var command = new Command("version", "Print the runner version.");
        command.SetAction(parseResult =>
        {
            parseResult.InvocationConfiguration.Output.WriteLine(Program.GetVersion());
            return ExitCodes.Success;
        });
        return command;
    }

    private static Command ScenariosCommand()
    {
        var command = new Command("scenarios", "List the scenario catalog, or show one scenario's limits, parameters, and expected signals.");
        var id = new Argument<string?>("scenario") { Description = "A scenario ID to show in full.", Arity = ArgumentArity.ZeroOrOne };
        var json = Json();
        command.Arguments.Add(id);
        command.Options.Add(json);
        command.SetAction(parseResult =>
        {
            var output = parseResult.InvocationConfiguration.Output;
            var catalog = ScenarioCatalog.Default;
            var wanted = parseResult.GetValue(id);
            try
            {
                var scenarios = wanted is null ? catalog.All : [catalog.Get(wanted)];
                if (parseResult.GetValue(json))
                {
                    var array = new JsonArray();
                    foreach (var scenario in scenarios)
                    {
                        array.Add(JsonNode.Parse(JsonSerializer.Serialize(scenario, CatalogJsonContext.Default.ScenarioDefinition)));
                    }

                    output.WriteLine(array.ToJsonString(OutputOptions));
                    return ExitCodes.Success;
                }

                foreach (var scenario in scenarios)
                {
                    output.WriteLine(string.Create(
                        CultureInfo.InvariantCulture,
                        $"{scenario.Id,-20} {scenario.Duration.DefaultSeconds,5} s default, {scenario.Duration.MaxSeconds,5} s max, concurrency {scenario.Concurrency.Default} ({scenario.Concurrency.Min}-{scenario.Concurrency.Max}), default targets {string.Join("/", scenario.Targets.Default)}. {scenario.Title}"));
                    if (wanted is not null)
                    {
                        output.WriteLine("  " + scenario.Summary);
                        foreach (var (name, parameter) in scenario.Parameters.OrderBy(p => p.Key, StringComparer.Ordinal))
                        {
                            output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"  --param {name}=<{parameter.Type}> (default {(parameter.Default.ValueKind == JsonValueKind.String ? parameter.Default.GetString() : parameter.Default.GetRawText())}): {parameter.Description}"));
                        }

                        foreach (var signal in scenario.ExpectedHubSignals)
                        {
                            output.WriteLine($"  Hub signal: {signal.Signal} ({signal.Surface})");
                        }

                        foreach (var symptom in scenario.ExpectedSymptoms)
                        {
                            output.WriteLine($"  Symptom: {symptom}");
                        }
                    }
                }

                return ExitCodes.Success;
            }
            catch (ScenarioRequestException ex)
            {
                parseResult.InvocationConfiguration.Error.WriteLine(ex.Message);
                return ExitCodes.Failure;
            }
        });
        return command;
    }

    private static Command RunCommand()
    {
        var command = new Command("run", "Run one bounded scenario on a target and wait for it to end (Ctrl+C stops it cleanly).");
        var target = new TargetOptions(command);
        var scenario = new Option<string>("--scenario", "-s") { Description = "The scenario ID (see 'scenarios').", Required = true };
        var run = new RunOptions(command);
        var json = Json();
        command.Options.Add(scenario);
        command.Options.Add(json);
        command.SetAction(async (parseResult, cancellationToken) =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            return await Guard(parseResult, log, async () =>
            {
                var endpointTarget = target.TargetOf(parseResult);
                var definition = ScenarioCatalog.Default.Get(parseResult.GetRequiredValue(scenario));
                var request = run.ToRequest(parseResult, definition.Id, endpointTarget);
                var plan = RunBounds.Plan(definition, request, DateTimeOffset.UtcNow);
                IScenarioExecutor runner = endpointTarget == DemoTarget.T4
                    ? new PgScenarioRunner(new PgConnectionOpener(target.ResolvePostgres(parseResult), log), log, TimeProvider.System)
                    : new ScenarioRunner(new SqlConnectionOpener(target.Resolve(parseResult), log), log, TimeProvider.System);
                var result = await runner.RunAsync(plan, cancellationToken).ConfigureAwait(false);
                WriteRunResult(parseResult, result, parseResult.GetValue(json));
                return result.Result == "Fail" ? ExitCodes.Failure : ExitCodes.Success;
            }).ConfigureAwait(false);
        });
        return command;
    }

    private static Command StopCommand()
    {
        var command = new Command("stop", "Stop one run, every run of a scenario, or everything on a target (--all also sets the activity profile to off).");
        var target = new TargetOptions(command);
        var runId = new Option<string?>("--run-id") { Description = "Stop this run." };
        var scenario = new Option<string?>("--scenario", "-s") { Description = "Stop every run of this scenario." };
        var all = new Option<bool>("--all") { Description = "Stop every run and set the activity profile to off." };
        var profileFile = ProfileFile();
        var requestedBy = RequestedBy();
        var json = Json();
        command.Options.Add(runId);
        command.Options.Add(scenario);
        command.Options.Add(all);
        command.Options.Add(profileFile);
        command.Options.Add(requestedBy);
        command.Options.Add(json);
        command.SetAction(async (parseResult, cancellationToken) =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            return await Guard(parseResult, log, async () =>
            {
                var targetValue = target.TargetOf(parseResult);
                var chosen = new[] { parseResult.GetValue(runId) is not null, parseResult.GetValue(scenario) is not null, parseResult.GetValue(all) }.Count(c => c);
                if (chosen != 1)
                {
                    throw new ScenarioRequestException("Choose exactly one of --run-id, --scenario, or --all.");
                }

                var who = parseResult.GetValue(requestedBy)!;
                var scope = parseResult.GetValue(all) ? "all" : parseResult.GetValue(runId) is not null ? "run" : "scenario";
                var scenarioId = parseResult.GetValue(scenario);
                if (scenarioId is not null)
                {
                    ScenarioCatalog.Default.Get(scenarioId);
                }

                var id = parseResult.GetValue(runId);
                if (id is not null && !SessionNames.IsValidRunId(id))
                {
                    throw new ScenarioRequestException("--run-id must be a run ID such as 20261020173000-t1-a1b2c3.");
                }

                if (scope == "all" && targetValue is DemoTarget.T3 or DemoTarget.T4)
                {
                    await new FileProfileStore(parseResult.GetValue(profileFile) ?? FileProfileStore.DefaultPathFor(targetValue)).SetAsync("off", who, null, null, cancellationToken).ConfigureAwait(false);
                }

                int cancelled;
                if (targetValue == DemoTarget.T4)
                {
                    await using var pgConnection = await new PgConnectionOpener(target.ResolvePostgres(parseResult), log).OpenAsync(SessionNames.ForControl("stop"), cancellationToken).ConfigureAwait(false);
                    cancelled = await new PgDemoDatabase(pgConnection).StopAsync(scope, id, scenarioId, who, cancellationToken).ConfigureAwait(false);
                }
                else
                {
                    var opener = new SqlConnectionOpener(target.Resolve(parseResult), log);
                    await using var connection = await opener.OpenAsync(SessionNames.ForControl("stop"), cancellationToken).ConfigureAwait(false);
                    cancelled = await new DemoDatabase(connection).StopAsync(scope, id, scenarioId, who, setProfileOff: scope == "all", cancellationToken).ConfigureAwait(false);
                }

                log.Info("stop.requested", "Stop requested.", ("target", targetValue), ("scope", scope), ("runsCancelled", cancelled));
                var check = new CheckRecord("stop", "Pass", string.Create(CultureInfo.InvariantCulture, $"Stop requested ({scope}); {cancelled} Running run(s) marked Cancelled. Their sessions end within a few seconds.{(scope == "all" ? " The activity profile is off." : string.Empty)}"));
                WriteChecks(parseResult, targetValue, "stop", [check], parseResult.GetValue(json));
                return ExitCodes.Success;
            }).ConfigureAwait(false);
        });
        return command;
    }

    private static Command ResetCommand()
    {
        var command = new Command("reset", "Return a target to a known, quiet state: stop everything, wait, kill leftover ContosoCare.Demo/ sessions, verify no demo transaction is open, and empty the scratch tables.");
        var target = new TargetOptions(command);
        var wait = new Option<int>("--wait-seconds") { Description = "How long to wait for sessions to end before killing them (0 to 300).", DefaultValueFactory = _ => 30 };
        var noKill = new Option<bool>("--no-kill") { Description = "Don't kill leftover demo sessions; only report them." };
        var keepProfile = new Option<bool>("--keep-profile") { Description = "Keep the activity profile (by default reset sets it to off)." };
        var undo = new Option<bool>("--undo-remediation") { Description = "Drop the missing-index remediation indexes, so that scenario starts again from 'before'. Needs an administrator." };
        var reseed = new Option<bool>("--reseed") { Description = "Reseed the business data with the recorded seed and scale. Needs an administrator." };
        var profileFile = ProfileFile();
        var requestedBy = RequestedBy();
        var json = Json();
        foreach (var option in new Option[] { wait, noKill, keepProfile, undo, reseed, profileFile, requestedBy, json })
        {
            command.Options.Add(option);
        }

        command.SetAction(async (parseResult, cancellationToken) =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            return await Guard(parseResult, log, async () =>
            {
                var targetValue = target.TargetOf(parseResult);
                var who = parseResult.GetValue(requestedBy)!;
                var seconds = Math.Clamp(parseResult.GetValue(wait), 0, 300);
                var checks = new List<CheckRecord>();
                if (targetValue is DemoTarget.T3 or DemoTarget.T4 && !parseResult.GetValue(keepProfile))
                {
                    await new FileProfileStore(parseResult.GetValue(profileFile) ?? FileProfileStore.DefaultPathFor(targetValue)).SetAsync("off", who, null, null, cancellationToken).ConfigureAwait(false);
                    checks.Add(new CheckRecord("profile-file-off", "Pass", targetValue == DemoTarget.T3
                        ? "The T3 activity profile file is set to off, so the runner stops connecting and T3 can auto-pause."
                        : "The T4 activity profile file is set to off, so the runner stops connecting to T4."));
                }

                var options = new ResetOptions(who, seconds, !parseResult.GetValue(noKill), parseResult.GetValue(keepProfile), parseResult.GetValue(undo), parseResult.GetValue(reseed));
                if (targetValue == DemoTarget.T4)
                {
                    checks.AddRange(await new PgScenarioRunner(new PgConnectionOpener(target.ResolvePostgres(parseResult), log), log, TimeProvider.System).ResetAsync(options, cancellationToken).ConfigureAwait(false));
                }
                else
                {
                    var opener = new SqlConnectionOpener(target.Resolve(parseResult), log);
                    await using var connection = await opener.OpenAsync(SessionNames.ForControl("reset"), cancellationToken).ConfigureAwait(false);
                    checks.AddRange(await new DemoDatabase(connection).ResetAsync(options, cancellationToken).ConfigureAwait(false));
                }

                foreach (var check in checks)
                {
                    log.Info("reset.check", check.Message, ("target", targetValue), ("check", check.CheckId), ("status", check.Status));
                }

                WriteChecks(parseResult, targetValue, "reset", checks, parseResult.GetValue(json));
                return ExitCodes.FromStatuses(checks.Select(c => c.Status));
            }).ConfigureAwait(false);
        });
        return command;
    }

    private static Command StatusCommand()
    {
        var command = new Command("status", "Show a target's activity profile, its profile host lane, running and recent runs, stop requests, live demo sessions, and space headroom.");
        var target = new TargetOptions(command);
        var count = new Option<int>("--runs") { Description = "How many recent runs to show.", DefaultValueFactory = _ => 10 };
        var profileFile = ProfileFile();
        var hostFile = HostStateFile();
        var json = Json();
        command.Options.Add(count);
        command.Options.Add(profileFile);
        command.Options.Add(hostFile);
        command.Options.Add(json);
        command.SetAction(async (parseResult, cancellationToken) =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            return await Guard(parseResult, log, async () =>
            {
                if (target.TargetOf(parseResult) == DemoTarget.T4)
                {
                    return await StatusT4Async(parseResult, target.ResolvePostgres(parseResult), Math.Clamp(parseResult.GetValue(count), 1, 100), parseResult.GetValue(profileFile), parseResult.GetValue(hostFile), parseResult.GetValue(json), log, cancellationToken).ConfigureAwait(false);
                }

                var endpoint = target.Resolve(parseResult);
                var opener = new SqlConnectionOpener(endpoint, log);
                await using var connection = await opener.OpenAsync(SessionNames.ForControl("status"), cancellationToken).ConfigureAwait(false);
                var database = new DemoDatabase(connection);
                var profile = endpoint.Target == DemoTarget.T3
                    ? await new FileProfileStore(parseResult.GetValue(profileFile) ?? FileProfileStore.DefaultPath).GetAsync(cancellationToken).ConfigureAwait(false)
                    : await database.GetProfileAsync(cancellationToken).ConfigureAwait(false);
                var runs = await database.GetRunsAsync(Math.Clamp(parseResult.GetValue(count), 1, 100), runningOnly: false, cancellationToken).ConfigureAwait(false);
                var flags = await database.GetStopFlagsAsync(cancellationToken).ConfigureAwait(false);
                var sessions = await database.GetDemoSessionsAsync(null, cancellationToken).ConfigureAwait(false);
                var space = await database.GetSpaceAsync(cancellationToken).ConfigureAwait(false);
                var now = DateTimeOffset.UtcNow;
                var host = HostLaneStatus.ForThisMachine(parseResult.GetValue(hostFile) ?? HostLanesFile.DefaultPath, endpoint.Target, ProfileHost.IsActive(profile, now, ActivityProfilesDefinition.Default, ScenarioCatalog.Default));
                var output = parseResult.InvocationConfiguration.Output;
                if (parseResult.GetValue(json))
                {
                    var document = new JsonObject
                    {
                        ["target"] = endpoint.Target.ToString(),
                        ["profile"] = new JsonObject
                        {
                            ["name"] = profile.Name,
                            ["setAt"] = DemoDatabase.Format(profile.SetAt),
                            ["setBy"] = profile.SetBy,
                            ["expiresAt"] = profile.ExpiresAt is { } expires ? DemoDatabase.Format(expires) : null,
                            ["description"] = ProfileHost.Describe(profile, now, ActivityProfilesDefinition.Default, ScenarioCatalog.Default),
                        },
                        ["runs"] = new JsonArray([.. runs.Select(RunNode)]),
                        ["stopRequests"] = new JsonArray([.. flags.Select(f => (JsonNode)new JsonObject { ["scenario"] = f.ScenarioId, ["requestedAt"] = f.RequestedAt is { } at ? DemoDatabase.Format(at) : null, ["requestedBy"] = f.RequestedBy })]),
                        ["demoSessions"] = sessions is null ? null : new JsonArray([.. sessions.Select(s => (JsonNode)new JsonObject { ["sessionId"] = s.SessionId, ["applicationName"] = s.ProgramName, ["status"] = s.Status, ["openTransactions"] = s.OpenTransactions, ["blockedBy"] = s.BlockingSessionId, ["waitType"] = s.WaitType })]),
                        ["dataHeadroomMb"] = space.DataHeadroomMb,
                        ["logHeadroomMb"] = space.LogHeadroomMb,

                        // Last, so the tail of the output that a Run Command keeps still holds it (validation's WORKLOAD.<target>.HOST).
                        ["host"] = host.ToNode(),
                    };
                    output.WriteLine(document.ToJsonString(OutputOptions));
                    return ExitCodes.Success;
                }

                output.WriteLine($"Target:   {endpoint.Describe()}");
                output.WriteLine($"Profile:  {ProfileHost.Describe(profile, now, ActivityProfilesDefinition.Default, ScenarioCatalog.Default)}");
                output.WriteLine($"Host:     [{host.Status}] {host.Message}");
                output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"Headroom: data {space.DataHeadroomMb?.ToString(CultureInfo.InvariantCulture) ?? "uncapped"} MB, log {space.LogHeadroomMb?.ToString(CultureInfo.InvariantCulture) ?? "managed or uncapped"} MB"));
                output.WriteLine(sessions is null ? "Sessions: not visible (needs VIEW SERVER STATE or VIEW DATABASE STATE)" : string.Create(CultureInfo.InvariantCulture, $"Sessions: {sessions.Count} live demo session(s), {sessions.Count(s => s.OpenTransactions > 0)} with an open transaction, {sessions.Count(s => s.BlockingSessionId is > 0)} blocked"));
                foreach (var flag in flags)
                {
                    output.WriteLine($"Stop:     {flag.ScenarioId} requested at {(flag.RequestedAt is { } at ? DemoDatabase.Format(at) : "?")} by {flag.RequestedBy}");
                }

                output.WriteLine("Runs:");
                foreach (var record in runs)
                {
                    output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"  {record.RunId,-28} {record.ScenarioId,-20} {record.Status,-9} started {DemoDatabase.Format(record.StartedAt)} deadline {DemoDatabase.Format(record.DeadlineAt)}{(record.ProfileName is null ? string.Empty : " profile " + record.ProfileName)}"));
                }

                return ExitCodes.Success;
            }).ConfigureAwait(false);
        });
        return command;
    }

    private static Command ProfileCommand()
    {
        var command = new Command("profile", "Get, set, or host the activity profile: off, baseline, business-day, or incident:<scenario>.");

        var get = new Command("get", "Show the target's activity profile, and with --json its profile host lane.");
        var getTarget = new TargetOptions(get);
        var getFile = ProfileFile();
        var getHostFile = HostStateFile();
        var getJson = Json();
        get.Options.Add(getFile);
        get.Options.Add(getHostFile);
        get.Options.Add(getJson);
        get.SetAction(async (parseResult, cancellationToken) =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            return await Guard(parseResult, log, async () =>
            {
                var targetValue = getTarget.TargetOf(parseResult);
                var store = Store(targetValue, () => getTarget.Resolve(parseResult), parseResult.GetValue(getFile), log);
                var state = await store.GetAsync(cancellationToken).ConfigureAwait(false);
                var now = DateTimeOffset.UtcNow;
                var description = ProfileHost.Describe(state, now, ActivityProfilesDefinition.Default, ScenarioCatalog.Default);
                if (parseResult.GetValue(getJson))
                {
                    var host = HostLaneStatus.ForThisMachine(parseResult.GetValue(getHostFile) ?? HostLanesFile.DefaultPath, targetValue, ProfileHost.IsActive(state, now, ActivityProfilesDefinition.Default, ScenarioCatalog.Default));
                    parseResult.InvocationConfiguration.Output.WriteLine(new JsonObject
                    {
                        ["target"] = targetValue.ToString(),
                        ["store"] = store.Description,
                        ["name"] = state.Name,
                        ["setAt"] = DemoDatabase.Format(state.SetAt),
                        ["setBy"] = state.SetBy,
                        ["expiresAt"] = state.ExpiresAt is { } at ? DemoDatabase.Format(at) : null,
                        ["parameters"] = state.Parameters is null ? null : JsonNode.Parse(ProfileParametersJson.Serialize(state.Parameters)),
                        ["description"] = description,
                        ["host"] = host.ToNode(),
                    }.ToJsonString(OutputOptions));
                }
                else
                {
                    parseResult.InvocationConfiguration.Output.WriteLine($"{targetValue}: {description} [{store.Description}]");
                }

                return ExitCodes.Success;
            }).ConfigureAwait(false);
        });

        var set = new Command("set", "Set the target's activity profile. A running 'profile run' host picks it up within its poll interval.");
        var setTarget = new TargetOptions(set);
        var name = new Option<string>("--name", "-n") { Description = "off, baseline, business-day, or incident:<scenario>.", Required = true };
        var setRun = new RunOptions(set);
        var withBaseline = new Option<bool?>("--with-baseline") { Description = "incident:<scenario> only: run the baseline next to the incident (default true)." };
        var setFile = ProfileFile();
        var setJson = Json();
        set.Options.Add(name);
        set.Options.Add(withBaseline);
        set.Options.Add(setFile);
        set.Options.Add(setJson);
        set.SetAction(async (parseResult, cancellationToken) =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            return await Guard(parseResult, log, async () =>
            {
                var targetValue = setTarget.TargetOf(parseResult);
                var catalog = ScenarioCatalog.Default;
                var profileName = ProfileName.Parse(parseResult.GetRequiredValue(name), catalog);
                var request = setRun.ToRequest(parseResult, profileName.ScenarioId ?? "healthy-baseline", targetValue);
                if (profileName.Kind != ProfileKind.Incident && (request.Parameters.Count > 0 || request.Concurrency is not null || request.Intensity is not null))
                {
                    throw new ScenarioRequestException("--param, --concurrency, and --intensity apply to incident:<scenario> only; baseline and business-day take theirs from scenarios/activity-profiles.json.");
                }

                if (profileName.Kind == ProfileKind.Incident)
                {
                    // Validates the incident's options now, so a bad value fails here instead of in the host.
                    RunBounds.Plan(catalog.Get(profileName.ScenarioId!), request, DateTimeOffset.UtcNow);
                }

                var parameters = profileName.Kind == ProfileKind.Off ? null : new ProfileParameters
                {
                    DurationSeconds = request.Duration is { } duration ? (int)duration.TotalSeconds : null,
                    Concurrency = request.Concurrency,
                    Intensity = request.Intensity,
                    Parameters = request.Parameters.Count > 0 ? new Dictionary<string, string>(request.Parameters, StringComparer.Ordinal) : null,
                    ResetBefore = request.ResetBefore ? true : null,
                    AutoCleanup = request.AutoCleanup ? null : false,
                    WithBaseline = parseResult.GetValue(withBaseline),
                };
                var expiresAt = profileName.Kind == ProfileKind.Off
                    ? (DateTimeOffset?)null
                    : ProfileScheduler.ComputeExpiry(profileName, parameters, DateTimeOffset.UtcNow, request.NotAfter, ActivityProfilesDefinition.Default, catalog);
                if (expiresAt is { } expiry && expiry <= DateTimeOffset.UtcNow)
                {
                    throw new ScenarioRequestException("The profile would expire immediately: --not-after is too close.");
                }

                var store = Store(targetValue, () => setTarget.Resolve(parseResult), parseResult.GetValue(setFile), log);
                await store.SetAsync(profileName.Value, request.RequestedBy, expiresAt, parameters, cancellationToken).ConfigureAwait(false);
                log.Info("profile.set", "Activity profile set.", ("target", targetValue), ("profile", profileName.Value), ("expiresAt", expiresAt), ("store", store.Description));
                var check = new CheckRecord("profile-set", "Pass", string.Create(CultureInfo.InvariantCulture, $"{targetValue} profile set to {profileName.Value}{(expiresAt is { } e ? " until " + DemoDatabase.Format(e) : string.Empty)}. A running 'profile run' host applies it within {ActivityProfilesDefinition.Default.PollSeconds} s."));
                WriteChecks(parseResult, targetValue, "profile", [check], parseResult.GetValue(setJson));
                return ExitCodes.Success;
            }).ConfigureAwait(false);
        });

        var host = new Command("run", "Host activity profiles as a long-running, service-style process until Ctrl+C, SIGTERM, or --not-after.");
        var hostTarget = new TargetOptions(host);
        var t3Server = new Option<string?>("--t3-server") { Description = "Also drive T3 from this machine (T1 only): the logical server name. Its profile lives in --profile-file." };
        var t3Identity = new Option<string?>("--t3-managed-identity-client-id") { Description = "Client ID of a user-assigned identity for T3; omit for the VM's system-assigned identity." };
        var t4Server = new Option<string?>("--t4-server") { Description = "Also drive T4 from this machine (T1 only): the PostgreSQL flexible server's FQDN. Its profile lives in --t4-profile-file." };
        var t4User = new Option<string?>("--t4-user") { Description = "The PostgreSQL role T4's runs sign in as (default contosocare_runner)." };
        var t4Identity = new Option<string?>("--t4-managed-identity-client-id") { Description = "Client ID of a user-assigned identity for T4; omit for the VM's system-assigned identity." };
        var t4File = new Option<string?>("--t4-profile-file") { Description = "T4's activity profile file. Defaults to C:\\ProgramData\\DbHubDemo\\activity-t4.json (or /var/lib/DbHubDemo/activity-t4.json)." };
        var hostFile = ProfileFile();
        var hostStateFile = HostStateFile();
        var notAfter = new Option<string?>("--not-after") { Description = "Stop activity 2 minutes before this time (ISO 8601 with an offset, typically the next auto-shutdown)." };
        host.Options.Add(t3Server);
        host.Options.Add(t3Identity);
        host.Options.Add(t4Server);
        host.Options.Add(t4User);
        host.Options.Add(t4Identity);
        host.Options.Add(t4File);
        host.Options.Add(hostFile);
        host.Options.Add(hostStateFile);
        host.Options.Add(notAfter);
        host.SetAction(async (parseResult, cancellationToken) =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            return await Guard(parseResult, log, async () =>
            {
                var limit = ParseNotAfter(parseResult.GetValue(notAfter));
                var primary = hostTarget.TargetOf(parseResult);
                var targets = new List<ProfileTarget>();
                if (primary == DemoTarget.T4)
                {
                    targets.Add(new ProfileTarget(DemoTarget.T4, new PgScenarioRunner(new PgConnectionOpener(hostTarget.ResolvePostgres(parseResult), log), log, TimeProvider.System), new FileProfileStore(parseResult.GetValue(t4File) ?? FileProfileStore.DefaultPathFor(DemoTarget.T4))));
                }
                else
                {
                    var endpoint = hostTarget.Resolve(parseResult);
                    targets.Add(new ProfileTarget(endpoint.Target, new ScenarioRunner(new SqlConnectionOpener(endpoint, log), log, TimeProvider.System), Store(endpoint.Target, () => endpoint, parseResult.GetValue(hostFile), log)));
                }

                if (parseResult.GetValue(t3Server) is { } server)
                {
                    if (primary is DemoTarget.T3 or DemoTarget.T4)
                    {
                        throw new ScenarioRequestException("--t3-server is for a T1 host that also drives T3.");
                    }

                    var t3 = TargetEndpoint.Create(DemoTarget.T3, server, sqlLoginFromEnvironment: false, parseResult.GetValue(t3Identity));
                    targets.Add(new ProfileTarget(DemoTarget.T3, new ScenarioRunner(new SqlConnectionOpener(t3, log), log, TimeProvider.System), new FileProfileStore(parseResult.GetValue(hostFile) ?? FileProfileStore.DefaultPath)));
                }

                if (parseResult.GetValue(t4Server) is { } pgServer)
                {
                    if (primary is DemoTarget.T3 or DemoTarget.T4)
                    {
                        throw new ScenarioRequestException("--t4-server is for a T1 host that also drives T4.");
                    }

                    var t4 = PgEndpoint.Create(pgServer, parseResult.GetValue(t4User), passwordFromEnvironment: false, parseResult.GetValue(t4Identity));
                    targets.Add(new ProfileTarget(DemoTarget.T4, new PgScenarioRunner(new PgConnectionOpener(t4, log), log, TimeProvider.System), new FileProfileStore(parseResult.GetValue(t4File) ?? FileProfileStore.DefaultPathFor(DemoTarget.T4))));
                }

                var options = ProfileHostOptions.From(ActivityProfilesDefinition.Default, parseResult.GetValue(hostStateFile) ?? HostLanesFile.DefaultPath);
                await new ProfileHost(ActivityProfilesDefinition.Default, ScenarioCatalog.Default, log, TimeProvider.System, options).RunAsync(targets, limit, cancellationToken).ConfigureAwait(false);
                return ExitCodes.Success;
            }).ConfigureAwait(false);
        });

        command.Subcommands.Add(get);
        command.Subcommands.Add(set);
        command.Subcommands.Add(host);
        return command;
    }

    private static Command WarmupCommand()
    {
        var command = new Command("warmup", "Connect and run a light query, retrying while a serverless database resumes (T3); reports how long it took.");
        var target = new TargetOptions(command);
        var json = Json();
        command.Options.Add(json);
        command.SetAction(async (parseResult, cancellationToken) =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            return await Guard(parseResult, log, async () =>
            {
                if (target.TargetOf(parseResult) == DemoTarget.T4)
                {
                    return await WarmupT4Async(parseResult, target.ResolvePostgres(parseResult), parseResult.GetValue(json), log, cancellationToken).ConfigureAwait(false);
                }

                var endpoint = target.Resolve(parseResult);
                var opener = new SqlConnectionOpener(endpoint, log);
                var started = DateTimeOffset.UtcNow;
                await using var connection = await opener.OpenAsync(SessionNames.ForControl("warmup"), cancellationToken).ConfigureAwait(false);
                await using var command = connection.CreateCommand();
                command.CommandText = "SELECT COUNT_BIG(*) FROM care.facilities; SELECT COUNT_BIG(*) FROM demo.fn_scenario_catalog();";
                command.CommandTimeout = 60;
                await using (var reader = await command.ExecuteReaderAsync(cancellationToken).ConfigureAwait(false))
                {
                    while (await reader.NextResultAsync(cancellationToken).ConfigureAwait(false))
                    {
                    }
                }

                var elapsed = DateTimeOffset.UtcNow - started;
                var check = new CheckRecord("warmup", "Pass", string.Create(CultureInfo.InvariantCulture, $"{endpoint.Target} answered in {elapsed.TotalSeconds:0.0} s (connect and a light query, including any serverless resume)."));
                WriteChecks(parseResult, endpoint.Target, "warmup", [check], parseResult.GetValue(json));
                return ExitCodes.Success;
            }).ConfigureAwait(false);
        });
        return command;
    }

    private static Command SetupCommand()
    {
        var command = new Command("setup", "Create or update the demo objects (control tables, procedures) in ContosoCare. Run it as an administrator; it's idempotent.");
        var target = new TargetOptions(command);
        var baseSchema = new Option<bool>("--include-base-schema") { Description = "Also apply 010-schema.sql and 020-seed.sql (the bootstraps normally do; T4's setup applies them itself)." };
        var seedScale = new Option<int?>("--seed-scale") { Description = "Run demo.usp_seed_contosocare at this scale (1 to 50) unless that seed is already complete." };
        var grant = new Option<string?>("--grant-windows-login") { Description = "T1 and T2: create a login, user, and contosocare_runner membership for the runner's service identity, for example 'NT SERVICE\\ContosoCareWorkload'." };
        var entraObject = new Option<string?>("--grant-entra-object-id") { Description = "T4: create the runner's PostgreSQL role for this Microsoft Entra object ID (T1's managed identity) and grant it the demo's rights. Needs --user to be an Entra administrator (the P6 group's name)." };
        var runnerRole = new Option<string?>("--runner-role") { Description = "T4: the runner's PostgreSQL role name (default contosocare_runner)." };
        var json = Json();
        command.Options.Add(baseSchema);
        command.Options.Add(seedScale);
        command.Options.Add(grant);
        command.Options.Add(entraObject);
        command.Options.Add(runnerRole);
        command.Options.Add(json);
        command.SetAction(async (parseResult, cancellationToken) =>
        {
            using var log = GlobalOptions.CreateLog(parseResult);
            return await Guard(parseResult, log, async () =>
            {
                if (target.TargetOf(parseResult) == DemoTarget.T4)
                {
                    var objectId = parseResult.GetValue(entraObject) is { } text
                        ? Guid.TryParse(text, out var parsed) ? parsed : throw new ScenarioRequestException("--grant-entra-object-id must be an object ID (a GUID).")
                        : (Guid?)null;
                    return await SetupT4Async(parseResult, target.ResolvePostgres(parseResult), parseResult.GetValue(baseSchema), parseResult.GetValue(seedScale), objectId, parseResult.GetValue(runnerRole) ?? PgEndpoint.RunnerRole, parseResult.GetValue(json), log, cancellationToken).ConfigureAwait(false);
                }

                if (parseResult.GetValue(entraObject) is not null)
                {
                    throw new ScenarioRequestException("--grant-entra-object-id is for T4.");
                }

                var endpoint = target.Resolve(parseResult);
                var checks = new List<CheckRecord>();
                var opener = new SqlConnectionOpener(endpoint, log);
                await using var connection = await opener.OpenAsync(SessionNames.ForControl("setup"), cancellationToken).ConfigureAwait(false);
                var scripts = parseResult.GetValue(baseSchema) ? SqlScripts.BaseSchema.Concat(SqlScripts.DemoObjects) : SqlScripts.DemoObjects;
                foreach (var script in scripts)
                {
                    var batches = await SqlScripts.ApplyAsync(connection, script, log, cancellationToken).ConfigureAwait(false);
                    checks.Add(new CheckRecord("script:" + script, "Pass", string.Create(CultureInfo.InvariantCulture, $"Applied {script} ({batches} batches).")));
                }

                if (parseResult.GetValue(seedScale) is { } scale)
                {
                    if (scale is < 1 or > 50)
                    {
                        throw new ScenarioRequestException("--seed-scale must be between 1 and 50.");
                    }

                    await using var seed = connection.CreateCommand();
                    seed.CommandText = "EXEC demo.usp_seed_contosocare @scale = @scale;";
                    seed.CommandTimeout = 3600;
                    seed.Parameters.Add("@scale", System.Data.SqlDbType.Int).Value = scale;
                    await seed.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
                    checks.Add(new CheckRecord("seed", "Pass", string.Create(CultureInfo.InvariantCulture, $"ContosoCare is seeded at scale {scale}.")));
                }

                if (parseResult.GetValue(grant) is { } account)
                {
                    if (endpoint.Target == DemoTarget.T3)
                    {
                        throw new ScenarioRequestException("--grant-windows-login is for T1 and T2; T3 is Microsoft Entra only.");
                    }

                    await SqlScripts.GrantWindowsLoginAsync(connection, account, cancellationToken).ConfigureAwait(false);
                    checks.Add(new CheckRecord("runner-login", "Pass", $"{account} can connect to ContosoCare as a member of contosocare_runner (no server-level permissions)."));
                }

                var procedures = SqlScripts.ExpectedProcedures(ScenarioCatalog.Default, endpoint.Target);
                var missing = await SqlScripts.FindMissingProceduresAsync(connection, procedures, cancellationToken).ConfigureAwait(false);
                checks.Add(new CheckRecord(
                    "scenario-procedures",
                    missing.Count == 0 ? "Pass" : "Fail",
                    missing.Count == 0
                        ? string.Create(CultureInfo.InvariantCulture, $"Every scenario that runs on {endpoint.Target} has its procedure ({procedures.Count}).")
                        : string.Create(CultureInfo.InvariantCulture, $"{missing.Count} scenario procedure(s) are missing: {string.Join(", ", missing)}.")));

                WriteChecks(parseResult, endpoint.Target, "setup", checks, parseResult.GetValue(json));
                return ExitCodes.FromStatuses(checks.Select(c => c.Status));
            }).ConfigureAwait(false);
        });
        return command;
    }

    private static IProfileStore Store(DemoTarget target, Func<TargetEndpoint> endpoint, string? profileFile, RunnerLog log) =>
        target is DemoTarget.T3 or DemoTarget.T4
            ? new FileProfileStore(profileFile ?? FileProfileStore.DefaultPathFor(target))
            : new SqlProfileStore(new SqlConnectionOpener(endpoint(), log));

    private static async Task<int> Guard(ParseResult parseResult, RunnerLog log, Func<Task<int>> action)
    {
        try
        {
            return await action().ConfigureAwait(false);
        }
        catch (ScenarioRequestException ex)
        {
            log.Error("command.refused", ex.Message);
            parseResult.InvocationConfiguration.Error.WriteLine(Redactor.Redact(ex.Message));
            return ExitCodes.Failure;
        }
        catch (SqlException ex)
        {
            log.Error("command.sql-error", "A SQL call failed.", ("error", ex.Number), ("message", ex.Message));
            parseResult.InvocationConfiguration.Error.WriteLine(Redactor.Redact(string.Create(CultureInfo.InvariantCulture, $"SQL error {ex.Number}: {ex.Message}")));
            return ExitCodes.Failure;
        }
        catch (Exception ex) when (ex is Npgsql.NpgsqlException or Azure.Identity.AuthenticationFailedException or Azure.Identity.CredentialUnavailableException)
        {
            var message = Postgres.PgConnectionOpener.Describe(ex);
            log.Error("command.pg-error", "A PostgreSQL call failed.", ("message", message));
            parseResult.InvocationConfiguration.Error.WriteLine(message);
            return ExitCodes.Failure;
        }
        catch (OperationCanceledException)
        {
            log.Warn("command.cancelled", "Cancelled.");
            return ExitCodes.Failure;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            log.Error("command.failed", ex.Message);
            parseResult.InvocationConfiguration.Error.WriteLine(Redactor.Redact(ex.Message));
            return ExitCodes.Failure;
        }
#pragma warning disable CA1031 // The command line's last resort: report any other failure redacted, with an exit code, instead of a raw stack trace.
        catch (Exception ex)
#pragma warning restore CA1031
        {
            log.Error("command.unexpected", "Unexpected error.", ("type", ex.GetType().FullName), ("message", ex.Message));
            log.Debug("command.unexpected-detail", ex.ToString());
            parseResult.InvocationConfiguration.Error.WriteLine(Redactor.Redact($"{ex.GetType().Name}: {ex.Message}"));
            return ExitCodes.Failure;
        }
    }

    internal static DateTimeOffset? ParseNotAfter(string? text)
    {
        if (text is null)
        {
            return null;
        }

        return DurationText.TryParseInstant(text, out var instant)
            ? instant
            : throw new ScenarioRequestException("--not-after must be an ISO 8601 time with an offset, for example 2026-10-20T19:00:00-07:00 or 2026-10-21T02:00:00Z.");
    }

    internal static IReadOnlyDictionary<string, string> ParseParameters(IEnumerable<string>? values)
    {
        var parameters = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var value in values ?? [])
        {
            var separator = value.IndexOf('=', StringComparison.Ordinal);
            var key = separator > 0 ? value[..separator].Trim() : string.Empty;
            if (key.Length == 0 || !key.All(char.IsAsciiLetterOrDigit))
            {
                throw new ScenarioRequestException($"--param must look like name=value (got '{Redactor.Redact(value)}').");
            }

            if (!parameters.TryAdd(key, value[(separator + 1)..].Trim()))
            {
                throw new ScenarioRequestException($"--param {key} is given twice.");
            }
        }

        return parameters;
    }

    private static void WriteRunResult(ParseResult parseResult, RunResult result, bool json)
    {
        var output = parseResult.InvocationConfiguration.Output;
        if (json)
        {
            output.WriteLine(RunResultNode(result).ToJsonString(OutputOptions));
            return;
        }

        output.WriteLine($"Run {result.RunId}: {result.ScenarioId} on {result.Target} -> {result.Status} ({result.Result})");
        output.WriteLine(string.Create(CultureInfo.InvariantCulture, $"  Duration {result.DurationSeconds} s, concurrency {result.Concurrency}, intensity {result.Intensity}; sessions {string.Join(",", result.SessionIds)}"));
        output.WriteLine("  Outcome: " + result.Outcome);
        foreach (var adjustment in result.Adjustments)
        {
            output.WriteLine("  Adjusted: " + adjustment);
        }

        foreach (var check in result.Checks)
        {
            output.WriteLine($"  [{check.Status}] {check.CheckId}: {check.Message}");
        }
    }

    internal static JsonObject RunResultNode(RunResult result)
    {
        return new JsonObject
        {
            ["runId"] = result.RunId,
            ["scenario"] = result.ScenarioId,
            ["target"] = result.Target.ToString(),
            ["status"] = result.Status,
            ["result"] = result.Result,
            ["applicationName"] = SessionNames.ForRun(result.ScenarioId, result.RunId),
            ["startedAt"] = result.StartedAt is { } started ? DemoDatabase.Format(started) : null,
            ["endedAt"] = result.EndedAt is { } ended ? DemoDatabase.Format(ended) : null,
            ["deadlineAt"] = result.DeadlineAt is { } deadline ? DemoDatabase.Format(deadline) : null,
            ["durationSeconds"] = result.DurationSeconds,
            ["concurrency"] = result.Concurrency,
            ["intensity"] = result.Intensity,
            ["parameters"] = new JsonObject([.. result.Parameters.Select(p => KeyValuePair.Create(p.Key, (JsonNode?)p.Value))]),
            ["adjustments"] = new JsonArray([.. result.Adjustments.Select(a => (JsonNode)a)]),
            ["sessionIds"] = new JsonArray([.. result.SessionIds.Select(s => (JsonNode)s)]),
            ["outcome"] = Redactor.Redact(result.Outcome),
            ["expectedSymptoms"] = new JsonArray([.. result.ExpectedSymptoms.Select(s => (JsonNode)s)]),
            ["checks"] = new JsonArray([.. result.Checks.Select(c => (JsonNode)new JsonObject { ["checkId"] = c.CheckId, ["status"] = c.Status, ["message"] = Redactor.Redact(c.Message) })]),
        };
    }

    private static JsonNode RunNode(RunRecord run) => new JsonObject
    {
        ["runId"] = run.RunId,
        ["scenario"] = run.ScenarioId,
        ["target"] = run.Target,
        ["status"] = run.Status,
        ["startedAt"] = DemoDatabase.Format(run.StartedAt),
        ["deadlineAt"] = DemoDatabase.Format(run.DeadlineAt),
        ["stoppedAt"] = run.StoppedAt is { } stopped ? DemoDatabase.Format(stopped) : null,
        ["maxDurationSeconds"] = run.MaxDurationSeconds,
        ["concurrency"] = run.Concurrency,
        ["intensity"] = run.Intensity,
        ["profile"] = run.ProfileName,
        ["requestedBy"] = run.RequestedBy,
        ["outcome"] = run.Outcome is null ? null : Redactor.Redact(run.Outcome),
    };

    /// <summary>Writes checks as text, or as ADR 0012 result records (validation-result.schema.json) with --json.</summary>
    private static void WriteChecks(ParseResult parseResult, DemoTarget target, string command, IReadOnlyList<CheckRecord> checks, bool json)
    {
        var output = parseResult.InvocationConfiguration.Output;
        if (!json)
        {
            foreach (var check in checks)
            {
                output.WriteLine($"[{check.Status}] {check.CheckId}: {check.Message}");
            }

            return;
        }

        var timestamp = DateTimeOffset.UtcNow.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture);
        var array = new JsonArray();
        foreach (var check in checks)
        {
            array.Add(ResultRecord(target, command, check, timestamp));
        }

        output.WriteLine(array.ToJsonString(OutputOptions));
    }

    internal static JsonObject ResultRecord(DemoTarget target, string command, CheckRecord check, string timestamp)
    {
        var id = new string([.. (command + "." + check.CheckId).ToUpperInvariant().Select(c => char.IsAsciiLetterOrDigit(c) || c == '.' ? c : '_')]);
        return new JsonObject
        {
            ["checkId"] = string.Create(CultureInfo.InvariantCulture, $"WORKLOAD.{target}.{id}"),
            ["area"] = "workload",
            ["target"] = target.ToString(),
            ["status"] = Statuses.Contains(check.Status, StringComparer.Ordinal) ? check.Status : "Warning",
            ["message"] = Redactor.Redact(check.Message),
            ["evidence"] = new JsonObject { ["check"] = check.CheckId },
            ["remediation"] = check.Status is "Pass" or "Not selected" ? string.Empty : "Run 'ContosoCare.Workload reset' as an administrator on the target, then 'status'.",
            ["docUrl"] = DocUrl(command, target),
            ["evaluationOnly"] = false,
            ["timestamp"] = timestamp,
        };
    }

    private static string DocUrl(string command, DemoTarget target) => (command, target) switch
    {
        ("reset" or "stop", DemoTarget.T4) => "https://www.postgresql.org/docs/current/functions-admin.html#FUNCTIONS-ADMIN-SIGNAL",
        ("setup", DemoTarget.T4) => "https://learn.microsoft.com/azure/postgresql/security/security-manage-entra-users",
        (_, DemoTarget.T4) => "https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW",
        ("reset" or "stop", _) => "https://learn.microsoft.com/sql/t-sql/language-elements/kill-transact-sql",
        ("warmup", _) => "https://learn.microsoft.com/azure/azure-sql/database/serverless-tier-auto-pause-resume",
        _ => "https://learn.microsoft.com/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-sessions-transact-sql",
    };

    private static Option<bool> Json() => new("--json") { Description = "Write the result to standard output as JSON." };

    private static Option<string?> ProfileFile() => new("--profile-file") { Description = "T3's or T4's activity profile file. Defaults to C:\\ProgramData\\DbHubDemo\\activity.json for T3 and activity-t4.json for T4 (or under /var/lib/DbHubDemo)." };

    private static Option<string?> HostStateFile() => new("--host-state-file") { Description = "The profile host's heartbeat file, which 'profile run' writes and 'status' reads. Defaults to C:\\ProgramData\\DbHubDemo\\host-lanes.json (or /var/lib/DbHubDemo/host-lanes.json)." };

    private static Option<string> RequestedBy() => new("--requested-by") { Description = "Who asked, recorded with the request (a name, never a secret).", DefaultValueFactory = _ => DefaultRequester() };

    internal static string DefaultRequester() => Environment.UserName + "@" + Environment.MachineName;

    /// <summary>Options shared by every command: logging format, log file, verbosity.</summary>
    private static class GlobalOptions
    {
        public static readonly Option<LogFormat> LogFormat = new("--log-format") { Description = "Log format on standard error: Text or Json.", DefaultValueFactory = _ => Diagnostics.LogFormat.Text, Recursive = true };

        public static readonly Option<string?> LogFile = new("--log-file") { Description = "Also append the (redacted) log to this file.", Recursive = true };

        public static readonly Option<bool> Verbose = new("--verbose") { Description = "Include debug events.", Recursive = true };

        public static RunnerLog CreateLog(ParseResult parseResult) => new(
            parseResult.InvocationConfiguration.Error,
            parseResult.GetValue(LogFormat),
            parseResult.GetValue(Verbose) ? LogLevel.Debug : LogLevel.Information,
            parseResult.GetValue(LogFile));
    }

    /// <summary>--target, --server, and the authentication switches, added to one command.</summary>
    private sealed class TargetOptions
    {
        private readonly Option<DemoTarget> target = new("--target", "-t") { Description = "T1 (SQL Server on an Azure VM), T2 (Arc-enabled SQL Server), T3 (Azure SQL Database), or T4 (Azure Database for PostgreSQL flexible server).", Required = true };
        private readonly Option<string?> server = new("--server") { Description = "T1 and T2: the local instance (default '.'), Windows authentication. T3: the logical server name, Microsoft Entra managed identity. T4: the flexible server's FQDN, Microsoft Entra managed identity." };
        private readonly Option<string?> clientId = new("--managed-identity-client-id") { Description = "T3 and T4: the client ID of a user-assigned managed identity; omit for the system-assigned identity." };
        private readonly Option<bool> sqlLogin = new("--sql-login-from-environment") { Description = "Local SQL Server containers only: sign in with CONTOSOCARE_SQL_USER and CONTOSOCARE_SQL_PASSWORD from the environment." };
        private readonly Option<string?> user = new("--user") { Description = "T4 only: the PostgreSQL role to sign in as with the managed identity's token (default contosocare_runner; setup signs in as the P6 group's name)." };
        private readonly Option<bool> pgPassword = new("--pg-password-from-environment") { Description = "Local PostgreSQL tests only (T4): sign in with CONTOSOCARE_PG_USER and CONTOSOCARE_PG_PASSWORD from the environment." };

        public TargetOptions(Command command)
        {
            command.Options.Add(target);
            command.Options.Add(server);
            command.Options.Add(clientId);
            command.Options.Add(sqlLogin);
            command.Options.Add(user);
            command.Options.Add(pgPassword);
        }

        public DemoTarget TargetOf(ParseResult parseResult) => parseResult.GetValue(target);

        public TargetEndpoint Resolve(ParseResult parseResult)
        {
            if (parseResult.GetValue(user) is not null || parseResult.GetValue(pgPassword))
            {
                throw new ScenarioRequestException("--user and --pg-password-from-environment are for T4.");
            }

            return TargetEndpoint.Create(parseResult.GetValue(target), parseResult.GetValue(server), parseResult.GetValue(sqlLogin), parseResult.GetValue(clientId));
        }

        public PgEndpoint ResolvePostgres(ParseResult parseResult)
        {
            if (parseResult.GetValue(sqlLogin))
            {
                throw new ScenarioRequestException("--sql-login-from-environment is for SQL Server; T4 local tests use --pg-password-from-environment.");
            }

            return PgEndpoint.Create(parseResult.GetValue(server), parseResult.GetValue(user), parseResult.GetValue(pgPassword), parseResult.GetValue(clientId));
        }
    }

    /// <summary>The run options shared by 'run' and 'profile set': duration, concurrency, intensity, parameters, reset-before, auto-cleanup, not-after.</summary>
    private sealed class RunOptions
    {
        private readonly Option<string?> duration = new("--duration", "-d") { Description = "How long to run: seconds or 90s, 10m, 1h. Clamped to the scenario's maximum and to --not-after." };
        private readonly Option<int?> concurrency = new("--concurrency", "-c") { Description = "Concurrent sessions (clamped to the scenario's range)." };
        private readonly Option<int?> intensity = new("--intensity", "-i") { Description = "1 (gentle) to 10 (heavy)." };
        private readonly Option<string[]> parameters = new("--param", "-p") { Description = "A scenario parameter, name=value; repeat as needed (see 'scenarios <id>')." };
        private readonly Option<bool> resetBefore = new("--reset-before") { Description = "Reset the target first (stops other runs, kills leftover demo sessions, empties scratch tables)." };
        private readonly Option<bool> noAutoCleanup = new("--no-auto-cleanup") { Description = "Keep the scenario's scratch data after the run (auto-cleanup is on by default)." };
        private readonly Option<string?> notAfter = new("--not-after") { Description = "End at least 2 minutes before this time (ISO 8601 with an offset), typically the next auto-shutdown." };
        private readonly Option<string> requestedBy = RequestedBy();

        public RunOptions(Command command)
        {
            foreach (var option in new Option[] { duration, concurrency, intensity, parameters, resetBefore, noAutoCleanup, notAfter, requestedBy })
            {
                command.Options.Add(option);
            }
        }

        public RunRequest ToRequest(ParseResult parseResult, string scenarioId, DemoTarget target)
        {
            TimeSpan? requested = null;
            if (parseResult.GetValue(duration) is { } text)
            {
                requested = DurationText.TryParse(text, out var parsed)
                    ? parsed
                    : throw new ScenarioRequestException("--duration must be seconds or a value like 90s, 10m, or 1h.");
            }

            return new RunRequest
            {
                ScenarioId = scenarioId,
                Target = target,
                Duration = requested,
                Concurrency = parseResult.GetValue(concurrency),
                Intensity = parseResult.GetValue(intensity),
                Parameters = ParseParameters(parseResult.GetValue(parameters)),
                ResetBefore = parseResult.GetValue(resetBefore),
                AutoCleanup = !parseResult.GetValue(noAutoCleanup),
                NotAfter = ParseNotAfter(parseResult.GetValue(notAfter)),
                RequestedBy = parseResult.GetValue(requestedBy) ?? DefaultRequester(),
            };
        }
    }
}
