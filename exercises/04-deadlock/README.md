# Exercise 4 — Deadlocks (A Waits for B, B Waits for A)

## Goal

Reproduce a classic **ABBA deadlock** and fix it in application code:

- **x** = `users.id = 1`, **y** = `users.id = 2`.
- Transaction **A** locks **x**, then requests **y**.
- Transaction **B** locks **y**, then requests **x**.
- Each holds a row the other one needs, so neither can continue.
- PostgreSQL detects the cycle after `deadlock_timeout` and aborts **one**
  session with SQLSTATE `40P01` (`deadlock_detected`). The other commits.
- The Node.js version shows the fix: lock rows in a **consistent order** and
  **retry** on `40P01` / `40001`.

Unlike the previous exercises, this one is about correctness under concurrency,
not throughput.

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

4. For the Node.js version, Node.js 18+ and npm are required. The database port
   is published by `docker-compose.yml` (`localhost:5432`), so no extra
   container is needed.

## Query files

| File | Purpose |
|------|---------|
| `01-reset-demo-rows.sql` | Reset x/y to `user_1` / `user_2` |
| `02-session-a-lock-x-then-y.sql` | A: `UPDATE` x, sleep, `UPDATE` y (deadlock side) |
| `03-session-b-lock-y-then-x.sql` | B: `UPDATE` y, sleep, `UPDATE` x (deadlock side) |
| `04-session-a-lock-ordered.sql` | A: lock x, sleep, lock y (fixed order) |
| `05-session-b-lock-ordered.sql` | B: lock x, then y (same order) |
| `06-observe-deadlock.sql` | `pg_stat_activity` / `pg_locks` snapshot of the cycle |
| `07-current-rows.sql` | Final x/y values and `xmin` |
| `08-waiting-pair-check.sql` | Counts sessions waiting on `transactionid` |

`02` and `03` take `-v pause_seconds=N` and `-v deadlock_timeout=5s`; `04` takes
`-v hold_seconds=N`.

## How to run

### SQL demo (PowerShell)

From the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\exercises\04-deadlock\deadlock-demo.ps1
```

Options:

```powershell
-PauseSeconds 4           # time each session holds its first row (default 4)
-DeadlockTimeout 5s       # how long a waiter waits before checking for a cycle
-OrderedHoldSeconds 2     # hold time in the fixed-order demo
```

The script:

1. Resets x/y.
2. Starts A and B simultaneously. Both take their first row, sleep, then request
   the other row.
3. Polls `pg_stat_activity` until **two** sessions are waiting on
   `transactionid`, then prints the lock snapshot.
4. Waits for both sessions and reports exit codes and final row values.
5. Repeats with both sessions using the same `x -> y` order.
6. Resets the rows.

`deadlock_timeout` is raised to `5s` in the demo so the cycle stays visible long
enough to inspect it. The PostgreSQL default is `1s`.

### Node.js demo and fix

From the repository root:

```powershell
cd exercises\04-deadlock\node
npm install

# Naive version: opposite lock order -> one transaction aborts with 40P01
npm run deadlock

# Fixed version: ordered locks + retry -> both transactions commit
npm run fixed
```

The scripts connect to `localhost:5432` with the `benchmark` user and database.
Override the defaults with standard variables:

```powershell
$env:PGHOST='localhost'
$env:PGPORT='5432'
$env:PGUSER='benchmark'
$env:PGPASSWORD='benchmark'
$env:PGDATABASE='benchmark'
```

`deadlock-demo.js` runs two clients concurrently, each using a different lock
order. `deadlock-fixed.js` runs the same two clients with one ordered
`SELECT ... FOR UPDATE` and a retry loop. Both scripts reset x/y when they
finish.

### Manual two-terminal version

Terminal A — lock x, then request y after 4 seconds:

```powershell
docker exec -i pg-benchmark psql -U benchmark -d benchmark -v pause_seconds=4 -v deadlock_timeout=5s `
  -f /exercises/04-deadlock/queries/02-session-a-lock-x-then-y.sql
```

Terminal B — immediately start the opposite order:

```powershell
docker exec -i pg-benchmark psql -U benchmark -d benchmark -v pause_seconds=4 -v deadlock_timeout=5s `
  -f /exercises/04-deadlock/queries/03-session-b-lock-y-then-x.sql
```

Terminal C — inspect the cycle while both are waiting:

```powershell
docker exec -i pg-benchmark psql -U benchmark -d benchmark `
  -f /exercises/04-deadlock/queries/06-observe-deadlock.sql
```

One of the terminals exits with code `3` and:

```text
ERROR:  deadlock detected
DETAIL:  Process 92 waits for ShareLock on transaction 865; blocked by process 91.
Process 91 waits for ShareLock on transaction 864; blocked by process 92.
```

Fixed-order manual version:

```powershell
# Terminal A
docker exec -i pg-benchmark psql -U benchmark -d benchmark -v hold_seconds=2 `
  -f /exercises/04-deadlock/queries/04-session-a-lock-ordered.sql

# Terminal B, started while A is sleeping
docker exec -i pg-benchmark psql -U benchmark -d benchmark `
  -f /exercises/04-deadlock/queries/05-session-b-lock-ordered.sql
```

Reset the demo rows:

```powershell
docker exec -i pg-benchmark psql -U benchmark -d benchmark `
  -f /exercises/04-deadlock/queries/01-reset-demo-rows.sql
```

## What to look for

- **`wait_event_type = Lock`, `wait_event = transactionid`** on both sessions.
- **`pg_blocking_pids` forms a cycle:** A is blocked by B and B is blocked by A.
- In `pg_locks`, each transaction holds a granted `transactionid`
  `ExclusiveLock` and has a **non-granted** `transactionid` `ShareLock` on the
  other transaction ID.
- **`40P01` / `deadlock detected`** in psql, or `error.code === '40P01'` in
  Node.js. psql exits with status `3` because `ON_ERROR_STOP=1` is set.
- The aborted transaction rolls back **all** of its work; the survivor commits.
  Which session is chosen as the victim is not deterministic.
- In the fixed version only **one** session waits at a time. B waits at the
  first row (`x`), then proceeds after A commits; there is no cycle.

## Expected outcome

Measured on the seeded dataset (see [REPORT.md](REPORT.md)):

| Run | Result |
|-----|--------|
| SQL deadlock demo | Both wait; **B aborted** with `40P01`, A committed; total **9.46 s** (4 s pause + 5 s detection + overhead) |
| SQL fixed order | Both commit; total **2.55 s**; B waits for A at x |
| Node naive (opposite order) | **A aborted** with `40P01` after 2.02 s, B committed in 2.02 s |
| Node fixed (ordered + retry) | Both commit on attempt 1; A in 0.42 s, B in 0.83 s |

Final values depend on which transaction commits last (`x-by-A`/`y-by-A` or
`x-by-B`/`y-by-B`); both runs above end with the survivor's values, then the
demo resets the rows to `user_1` / `user_2`.

## The Node.js fix explained

The essential change is a deterministic lock order:

```js
await client.query('BEGIN');

// Lock every row this transaction needs in one ordered statement.
await client.query(
  'SELECT id FROM users WHERE id = ANY($1::int[]) ORDER BY id FOR UPDATE',
  [[ROW_X, ROW_Y]]
);

// Now update in any order; the locks are already held.
await client.query('UPDATE users SET name = $1 WHERE id = $2', ['x-by-A', ROW_X]);
await client.query('UPDATE users SET name = $1 WHERE id = $2', ['y-by-A', ROW_Y]);

await client.query('COMMIT');
```

Why it works:

1. **No hold-and-wait cycle.** Both transactions request row 1 first. The second
   one blocks there and holds nothing else, so it cannot be the missing piece of
   a cycle.
2. **One statement, one order.** `ORDER BY id` makes the lock acquisition order
   explicit; PostgreSQL's `LockRows` node locks rows in that order.
3. **Retry is still useful.** `deadlock-fixed.js` retries `40P01` and `40001`
   with a short backoff. Ordered locking removes this particular deadlock, but
   retries cover unexpected lock-order changes and serialization failures.
4. **Keep transactions short.** Do not hold locks while waiting on network I/O,
   user input, or unrelated work. `lock_timeout` / `statement_timeout` bound the
   damage when a transaction does get stuck.

Alternatives that also avoid this deadlock:

- Lock a single parent/header row (for example an account row) before touching
  child rows, so all writers serialize on the same object.
- Use a PostgreSQL advisory lock keyed by the logical resource.
- Use `SKIP LOCKED` for queue-style workloads where waiting is not desirable.

## Cleanup

```bash
docker compose stop        # keep the seeded data volume
docker compose down -v     # remove the container and the 1M rows
```
