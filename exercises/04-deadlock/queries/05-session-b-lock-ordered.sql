-- exercises/04-deadlock/queries/05-session-b-lock-ordered.sql
-- Fixed version, session B: lock both rows upfront in ascending id order
-- (x, then y) — same order as session A — then UPDATE in reverse order
-- (y, then x) to prove that update order is irrelevant once all locks are
-- already held. B waits for A at the first row lock, holds nothing else,
-- so no cycle can form.
BEGIN;

-- Lock every row upfront in deterministic ascending id order (same as A).
SELECT id FROM users WHERE id = ANY(ARRAY[1, 2]) ORDER BY id FOR UPDATE;

-- Update in reverse order on purpose — both locks are already held.
UPDATE users SET name = 'y-by-B' WHERE id = 2;
UPDATE users SET name = 'x-by-B' WHERE id = 1;

COMMIT;

SELECT clock_timestamp() AS b_committed_at;
SELECT id, name FROM users WHERE id IN (1, 2) ORDER BY id;
