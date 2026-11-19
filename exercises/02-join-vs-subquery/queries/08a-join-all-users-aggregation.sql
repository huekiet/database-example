-- exercises/02-join-vs-subquery/queries/08a-join-all-users-aggregation.sql
-- JOIN version: aggregate the first 100,000 users (about 100,000 orders).
-- No filters, so every user must be reported (LEFT JOIN keeps users with no orders).
-- Compared against 08b-subquery-all-users-aggregation.sql.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.id,
       u.name,
       COUNT(o.id)                      AS order_count,
       COALESCE(SUM(o.amount), 0)       AS total_spent
FROM users u
LEFT JOIN orders o ON o.user_id = u.id
WHERE u.id <= 100000
GROUP BY u.id, u.name;
