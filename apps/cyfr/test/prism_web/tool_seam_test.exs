# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.ToolSeamTest do
  @moduledoc """
  `PrismWeb.MCPHelpers` is the console's seam onto the MCP tool surface —
  one place that splits `"tool/action"`, one `error_message/1` vocabulary.

  Eight console call sites reached past it and spelled
  `ToolRegistry.call_external/3` themselves, all for the same reason:
  `call_tool/3` wanted a socket, and work handed to `Aqua.TaskSupervisor`
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

  # State that exists only because a person is looking at a screen. Every
  # other change the console makes goes through a tool, because an agent can
  # make it too and one gate should answer for both.
  @console_owned [
    # Someone's own UI preferences. There is no `user.put_prefs` tool and
    # there should not be one.
    {"apps/cyfr/lib/prism_web/live/settings_live.ex", "Sanctum.Tenancy.Users.put_prefs"},
    # Dropping the in-flight marker after a manual tincture refresh. Cache
    # invalidation, not persistence.
    {"apps/cyfr/lib/prism_web/live/shell_live.ex", "Arca.Cache.delete_match"},
    # The one transcription of a sign-in outcome to a browser response —
    # it mints and retires the person's OWN session, before any console
    # exists for them. Door placement is pinned by Sanctum.DoorPlacementTest.
    {"apps/cyfr/lib/prism_web/sign_in_response.ex", "Sanctum.Session.create"},
    {"apps/cyfr/lib/prism_web/sign_in_response.ex", "Sanctum.Session.destroy"}
  ]

  @mutating_call ~r/\b((?:Arca|Sanctum|Compendium|Opus|Locus|Emissary)(?:\.[A-Z]\w+)*)\.(create\w*|update\w*|delete\w*|put_\w+|set_\w+|insert\w*|revoke\w*|rotate\w*|archive\w*|remove\w*|reindex\w*|save\w*|destroy\w*|add_\w+)\b/

  test "the console mutates other namespaces only where it owns the state" do
    allowed = MapSet.new(@console_owned)

    found =
      [Path.join(root(), "apps/cyfr/lib/prism_web/**/*.ex")]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.flat_map(fn path ->
        rel = Path.relative_to(path, root())

        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reject(fn {line, _n} -> String.match?(line, ~r/^\s*#/) end)
        |> Enum.flat_map(fn {line, n} ->
          @mutating_call
          |> Regex.scan(line)
          |> Enum.map(fn [call | _] -> {rel, call, n} end)
        end)
      end)

    offenders =
      for {rel, call, n} <- found,
          not MapSet.member?(allowed, {rel, call}),
          do: "#{rel}:#{n}: #{call}"

    assert offenders == [],
           """
           The console changes state in another namespace directly:

           #{Enum.map_join(Enum.sort(offenders), "\n", &"  #{&1}")}

           If an agent should be able to do this, it is a tool call —
           `call_tool/3`, so one gate answers for the page and the agent
           alike. If it exists only for the person at the keyboard, add it to
           `@console_owned` above with a line saying why there is no tool.
           """

    stale =
      for {rel, call} <- @console_owned,
          not Enum.any?(found, fn {f, c, _} -> f == rel and c == call end),
          do: "#{rel}: #{call}"

    assert stale == [],
           "`@console_owned` names calls that are gone: #{inspect(Enum.sort(stale))}"
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
