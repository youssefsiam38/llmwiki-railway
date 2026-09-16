# syntax=docker/dockerfile:1
#
# Supabase Postgres for Railway.
#
# Supabase's self-hosting stack configures this image through bind mounts: five init scripts under
# /docker-entrypoint-initdb.d and a named volume at /etc/postgresql-custom. Railway has neither --
# one volume per service and no bind mounts -- so the init scripts are baked in here, and the one
# piece of state that lived in that second volume, the pgsodium/vault root key, is moved into the
# data volume. Nothing about Postgres itself is changed.
ARG SUPABASE_POSTGRES_IMAGE=docker.io/supabase/postgres:17.6.1.136@sha256:f371b5f3f2ac0a05703f33d6e6134515fb2498cab708fb948a0aeb7481467c00
FROM ${SUPABASE_POSTGRES_IMAGE}

ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown

# The same paths Supabase's docker-compose.yml mounts them at.
COPY images/db/init/realtime.sql  /docker-entrypoint-initdb.d/migrations/99-realtime.sql
COPY images/db/init/_supabase.sql /docker-entrypoint-initdb.d/migrations/97-_supabase.sql
COPY images/db/init/webhooks.sql  /docker-entrypoint-initdb.d/init-scripts/98-webhooks.sql
COPY images/db/init/roles.sql     /docker-entrypoint-initdb.d/init-scripts/99-roles.sql
COPY images/db/init/jwt.sql       /docker-entrypoint-initdb.d/init-scripts/99-jwt.sql
COPY --chmod=0755 images/db/getkey.sh     /usr/local/bin/llmwiki-pgsodium-getkey
COPY --chmod=0755 images/db/entrypoint.sh /usr/local/bin/llmwiki-db-entrypoint
COPY licenses/ /usr/share/licenses/llmwiki-railway/

# Railway mounts the volume here, and a fresh volume already holds lost+found, which initdb refuses.
# The cluster therefore lives one level down; `data_directory` is passed on the command line because
# Supabase's postgresql.conf pins it to the mount root and PGDATA alone does not override that.
ENV PGDATA=/var/lib/postgresql/data/pgdata \
    POSTGRES_DB=postgres \
    POSTGRES_USER=supabase_admin \
    JWT_EXP=3600

LABEL org.opencontainers.image.title="llmwiki-railway-db" \
      org.opencontainers.image.description="Supabase Postgres for the LLM Wiki Railway template: init scripts baked in, vault key kept on the data volume." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/llmwiki-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENTRYPOINT ["/usr/local/bin/llmwiki-db-entrypoint"]
