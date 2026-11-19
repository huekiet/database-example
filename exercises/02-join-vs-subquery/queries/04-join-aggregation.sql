-- exercises/02-join-vs-subquery/queries/04-join-aggregation.sql
-- Heavy aggregation JOIN (joins 1M orders to users).
-- Good for observing Hash Join vs Nested Loop plan choice with/without indexes.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.id, u.name, COUNT(o.id) AS cnt, AVG(o.amount) AS avg_amount
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE o.status = 'delivered'
GROUP BY u.id, u.name
ORDER BY cnt DESC
LIMIT 20;
