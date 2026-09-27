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

`REDIS_PASSWORD` is optional. When it is non-empty, the Redis client sends it
as the Redis password; when absent or empty, no password is configured, which
preserves the upstream unauthenticated behavior.

The Dockerfile pins the Node 22.16.0 Alpine 3.21 base image to
`sha256:9f3ae04faa4d2188825803bf890792f33cc39033c9241fc6bb201149470436ca`.
The publish workflow creates a commit-SHA tag only from `main`; consuming
manifests must pin the resulting digest emitted in the workflow summary.

GitHub Container Registry packages initially default to private. The owner must
decide package visibility after the first publish; public deployments require
changing the package to public in its GitHub package settings.
