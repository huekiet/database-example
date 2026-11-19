-- exercises/02-join-vs-subquery/queries/09a-join-existence.sql
-- Semantics "users who bought a laptop", written as JOIN + DISTINCT.
-- Compare with 09b-in-existence.sql and 09c-exists-existence.sql.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT DISTINCT u.id, u.name, u.email
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE o.product = 'laptop';
