# Changelog

## 0.62.0 (2026-11-23)

- First release: Repowise v0.62.0 (PyPI wheel, hash-locked dependencies) and the v0.62.0 prebuilt web UI, on `python:3.12.16-slim-bookworm`.
- Caddy front with basic auth on the dashboard and bearer-token MCP at `/mcp`; health check at `/healthz`.
- Clones and indexes the repositories in `REPOWISE_REPOS` on boot; all data on the `/data` volume.
- Memory guard: below 900 MB the MCP server is off and repos are registered without auto-indexing.
