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
