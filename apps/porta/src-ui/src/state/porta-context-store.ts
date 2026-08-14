/**
 * PortaContext snapshot — a point-in-time summary of what the user is looking
 * at, sent to AQUA as a <porta-context> preamble on every turn so the model
 * can answer "what am I looking at?" without asking the user to restate.
 *
 * The snapshot is pulled by calling {@link getPortaContext} — no long-lived
 * state of its own. It reads from the other stores (tincture, overlay, agent)
 * and the router path at call time.
 */

import { useTinctureStore } from "./tincture-store";
import { useOverlayStore, type OverlayState } from "./overlay-store";
import { useAgentStore } from "./agent-store";
import { getCurrentPath } from "../harness/navigate";

export interface FocusedApp {
  publisher: string;
  name: string;
  title: string;
  shared: boolean;
}

export interface PortaContext {
  route: string;
  overlayState: OverlayState;
  focusedApp: FocusedApp | null;
  viewingApp: string | null;
  openedApps: string[];
  pendingSetupRef: string | null;
}

export function getPortaContext(): PortaContext {
  const tincture = useTinctureStore.getState();
  const overlay = useOverlayStore.getState();
  const agent = useAgentStore.getState();

  const focused = tincture.tinctures[tincture.focusedIndex] ?? null;

  return {
    route: getCurrentPath(),
    overlayState: overlay.state,
    focusedApp: focused
      ? {
          publisher: focused.publisher,
          name: focused.name,
          title: focused.title || focused.name,
          shared: focused.public,
        }
      : null,
    viewingApp: tincture.viewing,
    openedApps: [...tincture.openedTinctures],
    pendingSetupRef: agent.pendingSetupRef ?? null,
  };
}
