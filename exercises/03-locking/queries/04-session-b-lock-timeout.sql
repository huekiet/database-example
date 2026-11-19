-- exercises/03-locking/queries/04-session-b-lock-timeout.sql
-- Session B with lock_timeout: instead of waiting for A, the UPDATE aborts
-- after the configured interval (SQLSTATE 55P03, lock_not_available).
-- Run with: psql -v lock_timeout=2s -f ...
SET lock_timeout = :'lock_timeout';

BEGIN;
UPDATE users SET name = 'updated-by-B-timeout' WHERE id = 1;
COMMIT;
