import { useEffect, type ComponentType } from "react";
import { Outlet, NavLink } from "react-router-dom";
import { useOverlayStore } from "../state/overlay-store";
import { SetupFormHost } from "../components/agent/SetupFormHost";
import { AquaOverlay } from "../components/overlay/AquaOverlay";
import { ActivityLane } from "../components/activity/ActivityLane";
import { ProjectSwitcher } from "../components/projects/ProjectSwitcher";
import { NavigatorShim } from "../harness/navigator-shim";
import { label } from "../config/labels";

interface NavItem {
  to: string;
  label: string;
  icon: ComponentType;
}

const navItems: NavItem[] = [
  { to: "/tinctures", label: label("tincture", { plural: true }), icon: TincturesIcon },
  { to: "/schedules", label: "Schedules", icon: SchedulesIcon },
  { to: "/components", label: "Components", icon: ComponentsIcon },
  { to: "/mcp-servers", label: label("mcp_server", { plural: true }), icon: McpServersIcon },
  { to: "/settings", label: "Settings", icon: SettingsIcon },
];

export default function AppShell() {
  const overlayState = useOverlayStore((s) => s.state);
  const toggleOverlay = useOverlayStore((s) => s.toggle);
  const openOverlay = useOverlayStore((s) => s.open);
  const focusOverlayInput = useOverlayStore((s) => s.focusInput);
  const overlayOpen = overlayState !== "closed";

  // Global Cmd+K / Ctrl+K toggles the AQUA overlay.
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        const wasClosed = useOverlayStore.getState().state === "closed";
        toggleOverlay();
        if (wasClosed) focusOverlayInput();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [toggleOverlay, focusOverlayInput]);

  const handleAquaClick = () => {
    if (overlayOpen) {
      toggleOverlay();
    } else {
      openOverlay();
      focusOverlayInput();
    }
  };

  return (
    <div className="flex h-full bg-surface-base">
      {/* Sidebar */}
      <nav className="flex w-56 flex-col border-r border-border-default bg-surface-base">
        <div className="pt-3">
          <ProjectSwitcher />
        </div>
        <div className="flex flex-1 flex-col gap-0.5 px-2">
          {/* AQUA entry — opens overlay rather than navigating. */}
          <button
            onClick={handleAquaClick}
            className={`flex items-center justify-between gap-3 rounded-lg px-3 py-2 text-sm transition-colors ${
              overlayOpen
                ? "bg-accent-primary/15 text-accent-primary"
                : "text-text-secondary hover:bg-surface-raised hover:text-text-primary"
            }`}
            aria-pressed={overlayOpen}
          >
            <span className="flex items-center gap-3">
              <AskIcon />
              AQUA
            </span>
            <kbd className="rounded border border-border-default bg-surface-raised px-1.5 py-0.5 font-mono text-[10px] text-text-muted">
              ⌘K
            </kbd>
          </button>

          {navItems.map((item) => (
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
          ))}
        </div>

        {/* Activity lane lives at the bottom of the sidebar. */}
        <div className="px-2 pb-3">
          <ActivityLane />
        </div>
      </nav>

      {/* Main content */}
      <main className="flex flex-1 flex-col overflow-hidden">
        <Outlet />
      </main>

      <AquaOverlay />
      <SetupFormHost />
      <NavigatorShim />
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
