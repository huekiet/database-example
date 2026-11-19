#!/usr/bin/env node
'use strict';

// exercises/deadlock/node/deadlock-fixed.js
//
// The simple fix for the ABBA deadlock:
//
//   1. Lock every row a transaction needs in one deterministic order
//      (ascending primary key) with a single SELECT ... FOR UPDATE.
//   2. Retry on deadlock_detected (40P01) / serialization_failure (40001).
//
// Both sessions call runOrdered() and therefore take x (id 1) before y (id 2).
// The second session waits at the ordered lock statement; neither can hold one
// row while waiting for the other.

const { Client } = require('pg');

const ROW_X = 1;
const ROW_Y = 2;
const HOLD_SECONDS = 0.4;
const MAX_ATTEMPTS = 3;

const baseConfig = {
  host: process.env.PGHOST || 'localhost',
  port: Number(process.env.PGPORT || 5432),
  user: process.env.PGUSER || 'benchmark',
  password: process.env.PGPASSWORD || 'benchmark',
  database: process.env.PGDATABASE || 'benchmark',
};

const RETRYABLE_CODES = new Set(['40P01', '40001']);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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

async function runOrdered(label) {
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
    const client = await connect();
    const startedAt = Date.now();

    try {
      await client.query('BEGIN');

      // The key line: one statement, deterministic order, all rows at once.
      // PostgreSQL locks the rows in ORDER BY id order (x first, then y).
      await client.query(
        'SELECT id FROM users WHERE id = ANY($1::int[]) ORDER BY id FOR UPDATE',
        [[ROW_X, ROW_Y]]
      );

      // Hold both row locks for a moment so the other session has to wait.
      await client.query('SELECT pg_sleep($1)', [HOLD_SECONDS]);

      await client.query('UPDATE users SET name = $1 WHERE id = $2', [
        `x-by-${label}`,
        ROW_X,
      ]);
      await client.query('UPDATE users SET name = $1 WHERE id = $2', [
        `y-by-${label}`,
        ROW_Y,
      ]);

      await client.query('COMMIT');
      return { label, committed: true, attempt, ms: Date.now() - startedAt };
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});

      // Ordered locking should prevent this, but retrying is still the right
      // safety net for multi-row transactions and serialization failures.
      if (RETRYABLE_CODES.has(error.code) && attempt < MAX_ATTEMPTS) {
        await sleep(100 * attempt);
        continue;
      }

      return {
        label,
        committed: false,
        attempt,
        code: error.code,
        message: error.message,
        ms: Date.now() - startedAt,
      };
    } finally {
      await client.end().catch(() => {});
    }
  }

  return { label, committed: false, attempt: MAX_ATTEMPTS, message: 'no attempts left' };
}

function printResult(result) {
  const seconds = (result.ms / 1000).toFixed(2);
  if (result.committed) {
    console.log(
      `${result.label}: COMMITTED on attempt ${result.attempt} in ${seconds}s`
    );
  } else {
    console.log(
      `${result.label}: ABORTED on attempt ${result.attempt} in ${seconds}s ` +
        `[${result.code || 'unknown'}] ${result.message || ''}`
    );
  }
}

async function main() {
  await resetRows();

  console.log('=== Fixed version: ordered locks + retry ===');
  console.log(
    `Both sessions lock users.id=${ROW_X} then users.id=${ROW_Y} with one ordered SELECT ... FOR UPDATE.`
  );
  console.log('');

  const startedAt = Date.now();
  const results = await Promise.all([runOrdered('A'), runOrdered('B')]);
  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(2);

  printResult(results[0]);
  printResult(results[1]);
  console.log(`Total wall time: ${elapsed}s`);
  console.log('');
  await printRows();

  const allCommitted = results.every((result) => result.committed);
  if (allCommitted) {
    console.log('');
    console.log('Result: both transactions committed. B waited for A at the first row');
    console.log('instead of holding y while waiting for x, so no deadlock was possible.');
  } else {
    process.exitCode = 1;
    console.log('');
    console.log('WARNING: one or more transactions failed even with ordered locking.');
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
