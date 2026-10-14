# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.BusSourceScanTest do
  @moduledoc """
  The bus's ownership of every topic, read from the tree: nothing in any
  `lib` tree but the bus reaches the PubSub server, spells a topic or sends
  a retired message shape, and the retired helpers are gone. It reads
  source files and loaded modules only, so it runs beside other modules;
  `Cyfr.BusTest` holds the bus's behaviour.
  """
  use ExUnit.Case, async: true

  defp root, do: Path.expand("../../../..", __DIR__)

  # The bus's own file and its bounded dispatcher are the one place the
  # PubSub server is named and a topic is spelled; the boundary catalog
  # names every namespace it rosters and is read by its own scans.
  @owners ["apps/cyfr/lib/cyfr/bus.ex", "apps/cyfr/lib/cyfr/bus/bounded_dispatcher.ex"] ++
            Cyfr.Boundaries.scan_exclusions()

  @topic_literals ~w("tenant: "sanctum:vault "sanctum:athanor "sanctum:caller "sanctum:sessions
                     "sanctum:memberships "platform:notify "health_check: "room_feed:
                     "topbar:viewing "page: "bus: "thread: "execution:events "progress:
                     "cyfr:schedule_completions "cyfr:settings_changed)

  @retired [
    "{:execution_started,",
    "{:execution_completed,",
    "{:execution_failed,",
    "{:policy_decision,",
    "{:build_started,",
    "{:build_progress,",
    "{:build_stopped,",
    "{:schedule_fired,",
    "{:schedule_failed,",
    "{:component_installed,",
    "{:component_removed,",
    "{:component_pushed,",
    "{:tincture_invoke_started,",
    "{:tincture_invoke_stopped,",
    "{:tinctures_changed,",
    "{:vault_entry_changed,",
    "{:vault_entry_changed_global,",
    "{:athanor_archived_global,",
    "{:caller_invalidated,",
    "{:session_created,",
    "{:sessions_revoked,",
    "{:membership_changed,",
    "{:notify,",
    "{:register_progress,",
    "{:execution_event,",
    "{:thread,",
    "{:room_in_view,",
    "{:viewing,",
    "{:mcp_progress,",
    ":components_changed",
    ":schedules_updated",
    ":mcp_servers_changed",
    ":webhooks_changed",
    ":api_keys_changed"
  ]

  defp lib_lines do
    for lib <- Prima.Test.SourceTree.app_libs(root()),
        path <- Prima.Test.SourceTree.files!(Path.join([root(), lib, "**/*.ex"])),
        rel = Path.relative_to(path, root()),
        rel not in @owners,
        {line, n} <- Prima.Test.SourceTree.code_lines(path),
        do: {rel, n, line}
  end

  test "the scan reads every lib tree" do
    lines = lib_lines()
    assert length(lines) > 10_000
    assert Enum.any?(lines, fn {rel, _n, _line} -> String.starts_with?(rel, "apps/sanctum/") end)
    assert Enum.any?(lines, fn {rel, _n, _line} -> String.starts_with?(rel, "apps/arca/") end)
  end

  test "no lib tree but the bus names the PubSub server or calls it" do
    found =
      for {rel, n, line} <- lib_lines(),
          line =~ ~r/\bPhoenix\.PubSub\.|\bEmissary\.PubSub\b|\bCyfr\.PubSub\b/,
          # The one process start and the one server name the endpoint reads.
          rel != "apps/cyfr/lib/cyfr/application.ex",
          do: "#{rel}:#{n}: #{String.trim(line)}"

    assert found == []
  end

  test "no lib tree but the bus spells a topic" do
    found =
      for {rel, n, line} <- lib_lines(),
          Enum.any?(@topic_literals, &String.contains?(line, &1)),
          do: "#{rel}:#{n}: #{String.trim(line)}"

    assert found == []
  end

  test "no lib tree sends or matches a retired message shape" do
    found =
      for {rel, n, line} <- lib_lines(),
          Enum.any?(@retired, &String.contains?(line, &1)),
          do: "#{rel}:#{n}: #{String.trim(line)}"

    assert found == []
  end

  test "a planted reach, topic and retired shape are each found" do
    planted = ~S'''
    defmodule Planted do
      def a, do: Phoenix.PubSub.broadcast(Cyfr.PubSub, "tenant:x:bus:executions", :x)
      def b(msg), do: match?({:execution_started, _, _}, msg)
    end
    '''

    lines = Prima.Test.CodeLines.code_lines(planted)

    assert Enum.any?(lines, fn {line, _} -> line =~ ~r/\bPhoenix\.PubSub\./ end)
    assert Enum.any?(lines, fn {line, _} -> String.contains?(line, ~s("tenant:)) end)
    assert Enum.any?(lines, fn {line, _} -> Enum.any?(@retired, &String.contains?(line, &1)) end)
  end

  test "the retired helpers are gone" do
    refute Code.ensure_loaded?(Sanctum.PubSub)
    refute Code.ensure_loaded?(Prism.TelemetryBridge)

    exported =
      for {module, function, arity} <- [
            {Sanctum.Notify, :topic, 1},
            {Sanctum.Notify, :platform_topic, 0},
            {Sanctum.Session, :topic, 0},
            {Sanctum.Tenancy.Members, :topic, 1},
            {Emissary.MCP.Progress, :emit, 2}
          ],
          Code.ensure_loaded!(module),
          function_exported?(module, function, arity),
          do: {module, function, arity}

    assert exported == []

    refute Code.ensure_loaded?(Emissary.MCP.Progress.Registry)
  end
end
