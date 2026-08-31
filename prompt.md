# Add nullability inference to the optimizer

SQLGlot can already infer the *type* of every node in a parsed query
(`sqlglot.optimizer.annotate_types`). It cannot answer the other half of the
question a planner usually needs: **can this expression produce NULL?**

Knowing that a projection is NULL-free unlocks a lot of downstream work, from
dropping redundant `IS NOT NULL` guards to emitting `NOT NULL` column
definitions when a query result is materialised into a table. This task adds
that analysis.

Implement a nullability inference pass that mirrors the shape of the existing
type inference pass, and thread the required information through the pieces it
depends on: the expression tree, the schema, and the per-dialect expression
metadata.

Do not install any additional dependencies or use online connectivity while
working on this task.

---

## 1. Where the answer is stored

Every expression node carries its inferred nullability on a new
`Expr.nullable` property:

* `True` — the expression may evaluate to NULL.
* `False` — the expression can never evaluate to NULL.
* `None` — nullability has not been inferred (the state of a freshly parsed
  tree, and the state of nodes the pass does not annotate).

The property is readable and writable, it accepts `True`, `False` and `None`,
and it survives `copy()` and `deepcopy`. It is stored on the node itself, in
the same manner as the existing inferred type, not inside `Expr.meta`.

`False` is a *guarantee*. When the analysis cannot prove that NULL is
impossible, the answer is `True`. Every rule below is written with that in
mind.

## 2. Entry point

```python
from sqlglot.optimizer.annotate_nullability import annotate_nullability

annotate_nullability(expression, schema=None, dialect=None)
```

It annotates the tree in place and returns the same expression object, exactly
as `annotate_types` does. `schema` accepts the same values `annotate_types`
accepts (a nested `dict`, a `Schema` instance, or `None`). `dialect` selects
the dialect whose expression metadata is consulted.

The pass must also be reachable as `sqlglot.optimizer.annotate_nullability`.

Nullability inference is a standalone analysis. It is **not** added to the
optimizer's `RULES` sequence and `optimize()` behaviour is unchanged.

## 3. Which nodes get annotated

The pass annotates nodes that produce a value: literals, columns, operators,
function calls, `CASE`, subqueries, and the projections of a query.

Nodes that do not produce a value are left at `None`. That includes
identifiers, table references, data types, and the clause wrappers
(`From`, `Where`, `Join`, `Group`, `Order`, `Having`, `Limit`), as well as
`Select` and set-operation nodes themselves. The projections *inside* a
`Select` are annotated; the `Select` node is not.

The input need not be a query at all. Handing the pass a bare expression, such
as a parsed `COALESCE(NULL, 1)`, annotates that expression and everything under
it.

## 4. Operands

Several rules below are described as **strict**: the result may be NULL if and
only if at least one operand may be NULL.

The operands of a node are its direct child expressions, excluding
`exp.DataType` and `exp.Identifier` nodes. A node with no operands under a
strict rule is not nullable.

Strict is the default. Any expression not covered by a rule in section 5 or
section 8 is strict.

## 5. Expression rules

**Constants**

| Expression | Nullability |
|---|---|
| `exp.Null` | always nullable |
| `exp.Literal`, `exp.Boolean` | never nullable |
| `exp.Parameter`, `exp.Placeholder` | always nullable |

**Never nullable**

`exp.Count`, `exp.CountIf`, `exp.Exists`, `exp.Is`, `exp.RowNumber`,
`exp.Rank`, `exp.DenseRank`, `exp.PercentRank`, `exp.CumeDist`, `exp.Ntile`.

These hold in every dialect.

**Conditional forms**

* `exp.Coalesce` — not nullable as soon as *any* operand is not nullable;
  nullable only when every operand is nullable.
* `exp.Nullif` — always nullable.
* `exp.Case` — the branch conditions are irrelevant. Nullable if any result of
  an `exp.If` in `ifs` is nullable, or if there is no `default`, or if the
  `default` is nullable.
* `exp.If` used on its own (`IF(cond, a, b)`) — the condition is irrelevant.
  Nullable if `true` or `false` is nullable, or if `false` is absent.

**Casts**

* `exp.Cast` — takes the nullability of the value being cast.
* `exp.TryCast` — always nullable, whatever it is applied to.

**Aggregates**

An aggregate over an empty group returns NULL, so every `exp.AggFunc` is
nullable, with the two counting aggregates listed above as the exceptions.

**Window functions**

* An `exp.Window` takes the nullability of the function it wraps. Its
  partitioning, ordering and frame arguments are irrelevant.
* `exp.Lag` and `exp.Lead` are nullable if the value expression is nullable, or
  if no default is supplied, or if the supplied default is nullable. A row at
  the requested offset need not exist.

**Subqueries**

An `exp.Subquery` is always nullable; a scalar subquery over zero rows is NULL.

## 6. Schema nullability

A column is nullable unless the schema says otherwise, which is what SQL
itself does.

A mapping schema column may be declared with a trailing `NOT NULL`:

```python
schema = {"t": {"a": "INT NOT NULL", "b": "TEXT"}}
```

`t.a` is not nullable, `t.b` is. The marker is SQL, so it is recognised
whatever its case. The declaration must not disturb the column's *type*:
`get_column_type` still reports `INT` for `t.a`.

Schemas answer the new question through

```python
Schema.is_column_nullable(table, column, dialect=None, normalize=None) -> bool
```

which returns `False` only for a column the schema declares `NOT NULL`, and
`True` otherwise, including for a table or a column the schema does not know
about. The base `Schema` class provides it, so a custom schema implementation
that predates this change keeps working and simply reports everything as
nullable.

## 7. Query rules

### 7.1 Columns

A column resolves through the query's sources.

* A base table — the schema decides.
* A derived table, a CTE or any other subquery source — the nullability of the
  matching projection of that inner query.
* A `VALUES` clause — nullable if any row is nullable in that position.
* A column that cannot be resolved to a single source is nullable.

### 7.2 Outer joins

A join that can invent a row of NULLs makes every column of the side it
invents them for nullable, whatever the schema says.

* `LEFT [OUTER] JOIN` — the joined source.
* `RIGHT [OUTER] JOIN` — every source that precedes it.
* `FULL [OUTER] JOIN` — both.
* `INNER JOIN`, `CROSS JOIN` and a plain comma join — neither.

### 7.3 What a predicate proves

A `WHERE` clause discards rows for which it is not true, and a predicate that
is NULL is not true. So a `WHERE` clause can prove that certain columns are
not NULL in everything downstream of it.

Given a predicate, the set of columns it proves non-NULL is:

| Predicate | Proves |
|---|---|
| `x IS NOT NULL` | the columns of `x` |
| `NOT (x IS NULL)` | the columns of `x` |
| a comparison (`=`, `<>`, `<`, `<=`, `>`, `>=`, `LIKE`, `ILIKE`) | the columns of both sides |
| `x IN (...)`, `x BETWEEN a AND b` | the columns of every operand |
| `a AND b` | the union of what each side proves |
| `a OR b` | the intersection of what each side proves |
| anything else, including `x IS NULL` and any other `NOT` | nothing |

"The columns of `x`" means the columns reachable from `x` by descending only
through expressions that are strict. Nothing is proved about a column that
sits under an expression which can turn NULL into a value: `x + 1 > 0` proves
`x` is not NULL, while `COALESCE(x, 0) > 0` proves nothing.

A predicate in an `ON` clause proves the same set as a `WHERE` clause, but only
for an inner join. On an outer join it proves nothing, because it runs before
the NULL row is invented.

A `HAVING` clause proves nothing.

A filter is evaluated before it has filtered anything, so the columns *inside*
a `WHERE` or `ON` predicate keep the nullability they had before that predicate
proved anything. Only what comes after the filter sees the narrowed answer:
the projections, the grouping and ordering keys, `HAVING` and `QUALIFY`.

### 7.4 Outer joins meet predicates

The two interact. If a `WHERE` clause proves a column of an outer-joined source
non-NULL, no invented NULL row can survive that filter, and the source is no
longer null-extended. Its columns go back to what the schema says.

This is decided per source: in a query that left-joins two tables and filters
on one of them, only that one loses its null extension. Only the `WHERE` clause
can do this. An `ON` clause cannot, not even an inner join's: its rows are
matched before a later outer join invents anything, so what an inner `ON`
proves is in turn overridden when an outer join null-extends that source.

### 7.5 Grouping

`GROUP BY ROLLUP`, `GROUP BY CUBE` and `GROUP BY GROUPING SETS` add
super-aggregate rows in which the grouped columns are NULL, so every grouped
column becomes nullable in the projections. A plain `GROUP BY` changes nothing.

Grouping happens after filtering, so this has the last word: a column that a
`WHERE` clause proved non-NULL is nullable again once `ROLLUP` groups on it.

### 7.6 Set operations

For the *i*-th projection of a set operation:

* `UNION` and `UNION ALL` — nullable if either side is nullable.
* `INTERSECT` — nullable only if both sides are nullable.
* `EXCEPT` — the left side decides.

A set operation reports its output projections through `Query.selects`, which
hands back the nodes of its left operand. Those are the nodes that must carry
the combined verdict, so that reading the *i*-th projection of a query gives
the same kind of answer whether or not the query is a set operation.

## 8. Dialects differ

Nullability rules belong next to the return types, in the per-dialect
`EXPRESSION_METADATA` maps under `sqlglot/typing/`, keyed `"nullability"`.
The pass reads them for the dialect it was given, and a dialect that says
nothing about an expression inherits the default behaviour.

Two families of real differences have to be reflected.

**`CONCAT` and NULL.** In Postgres, DuckDB and T-SQL, `CONCAT` skips NULL
arguments and therefore never returns NULL. Everywhere else, including the
default dialect, it propagates NULL like any other strict function. This is a
property of the `CONCAT` function only: the `||` operator propagates NULL in
every dialect, Postgres and DuckDB included.

**Division by zero.** MySQL and Hive return NULL instead of raising, so `/`,
`DIV` and `%` are nullable there even when both operands are not, unless the
divisor is a numeric literal other than zero, in which case there is nothing to
guard against. Dialects that build on Hive inherit this; they must not restate
it.

## 9. Notes

* Match the surrounding code: this is a typed codebase and the new pass should
  read like `annotate_types` next door.
* Nested queries, CTEs and correlated subqueries all have to work; the analysis
  is not limited to a single flat `SELECT`.
* The pass runs on whatever tree it is handed. It does not require the query to
  have been qualified first, and it must not rewrite the query.
* Running the pass twice on the same tree gives the same answer.
