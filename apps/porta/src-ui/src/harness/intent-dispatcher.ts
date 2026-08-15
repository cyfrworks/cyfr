import { useOverlayStore } from "../state/overlay-store";
import { useTinctureStore } from "../state/tincture-store";
import { useApprovalStore } from "../state/approval-store";
import { useAgentStore } from "../state/agent-store";
import { navigate } from "./navigate";
import type { Intent } from "./aqua-actions-parser";

export interface DispatchRecord {
  intent: Intent;
  status: "dispatched" | "error";
  error?: string;
  timestamp: number;
}

/**
 * Dispatches a single validated intent to the appropriate Porta subsystem.
 * Returns a record suitable for logging to the activity lane.
 *
 * Today's handlers are all safe / auto-dispatch (no approval card, no
 * mcp_proxy interception); risky-intent handling is a future addition.
 */
async function dispatchIntent(intent: Intent): Promise<DispatchRecord> {
  const timestamp = Date.now();
  try {
    switch (intent.kind) {
      case "ui.navigate":
        navigate(intent.path);
        break;
      case "ui.overlay.open":
        useOverlayStore.getState().open(intent.state);
        break;
      case "ui.overlay.close":
        useOverlayStore.getState().close();
        break;
      case "ui.overlay.focus_input":
        useOverlayStore.getState().focusInput();
        break;
      case "ui.tincture.open": {
        navigate("/tinctures");
        useTinctureStore.getState().selectTincture(intent.name);
        break;
      }
      case "ui.tincture.close":
        useTinctureStore.getState().closeTincture(intent.name);
        break;
      case "ui.tincture.focus": {
        navigate("/tinctures");
        const store = useTinctureStore.getState();
        const idx = store.tinctures.findIndex((t) => t.name === intent.name);
        if (idx >= 0) store.setFocusedIndex(idx);
        break;
      }
      // The three focus intents navigate to the page; the target id is
      // carried in the intent but no store exposes per-item focus yet.
      case "ui.schedules.focus":
        navigate("/schedules");
        break;
      case "ui.components.focus":
        navigate("/components");
        break;
      case "ui.mcp.focus":
        navigate("/mcp-servers");
        break;
      case "ui.copy_clipboard":
        await navigator.clipboard.writeText(intent.text);
        break;
      case "ui.request_approval": {
        // Fire-and-forget: we surface the card immediately, then route the
        // user's decision back as a synthetic user turn. Don't await here or
        // subsequent intents would starve behind the user's decision.
        void useApprovalStore
          .getState()
          .request({
            source: "text_intent",
            title: intent.title,
            summary: intent.summary,
            risk: intent.risk,
            actionDescription: intent.action_description,
          })
          .then((decision) => {
            const msg = decision.approved
              ? `[System: user approved '${intent.title}'.]`
              : `[System: user declined '${intent.title}'.${
                  decision.reason ? ` Reason: ${decision.reason}` : ""
                }]`;
            void useAgentStore.getState().submit(msg);
          });
        break;
      }
    }
    return { intent, status: "dispatched", timestamp };
  } catch (err) {
    return {
      intent,
      status: "error",
      error: err instanceof Error ? err.message : String(err),
      timestamp,
    };
  }
}

export async function dispatchIntents(
  intents: Intent[],
): Promise<DispatchRecord[]> {
  const records: DispatchRecord[] = [];
  for (const intent of intents) {
    records.push(await dispatchIntent(intent));
  }
  return records;
}
