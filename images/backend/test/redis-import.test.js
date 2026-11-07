const test = require("node:test");
const assert = require("node:assert/strict");
const redis = require("redis");
const items = require("../db/items.json");
const { importData } = require("../app/redis");

// Mirrors the argument check in the redis client, which rejects numeric keys.
const fakeClient = (writes, closes) => ({
  isOpen: true,
  on() {},
  async connect() {},
  destroy() {
    this.isOpen = false;
    closes.push("destroy");
  },
  async set(key, value) {
    if (typeof key !== "string") {
      throw new TypeError(`"arguments[1]" must be of type "string | Buffer", got ${typeof key}`);
    }
    writes.set(key, value);
  }
});

test("imports item reviews under string keys", async t => {
  const writes = new Map();
  const closes = [];
  t.mock.method(redis, "createClient", () => fakeClient(writes, closes));

  await importData();

  assert.equal(writes.size, items.length);
  for (const item of items) {
    assert.equal(writes.get(String(item.index)), JSON.stringify(item.reviews));
  }
  assert.deepEqual(closes, ["destroy"]);
});
