#!/bin/sh
# llmwiki-railway storage entrypoint: RustFS on a Railway volume.
#
# Railway mounts a service's volume owned by root, with lost+found at its root, while RustFS runs as its
# own unprivileged user. So this starts as root only long enough to prepare a data directory one level
# down, owned by that user, then drops to it for RustFS itself.
set -eu
log()  { printf '[llmwiki-storage] %s\n' "$*"; }
fail() { printf '[llmwiki-storage] FATAL: %s\n' "$*" >&2; exit 1; }

for name in RUSTFS_ACCESS_KEY RUSTFS_SECRET_KEY; do
  eval "v=\${$name:-}"
  # shellcheck disable=SC2154  # v is assigned by the eval above
  [ -n "$v" ] || fail "missing required variable: $name"
done
[ "${#RUSTFS_ACCESS_KEY}" -ge 16 ] || fail "RUSTFS_ACCESS_KEY must be at least 16 characters"
[ "${#RUSTFS_SECRET_KEY}" -ge 32 ] || fail "RUSTFS_SECRET_KEY must be at least 32 characters"
case "$RUSTFS_ACCESS_KEY$RUSTFS_SECRET_KEY" in *rustfsadmin*|*minioadmin*) fail "refusing RustFS's default credentials" ;; esac

DATA=/data/rustfs
mkdir -p "$DATA" /logs
chown rustfs:rustfs "$DATA" /logs
chmod 0750 "$DATA"

export RUSTFS_VOLUMES="$DATA"
: "${PORT:=9000}"
export RUSTFS_ADDRESS="[::]:${PORT}"
export RUSTFS_CONSOLE_ENABLE=false
log "S3 API on [::]:${PORT}, data in ${DATA}, console off"
exec su-exec rustfs /entrypoint.sh rustfs
