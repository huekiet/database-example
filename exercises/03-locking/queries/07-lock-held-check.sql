-- exercises/03-locking/queries/07-lock-held-check.sql
-- Returns 1 when some session holds a granted row-write lock on users.
-- Used by the runner to know when session A is holding the row.
SELECT count(*)
FROM pg_locks
WHERE relation = 'users'::regclass
  AND mode = 'RowExclusiveLock'
  AND granted;
