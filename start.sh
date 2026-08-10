#!/bin/bash
# Boot OpenHands + nginx front proxy for OpenHost.
#
# Topology:
#   browser
#     -> OpenHost router (subdomain openhands.<zone>; verifies owner
#        zone_auth, stamps X-OpenHost-Is-Owner: true, blocks anon)
#     -> container :8080          (nginx, WS-aware)
#     -> 127.0.0.1:3000           (OpenHands uvicorn server)
#
# Runtime:
#   RUNTIME=local -> the action-execution server runs as a subprocess in
#   THIS container (no host Docker socket needed). SANDBOX_USER_ID=0 so
#   the OpenHands process runs as container-root (which OpenHost maps to
#   an unprivileged host subuid under rootless podman) and never touches
#   the docker.sock logic in the base entrypoint (which we bypass anyway).
#
# Auth model (Pattern E):
#   OpenHands' OSS web UI has NO authentication. It binds loopback-only
#   here, so nothing outside the container reaches it directly. External
#   access flows through nginx, gated by (a) the OpenHost router, which
#   blocks anonymous traffic since there are no public_paths, and (b)
#   nginx's own X-OpenHost-Is-Owner: true requirement. Two gates guard
#   what is effectively remote shell access.
#
# Credential handling:
#   The Anthropic API key is fetched at boot from the OpenHost secrets
#   service via the router service proxy, using this app's
#   OPENHOST_APP_TOKEN, and exported as LLM_API_KEY into the OpenHands
#   process environment. It is never committed to the image.
#
#   OpenHands additionally persists the key into its own
#   state/settings.json under app_data: the server refuses to create a
#   conversation until a settings record exists, and it stores the key
#   there whether we seed it (seed_settings below) or the owner types it
#   into the settings UI. We therefore seed it deliberately rather than
#   force the owner through the modal. app_data is only visible to apps
#   the owner explicitly grants access_all_data (e.g. file-browser), and
#   the key is independently retrievable from the secrets service, so
#   app_data is not its sole home. The cleanup rm -f below removes only
#   ad-hoc credential files a prior iteration might have dropped; it is
#   NOT claiming settings.json is credential-free.

set -euo pipefail

PERSIST="${OPENHOST_APP_DATA_DIR:-/data/app_data/openhands}"

# OpenHands persistent state (settings.json, conversations, event
# streams) lives at FILE_STORE_PATH. The base image defaults it to
# /.openhands; we repoint it at the app_data-backed dir.
STATE_DIR="$PERSIST/state"
# The agent's working directory.
WORKSPACE_DIR="$PERSIST/workspace"

UPSTREAM_PORT=3000

# OpenHands LLM model. LiteLLM provider/model format. Overridable by the
# owner in the UI (the setting persists in settings.json under STATE_DIR).
DEFAULT_MODEL="${LLM_MODEL:-anthropic/claude-sonnet-4-5-20250929}"

# ---------------------------------------------------------------------------
# Remove ad-hoc credential files a prior iteration of THIS app might
# have dropped (e.g. a plain anthropic-api-key file). This does NOT
# touch settings.json, which OpenHands legitimately uses to store the
# key (see "Credential handling" above).
# ---------------------------------------------------------------------------
rm -f "$PERSIST/anthropic-api-key" "$PERSIST/api-key.txt" 2>/dev/null || true

mkdir -p "$STATE_DIR" "$WORKSPACE_DIR"

# ---------------------------------------------------------------------------
# Seed the OpenHands settings record so the owner is NOT forced through
# the settings modal on first visit, and so conversations can be created
# immediately (the server refuses to create a conversation until a
# settings record exists — env vars alone are not enough:
# manage_conversations returns SETTINGS_NOT_FOUND otherwise).
#
# The settings store is a plain settings.json at FILE_STORE_PATH. We
# write it once with the model + API key; we NEVER overwrite an existing
# one, so any changes the owner makes in the UI persist. If no API key
# is available yet, we skip writing so the owner can configure it in the
# UI (and this app can be reloaded once the key is stored).
# ---------------------------------------------------------------------------
seed_settings() {
    local settings_file="$STATE_DIR/settings.json"
    if [ -f "$settings_file" ]; then
        echo "[start.sh] Existing settings.json found; leaving owner config untouched"
        return 0
    fi
    if [ -z "${1:-}" ]; then
        echo "[start.sh] No API key yet; skipping settings.json seed (configure in UI + reload)"
        return 0
    fi
    MODEL="$DEFAULT_MODEL" APIKEY="$1" python3 - "$settings_file" <<'PY'
import json
import os
import sys

dest = sys.argv[1]
# Mirror the fields OpenHands' Settings model persists. The api key is
# written in cleartext because OpenHands' FileSettingsStore reads it
# back through a SecretStr and expects the raw value on disk — this is
# exactly what OpenHands writes when the owner enters the key in its
# settings UI. The file lives under app_data (owner-only; visible to
# other apps only if the owner grants access_all_data). The key is also
# independently retrievable from the secrets service, so settings.json
# is not its sole home. See README "Note on settings.json".
settings = {
    "language": "en",
    "agent": "CodeActAgent",
    "max_iterations": None,
    "security_analyzer": None,
    "confirmation_mode": False,
    "llm_model": os.environ["MODEL"],
    "llm_api_key": os.environ["APIKEY"],
    "llm_base_url": None,
    "remote_runtime_resource_factor": None,
    "secrets_store": {"provider_tokens": {}},
    "enable_default_condenser": True,
    "enable_sound_notifications": False,
    "enable_proactive_conversation_starters": True,
    "user_consents_to_analytics": None,
}
with open(dest, "w", encoding="utf-8") as fh:
    json.dump(settings, fh)
PY
    chmod 600 "$settings_file" 2>/dev/null || true
    echo "[start.sh] Seeded settings.json (model=$DEFAULT_MODEL)"
}

# nginx scratch dirs (all under /tmp per nginx.conf.tmpl).
mkdir -p /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi \
         /tmp/nginx-uwsgi /tmp/nginx-scgi

# ---------------------------------------------------------------------------
# Fetch the Anthropic API key from the OpenHost secrets service.
# ---------------------------------------------------------------------------
fetch_secret() {
    local router="${OPENHOST_ROUTER_URL:-}"
    local apptok="${OPENHOST_APP_TOKEN:-}"
    if [ -z "$router" ] || [ -z "$apptok" ]; then
        echo "[start.sh] secrets: OPENHOST_ROUTER_URL / OPENHOST_APP_TOKEN unset; skipping fetch" >&2
        return 1
    fi
    local resp
    resp="$(curl -fsS --max-time 15 \
        -H "Authorization: Bearer $apptok" \
        -H "Content-Type: application/json" \
        -X POST "$router/api/services/v2/call/secrets/get" \
        -d '{"keys":["ANTHROPIC_API_KEY"]}' 2>/dev/null)" || {
        echo "[start.sh] secrets: fetch call failed" >&2
        return 1
    }
    local key
    key="$(printf '%s' "$resp" | jq -r '.secrets.ANTHROPIC_API_KEY // empty' 2>/dev/null)" || key=""
    if [ -n "$key" ]; then
        printf '%s' "$key"
        return 0
    fi
    echo "[start.sh] secrets: ANTHROPIC_API_KEY not present in response" >&2
    return 1
}

LLM_KEY="$(fetch_secret || true)"
if [ -z "${LLM_KEY:-}" ] && [ -n "${LLM_API_KEY:-}" ]; then
    LLM_KEY="$LLM_API_KEY"
    echo "[start.sh] Anthropic API key taken from LLM_API_KEY env (secrets fetch unavailable)"
elif [ -z "${LLM_KEY:-}" ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    LLM_KEY="$ANTHROPIC_API_KEY"
    echo "[start.sh] Anthropic API key taken from ANTHROPIC_API_KEY env (secrets fetch unavailable)"
elif [ -n "${LLM_KEY:-}" ]; then
    echo "[start.sh] Anthropic API key loaded from secrets service"
else
    echo "[start.sh] WARNING: no Anthropic API key available; OpenHands will start but the agent cannot run until a key is configured (store ANTHROPIC_API_KEY in the secrets app, then reload this app)"
fi

# Seed settings.json so the first visit skips the settings modal and
# conversations can be created immediately.
seed_settings "${LLM_KEY:-}"

# ---------------------------------------------------------------------------
# Launch nginx first so /_healthz answers 200 within the cold-start
# grace window.
# ---------------------------------------------------------------------------
NGINX_CONF="/run/openhost-openhands-nginx.conf"
UPSTREAM_PORT="$UPSTREAM_PORT" python3 - "$NGINX_CONF" <<'PY'
import os
import sys

dest = sys.argv[1]
with open("/opt/openhost-openhands/nginx.conf.tmpl", encoding="utf-8") as fh:
    conf = fh.read()
conf = conf.replace("__UPSTREAM_PORT__", os.environ["UPSTREAM_PORT"])
with open(dest, "w", encoding="utf-8") as fh:
    fh.write(conf)
PY

echo "[start.sh] Starting nginx front proxy on :8080"
nginx -c "$NGINX_CONF" -g 'daemon off;' &
NGINX_PID=$!

# ---------------------------------------------------------------------------
# Launch the OpenHands server, loopback-bound.
# ---------------------------------------------------------------------------
# * RUNTIME=local             -> in-container runtime, no docker.sock.
# * SANDBOX_USER_ID=0         -> run as container-root (rootless-mapped).
# * FILE_STORE_PATH=$STATE_DIR-> persist settings/conversations.
# * WORKSPACE_BASE=$WORKSPACE_DIR + SANDBOX_VOLUMES -> agent working dir.
# * LLM_MODEL / LLM_API_KEY   -> seed the Anthropic config so the owner
#   doesn't have to type it into the settings modal.
# * SERVE_FRONTEND=true (base default) -> the SPA is served at /.
echo "[start.sh] Starting OpenHands (RUNTIME=local) on 127.0.0.1:$UPSTREAM_PORT"

export RUNTIME=local
export SANDBOX_USER_ID=0
# LocalRuntime spawns the action-execution server as a loopback-bound
# subprocess in THIS container and then HTTP-connects to it at
# $SANDBOX_LOCAL_RUNTIME_URL:<port>. The base image defaults that URL to
# http://host.docker.internal (correct only for the docker runtime,
# where the runtime lives in a sibling container). In-container that
# host doesn't resolve, so the connect times out and every conversation
# hangs in STARTING_RUNTIME. Point it at localhost. The code also
# special-cases 'localhost' in this URL when building the VS Code / app
# sub-URLs, so this is the value LocalRuntime expects.
export SANDBOX_LOCAL_RUNTIME_URL="http://localhost"
export RUN_AS_OPENHANDS=false
export FILE_STORE=local
export FILE_STORE_PATH="$STATE_DIR"
export WORKSPACE_BASE="$WORKSPACE_DIR"
export SANDBOX_VOLUMES="$WORKSPACE_DIR:/workspace:rw"
export LLM_MODEL="$DEFAULT_MODEL"
export LOG_ALL_EVENTS=true

# ---------------------------------------------------------------------------
# Runtime warm pool — this is what makes "Starting runtime..." fast.
# ---------------------------------------------------------------------------
# A LocalRuntime cold start is expensive (~60-90s): it launches the
# action-execution server subprocess, which boots a bash/tmux session,
# initialises the jupyter kernel gateway + openvscode-server plugins,
# and resets a headless Chromium (the browser reset alone is ~30s). Done
# lazily on the FIRST message of every conversation, that shows up as a
# long "Starting runtime..." wait — and if several conversations init at
# once they contend for CPU and can exceed the 120s readiness deadline,
# so the wait appears to never finish.
#
# Pre-warm ONE runtime at server boot and keep one warm in reserve, so a
# ready action server is waiting before the owner sends their first
# message and the conversation attaches to it almost instantly.
export INITIAL_NUM_WARM_SERVERS="${INITIAL_NUM_WARM_SERVERS:-1}"
export DESIRED_NUM_WARM_SERVERS="${DESIRED_NUM_WARM_SERVERS:-1}"
if [ -n "${LLM_KEY:-}" ]; then
    export LLM_API_KEY="$LLM_KEY"
fi
unset LLM_KEY

cd /app
# The OpenHands SPA + API is served by this uvicorn app. Bind loopback
# only; nginx is the sole external listener.
exec_openhands() {
    /app/.venv/bin/uvicorn openhands.server.listen:app \
        --host 127.0.0.1 \
        --port "$UPSTREAM_PORT" &
    OPENHANDS_PID=$!
}
exec_openhands

# ---------------------------------------------------------------------------
# Supervision: if either process dies, tear the other down and exit.
# ---------------------------------------------------------------------------
trap 'kill -TERM "$NGINX_PID" "$OPENHANDS_PID" 2>/dev/null; wait' TERM INT

set +e
wait -n "$NGINX_PID" "$OPENHANDS_PID"
EXIT_CODE=$?
set -e

echo "[start.sh] Child exited (code=$EXIT_CODE); shutting down"
kill -TERM "$NGINX_PID" "$OPENHANDS_PID" 2>/dev/null || true
wait || true
exit "$EXIT_CODE"
