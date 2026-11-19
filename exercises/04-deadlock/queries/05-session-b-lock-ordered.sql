-- exercises/04-deadlock/queries/05-session-b-lock-ordered.sql
-- Fixed version, session B: also lock x (users.id = 1) first. B waits for A
-- to finish at the first UPDATE, then updates x and y without forming a cycle.
BEGIN;

UPDATE users SET name = 'x-by-B' WHERE id = 1;

UPDATE users SET name = 'y-by-B' WHERE id = 2;

COMMIT;

SELECT clock_timestamp() AS b_committed_at;
