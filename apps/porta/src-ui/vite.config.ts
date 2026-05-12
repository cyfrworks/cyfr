import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { VitePWA } from "vite-plugin-pwa";

// In dev, proxy the Cyfr API + tincture + remote-browser paths to a local
// stack so the PWA can be exercised with `npm run dev`. In production these
// paths are routed by the deployment's reverse proxy (Caddy).
const CYFR_API = process.env.CYFR_DEV_URL ?? "http://127.0.0.1:4000";
const CYFR_PRISM = process.env.CYFR_DEV_PRISM_URL ?? "http://127.0.0.1:4001";
const NEKO_URL = process.env.NEKO_DEV_URL ?? "http://127.0.0.1:8080";

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
        // Precache the built app shell; never serve API/SSE/tincture/browser
        // traffic from the cache — those must always hit the network.
        globPatterns: ["**/*.{js,css,html,ico,png,svg,woff2}"],
        navigateFallbackDenylist: [/^\/mcp/, /^\/api\//, /^\/t\//, /^\/browse/],
        runtimeCaching: [],
      },
      devOptions: { enabled: false },
    }),
  ],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    proxy: {
      "/mcp": { target: CYFR_API, changeOrigin: true },
      "/api": { target: CYFR_API, changeOrigin: true },
      "/auth": { target: CYFR_API, changeOrigin: true },
      "/t": { target: CYFR_API, changeOrigin: true },
      "/prism": { target: CYFR_PRISM, changeOrigin: true, ws: true },
      "/browse": { target: NEKO_URL, changeOrigin: true, ws: true },
    },
  },
  build: {
    target: "esnext",
  },
});
