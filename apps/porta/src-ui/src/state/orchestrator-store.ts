import { create } from "zustand";
import type { McpClient } from "../api/mcp-client";
import type { Orchestrator, AgentDetail } from "../api/types";

const AVAILABLE_TOOLS = [
  "component", "build", "execution", "aqua", "secret", "policy",
  "system", "request_setup", "files", "storage", "schedule", "http",
  "oauth", "native_search",
];

interface OrchestratorState {
  orchestrators: Orchestrator[];
  activeOrchestrator: string | null;
  loaded: boolean;
  loading: boolean;

  // Editor state
  editorAgents: AgentDetail[];
  editorLoading: boolean;
  editingPromptName: string | null;
  editingPromptContent: string;

  // Actions
  loadOrchestrators: (client: McpClient) => Promise<void>;
  selectOrchestrator: (name: string) => void;

  // Editor actions
  loadEditorAgents: (client: McpClient) => Promise<void>;
  setAgentModel: (client: McpClient, name: string, provider: string, model: string) => Promise<void>;
  setAgentModelInherit: (client: McpClient, name: string) => Promise<void>;
  toggleTool: (client: McpClient, name: string, tool: string) => Promise<void>;
  createOrchestrator: (client: McpClient, name: string) => Promise<void>;
  createSubAgent: (client: McpClient, parent: string, name: string) => Promise<void>;
  deleteAgent: (client: McpClient, name: string) => Promise<void>;
  editPrompt: (name: string) => void;
  savePrompt: (client: McpClient, content: string) => Promise<void>;
  cancelPrompt: () => void;
}

export { AVAILABLE_TOOLS };

export const useOrchestratorStore = create<OrchestratorState>((set, get) => ({
  orchestrators: [],
  activeOrchestrator: null,
  loaded: false,
  loading: false,
  editorAgents: [],
  editorLoading: false,
  editingPromptName: null,
  editingPromptContent: "",

  loadOrchestrators: async (client) => {
    set({ loading: true });
    try {
      const listResult = await client.callTool("aqua", {
        action: "list",
        type: "orchestrator",
      });
      const guides = (listResult.guides as Record<string, unknown>[]) ?? [];

      const orchestrators: Orchestrator[] = [];
      for (const g of guides) {
        try {
          const detail = await client.callTool("aqua", {
            action: "get",
            name: g.name as string,
          });
          orchestrators.push({
            name: (detail.name as string) ?? (g.name as string),
            title: (detail.title as string) ?? (g.name as string),
            catalyst_ref: (detail.catalyst_ref as string) ?? "",
            model: (detail.model as string) ?? "",
          });
        } catch {
          orchestrators.push({
            name: g.name as string,
            title: (g.title as string) ?? (g.name as string),
            catalyst_ref: "",
            model: "",
          });
        }
      }

      const active = get().activeOrchestrator;
      const hasActive = active && orchestrators.some((o) => o.name === active);

      set({
        orchestrators,
        loaded: true,
        loading: false,
        activeOrchestrator: hasActive ? active : orchestrators[0]?.name ?? null,
      });
    } catch {
      set({ loaded: true, loading: false });
    }
  },

  selectOrchestrator: (name) => {
    set({ activeOrchestrator: name });
  },

  loadEditorAgents: async (client) => {
    set({ editorLoading: true });
    try {
      // Single list call without type filter — matches AgentLive's editor_load_agents
      const listResult = await client.callTool("aqua", {
        action: "list",
      });
      const guides = (listResult.guides as Record<string, unknown>[]) ?? [];

      const agents: AgentDetail[] = [];

      for (const g of guides) {
        const type = g.type as string;
        if (type !== "orchestrator" && type !== "sub-agent") continue;

        try {
          const detail = await client.callTool("aqua", {
            action: "get",
            name: g.name as string,
          });
          agents.push({
            name: (detail.name as string) ?? (g.name as string),
            title: (detail.title as string) ?? (g.name as string),
            type: type as "orchestrator" | "sub-agent",
            parent: (detail.parent as string) ?? null,
            description: (detail.description as string) ?? "",
            model: (detail.model as string | null) ?? null,
            catalyst_ref: (detail.catalyst_ref as string | null) ?? null,
            visible_tools: (detail.visible_tools as string[] | null) ?? null,
            content: (detail.content as string) ?? "",
          });
        } catch {
          // Skip agents that fail to load
        }
      }

      set({ editorAgents: agents, editorLoading: false });
    } catch {
      set({ editorLoading: false });
    }
  },

  setAgentModel: async (client, name, provider, model) => {
    // Use versionless catalyst ref — matches AgentLive's version-stripping regex
    const providerStore = await import("./provider-store");
    const providers = providerStore.useProviderStore.getState().providers;
    const provInfo = providers.find((p) => p.key === provider);
    const catalystRef = provInfo?.catalystRef
      ? provInfo.catalystRef.replace(/:\d+\.\d+\.\d+$/, "")
      : `catalyst:moonmoon69.${provider}`;
    try {
      await client.callTool("aqua", {
        action: "update",
        name,
        model,
        catalyst_ref: catalystRef,
      });
      // Refresh
      await get().loadEditorAgents(client);
      await get().loadOrchestrators(client);
    } catch {
      // Silent
    }
  },

  setAgentModelInherit: async (client, name) => {
    try {
      await client.callTool("aqua", {
        action: "update",
        name,
        model: null,
        catalyst_ref: null,
      });
      await get().loadEditorAgents(client);
      await get().loadOrchestrators(client);
    } catch {
      // Silent
    }
  },

  toggleTool: async (client, name, tool) => {
    const agent = get().editorAgents.find((a) => a.name === name);
    if (!agent) return;

    const currentTools = agent.visible_tools;
    let newTools: string[];

    if (currentTools === null && tool === "native_search") {
      // First click on unrestricted + native_search → exclusive
      newTools = ["native_search"];
    } else if (currentTools === null) {
      // First click on unrestricted → remove this tool from full set
      newTools = AVAILABLE_TOOLS.filter((t) => t !== tool);
    } else if (tool === "native_search") {
      // native_search is exclusive — toggle on (alone) or off (empty)
      newTools = currentTools.includes("native_search") ? [] : ["native_search"];
    } else if (currentTools.includes(tool)) {
      // Toggle off — also strip native_search if present
      newTools = currentTools.filter((t) => t !== tool && t !== "native_search");
    } else {
      // Toggle on — also strip native_search if present
      newTools = [...currentTools.filter((t) => t !== "native_search"), tool];
    }

    try {
      await client.callTool("aqua", {
        action: "update",
        name,
        visible_tools: newTools,
      });
      await get().loadEditorAgents(client);
    } catch {
      // Silent
    }
  },

  createOrchestrator: async (client, name) => {
    try {
      await client.callTool("aqua", {
        action: "create_agent",
        name,
        title: name,
        content: `# ${name}\n\nYou are ${name}.`,
      });
      await get().loadEditorAgents(client);
      await get().loadOrchestrators(client);
    } catch {
      // Silent
    }
  },

  createSubAgent: async (client, parent, name) => {
    try {
      await client.callTool("aqua", {
        action: "create",
        parent,
        name,
        title: name,
        description: `Spawn a ${name} specialist.`,
        content: `# ${name}\n\nYou are the ${name} agent.`,
      });
      await get().loadEditorAgents(client);
    } catch {
      // Silent
    }
  },

  deleteAgent: async (client, name) => {
    try {
      await client.callTool("aqua", {
        action: "delete",
        name,
      });
      await get().loadEditorAgents(client);
      await get().loadOrchestrators(client);
    } catch {
      // Silent
    }
  },

  editPrompt: (name) => {
    const agent = get().editorAgents.find((a) => a.name === name);
    if (agent) {
      set({ editingPromptName: name, editingPromptContent: agent.content });
    }
  },

  savePrompt: async (client, content) => {
    const name = get().editingPromptName;
    if (!name) return;

    try {
      await client.callTool("aqua", {
        action: "update",
        name,
        content,
      });
      set({ editingPromptName: null, editingPromptContent: "" });
      await get().loadEditorAgents(client);
    } catch {
      // Silent
    }
  },

  cancelPrompt: () => {
    set({ editingPromptName: null, editingPromptContent: "" });
  },
}));
