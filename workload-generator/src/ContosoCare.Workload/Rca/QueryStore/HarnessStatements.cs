namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// The runner's own statements outside any module (rca/README.md, What the capture leaves out, 3): every ad hoc
/// statement the runner's harness code sends, which Query Store records with object_id 0, out of the harness mark's
/// reach. One entry per statement, as <c>Sql/DemoDatabase.cs</c>, <c>Sql/SqlScripts.cs</c>, and <c>Cli/CommandLine.cs</c>'s
/// SQL Server paths send it: today's, and every version's since edd01c86 (none has changed since then; the release of
/// 2026-11-23 added Query Store's state read). They're string constants that only the match uses
/// (<see cref="IsRunners"/>): nothing executes them, reads the objects they name, or prints them, and no other observer
/// code names those objects. Three of them name a table or function that blind-detection.json forbids in detection
/// code; its exceptions allow those two names in this file only. A runner test fails when a statement in those files
/// isn't listed here.
/// </summary>
internal static class HarnessStatements
{
    /// <summary>The statements, one entry each, for the match and its tests.</summary>
    internal static readonly IReadOnlyList<string> Statements =
    [
        // Sql/DemoDatabase.cs, IsStopRequestedAsync: the stop check every run polls.
        "SELECT demo.fn_run_stop_requested(@run_id);",

        // Sql/DemoDatabase.cs, GetRunsAsync.
        """
        SELECT TOP (@count) run_id, scenario_id, target, status, started_at, deadline_at, stopped_at, max_duration_seconds,
            concurrency, intensity, outcome, profile_name, requested_by
        FROM demo.scenario_runs
        WHERE @running_only = 0 OR status = 'Running'
        ORDER BY started_at DESC;
        """,

        // Sql/DemoDatabase.cs, GetDemoSessionsAsync and RecoverOrphanedProfileRunsAsync: whether the caller sees other sessions.
        "SELECT demo.fn_can_view_sessions();",

        // Sql/DemoDatabase.cs, GetDemoSessionsAsync.
        """
        SELECT session_id, program_name, status, open_transaction_count, blocking_session_id, wait_type
        FROM demo.fn_demo_sessions(@run_id)
        ORDER BY session_id;
        """,

        // Sql/DemoDatabase.cs, GetStopFlagsAsync: the stop flags, a statement simple parameterization rewrites.
        "SELECT scenario_id, stop_requested_at, stop_requested_by FROM demo.scenario_control WHERE stop_requested = 1 ORDER BY scenario_id;",

        // Sql/DemoDatabase.cs, GetFilePathsAsync: a statement simple parameterization rewrites.
        "SELECT physical_name FROM sys.database_files WHERE type IN (0, 1);",

        // Sql/DemoDatabase.cs, RecoverOrphanedProfileRunsAsync.
        """
        SELECT r.run_id
        FROM demo.scenario_runs AS r
        WHERE r.status = 'Running'
          AND r.runner_host = @runner_host
          AND r.requested_by LIKE N'profile:%'
          AND r.started_at < @started_before
          AND NOT EXISTS (SELECT 1 FROM demo.fn_demo_sessions(r.run_id))
        ORDER BY r.started_at;
        """,

        // Sql/DemoDatabase.cs, ReadQueryStoreAsync: Query Store's state, which the release of 2026-11-23 added.
        """
        SELECT TOP (1) actual_state_desc, desired_state_desc, readonly_reason, query_capture_mode_desc,
            interval_length_minutes, current_storage_size_mb, max_storage_size_mb
        FROM sys.database_query_store_options;
        """,

        // Sql/SqlScripts.cs, FindMissingProceduresAsync: setup's check of each scenario's procedure.
        "SELECT CASE WHEN OBJECT_ID(@name, N'P') IS NULL THEN 1 ELSE 0 END;",

        // Cli/CommandLine.cs, warmup: one batch of two statements.
        "SELECT COUNT_BIG(*) FROM care.facilities;",
        "SELECT COUNT_BIG(*) FROM demo.fn_scenario_catalog();",
    ];

    private static readonly HashSet<string> Normalized = Statements.Select(HarnessText.Normalize).ToHashSet(StringComparer.Ordinal);

    /// <summary>
    /// Whether a text Query Store keeps is one of the runner's statements: equal to a listed one once both are in
    /// <see cref="HarnessText.Normalize"/>'s form.
    /// </summary>
    public static bool IsRunners(string queryText) => Normalized.Contains(HarnessText.Normalize(queryText));
}
