import { create } from "zustand";
import type { Intent } from "../harness/porta-actions-parser";

/**
 * Activity lane records: every dispatched intent, failed dispatch, and
 * parser drop flows through here so the user (and future audit flows) can
 * review what the shell did on AQUA's behalf.
 *
 * Entries are capped at `CAP` newest-first to keep the store bounded; the
 * UI panel is the only consumer today but Phase 5 will also read this for
 * approval audit.
 */

export type ActivityEntry =
  | {
      kind: "dispatched";
      id: string;
      intent: Intent;
      timestamp: number;
    }
  | {
      kind: "dispatch_error";
      id: string;
      intent: Intent;
      error: string;
      timestamp: number;
    }
  | {
      kind: "drop";
      id: string;
      raw: unknown;
      reason: string;
      timestamp: number;
    };

const CAP = 100;

/**
 * Input shape for {@link ActivityState.log}. `id` and `timestamp` are filled
 * in automatically if omitted. The conditional type below distributes over
 * the ActivityEntry union so TS keeps the per-variant required fields.
 */
export type ActivityLogInput = ActivityEntry extends infer T
  ? T extends ActivityEntry
    ? Omit<T, "id" | "timestamp"> & { id?: string; timestamp?: number }
    : never
  : never;

interface ActivityState {
  entries: ActivityEntry[];
  unseen: number;
  log: (entry: ActivityLogInput) => void;
  markSeen: () => void;
  clear: () => void;
}

let _seq = 0;
function nextId(): string {
  _seq += 1;
  return `a_${Date.now()}_${_seq}`;
}

export const useActivityStore = create<ActivityState>((set) => ({
  entries: [],
  unseen: 0,

  log: (entry) => {
    const complete = {
      ...entry,
      id: entry.id ?? nextId(),
      timestamp: entry.timestamp ?? Date.now(),
    } as ActivityEntry;
    set((s) => ({
      entries: [complete, ...s.entries].slice(0, CAP),
      unseen: s.unseen + 1,
    }));
  },

  markSeen: () => set({ unseen: 0 }),

  clear: () => set({ entries: [], unseen: 0 }),
}));
