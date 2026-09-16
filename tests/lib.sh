#!/usr/bin/env bash
# shellcheck disable=SC2015  # `cond && pass || fail` is intentional; pass/fail always succeed
# Shared helpers for llmwiki-railway tests. Source this file; do not execute it.
# Secrets are never echoed. Only names, lengths, and pass/fail results are printed.

: "${APP_URL:=http://localhost:${LLMWIKI_TEST_PORT:-13900}}"
: "${GATEWAY_URL:=http://kong.localhost:${LLMWIKI_TEST_GATEWAY_PORT:-18900}}"
: "${API_URL:=http://api.localhost:${LLMWIKI_TEST_API_PORT:-18901}}"
: "${MCP_URL:=http://mcp.localhost:${LLMWIKI_TEST_MCP_PORT:-18902}/mcp}"
: "${FILES_URL:=http://files.localhost:${LLMWIKI_TEST_FILES_PORT:-18903}}"
: "${TEST_TIMEOUT:=900}"

TEST_TMP="${TEST_TMP:-$(mktemp -d)}"
export TEST_TMP
_PASS=0; _FAIL=0

pass() { _PASS=$((_PASS+1)); printf '  PASS  %s\n' "$*"; }
fail() { _FAIL=$((_FAIL+1)); printf '  FAIL  %s\n' "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$*"; }
summary() { printf '\n%d passed, %d failed\n' "$_PASS" "$_FAIL"; [ "$_FAIL" -eq 0 ]; }

# here-strings, not pipes: `grep -q` exits on the first match and a pipe writer would get SIGPIPE,
# which `pipefail` reports as failure when the haystack is larger than the pipe buffer
assert_eq() { if [ "$2" = "$3" ]; then pass "$1 ($3)"; else fail "$1: expected [$2] got [$3]"; fi; }
assert_contains() { if grep -q -- "$2" <<<"$3"; then pass "$1"; else fail "$1: missing [$2]"; fi; }
assert_not_contains() { if grep -q -- "$2" <<<"$3"; then fail "$1: found forbidden [$2]"; else pass "$1"; fi; }

# curl still prints 000 through -w when it cannot connect, so `|| true`, never `|| echo 000`
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@" || true; }

wait_for_code() {
  local url=$1 want=$2 timeout=${3:-$TEST_TIMEOUT} start code
  start=$(date +%s)
  while :; do
    code=$(http_code "$url")
    [ "$code" = "$want" ] && return 0
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then printf 'timed out waiting for %s -> %s (last %s)\n' "$url" "$want" "$code" >&2; return 1; fi
    sleep 5
  done
}

# wait_for_log SERVICE PATTERN [MIN_COUNT] [TIMEOUT]
wait_for_log() {
  local svc=$1 pat=$2 min=${3:-1} timeout=${4:-$TEST_TIMEOUT} start n
  start=$(date +%s)
  while :; do
    n=$(compose logs --no-color --no-log-prefix "$svc" 2>/dev/null | grep -cE -- "$pat" || true)
    [ "$n" -ge "$min" ] && return 0
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then printf 'timed out waiting for [%s] in %s logs\n' "$pat" "$svc" >&2; return 1; fi
    sleep 3
  done
}

compose() { docker compose -f "$REPO_ROOT/compose.yaml" "$@"; }

# mint_keys JWT_SECRET -> writes ANON_KEY / SERVICE_ROLE_KEY lines to $TEST_TMP/keys
mint_keys() { JWT_SECRET="$1" node "$REPO_ROOT/lib/mint-supabase-keys.mjs" > "$TEST_TMP/keys"; }
anon_key() { sed -n 's/^ANON_KEY=//p' "$TEST_TMP/keys"; }
service_key() { sed -n 's/^SERVICE_ROLE_KEY=//p' "$TEST_TMP/keys"; }

# jwt_part FILE|- N -> the decoded JSON of part N (0 header, 1 claims) of the token in FILE
jwt_part() {
  local p
  p=$(if [ "$1" = - ]; then cat; else cat "$1"; fi | cut -d. -f$(( $2 + 1 )) | tr '_-' '/+')
  while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
  base64 -d <<<"$p" 2>/dev/null
}

# sign_in EMAIL PASSWORD_FILE TOKEN_OUT -> 0 on success; the token goes to a file, never stdout
sign_in() {
  local email=$1 pwfile=$2 out=$3 body code
  body=$(curl -s -w '\n%{http_code}' --max-time 30 -X POST "$GATEWAY_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $(anon_key)" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg e "$email" --rawfile p "$pwfile" '{email:$e, password:($p|rtrimstr("\n"))}')" || true)
  code=${body##*$'\n'}; body=${body%$'\n'*}
  [ "$code" = "200" ] || return 1
  (umask 077; jq -er '.access_token' <<<"$body" > "$out" 2>/dev/null) || return 1
  [ -s "$out" ]
}

# sign_up EMAIL PASSWORD_FILE [EXTRA_METADATA_JSON] -> prints the HTTP status; on 200 the token goes to $TEST_TMP/signup-token
sign_up() {
  local email=$1 pwfile=$2 extra=${3:-'{}'} data body code
  data=$(jq -nc --arg e "$email" --rawfile p "$pwfile" --argjson x "$extra" \
    '{email:$e, password:($p|rtrimstr("\n")), data:$x}')
  body=$(curl -s -w '\n%{http_code}' --max-time 30 -X POST "$GATEWAY_URL/auth/v1/signup" \
    -H "apikey: $(anon_key)" -H 'Content-Type: application/json' --data "$data" || true)
  code=${body##*$'\n'}; body=${body%$'\n'*}
  [ "$code" = 200 ] && { (umask 077; jq -r '.access_token // empty' <<<"$body" > "$TEST_TMP/signup-token"); }
  printf '%s' "$code"
}

# api_as TOKEN_FILE METHOD PATH [curl args...] -> body, as the web app calls the API
api_as() {
  local tf=$1 method=$2 path=$3; shift 3
  curl -s --max-time 60 -X "$method" "$API_URL$path" -H "Authorization: Bearer $(cat "$tf")" "$@" || true
}
api_code_as() {
  local tf=$1 method=$2 path=$3; shift 3
  curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X "$method" "$API_URL$path" -H "Authorization: Bearer $(cat "$tf")" "$@" || true
}

# tus_upload TOKEN_FILE KB_ID FILE FILENAME -> the new document's id, uploaded the way the web app's
# uploader does it (tus: create, then one PATCH with the whole body)
tus_upload() {
  local tf=$1 kb=$2 file=$3 name=$4 size meta headers location doc
  size=$(stat -c %s "$file")
  meta="filename $(printf '%s' "$name" | base64 -w0),knowledge_base_id $(printf '%s' "$kb" | base64 -w0),path $(printf '/' | base64 -w0)"
  headers=$(curl -s -D - -o /dev/null --max-time 60 -X POST "$API_URL/v1/uploads" -H "Authorization: Bearer $(cat "$tf")" \
    -H 'Tus-Resumable: 1.0.0' -H "Upload-Length: $size" -H "Upload-Metadata: $meta" || true)
  location=$(tr -d '\r' <<<"$headers" | sed -n 's/^[Ll]ocation: //p' | head -1)
  [ -n "$location" ] || return 1
  case "$location" in http*) ;; *) location="$API_URL$location" ;; esac
  headers=$(curl -s -D - -o /dev/null --max-time 120 -X PATCH "$location" -H "Authorization: Bearer $(cat "$tf")" \
    -H 'Tus-Resumable: 1.0.0' -H 'Upload-Offset: 0' -H 'Content-Type: application/offset+octet-stream' --data-binary "@$file" || true)
  doc=$(tr -d '\r' <<<"$headers" | sed -n 's/^[Xx]-[Dd]ocument-[Ii]d: //p' | head -1)
  [ -n "$doc" ] && printf '%s' "$doc"
}

# wait_document TOKEN_FILE DOC_ID [TIMEOUT] -> prints the final status (ready / failed / timeout)
wait_document() {
  local tf=$1 doc=$2 timeout=${3:-300} start status
  start=$(date +%s)
  while :; do
    status=$(api_as "$tf" GET "/v1/documents/$doc" | jq -r '.status // empty' 2>/dev/null || true)
    case "$status" in ready|failed) printf '%s' "$status"; return 0 ;; esac
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then printf 'timeout(%s)' "$status"; return 0; fi
    sleep 3
  done
}

# oauth_connect TOKEN_FILE CLIENT_NAME OUT -> 0 when an MCP client registered itself, the signed-in user
# approved it on the consent API, and the client exchanged the code (PKCE) for tokens, as Claude does.
# The access token goes to OUT, the refresh token to OUT.refresh.
oauth_connect() {
  local tf=$1 name=$2 out=$3 redirect="http://127.0.0.1:33418/callback" issuer meta reg client verifier challenge loc aid consent code tokens details
  issuer=$(curl -s --max-time 30 "$MCP_URL" -o /dev/null -D - -X POST -H 'Content-Type: application/json' --data '{}' \
    | tr -d '\r' | sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate: .*resource_metadata="\([^"]*\)".*/\1/p' | head -1)
  [ -n "$issuer" ] || return 11
  issuer=$(curl -s --max-time 30 "$issuer" | jq -r '.authorization_servers[0] // empty')
  [ -n "$issuer" ] || return 12
  meta=$(curl -s --max-time 30 "$(sed -E 's#^(https?://[^/]+)(/.*)$#\1/.well-known/oauth-authorization-server\2#' <<<"$issuer")")
  [ "$(jq -r .issuer <<<"$meta")" = "$issuer" ] || return 13
  reg=$(curl -s --max-time 30 -X POST "$(jq -r .registration_endpoint <<<"$meta")" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg n "$name" --arg r "$redirect" '{client_name:$n, redirect_uris:[$r], token_endpoint_auth_method:"none", grant_types:["authorization_code","refresh_token"], response_types:["code"]}')")
  client=$(jq -r '.client_id // empty' <<<"$reg"); [ -n "$client" ] || return 14
  verifier=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n')
  challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=\n')
  loc=$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 30 -G "$(jq -r .authorization_endpoint <<<"$meta")" \
    --data-urlencode response_type=code --data-urlencode "client_id=$client" --data-urlencode "redirect_uri=$redirect" \
    --data-urlencode "code_challenge=$challenge" --data-urlencode code_challenge_method=S256 --data-urlencode state=probe \
    --data-urlencode "resource=$MCP_URL")
  case "$loc" in "$APP_URL/oauth/authorize?authorization_id="*) ;; *) return 15 ;; esac
  aid=${loc##*authorization_id=}; aid=${aid%%&*}
  printf '%s' "$loc" > "$TEST_TMP/oauth-consent-page"
  # The consent page first loads the request's details (which binds it to the signed-in user), shows the
  # client's name, and only then approves.
  details=$(curl -s --max-time 30 "$GATEWAY_URL/auth/v1/oauth/authorizations/$aid" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$tf")")
  [ "$(jq -r '.client.client_name // .client.name // empty' <<<"$details")" = "$name" ] || return 18
  consent=$(curl -s --max-time 30 -X POST "$GATEWAY_URL/auth/v1/oauth/authorizations/$aid/consent" -H "apikey: $(anon_key)" \
    -H "Authorization: Bearer $(cat "$tf")" -H 'Content-Type: application/json' --data '{"action":"approve"}')
  code=$(jq -r '.redirect_url // empty' <<<"$consent" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
  [ -n "$code" ] || return 16
  tokens=$(curl -s --max-time 30 -X POST "$(jq -r .token_endpoint <<<"$meta")" -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=authorization_code --data-urlencode "code=$code" --data-urlencode "code_verifier=$verifier" \
    --data-urlencode "client_id=$client" --data-urlencode "redirect_uri=$redirect")
  (umask 077; jq -jer '.access_token' <<<"$tokens" > "$out" 2>/dev/null && jq -jer '.refresh_token' <<<"$tokens" > "$out.refresh" 2>/dev/null) || return 17
  printf '%s' "$client" > "$out.client"
}

# mcp_rpc TOKEN_FILE METHOD PARAMS_JSON -> the JSON-RPC response (streamable HTTP; SSE or JSON body)
mcp_rpc() {
  local tf=$1 method=$2 params=${3:-'{}'} body
  body=$(curl -s --max-time 120 -X POST "$MCP_URL" -H "Authorization: Bearer $(cat "$tf")" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H 'MCP-Protocol-Version: 2025-06-18' \
    --data "$(jq -nc --arg m "$method" --argjson p "$params" '{jsonrpc:"2.0", id:1, method:$m, params:$p}')" || true)
  if grep -q '^data: ' <<<"$body"; then sed -n 's/^data: //p' <<<"$body" | tail -1; else printf '%s' "$body"; fi
}

# mcp_tool TOKEN_FILE NAME ARGS_JSON -> the text of the tool result
mcp_tool() {
  mcp_rpc "$1" tools/call "$(jq -nc --arg n "$2" --argjson a "$3" '{name:$n, arguments:$a}')" \
    | jq -r '[.result.content[]? | select(.type == "text") | .text] | join("\n")' 2>/dev/null || true
}

# psql_admin SQL -> tuples only, unaligned
psql_admin() { compose exec -T db psql -U supabase_admin -d postgres -tAc "$1"; }
