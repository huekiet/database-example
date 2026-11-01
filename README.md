# Postgres Benchmark: Index vs No-Index, Join vs Subquery

Containerized PostgreSQL (official `postgres:15-alpine` image) with 1,000,000
users and 1,000,000 orders, ready to run index/join-vs-subquery experiments.

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

# 3. Run the benchmark (Git Bash / WSL2 / Linux / macOS)
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
docker exec pg-benchmark psql -U benchmark -d benchmark -f /queries/01-point-lookup-by-user-id.sql

# WITH INDEX
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/03-indexes.sql
docker exec pg-benchmark psql -U benchmark -d benchmark -f /queries/01-point-lookup-by-user-id.sql

# Drop indexes again when finished
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/04-drop-indexes.sql
```

## What is tested

| File | What it measures |
|------|------------------|
| `queries/01-point-lookup-by-user-id.sql` | Single-row equality lookup `WHERE user_id = ?` — index scan vs seq scan over 1M orders |
| `queries/02-range-scan-by-date.sql` | Date range `BETWEEN` — index range scan vs seq scan over 1M orders |
| `queries/03-join-vs-subquery.sql` | Same result written as `JOIN` vs correlated `IN`/subquery across 1M users + 1M orders |
| `queries/04-join-aggregation.sql` | `JOIN` + `GROUP BY` over 1M orders joined to 1M users (hash vs nested loop) |
| `queries/05-subquery-aggregation.sql` | Same aggregation written with correlated subqueries across 1M users + 1M orders |

Each query uses `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` so you can see the actual
plan (Index Scan, Seq Scan, Hash Join, Nested Loop, SubPlan, etc.) and the
`Execution Time` in milliseconds.

## How the benchmark script works

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
- **JOIN vs subquery:** for simple existence/aggregation, PostgreSQL's planner
  often rewrites both to the same plan; differences show up mainly with large
  result sets or when indexes are missing (nested loop vs hash join).
- Always read the `EXPLAIN ANALYZE` plan, not just the final time — caching,
  `work_mem`, and data distribution affect results.
