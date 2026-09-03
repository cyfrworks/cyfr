---
name: "capability-acquisition"
description: "Find or build the component a task needs — installed first, then the registry, then the builder — and get it set up without ever asking for a secret in chat"
---

# Capability Acquisition

**NEVER tell the user a service is unavailable without checking first.**
**ALWAYS use tools to take action. NEVER instruct users to run CLI commands.**

### Steps

1. Check Runtime Context for installed components and MCP servers
2. If a matching component is installed but needs setup: `request_setup(component_ref: "...")`
3. If not installed: `component(action: "search", query: "...")` — results include a `component_ref` field
4. If found: `component(action: "pull", reference: "<component_ref from search>")` then `request_setup(component_ref: "<component_ref>")`
5. If nothing found in registry: `aqua_builder(task)` to scaffold a new component — the builder handles setup and verification before returning

### Component Types

- **catalyst** — API connectors and LLM providers. Use when the task needs to call an external service (Airtable, Notion, Slack, etc.) or invoke an LLM.
- **reagent** — Data transforms and utilities. Use when the task needs to parse, convert, validate, or process data (JSON parsing, CSV conversion, image resize, etc.).
- **formula** — Multi-step workflows and agents. Use when the task needs orchestration of multiple steps or sub-agents.
- **tincture** — Frontend displays (HTML/JS/CSS/React). Use when the user wants a dashboard, viewer, game, or visualization. Route to `aqua_artisan` (apps/dashboards) or `aqua_arcade` (games/3D).

When searching, filter by type if you know what you need: `component(action: "search", query: "airtable", type: "catalyst")`.

**Tincture data flow**: Tinctures invoke backend **formulas** via `cyfr.invoke(ref, input)`. The formula executes server-side (secrets resolved, policy enforced) and returns the result. Tinctures declare their backend dependencies in `dependencies.static` in the manifest — these should be formulas, not raw catalysts/reagents. The invoke endpoint is a trust boundary: any client can bypass the tincture frontend and call declared dependencies directly, so other components must be wrapped in formulas that validate input and enforce business logic.

**Tincture routing**: Route tincture work to `aqua_artisan` (dashboards, viewers, tools) or `aqua_arcade` (games, 3D). Both agents choose vanilla vs React based on complexity and library needs.

**Multi-component tincture projects**: When a tincture needs backend components that don't exist yet, delegate to both specialists in parallel — `aqua_builder` for the formula (and its catalyst dependencies), `aqua_artisan`/`aqua_arcade` for the tincture. The tincture's manifest declares the formula ref in `dependencies.static`, and the formula's manifest declares the catalysts it dispatches to.

### Component Reference Format

References follow the pattern `type:publisher.name` (versionless, preferred) or `type:publisher.name:version` (pinned):
- Preferred: `catalyst:moonmoon69.airtable` (resolves to latest, secrets/policy/OAuth persist across upgrades)
- Pinned: `catalyst:moonmoon69.airtable:0.1.0` (only for compile or when exact version needed)

**Always use versionless refs for execution, setup, and grants. Use versioned refs only from search/pull results when pulling a specific version.**

### Worked Example: "check my Airtable data"

```
Step 1: component(action: "list")
→ Check if an airtable catalyst is already installed
→ Not found locally

Step 2: component(action: "search", query: "airtable")
→ Result includes: { component_ref: "catalyst:moonmoon69.airtable:0.1.0", ... }

Step 3: component(action: "pull", reference: "catalyst:moonmoon69.airtable:0.1.0")
→ Pulled successfully (versioned ref from search result)

Step 4: request_setup(component_ref: "catalyst:moonmoon69.airtable")
→ Setup form opened — use versionless ref so setup persists across upgrades

Step 5 (after setup completes, task auto-resends):
→ execution(action: "run", reference: "catalyst:moonmoon69.airtable",
     type: "catalyst", input: { operation: "bases.list", params: {} })
→ Return results to user
```

After calling `request_setup`: tell the user the setup form has appeared, explain where to get credentials if needed. The task auto-resends once setup is complete.

**NEVER ask the user to paste credentials/secrets/tokens into the chat.** All secret handling goes through the setup form UI.

### OAuth Authorization (Gmail, Google Calendar, Slack, etc.)

Some components use OAuth instead of API keys. When you see `authorization_required` or `oauth_authorization_required` in an error, do NOT use `request_setup`. Instead:

1. **Retry the original request first** — tokens auto-refresh at the host level. If the token was just expired but has a refresh token, retrying will trigger an automatic refresh and succeed without user action.
2. **If retry still fails with `authorization_required`**: check `oauth(action: "status", component_ref: "...")` to confirm the token is truly missing or unrecoverable.
3. **Only then** call `oauth(action: "authorize", component_ref: "...", provider: "...")` — extract the component_ref and provider from the error.
4. The response contains an `authorize_url` — **show this URL to the user** and tell them to open it to grant access.
5. After the user completes consent in their browser, retry the original request.
