/**
 * Web host layer.
 *
 * A.Q.U.A. ships as a PWA served (typically) from the same origin as Cyfr.
 * Everything that used to be a Tauri `invoke(...)` — config/session
 * persistence, opening URLs — is implemented here against browser APIs.
 *
 * Persistent state lives in a single `localStorage` blob.
 */

export type RuntimeMode = "session" | "remote";

export interface AquaConfig {
  /** Active runtime mode. "session" = cookie/device-flow against {cyfrUrl};
   *  "remote" = explicit URL + API key. */
  mode: RuntimeMode;
  /** Cyfr base URL. Empty string ⇒ same origin as the PWA. */
  cyfrUrl: string;
  /** Bearer API key (remote mode). */
  apiKey: string;
  /** Device-flow / session id (session mode). */
  sessionId: string;
  /** Model / provider preferences (provider, model, catalyst_ref, …). */
  prefs: Record<string, unknown>;
}

const STORAGE_KEY = "aqua.config";

const DEFAULT_CONFIG: AquaConfig = {
  mode: "session",
  cyfrUrl: "",
  apiKey: "",
  sessionId: "",
  prefs: {},
};

function read(): AquaConfig {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return { ...DEFAULT_CONFIG };
    const parsed = JSON.parse(raw) as Partial<AquaConfig>;
    return { ...DEFAULT_CONFIG, ...parsed };
  } catch {
    return { ...DEFAULT_CONFIG };
  }
}

function write(cfg: AquaConfig): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(cfg));
  } catch {
    /* private-mode / quota — ignore */
  }
}

export const host = {
  /** Resolve the Cyfr base URL; empty stored value ⇒ same origin. */
  cyfrUrl(): string {
    const cfg = read();
    return cfg.cyfrUrl || window.location.origin;
  },

  getConfig(): AquaConfig {
    return read();
  },

  patchConfig(patch: Partial<AquaConfig>): AquaConfig {
    const next = { ...read(), ...patch };
    write(next);
    return next;
  },

  mode(): RuntimeMode {
    return read().mode;
  },

  hasApiKey(): boolean {
    return read().apiKey.length > 0;
  },

  getApiKey(): string {
    return read().apiKey;
  },

  getSessionId(): string {
    return read().sessionId;
  },

  setSessionId(sessionId: string): void {
    host.patchConfig({ sessionId });
  },

  getPrefs(): Record<string, unknown> {
    return read().prefs ?? {};
  },

  setPrefs(prefs: Record<string, unknown>): void {
    host.patchConfig({ prefs });
  },

  /** Raw JSON of the stored config — backs the "edit config" UI. */
  getConfigJson(): string {
    return JSON.stringify(read(), null, 2);
  },

  saveConfigJson(json: string): void {
    const parsed = JSON.parse(json) as Partial<AquaConfig>;
    write({ ...DEFAULT_CONFIG, ...parsed });
  },

  /** Open a URL in a new browser tab. */
  openUrl(url: string): void {
    window.open(url, "_blank", "noopener,noreferrer");
  },
};
