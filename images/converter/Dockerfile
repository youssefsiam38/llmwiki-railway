# syntax=docker/dockerfile:1
#
# LLM Wiki's document converter for Railway: LibreOffice and opendataloader turn uploaded PDF, Word and
# PowerPoint files into pages of text, isolated from the API process.
#
# Built as upstream's converter/Dockerfile builds it, from a pinned commit, with two changes: dependencies
# install from upstream's hash-locked file rather than the unpinned list, and the download allowlist accepts
# the template's own object storage (patch_s3_endpoint.py). It also listens on IPv6 as well as IPv4
# (lib/serve.py): Railway's private network is IPv6.
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
COPY images/converter/patch_s3_endpoint.py /tmp/patch_s3_endpoint.py
RUN python /tmp/patch_s3_endpoint.py /src/converter/main.py

FROM ${PYTHON_IMAGE} AS audit
ARG PIP_AUDIT_VERSION
COPY --from=source /src/converter/requirements.lock /tmp/requirements.lock
RUN pip install --no-cache-dir -q "pip-audit==${PIP_AUDIT_VERSION}" \
    && pip-audit -r /tmp/requirements.lock --strict --desc \
    && touch /tmp/audited

FROM ${PYTHON_IMAGE}
ARG UV_VERSION
ARG LLMWIKI_COMMIT
ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown
ARG BUILD_DATE=1970-01-01T00:00:00Z

RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      libreoffice-writer libreoffice-impress libreoffice-calc openjdk-17-jre-headless >/dev/null \
    && rm -rf /var/lib/apt/lists/*
ENV JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    LLMWIKI_COMMIT=${LLMWIKI_COMMIT}

COPY --from=audit /tmp/audited /opt/llmwiki-railway/.audited
COPY --from=source /src/converter/requirements.lock /tmp/requirements.lock
RUN pip install --no-cache-dir -q "uv==${UV_VERSION}" \
    && uv pip install --system --require-hashes -r /tmp/requirements.lock \
    && pip uninstall --yes -q uv && rm /tmp/requirements.lock \
    && useradd -m -s /bin/bash converter

WORKDIR /app
COPY --from=source /src/converter/main.py /app/main.py
COPY lib/serve.py /opt/llmwiki-railway/serve.py
COPY --chmod=0755 images/converter/entrypoint.sh /usr/local/bin/llmwiki-converter-entrypoint
COPY licenses/ /usr/share/licenses/llmwiki-railway/
RUN grep -q "llmwiki-railway: the template's bundled object storage" /app/main.py \
    && mkdir -p /tmp/conversions && chown converter:converter /tmp/conversions

USER converter

LABEL org.opencontainers.image.title="llmwiki-railway-converter" \
      org.opencontainers.image.description="LLM Wiki's document converter (LibreOffice, opendataloader) for the Railway template. Not affiliated with the LLM Wiki project." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/llmwiki-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.llmwiki-railway.upstream.commit="${LLMWIKI_COMMIT}"

EXPOSE 8000
ENTRYPOINT ["/usr/local/bin/llmwiki-converter-entrypoint"]
