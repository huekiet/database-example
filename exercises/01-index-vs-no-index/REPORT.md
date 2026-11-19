# Exercise 1 — Index vs No-Index: Benchmark Report

Query files live in two exercise folders. Queries 01–02 belong to this exercise;
queries 03–05 compare JOIN vs subquery but were measured here too, so they live in
[`../02-join-vs-subquery/queries/`](../02-join-vs-subquery/queries/).

**Environment:**
- Image: `postgres:15-alpine`
- Container: `pg-benchmark`
- Data: 1,000,000 users + 1,000,000 orders
- Date: 2026-11-20
- Method: one measured run per query per index state (via `benchmark.sh`),
  `statement_timeout = 30s` to cap the no-index correlated-subquery case.

## Test Queries

| # | File | Description |
|---|------|-------------|
| 01 | `exercises/01-index-vs-no-index/queries/01-point-lookup-by-user-id.sql` | Point lookup `WHERE user_id = 42424` |
| 02 | `exercises/01-index-vs-no-index/queries/02-range-scan-by-date.sql` | Date range `BETWEEN` June 2025 (returns ~41k of 1M rows) |
| 03 | `exercises/02-join-vs-subquery/queries/03-join-vs-subquery.sql` | JOIN vs correlated subquery, email filter `user_5000%` |
| 04 | `exercises/02-join-vs-subquery/queries/04-join-aggregation.sql` | JOIN + GROUP BY, `status = 'delivered'` (~25% of rows) |
| 05 | `exercises/02-join-vs-subquery/queries/05-subquery-aggregation.sql` | Correlated subquery aggregation, `status = 'delivered'` |

## Execution Time Results (ms)

| # | No Index | With Index | Speedup |
|---|----------|------------|---------|
| 01 Point lookup | 44.504 | 0.192 | **~232x faster** |
| 02 Range scan | 59.149 | 103.224 | index is slower (0.57x) |
| 03 JOIN | 156.129 | 63.854 | ~2.4x faster |
| 04 JOIN aggregation | 1,124.101 | 1,119.297 | ~1x (no difference) |
| 05 Subquery aggregation | >30,000 (timed out) | 1,920.810 | **>15x faster** |

Timed-out queries were stopped after the 30-second `statement_timeout` and are
reported as `>30,000 ms`.

## Query Plans Observed

### Query 01 — Point lookup
- **No index:** Parallel Seq Scan over 1M rows, 44.504 ms.
- **With index:** `Index Scan using idx_orders_user_id`, 0.192 ms (`Buffers: shared read=5`).
- **Result:** ~232x faster with the index.

### Query 02 — Range scan (~4% of table matches)
- **No index:** Parallel Seq Scan, 59.149 ms.
- **With index:** `Bitmap Index Scan` + `Bitmap Heap Scan` using `idx_orders_order_date`, 103.224 ms.
- **Lesson:** Index is slower when returning many rows because random heap fetches cost more than sequential scan (0.57x).

### Query 03 — JOIN vs Subquery (email filter)
- **No index — JOIN:** `Parallel Hash Join`, 156 ms.
- **With index — JOIN:** `Nested Loop` with `Index Scan` on `idx_orders_user_id`, 64 ms.
- **Lesson:** Without indexes the JOIN plan (single scan) beats repeated correlated scans; with indexes both collapse to nested-loop index probes and the JOIN is ~2.4x faster here.

### Query 04 — JOIN aggregation (status = 'delivered')
- **No index:** `Hash Join` + `Seq Scan` on orders, 1,124 ms.
- **With index:** `Hash Join` + `Index Scan using idx_orders_status`, 1,119 ms.
- **Lesson:** Returns ~25% of rows; index doesn't help because most rows match anyway (~1x).

### Query 05 — Subquery aggregation
- **No index:** Timed out (>30 s) — correlated subquery scans orders per user.
- **With index:** `Hash Semi Join` + repeated `Index Scan`, 1,921 ms.
- **Lesson:** Correlated subqueries are catastrophic without indexes on large tables (~>15x faster with indexes).

## Key Takeaways

1. **Indexes help point lookups dramatically** (~232x faster for equality lookups).
2. **Indexes can hurt range scans** when a large fraction of the table matches (random I/O vs sequential scan).
3. **JOIN beats correlated subquery without indexes** by orders of magnitude.
4. **With indexes, JOIN and subquery converge** to similar plans; JOIN still tends to be slightly faster for aggregations.
5. **Always check `EXPLAIN ANALYZE`** — execution time alone can be misleading; the plan (Index Scan vs Seq Scan, Hash Join vs Nested Loop) tells the real story.

## Indexes Used

Created by `init/03-indexes.sql`:
- `idx_orders_user_id` — point lookups and joins on `orders.user_id`
- `idx_orders_order_date` — date-range scans
- `idx_orders_status` — status filters
- `idx_orders_user_date` — composite `(user_id, order_date)`
- `idx_users_email` — lookups on `users.email`

Dropped by `init/04-drop-indexes.sql`.

## How to Reproduce

```powershell
# Start and re-seed (wipes existing data)
docker compose down -v
docker compose up -d

# Wait ~60-120s for seeding, verify:
docker exec pg-benchmark psql -U benchmark -d benchmark -c "SELECT 'users', COUNT(*) FROM users UNION ALL SELECT 'orders', COUNT(*) FROM orders;"

# WITHOUT INDEX
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/04-drop-indexes.sql
docker exec pg-benchmark psql -U benchmark -d benchmark -f /exercises/01-index-vs-no-index/queries/01-point-lookup-by-user-id.sql
# ... repeat for the other query files ...

# WITH INDEX
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/03-indexes.sql
docker exec pg-benchmark psql -U benchmark -d benchmark -f /exercises/01-index-vs-no-index/queries/01-point-lookup-by-user-id.sql
# ... repeat for the other query files ...
```

Or run the full automated benchmark (Git Bash / WSL2):
```bash
chmod +x benchmark.sh
./benchmark.sh
```
