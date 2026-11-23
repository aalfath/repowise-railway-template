#!/bin/sh
# Repowise on Railway: start the API, web UI, MCP server and Caddy, and exit
# non-zero as soon as any of them stops, so Railway's ON_FAILURE restarts us.
set -eu

: "${PORT:=8080}"
: "${REPOWISE_USERNAME:=admin}"
DATA="${REPOWISE_DATA:-/data}"

fail() { echo "repowise-start: $*" >&2; exit 1; }
[ -n "${REPOWISE_API_KEY:-}" ] || fail "REPOWISE_API_KEY is empty. Set it (the template generates one)."
[ -n "${REPOWISE_PASSWORD:-}" ] || fail "REPOWISE_PASSWORD is empty. Set it (the template generates one)."
[ "${#REPOWISE_API_KEY}" -ge 16 ] || fail "REPOWISE_API_KEY must be at least 16 characters."

mkdir -p "$DATA/home" "$DATA/repos" "$DATA/home/.repowise"
export HOME="$DATA/home"
export REPOWISE_CONFIG_DIR="${REPOWISE_CONFIG_DIR:-$DATA/home/.repowise}"
export REPOWISE_WORKSPACE_CEILING="$DATA"

# Size worker pools from the service's memory limit, not the host's CPUs
# (Railway shows 32 CPUs inside a 1 vCPU service).
limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
case "$limit" in max|"") mem_mb=4096 ;; *) mem_mb=$((limit / 1048576)) ;; esac
if [ "$mem_mb" -lt 1500 ]; then cpus=1; elif [ "$mem_mb" -lt 3000 ]; then cpus=2; else cpus=4; fi
# Memory guard: the API, web UI and MCP server together need about 1 GB.
# Below ~900 MB (Railway's Free plan gives 0.5 GB) the remote MCP server is
# left off and the web UI and proxy run lean, so the dashboard still works.
if [ "$mem_mb" -lt "${REPOWISE_MCP_MIN_MB:-900}" ]; then
  small=1; : "${NODE_HEAP_MB:=96}"
  echo "repowise-start: only ${mem_mb} MB of memory: the remote MCP server (/mcp) is OFF. Give the service 1 GB (Hobby plan or higher) to turn it on." >&2
else
  small=0; : "${NODE_HEAP_MB:=192}"
fi
export GOMAXPROCS="${GOMAXPROCS:-$cpus}" GOMEMLIMIT="${GOMEMLIMIT:-48MiB}"
export REPOWISE_CPUS="${REPOWISE_CPUS:-$cpus}"
export REPOWISE_PARSE_WORKERS="${REPOWISE_PARSE_WORKERS:-$cpus}"
export REPOWISE_GIT_WORKERS="${REPOWISE_GIT_WORKERS:-$cpus}"
export REPOWISE_WORKSPACE_CONCURRENCY="${REPOWISE_WORKSPACE_CONCURRENCY:-1}"
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"
export UV_THREADPOOL_SIZE="${UV_THREADPOOL_SIZE:-2}"
# Empty optional variables must not look like configuration.
for v in OPENAI_API_KEY OPENAI_BASE_URL REPOWISE_MODEL REPOWISE_PROVIDER GIT_TOKEN; do
  eval "val=\${$v:-}"; [ -n "$val" ] || unset "$v"
done
echo "repowise-start: memory limit ${mem_mb} MB, workers ${cpus}"

REPOWISE_PASSWORD_HASH=$(caddy hash-password --plaintext "$REPOWISE_PASSWORD")
export REPOWISE_PASSWORD_HASH REPOWISE_USERNAME PORT

pids=""
cd "$DATA"
REPOWISE_HOST=127.0.0.1 python -m uvicorn repowise.server.app:create_app --factory \
  --host 127.0.0.1 --port 7337 --log-level warning --no-access-log &
pids="$pids $!"

(cd /opt/repowise-web && REPOWISE_API_URL=http://127.0.0.1:7337 HOSTNAME=127.0.0.1 PORT=3000 \
  NODE_OPTIONS="--max-old-space-size=${NODE_HEAP_MB} --max-semi-space-size=2" exec node server.js) &
pids="$pids $!"

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
pids="$pids $!"

# Clones the repos in REPOWISE_REPOS, registers and indexes them, then serves
# MCP for the first one. It never exits on a bad repo; it exits non-zero only
# if the MCP server itself dies.
REPOWISE_SMALL="$small" python /usr/local/bin/repowise-bootstrap &
pids="$pids $!"

trap 'kill $pids 2>/dev/null; exit 0' TERM INT  # a stop Railway asked for is not a crash
# BusyBox/dash have no reliable `wait -n`: poll the children instead.
while :; do
  for p in $pids; do
    if ! kill -0 "$p" 2>/dev/null; then
      wait "$p" 2>/dev/null && rc=0 || rc=$?
      echo "repowise-start: process $p stopped (exit $rc); stopping the service" >&2
      kill $pids 2>/dev/null || true
      exit 1
    fi
  done
  sleep 2
done
