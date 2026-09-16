# syntax=docker/dockerfile:1
#
# LLM Wiki's web app for Railway.
#
# Next.js inlines NEXT_PUBLIC_* values into the bundle at build time, and the web app needs four of them: the
# Supabase gateway's URL and anon key, and the API's and MCP server's URLs. A one-click template cannot
# rebuild per deploy with values that do not exist yet, so this image is built once, from a pinned upstream
# commit, with unmistakable placeholder values, and the entrypoint writes the real values into the built
# files at start-up (fill-public-env.mjs).
#
# Dependencies: upstream's package.json and lockfile, with the pins that carry published advisories raised
# (images/web/deps; see UPSTREAM.md). The build fails if upstream's own manifest is not the one those files
# were derived from, so a new upstream commit cannot silently build with stale dependency choices.
ARG NODE_IMAGE=docker.io/library/node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32
ARG LLMWIKI_COMMIT=aac3e6493306b7fff3b09cb181ca93918e93d0e6
ARG UPSTREAM_PACKAGE_JSON_SHA256=b027a7c950396a653cf880082aef3848cdcc0ccb13a2e64b72ba7ffa045ff0a7
ARG UPSTREAM_PACKAGE_LOCK_SHA256=a3586ee2db02d91b7e6d58349c882fb73093e63132ac30bc88adc9b1424903ed

FROM ${NODE_IMAGE} AS source
ARG LLMWIKI_COMMIT
ARG UPSTREAM_PACKAGE_JSON_SHA256
ARG UPSTREAM_PACKAGE_LOCK_SHA256
RUN apk add --no-cache git >/dev/null \
    && git init -q /src \
    && git -C /src fetch -q --depth 1 https://github.com/lucasastorian/llmwiki.git "${LLMWIKI_COMMIT}" \
    && git -C /src checkout -q FETCH_HEAD \
    && test "$(git -C /src rev-parse HEAD)" = "${LLMWIKI_COMMIT}" \
    && rm -rf /src/.git \
    && echo "${UPSTREAM_PACKAGE_JSON_SHA256}  /src/web/package.json" | sha256sum -c - \
    && echo "${UPSTREAM_PACKAGE_LOCK_SHA256}  /src/web/package-lock.json" | sha256sum -c -
COPY images/web/deps/package.json images/web/deps/package-lock.json /src/web/

FROM ${NODE_IMAGE} AS builder
WORKDIR /app
COPY --from=source /src/web/package.json /src/web/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY --from=source /src/web/ ./
# Placeholders, replaced at start-up. URL-shaped where the build may parse them; `.invalid` is reserved and
# can never resolve. NEXT_PUBLIC_MODE=hosted is the multi-user app with sign-in; it is fixed, not filled.
ENV NEXT_PUBLIC_MODE=hosted \
    NEXT_PUBLIC_SUPABASE_URL=https://llmwiki-railway-placeholder-supabase-url.invalid \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=llmwiki-railway-placeholder-supabase-anon-key \
    NEXT_PUBLIC_API_URL=https://llmwiki-railway-placeholder-api-url.invalid \
    NEXT_PUBLIC_MCP_URL=https://llmwiki-railway-placeholder-mcp-url.invalid/mcp \
    NEXT_TELEMETRY_DISABLED=1
RUN npm run build
# The runtime layout upstream's image ships, assembled here so the placeholder index matches it exactly.
RUN mkdir -p /out \
    && cp -a .next/standalone/. /out/ \
    && cp -a .next/static /out/.next/static \
    && cp -a public /out/public
COPY images/web/fill-public-env.mjs /tmp/fill-public-env.mjs
RUN node /tmp/fill-public-env.mjs --index /out /opt/llmwiki-railway/pristine

FROM ${NODE_IMAGE}
ARG LLMWIKI_COMMIT
ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown
ARG BUILD_DATE=1970-01-01T00:00:00Z

WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000 LLMWIKI_COMMIT=${LLMWIKI_COMMIT}

COPY --from=builder --chown=node:node /out/ /app/
COPY --from=builder /opt/llmwiki-railway/pristine /opt/llmwiki-railway/pristine
COPY lib/mint-supabase-keys.mjs images/web/fill-public-env.mjs /opt/llmwiki-railway/
COPY --chmod=0755 images/web/entrypoint.sh /usr/local/bin/llmwiki-web-entrypoint
COPY licenses/ /usr/share/licenses/llmwiki-railway/

# Both the server output and the browser chunks must carry the placeholders.
RUN test -s /opt/llmwiki-railway/pristine/.index \
    && grep -q '^.next/static/' /opt/llmwiki-railway/pristine/.index \
    && grep -q '^.next/server/' /opt/llmwiki-railway/pristine/.index \
    && test -f /app/server.js

USER node

LABEL org.opencontainers.image.title="llmwiki-railway-web" \
      org.opencontainers.image.description="LLM Wiki's web app, built for the Railway template with its public URLs written in at start-up. Not affiliated with the LLM Wiki project." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/llmwiki-railway" \
      org.opencontainers.image.url="https://github.com/youssefsiam38/llmwiki-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.llmwiki-railway.upstream.commit="${LLMWIKI_COMMIT}"

EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/llmwiki-web-entrypoint"]
