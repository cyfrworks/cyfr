import { create } from "zustand";
import { friendlyError } from "../api/errors";
import { useConnectionStore } from "./connection-store";
import * as cyfrMcp from "../api/cyfr-mcp";

async function getClient() {
  return useConnectionStore.getState().getMcpClient();
}

const PROVIDERS = [
  {
    key: "claude",
    label: "Claude",
    catalystRef: "catalyst:moonmoon69.claude:1.0.0",
    keyUrl: "https://console.anthropic.com/settings/keys",
  },
  {
    key: "openai",
    label: "OpenAI",
    catalystRef: "catalyst:moonmoon69.openai:1.0.0",
    keyUrl: "https://platform.openai.com/api-keys",
  },
  {
    key: "gemini",
    label: "Gemini",
    catalystRef: "catalyst:moonmoon69.gemini:1.0.0",
    keyUrl: "https://aistudio.google.com/apikey",
  },
  {
    key: "grok",
    label: "Grok",
    catalystRef: "catalyst:moonmoon69.grok:1.0.0",
    keyUrl: "https://console.x.ai",
  },
  {
    key: "openrouter",
    label: "OpenRouter",
    catalystRef: "catalyst:moonmoon69.openrouter:1.0.0",
    keyUrl: "https://openrouter.ai/keys",
  },
] as const;

export type ProviderKey = (typeof PROVIDERS)[number]["key"];

export interface ProviderInfo {
  key: ProviderKey;
  label: string;
  catalystRef: string;
  keyUrl: string;
  /** The provider's consent is bound and live (server `setup_plan.ready`). */
  configured: boolean;
  /** A configured provider that also answered `list-models`. */
  ready: boolean;
  models: string[];
  error: string | null;
}

export interface ProviderState {
  providers: ProviderInfo[];
  loading: boolean;
  registering: boolean;
  /** Load-level failure surfaced to the UI — never swallowed. */
  error: string | null;

  loadAll: () => Promise<void>;
}

/**
 * Read-only provider status. Granting an API key is a consent decision made
 * in the Prism console (Connections + the consent sheet); Porta reports each
 * provider's `setup_plan` state and the models it serves once bound.
 */
export const useProviderStore = create<ProviderState>((set, get) => ({
  providers: PROVIDERS.map((p) => ({
    ...p,
    configured: false,
    ready: false,
    models: [],
    error: null,
  })),
  loading: false,
  registering: false,
  error: null,

  loadAll: async () => {
    set({ loading: true, error: null });

    try {
      const client = await getClient();
      const mode = useConnectionStore.getState().mode;

      // Check the provider catalysts are registered (skip register in remote
      // mode — registration scans the server's local components tree).
      try {
        const listResult = await cyfrMcp.listComponents(client, "catalyst");
        const components =
          (listResult.components as Record<string, unknown>[]) ?? [];
        const names = components.map((c) => c.name as string);
        const hasAll = PROVIDERS.every((p) => names.some((n) => n === p.key));

        if (!hasAll && mode !== "remote") {
          set({ registering: true });
          await cyfrMcp.registerComponents(client);
          set({ registering: false });
        }
      } catch (e) {
        set({ registering: false, error: friendlyError(e) });
      }

      // Configured-state per provider from the server's setup plan.
      const configured = new Map<ProviderKey, boolean>();
      await Promise.all(
        PROVIDERS.map(async (p) => {
          try {
            const plan = (await cyfrMcp.setupPlan(client, p.catalystRef)) as {
              ready?: boolean;
            };
            configured.set(p.key, plan?.ready === true);
          } catch {
            configured.set(p.key, false);
          }
        }),
      );

      set({
        providers: get().providers.map((p) => ({
          ...p,
          configured: configured.get(p.key) ?? false,
        })),
      });

      // Load models via the list-models formula.
      try {
        const modelsResult = await cyfrMcp.runComponent(
          client,
          "formula:local.list-models",
        );

        // CLI wraps output in { result: { models: {...}, refs: {...}, errors: {...} } }
        const result = (modelsResult.result ?? modelsResult) as Record<
          string,
          unknown
        >;
        const rawModels = (result.models ?? {}) as Record<string, unknown>;
        const errorsMap = (result.errors ?? {}) as Record<string, string>;
        const refsMap = (result.refs ?? {}) as Record<string, string>;

        // Parse model IDs per provider — matches agent_live.ex parse_model_ids
        // Gemini: data.models[].name with "models/" prefix stripped
        // Others: data.data[].id
        const modelsMap: Record<string, string[]> = {};
        for (const [provider, value] of Object.entries(rawModels)) {
          const obj = value as Record<string, unknown>;
          if (provider === "gemini") {
            const models = (obj.models ?? []) as Record<string, unknown>[];
            modelsMap[provider] = models
              .map((m) => ((m.name ?? "") as string).replace(/^models\//, ""))
              .filter((id) => id !== "");
          } else {
            const data = (obj.data ?? []) as Record<string, unknown>[];
            modelsMap[provider] = data
              .map((m) => (m.id ?? "") as string)
              .filter((id) => id !== "");
          }
        }

        set({
          providers: get().providers.map((p) => {
            const models = modelsMap[p.key] ?? [];
            const rawError = errorsMap[p.key] ?? null;
            // Errors for unconfigured providers are expected — not surfaced.
            const error =
              rawError && p.configured ? friendlyError(rawError) : null;
            const ref = refsMap[p.key] ?? p.catalystRef;
            return {
              ...p,
              catalystRef: ref,
              models,
              error,
              ready: models.length > 0,
            };
          }),
        });
      } catch (e) {
        set({ error: friendlyError(e) });
      }
    } catch (e) {
      set({ error: friendlyError(e) });
    }

    set({ loading: false });
  },
}));
