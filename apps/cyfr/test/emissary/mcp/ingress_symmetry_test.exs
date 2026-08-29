# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.IngressSymmetryTest do
  @moduledoc """
  Both ingresses hand a tool the same arguments.

  `Emissary.MCP.Router` validates `arguments` against the tool's
  `inputSchema` before dispatch; `ToolRegistry.call_external/4` — the console's
  path, through `PrismWeb.MCPHelpers` — did not. So a `phx-click` (or a
  crafted channel frame, since event params are client-controlled) reached a
  handler with arguments `POST /mcp` would have refused `-32602`, and every
  handler had to defend twice. `tool_registry.ex`'s own comment named the gap
  ("the HTTP path never gets here — InputValidator enforces the schema enum
  first") without closing it.
  """
  use ExUnit.Case, async: false

  alias Emissary.MCP.ToolRegistry

  defmodule Provider do
    # Records exactly what it was handed, so the test can tell "refused before
    # dispatch" from "the handler coped".
    def handle("ingress_probe", _ctx, %{"action" => "echo"} = args) do
      # The provider runs in a task, not the test process, so the signal goes
      # through the registered name the test set up.
      send(:ingress_probe_observer, {:reached_handler, args})
      {:ok, %{ok: true}}
    end

    def handle("ingress_probe", _ctx, _args), do: {:error, "unknown action"}
  end

  @schema %{
    "type" => "object",
    "properties" => %{
      "action" => %{"type" => "string", "enum" => ["echo"]},
      "id" => %{"type" => "string"}
    },
    "required" => ["action"]
  }

  setup do
    ToolRegistry.register_tool(
      "ingress_probe",
      Provider,
      %{
        annotations: %{actions: %{"echo" => %{kind: :read, planes: [:external]}}},
        input_schema: @schema
      },
      :timer.minutes(1)
    )

    Process.register(self(), :ingress_probe_observer)

    on_exit(fn -> ToolRegistry.unregister_tool("ingress_probe") end)
    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "a wrongly-typed argument is refused on the console path too", %{ctx: ctx} do
    # The schema says `id` is a string. Over `POST /mcp` this is a -32602;
    # through the console it used to reach the handler as an integer.
    assert {:error, _} =
             ToolRegistry.call_external("ingress_probe", ctx, %{
               "action" => "echo",
               "id" => 12_345
             })

    refute_receive {:reached_handler, _}, 200
  end

  test "an unknown action is still refused in its own vocabulary", %{ctx: ctx} do
    # The annotation layer owns which actions exist, and says so as
    # `{:unknown_action, …}`. Schema validation deliberately does not answer
    # first here: unknown actions were never the gap, and two refusals for one
    # condition is the drift `Emissary.MCP.ToolError` exists to end.
    assert {:error, {:unknown_action, _}} =
             ToolRegistry.call_external("ingress_probe", ctx, %{"action" => "nope"})

    refute_receive {:reached_handler, _}, 200
  end

  test "a well-formed call still reaches the handler", %{ctx: ctx} do
    assert {:ok, _} =
             ToolRegistry.call_external("ingress_probe", ctx, %{
               "action" => "echo",
               "id" => "abc"
             })

    assert_receive {:reached_handler, %{"action" => "echo", "id" => "abc"}}, 2_000
  end

  test "a tool with no schema is unaffected", %{ctx: ctx} do
    ToolRegistry.register_tool(
      "ingress_probe_bare",
      Provider,
      %{annotations: %{actions: %{"echo" => %{kind: :read, planes: [:external]}}}},
      :timer.minutes(1)
    )

    on_exit(fn -> ToolRegistry.unregister_tool("ingress_probe_bare") end)

    assert {:error, {:unknown_action, _}} =
             ToolRegistry.call_external("ingress_probe_bare", ctx, %{"action" => "nope"})
  end
end
