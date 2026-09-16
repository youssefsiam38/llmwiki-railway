# Security

## Reporting

Open an issue at https://github.com/youssefsiam38/llmwiki-railway/issues for a problem with the template or
its wrappers. Report anything in LLM Wiki itself to its maintainers (https://github.com/lucasastorian/llmwiki).
Do not include credentials, tokens, cookies, public hostnames or private documents in an issue.

## What this bundle holds

Everything a user has read and written: uploaded papers, notes, clippings with highlights and comments, the
compiled wiki pages, and, for each connected MCP client, an OAuth grant that lets it read and change that
user's wikis. Treat an LLM Wiki account, and any client it approved, as access to all of that user's wikis.

## Problems this template closes

| Problem on a public platform | What the template does |
|---|---|
| Supabase Auth accepts any signup, and the sign-up page is linked from the login screen | A `BEFORE INSERT` trigger on `auth.users` admits the owner and `LLMWIKI_ALLOWED_SIGNUPS`; nobody else. It sits under Supabase Auth, so Google sign-in and direct calls to the gateway are gated too. |
| The first account is whoever signs up first | The owner is created before the API listens. |
| Self-hosted Supabase signs sessions with the shared HS256 secret, which LLM Wiki refuses, and has no key pair to publish | A P-256 key is derived from a generated seed; Supabase Auth signs with it and publishes only its public half. The API and MCP server accept ES256 tokens only, so the HS256 secret cannot mint a user session for them. |
| Well-known demo secrets (Supabase's `.env.example`, RustFS's `rustfsadmin`) | Every secret is generated per deploy; the wrappers refuse the published values and short ones. |
| The converter fetches any `*.amazonaws.com` URL it is given; pointed elsewhere it would refuse, or, loosened carelessly, fetch anything | The allowlist is narrowed to the template's own storage origin and bucket, and the converter has no public domain and requires `CONVERTER_SECRET`. |
| Next.js 16.2.12, pinned upstream, has a critical image-optimizer RCE advisory (GHSA-2xp9-vwfh-vxw4) | The web app is built with Next.js 16.3.5 and the other pins with published advisories raised (see `UPSTREAM.md`). |
| Storage CORS left open for convenience | The bucket allows `GET`/`HEAD` from the web app's exact origin only, rewritten on every start. |
| Every user behind Railway's edge shares one rate-limit bucket | The API trusts the edge's `X-Forwarded-For`, so LLM Wiki's per-address limit applies per client. |
| Kong's admin API, access log and request-debug token | Off; Kong routes only Supabase Auth. |
| A redeploy re-running a "create owner" step would reset the owner's password | The start-up does nothing once the `OWNER_EMAIL` account exists. |

## What is exposed

| Surface | Anonymous | Notes |
|---|---|---|
| `web` | The landing, sign-in, sign-up, consent and public-wiki pages | A static app; it holds only the public anon key and the public URLs. |
| `api` | `/health`, and wikis their owners chose to share publicly (`/wiki/<slug>`) | Everything else needs a Supabase ES256 bearer token; queries run as the token's user under row-level security. CORS admits only the web app's origin. |
| `mcp` | `/health` and the OAuth protected-resource metadata | Every MCP call needs an ES256 token; DNS-rebinding protection checks the `Host` against `MCP_URL`. |
| `kong` | OAuth discovery metadata, JWKS, client registration, the authorize redirect, token exchange, e-mail verification and provider callbacks | The rest of Supabase Auth, including the consent and admin APIs, requires the anon or service-role key; the admin API also requires the service role. |
| `storage` | Nothing without a valid signature | The API signs `GET` links for one object for an hour; listing is refused. |
| `converter`, `auth`, `db` | Not public | Private network only. |

The service-role key never reaches a browser: only the API derives it, at start-up, to create the owner.

## MCP clients and dynamic registration

Anyone can register an OAuth client with Supabase Auth (`GOTRUE_OAUTH_SERVER_ALLOW_DYNAMIC_REGISTRATION`,
on by default because Claude requires it). A client alone gets nothing: a signed-in user must approve it
on the web app's consent page, which shows the name the client registered with. The name is chosen by
whoever registered the client, so **only approve a connection you started yourself**, from the MCP client
you are using, a moment ago. An approved client can read and change all of that user's wikis until the
grant is revoked or the signing seed is rotated. The consent page says access can be revoked from Settings,
but upstream's web app has no such screen yet: revoke with Supabase Auth's
`DELETE /auth/v1/user/oauth/grants?client_id=...` (signed in as the user, with the anon key), which ends the
client's sessions; its current access token keeps working until it expires, within an hour.

If nobody on the instance connects Claude or other clients that require it, set
`GOTRUE_OAUTH_SERVER_ALLOW_DYNAMIC_REGISTRATION=false` on `auth`.

## How the signup gate decides

A new user is admitted when one of these holds, and refused otherwise:

1. **Owner bootstrap.** The API's start-up stores the SHA-256 of 32 random bytes and sends those bytes as
   user metadata through the Auth admin API over the private network; the insert deletes the hash. The
   nonce is never logged, never leaves the container, and cannot be replayed.
2. **Allowlist.** The address, or `@` and its domain, is in `LLMWIKI_ALLOWED_SIGNUPS`. The match is exact:
   `@company.com` does not admit `someone@evilcompany.com` or `someone@company.com.evil.test`.
3. **Open mode.** `LLMWIKI_SIGNUP_MODE=open`, set deliberately.

The mode and the allowlist are rewritten from the variables on every start. A second trigger removes the
nonce from metadata on the update Supabase Auth makes right after the insert. `tests/smoke.sh` signs up a
stranger, a look-alike domain and a forged nonce and checks each is refused.

## Residual risks

**Admission is by address.** Addresses are not verified (`GOTRUE_MAILER_AUTOCONFIRM=true`, which LLM Wiki's
sign-up page expects). Someone who knows an allowlisted address can sign up as it before its owner does.
Allowlist domains only if you accept that, or configure SMTP and turn autoconfirm off.

**Consent phishing.** See above: a client's display name is not proof of who registered it.

**Documents leave the instance only when you send them.** Claude (or any MCP client) reads the pages it
asks for; `PDF_BACKEND=mistral` sends signed links to Mistral.

**A refused signup looks like a server error.** Supabase Auth reports any trigger exception as "Database
error saving new user".

**Anyone with access to the Railway project has everything.** Project variables contain the database
password, the JWT secret and signing seed (from which any session and API key follows), and the storage
credentials. Treat project membership as root on every wiki.

**Signed storage links work for an hour for whoever holds them**, as on llmwiki.app.

**Rate limiting trusts `X-Forwarded-For`.** A client that adds its own header can spread its requests over
several limit buckets; the limit is a guard against runaway clients, not an access control.

**The Vault root key** is a file on the `db` volume, beside the data it protects, because Railway gives a
service one volume. LLM Wiki does not use Vault.
