import { useEffect, useState, lazy, Suspense } from "react";
import { Outlet, NavLink, useLocation } from "react-router-dom";
import { listen } from "@tauri-apps/api/event";
import { invoke } from "@tauri-apps/api/core";
import { useConnectionStore } from "../state/connection-store";

const AskPage = lazy(() => import("../pages/AskPage"));

const navItems = [
  { to: "/ask", label: "AQUA", icon: AskIcon },
  { to: "/schedules", label: "Schedules", icon: SchedulesIcon },
  { to: "/components", label: "Components", icon: ComponentsIcon },
  { to: "/tinctures", label: "Tinctures", icon: TincturesIcon, external: true },
  { to: "/mcp-servers", label: "MCP Servers", icon: McpServersIcon },
  { to: "/settings", label: "Settings", icon: SettingsIcon },
];

interface UpdateInfo {
  kind: "cyfr" | "porta";
  current: string;
  latest: string;
  url?: string;
}

export default function AppShell() {
  const location = useLocation();
  const isAsk = location.pathname === "/ask" || location.pathname === "/";
  const [updates, setUpdates] = useState<UpdateInfo[]>([]);
  const startUpdate = useConnectionStore((s) => s.startUpdate);
  const cyfrUrl = useConnectionStore((s) => s.cyfrUrl);

  useEffect(() => {
    const unlisten = listen<UpdateInfo>("update-available", (event) => {
      setUpdates((prev) => {
        // Replace existing entry for same kind, or add new
        const filtered = prev.filter((u) => u.kind !== event.payload.kind);
        return [...filtered, event.payload];
      });
    });
    return () => {
      unlisten.then((fn) => fn());
    };
  }, []);

  const handleCyfrUpdate = (info: UpdateInfo) => {
    // Transition to full-screen update view via App.tsx
    startUpdate(info);
    setUpdates((prev) => prev.filter((u) => u.kind !== "cyfr"));
  };

  const handlePortaDownload = (url: string) => {
    invoke("open_url", { url }).catch(() => {});
  };

  const dismiss = (kind: string) => {
    setUpdates((prev) => prev.filter((u) => u.kind !== kind));
  };

  return (
    <div className="flex h-full bg-surface-base">
      {/* Sidebar */}
      <nav className="flex w-56 flex-col border-r border-border-default bg-surface-base">
        <div className="flex flex-1 flex-col gap-0.5 px-2 pt-3">
          {navItems.map((item) =>
            item.external ? (
              <button
                key={item.to}
                onClick={() => invoke("open_url", { url: `${cyfrUrl}${item.to}` }).catch(() => {})}
                className="flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors text-text-secondary hover:bg-surface-raised hover:text-text-primary"
              >
                <item.icon />
                {item.label}
                <ExternalIcon />
              </button>
            ) : (
              <NavLink
                key={item.to}
                to={item.to}
                className={({ isActive }) =>
                  `flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition-colors ${
                    isActive
                      ? "bg-accent-primary/15 text-accent-primary"
                      : "text-text-secondary hover:bg-surface-raised hover:text-text-primary"
                  }`
                }
              >
                <item.icon />
                {item.label}
              </NavLink>
            )
          )}
        </div>

        {/* Update pills */}
        {updates.length > 0 && (
          <div className="space-y-1.5 px-2 pb-3">
            {updates.map((info) => (
              <div
                key={info.kind}
                className="rounded-lg bg-accent-primary/10 px-3 py-2"
              >
                <div className="flex items-start justify-between gap-1">
                  <span className="text-xs font-medium text-accent-primary">
                    {info.kind === "cyfr" ? "CYFR" : "App"} v{info.latest}
                  </span>
                  <button
                    onClick={() => dismiss(info.kind)}
                    className="shrink-0 rounded p-0.5 text-text-muted hover:text-text-secondary"
                  >
                    <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                      <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
                    </svg>
                  </button>
                </div>
                <p className="mt-0.5 text-[10px] text-text-muted">
                  Current: v{info.current}
                </p>
                {info.kind === "cyfr" ? (
                  <button
                    onClick={() => handleCyfrUpdate(info)}
                    className="mt-1.5 w-full rounded-md bg-accent-primary/20 px-2 py-1 text-xs font-medium text-accent-primary transition-colors hover:bg-accent-primary/30"
                  >
                    Update
                  </button>
                ) : (
                  <button
                    onClick={() => info.url && handlePortaDownload(info.url)}
                    className="mt-1.5 w-full rounded-md bg-accent-primary/20 px-2 py-1 text-xs font-medium text-accent-primary transition-colors hover:bg-accent-primary/30"
                  >
                    Download
                  </button>
                )}
              </div>
            ))}
          </div>
        )}
      </nav>

      {/* Main content */}
      <main className="flex flex-1 flex-col overflow-hidden">
        {/* AskPage is always mounted to preserve streaming state across navigations */}
        <Suspense fallback={null}>
          <div className={isAsk ? "flex flex-1 flex-col" : "hidden"}>
            <AskPage />
          </div>
        </Suspense>
        {!isAsk && <Outlet />}
      </main>
    </div>
  );
}

function AskIcon() {
  return (
    <svg
      className="h-4 w-4"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={1.5}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M7.5 8.25h9m-9 3H12m-9.75 1.51c0 1.6 1.123 2.994 2.707 3.227 1.129.166 2.27.293 3.423.379.35.026.67.21.865.501L12 21l2.755-4.133a1.14 1.14 0 0 1 .865-.501 48.172 48.172 0 0 0 3.423-.379c1.584-.233 2.707-1.626 2.707-3.228V6.741c0-1.602-1.123-2.995-2.707-3.228A48.394 48.394 0 0 0 12 3c-2.392 0-4.744.175-7.043.513C3.373 3.746 2.25 5.14 2.25 6.741v6.018Z"
      />
    </svg>
  );
}

function SchedulesIcon() {
  return (
    <svg
      className="h-4 w-4"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={1.5}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M12 6v6h4.5m4.5 0a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z"
      />
    </svg>
  );
}

function ComponentsIcon() {
  return (
    <svg
      className="h-4 w-4"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={1.5}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="m21 7.5-9-5.25L3 7.5m18 0-9 5.25m9-5.25v9l-9 5.25M3 7.5l9 5.25M3 7.5v9l9 5.25m0-9v9"
      />
    </svg>
  );
}

function McpServersIcon() {
  return (
    <svg
      className="h-4 w-4"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={1.5}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M5.25 14.25h13.5m-13.5 0a3 3 0 0 1-3-3m3 3a3 3 0 1 0 0 6h13.5a3 3 0 1 0 0-6m-16.5-3a3 3 0 0 1 3-3h13.5a3 3 0 0 1 3 3m-19.5 0a4.5 4.5 0 0 1 .9-2.7L5.737 5.1a3.375 3.375 0 0 1 2.7-1.35h7.126c1.062 0 2.062.5 2.7 1.35l2.587 3.45a4.5 4.5 0 0 1 .9 2.7m0 0a3 3 0 0 1-3 3m0 3h.008v.008h-.008v-.008Zm0-6h.008v.008h-.008v-.008Zm-3 6h.008v.008h-.008v-.008Zm0-6h.008v.008h-.008v-.008Z"
      />
    </svg>
  );
}

function TincturesIcon() {
  return (
    <svg
      className="h-4 w-4"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={1.5}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M9.53 16.122a3 3 0 0 0-5.78 1.128 2.25 2.25 0 0 1-2.4 2.245 4.5 4.5 0 0 0 8.4-2.245c0-.399-.078-.78-.22-1.128Zm0 0a15.998 15.998 0 0 0 3.388-1.62m-5.043-.025a15.994 15.994 0 0 1 1.622-3.395m3.42 3.42a15.995 15.995 0 0 0 4.764-4.648l3.876-5.814a1.151 1.151 0 0 0-1.597-1.597L14.146 6.32a15.996 15.996 0 0 0-4.649 4.763m3.42 3.42a6.776 6.776 0 0 0-3.42-3.42"
      />
    </svg>
  );
}

function ExternalIcon() {
  return (
    <svg
      className="ml-auto h-3 w-3 opacity-50"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={2}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M13.5 6H5.25A2.25 2.25 0 0 0 3 8.25v10.5A2.25 2.25 0 0 0 5.25 21h10.5A2.25 2.25 0 0 0 18 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25"
      />
    </svg>
  );
}

function SettingsIcon() {
  return (
    <svg
      className="h-4 w-4"
      fill="none"
      viewBox="0 0 24 24"
      stroke="currentColor"
      strokeWidth={1.5}
    >
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.431.992a7.723 7.723 0 0 1 0 .255c-.007.378.138.75.43.991l1.004.827c.424.35.534.954.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.941-1.11.941h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z"
      />
      <path
        strokeLinecap="round"
        strokeLinejoin="round"
        d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z"
      />
    </svg>
  );
}
