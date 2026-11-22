# Exercise 4 — Deadlocks: Benchmark Report

Two transactions update the same two rows in opposite order. Each one holds a
row the other needs, PostgreSQL detects the cycle, and one transaction is
aborted with `40P01` (`deadlock_detected`). The Node.js version shows the fix:
consistent lock ordering plus a retry loop.

**Environment:**

| Item | Value |
|------|-------|
| Image | `postgres:15-alpine` (PostgreSQL 15.19) |
| Container | `pg-benchmark` |
| Host | Windows 11 + Docker Desktop, Intel i7-9750H (6C/12T), 16 GB RAM |
| Node.js | 22.22.0, `pg` 8.23.1 |
| Data | 1,000,000 users, 1,000,000 orders |
| Isolation | default `READ COMMITTED` |
| Demo rows | `users.id = 1` (**x**), `users.id = 2` (**y**) |
| Date | 2026-11-20 (UTC) |

**Method:**

- SQL demo: `exercises/04-deadlock/deadlock-demo.ps1` with `-PauseSeconds 4`,
  `-DeadlockTimeout 5s`, `-OrderedHoldSeconds 2`.
- Node demos: `deadlock-demo.js` (opposite order), `deadlock-fixed.js`
  (ordered `SELECT ... FOR UPDATE` + retry), and `deadlock-ordered-then-reversed.js`
  (ordered locks upfront, then UPDATEs in reverse order), with server-side
  `pg_sleep()` between the lock acquisitions.
- Deadlock latency is deliberately raised to 5 s for the SQL demo so the cycle
  can be sampled; PostgreSQL's default `deadlock_timeout` is 1 s.

## Scenario 1 — SQL sessions, opposite order

Timeline (session time is inside the transaction; the total includes process
startup):

| When | Session A (pid 91) | Session B (pid 92) |
|------|--------------------|--------------------|
| T+0.0 | `UPDATE users ... WHERE id = 1` → **holds x** | `UPDATE users ... WHERE id = 2` → **holds y** |
| T+4.0 | `pg_sleep(4)` ends; requests y → **waits** | `pg_sleep(4)` ends; requests x → **waits** |
| T+4.1 | blocked by B | blocked by A |
| T+9.0 | detector aborts B; A's `UPDATE y` proceeds | **aborted with 40P01**, transaction rolled back |
| T+9.0 | `COMMIT` | |

Observer output while both sessions were waiting (~1 s into the wait):

```text
sampled_at                     pid  state   wait_event_type  wait_event      blocked_by  waiting_for    query
2026-11-18 16:59:54.875628+00  91   active  Lock             transactionid   {92}        00:00:01.0254  UPDATE users SET name = 'y-by-A' WHERE id = 2;
2026-11-18 16:59:54.875628+00  92   active  Lock             transactionid   {91}        00:00:01.1051  UPDATE users SET name = 'x-by-B' WHERE id = 1;
```

The lock table shows the cycle directly — each PID has a non-granted
`transactionid` `ShareLock` on the other transaction:

| pid | locktype | mode | granted | transactionid | blocked_by | meaning |
|----:|----------|------|:-------:|--------------:|------------|---------|
| 91 | `relation` | `RowExclusiveLock` | yes | | `{92}` | A's table write lock (compatible) |
| 91 | `transactionid` | `ExclusiveLock` | yes | 865 | `{92}` | A owns its transaction |
| 91 | `tuple` | `ExclusiveLock` | yes | | `{92}` | A's new tuple version for x |
| 92 | `relation` | `RowExclusiveLock` | yes | | `{91}` | B's table write lock (compatible) |
| 92 | `transactionid` | `ExclusiveLock` | yes | 864 | `{91}` | B owns its transaction |
| 92 | `tuple` | `ExclusiveLock` | yes | | `{91}` | B's new tuple version for y |
| 91 | `transactionid` | `ShareLock` | **no** | 864 | `{92}` | **A waits for B (xid 864)** |
| 92 | `transactionid` | `ShareLock` | **no** | 865 | `{91}` | **B waits for A (xid 865)** |

Result:

- Session A: exit code `0`, committed at `16:59:58.781`.
- Session B: exit code `3`, aborted at `16:59:58.772`:

  ```text
  ERROR:  deadlock detected
  DETAIL:  Process 92 waits for ShareLock on transaction 865; blocked by process 91.
  Process 91 waits for ShareLock on transaction 864; blocked by process 92.
  HINT:  See server log for query details.
  CONTEXT:  while updating tuple (9345,85) in relation "users"
  ```

- Final rows: `1 | x-by-A | xmin=986` and `2 | y-by-A | xmin=986`.
  B's earlier `y-by-B` update was rolled back with the rest of its transaction.
- Total wall time: **9.25 s** (4 s hold + ~5 s `deadlock_timeout` + psql/Docker
  startup).

The PostgreSQL server log records the same event:

```text
2026-11-18 16:59:58.772 UTC [92] ERROR:  deadlock detected
2026-11-18 16:59:58.772 UTC [92] DETAIL:  Process 92 waits for ShareLock on transaction 865; blocked by process 91.
        Process 91 waits for ShareLock on transaction 864; blocked by process 92.
        Process 92: UPDATE users SET name = 'x-by-B' WHERE id = 1;
        Process 91: UPDATE users SET name = 'y-by-A' WHERE id = 2;
```

## Scenario 2 — SQL sessions, consistent lock order

Both sessions lock both rows upfront with `SELECT ... FOR UPDATE ORDER BY id`
(x, then y). B blocks at the first row lock (id=1), holds nothing, then
UPDATEs in reverse order (y, then x) once it holds both locks — proving update
order is irrelevant once all locks are already held:

| When | Session A | Session B |
|------|-----------|-----------|
| T+0.0 | `SELECT ... FOR UPDATE ORDER BY id` → locks id=1, id=2 | `SELECT ... FOR UPDATE ORDER BY id` → blocks on id=1 (holds nothing) |
| T+2.0 | `pg_sleep(2)` ends, `UPDATE id=1`, `UPDATE id=2`, `COMMIT` | — |
| T+2.0 | — | wakes, holds both locks, `UPDATE id=2`, `UPDATE id=1`, `COMMIT` |

Measured output:

```text
Total wall time: 2.18 s
Session A exit code: 0
Session B exit code: 0
Final rows: 1|x-by-B|989
2|y-by-B|989
Result: both sessions committed. B waited for A at the first row lock,
then UPDATEd id=2 first — but already held both locks, so no cycle formed.
```

Both transactions succeeded, with one ordinary lock wait and no cycle. B is the
last writer, so both rows carry B's values. The total is A's 2 s hold plus
startup; B does not add another hold.

## Scenario 3 — Node.js, opposite order

`npm run deadlock` starts two clients concurrently. Each holds one row for 1 s
server-side, then requests the other:

```text
=== Naive version: opposite lock order ===
A locks users.id=1 then users.id=2
B locks users.id=2 then users.id=1

A (x -> y): ABORTED in 2.02s [40P01] deadlock detected
   detail: Process 1636 waits for ShareLock on transaction 856; blocked by process 1637.
Process 1637 waits for ShareLock on transaction 857; blocked by process 1636.
B (y -> x): COMMITTED in 2.02s

Rows: 1=x-by-B, 2=y-by-B
```

The 2.02 s is the 1 s hold plus the default 1 s `deadlock_timeout`; the other
transaction then finishes. In this run A was the victim, while the SQL demo
above aborted B — which session gets aborted is a race and must not be relied
on.

## Scenario 4 — Node.js, fixed version

`npm run fixed` locks both rows in one ordered statement, then UPDATEs in
different orders (A: id=1→2; B: id=2→1) to prove update order is irrelevant once
all locks are held:

```js
await client.query(
  'SELECT id FROM users WHERE id = ANY($1::int[]) ORDER BY id FOR UPDATE',
  [[1, 2]]
);
```

Output:

```text
=== Fixed version: ordered locks upfront, then UPDATEs in any order ===
Both sessions lock users.id=1 then users.id=2 with one ordered SELECT ... FOR UPDATE.
A then UPDATEs id=1 -> id=2.
B then UPDATEs id=2 -> id=1 (reverse order).

A: COMMITTED on attempt 1 in 0.82s
B: COMMITTED on attempt 1 in 0.41s
Total wall time: 0.84s

Rows: 1=x-by-A, 2=y-by-A
```

A acquired both row locks first, held them for 0.4 s, and committed. B was
blocked at the ordered `SELECT ... FOR UPDATE`, then repeated the same work and
committed — even though it UPDATEd id=2 before id=1. Neither transaction ever
held one row while waiting for the other, so no deadlock was possible. The retry
loop exists as a safety net but was not needed here (`attempt 1` for both).

## Why the numbers look like this

- **Deadlock detection is time-based.** A blocked backend waits
  `deadlock_timeout` (default 1 s) before running cycle detection. The SQL demo
  raises it to 5 s so the wait graph can be observed; that is why its total is
  ~9.5 s rather than ~4.5 s.
- **The detection delay is not a lock wait.** The rows are already locked; the
  extra time is the detector deciding who to abort. Lowering
  `deadlock_timeout` makes failures arrive sooner but does not prevent them.
- **The victim is chosen by the detector, not by application priority.** The
  aborted transaction is rolled back completely; any application work done
  before the deadlock is lost unless it is retried.
- **Consistent ordering removes the cycle at its source.** If every transaction
  locks `x` before `y`, the wait-for graph is a chain, not a cycle: B waits for A
  at the first row and holds nothing A needs. The fixed Node run completes in
  about one hold interval (0.4 s) plus B's own hold (0.4 s), not two hold
  intervals in parallel.
- **Node's `pg_sleep()` holds the transaction open.** The sleep runs inside the
  open transaction on the server, so the row lock is definitely held when the
  other client makes its request.

## Key Takeaways

1. **A deadlock is a cycle in the wait-for graph.** Opposite lock order on the
   same two rows is the smallest reproducible example.
2. **PostgreSQL detects deadlocks; it does not prevent them.** After
   `deadlock_timeout`, one transaction gets `40P01` and is rolled back.
3. **Which transaction is aborted is nondeterministic.** Both the SQL and Node
   runs show the same deadlock, but different victims.
4. **Fix the lock order, not the timeout.** Sorting IDs, locking a common
   parent row, or using an advisory lock removes the cycle. `deadlock_timeout`
   only changes how quickly the error appears.
5. **Retry `40P01` and `40001`.** Use a bounded retry with backoff, and make the
   transaction idempotent. Ordered locking fixes this deadlock; retries cover
   the ones introduced later by other code paths.
6. **Keep transactions short and bound waits.** Do not hold locks across
   network calls or user input; set `lock_timeout` / `statement_timeout` as a
   safety net.
7. **Diagnose with the standard views.** `pg_stat_activity.wait_event`,
   `pg_blocking_pids(pid)`, and `pg_locks` show the cycle; the server log
   contains the full `DETAIL` with both queries.

## Caveats

- Single pair of rows, default `READ COMMITTED`; no gap locks, foreign-key
  locks, DDL, or serializable-isolation conflicts are exercised.
- The SQL demo sets `deadlock_timeout = 5s` for observability. With the default
  1 s, the same deadlock aborts about 4 s earlier.
- Timings include ~0.2–0.4 s of `docker exec` / psql / Node startup. The Node
  scripts use server-side sleeps, so their 2.02 s and 0.42/0.83 s figures are
  mostly database time.
- PIDs, transaction IDs, `xmin`, page/tuple locations, and the aborted session
  vary between runs.
- The demo restores `users.id = 1` and `2` to `user_1` / `user_2`; the rest of
  the seeded data is untouched.

## How to Reproduce

```powershell
# SQL demo: deadlock + ordered fix
powershell -ExecutionPolicy Bypass -File .\exercises\04-deadlock\deadlock-demo.ps1

# Node.js: naive deadlock, then the fixed version
cd exercises\04-deadlock\node
npm install
npm run deadlock
npm run fixed
```

Manual two-terminal commands and the Node.js explanation are in
[README.md](README.md).
