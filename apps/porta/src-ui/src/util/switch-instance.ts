import { invoke } from "@tauri-apps/api/core";

export async function switchInstance(opts: {
  mode: string | null;
  resetMcpClient: () => void;
  onError?: (e: unknown) => void;
}): Promise<void> {
  const { mode, resetMcpClient, onError } = opts;
  try {
    if (mode === "local-managed") {
      try {
        await invoke<{ success: boolean }>("cyfr_command", { args: ["down"] });
      } catch (e) {
        console.warn("cyfr down during switch failed:", e);
      }
    }

    const json = await invoke<string>("get_config_json");
    const cfg = JSON.parse(json) as Record<string, unknown>;
    delete cfg.mode;
    await invoke("save_config_json", { json: JSON.stringify(cfg, null, 2) });
    resetMcpClient();
    await invoke("reset_boot_state");
    window.location.href = window.location.pathname;
  } catch (e) {
    console.error("Switch instance failed:", e);
    onError?.(e);
  }
}
