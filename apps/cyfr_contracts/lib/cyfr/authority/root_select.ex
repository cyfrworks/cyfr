# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Cyfr.Authority.RootSelect do
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

  ## The selector vocabulary

  Defines `t:selector/0`. `:default` selects the single active owner
  profile; multiple owner labels return `{:ambiguous, _}`. Callers that
  must preserve a selected authority pass an explicit profile id.

  `{:id, _}` and `{:label, _}` are strict — a stored id matches an id and
  nothing else. `decode/1` is the one place a caller-supplied string
  becomes one of them, by the `prof_` prefix; `valid_label?/1` is what
  keeps that decode total, and the profile surfaces hold labels to it.
  """

  @id_prefix "prof_"

  @typedoc """
  Which profile roots an execution.

    * `:default` — the single active owner profile, or a refusal
    * `{:id, id}` — that exact profile id
    * `{:label, label}` — that exact label, among the candidates given
  """
  @type selector :: :default | {:id, String.t()} | {:label, String.t()}

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
  Whether `value` is a profile id rather than a label.

  Discriminating by prefix is sound because `valid_label?/1` refuses a
  label that would look like one — the same trick, and the same
  obligation, as telling an athanor id (`"ath_…"`) from a route slug.
  """
  @spec profile_id?(term()) :: boolean()
  def profile_id?(value), do: is_binary(value) and String.starts_with?(value, @id_prefix)

  @doc """
  Whether `label` may be stored as a profile label.

  Refuses the empty string and anything id-shaped. A label free to be
  `"prof_x"` would make `decode/1` a guess, and the profile surfaces would
  have no way to tell an operator which of the two they had named.
  """
  @spec valid_label?(term()) :: boolean()
  def valid_label?(label),
    do: is_binary(label) and label != "" and not String.starts_with?(label, @id_prefix)

  @doc """
  A caller-supplied string as a selector: id-shaped becomes `{:id, _}`,
  everything else `{:label, _}`. Blank and non-binary become `:default`.

  The one decode: wire surfaces take a single "profile" string because a
  person naming their grant should not have to know which of the two they
  are holding.
  """
  @spec decode(term()) :: selector()
  def decode(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :default
      trimmed -> if profile_id?(trimmed), do: {:id, trimmed}, else: {:label, trimmed}
    end
  end

  def decode(_), do: :default

  @doc """
  Select the root profile: by explicit id or label, or — with `:default` —
  the single active owner profile.

  An inactive match is reported as unavailable, never silently skipped in
  favor of another profile.
  """
  @spec select([profile_summary()], selector()) ::
          {:ok, profile_summary()} | {:error, select_error()}
  def select(candidates, :default) when is_list(candidates) do
    owners = Enum.filter(candidates, &(&1.kind == :owner))

    case Enum.filter(owners, &(&1.status == :active)) do
      [one] -> {:ok, one}
      [] -> no_active_owner(owners)
      many -> {:error, {:ambiguous, ids(many)}}
    end
  end

  def select(candidates, {field, value})
      when is_list(candidates) and field in [:id, :label] and is_binary(value) do
    case Enum.filter(candidates, &(Map.fetch!(&1, field) == value)) do
      [] -> {:error, {:not_found, value}}
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
    select(candidates, :default)
  end

  def select_for_route(candidates, :protected, false) when is_list(candidates) do
    {:error, :unauthenticated}
  end

  defp no_active_owner([%{status: status}]), do: {:error, {:profile_unavailable, status}}
  defp no_active_owner(_), do: {:error, :no_profile}

  defp ids(profiles), do: Enum.map(profiles, & &1.id)
end
