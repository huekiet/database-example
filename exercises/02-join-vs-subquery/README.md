# Exercise 2 — JOIN vs Subquery

## Goal

Write the same logical result as a `JOIN` and as a subquery, then compare the
plans and the median `Execution Time` with and without supporting indexes. The
interesting question is not "which keyword is faster" but *what plan each shape
produces*.

## Prerequisites

1. Docker Desktop (or Docker Engine + Compose) is running.
2. From the repository root, start the database:

   ```bash
   docker compose up -d
   ```

3. On the very first start the container seeds 1,000,000 users and 1,000,000
   orders (takes 60–120 s). Wait until the counts are populated:

   ```powershell
   docker exec pg-benchmark psql -U benchmark -d benchmark -c "SELECT 'users', COUNT(*) FROM users UNION ALL SELECT 'orders', COUNT(*) FROM orders;"
   ```

## Query pairs

All files live in `queries/` and contain one `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)`
statement. Pairs 06–09 are the focused suite; 03–05 are the original,
multi-shape demonstrations.

| Pair | JOIN | Subquery | Result |
|------|------|----------|--------|
| 03 | `03-join-vs-subquery.sql` | same file, second statement | Email-prefix slice, `JOIN` vs correlated `IN` |
| 04 / 05 | `04-join-aggregation.sql` | `05-subquery-aggregation.sql` | Top users by delivered orders |
| 06 | `06a-join-filtered-aggregation.sql` | `06b-subquery-filtered-aggregation.sql` | 21 users by primary key |
| 07 | `07a-join-global-aggregation.sql` | `07b-subquery-global-aggregation.sql` | Top 20 users by delivered-order count |
| 08 | `08a-join-all-users-aggregation.sql` | `08b-subquery-all-users-aggregation.sql` | First 100,000 users |
| 09 | `09a-join-existence.sql` | `09b-in-existence.sql`, `09c-exists-existence.sql` | Laptop buyers via `JOIN + DISTINCT` vs `IN` vs `EXISTS` |

Note: pair 09 is an existence test, not an aggregate. PostgreSQL rewrites
`IN`/`EXISTS` into a semi-join; `JOIN + DISTINCT` has to deduplicate afterwards.

## How to run

### Automated focused benchmark (recommended)

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\benchmark-join-vs-subquery.ps1 -Runs 7
```

What the script does:

1. Waits for PostgreSQL and prints row counts.
2. Drops the benchmark indexes, then runs queries 06–09 **without** indexes.
3. Applies `init/03-indexes.sql`, then runs the same queries **with** indexes.
4. Each state: 1 warm-up + `-Runs` measured runs, executed round-robin.
5. Uses `SET jit = off` and aborts queries after `-TimeoutSeconds` (default 30).
6. Prints median/min/max per query and saves raw JSON + plans to
   `benchmark-results/` (git-ignored).
7. Drops the indexes again, restoring the default state.

Useful options:

```powershell
-Runs 3                 # fewer measured runs (faster)
-TimeoutSeconds 60      # allow slower no-index runs
-QueryDir /exercises/02-join-vs-subquery/queries   # default query folder
```

### Manual single pair (PowerShell)

```powershell
# --- WITH indexes ---
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/03-indexes.sql
docker exec -i pg-benchmark psql -U benchmark -d benchmark -c "SET jit = off" -f /exercises/02-join-vs-subquery/queries/07a-join-global-aggregation.sql
docker exec -i pg-benchmark psql -U benchmark -d benchmark -c "SET jit = off" -f /exercises/02-join-vs-subquery/queries/07b-subquery-global-aggregation.sql

# --- WITHOUT indexes ---
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/04-drop-indexes.sql
docker exec -i pg-benchmark psql -U benchmark -d benchmark -c "SET jit = off" -f /exercises/02-join-vs-subquery/queries/07a-join-global-aggregation.sql
docker exec -i pg-benchmark psql -U benchmark -d benchmark -c "SET jit = off" -f /exercises/02-join-vs-subquery/queries/07b-subquery-global-aggregation.sql
```

## What to look for

- **`SubPlan N` with `loops=N`** — a correlated aggregate subquery runs once per
  outer row. `loops` close to the user count means per-row work.
- **Plan node:** `Nested Loop`, `Hash Join`, `Hash Semi Join`, `HashAggregate`.
- **Probe cost:** with an index on `orders.user_id`, each SubPlan execution is a
  ~10–25 µs index probe; without it, each is a full 1M-row `Seq Scan`.
- **`Batches` / `Disk Usage`** — hash aggregates spill when `work_mem=16MB` is
  exceeded.
- **`LIMIT` is not a rescue:** in pair 07 the `COUNT` feeding `ORDER BY` still
  runs for every candidate user; only the `AVG` can be deferred to the 20 rows
  that survive the sort.

## Expected outcome

With the benchmark indexes:

- Aggregate subqueries stay `SubPlan`s (PostgreSQL 15 cannot decorrelate them),
  so `JOIN` wins by **1.15–1.8x**, shrinking as the outer row set grows.
- `IN` / `EXISTS` produce the same semi-join plan and beat `JOIN + DISTINCT` by
  **~1.25–1.35x**.

Without indexes:

- Correlated aggregate subqueries degrade to one full scan of `orders` per user
  per subquery: **17x slower** for 21 users, and **>30 s timeouts** for the
  100k/221k-row cases.
- `JOIN` remains roughly constant (one scan of the joined input).

Full numbers, plans, and explanation: [REPORT.md](REPORT.md).

## Cleanup

```bash
docker compose stop        # keep the seeded data volume
docker compose down -v     # remove the container and the 1M rows
```
