const test = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const { Pool } = require("pg");
const items = require("../db/items.json");
const { importData } = require("../app/postgresql");

const isInsert = text => text.startsWith("INSERT");

// EventEmitter supplies on/removeListener and, like a real pg client, throws when
// 'error' is emitted with no listener attached.
const fakeClient = ({ failOn, dropOn } = {}) => {
  const client = Object.assign(new EventEmitter(), {
    calls: [],
    finished: [],
    released: [],
    errorListenersDuringQueries: [],
    errorListenersAtRelease: [],
    dropped: false,
    query(text, values) {
      client.calls.push({ text, values });
      client.errorListenersDuringQueries.push(client.listenerCount("error"));
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

test("listens for client errors during the import and stops before release", async t => {
  const client = fakeClient();
  t.mock.method(Pool.prototype, "connect", async () => client);

  await importData();

  assert.ok(client.errorListenersDuringQueries.every(count => count === 1));
  assert.deepEqual(client.errorListenersAtRelease, [0]);
});

test("rejects and discards the connection when it drops during the import", async t => {
  const client = fakeClient({ dropOn: isInsert });
  t.mock.method(Pool.prototype, "connect", async () => client);

  await assert.rejects(importData(), /Connection terminated unexpectedly/);

  assert.equal(client.finished.includes("COMMIT"), false);
  assert.equal(client.released.length, 1);
  assert.match(client.released[0].message, /not queryable/);
  assert.deepEqual(client.errorListenersAtRelease, [0]);
});
