const test = require("node:test");
const assert = require("node:assert/strict");
const redis = require("../app/redis");
const postgresql = require("../app/postgresql");
const app = require("../index");

const get = async path => {
  const server = app.listen(0, "127.0.0.1");
  await new Promise(resolve => server.once("listening", resolve));

  try {
    const started = Date.now();
    const response = await fetch(`http://127.0.0.1:${server.address().port}${path}`);
    return { status: response.status, body: await response.json(), milliseconds: Date.now() - started };
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
};

const unavailable = () => Object.assign(new Error("connect ECONNREFUSED"), { code: "ECONNREFUSED" });

const withReadinessTimeout = (t, value) => {
  const saved = process.env.READINESS_TIMEOUT_MS;
  process.env.READINESS_TIMEOUT_MS = value;
  t.after(() => {
    if (saved === undefined) {
      delete process.env.READINESS_TIMEOUT_MS;
    } else {
      process.env.READINESS_TIMEOUT_MS = saved;
    }
  });
};

test("GET /live answers 200 without touching PostgreSQL or Redis", async t => {
  const postgresqlPing = t.mock.method(postgresql, "ping", async () => {
    throw unavailable();
  });
  const redisPing = t.mock.method(redis, "ping", async () => {
    throw unavailable();
  });
  const search = t.mock.method(postgresql, "search", async () => {
    throw unavailable();
  });

  const response = await get("/live");

  assert.equal(response.status, 200);
  assert.deepEqual(response.body, { status: "ok" });
  assert.equal(postgresqlPing.mock.callCount(), 0);
  assert.equal(redisPing.mock.callCount(), 0);
  assert.equal(search.mock.callCount(), 0);
});

test("GET /ready answers 200 when both dependencies answer", async t => {
  t.mock.method(postgresql, "ping", async () => ({ rows: [{ "?column?": 1 }] }));
  t.mock.method(redis, "ping", async () => "PONG");

  const response = await get("/ready");

  assert.equal(response.status, 200);
  assert.deepEqual(response.body, { status: "ok", checks: { postgresql: "ok", redis: "ok" } });
});

test("GET /ready answers 503 and names the dependency that failed", async t => {
  t.mock.method(postgresql, "ping", async () => ({ rows: [] }));
  t.mock.method(redis, "ping", async () => {
    throw unavailable();
  });

  const response = await get("/ready");

  assert.equal(response.status, 503);
  assert.deepEqual(response.body, {
    status: "unavailable",
    checks: { postgresql: "ok", redis: "unavailable" }
  });
});

test("GET /ready answers 503 when PostgreSQL is down", async t => {
  t.mock.method(postgresql, "ping", async () => {
    throw unavailable();
  });
  t.mock.method(redis, "ping", async () => "PONG");

  const response = await get("/ready");

  assert.equal(response.status, 503);
  assert.equal(response.body.checks.postgresql, "unavailable");
});

test("GET /ready answers 503 within the timeout when a check hangs", async t => {
  withReadinessTimeout(t, "100");
  const timeouts = [];
  t.mock.method(postgresql, "ping", timeoutMs => {
    timeouts.push(timeoutMs);
    return new Promise(() => {});
  });
  t.mock.method(redis, "ping", async timeoutMs => {
    timeouts.push(timeoutMs);
    return "PONG";
  });

  const response = await get("/ready");

  assert.equal(response.status, 503);
  assert.equal(response.body.checks.postgresql, "unavailable");
  assert.deepEqual(timeouts, [100, 100]);
  assert.ok(response.milliseconds < 1500, `took ${response.milliseconds} ms`);
});
