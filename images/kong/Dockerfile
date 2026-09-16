# syntax=docker/dockerfile:1
#
# Kong as the Supabase API gateway for Railway.
#
# Supabase's compose mounts kong.yml and a small entrypoint into the stock Kong image and passes the
# two API keys in as variables. On Railway there are no mounts, and the keys cannot be variables
# because they are JWTs signed with JWT_SECRET, which Railway can generate but not sign with. So the
# config is baked in and the keys are minted at start-up.
ARG KONG_IMAGE=docker.io/kong/kong:3.9.3@sha256:9a2ae6699a2ce0d60592eb176555d3594a22782c20cc6557a61ff3a7e8b559a3
FROM ${KONG_IMAGE}

ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown

COPY images/kong/kong.yml /home/kong/temp.yml
COPY --chmod=0755 images/kong/mint-keys.pl   /usr/local/bin/llmwiki-mint-keys
COPY --chmod=0755 images/kong/entrypoint.sh  /usr/local/bin/llmwiki-kong-entrypoint
COPY licenses/ /usr/share/licenses/llmwiki-railway/

# Three departures from Supabase's compose, all about what a shared platform exposes:
#   - no access log: request URLs are nobody else's business, and Supabase clients can put keys in them
#   - request debugging off: Kong prints the debug token to the log at start-up
#   - two nginx workers: nginx starts one per CPU it can see, and on a shared host that is dozens
ENV KONG_DATABASE=off \
    KONG_DECLARATIVE_CONFIG=/usr/local/kong/kong.yml \
    KONG_ROUTER_FLAVOR=expressions \
    KONG_DNS_ORDER=LAST,AAAA,A,CNAME \
    KONG_DNS_NOT_FOUND_TTL=1 \
    KONG_DNS_VALID_TTL=5 \
    KONG_PLUGINS=request-transformer,cors,key-auth,acl,request-termination,post-function \
    KONG_NGINX_PROXY_PROXY_BUFFER_SIZE=160k \
    KONG_NGINX_PROXY_PROXY_BUFFERS="64 160k" \
    KONG_PROXY_ACCESS_LOG=off \
    KONG_PROXY_ERROR_LOG=/dev/stderr \
    KONG_LOG_LEVEL=warn \
    KONG_REQUEST_DEBUG=off \
    KONG_NGINX_WORKER_PROCESSES=2 \
    AUTH_HOST=auth

LABEL org.opencontainers.image.title="llmwiki-railway-kong" \
      org.opencontainers.image.description="Kong configured as the Supabase API gateway for the LLM Wiki Railway template." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/llmwiki-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

ENTRYPOINT ["/usr/local/bin/llmwiki-kong-entrypoint"]
