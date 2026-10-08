# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Ops do
  @moduledoc """
  The console's adapter onto the operation catalog.

  All tool invocations go through `Grimoire.call_external/3`
  using the `Sanctum.Context` stored in socket assigns — in-process: the
  gate, the contract and the handler on the LiveView's own process, with
  no task, timeout or wire encoding between them.

  ## Mutation scope

  Component, execution, schedule, credential, webhook, connection, and
  admission changes use the operation catalog and its authorization gate.

  UI preferences, cache invalidation, and authenticated chat operations
  call their domain functions directly. `Aqua.Providers.Thread` exposes chat
  operations separately to external OIDC-interactive clients.

  PrismWeb.ToolSeamTest checks the allowed direct domain calls.

  ## Result keys

  Two normalizations exist, and a page must know which it is on:

    * `call_tool/3` (this module) returns built-in handlers' Elixir terms
      VERBATIM — atom keys at the top level, but a field decoded from a
      stored JSON column keeps its string keys. Proxied `server:tool`
      calls carry decoded JSON throughout.
    * `PrismWeb.AquaLive.Section.call_aqua/2` deep-stringifies on the way out, so
      its consumers read string keys only.

  Some nested JSON values remain string-keyed inside atom-keyed rows.
  Check the field’s producer before removing mixed-key access handling.
  """

  @doc """
  Call an MCP tool with the socket's context, or with a context directly.

  The context form supports supervised tasks that have no LiveView socket.
  Either way the context passes `CyfrWeb.ContextGuard.check/1` first: one
  older than the freshness bound is revalidated for this call, and one
  that no longer stands is the call's refusal — nothing is dispatched.
  That refusal never reaches the gate, so it is recorded here as the one
  admission decision of the call, as an entry records a refusal it makes
  before the gate; a call the gate is reached for is the gate's to record.
  The record keeps the person and names no tenant, whatever the state of
  the athanor the context names, as a refusal before sign-in is filed. A
  socket with no context is refused `:no_context` and records nothing:
  there is no caller to attribute it to.

  A sensitive change the call makes may answer the consent signal
  `{:error, {:confirmation_required, %{id: id, …}}}`. Once the person
  proved that confirmation, the page repeats the same call with
  `confirmation_id: id` in `opts`, and the repeat carries the id in its
  context (`Sanctum.Context`'s `confirmation_id`), where the deciding site
  consumes it. A confirmation is for its one change: the id rides this
  call alone, never the socket's context.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def call_tool(socket_or_context, tool_name, args \\ %{}, opts \\ [])

  def call_tool(%Sanctum.Context{} = ctx, tool_name, args, opts) when is_list(opts) do
    {name, merged_args} = normalize_tool_call(tool_name, args)

    case CyfrWeb.ContextGuard.check(ctx) do
      {:ok, ctx} ->
        Grimoire.call_external(name, confirming(ctx, opts), merged_args)

      {:error, reason} = refused ->
        record_refusal(ctx, name, merged_args, reason)
        refused
    end
  end

  def call_tool(socket, tool_name, args, opts) when is_list(opts) do
    case socket.assigns do
      %{context: %Sanctum.Context{} = ctx} -> call_tool(ctx, tool_name, args, opts)
      _ -> {:error, :no_context}
    end
  end

  # The guard's refusal as the call's one decision, through the path an
  # entry records a refusal before the gate on (`Grimoire.refused_decision/3`):
  # under the person the refused context presented and no tenant, on the
  # plane every ingress takes, with the operation it named and the guard's
  # reason. The call id is minted for it, never a call id the context still
  # carries from an earlier call; the request id is the context's when it
  # has one, as the gate takes it, and a new one otherwise. Audit never
  # decides the refusal: the call is refused whether or not the record
  # lands.
  defp record_refusal(ctx, name, args, reason) do
    ctx = attributed(ctx)

    decision =
      Grimoire.refused_decision(ctx, reason,
        request_id: ctx.request_id || Prima.UUID7.request_id(),
        plane: :external,
        tool: name,
        action: action_of(args)
      )

    Grimoire.open_decision(ctx, decision, %{method: "tools/call", input: %{}})
  end

  # A refusal the guard makes is filed under no tenant, whatever the state
  # of the athanor the refused context names, as a refusal before sign-in
  # is: it keeps the person, and the athanor's id reaches neither log.
  # `decision_logs` and `mcp_logs` rows are erased by athanor id when an
  # athanor is destroyed, and the room can be archived and destroyed at any
  # moment before this write lands, so no read of its state made first
  # could keep a row from outliving that erasure; there is no such read.
  # The swap empties the athanor for this audit write alone: it narrows
  # onto no athanor, grants nothing, and the context is never used to act.
  defp attributed(%Sanctum.Context{} = ctx), do: %{ctx | athanor_id: nil}

  # The action as the gate reads it.
  defp action_of(args) when is_map(args), do: Map.get(args, "action") || Map.get(args, :action)
  defp action_of(_args), do: nil

  # The confirmation a repeated change names, or none: a caller's own
  # `confirmation_id` never survives into a call that names none.
  defp confirming(ctx, opts) do
    case Keyword.get(opts, :confirmation_id) do
      id when is_binary(id) and id != "" -> %{ctx | confirmation_id: id}
      _none -> %{ctx | confirmation_id: nil}
    end
  end

  @doc """
  Call a tool whose result is a list under `key`, and unwrap it.

  The one place the two list shapes are known: most tools answer
  `{:ok, %{entries: [...]}}`-style maps, a few answer the bare list.
  Anything else — including a refusal — comes back as
  `{:error, message}` through `error_message/1`, so a page shows one
  vocabulary of failure and never a raw term.
  """
  def fetch_list(socket, tool_name, key, args \\ %{}) when is_atom(key) do
    case call_tool(socket, tool_name, args) do
      {:ok, %{^key => list}} when is_list(list) -> {:ok, list}
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, other} -> {:error, error_message({:unexpected_shape, other})}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  @doc """
  One user-facing sentence for a tool failure.

  Every refusal renders through the table (`Grimoire.render/1`), the
  same sentence on the wire and the page: a bare sentence as its own
  words, an authorization refusal through its vocabulary, anything else
  logged and generalized — internal terms never reach the page.
  """
  def error_message(reason)
  def error_message(:no_context), do: "Not signed in."
  def error_message(reason), do: Grimoire.render(reason)

  defp normalize_tool_call(tool_name, args) do
    case String.split(tool_name, "/", parts: 2) do
      [name, action] when is_map(args) -> {name, Map.put(args, "action", action)}
      [name, _action] -> {name, args}
      [name] -> {name, args}
    end
  end
end
