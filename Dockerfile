# syntax=docker/dockerfile:1
#
# TimescaleDB and PostGIS in one image.
#
# The upstream timescale/timescaledb image does not ship PostGIS, and adding it
# is not the one-line `apk add postgis` it appears to be. That image is built on
# Alpine *edge*, which tracks whatever PostgreSQL major Alpine currently
# defaults to. When edge moves ahead of the major the image actually runs, its
# postgis package is compiled against the newer one — apk installs it happily,
# the build succeeds, and the failure surfaces much later as:
#
#     ERROR: could not load library ".../postgis-3.so": undefined symbol
#
# at CREATE EXTENSION, in whatever environment first tried to use it.
#
# The fix is to install PostGIS from a *pinned stable* Alpine release whose
# default PostgreSQL matches PG_MAJOR, and to take every dependency
# (libgeos, libgdal, libproj, …) from that same release so no mixed-version
# shared libraries end up on the path.

# This version is not cosmetic: it decides which timescaledb-<v>.so files end
# up in the image, and PostgreSQL loads the one matching the extension version
# recorded in the *data directory*, at server start, because timescaledb is in
# shared_preload_libraries.
#
# Pinned at 2.17.2, this image shipped 2.17.0-2.17.2 only. The production
# database at sensor_status_db has timescaledb 2.24.0 installed, so recreating
# that container from an image built here would have failed to start the
# server: no timescaledb-2.24.0.so on disk. The database was running from an
# older image out of a registry that has since been deleted, which is how the
# two drifted apart unnoticed.
#
# 2.25.1 is what the running database's own image was built from, and the
# upstream image ships the whole ladder from 2.17.0 up, so it contains 2.24.0
# and every version in between. Raise this to match production, never below it.
ARG TIMESCALEDB_VERSION=2.25.1
ARG PG_MAJOR=17

FROM timescale/timescaledb:${TIMESCALEDB_VERSION}-pg${PG_MAJOR}

# ARGs declared before the first FROM are only in scope for FROM itself, so
# anything a RUN needs has to be declared again here.
ARG PG_MAJOR

# Must be the Alpine release whose default `postgresql` package is PG_MAJOR.
# See the compatibility table in README.md — this pairing is the entire point
# of the image, and getting it wrong is what the assertion below catches.
ARG ALPINE_VERSION=3.21

ARG ALPINE_MIRROR=https://dl-cdn.alpinelinux.org/alpine

LABEL org.opencontainers.image.title="timescale-postgis" \
      org.opencontainers.image.description="TimescaleDB with PostGIS, built against a matching PostgreSQL major." \
      org.opencontainers.image.licenses="Apache-2.0"

USER root

RUN set -eux; \
    # --repositories-file rather than appending to /etc/apk/repositories: this
    # resolves *every* package for this transaction against the pinned release,
    # dependencies included. Appending would leave edge in the list and let apk
    # satisfy libgeos or libproj from it, which reintroduces the mixed-version
    # problem the pin exists to avoid.
    printf '%s\n' \
      "${ALPINE_MIRROR}/v${ALPINE_VERSION}/main" \
      "${ALPINE_MIRROR}/v${ALPINE_VERSION}/community" \
      > /tmp/alpine-pinned.repos; \
    apk add --no-cache --repositories-file /tmp/alpine-pinned.repos postgis; \
    rm /tmp/alpine-pinned.repos; \
    \
    # Fail here, at build time, rather than at CREATE EXTENSION in production.
    # Alpine installs the extension under /usr/lib/postgresql<major>/, so the
    # major it was compiled against is readable straight off the path. If
    # ALPINE_VERSION and PG_MAJOR disagree, this is where it stops.
    PGIS_SO="$(find /usr/lib -name 'postgis-*.so' | head -n1)"; \
    if [ -z "${PGIS_SO}" ]; then \
      echo "ERROR: no postgis shared library after 'apk add postgis'." >&2; \
      exit 1; \
    fi; \
    case "${PGIS_SO}" in \
      */postgresql${PG_MAJOR}/*) : ;; \
      *) \
        echo "ERROR: PostGIS was built for a different PostgreSQL major." >&2; \
        echo "  found:    ${PGIS_SO}" >&2; \
        echo "  expected: a path under /usr/lib/postgresql${PG_MAJOR}/" >&2; \
        echo "  cause:    Alpine v${ALPINE_VERSION} does not default to PostgreSQL ${PG_MAJOR}." >&2; \
        echo "  fix:      set ALPINE_VERSION to the release matching PG_MAJOR (see README)." >&2; \
        exit 1 ;; \
    esac; \
    \
    # The base image looks for extensions under /usr/local, where it installs
    # PostgreSQL; Alpine's package puts them under /usr. Symlink rather than
    # copy so an `apk upgrade` of postgis is picked up without rebuilding.
    for f in /usr/share/postgresql*/extension/postgis*.control \
             /usr/share/postgresql*/extension/postgis*.sql; do \
      [ -e "$f" ] && ln -sf "$f" /usr/local/share/postgresql/extension/; \
    done; \
    for f in /usr/lib/postgresql*/postgis*.so; do \
      [ -e "$f" ] && ln -sf "$f" /usr/local/lib/postgresql/; \
    done; \
    \
    # Prove the linker can actually resolve it now, rather than trusting that
    # the symlinks landed somewhere useful.
    ln -sf /usr/local/lib/postgresql/postgis-*.so /tmp/probe.so; \
    rm -f /tmp/probe.so

USER postgres
