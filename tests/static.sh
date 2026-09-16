#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted literals are matched, not expanded
# Static validation: syntax, shellcheck, compose, image pins, key minting and derivation, security defaults.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
cd "$REPO_ROOT"
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"

section "syntax"
for f in images/*/*.sh tests/*.sh; do
  if bash -n "$f" 2>/dev/null; then pass "parses: $f"; else fail "syntax error: $f"; fi
done
for f in lib/*.mjs images/*/*.mjs; do
  if node --check "$f" 2>/dev/null; then pass "parses: $f"; else fail "syntax error: $f"; fi
done
for f in images/*/*.py tests/*.py lib/*.py; do
  if python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$f" 2>/dev/null; then pass "parses: $f"; else fail "syntax error: $f"; fi
done
if perl -c images/kong/mint-keys.pl >/dev/null 2>&1; then pass "parses: images/kong/mint-keys.pl"; else fail "syntax error: images/kong/mint-keys.pl"; fi
if command -v gofmt >/dev/null; then
  [ -z "$(gofmt -l images/auth/keygen)" ] && pass "gofmt: images/auth/keygen" || fail "gofmt: images/auth/keygen"
else
  echo "  SKIP  gofmt not installed (the auth image build runs gofmt and go vet)"
fi

section "shellcheck"
if command -v shellcheck >/dev/null; then
  if shellcheck images/*/*.sh; then pass "shellcheck images"; else fail "shellcheck images"; fi
  if shellcheck -x -s bash tests/*.sh; then pass "shellcheck tests"; else fail "shellcheck tests"; fi
else
  echo "  SKIP  shellcheck not installed"
fi

section "compose"
if docker compose -f compose.yaml config -q; then pass "compose config"; else fail "compose config"; fi
cfg=$(docker compose -f compose.yaml config --format json)
assert_eq "eight services, as on Railway" "8" "$(jq '.services | length' <<<"$cfg")"
assert_eq "public services: web, api, mcp, the gateway and storage" "api kong mcp storage web" \
  "$(jq -r '[.services | to_entries[] | select(.value.ports) | .key] | sort | join(" ")' <<<"$cfg")"
assert_eq "published ports bind to loopback" "127.0.0.1 127.0.0.1 127.0.0.1 127.0.0.1 127.0.0.1" \
  "$(jq -r '[.services[] | .ports[]? | .host_ip] | join(" ")' <<<"$cfg")"
assert_eq "the test network has IPv6, like Railway's" "true" "$(jq -r '.networks.default.enable_ipv6' <<<"$cfg")"
assert_eq "the converter is private" "null" "$(jq -r '.services.converter.ports' <<<"$cfg")"
assert_eq "the API signs storage links with the public storage URL" "$(jq -r '.services.converter.environment.LLMWIKI_S3_ENDPOINT' <<<"$cfg")" \
  "$(jq -r '.services.api.environment.AWS_ENDPOINT_URL_S3' <<<"$cfg")"

section "images are pinned"
for df in images/*/Dockerfile; do
  base=$(grep -E '^ARG [A-Z_]+_IMAGE=' "$df")
  [ -n "$base" ] || { fail "$df has no pinned base image argument"; continue; }
  if grep -vqE '@sha256:[0-9a-f]{64}$' <<<"$base"; then fail "$df base image lacks a digest"; else pass "$df base pinned by digest"; fi
done
commits=$(grep -h '^ARG LLMWIKI_COMMIT=' images/*/Dockerfile | sort -u)
assert_eq "api, mcp, converter and web build the same upstream commit" "1" "$(wc -l <<<"$commits" | tr -d ' ')"
assert_contains "and it is an exact commit" '^ARG LLMWIKI_COMMIT=[0-9a-f]\{40\}$' "$commits"
for img in api mcp converter web; do
  assert_contains "$img verifies the fetched commit" 'test "$(git -C /src rev-parse HEAD)" = "${LLMWIKI_COMMIT}"' "$(cat "images/$img/Dockerfile")"
done
for img in api mcp converter; do
  df=$(cat "images/$img/Dockerfile")
  assert_contains "$img installs upstream's hash-locked dependencies" 'uv pip install --system --require-hashes -r /tmp/requirements.lock' "$df"
  assert_contains "$img keeps upstream's pip-audit gate" 'pip-audit -r /tmp/requirements.lock --strict' "$df"
  assert_contains "$img pins its tools" 'ARG UV_VERSION=[0-9]' "$df"
done
web_df=$(cat images/web/Dockerfile)
assert_contains "the web build checks upstream's package.json is the one the override came from" '${UPSTREAM_PACKAGE_JSON_SHA256}  /src/web/package.json" | sha256sum -c -' "$web_df"
assert_contains "and its lockfile" '${UPSTREAM_PACKAGE_LOCK_SHA256}  /src/web/package-lock.json" | sha256sum -c -' "$web_df"
assert_contains "the web build installs from the lockfile" 'npm ci' "$web_df"
assert_eq "the override raises Next.js past the image-optimizer RCE advisory" "16.3.5" "$(jq -r .dependencies.next images/web/deps/package.json)"
assert_eq "the lockfile agrees" "16.3.5" "$(jq -r '.packages["node_modules/next"].version' images/web/deps/package-lock.json)"
assert_contains "and it is built in hosted mode" '^ENV NEXT_PUBLIC_MODE=hosted' "$web_df"
for v in JWT_SECRET POSTGRES_PASSWORD OWNER_PASSWORD LLMWIKI_SIGNING_KEY_SEED CONVERTER_SECRET AWS_SECRET_ACCESS_KEY RUSTFS_SECRET_KEY; do
  if grep -qE "^\s+$v=|^ENV $v=|ARG $v" images/*/Dockerfile; then fail "$v is baked into an image"; else pass "no $v in any image"; fi
done

section "keys"
# Kong's key-auth compares API keys as strings, so every minter must produce byte-identical keys.
secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
node_out=$(JWT_SECRET="$secret" node lib/mint-supabase-keys.mjs)
perl_out=$(JWT_SECRET="$secret" perl images/kong/mint-keys.pl)
py_out=$(cd images/api && JWT_SECRET="$secret" python3 -c '
import os, importlib.util, sys, types
for m in ("aioboto3", "asyncpg", "httpx"): sys.modules.setdefault(m, types.ModuleType(m))
sys.modules["asyncpg"].Connection = object
bc = types.ModuleType("botocore"); ex = types.ModuleType("botocore.exceptions"); ex.ClientError = Exception
sys.modules.setdefault("botocore", bc); sys.modules.setdefault("botocore.exceptions", ex)
spec = importlib.util.spec_from_file_location("s", "railway_setup.py"); s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)
print("ANON_KEY=" + s.mint("anon", os.environ["JWT_SECRET"])); print("SERVICE_ROLE_KEY=" + s.mint("service_role", os.environ["JWT_SECRET"]))')
assert_eq "node and perl minters produce identical keys" "$(sha256sum <<<"$node_out" | cut -c1-16)" "$(sha256sum <<<"$perl_out" | cut -c1-16)"
assert_eq "the API's python minter does too" "$(sha256sum <<<"$node_out" | cut -c1-16)" "$(sha256sum <<<"$py_out" | cut -c1-16)"
anon=$(sed -n 's/^ANON_KEY=//p' <<<"$node_out")
sig_openssl=$(printf '%s' "$(cut -d. -f1-2 <<<"$anon")" | openssl dgst -sha256 -hmac "$secret" -binary | base64 | tr '+/' '-_' | tr -d '=')
assert_eq "signature verifies independently with openssl" "$sig_openssl" "$(cut -d. -f3 <<<"$anon")"
keygen=$(cat images/auth/keygen/main.go)
assert_contains "the signing key is derived with HMAC-SHA256 from the seed" 'hmac.New(sha256.New, seed)' "$keygen"
assert_contains "the seed must carry 256 bits" 'len(seed) < 32' "$keygen"
assert_contains "the legacy HS256 secret is verify-only" '"kid": "legacy-hs256", "alg": "HS256", "use": "sig", "key_ops": \[\]string{"verify"}' "$keygen"
assert_contains "the key id is the RFC 7638 thumbprint" '{"crv":"P-256","kty":"EC","x":"' "$keygen"
if command -v docker >/dev/null && docker image inspect llmwiki-railway-auth:local >/dev/null 2>&1; then
  seed=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
  a=$(docker run --rm --entrypoint llmwiki-keys -e JWT_SECRET="$secret" -e LLMWIKI_SIGNING_KEY_SEED="$seed" llmwiki-railway-auth:local jwks)
  b=$(docker run --rm --entrypoint llmwiki-keys -e JWT_SECRET="$secret" -e LLMWIKI_SIGNING_KEY_SEED="$seed" llmwiki-railway-auth:local jwks)
  assert_eq "the same seed gives the same key" "$a" "$b"
  assert_eq "the public JWKS carries no private material" "false" "$(jq '[.keys[] | has("d") or has("k")] | any' <<<"$a")"
  if docker run --rm --entrypoint llmwiki-keys -e JWT_SECRET="$secret" -e LLMWIKI_SIGNING_KEY_SEED=abc llmwiki-railway-auth:local jwks >/dev/null 2>&1; then
    fail "a short seed was accepted"
  else
    pass "a short seed is refused"
  fi
else
  echo "  SKIP  llmwiki-railway-auth:local not built; key derivation runs in the smoke test"
fi

section "who gets in"
gate=$(cat images/api/gate.sql)
assert_contains "the gate is a BEFORE INSERT trigger on auth.users" 'before insert on auth.users' "$gate"
assert_contains "the owner nonce is single-use" "delete from llmwiki_railway.settings" "$gate"
assert_contains "the allowlist matches whole addresses or whole domains" "entry = v_email or entry = '@' || split_part(v_email, '@', 2)" "$gate"
setup=$(cat images/api/railway_setup.py)
assert_contains "signup defaults to closed" 'env("LLMWIKI_SIGNUP_MODE", "closed")' "$setup"
assert_contains "the owner claim is the owner's own address" "select id::text from auth.users where lower(email) = \$1" "$setup"
assert_contains "the nonce is removed whatever happens" "finally:" "$setup"
assert_contains "migrations are recorded with a checksum" 'insert into llmwiki_railway.migrations (name, sha256)' "$setup"
assert_contains "a database with foreign LLM Wiki tables is refused" 'refusing to' "$setup"
api_ep=$(cat images/api/entrypoint.sh)
assert_contains "local mode (no sign-in) is refused" 'MODE must stay hosted' "$api_ep"
setup_line=$(grep -n 'railway_setup.py' images/api/entrypoint.sh | head -1 | cut -d: -f1)
start_line=$(grep -n 'exec python /opt/llmwiki-railway/serve.py' images/api/entrypoint.sh | cut -d: -f1)
[ "$setup_line" -lt "$start_line" ] && pass "start-up steps finish before the API listens" || fail "the API starts before the start-up steps"
assert_contains "secrets the API does not need are dropped before it starts" 'unset JWT_SECRET OWNER_PASSWORD' "$api_ep"
auth_ep=$(cat images/auth/entrypoint.sh)
assert_contains "the issuer is derived, not typed" 'GOTRUE_JWT_ISSUER="${SUPABASE_PUBLIC_URL}/auth/v1"' "$auth_ep"
assert_contains "Supabase's example JWT secret is refused" 'your-super-secret-jwt-token-with-at-least-32-characters-long' "$auth_ep"
assert_contains "the seed is dropped before Supabase Auth starts" 'unset JWT_SECRET LLMWIKI_SIGNING_KEY_SEED' "$auth_ep"

section "the converter patch"
patch=$(cat images/converter/patch_s3_endpoint.py)
assert_contains "the patch fails the build unless it matches exactly once" 'source.count(ANCHOR) != 1' "$patch"
assert_contains "scheme, host and port must all match" 'parsed.port != _expected.port' "$patch"
assert_contains "credentials in the URL are refused" 'parsed.username is not None' "$patch"
assert_contains "the path must be inside the bucket" 'parsed.path.startswith(f"/{S3_BUCKET}/")' "$patch"
assert_contains "the image build checks the patch is in place" "grep -q \"llmwiki-railway: the template's bundled object storage\" /app/main.py" "$(cat images/converter/Dockerfile)"
assert_contains "the converter refuses to start without the endpoint" 'missing required variable: LLMWIKI_S3_ENDPOINT' "$(cat images/converter/entrypoint.sh)"
assert_contains "and listens on IPv6 for Railway's private network" 'exec python /opt/llmwiki-railway/serve.py main:app' "$(cat images/converter/entrypoint.sh)"
assert_contains "the launcher turns IPV6_V6ONLY off, so IPv4 works too" 'IPV6_V6ONLY, 0' "$(cat lib/serve.py)"

section "gateway"
kong_df=$(cat images/kong/Dockerfile)
kong_ep=$(cat images/kong/entrypoint.sh)
kong_yml=$(grep -v "^#" images/kong/kong.yml)
assert_contains "Kong admin API off" 'KONG_ADMIN_LISTEN=off' "$kong_ep"
assert_contains "Kong access log off" 'KONG_PROXY_ACCESS_LOG=off' "$kong_df"
assert_contains "Kong request debugging off" 'KONG_REQUEST_DEBUG=off' "$kong_df"
for route in rest-v1 graphql-v1 storage-v1 realtime-v1 functions-v1 pg-meta; do assert_not_contains "no $route route" "$route" "$kong_yml"; done
open_oauth=$(grep -c 'paths: \["/.*\$"\]' images/kong/kong.yml)
assert_eq "exactly six open OAuth routes, each anchored to one path" "6" "$open_oauth"
assert_not_contains "the consent API is not opened" 'oauth/authorizations' "$kong_yml"
assert_not_contains "no admin route is opened" '/admin' "$kong_yml"
assert_contains "the vault key lives on the data volume" '/var/lib/postgresql/data/pgsodium_root.key' "$(cat images/db/getkey.sh)"

section "log streams"
# Railway colours a log line by the stream it arrived on: routine lines on stderr show as errors.
for f in images/*/entrypoint.sh; do
  if grep -q '^log()' "$f"; then
    if ! grep '^log()' "$f" | grep -q '>&2'; then pass "routine logs go to stdout: $f"; else fail "log() writes to stderr: $f"; fi
  fi
  if grep '^fail()' "$f" | grep -q '>&2'; then pass "failures go to stderr: $f"; else fail "fail() does not write to stderr: $f"; fi
done

section "workflows"
for wf in .github/workflows/*.yml; do
  if grep -qE 'uses: .*@[0-9a-f]{40}' "$wf" && ! grep -qE 'uses: [^#]*@v[0-9]+\s*$' "$wf"; then
    pass "actions pinned by SHA in $wf"
  else
    fail "unpinned action in $wf"
  fi
done
for c in db auth kong storage converter api mcp web; do
  var="LLMWIKI_RAILWAY_$(tr '[:lower:]' '[:upper:]' <<<"$c")_IMAGE"
  assert_contains "compose lets CI override the $c image" "$var" "$(cat compose.yaml)"
  assert_contains "the publish workflow tests the $c candidate" "$var" "$(cat .github/workflows/publish-image.yml)"
done

section "no tracked secrets"
if git rev-parse --git-dir >/dev/null 2>&1; then
  if git grep -nIE '(BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_|xox[baprs]-|sk-[A-Za-z0-9]{32,}|eyJhbGciOi)' -- . ':!tests/static.sh' ':!images/web/deps/package-lock.json' >/dev/null 2>&1; then
    fail "credential pattern in tracked files"
  else
    pass "no credential patterns in tracked files"
  fi
  if git ls-files --error-unmatch .env >/dev/null 2>&1; then fail ".env is tracked"; else pass ".env not tracked"; fi
else
  echo "  SKIP  not a git checkout"
fi
summary
