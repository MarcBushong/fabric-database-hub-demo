-- T3 azuresql01: read-only status for verification and warm-up (Test-DemoT3, Invoke-DemoT3WarmUp). Run it in
-- the ContosoCare database. It works before the schema exists: the seed state is read with dynamic SQL only when
-- demo.seed_state is there. One row, so the result fits the Run Command output limit.

DECLARE @seed_status varchar(20);
DECLARE @seed_scale int;
DECLARE @seed_version int;

IF OBJECT_ID(N'demo.seed_state', N'U') IS NOT NULL
    EXEC sys.sp_executesql
        N'SELECT @status = status, @scale = scale, @version = seed_version FROM demo.seed_state WHERE seed_state_id = 1;',
        N'@status varchar(20) OUTPUT, @scale int OUTPUT, @version int OUTPUT',
        @status = @seed_status OUTPUT,
        @scale = @seed_scale OUTPUT,
        @version = @seed_version OUTPUT;

SELECT
    engine_edition = CAST(SERVERPROPERTY('EngineEdition') AS int),
    database_name = DB_NAME(),
    performance_monitoring = (
        SELECT TOP (1) CAST(value AS nvarchar(16))
        FROM sys.extended_properties
        WHERE class = 0 AND name = N'MS_EnablePerformanceMonitoringPreview'),
    query_store_state = (SELECT TOP (1) actual_state_desc FROM sys.database_query_store_options),
    seed_procedure = CASE WHEN OBJECT_ID(N'demo.usp_seed_contosocare', N'P') IS NULL THEN 0 ELSE 1 END,
    runner_role = CASE WHEN DATABASE_PRINCIPAL_ID(N'contosocare_runner') IS NULL THEN 0 ELSE 1 END,
    seed_status = @seed_status,
    seed_scale = @seed_scale,
    seed_version = @seed_version,
    is_db_owner = IS_ROLEMEMBER(N'db_owner');
