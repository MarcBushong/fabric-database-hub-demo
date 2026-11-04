using Npgsql;

namespace ContosoCare.Workload.Postgres;

/// <summary>What one connection attempt in connection-surge's step past the limit came to.</summary>
internal enum SurgeAttemptOutcome
{
    /// <summary>The server had a free slot; the burst holds the connection for a few seconds at most.</summary>
    Opened,

    /// <summary>The server refused it at its connection limit (SQLSTATE 53300), which Azure Monitor counts as a failed connection.</summary>
    Refused,

    /// <summary>A sign-in failure (SQLSTATE class 28): the surge stops for good, so it never repeats a failed sign-in.</summary>
    SignInFailed,

    /// <summary>Anything else: the burst stops.</summary>
    Failed,
}

/// <summary>
/// connection-surge's fixed bounds on attempts past the limit (2026-11-03), which scenarios/connection-surge/scenario.json
/// and its README state: at most <see cref="MaxRefusedPerMinute"/> refused attempts in any minute and
/// <see cref="MaxRefusedPerRun"/> in a run, and the last free slots filled for at most <see cref="MaxBurst"/>. A wave
/// starts only while one more refusal is allowed, because its ramp can meet the limit too when other sessions opened
/// connections meanwhile; its burst gets what's left.
/// </summary>
internal sealed class SurgeBounds(TimeProvider time)
{
    public const int MaxRefusedPerMinute = 5;

    public const int MaxRefusedPerRun = 30;

    public static readonly TimeSpan MaxBurst = TimeSpan.FromSeconds(5);

    private static readonly TimeSpan Minute = TimeSpan.FromMinutes(1);

    private readonly Queue<DateTimeOffset> lastMinute = new();

    public int RefusedInRun { get; private set; }

    /// <summary>How many refused attempts are allowed now: <paramref name="wanted"/>, less what this minute and this run have used.</summary>
    public int Allowance(int wanted)
    {
        Prune();
        return Math.Max(0, Math.Min(wanted, Math.Min(MaxRefusedPerMinute - lastMinute.Count, MaxRefusedPerRun - RefusedInRun)));
    }

    /// <summary>Counts one refused attempt against both caps.</summary>
    public void RecordRefused()
    {
        lastMinute.Enqueue(time.GetUtcNow());
        RefusedInRun++;
    }

    /// <summary>When the next refusal is allowed: now, when a minute's oldest refusal leaves the window, or null once the run's cap is used up.</summary>
    public DateTimeOffset? NextAllowedAt()
    {
        Prune();
        if (RefusedInRun >= MaxRefusedPerRun)
        {
            return null;
        }

        return lastMinute.Count < MaxRefusedPerMinute ? time.GetUtcNow() : lastMinute.Peek() + Minute;
    }

    private void Prune()
    {
        var now = time.GetUtcNow();
        while (lastMinute.Count > 0 && now - lastMinute.Peek() >= Minute)
        {
            lastMinute.Dequeue();
        }
    }
}

/// <summary>A burst's outcome: what it opened (and closed again), what the server refused, and whether it stopped on a failure.</summary>
internal sealed record SurgeBurstResult(int Opened, int Refused, int Failed, bool SignInFailed, TimeSpan HeldFor, string? Error);

/// <summary>connection-surge's step past the limit (2026-11-03): fill the headroom briefly, so the next attempts are refused.</summary>
internal static class SurgeBurst
{
    /// <summary>Attempts beyond the headroom and the allowance, for slots other sessions freed since the wave began.</summary>
    public const int Slack = 2;

    /// <summary>
    /// Only max_connections' refusal (53300) counts as refused. A sign-in failure stops the surge: repeated failed sign-ins
    /// would look like a brute-force attempt to Microsoft Defender.
    /// </summary>
    public static SurgeAttemptOutcome Classify(Exception exception) => exception switch
    {
        PostgresException { SqlState: "53300" } => SurgeAttemptOutcome.Refused,
        PostgresException postgres when postgres.SqlState.StartsWith("28", StringComparison.Ordinal) => SurgeAttemptOutcome.SignInFailed,
        _ => SurgeAttemptOutcome.Failed,
    };

    /// <summary>
    /// Opens connections one at a time until the server has refused <paramref name="allowance"/> of them: the first fill the
    /// slots left free below the limit (the wave's headroom), the next are past it. At most <paramref name="maxAttempts"/>
    /// attempts within <paramref name="maxBurst"/>, each cut off at the burst's time limit; anything but a refusal stops
    /// it. Every connection it opened is closed before it returns, so the headroom is free again.
    /// </summary>
    public static async Task<SurgeBurstResult> RunAsync<TConnection>(
        Func<CancellationToken, Task<TConnection>> open,
        SurgeBounds bounds,
        int allowance,
        int maxAttempts,
        TimeSpan maxBurst,
        TimeProvider time,
        CancellationToken cancellationToken)
        where TConnection : IAsyncDisposable
    {
        ArgumentNullException.ThrowIfNull(open);
        ArgumentNullException.ThrowIfNull(bounds);
        ArgumentNullException.ThrowIfNull(time);
        var held = new List<TConnection>();
        var started = time.GetTimestamp();
        var refused = 0;
        var failed = 0;
        var signInFailed = false;
        string? error = null;
        TimeSpan heldFor;
        try
        {
            for (var attempt = 0; attempt < maxAttempts && refused < allowance; attempt++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var left = maxBurst - time.GetElapsedTime(started);
                if (left <= TimeSpan.Zero)
                {
                    break;
                }

                using var limit = new CancellationTokenSource(left, time);
                using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, limit.Token);
                var outcome = SurgeAttemptOutcome.Opened;
                try
                {
                    held.Add(await open(linked.Token).ConfigureAwait(false));
                }
                catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
                {
                    if (limit.IsCancellationRequested)
                    {
                        // The burst's time limit cut this attempt off; that's no failure, and the burst ends.
                        break;
                    }

                    outcome = Classify(ex);
                    if (outcome != SurgeAttemptOutcome.Refused)
                    {
                        error = PgConnectionOpener.Describe(ex);
                    }
                }

                if (outcome == SurgeAttemptOutcome.Refused)
                {
                    refused++;
                    bounds.RecordRefused();
                }
                else if (outcome != SurgeAttemptOutcome.Opened)
                {
                    failed++;
                    signInFailed = outcome == SurgeAttemptOutcome.SignInFailed;
                    break;
                }
            }
        }
        finally
        {
            heldFor = time.GetElapsedTime(started);
            foreach (var connection in held)
            {
                await connection.DisposeAsync().ConfigureAwait(false);
            }
        }

        return new SurgeBurstResult(held.Count, refused, failed, signInFailed, heldFor, error);
    }
}
