-- ContosoCare Operations schema (ADR 0010). Every row is synthetic: no real people, PHI, or PII.
-- Idempotent: safe to run again on any target. Portable across SQL Server 2022 and Azure SQL Database,
-- so it has no USE statement, filegroups, or instance-level settings. Run it in the ContosoCare database.
-- Some columns are deliberately left without an index for the missing-index scenario (Phase 11).

IF SCHEMA_ID(N'care') IS NULL
    EXEC (N'CREATE SCHEMA care AUTHORIZATION dbo;');
GO
IF SCHEMA_ID(N'demo') IS NULL
    EXEC (N'CREATE SCHEMA demo AUTHORIZATION dbo;');
GO

-- Business tables (schema care) ------------------------------------------------------------------

IF OBJECT_ID(N'care.facilities', N'U') IS NULL
CREATE TABLE care.facilities
(
    facility_id     int           NOT NULL CONSTRAINT pk_facilities PRIMARY KEY,
    facility_code   varchar(16)   NOT NULL CONSTRAINT uq_facilities_code UNIQUE,
    facility_name   nvarchar(100) NOT NULL,
    facility_type   varchar(20)   NOT NULL CONSTRAINT ck_facilities_type CHECK (facility_type IN ('Hospital', 'Clinic', 'Lab', 'Pharmacy')),
    region          varchar(20)   NOT NULL,
    bed_count       int           NOT NULL CONSTRAINT df_facilities_beds DEFAULT (0),
    opened_on       date          NOT NULL,
    is_active       bit           NOT NULL CONSTRAINT df_facilities_active DEFAULT (1)
);
GO

IF OBJECT_ID(N'care.providers', N'U') IS NULL
CREATE TABLE care.providers
(
    provider_id     int           NOT NULL CONSTRAINT pk_providers PRIMARY KEY,
    provider_code   varchar(16)   NOT NULL CONSTRAINT uq_providers_code UNIQUE,
    display_name    nvarchar(100) NOT NULL,
    specialty       varchar(40)   NOT NULL,
    facility_id     int           NOT NULL CONSTRAINT fk_providers_facility REFERENCES care.facilities (facility_id),
    hired_on        date          NOT NULL,
    is_active       bit           NOT NULL CONSTRAINT df_providers_active DEFAULT (1)
);
GO

IF OBJECT_ID(N'care.patients', N'U') IS NULL
CREATE TABLE care.patients
(
    patient_id          int           NOT NULL CONSTRAINT pk_patients PRIMARY KEY,
    mrn                 varchar(20)   NOT NULL CONSTRAINT uq_patients_mrn UNIQUE,
    given_name          nvarchar(50)  NOT NULL,
    family_name         nvarchar(50)  NOT NULL,
    birth_date          date          NOT NULL,
    sex                 char(1)       NOT NULL CONSTRAINT ck_patients_sex CHECK (sex IN ('F', 'M', 'X')),
    postal_code         varchar(10)   NOT NULL,
    phone               varchar(20)   NOT NULL,
    email               varchar(100)  NOT NULL,
    primary_facility_id int           NOT NULL CONSTRAINT fk_patients_facility REFERENCES care.facilities (facility_id),
    created_at          datetime2(0)  NOT NULL,
    is_synthetic        bit           NOT NULL CONSTRAINT df_patients_synthetic DEFAULT (1) CONSTRAINT ck_patients_synthetic CHECK (is_synthetic = 1)
);
GO

IF OBJECT_ID(N'care.appointments', N'U') IS NULL
CREATE TABLE care.appointments
(
    appointment_id   bigint IDENTITY(1, 1) NOT NULL CONSTRAINT pk_appointments PRIMARY KEY,
    patient_id       int           NOT NULL CONSTRAINT fk_appointments_patient REFERENCES care.patients (patient_id),
    provider_id      int           NOT NULL CONSTRAINT fk_appointments_provider REFERENCES care.providers (provider_id),
    facility_id      int           NOT NULL CONSTRAINT fk_appointments_facility REFERENCES care.facilities (facility_id),
    scheduled_start  datetime2(0)  NOT NULL,
    duration_minutes smallint      NOT NULL,
    status           varchar(20)   NOT NULL CONSTRAINT ck_appointments_status CHECK (status IN ('Scheduled', 'CheckedIn', 'Completed', 'Cancelled', 'NoShow')),
    reason_code      varchar(20)   NOT NULL,
    created_at       datetime2(0)  NOT NULL
);
GO

IF OBJECT_ID(N'care.encounters', N'U') IS NULL
CREATE TABLE care.encounters
(
    encounter_id     bigint IDENTITY(1, 1) NOT NULL CONSTRAINT pk_encounters PRIMARY KEY,
    appointment_id   bigint        NULL CONSTRAINT fk_encounters_appointment REFERENCES care.appointments (appointment_id),
    patient_id       int           NOT NULL CONSTRAINT fk_encounters_patient REFERENCES care.patients (patient_id),
    provider_id      int           NOT NULL CONSTRAINT fk_encounters_provider REFERENCES care.providers (provider_id),
    facility_id      int           NOT NULL CONSTRAINT fk_encounters_facility REFERENCES care.facilities (facility_id),
    encounter_type   varchar(20)   NOT NULL,
    started_at       datetime2(0)  NOT NULL,
    ended_at         datetime2(0)  NULL,
    acuity           tinyint       NOT NULL,
    diagnosis_code   varchar(12)   NOT NULL,
    notes            nvarchar(400) NULL
);
GO

IF OBJECT_ID(N'care.claims', N'U') IS NULL
CREATE TABLE care.claims
(
    claim_id         bigint IDENTITY(1, 1) NOT NULL CONSTRAINT pk_claims PRIMARY KEY,
    encounter_id     bigint        NOT NULL CONSTRAINT fk_claims_encounter REFERENCES care.encounters (encounter_id),
    patient_id       int           NOT NULL CONSTRAINT fk_claims_patient REFERENCES care.patients (patient_id),
    payer_code       varchar(20)   NOT NULL,
    claim_status     varchar(20)   NOT NULL CONSTRAINT ck_claims_status CHECK (claim_status IN ('Draft', 'Submitted', 'Denied', 'Paid', 'Appealed')),
    submitted_on     date          NOT NULL,
    billed_amount    decimal(12, 2) NOT NULL,
    allowed_amount   decimal(12, 2) NOT NULL,
    paid_amount      decimal(12, 2) NOT NULL
);
GO

IF OBJECT_ID(N'care.orders', N'U') IS NULL
CREATE TABLE care.orders
(
    order_id         bigint IDENTITY(1, 1) NOT NULL CONSTRAINT pk_orders PRIMARY KEY,
    encounter_id     bigint        NOT NULL CONSTRAINT fk_orders_encounter REFERENCES care.encounters (encounter_id),
    order_type       varchar(20)   NOT NULL CONSTRAINT ck_orders_type CHECK (order_type IN ('Lab', 'Imaging', 'Medication', 'Supply')),
    item_sku         varchar(20)   NOT NULL,
    quantity         int           NOT NULL,
    status           varchar(20)   NOT NULL CONSTRAINT ck_orders_status CHECK (status IN ('Ordered', 'InProgress', 'Completed', 'Cancelled')),
    ordered_at       datetime2(0)  NOT NULL,
    completed_at     datetime2(0)  NULL
);
GO

IF OBJECT_ID(N'care.inventory', N'U') IS NULL
CREATE TABLE care.inventory
(
    inventory_id     int           NOT NULL CONSTRAINT pk_inventory PRIMARY KEY,
    facility_id      int           NOT NULL CONSTRAINT fk_inventory_facility REFERENCES care.facilities (facility_id),
    item_sku         varchar(20)   NOT NULL,
    item_name        nvarchar(100) NOT NULL,
    quantity_on_hand int           NOT NULL,
    reorder_level    int           NOT NULL,
    unit_cost        decimal(10, 2) NOT NULL,
    updated_at       datetime2(0)  NOT NULL,
    CONSTRAINT uq_inventory_facility_sku UNIQUE (facility_id, item_sku)
);
GO

IF OBJECT_ID(N'care.payments', N'U') IS NULL
CREATE TABLE care.payments
(
    payment_id       bigint IDENTITY(1, 1) NOT NULL CONSTRAINT pk_payments PRIMARY KEY,
    claim_id         bigint        NOT NULL CONSTRAINT fk_payments_claim REFERENCES care.claims (claim_id),
    paid_on          date          NOT NULL,
    amount           decimal(12, 2) NOT NULL,
    method           varchar(20)   NOT NULL
);
GO

IF OBJECT_ID(N'care.audit_events', N'U') IS NULL
CREATE TABLE care.audit_events
(
    audit_event_id   bigint IDENTITY(1, 1) NOT NULL CONSTRAINT pk_audit_events PRIMARY KEY,
    event_time       datetime2(3)  NOT NULL,
    actor            varchar(64)   NOT NULL,
    entity_type      varchar(32)   NOT NULL,
    entity_id        bigint        NOT NULL,
    action           varchar(20)   NOT NULL,
    details          nvarchar(200) NULL
);
GO

IF OBJECT_ID(N'care.work_queues', N'U') IS NULL
CREATE TABLE care.work_queues
(
    work_item_id     bigint IDENTITY(1, 1) NOT NULL CONSTRAINT pk_work_queues PRIMARY KEY,
    queue_name       varchar(32)   NOT NULL,
    facility_id      int           NOT NULL CONSTRAINT fk_work_queues_facility REFERENCES care.facilities (facility_id),
    patient_id       int           NULL CONSTRAINT fk_work_queues_patient REFERENCES care.patients (patient_id),
    claim_id         bigint        NULL CONSTRAINT fk_work_queues_claim REFERENCES care.claims (claim_id),
    priority         tinyint       NOT NULL,
    status           varchar(20)   NOT NULL CONSTRAINT ck_work_queues_status CHECK (status IN ('Open', 'InProgress', 'Done')),
    created_at       datetime2(0)  NOT NULL,
    due_at           datetime2(0)  NOT NULL,
    assigned_to      int           NULL CONSTRAINT fk_work_queues_provider REFERENCES care.providers (provider_id)
);
GO

-- Supporting indexes. claims (payer_code, submitted_on) and appointments (reason_code) are left
-- unindexed on purpose for the missing-index scenario.
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_appointments_patient' AND object_id = OBJECT_ID(N'care.appointments'))
    CREATE INDEX ix_appointments_patient ON care.appointments (patient_id, scheduled_start);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_appointments_provider' AND object_id = OBJECT_ID(N'care.appointments'))
    CREATE INDEX ix_appointments_provider ON care.appointments (provider_id, scheduled_start) INCLUDE (status);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_encounters_patient' AND object_id = OBJECT_ID(N'care.encounters'))
    CREATE INDEX ix_encounters_patient ON care.encounters (patient_id, started_at);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_claims_encounter' AND object_id = OBJECT_ID(N'care.claims'))
    CREATE INDEX ix_claims_encounter ON care.claims (encounter_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_orders_encounter' AND object_id = OBJECT_ID(N'care.orders'))
    CREATE INDEX ix_orders_encounter ON care.orders (encounter_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_payments_claim' AND object_id = OBJECT_ID(N'care.payments'))
    CREATE INDEX ix_payments_claim ON care.payments (claim_id);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_work_queues_queue' AND object_id = OBJECT_ID(N'care.work_queues'))
    CREATE INDEX ix_work_queues_queue ON care.work_queues (queue_name, status, priority);
GO

-- Demo control tables (schema demo) ---------------------------------------------------------------

IF OBJECT_ID(N'demo.scenario_runs', N'U') IS NULL
CREATE TABLE demo.scenario_runs
(
    run_id               varchar(64)   NOT NULL CONSTRAINT pk_scenario_runs PRIMARY KEY,
    scenario_id          varchar(64)   NOT NULL,
    target               varchar(8)    NOT NULL CONSTRAINT ck_scenario_runs_target CHECK (target IN ('T1', 'T2', 'T3')),
    status               varchar(20)   NOT NULL CONSTRAINT ck_scenario_runs_status CHECK (status IN ('Running', 'Completed', 'Cancelled', 'TimedOut', 'Failed')),
    started_at           datetime2(3)  NOT NULL,
    deadline_at          datetime2(3)  NOT NULL,
    stopped_at           datetime2(3)  NULL,
    max_duration_seconds int           NOT NULL CONSTRAINT ck_scenario_runs_duration CHECK (max_duration_seconds BETWEEN 1 AND 14400),
    concurrency          int           NOT NULL CONSTRAINT ck_scenario_runs_concurrency CHECK (concurrency BETWEEN 1 AND 64),
    intensity            tinyint       NOT NULL,
    expected_symptoms    nvarchar(400) NULL,
    requested_by         nvarchar(128) NULL,
    notes                nvarchar(400) NULL
);
GO

IF OBJECT_ID(N'demo.scenario_control', N'U') IS NULL
CREATE TABLE demo.scenario_control
(
    scenario_id          varchar(64)   NOT NULL CONSTRAINT pk_scenario_control PRIMARY KEY,
    stop_requested       bit           NOT NULL CONSTRAINT df_scenario_control_stop DEFAULT (0),
    max_duration_seconds int           NOT NULL CONSTRAINT ck_scenario_control_duration CHECK (max_duration_seconds BETWEEN 1 AND 14400),
    updated_at           datetime2(3)  NOT NULL
);
GO

IF OBJECT_ID(N'demo.activity_profile', N'U') IS NULL
CREATE TABLE demo.activity_profile
(
    profile_slot         tinyint       NOT NULL CONSTRAINT pk_activity_profile PRIMARY KEY CONSTRAINT ck_activity_profile_slot CHECK (profile_slot = 1),
    profile_name         varchar(64)   NOT NULL CONSTRAINT ck_activity_profile_name CHECK (profile_name IN ('off', 'baseline', 'business-day') OR profile_name LIKE 'incident:%'),
    set_at               datetime2(3)  NOT NULL,
    set_by               nvarchar(128) NOT NULL,
    expires_at           datetime2(3)  NULL
);
GO

IF OBJECT_ID(N'demo.seed_state', N'U') IS NULL
CREATE TABLE demo.seed_state
(
    seed_state_id        tinyint       NOT NULL CONSTRAINT pk_seed_state PRIMARY KEY CONSTRAINT ck_seed_state_id CHECK (seed_state_id = 1),
    seed                 int           NOT NULL,
    scale                int           NOT NULL,
    seed_version         int           NOT NULL,
    status               varchar(20)   NOT NULL CONSTRAINT ck_seed_state_status CHECK (status IN ('Running', 'Completed')),
    started_at           datetime2(3)  NOT NULL,
    completed_at         datetime2(3)  NULL
);
GO

-- The workload starts with no activity; start-demo.ps1 sets a profile (ADR 0010).
IF NOT EXISTS (SELECT 1 FROM demo.activity_profile WHERE profile_slot = 1)
    INSERT INTO demo.activity_profile (profile_slot, profile_name, set_at, set_by)
    VALUES (1, 'off', SYSUTCDATETIME(), N'schema');
GO

-- Deterministic helpers for the seed ----------------------------------------------------------------

-- Rows 1..@count without touching any system table.
CREATE OR ALTER FUNCTION demo.fn_numbers (@count int)
RETURNS TABLE
AS
RETURN
    WITH e1 (n) AS (SELECT 1 FROM (VALUES (1), (1), (1), (1), (1), (1), (1), (1), (1), (1)) AS v (n)),
         e2 (n) AS (SELECT 1 FROM e1 AS a CROSS JOIN e1 AS b),
         e4 (n) AS (SELECT 1 FROM e2 AS a CROSS JOIN e2 AS b),
         e8 (n) AS (SELECT 1 FROM e4 AS a CROSS JOIN e4 AS b)
    SELECT TOP (CASE WHEN @count > 0 THEN @count ELSE 0 END)
        n = ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
    FROM e8;
GO

-- Six independent pseudo-random values in [0, 2^32) per (seed, stream, row), from SHA-256. The same
-- inputs give the same values on every target and every run; nothing uses RAND() or NEWID().
CREATE OR ALTER FUNCTION demo.fn_rand (@seed int, @stream varchar(32), @n bigint)
RETURNS TABLE
AS
RETURN
    SELECT
        r1 = CAST(SUBSTRING(h.v, 1, 4) AS bigint),
        r2 = CAST(SUBSTRING(h.v, 5, 4) AS bigint),
        r3 = CAST(SUBSTRING(h.v, 9, 4) AS bigint),
        r4 = CAST(SUBSTRING(h.v, 13, 4) AS bigint),
        r5 = CAST(SUBSTRING(h.v, 17, 4) AS bigint),
        r6 = CAST(SUBSTRING(h.v, 21, 4) AS bigint)
    FROM (SELECT v = HASHBYTES('SHA2_256', CONCAT(@seed, ':', @stream, ':', @n))) AS h;
GO
