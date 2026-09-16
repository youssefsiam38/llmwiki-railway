#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted literals are matched, not expanded
# Persistence: what exists before every container is destroyed is there after they are recreated (volumes
# kept), nothing the first boot did is repeated over it, and connected MCP clients stay signed in.
#   tests/persistence.sh         (starts its own fresh stack; LLMWIKI_TEST_KEEP=1 leaves it running)
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
umask 077

JWT='local-test-only-jwt-secret-000000000000000000000000000000'
OWNER_EMAIL='owner@example.com'
mint_keys "$JWT"
stamp=$(date +%s)
printf '%s' 'local-test-only-owner-password' > "$TEST_TMP/initial-pw"
printf '%s' "changed-in-the-app-$stamp" > "$TEST_TMP/changed-pw"

cleanup() {
  [ "${LLMWIKI_TEST_KEEP:-0}" = 1 ] || compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

ready() {
  wait_for_code "$API_URL/health" 200 "$TEST_TIMEOUT" && wait_for_code "$APP_URL/login" 200 300 \
    && wait_for_code "${MCP_URL%/mcp}/health" 200 300
}

section "fresh stack"
compose down -v --remove-orphans >/dev/null 2>&1 || true
compose up -d --no-build >/dev/null 2>&1 || die "compose up failed"
ready && pass "serving" || die "the stack never became ready"

section "write state"
sign_in "$OWNER_EMAIL" "$TEST_TMP/initial-pw" "$TEST_TMP/token" && pass "owner signs in with the generated password" || die "owner sign-in failed"
code=$(http_code -X PUT "$GATEWAY_URL/auth/v1/user" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$TEST_TMP/token")" \
  -H 'Content-Type: application/json' --data "$(jq -nc --rawfile p "$TEST_TMP/changed-pw" '{password:$p}')")
assert_eq "owner changes their password, as they would in the app" "200" "$code"
sign_in "$OWNER_EMAIL" "$TEST_TMP/changed-pw" "$TEST_TMP/token" || die "could not sign in with the changed password"
KB_ID=$(api_as "$TEST_TMP/token" POST /v1/knowledge-bases -H 'Content-Type: application/json' --data "{\"name\":\"Kept $stamp\"}" | jq -r '.id // empty')
[ -n "$KB_ID" ] && pass "a wiki exists" || die "could not create a wiki"
python3 "$REPO_ROOT/tests/make-pdf.py" "$TEST_TMP/kept.pdf" "kept-pdf-$stamp"
DOC_ID=$(tus_upload "$TEST_TMP/token" "$KB_ID" "$TEST_TMP/kept.pdf" "kept.pdf" || true)
assert_eq "an uploaded PDF is processed" "ready" "$(wait_document "$TEST_TMP/token" "$DOC_ID" 300)"
rc=0; oauth_connect "$TEST_TMP/token" "Persistent client" "$TEST_TMP/mcp" || rc=$?
assert_eq "an MCP client is connected" "0" "$rc"
kid=$(curl -s --max-time 30 "$GATEWAY_URL/auth/v1/.well-known/jwks.json" | jq -r '.keys[0].kid')
migrations=$(psql_admin 'select count(*) from llmwiki_railway.migrations' | tr -d ' \r')

section "destroy and recreate every container (volumes kept)"
compose down >/dev/null 2>&1
compose up -d --no-build >/dev/null 2>&1
ready && pass "serving again" || die "the stack did not come back"
wait_for_log api "owner account exists from an earlier start" 1 120 && pass "the owner is found, not created again" || fail "the owner step did not recognise the existing owner"

section "state survived"
assert_eq "the signing key is the same (derived from the seed)" "$kid" "$(curl -s --max-time 30 "$GATEWAY_URL/auth/v1/.well-known/jwks.json" | jq -r '.keys[0].kid')"
sign_in "$OWNER_EMAIL" "$TEST_TMP/changed-pw" "$TEST_TMP/token2" && pass "the changed password still works" || fail "the changed password was lost"
sign_in "$OWNER_EMAIL" "$TEST_TMP/initial-pw" "$TEST_TMP/token3" && fail "the redeploy reset the owner's password" || pass "the redeploy did not reset the owner's password"
assert_eq "the wiki is there" "Kept $stamp" "$(api_as "$TEST_TMP/token2" GET "/v1/knowledge-bases/$KB_ID" | jq -r '.name // empty')"
signed=$(api_as "$TEST_TMP/token2" GET "/v1/documents/$DOC_ID/url" | jq -r '.url // empty')
assert_eq "the uploaded file is still in storage" "%PDF" "$(curl -s --max-time 30 "$signed" | head -c 4)"
assert_eq "no migration ran twice" "$migrations" "$(psql_admin 'select count(*) from llmwiki_railway.migrations' | tr -d ' \r')"
assert_contains "and none ran at all" "0 applied now" "$(compose logs --no-color --no-log-prefix api 2>&1 | grep 'database schema current' | tail -1)"
if [ -s "$TEST_TMP/mcp" ]; then
  assert_contains "the MCP client's token from before still works" "Kept $stamp" "$(mcp_tool "$TEST_TMP/mcp" list_knowledge_bases '{}')"
fi

section "owner recovery"
LLMWIKI_TEST_RESET_OWNER=true compose up -d --no-build --no-deps api >/dev/null 2>&1
wait_for_log api "owner password reset from OWNER_PASSWORD" 1 300 && pass "LLMWIKI_RESET_OWNER_PASSWORD resets the owner" || fail "the reset did not run"
wait_for_code "$API_URL/health" 200 300 || true
sign_in "$OWNER_EMAIL" "$TEST_TMP/initial-pw" "$TEST_TMP/token4" && pass "the owner signs in with OWNER_PASSWORD again" || fail "the reset password does not work"

summary
