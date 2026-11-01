# Benchmark Report: Index vs No-Index, Join vs Subquery

**Environment:**
- Image: `postgres:15-alpine`
- Container: `pg-benchmark`
- Data: 1,000,000 users + 1,000,000 orders
- Date: 2026-11-01

## Test Queries

| # | File | Description |
|---|------|-------------|
| 01 | `queries/01-point-lookup-by-user-id.sql` | Point lookup `WHERE user_id = 42424` |
| 02 | `queries/02-range-scan-by-date.sql` | Date range `BETWEEN` June 2025 (returns ~41k of 1M rows) |
| 03 | `queries/03-join-vs-subquery.sql` | JOIN vs correlated subquery, email filter `user_5000%` |
| 04 | `queries/04-join-aggregation.sql` | JOIN + GROUP BY, `status = 'delivered'` (~25% of rows) |
| 05 | `queries/05-subquery-aggregation.sql` | Correlated subquery aggregation, `status = 'delivered'` |

## Execution Time Results (ms)

| # | No Index | With Index | Speedup |
|---|----------|------------|---------|
| 01 Point lookup | 34.290 | 0.178 | **~193x faster** |
| 02 Range scan | 46.374 | 66.917 | index is slower |
| 03 JOIN | 124.898 | 38.979 | ~3x faster |
| 03 Subquery | 10,123.347 | 39.866 | **~254x faster** |
| 04 JOIN aggregation | 962.920 | 973.999 | ~1x (no difference) |
| 05 Subquery aggregation | >120,000 (timed out) | 3,575.581 | **>33x faster** |

## Query Plans Observed

### Query 01 — Point lookup
- **No index:** Parallel Seq Scan over 1M rows, `Rows Removed by Filter: 333,333`
- **With index:** `Index Scan using idx_orders_user_id`, `Buffers: shared read=5`

### Query 02 — Range scan (~4% of table matches)
- **No index:** Parallel Seq Scan
- **With index:** `Bitmap Index Scan` + `Bitmap Heap Scan`
- **Lesson:** Index is slower when returning many rows because random heap fetches cost more than sequential scan.

### Query 03 — JOIN vs Subquery (email filter)
- **No index — JOIN:** `Parallel Hash Join`, 125 ms
- **No index — Subquery:** `Seq Scan` inside correlated subplan, executed 111 times, 10,123 ms
- **With index — JOIN:** `Nested Loop` with `Index Scan` on `idx_orders_user_id`, 39 ms
- **With index — Subquery:** `Index Only Scan` / `Index Scan`, 40 ms
- **Lesson:** Without indexes, JOIN wins by orders of magnitude. With indexes, planner optimizes both to similar plans.

### Query 04 — JOIN aggregation (status = 'delivered')
- **No index:** `Hash Join` + `Seq Scan` on orders, 963 ms
- **With index:** `Hash Join` + `Index Scan using idx_orders_status`, 974 ms
- **Lesson:** Returns 25% of rows; index doesn't help because most rows match anyway.

### Query 05 — Subquery aggregation
- **No index:** Timed out (>2 minutes) — correlated subquery scans orders per user
- **With index:** `Hash Semi Join` + repeated `Index Scan`, 3,576 ms
- **Lesson:** Correlated subqueries are catastrophic without indexes on large tables.

## Key Takeaways

1. **Indexes help point lookups dramatically** (~193x faster for equality lookups).
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
docker exec pg-benchmark psql -U benchmark -d benchmark -f /queries/01-point-lookup-by-user-id.sql
# ... repeat for other query files ...

# WITH INDEX
docker exec pg-benchmark psql -U benchmark -d benchmark -f /docker-entrypoint-initdb.d/03-indexes.sql
docker exec pg-benchmark psql -U benchmark -d benchmark -f /queries/01-point-lookup-by-user-id.sql
# ... repeat for other query files ...
```

Or run the full automated benchmark (Git Bash / WSL2):
```bash
chmod +x benchmark.sh
./benchmark.sh
```
