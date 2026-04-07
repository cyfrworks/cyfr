import { useEffect, useRef, useCallback, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { useTinctureStore } from "../state/tincture-store";
import { useAgentStore } from "../state/agent-store";
import { useConnectionStore } from "../state/connection-store";

export default function TincturesPage() {
  const tinctures = useTinctureStore((s) => s.tinctures);
  const loading = useTinctureStore((s) => s.loading);
  const activeTincture = useTinctureStore((s) => s.activeTincture);
  const openedTinctures = useTinctureStore((s) => s.openedTinctures);
  const selectTincture = useTinctureStore((s) => s.selectTincture);
  const closeTincture = useTinctureStore((s) => s.closeTincture);
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

  return (
    <div className="flex h-full">
      {/* Sidebar */}
      <div className="flex w-56 flex-col border-r border-border-default bg-surface-base">
        <div className="flex items-center justify-between px-3 pt-3 pb-2">
          <span className="text-xs font-medium text-text-secondary">Tinctures</span>
          <button
            onClick={handleRefresh}
            disabled={loading}
            className="rounded p-1 text-text-muted hover:text-text-secondary disabled:opacity-50"
            title="Refresh"
          >
            <svg className={`h-3.5 w-3.5 ${loading ? "animate-spin" : ""}`} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182" />
            </svg>
          </button>
        </div>

        <div className="flex-1 overflow-y-auto px-2">
          {tinctures.length === 0 && !loading && (
            <p className="px-3 py-6 text-center text-xs text-text-muted">
              No tinctures installed
            </p>
          )}

          {tinctures.map((t) => (
            <div
              key={`${t.publisher}/${t.name}`}
              onClick={() => selectTincture(t.name)}
              className={`group cursor-pointer rounded-lg px-3 py-2 transition-colors ${
                activeTincture === t.name
                  ? "bg-accent-primary/15 text-accent-primary"
                  : "text-text-secondary hover:bg-surface-raised hover:text-text-primary"
              }`}
            >
              <div className="flex items-center justify-between">
                <span className="text-xs font-medium truncate">{t.title || t.name}</span>
                {openedTinctures.includes(t.name) && (
                  <button
                    onClick={(e) => { e.stopPropagation(); closeTincture(t.name); }}
                    className="hidden group-hover:block rounded p-0.5 text-text-muted hover:text-text-secondary"
                  >
                    <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                    </svg>
                  </button>
                )}
              </div>
              <div className="flex items-center gap-1.5 mt-0.5">
                <span className="text-[10px] text-text-muted">{t.publisher}</span>
                <span className={`rounded px-1 text-[9px] font-medium ${
                  t.public ? "bg-green-500/15 text-green-500" : "bg-yellow-500/15 text-yellow-500"
                }`}>
                  {t.public ? "public" : "private"}
                </span>
              </div>
              <div className="hidden group-hover:flex items-center gap-1 mt-1.5">
                <button
                  onClick={(e) => { e.stopPropagation(); handleToggleVisibility(t.publisher, t.name); }}
                  className="rounded px-1.5 py-0.5 text-[10px] text-text-muted hover:bg-surface-base hover:text-text-secondary"
                >
                  {t.public ? "Private" : "Public"}
                </button>
                <button
                  onClick={(e) => { e.stopPropagation(); handleCopyUrl(t.publisher, t.name); }}
                  className="rounded px-1.5 py-0.5 text-[10px] text-text-muted hover:bg-surface-base hover:text-text-secondary"
                >
                  Copy URL
                </button>
                <button
                  onClick={(e) => { e.stopPropagation(); handleOpenInBrowser(t.publisher, t.name); }}
                  className="rounded px-1.5 py-0.5 text-[10px] text-text-muted hover:bg-surface-base hover:text-text-secondary"
                >
                  Browser
                </button>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Main content — stacked iframes */}
      <div className="flex-1 relative">
        {openedTinctures.map((name) => {
          const t = tinctures.find((tc) => tc.name === name);
          if (!t) return null;

          return (
            <TinctureIframe
              key={name}
              name={t.name}
              publisher={t.publisher}
              isActive={activeTincture === name}
              cyfrUrl={cyfrUrl}
              sessionId={sessionId}
            />
          );
        })}

        {openedTinctures.length === 0 && (
          <div className="flex h-full items-center justify-center">
            <div className="text-center">
              <svg className="mx-auto h-12 w-12 text-text-muted/30" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1}>
                <path strokeLinecap="round" strokeLinejoin="round" d="M9.53 16.122a3 3 0 0 0-5.78 1.128 2.25 2.25 0 0 1-2.4 2.245 4.5 4.5 0 0 0 8.4-2.245c0-.399-.078-.78-.22-1.128Zm0 0a15.998 15.998 0 0 0 3.388-1.62m-5.043-.025a15.994 15.994 0 0 1 1.622-3.395m3.42 3.42a15.995 15.995 0 0 0 4.764-4.648l3.876-5.814a1.151 1.151 0 0 0-1.597-1.597L14.146 6.32a15.996 15.996 0 0 0-4.649 4.763m3.42 3.42a6.776 6.776 0 0 0-3.42-3.42" />
              </svg>
              <p className="mt-3 text-sm text-text-muted">Select a tincture to view</p>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function TinctureIframe({
  name,
  publisher,
  isActive,
  cyfrUrl,
  sessionId,
}: {
  name: string;
  publisher: string;
  isActive: boolean;
  cyfrUrl: string;
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

  // Auth via MCP session in query param — tincture controller validates via Sanctum.TinctureAuth
  const src = sessionId
    ? `${cyfrUrl}/t/${publisher}/${name}?_session=${sessionId}`
    : `${cyfrUrl}/t/${publisher}/${name}`;

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
