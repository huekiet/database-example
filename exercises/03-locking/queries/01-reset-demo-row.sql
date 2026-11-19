-- exercises/03-locking/queries/01-reset-demo-row.sql
-- Reset the single row used by every locking demo.
UPDATE users SET name = 'user_1' WHERE id = 1;
SELECT id, name FROM users WHERE id = 1;
