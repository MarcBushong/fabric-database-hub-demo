-- Missing-index remediation for the missing-index scenario (Phase 11). NEVER applied automatically: the runner
-- has no code path that runs this file. A person reviews the recommendation (from the Database Agent, the
-- missing-index DMVs, or Query Store), approves it, and runs this script in the ContosoCare database, for
-- example from SSMS or sqlcmd. It needs ALTER on care.claims and care.appointments (an administrator).
--
-- Undo it with: EXEC demo.usp_undo_missing_index_remediation;  (or the runner's reset --undo-remediation)
--
-- No ONLINE option, so it runs on SQL Server 2022 Standard as well as Azure SQL Database. On the demo's data
-- sizes each index builds in seconds.

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_claims_payer_submitted' AND object_id = OBJECT_ID(N'care.claims'))
    CREATE INDEX ix_claims_payer_submitted ON care.claims (payer_code, submitted_on) INCLUDE (claim_status, billed_amount);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'ix_appointments_reason' AND object_id = OBJECT_ID(N'care.appointments'))
    CREATE INDEX ix_appointments_reason ON care.appointments (reason_code, scheduled_start);
GO
