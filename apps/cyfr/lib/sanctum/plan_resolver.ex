defmodule Sanctum.PlanResolver do
  @moduledoc """
  Behaviour for resolving an org's billing plan.

  Core has no concept of plans — the default `Sanctum.NoopPlanResolver` always
  returns `"free"`. Arx ships an implementation (`Arx.Sanctum.PlanResolver`)
  that fetches the org row and returns its `:plan` field.

  Wired via `config :cyfr, :plan_resolver, Mod`. Used by `Sanctum.Policy.Ceiling`
  to pick a plan-tier ceiling.
  """

  @callback get_plan(org_id :: String.t() | nil) :: String.t()
end
