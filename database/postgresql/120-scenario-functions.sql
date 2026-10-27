-- Bounded scenario steps for T4 (Phase 24, ADR 0010, ADR 0019): the PostgreSQL counterpart of
-- database/common/120-scenario-procedures.sql. Each function is one short unit of work that the runner calls in a
-- loop from its tagged sessions (ContosoCare.Demo/<scenario>/<run>), so no statement or transaction outlives the
-- run: every step first calls demo.usp_run_assert_running, which raises SQLSTATE CC001 once the run is stopped or
-- past its deadline. The runner sets statement_timeout, lock_timeout, and idle_in_transaction_session_timeout on
-- every session it opens, and the server's idle_in_transaction_session_timeout is the backstop. Scenarios work only
-- inside contosocare; changes to business data roll back, except the baseline's tagged audit rows and work-item
-- touches, which reset removes. Idempotent. Batches are separated by lines that hold only '-- @batch'.

-- The seeded sizes, from demo.seed_state (the seed scales every table linearly).
CREATE OR REPLACE FUNCTION demo.fn_seed_scale()
RETURNS integer
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_scale integer;
BEGIN
    SELECT s.scale INTO v_scale FROM demo.seed_state AS s WHERE s.seed_state_id = 1 AND s.status = 'Completed';
    IF v_scale IS NULL THEN
        RAISE EXCEPTION 'contosocare isn''t seeded; run ''ContosoCare.Workload setup --target T4 --seed-scale 1'' as an administrator.' USING ERRCODE = 'CC003';
    END IF;
    RETURN v_scale;
END;
$$;
-- @batch

-- healthy-baseline: the steady OLTP mix (front-desk lookup, a provider's day, a billing balance, work-queue triage,
-- a work-item touch, and an audit row). Short, indexed statements with no blocking.
CREATE OR REPLACE FUNCTION demo.usp_scenario_healthy_baseline(p_run_id varchar, p_worker integer, p_intensity integer)
RETURNS TABLE (statements integer, rows_read bigint, rows_written integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_scale integer := demo.fn_seed_scale();
    v_n bigint := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint * 64 + p_worker;
    v_patient integer;
    v_provider integer;
    v_item bigint;
    v_day timestamptz;
    v_read bigint := 0;
    v_count bigint;
    v_written integer := 0;
BEGIN
    PERFORM demo.usp_run_assert_running(p_run_id);
    v_patient := 1 + (demo.fn_rand(7, 'baseline-patient', v_n, 0) % (10000 * v_scale))::integer;
    v_provider := 1 + (demo.fn_rand(7, 'baseline-provider', v_n, 1) % (100 * v_scale))::integer;
    v_day := timestamptz '2026-10-01 00:00:00+00' + make_interval(days => (demo.fn_rand(7, 'baseline-day', v_n, 2) % 60)::integer - 30);

    SELECT count(*) INTO v_count FROM care.patients AS p WHERE p.mrn = 'MRN' || lpad(v_patient::text, 8, '0');
    v_read := v_read + v_count;
    SELECT count(*) INTO v_count FROM care.appointments AS a
    WHERE a.provider_id = v_provider AND a.scheduled_start >= v_day AND a.scheduled_start < v_day + interval '1 day';
    v_read := v_read + v_count;
    SELECT count(*) INTO v_count FROM care.claims AS c WHERE c.patient_id = v_patient AND c.claim_status IN ('Submitted', 'Denied', 'Appealed');
    v_read := v_read + v_count;
    SELECT count(*) INTO v_count FROM (
        SELECT w.work_item_id FROM care.work_queues AS w
        WHERE w.queue_name = 'Scheduling' AND w.status = 'Open'
        ORDER BY w.priority, w.work_item_id
        LIMIT 20) AS q;
    v_read := v_read + v_count;

    -- Touch a Scheduling item (never the Billing items locking-blocking contends for); reset clears the touch.
    v_item := 1 + (demo.fn_rand(7, 'baseline-item', v_n, 3) % (2000 * v_scale));
    UPDATE care.work_queues AS w
    SET last_touched_at = clock_timestamp(), touched_by_run = p_run_id
    WHERE w.work_item_id = v_item AND w.queue_name = 'Scheduling';
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_written := v_written + v_count::integer;

    INSERT INTO care.audit_events (event_time, actor, entity_type, entity_id, action, run_id)
    VALUES (clock_timestamp(), 'ContosoCare.Demo', 'patient', v_patient, 'view', p_run_id);
    v_written := v_written + 1;

    RETURN QUERY SELECT 6, v_read, v_written;
END;
$$;
-- @batch

-- cpu-pressure: the double-booking audit report. problem: the overlap test wraps both start times in expressions
-- and hashes every pair, so each call compares every pair of ten providers' appointments (CPU-bound, no IO).
-- healthy: the same question as an indexed range join. One call runs one report over a slice of providers.
CREATE OR REPLACE FUNCTION demo.usp_scenario_cpu_pressure(p_run_id varchar, p_worker integer, p_variant varchar)
RETURNS TABLE (executions integer, pairs_compared bigint, overlap_pairs bigint, elapsed_ms integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_scale integer := demo.fn_seed_scale();
    v_started timestamptz := clock_timestamp();
    v_from integer;
    v_pairs bigint;
    v_overlaps bigint;
BEGIN
    PERFORM demo.usp_run_assert_running(p_run_id);
    v_from := 1 + ((p_worker * 37 + EXTRACT(EPOCH FROM v_started)::bigint) % GREATEST(100 * v_scale - 9, 1))::integer;
    IF p_variant = 'healthy' THEN
        SELECT count(*), count(*) INTO v_pairs, v_overlaps
        FROM care.appointments AS a
        JOIN care.appointments AS b
          ON b.provider_id = a.provider_id
         AND b.scheduled_start >= a.scheduled_start
         AND b.scheduled_start < a.scheduled_start + make_interval(mins => a.duration_minutes)
         AND b.appointment_id <> a.appointment_id
        WHERE a.provider_id BETWEEN v_from AND v_from + 9
          AND a.status NOT IN ('Cancelled', 'NoShow');
    ELSE
        SELECT count(*),
               count(*) FILTER (WHERE abs(EXTRACT(EPOCH FROM a.scheduled_start) - EXTRACT(EPOCH FROM b.scheduled_start)) < a.duration_minutes * 60)
        INTO v_pairs, v_overlaps
        FROM care.appointments AS a
        JOIN care.appointments AS b
          ON b.provider_id = a.provider_id
         AND b.appointment_id <> a.appointment_id
        WHERE a.provider_id BETWEEN v_from AND v_from + 9
          AND a.status NOT IN ('Cancelled', 'NoShow')
          AND length(md5(a.reason_code || ':' || b.appointment_id::text)) = 32;
    END IF;
    RETURN QUERY SELECT 1, v_pairs, v_overlaps, (EXTRACT(EPOCH FROM clock_timestamp() - v_started) * 1000)::integer;
END;
$$;
-- @batch

-- locking-blocking: the hot rows are the first Billing work items still Open.
CREATE OR REPLACE FUNCTION demo.fn_locking_hot_rows(p_hot_rows integer)
RETURNS SETOF bigint
LANGUAGE sql
STABLE
AS $$
    SELECT w.work_item_id
    FROM care.work_queues AS w
    WHERE w.queue_name = 'Billing' AND w.status = 'Open'
    ORDER BY w.priority, w.work_item_id
    LIMIT GREATEST(1, LEAST(COALESCE(p_hot_rows, 10), 50));
$$;
-- @batch
-- The head blocker: row locks on the hot rows, in the caller's open transaction (the runner then sits idle in that
-- transaction and always rolls back).
CREATE OR REPLACE FUNCTION demo.usp_scenario_locking_acquire(p_run_id varchar, p_hot_rows integer)
RETURNS TABLE (run_id varchar, locked_rows integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows integer;
BEGIN
    PERFORM demo.usp_run_assert_running(p_run_id);
    UPDATE care.work_queues AS w
    SET priority = w.priority
    WHERE w.work_item_id IN (SELECT h FROM demo.fn_locking_hot_rows(p_hot_rows) AS h);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN QUERY SELECT p_run_id, v_rows;
END;
$$;
-- @batch
-- The head blocker as one active call: it locks the hot rows and waits (pg_sleep, one second at a time) for
-- p_hold_seconds, never past the deadline or a stop request. The runner rolls back afterward.
CREATE OR REPLACE FUNCTION demo.usp_scenario_locking_hold(p_run_id varchar, p_hot_rows integer, p_hold_seconds integer)
RETURNS TABLE (run_id varchar, locked_rows integer, held_ms integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_deadline timestamptz := demo.usp_run_assert_running(p_run_id);
    v_started timestamptz := clock_timestamp();
    v_until timestamptz;
    v_rows integer;
BEGIN
    UPDATE care.work_queues AS w
    SET priority = w.priority
    WHERE w.work_item_id IN (SELECT h FROM demo.fn_locking_hot_rows(p_hot_rows) AS h);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_until := LEAST(v_started + make_interval(secs => GREATEST(LEAST(COALESCE(p_hold_seconds, 60), 900), 1)), v_deadline);
    WHILE clock_timestamp() < v_until AND NOT demo.fn_run_should_stop(p_run_id) LOOP
        PERFORM pg_sleep(1);
    END LOOP;
    RETURN QUERY SELECT p_run_id, v_rows, (EXTRACT(EPOCH FROM clock_timestamp() - v_started) * 1000)::integer;
END;
$$;
-- @batch
-- A billing clerk: updates one hot row, so it waits on the head blocker's row lock (wait event Lock/transactionid).
-- The runner wraps each call in a transaction it rolls back, with lock_timeout set.
CREATE OR REPLACE FUNCTION demo.usp_scenario_locking_contend(p_run_id varchar, p_worker integer, p_hot_rows integer)
RETURNS TABLE (updates integer, waited_ms integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_item bigint;
    v_started timestamptz;
    v_rows integer;
BEGIN
    PERFORM demo.usp_run_assert_running(p_run_id);
    SELECT h INTO v_item
    FROM demo.fn_locking_hot_rows(p_hot_rows) AS h
    OFFSET (GREATEST(p_worker, 1) - 1) % GREATEST(LEAST(COALESCE(p_hot_rows, 10), 50), 1)
    LIMIT 1;
    v_started := clock_timestamp();
    UPDATE care.work_queues AS w SET priority = w.priority WHERE w.work_item_id = v_item;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN QUERY SELECT v_rows, (EXTRACT(EPOCH FROM clock_timestamp() - v_started) * 1000)::integer;
END;
$$;
-- @batch
-- The optional deadlock: side 1 locks inventory row 1 then 2, side 2 locks 2 then 1, each in a transaction the runner
-- rolls back. PostgreSQL's deadlock detector (deadlock_timeout) cancels one side with SQLSTATE 40P01.
CREATE OR REPLACE FUNCTION demo.usp_scenario_locking_deadlock(p_run_id varchar, p_side integer, p_step integer)
RETURNS TABLE (locked_inventory_id integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_id integer;
BEGIN
    PERFORM demo.usp_run_assert_running(p_run_id);
    v_id := CASE WHEN (p_side = 1) = (p_step = 1) THEN 1 ELSE 2 END;
    UPDATE care.inventory AS i SET quantity_on_hand = i.quantity_on_hand WHERE i.inventory_id = v_id;
    RETURN QUERY SELECT v_id;
END;
$$;
-- @batch

-- io-pressure: grows demo.io_scratch to p_scratch_mb (one row per page), at most p_chunk_mb per call, and never past
-- 8 GiB of database size (the 32 GiB server stays far from full; storage auto-grow is off).
CREATE OR REPLACE FUNCTION demo.usp_scenario_io_pressure_grow(p_run_id varchar, p_scratch_mb integer, p_chunk_mb integer)
RETURNS TABLE (rows_added integer, scratch_mb integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_have bigint;
    v_target bigint := LEAST(GREATEST(COALESCE(p_scratch_mb, 0), 0), 8192)::bigint * 128;
    v_add bigint;
BEGIN
    PERFORM demo.usp_run_assert_running(p_run_id);
    SELECT COALESCE(max(s.id), 0) INTO v_have FROM demo.io_scratch AS s;
    v_add := LEAST(v_target - v_have, LEAST(GREATEST(COALESCE(p_chunk_mb, 32), 1), 64)::bigint * 128);
    IF v_add > 0 THEN
        IF pg_database_size(current_database()) + v_add * 8192 > 8::bigint * 1024 * 1024 * 1024 THEN
            RAISE EXCEPTION 'io-pressure won''t grow contosocare past 8 GiB.' USING ERRCODE = 'CC003';
        END IF;
        INSERT INTO demo.io_scratch (id, run_id, touched, filler)
        SELECT v_have + g, p_run_id, 0, md5(g::text)
        FROM generate_series(1, v_add) AS g;
    ELSE
        v_add := 0;
    END IF;
    RETURN QUERY SELECT v_add::integer, ((v_have + v_add) / 128)::integer;
END;
$$;
-- @batch
-- One io-pressure cycle: a range read of up to 256 MB at a varying offset, then a 16 MB range of in-place (HOT)
-- updates that checkpoints write back. The table's fillfactor leaves room in each page, so updates don't grow it.
CREATE OR REPLACE FUNCTION demo.usp_scenario_io_pressure(p_run_id varchar, p_worker integer, p_scratch_mb integer)
RETURNS TABLE (pages_read bigint, pages_updated bigint, elapsed_ms integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_started timestamptz := clock_timestamp();
    v_rows bigint;
    v_scan bigint;
    v_from bigint;
    v_read bigint;
    v_updated bigint;
    v_n bigint := (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::bigint * 64 + p_worker;
BEGIN
    PERFORM demo.usp_run_assert_running(p_run_id);
    SELECT COALESCE(max(s.id), 0) INTO v_rows FROM demo.io_scratch AS s;
    IF v_rows = 0 THEN
        RETURN QUERY SELECT 0::bigint, 0::bigint, 0;
        RETURN;
    END IF;
    v_scan := LEAST(v_rows, 32768);
    v_from := 1 + demo.fn_rand(11, 'io-read', v_n, 0) % GREATEST(v_rows - v_scan + 1, 1);
    SELECT count(*) INTO v_read FROM demo.io_scratch AS s WHERE s.id BETWEEN v_from AND v_from + v_scan - 1 AND s.touched >= 0;
    v_from := 1 + demo.fn_rand(11, 'io-write', v_n, 1) % GREATEST(v_rows - 2048 + 1, 1);
    UPDATE demo.io_scratch AS s SET touched = s.touched + 1 WHERE s.id BETWEEN v_from AND v_from + 2047;
    GET DIAGNOSTICS v_updated = ROW_COUNT;
    RETURN QUERY SELECT v_read, v_updated, (EXTRACT(EPOCH FROM clock_timestamp() - v_started) * 1000)::integer;
END;
$$;
-- @batch

-- connection-surge: each held connection pings now and then, so it shows as active for a moment and idle otherwise.
CREATE OR REPLACE FUNCTION demo.usp_scenario_connection_surge(p_run_id varchar, p_worker integer)
RETURNS TABLE (facilities bigint)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM demo.usp_run_assert_running(p_run_id);
    RETURN QUERY SELECT count(*) FROM care.facilities AS f WHERE f.is_active;
END;
$$;
-- @batch

-- idle-in-transaction: each idle session locks its own slice of Submitted claims, then the runner leaves it idle in
-- that transaction; blocked writers update the same claims and wait (wait event Lock/transactionid).
CREATE OR REPLACE FUNCTION demo.fn_idle_rows(p_worker integer, p_rows integer)
RETURNS SETOF bigint
LANGUAGE sql
STABLE
AS $$
    SELECT c.claim_id
    FROM care.claims AS c
    WHERE c.claim_status = 'Submitted'
    ORDER BY c.claim_id
    OFFSET (GREATEST(p_worker, 1) - 1) * GREATEST(LEAST(COALESCE(p_rows, 5), 50), 1)
    LIMIT GREATEST(LEAST(COALESCE(p_rows, 5), 50), 1);
$$;
-- @batch
CREATE OR REPLACE FUNCTION demo.usp_scenario_idle_in_transaction(p_run_id varchar, p_worker integer, p_rows integer)
RETURNS TABLE (locked_rows integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows integer;
BEGIN
    PERFORM demo.usp_run_assert_running(p_run_id);
    UPDATE care.claims AS c
    SET claim_status = c.claim_status
    WHERE c.claim_id IN (SELECT r FROM demo.fn_idle_rows(p_worker, p_rows) AS r);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN QUERY SELECT v_rows;
END;
$$;
-- @batch
CREATE OR REPLACE FUNCTION demo.usp_scenario_idle_writer(p_run_id varchar, p_idle_worker integer, p_rows integer)
RETURNS TABLE (updates integer, waited_ms integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_claim bigint;
    v_started timestamptz;
    v_rows integer;
BEGIN
    PERFORM demo.usp_run_assert_running(p_run_id);
    SELECT r INTO v_claim FROM demo.fn_idle_rows(p_idle_worker, p_rows) AS r LIMIT 1;
    v_started := clock_timestamp();
    UPDATE care.claims AS c SET claim_status = c.claim_status WHERE c.claim_id = v_claim;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN QUERY SELECT v_rows, (EXTRACT(EPOCH FROM clock_timestamp() - v_started) * 1000)::integer;
END;
$$;
