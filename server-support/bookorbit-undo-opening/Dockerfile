ARG BASE_IMAGE=ghcr.io/bookorbit/bookorbit:3.2.0@sha256:1020eef9f004be972ac60e79dd5f416129f0d3d91491b803aa8fa656acb2b6a6
FROM ${BASE_IMAGE}
ARG PATCH_REVISION
COPY --chown=node:node overlay/ /app/
LABEL org.opencontainers.image.source="https://github.com/komadorirobin/Ereader" \
      se.littex.bookorbit.undo-opening.revision="${PATCH_REVISION}" \
      se.littex.bookorbit.undo-opening.base="3.2.0"
ENV BOOKORBIT_UNDO_OPENING_VERSION=1
