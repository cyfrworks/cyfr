import { create } from "zustand";

export type ApprovalRisk = "low" | "medium" | "high";

/**
 * Where the approval originated.
 *   text_intent — AQUA asked the user to confirm something it's about to do
 *                 (via a `ui.request_approval` block). Decision feedback goes
 *                 back into the conversation as a synthetic user message.
 *   tool_call   — Porta's MCP client intercepted a dangerous tool call
 *                 initiated from Porta's UI. Decision unblocks or rejects
 *                 the in-flight tool call.
 */
export type ApprovalSource = "text_intent" | "tool_call";

export interface ApprovalDecision {
  approved: boolean;
  reason?: string;
}

export interface PendingApproval {
  id: string;
  source: ApprovalSource;
  title: string;
  summary: string;
  risk: ApprovalRisk;
  actionDescription: string;
  createdAt: number;
}

export interface ApprovalRequest {
  source: ApprovalSource;
  title: string;
  summary: string;
  risk: ApprovalRisk;
  actionDescription: string;
}

interface ApprovalState {
  pending: PendingApproval[];
  /**
   * Opens an approval card and resolves once the user accepts or rejects.
   * Fires the decision callbacks in FIFO order if the same request is
   * submitted multiple times with the same id (shouldn't happen in practice).
   */
  request: (req: ApprovalRequest) => Promise<ApprovalDecision>;
  accept: (id: string) => void;
  reject: (id: string, reason?: string) => void;
  clearAll: () => void;
}

/**
 * Resolver callbacks indexed by approval id. Kept outside zustand state so we
 * don't store functions in a serializable store.
 */
const callbacks = new Map<string, (d: ApprovalDecision) => void>();

let _seq = 0;
function nextId(): string {
  _seq += 1;
  return `appr_${Date.now()}_${_seq}`;
}

export const useApprovalStore = create<ApprovalState>((set) => ({
  pending: [],

  request: (req) =>
    new Promise<ApprovalDecision>((resolve) => {
      const id = nextId();
      callbacks.set(id, resolve);
      const approval: PendingApproval = { ...req, id, createdAt: Date.now() };
      set((s) => ({ pending: [...s.pending, approval] }));
    }),

  accept: (id) => {
    const cb = callbacks.get(id);
    callbacks.delete(id);
    set((s) => ({ pending: s.pending.filter((p) => p.id !== id) }));
    cb?.({ approved: true });
  },

  reject: (id, reason) => {
    const cb = callbacks.get(id);
    callbacks.delete(id);
    set((s) => ({ pending: s.pending.filter((p) => p.id !== id) }));
    cb?.({ approved: false, reason });
  },

  clearAll: () => {
    for (const [, cb] of callbacks) cb({ approved: false, reason: "cleared" });
    callbacks.clear();
    set({ pending: [] });
  },
}));
