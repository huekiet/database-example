-- exercises/04-deadlock/queries/02-session-a-lock-x-then-y.sql
-- Session A of the ABBA deadlock:
--   1. lock x (users.id = 1)
--   2. wait, without committing
--   3. request y (users.id = 2)
-- Session B does the opposite (y first, then x), so both transactions end up
-- waiting for a row the other one holds.
--
-- Run with: psql -v pause_seconds=4 -v deadlock_timeout=5s -f ...
SET deadlock_timeout = :'deadlock_timeout';

BEGIN;

UPDATE users SET name = 'x-by-A' WHERE id = 1;
SELECT clock_timestamp() AS a_locked_x_at;

SELECT pg_sleep(:pause_seconds);

-- B holds y at this point, so A blocks here and the cycle is formed.
UPDATE users SET name = 'y-by-A' WHERE id = 2;

COMMIT;

SELECT clock_timestamp() AS a_committed_at;
SELECT id, name FROM users WHERE id IN (1, 2) ORDER BY id;
