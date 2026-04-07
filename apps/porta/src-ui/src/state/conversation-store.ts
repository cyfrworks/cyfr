import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";
import type { ConversationEntry, ConversationFile } from "../api/types";

interface CyfrResult {
  stdout: string;
  stderr: string;
  success: boolean;
  code: number;
}

const CONVERSATIONS_PATH = "data/agent_conversations";
const INDEX_PATH = `${CONVERSATIONS_PATH}/index.json`;

async function filesRun(input: Record<string, unknown>): Promise<Record<string, unknown>> {
  const result = await invoke<CyfrResult>("cyfr_command", {
    args: ["run", "catalyst:local.files", "--input", JSON.stringify(input)],
  });
  if (!result.success) throw new Error(result.stderr || "files command failed");
  const parsed = JSON.parse(result.stdout) as Record<string, unknown>;
  return (parsed.result ?? parsed) as Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// Index helpers — single file read instead of N per-conversation reads
// ---------------------------------------------------------------------------

async function readIndex(): Promise<ConversationEntry[]> {
  try {
    const result = await filesRun({ action: "read_text", path: INDEX_PATH });
    const index = JSON.parse(result.content as string) as { entries: ConversationEntry[] };
    return index.entries ?? [];
  } catch {
    return []; // No index yet
  }
}

async function writeIndex(entries: ConversationEntry[]): Promise<void> {
  await filesRun({
    action: "write_text",
    path: INDEX_PATH,
    content: JSON.stringify({ entries }),
  });
}

/** Full scan of conversation files — used as fallback when index is missing. */
async function rebuildIndex(): Promise<ConversationEntry[]> {
  const listResult = await filesRun({ action: "list", path: CONVERSATIONS_PATH });
  const files = (listResult.files as string[]) ?? [];
  const entries: ConversationEntry[] = [];

  for (const file of files) {
    if (!file.endsWith(".json") || file === "index.json") continue;
    try {
      const readResult = await filesRun({
        action: "read_text",
        path: `${CONVERSATIONS_PATH}/${file}`,
      });
      const conv = JSON.parse(readResult.content as string) as Record<string, unknown>;
      entries.push({
        id: conv.id as string,
        title: (conv.title as string) || "Untitled",
        updated_at: conv.updated_at as string,
        status: conv.running && conv.execution_id ? "running" : "idle",
      });
    } catch {
      // Skip unreadable files
    }
  }

  if (entries.length > 0) {
    entries.sort(
      (a, b) => new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime(),
    );
    await writeIndex(entries).catch(() => {});
  }

  return entries;
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

export interface ConversationState {
  conversations: ConversationEntry[];
  loading: boolean;

  loadConversations: () => Promise<void>;
  upsertIndex: (entry: ConversationEntry) => Promise<void>;
  deleteConversation: (id: string) => Promise<void>;
  getConversation: (id: string) => Promise<ConversationFile | null>;
}

export const useConversationStore = create<ConversationState>((set, get) => ({
  conversations: [],
  loading: false,

  loadConversations: async () => {
    set({ loading: true });
    try {
      let entries = await readIndex();

      // Fallback: rebuild from individual files if index doesn't exist yet
      if (entries.length === 0) {
        entries = await rebuildIndex();
      }

      // List actual files on disk to detect orphaned index entries
      let fileIds: Set<string> | null = null;
      try {
        const listResult = await filesRun({ action: "list", path: CONVERSATIONS_PATH });
        const files = (listResult.files as string[]) ?? [];
        fileIds = new Set(
          files
            .filter((f) => f.endsWith(".json") && f !== "index.json")
            .map((f) => f.replace(/\.json$/, "")),
        );
      } catch {
        // Can't list — skip orphan cleanup
      }

      let indexDirty = false;

      // Remove orphaned index entries (no backing file on disk)
      if (fileIds) {
        const before = entries.length;
        entries = entries.filter((e) => fileIds!.has(e.id));
        if (entries.length < before) {
          indexDirty = true;
        }
      }

      // Verify "running" entries — they may have completed while we weren't watching.
      // Read the actual conversation file to check if it's still running.
      for (const entry of entries) {
        if (entry.status !== "running") continue;
        try {
          const result = await filesRun({
            action: "read_text",
            path: `${CONVERSATIONS_PATH}/${entry.id}.json`,
          });
          const conv = JSON.parse(result.content as string) as Record<string, unknown>;
          if (!conv.running && !conv.execution_id) {
            entry.status = "idle";
            indexDirty = true;
          }
        } catch {
          // Can't read file — mark as idle
          entry.status = "idle";
          indexDirty = true;
        }
      }
      if (indexDirty) {
        await writeIndex(entries).catch(() => {});
      }

      entries.sort(
        (a, b) => new Date(b.updated_at).getTime() - new Date(a.updated_at).getTime(),
      );

      set({ conversations: entries, loading: false });
    } catch {
      set({ loading: false });
    }
  },

  /** Update a single entry in the index without re-reading all files. */
  upsertIndex: async (entry: ConversationEntry) => {
    const updated = get().conversations.filter((c) => c.id !== entry.id);
    updated.unshift(entry);
    set({ conversations: updated });
    await writeIndex(updated).catch(() => {});
  },

  deleteConversation: async (id: string) => {
    try {
      await filesRun({
        action: "delete",
        path: `${CONVERSATIONS_PATH}/${id}.json`,
      });

      const updated = get().conversations.filter((c) => c.id !== id);
      set({ conversations: updated });
      await writeIndex(updated).catch(() => {});
    } catch {
      // Silent
    }
  },

  getConversation: async (id: string): Promise<ConversationFile | null> => {
    try {
      const readResult = await filesRun({
        action: "read_text",
        path: `${CONVERSATIONS_PATH}/${id}.json`,
      });

      const content = readResult.content as string;
      return JSON.parse(content) as ConversationFile;
    } catch {
      return null;
    }
  },
}));
