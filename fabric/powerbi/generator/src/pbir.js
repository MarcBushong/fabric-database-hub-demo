// PBIR building blocks: schema URLs, deterministic names, literal and field expressions, projections, filters.
import { createHash } from 'node:crypto';

const BASE = 'https://developer.microsoft.com/json-schemas/fabric';
export const SCHEMAS = {
  pbip: `${BASE}/pbip/pbipProperties/1.0.0/schema.json`,
  platform: `${BASE}/gitIntegration/platformProperties/2.1.0/schema.json`,
  definitionProperties: `${BASE}/item/report/definitionProperties/2.0.0/schema.json`,
  report: `${BASE}/item/report/definition/report/3.3.0/schema.json`,
  version: `${BASE}/item/report/definition/versionMetadata/1.0.0/schema.json`,
  pages: `${BASE}/item/report/definition/pagesMetadata/1.1.0/schema.json`,
  page: `${BASE}/item/report/definition/page/2.1.0/schema.json`,
  visual: `${BASE}/item/report/definition/visualContainer/2.10.0/schema.json`,
  bookmark: `${BASE}/item/report/definition/bookmark/2.1.0/schema.json`,
  bookmarks: `${BASE}/item/report/definition/bookmarksMetadata/1.0.0/schema.json`,
};

// Deterministic 20-hex-character names, the form Power BI Desktop writes for pages, visuals, and filters.
export function hexName(...parts) {
  return createHash('sha256').update(parts.join('\u001f')).digest('hex').slice(0, 20);
}

export function hexGuid(...parts) {
  const hash = createHash('sha256').update(parts.join('\u001f')).digest('hex');
  return `${hash.slice(0, 8)}-${hash.slice(8, 12)}-${hash.slice(12, 16)}-${hash.slice(16, 20)}-${hash.slice(20, 32)}`;
}

export const literal = (value) => ({ expr: { Literal: { Value: value } } });
export const text = (value) => literal(`'${String(value).replace(/'/g, "''")}'`);
export const bool = (value) => literal(value ? 'true' : 'false');
export const num = (value) => literal(`${value}D`);
export const int = (value) => literal(`${value}L`);
export const solid = (hex) => ({ solid: { color: text(hex) } });

export function fieldRef(field, source) {
  const sourceRef = source ? { Source: source } : { Entity: field.table };
  const inner = { Expression: { SourceRef: sourceRef }, Property: field.name };
  return field.kind === 'measure' ? { Measure: inner } : { Column: inner };
}

// A color property whose value comes from a measure (field-value conditional formatting).
export const measureColor = (field) => ({ solid: { color: { expr: fieldRef(field) } } });

// A color property whose value is the minimum of a text column of hex colors.
export const columnColor = (field) => ({
  solid: { color: { expr: { Aggregation: { Expression: fieldRef(field), Function: 3 } } } },
});

export function projection(field, extra = {}) {
  return { field: fieldRef(field), queryRef: field.queryRef, nativeQueryRef: field.name, ...extra };
}

export const wildcardSelector = (metadata) => ({
  data: [{ dataViewWildcard: { matchingOption: 1 } }],
  ...(metadata ? { metadata } : {}),
});

function aliasFor(field, taken) {
  const base = field.table.replace(/[^A-Za-z]/g, '').toLowerCase().charAt(0) || 't';
  let alias = base;
  let counter = 1;
  while (taken.has(alias)) {
    counter += 1;
    alias = `${base}${counter}`;
  }
  taken.add(alias);
  return alias;
}

function literalFor(field, value) {
  const raw = String(value).trim();
  if (field.kind === 'measure' || ['int64', 'double', 'decimal'].includes(field.dataType)) {
    if (!/^-?\d+(\.\d+)?$/.test(raw)) {
      throw new Error(`A numeric literal is needed for ${field.text}: ${raw}`);
    }
    return { Literal: { Value: field.dataType === 'double' || raw.includes('.') ? `${raw}D` : `${raw}L` } };
  }
  if (field.dataType === 'boolean') {
    return { Literal: { Value: /^(true|yes|1)$/i.test(raw) ? 'true' : 'false' } };
  }
  return { Literal: { Value: `'${raw.replace(/'/g, "''")}'` } };
}

// "'Table'[Column] is value": a categorical filter on a column, or an equality filter on a measure.
export function equalsFilter(name, field, value) {
  const alias = aliasFor(field, new Set());
  const from = [{ Name: alias, Entity: field.table, Type: 0 }];
  if (field.kind === 'measure') {
    return {
      name,
      field: fieldRef(field),
      type: 'Advanced',
      filter: {
        Version: 2,
        From: from,
        Where: [{ Condition: { Comparison: { ComparisonKind: 0, Left: fieldRef(field, alias), Right: literalFor(field, value) } } }],
      },
      howCreated: 'User',
    };
  }
  return {
    name,
    field: fieldRef(field),
    type: 'Categorical',
    filter: {
      Version: 2,
      From: from,
      Where: [{ Condition: { In: { Expressions: [fieldRef(field, alias)], Values: [[literalFor(field, value)]] } } }],
    },
    howCreated: 'User',
  };
}

// Top N values of a column ordered by a measure (or by the maximum of a column), as Desktop writes it.
export function topNFilter(name, target, orderBy, count) {
  const taken = new Set();
  const targetAlias = aliasFor(target, taken);
  const from = [{ Name: targetAlias, Entity: target.table, Type: 0 }];
  let orderAlias = targetAlias;
  if (orderBy.table !== target.table) {
    orderAlias = aliasFor(orderBy, taken);
    from.push({ Name: orderAlias, Entity: orderBy.table, Type: 0 });
  }
  const orderExpression = orderBy.kind === 'measure'
    ? fieldRef(orderBy, orderAlias)
    : { Aggregation: { Expression: fieldRef(orderBy, orderAlias), Function: 4 } };
  return {
    name,
    field: fieldRef(target),
    type: 'TopN',
    filter: {
      Version: 2,
      From: [
        {
          Name: 'subquery',
          Expression: {
            Subquery: {
              Query: {
                Version: 2,
                From: from,
                Select: [{ ...fieldRef(target, targetAlias), Name: 'field' }],
                OrderBy: [{ Direction: 2, Expression: orderExpression }],
                Top: count,
              },
            },
          },
          Type: 2,
        },
        { Name: targetAlias, Entity: target.table, Type: 0 },
      ],
      Where: [{ Condition: { In: { Expressions: [fieldRef(target, targetAlias)], Table: { SourceRef: { Source: 'subquery' } } } } }],
    },
    howCreated: 'User',
  };
}

// The value of a measure for a dynamic textbox run or a bound property, in the form Desktop writes.
export function measureValue(field, id) {
  return {
    expr: {
      Min: {
        Expression: {
          Column: {
            Expression: {
              Subquery: {
                Query: {
                  Version: 2,
                  From: [{ Name: 'm', Entity: field.table, Type: 0 }],
                  Select: [{ ...fieldRef(field, 'm'), Name: field.queryRef }],
                },
              },
            },
            Property: field.queryRef,
          },
        },
        IncludeAllTypes: 1,
      },
      Annotations: {
        NaturalLanguage: { version: 1, kind: 'NaturalLanguage', annotation: { name: id, utterance: field.name } },
      },
    },
  };
}
