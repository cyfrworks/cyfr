# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ManifestCapsTest do
  @moduledoc """
  The `caps` block's storage paths are spelled as the storage door reaches
  them (`Prima.ComponentPath.door_path/1`): a path with an empty segment, a
  `.` or `..` segment, or a trailing form other than one `/` is refused at
  every manifest write, so the blob parse, the preview and the door read
  one spelling. `"*"` is the grant grammar's wildcard, not a path.
  """

  use ExUnit.Case, async: true

  alias Prima.Manifest
  alias Prima.Manifest.Caps

  doctest Prima.Manifest.Caps

  # A guest scope, as the storage boundary's predicate reads one.
  defp guest_path?(path), do: path == "data" or String.starts_with?(path, "data/")

  defp asking(paths),
    do: %{"caps" => %{"storage" => %{"paths" => paths, "actions" => ["read"]}}}

  describe "a storage path in the ask" do
    test "spelled as the door reaches it, a file, a folder, a bare scope or the wildcard, passes" do
      for paths <- [["data/secrets/"], ["data/report.md"], ["data"], ["*"], ["data/a/b/c.txt"]] do
        assert :ok = Caps.validate(asking(paths), &guest_path?/1), inspect(paths)
        assert :ok = Manifest.validate(asking(paths), &guest_path?/1)
      end
    end

    test "with an empty segment, a dot segment or a doubled trailing slash, is refused at publish" do
      for path <- [
            "data//secrets/",
            "data/./secrets/",
            "data/../secrets/",
            "data/notes//",
            "data/notes/.",
            "data/./"
          ] do
        assert {:error, {:invalid_caps, {:non_canonical_storage_path, ^path}}} =
                 Caps.validate(asking(["data/ok/", path]), &guest_path?/1),
               "#{path} was admitted"

        # The write boundaries refuse it as one manifest failure.
        assert {:error,
                {:invalid_manifest, [{:invalid_caps, {:non_canonical_storage_path, ^path}}]}} =
                 Manifest.validate(asking([path]), &guest_path?/1)

        # And a stored manifest spelling it reads as no caps block at all,
        # which the consent derivation refuses rather than reads as empty.
        assert Caps.from_manifest(asking([path]), &guest_path?/1) == nil
      end
    end

    test "outside every guest scope is the predicate's refusal, before the spelling's" do
      assert {:error, {:invalid_caps, {:invalid_storage_path, "aqua//x/"}}} =
               Caps.validate(asking(["aqua//x/"]), &guest_path?/1)
    end
  end

  describe "a list member that is no string" do
    test "is a tool pattern refused as itself, wherever it stands" do
      for {tools, bad} <- [
            {[nil], nil},
            {[nil, "a**"], nil},
            {["execution.run", nil], nil},
            {["execution.run", 1], 1}
          ] do
        assert {:error, {:invalid_caps, {:invalid_tool_pattern, ^bad}}} =
                 Caps.validate(%{"caps" => %{"tools" => tools}}, &guest_path?/1),
               inspect(tools)
      end
    end

    test "is a storage path refused, wherever it stands" do
      for paths <- [[nil], [nil, "data/../x"], ["data", nil]] do
        assert {:error,
                {:invalid_caps, {:invalid_string_list, [:caps, :storage, "paths"], ^paths}}} =
                 Caps.validate(asking(paths), &guest_path?/1),
               inspect(paths)
      end
    end
  end

  describe "a need's hosts" do
    defp need_hosting(hosts, egress) do
      manifest = %{
        "needs" => %{
          "api_key" => %{"type" => "api_key:example.com", "reason" => "r", "hosts" => hosts}
        }
      }

      if egress,
        do: Map.put(manifest, "caps", %{"egress" => %{"domains" => egress}}),
        else: manifest
    end

    test "fall within the egress domains the manifest asks" do
      for {hosts, egress} <- [
            {["api.example.com"], ["api.example.com"]},
            {["api.example.com"], ["*.example.com"]},
            {["api.example.com", "b.example.com"], ["*.example.com"]},
            {["*.example.com"], ["*.example.com"]},
            {["*.eu.example.com"], ["*.example.com"]},
            {["*.example.com"], ["*"]},
            {["api.example.com"], ["API.Example.com"]}
          ] do
        assert :ok = Caps.validate(need_hosting(hosts, egress), &guest_path?/1),
               inspect({hosts, egress})
      end
    end

    test "outside them, or with no egress asked, are refused" do
      for {hosts, egress, outside} <- [
            {["api.example.com"], ["other.example.com"], "api.example.com"},
            {["example.com"], ["*.example.com"], "example.com"},
            {["*.example.com"], ["api.example.com"], "*.example.com"},
            {["*.example.com"], ["*.eu.example.com"], "*.example.com"},
            {["api.example.com", "evil.test"], ["*.example.com"], "evil.test"},
            {["api.example.com"], nil, "api.example.com"},
            {["api.example.com"], [], "api.example.com"}
          ] do
        assert {:error, {:invalid_caps, {:need_host_outside_egress, "api_key", ^outside}}} =
                 Caps.validate(need_hosting(hosts, egress), &guest_path?/1),
               inspect({hosts, egress})
      end

      # A stored manifest whose need speaks outside its egress reads as no caps.
      assert Caps.from_manifest(
               need_hosting(["evil.test"], ["api.example.com"]),
               &guest_path?/1
             ) == nil
    end

    test "a need naming no hosts asks nothing of egress" do
      manifest = %{"needs" => %{"api_key" => %{"type" => "api_key:x.com", "reason" => "r"}}}
      assert :ok = Caps.validate(manifest, &guest_path?/1)
    end
  end

  describe "a feed write in the ask" do
    defp asking_tools(type, tools),
      do: %{"type" => type, "caps" => %{"tools" => tools}}

    test "is refused at declaration for every type but an agent, by its exact name" do
      for type <- ["formula", "catalyst", "reagent", "tincture", nil],
          tool <- ["feed.bind", "feed.remove"] do
        manifest = asking_tools(type, ["execution.run", tool])

        assert {:error, {:invalid_caps, {:agent_only_tool, ^tool}}} =
                 Caps.validate(manifest, &guest_path?/1),
               "#{inspect(type)} named #{tool}"

        # The write boundaries refuse it as one manifest failure, and a
        # stored manifest asking it reads as no caps block at all.
        assert {:error, {:invalid_manifest, [{:invalid_caps, {:agent_only_tool, ^tool}}]}} =
                 Manifest.validate(manifest, &guest_path?/1)

        assert Caps.from_manifest(manifest, &guest_path?/1) == nil
      end
    end

    test "is an agent's to name, and a pattern is not refused here" do
      assert :ok =
               Caps.validate(asking_tools("agent", ["feed.bind", "feed.remove"]), &guest_path?/1)

      # A pattern grants neither at expansion, whoever asks; the grammar
      # admits it.
      for type <- ["formula", "agent"], tools <- [["feed.*"], ["*"], ["feed.list"]] do
        assert :ok = Caps.validate(asking_tools(type, tools), &guest_path?/1), inspect(tools)
      end
    end
  end

  describe "the layout's write in the ask" do
    test "is refused at declaration for a catalyst, a reagent, a formula and every other type" do
      for type <- ["catalyst", "reagent", "formula", "tincture", nil] do
        manifest = asking_tools(type, ["execution.run", "layout.edit"])

        assert Caps.validate(manifest, &guest_path?/1) ==
                 {:error, {:invalid_caps, {:agent_only_tool, "layout.edit"}}},
               "#{inspect(type)} named layout.edit"

        assert Manifest.validate(manifest, &guest_path?/1) ==
                 {:error,
                  {:invalid_manifest, [{:invalid_caps, {:agent_only_tool, "layout.edit"}}]}}

        assert Caps.from_manifest(manifest, &guest_path?/1) == nil
      end
    end

    test "is an agent's to name; reading the layout and a pattern are not refused here" do
      assert :ok = Caps.validate(asking_tools("agent", ["layout.edit"]), &guest_path?/1)

      for type <- ["catalyst", "reagent", "formula", "agent"],
          tools <- [["layout.get"], ["layout.*"], ["*"]] do
        assert :ok = Caps.validate(asking_tools(type, tools), &guest_path?/1),
               "#{type} #{inspect(tools)}"
      end
    end
  end

  describe "canonical_storage_path?/1" do
    test "is the door's spelling, and the wildcard" do
      for path <- ["data/notes/", "data/report.md", "data", "*"],
          do: assert(Caps.canonical_storage_path?(path), path)

      for path <- ["data//notes/", "data/../x", "/data/notes/", "data/notes//", "", nil, 7],
          do: refute(Caps.canonical_storage_path?(path), inspect(path))
    end
  end
end
