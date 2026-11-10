const test = require("node:test");
const assert = require("node:assert/strict");
const postgresql = require("../app/postgresql");
const redis = require("../app/redis");
const { main } = require("../seed");

// main() reports failure through process.exitCode; restore it so a test that
// expects a failure does not fail the test run.
const runMain = async () => {
  const saved = process.exitCode;
  try {
    await main();
    return process.exitCode;
  } finally {
    process.exitCode = saved;
  }
};

const mockPoolEnd = t => t.mock.method(postgresql.pool, "end", async () => {});

test("seeds PostgreSQL, then Redis, and exits 0", async t => {
  const order = [];
  t.mock.method(postgresql, "seedData", async () => {
    order.push("postgresql");
    return { inserted: 100, skipped: false };
  });
  t.mock.method(redis, "seedData", async () => {
    order.push("redis");
    return { written: 100, kept: 0 };
  });
  const end = mockPoolEnd(t);

  assert.notEqual(await runMain(), 1);
  assert.deepEqual(order, ["postgresql", "redis"]);
  assert.equal(end.mock.callCount(), 1);
});

test("still fills missing Redis keys when PostgreSQL was already seeded", async t => {
  t.mock.method(postgresql, "seedData", async () => ({ inserted: 0, skipped: true }));
  const redisSeed = t.mock.method(redis, "seedData", async () => ({ written: 0, kept: 100 }));
  mockPoolEnd(t);

  assert.notEqual(await runMain(), 1);
  assert.equal(redisSeed.mock.callCount(), 1);
});

test("exits 1 and closes the pool when PostgreSQL fails, without touching Redis", async t => {
  t.mock.method(postgresql, "seedData", async () => {
    throw new Error("connect ECONNREFUSED");
  });
  const redisSeed = t.mock.method(redis, "seedData", async () => ({ written: 0, kept: 0 }));
  const end = mockPoolEnd(t);

  assert.equal(await runMain(), 1);
  assert.equal(redisSeed.mock.callCount(), 0);
  assert.equal(end.mock.callCount(), 1);
});

test("exits 1 when Redis fails", async t => {
  t.mock.method(postgresql, "seedData", async () => ({ inserted: 100, skipped: false }));
  t.mock.method(redis, "seedData", async () => {
    throw new Error("WRONGPASS invalid username-password pair");
  });
  mockPoolEnd(t);

  assert.equal(await runMain(), 1);
});
