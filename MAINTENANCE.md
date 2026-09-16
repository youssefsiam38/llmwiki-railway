# Maintenance

## Release process

1. Make the change on a branch. The `test` workflow builds every image and runs the full suite on every
   push and pull request.
2. Run locally:
   ```bash
   docker compose build --pull
   tests/static.sh && tests/smoke.sh && tests/persistence.sh
   ```
3. Tag `vX.Y.Z`. The `publish-image` workflow builds all eight images as local candidates, runs the smoke
   and persistence suites against the bundle of candidates, and only then retags and pushes those exact
   images to GHCR as `X.Y.Z`, `X.Y` and `latest`.
4. Update the Railway template (id in `RAILWAY_TEMPLATE.md`): the image tags of all eight services, with
   `templateChangeSetStage` then `templateChangeSetApply`. Tags only; the generator rejects digests.
   Republish the overview with `railway templates update <id> --readme-file marketplace/OVERVIEW.md` if it
   changed. Never put angle-bracket placeholders in the overview or variable descriptions: Railway strips
   them.
5. Deploy the updated template into a scratch project and run the live test with the owner's credentials
   and an allowlisted address:
   ```bash
   OWNER_EMAIL=... OWNER_PASSWORD_FILE=... ALLOWED_EMAIL=... \
     tests/railway-smoke.sh https://WEB https://API https://MCP https://KONG https://STORAGE
   ```
   Then redeploy `db`, `storage`, `auth` and `api` and run it again, and delete the scratch project.

The eight images are versioned together, so the template never mixes wrapper versions.

## Bumping LLM Wiki

Upstream merges `dev` into `master` in batches and publishes no releases. Move to a new `master` commit
deliberately.

1. Read the commits between the pinned commit and the candidate, especially `supabase/migrations/`,
   `api/config.py`, `mcp/config.py`, `mcp/hosted.py`, `converter/main.py`, the `.env.example` and the four
   Dockerfiles.
2. Change `ARG LLMWIKI_COMMIT` in `images/api`, `images/mcp`, `images/converter` and `images/web`.
3. If `web/package.json` or `web/package-lock.json` changed, the web build stops at the hash check.
   Regenerate `images/web/deps` from upstream's new files: re-apply only the pins that still carry
   advisories (`npm audit --omit=dev`), install with `--package-lock-only`, and update
   `UPSTREAM_PACKAGE_JSON_SHA256` / `UPSTREAM_PACKAGE_LOCK_SHA256` and the table in `UPSTREAM.md`. Drop an
   override once upstream's own pin is past the advisory.
4. Build and run the suites. Existing deployments apply the new migrations on their next start; a failure
   stops the start and the old containers keep serving.

### Breaking-change checklist

- [ ] New migrations: do they assume a role, extension or schema the Supabase image lacks? Do any need to
      run outside a transaction (`create index concurrently`)? `railway_setup.py` runs each in one.
- [ ] A historical migration edited upstream: the start-up logs a checksum warning and does not re-run it;
      decide whether existing deployments need a follow-up.
- [ ] `handle_new_user` still creates `public.users` from `auth.users`, and `users.page_limit` /
      `storage_limit_bytes` still exist (the limits step alters them).
- [ ] `api/auth.py` and `mcp/auth.py` still verify ES256 tokens from `SUPABASE_URL/auth/v1/.well-known/jwks.json`
      with issuer `SUPABASE_URL/auth/v1`.
- [ ] `converter/main.py`'s `_validate_s3_url` still matches the patch anchor.
- [ ] New `NEXT_PUBLIC_*` variables in `web/`: add a placeholder in `images/web/Dockerfile` and a shape in
      `fill-public-env.mjs`.
- [ ] New required settings in `api/config.py` or `mcp/config.py`: add them to the template.
- [ ] The web app's `/oauth/authorize` page still calls `getAuthorizationDetails` and `approveAuthorization`
      (`tests/lib.sh` `oauth_connect` mirrors it).

## Bumping Supabase Auth, Kong, Postgres and RustFS

Supabase Auth's OAuth server is recent and moving: after a bump, the OAuth section of `tests/smoke.sh`
(registration, authorize, consent, token, refresh, grant revocation) is the test that matters. Check the
release notes for `GOTRUE_JWT_KEYS` format changes, which `images/auth/keygen` produces. RustFS: read its
release notes for storage-format changes and back up the `storage` volume first. Record versions and
digests in `UPSTREAM.md`.

## What to watch

| Source | Why |
|---|---|
| https://github.com/lucasastorian/llmwiki/commits/master | Migrations, settings, security fixes. |
| https://github.com/lucasastorian/llmwiki/security | Upstream's own advisories and its security workflow's findings. |
| https://github.com/supabase/auth/releases | OAuth server and JWT key changes. |
| https://github.com/vercel/next.js/security/advisories | The web build's framework. |
| https://github.com/rustfs/rustfs/releases | Storage-format and credential changes. |

## Rolling back

Republish the template with the previous image tags. **The database does not roll back**: migrations a newer
image applied stay applied. Restore the `db` and `storage` volumes, taken at the same moment, from a backup
taken before the upgrade if the older API cannot run on the newer schema.

## Rotating secrets

| Secret | Effect of changing it |
|---|---|
| `LLMWIKI_SIGNING_KEY_SEED` (`auth`) | New signing key: every session ends, every MCP client must reconnect. Redeploy `auth`. |
| `JWT_SECRET` (`auth`) | New anon and service-role keys: redeploy `kong`, `api` and `web`. |
| `CONVERTER_SECRET` (`converter`) | Referenced by `api`; redeploy both. |
| `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY` (`storage`) | Referenced by `api` and `mcp`; redeploy all three. Existing signed links stop working. |
| `POSTGRES_PASSWORD` (`db`) | Set on an initialised cluster, it does not change the roles' passwords; change them in SQL first. |

## Backups

Railway volume backups cover `db` and `storage`. Back up both together: files in storage are referenced by
rows in the database.
