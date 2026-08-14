import { useEffect } from "react";
import { useNavigate, useLocation, type NavigateFunction } from "react-router-dom";

let _nav: NavigateFunction | null = null;
let _path = "/";

/**
 * Mount once inside the Router context to expose the imperative navigate
 * function and the current path to non-React callers (the intent dispatcher
 * and the porta-context snapshot). Returns null.
 */
export function NavigatorBridge() {
  const nav = useNavigate();
  const location = useLocation();

  useEffect(() => {
    _nav = nav;
    return () => {
      if (_nav === nav) _nav = null;
    };
  }, [nav]);

  useEffect(() => {
    _path = location.pathname;
  }, [location.pathname]);

  return null;
}

/**
 * Navigate to a path from outside the React tree. No-op until <NavigatorBridge />
 * has mounted. Paths should already be validated by the caller (the intent
 * parser enforces an allowlist).
 */
export function navigate(path: string): void {
  _nav?.(path);
}

/** Current router pathname. Fallback "/" before the shim mounts. */
export function getCurrentPath(): string {
  return _path;
}
