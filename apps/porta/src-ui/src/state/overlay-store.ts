import { create } from "zustand";

export type OverlayState = "closed" | "peek" | "half" | "full";
type OpenState = Exclude<OverlayState, "closed">;

const STORAGE_KEY = "porta.overlay.lastOpenState";

function loadLastOpenState(): OpenState {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved === "peek" || saved === "half" || saved === "full") return saved;
  } catch {
    // localStorage unavailable (private mode, etc.) — fall through.
  }
  return "half";
}

interface OverlayStoreState {
  state: OverlayState;
  /** Remembers which open size the user last used, so re-opening restores it. */
  lastOpenState: OpenState;
  /** Monotonic counter — any subscriber focuses the composer input on change. */
  focusInputNonce: number;

  open: (state?: OpenState) => void;
  close: () => void;
  toggle: () => void;
  setOverlayState: (state: OverlayState) => void;
  focusInput: () => void;
}

export const useOverlayStore = create<OverlayStoreState>((set, get) => ({
  state: "closed",
  lastOpenState: loadLastOpenState(),
  focusInputNonce: 0,

  open: (next) => {
    const target = next ?? get().lastOpenState;
    set({ state: target, lastOpenState: target });
    try {
      localStorage.setItem(STORAGE_KEY, target);
    } catch {
      // non-fatal
    }
  },
  close: () => set({ state: "closed" }),
  toggle: () => {
    if (get().state === "closed") get().open();
    else get().close();
  },
  setOverlayState: (state) => {
    if (state === "closed") get().close();
    else get().open(state);
  },
  focusInput: () => set((s) => ({ focusInputNonce: s.focusInputNonce + 1 })),
}));
