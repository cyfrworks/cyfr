# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Grimoire.VirtualToolsTest do
  @moduledoc """
  The virtual tools' one declaration: the four families and their
  catalysts, every action's kind, its planes (in-chain only), which reads
  are replay-safe, which action is auto-only, and the kinds that may run
  without a card. A change to the table fails here before it changes what
  the assistant may do.
  """
  use ExUnit.Case, async: true

  alias Grimoire.VirtualTools

  test "the four families, each on its catalyst" do
    assert VirtualTools.tools() == ["files", "http", "request_setup", "storage"]

    assert VirtualTools.catalyst_for("files") == "catalyst:local.files"
    assert VirtualTools.catalyst_for("storage") == "catalyst:local.files"
    assert VirtualTools.catalyst_for("http") == "catalyst:local.http"
    assert VirtualTools.catalyst_for("request_setup") == nil
    assert VirtualTools.catalyst_for("component") == nil
    assert VirtualTools.catalyst_for(nil) == nil

    assert VirtualTools.catalysts() == ["catalyst:local.files", "catalyst:local.http"]

    assert VirtualTools.tool?("files")
    refute VirtualTools.tool?("component")
    refute VirtualTools.tool?(:files)
  end

  test "every action's kind is exact" do
    assert VirtualTools.action_kinds() == [
             {"files",
              [
                {"delete", :destructive},
                {"edit", :write},
                {"grep", :read},
                {"list", :read},
                {"read", :read},
                {"search", :read},
                {"tree", :read},
                {"write", :write}
              ]},
             {"http",
              [
                {"delete", :destructive},
                {"get", :read},
                {"head", :read},
                {"links", :read},
                {"metadata", :read},
                {"options", :read},
                {"patch", :write},
                {"post", :execute},
                {"put", :write},
                {"read", :read}
              ]},
             {"request_setup", [{"open", :write}]},
             {"storage",
              [{"delete", :destructive}, {"list", :read}, {"read", :read}, {"write", :write}]}
           ]

    assert VirtualTools.kind_for("http", "post") == :execute
    assert VirtualTools.kind_for("files", "nope") == nil
    assert VirtualTools.kind_for("component", "read") == nil
    assert VirtualTools.kind_for("files", nil) == nil
  end

  test "every action runs in-chain only; a pair the table lacks has no plane" do
    for tool <- VirtualTools.tools(), action <- VirtualTools.actions_of(tool) do
      assert VirtualTools.planes(tool, action) == [:in_chain]
    end

    assert VirtualTools.planes("files", "nope") == []
    assert VirtualTools.actions_of("component") == []

    assert length(VirtualTools.action_pairs()) == 23
    assert VirtualTools.action_pairs() == Enum.sort(VirtualTools.action_pairs())
    assert "request_setup.open" in VirtualTools.action_pairs()
  end

  test "only the files and storage reads are replay-safe" do
    replay_safe =
      for tool <- VirtualTools.tools(),
          action <- VirtualTools.actions_of(tool),
          VirtualTools.recovery(tool, action) == :replay_safe,
          do: "#{tool}.#{action}"

    assert replay_safe == [
             "files.grep",
             "files.list",
             "files.read",
             "files.search",
             "files.tree",
             "storage.list",
             "storage.read"
           ]

    assert VirtualTools.recovery("http", "get") == nil
    assert VirtualTools.recovery("files", "write") == nil
    assert VirtualTools.recovery("component", "read") == nil
  end

  test "request_setup.open is the one auto-only action" do
    auto_only =
      for tool <- VirtualTools.tools(),
          action <- VirtualTools.actions_of(tool),
          VirtualTools.auto_only?(tool, action),
          do: {tool, action}

    assert auto_only == [{"request_setup", "open"}]
    refute VirtualTools.auto_only?("request_setup", "close")
    refute VirtualTools.auto_only?(nil, nil)
  end

  test "a read, write or execute may run without a card; nothing else may" do
    assert VirtualTools.auto_permitted_kinds() == [:read, :write, :execute]

    for kind <- [:read, :write, :execute], do: assert(VirtualTools.auto_permitted_kind?(kind))

    for kind <- [:destructive, :external, nil, "read"],
        do: refute(VirtualTools.auto_permitted_kind?(kind))
  end

  test "the table carries each family's display fields and its actions" do
    for {tool, family} <- VirtualTools.table() do
      assert is_binary(family.title) and family.title != ""
      assert is_binary(family.description) and family.description != ""
      assert Map.keys(family.actions) |> Enum.sort() == VirtualTools.actions_of(tool)
    end

    assert VirtualTools.action("files", "read") ==
             %{kind: :read, planes: [:in_chain], recovery: :replay_safe}

    assert VirtualTools.action("files", :read) == nil
  end
end
