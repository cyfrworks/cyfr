defmodule Sanctum.MembershipResolver do
  @moduledoc """
  Behaviour for resolving a user's primary org/project membership.

  Core has no concept of org membership — the default `Sanctum.NoopMembershipResolver`
  always returns `:no_membership`. Arx ships an implementation (`Arx.Sanctum.MembershipResolver`)
  that queries the `memberships` table and returns the user's accepted membership
  (preferring `accepted_at != nil`, falling back to first available).

  Wired via `config :cyfr, :membership_resolver, Mod`. Callers do
  `Application.fetch_env!(:cyfr, :membership_resolver).resolve(user_id)` instead
  of probing for Arx modules with `Code.ensure_loaded?` — that lets Core
  builds compile cleanly without `apps/arx/` and lets edition-specific behaviour
  swap in via config rather than module-name knowledge.
  """

  @callback resolve(user_id :: String.t()) ::
              %{
                optional(:namespace) => String.t() | nil,
                org_id: String.t() | nil,
                project_id: String.t() | nil
              }
              | :no_membership
              | {:error, term()}
end
