# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.NamespaceDirectionTest do
  @moduledoc """
  Which way the dependency arrows point between the umbrella's apps.

  `:opus` is the WASM engine and `:locus` the build toolchain; both depend
  on `:cyfr`, and `Cyfr.Execution` is the behaviour that keeps cyfr from
  depending on them back. What that leaves open is *where inside cyfr* they
  reach, and two answers were wrong in a way nothing caught: the engine took
  its PubSub topic names from `Prism`, the LiveView console, and every
  persistence path in the system took its id generator from `Emissary`, the
  MCP and HTTP surface. Neither is a compile-time cycle, so neither broke
  anything — the arrows just pointed at the wrong things, and the "a worker
  on another node would implement this surface" story quietly stopped being
  true.

  The rule this pins is narrow and checkable: an engine does not depend on
  a user interface. `Emissary` is deliberately NOT on the forbidden list —
  opus implements `Emissary.MCP.ToolProvider` and dispatches in-chain tool
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
  # dependency. Scoped to apps/opus and apps/locus only: inside cyfr,
  # Sanctum and Aqua legitimately name it today (the tincture token's
  # asset sibling, the router introspection Aqua.Actions documents).
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
      |> File.read!()
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

  @domain_web_calls [
    # The local fallback for the OAuth redirect origin. `CYFR_PUBLIC_URL` is
    # the configured answer (and the only one carrying a scheme); this is what
    # a dev box with nothing set uses.
    {"apps/cyfr/lib/sanctum/vault/oauth_grant.ex", "EmissaryWeb.Endpoint"},
    # `Aqua.Actions` validates an agent's navigation intents against the
    # console's real route table, so a link it emits cannot 404.
    {"apps/cyfr/lib/aqua/actions.ex", "EmissaryWeb.Router"}
  ]

  # Code only — a moduledoc that NAMES the controller it serves is describing
  # the dependency, not taking one. Same filter the surface tests use.
  defp code_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({[], false}, fn {line, n}, {kept, in_heredoc?} ->
      toggles =
        line
        |> String.graphemes()
        |> Enum.chunk_every(3, 1, :discard)
        |> Enum.count(&(&1 == ["\"", "\"", "\""]))

      now_inside? = if rem(toggles, 2) == 1, do: not in_heredoc?, else: in_heredoc?

      keep? = not in_heredoc? and not now_inside? and not String.match?(line, ~r/^\s*#/)
      {if(keep?, do: [{line, n} | kept], else: kept), now_inside?}
    end)
    |> elem(0)
  end

  test "the domain namespaces reach the web layer only where it is written down" do
    allowed = MapSet.new(@domain_web_calls)

    found =
      for dir <- @domain_dirs,
          path <- Path.wildcard(Path.join(root(), dir <> "/**/*.ex")),
          rel = Path.relative_to(path, root()),
          {line, n} <- path |> File.read!() |> code_lines(),
          [module] <- Regex.scan(~r/\bEmissaryWeb\.[A-Z]\w+/, line, capture: :first),
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

  test "the shared primitives live in the glue namespace" do
    assert File.exists?(Path.join(root(), "apps/cyfr/lib/cyfr/topics.ex"))
    assert File.exists?(Path.join(root(), "apps/cyfr/lib/cyfr/uuid7.ex"))

    refute File.exists?(Path.join(root(), "apps/cyfr/lib/prism/topics.ex")),
           "Cyfr.Topics moved out of the console namespace; it must not come back"

    refute File.exists?(Path.join(root(), "apps/cyfr/lib/emissary/uuid7.ex")),
           "Cyfr.UUID7 moved out of the transport namespace; it must not come back"
  end

  test "cyfr does not depend on the engine apps at compile time" do
    mix_exs = File.read!(Path.join(root(), "apps/cyfr/mix.exs"))

    refute mix_exs =~ ":opus",
           "cyfr must not declare a dependency on opus — Cyfr.Execution is the seam"

    refute mix_exs =~ ":locus",
           "cyfr must not declare a dependency on locus"
  end
end
