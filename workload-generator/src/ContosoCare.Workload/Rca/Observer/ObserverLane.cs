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
/// does; only a profile set after the end is captured again. The span then closes, unless the answer key still has to
/// record a fault run that ended by the end: then only its close waits, capturing nothing, so the stop's export takes the
/// span whole with those runs (the review of 1ca916a9).
/// </summary>
internal sealed class ObserverLane(IReadOnlyList<TargetObserver> observers, IReadOnlyList<DemoTarget> noted, IObservationGate gate, ICaptureStore store, RunnerLog log, TimeProvider time, ObserverOptions? options = null)
{
    /// <summary>
    /// An end later than this past the lane's clock when the lane first reads it is ignored for good (a clock that went
    /// back): capture goes on as before the end existed, and the stop's export names what stays on the VM.
    /// </summary>
    internal static readonly TimeSpan FutureEndLimit = TimeSpan.FromMinutes(1);

    // The tries, a second apart, to close a held span whose write fails as the lane stops.
    private const int StopCloseAttempts = 3;

    private readonly ObserverOptions settings = options ?? new ObserverOptions();
    private readonly Lock spanGate = new();
    private readonly Lock endGate = new();
    private ICaptureSpan? span;
    private int members;
    private DateTimeOffset storeRetryAt;

    // The span's close that waits for the answer key after the capture's end: the latest time one of its members ended.
    private DateTimeOffset? heldSince;

    // The latest time a member of the open span ended (each loop stamps its own time), where a held span closes.
    private DateTimeOffset? lastEnded;

    // The decision about the last end read, kept for that end whatever the clock does later (the review of 1ca916a9): one
    // ahead of the clock when first read stays ignored, and one applied stays applied.
    private (DateTimeOffset End, bool Ignored)? decided;

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        log.Info("rca.lane-started", "The RCA observer lane started.", ("targets", string.Join(",", observers.Select(o => o.Target).Concat(noted.Select(t => t.ToString())))));
        var loops = observers.Select(o => Task.Run(() => ObserveAsync(o, cancellationToken), CancellationToken.None)).ToList();
        if (noted.Count > 0)
        {
            loops.Add(Task.Run(() => NoteAsync(cancellationToken), CancellationToken.None));
        }

        loops.Add(Task.Run(() => CloseHeldAsync(cancellationToken), CancellationToken.None));
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
                        Release(observer.Target, time.GetUtcNow(), end);
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
                    Release(target.ToString(), now, end);
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
    /// null: none, one that can't be read, or one that was later than the lane's clock allows when the lane first read it
    /// (a clock that went back), which stays ignored, so capture goes on as before the end existed. The decision is kept for
    /// that end: a clock that goes back or forward later neither lifts an end nor brings an ignored one into force (the
    /// review of 1ca916a9: it only postponed it, until the clock caught up). The first tick that reads a new end says so in
    /// the log.
    /// </summary>
    private DateTimeOffset? CaptureEnd(DateTimeOffset now)
    {
        DateTimeOffset? read;
        try
        {
            read = store.CaptureEndedAt();
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            log.Debug("rca.end-unread", Redactor.Redact(ex.Message));
            return null;
        }

        if (read is not { } end)
        {
            return null;
        }

        lock (endGate)
        {
            if (decided is { } known && known.End == end)
            {
                return known.Ignored ? null : end;
            }

            var ignored = end > now + FutureEndLimit;
            decided = (end, ignored);
            if (ignored)
            {
                log.Warn("rca.end-ahead", "A session's stop recorded the capture's end ahead of this clock, so the RCA observer ignores it and captures on; the stop's export names what stays on this VM.", ("endedUtc", end), ("nowUtc", now));
                return null;
            }

            log.Info("rca.capture-ended", "A session's stop recorded the capture's end: the RCA observer ends its capture, and captures again once a profile is set after it.", ("endedUtc", end));
            return end;
        }
    }

    /// <summary>
    /// Whether the span's close waits for the answer key after the capture's end at <paramref name="end"/>: a fault run of a
    /// target this lane observes or notes that ended by then is still to be recorded (IObservationGate.HoldsAfter).
    /// </summary>
    private bool Holds(DateTimeOffset end)
    {
        try
        {
            // Every target this lane observes or notes: the answer key of any of them can hold the span's close.
            return observers.Select(o => o.Gate).Concat(noted).Distinct().Any(t => gate.HoldsAfter(t, end));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            log.Debug("rca.hold-failed", Redactor.Redact(ex.Message));
            return false;
        }
    }

    /// <summary>
    /// Closes the span whose close waited for the answer key (Release), once it no longer has to: checked every second, and
    /// whatever the answer key does, when the lane stops. It closes at the time its last member ended, so its coverage ends
    /// where the capture did. A close whose write fails is tried again a second later, and at the lane's stop for a few
    /// seconds at most (the re-check of 9440acf2: it ended this loop, and the lane's stop threw it).
    /// </summary>
    private async Task CloseHeldAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(1), time, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }

            bool held;
            lock (spanGate)
            {
                held = heldSince is not null;
            }

            if (held)
            {
                TryCloseHeld(CaptureEnd(time.GetUtcNow()) is { } end && Holds(end));
            }
        }

        for (var attempt = 1; !TryCloseHeld(holds: false); attempt++)
        {
            if (attempt >= StopCloseAttempts)
            {
                log.Warn("rca.span-left-open", "The RCA observer couldn't close its span as the lane stopped; once this runner has ended, the next export takes it as it was.");
                break;
            }

            await Task.Delay(TimeSpan.FromSeconds(1), time, CancellationToken.None).ConfigureAwait(false);
        }
    }

    /// <summary>CloseHeld, with a failed write of the span logged: false then, for the caller to try again.</summary>
    private bool TryCloseHeld(bool holds)
    {
        try
        {
            CloseHeld(holds);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log.Warn("rca.close-failed", "The RCA observer couldn't close the span that waited for the answer key; it tries again in a second.", ("error", Redactor.Redact(ex.Message)));
            return false;
        }
    }

    private void CloseHeld(bool holds)
    {
        lock (spanGate)
        {
            if (holds || span is null || members > 0 || heldSince is not { } since)
            {
                return;
            }

            span.Close(since);
            span = null;
            heldSince = null;
            log.Info("rca.span-closed", "The answer key has the fault runs that ended by the capture's end, so the span closed for the stop's export.");
        }
    }

    private ICaptureSpan? Acquire(string target, DateTimeOffset at)
    {
        lock (spanGate)
        {
            if (span is not null && heldSince is { } since)
            {
                // A session that began after the capture's end: the span that waits for the answer key is the stopped
                // session's, so it closes now, and the new session's capture goes into a span of its own. A close whose
                // write fails is tried again at the next tick (the re-check of 9440acf2: it ended the note loop).
                try
                {
                    span.Close(since);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    log.Warn("rca.close-failed", "The RCA observer couldn't close the span that waited for the answer key; it tries again in a second.", ("error", Redactor.Redact(ex.Message)));
                    return null;
                }

                span = null;
                heldSince = null;
            }

            if (span is null)
            {
                if (at < storeRetryAt)
                {
                    return null;
                }

                try
                {
                    span = store.Open(at);
                    lastEnded = null;
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

    /// <summary>
    /// A target's capture ended: the span closes once its last member has, except after the capture's end
    /// (<paramref name="end"/>) while the answer key still has to record a fault run that ended by then: its close waits for
    /// that, capturing nothing (CloseHeldAsync), so the stop's export takes those runs with it (the review of 1ca916a9).
    /// </summary>
    private void Release(string target, DateTimeOffset at, DateTimeOffset? end = null)
    {
        // Asked before the span's lock: the profile host answers under its lanes' own locks.
        var holds = end is { } ended && Holds(ended);
        lock (spanGate)
        {
            if (span is null)
            {
                return;
            }

            span.Ended(target, at);
            lastEnded = lastEnded is { } known && known > at ? known : at;
            if (--members <= 0)
            {
                members = 0;
                if (holds)
                {
                    heldSince = lastEnded;
                    log.Info("rca.span-held", "The RCA observer ended its capture at the session's stop; the span closes once the answer key has the fault runs that ended by then.");
                    return;
                }

                span.Close(at);
                span = null;
            }
        }
    }
}
