# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AquaToolEditsTest do
  @moduledoc """
  The `aqua` tool's edits meet under the lock: a per-key patch keeps a
  concurrent member's toggle, a prompt save names the version it edited,
  and a new role is one the soul may clone into from the same act.
  """
  use ExUnit.Case, async: false

  alias Aqua.AgentConfig
  alias Compendium.AquaAgent
  alias Compendium.AquaPath

  setup do
    test_path = Path.join(System.tmp_dir!(), "aqua_tool_edits_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:cyfr, :base_path)
    Application.put_env(:cyfr, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:cyfr, :base_path, original),
        else: Application.delete_env(:cyfr, :base_path)
    end)

    # The tool's door logs to the database; the runner it may reach does too.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Arca.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Arca.Repo, {:shared, self()})

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{"cloneable" => true}} = call(ctx, %{"action" => "create", "name" => "scout"})
    %{ctx: ctx}
  end

  defp call(ctx, args), do: AgentConfig.call_aqua(ctx, args)

  defp policy(ctx, name) do
    {:ok, %{"tool_policy" => policy}} = call(ctx, %{"action" => "get", "name" => name})
    policy
  end

  test "a new role is one the soul may clone into, from the same act", %{ctx: ctx} do
    assert policy(ctx, AquaPath.soul_name())[AquaAgent.clone_glob("scout")] == "auto"
  end

  # The derived index follows every write to the tree: a created role has a
  # row with its two digests, an edit moves them, a delete removes the row.
  test "the agent index follows the tree", %{ctx: ctx} do
    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    assert %{kind: "role", disabled: false} = scout = Enum.find(rows, &(&1.name == "scout"))
    assert String.starts_with?(scout.revision_digest, "sha256:")
    assert scout.capability_digest =~ "sha256:"

    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "tool_policy_patch" => %{"files.read" => "auto"}
             })

    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    edited = Enum.find(rows, &(&1.name == "scout"))
    refute edited.revision_digest == scout.revision_digest
    refute edited.capability_digest == scout.capability_digest

    assert {:ok, _} = call(ctx, %{"action" => "delete", "name" => "scout"})
    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    refute Enum.any?(rows, &(&1.name == "scout"))
  end

  # A reset reverts the tree to what ships, and the index follows: a role a
  # member created does not outlive its file as a row.
  test "the agent index follows a reset", %{ctx: ctx} do
    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    assert Enum.any?(rows, &(&1.name == "scout"))

    assert {:ok, %{"reset" => true}} = call(ctx, %{"action" => "reset", "all" => true})

    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    refute Enum.any?(rows, &(&1.name == "scout"))
    assert Enum.any?(rows, &(&1.name == AquaPath.soul_name()))
  end

  test "two members toggling different keys keep both", %{ctx: ctx} do
    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "tool_policy_patch" => %{"files.read" => "auto"}
             })

    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "tool_policy_patch" => %{"http.get" => "auto"}
             })

    assert policy(ctx, "scout") == %{"files.read" => "auto", "http.get" => "auto"}

    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "tool_policy_patch" => %{"files.read" => nil}
             })

    assert policy(ctx, "scout") == %{"http.get" => "auto"}
  end

  test "a patch is judged as the whole it makes", %{ctx: ctx} do
    # The kind ceiling and the no-ask-on-a-role rule hold for a patched
    # key exactly as for a replaced map.
    assert {:error, {:invalid_argument, _}} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "tool_policy_patch" => %{"files.delete" => "auto"}
             })

    assert {:error, {:invalid_argument, _}} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "tool_policy_patch" => %{"files.read" => "ask"}
             })

    assert {:error, {:invalid_argument, _}} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "tool_policy_patch" => %{"files.read" => "maybe"}
             })

    assert {:error, {:invalid_argument, _}} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "tool_policy" => %{},
               "tool_policy_patch" => %{"files.read" => "auto"}
             })

    assert policy(ctx, "scout") == %{}
  end

  test "a prompt save names the version it edited and is refused over a newer one", %{ctx: ctx} do
    {:ok, %{"content_digest" => digest}} = call(ctx, %{"action" => "get", "name" => "scout"})
    assert digest == Compendium.MCP.AquaTool.content_digest("")

    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "content" => "# Scout\n\nLook first.",
               "expected_digest" => digest
             })

    assert {:error, {:conflict, message}} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "content" => "# Scout\n\nA stale draft.",
               "expected_digest" => digest
             })

    assert message =~ "changed since"
    {:ok, %{"content" => content}} = call(ctx, %{"action" => "get", "name" => "scout"})
    assert content =~ "Look first."
  end

  @tag :capture_log
  test "a role whose commit could not finish serving is published, and the index names it", %{
    ctx: ctx
  } do
    alias Arca.PublicationContract.Faults

    previous = Application.get_env(:cyfr, :storage_adapter)
    Faults.wrap(Arca.Adapters.Local)
    Application.put_env(:cyfr, :storage_adapter, Faults)

    on_exit(fn ->
      Faults.unwrap()

      if previous,
        do: Application.put_env(:cyfr, :storage_adapter, previous),
        else: Application.delete_env(:cyfr, :storage_adapter)
    end)

    role = AquaPath.role_file("tracker")

    # The commit lands its row and then cannot write the role where
    # readers read: the unit is published, its bytes are not all served,
    # and the storage sweep's repair finishes the move.
    Faults.inject(fn op, path ->
      if op == :put and path == role, do: {:error, :enospc}, else: :pass
    end)

    assert {:error, {:finish_failed, :enospc}} =
             call(ctx, %{"action" => "create", "name" => "tracker"})

    Faults.clear()

    {root, key} = Arca.Storage.UnitLocator.unit_key(role)
    actor = Sanctum.Context.actor(ctx)
    assert {:ok, %{state: "committed"}} = Arca.StorageUnits.current(actor, root, key)
    assert {:ok, [_one_commit]} = Arca.StorageUnits.journal(actor, root, key)

    # The refusal is the vocabulary's, not a flattened storage failure,
    # and it says the unit is published.
    assert Cyfr.Ops.Error.reason?({:finish_failed, :enospc})
    assert Cyfr.Ops.Error.message({:finish_failed, :enospc}) =~ "published"

    # The resync ran rather than being skipped with the refusal: it reads
    # the served tree, which does not hold the role's bytes yet, so it
    # keeps what is served and names nothing more.
    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    assert Enum.any?(rows, &(&1.name == "scout"))
    refute Enum.any?(rows, &(&1.name == "tracker"))
    refute Arca.exists?(ctx, role)

    # The move is what was left: once it finishes, the published role is
    # served and the next sync names it.
    assert {:ok, :repaired} = Arca.Overlay.repair_unit(ctx, role)
    assert Arca.exists?(ctx, role)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    assert Enum.any?(rows, &(&1.name == "tracker"))
  end
end
