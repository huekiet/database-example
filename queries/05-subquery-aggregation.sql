-- queries/05-subquery-aggregation.sql
-- Same as 04 but written with a subquery in SELECT (correlated subquery).
-- Compare to 04-join-aggregation.sql.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.id, u.name,
       (SELECT COUNT(*) FROM orders o WHERE o.user_id = u.id AND o.status = 'delivered') AS cnt,
       (SELECT AVG(o.amount) FROM orders o WHERE o.user_id = u.id AND o.status = 'delivered') AS avg_amount
FROM users u
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id AND o.status = 'delivered')
ORDER BY cnt DESC
LIMIT 20;
