-- exercises/04-deadlock/queries/06-observe-deadlock.sql
-- Snapshot while both sessions are waiting for each other.

-- 1. Sessions waiting on a lock and who blocks them.
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

-- 2. Locks on x/y plus transaction IDs. A cycle is visible when each PID
--    appears in the other PID's blocked_by list.
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
WHERE (l.relation = 'users'::regclass OR l.locktype = 'transactionid')
  AND a.datname = current_database()
ORDER BY l.granted DESC, l.pid, l.locktype;
