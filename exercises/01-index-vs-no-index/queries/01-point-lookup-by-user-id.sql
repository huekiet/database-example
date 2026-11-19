-- exercises/01-index-vs-no-index/queries/01-point-lookup-by-user-id.sql
-- Single-row lookup by foreign key.
-- WITH INDEX:  uses idx_orders_user_id  (Index Scan)
-- WITHOUT:     sequential scan over 1M rows
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, user_id, product, amount, order_date
FROM orders
WHERE user_id = 42424;
