# syntax=docker/dockerfile:1
#
# LLM Wiki's MCP server (hosted mode) for Railway: the endpoint Claude, Codex and other MCP clients connect
# to, authenticated with Supabase Auth's OAuth tokens.
#
# Built as upstream's mcp/Dockerfile builds it, from a pinned commit: hash-locked dependencies behind the
# pip-audit gate. LLM Wiki's code is unchanged; the entrypoint only validates the configuration.
ARG PYTHON_IMAGE=docker.io/library/python:3.11-slim-bookworm@sha256:528257d48c1da0dcecc2e725d1ae34498d60c965f1241e39cd6a85a8859bdf84
ARG LLMWIKI_COMMIT=aac3e6493306b7fff3b09cb181ca93918e93d0e6
ARG UV_VERSION=0.12.15
ARG PIP_AUDIT_VERSION=2.10.1

FROM ${PYTHON_IMAGE} AS source
ARG LLMWIKI_COMMIT
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends git ca-certificates >/dev/null \
    && git init -q /src \
    && git -C /src fetch -q --depth 1 https://github.com/lucasastorian/llmwiki.git "${LLMWIKI_COMMIT}" \
    && git -C /src checkout -q FETCH_HEAD \
    && test "$(git -C /src rev-parse HEAD)" = "${LLMWIKI_COMMIT}" \
    && rm -rf /src/.git

FROM ${PYTHON_IMAGE} AS audit
ARG PIP_AUDIT_VERSION
COPY --from=source /src/mcp/requirements.lock /tmp/requirements.lock
RUN pip install --no-cache-dir -q "pip-audit==${PIP_AUDIT_VERSION}" \
    && pip-audit -r /tmp/requirements.lock --strict --desc \
    && touch /tmp/audited

FROM ${PYTHON_IMAGE}
ARG UV_VERSION
ARG LLMWIKI_COMMIT
ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown
ARG BUILD_DATE=1970-01-01T00:00:00Z

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 MODE=hosted PORT=8080 LLMWIKI_COMMIT=${LLMWIKI_COMMIT}
WORKDIR /app

COPY --from=audit /tmp/audited /opt/llmwiki-railway/.audited
COPY --from=source /src/mcp/requirements.lock /tmp/requirements.lock
RUN pip install --no-cache-dir -q "uv==${UV_VERSION}" \
    && uv pip install --system --require-hashes -r /tmp/requirements.lock \
    && pip uninstall --yes -q uv && rm /tmp/requirements.lock

COPY --from=source /src/mcp/ /app/
COPY lib/aws-config /opt/llmwiki-railway/aws-config
COPY --chmod=0755 images/mcp/entrypoint.sh /usr/local/bin/llmwiki-mcp-entrypoint
COPY licenses/ /usr/share/licenses/llmwiki-railway/
RUN cd /app && python -c "import tools, vaultfs, auth" \
    && rm -rf /app/Dockerfile /app/railway.toml \
    && useradd --system --uid 10001 --home-dir /nonexistent --shell /usr/sbin/nologin llmwiki

USER llmwiki

LABEL org.opencontainers.image.title="llmwiki-railway-mcp" \
      org.opencontainers.image.description="LLM Wiki's MCP server in hosted mode, for the Railway template. Not affiliated with the LLM Wiki project." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/llmwiki-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.llmwiki-railway.upstream.commit="${LLMWIKI_COMMIT}"

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/llmwiki-mcp-entrypoint"]
