# Repowise on Railway: API + web UI + MCP server behind one Caddy front.
# Upstream publishes no container image, so this builds the official v0.62.0
# release: the PyPI wheel (hash-pinned) and the release's prebuilt web bundle
# (sha256-checked), on pinned official base images.
FROM node:22.23.5-bookworm-slim@sha256:e9f565d32859f0cbfb52125eafe8be39390f24dac302dc3cdf566e8ba3ab21ee AS node
FROM caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0 AS caddy

FROM python:3.13.18-slim-bookworm@sha256:a5a7017efc5969e00ae2b91c8eb0631049a569652aa4ffc4501769049ae45c72

ARG REPOWISE_VERSION=0.62.0
ARG REPOWISE_WEB_SHA256=3d45499d8a8069973775d4c779ffe8e7f062e8d2579acf037a0fafac90224af8

RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy

# Python dependencies exactly as upstream's uv.lock at v0.62.0, every file hash-checked.
COPY requirements.lock repowise.lock /tmp/
RUN pip install --no-cache-dir --no-deps --require-hashes -r /tmp/requirements.lock -r /tmp/repowise.lock \
 && python -c "import repowise.server, sys; print('repowise', __import__('importlib.metadata').metadata.version('repowise'))"

# Prebuilt Next.js web UI from the GitHub release (the bundle `repowise serve` downloads).
RUN mkdir -p /opt/repowise-web \
 && curl -fsSL -o /tmp/web.tgz "https://github.com/repowise-dev/repowise/releases/download/v${REPOWISE_VERSION}/repowise-web.tar.gz" \
 && echo "${REPOWISE_WEB_SHA256}  /tmp/web.tgz" | sha256sum -c - \
 && tar xzf /tmp/web.tgz -C /opt/repowise-web \
 && rm /tmp/web.tgz \
 && test -f /opt/repowise-web/server.js

COPY gitconfig /etc/gitconfig
COPY Caddyfile /etc/caddy/Caddyfile
COPY start.sh /usr/local/bin/repowise-start
COPY bootstrap.py /usr/local/bin/repowise-bootstrap
RUN chmod 755 /usr/local/bin/repowise-start

ENV HOME=/data/home \
    REPOWISE_DATA=/data \
    PYTHONUNBUFFERED=1 \
    DO_NOT_TRACK=1 \
    REPOWISE_TELEMETRY_DISABLED=1 \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=8080

EXPOSE 8080
CMD ["/usr/local/bin/repowise-start"]
