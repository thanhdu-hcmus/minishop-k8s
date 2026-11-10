/*
 * Derived from Apache-2.0 kumahq/kuma-demo api/app/postgresql.js at db9e133.
 * Modified for a transactional, parameterized import (#43), and for logging idle
 * pool errors instead of exiting, bounded query and lookup waits, the SQLSTATE
 * helper, and a readiness ping (#39). The destructive import was replaced by a
 * non-destructive seed (#40); see ../LICENSE and ../UPSTREAM.md.
 */

const items = require("../db/items.json");
const { Pool, DatabaseError } = require("pg");
const { positiveInteger, withDeadline } = require("./dependency");
const pino = require('pino');
const logger = pino({ name: 'kuma-backend-pg', level: process.env.PINO_LOG_LEVEL || 'info' });
const dns = require('dns');
const dnsPromises = dns.promises;

const pool = new Pool({
  user: process.env.POSTGRES_USER || "kumademo",
  host: process.env.POSTGRES_HOST || "localhost",
  database: process.env.POSTGRES_DB || "kumademo",
  password: process.env.POSTGRES_PASSWORD || "kumademo",
  port: process.env.POSTGRES_PORT_NUM || 5432, //POSTGRES_PORT environmental variable is taken on K8S
  idleTimeoutMillis: positiveInteger(process.env.POSTGRES_IDLE_TIMEOUT, 10000),
  connectionTimeoutMillis: positiveInteger(process.env.POSTGRES_CONNECTION_TIMEOUT, 2000),
  // Bounds each query, so a PostgreSQL that accepts connections but stops
  // answering fails the request instead of hanging it. The pool discards the client.
  query_timeout: positiveInteger(process.env.POSTGRES_QUERY_TIMEOUT, 5000),
});

const dnsOptions = {
  all: true,
};

// pg-pool emits 'error' when an idle pooled connection drops, for example when
// PostgreSQL restarts. The pool has already removed that client and opens a new
// one on the next query, so log it and keep serving instead of exiting.
pool.on("error", (err) => {
  logger.error({ err }, 'idle postgresql client error; the pool discarded it');
});

// The SQLSTATE of a PostgreSQL server error, such as 42P01 for a missing table,
// or undefined for client-side and network errors. Safe to return to callers.
const sqlState = (error) => (error instanceof DatabaseError ? error.code : undefined);

const search = async (itemName) => {
  // pg bounds its own lookup with connectionTimeoutMillis; bound this logging
  // lookup the same way so an unresolvable host cannot stall the request.
  const result = await withDeadline(
    dnsPromises.lookup(pool.options.host, dnsOptions),
    pool.options.connectionTimeoutMillis,
    'DNS lookup for host ' + pool.options.host + ' timed out'
  );
  logger.info('DNS lookup for host ' + pool.options.host + ': %j', result);
  return await pool.query(
    "SELECT data FROM marketItems WHERE name ILIKE $1",
    [`%${itemName}%`]
  );
};

// Readiness check: a round trip that needs a connection but no table, so an
// unseeded database is still ready before the seed Job runs.
const ping = async (timeoutMs) =>
  withDeadline(
    pool.query({ text: "SELECT 1", query_timeout: timeoutMs }),
    timeoutMs,
    `PostgreSQL readiness check timed out after ${timeoutMs} ms`
  );

// Transaction-scoped advisory lock key that serializes concurrent seed runs, for
// example a Job retry that overlaps a slow first attempt. Any constant works as
// long as nothing else in this database uses it.
const SEED_LOCK_KEY = 4046;

// Non-destructive seed for the seed Job (#40). It never drops, truncates, or
// updates: it creates marketItems only if it is missing and inserts the seed rows
// only when the table is empty. ON CONFLICT DO NOTHING is a second guard. The
// whole run is one transaction, so a failure leaves the table as it was.
// Resolves { inserted, skipped }; skipped is true when the table already had rows.
const seedData = async () => {
  const client = await pool.connect();
  // pg-pool detaches its idle listener at checkout, so without this an 'error' event
  // from a dropped connection is unhandled and kills the process. The failed query
  // still rejects, so this listener only logs.
  const onClientError = (error) => {
    logger.error({ err: error }, 'postgresql client error during seed');
  };
  client.on("error", onClientError);
  let rollbackError;
  try {
    await client.query("BEGIN");
    await client.query("SELECT pg_advisory_xact_lock($1)", [SEED_LOCK_KEY]);
    await client.query(
      `CREATE TABLE IF NOT EXISTS marketItems(
        index INTEGER PRIMARY KEY,
        name TEXT,
        data JSONB
      )`
    );
    const existing = await client.query("SELECT EXISTS (SELECT 1 FROM marketItems) AS populated");
    if (existing.rows[0].populated) {
      await client.query("COMMIT");
      return { inserted: 0, skipped: true };
    }
    // One parameterized statement for all rows: the seed data never becomes SQL text.
    const result = await client.query(
      `INSERT INTO marketItems (index, name, data)
        SELECT (item->>'index')::integer, item->>'name', item
        FROM jsonb_array_elements($1::jsonb) AS item
        ON CONFLICT (index) DO NOTHING`,
      [JSON.stringify(items)]
    );
    await client.query("COMMIT");
    return { inserted: result.rowCount, skipped: false };
  } catch (error) {
    logger.error({ err: error }, 'postgresql seed failed');
    try {
      await client.query("ROLLBACK");
    } catch (failure) {
      logger.error({ err: failure }, 'postgresql rollback failed');
      rollbackError = failure;
    }
    throw error;
  } finally {
    client.removeListener("error", onClientError);
    // Passing an error makes the pool discard a connection left in an unknown state.
    client.release(rollbackError);
  }
};


module.exports = Object.assign({
  pool,
  sqlState,
  search,
  ping,
  seedData,
});
