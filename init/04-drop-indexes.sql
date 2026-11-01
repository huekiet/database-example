-- 04-drop-indexes.sql
-- Remove supporting indexes so you can benchmark "WITHOUT INDEX".

\set ON_ERROR_STOP on

DROP INDEX IF EXISTS idx_orders_user_id;
DROP INDEX IF EXISTS idx_orders_order_date;
DROP INDEX IF EXISTS idx_orders_status;
DROP INDEX IF EXISTS idx_orders_user_date;
DROP INDEX IF EXISTS idx_users_email;

ANALYZE orders;
ANALYZE users;

SELECT 'Indexes dropped' AS status;
