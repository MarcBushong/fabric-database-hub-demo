-- ContosoCare Operations schema for T4, Azure Database for PostgreSQL flexible server (Phase 24, ADR 0019).
-- The same synthetic clinic business as database/common/010-schema.sql, in PostgreSQL: every row is synthetic,
-- with no real people, PHI, or PII. Idempotent: safe to run again. Run it in the contosocare database as an
-- administrator (the P6 group's role); 'ContosoCare.Workload setup --target T4' applies it.
-- Batches are separated by lines that hold only '-- @batch'.

CREATE SCHEMA IF NOT EXISTS care;
-- @batch
CREATE SCHEMA IF NOT EXISTS demo;
-- @batch

-- Business tables (schema care) ------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS care.facilities
(
    facility_id     integer      NOT NULL CONSTRAINT pk_facilities PRIMARY KEY,
    facility_code   varchar(16)  NOT NULL CONSTRAINT uq_facilities_code UNIQUE,
    facility_name   varchar(100) NOT NULL,
    facility_type   varchar(20)  NOT NULL CONSTRAINT ck_facilities_type CHECK (facility_type IN ('Hospital', 'Clinic', 'Lab', 'Pharmacy')),
    region          varchar(20)  NOT NULL,
    bed_count       integer      NOT NULL DEFAULT 0,
    opened_on       date         NOT NULL,
    is_active       boolean      NOT NULL DEFAULT true
);
-- @batch
CREATE TABLE IF NOT EXISTS care.providers
(
    provider_id     integer      NOT NULL CONSTRAINT pk_providers PRIMARY KEY,
    provider_code   varchar(16)  NOT NULL CONSTRAINT uq_providers_code UNIQUE,
    display_name    varchar(100) NOT NULL,
    specialty       varchar(40)  NOT NULL,
    facility_id     integer      NOT NULL CONSTRAINT fk_providers_facility REFERENCES care.facilities (facility_id),
    hired_on        date         NOT NULL,
    is_active       boolean      NOT NULL DEFAULT true
);
-- @batch
CREATE TABLE IF NOT EXISTS care.patients
(
    patient_id          integer      NOT NULL CONSTRAINT pk_patients PRIMARY KEY,
    mrn                 varchar(20)  NOT NULL CONSTRAINT uq_patients_mrn UNIQUE,
    given_name          varchar(50)  NOT NULL,
    family_name         varchar(50)  NOT NULL,
    birth_date          date         NOT NULL,
    sex                 char(1)      NOT NULL CONSTRAINT ck_patients_sex CHECK (sex IN ('F', 'M', 'X')),
    postal_code         varchar(10)  NOT NULL,
    primary_facility_id integer      NOT NULL CONSTRAINT fk_patients_facility REFERENCES care.facilities (facility_id),
    created_at          timestamptz  NOT NULL,
    is_synthetic        boolean      NOT NULL DEFAULT true CONSTRAINT ck_patients_synthetic CHECK (is_synthetic)
);
-- @batch
CREATE TABLE IF NOT EXISTS care.appointments
(
    appointment_id   bigint       NOT NULL CONSTRAINT pk_appointments PRIMARY KEY,
    patient_id       integer      NOT NULL CONSTRAINT fk_appointments_patient REFERENCES care.patients (patient_id),
    provider_id      integer      NOT NULL CONSTRAINT fk_appointments_provider REFERENCES care.providers (provider_id),
    facility_id      integer      NOT NULL CONSTRAINT fk_appointments_facility REFERENCES care.facilities (facility_id),
    scheduled_start  timestamptz  NOT NULL,
    duration_minutes smallint     NOT NULL,
    status           varchar(20)  NOT NULL CONSTRAINT ck_appointments_status CHECK (status IN ('Scheduled', 'CheckedIn', 'Completed', 'Cancelled', 'NoShow')),
    reason_code      varchar(20)  NOT NULL,
    created_at       timestamptz  NOT NULL
);
-- @batch
CREATE TABLE IF NOT EXISTS care.encounters
(
    encounter_id     bigint       NOT NULL CONSTRAINT pk_encounters PRIMARY KEY,
    appointment_id   bigint       NULL CONSTRAINT fk_encounters_appointment REFERENCES care.appointments (appointment_id),
    patient_id       integer      NOT NULL CONSTRAINT fk_encounters_patient REFERENCES care.patients (patient_id),
    provider_id      integer      NOT NULL CONSTRAINT fk_encounters_provider REFERENCES care.providers (provider_id),
    facility_id      integer      NOT NULL CONSTRAINT fk_encounters_facility REFERENCES care.facilities (facility_id),
    encounter_type   varchar(20)  NOT NULL,
    started_at       timestamptz  NOT NULL,
    ended_at         timestamptz  NULL,
    acuity           smallint     NOT NULL,
    diagnosis_code   varchar(12)  NOT NULL
);
-- @batch
CREATE TABLE IF NOT EXISTS care.claims
(
    claim_id         bigint         NOT NULL CONSTRAINT pk_claims PRIMARY KEY,
    encounter_id     bigint         NOT NULL CONSTRAINT fk_claims_encounter REFERENCES care.encounters (encounter_id),
    patient_id       integer        NOT NULL CONSTRAINT fk_claims_patient REFERENCES care.patients (patient_id),
    payer_code       varchar(20)    NOT NULL,
    claim_status     varchar(20)    NOT NULL CONSTRAINT ck_claims_status CHECK (claim_status IN ('Draft', 'Submitted', 'Denied', 'Paid', 'Appealed')),
    submitted_on     date           NOT NULL,
    billed_amount    numeric(12, 2) NOT NULL,
    paid_amount      numeric(12, 2) NOT NULL
);
-- @batch
CREATE TABLE IF NOT EXISTS care.inventory
(
    inventory_id     integer       NOT NULL CONSTRAINT pk_inventory PRIMARY KEY,
    facility_id      integer       NOT NULL CONSTRAINT fk_inventory_facility REFERENCES care.facilities (facility_id),
    item_sku         varchar(20)   NOT NULL,
    item_name        varchar(100)  NOT NULL,
    quantity_on_hand integer       NOT NULL,
    reorder_level    integer       NOT NULL,
    updated_at       timestamptz   NOT NULL,
    CONSTRAINT uq_inventory_facility_sku UNIQUE (facility_id, item_sku)
);
-- @batch
-- Rows a scenario writes carry its run_id, so reset and the cleanup can remove exactly them.
CREATE TABLE IF NOT EXISTS care.audit_events
(
    audit_event_id   bigint GENERATED ALWAYS AS IDENTITY CONSTRAINT pk_audit_events PRIMARY KEY,
    event_time       timestamptz  NOT NULL,
    actor            varchar(64)  NOT NULL,
    entity_type      varchar(32)  NOT NULL,
    entity_id        bigint       NOT NULL,
    action           varchar(20)  NOT NULL,
    run_id           varchar(64)  NULL
);
-- @batch
CREATE TABLE IF NOT EXISTS care.work_queues
(
    work_item_id     bigint       NOT NULL CONSTRAINT pk_work_queues PRIMARY KEY,
    queue_name       varchar(32)  NOT NULL,
    facility_id      integer      NOT NULL CONSTRAINT fk_work_queues_facility REFERENCES care.facilities (facility_id),
    patient_id       integer      NULL CONSTRAINT fk_work_queues_patient REFERENCES care.patients (patient_id),
    claim_id         bigint       NULL CONSTRAINT fk_work_queues_claim REFERENCES care.claims (claim_id),
    priority         smallint     NOT NULL,
    status           varchar(20)  NOT NULL CONSTRAINT ck_work_queues_status CHECK (status IN ('Open', 'InProgress', 'Done')),
    created_at       timestamptz  NOT NULL,
    due_at           timestamptz  NOT NULL,
    last_touched_at  timestamptz  NULL,
    touched_by_run   varchar(64)  NULL
);
-- @batch

-- Supporting indexes ----------------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS ix_appointments_patient ON care.appointments (patient_id, scheduled_start);
-- @batch
CREATE INDEX IF NOT EXISTS ix_appointments_provider ON care.appointments (provider_id, scheduled_start) INCLUDE (status);
-- @batch
CREATE INDEX IF NOT EXISTS ix_encounters_patient ON care.encounters (patient_id, started_at);
-- @batch
CREATE INDEX IF NOT EXISTS ix_claims_patient ON care.claims (patient_id, submitted_on);
-- @batch
CREATE INDEX IF NOT EXISTS ix_claims_encounter ON care.claims (encounter_id);
-- @batch
CREATE INDEX IF NOT EXISTS ix_work_queues_queue ON care.work_queues (queue_name, status, priority);
-- @batch
CREATE INDEX IF NOT EXISTS ix_audit_events_run ON care.audit_events (run_id) WHERE run_id IS NOT NULL;
-- @batch

-- Seed bookkeeping (schema demo) ------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS demo.seed_state
(
    seed_state_id    smallint     NOT NULL CONSTRAINT pk_seed_state PRIMARY KEY CONSTRAINT ck_seed_state_id CHECK (seed_state_id = 1),
    seed             integer      NOT NULL,
    scale            integer      NOT NULL,
    seed_version     integer      NOT NULL,
    status           varchar(20)  NOT NULL CONSTRAINT ck_seed_state_status CHECK (status IN ('Running', 'Completed')),
    started_at       timestamptz  NOT NULL,
    completed_at     timestamptz  NULL
);
-- @batch

-- Pseudo-random values in [0, 2^32) per (seed, stream, row, slot 0 to 3), from MD5. The same inputs give the
-- same values on every run; nothing uses random().
CREATE OR REPLACE FUNCTION demo.fn_rand(p_seed integer, p_stream text, p_n bigint, p_slot integer)
RETURNS bigint
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT ('x' || substr(md5(p_seed::text || ':' || p_stream || ':' || p_n::text), 1 + 8 * (p_slot % 4), 8))::bit(32)::bigint;
$$;
