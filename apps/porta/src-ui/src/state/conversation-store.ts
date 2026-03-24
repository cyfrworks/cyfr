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

async function filesRun(input: Record<string, unknown>): Promise<Record<string, unknown>> {
  const result = await invoke<CyfrResult>("cyfr_command", {
    args: ["run", "catalyst:local.files", "--input", JSON.stringify(input)],
  });
  if (!result.success) throw new Error(result.stderr || "files command failed");
  const parsed = JSON.parse(result.stdout) as Record<string, unknown>;
  return (parsed.result ?? parsed) as Record<string, unknown>;
}

export interface ConversationState {
  conversations: ConversationEntry[];
  loading: boolean;

  loadConversations: () => Promise<void>;
  deleteConversation: (id: string) => Promise<void>;
  getConversation: (id: string) => Promise<ConversationFile | null>;
}

export const useConversationStore = create<ConversationState>((set, get) => ({
  conversations: [],
  loading: false,

  loadConversations: async () => {
    set({ loading: true });
    try {
      // List conversation files
      const listResult = await filesRun({
        action: "list",
        path: CONVERSATIONS_PATH,
      });

      const files = (listResult.files as string[]) ?? [];
      const entries: ConversationEntry[] = [];

      // Load metadata for each conversation file
      for (const file of files) {
        if (!file.endsWith(".json")) continue;
        try {
          const readResult = await filesRun({
            action: "read_text",
            path: `${CONVERSATIONS_PATH}/${file}`,
          });

          const content = readResult.content as string;
          const conv = JSON.parse(content) as Record<string, unknown>;

          entries.push({
            id: conv.id as string,
            title: (conv.title as string) || "Untitled",
            updated_at: conv.updated_at as string,
            status:
              conv.running && conv.execution_id ? "running" : "idle",
          });
        } catch {
          // Skip unreadable files
        }
      }

      // Sort by updated_at descending
      entries.sort(
        (a, b) =>
          new Date(b.updated_at).getTime() -
          new Date(a.updated_at).getTime(),
      );

      set({ conversations: entries, loading: false });
    } catch {
      set({ loading: false });
    }
  },

  deleteConversation: async (id: string) => {
    try {
      await filesRun({
        action: "delete",
        path: `${CONVERSATIONS_PATH}/${id}.json`,
      });

      set({
        conversations: get().conversations.filter((c) => c.id !== id),
      });
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
