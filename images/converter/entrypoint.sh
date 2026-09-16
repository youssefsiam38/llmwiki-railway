#!/bin/sh
# llmwiki-railway converter entrypoint: validate, then start LLM Wiki's converter. Values are never printed.
set -u
log()  { printf '[llmwiki-converter] %s\n' "$*"; }
fail() { printf '[llmwiki-converter] FATAL: %s\n' "$*" >&2; exit 1; }

[ -n "${CONVERTER_SECRET:-}" ] || fail "missing required variable: CONVERTER_SECRET"
[ "${#CONVERTER_SECRET}" -ge 32 ] || fail "CONVERTER_SECRET must be at least 32 characters"
[ -n "${S3_BUCKET:-}" ] || fail "missing required variable: S3_BUCKET"
# Without the endpoint the converter falls back to upstream's rule (Amazon S3 only) and every document from
# the bundled storage is refused.
case "${LLMWIKI_S3_ENDPOINT:-}" in
  http://?*|https://?*) ;;
  '') fail "missing required variable: LLMWIKI_S3_ENDPOINT (the storage URL the API signs document links with)" ;;
  *) fail "LLMWIKI_S3_ENDPOINT must be an http(s) URL" ;;
esac
case "$LLMWIKI_S3_ENDPOINT" in
  *://|*://:*|*://.*) fail "LLMWIKI_S3_ENDPOINT has no host name. On Railway this is a reference to the storage service's domain that had not resolved when this deployment started; redeploy once it has." ;;
esac
: "${PORT:=8000}"
case "$PORT" in ''|*[!0-9]*) fail "PORT must be a number, got \"$PORT\"" ;; esac
: "${MAX_CONCURRENT_EXTRACTIONS:=2}"
export MAX_CONCURRENT_EXTRACTIONS

log "listening on port ${PORT} (IPv6 and IPv4), ${MAX_CONCURRENT_EXTRACTIONS} concurrent extractions"
cd /app && exec python /opt/llmwiki-railway/serve.py main:app
