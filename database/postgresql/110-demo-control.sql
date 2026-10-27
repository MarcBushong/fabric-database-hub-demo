-- Demo control objects for T4 (Phase 24, ADR 0010, ADR 0019): the PostgreSQL counterpart of
-- database/common/110-demo-control.sql. Run bookkeeping, stop requests, the scenario catalog (the database layer of
-- the bounds), and the session tools, which only ever touch sessions in this database whose application_name
-- starts with ContosoCare.Demo/ (never ContosoCare.Demo/control/...). Idempotent. Applied by
-- 'ContosoCare.Workload setup --target T4' as an administrator. T4's activity profile lives in a file on T1, as
-- T3's does, so there's no activity_profile table here.
-- Batches are separated by lines that hold only '-- @batch'.

CREATE TABLE IF NOT EXISTS demo.scenario_runs
(
    run_id               varchar(64)   NOT NULL CONSTRAINT pk_scenario_runs PRIMARY KEY
                                       CONSTRAINT ck_scenario_runs_run_id CHECK (run_id ~ '^[a-z0-9][a-z0-9-]{0,39}$'),
    scenario_id          varchar(64)   NOT NULL,
    target               varchar(8)    NOT NULL CONSTRAINT ck_scenario_runs_target CHECK (target = 'T4'),
    status               varchar(20)   NOT NULL CONSTRAINT ck_scenario_runs_status CHECK (status IN ('Running', 'Completed', 'Cancelled', 'TimedOut', 'Failed')),
    started_at           timestamptz   NOT NULL,
    deadline_at          timestamptz   NOT NULL,
    stopped_at           timestamptz   NULL,
    max_duration_seconds integer       NOT NULL CONSTRAINT ck_scenario_runs_duration CHECK (max_duration_seconds BETWEEN 1 AND 14400),
    concurrency          integer       NOT NULL CONSTRAINT ck_scenario_runs_concurrency CHECK (concurrency BETWEEN 1 AND 64),
    intensity            smallint      NOT NULL CONSTRAINT ck_scenario_runs_intensity CHECK (intensity BETWEEN 1 AND 10),
    parameters           varchar(2000) NULL,
    expected_symptoms    varchar(400)  NULL,
    requested_by         varchar(128)  NULL,
    runner_host          varchar(128)  NULL,
    profile_name         varchar(64)   NULL,
    outcome              varchar(1000) NULL,
    session_ids          varchar(400)  NULL
);
-- @batch
CREATE INDEX IF NOT EXISTS ix_scenario_runs_status ON demo.scenario_runs (status, scenario_id);
-- @batch
CREATE TABLE IF NOT EXISTS demo.scenario_run_events
(
    event_id     bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT pk_scenario_run_events PRIMARY KEY,
    run_id       varchar(64)  NOT NULL CONSTRAINT fk_scenario_run_events_run REFERENCES demo.scenario_runs (run_id) ON DELETE CASCADE,
    event_time   timestamptz  NOT NULL,
    event_name   varchar(40)  NOT NULL,
    session_id   integer      NULL,
    detail       varchar(400) NULL
);
-- @batch
CREATE INDEX IF NOT EXISTS ix_scenario_run_events_run ON demo.scenario_run_events (run_id, event_time);
-- @batch
CREATE TABLE IF NOT EXISTS demo.scenario_control
(
    scenario_id          varchar(64)  NOT NULL CONSTRAINT pk_scenario_control PRIMARY KEY,
    stop_requested       boolean      NOT NULL DEFAULT false,
    stop_requested_at    timestamptz  NULL,
    stop_requested_by    varchar(128) NULL,
    max_duration_seconds integer      NOT NULL CONSTRAINT ck_scenario_control_duration CHECK (max_duration_seconds BETWEEN 1 AND 14400),
    updated_at           timestamptz  NOT NULL
);
-- @batch
-- io-pressure's scratch set: one row per 8 KB page (PLAIN storage keeps the 3,500-byte filler uncompressed and in
-- the row, and fillfactor 50 leaves the rest of the page free), so the scratch size in MB is predictable, reads are
-- real page reads, and the scenario's updates stay in their page (HOT) instead of growing the table.
CREATE TABLE IF NOT EXISTS demo.io_scratch
(
    id         bigint      NOT NULL CONSTRAINT pk_io_scratch PRIMARY KEY,
    run_id     varchar(64) NULL,
    touched    integer     NOT NULL DEFAULT 0,
    filler     char(3500)  NOT NULL
)
WITH (fillfactor = 50);
-- @batch
ALTER TABLE demo.io_scratch ALTER COLUMN filler SET STORAGE PLAIN;
-- @batch

-- The scenario catalog: the database layer of the bounds ---------------------------------------------------------------

-- The scenarios T4 runs and their hard maximum durations in seconds. They mirror scenarios/<id>/scenario.json for
-- every scenario that applies to T4; a .NET test fails when the two disagree.
CREATE OR REPLACE FUNCTION demo.fn_scenario_catalog()
RETURNS TABLE (scenario_id varchar(64), max_duration_seconds integer)
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT c.scenario_id::varchar(64), c.max_duration_seconds
    FROM (VALUES
        ('healthy-baseline', 14400),
        ('cpu-pressure', 1800),
        ('locking-blocking', 1800),
        ('io-pressure', 1800),
        ('connection-surge', 900),
        ('idle-in-transaction', 1800)
    ) AS c (scenario_id, max_duration_seconds);
$$;
-- @batch
-- One control row per scenario plus '*', the global cap and stop-all row. A re-run lowers nothing an operator set
-- below the catalog value and never touches a stop request.
INSERT INTO demo.scenario_control (scenario_id, stop_requested, max_duration_seconds, updated_at)
SELECT s.scenario_id, false, s.max_duration_seconds, now()
FROM demo.fn_scenario_catalog() AS s
ON CONFLICT (scenario_id) DO UPDATE
    SET max_duration_seconds = LEAST(demo.scenario_control.max_duration_seconds, EXCLUDED.max_duration_seconds),
        updated_at = now();
-- @batch
INSERT INTO demo.scenario_control (scenario_id, stop_requested, max_duration_seconds, updated_at)
VALUES ('*', false, 14400, now())
ON CONFLICT (scenario_id) DO NOTHING;
-- @batch

-- Helpers ---------------------------------------------------------------------------------------------------------------

-- true when someone asked a run to stop: it isn't Running any more (demo.usp_stop marks it Cancelled), a stop was
-- requested for its scenario or for all scenarios after it started, or the run doesn't exist.
CREATE OR REPLACE FUNCTION demo.fn_run_stop_requested(p_run_id varchar)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE((
        SELECT r.status <> 'Running'
            OR EXISTS (
                SELECT 1
                FROM demo.scenario_control AS c
                WHERE c.stop_requested
                  AND c.scenario_id IN (r.scenario_id, '*')
                  AND c.stop_requested_at >= r.started_at)
        FROM demo.scenario_runs AS r
        WHERE r.run_id = p_run_id), true);
$$;
-- @batch
-- true when a run must stop: a stop was requested (above) or it's past its deadline. Every scenario step checks it.
CREATE OR REPLACE FUNCTION demo.fn_run_should_stop(p_run_id varchar)
RETURNS boolean
LANGUAGE sql
VOLATILE
AS $$
    SELECT COALESCE((
        SELECT clock_timestamp() >= r.deadline_at OR demo.fn_run_stop_requested(p_run_id)
        FROM demo.scenario_runs AS r
        WHERE r.run_id = p_run_id), true);
$$;
-- @batch
-- Raises SQLSTATE CC001 unless the run exists, is Running, has no stop request, and is before its deadline. Every
-- scenario step calls it first; the runner treats CC001 as "this run has ended", not as an error.
CREATE OR REPLACE FUNCTION demo.usp_run_assert_running(p_run_id varchar)
RETURNS timestamptz
LANGUAGE plpgsql
AS $$
DECLARE
    v_deadline timestamptz;
BEGIN
    IF demo.fn_run_should_stop(p_run_id) THEN
        RAISE EXCEPTION 'Run % has ended: it was stopped or reached its deadline.', p_run_id USING ERRCODE = 'CC001';
    END IF;
    SELECT r.deadline_at INTO v_deadline FROM demo.scenario_runs AS r WHERE r.run_id = p_run_id;
    RETURN v_deadline;
END;
$$;
-- @batch
-- Demo sessions in this database: application name ContosoCare.Demo/<scenario>/<run>, never the runner's control
-- sessions (ContosoCare.Demo/control/...), never the caller. Optionally one run only. The statistics snapshot is
-- cleared first, so a caller that asks again in the same transaction sees current sessions.
CREATE OR REPLACE FUNCTION demo.fn_demo_sessions(p_run_id varchar)
RETURNS TABLE (
    pid integer,
    application_name text,
    state text,
    open_transaction boolean,
    blocked_by integer,
    wait_event_type text,
    wait_event text,
    transaction_seconds numeric,
    state_seconds numeric)
LANGUAGE plpgsql
VOLATILE
AS $$
BEGIN
    PERFORM pg_stat_clear_snapshot();
    RETURN QUERY
    SELECT a.pid,
           a.application_name,
           a.state,
           a.xact_start IS NOT NULL,
           (pg_blocking_pids(a.pid))[1],
           a.wait_event_type,
           a.wait_event,
           round(EXTRACT(EPOCH FROM clock_timestamp() - a.xact_start)::numeric, 1),
           round(EXTRACT(EPOCH FROM clock_timestamp() - a.state_change)::numeric, 1)
    FROM pg_stat_activity AS a
    WHERE a.datname = current_database()
      AND a.backend_type = 'client backend'
      AND a.pid <> pg_backend_pid()
      AND a.application_name LIKE 'ContosoCare.Demo/%'
      AND a.application_name NOT LIKE 'ContosoCare.Demo/control/%'
      AND (p_run_id IS NULL OR a.application_name LIKE 'ContosoCare.Demo/%/' || p_run_id);
END;
$$;
-- @batch

-- Run bookkeeping ---------------------------------------------------------------------------------------------------------

-- Marks runs that passed their deadline plus a grace period without ending as TimedOut (their runner stopped or lost
-- its connection), and closes cancelled runs that never recorded an end.
CREATE OR REPLACE FUNCTION demo.usp_recover_stale_runs(p_grace_seconds integer DEFAULT 120)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_now timestamptz := clock_timestamp();
    v_grace interval := make_interval(secs => GREATEST(COALESCE(p_grace_seconds, 0), 0));
    v_count integer;
BEGIN
    UPDATE demo.scenario_runs
    SET status = 'TimedOut',
        stopped_at = v_now,
        outcome = left(concat_ws(' ', outcome, 'Recovered: the run passed its deadline without recording an end, so its runner stopped or lost its connection.'), 1000)
    WHERE status = 'Running'
      AND deadline_at < v_now - v_grace;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    UPDATE demo.scenario_runs
    SET stopped_at = v_now
    WHERE status <> 'Running'
      AND stopped_at IS NULL
      AND deadline_at < v_now - v_grace;

    RETURN v_count;
END;
$$;
-- @batch
-- Registers a run and returns its deadline. The duration is clamped to the scenario's maximum, any lower limit in
-- demo.scenario_control, and the global cap. At most one Running run per scenario and four in total.
CREATE OR REPLACE FUNCTION demo.usp_run_begin(
    p_run_id varchar,
    p_scenario_id varchar,
    p_target varchar,
    p_duration_seconds integer,
    p_concurrency integer,
    p_intensity integer,
    p_parameters varchar DEFAULT NULL,
    p_expected_symptoms varchar DEFAULT NULL,
    p_requested_by varchar DEFAULT NULL,
    p_runner_host varchar DEFAULT NULL,
    p_profile_name varchar DEFAULT NULL)
RETURNS TABLE (deadline_at timestamptz, effective_duration_seconds integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_now timestamptz := clock_timestamp();
    v_catalog_max integer;
    v_control_max integer;
    v_global_max integer;
    v_effective integer;
    v_deadline timestamptz;
    v_running integer;
BEGIN
    IF p_run_id IS NULL OR p_run_id !~ '^[a-z0-9][a-z0-9-]{0,39}$' THEN
        RAISE EXCEPTION 'p_run_id must be 1 to 40 lowercase letters, digits, and hyphens.' USING ERRCODE = '22023';
    END IF;
    IF p_target IS DISTINCT FROM 'T4' THEN
        RAISE EXCEPTION 'This is T4''s database; p_target must be T4.' USING ERRCODE = '22023';
    END IF;
    IF p_concurrency IS NULL OR p_concurrency NOT BETWEEN 1 AND 64 THEN
        RAISE EXCEPTION 'p_concurrency must be between 1 and 64.' USING ERRCODE = '22023';
    END IF;
    IF p_intensity IS NULL OR p_intensity NOT BETWEEN 1 AND 10 THEN
        RAISE EXCEPTION 'p_intensity must be between 1 and 10.' USING ERRCODE = '22023';
    END IF;
    IF p_duration_seconds IS NULL OR p_duration_seconds < 10 THEN
        RAISE EXCEPTION 'p_duration_seconds must be at least 10.' USING ERRCODE = '22023';
    END IF;

    SELECT c.max_duration_seconds INTO v_catalog_max FROM demo.fn_scenario_catalog() AS c WHERE c.scenario_id = p_scenario_id;
    IF v_catalog_max IS NULL THEN
        RAISE EXCEPTION 'Unknown scenario ''%'' for T4. See demo.fn_scenario_catalog().', p_scenario_id USING ERRCODE = '22023';
    END IF;
    SELECT c.max_duration_seconds INTO v_control_max FROM demo.scenario_control AS c WHERE c.scenario_id = p_scenario_id;
    SELECT c.max_duration_seconds INTO v_global_max FROM demo.scenario_control AS c WHERE c.scenario_id = '*';
    v_effective := LEAST(p_duration_seconds, v_catalog_max, COALESCE(v_control_max, 14400), COALESCE(v_global_max, 14400), 14400);

    -- One registration at a time, so the checks below can't race.
    PERFORM pg_advisory_xact_lock(24240002);
    PERFORM demo.usp_recover_stale_runs(120);

    IF EXISTS (SELECT 1 FROM demo.scenario_runs AS r WHERE r.run_id = p_run_id) THEN
        RAISE EXCEPTION 'A run with this p_run_id already exists.' USING ERRCODE = 'CC002';
    END IF;
    IF EXISTS (SELECT 1 FROM demo.scenario_runs AS r WHERE r.status = 'Running' AND r.scenario_id = p_scenario_id) THEN
        RAISE EXCEPTION 'Scenario ''%'' already has a Running run on T4. Stop it first (demo.usp_stop).', p_scenario_id USING ERRCODE = 'CC002';
    END IF;
    SELECT count(*) INTO v_running FROM demo.scenario_runs AS r WHERE r.status = 'Running';
    IF v_running >= 4 THEN
        RAISE EXCEPTION 'Four runs are already Running on T4, the most the demo allows. Stop one first.' USING ERRCODE = 'CC002';
    END IF;

    v_deadline := v_now + make_interval(secs => v_effective);
    INSERT INTO demo.scenario_runs
        (run_id, scenario_id, target, status, started_at, deadline_at, max_duration_seconds, concurrency, intensity,
         parameters, expected_symptoms, requested_by, runner_host, profile_name)
    VALUES
        (p_run_id, p_scenario_id, 'T4', 'Running', v_now, v_deadline, v_effective, p_concurrency, p_intensity,
         left(p_parameters, 2000), left(p_expected_symptoms, 400), left(p_requested_by, 128), left(p_runner_host, 128), p_profile_name);

    INSERT INTO demo.scenario_run_events (run_id, event_time, event_name, session_id, detail)
    VALUES (p_run_id, v_now, 'run-begin', pg_backend_pid(),
        left(format('Deadline %s; requested %s s, effective %s s.', to_char(v_deadline AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), p_duration_seconds, v_effective), 400));

    RETURN QUERY SELECT v_deadline, v_effective;
END;
$$;
-- @batch
CREATE OR REPLACE FUNCTION demo.usp_run_event(p_run_id varchar, p_event_name varchar, p_session_id integer, p_detail varchar, p_event_time timestamptz DEFAULT NULL)
RETURNS void
LANGUAGE sql
AS $$
    INSERT INTO demo.scenario_run_events (run_id, event_time, event_name, session_id, detail)
    SELECT r.run_id, COALESCE(p_event_time, clock_timestamp()), left(p_event_name, 40), p_session_id, left(p_detail, 400)
    FROM demo.scenario_runs AS r
    WHERE r.run_id = p_run_id;
$$;
-- @batch
-- Records how a run ended. A run that demo.usp_stop marked Cancelled stays Cancelled.
CREATE OR REPLACE FUNCTION demo.usp_run_end(p_run_id varchar, p_status varchar, p_outcome varchar, p_session_ids varchar)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_status IS NULL OR p_status NOT IN ('Completed', 'Cancelled', 'TimedOut', 'Failed') THEN
        RAISE EXCEPTION 'p_status must be Completed, Cancelled, TimedOut, or Failed.' USING ERRCODE = '22023';
    END IF;
    UPDATE demo.scenario_runs
    SET status = CASE WHEN status = 'Cancelled' THEN 'Cancelled' ELSE p_status END,
        stopped_at = clock_timestamp(),
        outcome = left(concat_ws(' ', outcome, p_outcome), 1000),
        session_ids = left(p_session_ids, 400)
    WHERE run_id = p_run_id;
    PERFORM demo.usp_run_event(p_run_id, 'run-end', pg_backend_pid(), p_status, NULL);
END;
$$;
-- @batch
-- Stop requests: one run, every run of a scenario, or everything. Scenario steps see the request at their next
-- check, within about a second. Returns how many Running runs were marked Cancelled.
CREATE OR REPLACE FUNCTION demo.usp_stop(p_scope varchar, p_run_id varchar DEFAULT NULL, p_scenario_id varchar DEFAULT NULL, p_requested_by varchar DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_now timestamptz := clock_timestamp();
    v_note text := left(format('Stop requested by %s at %s.', COALESCE(p_requested_by, 'an operator'), to_char(clock_timestamp() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')), 200);
    v_runs integer;
BEGIN
    IF p_scope IS NULL OR p_scope NOT IN ('run', 'scenario', 'all') THEN
        RAISE EXCEPTION 'p_scope must be run, scenario, or all.' USING ERRCODE = '22023';
    END IF;
    IF p_scope = 'run' AND p_run_id IS NULL THEN
        RAISE EXCEPTION 'p_run_id is required when p_scope is run.' USING ERRCODE = '22023';
    END IF;
    IF p_scope = 'scenario' AND NOT EXISTS (SELECT 1 FROM demo.fn_scenario_catalog() AS c WHERE c.scenario_id = p_scenario_id) THEN
        RAISE EXCEPTION 'p_scenario_id must be a scenario T4 runs when p_scope is scenario.' USING ERRCODE = '22023';
    END IF;

    IF p_scope IN ('scenario', 'all') THEN
        UPDATE demo.scenario_control
        SET stop_requested = true, stop_requested_at = v_now, stop_requested_by = left(p_requested_by, 128), updated_at = v_now
        WHERE scenario_id = CASE WHEN p_scope = 'all' THEN '*' ELSE p_scenario_id END;
    END IF;

    UPDATE demo.scenario_runs
    SET status = 'Cancelled',
        outcome = left(concat_ws(' ', outcome, v_note), 1000)
    WHERE status = 'Running'
      AND (p_scope = 'all'
           OR (p_scope = 'run' AND run_id = p_run_id)
           OR (p_scope = 'scenario' AND scenario_id = p_scenario_id));
    GET DIAGNOSTICS v_runs = ROW_COUNT;
    RETURN v_runs;
END;
$$;
-- @batch
-- The watchdog backstop and reset: pg_terminate_backend for this database's ContosoCare.Demo/ sessions only (one run's,
-- or all of them), never control sessions or the caller. A session another role owns can't be terminated without
-- pg_signal_backend; it's counted as failed.
CREATE OR REPLACE FUNCTION demo.usp_kill_demo_sessions(p_run_id varchar, p_past_deadline_only boolean, p_requested_by varchar)
RETURNS TABLE (killed integer, failed integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_session record;
    v_killed integer := 0;
    v_failed integer := 0;
BEGIN
    FOR v_session IN
        SELECT s.pid, s.application_name
        FROM demo.fn_demo_sessions(p_run_id) AS s
        WHERE NOT COALESCE(p_past_deadline_only, false)
           OR EXISTS (
                SELECT 1
                FROM demo.scenario_runs AS r
                WHERE s.application_name = 'ContosoCare.Demo/' || r.scenario_id || '/' || r.run_id
                  AND clock_timestamp() > r.deadline_at)
    LOOP
        BEGIN
            IF pg_terminate_backend(v_session.pid) THEN
                v_killed := v_killed + 1;
            ELSE
                v_failed := v_failed + 1;
            END IF;
        EXCEPTION WHEN insufficient_privilege THEN
            v_failed := v_failed + 1;
        END;
    END LOOP;

    IF v_killed + v_failed > 0 AND p_run_id IS NOT NULL THEN
        PERFORM demo.usp_run_event(p_run_id, 'sessions-killed', pg_backend_pid(),
            format('%s session(s) terminated, %s failed, requested by %s.', v_killed, v_failed, COALESCE(p_requested_by, 'the watchdog')), NULL);
    END IF;
    RETURN QUERY SELECT v_killed, v_failed;
END;
$$;
-- @batch
-- Auto-cleanup after a run: empties io-pressure's scratch table or removes the rows the workload wrote. Never touches
-- a scenario that still has a Running run. Returns one check row.
CREATE OR REPLACE FUNCTION demo.usp_cleanup_scenario(p_scenario_id varchar)
RETURNS TABLE (check_id text, status text, message text)
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted bigint;
BEGIN
    IF EXISTS (SELECT 1 FROM demo.scenario_runs AS r WHERE r.scenario_id = p_scenario_id AND r.status = 'Running') THEN
        RETURN QUERY SELECT 'auto-cleanup'::text, 'Warning'::text, 'Skipped: the scenario still has a Running run.'::text;
        RETURN;
    END IF;
    BEGIN
        IF p_scenario_id = 'io-pressure' THEN
            TRUNCATE demo.io_scratch;
            RETURN QUERY SELECT 'auto-cleanup'::text, 'Pass'::text, 'demo.io_scratch emptied; its storage is released.'::text;
        ELSIF p_scenario_id IN ('healthy-baseline', 'locking-blocking', 'idle-in-transaction') THEN
            DELETE FROM care.audit_events AS e
            WHERE e.run_id IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM demo.scenario_runs AS r WHERE r.run_id = e.run_id AND r.status = 'Running');
            GET DIAGNOSTICS v_deleted = ROW_COUNT;
            UPDATE care.work_queues AS w
            SET last_touched_at = NULL, touched_by_run = NULL
            WHERE w.touched_by_run IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM demo.scenario_runs AS r WHERE r.run_id = w.touched_by_run AND r.status = 'Running');
            RETURN QUERY SELECT 'auto-cleanup'::text, 'Pass'::text, format('%s audit row(s) written by the workload removed.', v_deleted);
        ELSE
            RETURN QUERY SELECT 'auto-cleanup'::text, 'Not selected'::text, 'This scenario leaves nothing to clean up: its changes roll back or it only reads.'::text;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 'auto-cleanup'::text, 'Warning'::text, left('Cleanup skipped: ' || SQLERRM, 400);
    END;
END;
$$;
-- @batch
-- Reset's data steps: the scratch table and every row the workload wrote. The runner calls it after it has stopped
-- every run and ended the demo sessions.
CREATE OR REPLACE FUNCTION demo.usp_restore_seed()
RETURNS TABLE (check_id text, status text, message text)
LANGUAGE plpgsql
AS $$
DECLARE
    v_deleted bigint;
    v_touched bigint;
BEGIN
    BEGIN
        TRUNCATE demo.io_scratch;
        RETURN QUERY SELECT 'scratch-emptied'::text, 'Pass'::text, 'demo.io_scratch is empty.'::text;
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT 'scratch-emptied'::text, 'Warning'::text, left('demo.io_scratch not emptied: ' || SQLERRM, 400);
    END;

    DELETE FROM care.audit_events WHERE run_id IS NOT NULL;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    UPDATE care.work_queues SET last_touched_at = NULL, touched_by_run = NULL WHERE touched_by_run IS NOT NULL;
    GET DIAGNOSTICS v_touched = ROW_COUNT;
    RETURN QUERY SELECT 'workload-rows-removed'::text, 'Pass'::text,
        format('%s audit row(s) written by the workload removed; %s work item(s) back to their seeded state.', v_deleted, v_touched);

    -- Retention: events after 30 days, finished runs after 90 days.
    DELETE FROM demo.scenario_run_events AS e WHERE e.event_time < clock_timestamp() - interval '30 days';
    DELETE FROM demo.scenario_runs AS r WHERE r.status <> 'Running' AND r.started_at < clock_timestamp() - interval '90 days';
END;
$$;
