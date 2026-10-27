using System.CommandLine;
using System.Text.RegularExpressions;
using Xunit;

namespace ContosoCare.Workload.Tests;

public sealed class ProgramTests
{
    [Fact]
    public void VersionIsSemantic()
    {
        Assert.Matches(new Regex(@"^\d+\.\d+\.\d+$"), Program.GetVersion());
    }

    [Fact]
    public void VersionCommandSucceeds()
    {
        var (exitCode, output, _) = CliHarness.Invoke("version");

        Assert.Equal(0, exitCode);
        Assert.Equal(Program.GetVersion(), output.Trim());
    }

    [Theory]
    [InlineData("run")]
    [InlineData("stop")]
    [InlineData("reset")]
    [InlineData("status")]
    [InlineData("profile")]
    [InlineData("warmup")]
    [InlineData("setup")]
    [InlineData("scenarios")]
    public void EveryCommandIsAvailable(string command)
    {
        Assert.Contains(Program.BuildRootCommand().Subcommands, c => c.Name == command);
    }

    [Theory]
    [InlineData("get")]
    [InlineData("set")]
    [InlineData("run")]
    public void ProfileHasItsSubcommands(string subcommand)
    {
        var profile = Program.BuildRootCommand().Subcommands.Single(c => c.Name == "profile");

        Assert.Contains(profile.Subcommands, c => c.Name == subcommand);
    }

    [Fact]
    public void UnknownCommandFails()
    {
        var (exitCode, _, _) = CliHarness.Invoke("no-such-command");

        Assert.NotEqual(0, exitCode);
    }

    [Fact]
    public void TerminationGraceLeavesTimeForRollbacks()
    {
        Assert.True(Program.TerminationGrace >= TimeSpan.FromSeconds(30));
    }
}

/// <summary>Runs the command line in-process with captured output.</summary>
internal static class CliHarness
{
    public static (int ExitCode, string Output, string Error) Invoke(params string[] args)
    {
        using var output = new StringWriter();
        using var error = new StringWriter();
        var configuration = new InvocationConfiguration { Output = output, Error = error };
        var exitCode = Program.BuildRootCommand().Parse(args).Invoke(configuration);
        return (exitCode, output.ToString(), error.ToString());
    }

    public static IReadOnlyList<string> ParseErrors(params string[] args) =>
        [.. Program.BuildRootCommand().Parse(args).Errors.Select(e => e.Message)];
}
