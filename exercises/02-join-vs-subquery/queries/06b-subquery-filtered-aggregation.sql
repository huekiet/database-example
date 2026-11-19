-- exercises/02-join-vs-subquery/queries/06b-subquery-filtered-aggregation.sql
-- Subquery version: same result as 06a, written as correlated scalar subqueries.
-- PostgreSQL keeps these as SubPlan nodes (one aggregate per outer row) instead of
-- flattening them into a join.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.id,
       u.name,
       (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id)                   AS order_count,
       (SELECT COALESCE(SUM(o.amount), 0) FROM orders o WHERE o.user_id = u.id) AS total_spent
FROM users u
WHERE u.id BETWEEN 5000 AND 5020
ORDER BY order_count DESC;
