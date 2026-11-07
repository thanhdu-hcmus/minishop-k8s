const items = require("../db/items.json");
const { Pool } = require("pg");
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
  idleTimeoutMillis: process.env.POSTGRES_IDLE_TIMEOUT || 10000,
  connectionTimeoutMillis: process.env.POSTGRES_CONNECTION_TIMEOUT || 2000,
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

const search = async (itemName) => {
  await dnsPromises.lookup(pool.options.host, dnsOptions).then(async (result) => {
    await logger.info('DNS lookup for host ' + pool.options.host + ': %j', result);
  });
  return await pool.query(
    "SELECT data FROM marketItems WHERE name ILIKE $1",
    [`%${itemName}%`]
  );
};

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
  search,
  importData,
});
