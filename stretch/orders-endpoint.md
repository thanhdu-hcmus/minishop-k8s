# Orders endpoint

The upstream backend has no orders flow. Implement this only by forking the pinned Kuma source, adding an idempotent schema migration and tests, building a new digest-pinned image, and changing the active image reference explicitly.

