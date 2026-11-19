-- exercises/02-join-vs-subquery/queries/07a-join-global-aggregation.sql
-- JOIN version: aggregate 1M orders for delivered status, top 20 by order count.
-- Compared against 07b-subquery-global-aggregation.sql.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.id,
       u.name,
       COUNT(o.id)   AS cnt,
       AVG(o.amount) AS avg_amount
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE o.status = 'delivered'
GROUP BY u.id, u.name
ORDER BY cnt DESC
LIMIT 20;
