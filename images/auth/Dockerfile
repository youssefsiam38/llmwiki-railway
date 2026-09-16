# syntax=docker/dockerfile:1
#
# Supabase Auth (GoTrue) for the LLM Wiki Railway template.
#
# LLM Wiki verifies Supabase tokens only against an asymmetric key published in Supabase Auth's JWKS,
# and Claude and other MCP clients sign in through Supabase Auth's OAuth 2.1 server. Supabase's own
# self-hosting setup signs with the shared HS256 secret alone. This image adds one thing: a helper that
# derives a stable ES256 signing key from a generated seed at start-up (Railway can generate secrets,
# not key pairs). Supabase Auth itself is unchanged.
ARG GO_IMAGE=docker.io/library/golang:1.25-alpine@sha256:1ae0735f00daffa3aaf1363a5184c0d2dc55c78e3db4ec70241cdac97bf84b59
ARG GOTRUE_IMAGE=docker.io/supabase/gotrue:v2.197.0@sha256:1736a63078f5922b198c4cbe50f80ab9a2d3b54fe8b7b6cfb2e9dc5dbbc12c6b

FROM ${GO_IMAGE} AS keygen
WORKDIR /src
COPY images/auth/keygen/ ./
RUN test -z "$(gofmt -l .)" && go vet ./... \
    && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/llmwiki-keys .

FROM ${GOTRUE_IMAGE}
ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown

COPY --from=keygen /out/llmwiki-keys /usr/local/bin/llmwiki-keys
COPY --chmod=0755 images/auth/entrypoint.sh /usr/local/bin/llmwiki-auth-entrypoint
COPY licenses/ /usr/share/licenses/llmwiki-railway/

LABEL org.opencontainers.image.title="llmwiki-railway-auth" \
      org.opencontainers.image.description="Supabase Auth for the LLM Wiki Railway template: an ES256 signing key derived at start-up, OAuth 2.1 server for MCP clients." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/llmwiki-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

USER supabase
ENTRYPOINT ["/usr/local/bin/llmwiki-auth-entrypoint"]
