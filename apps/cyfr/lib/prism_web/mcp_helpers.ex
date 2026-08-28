# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.MCPHelpers do
  @moduledoc """
  The seam between LiveViews and the MCP tool surface.

  All tool invocations go through `Emissary.MCP.ToolRegistry.call_external/3`
  using the `Sanctum.Context` stored in socket assigns.

  ## Two planes, and which one a mutation belongs to

  Almost everything the console changes goes through a tool: components,
  executions, schedules, keys, webhooks, connections, the door. Those are
  the athanor's state, an agent can reach them too, and one gate should
  answer for both.

  What does not go through a tool is state that exists only because a
  person is looking at a screen — their UI preferences, the conversation
  they are having, a cache key being invalidated after a refresh. There is
  no tool for those because there should not be one: a `conversation.read`
  tool would put someone's chat history inside the agent-reachable surface,
  which is the opposite of what a private console is for.

  The rule, then: **if an agent should be able to do it, it is a tool call.
  If it exists only for the person at the keyboard, the console owns it
  directly.** `PrismWeb.ToolSeamTest` pins the second list, which is two
  calls long — the ones that grow it are worth an argument.

  ## Result keys

  Built-in tools return their handler's Elixir terms verbatim — atom keys,
  always. Only proxied `server:tool` calls carry decoded JSON with string
  keys. So a page calling built-in tools never defends against both key
  spellings; a page talking to an external server defends at that call
  site alone.
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
    Emissary.MCP.ToolRegistry.call_external(name, ctx, merged_args)
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

  def error_message(%Compendium.OCI.Errors{} = err),
    do: Compendium.MCP.Shared.to_error_string(err)

  def error_message(%{message: msg}) when is_binary(msg), do: msg

  def error_message(reason) do
    cond do
      Sanctum.Unauthorized.reason?(reason) ->
        Sanctum.Unauthorized.message(reason)

      Emissary.MCP.ToolError.reason?(reason) ->
        Emissary.MCP.ToolError.message(reason)

      true ->
        Logger.warning("[MCPHelpers] tool call failed: #{inspect(reason)}")
        "The request failed — try again."
    end
  end

  defp normalize_tool_call(tool_name, args) do
    case String.split(tool_name, "/", parts: 2) do
      [name, action] -> {name, Map.put(args, "action", action)}
      [name] -> {name, args}
    end
  end
end
