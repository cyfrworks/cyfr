defmodule Sanctum.NoopPlanResolver do
  @moduledoc """
  Default `Sanctum.PlanResolver` impl for Core.

  Core has no plan concept; always returns `"free"`.
  """

  @behaviour Sanctum.PlanResolver

  @impl true
  def get_plan(_org_id), do: "free"
end
