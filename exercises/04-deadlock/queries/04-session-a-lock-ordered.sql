-- exercises/04-deadlock/queries/04-session-a-lock-ordered.sql
-- Fixed version, session A: lock rows in ascending id order (x, then y).
-- Any transaction that touches both rows uses the same order, so a cycle
-- cannot form.
--
-- Run with: psql -v hold_seconds=2 -f ...
BEGIN;

UPDATE users SET name = 'x-by-A' WHERE id = 1;

SELECT clock_timestamp() AS a_locked_x_at;
SELECT pg_sleep(:hold_seconds);

UPDATE users SET name = 'y-by-A' WHERE id = 2;

COMMIT;

SELECT clock_timestamp() AS a_committed_at;
