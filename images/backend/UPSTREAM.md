# Backend image provenance

The source under this directory derives from `api/` at
[`kumahq/kuma-demo`](https://github.com/kumahq/kuma-demo) commit
`db9e13301b4936fd9aa47521db79cc6b7ee8e169` (2024-07-25), licensed under
Apache-2.0. The included `LICENSE` is the upstream license.

This snapshot retains the backend runtime sources (`index.js`, `app/`, and
`db/items.json`) and replaces the upstream Docker build. The upstream
`package.json` and `package-lock.json` specify different Redis major versions.
The copied client did not work with the locked Redis v4 API and the package.json
Redis v2 range has a high-severity advisory. This project adapts that client to
the current Redis API, uses exact dependency versions, and regenerates the
lockfile so `npm ci` is reproducible.

## Modifications

Each modified file carries a "Derived from ... Modified for ..." header.

- `app/redis.js`: adapted to the Redis v6 client with optional
  `REDIS_PASSWORD`, string keys for the review import (#43), and one
  client per request with no reconnects, bounded connect and command waits,
  and the socket closed with `destroy()` on every path (#39).
- `index.js`: `POST /upload` waits for both imports and returns an error when
  either fails (#43). PostgreSQL and Redis failures return 503 when the
  dependency is unavailable and 500 otherwise, with no error text in the body;
  `GET /live` (process only) and `GET /ready` (PostgreSQL and Redis) were
  added; the special-offer loop no longer indexes past the results (#39).
- `app/postgresql.js`: the import runs in one transaction with parameterized
  inserts and releases or discards its client (#43). Idle pool errors are
  logged instead of exiting the process, queries and the logging DNS lookup
  are bounded, and a readiness ping and SQLSTATE helper were added (#39).
- `app/dependency.js` (new, #39): deadlines, timeout parsing, and the
  unavailable-versus-internal error classification.
- `seed.js` (new, #40): the seed command for the chart's opt-in seed Job.
  `app/postgresql.js` gained `seedData`, which creates `marketItems` only if it
  is missing and inserts the seed rows only into an empty table, in one
  transaction under an advisory lock. `app/redis.js` gained `seedData`, which
  writes review keys with `SET ... NX`. Neither drops, truncates, or
  overwrites data.

## Runtime notes

`REDIS_PASSWORD` is optional. When it is non-empty, the Redis client sends it
as the Redis password; when absent or empty, no password is configured, which
preserves the upstream unauthenticated behavior.

The Dockerfile pins the Node 22.16.0 Alpine 3.21 base image to
`sha256:9f3ae04faa4d2188825803bf890792f33cc39033c9241fc6bb201149470436ca`.
The publish workflow creates a commit-SHA tag only from `main`; consuming
manifests must pin the resulting digest emitted in the workflow summary. After
the first publication, verify package visibility and repository access
permissions for the intended consumers. Adjust package settings only if they
differ from the intended access; the workflow does not modify them.
