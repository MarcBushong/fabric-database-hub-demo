-- T3 azuresql01: read-only status for verification and warm-up (Test-DemoT3, Invoke-DemoT3WarmUp). Run it in
-- the ContosoCare database. It works before the schema exists: the seed state and the Database Agent beat's hold on
-- automatic tuning (2026-11-18) are read with dynamic SQL only when their tables are there. One row, so the result fits
-- the Run Command output limit.

DECLARE @seed_status varchar(20);
DECLARE @seed_scale int;
DECLARE @seed_version int;
DECLARE @hold_run varchar(64);
DECLARE @hold_run_status varchar(20);

IF OBJECT_ID(N'demo.seed_state', N'U') IS NOT NULL
    EXEC sys.sp_executesql
        N'SELECT @status = status, @scale = scale, @version = seed_version FROM demo.seed_state WHERE seed_state_id = 1;',
        N'@status varchar(20) OUTPUT, @scale int OUTPUT, @version int OUTPUT',
        @status = @seed_status OUTPUT,
        @scale = @seed_scale OUTPUT,
        @version = @seed_version OUTPUT;

IF OBJECT_ID(N'demo.auto_tuning_hold', N'U') IS NOT NULL
    EXEC sys.sp_executesql
        N'SELECT @run = h.run_id, @run_status = r.status FROM demo.auto_tuning_hold AS h LEFT JOIN demo.scenario_runs AS r ON r.run_id = h.run_id WHERE h.option_name = N''FORCE_LAST_GOOD_PLAN'';',
        N'@run varchar(64) OUTPUT, @run_status varchar(20) OUTPUT',
        @run = @hold_run OUTPUT,
        @run_status = @hold_run_status OUTPUT;

SELECT
    engine_edition = CAST(SERVERPROPERTY('EngineEdition') AS int),
    database_name = DB_NAME(),
    performance_monitoring = (
        SELECT TOP (1) CAST(value AS nvarchar(16))
        FROM sys.extended_properties
        WHERE class = 0 AND name = N'MS_EnablePerformanceMonitoringPreview'),
    query_store_state = (SELECT TOP (1) actual_state_desc FROM sys.database_query_store_options),
    -- Query Store's desired state, read-only reason, capture mode, and storage against its limit (2026-11-23):
    -- validate.ps1's T3.QUERYSTORE, whose fix follows the measured reason.
    query_store_desired_state = (SELECT TOP (1) desired_state_desc FROM sys.database_query_store_options),
    query_store_readonly_reason = (SELECT TOP (1) readonly_reason FROM sys.database_query_store_options),
    query_store_capture_mode = (SELECT TOP (1) query_capture_mode_desc FROM sys.database_query_store_options),
    query_store_storage_mb = (SELECT TOP (1) current_storage_size_mb FROM sys.database_query_store_options),
    query_store_max_storage_mb = (SELECT TOP (1) max_storage_size_mb FROM sys.database_query_store_options),
    force_last_good_plan_desired = (SELECT TOP (1) desired_state_desc FROM sys.database_automatic_tuning_options WHERE name = N'FORCE_LAST_GOOD_PLAN'),
    force_last_good_plan_actual = (SELECT TOP (1) actual_state_desc FROM sys.database_automatic_tuning_options WHERE name = N'FORCE_LAST_GOOD_PLAN'),
    auto_tuning_hold_run = @hold_run,
    auto_tuning_hold_status = @hold_run_status,
    seed_procedure = CASE WHEN OBJECT_ID(N'demo.usp_seed_contosocare', N'P') IS NULL THEN 0 ELSE 1 END,
    runner_role = CASE WHEN DATABASE_PRINCIPAL_ID(N'contosocare_runner') IS NULL THEN 0 ELSE 1 END,
    seed_status = @seed_status,
    seed_scale = @seed_scale,
    seed_version = @seed_version,
    is_db_owner = IS_ROLEMEMBER(N'db_owner');
