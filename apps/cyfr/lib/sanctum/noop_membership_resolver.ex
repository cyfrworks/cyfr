defmodule Sanctum.NoopMembershipResolver do
  @moduledoc """
  Default `Sanctum.MembershipResolver` impl for Core.

  Core has no org membership concept; always returns `:no_membership`.
  """

  @behaviour Sanctum.MembershipResolver

  @impl true
  def resolve(_user_id), do: :no_membership
end
