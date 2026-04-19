import { useEffect, useRef } from "react";
import { create } from "zustand";

interface SlotState {
  element: HTMLElement | null;
  setElement: (el: HTMLElement | null) => void;
}

/**
 * Module-level registry of the current setup-form portal target. Any component
 * that wants to *receive* the setup form (the message list today, the overlay
 * rail in Phase 4) renders a <SetupFormSlot /> to register itself. The single
 * <SetupFormHost /> mounted in AppShell reads this store to know where to
 * portal its content.
 *
 * Only one slot may be registered at a time; the latest-mounted wins.
 */
export const useSetupFormSlotStore = create<SlotState>((set) => ({
  element: null,
  setElement: (element) => set({ element }),
}));

export function SetupFormSlot() {
  const setElement = useSetupFormSlotStore((s) => s.setElement);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    setElement(ref.current);
    return () => setElement(null);
  }, [setElement]);

  return <div ref={ref} data-setup-form-slot="" />;
}
