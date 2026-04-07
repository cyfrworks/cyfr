import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import type { McpClient } from "../api/mcp-client";
import type { TinctureEntry } from "../api/types";

interface CyfrResult {
  stdout: string;
  stderr: string;
  success: boolean;
  code: number;
}

interface TinctureState {
  tinctures: TinctureEntry[];
  loading: boolean;
  activeTincture: string | null;
  openedTinctures: string[];

  loadTinctures: (client: McpClient) => Promise<void>;
  toggleVisibility: (client: McpClient, publisher: string, name: string) => Promise<void>;
  selectTincture: (name: string) => void;
  closeTincture: (name: string) => void;
  refreshTinctures: (client: McpClient) => Promise<void>;
}

export const useTinctureStore = create<TinctureState>((set, get) => ({
  tinctures: [],
  loading: false,
  activeTincture: null,
  openedTinctures: [],

  loadTinctures: async (client) => {
    set({ loading: true });
    try {
      const listResult = await client.callTool("component", {
        action: "list",
        type: "tincture",
        limit: 1000,
      });
      const components = (listResult.components as Record<string, unknown>[]) ?? [];

      const tinctures: TinctureEntry[] = [];
      for (const c of components) {
        const publisher = (c.publisher as string) ?? "local";
        const name = (c.name as string) ?? "";
        if (!name) continue;

        let title = name;
        try {
          const manifestStr = c.manifest as string | undefined;
          if (manifestStr) {
            const manifest = JSON.parse(manifestStr) as Record<string, unknown>;
            title = (manifest.description as string) ?? name;
          }
        } catch {
          title = (c.description as string) ?? name;
        }

        let isPublic = false;
        try {
          const visResult = await client.callTool("tincture_visibility", {
            action: "get",
            publisher,
            name,
          });
          isPublic = (visResult.public as boolean) ?? false;
        } catch {
          // Default to private
        }

        tinctures.push({
          name,
          publisher,
          title,
          icon: null,
          public: isPublic,
          component_ref: (c.component_ref as string) ?? `tincture:${publisher}.${name}`,
        });
      }

      set({ tinctures, loading: false });
    } catch {
      set({ loading: false });
    }
  },

  toggleVisibility: async (client, publisher, name) => {
    const tincture = get().tinctures.find((t) => t.publisher === publisher && t.name === name);
    if (!tincture) return;

    const newPublic = !tincture.public;

    set({
      tinctures: get().tinctures.map((t) =>
        t.publisher === publisher && t.name === name
          ? { ...t, public: newPublic }
          : t
      ),
    });

    try {
      await client.callTool("tincture_visibility", {
        action: "set",
        publisher,
        name,
        public: newPublic,
      });
    } catch {
      set({
        tinctures: get().tinctures.map((t) =>
          t.publisher === publisher && t.name === name
            ? { ...t, public: !newPublic }
            : t
        ),
      });
    }
  },

  selectTincture: (name) => {
    const opened = get().openedTinctures;
    set({
      activeTincture: name,
      openedTinctures: opened.includes(name) ? opened : [...opened, name],
    });
  },

  closeTincture: (name) => {
    const opened = get().openedTinctures.filter((n) => n !== name);
    const active = get().activeTincture === name ? (opened[0] ?? null) : get().activeTincture;
    set({ openedTinctures: opened, activeTincture: active });
  },

  refreshTinctures: async (client) => {
    try {
      await invoke<CyfrResult>("cyfr_command", { args: ["register"] });
    } catch {
      // Non-fatal
    }
    await get().loadTinctures(client);
  },
}));
