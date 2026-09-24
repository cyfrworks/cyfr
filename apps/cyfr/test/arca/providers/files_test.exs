# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Arca.Providers.FilesTest do
  @moduledoc """
  The `file` tool is `Arca.Files` on the wire: the same folders, the same
  refusals, reads behind `storage_read` and changes behind
  `storage_write`, external-plane only, and a handler given the caller's
  actor alone.
  """

  use ExUnit.Case, async: false

  alias Grimoire.Catalog
  alias Arca.Providers.Files, as: Tool

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    base = Path.join(System.tmp_dir!(), "file_tool_#{System.unique_integer([:positive])}")
    prev_base = Application.fetch_env!(:arca, :base_path)
    Application.put_env(:arca, :base_path, base)

    on_exit(fn ->
      Application.put_env(:arca, :base_path, prev_base)
      File.rm_rf!(base)
    end)

    {:ok, ctx: Sanctum.TestContext.local()}
  end

  test "the annotations: reads behind storage_read, changes behind storage_write, no chain" do
    actions = Tool.definition().annotations.actions

    assert actions["list"] == %{
             kind: :read,
             planes: [:external],
             permission: :storage_read,
             auth: :required
           }

    assert actions["read"] == %{
             kind: :read,
             planes: [:external],
             permission: :storage_read,
             auth: :required
           }

    assert actions["write"] == %{
             kind: :write,
             planes: [:external],
             permission: :storage_write,
             auth: :required
           }

    assert actions["delete"] == %{
             kind: :destructive,
             auth: :required,
             planes: [:external],
             permission: :storage_write
           }

    assert :ok = Catalog.audit_action_kinds([Tool])
    assert "file" in Enum.map(Grimoire.list_tools(), & &1["name"])
  end

  test "the catalog serves the tree in the console's words", %{ctx: ctx} do
    assert {:ok, %{entries: folders}} = Grimoire.call_external("file", ctx, %{"action" => "list"})
    assert Enum.map(folders, & &1.name) == ~w(data aqua components threads notes)

    assert {:ok, %{written: "data/hello.txt", size: 5}} =
             Grimoire.call_external("file", ctx, %{
               "action" => "write",
               "path" => "data/hello.txt",
               "content" => "hello"
             })

    assert {:ok, %{content: "hello", encoding: "utf8"}} =
             Grimoire.call_external("file", ctx, %{"action" => "read", "path" => "data/hello.txt"})

    assert {:ok, %{entries: [%{name: "hello.txt", kind: :file, size: 5}]}} =
             Grimoire.call_external("file", ctx, %{"action" => "list", "path" => "data"})

    assert {:ok, %{deleted: "data/hello.txt"}} =
             Grimoire.call_external("file", ctx, %{
               "action" => "delete",
               "path" => "data/hello.txt"
             })

    assert {:error, {:not_found, "File", "data/hello.txt"}} =
             Grimoire.call_external("file", ctx, %{"action" => "read", "path" => "data/hello.txt"})

    assert {:error, {:not_found, "Folder", "payloads"}} =
             Grimoire.call_external("file", ctx, %{"action" => "list", "path" => "payloads"})
  end

  test "a missing argument and an unknown action answer in words", %{ctx: ctx} do
    actor = Sanctum.Context.actor(ctx)

    assert {:error, {:invalid_argument, "Missing required argument: path"}} =
             Tool.handle("file", actor, %{"action" => "read"})

    assert {:error, {:invalid_argument, "write needs path and content"}} =
             Tool.handle("file", actor, %{"action" => "write", "path" => "data/x"})

    assert {:error, {:unknown_action, "file.move"}} =
             Tool.handle("file", actor, %{"action" => "move"})

    assert {:error, :action_missing} = Tool.handle("file", actor, %{})
  end

  test "the handler is declared for the actor, and a context is not one", %{ctx: ctx} do
    assert Tool.context_kind() == :actor
    assert Prima.Provider.context_kind(Tool) == :actor
    assert Tool.service() == "arca"

    assert_raise FunctionClauseError, fn ->
      Tool.handle("file", ctx, %{"action" => "list"})
    end
  end

  test "an actor with no athanor is refused at the door", %{ctx: ctx} do
    tenantless = %{Sanctum.Context.actor(ctx) | athanor_id: nil}
    assert {:error, :missing_tenant} = Tool.handle("file", tenantless, %{"action" => "list"})

    assert {:error, :missing_tenant} =
             Tool.handle("file", tenantless, %{"action" => "read", "path" => "data/x"})
  end

  test "a key with storage_read reads and cannot write", %{ctx: ctx} do
    reader = %{
      ctx
      | auth_method: :api_key,
        api_key_type: :application,
        permissions: MapSet.new([:storage_read])
    }

    assert {:ok, %{entries: _}} = Grimoire.call_external("file", reader, %{"action" => "list"})

    assert {:error, _refused} =
             Grimoire.call_external("file", reader, %{
               "action" => "write",
               "path" => "data/x.txt",
               "content" => "x"
             })

    refute Arca.exists?(Sanctum.Context.actor(ctx), ["data", "x.txt"])
  end
end
