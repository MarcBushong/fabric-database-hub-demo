namespace ContosoCare.Workload.Tests;

/// <summary>Finds files in the repository from the test output folder.</summary>
internal static class RepositoryPaths
{
    public static readonly string Root = FindRoot();

    public static string Combine(params string[] parts) => Path.Combine([Root, .. parts]);

    public static string Relative(string path) => Path.GetRelativePath(Root, path).Replace('\\', '/');

    public static string[] ScenarioFolders() =>
        [.. Directory.GetDirectories(Combine("scenarios")).Where(d => File.Exists(Path.Combine(d, "scenario.json")) || File.Exists(Path.Combine(d, "README.md"))).Order(StringComparer.Ordinal)];

    private static string FindRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (Directory.Exists(Path.Combine(directory.FullName, "database")) &&
                Directory.Exists(Path.Combine(directory.FullName, "workload-generator")) &&
                Directory.Exists(Path.Combine(directory.FullName, "scenarios")))
            {
                return directory.FullName;
            }

            directory = directory.Parent;
        }

        throw new DirectoryNotFoundException("The repository root (with database/, scenarios/, and workload-generator/) was not found above the test output folder.");
    }
}
