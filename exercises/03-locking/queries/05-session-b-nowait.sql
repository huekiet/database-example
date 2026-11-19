-- exercises/03-locking/queries/05-session-b-nowait.sql
-- Alternative to waiting: fail immediately when the row is locked.
-- SQLSTATE 55P03, lock_not_available.
BEGIN;
SELECT id, name FROM users WHERE id = 1 FOR UPDATE NOWAIT;
COMMIT;
