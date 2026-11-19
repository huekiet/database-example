-- exercises/03-locking/queries/03-session-b-blocked-update.sql
-- Session B: update the same row. The UPDATE blocks on A's row lock until A
-- commits (or rolls back), then proceeds. Run it while A is holding the lock.
SELECT clock_timestamp() AS b_started_at;

BEGIN;
UPDATE users SET name = 'updated-by-B' WHERE id = 1;
COMMIT;

SELECT clock_timestamp() AS b_finished_at;
SELECT id, name, xmin FROM users WHERE id = 1;
