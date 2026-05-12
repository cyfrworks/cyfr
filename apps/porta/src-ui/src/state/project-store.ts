import { create } from "zustand";
import { host } from "../host";
import { useConnectionStore, type RuntimeMode } from "./connection-store";

/**
 * Named cyfr projects — one per instance the user can talk to (the same-origin
 * deployment, a home server, a work box, …). Still single-user; each project is
 * one of the user's own cyfr instances.
 *
 * The project list lives in localStorage; selecting a project writes its
 * mode/url/apiKey into the host config blob so the rest of the app picks it up.
 */

const STORAGE_KEY = "aqua.projects";
const ACTIVE_KEY = "aqua.activeProjectId";

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
  return mode === "remote" ? "Remote cyfr" : "My cyfr";
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

    // Push the project's mode/url/key into the host config so the rest of the
    // app (MCP client, SSE) sees a consistent connection.
    host.patchConfig({
      mode: project.mode,
      cyfrUrl: project.url,
      apiKey: project.apiKey ?? "",
    });

    // Discard the old client and reload connection + conversations so the UI
    // reflects the new instance.
    useConnectionStore.getState().resetMcpClient();
    useConnectionStore.getState().refresh();

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
