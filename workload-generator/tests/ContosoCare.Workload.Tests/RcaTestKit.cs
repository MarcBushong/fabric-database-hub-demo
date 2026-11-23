using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Tests;

/// <summary>Fakes for the Incident RCA's tests: a scripted capture connection, a sink that keeps what it gets, and a clock.</summary>
internal static class RcaTestKit
{
    public static readonly DateTimeOffset Start = new(2026, 11, 20, 16, 50, 0, TimeSpan.Zero);

    /// <summary>One result row from column-value pairs.</summary>
    public static CaptureValues Row(params (string Column, object? Value)[] values) =>
        new(values.ToDictionary(v => v.Column, v => v.Value, StringComparer.OrdinalIgnoreCase));

    /// <summary>A secret-shaped string built at run time, so no scanner sees a literal one in the source.</summary>
    public static string FakeSecret(int length = 48)
    {
        const string upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
        const string lower = "abcdefghijkmnopqrstuvwxyz";
        const string digits = "23456789";
        var random = new Random(length);
        var characters = new char[length];
        for (var i = 0; i < length; i++)
        {
            var set = (i % 3) switch { 0 => upper, 1 => lower, _ => digits };
            characters[i] = set[random.Next(set.Length)];
        }

        return new string(characters);
    }
}

/// <summary>A clock that moves only when told to.</summary>
internal sealed class ManualTime(DateTimeOffset start) : TimeProvider
{
    private long ticks;

    public DateTimeOffset Now => GetUtcNow();

    public void Set(DateTimeOffset to) => Interlocked.Exchange(ref ticks, (to - start).Ticks);

    public void Advance(TimeSpan by) => Interlocked.Add(ref ticks, by.Ticks);

    public override DateTimeOffset GetUtcNow() => start + TimeSpan.FromTicks(Interlocked.Read(ref ticks));
}

/// <summary>Keeps every row, note, and watermark the observer writes.</summary>
internal sealed class MemorySink : ICaptureSpan
{
    private readonly Lock gate = new();
    private readonly List<CaptureNote> notes = [];
    private readonly List<(string Target, DateTimeOffset At, bool Began)> membership = [];
    private DateTimeOffset? closedAt;
    private int closeFailures;

    public List<CaptureRow> Rows { get; } = [];

    /// <summary>A copy, safe to read while an observer writes.</summary>
    public List<CaptureNote> Notes
    {
        get
        {
            lock (gate)
            {
                return [.. notes];
            }
        }
    }

    public Dictionary<string, DateTimeOffset> Watermarks { get; } = new(StringComparer.Ordinal);

    /// <summary>A copy, safe to read while the lane writes.</summary>
    public List<(string Target, DateTimeOffset At, bool Began)> Membership
    {
        get
        {
            lock (gate)
            {
                return [.. membership];
            }
        }
    }

    public DateTimeOffset? ClosedAt
    {
        get
        {
            lock (gate)
            {
                return closedAt;
            }
        }
    }

    public void Write(CaptureRow row)
    {
        lock (gate)
        {
            Rows.Add(row);
        }
    }

    public void Note(CaptureNote note)
    {
        lock (gate)
        {
            notes.Add(note);
        }
    }

    public void Watermark(string target, DateTimeOffset complete)
    {
        lock (gate)
        {
            Watermarks[target] = complete;
        }
    }

    public void Began(string target, DateTimeOffset at)
    {
        lock (gate)
        {
            membership.Add((target, at, true));
        }
    }

    public void Ended(string target, DateTimeOffset at)
    {
        lock (gate)
        {
            membership.Add((target, at, false));
        }
    }

    public void Close(DateTimeOffset at)
    {
        lock (gate)
        {
            if (closeFailures > 0)
            {
                closeFailures--;
                throw new IOException("The process cannot access the file 'span.json' because it is being used by another process.");
            }

            closedAt = at;
        }
    }

    /// <summary>How many more times <see cref="Close"/> fails, as a write of span.json can, before it closes.</summary>
    public int CloseFailures
    {
        get
        {
            lock (gate)
            {
                return closeFailures;
            }
        }

        set
        {
            lock (gate)
            {
                closeFailures = value;
            }
        }
    }

    public List<CaptureRow> Table(string table) => [.. Rows.Where(r => r.Table == table)];

    public List<CaptureRow> Events(string kind) => [.. Rows.Where(r => r.Table == "rca_events" && (string?)r.Get("kind") == kind)];
}

/// <summary>
/// A capture connector whose blocks answer from a script: the test sets what each block returns for the current simulated
/// time, and every call is recorded with its text, so a test can check the observer ran only the catalog's blocks.
/// </summary>
internal sealed class ScriptedConnector(Func<string, int[]?, IReadOnlyList<CaptureValues>> answer) : ICaptureConnector
{
    public List<(string BlockId, string Text, int[]? Parameter)> Calls { get; } = [];

    public int Opens { get; private set; }

    /// <summary>When set, opening throws this (a target that doesn't answer).</summary>
    public CaptureException? OpenFailure { get; set; }

    /// <summary>When set, a block throws what it returns, or runs normally for null.</summary>
    public Func<string, CaptureException?>? Failure { get; set; }

    /// <summary>How long each statement takes.</summary>
    public TimeSpan Delay { get; set; }

    public string Description => "scripted";

    private Func<string, int[]?, IReadOnlyList<CaptureValues>> Answer { get; } = answer;

    public Task<ICaptureConnection> OpenAsync(CancellationToken cancellationToken)
    {
        if (OpenFailure is { } failure)
        {
            throw failure;
        }

        Opens++;
        return Task.FromResult<ICaptureConnection>(new Connection(this));
    }

    private sealed class Connection(ScriptedConnector owner) : ICaptureConnection
    {
        public async Task<IReadOnlyList<CaptureValues>> QueryAsync(string blockId, string text, int[]? parameter, TimeSpan timeout, CancellationToken cancellationToken)
        {
            lock (owner.Calls)
            {
                owner.Calls.Add((blockId, text, parameter));
            }

            if (owner.Delay > TimeSpan.Zero)
            {
                await Task.Delay(owner.Delay, cancellationToken);
            }

            if (owner.Failure?.Invoke(blockId) is { } failure)
            {
                throw failure;
            }

            return owner.Answer(blockId, parameter);
        }

        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
