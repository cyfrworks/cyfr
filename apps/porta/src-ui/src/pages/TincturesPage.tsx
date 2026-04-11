import { useEffect, useRef, useCallback, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useTinctureStore } from "../state/tincture-store";
import { useAgentStore } from "../state/agent-store";
import { useConnectionStore } from "../state/connection-store";
import { PageLayout } from "../components/common/PageLayout";
import type { TinctureEntry } from "../api/types";

const CARD_GRADIENTS = [
  "linear-gradient(135deg, #6366f1 0%, #8b5cf6 100%)",
  "linear-gradient(135deg, #ec4899 0%, #f43f5e 100%)",
  "linear-gradient(135deg, #06b6d4 0%, #3b82f6 100%)",
  "linear-gradient(135deg, #10b981 0%, #14b8a6 100%)",
  "linear-gradient(135deg, #f59e0b 0%, #ef4444 100%)",
  "linear-gradient(135deg, #8b5cf6 0%, #d946ef 100%)",
  "linear-gradient(135deg, #f43f5e 0%, #f97316 100%)",
  "linear-gradient(135deg, #14b8a6 0%, #0ea5e9 100%)",
];

function hashString(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) {
    h = (h * 31 + s.charCodeAt(i)) | 0;
  }
  return Math.abs(h);
}

function gradientFor(t: TinctureEntry): string {
  return CARD_GRADIENTS[hashString(`${t.publisher}/${t.name}`) % CARD_GRADIENTS.length]!;
}

/** Detect whether a string looks like an emoji glyph (vs a Lucide icon name).
 *  Excludes plain ASCII so names like "chart-line" or "palette" fall through. */
const EMOJI_RE = /\p{Extended_Pictographic}/u;
function looksLikeEmoji(s: string | null | undefined): boolean {
  return typeof s === "string" && s.length > 0 && EMOJI_RE.test(s);
}

export default function TincturesPage() {
  const tinctures = useTinctureStore((s) => s.tinctures);
  const loading = useTinctureStore((s) => s.loading);
  const viewing = useTinctureStore((s) => s.viewing);
  const focusedIndex = useTinctureStore((s) => s.focusedIndex);
  const currentPreviewIndex = useTinctureStore((s) => s.currentPreviewIndex);
  const openedTinctures = useTinctureStore((s) => s.openedTinctures);
  const selectTincture = useTinctureStore((s) => s.selectTincture);
  const setFocusedIndex = useTinctureStore((s) => s.setFocusedIndex);
  const nextPreview = useTinctureStore((s) => s.nextPreview);
  const previousPreview = useTinctureStore((s) => s.previousPreview);
  const closeViewer = useTinctureStore((s) => s.closeViewer);
  const toggleVisibility = useTinctureStore((s) => s.toggleVisibility);
  const loadTinctures = useTinctureStore((s) => s.loadTinctures);
  const refreshTinctures = useTinctureStore((s) => s.refreshTinctures);
  const client = useAgentStore((s) => s.client);
  const initClient = useAgentStore((s) => s.initClient);
  const cyfrUrl = useConnectionStore((s) => s.cyfrUrl);
  const [initialLoaded, setInitialLoaded] = useState(false);

  useEffect(() => {
    if (initialLoaded) return;
    const load = async () => {
      let c = client;
      if (!c) {
        await initClient();
        c = useAgentStore.getState().client;
      }
      if (c) {
        await loadTinctures(c);
        setInitialLoaded(true);
      }
    };
    load();
  }, [client, initialLoaded, initClient, loadTinctures]);

  // Keyboard navigation:
  //   ←/→  switch tincture (resets preview cursor to 0)
  //   ↑/↓  cycle previews of the focused tincture (no-op when fewer than 2)
  //   Enter launch the focused tincture
  //   Esc  close the immersive viewer
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (document.activeElement?.tagName ?? "").toLowerCase();
      if (tag === "input" || tag === "textarea" || tag === "select") return;

      if (viewing) {
        if (e.key === "Escape") {
          e.preventDefault();
          closeViewer();
        }
        return;
      }

      if (tinctures.length === 0) return;
      if (e.key === "ArrowLeft") {
        e.preventDefault();
        setFocusedIndex(focusedIndex - 1);
      } else if (e.key === "ArrowRight") {
        e.preventDefault();
        setFocusedIndex(focusedIndex + 1);
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        previousPreview();
      } else if (e.key === "ArrowDown") {
        e.preventDefault();
        nextPreview();
      } else if (e.key === "Enter") {
        e.preventDefault();
        const t = tinctures[focusedIndex];
        if (t) selectTincture(t.name);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [viewing, focusedIndex, tinctures, setFocusedIndex, selectTincture, closeViewer, nextPreview, previousPreview]);

  const handleRefresh = () => {
    if (client) refreshTinctures(client);
  };

  const handleToggleVisibility = (publisher: string, name: string) => {
    if (client) toggleVisibility(client, publisher, name);
  };

  const handleOpenInBrowser = (publisher: string, name: string) => {
    invoke("open_url", { url: `${cyfrUrl}/t/${publisher}/${name}` }).catch(() => {});
  };

  const handleCopyUrl = (publisher: string, name: string) => {
    const url = `${cyfrUrl}/t/${publisher}/${name}`;
    navigator.clipboard.writeText(url).catch(() => {});
  };

  // MCP session ID for iframe auth
  const sessionId = client?.sessionId ?? "";

  const focused = tinctures[focusedIndex];
  const previewCount = focused?.previews.length ?? 0;
  const safePreviewIndex = previewCount > 0
    ? Math.min(currentPreviewIndex, previewCount - 1)
    : 0;
  const currentPreviewUrl: string | null =
    (previewCount > 0 && focused ? focused.previews[safePreviewIndex] ?? null : null);

  const showSkeletons = loading && tinctures.length === 0;

  return (
    <>
      {/* ===== Picker layer ===== */}
      <PageLayout
        title="Tinctures"
        subtitle="Sandboxed mini-apps that run inside CYFR."
        actions={
          <button
            onClick={handleRefresh}
            disabled={loading}
            className="rounded-lg p-2 text-text-muted hover:bg-surface-raised hover:text-text-secondary disabled:opacity-50"
            title="Refresh"
          >
            <svg className={`h-4 w-4 ${loading ? "animate-spin" : ""}`} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182" />
            </svg>
          </button>
        }
        bleed
      >
        <div className="relative h-full w-full overflow-hidden">
        {/* Empty state */}
        {!showSkeletons && tinctures.length === 0 && (
          <div className="flex h-full items-center justify-center">
            <div className="text-center">
              <svg className="mx-auto h-12 w-12 text-text-muted/30" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9.53 16.122a3 3 0 0 0-5.78 1.128 2.25 2.25 0 0 1-2.4 2.245 4.5 4.5 0 0 0 8.4-2.245c0-.399-.078-.78-.22-1.128Zm0 0a15.998 15.998 0 0 0 3.388-1.62m-5.043-.025a15.994 15.994 0 0 1 1.622-3.395m3.42 3.42a15.995 15.995 0 0 0 4.764-4.648l3.876-5.814a1.151 1.151 0 0 0-1.597-1.597L14.146 6.32a15.996 15.996 0 0 0-4.649 4.763m3.42 3.42a6.776 6.776 0 0 0-3.42-3.42" />
              </svg>
              <p className="mt-3 text-sm text-text-muted">No tinctures installed</p>
              <p className="mt-1 text-xs text-text-muted/70">
                Run <code className="font-mono">cyfr build compile &lt;path&gt;</code> to add one.
              </p>
            </div>
          </div>
        )}

        {/* Loading skeleton */}
        {showSkeletons && (
          <div className="flex h-full items-center justify-center">
            <div className="aspect-video w-full max-w-3xl animate-pulse rounded-2xl bg-surface-raised" />
          </div>
        )}

        {/* Preview-first single-card layout */}
        {focused && !showSkeletons && (
          <div className="flex h-full flex-col items-center justify-center gap-6 px-12 pb-6">
            {/* Big preview area */}
            <PreviewStage
              tincture={focused}
              previewUrl={currentPreviewUrl}
              previewIndex={safePreviewIndex}
              previewCount={previewCount}
              onClick={() => selectTincture(focused.name)}
              onUp={previousPreview}
              onDown={nextPreview}
            />

            {/* Compact info bar */}
            <InfoBar
              tincture={focused}
              onLaunch={() => selectTincture(focused.name)}
              onToggleVisibility={() => handleToggleVisibility(focused.publisher, focused.name)}
              onCopyUrl={() => handleCopyUrl(focused.publisher, focused.name)}
              onOpenInBrowser={() => handleOpenInBrowser(focused.publisher, focused.name)}
            />

            {/* Tincture pagination dots */}
            {tinctures.length > 1 && (
              <div className="flex items-center gap-1.5">
                {tinctures.map((_, i) => (
                  <button
                    key={i}
                    onClick={() => setFocusedIndex(i)}
                    className={`rounded-full transition-all duration-300 ${
                      i === focusedIndex
                        ? "h-1.5 w-6 bg-accent-primary"
                        : "h-1.5 w-1.5 bg-text-muted/30 hover:bg-text-muted/50"
                    }`}
                    aria-label={`Tincture ${i + 1} of ${tinctures.length}`}
                  />
                ))}
              </div>
            )}
          </div>
        )}

        {/* Side arrow buttons (mouse users) */}
        {tinctures.length > 1 && !showSkeletons && (
          <>
            <button
              onClick={() => setFocusedIndex(focusedIndex - 1)}
              disabled={focusedIndex === 0}
              className="absolute left-6 top-1/2 z-10 flex h-10 w-10 -translate-y-1/2 items-center justify-center rounded-full bg-surface-overlay/70 text-text-secondary backdrop-blur-md transition-all hover:bg-surface-overlay hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-30"
              title="Previous tincture (←)"
            >
              <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 19.5 8.25 12l7.5-7.5" />
              </svg>
            </button>
            <button
              onClick={() => setFocusedIndex(focusedIndex + 1)}
              disabled={focusedIndex >= tinctures.length - 1}
              className="absolute right-6 top-1/2 z-10 flex h-10 w-10 -translate-y-1/2 items-center justify-center rounded-full bg-surface-overlay/70 text-text-secondary backdrop-blur-md transition-all hover:bg-surface-overlay hover:text-text-primary disabled:cursor-not-allowed disabled:opacity-30"
              title="Next tincture (→)"
            >
              <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                <path strokeLinecap="round" strokeLinejoin="round" d="m8.25 4.5 7.5 7.5-7.5 7.5" />
              </svg>
            </button>
          </>
        )}
        </div>
      </PageLayout>

      {/* ===== Viewer layer (immersive) ===== */}
      {viewing && (
        <div className="fixed inset-0 z-50 bg-surface-base">
          {openedTinctures.map((name) => {
            const t = tinctures.find((tc) => tc.name === name);
            if (!t) return null;
            return (
              <TinctureIframe
                key={name}
                name={t.name}
                publisher={t.publisher}
                isActive={viewing === name}
                sessionId={sessionId}
              />
            );
          })}

          {/* WeChat-style capsule menu (top-right): more · close */}
          <TinctureCapsule onClose={() => closeViewer()} />
        </div>
      )}
    </>
  );
}

/**
 * WeChat mini-app style capsule menu — two icon buttons joined by a divider
 * inside a rounded pill. Designed to be portable: the visual recipe (flex
 * row, rounded-full, semi-transparent surface, divider between two icon
 * buttons) translates 1:1 to React Native's StyleSheet. Only `backdrop-blur`
 * is web-only — RN should fall back to a slightly opaque background or use
 * BlurView from @react-native-community/blur.
 */
function TinctureCapsule({ onClose }: { onClose: () => void }) {
  const handleMore = () => {
    // TODO: open menu — about, share, settings, etc. Placeholder for now.
  };

  return (
    <div
      className="fixed right-4 top-4 z-[60] flex items-center rounded-full border border-white/10 bg-surface-overlay/70 shadow-lg backdrop-blur-md"
      role="toolbar"
      aria-label="Tincture controls"
    >
      <button
        onClick={handleMore}
        className="flex h-8 w-10 items-center justify-center rounded-l-full text-text-secondary transition-colors hover:bg-white/5 hover:text-text-primary"
        title="More"
        aria-label="More options"
      >
        <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <circle cx="5" cy="12" r="1" fill="currentColor" />
          <circle cx="12" cy="12" r="1" fill="currentColor" />
          <circle cx="19" cy="12" r="1" fill="currentColor" />
        </svg>
      </button>
      <span className="h-4 w-px bg-white/15" aria-hidden="true" />
      <button
        onClick={onClose}
        className="flex h-8 w-10 items-center justify-center rounded-r-full text-text-secondary transition-colors hover:bg-white/5 hover:text-text-primary"
        title="Close (Esc)"
        aria-label="Close tincture"
      >
        <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
          <path strokeLinecap="round" strokeLinejoin="round" d="M6 18 18 6M6 6l12 12" />
        </svg>
      </button>
    </div>
  );
}

/**
 * The big visual centerpiece. Shows the current preview image when the tincture
 * has any, otherwise falls back to the icon precedence ladder (image → emoji →
 * first-letter glyph) on a gradient background. Up/down arrow buttons (visible
 * when there are 2+ previews) cycle through the slides; the same is wired to
 * keyboard ↑/↓ at the page level.
 */
function PreviewStage({
  tincture,
  previewUrl,
  previewIndex,
  previewCount,
  onClick,
  onUp,
  onDown,
}: {
  tincture: TinctureEntry;
  previewUrl: string | null;
  previewIndex: number;
  previewCount: number;
  onClick: () => void;
  onUp: () => void;
  onDown: () => void;
}) {
  const [previewErrored, setPreviewErrored] = useState(false);

  // Reset error state when the preview URL changes (different tincture or slide)
  useEffect(() => {
    setPreviewErrored(false);
  }, [previewUrl]);

  const showPreview = previewUrl !== null && !previewErrored;

  return (
    <div className="relative w-full max-w-3xl">
      <button
        onClick={onClick}
        className="group relative block aspect-video w-full overflow-hidden rounded-2xl bg-black/40 shadow-2xl ring-1 ring-white/10 transition-all hover:ring-accent-primary/60"
      >
        {showPreview ? (
          <>
            {/* Blurred backdrop fill — uses the same image scaled and heavily
             *  blurred so any letterbox/pillarbox bars look intentional rather
             *  than empty. Browser caches the image so this is one network
             *  request total. */}
            <img
              src={previewUrl!}
              alt=""
              aria-hidden="true"
              className="absolute inset-0 h-full w-full scale-110 object-cover opacity-60 blur-2xl"
            />
            {/* Foreground preview — contained, never cropped. Works for any
             *  aspect ratio: 16:9 landscape fills the container, portrait gets
             *  pillarboxed against the blurred backdrop. */}
            <img
              src={previewUrl!}
              alt=""
              className="relative h-full w-full object-contain transition-opacity duration-300"
              onError={() => setPreviewErrored(true)}
            />
          </>
        ) : (
          <PreviewFallback tincture={tincture} />
        )}
      </button>

      {/* Vertical capsule on the right edge: up · counter · down.
       *  Only rendered when there are 2+ previews to navigate. */}
      {previewCount > 1 && (
        <div
          className="absolute right-4 top-1/2 z-10 flex -translate-y-1/2 flex-col items-stretch overflow-hidden rounded-full border border-white/15 bg-black/55 text-white/90 shadow-lg backdrop-blur-md"
          role="group"
          aria-label="Preview navigation"
        >
          <button
            onClick={(e) => { e.stopPropagation(); onUp(); }}
            className="flex h-9 w-9 items-center justify-center transition-colors hover:bg-white/10 hover:text-white"
            title="Previous preview (↑)"
            aria-label="Previous preview"
          >
            <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="m4.5 15.75 7.5-7.5 7.5 7.5" />
            </svg>
          </button>
          <span className="h-px w-full bg-white/15" aria-hidden="true" />
          <span className="flex h-7 w-9 items-center justify-center text-[11px] font-medium tabular-nums text-white/80">
            {previewIndex + 1}/{previewCount}
          </span>
          <span className="h-px w-full bg-white/15" aria-hidden="true" />
          <button
            onClick={(e) => { e.stopPropagation(); onDown(); }}
            className="flex h-9 w-9 items-center justify-center transition-colors hover:bg-white/10 hover:text-white"
            title="Next preview (↓)"
            aria-label="Next preview"
          >
            <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="m19.5 8.25-7.5 7.5-7.5-7.5" />
            </svg>
          </button>
        </div>
      )}
    </div>
  );
}

/**
 * Fallback inside the preview area when a tincture has no preview images yet.
 * Renders the icon precedence ladder (image → emoji → first-letter) on a
 * deterministic gradient so each tincture still has a recognizable identity.
 */
function PreviewFallback({ tincture }: { tincture: TinctureEntry }) {
  const gradient = gradientFor(tincture);
  const initial = (tincture.title || tincture.name).trim().charAt(0).toUpperCase();
  const [iconErrored, setIconErrored] = useState(false);

  const showImage = tincture.iconUrl !== null && !iconErrored;
  const showEmoji = !showImage && looksLikeEmoji(tincture.iconHint);

  return (
    <div
      className="flex h-full w-full items-center justify-center"
      style={{ background: gradient }}
    >
      {showImage ? (
        <img
          src={tincture.iconUrl!}
          alt=""
          className="h-48 w-48 select-none object-contain drop-shadow-2xl"
          onError={() => setIconErrored(true)}
        />
      ) : showEmoji ? (
        <span className="select-none text-[10rem] leading-none drop-shadow-2xl">
          {tincture.iconHint}
        </span>
      ) : (
        <span className="select-none text-[12rem] font-extralight leading-none text-white/90 drop-shadow-2xl">
          {initial}
        </span>
      )}
    </div>
  );
}

/**
 * Compact strip below the preview: small icon + title + tagline + publisher
 * status badge on the left, action buttons on the right.
 */
function InfoBar({
  tincture,
  onLaunch,
  onToggleVisibility,
  onCopyUrl,
  onOpenInBrowser,
}: {
  tincture: TinctureEntry;
  onLaunch: () => void;
  onToggleVisibility: () => void;
  onCopyUrl: () => void;
  onOpenInBrowser: () => void;
}) {
  const initial = (tincture.title || tincture.name).trim().charAt(0).toUpperCase();
  const [iconErrored, setIconErrored] = useState(false);

  const showImage = tincture.iconUrl !== null && !iconErrored;
  const showEmoji = !showImage && looksLikeEmoji(tincture.iconHint);

  return (
    <div className="flex w-full max-w-3xl items-center gap-4">
      {/* Small icon (image > emoji > first-letter) */}
      <div className="flex h-12 w-12 shrink-0 items-center justify-center overflow-hidden rounded-xl bg-surface-raised ring-1 ring-white/10">
        {showImage ? (
          <img
            src={tincture.iconUrl!}
            alt=""
            className="h-full w-full object-contain"
            onError={() => setIconErrored(true)}
          />
        ) : showEmoji ? (
          <span className="text-2xl leading-none">{tincture.iconHint}</span>
        ) : (
          <span className="text-lg font-semibold text-text-secondary">{initial}</span>
        )}
      </div>

      {/* Title + tagline */}
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="truncate text-base font-semibold text-text-primary">
            {tincture.name}
          </span>
          <span
            className={`shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium ${
              tincture.public
                ? "bg-green-500/15 text-green-500"
                : "bg-yellow-500/15 text-yellow-500"
            }`}
          >
            {tincture.public ? "public" : "private"}
          </span>
        </div>
        {(tincture.tagline || tincture.title) && (
          <div className="truncate text-xs text-text-muted">
            {tincture.tagline || tincture.title}
          </div>
        )}
      </div>

      {/* Action buttons */}
      <div className="flex shrink-0 gap-2">
        <button
          onClick={onLaunch}
          className="rounded-lg bg-accent-primary px-4 py-1.5 text-xs font-medium text-white transition-colors hover:bg-accent-hover"
        >
          Launch
        </button>
        <button
          onClick={onToggleVisibility}
          className="rounded-lg border border-border-default bg-surface-raised px-3 py-1.5 text-xs text-text-secondary transition-colors hover:text-text-primary"
        >
          {tincture.public ? "Make Private" : "Make Public"}
        </button>
        <button
          onClick={onCopyUrl}
          className="rounded-lg border border-border-default bg-surface-raised px-3 py-1.5 text-xs text-text-secondary transition-colors hover:text-text-primary"
          title="Copy public URL"
        >
          Copy URL
        </button>
        <button
          onClick={onOpenInBrowser}
          className="rounded-lg border border-border-default bg-surface-raised px-3 py-1.5 text-xs text-text-secondary transition-colors hover:text-text-primary"
          title="Open in browser"
        >
          Browser
        </button>
      </div>
    </div>
  );
}

function TinctureIframe({
  name,
  publisher,
  isActive,
  sessionId,
}: {
  name: string;
  publisher: string;
  isActive: boolean;
  sessionId: string;
}) {
  const iframeRef = useRef<HTMLIFrameElement>(null);

  // PostMessage bridge for tincture SDK
  const handleMessage = useCallback((event: MessageEvent) => {
    if (!event.data || event.data.type !== "cyfr:request") return;

    const iframe = iframeRef.current;
    if (!iframe?.contentWindow || event.source !== iframe.contentWindow) return;

    const { id, action } = event.data;

    switch (action) {
      case "ready":
        iframe.contentWindow.postMessage(
          { type: "cyfr:response", id, result: { ok: true } }, "*",
        );
        break;

      case "set_title":
        iframe.contentWindow.postMessage(
          { type: "cyfr:response", id, result: { ok: true } }, "*",
        );
        break;

      case "get_context":
        iframe.contentWindow.postMessage(
          { type: "cyfr:response", id, result: { tincture_id: name, window_id: name } }, "*",
        );
        break;

      case "close":
        useTinctureStore.getState().closeTincture(name);
        iframe.contentWindow.postMessage(
          { type: "cyfr:response", id, result: { ok: true } }, "*",
        );
        break;

      case "query":
        iframe.contentWindow.postMessage(
          { type: "cyfr:response", id, error: "queries_not_supported_in_desktop" }, "*",
        );
        break;

      default:
        iframe.contentWindow.postMessage(
          { type: "cyfr:response", id, error: "unknown_action" }, "*",
        );
    }
  }, [name]);

  useEffect(() => {
    window.addEventListener("message", handleMessage);
    return () => window.removeEventListener("message", handleMessage);
  }, [handleMessage]);

  // Route through tincture:// custom protocol to bypass WKWebView mixed-content blocking.
  // The Rust protocol handler proxies path verbatim to {cyfrUrl}{path} via reqwest.
  const src = sessionId
    ? `tincture://localhost/t/${publisher}/${name}?_session=${sessionId}`
    : `tincture://localhost/t/${publisher}/${name}`;

  // Porta needs allow-same-origin because the tincture:// custom protocol
  // requires a real origin for WKWebView to allow sub-resource fetches (JS, CSS).
  // This is safe here: the iframe origin (tincture://localhost) is cross-origin
  // from the parent (tauri://localhost), so allow-same-origin does NOT grant
  // access to the parent's cookies/storage — unlike the web ShellLive context
  // where parent and iframe share the same HTTP origin.
  return (
    <div className={`absolute inset-0 ${isActive ? "" : "hidden"}`}>
      <iframe
        ref={iframeRef}
        src={src}
        sandbox="allow-scripts allow-same-origin"
        className="h-full w-full border-0"
        title={name}
      />
    </div>
  );
}
