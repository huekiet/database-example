-- exercises/02-join-vs-subquery/queries/06a-join-filtered-aggregation.sql
-- JOIN version: aggregate a small slice of users (21 rows, by primary key).
-- The id filter is cheap on purpose, so this isolates the cost of the
-- join/aggregate itself. LEFT JOIN keeps users with no orders, matching the
-- subquery version's row set.
-- Compared against 06b-subquery-filtered-aggregation.sql.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.id,
       u.name,
       COUNT(o.id)                 AS order_count,
       COALESCE(SUM(o.amount), 0)  AS total_spent
FROM users u
LEFT JOIN orders o ON o.user_id = u.id
WHERE u.id BETWEEN 5000 AND 5020
GROUP BY u.id, u.name
ORDER BY order_count DESC;
