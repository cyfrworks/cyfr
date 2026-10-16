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
  that sends it — is real. The model's key is bound as a disclosed vault
  field, so every turn whose model ran holds `vault_disclosed`: the model
  child's ledger joins its turn when its step closes.
  """

  use PrismWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

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
      assert sources(ctx, second) == [Source.new(:vault_disclosed), host]
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
      assert sources(ctx, second) == [Source.new(:vault_disclosed), host]
    end

    test "the prompt's pinned page and an outside-derived note in the index join without a notes.read",
         %{ctx: ctx, thread: thread, host: host} do
      {:ok, _} = Aqua.Notes.pin(ctx, "about-us", "We are planning a trip.")
      {:ok, _} = Aqua.Notes.keep(ctx, "clip", "Fares rise on Monday", sources: [host])

      turn = accept!(ctx, thread, "@aqua hello")
      script!([reply("hello")])
      assert :completed = run(ctx, turn)

      assert sources(ctx, turn) == [
               Source.new(:pinned),
               Source.new(:filed),
               Source.new(:vault_disclosed),
               host
             ]

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

      # The files read is the turn's only source beside the model's key.
      assert sources(ctx, turn) == [Source.new(:files_by_grant), Source.new(:vault_disclosed)]
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

  describe "a launched component" do
    test "is outside, named by its reference, only when a run of its tree was admitted with egress",
         %{ctx: ctx, thread: thread} do
      turn = running!(ctx, thread)

      quiet = launched!(ctx, [])
      assert closed_launch!(ctx, turn, "formula:local.quiet", quiet) == []

      loud = launched!(ctx, ["api.example.com"])

      assert closed_launch!(ctx, turn, "formula:local.loud", loud) ==
               [Source.outside("formula:local.loud")]

      # A quiet root whose child reached the network.
      tree = launched!(ctx, [])
      _child = child_run!(ctx, tree, ["feeds.example"])

      assert Source.outside("formula:local.tree") in closed_launch!(
               ctx,
               turn,
               "formula:local.tree",
               tree
             )

      # A tree no row answers for, and a launch with no result, cannot
      # show they stayed in the athanor.
      assert Source.outside("formula:local.gone") in closed_launch!(
               ctx,
               turn,
               "formula:local.gone",
               "exec_none"
             )

      assert Source.outside("formula:local.unnamed") in closed_launch!(
               ctx,
               turn,
               "formula:local.unnamed",
               nil
             )
    end

    test "a root whose policy no longer reads as a JSON object is outside, marked or not",
         %{ctx: ctx, thread: thread} do
      turn = running!(ctx, thread)

      for {name, domains, policy} <- [
            {"formula:local.marked", ["api.example.com"], "not-json"},
            {"formula:local.blank", [], ""}
          ] do
        root = launched!(ctx, domains)

        {1, _} =
          Arca.Repo.update_all(from(e in Arca.Schemas.Execution, where: e.id == ^root),
            set: [host_policy: policy]
          )

        assert closed_launch!(ctx, turn, name, root) == [Source.outside(name)]
      end
    end

    test "retention pruning an egress-bearing child before the launch closes does not erase the outside source",
         %{ctx: ctx, thread: thread} do
      turn = running!(ctx, thread)
      actor = Sanctum.Context.actor(ctx)
      grant = Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id)
      root = launched!(ctx, [])

      loud = child_run!(ctx, root, ["feeds.example"])
      assert {:ok, _} = ended!(actor, loud.execution.id, loud.attempt.attempt, grant)
      quiet = child_run!(ctx, root, [])

      # The newest-N selection is deterministic without a timing sleep.
      {1, _} =
        Arca.Repo.update_all(
          from(e in Arca.Schemas.Execution, where: e.id == ^quiet.execution.id),
          set: [started_at: DateTime.add(DateTime.utc_now(), 1, :second)]
        )

      assert {:ok, 1} = Arca.Retention.cleanup(actor, "executions", value: 1)

      refute Arca.Repo.exists?(
               from(e in Arca.Schemas.Execution, where: e.id == ^loud.execution.id)
             )

      assert Arca.Repo.exists?(
               from(e in Arca.Schemas.Execution, where: e.id == ^root and e.status == "running")
             )

      assert Arca.Repo.exists?(
               from(e in Arca.Schemas.Execution, where: e.id == ^quiet.execution.id)
             )

      assert {:ok, _} = ended!(actor, quiet.execution.id, quiet.attempt.attempt, grant)
      root_row = Arca.Execution.get_tenant(actor, root)
      assert {:ok, _} = ended!(actor, root, root_row.current_attempt, grant)

      assert Source.outside("formula:local.retained-tree") in closed_launch!(
               ctx,
               turn,
               "formula:local.retained-tree",
               root
             )
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

  # A running turn on a root of its own, as the loop holds one.
  defp running!(ctx, thread) do
    turn = accept!(ctx, thread, "@aqua launch it")

    {:ok, %{execution: execution, attempt: attempt}} =
      Arca.Execution.admit(
        %{
          id: "exec_src_#{System.unique_integer([:positive])}",
          reference: "agent:local.aqua",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "agent",
          kind: "turn",
          turn_id: turn.id,
          origin: :interactive
        },
        reservation: %{budget_id: "bgt_#{System.unique_integer([:positive])}", cap: 4},
        grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
        verify: &Sanctum.ExecutionStanding.verify/1
      )

    {:ok, turn} =
      Tape.start_turn(ctx, turn, %{
        root_execution_id: execution.id,
        attempt: attempt.attempt,
        profile_id: "prof_src",
        consent_id: "consent_src",
        recovery_limit: Aqua.Runner.RecoveryPolicy.max_attempts()
      })

    turn
  end

  # A launched root admitted with `domains` as its egress, as Opus admits
  # one (`Opus.Record`): the policy it enforced, and the tree's mark when
  # that policy reaches the network.
  defp launched!(ctx, domains) do
    id = "exec_launched_#{System.unique_integer([:positive])}"
    {:ok, _} = admit_run!(ctx, id, domains, %{})
    id
  end

  # A child of `root` admitted the same way.
  defp child_run!(ctx, root, domains) do
    id = "exec_child_#{System.unique_integer([:positive])}"

    {:ok, admitted} =
      admit_run!(ctx, id, domains, %{parent_execution_id: root, root_execution_id: root})

    admitted
  end

  defp admit_run!(ctx, id, domains, lineage) do
    Arca.Execution.admit(
      Map.merge(
        %{
          id: id,
          reference: "formula:local.launched",
          user_id: ctx.user_id,
          athanor_id: ctx.athanor_id,
          component_type: "formula",
          origin: :interactive,
          host_policy: Jason.encode!(%{allowed_domains: domains, allowed_tools: []})
        },
        lineage
      ),
      grant: Cyfr.Test.AttemptFixtures.grant(ctx.athanor_id),
      verify: &Sanctum.ExecutionStanding.verify/1,
      reaches_outside: domains != []
    )
  end

  defp ended!(actor, id, attempt, grant) do
    Arca.Execution.record_end(
      actor,
      id,
      "completed",
      %{completed_at: DateTime.utc_now(), duration_ms: 1},
      attempt,
      grant: grant,
      verify: &Sanctum.ExecutionStanding.verify/1
    )
  end

  # One step of the turn closed as the loop closes a launch of `reference`
  # whose run started `execution_id`: with what its completion result says
  # (`execution.run`'s `reached_outside`, read as the provider reads it),
  # nothing for a launch with no result. Answers the sources it added.
  defp closed_launch!(ctx, turn, reference, execution_id) do
    before = sources(ctx, turn)
    {:ok, step} = Tape.record_model_intent(ctx, turn, %{})
    {:ok, step} = Tape.mark_dispatched(ctx, turn, step)

    reached =
      case execution_id && Opus.Record.reached_outside(ctx, execution_id) do
        reached when is_boolean(reached) -> reached
        _none -> :unknown
      end

    {:ok, _} =
      Tape.close_step(ctx, turn, step, "ok", %{
        launched: %{reference: reference, execution_id: execution_id, reached_outside: reached}
      })

    sources(ctx, turn) -- before
  end

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
