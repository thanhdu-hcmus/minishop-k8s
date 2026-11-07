const test = require("node:test");
const assert = require("node:assert/strict");
const { pool } = require("../app/postgresql");

// pg-pool emits 'error' when an idle pooled connection drops, for example when
// PostgreSQL stops within idleTimeoutMillis of the last query. The pool already
// discards that client, so the process must keep serving.
test("logs idle pool errors without exiting the process", t => {
  const exit = t.mock.method(process, "exit", () => {});

  pool.emit("error", new Error("Connection terminated unexpectedly"), {});

  assert.equal(exit.mock.callCount(), 0);
});
