/*
 * Derived from Apache-2.0 kumahq/kuma-demo api/app/redis.js at db9e133.
 * Modified for Redis v6 and optional REDIS_PASSWORD support; see ../LICENSE.
 */

const items = require("../db/items.json");
const redis = require("redis");

const redisOptions = (environment = process.env) => {
  const options = {
    socket: {
      host: environment.REDIS_HOST || "localhost",
      port: Number(environment.REDIS_PORT || 6379),
      reconnectStrategy: function(retries, cause) {
        if (cause && cause.code === "ECONNREFUSED") {
          return new Error("The Redis server refused the connection");
        }
        if (retries > 10) {
          return new Error("Redis reconnect attempts exhausted");
        }
        return Math.min(retries * 100, 1000);
      }
    }
  };

  if (environment.REDIS_PASSWORD) {
    options.password = environment.REDIS_PASSWORD;
  }

  return options;
};

const createClient = async () => {
  const client = redis.createClient(redisOptions());

  client.on("error", error => {
    if (error.code === "ECONNREFUSED") {
      return new Error("Cannot reach Redis");
    }
    return error;
  });
  await client.connect();

  return client;
};

const withClient = async callback => {
  const client = await createClient();

  try {
    return await callback(client);
  } finally {
    if (client.isOpen) {
      await client.quit();
    }
  }
};

const search = async itemId => {
  const result = await withClient(client => client.get(itemId));

  if (result == null) {
    return new Error("Item does not exist");
  }

  return result;
};

const importData = async () => {
  await withClient(client =>
    Promise.all(items.map(item => client.set(item.index, JSON.stringify(item.reviews))))
  );
};

module.exports = {
  createClient,
  redisOptions,
  search,
  importData
};
