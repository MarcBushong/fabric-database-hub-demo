using ContosoCare.Workload.Diagnostics;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>Redaction and structured logging. Fake secrets are built at run time so secret scanners never see a literal.</summary>
public sealed class LoggingTests
{
    private static string FakeJwt() =>
        "eyJ" + Convert.ToBase64String(Guid.NewGuid().ToByteArray()).TrimEnd('=').Replace('+', 'a').Replace('/', 'b')
        + "." + "eyJ" + Guid.NewGuid().ToString("N") + "." + Guid.NewGuid().ToString("N");

    [Fact]
    public void JwtsAreRedacted()
    {
        var token = FakeJwt();

        var redacted = Redactor.Redact("token " + token + " end");

        Assert.DoesNotContain(token, redacted, StringComparison.Ordinal);
        Assert.Contains("[REDACTED:jwt]", redacted, StringComparison.Ordinal);
    }

    [Fact]
    public void BearerTokensAreRedacted()
    {
        var token = Guid.NewGuid().ToString("N") + Guid.NewGuid().ToString("N");

        Assert.DoesNotContain(token, Redactor.Redact("Authorization: Bearer " + token), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("Password")]
    [InlineData("pwd")]
    [InlineData("Access Token")]
    public void ConnectionStringSecretsAreRedacted(string keyword)
    {
        var secret = "Fake" + Guid.NewGuid().ToString("N");

        var redacted = Redactor.Redact($"Server=x;{keyword}={secret};Database=ContosoCare");

        Assert.DoesNotContain(secret, redacted, StringComparison.Ordinal);
        Assert.Contains("Database=ContosoCare", redacted, StringComparison.Ordinal);
    }

    [Fact]
    public void SecretJsonPropertiesAreRedacted()
    {
        var secret = Guid.NewGuid().ToString("N");

        var redacted = Redactor.Redact("{\"clientSecret\": \"" + secret + "\", \"name\": \"ok\"}");

        Assert.DoesNotContain(secret, redacted, StringComparison.Ordinal);
        Assert.Contains("\"name\": \"ok\"", redacted, StringComparison.Ordinal);
    }

    [Fact]
    public void SasSignaturesAndAccountKeysAreRedacted()
    {
        var signature = Guid.NewGuid().ToString("N");
        var key = Convert.ToBase64String(Guid.NewGuid().ToByteArray());

        var redacted = Redactor.Redact($"https://x.blob.core.windows.net/c?sv=2024&sig={signature} AccountKey={key}");

        Assert.DoesNotContain(signature, redacted, StringComparison.Ordinal);
        Assert.DoesNotContain(key, redacted, StringComparison.Ordinal);
    }

    [Fact]
    public void ProductKeysAndGitHubTokensAreRedacted()
    {
        var productKey = string.Join("-", Enumerable.Range(0, 5).Select(i => Guid.NewGuid().ToString("N")[..5].ToUpperInvariant()));
        var gitHubToken = "ghp_" + Guid.NewGuid().ToString("N");

        var redacted = Redactor.Redact($"key {productKey} token {gitHubToken}");

        Assert.DoesNotContain(productKey, redacted, StringComparison.Ordinal);
        Assert.DoesNotContain(gitHubToken, redacted, StringComparison.Ordinal);
    }

    [Fact]
    public void OrdinaryTextIsUntouched()
    {
        const string text = "Run 20261020170000-t1-abcdef on T1: 3 contender(s) blocked by session 61 for 120 s.";

        Assert.Equal(text, Redactor.Redact(text));
    }

    [Fact]
    public void TextLinesCarryEventAndFieldsAndAreRedacted()
    {
        var secret = "Fake" + Guid.NewGuid().ToString("N");
        using var writer = new StringWriter();
        using (var log = new RunnerLog(writer))
        {
            log.Info("run.started", "Started with Password=" + secret, ("runId", "r-1"), ("note", "two words"));
        }

        var line = writer.ToString().Trim();

        Assert.Matches(@"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z INF run\.started ", line);
        Assert.Contains("runId=r-1", line, StringComparison.Ordinal);
        Assert.Contains("note=\"two words\"", line, StringComparison.Ordinal);
        Assert.DoesNotContain(secret, line, StringComparison.Ordinal);
    }

    [Fact]
    public void JsonLinesAreValidAndRedacted()
    {
        var token = FakeJwt();
        using var writer = new StringWriter();
        using (var log = new RunnerLog(writer, LogFormat.Json))
        {
            log.Warn("sql.retry", "Retrying.", ("detail", "Bearer " + token), ("attempt", 2));
        }

        using var document = System.Text.Json.JsonDocument.Parse(writer.ToString());

        Assert.Equal("Warning", document.RootElement.GetProperty("level").GetString());
        Assert.Equal("sql.retry", document.RootElement.GetProperty("event").GetString());
        Assert.Equal("2", document.RootElement.GetProperty("attempt").GetString());
        Assert.DoesNotContain(token, writer.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void DebugEventsAreHiddenByDefault()
    {
        using var writer = new StringWriter();
        using (var log = new RunnerLog(writer))
        {
            log.Debug("detail", "hidden");
        }

        Assert.Empty(writer.ToString());
    }
}
