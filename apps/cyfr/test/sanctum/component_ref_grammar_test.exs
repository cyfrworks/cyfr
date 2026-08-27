# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.ComponentRefGrammarTest do
  @moduledoc """
  A component reference is `type:namespace.name`, optionally `:version`.
  That grammar had twelve authors: every caller holding the three parts
  glued them together itself, so the separator characters lived in twelve
  files and a change to them would have needed twelve edits.

  `Sanctum.ComponentRef.build/4` is the one author now. This test keeps it
  that way, and pins the grammar it produces.
  """

  use ExUnit.Case, async: true

  alias Sanctum.ComponentRef

  # The shape a hand-spelled ref takes: a literal type prefix, a colon, an
  # interpolation, a dot, an interpolation. Anything matching this is a
  # second author of the grammar.
  @hand_spelled ~r/"[a-z_]*:#\{[^}]+\}\.#\{/

  @searched ~w(apps/cyfr/lib apps/opus/lib apps/locus/lib)

  defp root, do: Path.expand("../../../..", __DIR__)

  test "build/4 produces the canonical grammar" do
    assert ComponentRef.build("tincture", "acme", "docs") == "tincture:acme.docs"
    assert ComponentRef.build("reagent", "local", "fetch", "1.2.0") == "reagent:local.fetch:1.2.0"
    assert ComponentRef.build("catalyst", "local", "run", nil) == "catalyst:local.run"
  end

  test "what build/4 makes, parse/1 reads back" do
    for {type, ns, name, version} <- [
          {"tincture", "acme", "docs", nil},
          {"reagent", "local", "fetch", "1.2.0"},
          {"formula", "ns-with-dash", "n", "0.0.1-rc1"}
        ] do
      ref = ComponentRef.build(type, ns, name, version)

      assert {:ok, parsed} = ComponentRef.parse(ref)
      assert parsed.type == type
      assert parsed.namespace == ns
      assert parsed.name == name
      assert parsed.version == version
    end
  end

  test "nothing else spells the grammar" do
    offenders =
      @searched
      |> Enum.flat_map(&Path.wildcard(Path.join([root(), &1, "**/*.ex"])))
      |> Enum.reject(&String.ends_with?(&1, "component_ref.ex"))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.reject(fn {line, _n} -> String.match?(line, ~r/^\s*#/) end)
        |> Enum.filter(fn {line, _n} -> String.match?(line, @hand_spelled) end)
        |> Enum.map(fn {line, n} ->
          "#{Path.relative_to(path, root())}:#{n}: #{String.trim(line)}"
        end)
      end)

    assert offenders == [],
           """
           These build a component reference by hand:

           #{Enum.map_join(offenders, "\n", &"  #{&1}")}

           Use `Sanctum.ComponentRef.build/4` so the one place that knows a
           ref is `type:namespace.name` stays one place.
           """
  end
end
