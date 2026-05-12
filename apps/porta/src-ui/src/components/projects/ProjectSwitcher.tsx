import { useEffect, useRef, useState } from "react";
import { useProjectStore, type Project } from "../../state/project-store";

/**
 * Sidebar dropdown showing the active project with a list of the user's other
 * projects. Clicking one swaps the underlying cyfr connection.
 */
export function ProjectSwitcher() {
  const projects = useProjectStore((s) => s.projects);
  const activeProjectId = useProjectStore((s) => s.activeProjectId);
  const selectProject = useProjectStore((s) => s.selectProject);
  const updateProject = useProjectStore((s) => s.updateProject);
  const createProject = useProjectStore((s) => s.createProject);
  const deleteProject = useProjectStore((s) => s.deleteProject);

  const active = projects.find((p) => p.id === activeProjectId);
  const [open, setOpen] = useState(false);
  const [creating, setCreating] = useState(false);
  const [renaming, setRenaming] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (!containerRef.current?.contains(e.target as Node)) {
        setOpen(false);
        setCreating(false);
        setRenaming(false);
      }
    };
    window.addEventListener("mousedown", onClick);
    return () => window.removeEventListener("mousedown", onClick);
  }, [open]);

  // No project yet (pre-seed) — show a subtle placeholder.
  if (!active) {
    return (
      <div className="mb-2 px-3 text-xs text-text-muted">Loading…</div>
    );
  }

  return (
    <div ref={containerRef} className="relative mb-2 px-2">
      <button
        onClick={() => setOpen((v) => !v)}
        className="flex w-full items-center justify-between gap-2 rounded-lg border border-border-default bg-surface-raised px-3 py-2 text-left text-sm transition-colors hover:bg-surface-overlay"
        aria-expanded={open}
        title={`${active.mode} · ${active.url}`}
      >
        <div className="min-w-0 flex-1">
          <div className="truncate font-medium text-text-primary">{active.name}</div>
          <div className="truncate text-[10px] text-text-muted">
            {modeSummary(active)}
          </div>
        </div>
        <Chevron />
      </button>

      {open && (
        <div className="absolute left-2 right-2 top-full z-50 mt-1 rounded-lg border border-border-default bg-surface-raised shadow-xl">
          <ul className="max-h-64 overflow-y-auto divide-y divide-border-default">
            {projects.map((p) => (
              <li key={p.id}>
                <button
                  onClick={() => {
                    setOpen(false);
                    if (p.id !== active.id) void selectProject(p.id);
                  }}
                  className={`flex w-full items-start justify-between gap-2 px-3 py-2 text-left text-xs transition-colors hover:bg-surface-overlay ${
                    p.id === active.id ? "text-accent-primary" : "text-text-secondary"
                  }`}
                >
                  <div className="min-w-0 flex-1">
                    <div className="truncate font-medium">{p.name}</div>
                    <div className="truncate text-[10px] text-text-muted">
                      {modeSummary(p)}
                    </div>
                  </div>
                  {p.id === active.id && <Check />}
                </button>
              </li>
            ))}
          </ul>

          <div className="border-t border-border-default p-1">
            {!creating && !renaming && (
              <>
                <button
                  onClick={() => {
                    setRenaming(true);
                    setCreating(false);
                  }}
                  className="block w-full rounded px-3 py-1.5 text-left text-xs text-text-secondary hover:bg-surface-overlay"
                >
                  Rename current…
                </button>
                <button
                  onClick={() => {
                    setCreating(true);
                    setRenaming(false);
                  }}
                  className="block w-full rounded px-3 py-1.5 text-left text-xs text-text-secondary hover:bg-surface-overlay"
                >
                  Add project…
                </button>
                {projects.length > 1 && (
                  <button
                    onClick={() => {
                      if (confirm(`Delete project "${active.name}"?`)) {
                        deleteProject(active.id);
                        setOpen(false);
                      }
                    }}
                    className="block w-full rounded px-3 py-1.5 text-left text-xs text-status-error hover:bg-status-error/10"
                  >
                    Delete current
                  </button>
                )}
              </>
            )}

            {renaming && (
              <RenameForm
                initial={active.name}
                onSubmit={(name) => {
                  updateProject(active.id, { name });
                  setRenaming(false);
                }}
                onCancel={() => setRenaming(false)}
              />
            )}

            {creating && (
              <CreateForm
                onSubmit={(project) => {
                  const created = createProject(project);
                  setCreating(false);
                  setOpen(false);
                  void selectProject(created.id);
                }}
                onCancel={() => setCreating(false)}
              />
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function modeSummary(p: Project): string {
  if (p.mode === "remote") {
    try {
      return new URL(p.url).host;
    } catch {
      return p.url;
    }
  }
  return "Same origin (session)";
}

function RenameForm({
  initial,
  onSubmit,
  onCancel,
}: {
  initial: string;
  onSubmit: (name: string) => void;
  onCancel: () => void;
}) {
  const [value, setValue] = useState(initial);
  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        const trimmed = value.trim();
        if (trimmed) onSubmit(trimmed);
      }}
      className="flex flex-col gap-1.5 p-1.5"
    >
      <input
        autoFocus
        value={value}
        onChange={(e) => setValue(e.target.value)}
        className="rounded border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary focus:border-accent-primary focus:outline-none"
      />
      <div className="flex justify-end gap-1">
        <button
          type="button"
          onClick={onCancel}
          className="rounded px-2 py-0.5 text-[10px] text-text-muted hover:text-text-secondary"
        >
          Cancel
        </button>
        <button
          type="submit"
          className="rounded bg-accent-primary px-2 py-0.5 text-[10px] font-medium text-white hover:bg-accent-hover"
        >
          Save
        </button>
      </div>
    </form>
  );
}

function CreateForm({
  onSubmit,
  onCancel,
}: {
  onSubmit: (p: Omit<Project, "id" | "createdAt">) => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState("");
  const [mode, setMode] = useState<Project["mode"]>("remote");
  const [url, setUrl] = useState("");
  const [apiKey, setApiKey] = useState("");

  const canSubmit =
    name.trim().length > 0 &&
    (mode === "session"
      ? true
      : url.trim().length > 0 && apiKey.trim().length > 0);

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        if (!canSubmit) return;
        onSubmit({
          name: name.trim(),
          mode,
          url: url.trim(),
          apiKey: mode === "remote" ? apiKey.trim() : undefined,
        });
      }}
      className="flex flex-col gap-1.5 p-1.5"
    >
      <input
        autoFocus
        value={name}
        onChange={(e) => setName(e.target.value)}
        placeholder="Project name"
        className="rounded border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary focus:border-accent-primary focus:outline-none"
      />
      <select
        value={mode}
        onChange={(e) => setMode(e.target.value as Project["mode"])}
        className="rounded border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary focus:border-accent-primary focus:outline-none"
      >
        <option value="session">Same origin (cookie session)</option>
        <option value="remote">Remote (URL + API key)</option>
      </select>
      <input
        value={url}
        onChange={(e) => setUrl(e.target.value)}
        placeholder={mode === "remote" ? "https://cyfr.example.com" : "(blank = same origin)"}
        className="rounded border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary focus:border-accent-primary focus:outline-none"
      />
      {mode === "remote" && (
        <input
          value={apiKey}
          onChange={(e) => setApiKey(e.target.value)}
          placeholder="cyfr_pk_…"
          type="password"
          className="rounded border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary focus:border-accent-primary focus:outline-none"
        />
      )}
      <div className="flex justify-end gap-1">
        <button
          type="button"
          onClick={onCancel}
          className="rounded px-2 py-0.5 text-[10px] text-text-muted hover:text-text-secondary"
        >
          Cancel
        </button>
        <button
          type="submit"
          disabled={!canSubmit}
          className="rounded bg-accent-primary px-2 py-0.5 text-[10px] font-medium text-white hover:bg-accent-hover disabled:opacity-50"
        >
          Create
        </button>
      </div>
    </form>
  );
}

function Chevron() {
  return (
    <svg className="h-3 w-3 text-text-muted" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 15L12 18.75 15.75 15m-7.5-6L12 5.25 15.75 9" />
    </svg>
  );
}

function Check() {
  return (
    <svg className="h-3 w-3 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2.5}>
      <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
    </svg>
  );
}
