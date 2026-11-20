using System.Text;
using System.Text.RegularExpressions;
using ContosoCare.Workload.Diagnostics;

namespace ContosoCare.Workload.Rca.Observer;

/// <summary>
/// Normalizes text before the observer stores it (ADR 0031, Redaction and privacy): string, number, date, binary, and
/// GUID literals become <c>?</c>, IPv4 and IPv6 addresses <c>&lt;ip&gt;</c>, comments and runs of white space go, and a
/// statement keeps at most 2,000 characters and a detail 1,000. Then the runner's redaction runs, and a value that still
/// looks like a secret is dropped (null). Identifiers, variables (<c>@parent</c>), and PostgreSQL's positional
/// parameters (<c>$1</c>) stay: they're the statement's shape, which a DBA reads.
/// </summary>
internal static partial class TextNormalizer
{
    public const int StatementLength = 2000;

    public const int DetailLength = 1000;

    /// <summary>A statement, a batch, or an event's SQL text.</summary>
    public static string? Statement(string? text) => Finish(Sql(Addresses(text), keepNumbers: false), StatementLength);

    /// <summary>An RPC's input buffer (<c>procedure;1</c>): its name and number stay, as SQL Server reports them.</summary>
    public static string? RpcName(string? text) => Finish(Sql(Addresses(text), keepNumbers: true), StatementLength);

    /// <summary>A message the server wrote (an error's text): quoted values, numbers, dates, and GUIDs become <c>?</c>.</summary>
    public static string? Message(string? text) => Finish(MessageLiterals(Addresses(text)), DetailLength);

    /// <summary>The observer's own words, built from counts and names it read: only the cap, the redaction, and the secret check.</summary>
    public static string? Detail(string? text) => Finish(Addresses(text), DetailLength);

    /// <summary>An object, index, or module name as the catalog returns it: the redaction and the secret check, at most 256 characters.</summary>
    public static string? Name(string? text) => Finish(text, 256);

    /// <summary>True when a value, after the redaction, still looks like a credential: a secret-named key with a value, or a long random token.</summary>
    public static bool LooksLikeSecret(string text)
    {
        foreach (Match match in SecretAssignment().Matches(text))
        {
            var value = match.Groups["value"].Value;
            if (!(value.StartsWith('?') || value.StartsWith('@') || value.StartsWith('$') || value.StartsWith(':') || value.StartsWith("[REDACTED", StringComparison.Ordinal)))
            {
                return true;
            }
        }

        foreach (Match match in LongToken().Matches(text))
        {
            var token = match.Value;
            var classes = (token.Any(char.IsAsciiLetterUpper) ? 1 : 0) + (token.Any(char.IsAsciiLetterLower) ? 1 : 0) + (token.Any(char.IsAsciiDigit) ? 1 : 0);
            if (classes == 3)
            {
                return true;
            }
        }

        return false;
    }

    private static string? Finish(string? text, int maximum)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }

        var collapsed = WhiteSpace().Replace(text, " ").Trim();
        if (collapsed.Length > maximum)
        {
            collapsed = collapsed[..(maximum - 3)].TrimEnd() + "...";
        }

        var redacted = Redactor.Redact(collapsed);
        if (redacted.Length > maximum)
        {
            redacted = redacted[..(maximum - 3)] + "...";
        }

        return redacted.Length == 0 || LooksLikeSecret(redacted) ? null : redacted;
    }

    /// <summary>IPv4 and IPv6 addresses become &lt;ip&gt;, before any other rule sees their digits.</summary>
    private static string? Addresses(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return text;
        }

        var result = Ipv4().Replace(text, "<ip>");
        result = Ipv6Full().Replace(result, "<ip>");
        return Ipv6Compressed().Replace(result, match => match.Value.Count(c => c == ':') >= 2 && match.Value.Any(char.IsAsciiHexDigit) ? "<ip>" : match.Value);
    }

    private static string? MessageLiterals(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return text;
        }

        var result = QuotedText().Replace(text, "?");
        result = Guid().Replace(result, "?");
        result = DateTimeLiteral().Replace(result, "?");
        result = HexLiteral().Replace(result, "?");
        return MessageNumber().Replace(result, "?");
    }

    /// <summary>
    /// One pass over SQL text: comments go; string literals (N'..', E'..', $tag$..$tag$), binary literals (0x..), and
    /// numbers become ?; quoted and bracketed identifiers, names, variables, and $1 parameters are copied as they are.
    /// </summary>
    private static string? Sql(string? text, bool keepNumbers)
    {
        if (string.IsNullOrEmpty(text))
        {
            return text;
        }

        var output = new StringBuilder(text.Length);
        var i = 0;
        while (i < text.Length)
        {
            var c = text[i];
            var next = i + 1 < text.Length ? text[i + 1] : '\0';
            if (c == '-' && next == '-')
            {
                while (i < text.Length && text[i] != '\n')
                {
                    i++;
                }

                output.Append(' ');
                continue;
            }

            if (c == '/' && next == '*')
            {
                i = SkipBlockComment(text, i);
                output.Append(' ');
                continue;
            }

            if (c == '\'')
            {
                // N'..' and E'..' lose their prefix with the literal.
                if (output.Length > 0 && output[^1] is 'N' or 'n' or 'E' or 'e' && (output.Length == 1 || !IsIdentifierPart(output[^2])))
                {
                    var escapes = output[^1] is 'E' or 'e';
                    output.Length--;
                    i = SkipQuoted(text, i, '\'', escapes);
                }
                else
                {
                    i = SkipQuoted(text, i, '\'', backslashEscapes: false);
                }

                output.Append('?');
                continue;
            }

            if (c == '$')
            {
                if (char.IsAsciiDigit(next))
                {
                    // A positional parameter ($1): the statement's shape.
                    output.Append(c);
                    i++;
                    while (i < text.Length && char.IsAsciiDigit(text[i]))
                    {
                        output.Append(text[i]);
                        i++;
                    }

                    continue;
                }

                var close = DollarQuoteEnd(text, i);
                if (close > i)
                {
                    output.Append('?');
                    i = close;
                    continue;
                }

                output.Append(c);
                i++;
                continue;
            }

            if (c == '"')
            {
                var end = SkipQuoted(text, i, '"', backslashEscapes: false);
                output.Append(text, i, end - i);
                i = end;
                continue;
            }

            if (c == '[')
            {
                var end = SkipBracketed(text, i);
                output.Append(text, i, end - i);
                i = end;
                continue;
            }

            if (IsIdentifierStart(c))
            {
                var start = i;
                while (i < text.Length && IsIdentifierPart(text[i]))
                {
                    i++;
                }

                output.Append(text, start, i - start);
                continue;
            }

            if (c == '0' && next is 'x' or 'X')
            {
                i += 2;
                while (i < text.Length && char.IsAsciiHexDigit(text[i]))
                {
                    i++;
                }

                output.Append('?');
                continue;
            }

            if (char.IsAsciiDigit(c) || (c == '.' && char.IsAsciiDigit(next) && (output.Length == 0 || !IsIdentifierPart(output[^1]))))
            {
                var start = i;
                i = SkipNumber(text, i);
                if (keepNumbers)
                {
                    output.Append(text, start, i - start);
                }
                else
                {
                    output.Append('?');
                }

                continue;
            }

            output.Append(c);
            i++;
        }

        return output.ToString();
    }

    private static int SkipBlockComment(string text, int start)
    {
        // T-SQL and PostgreSQL both nest block comments.
        var depth = 0;
        var i = start;
        while (i < text.Length)
        {
            if (text[i] == '/' && i + 1 < text.Length && text[i + 1] == '*')
            {
                depth++;
                i += 2;
            }
            else if (text[i] == '*' && i + 1 < text.Length && text[i + 1] == '/')
            {
                depth--;
                i += 2;
                if (depth == 0)
                {
                    return i;
                }
            }
            else
            {
                i++;
            }
        }

        return i;
    }

    private static int SkipQuoted(string text, int start, char quote, bool backslashEscapes)
    {
        var i = start + 1;
        while (i < text.Length)
        {
            if (backslashEscapes && text[i] == '\\')
            {
                i += 2;
                continue;
            }

            if (text[i] == quote)
            {
                if (i + 1 < text.Length && text[i + 1] == quote)
                {
                    i += 2;
                    continue;
                }

                return i + 1;
            }

            i++;
        }

        return i;
    }

    private static int SkipBracketed(string text, int start)
    {
        var i = start + 1;
        while (i < text.Length)
        {
            if (text[i] == ']')
            {
                if (i + 1 < text.Length && text[i + 1] == ']')
                {
                    i += 2;
                    continue;
                }

                return i + 1;
            }

            i++;
        }

        return i;
    }

    /// <summary>The end of a dollar-quoted string ($$..$$ or $tag$..$tag$) that starts at <paramref name="start"/>, or <paramref name="start"/> when there's none.</summary>
    private static int DollarQuoteEnd(string text, int start)
    {
        var i = start + 1;
        while (i < text.Length && (char.IsAsciiLetterOrDigit(text[i]) || text[i] == '_'))
        {
            i++;
        }

        if (i >= text.Length || text[i] != '$' || (i > start + 1 && char.IsAsciiDigit(text[start + 1])))
        {
            return start;
        }

        var tag = text[start..(i + 1)];
        var close = text.IndexOf(tag, i + 1, StringComparison.Ordinal);
        return close < 0 ? text.Length : close + tag.Length;
    }

    private static int SkipNumber(string text, int start)
    {
        var i = start;
        while (i < text.Length && (char.IsAsciiDigit(text[i]) || text[i] == '.'))
        {
            i++;
        }

        if (i < text.Length && text[i] is 'e' or 'E' && i + 1 < text.Length && (char.IsAsciiDigit(text[i + 1]) || (text[i + 1] is '+' or '-' && i + 2 < text.Length && char.IsAsciiDigit(text[i + 2]))))
        {
            i += 2;
            while (i < text.Length && char.IsAsciiDigit(text[i]))
            {
                i++;
            }
        }

        return i;
    }

    private static bool IsIdentifierStart(char c) => char.IsLetter(c) || c is '_' or '@' or '#';

    private static bool IsIdentifierPart(char c) => char.IsLetterOrDigit(c) || c is '_' or '@' or '#' or '$';

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhiteSpace();

    [GeneratedRegex(@"(?<![\w.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\w.])")]
    private static partial Regex Ipv4();

    [GeneratedRegex(@"(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(?![\w:])")]
    private static partial Regex Ipv6Full();

    [GeneratedRegex(@"(?<![\w:])(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?::(?:[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){0,6})?(?![\w:])")]
    private static partial Regex Ipv6Compressed();

    [GeneratedRegex(@"N?'(?:[^']|'')*'|""(?:[^""]|"""")*""")]
    private static partial Regex QuotedText();

    [GeneratedRegex(@"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")]
    private static partial Regex Guid();

    [GeneratedRegex(@"\b\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?\b|\b\d{1,2}:\d{2}:\d{2}(?:\.\d+)?\b")]
    private static partial Regex DateTimeLiteral();

    [GeneratedRegex(@"\b0[xX][0-9A-Fa-f]+\b")]
    private static partial Regex HexLiteral();

    [GeneratedRegex(@"(?<![\w.$@#])\d+(?:[.,]\d+)*(?![\w])")]
    private static partial Regex MessageNumber();

    [GeneratedRegex(@"(?i)\b(?:password|passwd|pwd|secret|client_?secret|api_?key|access_?key|account_?key|shared_?access_?key|token|sig)\b\s*(?:=|:)\s*(?<value>[^\s;,)]{4,})")]
    private static partial Regex SecretAssignment();

    [GeneratedRegex(@"[A-Za-z0-9+/_=-]{40,}")]
    private static partial Regex LongToken();
}
