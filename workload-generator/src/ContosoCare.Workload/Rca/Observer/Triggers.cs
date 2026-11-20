using System.Globalization;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>A capture episode (rca/README.md, Capture triggers): detail capture that a signal started, until it stays clear.</summary>
internal sealed class Episode(string id, DateTimeOffset start, string startDetail)
{
    /// <summary>The episode's ID, <c>&lt;target&gt;-&lt;yyyyMMddTHHmmssZ&gt;</c>, the code of its capture rows.</summary>
    public string Id { get; } = id;

    public DateTimeOffset Start { get; } = start;

    public string StartDetail { get; } = startDetail;

    /// <summary>The last sample that wasn't clear: a quiet time counts from it.</summary>
    public DateTimeOffset LastBusy { get; set; } = start;

    /// <summary>Clear samples in a row.</summary>
    public int ClearSamples { get; set; }
}

/// <summary>What one sample did to a trigger's episode.</summary>
internal enum EpisodeChange
{
    None,
    Started,
    Ended,
}

/// <summary>Episode IDs, unique per target: a second episode that starts in the same second gets the next second's ID.</summary>
internal sealed class EpisodeIds(string target)
{
    private readonly HashSet<string> used = new(StringComparer.Ordinal);

    public string Next(DateTimeOffset at)
    {
        var second = new DateTimeOffset(at.UtcDateTime.Ticks - (at.UtcDateTime.Ticks % TimeSpan.TicksPerSecond), TimeSpan.Zero);
        while (true)
        {
            var id = string.Create(CultureInfo.InvariantCulture, $"{target}-{second:yyyyMMdd'T'HHmmss'Z'}");
            if (used.Add(id))
            {
                return id;
            }

            second = second.AddSeconds(1);
        }
    }
}

/// <summary>
/// One trigger of the capture triggers table: a sample can start an episode (<c>start</c>), and the episode ends when the
/// samples have been clear for <see cref="QuietFor"/> since the last one that wasn't (blocking, lock waiters,
/// connections, errors), or for <see cref="ClearSamples"/> samples in a row (the replica's replay). Pure, so the
/// triggers' timing is tested without a database.
/// </summary>
internal sealed class EpisodeTrigger(EpisodeIds ids, TimeSpan? quietFor, int clearSamples = 0)
{
    public TimeSpan? QuietFor { get; } = quietFor;

    public int ClearSamples { get; } = clearSamples;

    public Episode? Current { get; private set; }

    /// <summary>
    /// One sample at <paramref name="at"/>: <paramref name="start"/> when it crosses the start threshold,
    /// <paramref name="clear"/> when it's under the end threshold. <paramref name="canStart"/> is false for samples
    /// that may continue an episode but not open one (detail samples: only the sentinel starts an episode).
    /// </summary>
    public EpisodeChange Observe(DateTimeOffset at, bool start, bool clear, Func<string> startDetail, bool canStart = true)
    {
        if (Current is null)
        {
            if (start && canStart)
            {
                Current = new Episode(ids.Next(at), at, startDetail());
                return EpisodeChange.Started;
            }

            return EpisodeChange.None;
        }

        if (!clear)
        {
            Current.LastBusy = at > Current.LastBusy ? at : Current.LastBusy;
            Current.ClearSamples = 0;
            return EpisodeChange.None;
        }

        Current.ClearSamples++;
        var ended = QuietFor is { } quiet ? at - Current.LastBusy >= quiet : Current.ClearSamples >= ClearSamples;
        return ended ? EpisodeChange.Ended : EpisodeChange.None;
    }

    /// <summary>Ends the current episode (after <see cref="Observe"/> said so, or when observation stops) and returns it.</summary>
    public Episode? Finish()
    {
        var episode = Current;
        Current = null;
        return episode;
    }
}

/// <summary>What one sample's duration did to a target's cadence.</summary>
internal enum CadenceChange
{
    None,
    Slowed,
    DetailStopped,
    Recovered,
}

/// <summary>
/// Self-throttling (ADR 0031): a sample that takes over 2 seconds halves the target's cadence (its intervals double,
/// up to 8 times), and three in a row stop its detail capture for the rest of the observation; three quick samples in a
/// row win back one step.
/// </summary>
internal sealed class Cadence(TimeSpan? slowSample = null, int stopAfter = 3, int maximumFactor = 8)
{
    private readonly TimeSpan slow = slowSample ?? TimeSpan.FromSeconds(2);
    private int slowStreak;
    private int quickStreak;

    public int Factor { get; private set; } = 1;

    public bool DetailStopped { get; private set; }

    public TimeSpan Scale(TimeSpan interval) => interval * Factor;

    public CadenceChange Record(TimeSpan elapsed)
    {
        if (elapsed > slow)
        {
            quickStreak = 0;
            slowStreak++;
            Factor = Math.Min(Factor * 2, maximumFactor);
            if (slowStreak >= stopAfter && !DetailStopped)
            {
                DetailStopped = true;
                return CadenceChange.DetailStopped;
            }

            return CadenceChange.Slowed;
        }

        slowStreak = 0;
        quickStreak++;
        if (Factor > 1 && quickStreak >= 3)
        {
            Factor /= 2;
            quickStreak = 0;
            return CadenceChange.Recovered;
        }

        return CadenceChange.None;
    }
}

/// <summary>Cumulative counters, diffed: each reading's increase since the previous reading of the same counter.</summary>
internal sealed class CounterDeltas
{
    private readonly Dictionary<string, double> last = new(StringComparer.Ordinal);

    /// <summary>The increase, or null for the first reading and after the counter went back (a restart or a reset).</summary>
    public double? Next(string name, double? value)
    {
        if (value is not { } current)
        {
            return null;
        }

        var had = last.TryGetValue(name, out var previous);
        last[name] = current;
        return had && current >= previous ? current - previous : null;
    }

    public void Clear() => last.Clear();
}

/// <summary>Medians for the error trigger's baseline.</summary>
internal static class Median
{
    public static double Of(IReadOnlyList<double> values)
    {
        if (values.Count == 0)
        {
            return 0;
        }

        var sorted = values.Order().ToArray();
        var middle = sorted.Length / 2;
        return sorted.Length % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
    }
}
