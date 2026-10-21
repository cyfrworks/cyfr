# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.CanvasWriteTest do
  @moduledoc """
  Aqua writes a canvas itself, through `canvas.write`, from the shapes it
  may read and never from a value: one scripted turn calls the tool with
  no stream (none is canvas-readable yet), the call runs without a card
  under the soul's standing `auto`, and the new version is laid whole,
  registered and allocated, while the turn opens no stream and reads no
  stream value.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @seed_root Path.expand("../../../../seed", __DIR__)
  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @module ~S|export default function (canvas) { canvas.render({type: "text", value: "Runs"}) }|

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "canvas_write_#{System.unique_integer([:positive])}")
    keys = [arca: :base_path, arca: :seed_path, cyfr: :locus_runtime_workers]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, test_path)
    Application.put_env(:arca, :seed_path, @seed_root)

    on_exit(fn ->
      File.rm_rf!(test_path)

      for {{app, key}, value} <- prev do
        if value,
          do: Application.put_env(app, key, value),
          else: Application.delete_env(app, key)
      end
    end)

    # The loops' work stops before the paths it runs under are restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()

    ctx = Sanctum.TestContext.local(:prism)
    :ok = Sanctum.TestContext.shipped!(ctx.athanor_id)
    {:ok, %{errors: 0}} = Compendium.AutoIndexer.scan(ctx: ctx)
    {:ok, _} = Compendium.AgentIndex.sync(ctx)
    {:ok, %{minted: minted}} = Bootstrap.run(ctx)
    assert @soul in minted
    # The model catalyst unseals its key when its runner attaches.
    Sanctum.Test.ConsentFixtures.bind_key!(ctx, @model, %{"ANTHROPIC_API_KEY" => "sk-test"})
    ScriptedWorker.fresh_limits!(ctx, [@model])

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, thread: thread}
  end

  test "a scripted turn writes a new canvas version and reads no stream value", %{
    ctx: ctx,
    thread: thread
  } do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua make me a canvas of my runs"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    args = %{"action" => "write", "name" => "runs-board", "module" => @module, "streams" => []}

    start_supervised!(
      {ScriptedWorker,
       ref: @model,
       script: [
         %{
           "content" => [
             %{"type" => "tool_call", "id" => "c1", "name" => "canvas", "arguments" => args}
           ],
           "stop_reason" => "tool_call",
           "usage" => %{"input_tokens" => 20, "output_tokens" => 8}
         },
         %{
           "content" => [%{"type" => "text", "text" => "Your canvas is written."}],
           "stop_reason" => "end_turn",
           "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
         }
       ]}
    )

    assert :completed =
             Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 60_000)

    # The one call ran under the soul's standing auto: no card was raised.
    {:ok, steps} = Tape.steps(ctx, turn)

    assert [
             %{kind: "model"},
             %{kind: "tool", tool: "canvas", action: "write"} = call,
             %{kind: "model"}
           ] =
             steps

    assert {call.dispatch_state, call.outcome} == {"closed", "ok"}
    assert {:ok, []} = Tape.pending_approvals(ctx, turn)

    # The version directory, whole: its manifest and its module.
    actor = Sanctum.Context.actor(ctx)
    dir = Compendium.ComponentPath.version_dir("tincture", "local", "runs-board", "0.1.0")
    assert {:ok, files} = Arca.list_typed(actor, dir)
    assert Enum.sort(files) == [{"canvas.js", :file}, {"cyfr-manifest.json", :file}]
    assert {:ok, @module} = Arca.get(actor, dir ++ ["canvas.js"])

    # Registered as a canvas, and allocated in its versions document; a
    # glass activates it, the turn does not.
    assert {:ok, %{"release_digest" => "sha256:" <> _, "manifest" => manifest}} =
             Compendium.inspect_component(ctx, "tincture:local.runs-board:0.1.0")

    assert {:ok, decoded} = Prima.Manifest.decode_strict(manifest)
    assert get_in(decoded, ["tincture", "frame", "placement"]) == "canvas"

    assert {:ok, %{document: %{allocated: "0.1.0", working: nil}, revision: 1}} =
             Compendium.canvas_versions(ctx, "runs-board")

    # The result the model read back is the version, never a value.
    [result] =
      for %{kind: "tool_result", content: content} <-
            Threads.messages(actor, thread.id),
          do: content

    assert result =~ "tincture:local.runs-board:0.1.0"

    # No stream was opened by anything the turn ran, and no stream's value
    # reached the model.
    opens =
      Arca.Repo.all(
        from(l in Arca.Schemas.McpLog,
          where: l.athanor_id == ^ctx.athanor_id and l.method == "streams/open"
        )
      )

    assert opens == []
    refute Enum.any?(steps, &(&1.kind == "tool" and &1.tool != "canvas"))
  end
end
