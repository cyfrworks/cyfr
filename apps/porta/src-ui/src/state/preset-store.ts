import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import type { Preset, PresetFile } from "../api/types";

interface CyfrResult {
  stdout: string;
  stderr: string;
  success: boolean;
  code: number;
}

async function filesRun(input: Record<string, unknown>): Promise<Record<string, unknown>> {
  const result = await invoke<CyfrResult>("cyfr_command", {
    args: ["run", "catalyst:local.files", "--input", JSON.stringify(input)],
  });
  if (!result.success) throw new Error(result.stderr || "files command failed");
  const parsed = JSON.parse(result.stdout) as Record<string, unknown>;
  return (parsed.result ?? parsed) as Record<string, unknown>;
}

function generatePresetId(): string {
  const bytes = new Uint8Array(6);
  crypto.getRandomValues(bytes);
  const hex = Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return `preset_${hex}`;
}

const PRESETS_PATH = "data/agent_presets.json";

interface PresetState {
  presets: Preset[];
  loaded: boolean;

  loadPresets: () => Promise<void>;
  savePresets: () => Promise<void>;
  createPreset: (
    name: string,
    provider: string,
    model: string,
    catalystRef: string,
  ) => Preset;
  updatePreset: (id: string, updates: Partial<Omit<Preset, "id">>) => void;
  deletePreset: (id: string) => void;
  getByName: (name: string) => Preset | undefined;
}

export const usePresetStore = create<PresetState>((set, get) => ({
  presets: [],
  loaded: false,

  loadPresets: async () => {
    try {
      const readResult = await filesRun({
        action: "read_text",
        path: PRESETS_PATH,
      });
      const content = readResult.content as string;
      const data = JSON.parse(content) as PresetFile;
      set({ presets: data.presets ?? [], loaded: true });
    } catch {
      // File doesn't exist yet — start fresh
      set({ presets: [], loaded: true });
    }
  },

  savePresets: async () => {
    const { presets } = get();
    const data: PresetFile = { presets };
    try {
      await filesRun({
        action: "write_text",
        path: PRESETS_PATH,
        content: JSON.stringify(data, null, 2),
      });
    } catch {
      // Silent
    }
  },

  createPreset: (name, provider, model, catalystRef) => {
    const preset: Preset = {
      id: generatePresetId(),
      name,
      provider,
      model,
      catalyst_ref: catalystRef,
    };
    set({ presets: [...get().presets, preset] });
    get().savePresets();

    // Auto-activate first preset if none active
    import("./agent-store").then(({ useAgentStore }) => {
      if (!useAgentStore.getState().activePreset) {
        useAgentStore.getState().setActivePreset(preset.name);
      }
    });

    return preset;
  },

  updatePreset: (id, updates) => {
    set({
      presets: get().presets.map((p) =>
        p.id === id ? { ...p, ...updates } : p,
      ),
    });
    get().savePresets();
  },

  deletePreset: (id) => {
    set({ presets: get().presets.filter((p) => p.id !== id) });
    get().savePresets();
  },

  getByName: (name) => {
    const lower = name.toLowerCase();
    return get().presets.find((p) => p.name.toLowerCase() === lower);
  },
}));
