const test = require("node:test");
const assert = require("node:assert/strict");
const redis = require("redis");
const items = require("../db/items.json");
const { importData } = require("../app/redis");

// Mirrors the argument check in the redis client, which rejects numeric keys.
const fakeClient = writes => ({
  isOpen: true,
  on() {},
  async connect() {},
  async quit() {},
  async set(key, value) {
    if (typeof key !== "string") {
      throw new TypeError(`"arguments[1]" must be of type "string | Buffer", got ${typeof key}`);
    }
    writes.set(key, value);
  }
});

test("imports item reviews under string keys", async t => {
  const writes = new Map();
  t.mock.method(redis, "createClient", () => fakeClient(writes));

  await importData();

  assert.equal(writes.size, items.length);
  for (const item of items) {
    assert.equal(writes.get(String(item.index)), JSON.stringify(item.reviews));
  }
});
