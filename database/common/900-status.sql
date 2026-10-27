-- Read-only status that the VM bootstraps use to decide whether ContosoCare is configured and seeded
-- (vm/bootstrap). Run it in the ContosoCare database. It works before the schema exists, because the seed
-- state is read with dynamic SQL only when demo.seed_state is there.

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
    query_store_state = (SELECT TOP (1) actual_state_desc FROM sys.database_query_store_options),
    uncapped_files = (SELECT COUNT(*) FROM sys.database_files WHERE max_size = -1),
    recovery_model = (SELECT recovery_model_desc FROM sys.databases WHERE database_id = DB_ID()),
    seed_procedure = CASE WHEN OBJECT_ID(N'demo.usp_seed_contosocare', N'P') IS NULL THEN 0 ELSE 1 END,
    runner_role = CASE WHEN DATABASE_PRINCIPAL_ID(N'contosocare_runner') IS NULL THEN 0 ELSE 1 END,
    seed_status = @seed_status,
    seed_scale = @seed_scale,
    seed_version = @seed_version;
