const test = require("node:test");
const assert = require("node:assert/strict");
const net = require("node:net");

// Real pg and node-redis clients against a local server that accepts TCP but
// never replies: the readiness pings must still settle within their timeout.

const PING_TIMEOUT_MS = 200;
const MAX_ELAPSED_MS = 1500;
const TEST_TIMEOUT_MS = 10000;

const silentServer = async t => {
  const sockets = new Set();
  const server = net.createServer(socket => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  t.after(() => {
    for (const socket of sockets) {
      socket.destroy();
    }
    server.close();
  });
  return server.address().port;
};

const timed = async work => {
  const started = Date.now();
  try {
    await work();
    return { error: undefined, milliseconds: Date.now() - started };
  } catch (error) {
    return { error, milliseconds: Date.now() - started };
  }
};

test("PostgreSQL ping fails within its timeout against a silent server", { timeout: TEST_TIMEOUT_MS }, async t => {
  const port = await silentServer(t);
  // The pool reads its settings when the module loads.
  process.env.POSTGRES_HOST = "127.0.0.1";
  process.env.POSTGRES_PORT_NUM = String(port);
  const postgresql = require("../app/postgresql");
  t.after(() => postgresql.pool.end().catch(() => {}));

  const result = await timed(() => postgresql.ping(PING_TIMEOUT_MS));

  assert.ok(result.error, "expected the ping to fail");
  assert.ok(result.milliseconds < MAX_ELAPSED_MS, `took ${result.milliseconds} ms`);
});

test("Redis ping fails within its timeout against a silent server", { timeout: TEST_TIMEOUT_MS }, async t => {
  const port = await silentServer(t);
  process.env.REDIS_HOST = "127.0.0.1";
  process.env.REDIS_PORT = String(port);
  const redis = require("../app/redis");

  const result = await timed(() => redis.ping(PING_TIMEOUT_MS));

  assert.ok(result.error, "expected the ping to fail");
  assert.ok(result.milliseconds < MAX_ELAPSED_MS, `took ${result.milliseconds} ms`);
});
