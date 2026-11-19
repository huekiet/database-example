-- exercises/03-locking/queries/08-current-row.sql
-- Final state of the demo row.
SELECT id, name, xmin FROM users WHERE id = 1;
