-- queries/03-join-vs-subquery.sql
-- Same logical result written two ways:
--   (a) explicit JOIN
--   (b) subquery (IN)
-- Run each separately and compare actual time / rows.
-- Enable/disable indexes to see how the planner chooses between
-- Nested Loop, Hash Join, Merge Join, or SubPlan.

-- (a) JOIN version
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.id, u.name, COUNT(o.id) AS order_count, SUM(o.amount) AS total_spent
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE u.email LIKE 'user_5000%'
GROUP BY u.id, u.name;

-- (b) Subquery (IN) version
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, name,
       (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id) AS order_count,
       (SELECT COALESCE(SUM(o.amount), 0) FROM orders o WHERE o.user_id = u.id) AS total_spent
FROM users u
WHERE u.email LIKE 'user_5000%';
