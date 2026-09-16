#!/bin/bash
# llmwiki-railway db entrypoint: validate, then hand over to Supabase's own entrypoint.
set -uo pipefail
log()  { printf '[llmwiki-db] %s\n' "$*"; }
fail() { printf '[llmwiki-db] FATAL: %s\n' "$*" >&2; exit 1; }

[ -n "${POSTGRES_PASSWORD:-}" ] || fail "missing required variable: POSTGRES_PASSWORD"
[ "${#POSTGRES_PASSWORD}" -ge 32 ] || fail "POSTGRES_PASSWORD must be at least 32 characters; it is the password of every Supabase role, including the superuser"
case "$POSTGRES_PASSWORD" in
  your-super-secret-and-long-postgres-password|postgres)
    fail "POSTGRES_PASSWORD is the value from Supabase's public .env.example. Generate a real one." ;;
esac
# The init scripts interpolate the password into ALTER USER statements with psql's \set, which
# breaks on a single quote. Railway's generator never produces one; a hand-typed value might.
case "$POSTGRES_PASSWORD" in
  *"'"*|*"\\"*) fail "POSTGRES_PASSWORD must not contain quotes or backslashes" ;;
esac

# A fresh volume holds lost+found, which initdb refuses; the cluster lives in a subdirectory.
mkdir -p "$PGDATA" && chown postgres:postgres "$PGDATA" "$(dirname "$PGDATA")" 2>/dev/null
chmod 0700 "$PGDATA" 2>/dev/null || true

log "starting Supabase Postgres (data in ${PGDATA})"
exec docker-entrypoint.sh postgres \
  -c config_file=/etc/postgresql/postgresql.conf \
  -c data_directory="$PGDATA" \
  -c pgsodium.getkey_script=/usr/local/bin/llmwiki-pgsodium-getkey \
  -c vault.getkey_script=/usr/local/bin/llmwiki-pgsodium-getkey \
  -c listen_addresses='*' \
  -c log_min_messages=fatal
