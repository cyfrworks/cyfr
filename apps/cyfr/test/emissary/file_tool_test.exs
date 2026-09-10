# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.MCP.FileToolTest do
  @moduledoc """
  The `file` tool is `Cyfr.Files` on the wire: the same folders, the same
  refusals, reads behind `storage_read` and changes behind
  `storage_write`, external-plane only.
  """

  use ExUnit.Case, async: false

  alias Cyfr.Ops.Catalog
  alias Emissary.MCP.FileTool, as: Tool

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "file_tool_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, base)

    on_exit(fn ->
      Application.put_env(:cyfr, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "the annotations: reads behind storage_read, changes behind storage_write, no chain" do
    actions = Tool.definition().annotations.actions

    assert actions["list"] == %{kind: :read, planes: [:external], permission: :storage_read}
    assert actions["read"] == %{kind: :read, planes: [:external], permission: :storage_read}
    assert actions["write"] == %{kind: :write, planes: [:external], permission: :storage_write}

    assert actions["delete"] == %{
             kind: :destructive,
             planes: [:external],
             permission: :storage_write
           }

    assert :ok = Catalog.audit_action_kinds([Tool])
    assert "file" in Enum.map(Catalog.list_tools(), & &1["name"])
  end

  test "the catalog serves the tree in the console's words", %{ctx: ctx} do
    assert {:ok, %{entries: folders}} = Catalog.call_external("file", ctx, %{"action" => "list"})
    assert Enum.map(folders, & &1.name) == ~w(data aqua components conversations notes)

    assert {:ok, %{written: "data/hello.txt", size: 5}} =
             Catalog.call_external("file", ctx, %{
               "action" => "write",
               "path" => "data/hello.txt",
               "content" => "hello"
             })

    assert {:ok, %{content: "hello", encoding: "utf8"}} =
             Catalog.call_external("file", ctx, %{"action" => "read", "path" => "data/hello.txt"})

    assert {:ok, %{entries: [%{name: "hello.txt", kind: :file, size: 5}]}} =
             Catalog.call_external("file", ctx, %{"action" => "list", "path" => "data"})

    assert {:ok, %{deleted: "data/hello.txt"}} =
             Catalog.call_external("file", ctx, %{
               "action" => "delete",
               "path" => "data/hello.txt"
             })

    assert {:error, {:not_found, "File", "data/hello.txt"}} =
             Catalog.call_external("file", ctx, %{"action" => "read", "path" => "data/hello.txt"})

    assert {:error, {:not_found, "Folder", "payloads"}} =
             Catalog.call_external("file", ctx, %{"action" => "list", "path" => "payloads"})
  end

  test "a missing argument and an unknown action answer in words", %{ctx: ctx} do
    assert {:error, {:invalid_argument, "Missing required argument: path"}} =
             Tool.handle("file", ctx, %{"action" => "read"})

    assert {:error, {:invalid_argument, "write needs path and content"}} =
             Tool.handle("file", ctx, %{"action" => "write", "path" => "data/x"})

    assert {:error, {:unknown_action, "file.move"}} =
             Tool.handle("file", ctx, %{"action" => "move"})

    assert {:error, :action_missing} = Tool.handle("file", ctx, %{})
  end

  test "a key with storage_read reads and cannot write", %{ctx: ctx} do
    reader = %{
      ctx
      | auth_method: :api_key,
        api_key_type: :application,
        permissions: MapSet.new([:storage_read])
    }

    assert {:ok, %{entries: _}} = Catalog.call_external("file", reader, %{"action" => "list"})

    assert {:error, _refused} =
             Catalog.call_external("file", reader, %{
               "action" => "write",
               "path" => "data/x.txt",
               "content" => "x"
             })

    refute Arca.exists?(ctx, ["guest", "x.txt"])
  end
end
