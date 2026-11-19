-- exercises/03-locking/queries/02-session-a-hold-lock.sql
-- Session A: update the row, then hold the row lock for :lock_seconds before
-- committing. Run with: psql -v lock_seconds=10 -f ...
BEGIN;
UPDATE users SET name = 'updated-by-A' WHERE id = 1;
SELECT clock_timestamp() AS a_updated_at;
SELECT pg_sleep(:lock_seconds);
COMMIT;
SELECT clock_timestamp() AS a_committed_at;
