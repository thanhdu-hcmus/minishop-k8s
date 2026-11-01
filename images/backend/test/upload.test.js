const test = require("node:test");
const assert = require("node:assert/strict");
const redis = require("../app/redis");
const postgresql = require("../app/postgresql");
const app = require("../index");

const postUpload = async () => {
  const server = app.listen(0, "127.0.0.1");
  await new Promise(resolve => server.once("listening", resolve));

  try {
    return await fetch(`http://127.0.0.1:${server.address().port}/upload`, { method: "POST" });
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
};

test("responds only after both imports finish", async t => {
  const finished = [];
  t.mock.method(redis, "importData", async () => {
    await new Promise(resolve => setImmediate(resolve));
    finished.push("redis");
  });
  t.mock.method(postgresql, "importData", async () => {
    await new Promise(resolve => setImmediate(resolve));
    finished.push("postgresql");
  });

  const response = await postUpload();

  assert.equal(response.status, 200);
  assert.deepEqual(finished, ["redis", "postgresql"]);
});

test("returns 500 and skips PostgreSQL when the Redis import fails", async t => {
  t.mock.method(redis, "importData", async () => {
    throw new Error("redis import failed");
  });
  const postgresqlImport = t.mock.method(postgresql, "importData", async () => {});

  const response = await postUpload();

  assert.equal(response.status, 500);
  assert.equal(postgresqlImport.mock.callCount(), 0);
});

test("returns 500 when the PostgreSQL import fails", async t => {
  t.mock.method(redis, "importData", async () => {});
  t.mock.method(postgresql, "importData", async () => {
    throw new Error("postgresql import failed");
  });

  const response = await postUpload();

  assert.equal(response.status, 500);
});
