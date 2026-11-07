// Shared helpers for bounding and classifying PostgreSQL and Redis failures.

class DependencyTimeoutError extends Error {
  constructor(message) {
    super(message);
    this.name = "DependencyTimeoutError";
    this.code = "ETIMEDOUT";
  }
}

// Returns the integer value of an environment variable, or the fallback when it
// is unset, empty, or not a positive integer, so a typo cannot disable a bound.
const positiveInteger = (value, fallback) => {
  const parsed = Number(value);
  return Number.isInteger(parsed) && parsed > 0 ? parsed : fallback;
};

// Rejects with DependencyTimeoutError when the promise has not settled in time.
// onTimeout lets the caller tear down the work that is still running.
const withDeadline = (promise, milliseconds, message, onTimeout) => {
  let timer;
  const deadline = new Promise((resolve, reject) => {
    timer = setTimeout(() => {
      if (onTimeout) {
        try {
          onTimeout();
        } catch (_) {
          // Teardown is best effort; the caller still gets the timeout error.
        }
      }
      reject(new DependencyTimeoutError(message));
    }, milliseconds);
  });
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
};

const NETWORK_ERROR_CODES = new Set([
  "ECONNREFUSED",
  "ECONNRESET",
  "ENOTFOUND",
  "EAI_AGAIN",
  "ETIMEDOUT",
  "EHOSTUNREACH",
  "ENETUNREACH",
  "EPIPE"
]);

// node-redis error class names that mean the server could not be used.
const REDIS_UNAVAILABLE_ERRORS = new Set([
  "ClientClosedError",
  "ClientOfflineError",
  "ConnectionTimeoutError",
  "ReconnectStrategyError",
  "SocketClosedUnexpectedlyError",
  "SocketTimeoutError",
  "TimeoutError"
]);

// PostgreSQL SQLSTATE classes: 08 connection exception, 28 invalid authorization,
// 53300 too many connections, 57P01-57P03 shutdown or not accepting connections.
const POSTGRESQL_UNAVAILABLE_STATE = /^(08|28|53300$|57P0[1-3]$)/;

// Messages pg uses for connection-level failures that carry no code.
const POSTGRESQL_UNAVAILABLE_MESSAGE =
  /timeout exceeded when trying to connect|Connection terminated|not queryable|Query read timeout/i;

// Redis replies that mean the server cannot serve this client right now.
const REDIS_UNAVAILABLE_REPLY = /^(WRONGPASS|NOAUTH|LOADING|MASTERDOWN|BUSY)\b/;

// True when the error means a dependency is unreachable or refusing service
// (503), false for other failures such as a bad query or missing table (500).
const isDependencyUnavailable = error => {
  if (!error) {
    return false;
  }
  if (error instanceof DependencyTimeoutError || NETWORK_ERROR_CODES.has(error.code)) {
    return true;
  }
  if (typeof error.code === "string" && POSTGRESQL_UNAVAILABLE_STATE.test(error.code)) {
    return true;
  }
  if (REDIS_UNAVAILABLE_ERRORS.has(error.name) || REDIS_UNAVAILABLE_ERRORS.has(error.constructor?.name)) {
    return true;
  }
  const message = String(error.message || "");
  if (POSTGRESQL_UNAVAILABLE_MESSAGE.test(message) || REDIS_UNAVAILABLE_REPLY.test(message)) {
    return true;
  }
  if (Array.isArray(error.errors)) {
    return error.errors.some(isDependencyUnavailable);
  }
  return isDependencyUnavailable(error.cause);
};

module.exports = {
  DependencyTimeoutError,
  isDependencyUnavailable,
  positiveInteger,
  withDeadline
};
