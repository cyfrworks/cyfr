defmodule Prism.AquaVirtualToolsTest do
  use ExUnit.Case, async: true

  alias Prism.AquaVirtualTools

  describe "catalog/0" do
    test "exposes the four expected virtual tools" do
      catalog = AquaVirtualTools.catalog()

      assert Map.keys(catalog) |> Enum.sort() ==
               ["files", "http", "request_setup", "storage"]
    end

    test "every action declares a kind from the canonical set" do
      for {tool, %{actions: actions}} <- AquaVirtualTools.catalog(),
          {action, %{kind: kind}} <- actions do
        assert kind in [:read, :write, :execute, :destructive, :external],
               "#{tool}.#{action} has unexpected kind #{inspect(kind)}"
      end
    end

    test "files tool has the expected verbs" do
      %{actions: actions} = AquaVirtualTools.catalog()["files"]
      keys = actions |> Map.keys() |> Enum.sort()
      assert keys == ~w(delete edit grep list read search tree write)
    end

    test "storage tool aligns with formula API (read/write/list/delete)" do
      %{actions: actions} = AquaVirtualTools.catalog()["storage"]
      keys = actions |> Map.keys() |> Enum.sort()
      assert keys == ~w(delete list read write)
    end

    test "http tool covers the seven HTTP method verbs" do
      %{actions: actions} = AquaVirtualTools.catalog()["http"]
      keys = actions |> Map.keys() |> Enum.sort()
      assert keys == ~w(delete get head options patch post put)
    end
  end

  describe "kind_for/2" do
    test "looks up known virtual actions" do
      assert AquaVirtualTools.kind_for("files", "read") == :read
      assert AquaVirtualTools.kind_for("files", "write") == :write
      assert AquaVirtualTools.kind_for("files", "delete") == :destructive
      assert AquaVirtualTools.kind_for("storage", "read") == :read
      assert AquaVirtualTools.kind_for("http", "post") == :execute
      assert AquaVirtualTools.kind_for("http", "delete") == :destructive
    end

    test "returns nil for unknown tool/action" do
      assert AquaVirtualTools.kind_for("nope", "read") == nil
      assert AquaVirtualTools.kind_for("files", "purge") == nil
    end
  end

  describe "list_for_panel/0" do
    test "returns sorted [{tool, [{action, kind}]}] tuples" do
      panel = AquaVirtualTools.list_for_panel()

      tools = Enum.map(panel, &elem(&1, 0))
      assert tools == Enum.sort(tools)

      Enum.each(panel, fn {_tool, actions} ->
        action_names = Enum.map(actions, &elem(&1, 0))
        assert action_names == Enum.sort(action_names)
      end)
    end
  end

  describe "virtual_tool?/1" do
    test "true for managed virtual tools" do
      assert AquaVirtualTools.virtual_tool?("files")
      assert AquaVirtualTools.virtual_tool?("storage")
      assert AquaVirtualTools.virtual_tool?("http")
      assert AquaVirtualTools.virtual_tool?("request_setup")
    end

    test "false for MCP tool names and unknowns" do
      refute AquaVirtualTools.virtual_tool?("secret")
      refute AquaVirtualTools.virtual_tool?("mcp_servers")
      refute AquaVirtualTools.virtual_tool?(nil)
      refute AquaVirtualTools.virtual_tool?(123)
    end
  end
end
