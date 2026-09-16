# Deploy and Host LLM Wiki on Railway

LLM Wiki is an open-source take on Andrej Karpathy's LLM wiki idea: a personal Wikipedia that an AI builds
and maintains for you. Upload papers, notes, PDFs, Word and PowerPoint files, connect Claude (or Codex, or
any MCP client), and let it compile interlinked wiki pages with citations back to your sources, then keep
them current as you add more. This is a community-maintained template; it is not affiliated with the LLM
Wiki project.

## About Hosting LLM Wiki

LLM Wiki's hosted mode is a Next.js web app, a FastAPI API, an MCP server and a document converter
(LibreOffice and opendataloader), on Supabase Auth and Postgres with S3 storage. Claude and other MCP
clients sign in through Supabase Auth's OAuth 2.1 server. Upstream runs it on Supabase Cloud and AWS and
documents only its local desktop mode.

This template runs the whole hosted stack on Railway, in one project, eight services with every secret
generated: a self-hosted Supabase (Postgres, Auth with the OAuth server, and its gateway), RustFS object
storage, the converter, and LLM Wiki's API, MCP server and web app, built from a pinned upstream commit.
No Supabase account and no AWS.

The first start does the setup for you: it applies LLM Wiki's database migrations, creates the storage
bucket with a CORS policy for your web app, creates your owner account from the e-mail you enter, and only
then starts the API. Signup is closed by default and enforced in the database: only the owner and the
addresses or domains you list get accounts.

## Why Deploy LLM Wiki on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your
infrastructure so you don't have to deal with configuration, while allowing you to vertically and
horizontally scale it.

By deploying LLM Wiki on Railway, you are one step closer to supporting a complete full-stack application
with minimal burden. Host your servers, databases, AI agents, and more on Railway.

Concretely, this template keeps the database, Supabase Auth and the converter on Railway's private
network, serves the web app, API, MCP endpoint, sign-in gateway and signed file links over HTTPS, and
attaches volumes to the database and the document store. Your MCP server has a stable HTTPS URL that
Claude's custom connectors can reach.

## Common Use Cases

- A research wiki that Claude keeps up to date from the papers and articles you upload.
- A team's institutional memory: shared sources, compiled pages, one account per colleague.
- Course notes and study guides built from lecture PDFs and slides.
- A private context layer for Claude, Codex or Cursor over MCP, on infrastructure you control.

## Dependencies for LLM Wiki Hosting

- An MCP client such as Claude (claude.ai custom connectors, Claude Desktop or Claude Code), Codex or
  Cursor. The template itself needs no API key.
- Optional: a Mistral API key for higher-quality PDF OCR.
- Optional: SMTP for password-reset e-mails, and a Google OAuth client for Google sign-in.

### Deployment Dependencies

- LLM Wiki: https://github.com/lucasastorian/llmwiki (Apache-2.0)
- Supabase self-hosting stack: https://github.com/supabase/supabase/tree/master/docker (Apache-2.0)
- Supabase Auth: https://github.com/supabase/auth (MIT)
- RustFS: https://github.com/rustfs/rustfs (Apache-2.0)
- Template repository, images and tests: https://github.com/youssefsiam38/llmwiki-railway

### Implementation Details

The API, MCP server and web app are built from a pinned upstream commit with upstream's hash-locked
dependencies and its pip-audit gate; the web build raises the dependency pins that carry published
advisories, including a critical Next.js one. Supabase Auth signs sessions with an ES256 key derived from a
generated seed, which LLM Wiki's API and MCP server require and Railway cannot generate directly. The
converter's download allowlist is narrowed to the template's own storage bucket. Every service refuses to
start on missing, short or published example secrets.

The bundle is tested as a whole in CI and on a live deployment of this template: sign-in, the signup gate,
a PDF extracted by the converter, signed file links, account isolation, and a complete MCP session as
Claude runs it (client registration, consent, token exchange, tool calls that read the PDF and write and
search a wiki page, token refresh and revocation), on fresh and reused volumes.

The deploy form asks for one value, `OWNER_EMAIL`. After deploying, copy `OWNER_PASSWORD` from the api
service's variables, sign in on the web app's domain, and add the MCP URL from the settings page to Claude
as a custom connector.
