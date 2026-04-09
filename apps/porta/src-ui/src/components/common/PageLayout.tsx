import type { ReactNode } from "react";

interface PageLayoutProps {
  /** Page title shown in the header bar. */
  title: string;
  /** Optional subtitle shown under the title. */
  subtitle?: string;
  /** Optional action buttons rendered on the right side of the header. */
  actions?: ReactNode;
  /** Page body. Rendered inside a scrollable, full-width container. */
  children: ReactNode;
  /**
   * When true, the body fills the available area without internal padding
   * or its own scroll container. Use this for pages that manage their own
   * layout (e.g. the Tinctures carousel).
   */
  bleed?: boolean;
}

/**
 * Standard page chrome for routes rendered inside the AppShell main panel.
 *
 * Layout:
 *   ┌────────────────────────────────────────────────┐
 *   │  Title                              [Actions]  │  ← header bar
 *   │  Subtitle                                       │
 *   ├────────────────────────────────────────────────┤
 *   │                                                 │
 *   │  children (scrollable, full-width)              │
 *   │                                                 │
 *   └────────────────────────────────────────────────┘
 *
 * Pages should NOT add their own outer wrapper, max-width, or h1 — pass
 * them as props instead so every page in Porta uses the same chrome.
 */
export function PageLayout({
  title,
  subtitle,
  actions,
  children,
  bleed = false,
}: PageLayoutProps) {
  return (
    <div className="flex h-full flex-col bg-surface-base">
      <header className="flex shrink-0 items-center justify-between gap-4 border-b border-border-default px-4 py-3 sm:px-6 sm:py-4">
        <div className="min-w-0">
          <h1 className="truncate text-lg font-semibold text-text-primary">
            {title}
          </h1>
          {subtitle && (
            <p className="mt-0.5 truncate text-xs text-text-secondary">
              {subtitle}
            </p>
          )}
        </div>
        {actions && (
          <div className="flex shrink-0 items-center gap-2">{actions}</div>
        )}
      </header>

      {bleed ? (
        <div className="relative flex-1 overflow-hidden">{children}</div>
      ) : (
        <div className="flex-1 overflow-y-auto">
          <div className="px-4 py-6 sm:px-6 lg:px-8">{children}</div>
        </div>
      )}
    </div>
  );
}
