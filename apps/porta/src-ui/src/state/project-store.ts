import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import { useConnectionStore, type RuntimeMode } from "./connection-store";

/**
 * Named cyfr projects — one per instance the user can talk to (local Docker,
 * home server, work laptop, etc). "Remote" is still single-user; each project
 * is the user's own cyfr instance.
 *
 * For Phase 6 we persist the project list in localStorage and sync the
 * currently-selected project's mode/url/apiKey into Rust's porta.json via
 * the existing `save_porta_mode` command. Rust-side per-project key storage
 * is a future hardening step — for now, API keys live alongside the project
 * config in localStorage.
 */

const STORAGE_KEY = "porta.projects";
const ACTIVE_KEY = "porta.activeProjectId";

export interface Project {
  id: string;
  name: string;
  mode: RuntimeMode;
  url: string;
  apiKey?: string;
  createdAt: number;
}

interface ProjectsState {
  projects: Project[];
  activeProjectId: string | null;

  hydrate: () => void;
  seedFromConnection: () => void;
  createProject: (p: Omit<Project, "id" | "createdAt">) => Project;
  updateProject: (id: string, updates: Partial<Omit<Project, "id">>) => void;
  deleteProject: (id: string) => void;
  selectProject: (id: string) => Promise<void>;
}

function save(projects: Project[], activeId: string | null) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(projects));
    if (activeId) localStorage.setItem(ACTIVE_KEY, activeId);
    else localStorage.removeItem(ACTIVE_KEY);
  } catch {
    // non-fatal
  }
}

function load(): { projects: Project[]; activeProjectId: string | null } {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    const projects = raw ? (JSON.parse(raw) as Project[]) : [];
    const activeProjectId = localStorage.getItem(ACTIVE_KEY);
    return { projects, activeProjectId };
  } catch {
    return { projects: [], activeProjectId: null };
  }
}

let _seq = 0;
function newId(): string {
  _seq += 1;
  return `prj_${Date.now()}_${_seq}`;
}

function defaultName(mode: RuntimeMode): string {
  if (mode === "remote") return "My cyfr";
  if (mode === "local-managed") return "Local";
  return "Local (attached)";
}

export const useProjectStore = create<ProjectsState>((set, get) => ({
  projects: [],
  activeProjectId: null,

  hydrate: () => {
    const loaded = load();
    set(loaded);
  },

  seedFromConnection: () => {
    const { projects } = get();
    if (projects.length > 0) return;

    const conn = useConnectionStore.getState();
    if (!conn.mode) return;

    const project: Project = {
      id: newId(),
      name: defaultName(conn.mode),
      mode: conn.mode,
      url: conn.cyfrUrl,
      createdAt: Date.now(),
    };

    const next = [project];
    set({ projects: next, activeProjectId: project.id });
    save(next, project.id);
  },

  createProject: (p) => {
    const project: Project = { ...p, id: newId(), createdAt: Date.now() };
    const current = get();
    const next = [...current.projects, project];
    save(next, current.activeProjectId);
    set({ projects: next });
    return project;
  },

  updateProject: (id, updates) => {
    set((s) => {
      const next = s.projects.map((p) =>
        p.id === id ? { ...p, ...updates } : p,
      );
      save(next, s.activeProjectId);
      return { projects: next };
    });
  },

  deleteProject: (id) => {
    set((s) => {
      const next = s.projects.filter((p) => p.id !== id);
      const nextActive =
        s.activeProjectId === id ? next[0]?.id ?? null : s.activeProjectId;
      save(next, nextActive);
      return { projects: next, activeProjectId: nextActive };
    });
  },

  selectProject: async (id) => {
    const { projects } = get();
    const project = projects.find((p) => p.id === id);
    if (!project) return;

    set({ activeProjectId: id });
    save(get().projects, id);

    // Push the project's mode/url/key into Rust-side porta.json so the rest
    // of Porta (backend lifecycle, SSE proxy, etc.) sees consistent config.
    try {
      await invoke("save_porta_mode", {
        mode: project.mode,
        url: project.url,
        apiKey: project.apiKey ?? "",
      });
    } catch (err) {
      console.error("[project-store] save_porta_mode failed:", err);
    }

    // Discard the old client and reload connection + conversations so the UI
    // reflects the new instance.
    useConnectionStore.getState().resetMcpClient();
    await useConnectionStore.getState().fetchMode();

    const { useAgentStore } = await import("./agent-store");
    useAgentStore.getState().newChat();

    const { useConversationStore } = await import("./conversation-store");
    try {
      await useConversationStore.getState().loadConversations();
    } catch {
      // non-fatal — new project might not be reachable yet
    }
  },
}));
