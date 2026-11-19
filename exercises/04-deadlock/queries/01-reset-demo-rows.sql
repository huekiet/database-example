-- exercises/04-deadlock/queries/01-reset-demo-rows.sql
-- Reset the two rows used by the deadlock demos:
--   x = users.id 1, y = users.id 2
UPDATE users SET name = 'user_' || id WHERE id IN (1, 2);

SELECT id, name FROM users WHERE id IN (1, 2) ORDER BY id;
