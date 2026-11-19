# Exercise 3 — Row Locks (Two Writers, One Row)

## Goal

Make two transactions update the **same row** and observe what happens:

- the second writer **blocks** instead of failing,
- the wait shows up as `wait_event_type = Lock`, `wait_event = transactionid`,
- the lock is released only when the first transaction ends,
- waiting writers can give up via `lock_timeout` or fail instantly with `NOWAIT`,
- after the block, the second writer overwrites the first one's value (a lost
  update under `READ COMMITTED`).

All demos touch a single row (`users.id = 1`), so they are safe to run on the
seeded benchmark data.

## Prerequisites

1. Docker Desktop (or Docker Engine + Compose) is running.
2. From the repository root, start the database:

   ```bash
   docker compose up -d
   ```

3. Wait until the seed has finished (first start only):

   ```powershell
   docker exec pg-benchmark psql -U benchmark -d benchmark -c "SELECT 'users', COUNT(*) FROM users UNION ALL SELECT 'orders', COUNT(*) FROM orders;"
   ```

`exercises/` is mounted read-only at `/exercises`, so the SQL files below are
available inside the container.

## Query files

| File | Purpose |
|------|---------|
| `01-reset-demo-row.sql` | Reset `users.id = 1` to `name = 'user_1'` and show it |
| `02-session-a-hold-lock.sql` | Session A: `UPDATE` the row, `pg_sleep(:lock_seconds)`, `COMMIT` |
| `03-session-b-blocked-update.sql` | Session B: `UPDATE` the same row and block until A commits |
| `04-session-b-lock-timeout.sql` | Session B with `lock_timeout` — aborts instead of waiting |
| `05-session-b-nowait.sql` | `SELECT ... FOR UPDATE NOWAIT` — fails immediately |
| `06-observe-waits.sql` | `pg_stat_activity`, `pg_locks`, `pg_blocking_pids` snapshot |
| `07-lock-held-check.sql` | Used by the runner to detect that A holds the row lock |
| `08-current-row.sql` | Show the final demo row |

`02` takes a psql variable: `-v lock_seconds=10`; `04` takes
`-v lock_timeout=2s`.

## How to run

### Automated demo (recommended)

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\exercises\03-locking\locking-demo.ps1
```

Options:

```powershell
-LockSeconds 15          # how long session A holds the lock (default 10)
-LockTimeoutSeconds 3    # lock_timeout used in demo 2 (default 2)
```

The script:

1. Resets the demo row.
2. Starts session A in the background and waits until it holds the lock.
3. Starts session B, waits 2 s, prints the blocked session and lock table.
4. Waits for both sessions and prints B's wall time, exit code, and final row.
5. Repeats with `lock_timeout` and with `NOWAIT`.
6. Restores `users.id = 1` to `user_1`.

### Manual (two terminals)

Terminal A — hold the lock for 10 seconds:

```powershell
docker exec -i pg-benchmark psql -U benchmark -d benchmark -v lock_seconds=10 `
  -f /exercises/03-locking/queries/02-session-a-hold-lock.sql
```

Terminal B — while A is sleeping, update the same row (this blocks):

```powershell
docker exec -i pg-benchmark psql -U benchmark -d benchmark -v ON_ERROR_STOP=1 `
  -f /exercises/03-locking/queries/03-session-b-blocked-update.sql
```

Terminal C — inspect the wait:

```powershell
docker exec -i pg-benchmark psql -U benchmark -d benchmark `
  -f /exercises/03-locking/queries/06-observe-waits.sql
```

Alternatives for session B:

```powershell
# give up after 2 seconds (ERROR: canceling statement due to lock timeout)
docker exec -i pg-benchmark psql -U benchmark -d benchmark -v lock_timeout=2s `
  -f /exercises/03-locking/queries/04-session-b-lock-timeout.sql

# fail immediately (ERROR: could not obtain lock on row)
docker exec -i pg-benchmark psql -U benchmark -d benchmark `
  -f /exercises/03-locking/queries/05-session-b-nowait.sql
```

Reset the row afterwards:

```powershell
docker exec -i pg-benchmark psql -U benchmark -d benchmark `
  -f /exercises/03-locking/queries/01-reset-demo-row.sql
```

## What to look for

- **`wait_event_type = Lock`, `wait_event = transactionid`** — the writer is
  waiting for the transaction that changed the row to finish.
- **`pg_blocking_pids(pid)`** — the PID(s) it is waiting for.
- **`pg_locks`** — the holder has a granted `transactionid` `ExclusiveLock`; the
  waiter has a non-granted `transactionid` `ShareLock` on that transaction ID,
  plus a granted `tuple` lock on the row.
- **`now() - query_start`** — how long the `UPDATE` has been waiting.
- **Plain `SELECT` does not block.** Readers use MVCC and see the pre-update
  value; only writers (and `SELECT ... FOR UPDATE`) wait.
- **Lost update:** after A commits, B's `UPDATE` proceeds and writes its own
  value, replacing A's.

## Expected outcome

From the recorded run in [REPORT.md](REPORT.md):

| Demo | Result |
|------|--------|
| B waits for A (A sleeps 10 s) | B completes after **9.96 s**, exit code 0; final value `updated-by-B` (A's value lost) |
| B with `lock_timeout = 2s` | aborts after **2.19 s**, exit code 3, `ERROR: canceling statement due to lock timeout` |
| B with `NOWAIT` | aborts in **0.20 s**, exit code 3, `ERROR: could not obtain lock on row` |

The elapsed times include ~0.2 s of `docker exec` + `psql` startup; the lock
waits themselves are ~10 s, ~2 s, and ~0 s.

## Notes and caveats

- Default isolation is `READ COMMITTED`; the `UPDATE` re-reads the latest row
  version after the lock is released, which is why the last writer wins.
- These are row-level locks: other rows remain writable, and readers are not
  blocked.
- The demo assumes no other session is modifying `users.id = 1`.
- Deadlocks are a separate scenario (two sessions locking rows in opposite
  order); the fixes are consistent lock ordering, short transactions, and
  `lock_timeout` to avoid infinite waits.

## Cleanup

```bash
docker compose stop        # keep the seeded data volume
docker compose down -v     # remove the container and the 1M rows
```
