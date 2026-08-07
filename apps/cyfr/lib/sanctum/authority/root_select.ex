# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Sanctum.Authority.RootSelect do
  @moduledoc """
  Pure root-profile selection decisions.

  Ingress adapters gather a component's candidate profiles and ask here
  which one roots the execution. Two rules, both fail-closed:

    * **Never guess.** With no explicit selector, only a *single* active
      owner profile is selectable; several candidates is an error the
      caller must surface, not a coin flip.
    * **Public is resolved first, never inferred from authentication.**
      A public route selects the public profile regardless of any
      credentials the caller happens to present — a valid owner cookie on
      a public URL must not upgrade the request. Authentication is only a
      precondition of protected routes.
  """

  @type status :: :active | :needs_consent | :revoked

  @type profile_summary :: %{
          required(:id) => String.t(),
          required(:kind) => :owner | :public,
          required(:source_ref) => String.t(),
          required(:label) => String.t(),
          required(:status) => status()
        }

  @type select_error ::
          :no_profile
          | {:not_found, String.t()}
          | {:ambiguous, [String.t()]}
          | {:profile_unavailable, :needs_consent | :revoked}

  @doc """
  Select the root profile: by explicit selector (profile id or label), or —
  with no selector — the single active owner profile.

  An inactive match is reported as unavailable, never silently skipped in
  favor of another profile.
  """
  @spec select([profile_summary()], String.t() | nil) ::
          {:ok, profile_summary()} | {:error, select_error()}
  def select(candidates, nil) when is_list(candidates) do
    owners = Enum.filter(candidates, &(&1.kind == :owner))

    case Enum.filter(owners, &(&1.status == :active)) do
      [one] -> {:ok, one}
      [] -> no_active_owner(owners)
      many -> {:error, {:ambiguous, ids(many)}}
    end
  end

  def select(candidates, selector) when is_list(candidates) and is_binary(selector) do
    case Enum.filter(candidates, &(&1.id == selector or &1.label == selector)) do
      [] -> {:error, {:not_found, selector}}
      [%{status: :active} = one] -> {:ok, one}
      [%{status: status}] -> {:error, {:profile_unavailable, status}}
      many -> {:error, {:ambiguous, ids(many)}}
    end
  end

  @type route_error :: select_error() | :no_public_profile | :unauthenticated

  @doc """
  Select the root profile for a routed ingress.

  A `:public` route picks the public profile unconditionally — the
  `authenticated?` argument is deliberately ignored there. A `:protected`
  route requires authentication, then applies `select/2`'s no-selector
  rule.
  """
  @spec select_for_route([profile_summary()], :public | :protected, boolean()) ::
          {:ok, profile_summary()} | {:error, route_error()}
  def select_for_route(candidates, :public, _authenticated?) when is_list(candidates) do
    case Enum.filter(candidates, &(&1.kind == :public)) do
      [] -> {:error, :no_public_profile}
      [%{status: :active} = one] -> {:ok, one}
      [%{status: status}] -> {:error, {:profile_unavailable, status}}
      many -> {:error, {:ambiguous, ids(many)}}
    end
  end

  def select_for_route(candidates, :protected, true) when is_list(candidates) do
    select(candidates, nil)
  end

  def select_for_route(candidates, :protected, false) when is_list(candidates) do
    {:error, :unauthenticated}
  end

  defp no_active_owner([%{status: status}]), do: {:error, {:profile_unavailable, status}}
  defp no_active_owner(_), do: {:error, :no_profile}

  defp ids(profiles), do: Enum.map(profiles, & &1.id)
end
