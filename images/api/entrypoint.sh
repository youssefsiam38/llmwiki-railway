#!/bin/sh
# llmwiki-railway api entrypoint: validate, run the start-up steps (railway_setup.py), start LLM Wiki's API.
# Values are never printed.
set -u
log()  { printf '[llmwiki-api] %s\n' "$*"; }
fail() { printf '[llmwiki-api] FATAL: %s\n' "$*" >&2; exit 1; }

# A Railway reference such as ${{kong.RAILWAY_PRIVATE_DOMAIN}} is empty until that service has a
# deployment, which leaves `http://:8000`. Say so, rather than retry an address that cannot exist.
for name in DATABASE_URL SUPABASE_URL SUPABASE_INTERNAL_URL APP_URL API_URL AWS_ENDPOINT_URL_S3 LLMWIKI_S3_PUBLIC_ENDPOINT CONVERTER_URL; do
  eval "v=\${$name:-}"
  # shellcheck disable=SC2154  # v is assigned by the eval above
  case "$v" in
    '') fail "missing required variable: $name" ;;
    *://|*://:*|*://.*|*:///*|*@:*|*@/*)
      fail "$name has no host name. On Railway this is a reference to another service's domain that had not resolved when this deployment started; redeploy once that service has deployed." ;;
  esac
done

# Hosted mode is the multi-user server; local mode is a single-user desktop app with no authentication.
case "${MODE:-hosted}" in
  hosted) MODE=hosted ;;
  *) fail "MODE must stay hosted: local mode has no sign-in and serves one person's machine" ;;
esac
: "${PORT:=8000}"
case "$PORT" in ''|*[!0-9]*) fail "PORT must be a number, got \"$PORT\"" ;; esac
: "${AWS_REGION:=us-east-1}"
: "${STAGE:=production}"
# LLM Wiki's AWS client takes its endpoint from botocore's own variables; RustFS wants path-style addressing
# and only the checksums S3 requires.
: "${AWS_CONFIG_FILE:=/opt/llmwiki-railway/aws-config}"
: "${AWS_REQUEST_CHECKSUM_CALCULATION:=when_required}"
: "${AWS_RESPONSE_CHECKSUM_VALIDATION:=when_required}"
# Every request reaches the API through Railway's edge, so the client address is in X-Forwarded-For. Without
# this, LLM Wiki's per-address rate limit would put every user of the instance in one bucket.
: "${FORWARDED_ALLOW_IPS:=*}"
: "${QUOTA_MAX_STORAGE_BYTES:=${LLMWIKI_STORAGE_LIMIT_BYTES:-10737418240}}"
export MODE PORT AWS_REGION STAGE AWS_CONFIG_FILE AWS_REQUEST_CHECKSUM_CALCULATION AWS_RESPONSE_CHECKSUM_VALIDATION \
       FORWARDED_ALLOW_IPS QUOTA_MAX_STORAGE_BYTES

python /opt/llmwiki-railway/railway_setup.py || exit 1
unset JWT_SECRET OWNER_PASSWORD

log "starting LLM Wiki API on port ${PORT} (IPv6 and IPv4)"
cd /app && exec python /opt/llmwiki-railway/serve.py main:app --proxy-headers --timeout-graceful-shutdown 30
