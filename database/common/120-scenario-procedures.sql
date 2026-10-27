-- Bounded scenario procedures for the Contoso Care demo (ADR 0010, Phase 11). Run it in the ContosoCare database
-- after 110-demo-control.sql. Idempotent and portable across SQL Server 2022 and Azure SQL Database.
--
-- Every procedure takes the @run_id of a run registered with demo.usp_run_begin, refuses to start unless that run
-- is Running, loops only while SYSUTCDATETIME() < @deadline (the run's deadline), and checks
-- demo.fn_run_should_stop about once a second, so a stop request ends it within a second or two. Business data
-- is never changed for good: blocking, escalation, and deadlock transactions always roll back, the baseline toggles
-- values within their seeded ranges, and the IO, log-rate, log-flush, and capacity scenarios write only to demo
-- scratch tables. The tempdb scenario's #tables belong to its own sessions and are dropped every iteration.
-- Each procedure returns one row of counters, which the runner records as the run's outcome.

-- Healthy baseline -----------------------------------------------------------------------------------------------

-- A steady Contoso Care OLTP mix of short, indexed reads and single-row writes. Also the "normal workload" that
-- runs next to other scenarios, so it accepts any Running run.
CREATE OR ALTER PROCEDURE demo.usp_scenario_healthy_baseline
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 3
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    -- Wait at most 10 seconds for a lock, so a blocking incident delays the baseline without stalling it.
    SET LOCK_TIMEOUT 10000;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = NULL, @deadline_at = @deadline OUTPUT;

    DECLARE @pause datetime = demo.fn_pause(@intensity, 1000, 50);
    DECLARE @patients int, @providers int, @inventory int, @appointments bigint, @work_items bigint;
    DECLARE @iterations bigint = 0, @reads bigint = 0, @writes bigint = 0, @lock_timeouts int = 0, @errors int = 0, @inserted int = 0;
    DECLARE @stopped bit = 0, @next_check datetime2(3) = SYSUTCDATETIME();
    DECLARE @r bigint, @op int, @id bigint, @count int, @amount decimal(14, 2), @mrn varchar(20), @day datetime2(0);

    SELECT @patients = MAX(patient_id) FROM care.patients;
    SELECT @providers = MAX(provider_id) FROM care.providers;
    SELECT @inventory = MAX(inventory_id) FROM care.inventory;
    SELECT @appointments = MAX(appointment_id) FROM care.appointments;
    SELECT @work_items = MAX(work_item_id) FROM care.work_queues;
    IF @patients IS NULL OR @providers IS NULL OR @inventory IS NULL OR @appointments IS NULL OR @work_items IS NULL
        THROW 50140, N'ContosoCare isn''t seeded. Run demo.usp_seed_contosocare first.', 1;

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SET @r = ABS(CAST(CHECKSUM(NEWID()) AS bigint));
        SET @op = CAST(@r % 100 AS int);

        BEGIN TRY
            IF @op < 30
            BEGIN
                -- Front desk: a patient by MRN and their upcoming visits (uq_patients_mrn, ix_appointments_patient).
                SET @mrn = CONCAT('SYN-', RIGHT(CONCAT('0000000', 1 + @r % @patients), 7));
                SELECT @count = COUNT(*)
                FROM care.patients AS p
                INNER JOIN care.appointments AS a ON a.patient_id = p.patient_id
                WHERE p.mrn = @mrn AND a.scheduled_start >= '2026-06-01';
                SET @reads += 1;
            END;
            ELSE IF @op < 50
            BEGIN
                -- Scheduling: one provider's day (ix_appointments_provider).
                SET @id = 1 + @r % @providers;
                SET @day = DATEADD(day, CAST(@r % 365 AS int), CAST('2026-01-01' AS datetime2(0)));
                SELECT @count = COUNT(*)
                FROM care.appointments
                WHERE provider_id = @id AND scheduled_start >= @day AND scheduled_start < DATEADD(day, 1, @day);
                SET @reads += 1;
            END;
            ELSE IF @op < 62
            BEGIN
                -- Billing: one patient's open balance (ix_encounters_patient, then ix_claims_encounter).
                SET @id = 1 + @r % @patients;
                SELECT @amount = SUM(c.billed_amount - c.paid_amount)
                FROM care.encounters AS e
                INNER JOIN care.claims AS c ON c.encounter_id = e.encounter_id
                WHERE e.patient_id = @id;
                SET @reads += 1;
            END;
            ELSE IF @op < 74
            BEGIN
                -- Check-in, or undo one: toggles Scheduled and CheckedIn, so the status mix stays as seeded.
                SET @id = 1 + @r % @appointments;
                UPDATE care.appointments
                SET status = CASE status WHEN 'Scheduled' THEN 'CheckedIn' ELSE 'Scheduled' END
                WHERE appointment_id = @id AND status IN ('Scheduled', 'CheckedIn');
                SET @writes += 1;
            END;
            ELSE IF @op < 86
            BEGIN
                -- Work queue triage: re-prioritize one item (priorities stay within 1 to 5).
                SET @id = 1 + @r % @work_items;
                UPDATE care.work_queues SET priority = CAST(1 + (@r / 7) % 5 AS tinyint) WHERE work_item_id = @id;
                SET @writes += 1;
            END;
            ELSE IF @op < 96
            BEGIN
                -- Supplies: use one unit, or restock above the reorder level.
                SET @id = 1 + @r % @inventory;
                UPDATE care.inventory
                SET quantity_on_hand = CASE WHEN quantity_on_hand <= reorder_level THEN reorder_level + 100 ELSE quantity_on_hand - 1 END,
                    updated_at = SYSUTCDATETIME()
                WHERE inventory_id = @id;
                SET @writes += 1;
            END;
            ELSE
            BEGIN
                -- Audit trail: one synthetic event. Workload rows older than an hour are trimmed, so the table
                -- can't grow without bound, and reset removes the rest.
                INSERT INTO care.audit_events (event_time, actor, entity_type, entity_id, action, details)
                VALUES (SYSUTCDATETIME(), 'ContosoCare.Demo', 'appointment', 1 + @r % @appointments, 'View', N'Synthetic workload event.');
                SET @inserted += 1;
                SET @writes += 1;
                IF @inserted % 500 = 0
                    DELETE TOP (1000) FROM care.audit_events
                    WHERE actor = 'ContosoCare.Demo' AND event_time < DATEADD(hour, -1, SYSUTCDATETIME());
            END;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;
            IF ERROR_NUMBER() IN (1222, 1205)
                SET @lock_timeouts += 1;
            ELSE
            BEGIN
                SET @errors += 1;
                IF @errors >= 25
                    THROW;
            END;
        END CATCH;

        SET @iterations += 1;
        IF SYSUTCDATETIME() >= @next_check
        BEGIN
            SET @stopped = demo.fn_run_should_stop(@run_id);
            SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
        END;
        IF @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY @pause;
    END;

    SELECT worker = @worker, iterations = @iterations, reads = @reads, writes = @writes,
        lock_waits_abandoned = @lock_timeouts, errors = @errors, stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Locking and blocking -------------------------------------------------------------------------------------------

-- The hot rows every locking session fights over: the first @hot_rows Billing work items (1 to 50, so the
-- holder's row locks never escalate to a table lock).
CREATE OR ALTER FUNCTION demo.fn_locking_hot_rows (@hot_rows int)
RETURNS TABLE
AS
RETURN
    SELECT TOP (CASE WHEN @hot_rows BETWEEN 1 AND 50 THEN @hot_rows ELSE 10 END) w.work_item_id
    FROM care.work_queues AS w
    WHERE w.queue_name = 'Billing'
    ORDER BY w.work_item_id;
GO

-- The head blocker, like an application that forgot to commit: updates the hot rows inside the caller's open
-- transaction and returns, leaving the session idle with its row locks. The runner keeps the transaction open for
-- holdSeconds (never past the run's deadline) and then rolls it back, the watchdog rollback; closing the
-- connection rolls it back too.
CREATE OR ALTER PROCEDURE demo.usp_scenario_locking_acquire
    @run_id varchar(64),
    @hot_rows int = 10
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3), @locked int;

    IF @@TRANCOUNT <> 1
        THROW 50141, N'Call this inside exactly one open transaction (BEGIN TRANSACTION first); the runner rolls it back.', 1;
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'locking-blocking', @deadline_at = @deadline OUTPUT;

    UPDATE w
    SET priority = CASE WHEN w.priority >= 5 THEN 1 ELSE w.priority + 1 END
    FROM care.work_queues AS w
    WHERE w.work_item_id IN (SELECT h.work_item_id FROM demo.fn_locking_hot_rows(@hot_rows) AS h);
    SET @locked = @@ROWCOUNT;

    SELECT session_id = @@SPID, locked_rows = @locked, deadline_at = @deadline;
END;
GO

-- The same head blocker as a self-contained procedure, for SSMS or sqlcmd demos without the runner: holds the
-- hot rows for @hold_seconds (never past the run's deadline, and it stops early on a stop request), then always
-- rolls back.
CREATE OR ALTER PROCEDURE demo.usp_scenario_locking_hold
    @run_id varchar(64),
    @hold_seconds int = 120,
    @hot_rows int = 10
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3), @hold_until datetime2(3), @started datetime2(7), @locked int, @stopped bit = 0;

    IF @hold_seconds IS NULL OR @hold_seconds NOT BETWEEN 1 AND 900
        THROW 50142, N'@hold_seconds must be between 1 and 900.', 1;
    IF @@TRANCOUNT <> 0
        THROW 50143, N'Call this outside a transaction; it opens and rolls back its own.', 1;
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'locking-blocking', @deadline_at = @deadline OUTPUT;

    SET @started = SYSUTCDATETIME();
    SET @hold_until = DATEADD(second, @hold_seconds, @started);
    IF @hold_until > @deadline
        SET @hold_until = @deadline;

    EXEC demo.usp_run_event @run_id = @run_id, @event_name = 'holder-acquiring', @session_id = @@SPID, @detail = N'demo.usp_scenario_locking_hold';

    BEGIN TRANSACTION;

    UPDATE w
    SET priority = CASE WHEN w.priority >= 5 THEN 1 ELSE w.priority + 1 END
    FROM care.work_queues AS w
    WHERE w.work_item_id IN (SELECT h.work_item_id FROM demo.fn_locking_hot_rows(@hot_rows) AS h);
    SET @locked = @@ROWCOUNT;

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @hold_until
    BEGIN
        WAITFOR DELAY '00:00:01';
        SET @stopped = demo.fn_run_should_stop(@run_id);
    END;

    -- The watchdog rollback: the holder never commits.
    ROLLBACK TRANSACTION;

    EXEC demo.usp_run_event @run_id = @run_id, @event_name = 'holder-rolled-back', @session_id = @@SPID, @detail = N'demo.usp_scenario_locking_hold';

    SELECT session_id = @@SPID, locked_rows = @locked, held_ms = DATEDIFF(millisecond, @started, SYSUTCDATETIME()), stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- A blocked session: a billing clerk who keeps trying to claim a hot work item. Each attempt waits at most 20
-- seconds for the lock (less near the deadline), and the change is rolled back, so it only probes. The UPDATE
-- waits under row versioning too, and the READCOMMITTEDLOCK read shows a blocked reader. The list of hot item IDs
-- is read once, without waiting on the holder's locks (the IDs never change), so only the claim itself blocks.
CREATE OR ALTER PROCEDURE demo.usp_scenario_locking_contend
    @run_id varchar(64),
    @worker int = 1,
    @hot_rows int = 10
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'locking-blocking', @deadline_at = @deadline OUTPUT;

    DECLARE @hot TABLE (ordinal int IDENTITY(0, 1) PRIMARY KEY, work_item_id bigint NOT NULL);
    DECLARE @rows int, @id bigint, @found int, @remaining_ms int, @started datetime2(7), @wait_ms int;
    DECLARE @attempts int = 0, @acquired int = 0, @timeouts int = 0, @deadlocks int = 0, @longest_wait_ms int = 0;
    DECLARE @waited_ms bigint = 0, @stopped bit = 0, @next_check datetime2(3) = SYSUTCDATETIME();

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    INSERT INTO @hot (work_item_id)
    SELECT h.work_item_id FROM demo.fn_locking_hot_rows(@hot_rows) AS h ORDER BY h.work_item_id;
    SET @rows = @@ROWCOUNT;
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    IF @rows = 0
        THROW 50144, N'No Billing work items to contend for. Is ContosoCare seeded?', 1;

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SELECT @id = work_item_id FROM @hot WHERE ordinal = (@worker + @attempts) % @rows;

        SET @remaining_ms = DATEDIFF(millisecond, SYSUTCDATETIME(), @deadline);
        IF @remaining_ms >= 20000
            SET LOCK_TIMEOUT 20000;
        ELSE IF @remaining_ms >= 5000
            SET LOCK_TIMEOUT 5000;
        ELSE
            SET LOCK_TIMEOUT 1000;

        SET @started = SYSUTCDATETIME();
        BEGIN TRY
            BEGIN TRANSACTION;
            UPDATE care.work_queues SET status = 'InProgress', assigned_to = NULL WHERE work_item_id = @id;
            SELECT @found = COUNT(*) FROM care.work_queues WITH (READCOMMITTEDLOCK) WHERE work_item_id = @id;
            ROLLBACK TRANSACTION;
            SET @acquired += 1;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;
            IF ERROR_NUMBER() = 1222
                SET @timeouts += 1;
            ELSE IF ERROR_NUMBER() = 1205
                SET @deadlocks += 1;
            ELSE
                THROW;
        END CATCH;

        SET @wait_ms = DATEDIFF(millisecond, @started, SYSUTCDATETIME());
        IF @wait_ms < 0
            SET @wait_ms = 0;
        SET @waited_ms += @wait_ms;
        IF @wait_ms > @longest_wait_ms
            SET @longest_wait_ms = @wait_ms;
        SET @attempts += 1;

        IF SYSUTCDATETIME() >= @next_check
        BEGIN
            SET @stopped = demo.fn_run_should_stop(@run_id);
            SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
        END;
        IF @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY '00:00:00.500';
    END;

    SELECT worker = @worker, session_id = @@SPID, attempts = @attempts, acquired = @acquired, lock_timeouts = @timeouts,
        deadlock_victims = @deadlocks, waited_ms = @waited_ms, longest_wait_ms = @longest_wait_ms, stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- The optional, bounded deadlock: two sessions lock two inventory rows in opposite order. Side 2 runs at
-- DEADLOCK_PRIORITY LOW, so it's the victim; both sides always roll back. At most three rounds.
CREATE OR ALTER PROCEDURE demo.usp_scenario_locking_deadlock
    @run_id varchar(64),
    @side tinyint = 1,
    @rounds int = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 30000;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'locking-blocking', @deadline_at = @deadline OUTPUT;

    IF @side IS NULL OR @side NOT IN (1, 2)
        THROW 50145, N'@side must be 1 or 2.', 1;
    IF @rounds IS NULL OR @rounds NOT BETWEEN 1 AND 3
        THROW 50146, N'@rounds must be between 1 and 3.', 1;
    IF @side = 2
        SET DEADLOCK_PRIORITY LOW;

    DECLARE @first int = CASE @side WHEN 1 THEN 1 ELSE 2 END;
    DECLARE @second int = CASE @side WHEN 1 THEN 2 ELSE 1 END;
    DECLARE @remaining int = @rounds, @completed int = 0, @victim int = 0, @timeouts int = 0, @stopped bit = 0;

    WHILE @remaining > 0 AND @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SET @remaining -= 1;
        BEGIN TRY
            BEGIN TRANSACTION;
            UPDATE care.inventory SET updated_at = SYSUTCDATETIME() WHERE inventory_id = @first;
            WAITFOR DELAY '00:00:02';
            UPDATE care.inventory SET updated_at = SYSUTCDATETIME() WHERE inventory_id = @second;
            ROLLBACK TRANSACTION;
            SET @completed += 1;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;
            IF ERROR_NUMBER() = 1205
            BEGIN
                SET @victim += 1;
                EXEC demo.usp_run_event @run_id = @run_id, @event_name = 'deadlock-victim', @session_id = @@SPID, @detail = N'Error 1205; the transaction was rolled back.';
            END;
            ELSE IF ERROR_NUMBER() = 1222
                SET @timeouts += 1;
            ELSE
                THROW;
        END CATCH;

        SET @stopped = demo.fn_run_should_stop(@run_id);
        IF @remaining > 0 AND @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY '00:00:03';
    END;

    SELECT side = @side, session_id = @@SPID, rounds = @rounds - @remaining, completed = @completed,
        deadlock_victim = @victim, lock_timeouts = @timeouts, stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- CPU pressure ---------------------------------------------------------------------------------------------------

-- A double-booking audit. 'problem': the overlap test wraps both columns in DATEDIFF, so it can't seek on
-- ix_appointments_provider's scheduled_start key and compares every pair of a provider's appointments, a
-- bounded but expensive plan. 'healthy': the same question as a range on scheduled_start, joined with nested
-- loops so each appointment seeks the index for its few neighbours (the optimizer otherwise picks a hash join
-- that still compares every pair). @intensity sets how many providers each execution covers (4 per level).
CREATE OR ALTER PROCEDURE demo.usp_scenario_cpu_pressure
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 5,
    @variant varchar(16) = 'problem'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'cpu-pressure', @deadline_at = @deadline OUTPUT;

    IF @variant IS NULL OR @variant NOT IN ('problem', 'healthy')
        THROW 50147, N'@variant must be problem or healthy.', 1;

    DECLARE @providers int, @span int, @first int, @overlaps bigint, @total_overlaps bigint = 0, @executions int = 0;
    DECLARE @stopped bit = 0, @started datetime2(7), @busy_ms bigint = 0;

    SELECT @providers = MAX(provider_id) FROM care.providers;
    IF @providers IS NULL
        THROW 50140, N'ContosoCare isn''t seeded. Run demo.usp_seed_contosocare first.', 1;
    SET @span = 4 * CASE WHEN @intensity BETWEEN 1 AND 10 THEN @intensity ELSE 5 END;
    IF @span > @providers
        SET @span = @providers;

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SET @first = 1 + ABS(CHECKSUM(NEWID())) % (@providers - @span + 1);
        SET @started = SYSUTCDATETIME();

        IF @variant = 'problem'
            SELECT @overlaps = COUNT_BIG(*)
            FROM care.appointments AS a1
            INNER JOIN care.appointments AS a2
                ON a2.provider_id = a1.provider_id
               AND a2.appointment_id <> a1.appointment_id
            WHERE a1.provider_id BETWEEN @first AND @first + @span - 1
              AND a1.status <> 'Cancelled'
              AND a2.status <> 'Cancelled'
              AND DATEDIFF(minute, a1.scheduled_start, a2.scheduled_start) >= 0
              AND DATEDIFF(minute, a1.scheduled_start, a2.scheduled_start) < a1.duration_minutes
            OPTION (MAXDOP 1);
        ELSE
            SELECT @overlaps = COUNT_BIG(*)
            FROM care.appointments AS a1
            INNER JOIN care.appointments AS a2
                ON a2.provider_id = a1.provider_id
               AND a2.scheduled_start >= a1.scheduled_start
               AND a2.scheduled_start < DATEADD(minute, a1.duration_minutes, a1.scheduled_start)
               AND a2.appointment_id <> a1.appointment_id
            WHERE a1.provider_id BETWEEN @first AND @first + @span - 1
              AND a1.status <> 'Cancelled'
              AND a2.status <> 'Cancelled'
            OPTION (MAXDOP 1, LOOP JOIN);

        SET @busy_ms += DATEDIFF(millisecond, @started, SYSUTCDATETIME());
        SET @total_overlaps += @overlaps;
        SET @executions += 1;
        SET @stopped = demo.fn_run_should_stop(@run_id);
        IF @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY '00:00:00.200';
    END;

    SELECT worker = @worker, variant = @variant, executions = @executions, overlaps_found = @total_overlaps,
        avg_execution_ms = CASE WHEN @executions = 0 THEN 0 ELSE @busy_ms / @executions END, stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- IO pressure ----------------------------------------------------------------------------------------------------

-- Grows demo.io_scratch to @scratch_mb for io-pressure and capacity-max, which share it (Phase 25b). An exclusive,
-- session-owned application lock makes concurrent growers take turns, the free-space check against the file caps
-- runs first, and the growth stops at @deadline_at or on a stop request, 8 MB per statement. A run that can't get
-- the lock within a minute uses the rows already there. Returns the MB written in @written_mb.
CREATE OR ALTER PROCEDURE demo.usp_io_scratch_grow
    @run_id varchar(64),
    @scratch_mb int,
    @deadline_at datetime2(3),
    @written_mb int = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3) = @deadline_at;
    DECLARE @target_rows int = @scratch_mb * 128, @rows int, @batch int, @needed_mb int, @lock int;
    DECLARE @stopped bit = 0, @next_check datetime2(3) = SYSUTCDATETIME();

    SET @written_mb = 0;
    IF @scratch_mb IS NULL OR @scratch_mb NOT BETWEEN 64 AND 6144
        THROW 50148, N'@scratch_mb must be between 64 and 6144.', 1;

    EXEC @lock = sys.sp_getapplock @Resource = N'ContosoCare.Demo/io_scratch', @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 60000;
    IF @lock < 0
    BEGIN
        EXEC demo.usp_run_event @run_id = @run_id, @event_name = 'scratch-busy', @session_id = @@SPID,
            @detail = N'Another run kept demo.io_scratch locked for a minute; this run uses the rows already there.';
        RETURN;
    END;

    BEGIN TRY
        SELECT @rows = ISNULL(MAX(scratch_id), 0) FROM demo.io_scratch;
        IF @rows < @target_rows
        BEGIN
            SET @needed_mb = (@target_rows - @rows) / 128 + 1;
            EXEC demo.usp_check_space @required_data_mb = @needed_mb, @required_log_mb = 64, @raise = 1;
            EXEC demo.usp_run_event @run_id = @run_id, @event_name = 'scratch-growing', @session_id = @@SPID,
                @detail = N'demo.io_scratch grows toward @scratch_mb after the free-space check passed.';

            WHILE @stopped = 0 AND @rows < @target_rows AND SYSUTCDATETIME() < @deadline
            BEGIN
                SET @batch = CASE WHEN @target_rows - @rows < 1024 THEN @target_rows - @rows ELSE 1024 END;
                INSERT INTO demo.io_scratch (scratch_id, run_id, written_at, payload)
                SELECT @rows + n.n, @run_id, SYSUTCDATETIME(), REPLICATE(CHAR(65 + n.n % 26), 7000)
                FROM demo.fn_numbers(@batch) AS n;
                SET @rows += @batch;
                SET @written_mb += @batch / 128;

                IF SYSUTCDATETIME() >= @next_check
                BEGIN
                    SET @stopped = demo.fn_run_should_stop(@run_id);
                    SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
                END;
            END;
        END;

        EXEC sys.sp_releaseapplock @Resource = N'ContosoCare.Demo/io_scratch', @LockOwner = 'Session';
    END TRY
    BEGIN CATCH
        IF APPLOCK_MODE('public', N'ContosoCare.Demo/io_scratch', 'Session') <> 'NoLock'
            EXEC sys.sp_releaseapplock @Resource = N'ContosoCare.Demo/io_scratch', @LockOwner = 'Session';
        THROW;
    END CATCH;
END;
GO

-- Worker 1 first grows demo.io_scratch to @scratch_mb (demo.usp_io_scratch_grow, after the free-space check
-- confirms the headroom under the file caps, with a margin), 8 MB per statement. Then every worker alternates range
-- scans of up to 256 MB (read IO, physical once the scratch set no longer fits in memory) with 16 MB range updates
-- (dirty pages that checkpoints write). Nothing grows past @scratch_mb, and the scratch set is reused by later runs.
CREATE OR ALTER PROCEDURE demo.usp_scenario_io_pressure
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 5,
    @scratch_mb int = 1024
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'io-pressure', @deadline_at = @deadline OUTPUT;

    IF @scratch_mb IS NULL OR @scratch_mb NOT BETWEEN 64 AND 6144
        THROW 50148, N'@scratch_mb must be between 64 and 6144.', 1;

    DECLARE @pause datetime = demo.fn_pause(@intensity, 2000, 50);
    DECLARE @rows int, @start int, @span int, @pages bigint, @touched bigint;
    DECLARE @written_mb int = 0, @read_mb bigint = 0, @updated_mb bigint = 0, @scans int = 0, @updates int = 0, @iterations int = 0;
    DECLARE @stopped bit = 0, @next_check datetime2(3) = SYSUTCDATETIME();

    IF @worker = 1
        EXEC demo.usp_io_scratch_grow @run_id = @run_id, @scratch_mb = @scratch_mb, @deadline_at = @deadline, @written_mb = @written_mb OUTPUT;

    SELECT @rows = ISNULL(MAX(scratch_id), 0) FROM demo.io_scratch;
    SET @stopped = demo.fn_run_should_stop(@run_id);

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SELECT @rows = ISNULL(MAX(scratch_id), 0) FROM demo.io_scratch;
        IF @rows > 0
        BEGIN
            SET @span = CASE WHEN @rows < 32768 THEN @rows ELSE 32768 END;
            SET @start = 1 + ABS(CHECKSUM(NEWID())) % (@rows - @span + 1);
            IF (@iterations + @worker) % 4 = 0
            BEGIN
                UPDATE demo.io_scratch
                SET touched = touched + 1, written_at = SYSUTCDATETIME()
                WHERE scratch_id BETWEEN @start AND @start + 2047;
                SET @updated_mb += @@ROWCOUNT / 128;
                SET @updates += 1;
            END;
            ELSE
            BEGIN
                SELECT @pages = COUNT_BIG(*), @touched = SUM(CAST(touched AS bigint))
                FROM demo.io_scratch
                WHERE scratch_id BETWEEN @start AND @start + @span - 1
                OPTION (MAXDOP 1);
                SET @read_mb += @pages / 128;
                SET @scans += 1;
            END;
        END;

        SET @iterations += 1;
        IF SYSUTCDATETIME() >= @next_check
        BEGIN
            SET @stopped = demo.fn_run_should_stop(@run_id);
            SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
        END;
        IF @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY @pause;
    END;

    SELECT worker = @worker, scratch_mb = @rows / 128, written_mb = @written_mb, scanned_mb = @read_mb,
        updated_mb = @updated_mb, scans = @scans, updates = @updates, stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Missing index --------------------------------------------------------------------------------------------------

-- Repeatable lookups that no index covers: claims aging by payer and submission date, and visits by reason code.
-- Each call scans its table, and the optimizer records a missing-index suggestion. The remediation,
-- scenarios/missing-index/remediation.sql, is never applied automatically; demo.usp_undo_missing_index_remediation
-- (or reset -UndoRemediation) restores the "before" state.
CREATE OR ALTER PROCEDURE demo.usp_scenario_missing_index
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'missing-index', @deadline_at = @deadline OUTPUT;

    DECLARE @pause datetime = demo.fn_pause(@intensity, 1000, 20);
    DECLARE @r bigint, @payer varchar(20), @reason varchar(20), @from date, @claims int, @billed decimal(14, 2), @open int, @visits int;
    DECLARE @claim_lookups int = 0, @reason_lookups int = 0, @iterations int = 0, @stopped bit = 0, @next_check datetime2(3) = SYSUTCDATETIME();

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SET @r = ABS(CAST(CHECKSUM(NEWID()) AS bigint));
        SET @from = DATEADD(day, CAST(@r % 330 AS int), CAST('2026-01-01' AS date));

        IF @iterations % 4 <> 3
        BEGIN
            SET @payer = CHOOSE(1 + CAST(@r % 5 AS int), 'PAYER-A', 'PAYER-B', 'PAYER-C', 'PAYER-D', 'SELF-PAY');
            SELECT
                @claims = COUNT(*),
                @billed = SUM(billed_amount),
                @open = SUM(CASE WHEN claim_status IN ('Submitted', 'Appealed') THEN 1 ELSE 0 END)
            FROM care.claims
            WHERE payer_code = @payer
              AND submitted_on >= @from
              AND submitted_on < DATEADD(day, 30, @from);
            SET @claim_lookups += 1;
        END;
        ELSE
        BEGIN
            SET @reason = CONCAT('SYN-R', RIGHT(CONCAT('00', @r % 50), 2));
            SELECT @visits = COUNT(*)
            FROM care.appointments
            WHERE reason_code = @reason
              AND scheduled_start >= @from
              AND scheduled_start < DATEADD(day, 30, @from);
            SET @reason_lookups += 1;
        END;

        SET @iterations += 1;
        IF SYSUTCDATETIME() >= @next_check
        BEGIN
            SET @stopped = demo.fn_run_should_stop(@run_id);
            SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
        END;
        IF @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY @pause;
    END;

    SELECT worker = @worker, claim_lookups = @claim_lookups, reason_lookups = @reason_lookups,
        remediation_present = CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_claims_payer_submitted' AND object_id = OBJECT_ID(N'care.claims')) THEN 1 ELSE 0 END AS bit),
        stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Inefficient query ----------------------------------------------------------------------------------------------

-- A frequent front-desk lookup by the numeric part of the MRN. 'problem': RIGHT() on the indexed column hides it
-- from uq_patients_mrn, so every call scans care.patients (high reads per execution, high execution count).
-- 'healthy': the same lookup on the full MRN, which seeks. Compare the two in Query Store.
CREATE OR ALTER PROCEDURE demo.usp_scenario_inefficient_query
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 5,
    @variant varchar(16) = 'problem'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'inefficient-query', @deadline_at = @deadline OUTPUT;

    IF @variant IS NULL OR @variant NOT IN ('problem', 'healthy')
        THROW 50147, N'@variant must be problem or healthy.', 1;

    DECLARE @pause datetime = demo.fn_pause(@intensity, 500, 0);
    DECLARE @patients int, @r bigint, @digits varchar(7), @from datetime2(0), @visits int, @next_visit datetime2(0);
    DECLARE @lookups bigint = 0, @stopped bit = 0, @next_check datetime2(3) = SYSUTCDATETIME();

    SELECT @patients = MAX(patient_id) FROM care.patients;
    IF @patients IS NULL
        THROW 50140, N'ContosoCare isn''t seeded. Run demo.usp_seed_contosocare first.', 1;

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SET @r = ABS(CAST(CHECKSUM(NEWID()) AS bigint));
        SET @digits = RIGHT(CONCAT('0000000', 1 + @r % @patients), 7);
        SET @from = DATEADD(day, CAST(@r % 300 AS int), CAST('2026-01-01' AS datetime2(0)));

        IF @variant = 'problem'
            SELECT @visits = COUNT(*), @next_visit = MIN(a.scheduled_start)
            FROM care.patients AS p
            INNER JOIN care.appointments AS a ON a.patient_id = p.patient_id
            WHERE RIGHT(p.mrn, 7) = @digits
              AND a.scheduled_start >= @from;
        ELSE
            SELECT @visits = COUNT(*), @next_visit = MIN(a.scheduled_start)
            FROM care.patients AS p
            INNER JOIN care.appointments AS a ON a.patient_id = p.patient_id
            WHERE p.mrn = CONCAT('SYN-', @digits)
              AND a.scheduled_start >= @from;

        SET @lookups += 1;
        IF SYSUTCDATETIME() >= @next_check
        BEGIN
            SET @stopped = demo.fn_run_should_stop(@run_id);
            SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
        END;
        IF @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY @pause;
    END;

    SELECT worker = @worker, variant = @variant, lookups = @lookups, stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Resource governance (Azure SQL Database flavour) ------------------------------------------------------------------

-- Sustained, well-planned reporting at more concurrency than the target has vCores: a full utilization rollup
-- with a per-row scoring hash, parallelism allowed. On Azure SQL Database it drives CPU to the service
-- objective's limit; on SQL Server it's plain CPU saturation. The plans are sound, so the fix is capacity or
-- scheduling, not a rewrite. @intensity sets the hashing work per row and shortens the pause.
CREATE OR ALTER PROCEDURE demo.usp_scenario_resource_governance
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 6
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'resource-governance', @deadline_at = @deadline OUTPUT;

    DECLARE @level int = CASE WHEN @intensity BETWEEN 1 AND 10 THEN @intensity ELSE 6 END;
    DECLARE @repeat int = 1 + @level / 3;
    DECLARE @pause datetime = demo.fn_pause(@intensity, 1000, 10);
    DECLARE @rows bigint, @score bigint, @reports int = 0, @busy_ms bigint = 0, @started datetime2(7);
    DECLARE @stopped bit = 0, @next_check datetime2(3) = SYSUTCDATETIME();

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SET @started = SYSUTCDATETIME();

        SELECT
            @rows = COUNT_BIG(*),
            @score = SUM(CAST(CAST(SUBSTRING(HASHBYTES('SHA2_256', CONCAT(a.appointment_id, ':', a.provider_id, ':', e.diagnosis_code, ':', k.k, ':', @worker)), 1, 4) AS int) AS bigint) % 1000)
        FROM care.appointments AS a
        INNER JOIN care.encounters AS e ON e.appointment_id = a.appointment_id
        CROSS JOIN (VALUES (1), (2), (3), (4)) AS k (k)
        WHERE k.k <= @repeat;

        SET @busy_ms += DATEDIFF(millisecond, @started, SYSUTCDATETIME());
        SET @reports += 1;
        IF SYSUTCDATETIME() >= @next_check
        BEGIN
            SET @stopped = demo.fn_run_should_stop(@run_id);
            SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
        END;
        IF @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY @pause;
    END;

    SELECT worker = @worker, reports = @reports, avg_report_ms = CASE WHEN @reports = 0 THEN 0 ELSE @busy_ms / @reports END,
        stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Log-rate pressure (Azure SQL Database flavour) ------------------------------------------------------------------

-- Write-heavy batches of 3,000-byte rows into demo.log_rate_scratch, each deleted right after it commits, so the
-- table stays small while the log keeps working. The run asks for 2 MB of log per second per intensity level
-- (unthrottled at 10), shared by its workers. On Azure SQL Database, more than the service objective's log rate
-- shows as LOG_RATE_GOVERNOR waits; on SQL Server it shows as WRITELOG waits and log flushes. Each worker stops
-- after its share of @max_log_mb (an estimate: about 6.3 KB of log per row inserted and deleted), at the
-- deadline, or on a stop request, whichever comes first.
CREATE OR ALTER PROCEDURE demo.usp_scenario_log_rate_pressure
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 5,
    @max_log_mb int = 2048
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'log-rate-pressure', @deadline_at = @deadline OUTPUT;

    IF @max_log_mb IS NULL OR @max_log_mb NOT BETWEEN 64 AND 8192
        THROW 50149, N'@max_log_mb must be between 64 and 8192.', 1;

    DECLARE @workers int, @budget_mb decimal(18, 2), @written_mb decimal(18, 2) = 0, @rows_per_batch int = 256, @batches int = 0;
    DECLARE @level int = CASE WHEN @intensity BETWEEN 1 AND 10 THEN @intensity ELSE 5 END;
    DECLARE @rate_mb decimal(18, 4), @allowed_mb decimal(18, 2), @ahead_ms int, @wait datetime, @began datetime2(7) = SYSUTCDATETIME();
    DECLARE @stopped bit = 0, @next_check datetime2(3) = SYSUTCDATETIME();

    SELECT @workers = concurrency FROM demo.scenario_runs WHERE run_id = @run_id;
    IF @workers IS NULL OR @workers < 1
        SET @workers = 1;
    SET @budget_mb = CAST(@max_log_mb AS decimal(18, 2)) / @workers;
    SET @rate_mb = CASE WHEN @level >= 10 THEN NULL ELSE @level * 2.0 / @workers END;

    EXEC demo.usp_check_space @required_data_mb = 64, @required_log_mb = 256, @raise = 1;

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline AND @written_mb < @budget_mb
    BEGIN
        BEGIN TRANSACTION;
        INSERT INTO demo.log_rate_scratch (run_id, worker, written_at, payload)
        SELECT @run_id, @worker, SYSUTCDATETIME(), REPLICATE('L', 3000)
        FROM demo.fn_numbers(@rows_per_batch) AS n;
        COMMIT TRANSACTION;

        DELETE FROM demo.log_rate_scratch WHERE run_id = @run_id AND worker = @worker;

        SET @written_mb += @rows_per_batch * 6.3 / 1024.0;
        SET @batches += 1;
        IF SYSUTCDATETIME() >= @next_check
        BEGIN
            SET @stopped = demo.fn_run_should_stop(@run_id);
            SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
        END;

        -- Pace to the requested rate: wait (at most 2 seconds at a time) while ahead of it.
        IF @stopped = 0 AND @rate_mb IS NOT NULL
        BEGIN
            SET @allowed_mb = @rate_mb * DATEDIFF(millisecond, @began, SYSUTCDATETIME()) / 1000.0;
            IF @written_mb > @allowed_mb
            BEGIN
                SET @ahead_ms = CAST((@written_mb - @allowed_mb) / @rate_mb * 1000 AS int);
                IF @ahead_ms > 2000
                    SET @ahead_ms = 2000;
                SET @wait = DATEADD(millisecond, @ahead_ms, CAST(0 AS datetime));
                IF SYSUTCDATETIME() < @deadline
                    WAITFOR DELAY @wait;
            END;
        END;
    END;

    SELECT worker = @worker, batches = @batches, log_mb_estimate = CAST(@written_mb AS int),
        budget_reached = CAST(CASE WHEN @written_mb >= @budget_mb THEN 1 ELSE 0 END AS bit), stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Blocking chain and lock escalation (Phase 25b) --------------------------------------------------------------------

-- The rows a blocking chain locks: the first 21 Scheduling work items in ID order, apart from locking-blocking's
-- Billing rows. Ordinal 0 is the head blocker's row. Level L (2 to 6) of branch B (1 to 4) owns ordinal
-- (L - 2) * 4 + B and waits for its parent's row: ordinal 0 at level 2, ordinal (L - 3) * 4 + B deeper down. The IDs
-- are read without locks (READUNCOMMITTED): they never change, and a locked chain row must not block the lookup.
CREATE OR ALTER FUNCTION demo.fn_chain_rows ()
RETURNS TABLE
AS
RETURN
    SELECT TOP (21) ordinal = CAST(ROW_NUMBER() OVER (ORDER BY w.work_item_id) - 1 AS int), w.work_item_id
    FROM care.work_queues AS w WITH (READUNCOMMITTED)
    WHERE w.queue_name = 'Scheduling'
    ORDER BY w.work_item_id;
GO

-- The chain's head blocker, like an application that forgot to commit: updates the head row inside the caller's
-- open transaction and returns, leaving the session idle with its lock. The runner keeps the transaction open for
-- holdSeconds (never past the run's deadline) and then rolls it back; closing the connection rolls it back too.
CREATE OR ALTER PROCEDURE demo.usp_scenario_chain_acquire
    @run_id varchar(64)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3), @head bigint, @locked int;

    IF @@TRANCOUNT <> 1
        THROW 50150, N'Call this inside exactly one open transaction (BEGIN TRANSACTION first); the runner rolls it back.', 1;
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'blocking-chain', @deadline_at = @deadline OUTPUT;

    SELECT @head = work_item_id FROM demo.fn_chain_rows() WHERE ordinal = 0;
    IF @head IS NULL
        THROW 50151, N'No Scheduling work items for the chain. Is ContosoCare seeded?', 1;

    UPDATE care.work_queues
    SET priority = CASE WHEN priority >= 5 THEN 1 ELSE priority + 1 END
    WHERE work_item_id = @head;
    SET @locked = @@ROWCOUNT;

    SELECT session_id = @@SPID, locked_rows = @locked, deadline_at = @deadline;
END;
GO

-- One link of a blocking chain: it locks its own row, then waits for its parent's row, so the links below it wait
-- for it in turn (head blocker <- level 2 <- level 3 ...). Each wait lasts at most 60 seconds (less near the
-- deadline), and every change rolls back. When its parent lets go, the link rolls back and tries again a second
-- later, so the chain forms again every time the head blocker locks its row.
CREATE OR ALTER PROCEDURE demo.usp_scenario_chain_link
    @run_id varchar(64),
    @level int = 2,
    @branch int = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'blocking-chain', @deadline_at = @deadline OUTPUT;

    IF @level IS NULL OR @level NOT BETWEEN 2 AND 6
        THROW 50152, N'@level must be between 2 and 6.', 1;
    IF @branch IS NULL OR @branch NOT BETWEEN 1 AND 4
        THROW 50153, N'@branch must be between 1 and 4.', 1;

    DECLARE @own bigint, @parent bigint, @remaining_ms int, @started datetime2(7), @wait_ms int;
    DECLARE @attempts int = 0, @acquired int = 0, @timeouts int = 0, @deadlocks int = 0, @longest_wait_ms int = 0;
    DECLARE @waited_ms bigint = 0, @stopped bit = 0;

    SELECT @own = work_item_id FROM demo.fn_chain_rows() WHERE ordinal = (@level - 2) * 4 + @branch;
    SELECT @parent = work_item_id FROM demo.fn_chain_rows() WHERE ordinal = CASE WHEN @level = 2 THEN 0 ELSE (@level - 3) * 4 + @branch END;
    IF @own IS NULL OR @parent IS NULL
        THROW 50151, N'No Scheduling work items for the chain. Is ContosoCare seeded?', 1;

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SET @remaining_ms = DATEDIFF(millisecond, SYSUTCDATETIME(), @deadline);
        IF @remaining_ms >= 60000
            SET LOCK_TIMEOUT 60000;
        ELSE IF @remaining_ms >= 20000
            SET LOCK_TIMEOUT 20000;
        ELSE IF @remaining_ms >= 5000
            SET LOCK_TIMEOUT 5000;
        ELSE
            SET LOCK_TIMEOUT 1000;

        SET @started = SYSUTCDATETIME();
        BEGIN TRY
            BEGIN TRANSACTION;
            UPDATE care.work_queues SET priority = CASE WHEN priority >= 5 THEN 1 ELSE priority + 1 END WHERE work_item_id = @own;
            UPDATE care.work_queues SET priority = CASE WHEN priority >= 5 THEN 1 ELSE priority + 1 END WHERE work_item_id = @parent;
            ROLLBACK TRANSACTION;
            SET @acquired += 1;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;
            IF ERROR_NUMBER() = 1222
                SET @timeouts += 1;
            ELSE IF ERROR_NUMBER() = 1205
                SET @deadlocks += 1;
            ELSE
                THROW;
        END CATCH;

        SET @wait_ms = DATEDIFF(millisecond, @started, SYSUTCDATETIME());
        IF @wait_ms < 0
            SET @wait_ms = 0;
        SET @waited_ms += @wait_ms;
        IF @wait_ms > @longest_wait_ms
            SET @longest_wait_ms = @wait_ms;
        SET @attempts += 1;

        SET @stopped = demo.fn_run_should_stop(@run_id);
        -- A second's pause: the level below takes this row, and the head blocker locks its row again.
        IF @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY '00:00:01';
    END;

    SELECT level = @level, branch = @branch, session_id = @@SPID, attempts = @attempts, acquired = @acquired,
        lock_timeouts = @timeouts, deadlock_victims = @deadlocks, waited_ms = @waited_ms, longest_wait_ms = @longest_wait_ms,
        stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Lock escalation beside the chain: every @every_seconds (the first time 20 seconds in), one transaction updates
-- @rows consecutive appointments in a single statement with row locks. Past 5,000 locks on the table (documented;
-- measured from about 6,200 rows on SQL Server 2025 LocalDB, so at least 7,000 here) SQL Server escalates them to
-- one table lock, which blocks every other session that touches care.appointments (readers too, unless they use
-- row versioning, as Azure SQL Database does) until the holder rolls back @hold_seconds later. With optimized
-- locking (always on in Azure SQL Database) the update holds one transaction-ID lock instead of row locks, so it
-- doesn't escalate there, and the sessions it blocks wait on that lock (LCK_M_*_XACT). Every change rolls back.
-- Whether the escalation happened is read from sys.dm_tran_locks when the caller may see it, and recorded after the
-- rollback as a lock-escalation event.
CREATE OR ALTER PROCEDURE demo.usp_scenario_chain_escalate
    @run_id varchar(64),
    @rows int = 10000,
    @hold_seconds int = 15,
    @every_seconds int = 120
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'blocking-chain', @deadline_at = @deadline OUTPUT;

    IF @rows IS NULL OR @rows NOT BETWEEN 7000 AND 20000
        THROW 50154, N'@rows must be between 7000 and 20000.', 1;
    IF @hold_seconds IS NULL OR @hold_seconds NOT BETWEEN 5 AND 60
        THROW 50155, N'@hold_seconds must be between 5 and 60.', 1;
    IF @every_seconds IS NULL OR @every_seconds NOT BETWEEN 30 AND 600
        THROW 50156, N'@every_seconds must be between 30 and 600.', 1;

    DECLARE @max_id bigint, @first bigint, @locked int, @escalated bit, @next_until datetime2(3), @hold_until datetime2(3);
    DECLARE @attempts int = 0, @table_locks int = 0, @rows_locked bigint = 0, @held_ms bigint = 0, @timeouts int = 0, @deadlocks int = 0;
    DECLARE @stopped bit = 0, @can_view bit = demo.fn_can_view_sessions(), @started datetime2(7), @held int, @outcome nvarchar(100), @detail nvarchar(400);

    SELECT @max_id = MAX(appointment_id) FROM care.appointments;
    IF @max_id IS NULL OR @max_id < @rows
        THROW 50157, N'Not enough appointments for the lock escalation. Is ContosoCare seeded?', 1;

    SET @next_until = DATEADD(second, 20, SYSUTCDATETIME());
    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        WHILE @stopped = 0 AND SYSUTCDATETIME() < @next_until AND SYSUTCDATETIME() < @deadline
        BEGIN
            WAITFOR DELAY '00:00:01';
            SET @stopped = demo.fn_run_should_stop(@run_id);
        END;

        -- Never start an escalation that couldn't finish before the deadline.
        IF @stopped = 1 OR SYSUTCDATETIME() >= DATEADD(second, -(@hold_seconds + 5), @deadline)
            BREAK;

        SET @first = 1 + ABS(CHECKSUM(NEWID())) % (@max_id - @rows + 1);
        SET @locked = 0;
        SET @escalated = NULL;
        SET @held = 0;
        SET @outcome = N'held';
        SET LOCK_TIMEOUT 20000;
        SET @started = SYSUTCDATETIME();
        BEGIN TRY
            BEGIN TRANSACTION;
            UPDATE care.appointments WITH (ROWLOCK)
            SET duration_minutes = duration_minutes + 1
            WHERE appointment_id BETWEEN @first AND @first + @rows - 1;
            SET @locked = @@ROWCOUNT;

            IF @can_view = 1
                SET @escalated = CASE WHEN EXISTS (
                    SELECT 1
                    FROM sys.dm_tran_locks AS l
                    WHERE l.request_session_id = @@SPID
                      AND l.resource_type = 'OBJECT'
                      AND l.resource_associated_entity_id = OBJECT_ID(N'care.appointments')
                      AND l.request_mode = 'X') THEN 1 ELSE 0 END;

            SET @hold_until = DATEADD(second, @hold_seconds, SYSUTCDATETIME());
            WHILE @stopped = 0 AND SYSUTCDATETIME() < @hold_until AND SYSUTCDATETIME() < @deadline
            BEGIN
                WAITFOR DELAY '00:00:01';
                SET @stopped = demo.fn_run_should_stop(@run_id);
            END;

            -- The watchdog rollback: the escalation never commits.
            ROLLBACK TRANSACTION;
            SET @held = DATEDIFF(millisecond, @started, SYSUTCDATETIME());
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;
            IF ERROR_NUMBER() = 1222
            BEGIN
                SET @timeouts += 1;
                SET @outcome = N'lock timeout';
            END;
            ELSE IF ERROR_NUMBER() = 1205
            BEGIN
                SET @deadlocks += 1;
                SET @outcome = N'deadlock victim';
            END;
            ELSE
                THROW;
        END CATCH;

        SET @attempts += 1;
        SET @rows_locked += @locked;
        SET @held_ms += @held;
        IF @escalated = 1
            SET @table_locks += 1;

        -- Recorded after the rollback, so the event survives it.
        SET @detail = LEFT(CONCAT(@locked, N' appointment rows updated in one statement; table lock: ',
            CASE WHEN @escalated = 1 THEN N'yes' WHEN @escalated = 0 THEN N'no' ELSE N'unknown (no VIEW SERVER STATE or VIEW DATABASE STATE)' END,
            N'; ', @outcome, N' for ', @held, N' ms, then rolled back.'), 400);
        EXEC demo.usp_run_event @run_id = @run_id, @event_name = 'lock-escalation', @session_id = @@SPID, @detail = @detail;

        SET @next_until = DATEADD(second, @every_seconds, SYSUTCDATETIME());
    END;

    SELECT session_id = @@SPID, escalation_attempts = @attempts, table_locks = @table_locks, rows_locked = @rows_locked,
        held_ms = @held_ms, lock_timeouts = @timeouts, deadlock_victims = @deadlocks, stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Deadlock storm (Phase 25b) ---------------------------------------------------------------------------------------

-- Pairs of sessions that deadlock with each other, round after round, at most @max_rounds times. Pair P (1 to 8)
-- uses inventory rows 100 + 2P - 1 and 100 + 2P, apart from locking-blocking's rows 1 and 2. 'order': side 1 locks
-- row A then row B, side 2 row B then row A. 'conversion': both sides read row A with HOLDLOCK (a shared lock kept
-- to the end of the transaction), then both update it. 'mixed' alternates the two. Side 2 runs at
-- DEADLOCK_PRIORITY LOW, so it's the victim (error 1205); every round rolls back, and each victim is recorded as a
-- deadlock-victim event.
CREATE OR ALTER PROCEDURE demo.usp_scenario_deadlock_storm
    @run_id varchar(64),
    @pair int = 1,
    @side tinyint = 1,
    @intensity tinyint = 5,
    @shape varchar(16) = 'mixed',
    @max_rounds int = 60
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET LOCK_TIMEOUT 30000;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'deadlock-storm', @deadline_at = @deadline OUTPUT;

    IF @pair IS NULL OR @pair NOT BETWEEN 1 AND 8
        THROW 50158, N'@pair must be between 1 and 8.', 1;
    IF @side IS NULL OR @side NOT IN (1, 2)
        THROW 50145, N'@side must be 1 or 2.', 1;
    IF @shape IS NULL OR @shape NOT IN ('mixed', 'order', 'conversion')
        THROW 50159, N'@shape must be mixed, order, or conversion.', 1;
    IF @max_rounds IS NULL OR @max_rounds NOT BETWEEN 1 AND 300
        THROW 50160, N'@max_rounds must be between 1 and 300.', 1;
    IF @side = 2
        SET DEADLOCK_PRIORITY LOW;

    DECLARE @a int = 100 + 2 * @pair - 1, @b int = 100 + 2 * @pair;
    IF (SELECT COUNT(*) FROM care.inventory WITH (READUNCOMMITTED) WHERE inventory_id IN (@a, @b)) < 2
        THROW 50161, N'The deadlock rows aren''t there. Is ContosoCare seeded?', 1;

    DECLARE @first int = CASE @side WHEN 1 THEN @a ELSE @b END;
    DECLARE @second int = CASE @side WHEN 1 THEN @b ELSE @a END;
    DECLARE @pause datetime = demo.fn_pause(@intensity, 10000, 1000);
    DECLARE @remaining int = @max_rounds, @round int = 0, @round_shape varchar(16), @quantity int, @detail nvarchar(400);
    DECLARE @completed int = 0, @victims int = 0, @order_rounds int = 0, @conversion_rounds int = 0, @timeouts int = 0, @stopped bit = 0;

    WHILE @remaining > 0 AND @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SET @remaining -= 1;
        SET @round += 1;
        SET @round_shape = CASE WHEN @shape <> 'mixed' THEN @shape WHEN @round % 2 = 1 THEN 'order' ELSE 'conversion' END;
        BEGIN TRY
            BEGIN TRANSACTION;
            IF @round_shape = 'order'
            BEGIN
                SET @order_rounds += 1;
                UPDATE care.inventory SET updated_at = SYSUTCDATETIME() WHERE inventory_id = @first;
                WAITFOR DELAY '00:00:01';
                UPDATE care.inventory SET updated_at = SYSUTCDATETIME() WHERE inventory_id = @second;
            END;
            ELSE
            BEGIN
                SET @conversion_rounds += 1;
                SELECT @quantity = quantity_on_hand FROM care.inventory WITH (HOLDLOCK, ROWLOCK) WHERE inventory_id = @a;
                WAITFOR DELAY '00:00:01';
                UPDATE care.inventory SET updated_at = SYSUTCDATETIME() WHERE inventory_id = @a;
            END;
            ROLLBACK TRANSACTION;
            SET @completed += 1;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0
                ROLLBACK TRANSACTION;
            IF ERROR_NUMBER() = 1205
            BEGIN
                SET @victims += 1;
                SET @detail = LEFT(CONCAT(N'Pair ', @pair, N', ', @round_shape, N' deadlock in round ', @round, N': error 1205; the transaction was rolled back.'), 400);
                EXEC demo.usp_run_event @run_id = @run_id, @event_name = 'deadlock-victim', @session_id = @@SPID, @detail = @detail;
            END;
            ELSE IF ERROR_NUMBER() = 1222
                SET @timeouts += 1;
            ELSE
                THROW;
        END CATCH;

        SET @stopped = demo.fn_run_should_stop(@run_id);
        IF @remaining > 0 AND @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY @pause;
    END;

    SELECT pair = @pair, side = @side, session_id = @@SPID, rounds = @round, completed = @completed, deadlock_victim = @victims,
        order_rounds = @order_rounds, conversion_rounds = @conversion_rounds, lock_timeouts = @timeouts,
        stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- tempdb contention (Phase 25b) --------------------------------------------------------------------------------------

-- Many sessions creating, filling, indexing, and dropping temporary tables back to back. The #tables belong to the
-- scenario's own sessions (tempdb is the only place outside ContosoCare it touches, as any #table does), and the
-- index added after CREATE TABLE stops SQL Server from caching and reusing them, so every iteration allocates pages
-- and system catalog rows in tempdb: PAGELATCH waits on its allocation and catalog pages, and temp table creations.
CREATE OR ALTER PROCEDURE demo.usp_scenario_tempdb_contention
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 8,
    @rows_per_table int = 200
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'tempdb-contention', @deadline_at = @deadline OUTPUT;

    IF @rows_per_table IS NULL OR @rows_per_table NOT BETWEEN 10 AND 2000
        THROW 50162, N'@rows_per_table must be between 10 and 2000.', 1;

    DECLARE @level int = CASE WHEN @intensity BETWEEN 1 AND 10 THEN @intensity ELSE 8 END;
    DECLARE @pause datetime = demo.fn_pause(@intensity, 200, 0);
    DECLARE @tables bigint = 0, @rows bigint = 0, @found int, @stopped bit = 0, @next_check datetime2(3) = SYSUTCDATETIME();

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        CREATE TABLE #scratch (id int NOT NULL, worker int NOT NULL, payload char(400) NOT NULL);
        CREATE CLUSTERED INDEX cx_scratch ON #scratch (id);
        INSERT INTO #scratch (id, worker, payload)
        SELECT n.n, @worker, 'ContosoCare.Demo'
        FROM demo.fn_numbers(@rows_per_table) AS n;
        SELECT @found = COUNT(*) FROM #scratch WHERE id % 7 = 0;
        DROP TABLE #scratch;

        SET @tables += 1;
        SET @rows += @rows_per_table;
        IF SYSUTCDATETIME() >= @next_check
        BEGIN
            SET @stopped = demo.fn_run_should_stop(@run_id);
            SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
        END;
        IF @level < 10 AND @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY @pause;
    END;

    SELECT worker = @worker, temp_tables = @tables, rows_written = @rows, stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Memory grant pressure (Phase 25b) -----------------------------------------------------------------------------------

-- Large sorts, each reserving a big memory grant up front: MIN_GRANT_PERCENT asks for @grant_percent of the most one
-- query may get (25% of the workspace memory in the default workload group), so only a few run at once and the
-- rest wait in the RESOURCE_SEMAPHORE queue. Each query numbers appointments times a multiplier from @intensity in
-- a scrambled order (a sort, MAXDOP 1); nothing is written. A query hint needs a literal, so the validated integer is
-- placed in the statement text.
CREATE OR ALTER PROCEDURE demo.usp_scenario_memory_grants
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 6,
    @grant_percent int = 100
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'memory-grant-pressure', @deadline_at = @deadline OUTPUT;

    IF @grant_percent IS NULL OR @grant_percent NOT BETWEEN 10 AND 100
        THROW 50163, N'@grant_percent must be between 10 and 100.', 1;

    DECLARE @level int = CASE WHEN @intensity BETWEEN 1 AND 10 THEN @intensity ELSE 6 END;
    DECLARE @multiplier int = 8 * @level;
    DECLARE @pause datetime = demo.fn_pause(@intensity, 2000, 0);
    DECLARE @sql nvarchar(1000) = CONCAT(
        N'SELECT @rows_out = COUNT_BIG(*), @last_out = MAX(s.rn) ',
        N'FROM (SELECT rn = ROW_NUMBER() OVER (ORDER BY CHECKSUM(a.appointment_id, a.patient_id, m.n, @salt)) ',
        N'FROM care.appointments AS a CROSS JOIN demo.fn_numbers(@multiplier) AS m) AS s ',
        N'OPTION (MAXDOP 1, MIN_GRANT_PERCENT = ', @grant_percent, N');');
    DECLARE @rows bigint, @last bigint, @queries int = 0, @sorted bigint = 0, @busy_ms bigint = 0, @started datetime2(7);
    DECLARE @stopped bit = 0;

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SET @started = SYSUTCDATETIME();
        EXEC sys.sp_executesql @sql, N'@multiplier int, @salt int, @rows_out bigint OUTPUT, @last_out bigint OUTPUT',
            @multiplier = @multiplier, @salt = @worker, @rows_out = @rows OUTPUT, @last_out = @last OUTPUT;
        SET @busy_ms += DATEDIFF(millisecond, @started, SYSUTCDATETIME());
        SET @sorted += @rows;
        SET @queries += 1;

        SET @stopped = demo.fn_run_should_stop(@run_id);
        IF @level < 10 AND @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY @pause;
    END;

    SELECT worker = @worker, queries = @queries, rows_sorted = @sorted,
        avg_query_ms = CASE WHEN @queries = 0 THEN 0 ELSE @busy_ms / @queries END, stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Parallelism waits (Phase 25b) ---------------------------------------------------------------------------------------

-- A large reporting aggregate over appointments and their encounters times a multiplier, at MAXDOP @maxdop (SQL
-- Server never uses more threads than it has schedulers). The multiplier keeps each report near 1.2 million rows
-- plus 240,000 per intensity level whatever the seed scale, so one report stays well inside the run's grace period
-- on the smallest target. No hint forces parallelism: the estimated cost is well above the default cost threshold
-- for parallelism (5), so the optimizer picks a parallel plan where it can. The coordinating thread then waits for
-- its workers (CXCONSUMER), the workers wait at the exchanges (CXPACKET, CXSYNC_PORT), and grouping by status, a
-- skewed key, leaves them uneven work; more sessions than schedulers add CPU waits. The outer query uses every
-- column, so the optimizer can't drop the per-row work. Reads only. MAXDOP needs a literal and TOP gets an exact
-- estimate from one, so the validated integers are placed in the statement text.
CREATE OR ALTER PROCEDURE demo.usp_scenario_parallel_scans
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 6,
    @maxdop int = 4
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'parallel-scans', @deadline_at = @deadline OUTPUT;

    IF @maxdop IS NULL OR @maxdop NOT BETWEEN 2 AND 8
        THROW 50164, N'@maxdop must be between 2 and 8.', 1;

    DECLARE @encounters bigint = (SELECT COUNT_BIG(*) FROM care.encounters);
    IF @encounters = 0
        THROW 50140, N'ContosoCare isn''t seeded. Run demo.usp_seed_contosocare first.', 1;

    DECLARE @level int = CASE WHEN @intensity BETWEEN 1 AND 10 THEN @intensity ELSE 6 END;
    DECLARE @multiplier bigint = (1200000 + 240000 * @level) / @encounters;
    IF @multiplier < 2
        SET @multiplier = 2;
    IF @multiplier > 1000
        SET @multiplier = 1000;
    DECLARE @pause datetime = demo.fn_pause(@intensity, 2000, 0);
    DECLARE @sql nvarchar(1200) = CONCAT(
        N'SELECT @groups_out = COUNT(*), @visits_out = SUM(x.visits), @checksum_out = SUM(x.checksum_total) ',
        N'FROM (SELECT a.status, a.facility_id, visits = COUNT_BIG(*), ',
        N'checksum_total = SUM(CAST(CHECKSUM(a.appointment_id, a.patient_id, e.encounter_id, m.n) AS bigint)) ',
        N'FROM care.appointments AS a INNER JOIN care.encounters AS e ON e.appointment_id = a.appointment_id ',
        N'CROSS JOIN (SELECT TOP (', @multiplier, N') n = p.patient_id FROM care.patients AS p) AS m ',
        N'WHERE a.status <> ''Cancelled'' GROUP BY a.status, a.facility_id) AS x ',
        N'OPTION (MAXDOP ', @maxdop, N');');
    DECLARE @groups int, @visits bigint, @checksum bigint, @queries int = 0, @rows bigint = 0, @busy_ms bigint = 0;
    DECLARE @started datetime2(7), @stopped bit = 0;

    WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SET @started = SYSUTCDATETIME();
        EXEC sys.sp_executesql @sql, N'@groups_out int OUTPUT, @visits_out bigint OUTPUT, @checksum_out bigint OUTPUT',
            @groups_out = @groups OUTPUT, @visits_out = @visits OUTPUT, @checksum_out = @checksum OUTPUT;
        SET @busy_ms += DATEDIFF(millisecond, @started, SYSUTCDATETIME());
        SET @rows += ISNULL(@visits, 0);
        SET @queries += 1;

        SET @stopped = demo.fn_run_should_stop(@run_id);
        IF @level < 10 AND @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY @pause;
    END;

    SELECT worker = @worker, queries = @queries, rows_aggregated = @rows,
        avg_query_ms = CASE WHEN @queries = 0 THEN 0 ELSE @busy_ms / @queries END, stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Log flush waits (Phase 25b) ---------------------------------------------------------------------------------------------

-- One small row per transaction into demo.commit_scratch: every INSERT commits on its own, so each one waits for its
-- log flush (WRITELOG; on Azure SQL Database also Log Rate Governor when the rate passes the service objective's
-- limit). Each worker deletes its rows every 1,000 inserts, so the table stays small, and it stops after
-- @max_rows inserts, at the deadline, or on a stop request. Below intensity 10 it pauses after every 20 commits.
CREATE OR ALTER PROCEDURE demo.usp_scenario_commit_flood
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 10,
    @max_rows int = 200000
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'log-flush-waits', @deadline_at = @deadline OUTPUT;

    IF @max_rows IS NULL OR @max_rows NOT BETWEEN 1000 AND 2000000
        THROW 50165, N'@max_rows must be between 1000 and 2000000.', 1;

    EXEC demo.usp_check_space @required_data_mb = 64, @required_log_mb = 256, @raise = 1;

    DECLARE @level int = CASE WHEN @intensity BETWEEN 1 AND 10 THEN @intensity ELSE 10 END;
    DECLARE @pause datetime = demo.fn_pause(@intensity, 200, 0);
    DECLARE @remaining int = @max_rows, @commits bigint = 0, @deleted bigint = 0;
    DECLARE @stopped bit = 0, @next_check datetime2(3) = SYSUTCDATETIME();

    WHILE @remaining > 0 AND @stopped = 0 AND SYSUTCDATETIME() < @deadline
    BEGIN
        SET @remaining -= 1;
        INSERT INTO demo.commit_scratch (run_id, worker, written_at, payload)
        VALUES (@run_id, @worker, SYSUTCDATETIME(), 'ContosoCare.Demo');
        SET @commits += 1;

        IF @commits % 1000 = 0
        BEGIN
            DELETE FROM demo.commit_scratch WHERE run_id = @run_id AND worker = @worker;
            SET @deleted += @@ROWCOUNT;
        END;

        IF SYSUTCDATETIME() >= @next_check
        BEGIN
            SET @stopped = demo.fn_run_should_stop(@run_id);
            SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
        END;
        IF @level < 10 AND @commits % 20 = 0 AND @stopped = 0 AND SYSUTCDATETIME() < @deadline
            WAITFOR DELAY @pause;
    END;

    DELETE FROM demo.commit_scratch WHERE run_id = @run_id AND worker = @worker;
    SET @deleted += @@ROWCOUNT;

    SELECT worker = @worker, commits = @commits, rows_deleted = @deleted,
        budget_reached = CAST(CASE WHEN @remaining = 0 THEN 1 ELSE 0 END AS bit), stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO

-- Slow consumer (Phase 25b) ---------------------------------------------------------------------------------------------

-- A wide result set (about 1 KB per row) that the runner reads slowly on purpose, like a client that fetches a few
-- rows and then pauses: the server fills the network buffers and waits for the client (ASYNC_NETWORK_IO). The
-- procedure only reads. The runner cancels the query at the deadline or on a stop request, which the SQL Attention
-- rate counter counts, and runs it again while the run lasts.
CREATE OR ALTER PROCEDURE demo.usp_scenario_slow_consumer
    @run_id varchar(64),
    @worker int = 1,
    @rows int = 100000
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'slow-consumer', @deadline_at = @deadline OUTPUT;

    IF @rows IS NULL OR @rows NOT BETWEEN 1000 AND 500000
        THROW 50166, N'@rows must be between 1000 and 500000.', 1;

    SELECT TOP (@rows)
        a.appointment_id, a.patient_id, a.provider_id, a.facility_id, a.scheduled_start, a.status, a.reason_code,
        copy_number = m.n, worker = @worker, padding = CAST(REPLICATE('x', 900) AS char(900))
    FROM care.appointments AS a
    CROSS JOIN demo.fn_numbers(25) AS m;
END;
GO

-- Capacity maxed (Phase 25b) ----------------------------------------------------------------------------------------------

-- Every scheduler busy and the disks at their caps at the same time. Role 'cpu': back-to-back CPU-heavy reports at
-- MAXDOP 1, one scheduler each, so more sessions than schedulers keeps every scheduler busy (SOS_SCHEDULER_YIELD
-- and runnable tasks; on Azure SQL Database, CPU at the vCore limit). Role 'io': range scans and updates over
-- demo.io_scratch after its worker 1 grows it to @scratch_mb (demo.usp_io_scratch_grow, shared with io-pressure), so
-- reads miss the buffer pool once the scratch set is bigger than memory (PAGEIOLATCH and the disk's IOPS and
-- throughput caps; on Azure SQL Database, IO governance). Business data is only read.
CREATE OR ALTER PROCEDURE demo.usp_scenario_capacity_max
    @run_id varchar(64),
    @worker int = 1,
    @intensity tinyint = 10,
    @role varchar(8) = 'cpu',
    @scratch_mb int = 3072
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @deadline datetime2(3);
    EXEC demo.usp_run_assert_running @run_id = @run_id, @scenario_id = 'capacity-max', @deadline_at = @deadline OUTPUT;

    IF @role IS NULL OR @role NOT IN ('cpu', 'io')
        THROW 50167, N'@role must be cpu or io.', 1;
    IF @scratch_mb IS NULL OR @scratch_mb NOT BETWEEN 64 AND 6144
        THROW 50148, N'@scratch_mb must be between 64 and 6144.', 1;

    DECLARE @level int = CASE WHEN @intensity BETWEEN 1 AND 10 THEN @intensity ELSE 10 END;
    DECLARE @repeat int = 1 + @level / 3;
    DECLARE @pause datetime = demo.fn_pause(@intensity, 1000, 0);
    DECLARE @queries bigint = 0, @busy_ms bigint = 0, @started datetime2(7), @total bigint, @score bigint;
    DECLARE @written_mb int = 0, @read_mb bigint = 0, @updated_mb bigint = 0, @scans int = 0, @updates int = 0, @iterations int = 0;
    DECLARE @rows int = 0, @start int, @span int, @pages bigint, @touched bigint;
    DECLARE @stopped bit = 0, @next_check datetime2(3) = SYSUTCDATETIME();

    IF @role = 'cpu'
    BEGIN
        WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
        BEGIN
            SET @started = SYSUTCDATETIME();
            SELECT
                @total = COUNT_BIG(*),
                @score = SUM(CAST(CAST(SUBSTRING(HASHBYTES('SHA2_256', CONCAT(a.appointment_id, ':', a.patient_id, ':', k.k, ':', @worker)), 1, 4) AS int) AS bigint) % 1000)
            FROM care.appointments AS a
            CROSS JOIN (VALUES (1), (2), (3), (4)) AS k (k)
            WHERE k.k <= @repeat
            OPTION (MAXDOP 1);
            SET @busy_ms += DATEDIFF(millisecond, @started, SYSUTCDATETIME());
            SET @queries += 1;

            IF SYSUTCDATETIME() >= @next_check
            BEGIN
                SET @stopped = demo.fn_run_should_stop(@run_id);
                SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
            END;
            IF @level < 10 AND @stopped = 0 AND SYSUTCDATETIME() < @deadline
                WAITFOR DELAY @pause;
        END;
    END;
    ELSE
    BEGIN
        IF @worker = 1
            EXEC demo.usp_io_scratch_grow @run_id = @run_id, @scratch_mb = @scratch_mb, @deadline_at = @deadline, @written_mb = @written_mb OUTPUT;
        SET @stopped = demo.fn_run_should_stop(@run_id);

        WHILE @stopped = 0 AND SYSUTCDATETIME() < @deadline
        BEGIN
            SELECT @rows = ISNULL(MAX(scratch_id), 0) FROM demo.io_scratch;
            IF @rows > 0
            BEGIN
                SET @span = CASE WHEN @rows < 32768 THEN @rows ELSE 32768 END;
                SET @start = 1 + ABS(CHECKSUM(NEWID())) % (@rows - @span + 1);
                IF (@iterations + @worker) % 4 = 0
                BEGIN
                    UPDATE demo.io_scratch
                    SET touched = touched + 1, written_at = SYSUTCDATETIME()
                    WHERE scratch_id BETWEEN @start AND @start + 2047;
                    SET @updated_mb += @@ROWCOUNT / 128;
                    SET @updates += 1;
                END;
                ELSE
                BEGIN
                    SELECT @pages = COUNT_BIG(*), @touched = SUM(CAST(touched AS bigint))
                    FROM demo.io_scratch
                    WHERE scratch_id BETWEEN @start AND @start + @span - 1
                    OPTION (MAXDOP 1);
                    SET @read_mb += @pages / 128;
                    SET @scans += 1;
                END;
            END;
            ELSE
                WAITFOR DELAY '00:00:01';

            SET @iterations += 1;
            IF SYSUTCDATETIME() >= @next_check
            BEGIN
                SET @stopped = demo.fn_run_should_stop(@run_id);
                SET @next_check = DATEADD(millisecond, 1000, SYSUTCDATETIME());
            END;
            IF @level < 10 AND @stopped = 0 AND SYSUTCDATETIME() < @deadline
                WAITFOR DELAY @pause;
        END;
    END;

    SELECT worker = @worker, role = @role, queries = @queries,
        avg_query_ms = CASE WHEN @queries = 0 THEN 0 ELSE @busy_ms / @queries END,
        scratch_mb = @rows / 128, written_mb = @written_mb, scanned_mb = @read_mb, updated_mb = @updated_mb,
        scans = @scans, updates = @updates, stop_requested = demo.fn_run_stop_requested(@run_id);
END;
GO