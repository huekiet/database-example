#!/usr/bin/env node
'use strict';
//
// Demonstration: ordered locks acquired UPFRONT, then UPDATEs in any order.
//   A: SELECT FOR UPDATE ORDER BY id (1,2), then UPDATE id=1, then id=2
//   B: SELECT FOR UPDATE ORDER BY id (1,2), then UPDATE id=2, then id=1
//
// Both grab both row locks before any UPDATE, so even though B updates in
// reverse order, no deadlock is possible.
//
const { Client } = require('pg');

const ROW_X = 1;
const ROW_Y = 2;
const HOLD_SECONDS = 0.4;

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

async function runOrderedThenReverse(label, updateOrder) {
  // updateOrder: array of [{id, value}] in the order to UPDATE
  const client = await connect();
  const startedAt = Date.now();

  try {
    await client.query('BEGIN');

    // Lock both rows upfront in ascending id order
    await client.query(
      'SELECT id FROM users WHERE id = ANY($1::int[]) ORDER BY id FOR UPDATE',
      [[ROW_X, ROW_Y]]
    );

    // Hold locks briefly so the other session can contend
    await client.query('SELECT pg_sleep($1)', [HOLD_SECONDS]);

    // Update in the specified order (B reverses: id=2 then id=1)
    for (const { id, value } of updateOrder) {
      await client.query('UPDATE users SET name = $1 WHERE id = $2', [value, id]);
    }

    await client.query('COMMIT');
    return { label, committed: true, attempt: 1, ms: Date.now() - startedAt };
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

async function main() {
  await resetRows();

  console.log('=== Ordered locks upfront, then UPDATEs in reverse order ===');
  console.log(`A: SELECT FOR UPDATE ORDER BY id (1,2) -> UPDATE id=1 -> UPDATE id=2`);
  console.log(`B: SELECT FOR UPDATE ORDER BY id (1,2) -> UPDATE id=2 -> UPDATE id=1`);
  console.log('');

  const startedAt = Date.now();
  const results = await Promise.all([
    runOrderedThenReverse('A', [
      { id: ROW_X, value: 'x-by-A' },
      { id: ROW_Y, value: 'y-by-A' },
    ]),
    runOrderedThenReverse('B', [
      { id: ROW_Y, value: 'y-by-B' },
      { id: ROW_X, value: 'x-by-B' },
    ]),
  ]);
  const elapsed = ((Date.now() - startedAt) / 1000).toFixed(2);

  for (const r of results) {
    const seconds = (r.ms / 1000).toFixed(2);
    if (r.committed) {
      console.log(`${r.label}: COMMITTED in ${seconds}s`);
    } else {
      console.log(
        `${r.label}: ABORTED in ${seconds}s [${r.code || 'unknown'}] ${r.message || ''}`
      );
      if (r.detail) console.log(`   detail: ${r.detail}`);
    }
  }
  console.log(`Total wall time: ${elapsed}s`);
  console.log('');
  await printRows();
  console.log('');

  if (results.every((r) => r.committed)) {
    console.log(
      'Result: both committed. B updated id=2 first but already held both locks, '
      + 'so no deadlock was possible.'
    );
  } else {
    process.exitCode = 1;
    console.log('WARNING: deadlock still occurred.');
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
