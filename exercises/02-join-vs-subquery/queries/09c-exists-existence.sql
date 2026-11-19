-- exercises/02-join-vs-subquery/queries/09c-exists-existence.sql
-- Semantics "users who bought a laptop", written with EXISTS.
-- Same result as 09a / 09b, but without the DISTINCT that JOIN needs.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.id, u.name, u.email
FROM users u
WHERE EXISTS (SELECT 1 FROM orders o
               WHERE o.user_id = u.id AND o.product = 'laptop');
