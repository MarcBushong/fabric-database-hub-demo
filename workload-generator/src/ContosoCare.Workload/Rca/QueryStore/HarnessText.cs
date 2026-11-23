using System.Text;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// The form in which the runner's own ad hoc statements (<see cref="HarnessStatements"/>) and the texts Query Store keeps
/// (RCA-SQL-16) are compared (rca/README.md, What the capture leaves out, 3). Generic: it names no object. In order:
/// <list type="number">
/// <item>comments dropped (<c>--</c> to the end of the line, and <c>/* */</c>);</item>
/// <item>trimmed;</item>
/// <item>a leading parameter declaration dropped: a balanced parenthesis that starts with <c>(@</c>, which Query Store
/// keeps before a parameterized statement (<c>(@run_id varchar(64))</c>, or simple parameterization's
/// <c>(@1 tinyint)</c>);</item>
/// <item>square brackets removed;</item>
/// <item>each string literal (<c>N'...'</c>, with <c>''</c> escapes), number literal (not within an identifier:
/// <c>datetime2</c> keeps its 2), and parameter (<c>@run_id</c>, <c>@1</c>) made one <c>?</c>;</item>
/// <item>the keyword <c>ASC</c> removed, any case;</item>
/// <item>lowercased (invariant);</item>
/// <item>all white space removed;</item>
/// <item>a final <c>;</c> dropped.</item>
/// </list>
/// </summary>
internal static class HarnessText
{
    public static string Normalize(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var bare = WithoutDeclaration(WithoutComments(text).Trim());
        bare = bare.Replace("[", string.Empty, StringComparison.Ordinal).Replace("]", string.Empty, StringComparison.Ordinal);
        var placed = Placeheld(bare).ToLowerInvariant();
        var compact = new StringBuilder(placed.Length);
        foreach (var c in placed)
        {
            if (!char.IsWhiteSpace(c))
            {
                compact.Append(c);
            }
        }

        if (compact.Length > 0 && compact[^1] == ';')
        {
            compact.Length--;
        }

        return compact.ToString();
    }

    /// <summary>The text without its comments, each replaced by a space; string literals and quoted names are kept as they are.</summary>
    private static string WithoutComments(string text)
    {
        var result = new StringBuilder(text.Length);
        var i = 0;
        while (i < text.Length)
        {
            var c = text[i];
            if (c is '\'' or '"' or '[')
            {
                var end = Closing(text, i, c == '[' ? ']' : c);
                result.Append(text, i, end - i);
                i = end;
            }
            else if (c == '-' && At(text, i + 1, '-'))
            {
                while (i < text.Length && text[i] is not ('\r' or '\n'))
                {
                    i++;
                }

                result.Append(' ');
            }
            else if (c == '/' && At(text, i + 1, '*'))
            {
                // Block comments nest in T-SQL.
                var depth = 0;
                do
                {
                    if (text[i] == '/' && At(text, i + 1, '*'))
                    {
                        depth++;
                        i += 2;
                    }
                    else if (text[i] == '*' && At(text, i + 1, '/'))
                    {
                        depth--;
                        i += 2;
                    }
                    else
                    {
                        i++;
                    }
                }
                while (depth > 0 && i < text.Length);
                result.Append(' ');
            }
            else
            {
                result.Append(c);
                i++;
            }
        }

        return result.ToString();
    }

    /// <summary>The text after a leading parameter declaration, a balanced <c>(@ ... )</c>; the text itself without one.</summary>
    private static string WithoutDeclaration(string text)
    {
        if (!text.StartsWith("(@", StringComparison.Ordinal))
        {
            return text;
        }

        var depth = 0;
        for (var i = 0; i < text.Length; i++)
        {
            if (text[i] == '(')
            {
                depth++;
            }
            else if (text[i] == ')' && --depth == 0)
            {
                return text[(i + 1)..];
            }
        }

        return text;
    }

    /// <summary>Literals and parameters made one <c>?</c> each, and the keyword ASC removed.</summary>
    private static string Placeheld(string text)
    {
        var result = new StringBuilder(text.Length);
        var i = 0;
        while (i < text.Length)
        {
            var c = text[i];
            if (c == '\'')
            {
                i = Closing(text, i, '\'');
                result.Append('?');
            }
            else if (c == '@' && At(text, i + 1, '@'))
            {
                // A system function (@@ROWCOUNT), not a parameter.
                var end = Word(text, i + 2);
                result.Append(text, i, end - i);
                i = end;
            }
            else if (c == '@')
            {
                i = Word(text, i + 1);
                result.Append('?');
            }
            else if (IsNumberStart(text, i))
            {
                i = NumberEnd(text, i);
                result.Append('?');
            }
            else if (IsWordStart(c))
            {
                var end = Word(text, i);
                var word = text.AsSpan(i, end - i);
                if (word is "N" or "n" && At(text, end, '\''))
                {
                    i = Closing(text, end, '\'');
                    result.Append('?');
                    continue;
                }

                if (!word.Equals("ASC", StringComparison.OrdinalIgnoreCase))
                {
                    result.Append(word);
                }

                i = end;
            }
            else
            {
                result.Append(c);
                i++;
            }
        }

        return result.ToString();
    }

    /// <summary>The index after a quoted part that opens at <paramref name="open"/>: a doubled closing character is an escape.</summary>
    private static int Closing(string text, int open, char close)
    {
        var i = open + 1;
        while (i < text.Length)
        {
            if (text[i] == close)
            {
                if (At(text, i + 1, close))
                {
                    i += 2;
                    continue;
                }

                return i + 1;
            }

            i++;
        }

        return text.Length;
    }

    private static int Word(string text, int start)
    {
        var i = start;
        while (i < text.Length && IsWordPart(text[i]))
        {
            i++;
        }

        return i;
    }

    private static bool IsNumberStart(string text, int i) =>
        (char.IsAsciiDigit(text[i]) || (text[i] == '.' && i + 1 < text.Length && char.IsAsciiDigit(text[i + 1])))
        && (i == 0 || !IsWordPart(text[i - 1]));

    private static int NumberEnd(string text, int start)
    {
        var i = start;
        if (text[i] == '0' && i + 1 < text.Length && text[i + 1] is 'x' or 'X')
        {
            i += 2;
            while (i < text.Length && char.IsAsciiHexDigit(text[i]))
            {
                i++;
            }

            return i;
        }

        while (i < text.Length && char.IsAsciiDigit(text[i]))
        {
            i++;
        }

        if (i < text.Length && text[i] == '.')
        {
            i++;
            while (i < text.Length && char.IsAsciiDigit(text[i]))
            {
                i++;
            }
        }

        if (i < text.Length && text[i] is 'e' or 'E')
        {
            var exponent = i + 1;
            if (exponent < text.Length && text[exponent] is '+' or '-')
            {
                exponent++;
            }

            if (exponent < text.Length && char.IsAsciiDigit(text[exponent]))
            {
                i = exponent;
                while (i < text.Length && char.IsAsciiDigit(text[i]))
                {
                    i++;
                }
            }
        }

        return i;
    }

    private static bool IsWordStart(char c) => char.IsLetter(c) || c is '_' or '#';

    private static bool IsWordPart(char c) => char.IsLetterOrDigit(c) || c is '_' or '#' or '$' or '@';

    private static bool At(string text, int index, char expected) => index < text.Length && text[index] == expected;
}
