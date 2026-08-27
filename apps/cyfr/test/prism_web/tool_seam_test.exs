# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ToolSeamTest do
  @moduledoc """
  `PrismWeb.MCPHelpers` is the console's seam onto the MCP tool surface —
  one place that splits `"tool/action"`, one `error_message/1` vocabulary.

  Eight console call sites reached past it and spelled
  `ToolRegistry.call_external/3` themselves, all for the same reason:
  `call_tool/3` wanted a socket, and work handed to `Prism.TaskSupervisor`
  has a context and no socket. The seam takes a context now, so the reason
  is gone — and this test is what keeps the sites from coming back.
  """

  use ExUnit.Case, async: true

  @seam "apps/cyfr/lib/prism_web/mcp_helpers.ex"

  defp root, do: Path.expand("../../../..", __DIR__)

  test "the console reaches the tool surface only through its seam" do
    offenders =
      [Path.join(root(), "apps/cyfr/lib/prism_web/**/*.ex")]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.reject(&String.ends_with?(&1, "mcp_helpers.ex"))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} ->
          String.contains?(line, "ToolRegistry.call_external")
        end)
        |> Enum.map(fn {_line, n} -> "#{Path.relative_to(path, root())}:#{n}" end)
      end)

    assert offenders == [],
           """
           These console modules call the tool registry directly instead of
           `PrismWeb.MCPHelpers.call_tool/3`:

           #{Enum.map_join(offenders, "\n", &"  #{&1}")}

           `call_tool/3` takes a `%Sanctum.Context{}` as well as a socket, so
           work inside a supervised task has no reason to reach past #{@seam}.
           """
  end

  test "call_tool splits tool/action for both shapes" do
    ctx = Sanctum.TestContext.local()

    # An unknown tool is refused by the registry rather than raising, which
    # is enough to show the name/action split happened before dispatch.
    assert {:error, _} = PrismWeb.MCPHelpers.call_tool(ctx, "no-such-tool/list", %{})

    socket = %Phoenix.LiveView.Socket{assigns: %{context: ctx, __changed__: %{}}}
    assert {:error, _} = PrismWeb.MCPHelpers.call_tool(socket, "no-such-tool/list", %{})

    assert {:error, :no_context} =
             PrismWeb.MCPHelpers.call_tool(
               %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}},
               "component/list",
               %{}
             )
  end
end
