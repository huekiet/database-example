# Exercise 2 — JOIN vs Subquery: Benchmark Report

Focused follow-up to [the index-vs-no-index report](../01-index-vs-no-index/REPORT.md):
the same logical result is written as a `JOIN` and as a subquery, and both are
measured with and without secondary indexes.

**Environment:**

| Item | Value |
|------|-------|
| Image | `postgres:15-alpine` (PostgreSQL 15.19) |
| Container | `pg-benchmark` |
| Host | Windows 11 + Docker Desktop, Intel i7-9750H (6C/12T), 16 GB RAM |
| Data | 1,000,000 users, 1,000,000 orders |
| Server settings | `shared_buffers=256MB`, `work_mem=16MB`, `effective_cache_size=1GB`, `random_page_cost=1.1`, `max_parallel_workers_per_gather=2` |
| Session settings | `jit = off`, `statement_timeout = 30s` |
| Date | 2026-11-20 |

**Method**

- Every file contains exactly one `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` statement.
- Each state is run as 1 warm-up + **7 measured runs**; the **median** is reported
  together with min/max. Queries are interleaved (round-robin) so host-level drift
  affects both sides equally.
- `jit = off` removes one-time JIT compilation cost; without it the heavier
  subquery plans pay ~0.9 s of compilation in PostgreSQL 15.
- "With index" = indexes from `init/03-indexes.sql`. The primary keys and the
  `users.email` unique constraint exist in both states.
- Timings are PostgreSQL's own `Execution Time` (planning excluded).
- Raw data: `benchmark-results/join-vs-subquery-20261120-000243.json`
  (plans in the sibling `plan-*.txt` files).

## Test Queries

| Pair | JOIN file | Subquery file | Logical result |
|------|-----------|---------------|----------------|
| 06 | `exercises/02-join-vs-subquery/queries/06a-join-filtered-aggregation.sql` | `exercises/02-join-vs-subquery/queries/06b-subquery-filtered-aggregation.sql` | Order count + total spend for 21 users (`id BETWEEN 5000 AND 5020`) |
| 07 | `exercises/02-join-vs-subquery/queries/07a-join-global-aggregation.sql` | `exercises/02-join-vs-subquery/queries/07b-subquery-global-aggregation.sql` | Top 20 users by delivered-order count over 1M orders |
| 08 | `exercises/02-join-vs-subquery/queries/08a-join-all-users-aggregation.sql` | `exercises/02-join-vs-subquery/queries/08b-subquery-all-users-aggregation.sql` | Order count + total spend for the first 100,000 users |
| 09 | `exercises/02-join-vs-subquery/queries/09a-join-existence.sql` | `exercises/02-join-vs-subquery/queries/09b-in-existence.sql`, `exercises/02-join-vs-subquery/queries/09c-exists-existence.sql` | Users who bought a laptop (existence / semi-join) |

Pair 06 and 08 keep users without orders (`LEFT JOIN` / scalar subquery returning 0),
so both shapes return the same 21 / 100,000 rows.

## Results — WITH indexes

| Query | Median (ms) | Min–Max (ms) | Winner | Ratio |
|-------|------------:|--------------|--------|-------|
| 06a JOIN — 21 users | **0.414** | 0.350–0.863 | JOIN | **1.43x faster** |
| 06b SUBQUERY — 21 users | 0.591 | 0.431–1.043 | | |
| 07a JOIN — top 20 delivered | **1,193.148** | 1,112.015–1,359.964 | JOIN | **1.45x faster** |
| 07b SUBQUERY — top 20 delivered | 1,732.899 | 1,567.947–1,810.770 | | |
| 08a JOIN — 100k users | 629.019 | 582.225–742.568 | SUBQUERY (marginal) | 1.09x (SUBQUERY faster) |
| 08b SUBQUERY — 100k users | **575.092** | 561.579–678.399 | | |
| 09a JOIN + DISTINCT — laptop buyers | 269.009 | 242.657–328.252 | | |
| 09b `IN (subquery)` — laptop buyers | **190.408** | 164.552–285.077 | `IN` | **1.41x faster** than JOIN+DISTINCT |
| 09c `EXISTS` — laptop buyers | **186.417** | 169.592–216.086 | `EXISTS` | **1.44x faster** than JOIN+DISTINCT |

For pair 09 the ratio is relative to `09a` (`JOIN + DISTINCT`); `IN` and `EXISTS`
share the same plan, so small differences are run-to-run noise.

## Results — WITHOUT indexes

| Query | Median (ms) | Min–Max (ms) | Winner | Ratio |
|-------|------------:|--------------|--------|-------|
| 06a JOIN — 21 users | **196.405** | 171.882–202.796 | JOIN | **16.3x faster** |
| 06b SUBQUERY — 21 users | 3,208.003 | 3,154.381–3,689.617 | | |
| 07a JOIN — top 20 delivered | **1,299.951** | 1,215.573–1,370.333 | JOIN | >23x faster |
| 07b SUBQUERY — top 20 delivered | >30,000 (timeout) | — | | |
| 08a JOIN — 100k users | **666.124** | 597.130–820.776 | JOIN | >45x faster |
| 08b SUBQUERY — 100k users | >30,000 (timeout) | — | | |
| 09a JOIN + DISTINCT — laptop buyers | 258.645 | 239.746–325.586 | | |
| 09b `IN (subquery)` — laptop buyers | **186.900** | 167.636–223.502 | `IN` | ~1.38x faster than JOIN+DISTINCT |
| 09c `EXISTS` — laptop buyers | 203.150 | 176.122–266.053 | `EXISTS` | ~1.27x faster than JOIN+DISTINCT |

Timed-out queries were stopped after the first 30-second attempt and are reported
as `>30,000 ms`.

## Query Plans Observed

### Pair 06 — 21 users (small outer set)
- **JOIN, with index:** `Nested Loop Left Join` → `Index Scan users_pkey` (21 rows) →
  `Index Scan idx_orders_user_id` (21 loops). One index probe per user, 0.41 ms.
- **SUBQUERY, with index:** `Index Scan users_pkey` with two SubPlans evaluated
  **21 times each** — `Index Only Scan idx_orders_user_date` for `COUNT(*)` and
  `Index Scan idx_orders_user_id` for `SUM(amount)`. ~2 probes per user, 0.59 ms.
- **Without index:** the join plan becomes one scan of `orders` (196 ms total),
  while each of the 42 SubPlan executions scans all 1M orders (3.2 s total).
- **Lesson:** at tiny row counts both shapes are fine; the subquery simply does
  twice as many index probes and loses by a constant factor (1.43x).

### Pair 07 — top 20 users by delivered orders (1M orders)
- **JOIN:** `Seq Scan users` + `Index Scan idx_orders_status` → `Hash Join` →
  `HashAggregate` (spills: `Batches: 5`, ~11 MB disk) → `Sort` → `Limit`, 1.19 s.
- **SUBQUERY:** `Hash Semi Join` (the `EXISTS` is decorrelated) produces ~221k users.
  `SubPlan 1` (the `COUNT` used by `ORDER BY`) runs **221,193 times** as an
  `Index Scan` on `idx_orders_user_id` with a `status = 'delivered'` filter;
  `SubPlan 2` (`AVG`) runs only **20 times** because `LIMIT 20` lets it be
  evaluated lazily after the sort. Total 1.73 s.
- **Without index:** the join runs ~1.30 s; the subquery must scan 1M orders for
  every one of the 221k users and does not finish within 30 s.
- **Lesson:** PostgreSQL 15 decorrelates `EXISTS`, but **not** aggregate subqueries
  in the SELECT list. Those remain `SubPlan`s with per-row execution. `LIMIT` can
  defer the subquery for the selected rows, but not the one used for sorting.

### Pair 08 — aggregate 100k users
- **JOIN:** `Index Scan users_pkey` (100k rows) + `Seq Scan orders` (1M rows) →
  `Hash Right Join` → `HashAggregate` (spills, `Batches: 5`), 0.63 s. The full
  `orders` scan dominates.
- **SUBQUERY:** `Index Scan users_pkey` + two SubPlans evaluated 100,000 times each
  (200k index probes at ~5 µs), 0.58 s.
- **Lesson:** with indexes the two approaches converge (~tie; subquery marginally
  faster at 1.09x). The subquery cost scales linearly with the outer row count;
  here cheap index probes (~0.58 s for 200k probes) roughly equal one full table
  scan plus a spilling hash aggregate.

### Pair 09 — existence (`product = 'laptop'`)
- **JOIN + DISTINCT:** `Parallel Hash Join` (125k matching orders) → two-phase
  `HashAggregate` to deduplicate → 269 ms.
- **IN / EXISTS:** the planner rewrites both to the **same** plan — `Parallel Hash
  Semi Join`, which deduplicates while building the hash — 190 ms / 186 ms.
- **Lesson:** `IN` and `EXISTS` are equivalent in PostgreSQL 15 (identical costs
  and plans; the 190 vs 186 ms gap is run-to-run noise). `JOIN + DISTINCT` does
  extra work by materializing duplicates first, so it's ~1.4x slower here.
  With no indexes all three use sequential scans and are within noise (~200–260 ms).

## Why the numbers look like this

All the shapes in this report return the same rows, but the planner builds very
different machinery for them. That is the real source of the timing differences.

### Aggregate subquery = per-row `SubPlan`

```sql
SELECT u.id,
       (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id),     -- SubPlan 1
       (SELECT SUM(o.amount) FROM orders o WHERE o.user_id = u.id) -- SubPlan 2
FROM users u ...
```

PostgreSQL 15 has no rewrite that turns a correlated **aggregate** subquery into
a `JOIN … GROUP BY`. It stays a `SubPlan` attached to the outer node and runs
**once per outer row** (twice per row in these queries). Only the cost of each
execution changes with the index state:

| State | Cost of one `SubPlan` execution |
|-------|----------------------------------|
| With index | ~10–25 µs — `Index Scan` / `Index Only Scan` on `user_id`, including the `Aggregate` wrapper |
| No index | ~100–130 ms — `Seq Scan` over all 1M `orders` |

So the subquery cost is roughly:

```text
outer_rows × number_of_subqueries × cost_per_probe
```

| Outer rows | Probes | Measured |
|-----------:|-------:|---------:|
| 21 | 42 | 0.59 ms (with index) / 3.2 s (no index) |
| 100,000 | 200,000 | 0.58 s (with index) / >30 s (no index) |
| 221,193 | 442,386 | 1.73 s (with index) / >30 s (no index) |

The JOIN version, by contrast, processes the orders input once as a set:

```sql
FROM users u JOIN orders o ON o.user_id = u.id
GROUP BY u.id, u.name
```

It becomes a `Nested Loop` for 21 users (one index probe per user, i.e. one
subquery's worth of work) or one `Hash Join` + `HashAggregate` for the large
sets. Either way the work is proportional to `users × 1`, never
`users × number_of_subqueries`.

### Why the gap is small WITH indexes (1.09–1.45x)

Both sides are doing index/scan work, and the join's advantage is a constant
factor: 1 pass instead of 2 probes per user, hence ~1.43x at 21 users.

At 100k users the join's cost is no longer the join itself: it scans all 1M
orders and spills a 100k-group `HashAggregate` to disk (`work_mem = 16MB`,
`Batches: 5`). The subquery avoids that aggregate and pays "only" 200k cheap
index probes. Different bottlenecks, near tie (1.09x).

### Why the gap explodes WITHOUT indexes (16x, >23x, >45x)

The costs stop being additive:

- **JOIN** = one `Seq Scan` of `orders` (~200 ms) regardless of how many users.
- **SUBQUERY** = one `Seq Scan` of `orders` **per user, per subquery**. At 21
  users that is 42 scans (3.2 s); at 221k users it is effectively unbounded,
  which is why the 30 s timeout fires.

The keyword (`JOIN` vs `SELECT`-list subquery) is not what decides the winner —
whether the per-row lookup can be answered by an index is.

### Existence checks are different

For `EXISTS` / `IN`, PostgreSQL **does** rewrite the subquery into a semi-join
(`pull_up_sublinks`). That is why `09b` and `09c` produced literally identical
costs and plans (`Parallel Hash Semi Join`).

```text
JOIN + DISTINCT:  Parallel Hash Join (125k matching rows) → HashAggregate (dedupe)
IN / EXISTS:      Parallel Hash Semi Join (dedupe happens while hashing)
```

The semi-join can discard duplicates during the join and stop at the first match
per outer row; `DISTINCT` must materialize all 125k joined rows first. That is
the ~1.25–1.34x difference. Without indexes all three are sequential scans and
land within noise (~450 ms): the plan-shape advantage remains, but the scan
dominates.

### Rules of thumb

1. Aggregates for many parents → `JOIN … GROUP BY`. It is at worst a tie and
   robust when indexes are missing.
2. Existence → `IN` or `EXISTS`, never `JOIN + DISTINCT`. Same plan, fewer
   duplicates, less work.
3. Correlated scalar subqueries are fine only for a **small outer set with a
   supporting index** (e.g. a detail page for one user). Cost is linear in
   outer rows.
4. `LIMIT` is not a rescue: in 07b the `COUNT` feeding `ORDER BY` still ran
   221,193 times; only the `AVG` was deferred to the 20 surviving rows.
5. Read `EXPLAIN ANALYZE` for `SubPlan … loops=N`. Many loops = per-row work;
   `Hash Join` / `Hash Semi Join` = set-based work.

## Key Takeaways

1. **With supporting indexes, `JOIN` is consistently faster for "aggregate per
    parent" queries, but only by ~1.1–1.5x** — not orders of magnitude. At 100k
    users the gap is essentially a tie (1.09x, subquery marginally faster).
2. **Without indexes, correlated aggregate subqueries collapse.** They run one
    full scan of `orders` per outer row: ~16x slower for 21 users and more than
    30 s (>23x / >45x) for the 1M-row cases, versus ~1–2 s for the joins.
3. **PostgreSQL can rewrite `IN`/`EXISTS` into semi-joins, but it cannot
    decorrelate scalar aggregate subqueries.** That rewrite is the single biggest
    factor behind "JOIN vs subquery" results.
4. **For existence checks, prefer `IN`/`EXISTS` over `JOIN + DISTINCT`.** They are
    ~1.4x faster with indexes and remove the duplicate-row footgun.
5. **`work_mem = 16MB` forces the 100k–1M-group aggregations to spill to disk**
    (`Batches: 5`), which directly penalises the JOIN plans in pairs 07 and 08;
    the subquery plans avoid that hash aggregate but pay per-row index probes
    instead.
6. **Measure, don't guess:** the same "join vs subquery" question has answers from
    "1.5x faster" to "times out" depending on indexes, row counts, and whether the
    subquery is an existence test or an aggregate.

## Caveats

- Docker Desktop on Windows shares CPU/RAM with the host; parallel plans (2
  workers) add variance. Some queries show a 1.5–2x spread between min and max,
  so treat ratios as directional and absolute values as machine-specific.
- The 30 s timeout truncates two no-index measurements; their true cost is higher.
- Pair 09 is unaffected by the benchmark indexes (`product` has no index), so the
  with/without-index difference there is run-to-run noise; the JOIN vs semi-join
  difference is structural.
- `jit = off` is a deliberate micro-benchmark choice. With JIT enabled, the two
  heaviest subquery plans pay ~0.9 s extra compilation on first execution.

## How to Reproduce

```powershell
# Start Postgres (seeds 1M rows on first init) and wait for readiness
docker compose up -d

# Full suite: 1 warm-up + 7 measured runs, both index states
powershell -ExecutionPolicy Bypass -File .\benchmark-join-vs-subquery.ps1 -Runs 7
```

Run a single pair manually:

```powershell
# WITH indexes
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/03-indexes.sql
docker exec -i pg-benchmark psql -U benchmark -d benchmark -c "SET jit = off" -f /exercises/02-join-vs-subquery/queries/07a-join-global-aggregation.sql
docker exec -i pg-benchmark psql -U benchmark -d benchmark -c "SET jit = off" -f /exercises/02-join-vs-subquery/queries/07b-subquery-global-aggregation.sql

# WITHOUT indexes
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/04-drop-indexes.sql
docker exec -i pg-benchmark psql -U benchmark -d benchmark -c "SET jit = off" -f /exercises/02-join-vs-subquery/queries/07a-join-global-aggregation.sql
```

The runner restores the "no secondary index" state when it finishes.
