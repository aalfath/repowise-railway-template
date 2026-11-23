[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/repowise?utm_medium=integration&utm_source=button&utm_campaign=repowise)

# Repowise on Railway

One-click [Repowise](https://github.com/repowise-dev/repowise) **v0.62.0** (AGPL-3.0): codebase intelligence for people and AI coding agents. It indexes your Git repositories and serves a web dashboard (code health, generated docs, architecture graph, git hotspots, ownership, dead code, decisions) plus a **remote MCP server** your agents (Claude Code, Cursor, Codex…) can query.

Upstream publishes no container image, so this repo builds the official release: the PyPI wheel `repowise==0.62.0` (every dependency hash-locked from upstream's `uv.lock`) and the release's prebuilt web bundle (`repowise-web.tar.gz`, sha256-checked), on `python:3.12.16-slim-bookworm@sha256:935c3c5b…`.

## What gets deployed

One service, `Repowise`, with a volume on `/data`:

| Process | Listens on | What it does |
|---|---|---|
| Caddy | `$PORT` (public) | Front door: basic auth on the dashboard, bearer token on `/mcp`, `/healthz` for Railway |
| Repowise API (FastAPI) | 127.0.0.1:7337 | Indexing jobs, REST API, SQLite stores |
| Repowise web UI (Next.js) | 127.0.0.1:3000 | The dashboard |
| Repowise MCP server | 127.0.0.1:7338 | Streamable-HTTP MCP for the first repository (needs about 1 GB RAM) |

Everything Repowise writes (clones in `/data/repos`, each repo's `.repowise/` index, the server registry and settings in `/data/home`) lives on the volume. If any process stops, the container exits non-zero and Railway restarts it.

## Variables

| Variable | Default | |
|---|---|---|
| `REPOWISE_REPOS` | *(you set it)* | Git URLs to clone and index, space- or comma-separated, e.g. `https://github.com/you/app`. Read on every boot: add a URL and redeploy to add a repo. |
| `REPOWISE_USERNAME` | `admin` | Dashboard login name |
| `REPOWISE_PASSWORD` | generated | Dashboard password |
| `REPOWISE_API_KEY` | generated | Bearer token for `/mcp` and the REST API |
| `GIT_TOKEN` | empty | Optional token for private GitHub/GitLab/Bitbucket repos (read access is enough) |
| `OPENAI_API_KEY` | empty | Optional. Without a model, Repowise builds every analysis layer and a template wiki with no LLM calls. With a key, the first index of each repo writes the wiki with a model (costs tokens) and chat works. |
| `OPENAI_BASE_URL` | empty | Optional OpenAI-compatible endpoint (OpenRouter, Groq, LiteLLM, Ollama…) |
| `REPOWISE_MODEL` | empty | Optional model name, e.g. `gpt-4o-mini` |
| `PORT` | `8080` | Public port for Caddy |

Other providers Repowise supports (Anthropic, Gemini, DeepSeek…) can be added later as their usual variables (`ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, …) or chosen in the dashboard under Settings → Models.

## After deploy

1. Open the Railway domain and log in as `admin` with `REPOWISE_PASSWORD` (service → Variables).
2. The repositories in `REPOWISE_REPOS` are cloned and indexed on first boot; a medium repo (about 150 files) takes about 3 minutes on 1 vCPU. Watch progress in the deploy logs or the dashboard.
3. Connect an agent to the MCP server (1 GB plans and up):

```json
{
  "mcpServers": {
    "repowise": {
      "type": "http",
      "url": "https://YOUR-DOMAIN/mcp",
      "headers": { "Authorization": "Bearer YOUR-REPOWISE_API_KEY" }
    }
  }
}
```

Claude Code: `claude mcp add --transport http repowise https://YOUR-DOMAIN/mcp --header "Authorization: Bearer YOUR-REPOWISE_API_KEY"`.

The server owns its clones (`managed_checkout`), so **Sync** in the dashboard fetches the remote and re-indexes. For automatic updates on push, add a GitHub webhook to `https://YOUR-DOMAIN/api/webhooks/github` and set `REPOWISE_GITHUB_WEBHOOK_SECRET` (see upstream's [AUTO_SYNC](https://github.com/repowise-dev/repowise/blob/v0.62.0/docs/scale/AUTO_SYNC.md)); the webhook path sits behind the dashboard login, so webhooks need the login in the URL or a proxy change.

## Memory

- **0.5 GB (Free/Trial):** the dashboard, API and indexing of small repositories work; the start script detects the limit, turns the MCP server off and does not auto-index (press **Index** in the dashboard). Indexing a ~150-file repo was killed at 0.5 GB in our test.
- **1 GB (Hobby and up):** everything, including the MCP server and medium repos (peak about 700 MB while indexing a 156-file repo). Large monorepos need more.

## Updates

This template builds from this repo's `main` branch. When we bump Repowise, Railway shows deployers an update notice; read `CHANGELOG.md` first, then apply it from the Railway dashboard. Data on the volume is kept.

## Licence

Repowise is AGPL-3.0 (commercial licence available from upstream). This wrapper only packages the unmodified release.
