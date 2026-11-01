const test = require("node:test");
const assert = require("node:assert/strict");
const { Pool } = require("pg");
const items = require("../db/items.json");
const { importData } = require("../app/postgresql");

const isInsert = text => text.startsWith("INSERT");

const fakeClient = ({ failOn } = {}) => {
  const client = {
    calls: [],
    finished: [],
    released: [],
    query(text, values) {
      client.calls.push({ text, values });
      return new Promise((resolve, reject) => {
        setImmediate(() => {
          client.finished.push(text);
          if (failOn && failOn(text)) {
            reject(new Error(`query failed: ${text}`));
          } else {
            resolve({ rows: [] });
          }
        });
      });
    },
    release(error) {
      client.released.push(error);
    }
  };
  return client;
};

test("commits only after every parameterized insert finished", async t => {
  const client = fakeClient();
  t.mock.method(Pool.prototype, "connect", async () => client);

  await importData();

  const inserts = client.calls.filter(call => isInsert(call.text));
  assert.equal(inserts.length, items.length);
  assert.equal(client.finished.at(-1), "COMMIT");
  assert.equal(client.finished.filter(isInsert).length, items.length);
  assert.deepEqual(inserts[0].values, [
    items[0].index,
    items[0].name,
    JSON.stringify(items[0])
  ]);
  assert.ok(inserts.every(call => !call.text.includes(items[0].name)));
  assert.deepEqual(client.released, [undefined]);
});

test("rolls back, releases, and rejects with the failing query error", async t => {
  const client = fakeClient({ failOn: isInsert });
  t.mock.method(Pool.prototype, "connect", async () => client);

  await assert.rejects(importData(), /query failed: INSERT/);

  assert.equal(client.finished.includes("COMMIT"), false);
  assert.equal(client.finished.at(-1), "ROLLBACK");
  assert.deepEqual(client.released, [undefined]);
});

test("keeps the original error and discards the connection when rollback fails", async t => {
  const client = fakeClient({ failOn: text => isInsert(text) || text === "ROLLBACK" });
  t.mock.method(Pool.prototype, "connect", async () => client);

  await assert.rejects(importData(), /query failed: INSERT/);

  assert.equal(client.released.length, 1);
  assert.match(client.released[0].message, /query failed: ROLLBACK/);
});
