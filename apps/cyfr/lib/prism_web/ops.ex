# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.Ops do
  @moduledoc """
  The console's adapter onto the operation catalog.

  All tool invocations go through `Cyfr.Ops.Catalog.call_external/3`
  using the `Sanctum.Context` stored in socket assigns — in-process: the
  gate, the contract and the handler on the LiveView's own process, with
  no task, timeout or wire encoding between them.

  ## Two planes, and which one a mutation belongs to

  Almost everything the console changes goes through a tool: components,
  executions, schedules, keys, webhooks, connections, the door. Those are
  the athanor's state, an agent can reach them too, and one gate should
  answer for both.

  What does not go through a tool is state that exists only because a
  person is looking at a screen — their UI preferences, a cache key being
  invalidated after a refresh, the chat they are typing into. Chat IS on
  the wire (`Emissary.MCP.ConversationTool` — external-plane and
  OIDC-interactive, so no agent and no API key reaches it), but the
  console does not call its own tool for it: the LiveView already holds
  an authenticated member context, so it is a deliberate in-process
  client of the same domain functions the tool wraps. Same functions,
  two doors — the registry gate exists for surfaces that arrive without
  one.

  The rule, then: **if an agent should be able to do it, it is a tool call.
  If it exists only for the person at the keyboard, the console owns it
  directly.** `PrismWeb.ToolSeamTest` pins the second list — the calls
  that grow it are worth an argument. (The list itself lives in the test:
  a count here drifted the moment it grew.)

  ## Result keys

  Two normalizations exist, and a page must know which it is on:

    * `call_tool/3` (this module) returns built-in handlers' Elixir terms
      VERBATIM — atom keys at the top level, but a field decoded from a
      stored JSON column keeps its string keys. Proxied `server:tool`
      calls carry decoded JSON throughout.
    * `Aqua.AgentConfig.call_aqua/2` deep-stringifies on the way out, so
      its consumers read string keys only.

  An earlier version of this note claimed the pages' `x[:k] || x["k"]`
  defenses were gone; they are not (a shared `f/2` helper is copy-pasted
  across the feed pages), and some guard genuinely mixed shapes
  (JSON-decoded columns inside atom-keyed rows). Removing one is safe only
  after verifying that field's producer — do not delete them wholesale on
  the strength of this paragraph.
  """

  require Logger

  @doc """
  Call an MCP tool with the socket's context, or with a context directly.

  The second shape is for work a page hands to `Aqua.TaskSupervisor`: a
  task has the context but no socket, which is why those call sites used to
  reach past this module and spell the registry call themselves — losing
  the `"tool/action"` split with them.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def call_tool(socket_or_context, tool_name, args \\ %{})

  def call_tool(%Sanctum.Context{} = ctx, tool_name, args) do
    {name, merged_args} = normalize_tool_call(tool_name, args)
    Cyfr.Ops.Catalog.call_external(name, ctx, merged_args)
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
    # The same renderer the wire and the guest use
    # (`Cyfr.Ops.Error.render/1`): this used to carry its own `cond`,
    # which had drifted — it knew nothing of the crash/exit/timeout tuples and
    # showed the generic sentence for all three, losing the distinction.
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
      [name, action] -> {name, Map.put(args, "action", action)}
      [name] -> {name, args}
    end
  end
end
