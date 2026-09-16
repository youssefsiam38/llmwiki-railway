#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted literals are matched, not expanded
# End-to-end test against a deployed bundle, from the outside, through the requests the web app, the uploader
# and an MCP client (Claude) send. What it creates as the owner (a wiki, a note, a PDF, an OAuth client) is
# deleted again at the end.
#   tests/railway-smoke.sh https://web https://api https://mcp https://kong https://storage
# Optional:
#   OWNER_EMAIL=... OWNER_PASSWORD_FILE=/path   sign in as the owner (the file holds the password): wikis,
#                                               uploads through the converter, signed links, an OAuth + MCP session
#   ALLOWED_EMAIL=...                           an address in LLMWIKI_ALLOWED_SIGNUPS: signs up and checks isolation
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
usage="usage: railway-smoke.sh https://web https://api https://mcp https://kong https://storage"
APP_URL=${1:?$usage}; APP_URL=${APP_URL%/}
API_URL=${2:?$usage}; API_URL=${API_URL%/}
MCP_URL=${3:?$usage}; MCP_URL=${MCP_URL%/}; MCP_URL=${MCP_URL%/mcp}/mcp
GATEWAY_URL=${4:?$usage}; GATEWAY_URL=${GATEWAY_URL%/}
FILES_URL=${5:?$usage}; FILES_URL=${FILES_URL%/}
export APP_URL API_URL MCP_URL GATEWAY_URL FILES_URL
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
umask 077
stamp=$(date +%s)
KB_ID=""
cleanup() {
  if [ -n "$KB_ID" ] && [ -s "$TEST_TMP/owner-token" ]; then
    api_code_as "$TEST_TMP/owner-token" DELETE "/v1/knowledge-bases/$KB_ID" >/dev/null || true
  fi
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

section "TLS and routing"
# Railway's edge serves 404 for a few seconds while a deployment takes over.
wait_for_code "$APP_URL/login" 200 600 || true
assert_eq "the web app serves its sign-in page over https" "200" "$(http_code "$APP_URL/login")"
assert_eq "the API answers its health check" "200" "$(http_code "$API_URL/health")"
assert_eq "the MCP server answers its health check" "200" "$(http_code "${MCP_URL%/mcp}/health")"
for u in "$APP_URL/login" "$API_URL/health" "${MCP_URL%/mcp}/health" "$GATEWAY_URL/auth/v1/.well-known/jwks.json" "$FILES_URL/"; do
  assert_contains "valid certificate: ${u#https://}" "SSL certificate verify ok" "$(curl -sv -o /dev/null --max-time 30 "$u" 2>&1 || true)"
done
host=${APP_URL#https://}
assert_contains "http -> https" "https://$host" "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 "http://$host/login")"

section "the web app carries this deployment's values"
placeholder=0; found_gateway=0; found_api=0; found_mcp=0; anon=""
chunks=$(for page in /login /wikis /settings; do curl -s --max-time 30 "$APP_URL$page" | grep -oE '/_next/static/[^"]+\.js' || true; done | sort -u | head -200)
for js in $chunks; do
  chunk=$(curl -s --max-time 20 "$APP_URL$js" || true)
  grep -q 'llmwiki-railway-placeholder-' <<<"$chunk" && placeholder=1
  grep -q "$GATEWAY_URL" <<<"$chunk" && found_gateway=1
  grep -q "$API_URL" <<<"$chunk" && found_api=1
  grep -q "$MCP_URL" <<<"$chunk" && found_mcp=1
  [ -n "$anon" ] || anon=$(grep -oE 'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' <<<"$chunk" | head -1 || true)
done
[ "$placeholder" = 0 ] && pass "no build placeholder left" || fail "a build placeholder survived"
[ "$found_gateway" = 1 ] && pass "the browser is pointed at this Supabase gateway" || fail "no chunk carries the gateway URL"
[ "$found_api" = 1 ] && pass "and at this API" || fail "no chunk carries the API URL"
[ "$found_mcp" = 1 ] && pass "and shows this MCP server's URL" || fail "no chunk carries the MCP URL"
[ -n "$anon" ] && pass "found the public anon key" || fail "no anon key in the bundle"
assert_eq "it is the anon role" "anon" "$(jwt_part - 1 <<<"$anon" | jq -r .role)"
printf 'ANON_KEY=%s\n' "$anon" > "$TEST_TMP/keys"

section "the Supabase gateway"
assert_eq "no API key, no entry" "401" "$(http_code "$GATEWAY_URL/auth/v1/settings")"
assert_eq "Supabase Auth answers with the anon key" "200" "$(http_code "$GATEWAY_URL/auth/v1/settings" -H "apikey: $anon")"
jwks=$(curl -s --max-time 30 "$GATEWAY_URL/auth/v1/.well-known/jwks.json")
assert_eq "the JWKS publishes exactly one key, ES256" "1 EC ES256" "$(jq -r '"\(.keys|length) \(.keys[0].kty) \(.keys[0].alg)"' <<<"$jwks")"
assert_eq "and no private or symmetric material" "false" "$(jq '[.keys[] | has("d") or has("k")] | any' <<<"$jwks")"
meta=$(curl -s --max-time 30 "$GATEWAY_URL/.well-known/oauth-authorization-server/auth/v1")
assert_eq "OAuth metadata where MCP clients look, with this issuer" "$GATEWAY_URL/auth/v1" "$(jq -r .issuer <<<"$meta")"
assert_eq "REST is not routed" "404" "$(http_code "$GATEWAY_URL/rest/v1/" -H "apikey: $anon")"
assert_contains "the anon key cannot use the admin API" "^40[13]$" "$(http_code "$GATEWAY_URL/auth/v1/admin/users" -H "apikey: $anon")"
head -c 18 /dev/urandom | base64 | tr -d '/+=\n' > "$TEST_TMP/probe-pw"
assert_eq "a stranger's signup is refused" "500" "$(sign_up "probe-$stamp@example.com" "$TEST_TMP/probe-pw")"
assert_eq "so is one with a forged bootstrap nonce" "500" \
  "$(sign_up "forger-$stamp@example.com" "$TEST_TMP/probe-pw" "{\"llmwiki_railway_bootstrap_nonce\":\"$(printf '0%.0s' $(seq 1 64))\"}")"

section "the API, the MCP server and storage refuse strangers"
assert_eq "no token, no API" "401" "$(http_code "$API_URL/v1/knowledge-bases")"
assert_eq "the MCP server refuses an anonymous client" "401" "$(http_code -X POST "$MCP_URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')"
assert_eq "and points it at Supabase Auth" "$GATEWAY_URL/auth/v1" "$(curl -s --max-time 30 "${MCP_URL%/mcp}/.well-known/oauth-protected-resource/mcp" | jq -r '.authorization_servers[0]')"
assert_eq "nobody lists the bucket" "403" "$(http_code "$FILES_URL/llmwiki-documents/")"
cors=$(curl -s -D - -o /dev/null --max-time 30 -X OPTIONS "$API_URL/v1/knowledge-bases" -H "Origin: https://evil.example" -H 'Access-Control-Request-Method: GET' | tr -d '\r')
assert_not_contains "the API admits no foreign origin" "access-control-allow-origin" "$cors"

if [ -n "${OWNER_EMAIL:-}" ] && [ -n "${OWNER_PASSWORD_FILE:-}" ]; then
  section "the owner and the API"
  sign_in "$OWNER_EMAIL" "$OWNER_PASSWORD_FILE" "$TEST_TMP/owner-token" && pass "owner signs in" || fail "owner sign-in failed"
fi
if [ -s "$TEST_TMP/owner-token" ]; then
  assert_eq "sessions are signed with the published ES256 key" "ES256 $(jq -r '.keys[0].kid' <<<"$jwks")" \
    "$(jwt_part "$TEST_TMP/owner-token" 0 | jq -r '"\(.alg) \(.kid)"')"
  assert_eq "the API knows the owner" "$(tr '[:upper:]' '[:lower:]' <<<"$OWNER_EMAIL")" "$(api_as "$TEST_TMP/owner-token" GET /v1/me | jq -r .email)"
  kb=$(api_as "$TEST_TMP/owner-token" POST /v1/knowledge-bases -H 'Content-Type: application/json' --data "{\"name\":\"Railway Probe $stamp\",\"description\":\"end-to-end probe, deleted by the test\"}")
  KB_ID=$(jq -r '.id // empty' <<<"$kb"); KB_SLUG=$(jq -r '.slug // empty' <<<"$kb")
  [ -n "$KB_ID" ] && pass "the owner creates a wiki" || fail "could not create a wiki"
  note=$(api_as "$TEST_TMP/owner-token" POST "/v1/knowledge-bases/$KB_ID/documents/note" -H 'Content-Type: application/json' \
    --data "{\"filename\":\"field-notes.md\",\"path\":\"/\",\"content\":\"# Field notes\\n\\nrailway-probe-note-$stamp\\n\"}")
  assert_eq "and writes a note in it" "field-notes.md" "$(jq -r '.filename // empty' <<<"$note")"
  cors=$(curl -s -D - -o /dev/null --max-time 30 -X OPTIONS "$API_URL/v1/knowledge-bases" -H "Origin: $APP_URL" -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: authorization' | tr -d '\r')
  assert_contains "the API admits the web app's origin" "access-control-allow-origin: $APP_URL" "$cors"

  section "a PDF goes through the converter and storage"
  python3 "$REPO_ROOT/tests/make-pdf.py" "$TEST_TMP/probe.pdf" "Railway probe page one pdfmarker$stamp" "Second page"
  DOC_ID=$(tus_upload "$TEST_TMP/owner-token" "$KB_ID" "$TEST_TMP/probe.pdf" "probe-$stamp.pdf" || true)
  [ -n "$DOC_ID" ] && pass "the upload completes (tus)" || fail "the upload did not complete"
  signed=""
  if [ -n "$DOC_ID" ]; then
    assert_eq "the converter extracts it" "ready" "$(wait_document "$TEST_TMP/owner-token" "$DOC_ID" 600)"
    signed=$(api_as "$TEST_TMP/owner-token" GET "/v1/documents/$DOC_ID/url" | jq -r '.url // empty' 2>/dev/null || true)
    assert_contains "the viewer gets a signed link on the storage domain" "^$FILES_URL/llmwiki-documents/" "$signed"
  fi
  if [ -n "$signed" ]; then
    assert_eq "the browser can load it" "%PDF" "$(curl -s --max-time 30 "$signed" | head -c 4 || true)"
    assert_eq "not without the signature" "403" "$(http_code "${signed%%\?*}")"
    cors=$(curl -s -D - -o /dev/null --max-time 30 "$signed" -H "Origin: $APP_URL" | tr -d '\r' | tr '[:upper:]' '[:lower:]' || true)
    assert_contains "storage lets the web app read it (PDF viewer)" "access-control-allow-origin: $(tr '[:upper:]' '[:lower:]' <<<"$APP_URL")" "$cors"
  fi

  section "Claude connects over MCP with OAuth"
  rc=0; oauth_connect "$TEST_TMP/owner-token" "Railway probe client $stamp" "$TEST_TMP/mcp-token" || rc=$?
  assert_eq "register, authorize, consent, exchange the code (PKCE)" "0" "$rc"
  [ -s "$TEST_TMP/oauth-consent-page" ] && assert_eq "the consent step is the web app's page" "200" "$(http_code "$(cat "$TEST_TMP/oauth-consent-page")")"
  if [ -s "$TEST_TMP/mcp-token" ]; then
    assert_eq "initialize" "LLM Wiki" "$(mcp_rpc "$TEST_TMP/mcp-token" initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}' | jq -r '.result.serverInfo.name // empty')"
    assert_contains "the client sees the wiki" "$KB_SLUG" "$(mcp_tool "$TEST_TMP/mcp-token" list_knowledge_bases '{}')"
    assert_contains "and reads the PDF's extracted text" "pdfmarker$stamp" \
      "$(mcp_tool "$TEST_TMP/mcp-token" read "$(jq -nc --arg k "$KB_SLUG" --arg p "/probe-$stamp.pdf" '{knowledge_base:$k, path:$p, pages:"1"}')")"
    mcp_tool "$TEST_TMP/mcp-token" create "$(jq -nc --arg k "$KB_SLUG" --arg s "$stamp" '{knowledge_base:$k, title:"Railway probe", path:"/wiki/", tags:["probe"],
      content:("# Railway probe\n\nCompiled over MCP. wikimarker" + $s + "[^1]\n\n[^1]: field-notes.md\n")}')" > /dev/null
    assert_contains "writes a wiki page the web app lists" "railway-probe.md" "$(api_as "$TEST_TMP/owner-token" GET "/v1/knowledge-bases/$KB_ID/documents")"
    assert_contains "and finds it by full-text search" "wikimarker$stamp" \
      "$(mcp_tool "$TEST_TMP/mcp-token" search "$(jq -nc --arg k "$KB_SLUG" --arg q "wikimarker$stamp" '{knowledge_base:$k, mode:"search", query:$q}')")"
    refreshed=$(curl -s --max-time 30 -X POST "$GATEWAY_URL/auth/v1/oauth/token" -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode grant_type=refresh_token --data-urlencode "refresh_token@$TEST_TMP/mcp-token.refresh" --data-urlencode "client_id@$TEST_TMP/mcp-token.client")
    [ -n "$(jq -r '.access_token // empty' <<<"$refreshed")" ] && pass "the client refreshes its token" || fail "refresh_token grant failed"
    (umask 077; jq -jr '.refresh_token // empty' <<<"$refreshed" > "$TEST_TMP/mcp-token.refresh")
    code=$(http_code -X DELETE "$GATEWAY_URL/auth/v1/user/oauth/grants?client_id=$(cat "$TEST_TMP/mcp-token.client")" -H "apikey: $anon" -H "Authorization: Bearer $(cat "$TEST_TMP/owner-token")")
    assert_contains "the owner revokes the client" "^20[04]$" "$code"
    code=$(http_code -X POST "$GATEWAY_URL/auth/v1/oauth/token" -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode grant_type=refresh_token --data-urlencode "refresh_token@$TEST_TMP/mcp-token.refresh" --data-urlencode "client_id@$TEST_TMP/mcp-token.client")
    assert_contains "after which it cannot refresh" "^4" "$code"
  fi

  if [ -n "${ALLOWED_EMAIL:-}" ]; then
    section "an allowlisted colleague"
    assert_eq "may sign up" "200" "$(sign_up "$ALLOWED_EMAIL" "$TEST_TMP/probe-pw")"
    sign_in "$ALLOWED_EMAIL" "$TEST_TMP/probe-pw" "$TEST_TMP/friend-token" && pass "and sign in" || fail "the allowlisted user could not sign in"
    assert_eq "sees none of the owner's wikis" "404" "$(api_code_as "$TEST_TMP/friend-token" GET "/v1/knowledge-bases/$KB_ID")"
    assert_eq "nor a signed link to the owner's document" "404" "$(api_code_as "$TEST_TMP/friend-token" GET "/v1/documents/$DOC_ID/url")"
    assert_eq "a look-alike domain may not sign up" "500" "$(sign_up "someone-$stamp@${ALLOWED_EMAIL#*@}.evil.test" "$TEST_TMP/probe-pw")"
  fi

  section "clean up"
  assert_eq "the probe wiki is deleted" "204" "$(api_code_as "$TEST_TMP/owner-token" DELETE "/v1/knowledge-bases/$KB_ID")"
  KB_ID=""
fi
summary
