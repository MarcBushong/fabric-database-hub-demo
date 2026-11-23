using ContosoCare.Workload.Rca.Observer;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// What the RCA observer keeps of the text and names it reads (ADR 0031, Redaction and privacy; rca/README.md, Names):
/// literals become ?, addresses &lt;ip&gt;, statements keep 2,000 characters and details 1,000, the runner's redaction
/// runs, a value that still looks like a secret is dropped, and a workload session keeps only ContosoCare.Demo and an
/// opaque run token. Fake secrets are built at run time.
/// </summary>
public sealed class RcaNormalizerTests
{
    [Theory]
    [InlineData("UPDATE care.work_queues SET priority = CASE WHEN priority >= 5 THEN 5 ELSE priority + 1 END WHERE work_item_id = @parent", "UPDATE care.work_queues SET priority = CASE WHEN priority >= ? THEN ? ELSE priority + ? END WHERE work_item_id = @parent")]
    [InlineData("WAITFOR DELAY '00:00:01'", "WAITFOR DELAY ?")]
    [InlineData("SELECT @count = COUNT(*) FROM care.appointments WHERE provider_id = @id AND scheduled_start < DATEADD(day, 1, @day)", "SELECT @count = COUNT(*) FROM care.appointments WHERE provider_id = @id AND scheduled_start < DATEADD(day, ?, @day)")]
    [InlineData("SELECT * FROM t1 JOIN [table 2] AS x2 ON x2.id = t1.id WHERE t1.name = N'O''Brien' AND t1.code = 0x1F2E AND t1.v = 1.5e3", "SELECT * FROM t1 JOIN [table 2] AS x2 ON x2.id = t1.id WHERE t1.name = ? AND t1.code = ? AND t1.v = ?")]
    [InlineData("SELECT updates, waited_ms FROM demo.usp_x($1, $2, $3) WHERE note = E'it\\'s' AND body = $$ secret $$", "SELECT updates, waited_ms FROM demo.usp_x($1, $2, $3) WHERE note = ? AND body = ?")]
    [InlineData("SELECT \"Order 1\".id FROM \"Order 1\" WHERE id = 42 -- patient 1234\n/* id = 5 */ AND x = 7", "SELECT \"Order 1\".id FROM \"Order 1\" WHERE id = ? AND x = ?")]
    [InlineData("SELECT relid::regclass::text, $1::integer[] FROM pg_stat_user_tables WHERE seq_scan > 100", "SELECT relid::regclass::text, $1::integer[] FROM pg_stat_user_tables WHERE seq_scan > ?")]
    [InlineData("SELECT '2026-11-20T16:50:00Z', '9b7c1d2e-3f40-4a5b-8c6d-7e8f90a1b2c3', {d '2026-11-20'}", "SELECT ?, ?, {d ?}")]
    public void StatementsLoseTheirLiteralsAndKeepTheirShape(string text, string expected)
    {
        Assert.Equal(expected, TextNormalizer.Statement(text));
    }

    [Fact]
    public void WhiteSpaceRunsBecomeOneSpace()
    {
        Assert.Equal("SELECT a FROM b WHERE c = ?", TextNormalizer.Statement("SELECT a\r\n    FROM b\n\tWHERE c = 1   "));
    }

    [Fact]
    public void AnRpcInputBufferKeepsItsProcedureNumber()
    {
        Assert.Equal("demo.usp_chain_acquire;1", TextNormalizer.RpcName("demo.usp_chain_acquire;1"));
        Assert.Equal("demo.usp_chain_acquire;1", TextNormalizer.RpcName("demo.usp_chain_acquire;1 "));
    }

    [Theory]
    [InlineData("Transaction (Process ID 82) was deadlocked on lock resources with another process and has been chosen as the deadlock victim.", "Transaction (Process ID ?) was deadlocked on lock resources with another process and has been chosen as the deadlock victim.")]
    [InlineData("Conversion failed when converting the varchar value 'John Smith' to data type int.", "Conversion failed when converting the varchar value ? to data type int.")]
    [InlineData("Lock request time out period exceeded.", "Lock request time out period exceeded.")]
    [InlineData("Login failed for user 'contoso\\someone'. Reason: client 10.20.30.40 at 2026-11-20 16:53:01.", "Login failed for user ?. Reason: client <ip> at ?.")]
    public void MessagesLoseTheirValues(string text, string expected)
    {
        Assert.Equal(expected, TextNormalizer.Message(text));
    }

    [Theory]
    [InlineData("connected from 10.0.0.4 and 192.168.1.20", "connected from <ip> and <ip>")]
    [InlineData("peer fe80::1ff:fe23:4567:890a, then 2001:db8:85a3:0:0:8a2e:370:7334, then ::1", "peer <ip>, then <ip>, then <ip>")]
    [InlineData("at 17:11:15 UTC, version 15.0.4123.1", "at 17:11:15 UTC, version 15.0.4123.1")]
    public void AddressesBecomeIp(string text, string expected)
    {
        Assert.Equal(expected, TextNormalizer.Detail(text));
    }

    [Fact]
    public void StatementsKeep2000CharactersAndDetails1000()
    {
        var statement = TextNormalizer.Statement("SELECT " + string.Join(", ", Enumerable.Range(0, 1000).Select(i => "col_name")));
        var detail = TextNormalizer.Detail(new string('a', 400) + " " + new string('b', 400) + " " + new string('c', 400));

        Assert.InRange(statement!.Length, TextNormalizer.StatementLength - 3, TextNormalizer.StatementLength);
        Assert.EndsWith("...", statement, StringComparison.Ordinal);
        Assert.Equal(TextNormalizer.DetailLength, detail!.Length);
    }

    [Fact]
    public void TheRunnersRedactionRunsAndAValueThatStillLooksLikeASecretIsDropped()
    {
        var jwt = "eyJ" + RcaTestKit.FakeSecret(20) + "." + RcaTestKit.FakeSecret(30) + "." + RcaTestKit.FakeSecret(25);
        var redacted = TextNormalizer.Detail("the client sent " + jwt);
        Assert.NotNull(redacted);
        Assert.DoesNotContain(jwt, redacted, StringComparison.Ordinal);
        Assert.Contains("[REDACTED", redacted, StringComparison.Ordinal);

        // A long random token with no name the redaction knows, and a secret-named value, survive the redaction: dropped.
        Assert.Null(TextNormalizer.Message("authorization failed for " + RcaTestKit.FakeSecret()));
        Assert.Null(TextNormalizer.Detail("apikey: " + RcaTestKit.FakeSecret(12)));

        // A statement's secret-named column with a parameter is the statement's shape, not a secret.
        Assert.Equal("UPDATE demo.t SET token = @token, secret = ? WHERE id = ?", TextNormalizer.Statement("UPDATE demo.t SET token = @token, secret = '" + RcaTestKit.FakeSecret(16) + "' WHERE id = 3"));
    }

    [Fact]
    public void AWorkloadSessionKeepsOnlyItsProgramAndAnOpaqueRunToken()
    {
        var name = ApplicationNames.Reduce("ContosoCare.Demo/blocking-chain/20261120165200-t1-a1b2c3");

        Assert.Equal("ContosoCare.Demo", name.Program);
        Assert.Equal("de845fccbaba", name.RunToken);
        Assert.True(name.IsDemo);
        Assert.False(name.IsObserver);
    }

    [Theory]
    [InlineData("20261120165400-t1-c4d5e6", "ad502635d0e1")]
    [InlineData("20261120170200-t4-9b7c1d", "aefe56d6d1e0")]
    [InlineData("20261120171100-t4-5e8f21", "cb49b4c44561")]
    public void TheRunTokenIsTheContractsHash(string run, string token)
    {
        // rca/README.md, Names: the first 12 lowercase hex characters of SHA-256 over ContosoCare.RcaRunToken:<run>.
        Assert.Equal(token, ApplicationNames.RunToken(run));
    }

    [Theory]
    [InlineData("Microsoft SQL Server Management Studio - Query")]
    [InlineData("psql")]
    [InlineData("")]
    [InlineData(null)]
    [InlineData("ContosoCare.Demolition/x/y")]
    public void AnyOtherSessionsNameIsKeptOut(string? applicationName)
    {
        Assert.Equal(ReducedName.Other, ApplicationNames.Reduce(applicationName));
    }

    [Fact]
    public void TheObserversOwnSessionsAreRecognized()
    {
        var name = ApplicationNames.Reduce(ApplicationNames.Observer);

        Assert.True(name.IsObserver);
        Assert.Equal("ContosoCare.Demo/control/rca", ApplicationNames.Observer);
        Assert.Equal(Sql.SessionNames.ForControl("rca"), ApplicationNames.Observer);
        Assert.False(Sql.SessionNames.IsScenarioSession(ApplicationNames.Observer));
    }
}
