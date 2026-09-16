#!/bin/bash
# llmwiki-railway Kong entrypoint: mint the API keys, render the routes, start Kong.
set -uo pipefail
log()  { printf '[llmwiki-kong] %s\n' "$*"; }
fail() { printf '[llmwiki-kong] FATAL: %s\n' "$*" >&2; exit 1; }

[ -n "${JWT_SECRET:-}" ] || fail "missing required variable: JWT_SECRET"
[ "${#JWT_SECRET}" -ge 32 ] || fail "JWT_SECRET must be at least 32 characters"
case "$JWT_SECRET" in
  your-super-secret-jwt-token-with-at-least-32-characters-long)
    fail "JWT_SECRET is the value from Supabase's public .env.example. Anyone can sign a service_role token with it. Generate a real one." ;;
esac

[ -n "${AUTH_HOST:-}" ] || fail "AUTH_HOST is empty. On Railway this is a reference to another service's private domain that had not resolved when this deployment started; redeploy once that service has deployed."

PUBLIC_PORT="${PORT:-8000}"
case "$PUBLIC_PORT" in ''|*[!0-9]*) fail "PORT must be a number, got \"$PUBLIC_PORT\"" ;; esac
# Both families: Railway's edge reaches the public listener over IPv4, and the private network is IPv6.
export KONG_PROXY_LISTEN="0.0.0.0:${PUBLIC_PORT}, [::]:${PUBLIC_PORT}"
export KONG_ADMIN_LISTEN=off
export KONG_STATUS_LISTEN="127.0.0.1:8100"

keys=$(llmwiki-mint-keys) || fail "could not mint the Supabase API keys"
SUPABASE_ANON_KEY=$(printf '%s\n' "$keys" | sed -n 's/^ANON_KEY=//p')
SUPABASE_SERVICE_KEY=$(printf '%s\n' "$keys" | sed -n 's/^SERVICE_ROLE_KEY=//p')
unset keys
export SUPABASE_ANON_KEY SUPABASE_SERVICE_KEY

# Upstream's request-transformer expressions, legacy-key branch: pass a user's Authorization header
# through untouched, otherwise forward the apikey as the bearer token.
export LUA_AUTH_EXPR="\$((headers.authorization ~= nil and headers.authorization:sub(1, 10) ~= 'Bearer sb_' and headers.authorization) or headers.apikey)"

# Same substitution as upstream's kong-entrypoint.sh: awk rather than eval, so YAML quoting survives.
umask 077
awk '{
  result = ""
  rest = $0
  while (match(rest, /\$[A-Za-z_][A-Za-z_0-9]*/)) {
    varname = substr(rest, RSTART + 1, RLENGTH - 1)
    if (varname in ENVIRON) {
      result = result substr(rest, 1, RSTART - 1) ENVIRON[varname]
    } else {
      result = result substr(rest, 1, RSTART + RLENGTH - 1)
    }
    rest = substr(rest, RSTART + RLENGTH)
  }
  print result rest
}' /home/kong/temp.yml > "$KONG_DECLARATIVE_CONFIG" || fail "could not render kong.yml"
unset SUPABASE_ANON_KEY SUPABASE_SERVICE_KEY JWT_SECRET

log "gateway on :${PUBLIC_PORT} -> auth=${AUTH_HOST}"
exec /entrypoint.sh kong docker-start
