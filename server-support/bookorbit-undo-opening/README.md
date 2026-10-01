# BookOrbit undo-opening server support

This directory contains the server-side companion to
[`2-bookorbit-undo-opening.lua`](../../2-bookorbit-undo-opening.lua).
The KOReader plugin itself stays unmodified. This is a patch against BookOrbit
3.2.0, not a replacement synchronization client.

`server.patch` includes the server implementation, tests and generated Drizzle
migration. It applies to upstream tag `v3.2.0` (`d1b3fae7f701ba5e0e95192804aeec95ad49353b`).
The code changes are covered by BookOrbit's AGPL-3.0-only license and additional
terms; see the [upstream source](https://github.com/bookorbit/bookorbit/tree/v3.2.0).

## Build

Use a clean checkout of that tag, apply `server.patch` with `git apply`, install
its frozen dependencies and run `pnpm --dir server build`. Run the included
opening tests, server type check and lint before deploying. The PostgreSQL
integration tests require an isolated test database, never a production library.

```sh
git apply --check /path/to/Ereader/server-support/bookorbit-undo-opening/server.patch
git apply /path/to/Ereader/server-support/bookorbit-undo-opening/server.patch
pnpm install --frozen-lockfile
pnpm --dir server build
node /path/to/Ereader/server-support/bookorbit-undo-opening/prepare-overlay.mjs "$PWD" /tmp/bookorbit-undo-build
docker build --build-arg PATCH_REVISION=YOUR_SOURCE_REVISION -t bookorbit-local:3.2.0-undo-opening /tmp/bookorbit-undo-build
```

The Dockerfile pins the deployed amd64 3.2.0 base image. The overlay replaces
only twelve compiled server modules and adds migration 0101. It preserves the
upstream dependencies, web assets, entrypoint and complete KOReader plugin.
Source maps and migration metadata are included for diagnosis/reproducibility.
Do not point this overlay at a different upstream image without rebuilding and
testing against its matching source and migration history.

For a running isolated test server, `smoke-test.mjs` verifies authenticated
start/commit/undo requests, idempotent retries, validation, access isolation and
database restoration. It creates and removes only unique test fixtures without
external tokens. It requires `pg` from the checkout's installed dependencies:

```sh
OPENING_TEST_DATABASE_URL=postgres://TEST_USER:TEST_PASSWORD@127.0.0.1:TEST_DB_PORT/bookorbit_undo_test \
OPENING_TEST_API_URL=http://127.0.0.1:TEST_API_PORT \
node /path/to/Ereader/server-support/bookorbit-undo-opening/smoke-test.mjs /path/to/bookorbit
```

## Deploy and roll back

Before changing the running image, make and verify a PostgreSQL backup. Restore
it into an isolated, non-public test database and run the new migration and
application there first. Keep test containers off the internet so copied
integration credentials cannot contact Hardcover or other services.

Preserve the deployment's existing volumes, environment, security settings and
web asset overrides. Change only its app image, then recreate the app service.
The upstream entrypoint runs migrations before starting the server. Verify the
health endpoint, all three `/api/v1/koreader/plugin/openings` POST routes, the
migration ledger and the preserved book/history counts before enabling the
KOReader patch. Do not create or delete real Hardcover readings as a smoke test.

Migration 0101 only creates `reading_openings`, its foreign keys and its index;
it does not rewrite existing reading history. An image-only rollback before
first use may leave that unused additive table in place. After first use,
reconcile active openings and pending Hardcover cleanup before removing support.
Do not automatically restore a database backup over newer reading data.

Future official BookOrbit server images do not automatically contain this
extension. Rebase/test the server patch for that release, or arrange an upstream
implementation, before replacing the custom image. The KOReader patch's source
compatibility guard is separate from this server deployment requirement.
