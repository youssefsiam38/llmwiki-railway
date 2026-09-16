#!/bin/sh
# llmwiki-railway auth entrypoint: derive the JWT keys, fill in the settings LLM Wiki depends on, start
# Supabase Auth. Values are never printed.
set -u
log()  { printf '[llmwiki-auth] %s\n' "$*"; }
fail() { printf '[llmwiki-auth] FATAL: %s\n' "$*" >&2; exit 1; }

for name in JWT_SECRET LLMWIKI_SIGNING_KEY_SEED GOTRUE_DB_DATABASE_URL SUPABASE_PUBLIC_URL APP_URL; do
  eval "v=\${$name:-}"
  # shellcheck disable=SC2154  # v is assigned by the eval above
  [ -n "$v" ] || fail "missing required variable: $name"
done
case "$JWT_SECRET" in
  your-super-secret-jwt-token-with-at-least-32-characters-long)
    fail "JWT_SECRET is the value from Supabase's public .env.example. Anyone can sign a service_role token with it." ;;
esac
# A Railway reference to another service's domain is empty until that service has deployed.
for name in GOTRUE_DB_DATABASE_URL SUPABASE_PUBLIC_URL APP_URL; do
  eval "v=\${$name:-}"
  case "$v" in
    *://|*://:*|*://.*|*:///*|*@:*|*@/*)
      fail "$name has no host name. On Railway this is a reference to another service's domain that had not resolved when this deployment started; redeploy once that service has deployed." ;;
  esac
done
SUPABASE_PUBLIC_URL=${SUPABASE_PUBLIC_URL%/}
APP_URL=${APP_URL%/}
printf '%s' "$SUPABASE_PUBLIC_URL" | grep -Eqx 'https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?' || fail "SUPABASE_PUBLIC_URL must be an origin such as https://kong-production.up.railway.app"
printf '%s' "$APP_URL" | grep -Eqx 'https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?' || fail "APP_URL must be an origin such as https://web-production.up.railway.app"

GOTRUE_JWT_KEYS=$(llmwiki-keys jwt-keys) || fail "could not derive the JWT signing key"
GOTRUE_JWT_SECRET=$JWT_SECRET
unset JWT_SECRET LLMWIKI_SIGNING_KEY_SEED

# LLM Wiki's API and MCP server check the issuer against SUPABASE_URL + /auth/v1, so it is derived, not
# typed. MCP clients discover the OAuth endpoints from the same issuer.
GOTRUE_JWT_ISSUER="${SUPABASE_PUBLIC_URL}/auth/v1"
: "${API_EXTERNAL_URL:=$SUPABASE_PUBLIC_URL}"
: "${GOTRUE_SITE_URL:=$APP_URL}"
: "${GOTRUE_URI_ALLOW_LIST:=${APP_URL}/**}"

# Supabase Auth's OAuth 2.1 server, as LLM Wiki's hosted service configures it: the consent screen is the
# web app's /oauth/authorize page, and MCP clients register themselves (Claude requires dynamic
# registration). Registering a client grants nothing; a signed-in user still has to approve it.
: "${GOTRUE_OAUTH_SERVER_ENABLED:=true}"
: "${GOTRUE_OAUTH_SERVER_AUTHORIZATION_PATH:=/oauth/authorize}"
: "${GOTRUE_OAUTH_SERVER_ALLOW_DYNAMIC_REGISTRATION:=true}"

: "${GOTRUE_API_HOST:=::}"
: "${GOTRUE_API_PORT:=9999}"
: "${GOTRUE_DB_DRIVER:=postgres}"
: "${GOTRUE_JWT_AUD:=authenticated}"
: "${GOTRUE_JWT_DEFAULT_GROUP_NAME:=authenticated}"
: "${GOTRUE_JWT_ADMIN_ROLES:=service_role}"
: "${GOTRUE_JWT_EXP:=3600}"
: "${GOTRUE_EXTERNAL_EMAIL_ENABLED:=true}"
: "${GOTRUE_EXTERNAL_PHONE_ENABLED:=false}"
: "${GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED:=false}"
# Who may sign up is decided by the database gate (see images/api/gate.sql), not by this switch.
: "${GOTRUE_DISABLE_SIGNUP:=false}"
# LLM Wiki's sign-up page expects a session straight away, as its hosted service gives one.
: "${GOTRUE_MAILER_AUTOCONFIRM:=true}"

export GOTRUE_JWT_KEYS GOTRUE_JWT_SECRET GOTRUE_JWT_ISSUER API_EXTERNAL_URL GOTRUE_SITE_URL GOTRUE_URI_ALLOW_LIST \
       GOTRUE_OAUTH_SERVER_ENABLED GOTRUE_OAUTH_SERVER_AUTHORIZATION_PATH GOTRUE_OAUTH_SERVER_ALLOW_DYNAMIC_REGISTRATION \
       GOTRUE_API_HOST GOTRUE_API_PORT GOTRUE_DB_DRIVER GOTRUE_JWT_AUD GOTRUE_JWT_DEFAULT_GROUP_NAME GOTRUE_JWT_ADMIN_ROLES \
       GOTRUE_JWT_EXP GOTRUE_EXTERNAL_EMAIL_ENABLED GOTRUE_EXTERNAL_PHONE_ENABLED GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED \
       GOTRUE_DISABLE_SIGNUP GOTRUE_MAILER_AUTOCONFIRM

log "issuer ${GOTRUE_JWT_ISSUER}; OAuth server ${GOTRUE_OAUTH_SERVER_ENABLED}, dynamic client registration ${GOTRUE_OAUTH_SERVER_ALLOW_DYNAMIC_REGISTRATION}"
exec auth
