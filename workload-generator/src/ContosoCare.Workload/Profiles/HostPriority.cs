using System.Diagnostics;
using ContosoCare.Workload.Diagnostics;

namespace ContosoCare.Workload.Profiles;

/// <summary>
/// The profile host's process priority (the showcase, 2026-11-03). On T1 the host drives T3 and T4 too, so a CPU slot on
/// T1 mustn't starve their lanes (Phase 25d: capacity-max on T1 kept T4's baseline from connecting). The host raises
/// itself one step, to above normal, on Windows; SQL Server runs at normal priority, and the host itself uses little CPU.
/// Source: https://learn.microsoft.com/dotnet/api/system.diagnostics.process.priorityclass
/// </summary>
internal static class HostPriority
{
    /// <summary>Raises this process on Windows; returns the priority it runs at, or null elsewhere or when it couldn't be read.</summary>
    public static ProcessPriorityClass? RaiseCurrent(RunnerLog log)
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        using var self = Process.GetCurrentProcess();
        return Raise(() => self.PriorityClass, value => self.PriorityClass = value, log);
    }

    /// <summary>Raises a priority below above-normal to above-normal and leaves a higher one alone; a refusal is logged, and the priority stays as it was.</summary>
    internal static ProcessPriorityClass? Raise(Func<ProcessPriorityClass> get, Action<ProcessPriorityClass> set, RunnerLog log)
    {
        try
        {
            var current = get();
            if (current is ProcessPriorityClass.Idle or ProcessPriorityClass.BelowNormal or ProcessPriorityClass.Normal)
            {
                set(ProcessPriorityClass.AboveNormal);
                current = get();
            }

            log.Info("profile.priority", "The profile host runs at this priority, so a CPU incident on this VM doesn't starve its other lanes.", ("priority", current));
            return current;
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or NotSupportedException)
        {
            log.Warn("profile.priority-unchanged", "The profile host's priority couldn't be raised; it runs as it was started.", ("error", ex.Message));
            return null;
        }
    }
}
