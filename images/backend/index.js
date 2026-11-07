const redis = require("./app/redis");
const postgresql = require("./app/postgresql");
const { isDependencyUnavailable, positiveInteger, withDeadline } = require("./app/dependency");
const promBundle = require("express-prom-bundle");
const pino = require('pino');
const logger = pino({ name: 'kuma-backend', level: process.env.PINO_LOG_LEVEL || 'info' });

const express = require("express");
const app = express();

const metricsMiddleware = promBundle({includeMethod: true});
const bodyParser = require("body-parser");
let specialOffers = process.env.SPECIAL_OFFER || true;
let totalOffers = process.env.TOTAL_OFFER || 1;

app.use(metricsMiddleware);
app.use(bodyParser.json());
app.set("port", process.env.PORT || 3001);
app.set("etag", false);
app.use((req, res, next) => {
  res.set("Cache-Control", "no-store, no-cache, must-revalidate, private");
  next();
});
app.use((req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  res.header("Access-Control-Allow-Methods", "PUT, GET, POST, DELETE, OPTIONS");
  res.header("Access-Control-Allow-Headers", "*");
  next();
});

// 503 when PostgreSQL or Redis is unreachable or refusing service, 500 for any
// other failure. The body never carries the error message or stack; only a
// PostgreSQL SQLSTATE (for example 42P01, table missing before seeding).
const sendDependencyError = (res, error, message) => {
  const body = { error: message };
  const code = postgresql.sqlState(error);
  if (code) {
    body.code = code;
  }
  res.status(isDependencyUnavailable(error) ? 503 : 500).json(body);
};

app.get("/", (req, res) => {
  res.set(req.headers);
  logger.info('GET /');
  res.send(
    "Hello World! Marketplace with sales and reviews made with <3 by the OCTO team at Kong Inc."
  );
});

// Liveness: answers while the process can serve HTTP. It never checks PostgreSQL
// or Redis, so a dependency outage takes Pods out of the Service through
// readiness instead of restarting every replica at once.
app.get("/live", (req, res) => {
  res.json({ status: "ok" });
});

// Readiness: PostgreSQL and Redis must both answer within READINESS_TIMEOUT_MS
// (default 2000, below the 3 s probe timeout). Checks run in parallel.
app.get("/ready", async (req, res) => {
  const timeoutMs = positiveInteger(process.env.READINESS_TIMEOUT_MS, 2000);
  const dependencies = { postgresql, redis };
  const names = Object.keys(dependencies);
  const outcomes = await Promise.allSettled(
    names.map(name =>
      withDeadline(
        dependencies[name].ping(timeoutMs),
        timeoutMs,
        `${name} readiness check timed out after ${timeoutMs} ms`
      )
    )
  );
  const checks = {};
  outcomes.forEach((outcome, index) => {
    checks[names[index]] = outcome.status === "fulfilled" ? "ok" : "unavailable";
    if (outcome.status === "rejected") {
      logger.warn({ err: outcome.reason, dependency: names[index] }, 'readiness check failed');
    }
  });
  const ready = Object.values(checks).every(check => check === "ok");
  res.status(ready ? 200 : 503).json({ status: ready ? "ok" : "unavailable", checks });
});

app.post("/upload", async (req, res) => {
  try {
    await redis.importData();
    await postgresql.importData();
    res.end("Mock data updated in Redis and PostgreSQL!");
  } catch (err) {
    logger.error({ err }, 'mock data import failed');
    sendDependencyError(res, err, "Mock data import failed");
  }
});

app.get("/items", async (req, res) => {
  logger.info('get on /items');
  // Express 4 does not catch rejected async handlers, so every failure in this
  // handler, including a malformed result, must be caught here.
  try {
    const results = await postgresql.search(req.query.q);
    const rows = results.rows;
    if (rows.length === 0) {
      logger.warn('no results found');
    } else {
      logger.info('row count: ' + results.rowCount);
    }
    if (specialOffers == true) {
      res.send(addOffer(rows));
    } else {
      res.send(rows);
    }
  } catch (err) {
    logger.error({ err }, 'items query failed');
    sendDependencyError(res, err, "Items query failed");
  }
});

const addOffer = (arr) => {
  let items = arr;
  // TOTAL_OFFER larger than the result set must not index past the end.
  const offers = Math.min(Number(totalOffers) || 0, items.length);

  for (let i = 0; i < offers; i++) {
    items[i].data.specialOffer = true;
  }

  return items;
};

app.get("/items/:itemIndexId/reviews", async (req, res) => {
  logger.info('get on /items/.../reviews');
  try {
    const results = await redis.search(`${req.params.itemIndexId}`);
    if (results == null) {
      // Unchanged from before #39: 200 with {}. The pinned frontend shows an
      // endless spinner on a non-2xx here, so a 404 needs a frontend change first.
      res.json({});
      return;
    }
    res.send(results);
  } catch (err) {
    logger.error({ err }, 'reviews query failed');
    sendDependencyError(res, err, "Reviews query failed");
  }
});

if (require.main === module) {
  app.listen(app.get("port"), "0.0.0.0");
}

module.exports = app;
