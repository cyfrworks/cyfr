# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.QueryHelpers do
  @moduledoc """
  Shared Ecto query helpers for Arca storage modules.

  ## Tenant scoping

  Every tenant-owned row carries an `athanor_id`. There is no sentinel and
  no coercion: a `nil`/`""` athanor on a context is a bug upstream, never a
  value to normalize into some default row set.

  ## Relationship to the trust boundary

  These helpers are a fail-closed **backstop**, not the authoritative tenant
  control. The authoritative per-record tenant + permission decision is
  `Sanctum.Context.authorize/3` (via `Sanctum.TenantPolicy`).
  `where_tenant/2` — the context-taking entry every tenant-scoped store
  queries through — scopes the query to the context's athanor and raises for
  a context whose `athanor_id` is unresolved: such a context bypassed the
  Sanctum chokepoint (`Sanctum.Context.require_tenant!/1`).
  `where_athanor/2` is the plain filter for bare-key call sites (an athanor
  id string, no context to judge). Callers must not rely on any of these as
  the primary control.
  """

  import Ecto.Query

  @doc """
  `where_tenant/2`, except a platform-scope context reads unfiltered —
  the query-level mirror of `Sanctum.TenantPolicy.verify/2`'s platform
  bypass. ONE definition so record readers (executions, MCP logs, policy
  logs) cannot drift in how they spell the bypass.
  """
  def where_tenant_unless_platform(query, %Sanctum.Context{scope: :platform}), do: query
  def where_tenant_unless_platform(query, ctx), do: where_tenant(query, ctx)

  @doc """
  Add an athanor filter to a query for a bare athanor id.

  This is the plain filter for call sites that carry an athanor id string,
  not a context (API-key / webhook lookups by stored coordinates). Context-
  driven queries go through `where_tenant/2`, which owns the fail-closed
  rejection. A `nil`/`""` id raises: there is nothing to scope to.
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
  Scope a query to the athanor identified by the given context.

  Fail-closed backstop: raises `ArgumentError` for any context whose
  `athanor_id` is `nil`/`""` — including a platform-scope one. A platform
  reader that legitimately crosses athanors uses
  `where_tenant_unless_platform/2`; a platform task working inside one
  athanor carries that athanor on its context.
  """
  @spec where_tenant(Ecto.Queryable.t(), Sanctum.Context.t()) :: Ecto.Query.t()
  def where_tenant(query, %Sanctum.Context{athanor_id: athanor_id} = ctx) do
    if athanor_id in [nil, ""] do
      raise ArgumentError,
            "Arca.QueryHelpers.where_tenant/2: a resolved athanor_id is required " <>
              "(user_id=#{inspect(ctx.user_id)} scope=#{inspect(ctx.scope)} " <>
              "auth_method=#{inspect(ctx.auth_method)})"
    end

    from(q in query, where: q.athanor_id == ^athanor_id)
  end

  @doc """
  Conditionally add a key-value pair to a keyword list.
  Returns the keyword list unchanged if the value is nil.
  """
  @spec maybe_put(keyword(), atom(), any()) :: keyword()
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
