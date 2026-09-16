#!/bin/sh
# llmwiki-railway mcp entrypoint: validate, then start LLM Wiki's MCP server. Values are never printed.
set -u
log()  { printf '[llmwiki-mcp] %s\n' "$*"; }
fail() { printf '[llmwiki-mcp] FATAL: %s\n' "$*" >&2; exit 1; }

for name in DATABASE_URL SUPABASE_URL MCP_URL API_URL APP_URL AWS_ENDPOINT_URL_S3; do
  eval "v=\${$name:-}"
  # shellcheck disable=SC2154  # v is assigned by the eval above
  case "$v" in
    '') fail "missing required variable: $name" ;;
    *://|*://:*|*://.*|*:///*|*@:*|*@/*)
      fail "$name has no host name. On Railway this is a reference to another service's domain that had not resolved when this deployment started; redeploy once that service has deployed." ;;
  esac
done
for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY S3_BUCKET; do
  eval "v=\${$name:-}"
  [ -n "$v" ] || fail "missing required variable: $name"
done
# MCP clients are told the resource is exactly MCP_URL and check it; the server's DNS-rebinding guard also
# derives its allowed Host from it.
case "$MCP_URL" in
  https://*/mcp|http://localhost*/mcp|http://127.0.0.1*/mcp|http://*.localhost*/mcp) ;;
  *) fail "MCP_URL must be the public https URL of this service ending in /mcp, e.g. https://mcp-production.up.railway.app/mcp" ;;
esac
case "${MODE:-hosted}" in
  hosted) MODE=hosted ;;
  *) fail "MODE must stay hosted: local mode serves one person's files without sign-in" ;;
esac
: "${PORT:=8080}"
case "$PORT" in ''|*[!0-9]*) fail "PORT must be a number, got \"$PORT\"" ;; esac
: "${STAGE:=production}"
: "${AWS_REGION:=us-east-1}"
: "${AWS_CONFIG_FILE:=/opt/llmwiki-railway/aws-config}"
: "${AWS_REQUEST_CHECKSUM_CALCULATION:=when_required}"
: "${AWS_RESPONSE_CHECKSUM_VALIDATION:=when_required}"
: "${FORWARDED_ALLOW_IPS:=*}"
export MODE PORT STAGE AWS_REGION AWS_CONFIG_FILE AWS_REQUEST_CHECKSUM_CALCULATION AWS_RESPONSE_CHECKSUM_VALIDATION FORWARDED_ALLOW_IPS

log "MCP endpoint ${MCP_URL} on port ${PORT}"
cd /app && exec python -m hosted
