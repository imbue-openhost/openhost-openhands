# bottled-openhands

[OpenHands](https://github.com/OpenHands/OpenHands) (formerly OpenDevin)
— an autonomous AI software-engineering agent — packaged as a
self-hosted web app for
[Cloud in a Bottle](https://github.com/imbue-openhost/Cloud in a Bottle).

The Cloud in a Bottle zone owner opens `https://openhands.<zone>/` and lands in
the OpenHands web IDE with no login screen — Cloud in a Bottle SSO carries them
in. The agent talks to Anthropic Claude using an API key pulled from
the Cloud in a Bottle secrets service at boot.

Built on the classic single-container OpenHands **0.62** app image.

## Architecture

```
browser
  -> OpenHost router  (openhands.<zone>; verifies owner zone_auth,
                       stamps X-OpenHost-Is-Owner: true, blocks anon)
  -> container :8080  (nginx front proxy — Socket.IO WebSocket aware)
  -> 127.0.0.1:3000   (OpenHands uvicorn server: SPA + API + the
                       /socket.io agent event stream)
```

## Runtime: no host Docker socket required

Stock OpenHands defaults to `RUNTIME=docker`, which spawns a sibling
runtime container per conversation and therefore needs the host Docker
socket. Cloud in a Bottle does not expose the host Docker daemon to apps, so this
package runs **`RUNTIME=local`** (LocalRuntime): the agent's
action-execution server runs as a subprocess **inside this container**.
`tmux` is installed in the image because LocalRuntime drives the agent's
bash session through `libtmux` and refuses to start without it.

`SANDBOX_USER_ID=0` makes OpenHands run as container-root, which under
Cloud in a Bottle's rootless podman maps to an unprivileged host subuid — so it's
not real host root, and it avoids the base entrypoint's docker.sock
handling entirely (we bypass that entrypoint with our own supervisor).

**Trade-off:** with LocalRuntime the agent has unsandboxed shell access
to this container. That is acceptable here because the app is
single-tenant and strictly owner-only (see auth model). There is no
isolation between the agent and the app container — do not treat the
agent as untrusted.

## Auth model (Pattern E — no in-app auth, router + nginx gate)

The OpenHands OSS web UI has **no authentication** — no login page, no
session cookie gate. Two independent gates protect it:

1. **The Cloud in a Bottle router.** No `public_paths`, so the router rejects
   every anonymous request and only forwards the authenticated zone
   owner.
2. **nginx, in-container.** Denies any request lacking the
   router-stamped `X-OpenHost-Is-Owner: true` header (set by the router
   itself and stripped from client input, so unspoofable). Defence in
   depth against a future misconfigured `public_paths`.

OpenHands binds `127.0.0.1` only and is never reachable except through
nginx.

## Credential handling

The Anthropic API key is provisioned through the Cloud in a Bottle **secrets
service**, never baked into the image or written to disk:

1. The owner stores `ANTHROPIC_API_KEY` in the secrets app.
2. This app declares it consumes that key (`[[services.v2.consumes]]`
   with `grants = [{ key = "ANTHROPIC_API_KEY" }]`).
3. At boot, `start.sh` fetches it via the router service proxy
   (`POST $OPENHOST_ROUTER_URL/api/services/v2/call/secrets/get`) using
   the app's `OPENHOST_APP_TOKEN`, and exports it as `LLM_API_KEY` into
   the OpenHands process environment only.

If the secrets fetch fails, the app falls back to an `LLM_API_KEY` or
`ANTHROPIC_API_KEY` env var if present, and otherwise still starts so
the owner can see the UI and configure the key from the settings modal.

### Note on `settings.json`

OpenHands refuses to create a conversation until a persisted settings
record (`settings.json`) exists — env vars seed the in-memory config
but not this record. So at first boot `start.sh` writes
`state/settings.json` with the model and API key, letting the owner
skip the settings modal entirely. This is the **same** on-disk exposure
that occurs the moment the owner types the key into the OpenHands
settings UI (OpenHands persists it to `settings.json` either way), so
seeding it changes nothing about the threat model. That file lives
under `app_data`, which is only visible to apps the owner explicitly
grants `access_all_data` (e.g. a file-browser). Because the key is also
independently retrievable from the secrets service, `app_data` is not
its sole home. An existing `settings.json` is never overwritten, so
owner edits in the UI persist.

## Persistent state

Under `/data/app_data/openhands/`:

- `state/` — `FILE_STORE_PATH`: `settings.json`, conversations, event
  streams, OpenHands' own secrets store. Survives restarts.
- `workspace/` — the agent's working directory (`WORKSPACE_BASE`, also
  mounted into the runtime as `/workspace`).

## Changing the model

Change it in the OpenHands settings modal (persists in
`state/settings.json`), or set `LLM_MODEL` — default is
`anthropic/claude-sonnet-4-5-20250929` (LiteLLM `provider/model`
format).

## Cold start & the runtime warm pool

Two different "starting" phases exist:

1. **App import** — OpenHands takes up to a minute to finish importing.
   During that window nginx serves `/_healthz` (200) immediately and
   turns any upstream 5xx on `/` into a friendly "starting…" placeholder
   so the Cloud in a Bottle readiness probe doesn't flag the app as failed.

2. **Runtime start** — each conversation needs a LocalRuntime, whose
   cold start (~60-90s) boots a bash/tmux session, a jupyter kernel
   gateway, an openvscode-server, and a headless Chromium (the browser
   reset alone is ~30s). Done lazily on the first message, that shows up
   as the "Starting runtime… this may take 1-2 minutes" banner — and if
   several conversations initialise at once they contend for CPU and can
   blow past OpenHands' 120s readiness deadline, so the banner can appear
   to hang forever.

   To fix this, `start.sh` sets `INITIAL_NUM_WARM_SERVERS=1` and
   `DESIRED_NUM_WARM_SERVERS=1`: a runtime is pre-warmed at app boot and
   one is kept in reserve, so the owner's conversation attaches to an
   already-ready runtime almost instantly instead of paying the cold
   start. This is why the app is provisioned with extra memory/CPU (two
   runtimes can be live briefly during hand-off). After the app itself
   finishes importing, give it a further ~90s for the first warm runtime
   to become ready before starting a conversation.

## Deploying

```
oh app deploy https://github.com/imbue-openhost/bottled-openhands --name openhands --wait
```

Make sure `ANTHROPIC_API_KEY` is stored in the secrets app and that this
app is granted the `{ key = "ANTHROPIC_API_KEY" }` permission at install
time (approve the permission prompt, or pass `--grant-permissions-v2`).
