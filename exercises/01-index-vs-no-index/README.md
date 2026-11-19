# Exercise 1 — Index vs No-Index

## Goal

Run the same query with and without supporting indexes and compare PostgreSQL's
`EXPLAIN ANALYZE` output: `Seq Scan` vs `Index Scan` / `Bitmap Heap Scan`, the
number of buffers touched, and the reported `Execution Time`.

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

The `init/` folder is mounted at `/docker-entrypoint-initdb.d` (schema, seed,
index scripts) and `exercises/` at `/exercises` (query files).

## Query files

| File | Query |
|------|-------|
| `queries/01-point-lookup-by-user-id.sql` | Single-row equality lookup: `WHERE user_id = 42424` |
| `queries/02-range-scan-by-date.sql` | Month range: `order_date BETWEEN '2025-06-01' AND '2025-06-30'` |

Both files contain exactly one `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` statement.

## How to run

### Automated (Git Bash / WSL2 / Linux / macOS)

From the repository root:

```bash
chmod +x benchmark.sh
./benchmark.sh
```

The script benchmarks queries **01–05** (this exercise plus the JOIN pairs) in
both index states and prints a side-by-side table. Each query is measured once
per state, so treat it as a quick overview; the focused script in
[`../02-join-vs-subquery/`](../02-join-vs-subquery/README.md) does repeated runs.

### Manual (PowerShell, any OS)

From the repository root:

```powershell
# --- WITHOUT indexes ---
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/04-drop-indexes.sql
docker exec -i pg-benchmark psql -U benchmark -d benchmark -f /exercises/01-index-vs-no-index/queries/01-point-lookup-by-user-id.sql
docker exec -i pg-benchmark psql -U benchmark -d benchmark -f /exercises/01-index-vs-no-index/queries/02-range-scan-by-date.sql

# --- WITH indexes ---
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/03-indexes.sql
docker exec -i pg-benchmark psql -U benchmark -d benchmark -f /exercises/01-index-vs-no-index/queries/01-point-lookup-by-user-id.sql
docker exec -i pg-benchmark psql -U benchmark -d benchmark -f /exercises/01-index-vs-no-index/queries/02-range-scan-by-date.sql

# --- Restore the default (no secondary indexes) state ---
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/04-drop-indexes.sql
```

For repeatable single-query timings, run each file twice manually — the first
execution may include cold-cache reads.

## What to look for

- **`Execution Time`** at the bottom of the plan.
- **Plan node:** `Seq Scan` (whole table) vs `Index Scan` / `Bitmap Heap Scan`.
- **`Rows Removed by Filter`** — how many rows the filter throws away.
- **`Buffers: shared hit / read`** — how much of the plan was served from cache.
- **Selectivity:** indexes help narrow lookups; they can lose when a large
  fraction of the table matches and random heap fetches outweigh a sequential
  scan.

## Expected outcome

| Query | Typical result | Why |
|-------|----------------|-----|
| 01 Point lookup | Index is orders of magnitude faster | 1 row out of 1M; `Index Scan` vs `Seq Scan` |
| 02 Month range | Index can be **slower** | ~4% of rows match; index random I/O costs more than one sequential scan |

Full numbers, plans, and caveats: [REPORT.md](REPORT.md).

## Indexes used

Created by `init/03-indexes.sql`, removed by `init/04-drop-indexes.sql`:

- `idx_orders_user_id` — joins and point lookups on `orders.user_id`
- `idx_orders_order_date` — date-range scans
- `idx_orders_status` — status filters
- `idx_orders_user_date` — composite `(user_id, order_date)`
- `idx_users_email` — lookups on `users.email`

The primary keys and the `users.email` unique constraint always exist.

## Cleanup

```bash
docker compose stop        # keep the seeded data volume
docker compose down -v     # remove the container and the 1M rows
```
