-- exercises/02-join-vs-subquery/queries/08b-subquery-all-users-aggregation.sql
-- Subquery version: same result as 08a, two correlated aggregate subqueries per user.
-- Cost grows linearly with the number of outer rows: 2 index lookups per user.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.id,
       u.name,
       (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id)                   AS order_count,
       (SELECT COALESCE(SUM(o.amount), 0) FROM orders o WHERE o.user_id = u.id) AS total_spent
FROM users u
WHERE u.id <= 100000;
