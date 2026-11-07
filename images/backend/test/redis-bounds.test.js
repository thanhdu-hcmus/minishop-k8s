const test = require("node:test");
const assert = require("node:assert/strict");
const net = require("node:net");
const redis = require("../app/redis");

// These tests use the real node-redis client against local sockets, so they
// check the library honours the bounds, not only that the options are set.

const BOUND_MS = 200;
// Generous margin for a loaded CI host; the old behaviour took about 64 s.
const MAX_ELAPSED_MS = 1500;
// Without a bound the old client hangs; fail the test instead of the run.
const TEST_TIMEOUT_MS = 10000;

const withEnvironment = async (t, values) => {
  const saved = {};
  for (const [name, value] of Object.entries(values)) {
    saved[name] = process.env[name];
    process.env[name] = value;
  }
  t.after(() => {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) {
        delete process.env[name];
      } else {
        process.env[name] = value;
      }
    }
  });
};

const listen = server =>
  new Promise(resolve => server.listen(0, "127.0.0.1", () => resolve(server.address().port)));

const elapsed = async work => {
  const started = Date.now();
  let error;
  try {
    await work();
  } catch (caught) {
    error = caught;
  }
  return { error, milliseconds: Date.now() - started };
};

test("fails at once without reconnecting when the Redis port is closed", { timeout: TEST_TIMEOUT_MS }, async t => {
  const server = net.createServer();
  const port = await listen(server);
  await new Promise(resolve => server.close(resolve));
  await withEnvironment(t, {
    REDIS_HOST: "127.0.0.1",
    REDIS_PORT: String(port),
    REDIS_CONNECT_TIMEOUT_MS: String(BOUND_MS)
  });

  const result = await elapsed(() => redis.search("1"));

  assert.equal(result.error?.code, "ECONNREFUSED");
  assert.ok(result.milliseconds < MAX_ELAPSED_MS, `took ${result.milliseconds} ms`);
});

test("fails within the bound when Redis accepts connections but never replies", { timeout: TEST_TIMEOUT_MS }, async t => {
  const sockets = new Set();
  const server = net.createServer(socket => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
  });
  const port = await listen(server);
  t.after(() => {
    for (const socket of sockets) {
      socket.destroy();
    }
    server.close();
  });
  await withEnvironment(t, {
    REDIS_HOST: "127.0.0.1",
    REDIS_PORT: String(port),
    REDIS_CONNECT_TIMEOUT_MS: String(BOUND_MS),
    REDIS_COMMAND_TIMEOUT_MS: String(BOUND_MS)
  });

  const result = await elapsed(() => redis.search("1"));

  assert.ok(result.error, "expected the request to fail");
  assert.ok(result.milliseconds < MAX_ELAPSED_MS, `took ${result.milliseconds} ms`);
});

test("fails within the bound when the Redis host does not resolve", { timeout: TEST_TIMEOUT_MS }, async t => {
  // .invalid is reserved by RFC 2606 and never resolves.
  await withEnvironment(t, {
    REDIS_HOST: "minishop-redis.invalid",
    REDIS_PORT: "6379",
    REDIS_CONNECT_TIMEOUT_MS: String(BOUND_MS)
  });

  const result = await elapsed(() => redis.search("1"));

  assert.ok(result.error, "expected the request to fail");
  assert.ok(result.milliseconds < MAX_ELAPSED_MS, `took ${result.milliseconds} ms`);
});
