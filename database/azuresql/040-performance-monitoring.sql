-- T3 azuresql01: turns on Database Hub performance monitoring (preview) for ContosoCare. Run it in the user
-- database, never in master. Idempotent: it adds the database-level extended property, or updates it to 'true'.
-- This is Microsoft's documented script, unchanged:
-- https://learn.microsoft.com/fabric/database/hub/add-sql#enable-performance-monitoring-for-azure-sql-database
-- To stop collecting, Microsoft documents the same script with @value = N'false'.

IF EXISTS (
    SELECT 1
    FROM sys.extended_properties
    WHERE class = 0
        AND name = N'MS_EnablePerformanceMonitoringPreview'
)
BEGIN
    EXEC sys.sp_updateextendedproperty
        @name = N'MS_EnablePerformanceMonitoringPreview',
        @value = N'true';
END
ELSE
BEGIN
    EXEC sys.sp_addextendedproperty
        @name = N'MS_EnablePerformanceMonitoringPreview',
        @value = N'true';
END;
GO
