# Exercise 3 — Row Locks: Benchmark Report

Simulates two transactions updating the same row and measures the resulting
blocking. A second writer does not fail: it waits for the first transaction to
commit or roll back.

**Environment:**

| Item | Value |
|------|-------|
| Image | `postgres:15-alpine` (PostgreSQL 15.19) |
| Container | `pg-benchmark` |
| Host | Windows 11 + Docker Desktop, Intel i7-9750H (6C/12T), 16 GB RAM |
| Data | 1,000,000 users, 1,000,000 orders |
| Isolation | default `READ COMMITTED` |
| Demo row | `users.id = 1` |
| Date | 2026-11-20 |

**Method:** `exercises/03-locking/locking-demo.ps1` starts session A (which updates
the row and holds the lock for 10 s), then session B (which issues the same
`UPDATE`), samples `pg_stat_activity` / `pg_locks` while B is waiting, and waits
for both sessions. Session B's wall time includes ~0.2 s of Docker/psql startup.

## Scenario 1 — concurrent `UPDATE` on the same row

Timeline:

| When | Session A (holder) | Session B (waiter) |
|------|--------------------|--------------------|
| T+0.0 | `BEGIN; UPDATE users SET name = 'updated-by-A' WHERE id = 1;` → **row lock held** | |
| T+0.4 | `SELECT pg_sleep(10);` (lock still held) | `BEGIN; UPDATE ... WHERE id = 1;` → **blocks** |
| T+2.0 | still sleeping | waiting; observer samples below |
| T+10.0 | `COMMIT` → lock released | `UPDATE` proceeds, `COMMIT` |
| | | done after **9.99 s** wall time, exit code 0 |

Observer output while B was waiting (~2 s into the wait):

```text
sampled_at                     pid  state   wait_event_type  wait_event      blocked_by  waiting_for    query
2026-11-18 16:49:14.628078+00  973  active  Lock             transactionid   {959}       00:00:02.0356  UPDATE users SET name = 'updated-by-B' WHERE id = 1;
```

Lock state at the same moment:

| pid | locktype | mode | granted | transactionid | blocked_by | meaning |
|----:|----------|------|:-------:|--------------:|------------|---------|
| 959 | `relation` | `RowExclusiveLock` | yes | | `{}` | A holds the table write lock |
| 959 | `transactionid` | `ExclusiveLock` | yes | 847 | `{}` | A's transaction owns row 1 |
| 973 | `relation` | `RowExclusiveLock` | yes | | `{959}` | B's table write lock (compatible) |
| 973 | `transactionid` | `ExclusiveLock` | yes | 848 | `{959}` | B's own transaction ID |
| 973 | `tuple` | `ExclusiveLock` | yes | | `{959}` | B pins the tuple it wants |
| 973 | `transactionid` | `ShareLock` | **no** | 847 | `{959}` | **B waits for A's transaction (847)** |

`wait_event = transactionid` and the non-granted `transactionid` `ShareLock`
mean exactly the same thing: B needs A's transaction to finish before it can
modify the row.

Result: B's `UPDATE` succeeded after A committed, and the row ended as
`1 | updated-by-B | xmin=977`. A's value (`updated-by-A`) was **lost**, because
under `READ COMMITTED` the blocked `UPDATE` re-evaluates the row after the lock
is released and writes its own version.

## Scenario 2 — `lock_timeout = 2s`

Session B sets `lock_timeout` before the `UPDATE`:

```sql
SET lock_timeout = '2s';
BEGIN;
UPDATE users SET name = 'updated-by-B-timeout' WHERE id = 1;
COMMIT;
```

Measured: **2.19 s** wall time, exit code **3**:

```text
ERROR:  canceling statement due to lock timeout
CONTEXT:  while updating tuple (9345,94) in relation "users"
```

Instead of waiting for A, the statement aborts with SQLSTATE `55P03`
(`lock_not_available`). The 2.19 s is the 2 s timeout plus psql/docker startup.

## Scenario 3 — `SELECT ... FOR UPDATE NOWAIT`

```sql
BEGIN;
SELECT id, name FROM users WHERE id = 1 FOR UPDATE NOWAIT;
COMMIT;
```

Measured: **0.21 s** wall time, exit code **3**:

```text
ERROR:  could not obtain lock on row in relation "users"
```

`NOWAIT` fails immediately (same SQLSTATE `55P03`) instead of joining the wait
queue. `SKIP LOCKED` is the non-erroring variant used by job queues.

## Key Takeaways

1. **A row lock is held until the transaction ends.** A plain `UPDATE` takes an
   exclusive lock on the row; concurrent writers to the same row serialize.
2. **Blocking, not an error, is the default.** The second writer waits. Only
   `lock_timeout` / `statement_timeout` / `NOWAIT` turn that into an error.
3. **Readers do not block.** MVCC lets other sessions read the previous row
   version; only writers (`UPDATE`/`DELETE`/`SELECT FOR UPDATE`) wait.
4. **Diagnose with the standard views:** `pg_stat_activity.wait_event_type =
   Lock`, `wait_event = transactionid`, `pg_blocking_pids(pid)`, and `pg_locks`
   (`granted = false`).
5. **Waiting is not free.** One slow transaction holds every writer behind it;
   keep transactions short and bound the wait with `lock_timeout` at the
   application level.
6. **Lost updates are possible under `READ COMMITTED`.** If the application
   must read-then-write the same row, use `SELECT ... FOR UPDATE` (or a higher
   isolation level / optimistic version check).
7. **Lock ordering matters.** Two transactions taking the same rows in opposite
   order can deadlock; use a consistent order, retries, and timeouts.

## Caveats

- Single-row demo with the default `READ COMMITTED` isolation; no deadlock,
  DDL, foreign-key, or table-lock contention is exercised here.
- Timings are wall-clock around `docker exec`, so they include ~0.2 s of
  process/connection startup. The actual lock waits are ~10 s, ~2 s, and ~0 s.
- PIDs, transaction IDs, and `xmin` values vary between runs.
- The demo resets `users.id = 1` at the end; the seeded data is otherwise
  untouched.

## How to Reproduce

```powershell
# From the repository root (database already seeded and running)
powershell -ExecutionPolicy Bypass -File .\exercises\03-locking\locking-demo.ps1

# Longer hold time
powershell -ExecutionPolicy Bypass -File .\exercises\03-locking\locking-demo.ps1 -LockSeconds 20
```

Manual two-terminal version: see [README.md](README.md).
