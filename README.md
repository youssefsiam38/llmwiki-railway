# LLM Wiki on Railway

A community Railway template for [LLM Wiki][upstream], the open-source implementation of Andrej Karpathy's
LLM wiki idea: upload papers, notes and web clippings, connect Claude (or Codex, or any MCP client), and let
it compile and maintain an interlinked wiki of what you read, with citations back to the sources. It is not
affiliated with the LLM Wiki project.

LLM Wiki's hosted mode, the multi-user server behind llmwiki.app, expects a Supabase Cloud project with its
OAuth server switched on, an Amazon S3 bucket, and the Supabase CLI to apply the migrations. This template
runs **all of it on Railway, in one project**: a self-hosted Supabase (Postgres, Auth with the OAuth 2.1
server, and the Kong gateway), RustFS object storage, the document converter, and LLM Wiki's API, MCP server
and web app. No Supabase account, no AWS.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/llm-wiki)

## What you get

- **Eight services wired over Railway's private network**, every secret generated at deploy time. Five
  are public: the web app, the API it calls, the MCP endpoint, the Supabase gateway (sign-in and OAuth),
  and the storage endpoint the document viewer loads signed links from.
- **Claude connects with a URL.** Supabase Auth runs as an OAuth 2.1 authorization server with dynamic
  client registration, as on llmwiki.app, so adding `https://<mcp domain>/mcp` as a custom connector in
  Claude (or Codex, Cursor, Claude Code) signs you in through the web app's consent page.
- **Uploads that work**: PDF, Word and PowerPoint files are extracted by the converter service
  (LibreOffice and opendataloader); spreadsheets, HTML, Markdown and images are handled by the API.
- **The database set up for you**: upstream's migrations applied in order on every start, each once.
- **An owner account before anyone can reach the app**, created from the e-mail you enter and a
  generated password.
- **Signup closed by default, enforced in the database.** Supabase Auth accepts anyone on its own. Here the
  owner and the addresses and domains you list get accounts; nobody else.
- **Your limits, not a free tier.** The hosted service caps each account at 500 pages and 1 GiB; here the
  caps are variables, 100,000 pages and 10 GiB by default.
- Images built from a pinned upstream commit with upstream's hash-locked dependencies and pip-audit gate,
  and the whole bundle tested in CI (sign-in, the signup gate, a PDF through the converter, signed file
  links, and a complete OAuth + MCP session) before any image is pushed.

## First run

1. Deploy the template and enter `OWNER_EMAIL`, the address you will sign in with.
2. Wait for `api` and `web` to go green. The first start applies the database migrations; allow a few
   minutes.
3. Copy `OWNER_PASSWORD` from the `api` service's **Variables** tab and sign in on the `web` domain.
   Create your first wiki.
4. Connect Claude: in Claude, **Settings → Connectors → Add custom connector**, paste the MCP URL shown on
   the web app's settings page (`https://<mcp domain>/mcp`), and approve the consent screen. Then ask
   Claude to read the guide and build the wiki.
5. To give colleagues their own accounts, list their addresses or `@yourcompany.com` in
   `LLMWIKI_ALLOWED_SIGNUPS` on `api`; they sign up on the web app.

## Services

| Service | What it is | Image | Public | Volume |
|---|---|---|---|---|
| `web` | LLM Wiki web app | `ghcr.io/youssefsiam38/llmwiki-railway-web` | yes | |
| `api` | LLM Wiki API (hosted mode) | `ghcr.io/youssefsiam38/llmwiki-railway-api` | yes | |
| `mcp` | LLM Wiki MCP server | `ghcr.io/youssefsiam38/llmwiki-railway-mcp` | yes | |
| `converter` | PDF and Office extraction | `ghcr.io/youssefsiam38/llmwiki-railway-converter` | | |
| `storage` | RustFS, S3-compatible | `ghcr.io/youssefsiam38/llmwiki-railway-storage` | yes | `/data` |
| `kong` | Supabase API gateway (Auth, OAuth) | `ghcr.io/youssefsiam38/llmwiki-railway-kong` | yes | |
| `auth` | Supabase Auth (GoTrue) | `ghcr.io/youssefsiam38/llmwiki-railway-auth` | | |
| `db` | Supabase Postgres | `ghcr.io/youssefsiam38/llmwiki-railway-db` | | `/var/lib/postgresql/data` |

See `ARCHITECTURE.md` for how the pieces fit together.

## Variables you may want to change

On the `api` service unless noted.

| Variable | Default | Meaning |
|---|---|---|
| `OWNER_EMAIL` | asked at deploy | The owner account's e-mail. |
| `OWNER_PASSWORD` | generated | The owner's first password. Read on the first start only. |
| `LLMWIKI_ALLOWED_SIGNUPS` | unset | Comma-separated addresses and `@domain` entries that may sign up. |
| `LLMWIKI_SIGNUP_MODE` | `closed` | `open` lets anyone sign up. |
| `LLMWIKI_PAGE_LIMIT` | `100000` | Document pages each account may store. |
| `LLMWIKI_STORAGE_LIMIT_BYTES` | `10737418240` | Upload bytes each account may store. |
| `LLMWIKI_RESET_OWNER_PASSWORD` | unset | Set `true` with a new `OWNER_PASSWORD` to recover the owner; remove afterwards. |
| `MISTRAL_API_KEY`, `PDF_BACKEND` | unset, `opendataloader` | `PDF_BACKEND=mistral` with a key uses Mistral OCR for PDFs. |
| `GOTRUE_SMTP_*` (`auth`) | unset | SMTP for password-reset e-mails. |
| `GOTRUE_EXTERNAL_GOOGLE_*` (`auth`) | unset | Google sign-in; redirect URI `https://<kong domain>/auth/v1/callback`. |
| `GOTRUE_OAUTH_SERVER_ALLOW_DYNAMIC_REGISTRATION` (`auth`) | `true` | `false` stops MCP clients from registering themselves (Claude needs it). |
| `MAX_CONCURRENT_EXTRACTIONS` (`converter`) | `2` | Parallel PDF/Office extractions; each runs LibreOffice and a JVM. |

LLM Wiki's other settings (`QUOTA_MAX_PAGES_PER_DOC`, `GLOBAL_MAX_USERS`, Sentry, Logfire) pass through
unchanged; see upstream's `api/config.py`.

## Persistent data

| Service | Path | Holds | If lost |
|---|---|---|---|
| `db` | `/var/lib/postgresql/data` | Accounts, wikis, pages, extracted text, highlights, OAuth clients and grants, the Vault root key | Everything |
| `storage` | `/data` | Uploaded source files, converted PDFs, extracted images | Original files and figures |

## Before you rely on it

- **The published Chrome extension** is built with llmwiki.app's addresses (or a local install's); using it
  with this server means building it yourself with your URLs. Otherwise add web pages through Claude's
  `add_source_from_url` tool, or upload them.
- **Free-form quiz grading** uses Cloudflare Workers AI (`CLOUDFLARE_*` on `api`); without it that one
  feature is unavailable.
- **The web app's landing, privacy and terms pages** are upstream's, written for llmwiki.app.
- **Password resets need SMTP** on `auth`. Without it, use `LLMWIKI_RESET_OWNER_PASSWORD` for the owner.
- **Licence.** LLM Wiki is Apache-2.0.
- A refused signup shows a generic database error. The refusal is deliberate; see `SECURITY.md`.

## Local development

```bash
docker compose build
tests/static.sh
tests/smoke.sh
tests/persistence.sh
```

The compose file mirrors the Railway services one-to-one with fixed, public, local-test-only secrets. The
web app is served on `http://localhost:13900`, and the API, MCP server, gateway and storage on
`*.localhost` ports 18901, 18902, 18900 and 18903; move them with the `LLMWIKI_TEST_*` variables.

After deploying:

```bash
OWNER_EMAIL=you@example.com OWNER_PASSWORD_FILE=./owner-password \
  tests/railway-smoke.sh https://<web> https://<api> https://<mcp> https://<kong> https://<storage>
```

## Documents

| File | Contents |
|---|---|
| `ARCHITECTURE.md` | Service graph, start-up, keys and the OAuth server, the signup gate, storage |
| `SECURITY.md` | Threat model, what is exposed, residual risks |
| `RAILWAY_TEMPLATE.md` | The exact template configuration |
| `UPSTREAM.md` | Pinned versions, digests, and what this repository changes |
| `MAINTENANCE.md` | Release process, bumping upstream, rollback |
| `MARKETPLACE_AUDIT.md` | Why this template exists |
| `THIRD_PARTY_NOTICES.md` | Licences |

## Licence

MIT for this repository's own files. LLM Wiki is Apache-2.0; the Supabase components are MIT, Apache-2.0
and the PostgreSQL licence; RustFS is Apache-2.0. See `THIRD_PARTY_NOTICES.md`.

[upstream]: https://github.com/lucasastorian/llmwiki
