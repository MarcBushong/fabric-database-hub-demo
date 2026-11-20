using System.Security.Cryptography;
using System.Text;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>What the evidence keeps of a session's application name (rca/README.md, Names).</summary>
/// <param name="Program">The name as a DBA would see it, without the workload's internal segments; null for any other session.</param>
/// <param name="RunToken">An opaque token that groups one run's sessions and names nothing; null when there's no run segment.</param>
/// <param name="IsDemo">True for the workload's own sessions, which keep their text, login, and host.</param>
/// <param name="IsObserver">True for the observer's own sessions, which the capture leaves out.</param>
internal sealed record ReducedName(string? Program, string? RunToken, bool IsDemo, bool IsObserver)
{
    public static readonly ReducedName Other = new(null, null, false, false);
}

/// <summary>
/// The one place in the observer that knows the workload's application-name prefix (rca/blind-detection.json's only
/// exception). A workload session's application name names the fault it belongs to, so the evidence keeps only the
/// program, <c>ContosoCare.Demo</c>, and a run token: the first 12 lowercase hex characters of SHA-256 over the UTF-8
/// bytes of <c>ContosoCare.RcaRunToken:&lt;run&gt;</c>, the name's last segment. The middle segment never reaches the
/// evidence. Any other session's name is kept out entirely.
/// </summary>
internal static class ApplicationNames
{
    /// <summary>The program name the evidence keeps for every workload session.</summary>
    public const string Program = "ContosoCare.Demo";

    private const string Prefix = Program + "/";

    private const string TokenSalt = "ContosoCare.RcaRunToken:";

    /// <summary>
    /// The observer's own sessions (ADR 0031): a control name, so demo.fn_demo_sessions and the kill tools never list or
    /// end them, and the capture recognizes and leaves them out.
    /// </summary>
    public static string Observer => Prefix + "control/rca";

    public static ReducedName Reduce(string? applicationName)
    {
        if (string.IsNullOrEmpty(applicationName) || !applicationName.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase))
        {
            return ReducedName.Other;
        }

        if (string.Equals(applicationName, Observer, StringComparison.OrdinalIgnoreCase))
        {
            return new ReducedName(Program, null, true, true);
        }

        var rest = applicationName[Prefix.Length..];
        var separator = rest.LastIndexOf('/');
        var run = separator >= 0 ? rest[(separator + 1)..] : string.Empty;
        return new ReducedName(Program, run.Length > 0 ? RunToken(run) : null, true, false);
    }

    /// <summary>The run token of one run segment (rca/README.md, Names); the answer key carries the same token.</summary>
    public static string RunToken(string run)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(TokenSalt + run));
        return Convert.ToHexStringLower(hash)[..12];
    }
}
