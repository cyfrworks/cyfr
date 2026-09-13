# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.NamespaceDirectionTest do
  @moduledoc """
  Which way the dependency arrows point between the umbrella's apps.

  Checks that Opus and Locus depend on CYFR domain interfaces rather than web or console modules.

  The rule this pins is narrow and checkable: an engine does not depend on
  a user interface. `Emissary` is deliberately NOT on the forbidden list —
  opus implements `Cyfr.Ops.Provider` and dispatches in-chain tool
  calls through the registry, which is a real contract with the transport,
  honestly declared.
  """

  use ExUnit.Case, async: true

  @engine_libs [
    "apps/opus/lib",
    "apps/locus/lib",
    # The domain inside cyfr holds the same rule: storage, components and
    # identity never name the console (glue under lib/cyfr and the
    # transport under lib/emissary* are out of scope here).
    "apps/cyfr/lib/arca",
    "apps/cyfr/lib/compendium",
    "apps/cyfr/lib/sanctum",
    # The agent-orchestration domain: it drives the console's chat, but
    # through PubSub and rows — never by naming the console.
    "apps/cyfr/lib/aqua"
  ]

  # The console. An engine that names it has taken a UI module as a
  # dependency — `Prism.Topics` was the whole PubSub vocabulary, so opus,
  # locus, Sanctum and Compendium all did.
  @forbidden_from_engines ~r/\bPrism(Web)?\.[A-Z]/

  # The HTTP surface. Emissary (the MCP contract) is fair game for the
  # engine APPS — but EmissaryWeb (endpoint, router, plugs) is the web
  # layer, and an engine that names it has taken the browser surface as a
  # dependency. Scoped to apps/opus and apps/locus only; inside cyfr the
  # domain namespaces are held to the written-down roster below.
  @engine_apps ["apps/opus/lib", "apps/locus/lib"]
  @forbidden_web_from_engine_apps ~r/\bEmissaryWeb\.[A-Z]/

  defp root, do: Path.expand("../../../..", __DIR__)

  defp offenders(dirs, pattern) do
    dirs
    |> Enum.flat_map(fn dir ->
      root()
      |> Path.join(dir)
      |> Path.join("**/*.ex")
      |> Path.wildcard()
    end)
    |> Enum.flat_map(fn path ->
      path
      |> Cyfr.Test.SourceTree.read()
      # Doc prose is not a dependency: blank out heredoc bodies (module
      # and function docs), preserving line numbers for the report.
      |> String.replace(~r/"""[\s\S]*?"""/, fn block ->
        block |> String.split("\n") |> Enum.map_join("\n", fn _ -> "" end)
      end)
      |> String.split("\n")
      |> Enum.with_index(1)
      # A mention in a comment is prose, not a dependency.
      |> Enum.reject(fn {line, _n} -> String.match?(line, ~r/^\s*#/) end)
      |> Enum.filter(fn {line, _n} -> String.match?(line, pattern) end)
      |> Enum.map(fn {line, n} ->
        "#{Path.relative_to(path, root())}:#{n}: #{String.trim(line)}"
      end)
    end)
  end

  test "the engine apps do not depend on the console" do
    found = offenders(@engine_libs, @forbidden_from_engines)

    assert found == [],
           """
           engine/domain code reaches into the Prism (console) namespace:

           #{Enum.map_join(found, "\n", &"  #{&1}")}

           A shared primitive that both the engine and the console need is
           glue and belongs under `Cyfr.` — that is what `Cyfr.Topics` and
           `Cyfr.UUID7` are. Emissary is fair game (the MCP contract); a
           user interface is not.
           """
  end

  test "the engine apps do not depend on the web layer" do
    found = offenders(@engine_apps, @forbidden_web_from_engine_apps)

    assert found == [],
           """
           engine app code reaches into the EmissaryWeb (web layer) namespace:

           #{Enum.map_join(found, "\n", &"  #{&1}")}

           Emissary (the MCP contract) is the engines' honest dependency;
           the endpoint, router and plugs are not.
           """
  end

  # Inside cyfr, the domain namespaces may name the web layer — but only
  # where someone decided they should. This is the same shape as the engine
  # rule above, one level in: a NEW domain→web reach fails here until it is
  # argued, rather than accruing quietly the way these two did.
  @domain_dirs ["apps/cyfr/lib/sanctum", "apps/cyfr/lib/aqua", "apps/cyfr/lib/compendium"]

  # Empty: the assistant's navigation intents name a page by shape, and
  # `PrismWeb.Nav.page?/1` maps them to the route table on the web side.
  @domain_web_calls []

  # `{rel, module}` for every live domain→web reach, with its line.
  defp domain_web_reaches do
    for dir <- @domain_dirs,
        path <- Path.wildcard(Path.join(root(), dir <> "/**/*.ex")),
        rel = Path.relative_to(path, root()),
        {line, n} <- path |> Cyfr.Test.SourceTree.read() |> Cyfr.Test.CodeLines.code_lines(),
        [module] <- Regex.scan(~r/\bEmissaryWeb\.[A-Z]\w+/, line, capture: :first),
        do: {{rel, module}, n}
  end

  test "the domain namespaces reach the web layer only where it is written down" do
    allowed = MapSet.new(@domain_web_calls)

    found =
      for {{rel, module}, n} <- domain_web_reaches(),
          not MapSet.member?(allowed, {rel, module}),
          do: "#{rel}:#{n}: #{module}"

    assert found == [],
           """
           A domain namespace names the web layer somewhere this list does
           not cover:

           #{Enum.map_join(found, "\n", &"  #{&1}")}

           The auth domain reads key material and the public origin from
           CONFIG, not from the endpoint (`Sanctum.TinctureAuth` says why).
           If a new reach is right, add it above with a line saying so.
           """
  end

  # Reject exemptions that no longer correspond to a dependency.
  test "every domain→web exemption still names a live reach" do
    reached = MapSet.new(domain_web_reaches(), fn {pair, _n} -> pair end)

    stale = Enum.reject(@domain_web_calls, &MapSet.member?(reached, &1))

    assert stale == [],
           """
           These exemptions no longer match any reach in the tree:

           #{Enum.map_join(stale, "\n", fn {rel, module} -> "  #{rel} → #{module}" end)}

           The call was removed or moved. Delete the row — a standing
           exemption readmits the reach it was written to allow.
           """
  end

  test "the shared primitives live in the glue namespace" do
    assert File.exists?(Path.join(root(), "apps/cyfr/lib/cyfr/topics.ex"))
    assert File.exists?(Path.join(root(), "apps/cyfr/lib/cyfr/uuid7.ex"))

    refute File.exists?(Path.join(root(), "apps/cyfr/lib/prism/topics.ex")),
           "Cyfr.Topics moved out of the console namespace; it must not come back"

    refute File.exists?(Path.join(root(), "apps/cyfr/lib/emissary/uuid7.ex")),
           "Cyfr.UUID7 moved out of the transport namespace; it must not come back"
  end

  test "cyfr does not depend on the engine apps at compile time" do
    mix_exs = Cyfr.Test.SourceTree.read(Path.join(root(), "apps/cyfr/mix.exs"))

    refute mix_exs =~ ":opus",
           "cyfr must not declare a dependency on opus — Cyfr.Execution is the seam"

    refute mix_exs =~ ":locus",
           "cyfr must not declare a dependency on locus"
  end
end
