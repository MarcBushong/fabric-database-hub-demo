using System.Text.Json;
using System.Text.RegularExpressions;
using Xunit;

namespace ContosoCare.Workload.Tests;

/// <summary>config/versions.json records the runner's pins; these tests keep them in sync with the build files.</summary>
public sealed partial class PinTests
{
    private static readonly Lazy<JsonElement> Runner = new(() =>
    {
        using var document = JsonDocument.Parse(File.ReadAllText(RepositoryPaths.Combine("config", "versions.json")));
        return document.RootElement.GetProperty("workloadRunner").Clone();
    });

    [Fact]
    public void TheRunnerVersionMatchesTheBuild()
    {
        var props = File.ReadAllText(RepositoryPaths.Combine("workload-generator", "Directory.Build.props"));
        var match = VersionElement().Match(props);
        Assert.True(match.Success, "Directory.Build.props has no <Version>.");
        Assert.Equal(Runner.Value.GetProperty("version").GetString(), match.Groups[1].Value);
        Assert.Contains($"<TargetFramework>{Runner.Value.GetProperty("targetFramework").GetString()}</TargetFramework>", props, StringComparison.Ordinal);
    }

    [Fact]
    public void TheRunnerRestoresThePublishedRuntimeIdentifier()
    {
        var project = File.ReadAllText(RepositoryPaths.Combine("workload-generator", "src", "ContosoCare.Workload", "ContosoCare.Workload.csproj"));
        var lockFile = File.ReadAllText(RepositoryPaths.Combine("workload-generator", "src", "ContosoCare.Workload", "packages.lock.json"));
        var rid = Runner.Value.GetProperty("publishRuntimeIdentifier").GetString();
        Assert.Contains($"<RuntimeIdentifiers>{rid}</RuntimeIdentifiers>", project, StringComparison.Ordinal);
        Assert.Contains($"\"net10.0/{rid}\"", lockFile, StringComparison.Ordinal);
    }

    [Fact]
    public void TheComposeFileUsesThePinnedSqlServerImage()
    {
        var compose = File.ReadAllText(RepositoryPaths.Combine("workload-generator", "compose.yaml"));
        var images = ImageLine().Matches(compose).Select(m => m.Groups[1].Value).ToList();
        Assert.Contains(Runner.Value.GetProperty("localTestSqlServerImage").GetString(), images);
        Assert.DoesNotContain(images, image => image.EndsWith(":latest", StringComparison.Ordinal) || !image.Contains(':', StringComparison.Ordinal));
    }

    [GeneratedRegex(@"<Version>([^<]+)</Version>")]
    private static partial Regex VersionElement();

    [GeneratedRegex(@"^\s*image:\s*(\S+)\s*$", RegexOptions.Multiline)]
    private static partial Regex ImageLine();
}
