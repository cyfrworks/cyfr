# SPDX-License-Identifier: FSL-1.1-Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Sanctum.Tenancy.AthanorsPurgeTest do
  @moduledoc """
  Purging is the one verb that reclaims an athanor's storage tree, and it
  works only on an archived athanor: archive leaves the tree in place so
  unarchive reopens the furnace intact, purge is the deliberate final act.
  Blobs only — the rows survive.
  """
  use ExUnit.Case, async: false

  alias Sanctum.Context
  alias Sanctum.Tenancy.{Athanors, Users}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    test_path = Path.join(System.tmp_dir!(), "purge_#{:rand.uniform(1_000_000)}")
    prev = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if prev,
        do: Application.put_env(:cyfr, :base_path, prev),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    n = System.unique_integer([:positive])

    {:ok, user} =
      Users.upsert_from_provider(%{
        id: "github|https://github.com|purge-#{n}",
        provider: "github",
        email: "purge#{n}@example.com",
        verified: true
      })

    {:ok, group} = Athanors.create_group(user.id, "Purge #{n}")

    ctx =
      Context.build(
        user_id: user.id,
        athanor_id: group.id,
        permissions: [:*],
        scope: :athanor,
        auth_method: :oidc,
        authenticated: true
      )

    :ok = Arca.put(ctx, ["guest", "notes.txt"], "kept until purge")
    :ok = Arca.put(ctx, ["aqua", "agent.json"], "{}")

    {:ok, group: group, ctx: ctx}
  end

  test "refused while the athanor is active — archive first", %{group: group, ctx: ctx} do
    assert {:error, :not_archived} = Athanors.purge_storage(group)
    assert Arca.exists?(ctx, ["guest", "notes.txt"])
  end

  test "purge drops the per-scope usage counters, not just the whole-tree total", %{
    group: group,
    ctx: ctx
  } do
    # Warm the per-scope pair the public quota reads.
    assert {:ok, %{files: files}} = Arca.Usage.scope_usage(ctx, "guest")
    assert files >= 1

    {:ok, archived} = Athanors.archive(group)
    assert :ok = Athanors.purge_storage(archived)

    # The purge path is `delete_tree(ctx, [])`, whose empty path names no
    # scope — without the explicit invalidate, the cached pair would keep
    # answering the old counts until its TTL.
    assert {:ok, %{files: 0, bytes: 0}} = Arca.Usage.scope_usage(ctx, "guest")
  end

  test "after archive, the whole blob tree goes and the rows stay", %{group: group, ctx: ctx} do
    assert {:ok, archived} = Athanors.archive(group)
    assert Arca.exists?(ctx, ["guest", "notes.txt"])

    assert :ok = Athanors.purge_storage(archived)

    refute Arca.exists?(ctx, ["guest", "notes.txt"])
    refute Arca.exists?(ctx, ["aqua", "agent.json"])
    assert {:ok, []} = Arca.list_recursive(ctx, [])

    # The row remains — purge deletes blobs, never the record.
    assert {:ok, %{status: "archived"}} = Athanors.get(group.id)
  end
end
