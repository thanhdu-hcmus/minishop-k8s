/*
 * Derived from Apache-2.0 kumahq/kuma-demo api/app/redis.js at db9e133.
 * Modified for Redis v6, optional REDIS_PASSWORD support, and bounded
 * connection and command waits; see ../LICENSE.
 */

const items = require("../db/items.json");
const redis = require("redis");
const pino = require("pino");
const { positiveInteger, withDeadline } = require("./dependency");

const logger = pino({ name: "kuma-backend-redis", level: process.env.PINO_LOG_LEVEL || "info" });

const DEFAULT_CONNECT_TIMEOUT_MS = 2000;
const DEFAULT_COMMAND_TIMEOUT_MS = 2000;

// Each request opens its own client, so the request is the retry unit: a failed
// connection fails the request at once instead of reconnecting in the background.
// The previous strategy retried 11 times, and with a host that no longer resolves
// each attempt waited on DNS, so a request took about 64 s to fail.
const redisOptions = (environment = process.env) => {
  const options = {
    socket: {
      host: environment.REDIS_HOST || "localhost",
      port: Number(environment.REDIS_PORT || 6379),
      connectTimeout: positiveInteger(environment.REDIS_CONNECT_TIMEOUT_MS, DEFAULT_CONNECT_TIMEOUT_MS),
      reconnectStrategy: false
    },
    // Reject commands while disconnected instead of queueing them indefinitely.
    disableOfflineQueue: true,
    commandOptions: {
      timeout: positiveInteger(environment.REDIS_COMMAND_TIMEOUT_MS, DEFAULT_COMMAND_TIMEOUT_MS)
    }
  };

  if (environment.REDIS_PASSWORD) {
    options.password = environment.REDIS_PASSWORD;
  }

  return options;
};

const destroyQuietly = client => {
  try {
    client.destroy();
  } catch (_) {
    // Already closed.
  }
};

// timeoutMs overrides both the connect and command timeouts, for callers such as
// the readiness check that must finish inside a probe timeout.
const createClient = async ({ timeoutMs } = {}) => {
  const options = redisOptions();
  if (timeoutMs) {
    options.socket.connectTimeout = timeoutMs;
    options.commandOptions = { timeout: timeoutMs };
  }
  const client = redis.createClient(options);

  client.on("error", error => {
    logger.warn({ err: error }, "redis client error");
  });
  // connectTimeout covers the TCP connect; this deadline also covers the DNS
  // lookup and the connection handshake (AUTH, CLIENT SETINFO).
  await withDeadline(
    client.connect(),
    options.socket.connectTimeout,
    `Redis connection timed out after ${options.socket.connectTimeout} ms`,
    () => destroyQuietly(client)
  );

  return client;
};

const withClient = async (callback, clientOptions) => {
  const client = await createClient(clientOptions);

  try {
    return await callback(client);
  } finally {
    if (client.isOpen) {
      try {
        await withDeadline(client.quit(), DEFAULT_COMMAND_TIMEOUT_MS, "Redis quit timed out");
      } catch (error) {
        logger.warn({ err: error }, "redis quit failed; destroying the client");
        destroyQuietly(client);
      }
    }
  }
};

// Resolves null when the item has no reviews key, so the route can return 404.
const search = async itemId => withClient(client => client.get(itemId));

// Readiness check: connect, authenticate, and PING within timeoutMs.
const ping = async timeoutMs => withClient(client => client.ping(), { timeoutMs });

const importData = async () => {
  await withClient(client =>
    Promise.all(items.map(item => client.set(String(item.index), JSON.stringify(item.reviews))))
  );
};

module.exports = {
  createClient,
  redisOptions,
  search,
  ping,
  importData
};
