import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";

export interface ConnectionState {
  cyfrUrl: string;
  bootComplete: boolean;
  bootState: string;
  bootMessage: string;
  bootProgress: number;

  setBootComplete: (complete: boolean) => void;
  setBootState: (state: string, message: string, progress: number) => void;
  fetchCyfrUrl: () => Promise<void>;
}

export const useConnectionStore = create<ConnectionState>((set) => ({
  cyfrUrl: "http://localhost:4000",
  bootComplete: false,
  bootState: "checking",
  bootMessage: "",
  bootProgress: 0,

  setBootComplete: (complete) => set({ bootComplete: complete }),

  setBootState: (state, message, progress) =>
    set({ bootState: state, bootMessage: message, bootProgress: progress }),

  fetchCyfrUrl: async () => {
    try {
      const url = await invoke<string>("get_cyfr_url");
      set({ cyfrUrl: url });
    } catch {
      // Fall back to default
    }
  },
}));
