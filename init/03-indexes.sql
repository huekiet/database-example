-- 03-indexes.sql
-- Indexes used for the "WITH INDEX" benchmark.
-- Apply separately: psql -f init/03-indexes.sql
-- Drop with:        psql -f init/04-drop-indexes.sql

\set ON_ERROR_STOP on

CREATE INDEX IF NOT EXISTS idx_orders_user_id      ON orders(user_id);
CREATE INDEX IF NOT EXISTS idx_orders_order_date   ON orders(order_date);
CREATE INDEX IF NOT EXISTS idx_orders_status       ON orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_user_date    ON orders(user_id, order_date);
CREATE INDEX IF NOT EXISTS idx_users_email         ON users(email);

ANALYZE orders;
ANALYZE users;

SELECT 'Indexes created' AS status;
