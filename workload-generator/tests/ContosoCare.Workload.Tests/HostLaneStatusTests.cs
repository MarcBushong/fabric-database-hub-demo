using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Profiles;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>The profile host's heartbeat (host-lanes.json) and the ADR 0012 status that 'status' derives from it (Phase 25b).</summary>
public sealed class HostLaneStatusTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 26, 15, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset BootedAt = Now - TimeSpan.FromHours(3);

    [Fact]
    public void NoHeartbeatIsAWarning()
    {
        var verdict = Evaluate(null, DemoTarget.T1, profileActive: true);

        Assert.Equal("Warning", verdict.Status);
        Assert.Contains("No profile host heartbeat", verdict.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void AnUnreadableHeartbeatIsAWarningThatSaysWhy()
    {
        var verdict = HostLaneStatus.Evaluate(new HostLanesRead("host-lanes.json", null, "bad JSON"), DemoTarget.T1, true, Now, BootedAt, (_, _) => true);

        Assert.Equal("Warning", verdict.Status);
        Assert.Contains("bad JSON", verdict.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void AHeartbeatFromAnEarlierBootMeansTheHostHasNotStartedYet()
    {
        var document = Document(Lane("T1")) with { HostStartedAt = BootedAt - TimeSpan.FromHours(20), HeartbeatAt = BootedAt - TimeSpan.FromHours(19) };

        var verdict = Evaluate(document, DemoTarget.T1, profileActive: true, alive: false);

        Assert.Equal("Warning", verdict.Status);
        Assert.Contains("hasn't started since this machine booted", verdict.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(true, "Warning")]
    [InlineData(false, "Pass")]
    public void AHostThatStoppedCleanlyMattersOnlyWhileAProfileIsActive(bool profileActive, string expected)
    {
        var document = Document(Lane("T1")) with { StoppedAt = Now - TimeSpan.FromMinutes(3), StopReason = "not-after", HeartbeatAt = Now - TimeSpan.FromMinutes(3) };

        var verdict = Evaluate(document, DemoTarget.T1, profileActive, alive: false);

        Assert.Equal(expected, verdict.Status);
        Assert.Contains("before the next auto-shutdown", verdict.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(true, "Fail")]
    [InlineData(false, "Warning")]
    public void AHostProcessThatEndedWithoutAStopFailsAnActiveProfile(bool profileActive, string expected)
    {
        var verdict = Evaluate(Document(Lane("T1")), DemoTarget.T1, profileActive, alive: false);

        Assert.Equal(expected, verdict.Status);
        Assert.Contains("ended without a clean stop", verdict.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(true, "Fail")]
    [InlineData(false, "Warning")]
    public void AStaleHeartbeatMeansTheSupervisorIsNotRunning(bool profileActive, string expected)
    {
        var document = Document(Lane("T1")) with { HeartbeatAt = Now - TimeSpan.FromMinutes(4) };

        var verdict = Evaluate(document, DemoTarget.T1, profileActive);

        Assert.Equal(expected, verdict.Status);
        Assert.Contains("heartbeat is 4 min old", verdict.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(true, "Warning")]
    [InlineData(false, "Not selected")]
    public void ATargetTheHostDoesNotServe(bool profileActive, string expected)
    {
        var verdict = Evaluate(Document(Lane("T1")), DemoTarget.T3, profileActive);

        Assert.Equal(expected, verdict.Status);
        Assert.Contains("serves T1, not T3", verdict.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void AServingLanePasses()
    {
        var verdict = Evaluate(Document(Lane("T1"), Lane("T3")), DemoTarget.T3, profileActive: true);

        Assert.Equal("Pass", verdict.Status);
        Assert.Contains("serves T3", verdict.Message, StringComparison.Ordinal);
        Assert.Equal("T3", verdict.Lane!.Target);
    }

    [Fact]
    public void ALaneInABoundedResetIsNotStalled()
    {
        var lane = Lane("T1") with { LastPollAt = Now - TimeSpan.FromMinutes(8), BusyUntil = Now + TimeSpan.FromMinutes(4), State = "Busy", Operation = "resetting before the profile" };

        var verdict = Evaluate(Document(lane), DemoTarget.T1, profileActive: true);

        Assert.Equal("Pass", verdict.Status);
        Assert.Contains("resetting the target before the profile", verdict.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ALaneThatStoppedPollingIsAWarningUntilTheSupervisorReplacesIt()
    {
        var lane = Lane("T1") with { LastPollAt = Now - TimeSpan.FromMinutes(6), Operation = "reading the profile", OperationSince = Now - TimeSpan.FromMinutes(6) };

        var verdict = Evaluate(Document(lane), DemoTarget.T1, profileActive: true);

        Assert.Equal("Warning", verdict.Status);
        Assert.Contains("hasn't finished a poll for 6 min", verdict.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ASlowLaneIsAWarning()
    {
        var lane = Lane("T1") with { LastPollAt = Now - TimeSpan.FromSeconds(90) };

        Assert.Equal("Warning", Evaluate(Document(lane), DemoTarget.T1, profileActive: true).Status);
    }

    [Fact]
    public void ARestartingLaneIsAWarning()
    {
        var lane = Lane("T1") with { State = "Restarting", Restarts = 1, RecentRestarts = [Now - TimeSpan.FromSeconds(5)], LastRestartReason = "no poll finished for 301 s", RestartDueAt = Now + TimeSpan.FromSeconds(5) };

        var verdict = Evaluate(Document(lane), DemoTarget.T1, profileActive: true);

        Assert.Equal("Warning", verdict.Status);
        Assert.Contains("restarting the T1 lane (no poll finished for 301 s)", verdict.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ARecentRestartIsAWarningAndAnOldOneIsHistory()
    {
        var recent = Lane("T1") with { Restarts = 1, RecentRestarts = [Now - TimeSpan.FromMinutes(20)], LastRestartAt = Now - TimeSpan.FromMinutes(20), LastRestartReason = "its loop failed" };
        var old = recent with { RecentRestarts = [Now - TimeSpan.FromHours(2)], LastRestartAt = Now - TimeSpan.FromHours(2) };

        Assert.Equal("Warning", Evaluate(Document(recent), DemoTarget.T1, profileActive: true).Status);
        var verdict = Evaluate(Document(old), DemoTarget.T1, profileActive: true);
        Assert.Equal("Pass", verdict.Status);
        Assert.Contains("restarted 1 time(s) since", verdict.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void ALaneThatKeepsFailingFails()
    {
        var lane = Lane("T1") with { Restarts = 3, RecentRestarts = [Now - TimeSpan.FromMinutes(40), Now - TimeSpan.FromMinutes(20), Now - TimeSpan.FromMinutes(5)], LastRestartReason = "no poll finished for 300 s" };

        var verdict = Evaluate(Document(lane), DemoTarget.T1, profileActive: false);

        Assert.Equal("Fail", verdict.Status);
        Assert.Contains("restarted it 3 times in the last hour", verdict.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void FailingPollsAreAWarningWithTheError()
    {
        var lane = Lane("T1") with { ConsecutiveFailures = 2, LastError = "TimeoutException: Reading the profile took longer than 150 s" };

        var verdict = Evaluate(Document(lane), DemoTarget.T1, profileActive: true);

        Assert.Equal("Warning", verdict.Status);
        Assert.Contains("took longer than 150 s", verdict.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void TheNodeCarriesTheStatusAndTheLane()
    {
        var node = Evaluate(Document(Lane("T1")), DemoTarget.T1, profileActive: true).ToNode();

        Assert.Equal("Pass", (string?)node["status"]);
        Assert.Equal("Serving", (string?)node["lane"]!["state"]);
        Assert.Equal(4242, (int?)node["processId"]);
        Assert.Equal(5, (int?)node["lane"]!["lastPollAgeSeconds"]);
    }

    [Fact]
    public void TheFileRoundTrips()
    {
        var folder = Path.Combine(AppContext.BaseDirectory, "host-lanes-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(folder, HostLanesFile.FileName);
        try
        {
            Assert.Null(HostLanesFile.Read(path).Document);
            Assert.Null(HostLanesFile.Read(path).Error);

            HostLanesFile.Write(path, Document(Lane("T1") with { RecentRestarts = [Now - TimeSpan.FromMinutes(1)] }, Lane("T3")));
            var read = HostLanesFile.Read(path);

            Assert.Null(read.Error);
            Assert.Equal(4242, read.Document!.ProcessId);
            Assert.Equal(["T1", "T3"], read.Document.Lanes!.Select(l => l.Target));
            Assert.Equal(Now - TimeSpan.FromMinutes(1), Assert.Single(read.Document.Lanes![0].RecentRestarts!));
            Assert.False(File.Exists(path + ".tmp"));

            File.WriteAllText(path, "{ not json");
            Assert.NotNull(HostLanesFile.Read(path).Error);
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void TheDefaultFileSitsNextToTheT3ProfileFile()
    {
        Assert.Equal(Path.GetDirectoryName(FileProfileStore.DefaultPath), Path.GetDirectoryName(HostLanesFile.DefaultPath));
        Assert.Equal("host-lanes.json", Path.GetFileName(HostLanesFile.DefaultPath));
    }

    [Fact]
    public void ThisProcessIsAliveAndAnotherStartTimeIsNot()
    {
        using var process = System.Diagnostics.Process.GetCurrentProcess();
        var started = new DateTimeOffset(process.StartTime.ToUniversalTime(), TimeSpan.Zero);

        Assert.True(HostLaneStatus.IsProcessAlive(process.Id, started));
        Assert.False(HostLaneStatus.IsProcessAlive(process.Id, started - TimeSpan.FromHours(1)));
    }

    private static HostLaneVerdict Evaluate(HostLanesDocument? document, DemoTarget target, bool profileActive, bool? alive = true) =>
        HostLaneStatus.Evaluate(new HostLanesRead("host-lanes.json", document, null), target, profileActive, Now, BootedAt, (_, _) => alive);

    private static HostLanesDocument Document(params HostLaneRecord[] lanes) => new()
    {
        ProcessId = 4242,
        ProcessStartedAt = Now - TimeSpan.FromHours(2),
        HostStartedAt = Now - TimeSpan.FromHours(2),
        HeartbeatAt = Now - TimeSpan.FromSeconds(4),
        NotAfter = Now + TimeSpan.FromHours(4),
        PollSeconds = 10,
        HeartbeatSeconds = 10,
        StallLimitSeconds = 300,
        Lanes = [.. lanes],
    };

    private static HostLaneRecord Lane(string target) => new()
    {
        Target = target,
        State = "Serving",
        Generation = 1,
        LastPollAt = Now - TimeSpan.FromSeconds(5),
        Operation = "waiting for the next poll",
        OperationSince = Now - TimeSpan.FromSeconds(5),
        Profile = "baseline",
        RunningRuns = 1,
    };
}
