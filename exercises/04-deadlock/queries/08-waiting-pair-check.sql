-- exercises/04-deadlock/queries/08-waiting-pair-check.sql
-- Returns the number of sessions currently waiting for a transaction lock.
-- The deadlock demo waits until this reaches 2 (A waits for B, B waits for A).
SELECT count(*)::int
FROM pg_stat_activity
WHERE datname = current_database()
  AND wait_event_type = 'Lock'
  AND wait_event = 'transactionid';
