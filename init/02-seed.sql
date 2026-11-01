-- 02-seed.sql
-- Seed 1,000,000 users and 1,000,000 orders.
-- Idempotent: skips if data already present.

\set ON_ERROR_STOP on

DO $$
BEGIN
  IF (SELECT COUNT(*) FROM users) = 0 THEN
    INSERT INTO users (name, email, created_at)
    SELECT
        'user_' || g,
        'user_' || g || '@example.com',
        TIMESTAMP '2024-01-01 00:00:00' + (random() * (TIMESTAMP '2026-01-01 00:00:00' - TIMESTAMP '2024-01-01 00:00:00'))
    FROM generate_series(1, 1000000) AS g;
  END IF;

  IF (SELECT COUNT(*) FROM orders) = 0 THEN
    INSERT INTO orders (user_id, product, amount, status, order_date)
    SELECT
        (1 + (random() * 999999))::int,
        (ARRAY['laptop','mouse','keyboard','monitor','headphones','phone','case','charger'])[1 + (random() * 7)::int],
        round((random() * 2000 + 5)::numeric, 2),
        (ARRAY['pending','paid','shipped','delivered','cancelled'])[1 + (random() * 4)::int],
        TIMESTAMP '2024-01-01 00:00:00' + (random() * (TIMESTAMP '2026-01-01 00:00:00' - TIMESTAMP '2024-01-01 00:00:00'))
    FROM generate_series(1, 1000000) AS g;
  END IF;
END $$;

ANALYZE users;
ANALYZE orders;

SELECT 'users' AS tbl, COUNT(*) AS rows FROM users
UNION ALL
SELECT 'orders', COUNT(*) FROM orders;
