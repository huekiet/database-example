-- 01-schema.sql
-- Core tables for index / join benchmarking.
-- Runs automatically on container first-init via docker-entrypoint-initdb.d.

\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS users (
    id         SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(150) NOT NULL UNIQUE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS orders (
    id          SERIAL PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES users(id),
    product     VARCHAR(100) NOT NULL,
    amount      DECIMAL(10,2) NOT NULL,
    status      VARCHAR(20) NOT NULL DEFAULT 'pending',
    order_date  TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Helpful comments
COMMENT ON TABLE users IS 'Benchmark users table (1,000,000 rows)';
COMMENT ON TABLE orders IS 'Benchmark orders table (1,000,000 rows)';

ANALYZE users;
ANALYZE orders;
