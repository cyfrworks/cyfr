import { useState, useEffect } from "react";
import { usePresetStore } from "../../state/preset-store";
import { useProviderStore } from "../../state/provider-store";
import { useAgentStore } from "../../state/agent-store";

export function PresetPanel() {
  const presets = usePresetStore((s) => s.presets);
  const createPreset = usePresetStore((s) => s.createPreset);
  const deletePreset = usePresetStore((s) => s.deletePreset);
  const activePreset = useAgentStore((s) => s.activePreset);
  const setActivePreset = useAgentStore((s) => s.setActivePreset);
  const providers = useProviderStore((s) => s.providers);
  const loadAll = useProviderStore((s) => s.loadAll);

  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [selProvider, setSelProvider] = useState("");
  const [selModel, setSelModel] = useState("");

  useEffect(() => {
    const hasAny = providers.some((p) => p.ready || p.secretSet);
    if (!hasAny) loadAll();
  }, [providers, loadAll]);

  const readyProviders = providers.filter((p) => p.ready);
  const currentProviderInfo = providers.find((p) => p.key === selProvider);
  const availableModels = currentProviderInfo?.models ?? [];

  const handleCreate = () => {
    if (!name.trim() || !selProvider || !selModel) return;
    const provInfo = providers.find((p) => p.key === selProvider);
    const ref = provInfo?.catalystRef.replace(/:\d+\.\d+\.\d+$/, "") ?? `catalyst:moonmoon69.${selProvider}`;
    createPreset(name.trim(), selProvider, selModel, ref);
    setCreating(false);
    setName("");
    setSelProvider("");
    setSelModel("");
  };

  return (
    <div className="border-b border-border-default bg-surface-base px-4 py-3">
      <div className="mx-auto max-w-3xl">
        <div className="flex items-center justify-between">
          <span className="text-xs font-medium text-text-secondary">Presets</span>
          {!creating && (
            <button
              onClick={() => setCreating(true)}
              className="text-xs text-accent-primary hover:text-accent-hover"
            >
              + New
            </button>
          )}
        </div>

        {/* Create form */}
        {creating && (
          <div className="mt-2 space-y-2 rounded-lg border border-border-default bg-surface-raised p-2.5">
            <input
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Preset name"
              className="w-full rounded-md border border-border-default bg-surface-base px-2.5 py-1.5 text-xs text-text-primary outline-none focus:border-border-focus"
              autoFocus
            />
            <div className="flex gap-2">
              <select
                value={selProvider}
                onChange={(e) => { setSelProvider(e.target.value); setSelModel(""); }}
                className="flex-1 rounded-md border border-border-default bg-surface-base px-2.5 py-1.5 text-xs text-text-primary outline-none focus:border-border-focus"
              >
                <option value="" disabled>Provider...</option>
                {readyProviders.map((p) => (
                  <option key={p.key} value={p.key}>{p.label}</option>
                ))}
              </select>
              <select
                value={selModel}
                onChange={(e) => setSelModel(e.target.value)}
                className="flex-1 rounded-md border border-border-default bg-surface-base px-2.5 py-1.5 text-xs text-text-primary outline-none focus:border-border-focus"
              >
                <option value="" disabled>Model...</option>
                {availableModels.map((m) => (
                  <option key={m} value={m}>{m}</option>
                ))}
              </select>
            </div>
            <div className="flex justify-end gap-2">
              <button
                onClick={() => { setCreating(false); setName(""); setSelProvider(""); setSelModel(""); }}
                className="rounded-md border border-border-default px-2.5 py-1 text-xs text-text-secondary hover:bg-surface-base"
              >
                Cancel
              </button>
              <button
                onClick={handleCreate}
                disabled={!name.trim() || !selProvider || !selModel}
                className="btn-primary rounded-md px-2.5 py-1 text-xs disabled:opacity-30"
              >
                Create
              </button>
            </div>
          </div>
        )}

        {/* Preset list */}
        <div className="mt-2 space-y-1">
          {presets.length === 0 && !creating && (
            <p className="rounded-md border border-dashed border-border-default p-3 text-center text-xs text-text-muted">
              No presets yet
            </p>
          )}
          {presets.map((p) => (
            <div
              key={p.id}
              onClick={() => setActivePreset(p.name)}
              className={`flex cursor-pointer items-center justify-between rounded-md border px-3 py-2 transition-colors ${
                activePreset === p.name
                  ? "border-accent-primary/30 bg-accent-primary/5"
                  : "border-border-default bg-surface-raised hover:bg-surface-base"
              }`}
            >
              <div>
                <span className="text-xs font-medium text-text-primary">{p.name}</span>
                <div className="text-[10px] text-text-muted">{p.provider} / {p.model}</div>
              </div>
              <button
                onClick={(e) => { e.stopPropagation(); deletePreset(p.id); }}
                className="text-[10px] text-text-muted hover:text-status-error"
              >
                Delete
              </button>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
