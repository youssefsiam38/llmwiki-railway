# syntax=docker/dockerfile:1
#
# RustFS, an S3-compatible object store, prepared for a Railway volume.
# RustFS itself is unchanged; see images/storage/entrypoint.sh.
ARG RUSTFS_IMAGE=docker.io/rustfs/rustfs:1.0.0@sha256:8cc9801755448b71a786705ce76692c77e14936cccd87cf2fc31842e58f4d1ff
FROM ${RUSTFS_IMAGE}

ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown

USER root
RUN apk add --no-cache su-exec && su-exec rustfs true
COPY --chmod=0755 images/storage/entrypoint.sh /usr/local/bin/llmwiki-storage-entrypoint
COPY licenses/ /usr/share/licenses/llmwiki-railway/

LABEL org.opencontainers.image.title="llmwiki-railway-storage" \
      org.opencontainers.image.description="RustFS object storage for the LLM Wiki Railway template." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/llmwiki-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

EXPOSE 9000

ENTRYPOINT ["/usr/local/bin/llmwiki-storage-entrypoint"]
