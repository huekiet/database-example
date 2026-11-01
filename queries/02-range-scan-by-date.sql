-- queries/02-range-scan-by-date.sql
-- Range scan over a month of orders.
-- WITH INDEX:  idx_orders_order_date (Index Scan / Bitmap Heap Scan)
-- WITHOUT:     sequential scan
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, user_id, product, amount, order_date
FROM orders
WHERE order_date BETWEEN TIMESTAMP '2025-06-01 00:00:00'
                     AND TIMESTAMP '2025-06-30 23:59:59';
