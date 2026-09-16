# Railway template configuration

The template's exact configuration. Reproduce it from this file if it ever has to be rebuilt.

| | |
|---|---|
| Name | LLM Wiki |
| Code | `llm-wiki` |
| Template id | `4ba2d72f-0bed-4c28-b8cf-1433c84b19ea` |
| Deploy URL | https://railway.com/deploy/llm-wiki |
| Category | AI/ML |
| Card description | Karpathy's LLM wiki, self-hosted: Claude builds your wiki over MCP |
| Icon | `assets/icon.png` |
| Overview markdown | `marketplace/OVERVIEW.md` (Railway enforces its section headings) |

Generated values use Railway's `secret()` function: `hexN` is `${{secret(N, "abcdef0123456789")}}` and `alnumN` is
`${{secret(N, "a-zA-Z0-9")}}` spelled out. Alphanumeric passwords are used wherever a value is embedded in a
connection URL, so nothing needs percent-encoding. Images are referenced by tag, because the template generator
rejects digests; `UPSTREAM.md` records the digests.

## Services

### `db`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/llmwiki-railway-db:1.0.1` |
| Public domain | none |
| Volume | `/var/lib/postgresql/data` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `POSTGRES_PASSWORD` | generated, alnum48 |

### `auth`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/llmwiki-railway-auth:1.0.1` |
| Public domain | none |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `JWT_SECRET` | generated, hex64 |
| `LLMWIKI_SIGNING_KEY_SEED` | generated, hex64 |
| `PORT` | `9999` |
| `GOTRUE_DB_DATABASE_URL` | `postgres://supabase_auth_admin:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
| `SUPABASE_PUBLIC_URL` | `https://${{kong.RAILWAY_PUBLIC_DOMAIN}}` |
| `APP_URL` | `https://${{web.RAILWAY_PUBLIC_DOMAIN}}` |
| `GOTRUE_PASSWORD_MIN_LENGTH` | `10` |
| `GOTRUE_MAILER_URLPATHS_CONFIRMATION` | `/auth/v1/verify` |
| `GOTRUE_MAILER_URLPATHS_RECOVERY` | `/auth/v1/verify` |
| `GOTRUE_MAILER_URLPATHS_INVITE` | `/auth/v1/verify` |
| `GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE` | `/auth/v1/verify` |
| `GOTRUE_SMTP_HOST` | optional, unset |
| `GOTRUE_SMTP_PORT` | optional, unset |
| `GOTRUE_SMTP_USER` | optional, unset |
| `GOTRUE_SMTP_PASS` | optional, unset |
| `GOTRUE_SMTP_ADMIN_EMAIL` | optional, unset |
| `GOTRUE_EXTERNAL_GOOGLE_ENABLED` | optional, unset |
| `GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID` | optional, unset |
| `GOTRUE_EXTERNAL_GOOGLE_SECRET` | optional, unset |
| `GOTRUE_EXTERNAL_GOOGLE_REDIRECT_URI` | optional, unset |

### `kong`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/llmwiki-railway-kong:1.0.1` |
| Public domain | target port 8000 |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `8000` |
| `JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `AUTH_HOST` | `${{auth.RAILWAY_PRIVATE_DOMAIN}}` |

### `storage`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/llmwiki-railway-storage:1.0.1` |
| Public domain | target port 9000 |
| Volume | `/data` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `9000` |
| `RUSTFS_ACCESS_KEY` | generated, alnum20 |
| `RUSTFS_SECRET_KEY` | generated, alnum48 |

### `converter`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/llmwiki-railway-converter:1.0.1` |
| Public domain | none |
| Volume | none |
| Healthcheck | `/health`, timeout from `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `8000` |
| `CONVERTER_SECRET` | generated, hex64 |
| `S3_BUCKET` | `llmwiki-documents` |
| `LLMWIKI_S3_ENDPOINT` | `https://${{storage.RAILWAY_PUBLIC_DOMAIN}}` |

### `api`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/llmwiki-railway-api:1.0.1` |
| Public domain | target port 8000 |
| Volume | none |
| Healthcheck | `/health`, timeout from `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `8000` |
| `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` | `600` |
| `JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `DATABASE_URL` | `postgresql://postgres:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
| `SUPABASE_URL` | `https://${{kong.RAILWAY_PUBLIC_DOMAIN}}` |
| `SUPABASE_INTERNAL_URL` | `http://${{kong.RAILWAY_PRIVATE_DOMAIN}}:8000` |
| `APP_URL` | `https://${{web.RAILWAY_PUBLIC_DOMAIN}}` |
| `API_URL` | `https://${{api.RAILWAY_PUBLIC_DOMAIN}}` |
| `AWS_ACCESS_KEY_ID` | `${{storage.RUSTFS_ACCESS_KEY}}` |
| `AWS_SECRET_ACCESS_KEY` | `${{storage.RUSTFS_SECRET_KEY}}` |
| `AWS_ENDPOINT_URL_S3` | `http://${{storage.RAILWAY_PRIVATE_DOMAIN}}:9000` |
| `LLMWIKI_S3_PUBLIC_ENDPOINT` | `https://${{storage.RAILWAY_PUBLIC_DOMAIN}}` |
| `S3_BUCKET` | `llmwiki-documents` |
| `CONVERTER_URL` | `http://${{converter.RAILWAY_PRIVATE_DOMAIN}}:8000` |
| `CONVERTER_SECRET` | `${{converter.CONVERTER_SECRET}}` |
| `OWNER_EMAIL` | required input, no default |
| `OWNER_PASSWORD` | generated, alnum24 |
| `LLMWIKI_SIGNUP_MODE` | `closed` |
| `LLMWIKI_ALLOWED_SIGNUPS` | optional, unset |
| `LLMWIKI_PAGE_LIMIT` | optional, unset |
| `LLMWIKI_STORAGE_LIMIT_BYTES` | optional, unset |
| `MISTRAL_API_KEY` | optional, unset |
| `PDF_BACKEND` | optional, unset |

### `mcp`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/llmwiki-railway-mcp:1.0.1` |
| Public domain | target port 8080 |
| Volume | none |
| Healthcheck | `/health`, timeout from `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `8080` |
| `DATABASE_URL` | `postgresql://postgres:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
| `SUPABASE_URL` | `https://${{kong.RAILWAY_PUBLIC_DOMAIN}}` |
| `APP_URL` | `https://${{web.RAILWAY_PUBLIC_DOMAIN}}` |
| `API_URL` | `https://${{api.RAILWAY_PUBLIC_DOMAIN}}` |
| `MCP_URL` | `https://${{mcp.RAILWAY_PUBLIC_DOMAIN}}/mcp` |
| `AWS_ACCESS_KEY_ID` | `${{storage.RUSTFS_ACCESS_KEY}}` |
| `AWS_SECRET_ACCESS_KEY` | `${{storage.RUSTFS_SECRET_KEY}}` |
| `AWS_ENDPOINT_URL_S3` | `http://${{storage.RAILWAY_PRIVATE_DOMAIN}}:9000` |
| `S3_BUCKET` | `llmwiki-documents` |

### `web`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/llmwiki-railway-web:1.0.1` |
| Public domain | target port 3000 |
| Volume | none |
| Healthcheck | `/login`, timeout from `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `3000` |
| `JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `NEXT_PUBLIC_SUPABASE_URL` | `https://${{kong.RAILWAY_PUBLIC_DOMAIN}}` |
| `NEXT_PUBLIC_API_URL` | `https://${{api.RAILWAY_PUBLIC_DOMAIN}}` |
| `NEXT_PUBLIC_MCP_URL` | `https://${{mcp.RAILWAY_PUBLIC_DOMAIN}}/mcp` |

## Notes

- **Service names are part of the configuration.** Every cross-service reference uses them (`api` reads
  `storage.RUSTFS_ACCESS_KEY`, `converter.CONVERTER_SECRET`, `auth.JWT_SECRET`, and every public URL is built
  from the owning service's `RAILWAY_PUBLIC_DOMAIN`).
- **Five public domains are required**: `web`, `api`, `mcp`, `kong` and `storage`. The browser calls `api` and
  `kong` directly; MCP clients call `mcp` and `kong`; browsers and the converter fetch signed links from
  `storage`. Removing any of them breaks sign-in, uploads, the document viewer or MCP.
- **Storage has two addresses on `api`**: `AWS_ENDPOINT_URL_S3` is the private one (all reads and writes; Railway's
  edge does not complete S3 uploads) and `LLMWIKI_S3_PUBLIC_ENDPOINT` the public one (signed links only). The
  converter's `LLMWIKI_S3_ENDPOINT` must equal the latter, or it refuses every document.
- **`auth` derives the issuer from `SUPABASE_PUBLIC_URL`**; the API and MCP server compare it with their own
  `SUPABASE_URL` + `/auth/v1`. Both must be the `kong` public domain.
- The template was generated from a skeleton project that was never deployed: the generator keeps only
  reference-valued variables, so every literal and generator was patched in afterwards with
  `templateChangeSetStage` and `templateChangeSetApply`. Volumes, domains and healthchecks were checked after
  patching.
- **`api` has a 600-second healthcheck timeout**: the first start applies the migrations and creates the
  owner before the API listens.
- Tested on a clean-room deploy of this template (1.0.1): `tests/railway-smoke.sh` 57/57, a redeploy of all
  eight services keeping the owner's password, a wiki, an uploaded PDF, the signing key and a connected MCP
  client, and 57/57 again afterwards.
