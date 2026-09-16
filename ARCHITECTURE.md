# Architecture

## Service graph

```
 browser ──https──► web ─────────────── (static app; everything below is called from the browser)
    │
    ├──https──► api ──────► db (Postgres, pgroonga)
    │            │  ├─private► storage (S3)  ◄──https, signed URLs── browser (document viewer)
    │            │  └─────► converter ──https──► storage (signed GET)
    │            └──private─► kong ─► auth                        (owner account at start-up)
    │
    ├──https──► kong ──private──► auth ──► db                      (sign-in, consent API)
    │
 Claude ─https─► mcp ─────► db, storage (private)
    │             └──https──► api                                   (add_source_from_url)
    └──https──► kong ─► auth                                        (OAuth discovery, registration,
                                                                     authorize, token, JWKS)
```

| Service | Listens | Reached by |
|---|---|---|
| `web` | `[::]:3000` | browsers (public) |
| `api` | `[::]:8000`, IPv4 too | browsers, the MCP server (public) |
| `mcp` | `0.0.0.0:8080` | MCP clients (public) |
| `kong` | `[::]:8000` and `0.0.0.0:8000` | browsers, MCP clients, the API and MCP server's JWKS fetch (public); the API's owner step (private) |
| `storage` | `[::]:9000` | browsers and the converter through signed URLs (public); the API and MCP server (private) |
| `converter` | `[::]:8000`, IPv4 too | the API (private) |
| `auth` | `[::]:9999` | Kong (private) |
| `db` | `*:5432` | auth, api, mcp (private) |

Railway's private network is IPv6, so every private listener binds `::`; the API and converter use a dual-stack socket
(`lib/serve.py`), because uvicorn's `--host ::` is IPv6 only.

## Why three public LLM Wiki services

This is upstream's own hosted layout: the web app is a static Next.js build that calls the API and
Supabase Auth from the browser, and the MCP server is its own origin, because MCP clients identify the
protected resource by its exact URL. The API is public because the browser calls it directly (uploads use
tus, events use a WebSocket).

## Start-up

### auth

1. Derives the JWT keys (`images/auth/keygen`): a P-256 private key from `HMAC-SHA256(LLMWIKI_SIGNING_KEY_SEED,
   label)`, with the RFC 7638 thumbprint as its key id, plus `JWT_SECRET` as a verify-only HS256 key.
   `GOTRUE_JWT_KEYS` gets both; Supabase Auth signs every session with the ES256 key and still accepts the
   HS256 anon and service-role API keys. The JWKS endpoint publishes only the EC public key.
2. Derives the issuer from `SUPABASE_PUBLIC_URL` (`<kong>/auth/v1`), which is what LLM Wiki's API and MCP
   server check, and switches on the OAuth 2.1 server with the web app's `/oauth/authorize` as the
   consent page and dynamic client registration on.
3. Drops the seed and the secret from its environment and starts Supabase Auth.

The same seed always derives the same key, so redeploys keep everyone signed in and connected MCP clients
keep working; a new seed rotates the key and signs everyone out.

### api

`railway_setup.py`, before the API listens:

1. Waits for Postgres, the gateway and Supabase Auth, and the `auth.users` table.
2. Applies `supabase/migrations/*.sql` from the pinned commit in byte order, each in a transaction, recording
   name and SHA-256 in `llmwiki_railway.migrations`. Recorded files are not run again (a changed checksum
   is logged). A database that already holds LLM Wiki tables without that ledger is refused.
3. Installs the signup gate (`gate.sql`) and writes `LLMWIKI_SIGNUP_MODE` and `LLMWIKI_ALLOWED_SIGNUPS`.
4. Sets the per-user limits: the `users.page_limit` and `storage_limit_bytes` defaults, and every existing
   row, from `LLMWIKI_PAGE_LIMIT` and `LLMWIKI_STORAGE_LIMIT_BYTES`.
5. Creates the bucket if missing and sets its CORS policy: `GET`/`HEAD` from the web app's origin only.
6. Creates the owner through Supabase Auth's admin API if no account with `OWNER_EMAIL` exists.

Then it drops `JWT_SECRET` and `OWNER_PASSWORD` and starts uvicorn with `--proxy-headers`
(`FORWARDED_ALLOW_IPS=*`), so LLM Wiki's per-address rate limit sees client addresses rather than
Railway's edge.

### web

Built once with placeholder `NEXT_PUBLIC_*` values. At start the entrypoint mints the anon key from
`JWT_SECRET` and rewrites every built file that carries a placeholder from a pristine copy made at build
time, then starts the standalone server. A value that does not match its expected shape (origin, JWT,
`…/mcp`) stops the start rather than being written into JavaScript.

### mcp, converter

Validation only, then upstream's commands. The converter listens on `::`.

## Signing in and the OAuth server

- **Web app:** `supabase-js` in the browser signs in with e-mail and password (or Google, if configured)
  against `kong`, and sends the ES256 access token to the API as a bearer token. The API verifies it
  against Supabase Auth's JWKS (`ES256` only, issuer and audience checked); a token signed with the HS256
  secret is refused.
- **MCP clients:** a client calls `https://<mcp>/mcp`, gets `401` with the protected-resource metadata URL,
  learns the authorization server (`<kong>/auth/v1`), reads its metadata at
  `/.well-known/oauth-authorization-server/auth/v1`, registers itself, and sends the user to
  `/auth/v1/oauth/authorize`. Supabase Auth redirects to the web app's `/oauth/authorize` page, which
  signs the user in if needed and shows the client's name; approving returns a code that the client
  exchanges (PKCE) for an ES256 access token carrying its `client_id`, and a refresh token. The MCP server
  verifies those tokens the same way the API does, and scopes every query to the token's user.

Kong opens exactly the OAuth endpoints clients call without a Supabase key (metadata, registration,
authorize, token, userinfo) as anchored single-path routes; everything else under `/auth/v1/`, including
the consent API and the admin API, requires the anon or service-role key, as in Supabase's own gateway.

## The signup gate

A `BEFORE INSERT` trigger on `auth.users` admits a new user when:

1. its metadata carries the one-time bootstrap nonce (the owner, created by the API's start-up; only the
   nonce's SHA-256 is stored, the insert consumes it, and the start-up removes it whatever happens);
2. the signup mode is `open`;
3. its e-mail address, or `@` and its domain, is in the allowlist.

Everything else fails with an error Supabase Auth reports as a 500. A second trigger strips the nonce from
metadata on the update Supabase Auth issues right after the insert. Upstream's own `on_auth_user_created`
trigger then creates the `public.users` row with the instance's limits.

## Storage

The API and the MCP server read and write objects over the private network (`AWS_ENDPOINT_URL_S3`). Signed
links are different: browsers and the converter fetch them, and SigV4 signatures cover the host, so the API
signs them with the public storage domain (`LLMWIKI_S3_PUBLIC_ENDPOINT`, `images/api/patch_s3_presign.py`).
The split is required, not just cheaper: Railway's edge does not complete botocore's uploads, which send
`Expect: 100-continue`. Path-style addressing (`AWS_CONFIG_FILE`) and `when_required` checksums keep botocore
compatible with RustFS.

The converter's download allowlist (upstream: Amazon S3 only) is extended by `patch_s3_endpoint.py`: with
`LLMWIKI_S3_ENDPOINT` set, a URL must have that exact scheme, host and port, no credentials, and a path
inside `S3_BUCKET`, and nothing else is accepted.

RustFS runs as its own user on a data directory prepared on the root-owned volume, with its console off.
Without a valid signature it refuses every request, including listing.
