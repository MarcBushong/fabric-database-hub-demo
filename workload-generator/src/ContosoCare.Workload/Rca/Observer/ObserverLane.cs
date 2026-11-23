using ContosoCare.Workload.Catalog;
using ContosoCare.Workload.Diagnostics;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>
/// The observer lane of <c>profile run</c> (ADR 0031): one loop per observed target, each running the sentinel for the
/// whole session and the detail capture its triggers start, one statement at a time. A target is observed while its
/// profile is active (the profile host's lanes say so) and never because of what the profile plans. What the loops
/// capture goes into one observation span of the local evidence store, from the first target's start to the last
/// one's end. T5 has no observer: it's only noted in the span, so its coverage says where its evidence is.
/// A session's stop records the capture's end in the store (rca export --end-capture) while the workload runs on until
/// the VM stops: each loop reads it at its next tick, a second at most, and ends its target's capture as a profile's end
/// does, so the stop's export takes the span whole; only a profile set after the end is captured again.
/// </summary>
internal sealed class ObserverLane(IReadOnlyList<TargetObserver> observers, IReadOnlyList<DemoTarget> noted, IObservationGate gate, ICaptureStore store, RunnerLog log, TimeProvider time, ObserverOptions? options = null)
{
    /// <summary>An end later than this past the lane's clock is ignored (a clock that went back): capture goes on then.</summary>
    internal static readonly TimeSpan FutureEndLimit = TimeSpan.FromMinutes(1);

    private readonly ObserverOptions settings = options ?? new ObserverOptions();
    private readonly Lock spanGate = new();
    private readonly Lock endGate = new();
    private ICaptureSpan? span;
    private int members;
    private DateTimeOffset storeRetryAt;
    private DateTimeOffset? announcedEnd;

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        log.Info("rca.lane-started", "The RCA observer lane started.", ("targets", string.Join(",", observers.Select(o => o.Target).Concat(noted.Select(t => t.ToString())))));
        var loops = observers.Select(o => Task.Run(() => ObserveAsync(o, cancellationToken), CancellationToken.None)).ToList();
        if (noted.Count > 0)
        {
            loops.Add(Task.Run(() => NoteAsync(cancellationToken), CancellationToken.None));
        }

        await Task.WhenAll(loops).ConfigureAwait(false);
        log.Info("rca.lane-stopped", "The RCA observer lane stopped.");
    }

    private async Task ObserveAsync(TargetObserver observer, CancellationToken cancellationToken)
    {
        var active = false;
        while (!cancellationToken.IsCancellationRequested)
        {
            var now = time.GetUtcNow();
            var next = now + TimeSpan.FromSeconds(1);
            try
            {
                var end = CaptureEnd(now);
                var wanted = IsActive(observer.Gate, end);
                if (wanted && !active)
                {
                    if ((!observer.BeginsOnConnect || await observer.ProbeAsync(now, cancellationToken).ConfigureAwait(false)) && Acquire(observer.Target, now) is { } sink)
                    {
                        active = true;
                        await observer.BeginAsync(sink, now, cancellationToken).ConfigureAwait(false);
                    }
                }
                else if (!wanted && active)
                {
                    active = false;
                    // After a session's stop recorded the capture's end, the stop's export waits for this: bounded, as when
                    // the host stops, so a target that doesn't answer can't hold the span open past the export's wait.
                    using var bound = end is null ? null : CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    bound?.CancelAfter(settings.EndTimeout);
                    try
                    {
                        await observer.EndAsync(now, bound?.Token ?? cancellationToken).ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (bound?.IsCancellationRequested == true && !cancellationToken.IsCancellationRequested)
                    {
                        log.Warn("rca.end-timeout", "The RCA observer couldn't end its capture in time after the session's stop; the next start or the runner's reset drops its event session.", ("target", observer.Target));
                    }
                    finally
                    {
                        Release(observer.Target, time.GetUtcNow());
                    }
                }
                else if (!wanted && observer.BeginsOnConnect)
                {
                    await observer.ReleaseAsync().ConfigureAwait(false);
                }

                if (active)
                {
                    next = await observer.TickAsync(time.GetUtcNow(), cancellationToken).ConfigureAwait(false);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                // A failure of one tick never ends the lane: the next tick tries again.
                log.Warn("rca.tick-failed", "The RCA observer's tick failed; it carries on.", ("target", observer.Target), ("error", Redactor.Redact(ex.GetType().Name + ": " + ex.Message)));
                log.Debug("rca.tick-failed-detail", ex.ToString(), ("target", observer.Target));
                next = time.GetUtcNow() + TimeSpan.FromSeconds(5);
            }

            var delay = next - time.GetUtcNow();
            delay = delay < TimeSpan.FromMilliseconds(50) ? TimeSpan.FromMilliseconds(50) : delay > TimeSpan.FromSeconds(1) ? TimeSpan.FromSeconds(1) : delay;
            try
            {
                await Task.Delay(delay, time, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        if (active)
        {
            // The host is stopping: the last reads and the event session's drop, bounded.
            using var bound = new CancellationTokenSource(settings.EndTimeout);
            try
            {
                await observer.EndAsync(time.GetUtcNow(), bound.Token).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                log.Warn("rca.end-failed", "The RCA observer couldn't end its capture cleanly; the next start or the runner's reset drops its event session.", ("target", observer.Target), ("error", Redactor.Redact(ex.Message)));
            }
            finally
            {
                Release(observer.Target, time.GetUtcNow());
            }
        }
    }

    /// <summary>A target the lane doesn't observe (T5): it joins the span while its profile is active, so its coverage says why.</summary>
    private async Task NoteAsync(CancellationToken cancellationToken)
    {
        var active = new HashSet<DemoTarget>();
        while (!cancellationToken.IsCancellationRequested)
        {
            var now = time.GetUtcNow();
            var end = CaptureEnd(now);
            foreach (var target in noted)
            {
                var wanted = IsActive(target, end);
                if (wanted && !active.Contains(target) && Acquire(target.ToString(), now) is { } sink)
                {
                    active.Add(target);
                    sink.Note(new CaptureNote(NoteKind.Gap, target.ToString(), now, $"{target} has no observer: its evidence is Azure Monitor's metrics (its 429s and normalized request units), which the history saves."));
                    sink.Watermark(target.ToString(), now);
                }
                else if (!wanted && active.Remove(target))
                {
                    Release(target.ToString(), now);
                }
                else if (active.Contains(target))
                {
                    lock (spanGate)
                    {
                        span?.Watermark(target.ToString(), now);
                    }
                }
            }

            try
            {
                await Task.Delay(TimeSpan.FromSeconds(1), time, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        foreach (var target in active)
        {
            Release(target.ToString(), time.GetUtcNow());
        }
    }

    private bool IsActive(DemoTarget target, DateTimeOffset? end)
    {
        try
        {
            return end is { } at ? gate.IsActiveAfter(target, at) : gate.IsActive(target);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            log.Debug("rca.gate-failed", Redactor.Redact(ex.Message), ("target", target));
            return false;
        }
    }

    /// <summary>
    /// The capture's end that a session's stop recorded (rca export --end-capture), read from the store at each tick, or
    /// null: none, one that can't be read, or one later than the lane's clock allows (a clock that went back), after which
    /// capture goes on as before. The first tick that sees a new one says so in the log.
    /// </summary>
    private DateTimeOffset? CaptureEnd(DateTimeOffset now)
    {
        DateTimeOffset? end;
        try
        {
            end = store.CaptureEndedAt();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            log.Debug("rca.end-unread", Redactor.Redact(ex.Message));
            return null;
        }

        if (end is { } at && at > now + FutureEndLimit)
        {
            end = null;
        }

        if (end is not null && end != announcedEnd)
        {
            lock (endGate)
            {
                if (end != announcedEnd)
                {
                    announcedEnd = end;
                    log.Info("rca.capture-ended", "A session's stop recorded the capture's end: the RCA observer ends its capture, and captures again once a profile is set after it.", ("endedUtc", end));
                }
            }
        }

        return end;
    }

    private ICaptureSpan? Acquire(string target, DateTimeOffset at)
    {
        lock (spanGate)
        {
            if (span is null)
            {
                if (at < storeRetryAt)
                {
                    return null;
                }

                try
                {
                    span = store.Open(at);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException)
                {
                    storeRetryAt = at + TimeSpan.FromMinutes(10);
                    log.Warn("rca.store-failed", "The RCA observer couldn't open its evidence store, so nothing is captured; it tries again in 10 minutes.", ("error", Redactor.Redact(ex.Message)));
                    return null;
                }
            }

            members++;
            span.Began(target, at);
            return span;
        }
    }

    private void Release(string target, DateTimeOffset at)
    {
        lock (spanGate)
        {
            if (span is null)
            {
                return;
            }

            span.Ended(target, at);
            if (--members <= 0)
            {
                members = 0;
                span.Close(at);
                span = null;
            }
        }
    }
}
