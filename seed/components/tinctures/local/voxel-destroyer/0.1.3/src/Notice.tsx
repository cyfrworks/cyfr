import type { ReactNode } from 'react';

// What the game shows in its own area, in place of the game, when it cannot
// start.
export default function Notice({ children }: { children: ReactNode }) {
  return (
    <div className="notice" role="alert">
      <span className="notice-title">💥 VOXEL DESTROYER</span>
      <p className="notice-text">{children}</p>
    </div>
  );
}
