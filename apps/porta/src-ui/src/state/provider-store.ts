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
    secretName: "ANTHROPIC_API_KEY",
    keyUrl: "https://console.anthropic.com/settings/keys",
  },
  {
    key: "openai",
    label: "OpenAI",
    catalystRef: "catalyst:moonmoon69.openai:1.0.0",
    secretName: "OPENAI_API_KEY",
    keyUrl: "https://platform.openai.com/api-keys",
  },
  {
    key: "gemini",
    label: "Gemini",
    catalystRef: "catalyst:moonmoon69.gemini:1.0.0",
    secretName: "GEMINI_API_KEY",
    keyUrl: "https://aistudio.google.com/apikey",
  },
  {
    key: "grok",
    label: "Grok",
    catalystRef: "catalyst:moonmoon69.grok:1.0.0",
    secretName: "GROK_API_KEY",
    keyUrl: "https://console.x.ai",
  },
  {
    key: "openrouter",
    label: "OpenRouter",
    catalystRef: "catalyst:moonmoon69.openrouter:1.0.0",
    secretName: "OPENROUTER_API_KEY",
    keyUrl: "https://openrouter.ai/keys",
  },
] as const;

export type ProviderKey = (typeof PROVIDERS)[number]["key"];

export interface ProviderInfo {
  key: ProviderKey;
  label: string;
  catalystRef: string;
  secretName: string;
  keyUrl: string;
  ready: boolean;
  secretSet: boolean;
  models: string[];
  error: string | null;
  loading: boolean;
}

export interface ProviderState {
  providers: ProviderInfo[];
  loading: boolean;
  registering: boolean;

  loadAll: () => Promise<void>;
  setupProvider: (key: ProviderKey, apiKey: string) => Promise<void>;
  removeProvider: (key: ProviderKey) => Promise<void>;
}

export const useProviderStore = create<ProviderState>((set, get) => ({
  providers: PROVIDERS.map((p) => ({
    ...p,
    ready: false,
    secretSet: false,
    models: [],
    error: null,
    loading: false,
  })),
  loading: false,
  registering: false,

  loadAll: async () => {
    set({ loading: true });

    try {
      const client = await getClient();
      const mode = useConnectionStore.getState().mode;

      // Check if catalysts are registered (skip register in remote mode)
      try {
        const listResult = await cyfrMcp.listComponents(client, "catalyst");
        const components = (listResult.components as Record<string, unknown>[]) ?? [];
        const names = components.map((c) => c.name as string);
        const hasAll = PROVIDERS.every((p) => names.some((n) => n === p.key));

        if (!hasAll && mode !== "remote") {
          set({ registering: true });
          await cyfrMcp.registerComponents(client);
          set({ registering: false });
        }
      } catch {
        // Registration may fail — continue
        set({ registering: false });
      }

      // Check which secrets exist
      const existingSecrets = new Set<string>();
      try {
        const secretResult = await cyfrMcp.listSecrets(client);
        const secrets = (secretResult.secrets as string[]) ?? [];
        for (const s of secrets) existingSecrets.add(s);
      } catch {
        // May need auth — continue with empty set
      }

      // Update secret status
      set({
        providers: get().providers.map((p) => ({
          ...p,
          secretSet: existingSecrets.has(p.secretName),
        })),
      });

      // Load models via list-models formula
      try {
        const modelsResult = await cyfrMcp.runComponent(
          client,
          "formula:local.list-models",
        );

        // CLI wraps output in { result: { models: {...}, refs: {...}, errors: {...} } }
        const result = (modelsResult.result ?? modelsResult) as Record<string, unknown>;
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
            // Don't show errors for providers without a key — that's expected
            const error = rawError && p.secretSet ? friendlyError(rawError) : null;
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
      } catch {
        // Model loading failed — providers show based on secret status only
      }
    } catch {
      // Top-level failure
    }

    set({ loading: false });
  },

  setupProvider: async (key, apiKey) => {
    const provider = get().providers.find((p) => p.key === key);
    if (!provider) return;

    set({
      providers: get().providers.map((p) =>
        p.key === key ? { ...p, loading: true, error: null } : p,
      ),
    });

    try {
      const client = await getClient();

      // Step 1: Set secret
      await cyfrMcp.setSecret(client, provider.secretName, apiKey);

      // Step 2: Grant secret to catalyst (name-level, covers all versions)
      const nameRef = provider.catalystRef.replace(/:[^:]+$/, "");
      await cyfrMcp.grantSecret(client, nameRef, provider.secretName);

      // Step 3: Mark as set, try to load models
      set({
        providers: get().providers.map((p) =>
          p.key === key ? { ...p, secretSet: true } : p,
        ),
      });

      // Step 4: Load models for this provider
      try {
        const modelsResult = await cyfrMcp.runComponent(
          client,
          "formula:local.list-models",
          { providers: [key] },
        );

        const result = (modelsResult.result ?? modelsResult) as Record<string, unknown>;
        const rawModels = (result.models ?? {}) as Record<string, unknown>;
        const errorsMap = (result.errors ?? {}) as Record<string, string>;
        const providerData = rawModels[key] as Record<string, unknown> | undefined;
        let models: string[] = [];
        if (providerData) {
          if (key === "gemini") {
            const list = (providerData.models ?? []) as Record<string, unknown>[];
            models = list
              .map((m) => ((m.name ?? "") as string).replace(/^models\//, ""))
              .filter((id) => id !== "");
          } else {
            const list = (providerData.data ?? []) as Record<string, unknown>[];
            models = list
              .map((m) => (m.id ?? "") as string)
              .filter((id) => id !== "");
          }
        }

        const rawError = errorsMap[key] ?? null;
        const error = rawError ? friendlyError(rawError) : null;

        set({
          providers: get().providers.map((p) =>
            p.key === key
              ? { ...p, models, error, ready: models.length > 0, loading: false }
              : p,
          ),
        });
      } catch {
        // Mark as ready based on secret being set
        set({
          providers: get().providers.map((p) =>
            p.key === key ? { ...p, ready: true, loading: false } : p,
          ),
        });
      }
    } catch (err) {
      set({
        providers: get().providers.map((p) =>
          p.key === key
            ? {
                ...p,
                loading: false,
                error: friendlyError(err),
              }
            : p,
        ),
      });
    }
  },

  removeProvider: async (key) => {
    const provider = get().providers.find((p) => p.key === key);
    if (!provider) return;

    try {
      const client = await getClient();
      await cyfrMcp.deleteSecret(client, provider.secretName);
    } catch {
      // Best-effort
    }

    set({
      providers: get().providers.map((p) =>
        p.key === key
          ? { ...p, ready: false, secretSet: false, models: [], error: null }
          : p,
      ),
    });
  },
}));
