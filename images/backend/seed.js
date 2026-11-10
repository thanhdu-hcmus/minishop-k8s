/*
 * MiniShop seed command (#40), run by the chart's opt-in seed Job as
 * `node seed.js`. It replaces POST /upload, which dropped and recreated the
 * table. Both steps are non-destructive and safe to rerun: PostgreSQL rows are
 * inserted only into an empty marketItems table, and Redis review keys are
 * written only when absent. The process exits 0 on success and 1 on any
 * failure, so the Job retries; credentials come from the environment and are
 * never logged.
 */

const pino = require("pino");
const postgresql = require("./app/postgresql");
const redis = require("./app/redis");

const logger = pino({ name: "minishop-seed", level: process.env.PINO_LOG_LEVEL || "info" });

const seed = async () => {
  const items = await postgresql.seedData();
  if (items.skipped) {
    logger.info("marketItems already has rows; PostgreSQL left unchanged");
  } else {
    logger.info({ inserted: items.inserted }, "seeded marketItems");
  }
  const reviews = await redis.seedData();
  logger.info(reviews, "seeded Redis review keys that were missing");
};

const main = async () => {
  try {
    await seed();
    logger.info("seed finished");
  } catch (err) {
    logger.error({ err }, "seed failed");
    process.exitCode = 1;
  } finally {
    // Close idle pooled connections so the process can exit.
    await postgresql.pool.end().catch(err => {
      logger.warn({ err }, "closing the PostgreSQL pool failed");
    });
  }
};

if (require.main === module) {
  main();
}

module.exports = { seed, main };
