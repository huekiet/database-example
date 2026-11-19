-- exercises/03-locking/queries/06-observe-waits.sql
-- Who is blocked by whom, and which locks are granted vs waiting.

-- 1. Sessions that are currently waiting on a lock.
SELECT now()                           AS sampled_at,
       pid,
       state,
       wait_event_type,
       wait_event,
       pg_blocking_pids(pid)           AS blocked_by,
       now() - query_start             AS waiting_for,
       left(query, 60)                 AS query
FROM pg_stat_activity
WHERE datname = current_database()
  AND cardinality(pg_blocking_pids(pid)) > 0
ORDER BY pid;

-- 2. Table/tuple locks on users plus row-lock transaction IDs.
SELECT l.pid,
       l.locktype,
       l.mode,
       l.granted,
       l.transactionid,
       l.page,
       l.tuple,
       pg_blocking_pids(l.pid)         AS blocked_by,
       left(a.query, 50)               AS query
FROM pg_locks l
JOIN pg_stat_activity a USING (pid)
WHERE l.relation = 'users'::regclass
   OR l.locktype = 'transactionid'
ORDER BY l.granted DESC, l.pid, l.locktype;
