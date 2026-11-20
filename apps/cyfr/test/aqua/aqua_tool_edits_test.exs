# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.AquaToolEditsTest do
  @moduledoc """
  The `aqua` tool's edits meet under the lock: an add or a remove of the
  soul's tools keeps a concurrent member's toggle, a prompt save names
  the version it edited, a crew member holds no tools to edit, and a new
  crew member is its own file and nothing else.
  """
  use ExUnit.Case, async: false

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
    {:ok, %{"created" => "scout"}} = call(ctx, %{"action" => "create", "name" => "scout"})
    %{ctx: ctx}
  end

  defp call(ctx, args), do: Cyfr.Test.AquaTool.call(ctx, args)

  defp tools(ctx, name) do
    {:ok, %{"tools" => tools}} = call(ctx, %{"action" => "get", "name" => name})
    tools
  end

  @soul "aqua"

  test "a new crew member leaves the soul as it was, and the answer names only what it created",
       %{ctx: ctx} do
    actor = Sanctum.Context.actor(ctx)
    {:ok, soul} = Arca.get(actor, AquaPath.soul_file())
    before = tools(ctx, @soul)

    assert {:ok, %{"created" => "sentry", "type" => "crew"} = created} =
             call(ctx, %{"action" => "create", "name" => "sentry"})

    assert map_size(created) == 2
    assert {:ok, ^soul} = Arca.get(actor, AquaPath.soul_file())
    assert tools(ctx, @soul) == before
    assert tools(ctx, "sentry") == before
  end

  # The derived index follows every write to the tree: a created member has
  # a row with its two digests, an edit moves them, a delete removes the row.
  test "the agent index follows the tree", %{ctx: ctx} do
    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    assert %{kind: "crew", disabled: false} = scout = Enum.find(rows, &(&1.name == "scout"))
    assert String.starts_with?(scout.revision_digest, "sha256:")
    assert scout.capability_digest =~ "sha256:"

    assert {:ok, _} =
             call(ctx, %{"action" => "update", "name" => "scout", "model" => "another-model"})

    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    edited = Enum.find(rows, &(&1.name == "scout"))
    refute edited.revision_digest == scout.revision_digest
    refute edited.capability_digest == scout.capability_digest

    # The member is offered the soul's tools: an edit of the soul's list
    # moves the member's capability, never its file.
    refute "storage.write" in tools(ctx, @soul)

    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => @soul,
               "tools_add" => ["storage.write"]
             })

    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    under = Enum.find(rows, &(&1.name == "scout"))
    assert under.revision_digest == edited.revision_digest
    refute under.capability_digest == edited.capability_digest

    assert {:ok, _} = call(ctx, %{"action" => "delete", "name" => "scout"})
    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    refute Enum.any?(rows, &(&1.name == "scout"))
  end

  # A reset reverts the tree to what ships, and the index follows: a crew
  # member the athanor created does not outlive its file as a row.
  test "the agent index follows a reset", %{ctx: ctx} do
    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    assert Enum.any?(rows, &(&1.name == "scout"))

    assert {:ok, %{"reset" => true}} = call(ctx, %{"action" => "reset", "all" => true})

    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    refute Enum.any?(rows, &(&1.name == "scout"))
    assert Enum.any?(rows, &(&1.name == AquaPath.soul_name()))
  end

  test "two members toggling different tools of the soul's list at once keep both", %{ctx: ctx} do
    before = tools(ctx, @soul)
    refute "storage.write" in before or "custom.thing" in before

    ["storage.write", "custom.thing"]
    |> Enum.map(fn tool ->
      Task.async(fn ->
        call(ctx, %{"action" => "update", "name" => @soul, "tools_add" => [tool]})
      end)
    end)
    |> Task.await_many(30_000)
    |> Enum.each(&assert({:ok, %{"updated" => @soul}} = &1))

    assert tools(ctx, @soul) == Enum.sort(before ++ ["custom.thing", "storage.write"])

    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => @soul,
               "tools_remove" => ["storage.write"]
             })

    assert tools(ctx, @soul) == Enum.sort(["custom.thing" | before])

    # The crew is offered it.
    assert tools(ctx, "scout") == tools(ctx, @soul)
  end

  test "a patch is applied to the list as it is, in its one form, and a crew member holds none",
       %{ctx: ctx} do
    actor = Sanctum.Context.actor(ctx)
    {:ok, scout} = Arca.get(actor, AquaPath.crew_file("scout"))
    [first | _] = before = tools(ctx, @soul)

    # An add of a tool the list holds, and a remove of one it does not,
    # leave it as it was.
    for patch <- [%{"tools_add" => [first]}, %{"tools_remove" => ["custom.thing"]}] do
      assert {:ok, %{"updated" => @soul}} =
               call(ctx, Map.merge(%{"action" => "update", "name" => @soul}, patch))

      assert tools(ctx, @soul) == before
    end

    # One write adds and removes.
    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => @soul,
               "tools_add" => ["custom.thing"],
               "tools_remove" => [first]
             })

    after_patch = Enum.sort(["custom.thing" | before -- [first]])
    assert tools(ctx, @soul) == after_patch

    # An entry outside the grammar is refused at the door, one that is no
    # string by the tool's schema; a list beside its patch is refused.
    assert {:error,
            {:invalid_argument,
             ~s{Invalid tool "no-dot-here" — use "tool.action", "native_search" or "server:tool", one action an entry: list each action of a tool by name}}} =
             call(ctx, %{"action" => "update", "name" => @soul, "tools_add" => ["no-dot-here"]})

    assert {:error, %Prima.Refusal{stage: :admission, reason: {:invalid_argument, _}}} =
             call(ctx, %{"action" => "update", "name" => @soul, "tools_add" => [7]})

    assert {:error, {:invalid_argument, "Give tools, or tools_add and tools_remove, not both"}} =
             call(ctx, %{
               "action" => "update",
               "name" => @soul,
               "tools" => [],
               "tools_add" => ["files.read"]
             })

    # A crew member is offered the soul's tools and holds none to write.
    crew =
      "A crew member is offered the soul's tools and has none of its own — edit the soul's"

    for args <- [
          %{"tools_add" => ["files.read"]},
          %{"tools_remove" => [first]},
          %{"tools" => []}
        ] do
      assert {:error, {:invalid_argument, ^crew}} =
               call(ctx, Map.merge(%{"action" => "update", "name" => "scout"}, args))
    end

    assert tools(ctx, @soul) == after_patch
    assert {:ok, ^scout} = Arca.get(actor, AquaPath.crew_file("scout"))
    refute scout =~ "tools"
    assert tools(ctx, "scout") == after_patch
  end

  # A brain-option edit is a patch applied to the options as the write
  # lands, under the rewrite's lock: edits of different options made at
  # once all keep, and null takes one off.
  test "concurrent edits of different brain options all survive", %{ctx: ctx} do
    options = %{"effort" => "high", "budget" => 8, "thinking" => true, "mode" => "plan"}

    options
    |> Enum.map(fn {name, value} ->
      Task.async(fn ->
        call(ctx, %{"action" => "update", "name" => "scout", "options_patch" => %{name => value}})
      end)
    end)
    |> Task.await_many(30_000)
    |> Enum.each(&assert({:ok, _} = &1))

    assert {:ok, %{"options" => ^options}} = call(ctx, %{"action" => "get", "name" => "scout"})

    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "options_patch" => %{"mode" => nil}
             })

    want = Map.delete(options, "mode")
    assert {:ok, %{"options" => ^want}} = call(ctx, %{"action" => "get", "name" => "scout"})

    for bad <- [%{"effort" => %{"level" => "high"}}, %{"" => "x"}] do
      assert {:error, {:invalid_argument, _}} =
               call(ctx, %{"action" => "update", "name" => "scout", "options_patch" => bad})
    end

    assert {:error, {:invalid_argument, "Give options or options_patch, not both"}} =
             call(ctx, %{
               "action" => "update",
               "name" => "scout",
               "options" => %{},
               "options_patch" => %{"effort" => "low"}
             })
  end

  # A brain is a catalyst or a program, by its row's name: the tool writes
  # either, with the program's install beside it, lists and gets what it
  # wrote, indexes it, and refuses a member that would name both, whether
  # the call names both or one beside the file's other. A name the athanor
  # has no row of is configuration all the same: the install follows it.
  test "a member's brain is a program by name through the tool, never a catalyst too", %{ctx: ctx} do
    actor = Sanctum.Context.actor(ctx)
    install = "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323"
    assert {:error, :not_found} = Arca.McpServerStorage.get(actor, "claude")

    assert {:ok, %{"created" => "coder"}} =
             call(ctx, %{
               "action" => "create",
               "name" => "coder",
               "program" => "claude",
               "install" => install,
               "model" => "opus"
             })

    assert {:ok,
            %{
              "program" => "claude",
              "install" => ^install,
              "catalyst_ref" => nil,
              "model" => "opus"
            }} = call(ctx, %{"action" => "get", "name" => "coder"})

    {:ok, %{"guides" => guides}} = call(ctx, %{"action" => "list", "detail" => true})

    assert %{"program" => "claude", "install" => ^install, "catalyst_ref" => nil} =
             Enum.find(guides, &(&1["name"] == "coder"))

    assert %{"program" => nil, "install" => nil} = Enum.find(guides, &(&1["name"] == "scout"))

    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    coder = Enum.find(rows, &(&1.name == "coder"))
    assert %{program: "claude", catalyst_ref: nil} = coder
    assert %{program: nil} = Enum.find(rows, &(&1.name == "scout"))

    # Another install is the same capability; another name is another.
    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => "coder",
               "install" => "cyfr-claude-code claude"
             })

    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    assert Enum.find(rows, &(&1.name == "coder")).capability_digest == coder.capability_digest

    assert {:ok, _} =
             call(ctx, %{"action" => "update", "name" => "coder", "program" => "claude-work"})

    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    moved = Enum.find(rows, &(&1.name == "coder"))
    assert moved.program == "claude-work"
    refute moved.capability_digest == coder.capability_digest

    assert {:ok, %{"install" => "cyfr-claude-code claude"}} =
             call(ctx, %{"action" => "get", "name" => "coder"})

    {:ok, file} = Arca.get(actor, AquaPath.crew_file("coder"))

    both =
      "An agent's brain is a catalyst or a program, never both — " <>
        "give catalyst_ref or program, and clear the other"

    # Both named by the call, and a catalyst named beside the file's program.
    refused =
      for args <- [
            %{"action" => "create", "name" => "both", "program" => "claude"},
            %{"action" => "update", "name" => "coder", "program" => "claude"},
            %{"action" => "update", "name" => "coder"}
          ],
          do: call(ctx, Map.put(args, "catalyst_ref", "catalyst:local.claude"))

    assert refused == List.duplicate({:error, {:invalid_argument, both}}, 3)

    refute Arca.exists?(actor, AquaPath.crew_file("both"))
    assert {:ok, ^file} = Arca.get(actor, AquaPath.crew_file("coder"))

    # The program and its install cleared in the same write, the brain
    # moves to the catalyst.
    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => "coder",
               "catalyst_ref" => "catalyst:local.claude",
               "program" => nil,
               "install" => nil
             })

    assert {:ok, %{"program" => nil, "install" => nil, "catalyst_ref" => "catalyst:local.claude"}} =
             call(ctx, %{"action" => "get", "name" => "coder"})

    # Nothing of it made a program row.
    assert {:error, :not_found} = Arca.McpServerStorage.get(actor, "claude")
  end

  # Only the soul has a prompt to save.
  test "a prompt save names the version it edited and is refused over a newer one", %{ctx: ctx} do
    {:ok, %{"content_digest" => digest, "content" => prompt}} =
      call(ctx, %{"action" => "get", "name" => "aqua"})

    assert digest == Prima.Digest.sha256_hex(prompt)

    assert {:ok, _} =
             call(ctx, %{
               "action" => "update",
               "name" => "aqua",
               "content" => "# Aqua\n\nLook first.",
               "expected_digest" => digest
             })

    assert {:error, {:conflict, message}} =
             call(ctx, %{
               "action" => "update",
               "name" => "aqua",
               "content" => "# Aqua\n\nA stale draft.",
               "expected_digest" => digest
             })

    assert message =~ "changed since"
    {:ok, %{"content" => content}} = call(ctx, %{"action" => "get", "name" => "aqua"})
    assert content =~ "Look first."
  end

  @tag :capture_log
  test "a crew member whose writer died after its commit is published, and the index names it once the repair releases it",
       %{ctx: ctx} do
    actor = Sanctum.Context.actor(ctx)
    role = AquaPath.crew_file("tracker")
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
    # The dead writer's node-local lock outlives it by a moment, and a
    # repair that finds it held takes nothing.
    Arca.Test.LockWait.await_unit_lock_free!(actor, role)

    # Published: the row, the journal, and the member reads already.
    assert {:ok, %{state: "committed"}} = Arca.StorageUnits.current(actor, root, key)
    assert {:ok, [_one_commit]} = Arca.Test.StorageJournal.journal(actor, root, key)
    assert Arca.exists?(actor, role)

    # The commit stamped the member pending and its release never came: the
    # index is behind the tree, and says so rather than answer the rows it
    # held before the member was published.
    assert {:error, :projection_unavailable} = Compendium.AgentIndex.list(ctx)

    # Once the dead writer's draft has outlived its lifetime, the
    # reconciler's repair releases it at a newer, ready generation, and
    # the next read of the index derives the member with nothing else asked.
    long_ago =
      DateTime.add(DateTime.utc_now(), -2 * Arca.StorageUnits.draft_ttl_ms(), :millisecond)

    Arca.Repo.update_all(Arca.Schemas.StorageUnit, set: [updated_at: long_ago])
    Arca.Repo.update_all(Arca.Schemas.StorageProjectionChange, set: [updated_at: long_ago])
    assert :ok = Compendium.ProjectionReconciler.await(ctx, "aqua")

    {:ok, rows} = Compendium.AgentIndex.list(ctx)
    assert Enum.any?(rows, &(&1.name == "tracker"))
  end
end
