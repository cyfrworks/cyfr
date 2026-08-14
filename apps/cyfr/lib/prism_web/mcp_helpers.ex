# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.MCPHelpers do
  @moduledoc """
  Convenience wrapper for MCP tool calls from LiveViews.

  All tool invocations go through `Emissary.MCP.ToolRegistry.call_external/3`
  using the `Sanctum.Context` stored in socket assigns.
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

  defp normalize_tool_call(tool_name, args) do
    case String.split(tool_name, "/", parts: 2) do
      [name, action] -> {name, Map.put(args, "action", action)}
      [name] -> {name, args}
    end
  end
end
