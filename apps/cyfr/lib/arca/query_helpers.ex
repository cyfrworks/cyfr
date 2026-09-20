# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.QueryHelpers do
  @moduledoc """
  Shared Ecto query helpers for Arca storage modules.

  ## Tenant scoping

  Every tenant-owned row carries an `athanor_id`. There is no sentinel and
  no coercion: a `nil`/`""` athanor on an actor is an identity that was
  never resolved, never a value to normalize into some default row set.

  ## Relationship to the trust boundary

  These helpers are a fail-closed **backstop**, not the authoritative
  tenant control: the authoritative per-record tenant and permission
  decision belongs to the identity domain above, which establishes the
  actor in the first place. `where_tenant/2` — the actor-taking entry
  every tenant-scoped store queries through — scopes the query to the
  actor's athanor and raises for an actor whose `athanor_id` is
  unresolved: such an actor reached here around the chokepoint that
  resolves one. `where_athanor/2` is the plain filter for bare-key call
  sites (an athanor id string read off a row, no actor to judge). Callers
  must not rely on any of these as the primary control.

  ## The row-plane error convention

  Three spellings, each at its own altitude, none interchangeable: a
  database outage at a storage entry point is `{:error, :database_error}`
  (`Arca.Repo.Errors.with_db_rescue/2`); an entry point that answers
  tagged tuples refuses an actor with no athanor as
  `{:error, :no_athanor}` before any query; and an actor with no athanor
  reaching a backstop or a `!` entry point that runs inside a caller's
  transaction is an `ArgumentError` raise (`where_tenant/2`,
  `where_athanor/2`, `no_athanor!/1` — a bug upstream, never a value).
  Retention primitives answer `{:ok, count} | {:error, term}` — never a
  raw Ecto tuple.
  """

  import Ecto.Query

  @doc """
  `where_tenant/2`, except a platform-scope actor reads unfiltered — the
  query-level mirror of the platform bypass the identity domain grants.
  ONE definition so record readers (executions, MCP logs, policy logs)
  cannot drift in how they spell the bypass.

  `scope` is not a wire member of `Cyfr.Actor`, so nothing a worker
  returns can claim it.
  """
  @spec where_tenant_unless_platform(Ecto.Queryable.t(), Cyfr.Actor.t()) :: Ecto.Query.t()
  def where_tenant_unless_platform(query, %Cyfr.Actor{scope: :platform}), do: query

  def where_tenant_unless_platform(query, %Cyfr.Actor{} = actor),
    do: where_tenant(query, actor)

  @doc """
  Add an athanor filter to a query for a bare athanor id.

  This is the plain filter for call sites that carry an athanor id string
  read off a row they already hold, not an actor. Actor-driven queries go
  through `where_tenant/2`, which owns the fail-closed rejection. A
  `nil`/`""` id raises: there is nothing to scope to.
  """
  @spec where_athanor(Ecto.Queryable.t(), String.t()) :: Ecto.Query.t()
  def where_athanor(query, athanor_id) when is_binary(athanor_id) and athanor_id != "" do
    from(q in query, where: q.athanor_id == ^athanor_id)
  end

  def where_athanor(_query, athanor_id) do
    raise ArgumentError,
          "Arca.QueryHelpers.where_athanor/2: a resolved athanor_id is required, " <>
            "got #{inspect(athanor_id)}"
  end

  @doc """
  Scope a query to the athanor the actor carries.

  Fail-closed backstop: raises `ArgumentError` for any actor whose
  `athanor_id` is `nil`/`""` — including a platform-scope one. A platform
  reader that legitimately crosses athanors uses
  `where_tenant_unless_platform/2`; a platform task working inside one
  athanor carries that athanor on its actor.
  """
  @spec where_tenant(Ecto.Queryable.t(), Cyfr.Actor.t()) :: Ecto.Query.t()
  def where_tenant(query, %Cyfr.Actor{athanor_id: athanor_id} = actor) do
    if athanor_id in [nil, ""] do
      raise ArgumentError,
            "Arca.QueryHelpers.where_tenant/2: a resolved athanor_id is required " <>
              "(user_id=#{inspect(actor.user_id)} scope=#{inspect(actor.scope)} " <>
              "system=#{inspect(actor.system)})"
    end

    from(q in query, where: q.athanor_id == ^athanor_id)
  end

  @doc """
  Stamps the actor's athanor into write attributes. Raises for an
  unresolved actor, using the same backstop as `where_tenant/2`.
  """
  @spec stamp_tenant!(Cyfr.Actor.t(), map()) :: map()
  def stamp_tenant!(%Cyfr.Actor{athanor_id: athanor_id} = actor, attrs)
      when is_map(attrs) do
    if athanor_id in [nil, ""] do
      raise ArgumentError,
            "Arca.QueryHelpers.stamp_tenant!/2: a resolved athanor_id is required " <>
              "(user_id=#{inspect(actor.user_id)} scope=#{inspect(actor.scope)} " <>
              "system=#{inspect(actor.system)})"
    end

    Map.put(attrs, :athanor_id, athanor_id)
  end

  @doc """
  The refusal a `!` entry point owes an actor with no resolved athanor.

  A `!` function runs inside a caller's transaction and answers a value,
  not a tagged tuple, so it has no `{:error, :no_athanor}` to give: it
  raises here instead, before any query, and the caller's transaction
  rolls back. Entry points that already answer tagged tuples refuse with
  `{:error, :no_athanor}` and never reach this.
  """
  @spec no_athanor!(String.t()) :: no_return()
  def no_athanor!(fun) when is_binary(fun) do
    raise ArgumentError, "#{fun}: a resolved athanor is required, got an actor carrying none"
  end

  @doc """
  Conditionally add a key-value pair to a keyword list.
  Returns the keyword list unchanged if the value is nil.
  """
  @spec maybe_put(keyword(), atom(), any()) :: keyword()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  The retention window: rows whose `field` timestamp is before `cutoff` —
  the one filter every `delete_before`/`count_before` pair speaks.
  """
  @spec where_before(Ecto.Queryable.t(), atom(), DateTime.t()) :: Ecto.Query.t()
  def where_before(query, field, %DateTime{} = cutoff) when is_atom(field) do
    from(r in query, where: field(r, ^field) < ^cutoff)
  end
end
