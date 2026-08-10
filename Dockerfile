# OpenHands (formerly OpenDevin), packaged for OpenHost.
#
# Derives from the official OpenHands 0.62 app image and layers on:
#   * nginx      — SSE/WebSocket-aware front proxy on :8080
#   * tmux       — REQUIRED by RUNTIME=local (LocalRuntime drives the
#                  agent's bash session via libtmux; it errors at init
#                  if tmux is not on PATH). Not present in the base image.
#   * gosu, jq   — privilege drop helper + JSON parsing in start.sh
#   * curl       — secrets fetch (present in base, reinstalled to be safe)
#
# Topology:
#   browser
#     -> OpenHost router (subdomain openhands.<zone>; verifies owner
#        zone_auth, stamps X-OpenHost-Is-Owner: true, blocks anon)
#     -> container :8080          (nginx front proxy, WS-aware)
#     -> 127.0.0.1:3000           (OpenHands uvicorn server)
#
# The agent runs in LocalRuntime (RUNTIME=local): the action-execution
# server runs as a subprocess in THIS container, so no host Docker
# socket / docker-in-docker is needed. The trade-off is that the agent
# has unsandboxed shell access to this container — acceptable because
# the app is single-tenant and owner-only.

FROM docker.openhands.dev/openhands/openhands:0.62

USER root

# The base image is Debian-based (python:3.13 slim lineage). Install the
# extra runtime deps. tmux is the critical one for RUNTIME=local.
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
        nginx \
        tmux \
        gosu \
        jq \
        curl \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && tmux -V

# uv / uvx: OpenHands' default MCP integration shells out to `uvx` to
# launch stdio MCP servers (e.g. the optional Tavily search tool). It is
# not in the base image, so every runtime init logs a noisy
# "No such file or directory: 'uvx'" error. Installing uv removes that
# and enables those MCP tools if the owner ever configures a search key.
RUN curl -fsSL https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh \
 && uv --version && uvx --version

# ---------------------------------------------------------------------------
# Playwright Chromium for the agent's web-browsing tool.
# ---------------------------------------------------------------------------
# OpenHands' BrowserEnv launches a headless Chromium via Playwright when
# the runtime connects. The base image ships the playwright python
# package + driver but NOT the browser binary, so without this the
# server hangs ~200s on runtime connect and then fails
# (BrowserType.launch: Executable doesn't exist). Install the browser
# and its OS dependencies now, into the default cache
# (/root/.cache/ms-playwright) — the OpenHands process runs as
# container-root (SANDBOX_USER_ID=0), so root's cache is the right one.
# --with-deps pulls the apt libraries Chromium needs.
RUN /app/.venv/bin/playwright install --with-deps chromium \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# OpenVSCode Server for the OpenHands "VS Code" editor plugin.
# ---------------------------------------------------------------------------
# In non-headless (server) mode OpenHands always loads the VSCode plugin,
# which execs /openhands/.openvscode-server/bin/openvscode-server. That
# binary ships in the OpenHands *runtime* image, not the app image, so
# under RUNTIME=local it is missing -> the plugin launch fails and the
# action-execution server's plugin init times out (120s), leaving every
# conversation stuck in STARTING_RUNTIME. Install it at the exact path
# the plugin expects, mirroring the OpenHands runtime Dockerfile
# (gitpod-io/openvscode-server v1.98.2, matching the 0.62 runtime image).
ARG OPENVSCODE_RELEASE_TAG="openvscode-server-v1.98.2"
ENV OPENVSCODE_SERVER_ROOT=/openhands/.openvscode-server
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends wget \
 && arch="$(uname -m)" \
 && if [ "$arch" = "x86_64" ]; then arch="x64"; \
    elif [ "$arch" = "aarch64" ]; then arch="arm64"; fi \
 && wget -q "https://github.com/gitpod-io/openvscode-server/releases/download/${OPENVSCODE_RELEASE_TAG}/${OPENVSCODE_RELEASE_TAG}-linux-${arch}.tar.gz" \
 && tar -xzf "${OPENVSCODE_RELEASE_TAG}-linux-${arch}.tar.gz" \
 && mkdir -p /openhands \
 && rm -rf "${OPENVSCODE_SERVER_ROOT}" \
 && mv "${OPENVSCODE_RELEASE_TAG}-linux-${arch}" "${OPENVSCODE_SERVER_ROOT}" \
 && cp "${OPENVSCODE_SERVER_ROOT}/bin/remote-cli/openvscode-server" "${OPENVSCODE_SERVER_ROOT}/bin/remote-cli/code" \
 && rm -f "${OPENVSCODE_SERVER_ROOT}"*.tar.gz "${OPENVSCODE_RELEASE_TAG}-linux-${arch}.tar.gz" \
 && rm -rf /var/lib/apt/lists/*

# App files. Placed under /opt so they never collide with /app.
COPY start.sh          /opt/openhost-openhands/start.sh
COPY nginx.conf.tmpl   /opt/openhost-openhands/nginx.conf.tmpl
COPY proxy_common.conf /opt/openhost-openhands/proxy_common.conf
RUN chmod 0755 /opt/openhost-openhands/start.sh

# OpenHost-routed port (nginx front proxy). OpenHands' own port (3000)
# stays loopback-only.
EXPOSE 8080

# Override the base image's ENTRYPOINT/CMD entirely. Our start.sh is the
# supervisor; it invokes the OpenHands server itself (loopback-bound)
# and nginx.
ENTRYPOINT []
CMD ["/opt/openhost-openhands/start.sh"]
