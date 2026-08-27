# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.MCPHelpers do
  @moduledoc """
  The seam between LiveViews and the MCP tool surface.

  All tool invocations go through `Emissary.MCP.ToolRegistry.call_external/3`
  using the `Sanctum.Context` stored in socket assigns.

  ## Result keys

  Built-in tools return their handler's Elixir terms verbatim — atom keys,
  always. Only proxied `server:tool` calls carry decoded JSON with string
  keys. So a page calling built-in tools never defends against both key
  spellings; a page talking to an external server defends at that call
  site alone.
  """

  @doc """
  Call an MCP tool using the context from socket assigns.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def call_tool(socket, tool_name, args \\ %{}) do
    case socket.assigns do
      %{context: %Sanctum.Context{} = ctx} ->
        {name, merged_args} = normalize_tool_call(tool_name, args)
        Emissary.MCP.ToolRegistry.call_external(name, ctx, merged_args)

      _ ->
        {:error, :no_context}
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
    if Sanctum.Unauthorized.reason?(reason) do
      Sanctum.Unauthorized.message(reason)
    else
      require Logger
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
