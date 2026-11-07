const { test, before, after } = require("node:test");
const assert = require("node:assert/strict");
const net = require("node:net");

// Real pg and node-redis clients against a local server that accepts TCP but
// never replies: the readiness pings must still settle within their timeout.

const PING_TIMEOUT_MS = 200;
const MAX_ELAPSED_MS = 1500;
const TEST_TIMEOUT_MS = 10000;

const sockets = new Set();
const servers = [];
let postgresql;
let redis;

const silentServer = async () => {
  const server = net.createServer(socket => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  servers.push(server);
  return server.address().port;
};

// The modules read their settings from the environment when they load, so load
// them once the silent servers are listening, outside the timed tests.
before(async () => {
  process.env.POSTGRES_HOST = "127.0.0.1";
  process.env.POSTGRES_PORT_NUM = String(await silentServer());
  process.env.REDIS_HOST = "127.0.0.1";
  process.env.REDIS_PORT = String(await silentServer());
  postgresql = require("../app/postgresql");
  redis = require("../app/redis");
});

after(async () => {
  await postgresql.pool.end().catch(() => {});
  for (const socket of sockets) {
    socket.destroy();
  }
  for (const server of servers) {
    server.close();
  }
});

const timed = async work => {
  const started = Date.now();
  try {
    await work();
    return { error: undefined, milliseconds: Date.now() - started };
  } catch (error) {
    return { error, milliseconds: Date.now() - started };
  }
};

test("PostgreSQL ping fails within its timeout against a silent server", { timeout: TEST_TIMEOUT_MS }, async () => {
  const result = await timed(() => postgresql.ping(PING_TIMEOUT_MS));

  assert.ok(result.error, "expected the ping to fail");
  assert.ok(result.milliseconds < MAX_ELAPSED_MS, `took ${result.milliseconds} ms`);
});

test("Redis ping fails within its timeout against a silent server", { timeout: TEST_TIMEOUT_MS }, async () => {
  const result = await timed(() => redis.ping(PING_TIMEOUT_MS));

  assert.ok(result.error, "expected the ping to fail");
  assert.ok(result.milliseconds < MAX_ELAPSED_MS, `took ${result.milliseconds} ms`);
});
