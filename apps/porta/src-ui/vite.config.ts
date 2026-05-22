import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { VitePWA } from "vite-plugin-pwa";

// Proxy target for dev (`npm run dev`) — points at the local Cyfr / Prism.
// In the `porta` docker container (`vite preview`), the target is `cyfr:4000`
// on the compose network; see `preview.proxy` below.
const CYFR_API = process.env.CYFR_DEV_URL ?? "http://127.0.0.1:4000";
const CYFR_PRISM = process.env.CYFR_DEV_PRISM_URL ?? "http://127.0.0.1:4001";

export default defineConfig({
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      registerType: "autoUpdate",
      // Emit a separate registerSW.js (referenced via <script src>) instead of
      // an inline script, so a strict `script-src 'self'` CSP doesn't block it.
      injectRegister: "script",
      includeAssets: ["favicon.ico", "logo.png", "apple-touch-icon.png"],
      manifest: {
        name: "A.Q.U.A.",
        short_name: "AQUA",
        description: "Autonomous Query & Utility Assistant — CYFR client",
        theme_color: "#0b0f17",
        background_color: "#0b0f17",
        display: "standalone",
        start_url: "/",
        scope: "/",
        icons: [
          { src: "/icons/32x32.png", sizes: "32x32", type: "image/png" },
          { src: "/icons/128x128.png", sizes: "128x128", type: "image/png" },
          { src: "/icons/128x128@2x.png", sizes: "256x256", type: "image/png" },
          { src: "/icons/icon.png", sizes: "512x512", type: "image/png", purpose: "any maskable" },
        ],
      },
      workbox: {
        // Precache the built app shell; never serve API/SSE/tincture traffic
        // from the cache — those must always hit the network. Each matcher
        // mirrors the `Caddyfile` route + the `proxy` keys below so the same
        // request maps to cyfr everywhere: `/mcp` (incl. an incidental
        // query/subpath) is the cyfr MCP endpoint, but `/mcp-servers` (the
        // PWA page) is NOT caught and still gets the SPA fallback.
        globPatterns: ["**/*.{js,css,html,ico,png,svg,woff2}"],
        navigateFallbackDenylist: [/^\/mcp(\/|\?|$)/, /^\/api\//, /^\/auth\//, /^\/t\//],
        runtimeCaching: [],
      },
      devOptions: { enabled: false },
    }),
  ],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    // Vite proxy keys are prefix matchers (`/mcp` would also catch
    // `/mcp-servers`), so anchor them as RegExp. Vite tests the regex
    // against `req.url` (path + query), so these mirror the `Caddyfile`
    // routes and the workbox denylist above — same request, same target
    // everywhere:
    //   ^/mcp([/?]|$)    — the cyfr MCP endpoint (+ any query/subpath),
    //                      never the `/mcp-servers` PWA route
    //   ^/(api|auth|t)/  — sub-paths only, so bare `/t` can't match
    //                      `/tinctures`
    proxy: {
      "^/mcp([/?]|$)": { target: CYFR_API, changeOrigin: true },
      "^/(api|auth|t)/": { target: CYFR_API, changeOrigin: true },
      "^/prism(/|$)": { target: CYFR_PRISM, changeOrigin: true, ws: true },
    },
  },
  // The `porta` docker image runs `vite preview`; same proxy shape as dev,
  // but pointed at the `cyfr` service on the compose network. Harmless when
  // a TLS proxy (Caddy) is in front — those paths get intercepted upstream.
  preview: {
    port: 8080,
    host: "0.0.0.0",
    proxy: {
      "^/mcp([/?]|$)": { target: "http://cyfr:4000", changeOrigin: true },
      "^/(api|auth|t)/": { target: "http://cyfr:4000", changeOrigin: true },
    },
  },
  build: {
    target: "esnext",
  },
});
