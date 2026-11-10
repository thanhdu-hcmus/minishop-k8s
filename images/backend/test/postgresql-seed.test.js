const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const { Pool } = require("pg");
const items = require("../db/items.json");
const { seedData } = require("../app/postgresql");

const isInsert = text => text.trimStart().startsWith("INSERT");
const isExistsCheck = text => text.startsWith("SELECT EXISTS");
const DESTRUCTIVE = /\b(DROP|TRUNCATE|DELETE|UPDATE)\b/i;

// EventEmitter supplies on/removeListener and, like a real pg client, throws when
// 'error' is emitted with no listener attached.
const fakeClient = ({ populated = false, failOn, dropOn } = {}) => {
  const client = Object.assign(new EventEmitter(), {
    calls: [],
    finished: [],
    released: [],
    errorListenersAtRelease: [],
    dropped: false,
    query(text, values) {
      client.calls.push({ text, values });
      return new Promise((resolve, reject) => {
        setImmediate(() => {
          client.finished.push(text);
          if (client.dropped) {
            reject(new Error("Client has encountered a connection error and is not queryable"));
          } else if (dropOn && dropOn(text)) {
            client.dropped = true;
            const error = new Error("Connection terminated unexpectedly");
            client.emit("error", error);
            reject(error);
          } else if (failOn && failOn(text)) {
            reject(new Error(`query failed: ${text}`));
          } else if (isExistsCheck(text)) {
            resolve({ rows: [{ populated }] });
          } else if (isInsert(text)) {
            resolve({ rows: [], rowCount: JSON.parse(values[0]).length });
          } else {
            resolve({ rows: [] });
          }
        });
      });
    },
    release(error) {
      client.released.push(error);
      client.errorListenersAtRelease.push(client.listenerCount("error"));
    }
  });
  return client;
};

test("seeds an empty table in one transaction with one parameterized insert", async t => {
  const client = fakeClient();
  t.mock.method(Pool.prototype, "connect", async () => client);

  const result = await seedData();

  assert.deepEqual(result, { inserted: items.length, skipped: false });
  assert.equal(client.finished[0], "BEGIN");
  assert.equal(client.finished.at(-1), "COMMIT");
  assert.match(client.calls[1].text, /pg_advisory_xact_lock/);
  assert.ok(client.calls.some(call => /CREATE TABLE IF NOT EXISTS marketItems/.test(call.text)));
  const inserts = client.calls.filter(call => isInsert(call.text));
  assert.equal(inserts.length, 1);
  assert.match(inserts[0].text, /ON CONFLICT \(index\) DO NOTHING/);
  assert.deepEqual(JSON.parse(inserts[0].values[0]), items);
  assert.equal(inserts[0].text.includes(items[0].name), false, "seed data inlined into SQL");
  assert.deepEqual(client.released, [undefined]);
  assert.deepEqual(client.errorListenersAtRelease, [0]);
});

test("leaves a populated table unchanged", async t => {
  const client = fakeClient({ populated: true });
  t.mock.method(Pool.prototype, "connect", async () => client);

  const result = await seedData();

  assert.deepEqual(result, { inserted: 0, skipped: true });
  assert.equal(client.calls.some(call => isInsert(call.text)), false);
  assert.equal(client.finished.at(-1), "COMMIT");
  assert.deepEqual(client.released, [undefined]);
});

test("never sends a destructive statement", async t => {
  for (const populated of [false, true]) {
    const client = fakeClient({ populated });
    t.mock.method(Pool.prototype, "connect", async () => client);

    await seedData();

    for (const call of client.calls) {
      assert.equal(DESTRUCTIVE.test(call.text), false, call.text);
    }
    t.mock.restoreAll();
  }
});

test("rolls back, releases, and rejects with the failing query error", async t => {
  const client = fakeClient({ failOn: isInsert });
  t.mock.method(Pool.prototype, "connect", async () => client);

  await assert.rejects(seedData(), /query failed: +INSERT/);

  assert.equal(client.finished.includes("COMMIT"), false);
  assert.equal(client.finished.at(-1), "ROLLBACK");
  assert.deepEqual(client.released, [undefined]);
});

test("keeps the original error and discards the connection when rollback fails", async t => {
  const client = fakeClient({ failOn: text => isInsert(text) || text === "ROLLBACK" });
  t.mock.method(Pool.prototype, "connect", async () => client);

  await assert.rejects(seedData(), /query failed: +INSERT/);

  assert.equal(client.released.length, 1);
  assert.match(client.released[0].message, /query failed: ROLLBACK/);
});

test("rejects and discards the connection when it drops during the seed", async t => {
  const client = fakeClient({ dropOn: isInsert });
  t.mock.method(Pool.prototype, "connect", async () => client);

  await assert.rejects(seedData(), /Connection terminated unexpectedly/);

  assert.equal(client.finished.includes("COMMIT"), false);
  assert.equal(client.released.length, 1);
  assert.match(client.released[0].message, /not queryable/);
  assert.deepEqual(client.errorListenersAtRelease, [0]);
});
