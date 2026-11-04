using System.Diagnostics;
using System.Text.Json.Nodes;
using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;
using ContosoCare.Workload.Profiles;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>
/// The showcase's supersede guard (ADR 0020, newest wins): request stamps, the profile file's compare-and-set under its
/// lock, and the command line's stamped profile set, stop, and reset; and the profile host's process priority. Nothing
/// here connects to a database.
/// </summary>
public sealed class ProfileStoreTests : IDisposable
{
    private static readonly DateTimeOffset Older = new(2026, 11, 3, 18, 0, 0, 123, TimeSpan.Zero);
    private static readonly DateTimeOffset Newer = Older.AddSeconds(5);
    private readonly string folder = Path.Combine(AppContext.BaseDirectory, "profile-store-" + Guid.NewGuid().ToString("N"));

    private string FilePath => Path.Combine(folder, "activity-t4.json");

    public void Dispose()
    {
        if (Directory.Exists(folder))
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void StampsCompareByTimeThenByRequestIdAtMillisecondPrecision()
    {
        var stamp = new ProfileRequestStamp(Older.AddTicks(4321), "job-b");

        Assert.Equal(Older, stamp.RequestedAt);
        Assert.True(stamp.CompareTo(null, null) > 0);
        Assert.True(stamp.CompareTo(Older.AddMilliseconds(-1), "zzz") > 0);
        Assert.True(stamp.CompareTo(Older.AddMilliseconds(1), "aaa") < 0);
        Assert.True(stamp.CompareTo(Older, "job-a") > 0);
        Assert.True(stamp.CompareTo(Older, "job-c") < 0);
        Assert.Equal(0, stamp.CompareTo(Older, "job-b"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("has space")]
    [InlineData("semi;colon")]
    [InlineData("0123456789012345678901234567890123456789012345678901234567890123456789")]
    public void BadRequestIdsAreRefused(string id)
    {
        Assert.Throws<ScenarioRequestException>(() => new ProfileRequestStamp(Older, id));
    }

    [Fact]
    public async Task ANewerRequestReplacesAnOlderOneButNeverTheOtherWayAround()
    {
        var store = new FileProfileStore(FilePath);
        var token = TestContext.Current.CancellationToken;

        Assert.True((await store.SetAsync("baseline", "job", null, null, new ProfileRequestStamp(Older, "job-1"), token)).Applied);
        Assert.True((await store.SetAsync("showcase", "job", null, new ProfileParameters { Tier = "GeneralPurpose" }, new ProfileRequestStamp(Newer, "job-2"), token)).Applied);
        var late = await store.SetAsync("off", "job", null, null, new ProfileRequestStamp(Older, "job-1"), token);

        Assert.False(late.Applied);
        Assert.Equal("job-2", late.NewerRequestId);
        var state = await store.GetAsync(token);
        Assert.Equal("showcase", state.Name);
        Assert.Equal("GeneralPurpose", state.Parameters?.Tier);
        Assert.Equal(Newer, state.RequestedAt);
        Assert.Equal("job-2", state.RequestId);
    }

    [Fact]
    public async Task TheSameRequestAgainKeepsTheProfileAndItsCycle()
    {
        var store = new FileProfileStore(FilePath);
        var token = TestContext.Current.CancellationToken;
        var stamp = new ProfileRequestStamp(Newer, "job-2");
        await store.SetAsync("showcase", "job", null, null, stamp, token);
        var first = await store.GetAsync(token);
        await Task.Delay(30, token);

        Assert.True((await store.SetAsync("showcase", "job", null, null, stamp, token)).Applied);

        Assert.Equal(first.SetAt, (await store.GetAsync(token)).SetAt);
    }

    [Fact]
    public async Task AnUnstampedSetAlwaysWritesAndKeepsTheStoredStamp()
    {
        var store = new FileProfileStore(FilePath);
        var token = TestContext.Current.CancellationToken;
        await store.SetAsync("showcase", "job", null, null, new ProfileRequestStamp(Newer, "job-2"), token);

        Assert.True((await store.SetAsync("baseline", "deploy", null, null, null, token)).Applied);

        var state = await store.GetAsync(token);
        Assert.Equal("baseline", state.Name);
        Assert.Equal("job-2", state.RequestId);
        Assert.False((await store.SetAsync("off", "job", null, null, new ProfileRequestStamp(Older, "job-1"), token)).Applied);
    }

    [Fact]
    public async Task ConcurrentStampedSetsLeaveTheNewestRequest()
    {
        var token = TestContext.Current.CancellationToken;
        var stamps = Enumerable.Range(0, 12).Select(i => new ProfileRequestStamp(Older.AddSeconds(i), $"job-{i:00}")).OrderBy(_ => Random.Shared.Next()).ToList();

        await Task.WhenAll(stamps.Select(stamp => Task.Run(() => new FileProfileStore(FilePath).SetAsync("showcase", "job", null, null, stamp, token), token)));

        var state = await new FileProfileStore(FilePath).GetAsync(token);
        Assert.Equal("job-11", state.RequestId);
        Assert.Equal(Older.AddSeconds(11), state.RequestedAt);
    }

    [Fact]
    public async Task AWriterWaitsForTheLockAndGivesUpAfterItsTimeout()
    {
        var token = TestContext.Current.CancellationToken;
        Directory.CreateDirectory(folder);
        var store = new FileProfileStore(FilePath, TimeSpan.FromMilliseconds(300));
        await using (new FileStream(store.LockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
        {
            await Assert.ThrowsAnyAsync<IOException>(() => store.SetAsync("off", "test", null, null, null, token));
        }

        var held = new FileStream(store.LockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var release = Task.Run(
            async () =>
            {
                await Task.Delay(100, token);
                await held.DisposeAsync();
            },
            token);
        Assert.True((await new FileProfileStore(FilePath, TimeSpan.FromSeconds(5)).SetAsync("baseline", "test", null, null, null, token)).Applied);
        await release;
        Assert.Equal("baseline", (await store.GetAsync(token)).Name);
    }

    [Fact]
    public void ProfileSetStampsT4sFileAndALaterOlderRequestChangesNothing()
    {
        Directory.CreateDirectory(folder);
        var (exitCode, output, error) = CliHarness.Invoke("profile", "set", "--target", "T4", "--name", "showcase", "--tier", "GeneralPurpose", "--profile-file", FilePath, "--if-newer", "2026-11-03T18:00:05.000Z", "--request-id", "job-2", "--requested-by", "test");

        Assert.True(exitCode == 0, error);
        Assert.Contains("profile set to showcase", output, StringComparison.Ordinal);
        var file = JsonNode.Parse(File.ReadAllText(FilePath))!;
        Assert.Equal("showcase", file["profile"]!.GetValue<string>());
        Assert.Equal("GeneralPurpose", file["parameters"]!["tier"]!.GetValue<string>());
        Assert.Equal("job-2", file["requestId"]!.GetValue<string>());

        (exitCode, output, _) = CliHarness.Invoke("profile", "set", "--target", "T4", "--name", "off", "--profile-file", FilePath, "--if-newer", "2026-11-03T18:00:00Z", "--request-id", "job-1");
        Assert.Equal(0, exitCode);
        Assert.Contains("Not applied: a newer request (job-2)", output, StringComparison.Ordinal);

        // An older stamped stop or reset stops nothing, and never connects to T4.
        (exitCode, output, _) = CliHarness.Invoke("stop", "--target", "T4", "--all", "--server", "pgflex01-abc123.postgres.database.azure.com", "--profile-file", FilePath, "--if-newer", "2026-11-03T18:00:00Z", "--request-id", "job-1");
        Assert.Equal(0, exitCode);
        Assert.Contains("Not applied", output, StringComparison.Ordinal);
        (exitCode, output, _) = CliHarness.Invoke("reset", "--target", "T4", "--server", "pgflex01-abc123.postgres.database.azure.com", "--profile-file", FilePath, "--if-newer", "2026-11-03T18:00:01Z", "--request-id", "job-1");
        Assert.Equal(0, exitCode);
        Assert.Contains("Not applied", output, StringComparison.Ordinal);
        Assert.Equal("showcase", JsonNode.Parse(File.ReadAllText(FilePath))!["profile"]!.GetValue<string>());
    }

    [Theory]
    [InlineData("--name", "baseline", "--tier", "Burstable")]
    [InlineData("--name", "showcase", "--tier", "Premium")]
    [InlineData("--name", "showcase", "--if-newer", "2026-11-03T18:00:00Z")]
    [InlineData("--name", "showcase", "--request-id", "job-1")]
    [InlineData("--name", "showcase", "--if-newer", "2026-11-03T18:00:00", "--request-id", "job-1")]
    [InlineData("--name", "showcase", "--param", "variant=healthy")]
    public void ProfileSetRefusesOptionsThatDontFit(params string[] options)
    {
        var (exitCode, _, error) = CliHarness.Invoke(["profile", "set", "--target", "T4", "--profile-file", FilePath, .. options]);

        Assert.Equal(1, exitCode);
        Assert.NotEmpty(error);
        Assert.False(File.Exists(FilePath));
    }

    [Fact]
    public void AStampGoesOnlyWithAStopOrResetThatSetsTheProfile()
    {
        var (exitCode, _, error) = CliHarness.Invoke("stop", "--target", "T3", "--run-id", "20261103180000-t3-a1b2c3", "--server", "sql-x", "--if-newer", "2026-11-03T18:00:00Z", "--request-id", "job-1");
        Assert.Equal(1, exitCode);
        Assert.Contains("--all", error, StringComparison.Ordinal);

        (exitCode, _, error) = CliHarness.Invoke("reset", "--target", "T3", "--keep-profile", "--server", "sql-x", "--if-newer", "2026-11-03T18:00:00Z", "--request-id", "job-1");
        Assert.Equal(1, exitCode);
        Assert.Contains("--keep-profile", error, StringComparison.Ordinal);
    }

    [Fact]
    public void TheHostRaisesANormalPriorityOneStepAndLeavesAHigherOneAlone()
    {
        var current = ProcessPriorityClass.Normal;
        Assert.Equal(ProcessPriorityClass.AboveNormal, HostPriority.Raise(() => current, value => current = value, RunnerLog.Null));

        current = ProcessPriorityClass.High;
        Assert.Equal(ProcessPriorityClass.High, HostPriority.Raise(() => current, _ => throw new InvalidOperationException("never set"), RunnerLog.Null));

        Assert.Null(HostPriority.Raise(() => ProcessPriorityClass.Normal, _ => throw new System.ComponentModel.Win32Exception(5), RunnerLog.Null));
        Assert.False(ProfileHostOptions.From(ActivityProfilesDefinition.Default, null).RaisePriority, "only 'profile run' raises it");
    }
}
