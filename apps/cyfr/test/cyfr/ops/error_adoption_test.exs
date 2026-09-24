# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Ops.ErrorAdoptionTest do
  @moduledoc """
  A ratchet on the conversion to `Cyfr.Refusal`, the one refusal
  vocabulary.

  Limits plain-string error returns per module and rejects unlisted
  producers. A module may reduce its allowance as it adopts typed errors.

  So the roster is here, it is checked, and it only goes down:

  - A module that grows a new `{:error, "…"}` fails, naming it.
  - A module that converts some and forgets this file fails too, so the
    number in front of a reader is the number in the tree.
  - A module the scan reaches and the roster does not name may not return
    string errors at all.

  Converting one is the fix; lowering its number is the bookkeeping.
  Reaching zero deletes its line. Crafted operator sentences that fit no
  member of the vocabulary — compiler output, remediation hints, an
  upstream provider's own error code, a partial-failure count — are
  legitimately strings and simply stay counted here.

  ## What the scan reaches

  A tool module — one that defines `definition` or `handle/3` — and every
  module it names that this umbrella defines. Both halves are needed,
  because a refusal reaches a renderer from wherever it was produced: the
  scan read only tool modules once, and `Compendium.Builds.Provider`
  counted 2 where `Locus.MCP` counted 11, because the build orchestration's
  sentences live in `Compendium.Builds`, which defines no tool and which
  the scan never opened.
  """

  use ExUnit.Case, async: true

  # module path => string-returning `{:error, "…"}` sites remaining.
  # Ordered by size, which is also the order worth converting them in.
  @worklist %{
    "apps/cyfr_contracts/lib/cyfr/component_ref.ex" => 20,
    "apps/cyfr/lib/emissary/mcp/external_server.ex" => 19,
    # The concurrency argument's own refusal is a sentence about the value
    # offered; the two that were the tool's catch-alls are typed now, so
    # the action-coverage case reads one vocabulary.
    "apps/cyfr/lib/cyfr/schedules/provider.ex" => 18,
    "apps/sanctum/lib/sanctum/mcp/webhook_tool.ex" => 18,
    "apps/cyfr/lib/cyfr/execution/mcp.ex" => 13,
    # An upstream registry's own diagnostics, which are its words and not
    # this vocabulary's.
    "apps/cyfr/lib/compendium/oci/client.ex" => 12,
    "apps/cyfr/lib/emissary/mcp/tools/system_provider.ex" => 12,
    "apps/cyfr_contracts/lib/cyfr/authority/blob.ex" => 11,
    "apps/sanctum/lib/sanctum/mcp/key_tool.ex" => 11,
    # What is wrong with a cron expression, said in the expression's own
    # terms.
    "apps/cyfr/lib/cyfr/schedules/cron.ex" => 10,
    "apps/cyfr/lib/compendium/scaffold.ex" => 8,
    "apps/cyfr/lib/compendium/mcp.ex" => 6,
    "apps/cyfr/lib/compendium/mcp/component_tool.ex" => 7,
    "apps/cyfr/lib/cyfr/tincture_helpers.ex" => 7,
    "apps/sanctum/lib/sanctum/mcp/profile_tool.ex" => 7,
    "apps/sanctum/lib/sanctum/webhook.ex" => 7,
    "apps/cyfr/lib/emissary/mcp/mcp_servers_tool.ex" => 6,
    "apps/cyfr/lib/compendium/fork.ex" => 5,
    "apps/cyfr/lib/compendium/oci/reference.ex" => 5,
    "apps/cyfr_contracts/lib/cyfr/limits.ex" => 5,
    "apps/sanctum/lib/sanctum/provider_credentials.ex" => 5,
    "apps/cyfr/lib/aqua/approvals.ex" => 4,
    "apps/cyfr/lib/compendium/component.ex" => 4,
    "apps/cyfr/lib/compendium/mcp/shared.ex" => 4,
    "apps/cyfr/lib/compendium/registry.ex" => 4,
    "apps/cyfr/lib/cyfr/ops/catalog.ex" => 4,
    # The build orchestration behind `Compendium.Builds.Provider`: the
    # three this ratchet could not see until the scan followed a tool
    # module into what it calls.
    "apps/cyfr/lib/compendium/builds.ex" => 3,
    "apps/cyfr/lib/emissary/mcp/external_provider.ex" => 3,
    # The retention tool's handlers, moved with their sentences until the
    # storage layer owns retention.
    "apps/cyfr/lib/cyfr/retention.ex" => 3,
    "apps/sanctum/lib/sanctum/mcp/oauth_tool.ex" => 3,
    # Two of the three are the capacity refusals a poller sees when the
    # server will not mint them an athanor: remediation prose (wait, or ask
    # the operator), not a resource that is missing or briefly away.
    "apps/sanctum/lib/sanctum/mcp/session_tool.ex" => 3,
    "apps/sanctum/lib/sanctum/vault/oauth_grant.ex" => 3,
    "apps/cyfr/lib/aqua/policy.ex" => 2,
    # A tool this provider does not define, and the validation rate a
    # caller reached, with the seconds to wait.
    "apps/cyfr/lib/compendium/builds/provider.ex" => 2,
    "apps/cyfr/lib/cyfr/execution/record.ex" => 2,
    "apps/cyfr_contracts/lib/cyfr/ops/arg.ex" => 2,
    "apps/sanctum/lib/sanctum/mcp.ex" => 1,
    "apps/cyfr/lib/compendium/pull.ex" => 1,
    "apps/sanctum/lib/sanctum/api_key.ex" => 1,
    "apps/sanctum/lib/sanctum/auth/device_flow.ex" => 1,
    "apps/sanctum/lib/sanctum/mcp/athanor_tool.ex" => 1,
    "apps/sanctum/lib/sanctum/mcp/tincture_visibility_tool.ex" => 1,
    "apps/sanctum/lib/sanctum/vault.ex" => 1
  }

  defp root, do: Path.expand("../../../../..", __DIR__)

  defp lib_files do
    root()
    |> Cyfr.Test.SourceTree.app_libs()
    |> Enum.flat_map(&Cyfr.Test.SourceTree.files!(Path.join([root(), &1, "**/*.ex"])))
  end

  # A module that defines a tool: where a refusal that reaches a renderer
  # is answered.
  defp tool_modules do
    Enum.filter(lib_files(), fn path ->
      source = Cyfr.Test.SourceTree.read(path)
      String.contains?(source, "def definition") or String.contains?(source, "def handle(")
    end)
  end

  # The tool modules, and every module of this umbrella they name. A
  # refusal a tool returns is often produced a call deeper, and a scan
  # that stops at the tool counts the wrong number.
  defp scanned_modules do
    by_module =
      for path <- lib_files(),
          name = defmodule_name(path),
          name != nil,
          into: %{},
          do: {name, path}

    tools = tool_modules()

    reached =
      for tool <- tools,
          {name, _line} <- Cyfr.Test.SourceTree.aliases(tool),
          path = Map.get(by_module, name),
          do: path

    Enum.uniq(tools ++ reached)
  end

  defp defmodule_name(path) do
    path
    |> Cyfr.Test.SourceTree.code_lines()
    |> Enum.find_value(fn {line, _n} ->
      case Regex.run(~r/^defmodule ([A-Z][\w.]*) do$/, line, capture: :all_but_first) do
        [name] -> name
        _ -> nil
      end
    end)
  end

  defp string_error_count(path) do
    path
    |> Cyfr.Test.SourceTree.code_lines()
    |> Enum.count(fn {line, _n} -> String.contains?(line, ~s|{:error, "|) end)
  end

  test "the scan reaches past the tool modules into what they call" do
    scanned = MapSet.new(scanned_modules(), &Path.relative_to(&1, root()))

    assert MapSet.size(scanned) > length(tool_modules()),
           "the scan reads only the tool modules; a refusal produced a call deeper is invisible"

    assert MapSet.member?(scanned, "apps/cyfr/lib/compendium/builds.ex"),
           "the build orchestration behind `Compendium.Builds.Provider` is the case this " <>
             "widening was measured against, and the scan does not open it"
  end

  test "no scanned module returns more string errors than the roster records" do
    counts =
      for path <- scanned_modules(),
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
           These modules gained `{:error, "…"}` sites:

           #{Enum.join(Enum.sort(grown), "\n")}

           A refusal that a caller might branch on belongs in the
           `Cyfr.Refusal` vocabulary — `{:not_found, kind, name}`,
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

  test "the roster names only modules the scan still reaches" do
    live = MapSet.new(scanned_modules(), &Path.relative_to(&1, root()))

    gone = for rel <- Map.keys(@worklist), not MapSet.member?(live, rel), do: rel

    assert gone == [],
           "the roster names files that are gone or no longer reached: #{inspect(Enum.sort(gone))}"
  end
end
