# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Prism.AquaRustConsistencyTest do
  # The agent's virtual tools are defined twice: in Rust, where they are
  # dispatched, and in `Prism.AquaVirtualTools`, where the harness classifies
  # and displays them. Nothing kept the two in step, and they had already
  # drifted — the Rust `http` tool grew a `read` verb the Elixir catalog
  # never learned about, so `kind_for/2` returned nil for it and it would
  # have had no plane either.
  use ExUnit.Case, async: true

  alias Prism.AquaVirtualTools

  @aqua_glob Path.join([
               __DIR__,
               "../../../../components/local/default/formulas/local/aqua/*/src/src/tools.rs"
             ])

  # Host-side only: the Rust side declares it, but its verbs are handled by
  # the harness rather than dispatched as a tool.
  @host_side_tools ~w(request_setup)

  defp newest_tools_rs do
    @aqua_glob
    |> Path.wildcard()
    |> Enum.sort_by(fn path ->
      path |> Path.split() |> Enum.at(-4) |> String.split(".") |> Enum.map(&String.to_integer/1)
    end)
    |> List.last()
  end

  # Extract `"name": "x"` … `"action": {… "enum": [...]}` pairs from the
  # virtual-tool definitions.
  defp rust_actions(source) do
    ~r/"name":\s*"(?<tool>[a-z_]+)".*?"enum":\s*\[(?<enum>[^\]]*)\]/s
    |> Regex.scan(source, capture: :all_names)
    |> Map.new(fn [enum, tool] ->
      {tool, ~r/"([a-z_]+)"/ |> Regex.scan(enum) |> Enum.map(&List.last/1) |> Enum.sort()}
    end)
  end

  test "the Elixir catalog matches the Rust dispatch surface" do
    path = newest_tools_rs()
    assert path, "no aqua tools.rs found — check the glob"

    rust = rust_actions(File.read!(path))

    for {tool, %{actions: actions}} <- AquaVirtualTools.catalog(),
        tool not in @host_side_tools do
      rust_verbs = Map.get(rust, tool)

      assert rust_verbs,
             "#{tool} is in the Elixir catalog but not in #{Path.relative_to_cwd(path)}"

      assert Enum.sort(Map.keys(actions)) == rust_verbs,
             "#{tool} drifted: elixir=#{inspect(Enum.sort(Map.keys(actions)))} " <>
               "rust=#{inspect(rust_verbs)} (#{Path.relative_to_cwd(path)})"
    end
  end

  test "the http read verb the drift hid is present" do
    # Pinned specifically: this is the verb that was missing, and losing it
    # again would silently un-classify the agent's most-used read path.
    assert AquaVirtualTools.kind_for("http", "read") == :read
    assert "http.read" in AquaVirtualTools.action_pairs()
  end
end
