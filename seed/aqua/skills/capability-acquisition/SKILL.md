---
name: "capability-acquisition"
description: "Find or build the component a task needs — installed first, then the registry, then the builder — and get it set up without ever asking for a secret in chat"
---

# Capability Acquisition

**NEVER tell the user a service is unavailable without checking first.**
**ALWAYS use tools to take action. NEVER instruct users to run CLI commands.**

### Steps

1. `component(action: "list")` — what is installed
2. If a matching component is installed but needs setup: `request_setup(component_ref: "...")`
3. If not installed: `component(action: "search", query: "...")` — results include a `component_ref` field
4. If found: `component(action: "pull", reference: "<component_ref from search>")` then `request_setup(component_ref: "<component_ref>")`
5. If nothing found in the registry: put on the Builder role — `aqua_builder(task: "...")` — to scaffold a new component; the Builder handles setup and verification before handing back

### Component Types

- **catalyst** — API connectors and LLM providers. Use when the task needs to call an external service (Airtable, Notion, Slack, etc.) or invoke an LLM.
- **reagent** — Data transforms and utilities. Use when the task needs to parse, convert, validate, or process data (JSON parsing, CSV conversion, image resize, etc.).
- **formula** — Multi-step workflows. Use when the task chains several steps or components.
- **tincture** — Frontend displays (HTML/JS/CSS/React). Use when the user wants a dashboard, viewer, game, or visualization.

When searching, filter by type if you know what you need: `component(action: "search", query: "airtable", type: "catalyst")`.

**Tincture data flow**: Tinctures invoke backend **formulas** via `cyfr.invoke(ref, input)`. The formula executes server-side (secrets resolved, policy enforced) and returns the result. Tinctures declare their backend dependencies in `dependencies.static` in the manifest — these should be formulas, not raw catalysts/reagents. The invoke endpoint is a trust boundary: any client can bypass the tincture frontend and call declared dependencies directly, so other components must be wrapped in formulas that validate input and enforce business logic.

### Component Reference Format

References follow the pattern `type:publisher.name` (versionless, preferred) or `type:publisher.name:version` (pinned):
- Preferred: `catalyst:moonmoon69.airtable` (resolves to latest; secrets and policy persist across upgrades)
- Pinned: `catalyst:moonmoon69.airtable:0.1.0` (only for compile or when an exact version is needed)

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
→ Setup form opened — versionless ref so setup persists across upgrades

Step 5 (after setup completes, the task auto-resends):
→ execution(action: "run", reference: "catalyst:moonmoon69.airtable",
     type: "catalyst", input: { operation: "bases.list", params: {} })
→ Return results to user
```

After calling `request_setup`: tell the user the setup form has appeared, and where to get credentials if needed. The task auto-resends once setup is complete.

**NEVER ask the user to paste credentials/secrets/tokens into the chat.** All secret handling goes through the setup form UI.
