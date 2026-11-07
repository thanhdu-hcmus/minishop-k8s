/*
 * Derived from Apache-2.0 kumahq/kuma-demo api/app/postgresql.js at db9e133.
 * Modified for a transactional, parameterized import (#43), and for logging idle
 * pool errors instead of exiting, bounded query and lookup waits, the SQLSTATE
 * helper, and a readiness ping (#39); see ../LICENSE and ../UPSTREAM.md.
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
// unseeded database is still ready to accept POST /upload.
const ping = async (timeoutMs) =>
  withDeadline(
    pool.query({ text: "SELECT 1", query_timeout: timeoutMs }),
    timeoutMs,
    `PostgreSQL readiness check timed out after ${timeoutMs} ms`
  );

const importData = async () => {
  const client = await pool.connect();
  // pg-pool detaches its idle listener at checkout, so without this an 'error' event
  // from a dropped connection is unhandled and kills the process. The failed query
  // still rejects, so this listener only logs.
  const onClientError = (error) => {
    logger.error({ err: error }, 'postgresql client error during import');
  };
  client.on("error", onClientError);
  let rollbackError;
  try {
    await client.query("BEGIN");
    await client.query("DROP TABLE IF EXISTS marketItems");
    await client.query(
      `CREATE TABLE marketItems(
        index INTEGER PRIMARY KEY,
        name TEXT,
        data JSONB
      )`
    );
    for (const item of items) {
      await client.query(
        "INSERT INTO marketItems VALUES($1, $2, $3)",
        [item.index, item.name, JSON.stringify(item)]
      );
    }
    await client.query("COMMIT");
  } catch (error) {
    logger.error({ err: error }, 'postgresql import failed');
    try {
      await client.query("ROLLBACK");
    } catch (failure) {
      logger.error({ err: failure }, 'postgresql rollback failed');
      rollbackError = failure;
    }
    throw error;
  } finally {
    logger.debug("Release");
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
  importData,
});
