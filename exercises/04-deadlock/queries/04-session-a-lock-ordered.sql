-- exercises/04-deadlock/queries/04-session-a-lock-ordered.sql
-- Fixed version, session A: lock both rows upfront in ascending id order
-- (x, then y) with one SELECT ... FOR UPDATE, then UPDATE.
-- Any transaction that touches both rows uses the same lock order, so a cycle
-- cannot form.
--
-- Run with: psql -v hold_seconds=2 -f ...
BEGIN;

-- Lock every row upfront in deterministic ascending id order.
SELECT id FROM users WHERE id = ANY(ARRAY[1, 2]) ORDER BY id FOR UPDATE;

SELECT clock_timestamp() AS a_locked_both_at;
SELECT pg_sleep(:hold_seconds);

-- Update order does not matter now — both locks are already held.
UPDATE users SET name = 'x-by-A' WHERE id = 1;
UPDATE users SET name = 'y-by-A' WHERE id = 2;

COMMIT;

SELECT clock_timestamp() AS a_committed_at;
SELECT id, name FROM users WHERE id IN (1, 2) ORDER BY id;
