# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.
defmodule Prism.AquaRustConsistencyTest do
  # Keep Rust virtual-tool dispatch aligned with Aqua.Hands
  # classification and display metadata.
  use ExUnit.Case, async: true

  alias Aqua.Hands

  @aqua_glob Path.join([
               __DIR__,
               "../../../../seed/components/formulas/local/aqua/*/src/src/tools.rs"
             ])

  # Every virtual tool is compared, `request_setup` included: its one verb
  # is handled by the harness rather than dispatched, but the guest still
  # declares it, so the two sides must agree on it like any other.
  @host_side_tools ~w()

  defp newest_tools_rs do
    @aqua_glob
    |> Path.wildcard()
    |> Enum.sort_by(fn path ->
      path |> Path.split() |> Enum.at(-4) |> String.split(".") |> Enum.map(&String.to_integer/1)
    end)
    |> List.last()
  end

  # Extract each virtual tool's name and its `action` enum from the
  # definitions the model is shown. The names are constants (`"name":
  # FILES_TOOL`), resolved first; the guest's own unit tests hold that
  # enum to the set its one dispatch table accepts, so the schema IS the
  # dispatch surface and this comparison is the whole contract.
  defp rust_actions(source) do
    consts =
      ~r/const\s+(?<ident>[A-Z_]+):\s*&str\s*=\s*"(?<value>[a-z_]+)";/
      |> Regex.scan(source, capture: :all_names)
      |> Map.new(fn [ident, value] -> {ident, value} end)

    ~r/"name":\s*(?:"(?<literal>[a-z_]+)"|(?<const>[A-Z_]+)).*?"enum":\s*\[(?<enum>[^\]]*)\]/s
    |> Regex.scan(source, capture: :all_names)
    |> Map.new(fn [const, enum, literal] ->
      tool = if literal == "", do: Map.fetch!(consts, const), else: literal
      {tool, ~r/"([a-z_]+)"/ |> Regex.scan(enum) |> Enum.map(&List.last/1) |> Enum.sort()}
    end)
  end

  test "the Elixir catalog matches the Rust dispatch surface" do
    path = newest_tools_rs()
    assert path, "no aqua tools.rs found — check the glob"

    rust = rust_actions(File.read!(path))

    for {tool, %{actions: actions}} <- Hands.catalog(),
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
    assert Hands.kind_for("http", "read") == :read
    assert "http.read" in Hands.action_pairs()
  end
end
