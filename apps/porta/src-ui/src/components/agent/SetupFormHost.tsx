import { createPortal } from "react-dom";
import { useAgentStore } from "../../state/agent-store";
import { useSetupFormSlotStore } from "./SetupFormSlot";
import { SetupForm } from "./SetupForm";

/**
 * Mounts the setup form (when one is pending) into whichever slot is currently
 * registered via <SetupFormSlot />. This lets us keep the pendingSetupRef
 * subscription in one place at shell level while changing where the form
 * renders visually (inline today, dedicated rail planned).
 */
export function SetupFormHost() {
  const pendingSetupRef = useAgentStore((s) => s.pendingSetupRef);
  const completeSetup = useAgentStore((s) => s.completeSetup);
  const dismissSetup = useAgentStore((s) => s.dismissSetup);
  const slot = useSetupFormSlotStore((s) => s.element);

  if (!pendingSetupRef || !slot) return null;

  return createPortal(
    <SetupForm
      componentRef={pendingSetupRef}
      onComplete={completeSetup}
      onDismiss={dismissSetup}
    />,
    slot,
  );
}
