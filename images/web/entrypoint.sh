#!/bin/sh
# llmwiki-railway web entrypoint: mint the public anon key, write the public URLs into the built app, start
# the web server. Values are never printed.
set -u
log()  { printf '[llmwiki-web] %s\n' "$*"; }
fail() { printf '[llmwiki-web] FATAL: %s\n' "$*" >&2; exit 1; }

for name in JWT_SECRET NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_API_URL NEXT_PUBLIC_MCP_URL; do
  eval "v=\${$name:-}"
  # shellcheck disable=SC2154  # v is assigned by the eval above
  [ -n "$v" ] || fail "missing required variable: $name"
done
[ "${#JWT_SECRET}" -ge 32 ] || fail "JWT_SECRET must be at least 32 characters"
for name in NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_API_URL NEXT_PUBLIC_MCP_URL; do
  eval "v=\${$name:-}"
  case "$v" in
    *://|*://:*|*://.*|*:///*)
      fail "$name has no host name. On Railway this is a reference to another service's domain that had not resolved when this deployment started; redeploy once that service has deployed." ;;
  esac
done
NEXT_PUBLIC_SUPABASE_URL=${NEXT_PUBLIC_SUPABASE_URL%/}
NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL%/}

keys=$(node /opt/llmwiki-railway/mint-supabase-keys.mjs) || fail "could not mint the Supabase anon key"
NEXT_PUBLIC_SUPABASE_ANON_KEY=$(printf '%s\n' "$keys" | sed -n 's/^ANON_KEY=//p')
unset keys JWT_SECRET
export NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_ANON_KEY NEXT_PUBLIC_API_URL NEXT_PUBLIC_MCP_URL

node /opt/llmwiki-railway/fill-public-env.mjs || exit 1

: "${PORT:=3000}"
case "$PORT" in ''|*[!0-9]*) fail "PORT must be a number, got \"$PORT\"" ;; esac
export PORT HOSTNAME=::
log "starting LLM Wiki web app on [::]:${PORT}"
cd /app && exec node server.js
