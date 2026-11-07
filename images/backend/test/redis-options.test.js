const test = require("node:test");
const assert = require("node:assert/strict");
const { redisOptions } = require("../app/redis");

test("does not configure Redis authentication when the password is absent", () => {
  const options = redisOptions({
    REDIS_HOST: "redis",
    REDIS_PORT: "6379"
  });

  assert.equal(options.password, undefined);
  assert.equal(options.socket.host, "redis");
  assert.equal(options.socket.port, 6379);
});

test("configures Redis authentication when the password is provided", () => {
  const options = redisOptions({
    REDIS_HOST: "redis",
    REDIS_PORT: "6379",
    REDIS_PASSWORD: "test-value"
  });

  assert.equal(options.password, "test-value");
});

test("bounds the connection and commands and does not reconnect by default", () => {
  const options = redisOptions({});

  assert.equal(options.socket.connectTimeout, 2000);
  assert.equal(options.socket.reconnectStrategy, false);
  assert.equal(options.disableOfflineQueue, true);
  assert.equal(options.commandOptions.timeout, 2000);
});

test("reads the timeouts from the environment and ignores invalid values", () => {
  const configured = redisOptions({
    REDIS_CONNECT_TIMEOUT_MS: "500",
    REDIS_COMMAND_TIMEOUT_MS: "750"
  });
  const invalid = redisOptions({
    REDIS_CONNECT_TIMEOUT_MS: "0",
    REDIS_COMMAND_TIMEOUT_MS: "soon"
  });

  assert.equal(configured.socket.connectTimeout, 500);
  assert.equal(configured.commandOptions.timeout, 750);
  assert.equal(invalid.socket.connectTimeout, 2000);
  assert.equal(invalid.commandOptions.timeout, 2000);
});
