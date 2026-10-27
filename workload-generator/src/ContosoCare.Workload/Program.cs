using System.CommandLine;
using System.Reflection;
using ContosoCare.Workload.Cli;

namespace ContosoCare.Workload;

/// <summary>
/// Entry point for the Contoso Care Operations workload runner (ADR 0010): bounded scenarios, activity profiles, stop,
/// reset, and status for the demo's three SQL targets.
/// </summary>
internal static class Program
{
    /// <summary>How long Ctrl+C or SIGTERM waits for runs to stop cleanly (roll back, record their end) before the process exits.</summary>
    internal static readonly TimeSpan TerminationGrace = TimeSpan.FromSeconds(60);

    internal static async Task<int> Main(string[] args)
    {
        var configuration = new InvocationConfiguration { ProcessTerminationTimeout = TerminationGrace };
        return await BuildRootCommand().Parse(args).InvokeAsync(configuration).ConfigureAwait(false);
    }

    internal static RootCommand BuildRootCommand() => CommandLine.Build();

    internal static string GetVersion()
    {
        var informational = typeof(Program).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion;

        // Drop any source-revision suffix ("+<sha>") so the output is a plain semantic version.
        return (informational ?? "0.0.0").Split('+')[0];
    }
}
