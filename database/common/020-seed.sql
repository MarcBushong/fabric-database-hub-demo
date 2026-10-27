-- Deterministic, set-based seed for ContosoCare (ADR 0010). The same @seed and @scale produce the same rows
-- on every target and every run: pseudo-random values come from SHA-256 of (seed, stream, row number) via
-- demo.fn_rand, never from RAND() or NEWID(). Every value is obviously synthetic: "Test Patient-0000001",
-- 555-01xx phone numbers, example.invalid email addresses, and SYN- codes. Idempotent: a completed seed with
-- the same seed, scale, and version is a no-op unless @force = 1. Run it in the ContosoCare database.

CREATE OR ALTER PROCEDURE demo.usp_seed_contosocare
    @scale int = 1,
    @seed int = 20261019,
    @force bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @version int = 1;
    DECLARE @base date = '2026-01-01';
    DECLARE @base_time datetime2(0) = '2026-01-01T08:00:00';

    IF @scale IS NULL OR @scale < 1 OR @scale > 50
        THROW 50001, N'@scale must be between 1 and 50.', 1;

    IF @force = 0 AND EXISTS (
        SELECT 1 FROM demo.seed_state
        WHERE seed_state_id = 1 AND status = 'Completed' AND seed = @seed AND scale = @scale AND seed_version = @version)
        RETURN 0;

    IF EXISTS (SELECT 1 FROM demo.scenario_runs WHERE status = 'Running')
        THROW 50002, N'A scenario run is still Running. Stop it before reseeding.', 1;

    DECLARE @patients int = 5000 * @scale;
    DECLARE @providers int = 40 * @scale;
    DECLARE @appointments int = 20000 * @scale;
    DECLARE @audit_events int = 10000 * @scale;
    DECLARE @work_items int = 2000 * @scale;
    DECLARE @claims int;

    IF EXISTS (SELECT 1 FROM demo.seed_state WHERE seed_state_id = 1)
        UPDATE demo.seed_state
        SET seed = @seed, scale = @scale, seed_version = @version, status = 'Running', started_at = SYSUTCDATETIME(), completed_at = NULL
        WHERE seed_state_id = 1;
    ELSE
        INSERT INTO demo.seed_state (seed_state_id, seed, scale, seed_version, status, started_at)
        VALUES (1, @seed, @scale, @version, 'Running', SYSUTCDATETIME());

    BEGIN TRANSACTION;

    -- Children first, so foreign keys hold. Demo control tables are left alone.
    DELETE FROM care.work_queues;
    DELETE FROM care.payments;
    DELETE FROM care.orders;
    DELETE FROM care.claims;
    DELETE FROM care.encounters;
    DELETE FROM care.appointments;
    DELETE FROM care.inventory;
    DELETE FROM care.patients;
    DELETE FROM care.providers;
    DELETE FROM care.facilities;
    DELETE FROM care.audit_events;

    -- 12 fixed sites: hospitals, clinics, labs, and pharmacies in three regions.
    INSERT INTO care.facilities (facility_id, facility_code, facility_name, facility_type, region, bed_count, opened_on)
    SELECT
        n.n,
        CONCAT('FAC-', RIGHT(CONCAT('000', n.n), 3)),
        CONCAT(N'Contoso Care ', CHOOSE(1 + (CAST(n.n AS int) - 1) % 4, N'Hospital', N'Clinic', N'Lab', N'Pharmacy'), N' ', n.n),
        CHOOSE(1 + (CAST(n.n AS int) - 1) % 4, 'Hospital', 'Clinic', 'Lab', 'Pharmacy'),
        CHOOSE(1 + (CAST(n.n AS int) - 1) % 3, 'North', 'Central', 'South'),
        CASE WHEN (n.n - 1) % 4 = 0 THEN CAST(100 + r.r1 % 300 AS int) ELSE 0 END,
        DATEADD(day, -CAST(r.r2 % 7300 AS int), @base)
    FROM demo.fn_numbers(12) AS n
    CROSS APPLY demo.fn_rand(@seed, 'facilities', n.n) AS r;

    INSERT INTO care.providers (provider_id, provider_code, display_name, specialty, facility_id, hired_on)
    SELECT
        n.n,
        CONCAT('PRV-', RIGHT(CONCAT('00000', n.n), 5)),
        CONCAT(N'Dr. Synthetic ', RIGHT(CONCAT('00000', n.n), 5)),
        CHOOSE(1 + CAST(r.r1 % 8 AS int), 'Family Medicine', 'Cardiology', 'Orthopedics', 'Pediatrics', 'Radiology', 'Oncology', 'Dermatology', 'Emergency'),
        1 + CAST(r.r2 % 12 AS int),
        DATEADD(day, -CAST(r.r3 % 5000 AS int), @base)
    FROM demo.fn_numbers(@providers) AS n
    CROSS APPLY demo.fn_rand(@seed, 'providers', n.n) AS r;

    INSERT INTO care.patients (patient_id, mrn, given_name, family_name, birth_date, sex, postal_code, phone, email, primary_facility_id, created_at)
    SELECT
        n.n,
        CONCAT('SYN-', RIGHT(CONCAT('0000000', n.n), 7)),
        N'Test',
        CONCAT(N'Patient-', RIGHT(CONCAT('0000000', n.n), 7)),
        DATEADD(day, -CAST(6570 + r.r1 % 25550 AS int), @base),
        CHOOSE(1 + CAST(r.r2 % 3 AS int), 'F', 'M', 'X'),
        CONCAT('SYN-', RIGHT(CONCAT('000', r.r3 % 1000), 3)),
        CONCAT('555-01', RIGHT(CONCAT('00', r.r4 % 100), 2)),
        CONCAT('patient', RIGHT(CONCAT('0000000', n.n), 7), '@example.invalid'),
        1 + CAST(r.r5 % 12 AS int),
        DATEADD(minute, CAST(r.r6 % 525600 AS int), DATEADD(year, -2, @base_time))
    FROM demo.fn_numbers(@patients) AS n
    CROSS APPLY demo.fn_rand(@seed, 'patients', n.n) AS r;

    SET IDENTITY_INSERT care.appointments ON;
    INSERT INTO care.appointments (appointment_id, patient_id, provider_id, facility_id, scheduled_start, duration_minutes, status, reason_code, created_at)
    SELECT
        n.n,
        1 + CAST(r.r1 % @patients AS int),
        p.provider_id,
        p.facility_id,
        DATEADD(minute, CAST((r.r3 % 9) * 60 + (r.r4 % 4) * 15 AS int), DATEADD(day, CAST(r.r2 % 365 AS int), @base_time)),
        CAST(CHOOSE(1 + CAST(r.r5 % 4 AS int), 15, 20, 30, 45) AS smallint),
        CASE
            WHEN r.r6 % 100 < 70 THEN 'Completed'
            WHEN r.r6 % 100 < 80 THEN 'Scheduled'
            WHEN r.r6 % 100 < 88 THEN 'Cancelled'
            WHEN r.r6 % 100 < 95 THEN 'NoShow'
            ELSE 'CheckedIn'
        END,
        CONCAT('SYN-R', RIGHT(CONCAT('00', r.r6 % 50), 2)),
        DATEADD(day, -CAST(1 + r.r3 % 30 AS int), DATEADD(day, CAST(r.r2 % 365 AS int), @base_time))
    FROM demo.fn_numbers(@appointments) AS n
    CROSS APPLY demo.fn_rand(@seed, 'appointments', n.n) AS r
    INNER JOIN care.providers AS p ON p.provider_id = 1 + CAST((r.r1 / 7) % @providers AS int);
    SET IDENTITY_INSERT care.appointments OFF;

    SET IDENTITY_INSERT care.encounters ON;
    INSERT INTO care.encounters (encounter_id, appointment_id, patient_id, provider_id, facility_id, encounter_type, started_at, ended_at, acuity, diagnosis_code, notes)
    SELECT
        ROW_NUMBER() OVER (ORDER BY a.appointment_id),
        a.appointment_id,
        a.patient_id,
        a.provider_id,
        a.facility_id,
        CHOOSE(1 + CAST(r.r1 % 4 AS int), 'Office', 'Telehealth', 'Procedure', 'FollowUp'),
        a.scheduled_start,
        CASE WHEN a.status = 'Completed' THEN DATEADD(minute, a.duration_minutes, a.scheduled_start) END,
        CAST(1 + r.r2 % 5 AS tinyint),
        CONCAT('SYN-D', RIGHT(CONCAT('000', r.r3 % 200), 3)),
        CASE WHEN r.r4 % 10 = 0 THEN N'Synthetic follow-up note for demo purposes only.' END
    FROM care.appointments AS a
    CROSS APPLY demo.fn_rand(@seed, 'encounters', a.appointment_id) AS r
    WHERE a.status IN ('Completed', 'CheckedIn');
    SET IDENTITY_INSERT care.encounters OFF;

    SET IDENTITY_INSERT care.claims ON;
    INSERT INTO care.claims (claim_id, encounter_id, patient_id, payer_code, claim_status, submitted_on, billed_amount, allowed_amount, paid_amount)
    SELECT
        ROW_NUMBER() OVER (ORDER BY e.encounter_id),
        e.encounter_id,
        e.patient_id,
        CHOOSE(1 + CAST(r.r1 % 5 AS int), 'PAYER-A', 'PAYER-B', 'PAYER-C', 'PAYER-D', 'SELF-PAY'),
        s.claim_status,
        DATEADD(day, CAST(1 + r.r3 % 14 AS int), CAST(e.started_at AS date)),
        b.billed,
        CAST(b.billed * 0.8 AS decimal(12, 2)),
        CASE WHEN s.claim_status = 'Paid' THEN CAST(b.billed * 0.8 AS decimal(12, 2)) ELSE 0 END
    FROM care.encounters AS e
    CROSS APPLY demo.fn_rand(@seed, 'claims', e.encounter_id) AS r
    CROSS APPLY (SELECT billed = CAST(50 + (r.r4 % 500000) / 100.0 AS decimal(12, 2))) AS b
    CROSS APPLY (
        SELECT claim_status = CASE
            WHEN r.r2 % 100 < 60 THEN 'Paid'
            WHEN r.r2 % 100 < 80 THEN 'Submitted'
            WHEN r.r2 % 100 < 90 THEN 'Denied'
            WHEN r.r2 % 100 < 95 THEN 'Appealed'
            ELSE 'Draft'
        END) AS s
    WHERE e.ended_at IS NOT NULL;
    SET IDENTITY_INSERT care.claims OFF;

    SET @claims = (SELECT COUNT(*) FROM care.claims);

    SET IDENTITY_INSERT care.orders ON;
    INSERT INTO care.orders (order_id, encounter_id, order_type, item_sku, quantity, status, ordered_at, completed_at)
    SELECT
        ROW_NUMBER() OVER (ORDER BY e.encounter_id, k.k),
        e.encounter_id,
        CHOOSE(1 + CAST(r.r2 % 4 AS int), 'Lab', 'Imaging', 'Medication', 'Supply'),
        CONCAT('SKU-', RIGHT(CONCAT('0000', 1 + r.r3 % 50), 4)),
        CAST(1 + r.r4 % 5 AS int),
        CASE WHEN e.ended_at IS NULL THEN 'Ordered' WHEN r.r5 % 10 = 0 THEN 'Cancelled' ELSE 'Completed' END,
        DATEADD(minute, CAST(r.r6 % 30 AS int), e.started_at),
        CASE WHEN e.ended_at IS NULL OR r.r5 % 10 = 0 THEN NULL ELSE DATEADD(hour, CAST(1 + r.r6 % 48 AS int), e.started_at) END
    FROM care.encounters AS e
    CROSS APPLY demo.fn_rand(@seed, 'orders', e.encounter_id) AS h
    CROSS APPLY (VALUES (1), (2), (3)) AS k (k)
    CROSS APPLY demo.fn_rand(@seed, 'order-lines', e.encounter_id * 4 + k.k) AS r
    WHERE k.k <= 1 + h.r1 % 3;
    SET IDENTITY_INSERT care.orders OFF;

    -- 50 supply items per facility.
    INSERT INTO care.inventory (inventory_id, facility_id, item_sku, item_name, quantity_on_hand, reorder_level, unit_cost, updated_at)
    SELECT
        (f.facility_id - 1) * 50 + CAST(i.n AS int),
        f.facility_id,
        CONCAT('SKU-', RIGHT(CONCAT('0000', i.n), 4)),
        CONCAT(N'Synthetic supply item ', i.n),
        CAST(r.r1 % 500 AS int),
        CAST(20 + r.r2 % 80 AS int),
        CAST(1 + (r.r3 % 20000) / 100.0 AS decimal(10, 2)),
        DATEADD(minute, CAST(r.r4 % 525600 AS int), DATEADD(year, -1, @base_time))
    FROM care.facilities AS f
    CROSS JOIN demo.fn_numbers(50) AS i
    CROSS APPLY demo.fn_rand(@seed, 'inventory', (f.facility_id - 1) * 50 + i.n) AS r;

    SET IDENTITY_INSERT care.payments ON;
    INSERT INTO care.payments (payment_id, claim_id, paid_on, amount, method)
    SELECT
        ROW_NUMBER() OVER (ORDER BY c.claim_id),
        c.claim_id,
        DATEADD(day, CAST(5 + r.r1 % 40 AS int), c.submitted_on),
        c.paid_amount,
        CHOOSE(1 + CAST(r.r2 % 3 AS int), 'EFT', 'Check', 'Card')
    FROM care.claims AS c
    CROSS APPLY demo.fn_rand(@seed, 'payments', c.claim_id) AS r
    WHERE c.claim_status = 'Paid';
    SET IDENTITY_INSERT care.payments OFF;

    SET IDENTITY_INSERT care.work_queues ON;
    INSERT INTO care.work_queues (work_item_id, queue_name, facility_id, patient_id, claim_id, priority, status, created_at, due_at, assigned_to)
    SELECT
        n.n,
        q.queue_name,
        1 + CAST(r.r2 % 12 AS int),
        1 + CAST(r.r3 % @patients AS int),
        CASE WHEN q.queue_name = 'Billing' AND @claims > 0 THEN 1 + r.r4 % @claims END,
        CAST(1 + r.r5 % 5 AS tinyint),
        CASE WHEN r.r6 % 10 < 6 THEN 'Open' WHEN r.r6 % 10 < 8 THEN 'InProgress' ELSE 'Done' END,
        t.created_at,
        DATEADD(day, CAST(1 + r.r5 % 10 AS int), t.created_at),
        CASE WHEN r.r6 % 10 < 6 THEN NULL ELSE 1 + CAST(r.r1 % @providers AS int) END
    FROM demo.fn_numbers(@work_items) AS n
    CROSS APPLY demo.fn_rand(@seed, 'work-queues', n.n) AS r
    CROSS APPLY (SELECT queue_name = CHOOSE(1 + CAST(r.r1 % 4 AS int), 'Billing', 'Scheduling', 'Referrals', 'PriorAuth')) AS q
    CROSS APPLY (SELECT created_at = DATEADD(minute, CAST(r.r4 % 525600 AS int), @base_time)) AS t;
    SET IDENTITY_INSERT care.work_queues OFF;

    SET IDENTITY_INSERT care.audit_events ON;
    INSERT INTO care.audit_events (audit_event_id, event_time, actor, entity_type, entity_id, action, details)
    SELECT
        n.n,
        DATEADD(second, CAST(r.r1 % 31536000 AS int), CAST(@base_time AS datetime2(3))),
        CONCAT('svc-synthetic-', RIGHT(CONCAT('00', r.r2 % 20), 2)),
        CHOOSE(1 + CAST(r.r3 % 4 AS int), 'appointment', 'claim', 'order', 'patient'),
        1 + r.r4 % 100000,
        CHOOSE(1 + CAST(r.r5 % 4 AS int), 'Create', 'Update', 'View', 'Export'),
        N'Synthetic audit event.'
    FROM demo.fn_numbers(@audit_events) AS n
    CROSS APPLY demo.fn_rand(@seed, 'audit-events', n.n) AS r;
    SET IDENTITY_INSERT care.audit_events OFF;

    COMMIT TRANSACTION;

    UPDATE demo.seed_state
    SET status = 'Completed', completed_at = SYSUTCDATETIME()
    WHERE seed_state_id = 1;

    RETURN 0;
END;
GO
