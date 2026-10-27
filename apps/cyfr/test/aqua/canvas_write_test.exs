# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.CanvasWriteTest do
  @moduledoc """
  Aqua writes a canvas itself, through `canvas.write`, and asks the person
  first (the soul's standing `ask`): a scripted turn's call opens a card
  and writes nothing until it is decided. Every write asks: the action
  takes no standing answer (`standing: false`), so its card offers only
  this call's approval, and no allow, given on a card or stored past the
  rule, covers a later write. The card names the streams the
  version reads, from the call it binds. Approved, the call runs as the
  card showed it, and the new version is laid whole, registered and
  allocated, while the turn opens no stream and the request log holds
  each file as its size and digest. Declined, or with its turn cancelled
  while the card waits, nothing is written.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedWorker
  alias Sanctum.Consent.Bootstrap

  @seed_root Path.expand("../../../../seed", __DIR__)
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
  @streams [%{"name" => "runs.changes"}, %{"name" => "schedules.changes"}]

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

  test "the write waits for the person, its card names the streams, and the approval runs " <>
         "the call the card showed",
       %{ctx: ctx, thread: thread} do
    turn = asked!(ctx, thread)

    # Nothing is written while the card waits.
    assert %{approval: approval, intent: intent} = pending_card(ctx, turn)
    assert_nothing_written(ctx)

    # The card binds the call as the model made it, and names its streams.
    assert %{"tool" => "canvas", "action" => "write", "args" => args} = intent["proposal"]

    assert {args["name"], args["template"], args["files"], args["streams"]} ==
             {@canvas, "vanilla", @files, @streams}

    html = card_html(intent, approval)

    [named] =
      Regex.run(~r/data-test="approval-canvas-streams"[^>]*>(.*?)<\/div>/s, html,
        capture: :all_but_first
      )

    assert named =~ "runs.changes"
    assert named =~ "schedules.changes"

    # The card offers this call's approval and no standing answer, and one
    # that would stand is refused while the card waits.
    assert intent["standing"] == false
    assert html =~ ~s(phx-value-scope="once")
    refute html =~ ~s(data-test="approval-standing")
    refute html =~ ~s(phx-value-scope="thread")
    refute html =~ ~s(phx-value-scope="always")

    for scope <- [:thread, :always] do
      assert {:error, {:scope_not_permitted, :never_standing}} =
               Aqua.Approvals.resolve(ctx, approval.id, %{decision: :approved, scope: scope})
    end

    assert {:ok, %{status: "pending"}} = Tape.approval(ctx, approval.id)
    assert_nothing_written(ctx)

    # Approved, the call runs as it was shown.
    assert {:ok, %{decision: "approved"}} =
             Aqua.Approvals.resolve(ctx, approval.id, %{decision: :approved})

    assert :completed = resume(ctx, turn)
    assert %{dispatch_state: "closed", outcome: "ok"} = canvas_step(ctx, turn)

    # The version directory, whole: the files and the manifest.
    actor = Sanctum.Context.actor(ctx)
    dir = Compendium.ComponentPath.version_dir("tincture", "local", @canvas, "0.1.0")
    {:ok, pairs} = Arca.read_subtree(actor, dir)
    written = Map.new(pairs, fn {segments, bytes} -> {Enum.join(segments, "/"), bytes} end)
    {manifest, files} = Map.pop!(written, "cyfr-manifest.json")
    assert files == @files

    assert %{
             "frame" => %{"placement" => "canvas"},
             "entry" => "index.html",
             "streams" => @streams
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

  test "no standing answer covers a later write: none is taken at either scope, and one " <>
         "stored past the rule leaves the next write waiting on its card",
       %{ctx: ctx, thread: thread} do
    allow = fn scope, thread_id ->
      %{
        scope: scope,
        effect: "allow",
        thread_id: thread_id,
        agent_name: "aqua",
        tool: "canvas",
        action: "write"
      }
    end

    standing = [{"thread", thread.id}, {"agent", nil}]

    for {scope, thread_id} <- standing do
      assert {:error, {:scope_not_permitted, :never_standing}} =
               Sanctum.ToolGrants.put(ctx, allow.(scope, thread_id)),
             "canvas.write took a #{scope}-scope standing allow"
    end

    # Allows written straight to storage, as by a surface that never went
    # through the rule, at both scopes: the turn's write still asks.
    for {scope, thread_id} <- standing do
      assert {:ok, _} =
               Arca.ToolGrantStorage.put(
                 Map.merge(allow.(scope, thread_id), %{
                   athanor_id: ctx.athanor_id,
                   granted_by: ctx.user_id
                 })
               )
    end

    turn = asked!(ctx, thread)
    assert %{intent: %{"standing" => false}} = pending_card(ctx, turn)
    assert_nothing_written(ctx)
  end

  test "a declined card writes nothing", %{ctx: ctx, thread: thread} do
    turn = asked!(ctx, thread)
    %{approval: approval} = pending_card(ctx, turn)

    assert {:ok, %{decision: "declined"}} =
             Aqua.Approvals.resolve(ctx, approval.id, %{decision: :declined})

    assert :completed = resume(ctx, turn)
    assert %{outcome: "denied"} = canvas_step(ctx, turn)
    assert_nothing_written(ctx)
  end

  test "a turn cancelled while its card waits writes nothing, and its card approves nothing",
       %{ctx: ctx, thread: thread} do
    turn = asked!(ctx, thread)
    %{approval: approval} = pending_card(ctx, turn)

    # As the runner stops a turn: abort it, then end it cancelled.
    {:ok, open} = Tape.turn(ctx, turn.id)
    assert {:ok, aborted} = Aqua.Loop.abort(ctx, open, "stopped")
    assert {:ok, _} = Tape.finish(ctx, aborted, "cancelled", %{error: "stopped"})

    refute match?(
             {:ok, %{decision: "approved"}},
             Aqua.Approvals.resolve(ctx, approval.id, %{decision: :approved})
           )

    assert_nothing_written(ctx)
  end

  # The turn that asks to write the canvas, run until it waits on its card.
  defp asked!(ctx, thread) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: "@aqua make me a canvas of my runs"},
        turn: %{agent: "aqua", requested_by: ctx.user_id}
      })

    args = %{
      "action" => "write",
      "name" => @canvas,
      "template" => "vanilla",
      "files" => @files,
      "streams" => @streams
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

    assert {:paused, :approval} =
             Task.await(Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end), 60_000)

    assert %{dispatch_state: "proposed"} = canvas_step(ctx, turn)
    turn
  end

  defp resume(ctx, turn) do
    Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume) end)
    |> Task.await(60_000)
  end

  defp canvas_step(ctx, turn) do
    {:ok, steps} = Tape.steps(ctx, turn)
    [step] = for %{kind: "tool", tool: "canvas", action: "write"} = step <- steps, do: step
    step
  end

  defp pending_card(ctx, turn) do
    {:ok, fresh} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, fresh)
    {:ok, card} = Tape.message(ctx, approval.message_id)
    %{approval: approval, intent: Tape.payload(card)["intent"]}
  end

  # The card as the console draws it.
  defp card_html(intent, approval) do
    render_component(PrismWeb.AquaApprovalCard,
      id: "card-#{approval.id}",
      message_id: approval.message_id,
      approval_id: approval.id,
      status: "pending",
      payload: intent
    )
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
