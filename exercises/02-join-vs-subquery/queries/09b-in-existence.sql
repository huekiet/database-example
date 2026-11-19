-- exercises/02-join-vs-subquery/queries/09b-in-existence.sql
-- Semantics "users who bought a laptop", written with IN (subquery).
-- PostgreSQL usually rewrites this to a semi-join, producing the same plan as EXISTS.
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.id, u.name, u.email
FROM users u
WHERE u.id IN (SELECT o.user_id FROM orders o WHERE o.product = 'laptop');
