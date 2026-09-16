#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted literals are matched, not expanded
# End-to-end test of the whole bundle on a fresh local stack, through the requests the web app, the
# document uploader and an MCP client (Claude) send.
#   tests/smoke.sh               (LLMWIKI_TEST_KEEP=1 leaves the stack running)
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
umask 077
JWT_SECRET_LOCAL=local-test-only-jwt-secret-000000000000000000000000000000
OWNER_EMAIL=owner@example.com
printf '%s' local-test-only-owner-password > "$TEST_TMP/owner-pw"
stamp=$(date +%s)

cleanup() {
  [ "${LLMWIKI_TEST_KEEP:-0}" = 1 ] || compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

section "start a fresh stack"
compose down -v --remove-orphans >/dev/null 2>&1 || true
compose up -d --no-build >/dev/null 2>&1 || die "compose up failed"
wait_for_log api "starting LLM Wiki API" 1 || { compose logs --no-color --tail 60 api >&2; die "the API did not start"; }
wait_for_code "$API_URL/health" 200 300 || die "API health"
wait_for_code "$APP_URL/login" 200 300 || die "web app"
wait_for_code "${MCP_URL%/mcp}/health" 200 300 || die "MCP server"
wait_for_code "$GATEWAY_URL/auth/v1/.well-known/jwks.json" 200 120 || die "gateway"
mint_keys "$JWT_SECRET_LOCAL"
pass "all public services answer"

section "start-up steps"
api_logs=$(compose logs --no-color --no-log-prefix api 2>&1)
n_files=$(compose exec -T api sh -c 'ls /opt/llmwiki-railway/migrations/*.sql | wc -l' | tr -d ' \r')
assert_eq "every upstream migration is recorded once" "$n_files" "$(psql_admin 'select count(*) from llmwiki_railway.migrations' | tr -d ' \r')"
assert_contains "the owner is created before the API listens" "owner account created for o\*\*\*@example.com" "$api_logs"
assert_contains "signup policy written from the variables" "signup: closed, 2 allowlist entries" "$api_logs"
assert_contains "the bucket is prepared" "bucket llmwiki-documents ready" "$api_logs"
all_logs=$(compose logs --no-color 2>&1)
# Supabase Auth's own audit log records addresses, as it does everywhere; this template's services must not.
assert_not_contains "no wrapper logs the owner's e-mail" "$OWNER_EMAIL" "$(compose logs --no-color api web mcp kong storage converter 2>&1)"
assert_not_contains "no service logs the owner's password" "local-test-only-owner-password" "$all_logs"
assert_not_contains "no service logs the JWT secret" "$JWT_SECRET_LOCAL" "$all_logs"
assert_eq "the owner gets the instance's per-user limits" "100000|10737418240" \
  "$(psql_admin "select page_limit || '|' || storage_limit_bytes from public.users where email = '$OWNER_EMAIL'" | tr -d '\r')"

section "the web app carries this deployment's values"
login=$(curl -s --max-time 30 "$APP_URL/login" || true)
placeholder=0; found_gateway=0; found_api=0; found_mcp=0; anon=""
# The sign-in page loads the Supabase client; the dashboard and settings pages load the API and MCP settings.
chunks=$(for page in /login /wikis /settings; do curl -s --max-time 30 "$APP_URL$page" | grep -oE '/_next/static/[^"]+\.js' || true; done | sort -u | head -200)
for js in $chunks; do
  chunk=$(curl -s --max-time 20 "$APP_URL$js" || true)
  grep -q 'llmwiki-railway-placeholder-' <<<"$chunk" && placeholder=1
  grep -q "$GATEWAY_URL" <<<"$chunk" && found_gateway=1
  grep -q "$API_URL" <<<"$chunk" && found_api=1
  grep -q "$MCP_URL" <<<"$chunk" && found_mcp=1
  [ -n "$anon" ] || anon=$(grep -oE 'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' <<<"$chunk" | head -1 || true)
  grep -q "$(service_key)" <<<"$chunk" && fail "the service-role key is in $js"
done
[ "$placeholder" = 0 ] && pass "no build placeholder left" || fail "a build placeholder survived"
[ "$found_gateway" = 1 ] && pass "the browser is pointed at this Supabase gateway" || fail "no chunk carries the gateway URL"
[ "$found_api" = 1 ] && pass "and at this API" || fail "no chunk carries the API URL"
[ "$found_mcp" = 1 ] && pass "and shows this MCP server's URL" || fail "no chunk carries the MCP URL"
assert_eq "the browser uses the anon key minted from JWT_SECRET" "$(anon_key)" "$anon"
assert_not_contains "the service-role key is not in the page" "$(service_key)" "$login"

section "the Supabase gateway"
assert_eq "no API key, no entry" "401" "$(http_code "$GATEWAY_URL/auth/v1/settings")"
assert_eq "Supabase Auth answers with the anon key" "200" "$(http_code "$GATEWAY_URL/auth/v1/settings" -H "apikey: $(anon_key)")"
jwks=$(curl -s --max-time 30 "$GATEWAY_URL/auth/v1/.well-known/jwks.json")
assert_eq "the JWKS publishes exactly one key, ES256" "1 EC ES256" "$(jq -r '"\(.keys|length) \(.keys[0].kty) \(.keys[0].alg)"' <<<"$jwks")"
assert_eq "and no private or symmetric material" "false" "$(jq '[.keys[] | has("d") or has("k")] | any' <<<"$jwks")"
meta=$(curl -s --max-time 30 "$GATEWAY_URL/.well-known/oauth-authorization-server/auth/v1")
assert_eq "OAuth metadata is served where MCP clients look (RFC 8414)" "$GATEWAY_URL/auth/v1" "$(jq -r .issuer <<<"$meta")"
assert_eq "it offers dynamic client registration" "$GATEWAY_URL/auth/v1/oauth/clients/register" "$(jq -r .registration_endpoint <<<"$meta")"
assert_eq "REST is not routed" "404" "$(http_code "$GATEWAY_URL/rest/v1/" -H "apikey: $(anon_key)")"
assert_contains "the anon key cannot use the admin API" "^40[13]$" "$(http_code "$GATEWAY_URL/auth/v1/admin/users" -H "apikey: $(anon_key)")"

section "who may sign up"
printf '%s' "probe-password-$stamp" > "$TEST_TMP/probe-pw"
assert_eq "a stranger's signup is refused" "500" "$(sign_up "stranger-$stamp@example.com" "$TEST_TMP/probe-pw")"
assert_eq "so is one with a forged bootstrap nonce" "500" \
  "$(sign_up "forger-$stamp@example.com" "$TEST_TMP/probe-pw" "{\"llmwiki_railway_bootstrap_nonce\":\"$(printf '0%.0s' $(seq 1 64))\"}")"
assert_eq "an allowlisted address may sign up" "200" "$(sign_up friend@example.com "$TEST_TMP/probe-pw")"
assert_eq "so may an address in an allowlisted domain" "200" "$(sign_up "colleague-$stamp@team.example.com" "$TEST_TMP/probe-pw")"
assert_eq "but not a look-alike domain" "500" "$(sign_up "someone-$stamp@team.example.com.evil.test" "$TEST_TMP/probe-pw")"
assert_eq "new accounts get the instance's limits too" "100000" \
  "$(psql_admin "select page_limit from public.users where email = 'friend@example.com'" | tr -d '\r ')"

section "the owner and the API"
sign_in "$OWNER_EMAIL" "$TEST_TMP/owner-pw" "$TEST_TMP/owner-token" && pass "owner signs in" || fail "owner sign-in failed"
assert_eq "sessions are signed with the published ES256 key" "ES256 $(jq -r '.keys[0].kid' <<<"$jwks")" \
  "$(jwt_part "$TEST_TMP/owner-token" 0 | jq -r '"\(.alg) \(.kid)"')"
assert_eq "with the issuer the API expects" "$GATEWAY_URL/auth/v1" "$(jwt_part "$TEST_TMP/owner-token" 1 | jq -r .iss)"
assert_eq "the API knows the owner" "$OWNER_EMAIL" "$(api_as "$TEST_TMP/owner-token" GET /v1/me | jq -r .email)"
assert_eq "no token, no API" "401" "$(http_code "$API_URL/v1/knowledge-bases")"
owner_id=$(jwt_part "$TEST_TMP/owner-token" 1 | jq -r .sub)
JWT_SECRET="$JWT_SECRET_LOCAL" SUB="$owner_id" ISS="$GATEWAY_URL/auth/v1" node -e '
  const c = require("crypto"); const b = (s) => Buffer.from(s).toString("base64url"); const now = Math.floor(Date.now()/1000);
  const u = b(JSON.stringify({alg:"HS256",typ:"JWT",kid:"legacy-hs256"})) + "." + b(JSON.stringify({sub:process.env.SUB,aud:"authenticated",role:"authenticated",iss:process.env.ISS,iat:now,exp:now+600}));
  process.stdout.write(u + "." + c.createHmac("sha256", process.env.JWT_SECRET).update(u).digest("base64url"));' > "$TEST_TMP/forged-token"
assert_eq "a token signed with the shared HS256 secret is refused" "401" "$(api_code_as "$TEST_TMP/forged-token" GET /v1/me)"
kb=$(api_as "$TEST_TMP/owner-token" POST /v1/knowledge-bases -H 'Content-Type: application/json' --data "{\"name\":\"Railway Probe $stamp\",\"description\":\"end-to-end\"}")
KB_ID=$(jq -r '.id // empty' <<<"$kb"); KB_SLUG=$(jq -r '.slug // empty' <<<"$kb")
[ -n "$KB_ID" ] && pass "the owner creates a wiki" || fail "could not create a wiki: $(head -c 200 <<<"$kb")"
note=$(api_as "$TEST_TMP/owner-token" POST "/v1/knowledge-bases/$KB_ID/documents/note" -H 'Content-Type: application/json' \
  --data "{\"filename\":\"field-notes.md\",\"path\":\"/\",\"content\":\"# Field notes\\n\\nThe railway-probe-note-$stamp marker lives here.\\n\"}")
assert_eq "and writes a note in it" "field-notes.md" "$(jq -r '.filename // empty' <<<"$note")"
assert_contains "the note is listed" "field-notes.md" "$(api_as "$TEST_TMP/owner-token" GET "/v1/knowledge-bases/$KB_ID/documents")"
cors=$(curl -s -D - -o /dev/null --max-time 30 -X OPTIONS "$API_URL/v1/knowledge-bases" -H "Origin: $APP_URL" -H 'Access-Control-Request-Method: GET' -H 'Access-Control-Request-Headers: authorization' | tr -d '\r')
assert_contains "the API admits the web app's origin" "access-control-allow-origin: $APP_URL" "$cors"
cors=$(curl -s -D - -o /dev/null --max-time 30 -X OPTIONS "$API_URL/v1/knowledge-bases" -H "Origin: https://evil.example" -H 'Access-Control-Request-Method: GET' | tr -d '\r')
assert_not_contains "and no other origin" "access-control-allow-origin" "$cors"

section "a PDF upload goes through the converter and storage"
python3 "$REPO_ROOT/tests/make-pdf.py" "$TEST_TMP/probe.pdf" "Railway probe page one pdfmarker$stamp" "Second page about wiki compounding"
DOC_ID=$(tus_upload "$TEST_TMP/owner-token" "$KB_ID" "$TEST_TMP/probe.pdf" "probe-$stamp.pdf" || true)
[ -n "$DOC_ID" ] && pass "the upload completes (tus)" || fail "the upload did not complete"
assert_eq "the converter extracts it" "ready" "$(wait_document "$TEST_TMP/owner-token" "$DOC_ID" 300)"
assert_contains "the converter logged the extraction" "extract done: ext=pdf pages=2" "$(compose logs --no-color --no-log-prefix converter 2>&1)"
signed=$(api_as "$TEST_TMP/owner-token" GET "/v1/documents/$DOC_ID/url" | jq -r '.url // empty')
assert_contains "the viewer gets a signed link on the storage domain" "^$FILES_URL/llmwiki-documents/" "$signed"
assert_eq "the browser can load it" "%PDF" "$(curl -s --max-time 30 "$signed" | head -c 4)"
assert_eq "not without the signature" "403" "$(http_code "${signed%%\?*}")"
assert_eq "nor can anyone list the bucket" "403" "$(http_code "$FILES_URL/llmwiki-documents/")"
cors=$(curl -s -D - -o /dev/null --max-time 30 "$signed" -H "Origin: $APP_URL" | tr -d '\r' | tr '[:upper:]' '[:lower:]')
assert_contains "storage lets the web app's pages read it (PDF viewer)" "access-control-allow-origin: $(tr '[:upper:]' '[:lower:]' <<<"$APP_URL")" "$cors"
conv=$(compose exec -T api python -c '
import os, httpx
u = "http://converter:8000/extract"
h = {"Authorization": "Bearer " + os.environ["CONVERTER_SECRET"]}
a = httpx.post(u, json={"source_url": "http://169.254.169.254/latest/meta-data/x.pdf", "source_ext": "pdf"}, headers=h).status_code
b = httpx.post(u, json={"source_url": os.environ["AWS_ENDPOINT_URL_S3"] + "/another-bucket/x.pdf", "source_ext": "pdf"}, headers=h).status_code
c = httpx.post(u, json={"source_url": os.environ["AWS_ENDPOINT_URL_S3"] + "/" + os.environ["S3_BUCKET"] + "/x.pdf", "source_ext": "pdf"}, headers={"Authorization": "Bearer wrong"}).status_code
print(a, b, c)' 2>/dev/null | tr -d '\r')
assert_eq "the converter fetches nothing but this bucket, and only for the API" "400 400 401" "$conv"

section "accounts are isolated"
sign_in friend@example.com "$TEST_TMP/probe-pw" "$TEST_TMP/friend-token" && pass "the allowlisted friend signs in" || fail "friend sign-in failed"
assert_eq "they see none of the owner's wikis" "0" "$(api_as "$TEST_TMP/friend-token" GET /v1/knowledge-bases | jq 'length')"
assert_eq "nor the owner's wiki by id" "404" "$(api_code_as "$TEST_TMP/friend-token" GET "/v1/knowledge-bases/$KB_ID")"
assert_eq "nor a signed link to the owner's document" "404" "$(api_code_as "$TEST_TMP/friend-token" GET "/v1/documents/$DOC_ID/url")"

section "an MCP client connects with OAuth, as Claude does"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$MCP_URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' || true)
assert_eq "the MCP server refuses an anonymous client" "401" "$code"
prm=$(curl -s --max-time 30 "${MCP_URL%/mcp}/.well-known/oauth-protected-resource/mcp")
assert_eq "and points it at Supabase Auth" "$GATEWAY_URL/auth/v1" "$(jq -r '.authorization_servers[0]' <<<"$prm")"
rc=0; oauth_connect "$TEST_TMP/owner-token" "Railway probe client" "$TEST_TMP/mcp-token" || rc=$?
assert_eq "register, authorize, consent, exchange the code (PKCE)" "0" "$rc"
[ -s "$TEST_TMP/oauth-consent-page" ] && assert_eq "the consent step is the web app's page" "200" "$(http_code "$(cat "$TEST_TMP/oauth-consent-page")")"
if [ -s "$TEST_TMP/mcp-token" ]; then
  assert_eq "the client's token is an ES256 user token bound to the client" "ES256 $(cat "$TEST_TMP/mcp-token.client")" \
    "$(jwt_part "$TEST_TMP/mcp-token" 0 | jq -r .alg) $(jwt_part "$TEST_TMP/mcp-token" 1 | jq -r .client_id)"
  assert_eq "initialize" "LLM Wiki" "$(mcp_rpc "$TEST_TMP/mcp-token" initialize '{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}' | jq -r '.result.serverInfo.name // empty')"
  tools=$(mcp_rpc "$TEST_TMP/mcp-token" tools/list '{}' | jq -r '[.result.tools[].name] | sort | join(",")')
  for t in guide list_knowledge_bases search read create edit; do assert_contains "tool offered: $t" "\(^\|,\)$t\(,\|$\)" "$tools"; done
  assert_contains "the client sees the owner's wiki" "$KB_SLUG" "$(mcp_tool "$TEST_TMP/mcp-token" list_knowledge_bases '{}')"
  assert_contains "and reads the uploaded PDF's extracted text" "pdfmarker$stamp" \
    "$(mcp_tool "$TEST_TMP/mcp-token" read "$(jq -nc --arg k "$KB_SLUG" --arg p "/probe-$stamp.pdf" '{knowledge_base:$k, path:$p, pages:"1"}')")"
  mcp_tool "$TEST_TMP/mcp-token" create "$(jq -nc --arg k "$KB_SLUG" --arg s "$stamp" '{knowledge_base:$k, title:"Railway probe", path:"/wiki/", tags:["probe"],
    content:("# Railway probe\n\nCompiled by the MCP client. wikimarker" + $s + "[^1]\n\n[^1]: field-notes.md\n")}')" > /dev/null
  assert_contains "writes a wiki page that the web app lists" "railway-probe.md" "$(api_as "$TEST_TMP/owner-token" GET "/v1/knowledge-bases/$KB_ID/documents")"
  assert_contains "and finds it by full-text search (pgroonga)" "wikimarker$stamp" \
    "$(mcp_tool "$TEST_TMP/mcp-token" search "$(jq -nc --arg k "$KB_SLUG" --arg q "wikimarker$stamp" '{knowledge_base:$k, mode:"search", query:$q}')")"
  refreshed=$(curl -s --max-time 30 -X POST "$GATEWAY_URL/auth/v1/oauth/token" -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=refresh_token --data-urlencode "refresh_token@$TEST_TMP/mcp-token.refresh" --data-urlencode "client_id@$TEST_TMP/mcp-token.client")
  [ -n "$(jq -r '.access_token // empty' <<<"$refreshed")" ] && pass "the client refreshes its token" || fail "refresh_token grant failed"
  (umask 077; jq -jr '.refresh_token // empty' <<<"$refreshed" > "$TEST_TMP/mcp-token.refresh")
  grants=$(curl -s --max-time 30 "$GATEWAY_URL/auth/v1/user/oauth/grants" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$TEST_TMP/owner-token")")
  assert_contains "the owner can list the client's grant" "Railway probe client" "$grants"
  code=$(http_code -X DELETE "$GATEWAY_URL/auth/v1/user/oauth/grants?client_id=$(cat "$TEST_TMP/mcp-token.client")" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$TEST_TMP/owner-token")")
  assert_contains "and revoke it" "^20[04]$" "$code"
  code=$(http_code -X POST "$GATEWAY_URL/auth/v1/oauth/token" -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=refresh_token --data-urlencode "refresh_token@$TEST_TMP/mcp-token.refresh" --data-urlencode "client_id@$TEST_TMP/mcp-token.client")
  assert_contains "after which the client cannot refresh" "^4" "$code"
  printf 'not-a-token' > "$TEST_TMP/bad-token"
  assert_eq "a garbage token is refused" "401" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$MCP_URL" -H "Authorization: Bearer not-a-token" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' || true)"
  assert_eq "so is the forged HS256 token" "401" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$MCP_URL" -H "Authorization: Bearer $(cat "$TEST_TMP/forged-token")" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' --data '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' || true)"
fi
rc=0; oauth_connect "$TEST_TMP/friend-token" "Friend's client" "$TEST_TMP/friend-mcp" || rc=$?
[ "$rc" = 0 ] && assert_not_contains "another account's client sees none of the owner's wikis" "$KB_SLUG" "$(mcp_tool "$TEST_TMP/friend-mcp" list_knowledge_bases '{}')" \
  || fail "the friend's MCP client could not connect ($rc)"

summary
