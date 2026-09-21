# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.ErrorAdoptionTest do
  @moduledoc """
  A ratchet on the conversion to `Cyfr.Ops.Error`.

  Limits plain-string error returns per provider and rejects unlisted
  producers. Providers may reduce their allowance as they adopt typed errors.

  So the roster is here, it is checked, and it only goes down:

  - A module that grows a new `{:error, "…"}` fails, naming it.
  - A module that converts some and forgets this file fails too, so the
    number in front of a reader is the number in the tree.
  - A module absent from the roster may not return string errors at all.

  Converting one is the fix; lowering its number is the bookkeeping.
  Reaching zero deletes its line. Crafted operator sentences that fit no
  member of the vocabulary — compiler output, remediation hints, an
  upstream provider's own error code, a partial-failure count — are
  legitimately strings and simply stay counted here.
  """

  use ExUnit.Case, async: true

  # module path => string-returning `{:error, "…"}` sites remaining.
  # Ordered by size, which is also the order worth converting them in.
  @worklist %{
    # One more than the tool carried before: the concurrency argument's
    # own refusal, a sentence about the value offered.
    "apps/cyfr/lib/cyfr/schedules/provider.ex" => 20,
    "apps/sanctum/lib/sanctum/mcp/webhook_tool.ex" => 18,
    "apps/cyfr/lib/cyfr/execution/mcp.ex" => 14,
    "apps/cyfr/lib/emissary/mcp/tools/system_provider.ex" => 12,
    "apps/sanctum/lib/sanctum/mcp/key_tool.ex" => 11,
    "apps/sanctum/lib/sanctum/mcp/profile_tool.ex" => 7,
    "apps/cyfr/lib/compendium/mcp/component_tool.ex" => 7,
    "apps/cyfr/lib/compendium/mcp.ex" => 7,
    "apps/cyfr/lib/emissary/mcp/tools/records_provider.ex" => 6,
    "apps/cyfr/lib/emissary/mcp/mcp_servers_tool.ex" => 6,
    "apps/sanctum/lib/sanctum/mcp/oauth_tool.ex" => 3,
    "apps/sanctum/lib/sanctum/mcp.ex" => 2,
    # A tool this provider does not define, and the validation rate a
    # caller reached, with the seconds to wait.
    "apps/cyfr/lib/compendium/builds/provider.ex" => 2,
    "apps/sanctum/lib/sanctum/mcp/tincture_visibility_tool.ex" => 1,
    # Two of the three are the capacity refusals a poller sees when the
    # server will not mint them an athanor: remediation prose (wait, or ask
    # the operator), not a resource that is missing or briefly away.
    "apps/sanctum/lib/sanctum/mcp/session_tool.ex" => 3,
    "apps/sanctum/lib/sanctum/mcp/athanor_tool.ex" => 1
  }

  defp root, do: Path.expand("../../../../..", __DIR__)

  # Every module that defines a tool: those are the ones whose refusals
  # reach a renderer, and the only ones this roster is about.
  defp tool_modules do
    root()
    |> Cyfr.Test.SourceTree.app_libs()
    |> Enum.flat_map(&Cyfr.Test.SourceTree.files!(Path.join([root(), &1, "**/*.ex"])))
    |> Enum.filter(fn path ->
      source = Cyfr.Test.SourceTree.read(path)
      String.contains?(source, "def definition") or String.contains?(source, "def handle(")
    end)
  end

  defp string_error_count(path) do
    path
    |> Cyfr.Test.SourceTree.read()
    |> Cyfr.Test.CodeLines.code_lines()
    |> Enum.count(fn {line, _n} -> String.contains?(line, ~s|{:error, "|) end)
  end

  test "no tool module returns more string errors than the roster records" do
    counts =
      for path <- tool_modules(),
          rel = Path.relative_to(path, root()),
          count = string_error_count(path),
          count > 0,
          into: %{},
          do: {rel, count}

    grown =
      for {rel, count} <- counts,
          recorded = Map.get(@worklist, rel, 0),
          count > recorded,
          do: "  #{rel}: #{count} now, #{recorded} recorded"

    assert grown == [],
           """
           These tool modules gained `{:error, "…"}` sites:

           #{Enum.join(Enum.sort(grown), "\n")}

           A refusal that a caller might branch on belongs in the
           `Cyfr.Ops.Error` vocabulary — `{:not_found, kind, name}`,
           `{:invalid_argument, msg}`, `{:unavailable, service}` — so the
           wire, the console and the guest all render one decision.

           If the new sentence is genuinely crafted operator prose that fits
           no member (compiler output, a remediation hint, an upstream
           provider's own code), raise the number above and say which.
           """

    shrunk =
      for {rel, recorded} <- @worklist,
          count = Map.get(counts, rel, 0),
          count < recorded,
          do: "  #{rel}: #{count} now, #{recorded} recorded"

    assert shrunk == [],
           """
           These modules have FEWER string errors than recorded — good, but
           the roster is the number a reader trusts, so lower it (or delete
           the line at zero):

           #{Enum.join(Enum.sort(shrunk), "\n")}
           """
  end

  test "the roster names only modules that exist and still qualify" do
    live = MapSet.new(tool_modules(), &Path.relative_to(&1, root()))

    gone = for rel <- Map.keys(@worklist), not MapSet.member?(live, rel), do: rel

    assert gone == [],
           "the roster names files that are gone or no longer define a tool: #{inspect(Enum.sort(gone))}"
  end
end
