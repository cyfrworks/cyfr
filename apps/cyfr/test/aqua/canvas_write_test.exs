# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.CanvasWriteTest do
  @moduledoc """
  Aqua writes a canvas itself, through `canvas.write`. In `auto` a
  scripted turn's call runs as the model made it: the new version is laid
  whole, registered and allocated, while the turn opens no stream and the
  request log holds each file as its size and digest. A read-only soul is
  refused the call in its mode's sentence, and nothing is written.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @soul "agent:local.aqua"
  @model "catalyst:local.claude"
  @canvas "runs-board"
  @files %{
    "index.html" =>
      ~S|<!DOCTYPE html><html><head><link rel="stylesheet" href="style.css"></head><body><ul id="runs"></ul><script src="app.js"></script></body></html>|,
    "app.js" =>
      ~S|cyfr.stream("runs.changes", null, () => {}).catch(() => {}).finally(() => cyfr.ready()) // CANVAS_FILE_MARKER|,
    "style.css" => "body { margin: 0 }"
  }
  @data ["runs.changes", "schedules.changes"]
  @feeds ["btc"]

  setup do
    Arca.Cache.init()
    Cyfr.Test.Sandbox.setup!()

    test_path = Path.join(System.tmp_dir!(), "canvas_write_#{System.unique_integer([:positive])}")
    keys = [arca: :base_path, cyfr: :locus_runtime_workers]
    prev = Map.new(keys, fn {app, key} -> {{app, key}, Application.get_env(app, key)} end)
    Application.put_env(:arca, :base_path, test_path)
    Cyfr.Test.SeedBundle.lay!(~w(claude files http))

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

    {:ok, thread} = Arca.Test.Days.thread(Sanctum.Context.actor(ctx))
    {:ok, ctx: ctx, thread: thread}
  end

  test "in auto the write runs as the model made it: the version laid whole, registered and " <>
         "allocated, no stream opened and each file logged as its size and digest",
       %{ctx: ctx, thread: thread} do
    turn = asked!(ctx, thread)
    assert %{dispatch_state: "closed", outcome: "ok"} = canvas_step(ctx, turn)

    # The version directory, whole: the files and the manifest.
    actor = Sanctum.Context.actor(ctx)
    dir = Compendium.ComponentPath.version_dir("tincture", "local", @canvas, "0.1.0")
    {:ok, pairs} = Arca.read_subtree(actor, dir)
    written = Map.new(pairs, fn {segments, bytes} -> {Enum.join(segments, "/"), bytes} end)
    {manifest, files} = Map.pop!(written, "cyfr-manifest.json")
    assert files == @files

    assert %{
             "entry" => "index.html",
             "desktop" => %{"data" => @data, "feeds" => @feeds}
           } =
             Jason.decode!(manifest)["tincture"]

    # Registered as a canvas, and allocated in its versions document; a
    # browser activates it, the turn does not.
    assert {:ok, %{"release_digest" => "sha256:" <> _}} =
             Compendium.inspect_component(ctx, "tincture:local.#{@canvas}:0.1.0")

    assert {:ok, %{document: %{allocated: "0.1.0", working: nil}, revision: 1}} =
             Compendium.canvas_versions(ctx, @canvas)

    # The result the model read back is the version, never a value.
    [result] =
      for %{kind: "tool_result", content: content} <- Threads.messages(actor, thread.id),
          do: content

    assert result =~ "tincture:local.#{@canvas}:0.1.0"

    # No stream was opened by anything the turn ran, and the request log
    # holds each file as its size and digest, never its text.
    logs =
      Arca.Repo.all(from(l in Arca.Schemas.McpLog, where: l.athanor_id == ^ctx.athanor_id))

    refute Enum.any?(logs, &(&1.method == "streams/open"))
    assert [write] = Enum.filter(logs, &({&1.tool, &1.action} == {"canvas", "write"}))
    refute write.input =~ "CANVAS_FILE_MARKER"

    assert Jason.decode!(write.input)["files"] ==
             Map.new(@files, fn {path, text} -> {path, measured(text)} end)
  end

  test "a read-only soul is refused the write in its mode's sentence, and nothing is written",
       %{ctx: ctx, thread: thread} do
    {:ok, _} =
      Cyfr.Test.AquaTool.call(ctx, %{
        "action" => "update",
        "name" => Cyfr.Test.SeedBundle.seat_member(),
        "mode" => "read-only"
      })

    turn = asked!(ctx, thread)

    assert %{dispatch_state: "closed", outcome: "denied", result_message_id: refused} =
             canvas_step(ctx, turn)

    assert {:ok, %{content: content}} = Tape.message(ctx, refused)
    assert content == Aqua.Loop.Policy.read_only_sentence("Aqua")
    assert_nothing_written(ctx)
  end

  # The turn that asks to write the canvas, run to its end.
  defp asked!(ctx, thread) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{
          author: ctx.user_id,
          sent_by: "person",
          content: "@aqua make me a canvas of my runs"
        },
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    args = %{
      "action" => "write",
      "name" => @canvas,
      "template" => "vanilla",
      "files" => @files,
      "data" => @data,
      "feeds" => @feeds
    }

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

    turn
  end

  defp canvas_step(ctx, turn) do
    {:ok, steps} = Tape.steps(ctx, turn)
    [step] = for %{kind: "tool", tool: "canvas", action: "write"} = step <- steps, do: step
    step
  end

  defp assert_nothing_written(ctx) do
    actor = Sanctum.Context.actor(ctx)
    assert {:error, :not_found} = Arca.CanvasVersions.get(actor, @canvas)

    refute Arca.exists?(
             actor,
             Compendium.ComponentPath.version_dir("tincture", "local", @canvas, "0.1.0") ++
               ["cyfr-manifest.json"]
           )
  end

  defp measured(bytes) do
    %{
      "size" => byte_size(bytes),
      "digest" => "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    }
  end
end
