# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Aqua.TurnSourcesTest do
  @moduledoc """
  A turn's sources (`turns.sources`), grown through the real loop from
  every way it reads — the prompt's pinned page and notes index, a tool's
  result, a note's own provenance, an earlier turn's rows and a compaction
  summary — and a standing allow bounded by them: an allow names the
  outside sources it also follows, none unless a person chose some on the
  card, so a call made after an outside read it does not name asks, from
  the rows, after a restart too.

  The model, the HTTP hand and the files hand are scripted; everything
  else — the loop, the gate, the cards, `approval.resolve` and the pane
  that sends it — is real.
  """

  use PrismWeb.ConnCase, async: false

  alias Aqua.Tape
  alias Arca.ThreadStorage, as: Threads
  alias Cyfr.Test.ScriptedWorker
  alias Prima.Source
  alias Sanctum.Tenancy.Athanors

  @model "catalyst:local.claude"
  @http "catalyst:local.http"
  @files "catalyst:local.files"
  @model_id "scripted-small"
  @window 40_000
  @full 21_000
  @url "https://news.example/today"

  setup %{conn: conn} do
    Arca.Cache.init()
    test_path = Path.join(System.tmp_dir!(), "sources_#{System.unique_integer([:positive])}")
    original = Application.get_env(:arca, :base_path)

    on_exit(fn ->
      File.rm_rf(test_path)

      if original,
        do: Application.put_env(:arca, :base_path, original),
        else: Application.delete_env(:arca, :base_path)
    end)

    Application.put_env(:arca, :base_path, test_path)

    user = test_user()

    {:ok, room} =
      Athanors.create_group(user.user_id, "Sources #{System.unique_integer([:positive])}")

    conn = log_in_user(conn, user, athanor_id: room.id)
    {:ok, _} = Athanors.mark_provisioned(room)
    ctx = ready_athanor!(room.id, user.user_id)
    # The loops' work stops before the paths it runs under are restored.
    Cyfr.Test.Sandbox.stop_work_on_exit()
    ScriptedWorker.fresh_limits!(ctx, [@model, @http, @files])

    {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))
    {:ok, conn: conn, ctx: ctx, room: room, thread: thread, host: Source.outside("news.example")}
  end

  describe "a standing allow after an outside read" do
    test "a card's allow with no lifecycle asks again once the turn reads outside, after a restart too; one naming the host is spent",
         %{ctx: ctx, thread: thread, host: host} do
      turn = accept!(ctx, thread, "@aqua keep notes as you read")

      script!([
        calls([keep("c1", "first", "before reading")]),
        calls([get("c2")]),
        %{"body" => "Fares rise on Monday"},
        calls([keep("c3", "second", "fares rise")]),
        calls([keep("c4", "third", "fares rise")]),
        calls([keep("c5", "fourth", "fares rise")]),
        reply("done")
      ])

      # The card's answer: for this thread, with no lifecycle and no deadline.
      assert {:paused, :approval} = run(ctx, turn)
      approve!(ctx, turn, %{scope: :thread})

      assert {:ok, [%{sources: [], lifecycle_kind: nil, expires_at: nil}]} =
               Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")

      # The allow covered nothing past the outside read: the next keep asks.
      assert {:paused, :approval} = resume(ctx, turn)
      assert host in sources(ctx, turn)
      assert %{"sources" => shown} = pending_intent(ctx, turn)
      assert Source.to_json(host) in shown
      assert step(ctx, turn, "c2").outcome == "ok"
      assert step(ctx, turn, "c3").approval_id

      # A restart reads the sources from the row: the next keep asks again.
      decline!(ctx, turn)
      assert {:paused, :approval} = resume(ctx, turn)
      assert step(ctx, turn, "c4").approval_id

      # Approved also when it follows the host: the next keep is spent.
      approve!(ctx, turn, %{scope: :thread, sources: [host]})
      assert :completed = resume(ctx, turn)

      fourth = step(ctx, turn, "c5")
      assert %{outcome: "ok", approval_id: nil} = fourth
      {:ok, ended} = Tape.turn(ctx, turn.id)
      assert {:ok, []} = Tape.pending_approvals(ctx, ended)
      assert {:ok, %{sources: []}} = Aqua.Notes.read(ctx, "first")
      # Admitted by an allow naming the host, the note is still marked.
      assert {:ok, %{sources: kept}} = Aqua.Notes.read(ctx, "fourth")
      assert host in kept
    end

    test "the card's event through the pane and approval.resolve stores an allow naming the host, spent before and after a restart",
         %{conn: conn, ctx: ctx, room: room, thread: thread, host: host} do
      turn = accept!(ctx, thread, "@aqua read and keep")

      script!([
        calls([get("c1")]),
        %{"body" => "Fares rise on Monday"},
        calls([keep("c2", "first", "fares rise")]),
        calls([keep("c3", "second", "fares rise")]),
        reply("done"),
        calls([get("d1")]),
        %{"body" => "Fares rise again"},
        calls([keep("d2", "third", "again")]),
        reply("done again")
      ])

      assert {:paused, :approval} = run(ctx, turn)
      %{id: card_id} = pending_card(ctx, turn)

      pane = room_pane(conn, room, thread)
      card_dom = ~s([id$="-card-#{card_id}"])
      assert render(pane) =~ "news.example"

      pane
      |> element(~s(#{card_dom} input[phx-click="approval:toggle_follows"]))
      |> render_click()

      pane |> element(~s(#{card_dom} button[phx-value-hours="1"])) |> render_click()
      render(pane)

      assert {:ok, [%{sources: [^host], scope: "thread"}]} =
               Aqua.ToolGrants.for_thread(ctx, thread.id, "aqua")

      Cyfr.Test.Sandbox.end_views()

      # The decision resumes the turn: the approved keep runs, and the next
      # one, after the same host, is spent.
      Prima.Test.Wait.wait_until(fn -> status(ctx, turn) == "completed" end, 30_000)
      assert %{outcome: "ok", approval_id: nil} = step(ctx, turn, "c3")

      # A new turn, a new loop: the rows alone carry the allow and the reads.
      again = accept!(ctx, thread, "@aqua once more")
      assert :completed = run(ctx, again)
      assert %{outcome: "ok", approval_id: nil} = step(ctx, again, "d2")
      assert host in sources(ctx, again)
    end
  end

  describe "how a turn reads" do
    test "an earlier turn's outside result in history seeds a new turn before any call",
         %{ctx: ctx, thread: thread, host: host} do
      first = accept!(ctx, thread, "@aqua what is in the news?")
      script!([calls([get("c1")]), %{"body" => "Fares rise"}, reply("Fares rise.")])
      assert :completed = run(ctx, first)
      assert host in sources(ctx, first)
      stop_script!()

      # The second turn calls nothing: what it read is what its rows carried.
      second = accept!(ctx, thread, "@aqua and now?")
      script!([reply("still fares")])
      assert :completed = run(ctx, second)
      assert sources(ctx, second) == [host]
      assert [] = for(%{kind: kind} = s <- steps(ctx, second), kind != "model", do: s)
    end

    test "a compaction summary carries its turn's sources into the next turn",
         %{ctx: ctx, thread: thread, host: host} do
      # The first turn reads outside, then compacts its own older rows.
      first = accept_large!(ctx, thread)

      script!([
        response([get("c1")], nil, @full),
        %{"body" => "Fares rise"},
        reply("the story so far"),
        reply("Fares rise.")
      ])

      assert :completed = run(ctx, first)
      assert %{turn_id: by} = ctx |> rows(thread) |> Enum.find(&(&1.kind == "compaction"))
      assert by == first.id
      assert host in sources(ctx, first)
      stop_script!()

      second = accept!(ctx, thread, "@aqua and now?")
      script!([reply("still fares")])
      assert :completed = run(ctx, second)
      assert sources(ctx, second) == [host]
    end

    test "the prompt's pinned page and an outside-derived note in the index join without a notes.read",
         %{ctx: ctx, thread: thread, host: host} do
      {:ok, _} = Aqua.Notes.pin(ctx, "about-us", "We are planning a trip.")
      {:ok, _} = Aqua.Notes.keep(ctx, "clip", "Fares rise on Monday", sources: [host])

      turn = accept!(ctx, thread, "@aqua hello")
      script!([reply("hello")])
      assert :completed = run(ctx, turn)

      assert sources(ctx, turn) == [Source.new(:pinned), Source.new(:filed), host]
      [request] = chat_requests()
      assert Jason.encode!(request) =~ "kept after reading outside material: news.example"
    end

    test "the room excerpt is sent once, marked excluded, and adds no source",
         %{ctx: ctx, thread: thread} do
      {:ok, room_thread} = Threads.create(Sanctum.Context.actor(ctx))

      {:ok, _} =
        Threads.append(Sanctum.Context.actor(ctx), room_thread.id, %{
          author: ctx.user_id,
          content: "ROOM-ONLY-LINE"
        })

      {:ok, %{turn: turn}} =
        Tape.accept(ctx, thread.id, %{
          message: %{author: ctx.user_id, content: "@aqua what did they say?"},
          turn: %{
            agent: "aqua",
            requested_by: ctx.user_id,
            model: @model_id,
            options: %{"room" => %{"athanor_id" => ctx.athanor_id, "thread_id" => room_thread.id}}
          }
        })

      script!([
        calls([{"f1", "files", %{"action" => "list", "path" => "data"}}]),
        %{"entries" => []},
        reply("They said hello.")
      ])

      assert :completed = run(ctx, turn)
      [first, second] = chat_requests()
      assert Jason.encode!(first) =~ "ROOM-ONLY-LINE"
      refute Jason.encode!(second) =~ "ROOM-ONLY-LINE"

      [opened | _] = for %{kind: "model"} = s <- steps(ctx, turn), do: s
      assert opened.excluded =~ "room_excerpt"
      [_ | later] = for %{kind: "model"} = s <- steps(ctx, turn), do: s
      refute Enum.any?(later, fn s -> (s.excluded || "") =~ "room_excerpt" end)

      # The files read is the turn's only source.
      assert sources(ctx, turn) == [Source.new(:files_by_grant)]
    end

    test "a note kept by a flush after an outside read carries it, and reading it elsewhere puts it back",
         %{ctx: ctx, thread: thread, host: host} do
      # The flush runs under an allow that follows the host.
      {:ok, _} =
        Aqua.ToolGrants.put(ctx, %{
          scope: "thread",
          effect: "allow",
          thread_id: thread.id,
          agent_name: "aqua",
          tool: "notes",
          action: "keep",
          sources: [host]
        })

      turn = accept_large!(ctx, thread)

      script!([
        response([get("c1")], nil, @full),
        %{"body" => "Fares rise"},
        response([keep("n1", "plan", "fares rise on Monday")], nil, @full),
        reply("the story so far"),
        reply("done")
      ])

      assert :completed = run(ctx, turn)
      assert %{purpose: "flush", outcome: "ok"} = step(ctx, turn, "n1")
      assert {:ok, %{sources: kept}} = Aqua.Notes.read(ctx, "plan")
      assert host in kept
      stop_script!()

      # Another thread shares no history: only the note's provenance can
      # bring the host into its turn.
      {:ok, elsewhere} = Threads.create(Sanctum.Context.actor(ctx))
      later = accept!(ctx, elsewhere, "@aqua what was the plan?")

      script!([
        calls([{"r1", "notes", %{"action" => "read", "name" => "plan"}}]),
        reply("Fares rise on Monday.")
      ])

      assert :completed = run(ctx, later)
      assert host in sources(ctx, later)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp script!(items) do
    start_supervised!(
      {ScriptedWorker, ref: [@model, @http, @files], script: items, window: @window},
      id: :script
    )
  end

  defp stop_script!, do: stop_supervised!(:script)

  defp run(ctx, turn),
    do: Task.async(fn -> Aqua.Loop.run(ctx: ctx, turn_id: turn.id) end) |> Task.await(60_000)

  defp resume(ctx, turn) do
    Task.async(fn -> Aqua.Loop.run_nested(ctx: ctx, turn_id: turn.id, mode: :resume) end)
    |> Task.await(60_000)
  end

  defp accept!(ctx, thread, text) do
    {:ok, %{turn: turn}} =
      Tape.accept(ctx, thread.id, %{
        message: %{author: ctx.user_id, content: text},
        turn: %{agent: "aqua", requested_by: ctx.user_id, model: @model_id}
      })

    turn
  end

  # A message past the window's fill: the first round has nothing older to
  # summarize; once a round follows it, the message is older than the
  # boundary.
  defp accept_large!(ctx, thread),
    do: accept!(ctx, thread, "@aqua read this\n" <> String.duplicate("lorem ipsum ", 7_000))

  defp status(ctx, turn) do
    {:ok, %{status: status}} = Tape.turn(ctx, turn.id)
    status
  end

  defp sources(ctx, turn) do
    {:ok, %{sources: sources}} = Tape.turn(ctx, turn.id)
    Source.decode(sources)
  end

  defp steps(ctx, turn) do
    {:ok, steps} = Tape.steps(ctx, turn)
    steps
  end

  # The step of one call, by the id its model gave it.
  defp step(ctx, turn, call_id) do
    {:ok, steps} = Tape.steps(ctx, turn)
    Enum.find(steps, &String.ends_with?(&1.idempotency_key || "", ":" <> call_id))
  end

  defp rows(ctx, thread), do: Threads.messages(Sanctum.Context.actor(ctx), thread.id)

  defp pending_card(ctx, turn) do
    {:ok, fresh} = Tape.turn(ctx, turn.id)
    {:ok, [approval]} = Tape.pending_approvals(ctx, fresh)
    {:ok, card} = Tape.message(ctx, approval.message_id)
    %{id: card.id, approval: approval, intent: Tape.payload(card)["intent"]}
  end

  defp pending_intent(ctx, turn), do: pending_card(ctx, turn).intent

  defp approve!(ctx, turn, choice) do
    %{approval: approval} = pending_card(ctx, turn)

    assert {:ok, %{decision: "approved"}} =
             Aqua.Approvals.resolve(ctx, approval.id, Map.put(choice, :decision, :approved))
  end

  defp decline!(ctx, turn) do
    %{approval: approval} = pending_card(ctx, turn)
    assert {:ok, _} = Aqua.Approvals.resolve(ctx, approval.id, %{decision: :declined})
  end

  defp room_pane(conn, room, thread) do
    {:ok, view, _} = live(conn, PrismWeb.ChatLive.chat_path(Athanors.route_slug(room), thread.id))
    settled_render(view)
    child!(view, "pane-" <> room.id)
  end

  # A nested view mounts after its host renders; look again until it has.
  defp child!(parent, id, tries \\ 50) do
    render(parent)

    case find_live_child(parent, id) do
      nil when tries > 0 ->
        Process.sleep(20)
        child!(parent, id, tries - 1)

      nil ->
        flunk("no child #{id} under #{parent.id}")

      child ->
        child
    end
  end

  defp get(id), do: {id, "http", %{"action" => "get", "url" => @url}}

  defp keep(id, name, content),
    do: {id, "notes", %{"action" => "keep", "name" => name, "content" => content}}

  defp calls(blocks), do: response(blocks, nil, 10)

  defp response(blocks, text, input_tokens) do
    content =
      if(text, do: [%{"type" => "text", "text" => text}], else: []) ++
        Enum.map(blocks, fn {id, name, args} ->
          %{"type" => "tool_call", "id" => id, "name" => name, "arguments" => args}
        end)

    %{
      "content" => content,
      "stop_reason" => "tool_call",
      "usage" => %{"input_tokens" => input_tokens, "output_tokens" => 8}
    }
  end

  defp reply(text),
    do: %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

  defp chat_requests do
    for %{input: %{"operation" => "chat", "params" => params}} <- ScriptedWorker.calls(),
        do: params
  end
end
