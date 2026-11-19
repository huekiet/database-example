#!/usr/bin/env node
'use strict';

// exercises/deadlock/node/deadlock-demo.js
//
// Reproduces the ABBA deadlock with two PostgreSQL clients:
//   A: UPDATE x (id 1) -> sleep -> UPDATE y (id 2)
//   B: UPDATE y (id 2) -> sleep -> UPDATE x (id 1)
//
// Both transactions hold one row and request the other, so PostgreSQL detects
// the cycle and aborts one of them with SQLSTATE 40P01 (deadlock_detected).

const { Client } = require('pg');

const ROW_X = 1;
const ROW_Y = 2;
const HOLD_SECONDS = 1;

const baseConfig = {
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT || 5432),
  user: process.env.PGUSER || 'benchmark',
  password: process.env.PGPASSWORD || 'benchmark',
  database: process.env.PGDATABASE || 'benchmark',
};

async function connect() {
  const client = new Client(baseConfig);
  await client.connect();
  return client;
}

async function resetRows() {
  const client = await connect();
  try {
    await client.query("UPDATE users SET name = 'user_' || id WHERE id IN (1, 2)");
  } finally {
    await client.end().catch(() => {});
  }
}

async function printRows() {
  const client = await connect();
  try {
    const { rows } = await client.query(
      'SELECT id, name FROM users WHERE id IN (1, 2) ORDER BY id'
    );
    const text = rows.map((row) => `${row.id}=${row.name}`).join(', ');
    console.log(`Rows: ${text}`);
  } finally {
    await client.end().catch(() => {});
  }
}

async function runOppositeOrder(label, firstId, secondId, firstValue, secondValue) {
  const client = await connect();
  const startedAt = Date.now();

  try {
    await client.query('BEGIN');

    // Each transaction takes a different row first...
    await client.query('UPDATE users SET name = $1 WHERE id = $2', [firstValue, firstId]);

    // ...then waits while still holding it, so both sessions are holding a row
    // before either one asks for the other row.
    await client.query('SELECT pg_sleep($1)', [HOLD_SECONDS]);

    // This is where the cycle closes.
    await client.query('UPDATE users SET name = $1 WHERE id = $2', [secondValue, secondId]);

    await client.query('COMMIT');
    return { label, committed: true, ms: Date.now() - startedAt };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    return {
      label,
      committed: false,
      code: error.code,
      message: error.message,
      detail: error.detail,
      ms: Date.now() - startedAt,
    };
  } finally {
    await client.end().catch(() => {});
  }
}

function printResult(result, path) {
  const seconds = (result.ms / 1000).toFixed(2);
  if (result.committed) {
    console.log(`${result.label} (${path}): COMMITTED in ${seconds}s`);
  } else {
    console.log(
      `${result.label} (${path}): ABORTED in ${seconds}s ` +
        `[${result.code || 'unknown'}] ${result.message || ''}`
    );
    if (result.detail) {
      console.log(`   detail: ${result.detail}`);
    }
  }
}

async function main() {
  await resetRows();

  console.log('=== Naive version: opposite lock order ===');
  console.log(`A locks users.id=${ROW_X} then users.id=${ROW_Y}`);
  console.log(`B locks users.id=${ROW_Y} then users.id=${ROW_X}`);
  console.log('');

  const results = await Promise.all([
    runOppositeOrder('A', ROW_X, ROW_Y, 'x-by-A', 'y-by-A'),
    runOppositeOrder('B', ROW_Y, ROW_X, 'y-by-B', 'x-by-B'),
  ]);

  printResult(results[0], 'x -> y');
  printResult(results[1], 'y -> x');
  console.log('');
  await printRows();

  const aborted = results.filter((result) => !result.committed);
  const deadlocks = aborted.filter((result) => result.code === '40P01');

  if (aborted.length === 1 && deadlocks.length === 1) {
    console.log('');
    console.log('Result: exactly one transaction was aborted with 40P01 (deadlock detected);');
    console.log('the other transaction committed. The aborted transaction rolled back completely.');
  } else {
    process.exitCode = 1;
    console.log('');
    console.log(
      `WARNING: expected one deadlock and one commit, got ${deadlocks.length} deadlock(s) ` +
        `and ${results.length - aborted.length} commit(s).`
    );
  }

  await resetRows();
  console.log('Rows reset to user_1 / user_2.');
}

main().catch(async (error) => {
  if (error.code === 'ECONNREFUSED') {
    console.error(
      `Cannot reach PostgreSQL at ${baseConfig.host}:${baseConfig.port}. ` +
        'Start it with: docker compose up -d'
    );
  } else {
    console.error(error);
  }
  process.exitCode = 1;
});
