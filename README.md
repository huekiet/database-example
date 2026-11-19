# Postgres Benchmark: Index vs No-Index, Join vs Subquery, Locks & Deadlocks

Containerized PostgreSQL (official `postgres:15-alpine` image) with 1,000,000
users and 1,000,000 orders. The four exercises are numbered under `exercises/`,
with shared schema, seed data, and index scripts in `init/`.

## Repository layout

```text
.
├── init/                              # shared: schema, seed, index scripts
│   ├── 01-schema.sql
│   ├── 02-seed.sql
│   ├── 03-indexes.sql                 # apply benchmark indexes
│   └── 04-drop-indexes.sql            # restore "no index" state
├── exercises/
│   ├── 01-index-vs-no-index/
│   │   ├── queries/                   # 01 point lookup, 02 range scan
│   │   ├── README.md                  # exercise instructions
│   │   └── REPORT.md                  # measured results
│   ├── 02-join-vs-subquery/
│   │   ├── queries/                   # 03-09, JOIN/subquery pairs
│   │   ├── README.md
│   │   └── REPORT.md
│   ├── 03-locking/
│   │   ├── queries/                   # 01-08, two sessions on one row
│   │   ├── locking-demo.ps1           # runs the three lock scenarios
│   │   ├── README.md
│   │   └── REPORT.md
│   └── 04-deadlock/
│       ├── queries/                   # 01-08, ABBA deadlock
│       ├── node/                      # pg demo + fixed version
│       ├── deadlock-demo.ps1          # two psql sessions, then the fix
│       ├── README.md
│       └── REPORT.md
├── benchmark.sh                       # index vs no-index harness (01-05)
├── benchmark-join-vs-subquery.ps1     # join vs subquery harness (06-09)
└── docker-compose.yml
```

`init/` is mounted at `/docker-entrypoint-initdb.d` (seeds on first start) and
`exercises/` is mounted read-only at `/exercises`, so queries can be run with
`psql -f` inside the container.

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows) or
  Docker Engine + Compose (Linux/macOS).
- The `psql` client is only needed if you want to run `benchmark.sh` from the
  host; otherwise everything runs inside the container.

## Quick start

```bash
# 1. Start Postgres (seeds 1M rows automatically on first init)
docker compose up -d

# 2. Wait ~60-120s for seeding to finish (1M rows takes longer), then check row counts
docker exec -it pg-benchmark psql -U benchmark -d benchmark -c \
  "SELECT 'users', COUNT(*) FROM users UNION ALL SELECT 'orders', COUNT(*) FROM orders;"

# 3. Run the index vs no-index benchmark (Git Bash / WSL2 / Linux / macOS)
chmod +x benchmark.sh
./benchmark.sh
```

### Windows PowerShell (no bash)

If you don't have Git Bash/WSL2, run the steps manually in PowerShell:

```powershell
docker compose up -d
# wait for seed, then:
docker exec pg-benchmark psql -U benchmark -d benchmark -c "SELECT 'users', COUNT(*) FROM users UNION ALL SELECT 'orders', COUNT(*) FROM orders;"

# WITHOUT INDEX
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/04-drop-indexes.sql
docker exec pg-benchmark psql -U benchmark -d benchmark -f /exercises/01-index-vs-no-index/queries/01-point-lookup-by-user-id.sql

# WITH INDEX
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/03-indexes.sql
docker exec pg-benchmark psql -U benchmark -d benchmark -f /exercises/01-index-vs-no-index/queries/01-point-lookup-by-user-id.sql

# Drop indexes again when finished
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/04-drop-indexes.sql
```

## What is tested

### 1. Index vs no-index — `exercises/01-index-vs-no-index/queries/`

| File | What it measures |
|------|------------------|
| `01-point-lookup-by-user-id.sql` | Single-row equality lookup `WHERE user_id = ?` — index scan vs seq scan over 1M orders |
| `02-range-scan-by-date.sql` | Date range `BETWEEN` — index range scan vs seq scan over 1M orders |

### 2. Join vs subquery — `exercises/02-join-vs-subquery/queries/`

| File | What it measures |
|------|------------------|
| `03-join-vs-subquery.sql` | Same result written as `JOIN` vs correlated `IN`/subquery across 1M users + 1M orders |
| `04-join-aggregation.sql` | `JOIN` + `GROUP BY` over 1M orders joined to 1M users (hash vs nested loop) |
| `05-subquery-aggregation.sql` | Same aggregation written with correlated subqueries across 1M users + 1M orders |
| `06a-join-filtered-aggregation.sql` / `06b-subquery-filtered-aggregation.sql` | JOIN vs correlated subquery aggregation for 21 users |
| `07a-join-global-aggregation.sql` / `07b-subquery-global-aggregation.sql` | JOIN vs correlated subquery, top 20 users by delivered orders |
| `08a-join-all-users-aggregation.sql` / `08b-subquery-all-users-aggregation.sql` | JOIN vs correlated subquery aggregation for 100,000 users |
| `09a-join-existence.sql` / `09b-in-existence.sql` / `09c-exists-existence.sql` | Existence check written as JOIN + DISTINCT vs `IN` vs `EXISTS` |

Each query uses `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` so you can see the actual
plan (Index Scan, Seq Scan, Hash Join, Nested Loop, SubPlan, etc.) and the
`Execution Time` in milliseconds.

### 3. Row locks — `exercises/03-locking/queries/`

Not a benchmark: a two-session demo where both transactions update
`users.id = 1`, so the second writer blocks on the first one's row lock.

| File | What it does |
|------|--------------|
| `01-reset-demo-row.sql` | Reset `users.id = 1` to `name = 'user_1'` |
| `02-session-a-hold-lock.sql` | Session A: `UPDATE`, hold the lock for `:lock_seconds`, `COMMIT` |
| `03-session-b-blocked-update.sql` | Session B: same `UPDATE`, blocks until A finishes |
| `04-session-b-lock-timeout.sql` | Session B with `lock_timeout` — aborts instead of waiting |
| `05-session-b-nowait.sql` | `SELECT ... FOR UPDATE NOWAIT` — fails immediately |
| `06-observe-waits.sql` | `pg_stat_activity` / `pg_locks` / `pg_blocking_pids` snapshot |
| `07-lock-held-check.sql` | Detects that a session holds the row lock |
| `08-current-row.sql` | Show the final demo row |

### 4. Deadlocks — `exercises/04-deadlock/queries/`

Two transactions lock **x** (`users.id = 1`) and **y** (`users.id = 2`) in
opposite order, then request each other's row. PostgreSQL aborts one with
`40P01` (`deadlock_detected`). The exercise also includes a Node.js reproduction
and an ordered-locking fix.

| File | What it does |
|------|--------------|
| `01-reset-demo-rows.sql` | Reset x/y to `user_1` / `user_2` |
| `02-session-a-lock-x-then-y.sql` | A: `UPDATE` x, sleep, `UPDATE` y |
| `03-session-b-lock-y-then-x.sql` | B: `UPDATE` y, sleep, `UPDATE` x |
| `04-session-a-lock-ordered.sql` | Fixed order: A locks x, then y |
| `05-session-b-lock-ordered.sql` | Fixed order: B locks x, then y |
| `06-observe-deadlock.sql` | `pg_stat_activity` / `pg_locks` snapshot of the cycle |
| `07-current-rows.sql` | Final x/y values and `xmin` |
| `08-waiting-pair-check.sql` | Counts sessions waiting on `transactionid` |

## How the benchmark script works

`benchmark.sh` benchmarks queries 01–05 (from both exercise folders):

1. Waits for the container to be ready.
2. Runs every query **without** indexes and captures `Execution Time`.
3. Applies `init/03-indexes.sql`, re-runs the same queries **with** indexes.
4. Drops the indexes again so the next iteration starts clean.
5. Prints a side-by-side comparison with speedup factor.

## Indexes toggled

`init/03-indexes.sql` creates:
- `idx_orders_user_id` — supports point lookups and joins on `orders.user_id`
- `idx_orders_order_date` — supports date-range scans
- `idx_orders_status` — supports status filters
- `idx_orders_user_date` — composite index for `(user_id, order_date)`
- `idx_users_email` — supports lookups on `users.email`

`init/04-drop-indexes.sql` removes them all.

## Focused JOIN vs subquery benchmark

`benchmark-join-vs-subquery.ps1` runs the paired queries 06–09 from
`exercises/02-join-vs-subquery/queries/` (one statement per file), 1 warm-up + N
measured runs, and reports the median `Execution Time` with and without the
indexes from `init/03-indexes.sql`:

```powershell
# Windows PowerShell (5.1+)
powershell -ExecutionPolicy Bypass -File .\benchmark-join-vs-subquery.ps1 -Runs 7
```

The script runs `SET jit = off` for stable timings, interleaves the queries
round-robin, stops any query that exceeds `-TimeoutSeconds` (default 30), saves
raw JSON + plans under `benchmark-results/`, and restores the no-index state when
it finishes. Use `-QueryDir` to point it at a different query folder.

## Row-lock demo

`exercises/03-locking/locking-demo.ps1` starts two sessions against the same row
(`users.id = 1`). Session A updates the row and holds the lock; session B issues
the same `UPDATE` and blocks until A commits. It also shows the two ways to stop
waiting — `lock_timeout` and `NOWAIT` — and prints a `pg_locks` snapshot while B
is blocked:

```powershell
powershell -ExecutionPolicy Bypass -File .\exercises\03-locking\locking-demo.ps1

# keep the lock longer / change the timeout
powershell -ExecutionPolicy Bypass -File .\exercises\03-locking\locking-demo.ps1 -LockSeconds 15 -LockTimeoutSeconds 3
```

The demo resets the row when it finishes. Per-file commands and the expected
output are in [exercises/03-locking/README.md](exercises/03-locking/README.md).

## Deadlock demo

`exercises/04-deadlock/deadlock-demo.ps1` runs two psql sessions in opposite order:
A locks `users.id = 1` then requests `id = 2`; B locks `id = 2` then requests
`id = 1`. Both wait, PostgreSQL detects the cycle, and one session aborts with
`40P01` (`deadlock_detected`). The script then repeats the work with a
consistent `1 -> 2` order, where both transactions commit:

```powershell
powershell -ExecutionPolicy Bypass -File .\exercises\04-deadlock\deadlock-demo.ps1
```

The Node.js version reproduces the deadlock and shows the fix (ordered
`SELECT ... FOR UPDATE` + retry):

```powershell
cd exercises\04-deadlock\node
npm install
npm run deadlock   # one transaction aborts with 40P01
npm run fixed      # both commit, no deadlock
```

Per-file commands and the explanation are in
[exercises/04-deadlock/README.md](exercises/04-deadlock/README.md).

## Exercise guides and reports

| # | Exercise | Instructions | Results |
|---|----------|--------------|---------|
| 1 | Index vs no-index | [README](exercises/01-index-vs-no-index/README.md) | [REPORT](exercises/01-index-vs-no-index/REPORT.md) |
| 2 | JOIN vs subquery | [README](exercises/02-join-vs-subquery/README.md) | [REPORT](exercises/02-join-vs-subquery/REPORT.md) |
| 3 | Row locks | [README](exercises/03-locking/README.md) | [REPORT](exercises/03-locking/REPORT.md) |
| 4 | Deadlocks | [README](exercises/04-deadlock/README.md) | [REPORT](exercises/04-deadlock/REPORT.md) |

## Cleanup

```bash
# Stop and remove container, keep data volume
docker compose stop

# Remove container + data volume (⚠️ deletes the 1M rows)
docker compose down -v
```

## Expected takeaways

- **Index vs no-index:** point lookups and narrow date ranges should be orders
  of magnitude faster with an index (Index Scan vs Seq Scan over 1M rows).
- **JOIN vs subquery:** with indexes, `JOIN` is modestly faster for aggregate
  subqueries and clearly better for existence checks than `JOIN + DISTINCT`;
  without indexes, correlated aggregate subqueries degrade to a full table scan
  per outer row.
- **Row locks:** concurrent writers to the same row serialize — the second one
  waits (`wait_event_type = Lock`, `wait_event = transactionid`), not fails.
  Only `lock_timeout`, `statement_timeout`, or `NOWAIT` turn the wait into an
  error, and under `READ COMMITTED` the last writer wins.
- **Deadlocks:** taking the same rows in opposite order creates a wait-for
  cycle. PostgreSQL waits `deadlock_timeout` (default 1 s), then aborts one
  transaction with `40P01` and rolls it back. Lock rows in a consistent order
  (or use one parent/advisory lock) and retry `40P01` / `40001`.
- Always read the `EXPLAIN ANALYZE` plan, not just the final time — caching,
  `work_mem`, and data distribution affect results.
