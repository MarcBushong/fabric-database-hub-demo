namespace ContosoCare.Workload.Profiles;

/// <summary>
/// Replaces a file with a temporary file written next to it, so a reader never sees half of it. On Windows the replace is
/// refused ("Access to the path is denied") while any other handle has the file open, whatever its share mode, so a writer
/// tries again a few times, briefly (live, 2026-11-17: demo-control's profile set failed once while the profile host read
/// T4's profile file during an incident).
/// </summary>
internal static class FileReplace
{
    /// <summary>The waits between tries: about 3 seconds in all.</summary>
    public static readonly IReadOnlyList<TimeSpan> RetryDelays =
        [TimeSpan.FromMilliseconds(50), TimeSpan.FromMilliseconds(100), TimeSpan.FromMilliseconds(200), TimeSpan.FromMilliseconds(400), TimeSpan.FromMilliseconds(800), TimeSpan.FromMilliseconds(1600)];

    /// <summary>The replace itself: the temporary file moves over the old one.</summary>
    public static void Move(string temporary, string path) => File.Move(temporary, path, overwrite: true);

    /// <summary>Is the error a file in use: access denied, or a sharing or lock violation?</summary>
    public static bool IsInUse(Exception ex) =>
        ex is UnauthorizedAccessException || (ex is IOException io && (io.HResult & 0xFFFF) is 32 or 33);

    public static async Task ReplaceAsync(string temporary, string path, Action<string, string> replace, CancellationToken cancellationToken)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                replace(temporary, path);
                return;
            }
            catch (Exception ex) when (attempt < RetryDelays.Count && IsInUse(ex))
            {
                await Task.Delay(RetryDelays[attempt], cancellationToken).ConfigureAwait(false);
            }
        }
    }

    public static void Replace(string temporary, string path, Action<string, string> replace)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                replace(temporary, path);
                return;
            }
            catch (Exception ex) when (attempt < RetryDelays.Count && IsInUse(ex))
            {
                Thread.Sleep(RetryDelays[attempt]);
            }
        }
    }
}
