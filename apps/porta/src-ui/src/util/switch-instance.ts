import { host } from "../host";

/**
 * "Switch instance" / start over: forget the stored connection (URL, API key,
 * session id), drop the cached MCP client, and reload so the app re-runs its
 * boot/auth flow against a fresh config.
 */
export async function switchInstance(opts: {
  resetMcpClient: () => void;
  onError?: (e: unknown) => void;
}): Promise<void> {
  const { resetMcpClient, onError } = opts;
  try {
    host.patchConfig({
      mode: "session",
      cyfrUrl: "",
      apiKey: "",
      sessionId: "",
    });
    resetMcpClient();
    window.location.href = window.location.pathname;
  } catch (e) {
    console.error("Switch instance failed:", e);
    onError?.(e);
  }
}
