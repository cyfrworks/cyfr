# Tincture Reference

Build, test, and deploy tinctures for CYFR. Tinctures are full-stack frontend experiences (HTML/JS/CSS) that invoke CYFR components as their backend. Unlike WASM components, tinctures run in the browser — they call backend components via `cyfr.invoke()` and CYFR handles execution, secrets, and policy enforcement server-side.

---

## Architecture

Tinctures are served at `/t/:publisher/:name`. They invoke backend components via `cyfr.invoke()` — CYFR validates the call against the manifest's dependency allowlist, executes the component server-side (resolving secrets, enforcing policy), and returns secret-masked output to the browser. Tinctures never see API keys, session tokens, or secrets.

### Private vs Public

Tinctures are **private by default** — only authenticated users can access them.

| | Private | Public |
|---|---|---|
| **Access** | Authenticated users only | Anyone |
| **How to set** | Default | `policy.set` or `tincture_visibility.set` MCP tool |
| **Invoke rate limit** | Policy-configured (default 100/min per user) | Policy-configured (default 100/min per IP) |
| **`cyfr.invoke()`** | Works the same | Works the same |

The `tincture.public` field in the manifest is a **metadata hint only** — actual access control is managed via the policy system (`is_public` field). Use `policy.set` with `component_type: "tincture"` or the `tincture_visibility.set` convenience tool.

---

## Directory Layout

**Vanilla tincture** (no build step):

```
components/local/default/tinctures/local/stock-dashboard/1.0.0/
├── cyfr-manifest.json    ← type: "tincture"
├── index.html            ← entry point
├── app.js                ← application JavaScript
├── style.css             ← styles
├── public/
│   └── media/
│       ├── icon.svg          ← shown in Prism sidebar + Porta carousel (auto-discovered)
│       └── preview-1.svg     ← screenshot strip on the focused card (up to preview-6)
└── src/                  ← optional source for forking
```

**React tincture** (after `cyfr build compile`):

```
components/local/default/tinctures/local/stock-dashboard/1.0.0/
├── cyfr-manifest.json    ← type: "tincture", tincture.build.tool: "vite"
├── package.json          ← React + Vite + TypeScript dependencies
├── tsconfig.json         ← TypeScript config (strict mode)
├── vite.config.ts        ← Vite config (base: "./")
├── index.html            ← built entry point (from dist/, overwrites Vite source index.html)
├── assets/               ← built JS/CSS bundles with content hashes
│   ├── index-abc123.js
│   └── index-def456.css
├── public/
│   └── media/
│       ├── icon.svg          ← shown in Prism sidebar + Porta carousel (auto-discovered)
│       └── preview-1.svg     ← screenshot strip on the focused card (up to preview-6)
├── src/                  ← React/TypeScript source (not served — .tsx not in extension allowlist)
│   ├── main.tsx
│   ├── App.tsx
│   └── index.css
```

---

## Development Loop

### Vanilla Tinctures

```
1. Scaffold    cyfr new tincture stock-dashboard       (once — creates HTML/JS/CSS scaffold)
2. Edit        Edit index.html, app.js, style.css      (any web editor or IDE)
3. Register    cyfr register                           (index the tincture)
4. View        Open Prism at localhost:4001 → Tinctures tab, or visit /t/local/stock-dashboard
5. Iterate     Edit HTML/JS/CSS → reload browser (no compile step)
```

Vanilla tinctures have no compile step — edit files directly and reload.

### React Tinctures

```
1. Scaffold    cyfr new tincture stock-dashboard --template react   (once — creates React/TS/Vite project)
2. Edit        Edit src/App.tsx, add components                     (standard React + TypeScript)
3. Compile     cyfr build compile t:local.stock-dashboard:0.1.0     (npm install && vite build)
4. Register    cyfr register                                        (index the built output)
5. View        Open Prism at localhost:4001 → Tinctures tab
6. Iterate     Edit source → recompile → reload
```

React tinctures use TypeScript + Vite and require a build step. The build runs `npm install && npm run build` (which runs `tsc` then `vite build`) in a sandboxed temp directory, then writes the `dist/` output (static HTML/JS/CSS) back to the tincture's version directory. The served output is identical to a vanilla tincture — no JS runtime at serve-time.

Tinctures invoke backend components via `cyfr.invoke()` (the SDK is auto-injected at serve time). Declare backend dependencies in the manifest's `dependencies.static` section.

---

## Tincture Manifest

```json
{
  "name": "stock-dashboard",
  "type": "tincture",
  "version": "1.0.0",
  "publisher": "local",
  "description": "Stock analysis dashboard with TA indicators",
  "tags": ["finance", "stocks", "dashboard"],
  "category": "finance",

  "tincture": {
    "entry": "index.html",
    "icon": "📈",
    "tagline": "Real-time stock charts with TA indicators",
    "public": true,
    "window": {"width": 800, "height": 600, "resizable": true},
    "sandbox": {"allow_scripts": true, "allow_forms": false, "allow_same_origin": false},
    "connect": ["*.supabase.co"]
  },

  "dependencies": {
    "static": [
      {"ref": "f:local.stock-analysis", "optional": false, "reason": "Stock data + AI analysis"}
    ]
  }
}
```

### `tincture` Block

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `entry` | string | `"index.html"` | Entry point file |
| `icon` | string | `"palette"` | Glyph fallback used by the picker when no `public/media/icon.{svg,png}` exists. Accepts an emoji (e.g. `"🎮"`) or a Lucide icon name (e.g. `"palette"`) |
| `tagline` | string | — | Short one-line tagline shown under the title in the Porta tincture picker. Distinct from `description`, which is used as the card title |
| `public` | boolean | `false` | Metadata hint. Actual public access is controlled via the policy system (`is_public` field) — set with `policy.set` or `tincture_visibility.set` MCP tool |
| `build` | object | — | Build config. `{"tool": "vite"}` signals Locus to run npm+Vite build. Omit for vanilla tinctures |
| `window` | object | `{}` | Shell window hints: `width`, `height`, `resizable`, `singleton` |
| `sandbox` | object | `{}` | iframe sandbox config — `allow_scripts` only (no `allow_same_origin`) |
| `connect` | string[] | `[]` | External domains for CSP `connect-src` (e.g., `["*.supabase.co"]`). Enables client-side SDK access to external services |

### Media Convention

CYFR auto-discovers tincture media from a fixed `public/media/` layout. **No manifest fields needed** — drop the files in the right slots and the picker (Prism sidebar + Porta carousel) finds them.

```
components/local/default/tinctures/local/{name}/{version}/
└── public/
    └── media/
        ├── icon.svg          ← OR icon.png  (svg preferred)
        ├── preview-1.svg     ← OR preview-1.png
        ├── preview-2.svg     ← up to preview-6.{svg,png}
        └── ...
```

| Slot | Path | Notes |
|------|------|-------|
| Icon | `public/media/icon.svg` (or `.png`) | Rendered 20×20 in Prism sidebar, 48×48 in the Porta info bar, and up to 192×192 as the in-stage fallback when a tincture has no previews. SVG strongly preferred — scales crisply at every size. |
| Previews | `public/media/preview-1.svg` … `preview-6.svg` (or `.png`) | Up to 6 numbered slots. Shown one at a time in the Porta preview stage; ↑/↓ cycles through them. Add them in order; gaps are skipped. |

**Preview dimensions and aspect ratios:** the Porta preview stage is a fixed 16:9 landscape container, and previews are *contained* (not cropped) — so any aspect ratio works without trimming. Anything wider or taller than 16:9 is letterboxed against a softly-blurred copy of the image, which makes the bars look intentional. Recommended:

- **16:9 landscape** (e.g. 1280×720, 1920×1080): fills the stage edge-to-edge, the most polished look.
- **Other landscape** (4:3, 3:2): small letterbox bars top/bottom, still looks great.
- **Portrait** (9:16, 3:4): pillarboxed with blurred backdrop — works fine for screenshots from a portrait/mobile-style tincture.
- **Square** (1:1): pillarboxed slightly. Fine for icon-style art.
- **Avoid extremely wide** (e.g. 21:9 ultrawide) or **extremely tall** (e.g. infinite-scroll captures) — they'll either letterbox heavily or shrink the focal area.

Both SVG and PNG are accepted. Keep individual files under ~500 KB to keep the picker snappy on first load.

**Why `public/`?** Vanilla tinctures get a regular subdirectory; React tinctures use Vite's existing `public/` convention (Vite copies it to dist on build, but the source files at `public/media/...` survive untouched, so the discovery helper finds them either way — no `vite.config.ts` changes needed).

**Why SVG first?** SVG renders crisply from the 20px sidebar entry to the 160px carousel card without any rasterization artifacts. PNG is the supported fallback for design tools that don't export SVG.

**`cyfr new tincture`** scaffolds both placeholder files for you. Replace them with your real artwork — the picker updates automatically on the next refresh, no manifest edits.

**Escape hatch for non-standard layouts:** if you must keep media files outside `public/media/`, the legacy `tincture.media.icon` and `tincture.media.previews` manifest fields still work and override discovery. You almost certainly don't need them — and the docs and scaffold no longer mention them for new tinctures.

### `dependencies.static` Block

**`dependencies.static`** — declares which backend components the tincture can invoke:

| Field | Type | Description |
|-------|------|-------------|
| `ref` | string | Component reference (versionless preferred, e.g. `formula:local.stock-analysis`) — use `type:ns.name:version` only when pinning for reproducibility |
| `optional` | boolean | `false` = required for deployment |
| `reason` | string | Why this dependency is needed |

The dependency list acts as the **invoke allowlist** — `cyfr.invoke()` calls to unlisted components are rejected server-side.

---

## Cyfr SDK (`cyfr.js`)

The SDK is **auto-injected** into every tincture's `<head>` at serve time — no `<script>` tag needed. `window.cyfr` is always available when your app code runs. A per-request nonce secures the inline script via CSP.

**API:**

| Function | Description |
|----------|-------------|
| `cyfr.mode` | `"shell"` or `"public"` — the SDK detects context automatically |
| `cyfr.invoke(reference, input)` | Invoke a backend component. Returns `Promise<{status, output, execution_id, duration_ms}>` |
| `cyfr.ready()` | Signal the shell that the tincture has finished initializing |
| `cyfr.setTitle(title)` | Update the window title in the Prism shell |
| `cyfr.close()` | Close this tincture's window |
| `cyfr.getContext()` | Get `{tincture_id, window_id}` from the shell |
| `cyfr.on(event, callback)` | Subscribe to shell events |
| `cyfr.off(event, callback)` | Unsubscribe from shell events |

**Example**:

```javascript
// Invoke a formula
const result = await cyfr.invoke("f:local.stock-analysis", { symbol: "AAPL" });
console.log(result.status);       // "completed"
console.log(result.output);       // {symbol: "AAPL", price: 185.42, ...}
console.log(result.execution_id); // "exec_abc123..."
console.log(result.duration_ms);  // 1234
```

**Security**: The component's API keys and secrets are resolved server-side — they never appear in the response. `cyfr.invoke()` returns only the component's output (secret-masked).

**Auth patterns**: Pass auth context (JWTs, tokens) as part of the input — the backend component verifies them server-side:

```javascript
// Supabase auth: pass JWT for the formula to verify server-side
const jwt = supabase.auth.session()?.access_token;
const data = await cyfr.invoke("f:local.supabase-rpc", {
  jwt: jwt,
  action: "get_user_data"
});
```

---

## Sandbox Constraints

Tinctures run in a sandboxed iframe (`sandbox="allow-scripts"`, no `allow-same-origin`). This blocks many standard browser APIs:

| Blocked | Why | Use Instead |
|---------|-----|-------------|
| **Inline `<script>` blocks** | **CSP `script-src: 'self' 'nonce-...'` — only the SDK injection gets the nonce** | **Put all JS in external `.js` files and load with `<script src="app.js"></script>`** |
| `eval()`, `new Function()` | CSP blocks dynamic code execution | Not available — restructure code to avoid eval |
| `fetch()` to **undeclared** external URLs | CSP `connect-src` only includes declared domains | Declare domains in `tincture.connect` or use `cyfr.invoke()` |
| `localStorage` / `sessionStorage` | Opaque origin (no `allow-same-origin`) | Store state in memory or via backend components |
| Cookies | Opaque origin | Not needed — auth handled via `cyfr.invoke()` or client-side SDKs |
| `<script src="https://cdn...">` | CSP `script-src: 'self' 'nonce-...'` | Bundle deps locally (Vite for React, local `.js` files for vanilla) |
| Dynamic `import()` from CDN | CSP `script-src: 'self'` | Use local modules or bundle with Vite |
| `window.parent` access | Cross-origin sandbox | `cyfr.*` SDK methods (use postMessage internally) |
| `navigator.geolocation` | Permissions blocked in sandbox | Not available |

**CRITICAL: No inline `<script>` blocks.** The CSP only grants a nonce to the auto-injected SDK. Any `<script>` block you write in `index.html` will be **silently blocked** — no error, no console warning, just nothing executes. Always use external script files: `<script src="app.js"></script>`. Inline `<style>` blocks ARE allowed (`style-src 'unsafe-inline'`).

**External connectivity**: By default, `connect-src` is `'self'` only. To use client-side SDKs (Supabase JS, Stripe, etc.), declare the domains in `tincture.connect` in the manifest — they'll be added to the CSP.

**All JavaScript must be in external `.js` files** within the tincture directory. For vanilla tinctures, add `.js` and `.css` files and reference them with `<script src>` and `<link rel="stylesheet">` tags. For React tinctures, Vite bundles everything into `assets/` during build.

---

## Limits

| Limit | Value | What happens |
|-------|-------|-------------|
| Max query rows | 1,000 | Response includes `truncated: true`, excess rows dropped |
| Query timeout | 2,000ms | Returns `"query timeout exceeded"` error |
| DB size | 50MB | Writes rejected beyond limit |
| Rate limit | 100 req/min (default, policy-configurable) | HTTP 429 / `"rate_limited"` error. Public: per IP. Private: per user |
| SDK request timeout | 30 seconds | Promise rejects with `"Request timed out"` |
| Query cache TTL | 30s default | Override with `cache_ttl` in manifest query definition |
| Allowed asset extensions | `.html .js .css .json .svg .png .jpg .jpeg .gif .ico .woff .woff2 .ttf .eot .map` | Other extensions return 404 |
| Blocked files | `data.db`, `cyfr-manifest.json`, `schema.sql`, dotfiles | Always 404 |

---

## Third-Party Libraries

CDN `<script>` tags are blocked by CSP. All libraries must be served as local files.

**React tinctures** (recommended when libraries are needed):
Add dependencies to `package.json` and import normally. `cyfr build compile` runs `npm install` and Vite bundles everything — fully autonomous, no manual steps.

**Vanilla tinctures**:
Download the library's standalone/UMD/IIFE build and save it in the tincture directory. Reference with a `<script>` tag before your app script:

```html
<script src="three.module.js"></script>
<script src="app.js"></script>
```

If the tincture needs multiple npm-ecosystem libraries, prefer the React template — it handles dependencies automatically via `npm install` during compile.

---

## Complete Vanilla Example

A minimal working `app.js` showing the full lifecycle — loading, fetching, rendering, error handling, and refresh:

```javascript
// app.js
const app = document.getElementById("app");
let loading = true, error = null, rows = [];

function render() {
  if (loading) { app.innerHTML = '<p class="loading">Loading…</p>'; return; }
  if (error) {
    app.innerHTML = `<p class="error">${error}</p><button onclick="loadData()">Retry</button>`;
    return;
  }
  if (!rows.length) {
    app.innerHTML = '<p>No data yet — call cyfr.invoke() to load some.</p>';
    return;
  }
  const cols = Object.keys(rows[0]);
  app.innerHTML = `
    <button onclick="loadData()">Refresh</button>
    <table>
      <thead><tr>${cols.map(c => `<th>${c}</th>`).join("")}</tr></thead>
      <tbody>${rows.map(r =>
        `<tr>${cols.map(c => `<td>${r[c] ?? ""}</td>`).join("")}</tr>`
      ).join("")}</tbody>
    </table>`;
}

async function loadData() {
  loading = true; error = null; render();
  try {
    const result = await cyfr.invoke("f:local.stock-analysis", { symbol: "AAPL" });
    rows = [result.output];  // Component returns data in output
  } catch (err) { error = err.message; }
  loading = false; render();
}

cyfr.ready();  // Signal shell that initialization started
loadData();
```

**Key patterns**:
- Call `cyfr.ready()` early — signals the shell that the tincture has started
- Access `result.output` — `cyfr.invoke()` returns `{status, output, execution_id, duration_ms}`
- Handle loading, error, and empty states
- Invoke formulas, not catalysts directly — formulas validate input and enforce business logic server-side
- Pass auth tokens as part of the input if the component needs user verification

---

## Complete React Example

A minimal `App.tsx` with full SDK type declarations and data loading:

```tsx
import { useState, useEffect, useCallback } from "react";

// Full Cyfr SDK type declaration — cyfr is auto-injected at serve time, do NOT import it
declare const cyfr: {
  mode: "shell" | "public";
  ready(): Promise<{ ok: true }>;
  query(name: string, params?: Record<string, unknown>): Promise<{
    data: Record<string, unknown>[];
    columns: string[];
    cached: boolean;
  }>;
  setTitle(title: string): Promise<{ ok: true }>;
  close(): Promise<{ ok: true }>;
  getContext(): Promise<{ tincture_id: string; window_id: string }>;
  on(event: string, callback: (data: unknown) => void): void;
  off(event: string, callback: (data: unknown) => void): void;
};

export default function App() {
  const [rows, setRows] = useState<Record<string, unknown>[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  const loadData = useCallback(async () => {
    setLoading(true); setError(null);
    try {
      const result = await cyfr.invoke("f:local.stock-analysis", { symbol: "AAPL" });
      setRows([result.output]);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
    setLoading(false);
  }, []);

  useEffect(() => { cyfr.ready(); loadData(); }, [loadData]);

  if (loading) return <p>Loading…</p>;
  if (error) return <div><p style={{color:"red"}}>{error}</p><button onClick={loadData}>Retry</button></div>;
  if (!rows.length) return <p>No data yet.</p>;

  const cols = Object.keys(rows[0]);
  return (
    <div>
      <button onClick={loadData}>Refresh</button>
      <table>
        <thead><tr>{cols.map(c => <th key={c}>{c}</th>)}</tr></thead>
        <tbody>{rows.map((r, i) => (
          <tr key={i}>{cols.map(c => <td key={c}>{String(r[c] ?? "")}</td>)}</tr>
        ))}</tbody>
      </table>
    </div>
  );
}
```

**React-specific notes**:
- `cyfr` is a global injected at serve time — do not import it. The `declare const cyfr` block above is the complete type declaration
- After editing source, compile with `cyfr build compile t:local.<name>:<version>` — runs `npm install && tsc && vite build`
- `vite.config.ts` must use `base: "./"` (the scaffold sets this correctly) so assets resolve from subpath routes
- Dev workflow: edit `src/*.tsx` → compile → reload browser. No local Vite dev server connects to the cyfr SDK

---

## Routes

All tinctures are served from a unified `/t/` path. Public tinctures are accessible by anyone; private tinctures require authentication.

| Route | Auth | Description |
|-------|------|-------------|
| `/t/:publisher/:name` | Optional | Serve tincture (see Private vs Public above) |
| `/t/:publisher/:name/*path` | None | Serve tincture static assets (JS, CSS, images) |

- Canonical routes are **versionless** — the server resolves the latest registered version
- Iframes get `sandbox="allow-scripts"` only (no `allow-same-origin`) — assets are served without cookie auth since sandboxed iframes cannot send cookies
- A `<base>` tag and the Cyfr SDK are injected into `<head>` at serve time (nonce-secured)

---

## Security Model

- **Invoke allowlist** — tinctures can only invoke components declared in `dependencies.static`
- **Scoped context** — invoke uses a tincture execution context, not the operator's session
- **No secrets in responses** — component output is secret-masked before returning to the browser
- **Sandbox iframe** — `allow-scripts` only, no `allow-same-origin`
- **Sensitive file denylist** — `cyfr-manifest.json`, `schema.sql`, dotfiles never served
- **Policy-managed** — tinctures use the same policy system as other component types for rate limits and visibility (`is_public`). Configurable via `policy.set` or `tincture_visibility.set` MCP tool
- **No `sessionStorage`/`localStorage`** — sandboxed iframes without `allow-same-origin` cannot access browser storage; store state in memory or via backend components
- **Rate limited** — default 100 req/min (policy-configurable). Public: per IP. Private: per user. Clamped by platform ceiling

### Invoke Formulas, Not Raw Catalysts

**Tinctures should invoke formulas — never declare catalysts directly in `dependencies.static`.**

The invoke endpoint is a trust boundary. Any client that can reach the tincture can call any component declared in `dependencies.static`, bypassing the tincture frontend entirely. Frontend validation (confirm dialogs, input sanitization, flow gates) provides zero protection — the server only checks that the reference is in the allowlist.

Formulas solve this by acting as a backend gateway:

```
AVOID:
  Tincture → cyfr.invoke("c:local.stripe-charge", input)
  ↑ Any client can call this directly, bypassing the UI

RECOMMENDED:
  Tincture → cyfr.invoke("f:local.purchase-flow", input)
                           ↓
                     Formula validates input, enforces business logic,
                     then dispatches to c:local.stripe-charge internally
```

Why formulas are safer:
- **The catalyst is unreachable** — it's not in the tincture's `dependencies.static`, so `can_invoke?` rejects direct calls
- **Input validation in WASM** — the formula validates and sanitizes before dispatching
- **Tool access control** — formulas have their own `allowed_tools` policy (deny-by-default)
- **Audit lineage** — sub-invocations track `parent_execution_id` for full call chain visibility
- **Dependency enforcement** — formulas fail at execution time if any declared dependency is missing

---

## Error Reference

| Error | Context | Fix |
|-------|---------|-----|
| `component not in dependencies` | Invoke ref not in manifest deps | Add the component to `dependencies.static` in `cyfr-manifest.json` |
| `Rate limit exceeded` | Public tincture hit rate limit | Wait for `Retry-After` header value. Limit is policy-configurable (default 100/min) |
| `rate_limited` | Private tincture hit rate limit | Reduce invoke frequency or batch requests in a formula. Limit is policy-configurable |
| `Request timed out` | SDK got no response in 30s | Check if shell is responsive, check component execution time |
| Blank page / nothing renders | Inline `<script>` blocked by CSP | Move all JS to external `.js` files |
| 404 on asset | File extension not in allowlist | Only `.html .js .css .json .svg .png .jpg .jpeg .gif .ico .woff .woff2 .ttf .eot .map` are served |

---

## Before Committing

- [ ] `cyfr-manifest.json` has `type: "tincture"` with valid `tincture` and `schema` blocks
- [ ] Entry file exists (default `index.html`)
- [ ] **No inline `<script>` blocks** — all JS in external `.js` files loaded via `<script src="...">`
- [ ] `cyfr.ready()` called in the external JS (SDK is auto-injected — no `<script>` tag needed for SDK)
- [ ] All queries use named params (`:param`), never string concatenation
- [ ] `tincture.public` matches intended visibility (actual access controlled via `policy.set` or `tincture_visibility.set` MCP tool)
- [ ] If public: tested both authenticated and unauthenticated access at `/t/:publisher/:name`
- [ ] For React tinctures: `vite.config.ts` uses `base: "./"` (required for subpath serving)
- [ ] For React tinctures: `cyfr build compile t:local.<name>:<version>` succeeds before registering
