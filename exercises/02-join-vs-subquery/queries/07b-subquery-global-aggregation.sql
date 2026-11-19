-- exercises/02-join-vs-subquery/queries/07b-subquery-global-aggregation.sql
-- Subquery version: same result as 07a, written with correlated subqueries.
-- The EXISTS in the WHERE clause is rewritten to a semi-join, but the two
-- aggregate subqueries in the SELECT list cannot be flattened, so they run once
-- per surviving user.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.id,
       u.name,
       (SELECT COUNT(*) FROM orders o
         WHERE o.user_id = u.id AND o.status = 'delivered') AS cnt,
       (SELECT AVG(o.amount) FROM orders o
         WHERE o.user_id = u.id AND o.status = 'delivered') AS avg_amount
FROM users u
WHERE EXISTS (SELECT 1 FROM orders o
               WHERE o.user_id = u.id AND o.status = 'delivered')
ORDER BY cnt DESC
LIMIT 20;
