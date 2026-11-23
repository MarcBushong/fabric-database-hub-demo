using System.Globalization;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>What RCA Query Plans keeps of a showplan: its shape in words, its estimated cost, and whether it's parallel.</summary>
internal sealed record PlanShape(string? Summary, double? EstimatedCost, bool Parallel);

/// <summary>
/// Reduces a showplan (sys.query_store_plan.query_plan, which Query Store keeps as text) to its shape in words
/// (rca/README.md, Query Store): its three costliest operators by their own estimated cost, each with the object and
/// index it reads or writes and its share of the statement's cost; parallel or not; its warnings; and the missing index
/// with the highest impact. It reads only operator, object, index, and column names, costs, flags, and the kinds of the
/// warnings: never a statement's text, a scalar expression, or a parameter's compiled value, so no value a query ran
/// with reaches the evidence. The showplan schema:
/// https://learn.microsoft.com/sql/relational-databases/showplan-logical-and-physical-operators-reference.
/// </summary>
internal static partial class PlanSummary
{
    /// <summary>A showplan longer than this (in characters) isn't reduced.</summary>
    public const int MaximumXmlLength = 8 * 1024 * 1024;

    private const int TopOperators = 3;

    private static readonly XNamespace Showplan = "http://schemas.microsoft.com/sqlserver/2004/07/showplan";

    /// <summary>The plan's shape, or null with <paramref name="problem"/> saying why it couldn't be read.</summary>
    public static PlanShape? Reduce(string? xml, out string? problem)
    {
        problem = null;
        if (string.IsNullOrWhiteSpace(xml))
        {
            problem = "Query Store returned no showplan for it";
            return null;
        }

        if (xml.Length > MaximumXmlLength)
        {
            problem = string.Create(CultureInfo.InvariantCulture, $"its showplan has {xml.Length:N0} characters, more than the {MaximumXmlLength:N0} the observer reduces");
            return null;
        }

        XElement root;
        try
        {
            var settings = new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Prohibit,
                XmlResolver = null,
                IgnoreComments = true,
                IgnoreProcessingInstructions = true,
                IgnoreWhitespace = true,
                MaxCharactersInDocument = MaximumXmlLength,
            };
            using var reader = XmlReader.Create(new StringReader(xml), settings);
            root = XDocument.Load(reader).Root ?? throw new XmlException("The document has no root.");
        }
        catch (XmlException ex)
        {
            problem = "its showplan isn't XML the observer can read (" + ex.Message + ")";
            return null;
        }

        if (root.Name != Showplan + "ShowPlanXML")
        {
            problem = "its showplan isn't a ShowPlanXML document";
            return null;
        }

        var plans = root.Descendants(Showplan + "QueryPlan").ToList();
        if (plans.Count == 0)
        {
            problem = "its showplan holds no query plan";
            return null;
        }

        var cost = StatementCost(plans);
        var operators = Operators(root);
        var parallel = operators.Any(o => IsTrue(o.Element.Attribute("Parallel"))) || plans.Any(p => (Number(p.Attribute("DegreeOfParallelism")) ?? 0) > 1);
        var parts = new List<string>();
        if (Costliest(operators, cost) is { Length: > 0 } costliest)
        {
            parts.Add(costliest);
        }

        if (parallel)
        {
            parts.Add("Parallel");
        }
        else if (plans.Select(p => (string?)p.Attribute("NonParallelPlanReason")).FirstOrDefault(r => !string.IsNullOrWhiteSpace(r)) is { } reason)
        {
            parts.Add("Serial: " + Words(reason));
        }

        var warnings = Warnings(plans, operators);
        if (warnings.Count > 0)
        {
            parts.Add("Warnings: " + string.Join(", ", warnings));
        }

        if (MissingIndex(root) is { } missing)
        {
            parts.Add(missing);
        }

        var summary = parts.Count == 0 ? null : TextNormalizer.Detail(string.Join(". ", parts) + ".");
        return new PlanShape(summary, cost is { } total ? Math.Round(total, 6) : null, parallel);
    }

    /// <summary>The statements' estimated cost (StatementSubTreeCost), summed over the statements that have a plan.</summary>
    private static double? StatementCost(List<XElement> plans)
    {
        double? total = null;
        foreach (var statement in plans.Select(p => p.Ancestors().FirstOrDefault(a => a.Attribute("StatementSubTreeCost") is not null)).OfType<XElement>().Distinct())
        {
            if (Number(statement.Attribute("StatementSubTreeCost")) is { } cost)
            {
                total = (total ?? 0) + cost;
            }
        }

        return total;
    }

    /// <summary>Every operator with its own estimated cost: its subtree's less its children's, the nearest RelOps below it.</summary>
    private static List<(XElement Element, double Own, int Node)> Operators(XElement root)
    {
        var elements = root.Descendants(Showplan + "RelOp").ToList();
        var own = elements.ToDictionary(e => e, e => Number(e.Attribute("EstimatedTotalSubtreeCost")) ?? 0);
        foreach (var element in elements)
        {
            if (element.Ancestors(Showplan + "RelOp").FirstOrDefault() is { } parent && own.ContainsKey(parent))
            {
                own[parent] -= Number(element.Attribute("EstimatedTotalSubtreeCost")) ?? 0;
            }
        }

        return [.. elements.Select((e, i) => (e, Math.Max(0, own[e]), (int?)Number(e.Attribute("NodeId")) ?? i))];
    }

    /// <summary>
    /// The three costliest operators, by their own cost: <c>Index Seek on [care].[visits].[ix_visits_patient] seeking
    /// patient_id (62 % of the cost); Key Lookup on [care].[visits].[pk_visits] for status (30 %)</c>.
    /// </summary>
    private static string Costliest(List<(XElement Element, double Own, int Node)> operators, double? total)
    {
        var shares = total is > 0;
        var top = operators
            .Where(o => !shares || o.Own > 0)
            .OrderByDescending(o => shares ? o.Own : 0)
            .ThenBy(o => o.Node)
            .Take(TopOperators)
            .Select((o, i) =>
            {
                var text = OperatorName(o.Element);
                if (ObjectName(o.Element) is { } name)
                {
                    text += " on " + name;
                }

                if (Details(o.Element) is { } details)
                {
                    text += " " + details;
                }

                return shares ? string.Create(CultureInfo.InvariantCulture, $"{text} ({Math.Round(o.Own / total!.Value * 100, MidpointRounding.AwayFromZero):0} %{(i == 0 ? " of the cost" : string.Empty)})") : text;
            });
        return string.Join("; ", top);
    }

    /// <summary>The columns an operator seeks, fetches, sorts, or filters on, by name: never the values it compares them with.</summary>
    private static string? Details(XElement relOp)
    {
        var parts = new List<string>();
        foreach (var operation in relOp.Elements())
        {
            if (operation.Element(Showplan + "SeekPredicates") is { } seek && Columns(seek) is { } seeking)
            {
                parts.Add("seeking " + seeking);
            }

            if (IsTrue(operation.Attribute("Lookup")) && relOp.Element(Showplan + "OutputList") is { } output && Columns(output) is { } fetched)
            {
                parts.Add("for " + fetched);
            }

            if (operation.Element(Showplan + "OrderBy") is { } order && Columns(order) is { } sorted)
            {
                parts.Add("by " + sorted);
            }

            if (operation.Element(Showplan + "Predicate") is { } predicate && Columns(predicate) is { } filtered)
            {
                parts.Add("filtering on " + filtered);
            }
        }

        return parts.Count == 0 ? null : string.Join(", ", parts);
    }

    /// <summary>A table's columns under <paramref name="scope"/>, at most four: a variable or a parameter (@name) and the plan's own expressions aren't columns.</summary>
    private static string? Columns(XElement scope)
    {
        var names = scope.Descendants(Showplan + "ColumnReference")
            .Where(c => c.Attribute("Table") is not null)
            .Select(c => ((string?)c.Attribute("Column"))?.Trim('[', ']'))
            .OfType<string>()
            .Where(n => n.Length > 0 && n[0] != '@')
            .Distinct(StringComparer.Ordinal)
            .Take(4)
            .ToList();
        return names.Count switch
        {
            0 => null,
            1 => names[0],
            2 => names[0] + " and " + names[1],
            _ => string.Join(", ", names),
        };
    }

    private static string OperatorName(XElement relOp)
    {
        var physical = (string?)relOp.Attribute("PhysicalOp") ?? "An operator";
        if (relOp.Elements(Showplan + "IndexScan").Any(s => IsTrue(s.Attribute("Lookup"))))
        {
            return "Key Lookup";
        }

        var logical = (string?)relOp.Attribute("LogicalOp");
        return logical is { Length: > 0 } && !physical.Contains(logical, StringComparison.Ordinal) ? $"{physical} ({logical})" : physical;
    }

    /// <summary>The object and index an operator reads or writes, as the plan names them: <c>[care].[visits].[ix_visits_patient]</c>.</summary>
    private static string? ObjectName(XElement relOp)
    {
        var item = relOp.Elements().Elements(Showplan + "Object").FirstOrDefault();
        if (item is null || TableName(item) is not { } table)
        {
            return null;
        }

        return (string?)item.Attribute("Index") is { Length: > 0 } index ? table + "." + index : table;
    }

    private static string? TableName(XElement item)
    {
        var table = (string?)item.Attribute("Table");
        if (string.IsNullOrWhiteSpace(table))
        {
            return null;
        }

        // A temporary table's name carries a suffix of underscores and a number per session: the name it was created with stays.
        table = TemporarySuffix().Replace(table, "]");
        return (string?)item.Attribute("Schema") is { Length: > 0 } schema ? schema + "." + table : table;
    }

    /// <summary>The plan's warnings by kind (the plan's own, then each operator's with its name), each once.</summary>
    private static List<string> Warnings(List<XElement> plans, List<(XElement Element, double Own, int Node)> operators)
    {
        var found = new List<string>();
        foreach (var warnings in plans.SelectMany(p => p.Elements(Showplan + "Warnings")))
        {
            found.AddRange(WarningKinds(warnings));
        }

        foreach (var (element, _, _) in operators)
        {
            foreach (var warnings in element.Elements(Showplan + "Warnings"))
            {
                found.AddRange(WarningKinds(warnings).Select(w => $"{w} at {OperatorName(element)}"));
            }
        }

        return [.. found.Distinct(StringComparer.Ordinal)];
    }

    private static IEnumerable<string> WarningKinds(XElement warnings)
    {
        foreach (var flag in warnings.Attributes().Where(a => IsTrue(a)))
        {
            yield return Words(flag.Name.LocalName);
        }

        foreach (var warning in warnings.Elements())
        {
            yield return warning.Name.LocalName switch
            {
                "PlanAffectingConvert" => "an implicit conversion affecting the " + ((string?)warning.Attribute("ConvertIssue") is { Length: > 0 } issue ? issue.ToLowerInvariant() : "plan"),
                "MemoryGrantWarning" => "a memory grant warning" + ((string?)warning.Attribute("GrantWarningKind") is { Length: > 0 } kind ? $" ({kind.ToLowerInvariant()})" : string.Empty),
                "SpillToTempDb" => "a spill to tempdb",
                "ColumnsWithNoStatistics" => "columns without statistics",
                "ColumnsWithStaleStatistics" => "columns with stale statistics",
                var other => Words(other),
            };
        }
    }

    /// <summary>The missing index with the highest impact: its table, key columns (equality, then inequality), and included ones.</summary>
    private static string? MissingIndex(XElement root)
    {
        var groups = root.Descendants(Showplan + "MissingIndexGroup")
            .Select(g => (Impact: Number(g.Attribute("Impact")) ?? 0, Index: g.Element(Showplan + "MissingIndex")))
            .Where(g => g.Index is not null && TableName(g.Index) is not null)
            .OrderByDescending(g => g.Impact)
            .ToList();
        if (groups.Count == 0)
        {
            return null;
        }

        var (impact, index) = groups[0];
        string Columns(params string[] usages) => string.Join(", ", index!.Elements(Showplan + "ColumnGroup")
            .Where(c => usages.Contains((string?)c.Attribute("Usage"), StringComparer.OrdinalIgnoreCase))
            .SelectMany(c => c.Elements(Showplan + "Column"))
            .Select(c => (string?)c.Attribute("Name"))
            .Where(n => !string.IsNullOrWhiteSpace(n)));
        var keys = Columns("EQUALITY", "INEQUALITY");
        var included = Columns("INCLUDE");
        var text = string.Create(CultureInfo.InvariantCulture, $"Missing index (impact {Math.Round(impact, MidpointRounding.AwayFromZero):0} %) on {TableName(index!)} ({keys})");
        if (included.Length > 0)
        {
            text += $" including ({included})";
        }

        return groups.Count > 1 ? string.Create(CultureInfo.InvariantCulture, $"{text}, and {groups.Count - 1} more") : text;
    }

    /// <summary>A showplan name in words: <c>NoJoinPredicate</c> becomes <c>no join predicate</c>, <c>MaxDOPSetToOne</c> <c>max dop set to one</c>.</summary>
    private static string Words(string name) => WordBoundary().Replace(name, " ").Trim().ToLowerInvariant();

    private static bool IsTrue(XAttribute? attribute) => attribute is not null && (attribute.Value == "1" || string.Equals(attribute.Value, "true", StringComparison.OrdinalIgnoreCase));

    private static double? Number(XAttribute? attribute) =>
        attribute is not null && double.TryParse(attribute.Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && double.IsFinite(value) ? value : null;

    [GeneratedRegex(@"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")]
    private static partial Regex WordBoundary();

    [GeneratedRegex(@"_{3,}[0-9A-Fa-f]{6,}\]$")]
    private static partial Regex TemporarySuffix();
}
