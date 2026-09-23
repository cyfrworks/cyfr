# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Ops do
  @moduledoc """
  The console's adapter onto the operation catalog.

  All tool invocations go through `Cyfr.Ops.Catalog.call_external/3`
  using the `Sanctum.Context` stored in socket assigns — in-process: the
  gate, the contract and the handler on the LiveView's own process, with
  no task, timeout or wire encoding between them.

  ## Mutation scope

  Component, execution, schedule, credential, webhook, connection, and
  admission changes use the operation catalog and its authorization gate.

  UI preferences, cache invalidation, and authenticated chat operations
  call their domain functions directly. ThreadTool exposes chat
  operations separately to external OIDC-interactive clients.

  PrismWeb.ToolSeamTest checks the allowed direct domain calls.

  ## Result keys

  Two normalizations exist, and a page must know which it is on:

    * `call_tool/3` (this module) returns built-in handlers' Elixir terms
      VERBATIM — atom keys at the top level, but a field decoded from a
      stored JSON column keeps its string keys. Proxied `server:tool`
      calls carry decoded JSON throughout.
    * `Aqua.AgentConfig.call_aqua/2` deep-stringifies on the way out, so
      its consumers read string keys only.

  Some nested JSON values remain string-keyed inside atom-keyed rows.
  Check the field’s producer before removing mixed-key access handling.
  """

  require Logger

  @doc """
  Call an MCP tool with the socket's context, or with a context directly.

  The context form supports supervised tasks that have no LiveView socket.
  Either way the context passes `CyfrWeb.ContextGuard.check/1` first: one
  older than the freshness bound is revalidated for this call, and one
  that no longer stands is the call's refusal — nothing is dispatched.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def call_tool(socket_or_context, tool_name, args \\ %{})

  def call_tool(%Sanctum.Context{} = ctx, tool_name, args) do
    with {:ok, ctx} <- CyfrWeb.ContextGuard.check(ctx) do
      {name, merged_args} = normalize_tool_call(tool_name, args)
      Cyfr.Ops.Catalog.call_external(name, ctx, merged_args)
    end
  end

  def call_tool(socket, tool_name, args) do
    case socket.assigns do
      %{context: %Sanctum.Context{} = ctx} -> call_tool(ctx, tool_name, args)
      _ -> {:error, :no_context}
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

  Tool refusals are already sentences and pass through; an authorization
  refusal renders through its vocabulary; anything else is logged and
  generalized — internal terms never reach the page.
  """
  def error_message(reason)
  def error_message(message) when is_binary(message), do: message
  def error_message(:no_context), do: "Not signed in."

  def error_message(reason) do
    # Use the shared wire, console and guest error renderer.
    case Cyfr.Ops.Error.render(reason) do
      nil ->
        Logger.warning("[PrismWeb.Ops] tool call failed: #{inspect(reason)}")
        "The request failed — try again."

      message ->
        message
    end
  end

  defp normalize_tool_call(tool_name, args) do
    case String.split(tool_name, "/", parts: 2) do
      [name, action] when is_map(args) -> {name, Map.put(args, "action", action)}
      [name, _action] -> {name, args}
      [name] -> {name, args}
    end
  end
end
