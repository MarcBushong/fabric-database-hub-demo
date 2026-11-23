using ContosoCare.Workload.Postgres;
using ContosoCare.Workload.Rca.Observer;

namespace ContosoCare.Workload.Rca.QueryStore;

/// <summary>
/// Every statement the observer sends to contosocare on T4, as it sends them, for RCA-PG-14's leave-out by text (its $7;
/// rca/README.md, What the capture leaves out):
/// <list type="bullet">
/// <item>the capture catalog's PostgreSQL blocks;</item>
/// <item>the snapshot clear each block runs after;</item>
/// <item>the session limits' SETs on its connections, one statement each, as Npgsql sends a command of several;</item>
/// <item>Npgsql's type loading, which it runs once for each new connection string, as one query of four statements that
/// Query Store may keep whole or one statement at a time, so both are here.</item>
/// </list>
/// RCA-PG-14 compares them with Query Store's texts once comments are stripped and white space collapsed, so a block's
/// earlier versions that differ only there are the same statement: edd01c86's, before the observer's marker, which Query
/// Store may still keep for the queries it saw then. It's built from the runner's own catalog and code, never from the
/// answer key or what the workload plans.
/// </summary>
internal static class PgObserverStatements
{
    /// <summary>
    /// What Npgsql 10.0.3 (workload-generator/Directory.Packages.props) sends to learn a PostgreSQL 14-or-later server's
    /// types for a new connection string, statement by statement, normalized as RCA-PG-14 compares them (comments stripped,
    /// white space collapsed, a final semicolon dropped). It sends them as one query (<see cref="NpgsqlTypeLoadingQuery"/>).
    /// The runner's tests capture what Npgsql sends and fail when this list no longer holds it.
    /// </summary>
    internal static readonly string[] NpgsqlTypeLoading =
    [
        "SELECT version()",
        "SELECT ns.nspname, t.oid, t.typname, t.typtype, t.typnotnull, t.elemtypoid FROM ( SELECT typ.oid, "
            + "typ.typnamespace, typ.typname, typ.typtype, typ.typrelid, typ.typnotnull, typ.relkind, elemtyp.oid AS "
            + "elemtypoid, elemtyp.typname AS elemtypname, elemcls.relkind AS elemrelkind, CASE WHEN "
            + "elemproc.proname='array_recv' THEN 'a' ELSE elemtyp.typtype END AS elemtyptype , typ.typcategory FROM ( "
            + "SELECT typ.oid, typnamespace, typname, typrelid, typnotnull, relkind, typelem AS elemoid, CASE WHEN "
            + "proc.proname='array_recv' THEN 'a' ELSE typ.typtype END AS typtype, CASE WHEN proc.proname='array_recv' "
            + "THEN typ.typelem WHEN typ.typtype='r' THEN rngsubtype WHEN typ.typtype='m' THEN (SELECT rngtypid FROM "
            + "pg_range WHERE rngmultitypid = typ.oid) WHEN typ.typtype='d' THEN typ.typbasetype END AS elemtypoid , "
            + "typ.typcategory FROM pg_type AS typ LEFT JOIN pg_class AS cls ON (cls.oid = typ.typrelid) LEFT JOIN "
            + "pg_proc AS proc ON proc.oid = typ.typreceive LEFT JOIN pg_range ON (pg_range.rngtypid = typ.oid) ) AS "
            + "typ LEFT JOIN pg_type AS elemtyp ON elemtyp.oid = elemtypoid LEFT JOIN pg_class AS elemcls ON "
            + "(elemcls.oid = elemtyp.typrelid) LEFT JOIN pg_proc AS elemproc ON elemproc.oid = elemtyp.typreceive ) AS "
            + "t JOIN pg_namespace AS ns ON (ns.oid = typnamespace) WHERE (typtype IN ('b', 'r', 'm', 'e', 'd') OR "
            + "(typtype = 'c' AND relkind='c') OR (typtype = 'p' AND typname IN ('record', 'void', 'unknown')) OR "
            + "(typtype = 'a' AND ( elemtyptype IN ('b', 'r', 'm', 'e', 'd') OR (elemtyptype = 'p' AND elemtypname IN "
            + "('record', 'void')) OR (elemtyptype = 'c' AND elemrelkind='c') ))) ORDER BY CASE WHEN typtype IN ('b', "
            + "'e', 'p') THEN 0 WHEN typtype = 'c' THEN 1 WHEN typtype = 'r' THEN 2 WHEN typtype = 'm' THEN 3 WHEN "
            + "typtype = 'd' AND elemtyptype <> 'a' THEN 4 WHEN typtype = 'a' THEN 5 WHEN typtype = 'd' AND elemtyptype "
            + "= 'a' THEN 6 END",
        "SELECT typ.oid, att.attname, att.atttypid FROM pg_type AS typ JOIN pg_namespace AS ns ON (ns.oid = "
            + "typ.typnamespace) JOIN pg_class AS cls ON (cls.oid = typ.typrelid) JOIN pg_attribute AS att ON "
            + "(att.attrelid = typ.typrelid) WHERE (typ.typtype = 'c' AND cls.relkind='c') AND attnum > 0 AND NOT "
            + "attisdropped ORDER BY typ.oid, att.attnum",
        "SELECT typ.oid, enumlabel FROM pg_enum JOIN pg_type AS typ ON typ.oid = enumtypid JOIN pg_namespace AS "
            + "ns ON ns.oid = typ.typnamespace ORDER BY oid, enumsortorder",
    ];

    /// <summary>Npgsql's type loading as it sends it, one query of its statements, normalized.</summary>
    internal static string NpgsqlTypeLoadingQuery => string.Join("; ", NpgsqlTypeLoading);

    /// <summary>The list, in a fixed order: the catalog's blocks by ID, then the rest.</summary>
    public static IReadOnlyList<string> All { get; } = Build();

    /// <summary>The session limits' statements, as the observer's connections apply them.</summary>
    internal static IEnumerable<string> LimitStatements(PgSessionLimits limits) =>
        PgConnectionOpener.LimitsCommand(limits).Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

    private static string[] Build() =>
        [.. CaptureCatalog.All
            .Where(b => b.Key.StartsWith("RCA-PG-", StringComparison.Ordinal))
            .OrderBy(b => b.Key, StringComparer.Ordinal)
            .Select(b => b.Value)
            .Append(PgCaptureConnector.ClearSnapshot)
            .Concat(LimitStatements(PgCaptureConnector.Limits))
            .Concat(LimitStatements(PgCaptureConnector.QueryStoreLimits))
            .Concat(NpgsqlTypeLoading)
            .Append(NpgsqlTypeLoadingQuery)
            .Where(s => s.Length > 0)
            .Distinct(StringComparer.Ordinal)];
}
