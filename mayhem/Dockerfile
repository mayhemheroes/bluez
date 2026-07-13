# syntax=docker/dockerfile:1.7
#
# Commit-image for mayhemheroes/bluez — builds the SDP fuzz harness + the upstream unit tests
# on top of the org C/C++ base image.
FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# BlueZ build deps + the ELL source tree it requires (configure looks for ../ell/ell/ell.h).
# ELL is pinned and cloned at build time so the offline build.sh re-run stays air-gapped.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        autoconf automake libtool pkg-config \
        libglib2.0-dev libdbus-1-dev libical-dev libudev-dev libreadline-dev \
        flex bison \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch 0.83 \
        https://git.kernel.org/pub/scm/libs/ell/ell.git /ell \
    && chown -R 2000:2000 /ell

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
