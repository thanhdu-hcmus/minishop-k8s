const test = require("node:test");
const assert = require("node:assert/strict");
const { DatabaseError } = require("pg");
const redis = require("../app/redis");
const postgresql = require("../app/postgresql");
const { DependencyTimeoutError } = require("../app/dependency");
const app = require("../index");

const request = async (method, path) => {
  const server = app.listen(0, "127.0.0.1");
  await new Promise(resolve => server.once("listening", resolve));

  try {
    const response = await fetch(`http://127.0.0.1:${server.address().port}${path}`, { method });
    return {
      status: response.status,
      contentType: response.headers.get("content-type"),
      text: await response.text()
    };
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
};

const withCode = (error, code) => Object.assign(error, { code });

const missingTable = () => {
  const error = new DatabaseError('relation "marketitems" does not exist', 0, "error");
  error.code = "42P01";
  return error;
};

const assertNoDetails = (text, error) => {
  assert.equal(text.includes(error.message), false, "error message leaked");
  assert.equal(text.includes("stack"), false, "stack leaked");
};

test("GET /items returns the rows with the special offer flag", async t => {
  t.mock.method(postgresql, "search", async () => ({
    rowCount: 2,
    rows: [{ data: { index: 0 } }, { data: { index: 1 } }]
  }));

  const response = await request("GET", "/items?q=");

  assert.equal(response.status, 200);
  assert.deepEqual(JSON.parse(response.text), [
    { data: { index: 0, specialOffer: true } },
    { data: { index: 1 } }
  ]);
});

test("GET /items returns an empty list when nothing matches", async t => {
  t.mock.method(postgresql, "search", async () => ({ rowCount: 0, rows: [] }));

  const response = await request("GET", "/items?q=none");

  assert.equal(response.status, 200);
  assert.deepEqual(JSON.parse(response.text), []);
});

test("GET /items returns 503 when PostgreSQL is unreachable", async t => {
  const error = withCode(new Error("connect ECONNREFUSED 10.0.0.1:5432"), "ECONNREFUSED");
  t.mock.method(postgresql, "search", async () => {
    throw error;
  });

  const response = await request("GET", "/items?q=");

  assert.equal(response.status, 503);
  assert.deepEqual(JSON.parse(response.text), { error: "Items query failed" });
  assertNoDetails(response.text, error);
});

test("GET /items returns 503 when PostgreSQL rejects the password", async t => {
  const error = new DatabaseError('password authentication failed for user "minishop"', 0, "error");
  error.code = "28P01";
  t.mock.method(postgresql, "search", async () => {
    throw error;
  });

  const response = await request("GET", "/items?q=");

  assert.equal(response.status, 503);
  assertNoDetails(response.text, error);
});

test("GET /items returns 503 when the query times out", async t => {
  t.mock.method(postgresql, "search", async () => {
    throw new DependencyTimeoutError("DNS lookup timed out");
  });

  const response = await request("GET", "/items?q=");

  assert.equal(response.status, 503);
});

test("GET /items returns 500 with the SQLSTATE when the table is missing", async t => {
  const error = missingTable();
  t.mock.method(postgresql, "search", async () => {
    throw error;
  });

  const response = await request("GET", "/items?q=");

  assert.equal(response.status, 500);
  assert.deepEqual(JSON.parse(response.text), { error: "Items query failed", code: "42P01" });
  assertNoDetails(response.text, error);
});

test("GET /items returns 500 instead of crashing on a malformed result", async t => {
  t.mock.method(postgresql, "search", async () => undefined);

  const response = await request("GET", "/items?q=");

  assert.equal(response.status, 500);
});

test("GET /items/:id/reviews returns the stored reviews", async t => {
  const search = t.mock.method(redis, "search", async () => '[{"name":"a"}]');

  const response = await request("GET", "/items/7/reviews");

  assert.equal(response.status, 200);
  assert.deepEqual(JSON.parse(response.text), [{ name: "a" }]);
  assert.deepEqual(search.mock.calls[0].arguments, ["7"]);
});

test("GET /items/:id/reviews keeps the pre-#39 200 {} when the item has no reviews", async t => {
  t.mock.method(redis, "search", async () => null);

  const response = await request("GET", "/items/999/reviews");

  // origin/main at 8b4bffd answered exactly this.
  assert.equal(response.status, 200);
  assert.equal(response.contentType, "application/json; charset=utf-8");
  assert.equal(response.text, "{}");
});

test("GET /items/:id/reviews returns 503 when Redis is unreachable or rejects the password", async t => {
  const failures = [
    withCode(new Error("getaddrinfo ENOTFOUND minishop-redis"), "ENOTFOUND"),
    new DependencyTimeoutError("Redis connection timed out after 2000 ms"),
    new Error("WRONGPASS invalid username-password pair or user is disabled.")
  ];

  for (const error of failures) {
    t.mock.method(redis, "search", async () => {
      throw error;
    });

    const response = await request("GET", "/items/1/reviews");

    assert.equal(response.status, 503, error.message);
    assert.deepEqual(JSON.parse(response.text), { error: "Reviews query failed" });
    assertNoDetails(response.text, error);
    t.mock.restoreAll();
  }
});

test("GET /items/:id/reviews returns 500 on other Redis errors", async t => {
  t.mock.method(redis, "search", async () => {
    throw new Error("WRONGTYPE Operation against a key holding the wrong kind of value");
  });

  const response = await request("GET", "/items/1/reviews");

  assert.equal(response.status, 500);
});

test("POST /upload returns 503 when a dependency is unreachable", async t => {
  t.mock.method(redis, "importData", async () => {
    throw withCode(new Error("connect ECONNREFUSED 10.0.0.2:6379"), "ECONNREFUSED");
  });
  t.mock.method(postgresql, "importData", async () => {});

  const response = await request("POST", "/upload");

  assert.equal(response.status, 503);
  assert.deepEqual(JSON.parse(response.text), { error: "Mock data import failed" });
});

test("PostgreSQL bounds each query and the pool connection", () => {
  assert.equal(postgresql.pool.options.query_timeout, 5000);
  assert.equal(postgresql.pool.options.connectionTimeoutMillis, 2000);
  assert.equal(postgresql.pool.options.idleTimeoutMillis, 10000);
});

test("sqlState returns only PostgreSQL server error codes", () => {
  assert.equal(postgresql.sqlState(missingTable()), "42P01");
  assert.equal(postgresql.sqlState(withCode(new Error("pipe"), "EPIPE")), undefined);
  assert.equal(postgresql.sqlState(undefined), undefined);
});
