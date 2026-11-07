const test = require("node:test");
const assert = require("node:assert/strict");
const {
  DependencyTimeoutError,
  isDependencyUnavailable,
  positiveInteger,
  withDeadline
} = require("../app/dependency");

const errorWith = (properties, message = "failure") =>
  Object.assign(new Error(message), properties);

test("withDeadline resolves with the value when the work finishes in time", async () => {
  assert.equal(await withDeadline(Promise.resolve("done"), 1000, "late"), "done");
});

test("withDeadline keeps the original rejection when the work fails in time", async () => {
  await assert.rejects(withDeadline(Promise.reject(new Error("boom")), 1000, "late"), /boom/);
});

test("withDeadline rejects and runs the teardown when the work hangs", async () => {
  let tornDown = 0;
  const started = Date.now();

  await assert.rejects(
    withDeadline(new Promise(() => {}), 50, "work timed out", () => {
      tornDown += 1;
    }),
    error => error instanceof DependencyTimeoutError && /work timed out/.test(error.message)
  );

  assert.equal(tornDown, 1);
  assert.ok(Date.now() - started < 1000);
});

test("withDeadline still rejects when the teardown throws", async () => {
  await assert.rejects(
    withDeadline(new Promise(() => {}), 10, "late", () => {
      throw new Error("teardown failed");
    }),
    DependencyTimeoutError
  );
});

test("positiveInteger falls back on unset, empty, zero, negative, and non-numeric values", () => {
  for (const value of [undefined, "", "0", "-5", "abc", "1.5"]) {
    assert.equal(positiveInteger(value, 2000), 2000, `value ${value}`);
  }
  assert.equal(positiveInteger("750", 2000), 750);
});

test("classifies network, connection, and authentication failures as unavailable", () => {
  const unavailable = [
    errorWith({ code: "ECONNREFUSED" }),
    errorWith({ code: "ENOTFOUND" }),
    errorWith({ code: "EAI_AGAIN" }),
    errorWith({ code: "28P01" }, "password authentication failed for user"),
    errorWith({ code: "57P01" }, "terminating connection due to administrator command"),
    errorWith({ code: "08006" }),
    new Error("timeout exceeded when trying to connect"),
    new Error("Connection terminated unexpectedly"),
    new Error("Query read timeout"),
    new Error("WRONGPASS invalid username-password pair or user is disabled."),
    errorWith({ name: "ConnectionTimeoutError" }, "Connection timeout"),
    errorWith({ name: "SocketClosedUnexpectedlyError" }, "Socket closed unexpectedly"),
    new DependencyTimeoutError("Redis connection timed out"),
    new AggregateError([errorWith({ code: "ECONNREFUSED" })], "connect failed")
  ];

  for (const error of unavailable) {
    assert.equal(isDependencyUnavailable(error), true, error.message);
  }
});

test("classifies query and data failures as internal errors", () => {
  const internal = [
    errorWith({ code: "42P01" }, 'relation "marketitems" does not exist'),
    errorWith({ code: "42601" }, "syntax error"),
    new TypeError("Cannot read properties of undefined"),
    undefined
  ];

  for (const error of internal) {
    assert.equal(isDependencyUnavailable(error), false, String(error && error.message));
  }
});
