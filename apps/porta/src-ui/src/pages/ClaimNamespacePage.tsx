import { FormEvent, useState } from "react";
import { useAuthStore } from "../state/auth-store";

/**
 * First-login gate — the user has a valid Sanctum session but cyfr.run
 * reports no personal namespace claimed. Blocks the rest of the UI until
 * either (a) the claim succeeds, (b) the user bails out via "Skip for
 * now", or (c) the IdP access_token expires and we force re-login.
 *
 * Mirrors the codex CLI `promptAndClaimPersonalNamespace` (apps/codex/cmd/
 * login.go) and the web server flow (apps/cyfr/lib/emissary_web/controllers/
 * claim_namespace_controller.ex). The `submitPersonalClaim` action in
 * auth-store owns the MCP call + slug_taken/reauth discrimination.
 *
 * Personal slug rules (enforced client-side AND by cyfr.run):
 *   - `^[a-z0-9]+(-[a-z0-9]+)*$`, 1–39 chars (GitHub-style).
 *   - No '@', uppercase, leading/trailing/consecutive hyphens.
 *
 * See auth_refactor.md §"Namespace format".
 */
export default function ClaimNamespacePage() {
  const claimGate = useAuthStore((s) => s.claimGate);
  const submit = useAuthStore((s) => s.submitPersonalClaim);
  const dismiss = useAuthStore((s) => s.dismissClaimGate);
  const logout = useAuthStore((s) => s.logout);

  const [username, setUsername] = useState(claimGate.suggestedUsername ?? "");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();

    const trimmed = username.trim();
    if (!trimmed) {
      setError("Slug cannot be empty.");
      return;
    }

    if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(trimmed)) {
      setError(
        "Slug must be lowercase alphanumerics with single hyphens " +
          "(GitHub-style). No '@', uppercase, or leading/trailing hyphens.",
      );
      return;
    }

    if (trimmed.length > 39) {
      setError("Slug must be 39 characters or fewer.");
      return;
    }

    setError(null);
    setSubmitting(true);

    try {
      const outcome = await submit(trimmed);
      switch (outcome) {
        case "ok":
          // auth-store clears the gate and re-runs checkAuth; App.tsx
          // falls through to the main shell on next render.
          return;
        case "slug_taken":
          setError(`"${trimmed}" is already taken. Try a different slug.`);
          break;
        case "invalid":
          setError(
            `"${trimmed}" is not a valid personal slug. Must be bare ` +
              "lowercase alphanumerics + single hyphens, no '@', 1–39 chars.",
          );
          break;
        case "reauth":
          // IdP access_token expired; bounce back through login.
          await logout();
          return;
        case "error":
        default:
          setError("Claim failed. Please try again or run cyfr login again.");
      }
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div className="flex h-full items-center justify-center bg-surface-base p-8">
      <div className="w-full max-w-md space-y-6">
        <div className="text-center">
          <img
            src="/logo.png"
            alt="CYFR"
            className="mx-auto h-16 w-16 object-contain"
          />
          <h1 className="mt-4 text-2xl font-semibold text-text-primary">
            Claim your cyfr.run namespace
          </h1>
          <p className="mt-2 text-sm text-text-secondary">
            To publish or pull private components, you need a personal
            namespace on cyfr.run. This is a one-time choice per identity.
          </p>
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label
              htmlFor="username"
              className="block text-sm font-medium text-text-primary"
            >
              Namespace slug
            </label>
            <input
              id="username"
              type="text"
              value={username}
              onChange={(e) => {
                setUsername(e.target.value);
                if (error) setError(null);
              }}
              pattern="^[a-z0-9]+(-[a-z0-9]+)*$"
              minLength={1}
              maxLength={39}
              autoFocus
              required
              disabled={submitting}
              className="mt-1 w-full rounded-md border border-surface-border bg-surface-raised px-3 py-2 text-sm text-text-primary placeholder:text-text-muted focus:border-accent-primary focus:outline-none focus:ring-1 focus:ring-accent-primary disabled:opacity-50"
              placeholder="alice"
            />
            <p className="mt-1 text-xs text-text-muted">
              Lowercase letters, digits, and single hyphens. 1–39 chars.
              No "@". Examples: <code>alice</code>, <code>bob-123</code>.
            </p>
          </div>

          {error && (
            <div className="rounded-md border border-red-500/30 bg-red-500/10 px-3 py-2 text-sm text-red-400">
              {error}
            </div>
          )}

          <div className="flex gap-2">
            <button
              type="submit"
              disabled={submitting || !username.trim()}
              className="flex-1 rounded-md bg-accent-primary px-4 py-2 text-sm font-medium text-white hover:bg-accent-hover disabled:opacity-50"
            >
              {submitting ? "Claiming..." : "Claim namespace"}
            </button>
            <button
              type="button"
              onClick={dismiss}
              disabled={submitting}
              className="rounded-md border border-surface-border px-4 py-2 text-sm text-text-secondary hover:bg-surface-raised disabled:opacity-50"
              title="Skip for now — you won't be able to publish or manage registry namespaces until you claim one. The gate will re-appear on next login."
            >
              Skip
            </button>
          </div>
        </form>

        <div className="text-center text-xs text-text-muted">
          Something wrong?{" "}
          <button
            type="button"
            onClick={() => {
              void logout();
            }}
            className="underline hover:text-text-secondary"
          >
            Sign out and try again
          </button>
        </div>
      </div>
    </div>
  );
}
