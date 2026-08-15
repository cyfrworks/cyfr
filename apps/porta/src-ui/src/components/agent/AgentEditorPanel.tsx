import { useState, useEffect } from "react";
import { useOrchestratorStore } from "../../state/orchestrator-store";
import { useProviderStore } from "../../state/provider-store";
import { useAgentStore } from "../../state/agent-store";
import type { AgentDetail } from "../../api/types";

export function AgentEditorPanel({ onClose }: { onClose: () => void }) {
  const editorAgents = useOrchestratorStore((s) => s.editorAgents);
  const editorLoading = useOrchestratorStore((s) => s.editorLoading);
  const editingPromptName = useOrchestratorStore((s) => s.editingPromptName);
  const providers = useProviderStore((s) => s.providers);
  const client = useAgentStore((s) => s.client);

  const [newOrchName, setNewOrchName] = useState("");
  const [newSubName, setNewSubName] = useState<Record<string, string>>({});

  // Always reload agents and providers when the modal opens (matches LiveView behavior)
  useEffect(() => {
    const { providers: provs } = useProviderStore.getState();
    const hasAny = provs.some((p) => p.ready || p.configured);
    if (!hasAny) useProviderStore.getState().loadAll();

    (async () => {
      // Ensure MCP client is initialized (it's null until first submit)
      let cl = useAgentStore.getState().client;
      if (!cl) {
        await useAgentStore.getState().initClient();
        cl = useAgentStore.getState().client;
      }
      if (cl) {
        useOrchestratorStore.getState().loadEditorAgents(cl);
      }
    })();
  }, []);

  const orchestrators = editorAgents.filter((a) => a.type === "orchestrator");
  const subAgents = editorAgents.filter((a) => a.type === "sub-agent");
  const readyProviders = providers.filter((p) => p.ready);

  const handleCreateOrchestrator = () => {
    const name = newOrchName.trim();
    if (!name || !client) return;
    useOrchestratorStore.getState().createOrchestrator(client, name);
    setNewOrchName("");
  };

  const handleCreateSubAgent = (parent: string) => {
    const name = (newSubName[parent] ?? "").trim();
    if (!name || !client) return;
    useOrchestratorStore.getState().createSubAgent(client, parent, name);
    setNewSubName({ ...newSubName, [parent]: "" });
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <div className="mx-4 flex w-full max-w-2xl flex-col rounded-xl border border-border-default bg-surface-base shadow-2xl max-h-[85vh]">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-border-default px-4 py-3 shrink-0">
          <div className="flex items-center gap-2">
            <span className="text-sm font-medium text-text-primary">
              Agents
            </span>
            {editorLoading && (
              <span className="text-[10px] text-text-muted animate-pulse">
                Loading...
              </span>
            )}
          </div>
          <button
            onClick={onClose}
            className="text-text-muted hover:text-text-secondary transition-colors"
          >
            <svg
              className="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              strokeWidth={2}
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Orchestrators */}
          {orchestrators.map((orch) => (
            <div key={orch.name} className="space-y-2">
              <AgentCard
                agent={orch}
                providers={readyProviders}
                client={client}
              />

              {/* Sub-agents for this orchestrator */}
              {subAgents
                .filter((s) => s.parent === orch.name)
                .map((sub) => (
                  <div key={sub.name} className="ml-4">
                    <AgentCard
                      agent={sub}
                      providers={readyProviders}
                      client={client}
                    />
                  </div>
                ))}

              {/* Add sub-agent */}
              <div className="ml-4 flex gap-1.5">
                <input
                  value={newSubName[orch.name] ?? ""}
                  onChange={(e) =>
                    setNewSubName({
                      ...newSubName,
                      [orch.name]: e.target.value,
                    })
                  }
                  placeholder="Sub-agent name"
                  className="flex-1 rounded-md border border-border-default bg-surface-raised px-2 py-1 text-xs text-text-primary outline-hidden focus:border-border-focus"
                  onKeyDown={(e) => {
                    if (e.key === "Enter") handleCreateSubAgent(orch.name);
                  }}
                />
                <button
                  onClick={() => handleCreateSubAgent(orch.name)}
                  disabled={!(newSubName[orch.name] ?? "").trim()}
                  className="rounded-md border border-border-default px-2 py-1 text-xs text-text-secondary hover:bg-surface-raised disabled:opacity-30"
                >
                  + Sub-Agent
                </button>
              </div>
            </div>
          ))}

          {/* Add orchestrator */}
          <div className="flex gap-1.5">
            <input
              value={newOrchName}
              onChange={(e) => setNewOrchName(e.target.value)}
              placeholder="Orchestrator name"
              className="flex-1 rounded-md border border-border-default bg-surface-raised px-2 py-1 text-xs text-text-primary outline-hidden focus:border-border-focus"
              onKeyDown={(e) => {
                if (e.key === "Enter") handleCreateOrchestrator();
              }}
            />
            <button
              onClick={handleCreateOrchestrator}
              disabled={!newOrchName.trim()}
              className="rounded-md border border-border-default px-2 py-1 text-xs text-text-secondary hover:bg-surface-raised disabled:opacity-30"
            >
              + Orchestrator
            </button>
          </div>
        </div>

        {/* Prompt editor modal */}
        {editingPromptName && <PromptEditorModal />}
      </div>
    </div>
  );
}

function AgentCard({
  agent,
  providers,
  client,
}: {
  agent: AgentDetail;
  providers: {
    key: string;
    label: string;
    models: string[];
    catalystRef: string;
  }[];
  client: ReturnType<typeof useAgentStore.getState>["client"];
}) {
  const store = useOrchestratorStore;

  // Detect current provider from catalyst_ref
  const currentProvider = agent.catalyst_ref
    ? (providers.find((p) => agent.catalyst_ref!.includes(p.key))?.key ?? "")
    : "";
  const currentModels =
    providers.find((p) => p.key === currentProvider)?.models ?? [];
  const isInherited =
    agent.type === "sub-agent" && !agent.catalyst_ref && !agent.model;
  const handleProviderChange = (value: string) => {
    if (!client) return;
    if (value === "inherit") {
      store.getState().setAgentModelInherit(client, agent.name);
    } else {
      const prov = providers.find((p) => p.key === value);
      const firstModel = prov?.models[0] ?? "";
      if (firstModel) {
        store.getState().setAgentModel(client, agent.name, value, firstModel);
      }
    }
  };

  const handleModelChange = (model: string) => {
    if (!client || !currentProvider) return;
    store.getState().setAgentModel(client, agent.name, currentProvider, model);
  };

  const handleDelete = () => {
    if (!client) return;
    store.getState().deleteAgent(client, agent.name);
  };

  return (
    <div className="rounded-lg border border-border-default bg-surface-raised p-3 space-y-2">
      {/* Header */}
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="rounded bg-accent-primary/10 px-1.5 py-0.5 text-[10px] font-medium text-accent-primary">
            {agent.type}
          </span>
          <span className="text-xs font-medium text-text-primary">
            {agent.name}
          </span>
          {agent.title !== agent.name && (
            <span className="text-[10px] text-text-muted">{agent.title}</span>
          )}
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={() => store.getState().editPrompt(agent.name)}
            className="rounded px-1.5 py-0.5 text-[10px] text-text-secondary hover:bg-surface-base"
          >
            prompt
          </button>
          {agent.name !== "aqua" && (
            <button
              onClick={handleDelete}
              className="rounded px-1.5 py-0.5 text-[10px] text-text-muted hover:text-status-error"
            >
              delete
            </button>
          )}
        </div>
      </div>

      {/* Description (sub-agents only) */}
      {agent.type === "sub-agent" && agent.description && (
        <p className="text-[10px] text-text-muted line-clamp-2">
          {agent.description}
        </p>
      )}

      {/* Model selection */}
      <div className="flex gap-1.5">
        <select
          value={isInherited ? "inherit" : currentProvider}
          onChange={(e) => handleProviderChange(e.target.value)}
          className="flex-1 rounded-md border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary outline-hidden focus:border-border-focus"
        >
          {agent.type === "sub-agent" && (
            <option value="inherit">inherit</option>
          )}
          {!isInherited && !currentProvider && (
            <option value="" disabled>
              Provider...
            </option>
          )}
          {providers.map((p) => (
            <option key={p.key} value={p.key}>
              {p.label}
            </option>
          ))}
        </select>
        {!isInherited && (
          <select
            value={agent.model ?? ""}
            onChange={(e) => handleModelChange(e.target.value)}
            className="flex-1 rounded-md border border-border-default bg-surface-base px-2 py-1 text-xs text-text-primary outline-hidden focus:border-border-focus"
          >
            {!agent.model && (
              <option value="" disabled>
                Model...
              </option>
            )}
            {currentModels.map((m) => (
              <option key={m} value={m}>
                {m}
              </option>
            ))}
          </select>
        )}
      </div>
    </div>
  );
}

function PromptEditorModal() {
  const editingPromptName = useOrchestratorStore((s) => s.editingPromptName);
  const editingPromptContent = useOrchestratorStore(
    (s) => s.editingPromptContent,
  );
  const savePrompt = useOrchestratorStore((s) => s.savePrompt);
  const cancelPrompt = useOrchestratorStore((s) => s.cancelPrompt);
  const client = useAgentStore((s) => s.client);

  const [content, setContent] = useState(editingPromptContent);

  useEffect(() => {
    setContent(editingPromptContent);
  }, [editingPromptContent]);

  const handleSave = () => {
    if (client) {
      savePrompt(client, content);
    }
  };

  return (
    <div className="fixed inset-0 z-[60] flex items-center justify-center bg-black/60">
      <div className="mx-4 w-full max-w-3xl rounded-xl bg-surface-base p-4 shadow-xl">
        <div className="mb-3 flex items-center justify-between">
          <span className="text-sm font-medium text-text-primary">
            Edit prompt: {editingPromptName}
          </span>
        </div>
        <textarea
          value={content}
          onChange={(e) => setContent(e.target.value)}
          rows={20}
          className="w-full rounded-lg border border-border-default bg-surface-raised p-3 font-mono text-xs text-text-primary outline-hidden focus:border-border-focus"
        />
        <div className="mt-3 flex justify-end gap-2">
          <button
            onClick={cancelPrompt}
            className="rounded-md border border-border-default px-3 py-1.5 text-xs text-text-secondary hover:bg-surface-raised"
          >
            Cancel
          </button>
          <button
            onClick={handleSave}
            className="btn-primary rounded-md px-3 py-1.5 text-xs"
          >
            Save
          </button>
        </div>
      </div>
    </div>
  );
}
