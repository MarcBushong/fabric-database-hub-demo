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
/// <see cref="Statements"/> splits a batch into the statements Query Store keeps of it, each compared in that form.
/// </summary>
internal static class HarnessText
{
    /// <summary>The keywords that start a statement: an <c>IF</c>'s condition ends before the first of them outside parentheses.</summary>
    private static readonly HashSet<string> StatementKeywords = new(StringComparer.Ordinal)
    {
        "ALTER", "BACKUP", "BEGIN", "BREAK", "BULK", "CHECKPOINT", "CLOSE", "COMMIT", "CONTINUE", "CREATE", "DBCC",
        "DEALLOCATE", "DECLARE", "DELETE", "DENY", "DISABLE", "DROP", "ENABLE", "EXEC", "EXECUTE", "FETCH", "GOTO", "GRANT",
        "IF", "INSERT", "KILL", "MERGE", "OPEN", "PRINT", "RAISERROR", "RECONFIGURE", "RESTORE", "RETURN", "REVOKE",
        "ROLLBACK", "SAVE", "SELECT", "SET", "THROW", "TRUNCATE", "UPDATE", "USE", "WAITFOR", "WHILE", "WITH",
    };

    private enum TokenKind
    {
        Word,
        Name,
        Variable,
        Literal,
        Symbol,
    }

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

    /// <summary>
    /// A batch's statements as Query Store keeps them, each a query of its own (rca/README.md, What the capture leaves out,
    /// 1): the batch split at each <c>;</c> outside a comment, a literal, a quoted name, or parentheses. A session option
    /// (<c>SET NOCOUNT ON</c>, <c>SET LOCK_TIMEOUT 1000</c>) isn't one: Query Store keeps no query for it, and every
    /// connection sends it. An <c>IF</c> gives its condition, from <c>IF</c> to the first statement keyword outside
    /// parentheses, which the engine evaluates as a statement of its own; then its body's statements; then the whole, in case
    /// the engine keeps it as one text. Generic, as <see cref="Normalize"/> is. A <c>BEGIN</c> ... <c>END</c> block isn't
    /// split as the engine splits it, so the runner's tests check every batch the runner takes statements from.
    /// </summary>
    public static IReadOnlyList<string> Statements(string batch)
    {
        ArgumentNullException.ThrowIfNull(batch);
        var statements = new List<string>();
        var start = 0;
        var depth = 0;
        foreach (var (begin, end, kind) in Tokens(batch))
        {
            if (kind != TokenKind.Symbol)
            {
                continue;
            }

            switch (batch[begin])
            {
                case '(':
                    depth++;
                    break;
                case ')':
                    depth = Math.Max(0, depth - 1);
                    break;
                case ';' when depth == 0:
                    AddStatement(statements, batch[start..begin]);
                    start = end;
                    break;
            }
        }

        AddStatement(statements, batch[start..]);
        return statements;
    }

    /// <summary>One statement's texts, as <see cref="Statements"/> gives them: none for a session option; for an <c>IF</c>, its condition, its body's, and the whole.</summary>
    private static void AddStatement(List<string> statements, string text)
    {
        var tokens = Tokens(text).ToList();
        if (tokens.Count == 0)
        {
            return;
        }

        var first = Keyword(text, tokens[0]);
        if (first == "ELSE")
        {
            AddStatement(statements, text[tokens[0].End..]);
            return;
        }

        if (first == "SET" && (tokens.Count < 2 || tokens[1].Kind != TokenKind.Variable))
        {
            return;
        }

        if (first == "IF")
        {
            var depth = 0;
            for (var i = 1; i < tokens.Count; i++)
            {
                var (begin, _, kind) = tokens[i];
                if (kind == TokenKind.Symbol && text[begin] == '(')
                {
                    depth++;
                }
                else if (kind == TokenKind.Symbol && text[begin] == ')')
                {
                    depth = Math.Max(0, depth - 1);
                }
                else if (depth == 0 && StatementKeywords.Contains(Keyword(text, tokens[i])))
                {
                    statements.Add(text[..begin].Trim());
                    AddStatement(statements, text[begin..]);
                    statements.Add(text.Trim());
                    return;
                }
            }
        }

        statements.Add(text.Trim());
    }

    /// <summary>A word token's text in upper case, the keyword it is; empty for any other token.</summary>
    private static string Keyword(string text, (int Start, int End, TokenKind Kind) token) =>
        token.Kind == TokenKind.Word ? text[token.Start..token.End].ToUpperInvariant() : string.Empty;

    /// <summary>The text's tokens, comments and white space left out: words, quoted names, variables, literals, and single symbols.</summary>
    private static IEnumerable<(int Start, int End, TokenKind Kind)> Tokens(string text)
    {
        var i = 0;
        while (i < text.Length)
        {
            var c = text[i];
            var start = i;
            if (char.IsWhiteSpace(c))
            {
                i++;
            }
            else if (c == '-' && At(text, i + 1, '-'))
            {
                i = LineCommentEnd(text, i);
            }
            else if (c == '/' && At(text, i + 1, '*'))
            {
                i = BlockCommentEnd(text, i);
            }
            else if (c == '\'' || (c is 'N' or 'n' && At(text, i + 1, '\'')))
            {
                i = Closing(text, c == '\'' ? i : i + 1, '\'');
                yield return (start, i, TokenKind.Literal);
            }
            else if (c is '"' or '[')
            {
                i = Closing(text, i, c == '[' ? ']' : '"');
                yield return (start, i, TokenKind.Name);
            }
            else if (c == '@' && !At(text, i + 1, '@'))
            {
                i = Word(text, i + 1);
                yield return (start, i, TokenKind.Variable);
            }
            else if (c == '@')
            {
                i = Word(text, i + 2);
                yield return (start, i, TokenKind.Word);
            }
            else if (IsNumberStart(text, i))
            {
                i = NumberEnd(text, i);
                yield return (start, i, TokenKind.Literal);
            }
            else if (IsWordStart(c))
            {
                i = Word(text, i);
                yield return (start, i, TokenKind.Word);
            }
            else
            {
                i++;
                yield return (start, i, TokenKind.Symbol);
            }
        }
    }

    /// <summary>The index of the line break that ends a <c>--</c> comment, or the text's end.</summary>
    private static int LineCommentEnd(string text, int start)
    {
        var i = start;
        while (i < text.Length && text[i] is not ('\r' or '\n'))
        {
            i++;
        }

        return i;
    }

    /// <summary>The index after a <c>/* */</c> comment that opens at <paramref name="start"/>: block comments nest in T-SQL.</summary>
    private static int BlockCommentEnd(string text, int start)
    {
        var i = start;
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
        return i;
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
                i = LineCommentEnd(text, i);
                result.Append(' ');
            }
            else if (c == '/' && At(text, i + 1, '*'))
            {
                i = BlockCommentEnd(text, i);
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
