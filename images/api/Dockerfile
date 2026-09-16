# syntax=docker/dockerfile:1
#
# LLM Wiki's API (hosted mode) for Railway.
#
# Upstream publishes no images; its hosted service builds api/Dockerfile from the repository. This image
# does the same from a pinned commit -- the hash-locked dependencies, the pip-audit gate, the parser
# removed from the API process -- and adds the start-up steps a one-click deployment needs in place of the
# Supabase CLI and a hand-made bucket (railway_setup.py). One change to LLM Wiki's code: signed storage
# links use the public storage address while the API itself uses the private one (patch_s3_presign.py).
ARG PYTHON_IMAGE=docker.io/library/python:3.11-slim-bookworm@sha256:528257d48c1da0dcecc2e725d1ae34498d60c965f1241e39cd6a85a8859bdf84
ARG LLMWIKI_COMMIT=aac3e6493306b7fff3b09cb181ca93918e93d0e6
ARG UV_VERSION=0.12.15
ARG PIP_AUDIT_VERSION=2.10.1

# Upstream source at an exact commit. Fetching by commit id makes git verify it.
FROM ${PYTHON_IMAGE} AS source
ARG LLMWIKI_COMMIT
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends git ca-certificates >/dev/null \
    && git init -q /src \
    && git -C /src fetch -q --depth 1 https://github.com/lucasastorian/llmwiki.git "${LLMWIKI_COMMIT}" \
    && git -C /src checkout -q FETCH_HEAD \
    && test "$(git -C /src rev-parse HEAD)" = "${LLMWIKI_COMMIT}" \
    && rm -rf /src/.git
COPY images/api/patch_s3_presign.py /tmp/patch_s3_presign.py
RUN python /tmp/patch_s3_presign.py /src/api/services/s3.py

# Upstream's dependency gate, kept: the image is not built while a locked dependency has a known advisory.
FROM ${PYTHON_IMAGE} AS audit
ARG PIP_AUDIT_VERSION
COPY --from=source /src/api/requirements.lock /tmp/requirements.lock
RUN pip install --no-cache-dir -q "pip-audit==${PIP_AUDIT_VERSION}" \
    && pip-audit -r /tmp/requirements.lock --strict --desc \
    && touch /tmp/audited

FROM ${PYTHON_IMAGE}
ARG UV_VERSION
ARG LLMWIKI_COMMIT
ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown
ARG BUILD_DATE=1970-01-01T00:00:00Z

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 MODE=hosted LLMWIKI_COMMIT=${LLMWIKI_COMMIT}
WORKDIR /app

COPY --from=audit /tmp/audited /opt/llmwiki-railway/.audited
COPY --from=source /src/api/requirements.lock /tmp/requirements.lock
RUN pip install --no-cache-dir -q "uv==${UV_VERSION}" \
    && uv pip install --system --require-hashes -r /tmp/requirements.lock \
    # As upstream: PDF and Office parsing belongs to the converter service, never the API process.
    && pip uninstall --yes -q opendataloader-pdf \
    && pip uninstall --yes -q uv \
    && rm /tmp/requirements.lock

COPY --from=source /src/api/ /app/
COPY --from=source /src/supabase/migrations/ /opt/llmwiki-railway/migrations/
COPY images/api/railway_setup.py images/api/gate.sql lib/aws-config lib/serve.py /opt/llmwiki-railway/
COPY --chmod=0755 images/api/entrypoint.sh /usr/local/bin/llmwiki-api-entrypoint
COPY licenses/ /usr/share/licenses/llmwiki-railway/

# The app must import as built (a missing module fails here, not at deploy time).
RUN cd /app && python -c "import main" \
    && grep -q 'llmwiki-railway: links are for browsers' /app/services/s3.py \
    && ls /opt/llmwiki-railway/migrations/001_initial.sql >/dev/null \
    && python -m py_compile /opt/llmwiki-railway/railway_setup.py \
    && useradd --system --uid 10001 --home-dir /nonexistent --shell /usr/sbin/nologin llmwiki \
    && rm -rf /app/tests /app/Dockerfile /app/railway.toml

USER llmwiki

LABEL org.opencontainers.image.title="llmwiki-railway-api" \
      org.opencontainers.image.description="LLM Wiki's API in hosted mode, built for the Railway template: migrations, signup gate, bucket and owner account handled at start-up. Not affiliated with the LLM Wiki project." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/llmwiki-railway" \
      org.opencontainers.image.url="https://github.com/youssefsiam38/llmwiki-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.llmwiki-railway.upstream.commit="${LLMWIKI_COMMIT}"

EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/llmwiki-api-entrypoint"]
