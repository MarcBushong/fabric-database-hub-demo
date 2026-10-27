using System.Text.Json;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Runs;
using Xunit;
using CommandLineDefinition = ContosoCare.Workload.Cli.CommandLine;

namespace ContosoCare.Workload.Tests;

/// <summary>Argument parsing and validation. Every case here fails or finishes before the runner would connect to SQL.</summary>
public sealed class CommandLineTests
{
    [Fact]
    public void RunNeedsATarget()
    {
        var errors = CliHarness.ParseErrors("run", "--scenario", "cpu-pressure");

        Assert.Contains(errors, e => e.Contains("--target", StringComparison.Ordinal));
    }

    [Fact]
    public void RunRefusesAnUnknownTarget()
    {
        Assert.NotEmpty(CliHarness.ParseErrors("run", "--target", "T9", "--scenario", "cpu-pressure"));
    }

    [Theory]
    [InlineData("t1")]
    [InlineData("T1")]
    public void TargetIsCaseInsensitive(string target)
    {
        Assert.Empty(CliHarness.ParseErrors("status", "--target", target));
    }

    [Fact]
    public void RunRefusesAnUnknownScenario()
    {
        var (exitCode, _, error) = CliHarness.Invoke("run", "--target", "T1", "--scenario", "no-such-scenario");

        Assert.Equal(1, exitCode);
        Assert.Contains("Unknown scenario", error, StringComparison.Ordinal);
    }

    [Fact]
    public void RunRefusesABadDuration()
    {
        var (exitCode, _, error) = CliHarness.Invoke("run", "--target", "T1", "--scenario", "cpu-pressure", "--duration", "soon");

        Assert.Equal(1, exitCode);
        Assert.Contains("--duration", error, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("noequals")]
    [InlineData("=value")]
    [InlineData("bad-name=1")]
    public void RunRefusesAMalformedParameter(string parameter)
    {
        var (exitCode, _, error) = CliHarness.Invoke("run", "--target", "T1", "--scenario", "cpu-pressure", "--param", parameter);

        Assert.Equal(1, exitCode);
        Assert.Contains("--param", error, StringComparison.Ordinal);
    }

    [Fact]
    public void RunRefusesAnUnknownParameter()
    {
        var (exitCode, _, error) = CliHarness.Invoke("run", "--target", "T1", "--scenario", "cpu-pressure", "--param", "nope=1");

        Assert.Equal(1, exitCode);
        Assert.Contains("has no parameter 'nope'", error, StringComparison.Ordinal);
    }

    [Fact]
    public void RunRefusesANotAfterWithoutAnOffset()
    {
        var (exitCode, _, error) = CliHarness.Invoke("run", "--target", "T1", "--scenario", "cpu-pressure", "--not-after", "2026-10-20T19:00:00");

        Assert.Equal(1, exitCode);
        Assert.Contains("--not-after", error, StringComparison.Ordinal);
    }

    [Fact]
    public void RunRefusesWhenTheShutdownIsTooClose()
    {
        var soon = DateTimeOffset.UtcNow.AddMinutes(1).ToString("yyyy-MM-ddTHH:mm:ssZ", System.Globalization.CultureInfo.InvariantCulture);
        var (exitCode, _, error) = CliHarness.Invoke("run", "--target", "T1", "--scenario", "cpu-pressure", "--not-after", soon);

        Assert.Equal(1, exitCode);
        Assert.Contains("Not enough time before --not-after", error, StringComparison.Ordinal);
    }

    [Fact]
    public void T3NeedsAServerName()
    {
        var (exitCode, _, error) = CliHarness.Invoke("status", "--target", "T3");

        Assert.Equal(1, exitCode);
        Assert.Contains("--server", error, StringComparison.Ordinal);
    }

    [Fact]
    public void T3RefusesSqlLogins()
    {
        var (exitCode, _, error) = CliHarness.Invoke("status", "--target", "T3", "--server", "example", "--sql-login-from-environment");

        Assert.Equal(1, exitCode);
        Assert.Contains("Microsoft Entra only", error, StringComparison.Ordinal);
    }

    [Fact]
    public void StopNeedsAScope()
    {
        var (exitCode, _, error) = CliHarness.Invoke("stop", "--target", "T1");

        Assert.Equal(1, exitCode);
        Assert.Contains("exactly one", error, StringComparison.Ordinal);
    }

    [Fact]
    public void StopTakesOnlyOneScope()
    {
        var (exitCode, _, error) = CliHarness.Invoke("stop", "--target", "T1", "--all", "--scenario", "cpu-pressure");

        Assert.Equal(1, exitCode);
        Assert.Contains("exactly one", error, StringComparison.Ordinal);
    }

    [Fact]
    public void StopRefusesAMalformedRunId()
    {
        var (exitCode, _, error) = CliHarness.Invoke("stop", "--target", "T1", "--run-id", "Robert'); DROP TABLE x;--");

        Assert.Equal(1, exitCode);
        Assert.Contains("--run-id", error, StringComparison.Ordinal);
    }

    [Fact]
    public void ProfileSetRefusesAnUnknownProfile()
    {
        var (exitCode, _, error) = CliHarness.Invoke("profile", "set", "--target", "T1", "--name", "weekend");

        Assert.Equal(1, exitCode);
        Assert.Contains("Unknown activity profile", error, StringComparison.Ordinal);
    }

    [Fact]
    public void ProfileSetRefusesRunOptionsForNonIncidentProfiles()
    {
        var (exitCode, _, error) = CliHarness.Invoke("profile", "set", "--target", "T1", "--name", "business-day", "--param", "variant=healthy");

        Assert.Equal(1, exitCode);
        Assert.Contains("incident:<scenario> only", error, StringComparison.Ordinal);
    }

    [Fact]
    public void ProfileSetValidatesIncidentOptions()
    {
        var (exitCode, _, error) = CliHarness.Invoke("profile", "set", "--target", "T1", "--name", "incident:cpu-pressure", "--param", "variant=fast");

        Assert.Equal(1, exitCode);
        Assert.Contains("must be one of", error, StringComparison.Ordinal);
    }

    [Fact]
    public void ScenariosListsTheCatalog()
    {
        var (exitCode, output, _) = CliHarness.Invoke("scenarios");

        Assert.Equal(0, exitCode);
        foreach (var scenario in ScenarioCatalog.Default.All)
        {
            Assert.Contains(scenario.Id, output, StringComparison.Ordinal);
        }
    }

    [Fact]
    public void ScenariosWritesJson()
    {
        var (exitCode, output, _) = CliHarness.Invoke("scenarios", "locking-blocking", "--json");

        Assert.Equal(0, exitCode);
        using var document = JsonDocument.Parse(output);
        Assert.Equal("locking-blocking", document.RootElement[0].GetProperty("id").GetString());
    }

    [Fact]
    public void ParametersParseAsNameValuePairs()
    {
        var parameters = CommandLineDefinition.ParseParameters(["variant=healthy", "scratchMb = 512"]);

        Assert.Equal("healthy", parameters["variant"]);
        Assert.Equal("512", parameters["scratchMb"]);
    }

    [Fact]
    public void ParametersRefuseDuplicates()
    {
        Assert.Throws<ScenarioRequestException>(() => CommandLineDefinition.ParseParameters(["variant=a", "variant=b"]));
    }

    [Theory]
    [InlineData("600", 600)]
    [InlineData("90s", 90)]
    [InlineData("10m", 600)]
    [InlineData("1h", 3600)]
    [InlineData("1.5m", 90)]
    [InlineData("00:10:00", 600)]
    public void DurationsParse(string text, int seconds)
    {
        Assert.True(DurationText.TryParse(text, out var duration));
        Assert.Equal(TimeSpan.FromSeconds(seconds), duration);
    }

    [Theory]
    [InlineData("")]
    [InlineData("-5")]
    [InlineData("0")]
    [InlineData("ten")]
    [InlineData("2d")]
    [InlineData("100000h")]
    public void BadDurationsDoNotParse(string text)
    {
        Assert.False(DurationText.TryParse(text, out _));
    }

    [Theory]
    [InlineData("2026-10-20T19:00:00-07:00", "2026-10-21T02:00:00Z")]
    [InlineData("2026-10-21T02:00:00Z", "2026-10-21T02:00:00Z")]
    [InlineData("2026-10-21T02:00:00+0000", "2026-10-21T02:00:00Z")]
    public void NotAfterNeedsAnOffset(string text, string utc)
    {
        Assert.True(DurationText.TryParseInstant(text, out var instant));
        Assert.Equal(DateTimeOffset.Parse(utc, System.Globalization.CultureInfo.InvariantCulture), instant);
    }

    [Theory]
    [InlineData("2026-10-21T02:00:00")]
    [InlineData("tomorrow")]
    public void NotAfterWithoutAnOffsetIsRefused(string text)
    {
        Assert.False(DurationText.TryParseInstant(text, out _));
    }

    [Fact]
    public void ExitCodesFollowTheStatusModel()
    {
        Assert.Equal(0, Cli.ExitCodes.FromStatuses(["Pass", "Warning", "Not selected", "Not supported"]));
        Assert.Equal(2, Cli.ExitCodes.FromStatuses(["Pass", "Manual action required"]));
        Assert.Equal(1, Cli.ExitCodes.FromStatuses(["Manual action required", "Fail"]));
    }

    [Fact]
    public void ResultRecordsMatchTheValidationSchema()
    {
        var record = CommandLineDefinition.ResultRecord(DemoTarget.T1, "reset", new Sql.CheckRecord("no-open-demo-transactions", "Pass", "No demo session has an open transaction."), "2026-10-20T18:00:00.000Z");
        var schema = Json.Schema.JsonSchema.FromText(File.ReadAllText(RepositoryPaths.Combine("scripts", "modules", "DbHubDemo", "schemas", "validation-result.schema.json")));
        using var document = JsonDocument.Parse(record.ToJsonString());

        var result = schema.Evaluate(document.RootElement);

        Assert.True(result.IsValid);
        Assert.Equal("WORKLOAD.T1.RESET.NO_OPEN_DEMO_TRANSACTIONS", record["checkId"]!.GetValue<string>());
    }
}
