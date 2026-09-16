# Upstream provenance

Everything the bundle runs, where it comes from, and what this repository changes. Digests are
multi-architecture index digests as resolved on 2026-09-16. The Railway template references tags, because
Railway's template generator rejects digest references; the Dockerfiles pin tag and digest.

## LLM Wiki

| | |
|---|---|
| Project | https://github.com/lucasastorian/llmwiki |
| Licence | Apache-2.0 (`licenses/LLMWIKI-LICENSE`) |
| Commit pinned | `aac3e6493306b7fff3b09cb181ca93918e93d0e6` (2026-08-09, `master`, "Merge pull request #80 from lucasastorian/dev") |
| Why a commit | Upstream publishes no releases or images; its hosted service deploys `master`. |
| Components built | `api/`, `mcp/`, `converter/`, `web/`, and `supabase/migrations/` run at start-up |

The source is fetched by commit id, so git verifies the content.

### What this repository changes

| Component | Change | Why |
|---|---|---|
| `api` | `S3Service.generate_presigned_get/put` sign with `LLMWIKI_S3_PUBLIC_ENDPOINT` while every other storage call uses the private address (`images/api/patch_s3_presign.py`; the build fails if the methods change upstream). The image adds `railway_setup.py` (migrations, signup gate, limits, bucket, owner), `gate.sql`, `lib/serve.py` and an entrypoint; runs as an unprivileged user. | Railway's edge does not complete S3 uploads; upstream relies on the Supabase CLI and hand-made cloud resources. |
| `mcp` | None. Entrypoint validation only; runs as an unprivileged user. | |
| `converter` | `_validate_s3_url` accepts the template's own storage origin and bucket when `LLMWIKI_S3_ENDPOINT` is set (`images/converter/patch_s3_endpoint.py`; the build fails if the function changes upstream). Dependencies install from upstream's `requirements.lock` with hashes rather than the unpinned `requirements.txt`. Served on a dual-stack socket. | Upstream accepts Amazon S3 URLs only. |
| `web` | None to the code. `package.json` and `package-lock.json` are upstream's with the pins below raised; the build checks upstream's own manifest hashes first. Built with placeholder public URLs, filled at start. | Published advisories; one-click deploys cannot rebuild per deployment. |

Dependency pins raised in `images/web/deps` (production `npm audit` is clean after the change):

| Package | Upstream | Here | Advisory |
|---|---|---|---|
| `next` | 16.2.12 | 16.3.5 | GHSA-2xp9-vwfh-vxw4 (critical, RCE in the image optimizer via AVIF), GHSA-p293-qw3h-jr36 |
| `sharp` (override) | 0.35.3 | 0.35.4 | GHSA-rgj7-g3m4-5g8c (libheif) |
| `@tiptap/*` (and the `core`/`pm` overrides) | 3.22.2 | 3.30.5 | GHSA-cp6q-959q-f8rh, GHSA-j95f-988m-3j2f |
| `fast-uri` (override) | 3.1.5 | 3.1.6 | GHSA-5jgf-p345-68v8, GHSA-f65p-4m7j-42xc |

Python dependencies are upstream's hash-locked files, unchanged, and the build runs `pip-audit --strict`
on them as upstream's Dockerfiles do.

| Tool | Version |
|---|---|
| uv | 0.12.15 (upstream installs it unpinned) |
| pip-audit | 2.10.1 (upstream installs it unpinned) |

## Supabase

| Component | Image | Digest | Licence |
|---|---|---|---|
| Postgres (with pgroonga) | `supabase/postgres:17.6.1.136` | `sha256:f371b5f3f2ac0a05703f33d6e6134515fb2498cab708fb948a0aeb7481467c00` | PostgreSQL, Apache-2.0 |
| Auth | `supabase/gotrue:v2.197.0` | `sha256:1736a63078f5922b198c4cbe50f80ab9a2d3b54fe8b7b6cfb2e9dc5dbbc12c6b` | MIT |
| Kong | `kong:3.9.3` | `sha256:9a2ae6699a2ce0d60592eb176555d3594a22782c20cc6557a61ff3a7e8b559a3` | Apache-2.0 |

Supabase Auth v2.197.0 (the latest release on 2026-09-16) provides the OAuth 2.1 server this template
relies on (`GOTRUE_OAUTH_SERVER_*`, dynamic client registration, the consent and grant APIs) and asymmetric
`GOTRUE_JWT_KEYS`. The `auth` wrapper adds `llmwiki-keys` (built with `golang:1.25-alpine`,
`sha256:1ae0735f00daffa3aaf1363a5184c0d2dc55c78e3db4ec70241cdac97bf84b59`) and an entrypoint. The `db` and
`kong` wrappers are derived from the Morphic template's: init scripts baked in, the Vault key on
the data volume, Kong's routes trimmed to Auth plus the OAuth endpoints.

## RustFS

| | |
|---|---|
| Image | `rustfs/rustfs:1.0.0`, `sha256:8cc9801755448b71a786705ce76692c77e14936cccd87cf2fc31842e58f4d1ff` |
| Licence | Apache-2.0 |

The wrapper adds `su-exec` and an entrypoint that prepares the data directory on the volume, turns the
console off and refuses default credentials.

## Base images

| Image | Digest | Used by |
|---|---|---|
| `python:3.11-slim-bookworm` | `sha256:528257d48c1da0dcecc2e725d1ae34498d60c965f1241e39cd6a85a8859bdf84` | api, mcp, converter (as upstream) |
| `node:22-alpine` | `sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32` | web (as upstream) |

The converter installs LibreOffice Writer, Impress and Calc and OpenJDK 17 from Debian bookworm at build
time, as upstream's Dockerfile does.
