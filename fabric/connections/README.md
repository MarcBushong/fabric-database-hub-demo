# Fabric connections

The notebooks don't use stored Fabric connections, and none need to be created:

- **Fabric REST API:** a `pbi` token from `notebookutils.credentials.getToken` at run time.
- **Telemetry endpoint:** a `kusto` token from `notebookutils.credentials.getToken` at run time, with a printed-KQL fallback for the Azure Data Explorer web UI ([ADR 0014](../../docs/adr/0014-notebook-role-and-capacity.md)).
- **GitHub (optional, P9):** a fine-grained token read from Key Vault with `notebookutils.credentials.getSecret` for one request.
- **Optional Real-Time Dashboard:** created in the Database Hub UI (**Performance** > **Create SQL monitors from template**) or by hand with the data source `https://adx.centralus.arcdataservices.com/kusto/` and the database `ArcSqlTelemetry`. Each viewer sees only the resources their own Azure permissions allow ([query performance monitoring telemetry](https://learn.microsoft.com/fabric/database/hub/microsoft-sql-query-performance-monitoring-telemetry)).
