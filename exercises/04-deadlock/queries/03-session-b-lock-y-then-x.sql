-- exercises/04-deadlock/queries/03-session-b-lock-y-then-x.sql
-- Session B of the ABBA deadlock: lock y (users.id = 2), wait, then request
-- x (users.id = 1). A does the opposite, so the two sessions deadlock.
--
-- Run with: psql -v pause_seconds=4 -v deadlock_timeout=5s -f ...
SET deadlock_timeout = :'deadlock_timeout';

BEGIN;

UPDATE users SET name = 'y-by-B' WHERE id = 2;
SELECT clock_timestamp() AS b_locked_y_at;

SELECT pg_sleep(:pause_seconds);

-- A holds x at this point, so B blocks here and closes the cycle.
UPDATE users SET name = 'x-by-B' WHERE id = 1;

COMMIT;

SELECT clock_timestamp() AS b_committed_at;
SELECT id, name FROM users WHERE id IN (1, 2) ORDER BY id;
