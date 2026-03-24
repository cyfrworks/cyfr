import { useAuthStore } from "../state/auth-store";

export default function SettingsPage() {
  return (
    <div className="flex-1 overflow-y-auto">
      <div className="mx-auto max-w-2xl px-6 py-8">
        <h1 className="text-xl font-semibold text-text-primary">Settings</h1>

        <AccountSection />
      </div>
    </div>
  );
}

function AccountSection() {
  const { userName, userEmail, logout } = useAuthStore();

  return (
    <section className="mt-8">
      <h2 className="text-sm font-medium text-text-primary">Account</h2>
      <div className="mt-3 flex items-center justify-between rounded-lg border border-border-default bg-surface-raised px-4 py-3">
        <div>
          <div className="text-sm text-text-primary">
            {userEmail ?? userName ?? "Logged in"}
          </div>
          {userName && userEmail && (
            <div className="text-xs text-text-muted">{userName}</div>
          )}
        </div>
        <button
          onClick={logout}
          className="text-xs text-text-muted hover:text-status-error"
        >
          Log out
        </button>
      </div>
    </section>
  );
}
