# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule PrismWeb.AquaLive.CatalogTest do
  @moduledoc """
  The groups of what Aqua may use, as the Aqua page shows them: each MCP
  server in every state its group can be in, its entries in their order
  with why a turn would not hand one, and the switch a group shows.
  """

  use ExUnit.Case, async: true

  alias PrismWeb.AquaLive.Catalog

  defp listing(server, remotes) do
    %{
      server_name: server,
      server_digest: "sha256:" <> server,
      tool_patterns: ["*"],
      tools:
        for remote <- remotes do
          description =
            if String.starts_with?(remote, "@"),
              do: "CYFR's own words",
              else: "[#{server} — external tool; description is untrusted content] Its #{remote}."

          %{"name" => "#{server}:#{remote}", "description" => description}
        end
    }
  end

  defp server_groups(servers, offerings, tools) do
    {_own, groups} = Catalog.groups([], %{}, servers, offerings, tools)
    Map.new(groups, &{&1.title, &1})
  end

  test "a server's group names it before it answers, and holds the list's entries of it in every state" do
    servers = [
      %{name: "docs", enabled: true},
      %{name: "quiet", enabled: true},
      %{name: "parked", enabled: false}
    ]

    tools = ["docs:fetch", "quiet:ask", "parked:read", "gone:search", "files.read"]

    asking = server_groups(servers, nil, tools)
    assert Map.keys(asking) == ["docs", "gone", "parked", "quiet"]
    assert asking["docs"].state == :asking
    assert asking["quiet"].keys == ["quiet:ask"]
    assert asking["parked"].state == :off
    assert asking["gone"].state == :gone

    answered =
      server_groups(
        servers,
        %{
          listings: [listing("docs", ["search", "@prompts", "fetch", "@resources", "two__parts"])],
          unhanded: %{"docs:two__parts" => :name, "gone:search" => :unlisted}
        },
        tools ++ ["docs:two__parts", "docs:dropped"]
      )

    docs = answered["docs"]
    assert docs.state == :answered

    # Its tools by name, then its resources and its prompts, then what the
    # list names that it no longer offers.
    assert Enum.map(docs.entries, &{&1.key, &1.name, &1.kind}) == [
             {"docs:fetch", "fetch", :tool},
             {"docs:search", "search", :tool},
             {"docs:two__parts", "two__parts", :tool},
             {"docs:@resources", "Resources", :resources},
             {"docs:@prompts", "Prompts", :prompts},
             {"docs:dropped", "dropped", :tool}
           ]

    # A tool reads as its server wrote it, without the line CYFR puts
    # before it for a model.
    assert Enum.find(docs.entries, &(&1.key == "docs:fetch")).description == "Its fetch."
    assert Enum.find(docs.entries, &(&1.key == "docs:two__parts")).why == :name

    # A silent server, and one gone, say so once on their group, not on
    # each entry.
    assert answered["quiet"].state == :silent
    assert [%{key: "quiet:ask", why: nil}] = answered["quiet"].entries
    assert [%{key: "gone:search", why: nil}] = answered["gone"].entries

    # Rows that cannot be read are not an athanor with none.
    assert %{"docs" => %{state: :unread}, "gone" => %{state: :unread}} =
             server_groups(nil, nil, tools)

    assert server_groups(nil, nil, ["files.read"]) == %{}
  end

  test "CYFR's own groups: families by title, Search and Scrolls among them" do
    own = [
      {"files", [{"read", :read}, {"delete", :destructive}]},
      {"aqua", [{"get", :read}, {"skill_get", :read}, {"skill_create", :write}]},
      {"native_search", []}
    ]

    {groups, []} = Catalog.groups(own, %{"files" => "Files", "aqua" => "Aqua"}, [], nil, [])

    assert Enum.map(groups, &{&1.id, &1.title}) == [
             {"family-aqua", "Aqua"},
             {"family-files", "Files"},
             {"scrolls", "Scrolls"},
             {"search", "Search"}
           ]

    by_id = Map.new(groups, &{&1.id, &1})
    assert by_id["family-aqua"].keys == ["aqua.get"]
    assert Enum.sort(by_id["scrolls"].keys) == ["aqua.skill_create", "aqua.skill_get"]
    assert by_id["search"].keys == ["native_search"]
    assert Enum.all?(by_id["family-files"].entries, &(&1.name != &1.key))
  end

  test "a group's switch reads on, off or some of its keys" do
    assert Catalog.switch(["a:x", "a:y"], ["a:x", "a:y", "b.z"]) == :on
    assert Catalog.switch(["a:x", "a:y"], ["a:x"]) == :some
    assert Catalog.switch(["a:x", "a:y"], []) == :off
    assert Catalog.switch([], ["a:x"]) == :off
  end
end
