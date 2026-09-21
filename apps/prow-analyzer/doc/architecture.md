# Prow Analyzer -- Usage and Architecture

> Looking for how to *use* the tool (quick start, limitations, best practices,
> review/undo, data handling, RBAC, contacts)? See the
> **[User Guide](user-guide.md)**. This document covers architecture and
> deployment internals.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
  - [System Diagram](#system-diagram)
  - [Components](#components)
  - [MCP Protocol Flow](#mcp-protocol-flow)
  - [Design Decisions](#design-decisions)
- [Configuration](#configuration)
  - [Environment Variables](#environment-variables)
  - [CLI Flags](#cli-flags)
  - [Bot Flags](#bot-flags)
  - [Prompt Template](#prompt-template)
  - [Recognized Prow URL Patterns](#recognized-prow-url-patterns)
- [Usage](#usage)
  - [CLI](#cli)
  - [Slack Bot](#slack-bot)
- [Deployment](#deployment)
  - [Prerequisites](#prerequisites)
  - [Slack App Setup](#slack-app-setup)
  - [Option 1: Run Locally](#option-1-run-locally)
  - [Option 2: OpenShift Deployment](#option-2-openshift-deployment)
  - [Updating a Running Deployment](#updating-a-running-deployment)
- [Development](#development)
  - [Project Structure](#project-structure)
  - [Building](#building)
  - [Testing](#testing)
  - [Dependencies](#dependencies)
  - [Container Image](#container-image)
- [Troubleshooting](#troubleshooting)
  - [Diagnosing Failures](#diagnosing-failures)
  - [Error Reference](#error-reference)
  - [Bot Not Responding](#bot-not-responding)
  - [Exec Format Error](#exec-format-error)
  - [Queue Full](#queue-full)
- [Known Issues](#known-issues)
  - [Deployment command / binary-name mismatch](#deployment-command--binary-name-mismatch)
  - [PROMPT_TEMPLATE env var is not consumed](#prompt_template-env-var-is-not-consumed)

---

## Overview

Prow Analyzer automates the analysis of Prow CI job failures by querying Red Hat's ship-help MCP (AI helpdesk). Ship-help has access to Jira issues, GitHub repositories, build logs, test results, Firewatch triage data, Slack discussions, internal documentation, and historical failure patterns.

The project ships two binaries:

- **`prow-analyzer--cli`** -- Analyze a single Prow job URL from the command line.
- **`prow-analyzer--bot`** -- A Slack bot that monitors channels and auto-analyzes Prow URLs posted by users, replying in-thread with root cause analysis, related Jira issues, recurring pattern detection, and recommended actions.

Analysis typically takes 2-4 minutes as ship-help searches across 9+ data sources.

---

## Architecture

### System Diagram

```
                         +---------------------+
                         |   Slack Workspace    |
                         |  (Socket Mode WSS)   |
                         +----------+----------+
                                    |
                           message events
                                    |
                                    v
+-----------------------------------+-----------------------------------+
|                         prow-analyzer--bot                            |
|                                                                       |
|  cmd/prow-analyzer--bot/main.go                                       |
|  +-- Parses flags / env vars                                          |
|  +-- Creates Slack socket-mode client                                 |
|  +-- Routes EventsAPI callbacks to handler                            |
|                                                                       |
|  pkg/slack/handler/                                                   |
|  +-- Filters: callback type, message type, bot msgs, channel ACL      |
|  +-- Extracts Prow URL from message text                              |
|  +-- Semaphore-gated async dispatch (max 5 concurrent)                |
|  +-- Posts analysis result (or error) as thread reply                  |
|                                                                       |
|  pkg/analyzer/                                                        |
|  +-- MCP session lifecycle (initialize, cache, invalidate, recover)   |
|  +-- JSON-RPC over SSE request/response                               |
|  +-- Prow URL regex extraction                                        |
|  +-- Slack response formatting                                        |
+-----------------------------------+-----------------------------------+
                                    |
                           JSON-RPC / SSE
                                    |
                                    v
                         +---------------------+
                         |   ship-help MCP      |
                         |   (AI helpdesk)      |
                         +---------------------+
                                    |
                    +---------------+---------------+
                    |       |       |       |       |
                  Jira   GitHub  Build   Fire-   Slack
                 issues   PRs    logs   watch  discussions
```

### Components

**CLI entrypoint** (`cmd/prow-analyzer--cli/main.go`)

Standalone command-line tool for one-off analysis. Parses flags, creates an Analyzer instance, calls `AnalyzeFailure`, and prints the result to stdout. Exits with code 1 on error. Requires exactly two positional arguments: the command `analyze` and a Prow URL.

**Bot entrypoint** (`cmd/prow-analyzer--bot/main.go`)

Long-running Slack bot. Creates a Slack client in Socket Mode (outbound WebSocket), creates an Analyzer and Handler, then enters the event loop. Events are acknowledged immediately via `socketClient.Ack()` and analysis runs asynchronously. Debug logging is enabled for both the Slack client and socket-mode client.

**Analyzer package** (`pkg/analyzer/analyzer.go`)

The core MCP client. Key responsibilities:

- **Session management** -- Initializes an MCP session on first use, caches the session ID, and automatically recovers from stale sessions. The `ensureSession` method acquires `initMtx` and initializes only if `initialized` is false. The `invalidateSession` method resets this flag. Both methods are goroutine-safe.

- **Request/response** -- Builds JSON-RPC 2.0 requests, sends them as HTTP POST with SSE accept header, and reads the response from an SSE stream. The `readSSEData` function scans line by line, skipping empty lines and SSE comment/ping lines (lines starting with `:`), and returns the first `data:` payload.

- **Session recovery** -- `AnalyzeFailure` calls `doAnalysis`. If the error contains "Session not found", it calls `invalidateSession`, re-initializes via `ensureSession`, and retries `doAnalysis` exactly once. This handles the case where the MCP server expires a session after a timeout.

- **URL extraction** -- `ExtractProwURL` uses a compiled regex to match Prow URLs from `prow.ci.openshift.org` and `deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com`. It handles Slack link formatting (`<url|label>`), Markdown links, trailing punctuation, and whitespace-terminated URLs.

- **Response formatting** -- `FormatSlackResponse` wraps the analysis text in Slack mrkdwn with a header and duration footer. Guards against nil results.

- **HTTP client** -- Uses `http.Client` with a 600-second timeout. Optionally skips TLS verification when `TLS_INSECURE_SKIP_VERIFY=true`. The client is injected via the `HTTPDoer` interface to enable testing.

- **Dependency injection** -- `jsonMarshal` and `newRequest` functions are injected fields, allowing tests to exercise error paths that are otherwise unreachable (e.g., `json.Marshal` failure, `http.NewRequestWithContext` failure).

**Slack handler package** (`pkg/slack/handler/handler.go`)

Implements the `PartialHandler` interface with `Handle` and `Identifier` methods. The `Handle` method applies a filter chain before dispatching:

1. Event must be `CallbackEvent` type (not URL verification, etc.)
2. Inner event must be `MessageEvent` (not app mention, reaction, etc.)
3. Message must not be from a bot (`event.BotID == ""`) to prevent loops
4. Channel must be in the `monitoredChannels` map
5. Message text must contain a recognized Prow URL

If all filters pass, the handler attempts to acquire a semaphore slot (buffered channel of size 5). If acquired, `analyzeAndRespond` runs in a goroutine. If the semaphore is full, a "queue full" message is posted to the user immediately.

`analyzeAndRespond` releases the semaphore slot on return via `defer`, calls `analyzer.AnalyzeFailure`, and posts the result (or a generic error message) as a thread reply using `slack.MsgOptionTS`.

**Container image** (`image/container/prow-analyzer/`)

Multi-stage Dockerfile:
- Builder: `rhel-9-golang-1.25-openshift-4.22` -- vendors dependencies and compiles both binaries.
- Runtime: `base-rhel9` -- copies binaries to `/usr/bin/`, runs as UID 1000.

The Makefile supports `build`, `push`, and `clean` targets with configurable `IMAGE_REGISTRY`, `IMAGE_NAMESPACE`, `IMAGE_NAME`, and `IMAGE_TAG`. The `BUILDFLAGS` variable passes flags to `podman build` (e.g., `--platform linux/amd64`).

**OpenShift deployment** (`deploy/openshift/deployment.yaml`)

Defines four resources in a single file:
- `Namespace` (default: `prow-analyzer`)
- `Secret` (`prow-analyzer-secrets`) -- ship-help token, Slack bot token, Slack app token
- `ConfigMap` (`prow-analyzer-config`) -- MCP URL, monitored channels, prompt template
- `Deployment` (`prow-analyzer-bot`) -- single replica, non-root security context, liveness probe via `pgrep`, resource limits (128-512Mi memory, 100-500m CPU)

**Slack app manifest** (`deploy/slack/manifest.yaml`)

Defines the Slack app configuration for import at https://api.slack.com/apps. Bot scopes: `channels:history`, `chat:write`. Socket Mode enabled. Subscribes to `message.channels` events.

### MCP Protocol Flow

**Step 1: Initialize session**

```
POST <mcp-url>
Content-Type: application/json
Authorization: Bearer <token>

{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": { "name": "prow-analyzer", "version": "1.0" }
  }
}

Response: 200 OK
Header: Mcp-Session-Id: <session-id>
Body: {"jsonrpc":"2.0","id":0}
```

**Step 2: Call ask_persona**

```
POST <mcp-url>
Content-Type: application/json
Authorization: Bearer <token>
Mcp-Session-Id: <session-id>
Accept: application/json, text/event-stream

{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "ask_persona",
    "arguments": { "question": "<prompt with job URL>" }
  }
}

Response: 200 OK (text/event-stream)
: ping - 2026-08-10
: ping - 2026-08-10
data: {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"<analysis>"}]}}
```

**Step 3: Session recovery (automatic)**

If step 2 returns `HTTP 404` with `{"error":{"message":"Session not found"}}`, the analyzer:
1. Invalidates the cached session (`initialized = false`)
2. Re-runs step 1 to get a new session ID
3. Retries step 2 exactly once with the new session

### Design Decisions

**Socket Mode over webhooks.** The bot uses Slack's WebSocket-based Socket Mode instead of HTTP webhooks. This eliminates the need for a public ingress endpoint or route -- the bot runs behind the firewall with outbound-only connections. The tradeoff is a persistent WebSocket connection, but this is well-suited for a single-replica deployment.

**Semaphore-gated concurrency.** A buffered channel of size 5 limits concurrent MCP requests. This prevents overwhelming ship-help when many Prow URLs are posted simultaneously. Excess requests are immediately rejected with a user-visible "queue full" message rather than queued indefinitely, so users know to retry.

**Async analysis.** Each analysis runs in a goroutine spawned by the handler. The Slack event is acknowledged immediately so the 3-second Socket Mode ack deadline is never hit. The goroutine posts the result (or error) as a thread reply when complete.

**Session recovery.** MCP sessions can expire on the server side, particularly after the 600-second HTTP client timeout kills a long-running SSE stream. Without recovery, the bot would return "Session not found" errors indefinitely until restarted. The retry-once approach handles this transparently.

**Bot message filtering.** All messages with a non-empty `BotID` are ignored. This prevents infinite loops where the bot's own thread replies (which contain Prow URLs in the analysis) trigger new analyses.

**Single prompt template.** The `{job_url}` placeholder in the configurable prompt template is replaced with the actual URL. This allows operators to tune what ship-help returns without code changes.

---

## Configuration

### Environment Variables

| Variable | Required | Used By | Description |
|---|---|---|---|
| `SHIP_HELP_MCP_URL` | Yes | CLI, Bot | Ship-help MCP endpoint URL |
| `SHIP_HELP_MCP_TOKEN` | Yes | CLI, Bot | Bearer token for MCP authentication |
| `SLACK_BOT_TOKEN` | Bot only | Bot | Slack bot token (`xoxb-...`) |
| `SLACK_APP_TOKEN` | Bot only | Bot | Slack app-level token for Socket Mode (`xapp-...`) |
| `MONITORED_CHANNELS` | Bot only | Bot | Comma-separated Slack channel IDs to monitor |
| `TLS_INSECURE_SKIP_VERIFY` | No | CLI, Bot | Set to `"true"` to skip TLS certificate verification |

All environment variables can be overridden by the corresponding command-line flag.

### CLI Flags

```
prow-analyzer--cli [flags] analyze <prow-url>

  -mcp-url    Ship-help MCP URL (default: $SHIP_HELP_MCP_URL)
  -token      Ship-help MCP token (default: $SHIP_HELP_MCP_TOKEN)
  -prompt     Analysis prompt template (default: "Analyze this Prow CI failure: {job_url}")
```

Exactly two positional arguments are required: the command (`analyze`) and the Prow job URL.

### Bot Flags

```
prow-analyzer--bot [flags]

  -slack-token   Slack bot token (default: $SLACK_BOT_TOKEN)
  -app-token     Slack app token for socket mode (default: $SLACK_APP_TOKEN)
  -mcp-url       Ship-help MCP URL (default: $SHIP_HELP_MCP_URL)
  -mcp-token     Ship-help MCP token (default: $SHIP_HELP_MCP_TOKEN)
  -channels      Comma-separated channel IDs (default: $MONITORED_CHANNELS)
  -prompt        Analysis prompt template (default: detailed template requesting
                 root cause, Jira issues, recurring patterns, and recommended actions)
```

### Prompt Template

The prompt is a string with a `{job_url}` placeholder that is replaced with the actual Prow URL before being sent to ship-help. The default bot prompt requests:

1. Root cause
2. Related Jira issues
3. Recurring pattern analysis
4. Recommended actions

Customize via the `-prompt` command-line flag.

> **Note:** The bot's `-prompt` flag defaults to a hardcoded string literal; it does **not** read an environment variable. The `PROMPT_TEMPLATE` env var / `prompt-template` ConfigMap key wired up in `deploy/openshift/deployment.yaml` is therefore **not currently consumed** by the bot. To change the deployed prompt today, pass `-prompt` via the container `args`. See [Known Issues](#known-issues) for details.

### Recognized Prow URL Patterns

The regex matches URLs from these domains:

- `https://prow.ci.openshift.org/view/gs/...`
- `https://prow.ci.openshift.org/?pr=...`
- `https://deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com/...`

Extraction correctly handles:

- Plain text URLs
- Slack-formatted links (`<url|label>`)
- Markdown links (`[label](url)`)
- Trailing punctuation (periods, parentheses, angle brackets)

---

## Usage

### CLI

```bash
export SHIP_HELP_MCP_URL="https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp"
export SHIP_HELP_MCP_TOKEN="eyJhbGc..."

./prow-analyzer--cli analyze https://prow.ci.openshift.org/view/gs/test-platform-results/logs/periodic-ci-stolostron-policy-collection-main-ocp4.22-interop-opp-aws/2066255424226594816
```

Example output:

```
Analyzing Prow failure...
URL: https://prow.ci.openshift.org/view/gs/...

**Root Cause:**
Test failure in openshift-tests due to timeout waiting for operator rollout.

**Related Jira Issues:**
- OCPBUGS-12345: Operator timeout in e2e tests (Open)
- OCPBUGS-11111: Similar timeout resolved by increasing wait time (Closed)

**Recurring Patterns:**
This failure pattern appears in 3 other jobs in the last 7 days, all in
the same test suite.

**Recommendations:**
1. Check cluster operator status at test start
2. Increase timeout from 5m to 10m
3. Review OCPBUGS-12345 for ongoing investigation

---
Analysis completed in 78.6s
```

### Slack Bot

Once running, the bot automatically responds to any message containing a Prow URL in a monitored channel. No commands or mentions are needed -- just paste a Prow URL.

The bot replies in a thread with:

```
Prow Analyzer Analysis

<analysis text from ship-help>

Analysis completed in 78.6s - Powered by ship-help MCP
```

If analysis fails, the user sees:

```
Analysis failed. Please retry shortly or contact maintainers if this persists.
```

If the analysis queue is full (5 concurrent analyses running), the user sees:

```
Analysis queue is currently full. Please retry in a moment.
```

---

## Deployment

### Prerequisites

- Go 1.22+ (for building from source)
- podman (for container builds)
- Access to quay.io (for pushing images)
- `oc` CLI (for OpenShift deployment)
- Ship-help MCP token (from `#ship-users` on Slack)
- Slack app with Socket Mode enabled

### Slack App Setup

1. Go to https://api.slack.com/apps and click **Create New App > From a manifest**.
2. Paste the contents of `deploy/slack/manifest.yaml`.
3. Enable **Socket Mode** under Settings > Socket Mode. Generate an App-Level Token with `connections:write` scope. This is your `xapp-...` token.
4. Under Settings > Install App, install to your workspace. Copy the Bot User OAuth Token. This is your `xoxb-...` token.
5. Invite the bot to each channel you want it to monitor (`/invite @Prow Analyzer`).

**Finding channel IDs:**

- From a Slack URL: `https://app.slack.com/client/T09NY5SBT/C12345678` -- the last path segment is the channel ID.
- Or right-click the channel name > View channel details > the ID is at the bottom of the popup.

### Option 1: Run Locally

```bash
export SHIP_HELP_MCP_URL="https://ship-help-mcp-continuous-release-tooling--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp"
export SHIP_HELP_MCP_TOKEN="$(cat /path/to/token.txt | tr -d '\n')"
export SLACK_BOT_TOKEN="xoxb-..."
export SLACK_APP_TOKEN="xapp-..."
export MONITORED_CHANNELS="C12345678"

cd apps/prow-analyzer
make build-bot
./prow-analyzer--bot
```

Test by posting a Prow URL in the monitored channel.

### Option 2: OpenShift Deployment

**Step 1: Build and push the container image.**

```bash
cd image/container/prow-analyzer

podman login quay.io

# --platform linux/amd64 is required when building on Mac ARM
make push BUILDFLAGS="--platform linux/amd64"

# Or with a specific tag
make push BUILDFLAGS="--platform linux/amd64" IMAGE_TAG=v1.1.0
```

The image pushes to `quay.io/<IMAGE_NAMESPACE>/prow-analyzer-bot:<IMAGE_TAG>`. The default namespace is set in the Makefile.

**Step 2: Create secrets in the target namespace.**

```bash
oc create secret generic prow-analyzer-secrets \
  --from-literal=ship-help-token="YOUR_TOKEN_HERE" \
  --from-literal=slack-bot-token="xoxb-..." \
  --from-literal=slack-app-token="xapp-..." \
  -n <your-namespace>
```

**Step 3: Update the deployment manifest.**

Edit `deploy/openshift/deployment.yaml`:

- Set `namespace` on all resources to your target namespace.
- Set `monitored-channels` in the ConfigMap to your actual channel IDs.
- Set the container `image` field to your registry path (e.g., `quay.io/chaclark/prow-analyzer-bot:latest`).

**Step 4: Deploy.**

```bash
oc apply -f deploy/openshift/deployment.yaml
```

**Step 5: Verify.**

```bash
# Check pod status
oc get pods -n <your-namespace> -l app=prow-analyzer-bot

# Tail logs
oc logs -f -n <your-namespace> -l app=prow-analyzer-bot

# Test by posting a Prow URL in a monitored channel
```

### Updating a Running Deployment

```bash
# Rebuild and push
cd image/container/prow-analyzer
make push BUILDFLAGS="--platform linux/amd64"

# Restart to pull the new image (when using :latest tag)
oc rollout restart deployment/prow-analyzer-bot -n <your-namespace>

# Or update to a new tag
oc set image deployment/prow-analyzer-bot -n <your-namespace> \
  container=quay.io/<namespace>/prow-analyzer-bot:<new-tag>
```

---

## Development

### Project Structure

```
apps/prow-analyzer/
  cmd/
    prow-analyzer--bot/main.go         Bot entrypoint (Slack socket mode)
    prow-analyzer--cli/main.go         CLI entrypoint (single URL analysis)
  pkg/
    analyzer/
      analyzer.go                      Core MCP client and analysis logic
      analyzer_test.go                 Unit tests (21 tests)
      mocks_test.go                    Test helpers and mock types
    slack/
      handler/
        handler.go                     Slack event handler
        handler_test.go                Handler unit tests (10 tests)
  deploy/
    openshift/deployment.yaml          OpenShift deployment manifest
    slack/manifest.yaml                Slack app manifest
  doc/
    architecture.md                    This file
    deployment.md                      Deployment quick-start guide
  Makefile                             Local build targets
  go.mod                              Go module definition

image/container/prow-analyzer/
  Dockerfile                           Multi-stage build (RHEL 9, Go 1.25)
  Makefile                             Container build/push targets
```

### Building

```bash
cd apps/prow-analyzer

# Build both binaries
make build

# Build individually
make build-cli
make build-bot

# Clean build artifacts
make clean
```

### Testing

```bash
# Run all tests with race detector
make test

# Run with coverage enforcement
make test-coverage

# Run specific tests
go test -v -run TestAnalyzeFailure ./pkg/analyzer/
go test -v -run TestHandle ./pkg/slack/handler/
```

Test coverage areas:

- **Analyzer (21 tests):** MCP session initialization and reuse, stale session recovery (404 retry), HTTP error handling (401, 403, 404, 500), SSE stream parsing (pings, data lines, empty streams, invalid JSON), context cancellation, dependency injection error paths (marshal, request builder, reader, client.Do), initialization failure retryability, Prow URL extraction (plain, Slack-formatted, trailing punctuation, deck-internal), response formatting (valid and nil results).

- **Handler (10 tests):** Constructor, identifier, event type filtering (non-callback, non-message), bot message rejection, unmonitored channel rejection, no-Prow-URL rejection, successful dispatch, end-to-end with mock MCP server, Slack post error handling, interface compliance.

### Dependencies

| Dependency | Version | Purpose |
|---|---|---|
| `github.com/slack-go/slack` | v0.14.0 | Slack API client and Socket Mode |
| `github.com/gorilla/websocket` | v1.5.0 | WebSocket support (transitive via slack-go) |
| Go standard library | 1.22+ | HTTP, JSON, SSE, TLS, regex, concurrency |

### Container Image

The Dockerfile uses a multi-stage build:

1. **Builder stage** (`registry.ci.openshift.org/ocp/builder:rhel-9-golang-1.25-openshift-4.22`) -- copies source, vendors dependencies (`go mod vendor`), and compiles both binaries.
2. **Runtime stage** (`registry.ci.openshift.org/ocp/4.22:base-rhel9`) -- copies binaries to `/usr/bin/`, sets user to `1000:1000`, sets entrypoint to `prow-analyzer--bot`.

Both binaries are included in the image. The CLI can be invoked inside the container as `/usr/bin/prow-analyzer--cli`.

Build context is `apps/prow-analyzer/` (the Makefile maps `../../../apps/prow-analyzer` relative to the Dockerfile location).

---

## Troubleshooting

### Diagnosing Failures

The Slack user sees a generic error message. The actual error is logged to stdout:

```bash
oc logs -n <namespace> -l app=prow-analyzer-bot | grep "PROW-ANALYZER ERROR"
```

Additional debug lines (SSE pings, data line sizes, analysis start markers) are also logged with the `PROW-ANALYZER` prefix:

```bash
oc logs -n <namespace> -l app=prow-analyzer-bot | grep "PROW-ANALYZER"
```

### Error Reference

| Log message | Cause | Fix |
|---|---|---|
| `initialize session: init request failed (HTTP 401)` | Invalid or expired MCP token | Get a new token from `#ship-users` |
| `initialize session: init request failed (HTTP 403)` | Token lacks permissions | Contact ship-help admins |
| `initialize session: send init request: <network error>` | MCP URL unreachable | Check network/DNS, verify `SHIP_HELP_MCP_URL` |
| `initialize session: no session ID in response` | MCP server didn't return `Mcp-Session-Id` header | Server-side issue -- contact ship-help team |
| `HTTP 404: ... Session not found` | Stale session after timeout | Auto-recovered by session retry (if this persists, the recovery logic isn't deployed) |
| `read SSE stream: reading stream: context deadline exceeded` | Analysis exceeded 600s HTTP client timeout | Retry; if persistent, ship-help MCP may be overloaded |
| `send request: <network error>` | Network error during analysis request | Check connectivity to MCP endpoint |
| `marshal request: ...` | Internal error serializing JSON | Should not occur in normal operation -- file a bug |
| `no content in response` | MCP returned empty result | Retry; may indicate a ship-help processing error |
| `MCP error <code>: <message>` | Ship-help returned a JSON-RPC error | Check the error message; may need to adjust the prompt |
| `parse response: ...` | MCP returned invalid JSON in SSE stream | Server-side issue -- contact ship-help team |

### Bot Not Responding

1. **Pod running?** `oc get pods -n <namespace> -l app=prow-analyzer-bot`
2. **Correct channel ID?** Verify the channel ID is listed in `MONITORED_CHANNELS`. Channel IDs look like `C1234ABCD`, not channel names.
3. **Bot invited to channel?** Slack doesn't deliver events for channels the bot hasn't joined. Run `/invite @Prow Analyzer` in the channel.
4. **URL recognized?** Only `prow.ci.openshift.org` and `deck-internal-ci.apps.ci.l2s4.p1.openshiftapps.com` URLs are detected.
5. **Message from a human?** Bot messages (including the bot's own replies) are ignored to prevent loops.
6. **Tokens valid?** Check logs for authentication errors. Tokens can expire or be revoked.

### Exec Format Error

```
exec container process `/usr/bin/prow-analyzer--bot`: Exec format error
```

The image was built for ARM (e.g., on a Mac with Apple Silicon) but the cluster runs x86_64. Rebuild with:

```bash
make push BUILDFLAGS="--platform linux/amd64"
```

Then delete the old pod so the deployment creates a new one with the correct image.

### Queue Full

```
Analysis queue is currently full. Please retry in a moment.
```

All 5 concurrent analysis slots are occupied. Wait for in-progress analyses to complete and retry. If this happens frequently, the semaphore size can be increased by changing the buffer size in `New` (`pkg/slack/handler/handler.go:127`):

```go
semaphore: make(chan struct{}, 5),  // increase this value
```

---

## Known Issues

These are gaps between the committed configuration and the code as of this writing. They do not affect the CLI or a locally-run bot invoked with explicit flags, but they will bite an OpenShift deployment made straight from the manifest.

### Deployment `command` / binary-name mismatch

`deploy/openshift/deployment.yaml` overrides the image entrypoint with:

```yaml
command: ["/usr/bin/prow-analyzer-bot"]   # single dash
```

The Dockerfile installs the binary as `/usr/bin/prow-analyzer--bot` (**double** dash) and sets it as the `ENTRYPOINT`. As written, the `command` override points at a path that does not exist, so the container fails to start (CrashLoopBackOff). The liveness probe has the same problem: `pgrep prow-analyzer-bot` will not match the running process named `prow-analyzer--bot`.

**Fix options (pick one):**

- Remove the `command:` line entirely and let the Dockerfile `ENTRYPOINT` run, and change the probe to `pgrep prow-analyzer--bot` (or `pgrep -f prow-analyzer--bot`).
- Or rename the binary to `prow-analyzer-bot` consistently in the Dockerfile, Makefile output, and probe.

### `PROMPT_TEMPLATE` env var is not consumed

The deployment sets `PROMPT_TEMPLATE` from the `prompt-template` ConfigMap key, but `cmd/prow-analyzer--bot/main.go` defines the prompt flag as:

```go
prompt = flag.String("prompt", "Analyze this Prow CI failure in detail. ...", "Analysis prompt template")
```

The default is a string literal, not `os.Getenv("PROMPT_TEMPLATE")`, and nothing else reads the env var. Editing the ConfigMap therefore has no effect on the deployed bot's prompt.

**Fix options (pick one):**

- Change the flag default to `os.Getenv("PROMPT_TEMPLATE")` (with a fallback literal), matching the pattern used for the other bot flags.
- Or pass the prompt explicitly through the container `args` in the deployment (`args: ["-prompt", "$(PROMPT_TEMPLATE)"]`).
