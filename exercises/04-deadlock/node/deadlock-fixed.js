#!/usr/bin/env node
'use strict';

// exercises/04-deadlock/node/deadlock-fixed.js
//
// The simple fix for the ABBA deadlock:
//
//   1. Lock every row a transaction needs in one deterministic order
//      (ascending primary key) with a single SELECT ... FOR UPDATE,
//      BEFORE any UPDATE.
//   2. Retry on deadlock_detected (40P01) / serialization_failure (40001).
//
// Both sessions lock x (id 1) then y (id 2) upfront. Session A then UPDATEs
// id=1 -> id=2; Session B intentionally UPDATEs id=2 -> id=1 (reverse order)
// to prove that update order is irrelevant once all locks are already held.
// Neither can hold one row while waiting for the other, so no cycle forms.

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

async function runOrdered(label, updateOrder) {
  // updateOrder: array of [{id, value}] in the order to UPDATE after locking.
  // Both sessions lock rows in ascending id order upfront, but may UPDATE in
  // different orders to prove that update order does not matter once all locks
  // are already held.
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt += 1) {
    const client = await connect();
    const startedAt = Date.now();

    try {
      await client.query('BEGIN');

      // Lock every row upfront in deterministic ascending id order.
      // Both sessions acquire locks on id=1, then id=2 — before any UPDATE.
      await client.query(
        'SELECT id FROM users WHERE id = ANY($1::int[]) ORDER BY id FOR UPDATE',
        [[ROW_X, ROW_Y]]
      );

      // Hold both row locks so the other session can contend.
      await client.query('SELECT pg_sleep($1)', [HOLD_SECONDS]);

      // UPDATE in the specified order. B intentionally reverses (id=2 first)
      // to prove that update order is irrelevant once both locks are held.
      for (const { id, value } of updateOrder) {
        await client.query('UPDATE users SET name = $1 WHERE id = $2', [
          value,
          id,
        ]);
      }

      await client.query('COMMIT');
      return { label, committed: true, attempt, ms: Date.now() - startedAt };
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});

      // Ordered locking should prevent deadlocks, but retrying is still the
      // right safety net for multi-row transactions and serialization failures.
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

  console.log('=== Fixed version: ordered locks upfront, then UPDATEs in any order ===');
  console.log(
    `Both sessions lock users.id=${ROW_X} then users.id=${ROW_Y} with one ordered SELECT ... FOR UPDATE.`
  );
  console.log(`A then UPDATEs id=${ROW_X} -> id=${ROW_Y}.`);
  console.log(`B then UPDATEs id=${ROW_Y} -> id=${ROW_X} (reverse order).`);
  console.log('');

  const startedAt = Date.now();
  const results = await Promise.all([
    runOrdered('A', [
      { id: ROW_X, value: 'x-by-A' },
      { id: ROW_Y, value: 'y-by-A' },
    ]),
    runOrdered('B', [
      { id: ROW_Y, value: 'y-by-B' },
      { id: ROW_X, value: 'x-by-B' },
    ]),
  ]);
  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(2);

  printResult(results[0]);
  printResult(results[1]);
  console.log(`Total wall time: ${elapsed}s`);
  console.log('');
  await printRows();

  const allCommitted = results.every((result) => result.committed);
  if (allCommitted) {
    console.log('');
    console.log(
      'Result: both committed. B UPDATEd id=2 first but already held both locks, '
      + 'so no deadlock was possible.'
    );
  } else {
    process.exitCode = 1;
    console.log('');
    console.log('WARNING: one or more transactions failed even with ordered locking.');
  }

  await resetRows();
  console.log('Rows reset to user_1 / user_2.');
}

main().catch((error) => {
  if (error.code === 'ECONNREFUSED') {
    console.error(
      `Cannot reach PostgreSQL at ${baseConfig.host}:${baseConfig.port}. `
      + 'Start it with: docker compose up -d'
    );
  } else {
    console.error(error);
  }
  process.exitCode = 1;
});
