defmodule PrismWeb.MCPHelpers do
  @moduledoc """
  Convenience wrapper for MCP tool calls from LiveViews.

  All tool invocations go through `Emissary.MCP.ToolRegistry.call/3`
  using the `Sanctum.Context` stored in socket assigns.
  """

  @doc """
  Call an MCP tool using the context from socket assigns.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  def call_tool(socket, tool_name, args \\ %{}) do
    ctx = socket.assigns.context
    {name, merged_args} = normalize_tool_call(tool_name, args)
    Emissary.MCP.ToolRegistry.call(name, ctx, merged_args)
  end

  @doc """
  Call an MCP tool, returning the result or a default on error.
  """
  def call_tool!(socket, tool_name, args \\ %{}, default \\ nil) do
    case call_tool(socket, tool_name, args) do
      {:ok, result} -> result
      {:error, _} -> default
    end
  end

  defp normalize_tool_call(tool_name, args) do
    case String.split(tool_name, "/", parts: 2) do
      [name, action] -> {name, Map.put(args, "action", action)}
      [name] -> {name, args}
    end
  end
end
