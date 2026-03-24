import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";

export interface UpdateInfo {
  kind: "cyfr" | "porta";
  current: string;
  latest: string;
  url?: string;
}

export interface ConnectionState {
  cyfrUrl: string;
  bootComplete: boolean;
  bootState: string;
  bootMessage: string;
  bootProgress: number;
  updating: boolean;
  updateInfo: UpdateInfo | null;

  setBootComplete: (complete: boolean) => void;
  setBootState: (state: string, message: string, progress: number) => void;
  startUpdate: (info: UpdateInfo) => void;
  finishUpdate: () => void;
  fetchCyfrUrl: () => Promise<void>;
}

export const useConnectionStore = create<ConnectionState>((set) => ({
  cyfrUrl: "http://localhost:4000",
  bootComplete: false,
  bootState: "checking",
  bootMessage: "",
  bootProgress: 0,
  updating: false,
  updateInfo: null,

  setBootComplete: (complete) => set({ bootComplete: complete }),

  setBootState: (state, message, progress) =>
    set({ bootState: state, bootMessage: message, bootProgress: progress }),

  startUpdate: (info) => set({ updating: true, updateInfo: info }),
  finishUpdate: () => set({ updating: false, updateInfo: null }),

  fetchCyfrUrl: async () => {
    try {
      const url = await invoke<string>("get_cyfr_url");
      set({ cyfrUrl: url });
    } catch {
      // Fall back to default
    }
  },
}));
