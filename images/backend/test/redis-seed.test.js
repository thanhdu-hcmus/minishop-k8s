const test = require("node:test");
const assert = require("node:assert/strict");
const redis = require("redis");
const items = require("../db/items.json");
const { seedData } = require("../app/redis");

// Mirrors SET ... NX on a store: only absent keys are written, and the reply is
// null for a key that already exists. Also mirrors the client's argument check,
// which rejects numeric keys.
const fakeClient = (store, calls, closes) => ({
  isOpen: true,
  on() {},
  async connect() {},
  destroy() {
    this.isOpen = false;
    closes.push("destroy");
  },
  async set(key, value, options) {
    if (typeof key !== "string") {
      throw new TypeError(`"arguments[1]" must be of type "string | Buffer", got ${typeof key}`);
    }
    calls.push(options);
    if (options?.condition === "NX" && store.has(key)) {
      return null;
    }
    store.set(key, value);
    return "OK";
  }
});

const useFake = (t, store) => {
  const calls = [];
  const closes = [];
  t.mock.method(redis, "createClient", () => fakeClient(store, calls, closes));
  return { calls, closes };
};

test("writes every review key into an empty store with NX", async t => {
  const store = new Map();
  const { calls, closes } = useFake(t, store);

  const result = await seedData();

  assert.deepEqual(result, { written: items.length, kept: 0 });
  assert.equal(store.size, items.length);
  for (const item of items) {
    assert.equal(store.get(String(item.index)), JSON.stringify(item.reviews));
  }
  assert.ok(calls.every(options => options?.condition === "NX"));
  assert.deepEqual(closes, ["destroy"]);
});

test("never overwrites existing keys and fills only missing ones", async t => {
  const store = new Map([["0", "edited"], ["1", "[]"]]);
  useFake(t, store);

  const result = await seedData();

  assert.deepEqual(result, { written: items.length - 2, kept: 2 });
  assert.equal(store.get("0"), "edited");
  assert.equal(store.get("1"), "[]");
  assert.equal(store.size, items.length);
});

test("a second run changes nothing", async t => {
  const store = new Map();
  useFake(t, store);

  await seedData();
  const snapshot = new Map(store);
  const result = await seedData();

  assert.deepEqual(result, { written: 0, kept: items.length });
  assert.deepEqual(store, snapshot);
});
