const test = require("node:test");
const assert = require("node:assert/strict");
const redis = require("../app/redis");
const { DependencyTimeoutError } = require("../app/dependency");
const { startFakeRedis } = require("./fake-redis");

// The fake server completes the handshake, so these cases reach a written
// command. node-redis does not time a written command, so the bound and the
// socket close come from withClient.

const BOUND_MS = 200;
const MAX_ELAPSED_MS = 1500;
const CLOSE_WAIT_MS = 1000;
const TEST_TIMEOUT_MS = 10000;

const useFakeRedis = async (t, options) => {
  const fake = await startFakeRedis(options);
  const saved = {
    REDIS_HOST: process.env.REDIS_HOST,
    REDIS_PORT: process.env.REDIS_PORT,
    REDIS_CONNECT_TIMEOUT_MS: process.env.REDIS_CONNECT_TIMEOUT_MS,
    REDIS_COMMAND_TIMEOUT_MS: process.env.REDIS_COMMAND_TIMEOUT_MS
  };
  Object.assign(process.env, {
    REDIS_HOST: "127.0.0.1",
    REDIS_PORT: String(fake.port),
    REDIS_CONNECT_TIMEOUT_MS: String(BOUND_MS),
    REDIS_COMMAND_TIMEOUT_MS: String(BOUND_MS)
  });
  t.after(async () => {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    await fake.close();
  });
  return fake;
};

const timed = async work => {
  const started = Date.now();
  try {
    return { value: await work(), milliseconds: Date.now() - started };
  } catch (error) {
    return { error, milliseconds: Date.now() - started };
  }
};

test("search fails within the bound and closes the socket when GET is never answered", { timeout: TEST_TIMEOUT_MS }, async t => {
  const fake = await useFakeRedis(t, { stall: ["GET"] });

  const result = await timed(() => redis.search("1"));

  assert.ok(result.error instanceof DependencyTimeoutError, String(result.error));
  assert.ok(result.milliseconds < MAX_ELAPSED_MS, `took ${result.milliseconds} ms`);
  assert.ok(fake.received.includes("GET"), "GET was not written");
  assert.equal(await fake.waitForAllClosed(CLOSE_WAIT_MS), true, "client socket left open");
});

test("ping fails within its timeout and closes the socket when PING is never answered", { timeout: TEST_TIMEOUT_MS }, async t => {
  const fake = await useFakeRedis(t, { stall: ["PING"] });

  const result = await timed(() => redis.ping(BOUND_MS));

  assert.ok(result.error instanceof DependencyTimeoutError, String(result.error));
  assert.ok(result.milliseconds < MAX_ELAPSED_MS, `took ${result.milliseconds} ms`);
  assert.equal(await fake.waitForAllClosed(CLOSE_WAIT_MS), true, "client socket left open");
});

test("seed fails within the bound and closes the socket when SET is never answered", { timeout: TEST_TIMEOUT_MS }, async t => {
  const fake = await useFakeRedis(t, { stall: ["SET"] });

  const result = await timed(() => redis.seedData());

  assert.ok(result.error instanceof DependencyTimeoutError, String(result.error));
  assert.ok(result.milliseconds < MAX_ELAPSED_MS, `took ${result.milliseconds} ms`);
  assert.equal(await fake.waitForAllClosed(CLOSE_WAIT_MS), true, "client socket left open");
});

test("search returns the value and closes the socket without waiting for QUIT", { timeout: TEST_TIMEOUT_MS }, async t => {
  const fake = await useFakeRedis(t, { stall: ["QUIT"], values: new Map([["1", "[]"]]) });

  const result = await timed(() => redis.search("1"));

  assert.equal(result.error, undefined);
  assert.equal(result.value, "[]");
  assert.ok(result.milliseconds < MAX_ELAPSED_MS, `took ${result.milliseconds} ms`);
  assert.equal(fake.received.includes("QUIT"), false, "QUIT was sent");
  assert.equal(await fake.waitForAllClosed(CLOSE_WAIT_MS), true, "client socket left open");
});

test("ping resolves PONG and closes the socket", { timeout: TEST_TIMEOUT_MS }, async t => {
  const fake = await useFakeRedis(t);

  const result = await timed(() => redis.ping(BOUND_MS));

  assert.equal(result.value, "PONG");
  assert.equal(await fake.waitForAllClosed(CLOSE_WAIT_MS), true, "client socket left open");
});
