# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Prima.ManifestCapsTest do
  @moduledoc """
  The `caps` block's storage paths are spelled as the storage door reaches
  them (`Prima.ComponentPath.door_path/1`): a path with an empty segment, a
  `.` or `..` segment, or a trailing form other than one `/` is refused at
  every manifest write, so the blob parse, the preview and the door read
  one spelling. `"*"` is the grant grammar's wildcard, not a path. A flow
  names a source class and an exit the manifest declares — an egress
  domain or connect origin as spelled, a declared need, or a tool server —
  and anything else is refused at every write.
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

  describe "a schedule write in the ask" do
    test "is refused at declaration for every type but an agent, by its exact name" do
      for type <- ["catalyst", "reagent", "formula", "tincture", nil],
          tool <- ["schedule.create", "schedule.update"] do
        manifest = asking_tools(type, ["execution.run", tool])

        assert Caps.validate(manifest, &guest_path?/1) ==
                 {:error, {:invalid_caps, {:agent_only_tool, tool}}},
               "#{inspect(type)} named #{tool}"

        assert Manifest.validate(manifest, &guest_path?/1) ==
                 {:error, {:invalid_manifest, [{:invalid_caps, {:agent_only_tool, tool}}]}}

        assert Caps.from_manifest(manifest, &guest_path?/1) == nil
      end
    end

    test "is an agent's to name; the schedule's reads, its removal and a pattern are not refused here" do
      assert :ok =
               Caps.validate(
                 asking_tools("agent", ["schedule.create", "schedule.update"]),
                 &guest_path?/1
               )

      for type <- ["catalyst", "reagent", "formula", "agent"],
          tools <- [["schedule.list"], ["schedule.delete"], ["schedule.*"], ["*"]] do
        assert :ok = Caps.validate(asking_tools(type, tools), &guest_path?/1),
               "#{type} #{inspect(tools)}"
      end
    end

    test "joins the agent-only tools as exact names, and nothing else does" do
      assert Caps.agent_only_tools() ==
               ~w(feed.bind feed.remove layout.edit schedule.create schedule.update)
    end
  end

  describe "a flow in the ask" do
    # A manifest declaring two egress domains, one connect origin and one
    # need, and the flows it names.
    defp flowing(flows, extra \\ %{}) do
      Map.merge(
        %{
          "type" => "tincture",
          "needs" => %{"api_key" => %{"type" => "api_key:x.com", "reason" => "r"}},
          "tincture" => %{"connect" => ["origin.example"]},
          "caps" => %{
            "egress" => %{"domains" => ["api.example.com", "*.cdn.example"]},
            "flows" => flows
          }
        },
        extra
      )
    end

    defp flow(from, to), do: %{"from" => from, "to" => to}

    test "naming a declared domain, a connect origin, a declared need or a server passes" do
      flows = [
        flow("filed", "api.example.com"),
        flow("pinned", "*.cdn.example"),
        flow("outside", "origin.example"),
        flow("vault_disclosed", "need:api_key"),
        flow("files_by_grant", "server:forecasts"),
        flow("pinned", "*.cdn.example")
      ]

      assert :ok = Caps.validate(flowing(flows), &guest_path?/1)
      assert :ok = Manifest.validate(flowing(flows), &guest_path?/1)

      # Read as one set: in class order, then by exit, each flow once.
      assert %{flows: read} = Caps.from_manifest(flowing(flows), &guest_path?/1)

      assert read == [
               %{from: :pinned, to: "*.cdn.example"},
               %{from: :filed, to: "api.example.com"},
               %{from: :files_by_grant, to: "server:forecasts"},
               %{from: :vault_disclosed, to: "need:api_key"},
               %{from: :outside, to: "origin.example"}
             ]

      # The same flows in another order and repeated are the same ask.
      assert Caps.from_manifest(flowing(Enum.reverse(flows) ++ flows), &guest_path?/1) ==
               Caps.from_manifest(flowing(flows), &guest_path?/1)
    end

    test "naming an exit the manifest does not declare is refused at every write" do
      for to <- [
            "other.example",
            "sub.api.example.com",
            "x.cdn.example",
            "https://api.example.com",
            "need:other",
            "origin.example.org"
          ] do
        manifest = flowing([flow("filed", to)])

        assert {:error, {:invalid_caps, {:undeclared_flow_exit, ^to}}} =
                 Caps.validate(manifest, &guest_path?/1),
               to

        assert {:error, {:invalid_manifest, [{:invalid_caps, {:undeclared_flow_exit, ^to}}]}} =
                 Manifest.validate(manifest, &guest_path?/1)

        assert Caps.from_manifest(manifest, &guest_path?/1) == nil
      end

      # A connect entry that is no origin declares no exit, and a manifest
      # with no tincture block declares none at all.
      bad_origin = flowing([flow("filed", "a b")], %{"tincture" => %{"connect" => ["a b"]}})

      assert {:error, {:invalid_caps, {:undeclared_flow_exit, "a b"}}} =
               Caps.validate(bad_origin, &guest_path?/1)

      no_frame = Map.delete(flowing([flow("filed", "origin.example")]), "tincture")

      assert {:error, {:invalid_caps, {:undeclared_flow_exit, "origin.example"}}} =
               Caps.validate(no_frame, &guest_path?/1)
    end

    test "an unknown or unsettled class, a malformed entry or exit, or another key is refused" do
      for {flows, reason} <- [
            {[flow("unsettled", "api.example.com")], {:unknown_flow_class, "unsettled"}},
            {[flow("secret", "api.example.com")], {:unknown_flow_class, "secret"}},
            {[flow(nil, "api.example.com")], {:unknown_flow_class, nil}},
            {[flow("filed", "server:")], {:malformed_flow_exit, "server:"}},
            {[flow("filed", "need:")], {:malformed_flow_exit, "need:"}},
            {[flow("filed", "")], {:malformed_flow_exit, ""}},
            {[flow("filed", nil)], {:malformed_flow_exit, nil}},
            {[Map.put(flow("filed", "api.example.com"), "via", "x")],
             {:unknown_flow_keys, ["via"]}},
            {["filed>api.example.com"], {:flow_not_an_object, "filed>api.example.com"}},
            {%{"from" => "filed"}, {:flows_not_a_list, %{"from" => "filed"}}}
          ] do
        assert {:error, {:invalid_caps, ^reason}} =
                 Caps.validate(flowing(flows), &guest_path?/1),
               inspect(flows)
      end
    end

    test "a manifest that declares none asks none" do
      assert %{flows: []} = Caps.from_manifest(%{"caps" => %{}}, &guest_path?/1)
      assert %{flows: []} = Caps.empty()
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
