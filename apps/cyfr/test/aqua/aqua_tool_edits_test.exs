# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AquaToolEditsTest do
  @moduledoc """
  The `aqua` tool's edits meet under the lock: a per-key patch keeps a
  concurrent member's toggle, a prompt save names the version it edited,
  and a new role is one the soul may clone into from the same act.
  """
  use ExUnit.Case, async: false

  alias Compendium.AquaAgent
  alias Compendium.AquaPath

  setup tags do
    test_path = Path.join(System.tmp_dir!(), "aqua_tool_edits_#{:rand.uniform(1_000_000)}")
    original = Application.get_env(:arca, :base_path)
    Application.put_env(:arca, :base_path, test_path)

    on_exit(fn ->
      File.rm_rf!(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    # The tool's door logs to the database; the runner it may reach does too.
    Cyfr.Test.Sandbox.setup!(tags)

    ctx = Sanctum.TestContext.local()
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{"cloneable" => true}} = call(ctx, %{"action" => "create", "name" => "scout"})
    %{ctx: ctx}
  end

  defp call(ctx, args), do: Cyfr.Test.AquaTool.call(ctx, args)

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

    assert {:error, %Prima.Refusal{stage: :admission, reason: {:invalid_argument, _}}} =
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
    assert digest == Prima.Digest.sha256_hex("")

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
  test "a role whose writer died after its commit is published, and the index names it once the repair releases it",
       %{ctx: ctx} do
    actor = Sanctum.Context.actor(ctx)
    role = AquaPath.role_file("tracker")
    {root, key} = Arca.Storage.UnitLocator.unit_key(role)
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)
    test_pid = self()

    # The writer dies at its commit's announcement: after the pointer
    # moved, before the draft is given back.
    :ok =
      :telemetry.attach(
        handler,
        Arca.StorageProjectionChanges.event(),
        fn _event, _measurements, metadata, _config ->
          if metadata.athanor_id == actor.athanor_id and metadata.root == root and
               not metadata.ready and self() != test_pid and
               match?(
                 {:ok, %{draft_writer_token: token}} when is_binary(token),
                 Arca.StorageUnits.current(actor, root, key)
               ) do
            :telemetry.detach(handler)
            # Outright: an exit raised in a telemetry handler is caught.
            Process.exit(self(), :kill)
          end
        end,
        nil
      )

    {pid, ref} = spawn_monitor(fn -> call(ctx, %{"action" => "create", "name" => "tracker"}) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 30_000

    # Published: the row, the journal, and the role reads already.
    assert {:ok, %{state: "committed"}} = Arca.StorageUnits.current(actor, root, key)
    assert {:ok, [_one_commit]} = Arca.StorageUnits.journal(actor, root, key)
    assert Arca.exists?(actor, role)

    # The commit stamped the role pending and its release never came: the
    # index is behind the tree, and says so rather than answer the rows it
    # held before the role was published.
    assert {:error, :projection_unavailable} = Compendium.AgentIndex.list(ctx)

    # Once the dead writer's draft has outlived its lifetime, the
    # reconciler's repair releases it at a newer, ready generation, and
    # the next read of the index derives the role with nothing else asked.
    long_ago =
      DateTime.add(DateTime.utc_now(), -2 * Arca.StorageUnits.draft_ttl_ms(), :millisecond)

    Arca.Repo.update_all(Arca.Schemas.StorageUnit, set: [updated_at: long_ago])
    assert :ok = Compendium.ProjectionReconciler.await(ctx, "aqua", settle_after_ms: 0)

    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    assert Enum.any?(rows, &(&1.name == "tracker"))
  end
end
