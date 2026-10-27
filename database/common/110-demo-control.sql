-- Demo control objects for the scenarios and activity profiles (ADR 0010, Phase 11). Run it in the ContosoCare
-- database after 010-schema.sql. Idempotent, and portable across SQL Server 2022 and Azure SQL Database: no USE,
-- no three-part names, no instance-level settings, and nothing outside the ContosoCare database.
--
-- Bounds are enforced in three layers. This file is the T-SQL layer: every run is registered here with a hard
-- deadline (clamped to the scenario's maximum and a global 4-hour cap), procedures stop at that deadline or on a
-- stop request, and the session tools act only on sessions whose application name starts with ContosoCare.Demo/.

-- Runner role ------------------------------------------------------------------------------------------------------

-- The target-specific 030-configure.sql scripts create the same role; creating it here as well keeps Azure SQL
-- Database, which has no target-specific script for it, on the same model. The role never gets server permissions.
IF DATABASE_PRINCIPAL_ID(N'contosocare_runner') IS NULL
    CREATE ROLE contosocare_runner AUTHORIZATION dbo;
GO
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::care TO contosocare_runner;
GO
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::demo TO contosocare_runner;
GO

-- Columns added to the Phase 6 control tables ----------------------------------------------------------------------

IF COL_LENGTH(N'demo.scenario_runs', N'parameters') IS NULL
    ALTER TABLE demo.scenario_runs ADD parameters nvarchar(2000) NULL;
GO
IF COL_LENGTH(N'demo.scenario_runs', N'outcome') IS NULL
    ALTER TABLE demo.scenario_runs ADD outcome nvarchar(1000) NULL;
GO
IF COL_LENGTH(N'demo.scenario_runs', N'session_ids') IS NULL
    ALTER TABLE demo.scenario_runs ADD session_ids varchar(400) NULL;
GO
IF COL_LENGTH(N'demo.scenario_runs', N'runner_host') IS NULL
    ALTER TABLE demo.scenario_runs ADD runner_host nvarchar(128) NULL;
GO
IF COL_LENGTH(N'demo.scenario_runs', N'profile_name') IS NULL
    ALTER TABLE demo.scenario_runs ADD profile_name varchar(64) NULL;
GO
IF COL_LENGTH(N'demo.scenario_control', N'stop_requested_at') IS NULL
    ALTER TABLE demo.scenario_control ADD stop_requested_at datetime2(3) NULL;
GO
IF COL_LENGTH(N'demo.scenario_control', N'stop_requested_by') IS NULL
    ALTER TABLE demo.scenario_control ADD stop_requested_by nvarchar(128) NULL;
GO
IF COL_LENGTH(N'demo.activity_profile', N'parameters') IS NULL
    ALTER TABLE demo.activity_profile ADD parameters nvarchar(2000) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_scenario_runs_status' AND object_id = OBJECT_ID(N'demo.scenario_runs'))
    CREATE INDEX ix_scenario_runs_status ON demo.scenario_runs (status, started_at);
GO

-- New control and scratch tables -----------------------------------------------------------------------------------

-- Session IDs and timestamps for each run (holder acquired, blocked, rolled back, deadlock victim, and so on).
-- run_id refers to demo.scenario_runs; there's no foreign key, so recording an event never waits on a run row.
IF OBJECT_ID(N'demo.scenario_run_events', N'U') IS NULL
CREATE TABLE demo.scenario_run_events
(
    event_id    bigint IDENTITY(1, 1) NOT NULL CONSTRAINT pk_scenario_run_events PRIMARY KEY,
    run_id      varchar(64)   NOT NULL,
    event_time  datetime2(3)  NOT NULL,
    event_name  varchar(40)   NOT NULL,
    session_id  int           NULL,
    detail      nvarchar(400) NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_scenario_run_events_run' AND object_id = OBJECT_ID(N'demo.scenario_run_events'))
    CREATE INDEX ix_scenario_run_events_run ON demo.scenario_run_events (run_id, event_id);
GO

-- Scratch data for the IO scenario: one 7,000-byte row per 8 KB page, so its size in MB is rows / 128. It's
-- reused between runs and capped by the scenario's scratchMb parameter, the file caps, and a free-space check.
IF OBJECT_ID(N'demo.io_scratch', N'U') IS NULL
CREATE TABLE demo.io_scratch
(
    scratch_id  int          NOT NULL CONSTRAINT pk_io_scratch PRIMARY KEY,
    run_id      varchar(64)  NOT NULL,
    written_at  datetime2(3) NOT NULL,
    touched     int          NOT NULL CONSTRAINT df_io_scratch_touched DEFAULT (0),
    payload     char(7000)   NOT NULL
);
GO

-- Write-only churn for the log-rate scenario: each worker inserts a batch and deletes it again.
IF OBJECT_ID(N'demo.log_rate_scratch', N'U') IS NULL
CREATE TABLE demo.log_rate_scratch
(
    row_id      bigint IDENTITY(1, 1) NOT NULL CONSTRAINT pk_log_rate_scratch PRIMARY KEY,
    run_id      varchar(64)  NOT NULL,
    worker      int          NOT NULL,
    written_at  datetime2(3) NOT NULL,
    payload     char(3000)   NOT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_log_rate_scratch_run' AND object_id = OBJECT_ID(N'demo.log_rate_scratch'))
    CREATE INDEX ix_log_rate_scratch_run ON demo.log_rate_scratch (run_id, worker);
GO

-- Commit churn for the log-flush scenario (Phase 25b): one small row per transaction, deleted every 1,000 rows.
IF OBJECT_ID(N'demo.commit_scratch', N'U') IS NULL
CREATE TABLE demo.commit_scratch
(
    row_id      bigint IDENTITY(1, 1) NOT NULL CONSTRAINT pk_commit_scratch PRIMARY KEY,
    run_id      varchar(64)  NOT NULL,
    worker      int          NOT NULL,
    written_at  datetime2(3) NOT NULL,
    payload     char(200)    NOT NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_commit_scratch_run' AND object_id = OBJECT_ID(N'demo.commit_scratch'))
    CREATE INDEX ix_commit_scratch_run ON demo.commit_scratch (run_id, worker);
GO

-- TRUNCATE needs ALTER on the table; the grant covers only the scratch tables.
GRANT ALTER ON OBJECT::demo.io_scratch TO contosocare_runner;
GO
GRANT ALTER ON OBJECT::demo.log_rate_scratch TO contosocare_runner;
GO
GRANT ALTER ON OBJECT::demo.commit_scratch TO contosocare_runner;
GO

-- Scenario catalog: the T-SQL layer of the bounds ----------------------------------------------------------------

-- Known scenarios and their hard maximum durations in seconds. They mirror scenarios/<id>/scenario.json; a .NET
-- test fails when the two disagree.
CREATE OR ALTER FUNCTION demo.fn_scenario_catalog ()
RETURNS TABLE
AS
RETURN
    SELECT scenario_id = CAST(c.scenario_id AS varchar(64)), max_duration_seconds = c.max_duration_seconds
    FROM (VALUES
        ('healthy-baseline', 14400),
        ('locking-blocking', 1800),
        ('cpu-pressure', 1800),
        ('io-pressure', 1800),
        ('missing-index', 1800),
        ('inefficient-query', 1800),
        ('resource-governance', 1200),
        ('log-rate-pressure', 900),
        ('blocking-chain', 1800),
        ('deadlock-storm', 1800),
        ('tempdb-contention', 1800),
        ('memory-grant-pressure', 1800),
        ('parallel-scans', 1800),
        ('log-flush-waits', 1800),
        ('slow-consumer', 1800),
        ('capacity-max', 1200)
    ) AS c (scenario_id, max_duration_seconds);
GO

-- One control row per scenario plus '*', the global cap and stop-all row. An operator can lower a limit here; a
-- re-run raises it back to the catalog value but never touches a stop request.
UPDATE c
SET max_duration_seconds = s.max_duration_seconds, updated_at = SYSUTCDATETIME()
FROM demo.scenario_control AS c
INNER JOIN demo.fn_scenario_catalog() AS s ON s.scenario_id = c.scenario_id
WHERE c.max_duration_seconds > s.max_duration_seconds;
GO
INSERT INTO demo.scenario_control (scenario_id, stop_requested, max_duration_seconds, updated_at)
SELECT s.scenario_id, 0, s.max_duration_seconds, SYSUTCDATETIME()
FROM demo.fn_scenario_catalog() AS s
WHERE NOT EXISTS (SELECT 1 FROM demo.scenario_control AS c WHERE c.scenario_id = s.scenario_id);
GO
IF NOT EXISTS (SELECT 1 FROM demo.scenario_control WHERE scenario_id = '*')
    INSERT INTO demo.scenario_control (scenario_id, stop_requested, max_duration_seconds, updated_at)
    VALUES ('*', 0, 14400, SYSUTCDATETIME());
GO

-- Helpers ------------------------------------------------------------------------------------------------------------

-- 1 when someone asked a run to stop: it isn't Running any more (demo.usp_stop marks it Cancelled), a stop was
-- requested for its scenario or for all scenarios after it started, or the run doesn't exist.
CREATE OR ALTER FUNCTION demo.fn_run_stop_requested (@run_id varchar(64))
RETURNS bit
AS
BEGIN
    DECLARE @stop bit = 1;

    SELECT @stop = CASE
            WHEN r.status <> 'Running' THEN 1
            WHEN EXISTS (
                SELECT 1
                FROM demo.scenario_control AS c
                WHERE c.stop_requested = 1
                  AND c.scenario_id IN (r.scenario_id, '*')
                  AND c.stop_requested_at >= r.started_at) THEN 1
            ELSE 0
        END
    FROM demo.scenario_runs AS r
    WHERE r.run_id = @run_id;

    RETURN @stop;
END;
GO

-- 1 when a run must stop: a stop was requested (above) or it's past its deadline. Every scenario loop checks it.
CREATE OR ALTER FUNCTION demo.fn_run_should_stop (@run_id varchar(64))
RETURNS bit
AS
BEGIN
    DECLARE @stop bit = 1;

    SELECT @stop = CASE WHEN SYSUTCDATETIME() >= r.deadline_at THEN 1 ELSE demo.fn_run_stop_requested(@run_id) END
    FROM demo.scenario_runs AS r
    WHERE r.run_id = @run_id;

    RETURN @stop;
END;
GO

-- The pause between units of work: @slow_ms at intensity 1 down to @fast_ms at intensity 10.
CREATE OR ALTER FUNCTION demo.fn_pause (@intensity tinyint, @slow_ms int, @fast_ms int)
RETURNS datetime
AS
BEGIN
    DECLARE @level int = CASE WHEN @intensity IS NULL OR @intensity < 1 THEN 1 WHEN @intensity > 10 THEN 10 ELSE @intensity END;
    RETURN DATEADD(millisecond, @slow_ms - (@slow_ms - @fast_ms) * (@level - 1) / 9, CAST(0 AS datetime));
END;
GO

-- 1 when the caller can see other sessions: VIEW SERVER STATE (or VIEW SERVER PERFORMANCE STATE) on SQL Server,
-- VIEW DATABASE STATE (or VIEW DATABASE PERFORMANCE STATE) on Azure SQL Database. Without it the session DMVs
-- show only the caller's own session, so checks that rely on them report Manual action required instead of Pass.
CREATE OR ALTER FUNCTION demo.fn_can_view_sessions ()
RETURNS bit
AS
BEGIN
    IF CAST(SERVERPROPERTY('EngineEdition') AS int) = 5
        RETURN CASE
            WHEN HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE STATE') = 1 THEN 1
            WHEN HAS_PERMS_BY_NAME(DB_NAME(), 'DATABASE', 'VIEW DATABASE PERFORMANCE STATE') = 1 THEN 1
            ELSE 0
        END;

    RETURN CASE
        WHEN HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER STATE') = 1 THEN 1
        WHEN HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE') = 1 THEN 1
        ELSE 0
    END;
END;
GO

-- Demo sessions in this database: application name ContosoCare.Demo/<scenario>/<run>, never the runner's own
-- control sessions (ContosoCare.Demo/control/...), never the caller. Optionally one run only.
CREATE OR ALTER FUNCTION demo.fn_demo_sessions (@run_id varchar(64))
RETURNS TABLE
AS
RETURN
    SELECT
        s.session_id,
        s.login_time,
        s.program_name,
        s.status,
        s.open_transaction_count,
        s.last_request_end_time,
        blocking_session_id = r.blocking_session_id,
        wait_type = r.wait_type,
        wait_time_ms = r.wait_time
    FROM sys.dm_exec_sessions AS s
    LEFT JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
    WHERE s.is_user_process = 1
      AND s.database_id = DB_ID()
      AND s.session_id <> @@SPID
      AND s.program_name LIKE 'ContosoCare.Demo/%'
      AND s.program_name NOT LIKE 'ContosoCare.Demo/control/%'
      AND (@run_id IS NULL OR s.program_name LIKE CONCAT('ContosoCare.Demo/%/', @run_id));
GO

-- Run bookkeeping ------------------------------------------------------------------------------------------------------

-- Marks runs that passed their deadline plus a grace period without ending as TimedOut (their runner stopped or
-- lost its connection), and closes cancelled runs that never recorded an end.
CREATE OR ALTER PROCEDURE demo.usp_recover_stale_runs
    @grace_seconds int = 120
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @now datetime2(3) = SYSUTCDATETIME();
    IF @grace_seconds IS NULL OR @grace_seconds < 0
        SET @grace_seconds = 0;

    UPDATE demo.scenario_runs
    SET status = 'TimedOut',
        stopped_at = @now,
        outcome = LEFT(CONCAT(outcome, CASE WHEN outcome IS NULL THEN N'' ELSE N' ' END,
            N'Recovered: the run passed its deadline without recording an end, so its runner stopped or lost its connection.'), 1000)
    WHERE status = 'Running'
      AND deadline_at < DATEADD(second, -@grace_seconds, @now);

    UPDATE demo.scenario_runs
    SET stopped_at = @now
    WHERE status <> 'Running'
      AND stopped_at IS NULL
      AND deadline_at < DATEADD(second, -@grace_seconds, @now);
END;
GO

-- Registers a run and returns its deadline. The duration is clamped to the scenario's maximum, any lower limit in
-- demo.scenario_control, and the global cap. At most one Running run per scenario and four in total per database.
CREATE OR ALTER PROCEDURE demo.usp_run_begin
    @run_id varchar(64),
    @scenario_id varchar(64),
    @target varchar(8),
    @duration_seconds int,
    @concurrency int,
    @intensity tinyint,
    @parameters nvarchar(2000) = NULL,
    @expected_symptoms nvarchar(400) = NULL,
    @requested_by nvarchar(128) = NULL,
    @runner_host nvarchar(128) = NULL,
    @profile_name varchar(64) = NULL,
    @deadline_at datetime2(3) = NULL OUTPUT,
    @effective_duration_seconds int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now datetime2(3) = SYSUTCDATETIME();
    DECLARE @catalog_max int, @control_max int, @global_max int, @running int, @message nvarchar(2048);

    IF @run_id IS NULL OR LEN(@run_id) > 40 OR @run_id LIKE '%[^a-z0-9-]%' OR @run_id NOT LIKE '[a-z0-9]%'
        THROW 50101, N'@run_id must be 1 to 40 lowercase letters, digits, and hyphens.', 1;
    IF @target IS NULL OR @target NOT IN ('T1', 'T2', 'T3')
        THROW 50102, N'@target must be T1, T2, or T3.', 1;
    IF @concurrency IS NULL OR @concurrency NOT BETWEEN 1 AND 64
        THROW 50103, N'@concurrency must be between 1 and 64.', 1;
    IF @intensity IS NULL OR @intensity NOT BETWEEN 1 AND 10
        THROW 50104, N'@intensity must be between 1 and 10.', 1;
    IF @duration_seconds IS NULL OR @duration_seconds < 10
        THROW 50105, N'@duration_seconds must be at least 10.', 1;

    SELECT @catalog_max = max_duration_seconds FROM demo.fn_scenario_catalog() WHERE scenario_id = @scenario_id;
    IF @catalog_max IS NULL
    BEGIN
        SET @message = CONCAT(N'Unknown scenario ''', @scenario_id, N'''. See demo.fn_scenario_catalog().');
        THROW 50106, @message, 1;
    END;

    SELECT @control_max = max_duration_seconds FROM demo.scenario_control WHERE scenario_id = @scenario_id;
    SELECT @global_max = max_duration_seconds FROM demo.scenario_control WHERE scenario_id = '*';

    SET @effective_duration_seconds = @duration_seconds;
    IF @effective_duration_seconds > @catalog_max
        SET @effective_duration_seconds = @catalog_max;
    IF @control_max IS NOT NULL AND @effective_duration_seconds > @control_max
        SET @effective_duration_seconds = @control_max;
    IF @effective_duration_seconds > ISNULL(@global_max, 14400)
        SET @effective_duration_seconds = ISNULL(@global_max, 14400);

    EXEC demo.usp_recover_stale_runs @grace_seconds = 120;

    IF EXISTS (SELECT 1 FROM demo.scenario_runs WHERE run_id = @run_id)
        THROW 50107, N'A run with this @run_id already exists.', 1;
    IF EXISTS (SELECT 1 FROM demo.scenario_runs WHERE status = 'Running' AND scenario_id = @scenario_id)
    BEGIN
        SET @message = CONCAT(N'Scenario ''', @scenario_id, N''' already has a Running run. Stop it first (demo.usp_stop).');
        THROW 50108, @message, 1;
    END;
    SELECT @running = COUNT(*) FROM demo.scenario_runs WHERE status = 'Running';
    IF @running >= 4
        THROW 50109, N'Four runs are already Running in this database, the most the demo allows. Stop one first.', 1;

    SET @deadline_at = DATEADD(second, @effective_duration_seconds, @now);

    INSERT INTO demo.scenario_runs
        (run_id, scenario_id, target, status, started_at, deadline_at, max_duration_seconds, concurrency, intensity,
         expected_symptoms, requested_by, parameters, runner_host, profile_name)
    VALUES
        (@run_id, @scenario_id, @target, 'Running', @now, @deadline_at, @effective_duration_seconds, @concurrency, @intensity,
         @expected_symptoms, @requested_by, @parameters, @runner_host, @profile_name);

    INSERT INTO demo.scenario_run_events (run_id, event_time, event_name, session_id, detail)
    VALUES (@run_id, @now, 'run-begin', @@SPID,
        LEFT(CONCAT(N'Deadline ', CONVERT(nvarchar(30), @deadline_at, 126), N'Z; requested ', @duration_seconds, N' s, effective ',
            @effective_duration_seconds, N' s.'), 400));
END;
GO

-- Throws unless the run exists, is Running, belongs to @scenario_id (when given), and has no stop request; returns
-- its deadline. Scenario procedures call it first.
CREATE OR ALTER PROCEDURE demo.usp_run_assert_running
    @run_id varchar(64),
    @scenario_id varchar(64) = NULL,
    @deadline_at datetime2(3) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @status varchar(20), @run_scenario varchar(64), @message nvarchar(2048);

    SELECT @status = status, @run_scenario = scenario_id, @deadline_at = deadline_at
    FROM demo.scenario_runs
    WHERE run_id = @run_id;

    IF @status IS NULL
        THROW 50110, N'Unknown run. Register runs with demo.usp_run_begin first.', 1;
    IF @scenario_id IS NOT NULL AND @run_scenario <> @scenario_id
    BEGIN
        SET @message = CONCAT(N'Run ', @run_id, N' belongs to scenario ''', @run_scenario, N''', not ''', @scenario_id, N'''.');
        THROW 50111, @message, 1;
    END;
    IF demo.fn_run_should_stop(@run_id) = 1
        THROW 50112, N'The run isn''t Running, is past its deadline, or has a stop request.', 1;
END;
GO

-- Records one event for a run: at most 500 per run, so a loop can never fill the table. @event_time lets the
-- runner keep the moment it observed something (a holder acquiring its locks, say) when it records it later.
CREATE OR ALTER PROCEDURE demo.usp_run_event
    @run_id varchar(64),
    @event_name varchar(40),
    @session_id int = NULL,
    @detail nvarchar(400) = NULL,
    @event_time datetime2(3) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF (SELECT COUNT(*) FROM demo.scenario_run_events WHERE run_id = @run_id) < 500
        INSERT INTO demo.scenario_run_events (run_id, event_time, event_name, session_id, detail)
        VALUES (@run_id, ISNULL(@event_time, SYSUTCDATETIME()), @event_name, @session_id, @detail);
END;
GO

-- Records the end of a run. A run that a stop request already marked Cancelled keeps that status.
CREATE OR ALTER PROCEDURE demo.usp_run_end
    @run_id varchar(64),
    @status varchar(20),
    @outcome nvarchar(1000) = NULL,
    @session_ids varchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @status IS NULL OR @status NOT IN ('Completed', 'Cancelled', 'TimedOut', 'Failed')
        THROW 50113, N'@status must be Completed, Cancelled, TimedOut, or Failed.', 1;

    UPDATE demo.scenario_runs
    SET status = CASE WHEN status = 'Running' THEN @status ELSE status END,
        stopped_at = SYSUTCDATETIME(),
        outcome = LEFT(CONCAT(outcome, CASE WHEN outcome IS NULL OR @outcome IS NULL THEN N'' ELSE N' ' END, @outcome), 1000),
        session_ids = ISNULL(@session_ids, session_ids)
    WHERE run_id = @run_id;

    EXEC demo.usp_run_event @run_id = @run_id, @event_name = 'run-end', @session_id = @@SPID, @detail = @status;
END;
GO

-- Stop requests: one run, every run of a scenario, or everything (optionally also the activity profile). Running
-- procedures see the request at their next check, within about a second.
CREATE OR ALTER PROCEDURE demo.usp_stop
    @scope varchar(10),
    @run_id varchar(64) = NULL,
    @scenario_id varchar(64) = NULL,
    @requested_by nvarchar(128) = NULL,
    @set_profile_off bit = 0,
    @return_results bit = 1,
    @runs_cancelled int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @now datetime2(3) = SYSUTCDATETIME();
    DECLARE @note nvarchar(200) = LEFT(CONCAT(N'Stop requested by ', ISNULL(@requested_by, N'an operator'), N' at ', CONVERT(nvarchar(30), @now, 126), N'Z.'), 200);
    DECLARE @runs int = 0;

    IF @scope IS NULL OR @scope NOT IN ('run', 'scenario', 'all')
        THROW 50114, N'@scope must be run, scenario, or all.', 1;
    IF @scope = 'run' AND @run_id IS NULL
        THROW 50115, N'@run_id is required when @scope is run.', 1;
    IF @scope = 'scenario' AND NOT EXISTS (SELECT 1 FROM demo.fn_scenario_catalog() WHERE scenario_id = @scenario_id)
        THROW 50116, N'@scenario_id must be a known scenario when @scope is scenario.', 1;

    BEGIN TRANSACTION;

    IF @scope IN ('scenario', 'all')
        UPDATE demo.scenario_control
        SET stop_requested = 1, stop_requested_at = @now, stop_requested_by = @requested_by, updated_at = @now
        WHERE scenario_id = CASE WHEN @scope = 'all' THEN '*' ELSE @scenario_id END;

    UPDATE demo.scenario_runs
    SET status = 'Cancelled',
        outcome = LEFT(CONCAT(outcome, CASE WHEN outcome IS NULL THEN N'' ELSE N' ' END, @note), 1000)
    WHERE status = 'Running'
      AND (@scope = 'all'
           OR (@scope = 'run' AND run_id = @run_id)
           OR (@scope = 'scenario' AND scenario_id = @scenario_id));
    SET @runs = @@ROWCOUNT;

    IF @set_profile_off = 1
        UPDATE demo.activity_profile
        SET profile_name = 'off', set_at = @now, set_by = ISNULL(@requested_by, N'stop'), expires_at = NULL, parameters = NULL
        WHERE profile_slot = 1;

    COMMIT TRANSACTION;

    SET @runs_cancelled = @runs;
    IF @return_results = 1
        SELECT scope = @scope, runs_cancelled = @runs, requested_at = @now;
END;
GO

-- Activity profile (T1 and T2; T3's profile lives in a file on T1 so polling never wakes the serverless database) --

CREATE OR ALTER PROCEDURE demo.usp_profile_set
    @profile_name varchar(64),
    @set_by nvarchar(128),
    @expires_at datetime2(3) = NULL,
    @parameters nvarchar(2000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @message nvarchar(2048);

    IF @profile_name IS NULL
       OR (@profile_name NOT IN ('off', 'baseline', 'business-day')
           AND NOT (@profile_name LIKE 'incident:%'
                    AND EXISTS (SELECT 1 FROM demo.fn_scenario_catalog() WHERE CONCAT('incident:', scenario_id) = @profile_name)))
    BEGIN
        SET @message = CONCAT(N'Unknown activity profile ''', @profile_name, N'''. Use off, baseline, business-day, or incident:<scenario>.');
        THROW 50117, @message, 1;
    END;

    IF EXISTS (SELECT 1 FROM demo.activity_profile WHERE profile_slot = 1)
        UPDATE demo.activity_profile
        SET profile_name = @profile_name, set_at = SYSUTCDATETIME(), set_by = ISNULL(@set_by, N'unknown'),
            expires_at = @expires_at, parameters = @parameters
        WHERE profile_slot = 1;
    ELSE
        INSERT INTO demo.activity_profile (profile_slot, profile_name, set_at, set_by, expires_at, parameters)
        VALUES (1, @profile_name, SYSUTCDATETIME(), ISNULL(@set_by, N'unknown'), @expires_at, @parameters);
END;
GO

CREATE OR ALTER PROCEDURE demo.usp_profile_get
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        profile_name,
        set_at,
        set_by,
        expires_at,
        parameters,
        is_active = CAST(CASE WHEN profile_name <> 'off' AND (expires_at IS NULL OR expires_at > SYSUTCDATETIME()) THEN 1 ELSE 0 END AS bit)
    FROM demo.activity_profile
    WHERE profile_slot = 1;
END;
GO

-- Free space -----------------------------------------------------------------------------------------------------------

-- Headroom in MB for the data and log files: file caps (MAXSIZE) on SQL Server, the service objective's maximum
-- size on Azure SQL Database, where the log is managed by the service. An uncapped file has no headroom value; a
-- caller that needs space then fails rather than letting a file grow without bound. Raises error 50120 or 50121
-- when @raise = 1 and the space isn't there, keeping a 512 MB data and 256 MB log margin.
CREATE OR ALTER PROCEDURE demo.usp_check_space
    @required_data_mb int = 0,
    @required_log_mb int = 0,
    @raise bit = 1,
    @data_headroom_mb int = NULL OUTPUT,
    @log_headroom_mb int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @azure bit = CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 5 THEN 1 ELSE 0 END;
    DECLARE @data_used bigint, @data_max bigint, @data_uncapped int, @log_used bigint, @log_max bigint, @log_uncapped int;
    DECLARE @message nvarchar(2048);

    SELECT
        @data_used = SUM(CAST(FILEPROPERTY(name, 'SpaceUsed') AS bigint)),
        @data_max = SUM(CASE WHEN max_size > 0 THEN CAST(max_size AS bigint) ELSE 0 END),
        @data_uncapped = SUM(CASE WHEN max_size = -1 THEN 1 ELSE 0 END)
    FROM sys.database_files
    WHERE type = 0;

    SELECT
        @log_used = SUM(CAST(FILEPROPERTY(name, 'SpaceUsed') AS bigint)),
        @log_max = SUM(CASE WHEN max_size > 0 THEN CAST(max_size AS bigint) ELSE 0 END),
        @log_uncapped = SUM(CASE WHEN max_size = -1 THEN 1 ELSE 0 END)
    FROM sys.database_files
    WHERE type = 1;

    IF @azure = 1
    BEGIN
        SET @data_max = CAST(DATABASEPROPERTYEX(DB_NAME(), 'MaxSizeInBytes') AS bigint) / 8192;
        SET @data_uncapped = 0;
    END;

    SET @data_headroom_mb = CASE WHEN @data_uncapped > 0 OR @data_max IS NULL THEN NULL ELSE CAST((@data_max - ISNULL(@data_used, 0)) / 128 AS int) END;
    SET @log_headroom_mb = CASE WHEN @azure = 1 OR @log_uncapped > 0 OR @log_max IS NULL THEN NULL ELSE CAST((@log_max - ISNULL(@log_used, 0)) / 128 AS int) END;

    IF @raise = 1 AND @required_data_mb > 0
    BEGIN
        IF @data_headroom_mb IS NULL
            THROW 50120, N'A ContosoCare data file has no MAXSIZE cap, so growth can''t be bounded. Cap it first (030-configure.sql).', 1;
        IF @data_headroom_mb < @required_data_mb + 512
        BEGIN
            SET @message = CONCAT(N'Not enough data headroom: ', @data_headroom_mb, N' MB left under the cap, ', @required_data_mb, N' MB needed plus a 512 MB margin.');
            THROW 50121, @message, 1;
        END;
    END;

    IF @raise = 1 AND @required_log_mb > 0 AND @azure = 0
    BEGIN
        IF @log_headroom_mb IS NULL
            THROW 50120, N'The ContosoCare log file has no MAXSIZE cap, so growth can''t be bounded. Cap it first (030-configure.sql).', 1;
        IF @log_headroom_mb < @required_log_mb + 256
        BEGIN
            SET @message = CONCAT(N'Not enough log headroom: ', @log_headroom_mb, N' MB left under the cap, ', @required_log_mb, N' MB needed plus a 256 MB margin.');
            THROW 50121, @message, 1;
        END;
    END;
END;
GO

-- Session tools: only ContosoCare.Demo/ sessions in this database ---------------------------------------------------

-- Ends demo sessions with KILL: by default only those whose run is no longer Running or is past its deadline (the
-- watchdog backstop), or every demo session when @past_deadline_only = 0 (reset). Each session is re-checked
-- (same login time, still tagged, still in this database) immediately before it's killed. KILL needs ALTER ANY
-- CONNECTION on SQL Server or KILL DATABASE CONNECTION on Azure SQL Database; without it each attempt is reported
-- as failed and nothing else happens.
CREATE OR ALTER PROCEDURE demo.usp_kill_demo_sessions
    @run_id varchar(64) = NULL,
    @past_deadline_only bit = 1,
    @requested_by nvarchar(128) = NULL,
    @return_results bit = 1,
    @killed int = NULL OUTPUT,
    @failed int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @targets TABLE (ordinal int IDENTITY(1, 1) PRIMARY KEY, session_id int NOT NULL, login_time datetime NOT NULL, program_name nvarchar(128) NOT NULL);
    DECLARE @results TABLE (session_id int NOT NULL, program_name nvarchar(128) NOT NULL, outcome varchar(20) NOT NULL, detail nvarchar(400) NULL);
    DECLARE @remaining int, @ordinal int = 0, @session int, @login datetime, @program nvarchar(128), @sql nvarchar(64);

    SET @killed = 0;
    SET @failed = 0;

    IF demo.fn_can_view_sessions() = 0
    BEGIN
        SET @failed = NULL;
        IF @return_results = 1
            SELECT session_id = CAST(NULL AS int), program_name = CAST(NULL AS nvarchar(128)), outcome = 'NotVisible',
                detail = N'The caller can''t see other sessions (VIEW SERVER STATE or VIEW DATABASE STATE), so nothing was killed.';
        RETURN;
    END;

    INSERT INTO @targets (session_id, login_time, program_name)
    SELECT s.session_id, s.login_time, s.program_name
    FROM demo.fn_demo_sessions(@run_id) AS s
    WHERE @past_deadline_only = 0
       OR EXISTS (
            SELECT 1
            FROM demo.scenario_runs AS r
            WHERE s.program_name = CONCAT('ContosoCare.Demo/', r.scenario_id, '/', r.run_id)
              AND (r.status <> 'Running' OR r.deadline_at < SYSUTCDATETIME()));

    SET @remaining = @@ROWCOUNT;

    WHILE @remaining > 0
    BEGIN
        SET @remaining -= 1;
        SET @ordinal += 1;
        SELECT @session = session_id, @login = login_time, @program = program_name FROM @targets WHERE ordinal = @ordinal;

        IF EXISTS (
            SELECT 1
            FROM sys.dm_exec_sessions AS s
            WHERE s.session_id = @session
              AND s.login_time = @login
              AND s.database_id = DB_ID()
              AND s.program_name LIKE 'ContosoCare.Demo/%'
              AND s.program_name NOT LIKE 'ContosoCare.Demo/control/%')
        BEGIN
            SET @sql = CONCAT(N'KILL ', @session, N';');
            BEGIN TRY
                EXEC (@sql);
                SET @killed += 1;
                INSERT INTO @results (session_id, program_name, outcome, detail)
                VALUES (@session, @program, 'Killed', LEFT(CONCAT(N'Killed by ', ISNULL(@requested_by, N'an operator'), N'.'), 400));
            END TRY
            BEGIN CATCH
                SET @failed += 1;
                INSERT INTO @results (session_id, program_name, outcome, detail)
                VALUES (@session, @program, 'Failed', LEFT(ERROR_MESSAGE(), 400));
            END CATCH;
        END;
        ELSE
            INSERT INTO @results (session_id, program_name, outcome, detail)
            VALUES (@session, @program, 'Gone', N'The session ended before it was killed.');
    END;

    IF @return_results = 1
        SELECT session_id, program_name, outcome, detail FROM @results ORDER BY session_id;
END;
GO

-- Auto-cleanup after a run: empties the scenario's scratch table (the space stays allocated for the next run) or
-- removes the workload's audit rows. Never touches a scenario that still has a Running run. Returns one check row.
CREATE OR ALTER PROCEDURE demo.usp_cleanup_scenario
    @scenario_id varchar(64)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @remaining int = 100, @batch int, @deleted int = 0;

    IF EXISTS (SELECT 1 FROM demo.scenario_runs WHERE scenario_id = @scenario_id AND status = 'Running')
    BEGIN
        SELECT check_id = 'auto-cleanup', status = 'Warning', message = N'Skipped: the scenario still has a Running run.';
        RETURN;
    END;

    BEGIN TRY
        IF @scenario_id IN ('io-pressure', 'capacity-max')
        BEGIN
            -- The two scenarios share demo.io_scratch, so it's emptied only when neither is running.
            IF EXISTS (SELECT 1 FROM demo.scenario_runs WHERE scenario_id IN ('io-pressure', 'capacity-max') AND status = 'Running')
                SELECT check_id = 'auto-cleanup', status = 'Warning', message = N'Skipped: another run still uses demo.io_scratch; reset or its own cleanup empties it.';
            ELSE
            BEGIN
                TRUNCATE TABLE demo.io_scratch;
                SELECT check_id = 'auto-cleanup', status = 'Pass', message = N'demo.io_scratch emptied; its space stays allocated for the next run.';
            END;
        END;
        ELSE IF @scenario_id = 'log-rate-pressure'
        BEGIN
            TRUNCATE TABLE demo.log_rate_scratch;
            SELECT check_id = 'auto-cleanup', status = 'Pass', message = N'demo.log_rate_scratch emptied.';
        END;
        ELSE IF @scenario_id = 'log-flush-waits'
        BEGIN
            TRUNCATE TABLE demo.commit_scratch;
            SELECT check_id = 'auto-cleanup', status = 'Pass', message = N'demo.commit_scratch emptied.';
        END;
        ELSE IF @scenario_id IN ('healthy-baseline', 'locking-blocking', 'blocking-chain')
        BEGIN
            WHILE @remaining > 0
            BEGIN
                SET @remaining -= 1;
                DELETE TOP (5000) FROM care.audit_events WHERE actor = 'ContosoCare.Demo';
                SET @batch = @@ROWCOUNT;
                SET @deleted += @batch;
                IF @batch = 0
                    SET @remaining = 0;
            END;
            SELECT check_id = 'auto-cleanup', status = 'Pass', message = LEFT(CONCAT(@deleted, N' audit row(s) written by the workload removed.'), 400);
        END;
        ELSE
            SELECT check_id = 'auto-cleanup', status = 'Not selected', message = N'This scenario leaves nothing to clean up: its changes roll back or it only reads.';
    END TRY
    BEGIN CATCH
        SELECT check_id = 'auto-cleanup', status = 'Warning', message = LEFT(CONCAT(N'Cleanup skipped: ', ERROR_MESSAGE()), 400);
    END CATCH;
END;
GO

-- Missing-index remediation undo: drops only the two indexes that scenarios/missing-index/remediation.sql creates,
-- so the scenario can run again from its "before" state. Needs ALTER on the tables (an administrator).
CREATE OR ALTER PROCEDURE demo.usp_undo_missing_index_remediation
    @indexes_dropped int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @indexes_dropped = 0;

    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_claims_payer_submitted' AND object_id = OBJECT_ID(N'care.claims'))
    BEGIN
        DROP INDEX ix_claims_payer_submitted ON care.claims;
        SET @indexes_dropped += 1;
    END;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_appointments_reason' AND object_id = OBJECT_ID(N'care.appointments'))
    BEGIN
        DROP INDEX ix_appointments_reason ON care.appointments;
        SET @indexes_dropped += 1;
    END;
END;
GO

-- Reset: back to a known, quiet state without redeploying ------------------------------------------------------------

-- 1. Stops every run (and the activity profile unless @keep_profile = 1). 2. Waits up to @wait_seconds for demo
-- sessions to end. 3. Kills the demo sessions that remain (@kill_sessions = 1). 4. Verifies that no demo
-- transaction is still open. 5. Closes run records. 6. Empties the scratch tables. 7. Removes the workload's audit
-- rows. 8. Optionally undoes the missing-index remediation and reseeds. 9. Purges old run history.
-- Returns one row per check, with the ADR 0012 statuses.
CREATE OR ALTER PROCEDURE demo.usp_reset
    @requested_by nvarchar(128) = NULL,
    @wait_seconds int = 30,
    @kill_sessions bit = 1,
    @keep_profile bit = 0,
    @undo_remediation bit = 0,
    @reseed bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @checks TABLE (ordinal int IDENTITY(1, 1) PRIMARY KEY, check_id varchar(40) NOT NULL, status varchar(30) NOT NULL, message nvarchar(400) NOT NULL);
    DECLARE @can_view bit = demo.fn_can_view_sessions();
    DECLARE @wait_until datetime2(3), @sessions int, @open int, @killed int, @failed int, @remaining int, @batch int, @deleted int;
    DECLARE @runs_cancelled int, @indexes_dropped int, @scale int, @seed int;

    IF @wait_seconds IS NULL OR @wait_seconds < 0
        SET @wait_seconds = 0;
    IF @wait_seconds > 300
        SET @wait_seconds = 300;

    -- 1. Stop.
    EXEC demo.usp_stop @scope = 'all', @requested_by = @requested_by, @set_profile_off = 0, @return_results = 0, @runs_cancelled = @runs_cancelled OUTPUT;
    IF @keep_profile = 0
        EXEC demo.usp_profile_set @profile_name = 'off', @set_by = @requested_by;
    INSERT INTO @checks (check_id, status, message)
    VALUES ('runs-stopped', 'Pass', LEFT(CONCAT(N'Stop requested for every run; ', @runs_cancelled, N' Running run(s) marked Cancelled',
        CASE WHEN @keep_profile = 0 THEN N'; activity profile set to off.' ELSE N'; activity profile kept.' END), 400));

    -- 2. Wait for the scenario procedures to notice the stop request (they check about once a second).
    SET @wait_until = DATEADD(second, CASE WHEN @can_view = 1 THEN @wait_seconds WHEN @wait_seconds < 5 THEN @wait_seconds ELSE 5 END, SYSUTCDATETIME());
    WHILE SYSUTCDATETIME() < @wait_until
          AND (@can_view = 0 OR EXISTS (SELECT 1 FROM demo.fn_demo_sessions(NULL)))
        WAITFOR DELAY '00:00:01';

    -- 3. Kill what's left.
    IF @can_view = 0
        INSERT INTO @checks (check_id, status, message)
        VALUES ('demo-sessions-ended', 'Manual action required',
            N'Can''t see other sessions. Run reset as an administrator, or grant VIEW SERVER STATE (SQL Server) or VIEW DATABASE STATE (Azure SQL Database).');
    ELSE
    BEGIN
        SELECT @sessions = COUNT(*) FROM demo.fn_demo_sessions(NULL);
        IF @sessions = 0
            INSERT INTO @checks (check_id, status, message) VALUES ('demo-sessions-ended', 'Pass', N'No demo sessions remain.');
        ELSE IF @kill_sessions = 0
            INSERT INTO @checks (check_id, status, message)
            VALUES ('demo-sessions-ended', 'Warning', LEFT(CONCAT(@sessions, N' demo session(s) remain, and @kill_sessions = 0 left them alone.'), 400));
        ELSE
        BEGIN
            EXEC demo.usp_kill_demo_sessions @run_id = NULL, @past_deadline_only = 0, @requested_by = @requested_by,
                @return_results = 0, @killed = @killed OUTPUT, @failed = @failed OUTPUT;
            INSERT INTO @checks (check_id, status, message)
            VALUES ('demo-sessions-ended',
                CASE WHEN ISNULL(@failed, 0) > 0 THEN 'Manual action required' ELSE 'Pass' END,
                LEFT(CONCAT(ISNULL(@killed, 0), N' demo session(s) killed, ', ISNULL(@failed, 0), N' could not be killed',
                    CASE WHEN ISNULL(@failed, 0) > 0 THEN N' (needs ALTER ANY CONNECTION or KILL DATABASE CONNECTION; run reset as an administrator).' ELSE N'.' END), 400));

            -- Killed sessions roll back before they disappear.
            SET @wait_until = DATEADD(second, @wait_seconds, SYSUTCDATETIME());
            WHILE SYSUTCDATETIME() < @wait_until AND EXISTS (SELECT 1 FROM demo.fn_demo_sessions(NULL) WHERE open_transaction_count > 0)
                WAITFOR DELAY '00:00:01';
        END;
    END;

    -- 4. Verify that no demo transaction is open.
    IF @can_view = 1
    BEGIN
        SELECT @open = COUNT(*) FROM demo.fn_demo_sessions(NULL) WHERE open_transaction_count > 0;
        INSERT INTO @checks (check_id, status, message)
        VALUES ('no-open-demo-transactions', CASE WHEN @open = 0 THEN 'Pass' ELSE 'Fail' END,
            CASE WHEN @open = 0 THEN N'No demo session has an open transaction.'
                 ELSE LEFT(CONCAT(@open, N' demo session(s) still have an open transaction; run reset again as an administrator.'), 400) END);
    END;
    ELSE
        INSERT INTO @checks (check_id, status, message)
        VALUES ('no-open-demo-transactions', 'Manual action required',
            N'Can''t verify open demo transactions without VIEW SERVER STATE (SQL Server) or VIEW DATABASE STATE (Azure SQL Database).');

    -- 5. Close run records whose runner didn't.
    EXEC demo.usp_recover_stale_runs @grace_seconds = 0;
    UPDATE demo.scenario_runs SET stopped_at = SYSUTCDATETIME() WHERE status <> 'Running' AND stopped_at IS NULL;

    -- 6. Scratch tables.
    BEGIN TRY
        TRUNCATE TABLE demo.io_scratch;
        TRUNCATE TABLE demo.log_rate_scratch;
        TRUNCATE TABLE demo.commit_scratch;
        INSERT INTO @checks (check_id, status, message) VALUES ('scratch-emptied', 'Pass', N'demo.io_scratch, demo.log_rate_scratch, and demo.commit_scratch are empty; their space stays allocated for reuse.');
    END TRY
    BEGIN CATCH
        INSERT INTO @checks (check_id, status, message) VALUES ('scratch-emptied', 'Warning', LEFT(CONCAT(N'Scratch tables not emptied: ', ERROR_MESSAGE()), 400));
    END CATCH;

    -- 7. The baseline's audit rows (bounded: at most 200 batches of 5,000).
    SET @remaining = 200;
    SET @deleted = 0;
    WHILE @remaining > 0
    BEGIN
        SET @remaining -= 1;
        DELETE TOP (5000) FROM care.audit_events WHERE actor = 'ContosoCare.Demo';
        SET @batch = @@ROWCOUNT;
        SET @deleted += @batch;
        IF @batch = 0
            SET @remaining = 0;
    END;
    INSERT INTO @checks (check_id, status, message) VALUES ('workload-rows-removed', 'Pass', LEFT(CONCAT(@deleted, N' audit row(s) written by the workload removed.'), 400));

    -- 8. Optional steps.
    IF @undo_remediation = 1
    BEGIN
        BEGIN TRY
            EXEC demo.usp_undo_missing_index_remediation @indexes_dropped = @indexes_dropped OUTPUT;
            INSERT INTO @checks (check_id, status, message)
            VALUES ('remediation-undone', 'Pass', LEFT(CONCAT(@indexes_dropped, N' remediation index(es) dropped.'), 400));
        END TRY
        BEGIN CATCH
            INSERT INTO @checks (check_id, status, message) VALUES ('remediation-undone', 'Fail', LEFT(CONCAT(N'Remediation not undone (needs ALTER on the tables): ', ERROR_MESSAGE()), 400));
        END CATCH;
    END;
    ELSE
        INSERT INTO @checks (check_id, status, message) VALUES ('remediation-undone', 'Not selected', N'The missing-index remediation was left as it is.');

    IF @reseed = 1
    BEGIN
        SELECT @scale = scale, @seed = seed FROM demo.seed_state WHERE seed_state_id = 1;
        BEGIN TRY
            IF @scale IS NULL
                THROW 50122, N'demo.seed_state has no completed seed to repeat.', 1;
            EXEC demo.usp_seed_contosocare @scale = @scale, @seed = @seed, @force = 1;
            INSERT INTO @checks (check_id, status, message) VALUES ('reseeded', 'Pass', LEFT(CONCAT(N'Reseeded at scale ', @scale, N' with seed ', @seed, N'.'), 400));
        END TRY
        BEGIN CATCH
            INSERT INTO @checks (check_id, status, message) VALUES ('reseeded', 'Fail', LEFT(CONCAT(N'Reseed failed (needs an administrator): ', ERROR_MESSAGE()), 400));
        END CATCH;
    END;
    ELSE
        INSERT INTO @checks (check_id, status, message) VALUES ('reseeded', 'Not selected', N'Business data kept; scenarios roll back their own changes.');

    -- 9. Retention: events after 30 days, finished runs after 90 days.
    DELETE FROM demo.scenario_run_events WHERE event_time < DATEADD(day, -30, SYSUTCDATETIME());
    DELETE FROM demo.scenario_runs WHERE status <> 'Running' AND started_at < DATEADD(day, -90, SYSUTCDATETIME());

    SELECT check_id, status, message FROM @checks ORDER BY ordinal;
END;
GO
