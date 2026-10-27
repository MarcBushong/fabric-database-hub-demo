-- T2 arcsql01: database settings for the demo. Run it in the ContosoCare database after the common schema.
-- Idempotent.

-- Query Store gives the before-and-after evidence for the CPU, IO, expensive-query, and missing-index
-- scenarios; remediation is never applied automatically (architecture).
ALTER DATABASE ContosoCare SET QUERY_STORE = ON;
GO
ALTER DATABASE ContosoCare SET QUERY_STORE
(
    OPERATION_MODE = READ_WRITE,
    QUERY_CAPTURE_MODE = AUTO,
    MAX_STORAGE_SIZE_MB = 512,
    INTERVAL_LENGTH_MINUTES = 15,
    CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = 14),
    SIZE_BASED_CLEANUP_MODE = AUTO
);
GO

-- No backups in the demo, so simple recovery keeps the log small.
ALTER DATABASE ContosoCare SET RECOVERY SIMPLE;
GO

-- File growth caps that respect the 64 GB guest VHDX (the IO scenario checks free space first, Phase 11).
ALTER DATABASE ContosoCare MODIFY FILE (NAME = N'ContosoCare', MAXSIZE = 8192MB, FILEGROWTH = 256MB);
GO
ALTER DATABASE ContosoCare MODIFY FILE (NAME = N'ContosoCare_log', MAXSIZE = 4096MB, FILEGROWTH = 256MB);
GO

-- Least-privilege role for the workload runner. Phase 11 creates the runner service's Windows login and
-- adds its database user to this role; the role never gets server-level permissions.
IF DATABASE_PRINCIPAL_ID(N'contosocare_runner') IS NULL
    CREATE ROLE contosocare_runner AUTHORIZATION dbo;
GO
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::care TO contosocare_runner;
GO
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::demo TO contosocare_runner;
GO
