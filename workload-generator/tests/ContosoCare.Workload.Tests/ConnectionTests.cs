using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Sql;
using Microsoft.Data.SqlClient;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>Application Name tagging, run IDs, and connection strings that never carry a secret.</summary>
public sealed class ConnectionTests
{
    private static readonly string[] SecretKeywords = ["password", "pwd", "accesstoken", "access token", "client secret", "sig="];

    [Fact]
    public void RunSessionsAreTaggedWithServiceAndRun()
    {
        Assert.Equal("ContosoCare.Demo/billing-worker/9f2c4e1a7b3d5f60", SessionNames.ForRun("billing-worker", "9f2c4e1a7b3d5f60"));
    }

    [Theory]
    [InlineData("control", "9f2c4e1a7b3d5f60")]
    [InlineData("billing/worker", "9f2c4e1a7b3d5f60")]
    [InlineData("Billing-worker", "9f2c4e1a7b3d5f60")]
    [InlineData("billing-worker-", "9f2c4e1a7b3d5f60")]
    [InlineData("billing--worker", "9f2c4e1a7b3d5f60")]
    [InlineData("a23456789012345678901234567890123", "9f2c4e1a7b3d5f60")]
    [InlineData("billing-worker", "9f2c%")]
    [InlineData("billing-worker", "9f2c_4e1a")]
    [InlineData("billing-worker", "")]
    public void ARunsNameNeverPassesForAControlSessionOrMatchesAnotherRun(string service, string runId)
    {
        // A 'control' service would hide the run's sessions from the session tools, and a LIKE wildcard in the run ID would
        // make their run match reach other runs' sessions.
        Assert.Throws<ArgumentException>(() => SessionNames.ForRun(service, runId));
    }

    [Fact]
    public void ControlSessionsAreTaggedSeparately()
    {
        var name = SessionNames.ForControl("reset");

        Assert.Equal("ContosoCare.Demo/control/reset", name);
        Assert.False(SessionNames.IsScenarioSession(name));
    }

    [Theory]
    [InlineData("ContosoCare.Demo/scheduling-service/9f2c4e1a7b3d5f60", true)]
    [InlineData("ContosoCare.Demo/cpu-pressure/20261020170000-t2-abcdef", true)]
    [InlineData("contosocare.demo/cpu-pressure/x", true)]
    [InlineData("ContosoCare.Demo/control/status", false)]
    [InlineData("SQLCMD", false)]
    [InlineData("Microsoft SQL Server Management Studio", false)]
    [InlineData("ContosoCare.Demonstration", false)]
    [InlineData(null, false)]
    public void OnlyScenarioSessionsMatchTheWatchdogFilter(string? applicationName, bool expected)
    {
        Assert.Equal(expected, SessionNames.IsScenarioSession(applicationName));
    }

    [Fact]
    public void RunIdsAreOpaqueLowercaseHexAndUnique()
    {
        var ids = Enumerable.Range(0, 50).Select(_ => SessionNames.NewRunId()).ToList();

        // 64 random bits and nothing else: no time, no target.
        Assert.All(ids, id => Assert.Matches("^[0-9a-f]{16}$", id));
        Assert.All(ids, id => Assert.True(SessionNames.IsValidRunId(id)));
        Assert.Equal(ids.Count, ids.Distinct(StringComparer.Ordinal).Count());
    }

    [Theory]
    [InlineData("9f2c4e1a7b3d5f60")]
    [InlineData("20261120170200-t1-9b7c1d")]
    public void RunIdsOfThisAndOlderRunnersAreValid(string runId)
    {
        // An older runner's run IDs (time, target, random hex) stay valid: its runs are stopped, reset, and watched by run ID.
        Assert.True(SessionNames.IsValidRunId(runId));
    }

    [Theory]
    [InlineData("")]
    [InlineData("-leading-hyphen")]
    [InlineData("UPPER")]
    [InlineData("has space")]
    [InlineData("x'; KILL 1;--")]
    [InlineData("0123456789012345678901234567890123456789x")]
    public void MalformedRunIdsAreRefused(string runId)
    {
        Assert.False(SessionNames.IsValidRunId(runId));
    }

    [Fact]
    public void EveryScenarioFitsTheApplicationNameLimit()
    {
        var runId = SessionNames.NewRunId();

        foreach (var scenario in ScenarioCatalog.Default.All)
        {
            Assert.True(SessionNames.ForRun(scenario.Service, runId).Length <= 128, scenario.Id);
        }
    }

    [Fact]
    public void TheWatchdogMatchesARunsSessionsByTheRunAlone()
    {
        // ContosoCare.Demo/<service>/<run>, and an older runner's ContosoCare.Demo/<scenario>/<run>: the past-deadline kill
        // finds a session's run by the run ID at the end of its name, whatever precedes it (ADR 0031, decision 6).
        var sql = SqlScriptTests.ProcedureText("demo.usp_kill_demo_sessions");
        var postgres = Postgres.PgScripts.Read("110-demo-control.sql");
        postgres = postgres[postgres.IndexOf("CREATE OR REPLACE FUNCTION demo.usp_kill_demo_sessions", StringComparison.Ordinal)..];
        postgres = postgres[..postgres.IndexOf("$$;", StringComparison.Ordinal)];

        Assert.Contains("WHERE s.program_name LIKE CONCAT('ContosoCare.Demo/%/', r.run_id)", sql, StringComparison.Ordinal);
        Assert.Contains("WHERE s.application_name LIKE 'ContosoCare.Demo/%/' || r.run_id", postgres, StringComparison.Ordinal);
        Assert.DoesNotContain("scenario_id", sql, StringComparison.Ordinal);
        Assert.DoesNotContain("scenario_id", postgres, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("T1")]
    [InlineData("T2")]
    public void LocalTargetsUseWindowsAuthentication(string target)
    {
        var endpoint = TargetEndpoint.Create(Enum.Parse<DemoTarget>(target), null, sqlLoginFromEnvironment: false, managedIdentityClientId: null);
        var builder = new SqlConnectionStringBuilder(ConnectionStrings.Build(endpoint, SessionNames.ForControl("test"), 30));

        Assert.Equal(".", builder.DataSource);
        Assert.True(builder.IntegratedSecurity);
        Assert.Equal(SqlAuthenticationMethod.NotSpecified, builder.Authentication);
        Assert.True(endpoint.IsLocal);
    }

    [Fact]
    public void T3UsesTheManagedIdentityWithStrictCertificateChecks()
    {
        var endpoint = TargetEndpoint.Create(DemoTarget.T3, "sql-contoso-demo", sqlLoginFromEnvironment: false, managedIdentityClientId: null);
        var builder = new SqlConnectionStringBuilder(ConnectionStrings.Build(endpoint, SessionNames.ForControl("test"), 60));

        Assert.Equal("sql-contoso-demo.database.windows.net", builder.DataSource);
        Assert.Equal(SqlAuthenticationMethod.ActiveDirectoryManagedIdentity, builder.Authentication);
        Assert.False(builder.IntegratedSecurity);
        Assert.False(builder.TrustServerCertificate);
        Assert.Equal(SqlConnectionEncryptOption.Mandatory, builder.Encrypt);
        Assert.Empty(builder.UserID);
        Assert.False(endpoint.IsLocal);
    }

    [Fact]
    public void T3CanUseAUserAssignedIdentityByClientId()
    {
        var clientId = Guid.NewGuid().ToString();
        var endpoint = TargetEndpoint.Create(DemoTarget.T3, "sql-contoso-demo.database.windows.net", sqlLoginFromEnvironment: false, managedIdentityClientId: clientId);
        var builder = new SqlConnectionStringBuilder(ConnectionStrings.Build(endpoint, SessionNames.ForControl("test"), 60));

        Assert.Equal(clientId, builder.UserID);
        Assert.Empty(builder.Password);
    }

    [Fact]
    public void T3RefusesAClientIdThatIsNotAGuid()
    {
        Assert.Throws<ScenarioRequestException>(() => TargetEndpoint.Create(DemoTarget.T3, "sql-contoso-demo", false, "not-a-guid"));
    }

    [Theory]
    [InlineData("T1", null, false)]
    [InlineData("T2", "(localdb)\\demo", false)]
    [InlineData("T3", "sql-contoso-demo", false)]
    [InlineData("T2", "localhost,14333", true)]
    public void EveryConnectionIsBoundedToContosoCareWithoutSecrets(string target, string? server, bool sqlLogin)
    {
        var endpoint = TargetEndpoint.Create(Enum.Parse<DemoTarget>(target), server, sqlLogin, null);
        var connectionString = ConnectionStrings.Build(endpoint, SessionNames.ForRun("scheduling-service", "9f2c4e1a7b3d5f60"), 30);
        var builder = new SqlConnectionStringBuilder(connectionString);

        Assert.Equal("ContosoCare", builder.InitialCatalog);
        Assert.Equal("ContosoCare.Demo/scheduling-service/9f2c4e1a7b3d5f60", builder.ApplicationName);
        Assert.False(builder.Pooling);
        Assert.False(builder.MultipleActiveResultSets);
        Assert.Empty(builder.Password);
        foreach (var keyword in SecretKeywords)
        {
            Assert.DoesNotContain(keyword, connectionString, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public void TheSqlLoginPasswordNeverEntersTheConnectionString()
    {
        var fakePassword = "Fake-" + Guid.NewGuid().ToString("N");
        Environment.SetEnvironmentVariable(TargetEndpoint.UserVariable, "sa");
        Environment.SetEnvironmentVariable(TargetEndpoint.PasswordVariable, fakePassword);
        try
        {
            var endpoint = TargetEndpoint.Create(DemoTarget.T2, "localhost,14333", sqlLoginFromEnvironment: true, managedIdentityClientId: null);
            var connectionString = ConnectionStrings.Build(endpoint, SessionNames.ForControl("test"), 30);

            Assert.DoesNotContain(fakePassword, connectionString, StringComparison.Ordinal);
            Assert.DoesNotContain(fakePassword, endpoint.Describe(), StringComparison.Ordinal);
            Assert.False(endpoint.IsLocal);
        }
        finally
        {
            Environment.SetEnvironmentVariable(TargetEndpoint.UserVariable, null);
            Environment.SetEnvironmentVariable(TargetEndpoint.PasswordVariable, null);
        }
    }

    [Fact]
    public void SqlLoginsNeedAnExplicitServer()
    {
        Assert.Throws<ScenarioRequestException>(() => TargetEndpoint.Create(DemoTarget.T2, null, sqlLoginFromEnvironment: true, managedIdentityClientId: null));
    }

    [Theory]
    [InlineData(".", true)]
    [InlineData("(local)", true)]
    [InlineData("localhost", true)]
    [InlineData("tcp:localhost,1433", true)]
    [InlineData("(localdb)\\MSSQLLocalDB", true)]
    [InlineData("sqlvm01.contoso.example", false)]
    public void LocalServersAreRecognized(string server, bool local)
    {
        Assert.Equal(local, TargetEndpoint.Create(DemoTarget.T1, server, false, null).IsLocal);
    }

    [Fact]
    public void TransientErrorsIncludeServerlessResume()
    {
        // 40613: "Database ... is not currently available", returned while a paused serverless database resumes.
        var numbers = typeof(SqlConnectionOpener)
            .GetField("TransientErrors", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)!
            .GetValue(null) as HashSet<int>;

        Assert.NotNull(numbers);
        Assert.Contains(40613, numbers);
        Assert.Contains(40197, numbers);
        Assert.Contains(40501, numbers);
        Assert.DoesNotContain(18456, numbers);
    }

    [Fact]
    public void AnOpenQueuedBehindOtherOpensIsRetried()
    {
        // SqlClient runs only as many non-pooled opens at once as there are processors; one that waits past its
        // connect timeout throws this before anything was opened (capacity-max on T2's 2-vCPU guest, Phase 25d live).
        var queued = new TimeoutException("Timeout attempting to open the connection. The time period elapsed prior to attempting to open the connection has been exceeded. This may have occurred because of too many simultaneous non-pooled connection attempts.");

        Assert.True(SqlConnectionOpener.IsRetryableOpenFailure(queued));
        Assert.False(SqlConnectionOpener.IsRetryableOpenFailure(new InvalidOperationException("The ConnectionString property has not been initialized.")));
        Assert.False(SqlConnectionOpener.IsRetryableOpenFailure(new ArgumentException("Keyword not supported.")));
    }
}
