-- Deterministic seed for T4's contosocare database (Phase 24, ADR 0019). Every row is synthetic. The same scale
-- always produces the same rows: values come from demo.fn_rand (MD5 of seed, stream, and row number), never from
-- random(). Run it in the contosocare database; 'ContosoCare.Workload setup --target T4 --seed-scale <n>' calls it.
-- Batches are separated by lines that hold only '-- @batch'.

CREATE OR REPLACE FUNCTION demo.usp_seed_contosocare(p_scale integer, p_force boolean DEFAULT false)
RETURNS TABLE (check_id text, status text, message text)
LANGUAGE plpgsql
AS $$
DECLARE
    v_seed constant integer := 20261023;
    v_version constant integer := 1;
    v_base constant timestamptz := timestamptz '2026-10-01 00:00:00+00';
    v_providers integer;
    v_patients integer;
    v_appointments integer;
    v_encounters integer;
    v_work_items integer;
    v_state demo.seed_state%ROWTYPE;
BEGIN
    IF p_scale IS NULL OR p_scale < 1 OR p_scale > 50 THEN
        RAISE EXCEPTION 'p_scale must be between 1 and 50.' USING ERRCODE = '22023';
    END IF;

    -- One seed at a time; the lock ends with the transaction.
    PERFORM pg_advisory_xact_lock(24240001);

    SELECT s.* INTO v_state FROM demo.seed_state AS s WHERE s.seed_state_id = 1;
    IF FOUND AND v_state.status = 'Completed' AND v_state.scale = p_scale AND v_state.seed_version = v_version AND NOT p_force THEN
        RETURN QUERY SELECT 'seed'::text, 'Pass'::text, format('contosocare is already seeded at scale %s.', p_scale);
        RETURN;
    END IF;

    v_providers := 100 * p_scale;
    v_patients := 10000 * p_scale;
    v_appointments := 40000 * p_scale;
    v_encounters := 20000 * p_scale;
    v_work_items := 2000 * p_scale;

    INSERT INTO demo.seed_state AS s (seed_state_id, seed, scale, seed_version, status, started_at, completed_at)
    VALUES (1, v_seed, p_scale, v_version, 'Running', now(), NULL)
    ON CONFLICT (seed_state_id) DO UPDATE
        SET seed = EXCLUDED.seed, scale = EXCLUDED.scale, seed_version = EXCLUDED.seed_version,
            status = 'Running', started_at = EXCLUDED.started_at, completed_at = NULL;

    TRUNCATE care.audit_events, care.work_queues, care.claims, care.encounters, care.appointments,
        care.inventory, care.patients, care.providers, care.facilities;

    INSERT INTO care.facilities (facility_id, facility_code, facility_name, facility_type, region, bed_count, opened_on)
    SELECT g,
           'FAC-' || lpad(g::text, 3, '0'),
           'Contoso Care ' || (ARRAY['North', 'South', 'East', 'West', 'Central'])[1 + g % 5] || ' ' || (ARRAY['Hospital', 'Clinic', 'Lab', 'Pharmacy'])[1 + g % 4] || ' ' || g,
           (ARRAY['Hospital', 'Clinic', 'Lab', 'Pharmacy'])[1 + g % 4],
           (ARRAY['North', 'South', 'East', 'West', 'Central'])[1 + g % 5],
           CASE WHEN g % 4 = 0 THEN 0 ELSE 20 + (demo.fn_rand(v_seed, 'facility', g, 0) % 200)::integer END,
           date '2005-01-01' + (demo.fn_rand(v_seed, 'facility', g, 1) % 6000)::integer
    FROM generate_series(1, 20) AS g;

    INSERT INTO care.providers (provider_id, provider_code, display_name, specialty, facility_id, hired_on)
    SELECT g,
           'PRV-' || lpad(g::text, 5, '0'),
           'Dr. Synthetic Provider ' || g,
           (ARRAY['Family Medicine', 'Cardiology', 'Pediatrics', 'Orthopedics', 'Radiology', 'Oncology', 'Dermatology', 'Neurology'])[1 + (demo.fn_rand(v_seed, 'provider', g, 0) % 8)::integer],
           1 + (demo.fn_rand(v_seed, 'provider', g, 1) % 20)::integer,
           date '2010-01-01' + (demo.fn_rand(v_seed, 'provider', g, 2) % 5000)::integer
    FROM generate_series(1, v_providers) AS g;

    INSERT INTO care.patients (patient_id, mrn, given_name, family_name, birth_date, sex, postal_code, primary_facility_id, created_at)
    SELECT g,
           'MRN' || lpad(g::text, 8, '0'),
           (ARRAY['Avery', 'Jordan', 'Riley', 'Casey', 'Morgan', 'Quinn', 'Taylor', 'Skyler', 'Reese', 'Rowan'])[1 + (demo.fn_rand(v_seed, 'patient', g, 0) % 10)::integer],
           'Testpatient' || (1 + (demo.fn_rand(v_seed, 'patient', g, 1) % 997)),
           date '1940-01-01' + (demo.fn_rand(v_seed, 'patient', g, 2) % 29000)::integer,
           (ARRAY['F', 'M', 'X'])[1 + (demo.fn_rand(v_seed, 'patient', g, 3) % 3)::integer],
           '9' || lpad((demo.fn_rand(v_seed, 'patient', g, 0) % 10000)::text, 4, '0'),
           1 + (demo.fn_rand(v_seed, 'patient', g, 1) % 20)::integer,
           v_base - make_interval(days => (demo.fn_rand(v_seed, 'patient', g, 2) % 1500)::integer)
    FROM generate_series(1, v_patients) AS g;

    INSERT INTO care.appointments (appointment_id, patient_id, provider_id, facility_id, scheduled_start, duration_minutes, status, reason_code, created_at)
    SELECT a.g,
           1 + (demo.fn_rand(v_seed, 'appointment', a.g, 0) % v_patients)::integer,
           p.provider_id,
           p.facility_id,
           v_base - interval '30 days' + make_interval(mins => (demo.fn_rand(v_seed, 'appointment', a.g, 2) % (60 * 24 * 90))::integer),
           (ARRAY[15, 30, 45, 60])[1 + (demo.fn_rand(v_seed, 'appointment', a.g, 3) % 4)::integer]::smallint,
           (ARRAY['Scheduled', 'Scheduled', 'CheckedIn', 'Completed', 'Completed', 'Completed', 'Cancelled', 'NoShow'])[1 + (demo.fn_rand(v_seed, 'appointment', a.g, 0) % 8)::integer],
           'R' || lpad((demo.fn_rand(v_seed, 'appointment', a.g, 1) % 50)::text, 3, '0'),
           v_base - interval '60 days'
    FROM (SELECT g, 1 + (demo.fn_rand(v_seed, 'appointment', g, 1) % v_providers)::integer AS provider_id FROM generate_series(1, v_appointments) AS g) AS a
    JOIN care.providers AS p ON p.provider_id = a.provider_id;

    INSERT INTO care.encounters (encounter_id, appointment_id, patient_id, provider_id, facility_id, encounter_type, started_at, ended_at, acuity, diagnosis_code)
    SELECT e.g,
           ap.appointment_id,
           ap.patient_id,
           ap.provider_id,
           ap.facility_id,
           (ARRAY['Office', 'Telehealth', 'Emergency', 'Inpatient'])[1 + (demo.fn_rand(v_seed, 'encounter', e.g, 0) % 4)::integer],
           ap.scheduled_start,
           ap.scheduled_start + make_interval(mins => ap.duration_minutes),
           (1 + demo.fn_rand(v_seed, 'encounter', e.g, 1) % 5)::smallint,
           'D' || lpad((demo.fn_rand(v_seed, 'encounter', e.g, 2) % 900)::text, 4, '0')
    FROM generate_series(1, v_encounters) AS e (g)
    JOIN care.appointments AS ap ON ap.appointment_id = e.g * 2;

    INSERT INTO care.claims (claim_id, encounter_id, patient_id, payer_code, claim_status, submitted_on, billed_amount, paid_amount)
    SELECT en.encounter_id,
           en.encounter_id,
           en.patient_id,
           (ARRAY['CONTOSO-HMO', 'FABRIKAM-PPO', 'NORTHWIND-MED', 'SELF-PAY', 'TAILSPIN-INS'])[1 + (demo.fn_rand(v_seed, 'claim', en.encounter_id, 0) % 5)::integer],
           (ARRAY['Draft', 'Submitted', 'Submitted', 'Paid', 'Paid', 'Denied', 'Appealed'])[1 + (demo.fn_rand(v_seed, 'claim', en.encounter_id, 1) % 7)::integer],
           (en.started_at + interval '3 days')::date,
           round((50 + (demo.fn_rand(v_seed, 'claim', en.encounter_id, 2) % 500000) / 100.0)::numeric, 2),
           round((demo.fn_rand(v_seed, 'claim', en.encounter_id, 3) % 30000) / 100.0, 2)
    FROM care.encounters AS en;

    INSERT INTO care.inventory (inventory_id, facility_id, item_sku, item_name, quantity_on_hand, reorder_level, updated_at)
    SELECT (f.facility_id - 1) * 50 + i,
           f.facility_id,
           'SKU-' || lpad(i::text, 4, '0'),
           'Synthetic supply item ' || i,
           (demo.fn_rand(v_seed, 'inventory', (f.facility_id - 1) * 50 + i, 0) % 900)::integer + 50,
           25,
           v_base
    FROM care.facilities AS f
    CROSS JOIN generate_series(1, 50) AS i;

    INSERT INTO care.work_queues (work_item_id, queue_name, facility_id, patient_id, claim_id, priority, status, created_at, due_at)
    SELECT g,
           (ARRAY['Billing', 'Scheduling', 'Referrals', 'Coding'])[1 + g % 4],
           1 + (demo.fn_rand(v_seed, 'work', g, 0) % 20)::integer,
           CASE WHEN g % 4 = 0 THEN NULL ELSE 1 + (demo.fn_rand(v_seed, 'work', g, 1) % v_patients)::integer END,
           CASE WHEN g % 4 = 0 THEN 1 + (demo.fn_rand(v_seed, 'work', g, 1) % v_encounters)::bigint ELSE NULL END,
           (1 + demo.fn_rand(v_seed, 'work', g, 2) % 5)::smallint,
           (ARRAY['Open', 'Open', 'Open', 'Open', 'Open', 'Open', 'Open', 'InProgress', 'InProgress', 'Done'])[1 + (demo.fn_rand(v_seed, 'work', g, 3) % 10)::integer],
           v_base - make_interval(hours => (demo.fn_rand(v_seed, 'work', g, 2) % 720)::integer),
           v_base + make_interval(hours => (demo.fn_rand(v_seed, 'work', g, 3) % 720)::integer)
    FROM generate_series(1, v_work_items) AS g;

    UPDATE demo.seed_state SET status = 'Completed', completed_at = now() WHERE seed_state_id = 1;

    RETURN QUERY SELECT 'seed'::text, 'Pass'::text,
        format('contosocare seeded at scale %s: %s providers, %s patients, %s appointments, %s encounters and claims, %s work items.',
               p_scale, v_providers, v_patients, v_appointments, v_encounters, v_work_items);
END;
$$;
