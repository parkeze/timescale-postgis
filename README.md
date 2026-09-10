# timescale-postgis

TimescaleDB with PostGIS, built against a matching PostgreSQL major.

```
ghcr.io/parkeze/timescale-postgis:pg17
```

Public image, `linux/amd64` and `linux/arm64`. No pull secret required.

## Why this exists

The upstream `timescale/timescaledb` image does not ship PostGIS, and adding it
is not the one-line change it looks like:

```dockerfile
FROM timescale/timescaledb:2.17.2-pg17
RUN apk add --no-cache postgis          # looks fine, builds fine, breaks later
```

That image is built on Alpine **edge**, which tracks whatever PostgreSQL major
Alpine currently defaults to. Once edge moves ahead of the major the image
actually runs, its `postgis` package is compiled against the newer one. apk
installs it without complaint and the build succeeds. The failure arrives much
later, in whatever environment first runs `CREATE EXTENSION`:

```
ERROR:  could not load library "/usr/local/lib/postgresql/postgis-3.so":
        undefined symbol: ...
```

The problem is not obvious from that message, and the build that caused it
succeeded weeks earlier.

This image installs PostGIS from a **pinned stable** Alpine release whose
default PostgreSQL matches, takes every transitive dependency (GEOS, GDAL,
PROJ) from that same release so no mixed-version shared libraries reach the
path, and **asserts the pairing at build time** so a mismatch fails in CI
rather than in production.

## Usage

```yaml
services:
  db:
    image: ghcr.io/parkeze/timescale-postgis:pg17
    environment:
      POSTGRES_PASSWORD: example
```

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS postgis;
```

As a base image:

```dockerfile
FROM ghcr.io/parkeze/timescale-postgis:pg17
COPY schema/*.sql /docker-entrypoint-initdb.d/
```

Everything the upstream image supports — `POSTGRES_DB`, `POSTGRES_USER`,
initdb scripts, the `postgres` entrypoint — works unchanged. This adds
extensions and nothing else.

## Tags

| Tag | Contents |
|---|---|
| `pg17` | Latest build for PostgreSQL 17 |
| `2.17.2-pg17` | Pinned TimescaleDB and PostgreSQL |
| `latest` | Same as the newest `pg*` tag |

Pin to `<timescaledb>-pg<major>` for anything you care about. `pg17` moves when
TimescaleDB is upgraded.

## Building

```bash
docker build -t timescale-postgis .
```

| Build arg | Default | Meaning |
|---|---|---|
| `TIMESCALEDB_VERSION` | `2.25.1` | Upstream TimescaleDB tag. Must be >= the extension version installed in any database this image will serve — PostgreSQL loads `timescaledb-<installed>.so` at start, so an image below it cannot start the server. |
| `PG_MAJOR` | `17` | PostgreSQL major |
| `ALPINE_VERSION` | `3.21` | Alpine release PostGIS is installed from |
| `ALPINE_MIRROR` | `dl-cdn.alpinelinux.org` | Override for a local mirror |

### Choosing ALPINE_VERSION

`ALPINE_VERSION` must be the Alpine release whose **default** `postgresql`
package is `PG_MAJOR`. This is the one thing that has to be right.

| PostgreSQL | Alpine | Status |
|---|---|---|
| 17 | 3.21 | Verified — PostGIS 3.5, GEOS, PROJ |

Other majors are not published here, but the build is parameterised for them.
To add one, find the Alpine release whose `postgresql` package is that major
(check <https://pkgs.alpinelinux.org/packages?name=postgresql>), then:

```bash
docker build --build-arg PG_MAJOR=16 --build-arg ALPINE_VERSION=3.20 .
```

If the pairing is wrong the build stops with the mismatch spelled out, rather
than producing an image that fails at `CREATE EXTENSION`:

```
ERROR: PostGIS was built for a different PostgreSQL major.
  found:    /usr/lib/postgresql16/postgis-3.so
  expected: a path under /usr/lib/postgresql17/
  cause:    Alpine v3.20 does not default to PostgreSQL 17.
```

A pairing that builds and passes the CI smoke test is a pairing that works —
send a PR adding it to the matrix.

## What CI checks

Every build starts the image, waits for readiness, creates both extensions and
runs a real geometry operation. An image that cannot `ST_MakePoint` does not
get published.

## License

Apache 2.0. See [LICENSE](LICENSE).

TimescaleDB and PostGIS carry their own licenses; this repository packages
them and claims nothing over either.
