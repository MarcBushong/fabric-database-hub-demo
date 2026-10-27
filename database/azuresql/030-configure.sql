-- T3 azuresql01: database settings for the demo. Run it in the ContosoCare database after the common schema.
-- Idempotent. Azure SQL Database manages files, backups, and the recovery model (always FULL), so unlike T1 and
-- T2 there are no file caps or recovery settings here: the template's maxSizeBytes caps the database at 32 GB.

-- Query Store is on by default in Azure SQL Database. These are T1's settings, so the query-level evidence
-- (Query Store before and after) is comparable across targets.
ALTER DATABASE CURRENT SET QUERY_STORE = ON;
GO
ALTER DATABASE CURRENT SET QUERY_STORE
(
    OPERATION_MODE = READ_WRITE,
    QUERY_CAPTURE_MODE = AUTO,
    MAX_STORAGE_SIZE_MB = 1024,
    INTERVAL_LENGTH_MINUTES = 15,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 14),
    SIZE_BASED_CLEANUP_MODE = AUTO
);
GO

-- Least-privilege role for the workload runner, as on T1 and T2. By default T1's managed identity reaches T3
-- through the P6 administrator group and connects as dbo (ADR 0008, risk R26), so no contained user is created
-- here. The hardened option adds a contained user for T1 to this role and takes T1 out of the group.
IF DATABASE_PRINCIPAL_ID(N'contosocare_runner') IS NULL
    CREATE ROLE contosocare_runner AUTHORIZATION dbo;
GO
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::care TO contosocare_runner;
GO
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::demo TO contosocare_runner;
GO
