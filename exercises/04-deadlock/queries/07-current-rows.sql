-- exercises/04-deadlock/queries/07-current-rows.sql
-- Final state of the two demo rows.
SELECT id, name, xmin FROM users WHERE id IN (1, 2) ORDER BY id;
