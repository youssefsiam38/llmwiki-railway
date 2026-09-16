# Third-party notices

Licences for code copied into or built into this repository's images are vendored in `licenses/` and
shipped inside every wrapper image at `/usr/share/licenses/llmwiki-railway/`.

## LLM Wiki: Apache-2.0

The `api`, `mcp`, `converter` and `web` images contain LLM Wiki, built from
https://github.com/lucasastorian/llmwiki at the commit in `UPSTREAM.md`, under the Apache License 2.0
(`licenses/LLMWIKI-LICENSE`). The changes are listed in `UPSTREAM.md`: the converter's download allowlist
(`images/converter/patch_s3_endpoint.py`) and raised dependency versions for the web build. This
repository's own files (Dockerfiles, scripts, tests, docs) are MIT.

## Copied into the images

| What | From | Licence | Notice |
|---|---|---|---|
| Database migrations, run at start-up | lucasastorian/llmwiki `supabase/migrations/` | Apache-2.0 | `licenses/LLMWIKI-LICENSE` |
| `web` `package.json` and lockfile, with raised pins | lucasastorian/llmwiki `web/` | Apache-2.0 | `licenses/LLMWIKI-LICENSE` |
| Five database init scripts | supabase/supabase `docker/volumes/db` | Apache-2.0 | `licenses/SUPABASE-LICENSE` |
| Kong declarative config, trimmed and extended | supabase/supabase `docker/volumes/api/kong.yml` | Apache-2.0 | `licenses/SUPABASE-LICENSE` |

LLM Wiki's Python and npm dependencies are installed from its lockfiles and carry their own licences.

## Base images

| Image | Licence |
|---|---|
| `supabase/postgres` | PostgreSQL Licence; bundled extensions under their own licences |
| `supabase/gotrue` | MIT |
| `kong` | Apache-2.0 |
| `rustfs/rustfs` | Apache-2.0 |
| `python`, `node`, `golang` (build only) | Their own licences; Debian and Alpine packages under theirs |
| LibreOffice (converter) | MPL-2.0 |
| OpenJDK 17 (converter) | GPL-2.0 with the Classpath Exception |
