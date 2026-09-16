#!/bin/bash
# pgsodium and supabase_vault fetch their root key through this script. Upstream's version writes
# the key to /etc/postgresql-custom, which Supabase's compose keeps on a second named volume. On
# Railway that directory is part of the container's throwaway filesystem, so upstream's script
# would mint a NEW key on every deploy and every vault secret written before it would become
# permanently undecryptable. This one keeps the key beside the data it protects.
set -euo pipefail
KEY_FILE="${LLMWIKI_PGSODIUM_KEY_FILE:-/var/lib/postgresql/data/pgsodium_root.key}"
if [[ ! -s "${KEY_FILE}" ]]; then
  umask 077
  head -c 32 /dev/urandom | od -A n -t x1 | tr -d ' \n' > "${KEY_FILE}"
fi
cat "${KEY_FILE}"
