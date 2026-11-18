# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.BrainTest do
  @moduledoc """
  The brain holder (`Opus.Brain`) against the scripted backends service,
  the test playing the driver: it reads the lines the holder sends and
  writes the driver's into the session (`Cyfr.Test.ScriptedBackends`).

  A session opens fresh for a binding that proves a running turn, its
  driver's hello handed first; one command is written at a time, after
  the hello; each batch is handed whole and the next read only once the
  attendant says; a write is refused, with nothing written, for a binding
  of another athanor, person, row or epoch, a moved fence, a moved
  generation, a step that is not the turn's decided `program.start` of
  that row and epoch, a turn that is not running, and a stored decision
  that no longer stands (a standing never recorded since, an allow past
  its deadline or short of the turn's sources, a card not approved); a
  paused turn's proof writes a post or an answer of its own work and
  nothing else; a stale open ends no successor. A line that does not read, one past the bound, one lost
  unread, the row's change, the driver's end, a lost answer to a write and
  a take-over each end the session, its box session closed.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.TurnStorage
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Opus.Brain

  @root :crypto.strong_rand_bytes(32)

  setup do
    Cyfr.Test.Sandbox.setup!()
    Arca.Cache.init()
    fake = Scripted.start(self(), @root)
    _controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "reconcile", _message, _fields}, 2_000

    {ctx, _user} = person!("brain-person")
    row = brain_row!(ctx)
    {turn, thread} = turn!(ctx)
    step = start_step!(ctx, turn, row)

    binding = %{
      ctx: ctx,
      thread_id: thread.id,
      agent: turn.agent,
      turn_id: turn.id,
      origin: turn.origin,
      fence: turn.fence,
      step: step.id,
      row_id: row.id,
      epoch: row.epoch,
      generation: thread.brain_generation,
      admits?: fn -> true end
    }

    {:ok, fake: fake, ctx: ctx, row: row, turn: turn, thread: thread, binding: binding}
  end

  defp person!(key) do
    {:ok, user} = Sanctum.Test.People.linked(%{id: key, provider: "local", verified: true})
    athanor = Sanctum.Test.People.athanor!(user)

    ctx = %{
      Sanctum.TestContext.local(:prism)
      | user_id: user.id,
        athanor_id: athanor.id,
        permissions: MapSet.new([:*])
    }

    {ctx, user}
  end

  defp brain_row!(ctx, name \\ "claude-code") do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: name,
        transport: "program",
        mark: "driven",
        url: nil,
        home: "kept",
        memory_bytes: 1_073_741_824,
        config_json:
          Jason.encode!(%{
            "command" => "cyfr-claude-code npx -y @anthropic-ai/claude-code@2.1.323",
            "env" => %{}
          })
      })

    row
  end

  defp turn!(ctx) do
    actor = Sanctum.Context.actor(ctx)
    {:ok, thread} = Arca.Test.Days.thread(actor)

    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "work on it"},
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [status: "running"]
      )

    {:ok, turn} = TurnStorage.get(actor, turn.id)
    {:ok, thread} = Arca.ThreadStorage.get(actor, thread.id)
    {turn, thread}
  end

  # The step that admitted the program's start, as the loop records and
  # decides one: the model's `program.start` of `row` at its epoch, its
  # `tool_call` row and its step written as a response's call, dispatched,
  # and allowed by a standing answer for this thread as a card writes one
  # (`Aqua.Standing.rows/5`); `allow: false` writes no answer.
  defp start_step!(ctx, turn, row, opts \\ []) do
    actor = Sanctum.Context.actor(ctx)
    {:ok, model} = TurnStorage.put_step(actor, turn.id, %{kind: "model", fence: turn.fence})

    args =
      Keyword.get(opts, :args, %{"action" => "start", "program" => row.id, "epoch" => row.epoch})

    {:ok, %{calls: [%{step: step}]}} =
      TurnStorage.record_response(actor, turn.id, model.id, %{
        fence: turn.fence,
        tool_calls: [
          %{
            tool_call_id: "call_#{System.unique_integer([:positive])}",
            name: "program",
            tool: "program",
            action: "start",
            arguments: args
          }
        ]
      })

    step =
      if Keyword.get(opts, :card) do
        step
      else
        {:ok, step} = TurnStorage.dispatch_step(actor, step.id, %{fence: turn.fence})
        step
      end

    if Keyword.get(opts, :allow, true), do: allow!(ctx, turn, row)
    step
  end

  defp start_proposal(row),
    do: %{
      "tool" => "program",
      "action" => "start",
      "args" => %{"program" => row.id, "epoch" => row.epoch}
    }

  # A standing answer to the agent's `program.start` of `row`, recorded
  # through Sanctum as the card's answer records one.
  defp allow!(ctx, turn, row, bounds \\ %{}) do
    {:ok, [grant]} = Aqua.Standing.rows(ctx, turn, start_proposal(row), :thread, bounds)
    {:ok, grant} = Sanctum.ToolGrants.put(ctx, grant)
    grant
  end

  defp no_allows!(ctx),
    do:
      Arca.Repo.delete_all(
        from(g in Arca.Schemas.ToolGrant, where: g.athanor_id == ^ctx.athanor_id)
      )

  # A card opened on a start step as the loop opens one, its intent naming
  # the proposal and the turn's sources it shows (`sources`, none by
  # default; `intent` overrides members, `:drop` removing one), answered
  # or still waiting; the waiting one's step is marked dispatched by hand,
  # which no loop does, so the approval's own state is what refuses it.
  defp carded!(ctx, turn, row, answer, opts \\ []) do
    actor = Sanctum.Context.actor(ctx)
    step = start_step!(ctx, turn, row, card: true, allow: false)
    proposal = start_proposal(row)

    intent =
      %{
        "kind" => "request_approval",
        "proposal" => proposal,
        "sources" => Prima.Source.to_json_list(Keyword.get(opts, :sources, []))
      }
      |> Map.merge(Keyword.get(opts, :intent, %{}))
      |> Map.reject(fn {_key, value} -> value == :drop end)

    {:ok, %{approval: approval}} =
      TurnStorage.open_approval(actor, step.id, %{
        proposal_digest: Aqua.Loop.Policy.proposal_digest(proposal),
        card: %{content: "program.start", payload: %{"intent" => intent}},
        fence: turn.fence
      })

    if answer == :approved do
      {:ok, _} =
        TurnStorage.resolve_approval(actor, approval.id, "approved", %{
          resolution_kind: "continue",
          fence: turn.fence
        })

      {:ok, step} = TurnStorage.dispatch_step(actor, step.id, %{fence: turn.fence})
      step
    else
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.TurnStep, where: t.id == ^step.id),
          set: [dispatch_state: "dispatched"]
        )

      step
    end
  end

  # The driver accepts the post just written, and the holder reads it.
  defp accepted!(fake, row, brain) do
    assert %{"t" => "post", "id" => id} = sent()
    say(fake, row, %{"t" => "accepted", "id" => id})
    assert {"boot-one", [{seq, %{"t" => "accepted"}}]} = batch(brain)
    :ok = Brain.read_on(brain, "boot-one", seq)
  end

  defp never!(ctx, turn, row) do
    {:ok, [grant]} = Aqua.Standing.rows(ctx, turn, start_proposal(row), :never)
    {:ok, grant} = Sanctum.ToolGrants.put(ctx, grant)
    grant
  end

  # A step written by hand, for the steps that are no decided start.
  defp bare_step!(ctx, turn, attrs \\ %{}) do
    {:ok, step} =
      TurnStorage.put_step(
        Sanctum.Context.actor(ctx),
        turn.id,
        Map.merge(
          %{
            kind: "tool",
            tool: "program",
            action: "start",
            dispatch_state: "dispatched",
            fence: turn.fence
          },
          attrs
        )
      )

    step
  end

  defp set_turn(turn, fields),
    do:
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id), set: fields)

  # The driver writes `event` into the session.
  defp say(fake, row, event) when is_map(event),
    do: Scripted.write(fake, row.id, Jason.encode!(event))

  defp say(fake, row, line) when is_binary(line), do: Scripted.write(fake, row.id, line)

  defp hello(boot \\ "boot-one"),
    do: %{"t" => "hello", "v" => 1, "driver" => "cyfr-claude-code", "boot" => boot}

  # The next batch handed to this attendant.
  defp batch({_pid, ref}) do
    assert_receive {Brain, ^ref, {:lines, boot, lines}}, 5_000
    {boot, lines}
  end

  defp sent do
    assert_receive {:session, "send", %{"lines" => [line]}, _fields}, 5_000
    Jason.decode!(line)
  end

  defp refute_sent, do: refute_received({:session, "send", _wire, _fields})

  # A held session past its hello, the hello's batch taken.
  defp opened!(fake, row, binding, boot \\ "boot-one") do
    {:ok, brain} = Brain.open(binding)
    say(fake, row, hello(boot))
    assert {^boot, [{1, %{"t" => "hello"}}]} = batch(brain)
    :ok = Brain.read_on(brain, boot, 1)
    brain
  end

  # A held session whose harness has started.
  defp started!(fake, row, binding, config \\ %{}, gen \\ 0) do
    brain = opened!(fake, row, binding)
    assert :ok = Brain.write(brain, binding, %{"t" => "start", "gen" => gen, "config" => config})
    assert %{"t" => "start"} = sent()

    say(fake, row, %{
      "t" => "started",
      "session" => "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30",
      "fresh" => true,
      "held" => []
    })

    assert {"boot-one", [{seq, %{"t" => "started"}}]} = batch(brain)
    :ok = Brain.read_on(brain, "boot-one", seq)
    brain
  end

  defp post(binding, id \\ "stp_post", work \\ nil),
    do: %{
      "t" => "post",
      "id" => id,
      "work" => work || binding.turn_id,
      "content" => [%{"type" => "text", "text" => "hi"}]
    }

  defp set_generation(thread, generation),
    do:
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^thread.id),
          set: [brain_generation: generation]
        )

  defp running_sessions(fake, row),
    do: fake |> Scripted.sessions(row.id) |> Enum.filter(fn {_id, s} -> s.running end)

  describe "a session" do
    test "a start of another generation than the binding's writes nothing", %{
      fake: fake,
      row: row,
      binding: binding
    } do
      brain = opened!(fake, row, binding, "boot-one")

      assert Brain.write(brain, binding, %{
               "t" => "start",
               "gen" => binding.generation + 1,
               "config" => %{}
             }) ==
               {:error, :not_this_generation}

      refute_sent()
    end

    test "opens a fresh run session of the driver in the row's kept folder, its hello handed first",
         %{fake: fake, row: row, binding: binding} do
      {:ok, brain} = Brain.open(binding)
      assert_receive {:session, "open", open, _fields}, 5_000
      assert %{"mode" => "run", "home_id" => home, "key" => "brain-" <> _, "argv" => []} = open
      assert home == row.id

      # Nothing is written before the driver's hello.
      assert Brain.write(brain, binding, %{"t" => "start", "gen" => 0, "config" => %{}}) ==
               {:error, :busy}

      refute_sent()

      say(fake, row, hello())
      assert {"boot-one", [{1, %{"t" => "hello", "boot" => "boot-one"}}]} = batch(brain)
    end

    test "writes one command at a time: the next only once the last is answered",
         %{fake: fake, row: row, binding: binding} do
      brain = opened!(fake, row, binding)
      assert :ok = Brain.write(brain, binding, %{"t" => "start", "gen" => 0, "config" => %{}})
      assert %{"t" => "start", "gen" => 0} = sent()
      assert Brain.write(brain, binding, post(binding)) == {:error, :busy}
      refute_sent()

      say(fake, row, %{
        "t" => "started",
        "session" => "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30",
        "fresh" => true,
        "held" => []
      })

      {_boot, [{seq, _started}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)
      assert :ok = Brain.write(brain, binding, post(binding))
      assert %{"t" => "post", "id" => "stp_post"} = sent()
      assert Brain.write(brain, binding, post(binding, "stp_second")) == {:error, :busy}
      say(fake, row, %{"t" => "accepted", "id" => "stp_post"})
      {_boot, [{seq, _accepted}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)
      assert :ok = Brain.write(brain, binding, post(binding, "stp_second"))
    end

    test "hands a batch whole and reads past it only once told", %{
      fake: fake,
      row: row,
      binding: binding
    } do
      brain = started!(fake, row, binding)

      for n <- 1..2,
          do: say(fake, row, %{"t" => "text", "gen" => 0, "message" => "m", "delta" => "#{n}"})

      {_boot, lines} = batch(brain)
      last = lines |> List.last() |> elem(0)
      say(fake, row, %{"t" => "text", "gen" => 0, "message" => "m", "delta" => "after"})
      refute_receive {Brain, _ref, {:lines, _boot, _lines}}, 300

      :ok = Brain.read_on(brain, "boot-one", last)
      assert {_boot, [{_seq, %{"delta" => "after"}}]} = batch(brain)
    end

    test "re-hands what the attendant did not commit, keeping each line's effect once",
         %{fake: fake, row: row, binding: binding} do
      brain = started!(fake, row, binding)

      ask = %{
        "t" => "ask",
        "gen" => 0,
        "work" => binding.turn_id,
        "ask" => "ask-1",
        "name" => "files",
        "arguments" => %{}
      }

      say(fake, row, ask)
      {_boot, [{ask_seq, _ask}]} = batch(brain)

      # The attendant committed only what came before the ask: it is handed again.
      :ok = Brain.read_on(brain, "boot-one", ask_seq - 1)
      assert {_boot, [{^ask_seq, %{"t" => "ask"}}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", ask_seq)

      answer = %{
        "t" => "answer",
        "id" => "stp_answer",
        "ask" => "ask-1",
        "content" => "done",
        "is_error" => false
      }

      assert :ok = Brain.write(brain, binding, answer)
      assert %{"t" => "answer"} = sent()
      say(fake, row, %{"t" => "accepted", "id" => "stp_answer"})
      {_boot, [{seq, _}]} = batch(brain)

      # What the attendant committed is never handed again, and an answered
      # ask is not answerable again.
      :ok = Brain.read_on(brain, "boot-one", ask_seq - 1)
      {_boot, _again} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)

      assert Brain.write(brain, binding, %{answer | "id" => "stp_twice"}) ==
               {:error, :not_this_work}
    end

    test "a work whose configuration differs closes the driver's process and opens a new one",
         %{fake: fake, row: row, binding: binding} do
      brain =
        started!(fake, row, binding, %{"model" => "opus", "harness_tools" => ["Read", "Grep"]})

      [{first, _}] = running_sessions(fake, row)
      work = %{"t" => "work", "id" => "stp_work", "work" => binding.turn_id, "tools" => []}

      assert :ok =
               Brain.write(brain, binding, work,
                 config: %{"model" => "opus", "harness_tools" => ["Read", "Grep"]}
               )

      assert %{"t" => "work"} = sent()
      say(fake, row, %{"t" => "accepted", "id" => "stp_work"})
      {_boot, [{seq, _}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)

      # A narrower set of the harness's own tools: nothing of the work is
      # written, the process is started again.
      assert {:ok, :restarted} =
               Brain.write(brain, binding, %{work | "id" => "stp_next"},
                 config: %{"model" => "opus", "harness_tools" => ["Read"]}
               )

      refute_sent()
      assert [{second, _}] = running_sessions(fake, row)
      assert second != first
      say(fake, row, hello("boot-two"))
      assert {"boot-two", [{1, %{"t" => "hello"}}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-two", 1)

      resume = %{
        "t" => "start",
        "gen" => 0,
        "session" => "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30",
        "config" => %{"model" => "opus", "harness_tools" => ["Read"]}
      }

      assert :ok = Brain.write(brain, binding, resume)
      assert %{"t" => "start", "session" => _} = sent()
    end
  end

  describe "the binding to admitted work" do
    setup %{fake: fake, row: row, binding: binding} do
      {:ok, brain: started!(fake, row, binding)}
    end

    test "a binding that proves the running turn writes", %{brain: brain, binding: binding} do
      assert :ok = Brain.write(brain, binding, post(binding))
      assert %{"t" => "post"} = sent()
    end

    test "another athanor, person, thread, row or epoch writes nothing",
         %{brain: brain, binding: binding, ctx: ctx} do
      {other_ctx, _} = person!("brain-other-person")
      other_row = brain_row!(ctx, "another-brain")

      for {binding, reason} <- [
            {%{binding | ctx: other_ctx}, :wrong_place},
            # A person of another athanor does not stand in this one.
            {%{binding | ctx: %{ctx | user_id: elem(person!("brain-third"), 0).user_id}},
             :not_standing},
            {%{binding | row_id: other_row.id}, :wrong_place},
            {%{binding | epoch: binding.epoch + 1}, :wrong_place},
            {%{binding | thread_id: "thr_other"}, :wrong_place}
          ] do
        assert Brain.write(brain, binding, post(binding)) == {:error, {:not_admitted, reason}}
      end

      refute_sent()
    end

    test "a turn another person asked for writes nothing", %{
      brain: brain,
      binding: binding,
      turn: turn
    } do
      set_turn(turn, requested_by: "usr_another")

      assert Brain.write(brain, binding, post(binding)) ==
               {:error, {:not_admitted, :wrong_person}}

      refute_sent()
    end

    test "a turn of another origin writes nothing", %{brain: brain, binding: binding} do
      assert Brain.write(brain, %{binding | origin: "scheduled"}, post(binding)) ==
               {:error, {:not_admitted, :wrong_origin}}

      refute_sent()
    end

    test "a stopped turn's start writes nothing", %{
      brain: brain,
      binding: binding,
      ctx: ctx,
      turn: turn
    } do
      {:ok, _turn} =
        TurnStorage.supersede(Sanctum.Context.actor(ctx), turn.id, %{fence: turn.fence})

      {:ok, stopped} = TurnStorage.get(Sanctum.Context.actor(ctx), turn.id)

      assert Brain.write(brain, %{binding | fence: stopped.fence}, post(binding)) ==
               {:error, {:not_admitted, :stopped}}

      refute_sent()
    end

    test "a changed row epoch writes nothing", %{brain: brain, binding: binding, row: row} do
      {1, _} =
        Arca.Repo.update_all(from(r in Arca.Schemas.McpServer, where: r.id == ^row.id),
          inc: [epoch: 1]
        )

      assert Brain.write(brain, binding, post(binding)) == {:error, {:not_admitted, :row_changed}}
      refute_sent()
    end

    test "a disabled row writes nothing", %{brain: brain, binding: binding, row: row} do
      {1, _} =
        Arca.Repo.update_all(from(r in Arca.Schemas.McpServer, where: r.id == ^row.id),
          set: [enabled: false]
        )

      assert Brain.write(brain, binding, post(binding)) == {:error, {:not_admitted, :disabled}}
      refute_sent()
    end

    test "a stale turn fence writes nothing", %{brain: brain, binding: binding, turn: turn} do
      set_turn(turn, fence: turn.fence + 1)
      assert Brain.write(brain, binding, post(binding)) == {:error, {:not_admitted, :superseded}}
      refute_sent()
    end

    test "a moved session generation writes nothing", %{
      brain: brain,
      binding: binding,
      thread: thread
    } do
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^thread.id),
          inc: [brain_generation: 1]
        )

      assert Brain.write(brain, binding, post(binding)) ==
               {:error, {:not_admitted, :generation_moved}}

      refute_sent()
    end

    test "a standing never recorded after the start writes nothing", %{
      brain: brain,
      binding: binding,
      ctx: ctx,
      turn: turn,
      row: row
    } do
      never!(ctx, turn, row)
      assert Brain.write(brain, binding, post(binding)) == {:error, {:not_admitted, :denied}}
      refute_sent()
    end

    test "an allow past its deadline writes nothing", %{
      brain: brain,
      binding: binding,
      ctx: ctx
    } do
      {1, _} =
        Arca.Repo.update_all(
          from(g in Arca.Schemas.ToolGrant, where: g.athanor_id == ^ctx.athanor_id),
          set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
        )

      assert Brain.write(brain, binding, post(binding)) == {:error, {:not_admitted, :withdrawn}}
      refute_sent()
    end

    test "an allow that names none of the turn's outside sources writes nothing", %{
      brain: brain,
      binding: binding,
      turn: turn
    } do
      set_turn(turn, sources: Prima.Source.encode([Prima.Source.outside("the web")]))
      assert Brain.write(brain, binding, post(binding)) == {:error, {:not_admitted, :withdrawn}}
      refute_sent()
    end

    test "a step whose call started another program, or this one at another epoch, writes nothing",
         %{brain: brain, binding: binding, ctx: ctx, turn: turn, row: row} do
      other = brain_row!(ctx, "another")

      for args <- [
            %{"action" => "start", "program" => other.id, "epoch" => other.epoch},
            %{"action" => "start", "program" => row.id, "epoch" => row.epoch + 1}
          ] do
        step = start_step!(ctx, turn, row, args: args)

        assert Brain.write(brain, %{binding | step: step.id}, post(binding)) ==
                 {:error, {:not_admitted, :not_this_program}}
      end

      refute_sent()
    end

    test "a start the person allowed on its card writes, until a standing never; one not approved writes nothing",
         %{fake: fake, brain: brain, binding: binding, ctx: ctx, turn: turn, row: row} do
      no_allows!(ctx)
      assert Brain.write(brain, binding, post(binding)) == {:error, {:not_admitted, :withdrawn}}

      approved = carded!(ctx, turn, row, :approved)
      waiting = carded!(ctx, turn, row, :waiting)

      assert Brain.write(brain, %{binding | step: waiting.id}, post(binding)) ==
               {:error, {:not_admitted, :not_allowed}}

      refute_sent()

      assert :ok = Brain.write(brain, %{binding | step: approved.id}, post(binding))
      accepted!(fake, row, brain)

      never!(ctx, turn, row)

      assert Brain.write(brain, %{binding | step: approved.id}, post(binding, "stp_post_2")) ==
               {:error, {:not_admitted, :denied}}

      refute_sent()
    end

    # #8321's first finding: a card covers the outside sources it showed
    # and no other, since the session takes the posts and results of later
    # writes; a card whose sources cannot be read covers none.
    test "a start the person allowed on its card writes only while the turn's outside sources are ones the card showed",
         %{fake: fake, brain: brain, binding: binding, ctx: ctx, turn: turn, row: row} do
      no_allows!(ctx)
      web = Prima.Source.outside("the web")
      approved = carded!(ctx, turn, row, :approved, sources: [web])
      binding = %{binding | step: approved.id}

      assert :ok = Brain.write(brain, binding, post(binding))
      accepted!(fake, row, brain)

      set_turn(turn, sources: Prima.Source.encode([web]))
      assert :ok = Brain.write(brain, binding, post(binding, "stp_post_2"))
      accepted!(fake, row, brain)

      set_turn(turn, sources: Prima.Source.encode([web, Prima.Source.outside("mail")]))

      assert Brain.write(brain, binding, post(binding, "stp_post_3")) ==
               {:error, {:not_admitted, :source_not_covered}}

      refute_sent()
    end

    test "a card whose shown sources cannot be read covers nothing", %{
      brain: brain,
      binding: binding,
      ctx: ctx,
      turn: turn,
      row: row
    } do
      no_allows!(ctx)

      for intent <- [%{"sources" => :drop}, %{"sources" => "[]"}, %{"sources" => ["the web"]}] do
        step = carded!(ctx, turn, row, :approved, intent: intent)

        assert Brain.write(brain, %{binding | step: step.id}, post(binding)) ==
                 {:error, {:not_admitted, :coverage_unreadable}}
      end

      refute_sent()
    end

    test "the attendant's veto writes nothing, whatever the stored decision says", %{
      brain: brain,
      binding: binding
    } do
      assert Brain.write(brain, %{binding | admits?: fn -> false end}, post(binding)) ==
               {:error, {:not_admitted, :vetoed}}

      refute_sent()
    end

    test "a step that is not the turn's decided program.start writes nothing",
         %{brain: brain, binding: binding, ctx: ctx, turn: turn} do
      proposed = bare_step!(ctx, turn, %{dispatch_state: "proposed"})
      other = bare_step!(ctx, turn, %{tool: "files", action: "read"})
      {:ok, %{turn: elsewhere}} = elsewhere_turn(ctx)
      foreign = bare_step!(ctx, elsewhere)
      unrecorded = bare_step!(ctx, turn)

      for {step, reason} <- [
            {proposed.id, :not_decided},
            {other.id, :wrong_step},
            {foreign.id, :wrong_step},
            {unrecorded.id, :wrong_step},
            {"stp_none", :step_not_found}
          ] do
        assert Brain.write(brain, %{binding | step: step}, post(binding)) ==
                 {:error, {:not_admitted, reason}}
      end

      refute_sent()
    end

    test "a person who no longer stands writes nothing", %{
      brain: brain,
      binding: binding,
      ctx: ctx
    } do
      {1, _} =
        Arca.Repo.update_all(from(a in Arca.Schemas.Athanor, where: a.id == ^ctx.athanor_id),
          set: [status: "archived"]
        )

      assert Brain.write(brain, binding, post(binding)) ==
               {:error, {:not_admitted, :not_standing}}

      refute_sent()
    end

    test "a post of another work, or an answer to an ask of another work, writes nothing",
         %{brain: brain, binding: binding, fake: fake, row: row} do
      assert Brain.write(brain, binding, post(binding, "stp_post", "trn_other")) ==
               {:error, :not_this_work}

      say(fake, row, %{
        "t" => "ask",
        "gen" => 0,
        "work" => "trn_other",
        "ask" => "ask-other",
        "name" => "files",
        "arguments" => %{}
      })

      say(fake, row, %{
        "t" => "ask",
        "gen" => 0,
        "ask" => "ask-none",
        "name" => "files",
        "arguments" => %{}
      })

      {_boot, lines} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", lines |> List.last() |> elem(0))

      for ask <- ["ask-other", "ask-none", "ask-never-shown"] do
        answer = %{
          "t" => "answer",
          "id" => "stp_a",
          "ask" => ask,
          "content" => "x",
          "is_error" => false
        }

        assert Brain.write(brain, binding, answer) == {:error, :not_this_work}
      end

      refute_sent()
    end
  end

  describe "a paused turn's narrow proof" do
    test "delivers a post or an answer of its own work, and starts nothing",
         %{fake: fake, row: row, binding: binding, turn: turn} do
      brain = started!(fake, row, binding)

      say(fake, row, %{
        "t" => "ask",
        "gen" => 0,
        "work" => binding.turn_id,
        "ask" => "ask-1",
        "name" => "files",
        "arguments" => %{}
      })

      {_boot, [{seq, _}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)
      set_turn(turn, status: "paused", paused_reason: "approval")

      work = %{"t" => "work", "id" => "stp_work", "work" => binding.turn_id, "tools" => []}
      assert Brain.write(brain, binding, work) == {:error, {:not_admitted, :paused}}
      refute_sent()

      assert :ok = Brain.write(brain, binding, post(binding))
      assert %{"t" => "post"} = sent()
      say(fake, row, %{"t" => "accepted", "id" => "stp_post"})
      {_boot, [{seq, _}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)

      answer = %{
        "t" => "answer",
        "id" => "stp_answer",
        "ask" => "ask-1",
        "content" => "x",
        "is_error" => false
      }

      assert :ok = Brain.write(brain, binding, answer)
      assert %{"t" => "answer"} = sent()
    end

    test "opens nothing: a paused turn starts no driver", %{binding: binding, turn: turn} do
      set_turn(turn, status: "paused", paused_reason: "approval")
      assert Brain.open(binding) == {:error, {:not_admitted, :paused}}
      refute_received {:session, "open", _wire, _fields}
    end

    test "revocation and a take-over end it", %{
      fake: fake,
      row: row,
      binding: binding,
      ctx: ctx,
      turn: turn
    } do
      brain = started!(fake, row, binding)
      set_turn(turn, status: "paused", paused_reason: "approval")
      never!(ctx, turn, row)

      assert Brain.write(brain, binding, post(binding)) == {:error, {:not_admitted, :denied}}

      set_turn(turn, fence: turn.fence + 1)
      assert Brain.write(brain, binding, post(binding)) == {:error, {:not_admitted, :superseded}}
      refute_sent()
    end
  end

  describe "its end" do
    setup %{fake: fake, row: row, binding: binding} do
      {:ok, brain: started!(fake, row, binding)}
    end

    test "a line that does not read ends it and closes its session", %{
      fake: fake,
      row: row,
      brain: {pid, ref} = _brain
    } do
      monitor = Process.monitor(pid)
      say(fake, row, "Welcome to Claude Code")
      assert_receive {Brain, ^ref, {:ended, :unreadable}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
      assert running_sessions(fake, row) == []
    end

    for {name, line} <- [
          {"an unknown message", ~s({"t":"shell","cmd":"rm -rf /"})},
          {"a command from the driver", ~s({"t":"post","id":"p","work":"w","content":[]})},
          {"a second hello", ~s({"t":"hello","v":1,"driver":"d","boot":"b"})},
          {"a member beyond its message's", ~s({"t":"accepted","id":"p","thread":"thr_other"})}
        ] do
      test "#{name} ends it", %{fake: fake, row: row, brain: {_pid, ref}} do
        say(fake, row, unquote(line))
        assert_receive {Brain, ^ref, {:ended, :unreadable}}, 5_000
      end
    end

    test "a line lost unread ends it", %{fake: fake, row: row, brain: {_pid, ref}} do
      Scripted.set(fake, :dropped, 2)
      say(fake, row, %{"t" => "text", "gen" => 0, "message" => "m", "delta" => "x"})
      assert_receive {Brain, ^ref, {:ended, :dropped}}, 5_000
    end

    test "the row's change ends it", %{ctx: ctx, row: row, brain: {_pid, ref}} do
      :ok = Opus.Programs.end_mounts(ctx.athanor_id, row.id)
      assert_receive {Brain, ^ref, {:ended, :row_changed}}, 5_000
    end

    test "being told ends it, its session closed", %{
      fake: fake,
      row: row,
      brain: {_pid, ref} = brain
    } do
      :ok = Brain.close(brain)
      assert_receive {Brain, ^ref, {:ended, :closed}}, 5_000
      assert running_sessions(fake, row) == []
    end

    test "the attendant's exit ends it, its session closed", %{
      fake: fake,
      row: row,
      binding: binding
    } do
      test = self()

      attendant =
        spawn(fn ->
          {:ok, {pid, _ref}} = Brain.open(%{binding | fence: binding.fence})
          send(test, {:holder, pid})
          receive do: (:never -> :ok)
        end)

      # The test's own holder is replaced by the attendant's.
      assert_receive {:holder, pid}, 5_000
      monitor = Process.monitor(pid)
      Process.exit(attendant, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
      assert running_sessions(fake, row) == []
    end
  end

  describe "a crash or a loss with a tool result outstanding" do
    setup %{fake: fake, row: row, binding: binding} do
      brain = started!(fake, row, binding)

      say(fake, row, %{
        "t" => "ask",
        "gen" => 0,
        "work" => binding.turn_id,
        "ask" => "ask-1",
        "name" => "files",
        "arguments" => %{}
      })

      {_boot, [{seq, _}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)

      {:ok,
       brain: brain,
       answer: %{
         "t" => "answer",
         "id" => "stp_answer",
         "ask" => "ask-1",
         "content" => "x",
         "is_error" => false
       }}
    end

    test "a write whose answer is lost is uncertain, ends the session and is never written again",
         %{fake: fake, row: row, binding: binding, brain: {_pid, ref} = brain, answer: answer} do
      Scripted.set(fake, :reset_send, true)
      assert Brain.write(brain, binding, answer) == {:error, :uncertain}
      assert_receive {:session, "send", %{"lines" => [_line]}, _fields}, 5_000
      assert_receive {Brain, ^ref, {:ended, :interrupted}}, 5_000
      assert running_sessions(fake, row) == []
      assert Brain.write(brain, binding, answer) == {:error, :unavailable}
      refute_sent()
    end

    test "the driver's death ends the session; nothing more is written",
         %{fake: fake, row: row, binding: binding, brain: {_pid, ref} = brain, answer: answer} do
      Scripted.end_sessions(fake, row.id)
      assert_receive {Brain, ^ref, {:ended, :exited}}, 5_000
      assert Brain.write(brain, binding, answer) == {:error, :unavailable}
      refute_sent()
    end

    test "the holder's death closes its session, and the next opens a driver that has heard nothing",
         %{fake: fake, row: row, binding: binding, brain: {pid, _ref}} do
      [{first, _}] = running_sessions(fake, row)
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
      # Killed outright, it closes nothing itself: the box closes what a
      # holder leaves, and a new holder opens afresh in any case.
      {:ok, _brain} = Brain.open(binding)
      assert_receive {:session, "open", _open, _fields}, 5_000
      assert [{second, _}] = running_sessions(fake, row)
      assert second != first
    end

    test "a take-over ends the old holder and stops its writes",
         %{
           fake: fake,
           row: row,
           binding: binding,
           turn: turn,
           brain: {old, ref} = brain,
           answer: answer
         } do
      # A successor raises the turn's fence as it takes the turn over.
      taken = %{fence: turn.fence + 1}
      set_turn(turn, fence: taken.fence)
      assert Brain.write(brain, binding, answer) == {:error, {:not_admitted, :superseded}}
      refute_sent()

      monitor = Process.monitor(old)
      {:ok, _new} = Brain.open(%{binding | fence: taken.fence})
      assert_receive {Brain, ^ref, {:ended, :replaced}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^old, _}, 5_000
      assert [{_one, _}] = running_sessions(fake, row)
    end
  end

  describe "a take-over" do
    # The ordering of #8138's second finding: the first open waits in its
    # binding's last callback, the turn's fence moves, the successor opens,
    # and only then is the first let go.
    test "a stale open paused in a wait is refused, and the successor it raced lives",
         %{binding: binding, turn: turn} do
      test = self()
      first = :atomics.new(1, [])

      stale = %{
        binding
        | admits?: fn ->
            if :atomics.add_get(first, 1, 1) == 1 do
              send(test, {:paused, self()})
              receive do: (:go -> :ok)
            end

            true
          end
      }

      opening = Task.async(fn -> Brain.open(stale) end)
      assert_receive {:paused, waiter}, 5_000

      set_turn(turn, fence: turn.fence + 1)

      successor =
        spawn_link(fn ->
          send(test, {:successor, Brain.open(%{binding | fence: turn.fence + 1})})
          receive do: (:done -> :ok)
        end)

      send(waiter, :go)
      assert Task.await(opening, 10_000) == {:error, {:not_admitted, :superseded}}
      assert_receive {:successor, {:ok, {holder, _ref}}}, 10_000
      assert Process.alive?(holder)
      assert Brain.whereis(binding.ctx.athanor_id, binding.thread_id, binding.agent) == holder
      send(successor, :done)
    end

    test "a binding that goes stale while the driver's session opens opens nothing, its session closed",
         %{fake: fake, row: row, binding: binding, turn: turn} do
      Scripted.hold(fake, "opened")
      opening = Task.async(fn -> Brain.open(binding) end)
      assert_receive {:held, "opened", service}, 5_000
      holder = Brain.whereis(binding.ctx.athanor_id, binding.thread_id, binding.agent)
      monitor = Process.monitor(holder)

      set_turn(turn, fence: turn.fence + 1)
      send(service, :go)

      assert Task.await(opening, 10_000) == {:error, {:not_admitted, :superseded}}
      assert_receive {:DOWN, ^monitor, :process, ^holder, _reason}, 5_000
      assert running_sessions(fake, row) == []
    end

    test "a stale open ends no holder: the successor's session stays",
         %{binding: binding, turn: turn} do
      set_turn(turn, fence: turn.fence + 1)
      {:ok, {holder, ref}} = Brain.open(%{binding | fence: turn.fence + 1})

      assert Brain.open(binding) == {:error, {:not_admitted, :superseded}}
      assert Process.alive?(holder)
      refute_received {Brain, ^ref, {:ended, _reason}}
    end
  end

  describe "two paths no turn admits" do
    @session "1b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"

    # A removal owed for `thread`'s session on `row`, as a forgetting
    # transaction records one.
    defp owed!(ctx, thread_id, row, opts \\ []) do
      record =
        Prima.OutboxRecord.brain_forget(%{
          athanor_id: ctx.athanor_id,
          thread_id: thread_id,
          agent: Keyword.get(opts, :agent, "aqua"),
          row_id: row.id,
          session: Keyword.get(opts, :session, @session),
          generation: Keyword.get(opts, :generation, 0)
        })

      {:ok, :ok} =
        Arca.Repo.transaction(fn -> Arca.Outbox.put!(Sanctum.Context.actor(ctx), record) end)

      record
    end

    # The driver of a once-holder: its session opened, its hello written,
    # the one command it is sent read back.
    defp once_driver!(fake, row) do
      assert_receive {:session, "open", %{"mode" => "run", "home_id" => home}, _fields}, 5_000
      assert home == row.id
      first_read!()
      say(fake, row, hello())
      sent()
    end

    # The session stands once its first read arrives: a line written
    # before then has no session to land in.
    defp first_read!,
      do: assert_receive({:session, "recv", %{"after" => 0}, _fields}, 5_000)

    # The reads an earlier holder made, told already.
    defp flush_reads do
      receive do
        {:session, "recv", _read, _fields} -> flush_reads()
      after
        0 -> :ok
      end
    end

    test "cleanup forgets the session the stored record names and nothing else",
         %{fake: fake, ctx: ctx, row: row, thread: thread} do
      record = owed!(ctx, thread.id, row)
      task = Task.async(fn -> Brain.forget(record) end)

      assert %{"t" => "forget", "id" => "obx_" <> _ = id, "session" => @session} =
               forget = once_driver!(fake, row)

      assert Map.keys(forget) == ["id", "session", "t"]
      say(fake, row, %{"t" => "forgot", "id" => id, "session" => @session})
      assert Task.await(task, 10_000) == :forgot
      refute_sent()
      assert running_sessions(fake, row) == []

      # Every try of one record names the same id.
      again = Task.async(fn -> Brain.forget(record) end)
      assert %{"id" => ^id} = once_driver!(fake, row)
      say(fake, row, %{"t" => "forgot", "id" => id, "session" => @session})
      assert Task.await(again, 10_000) == :forgot
    end

    test "cleanup takes no answer but forgot of that id and session as a removal",
         %{fake: fake, ctx: ctx, row: row, thread: thread} do
      record = owed!(ctx, thread.id, row)

      for {answer, expected} <- [
            {fn id -> %{"t" => "refused", "id" => id, "reason" => "cannot look"} end,
             {:error, {:refused, "cannot look"}}},
            {fn id ->
               %{"t" => "forgot", "id" => id, "session" => "2b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"}
             end, {:error, :unreadable}},
            {fn _id -> %{"t" => "forgot", "id" => "obx_other", "session" => @session} end,
             {:error, :unreadable}}
          ] do
        task = Task.async(fn -> Brain.forget(record) end)
        %{"id" => id} = once_driver!(fake, row)
        say(fake, row, answer.(id))
        assert Task.await(task, 10_000) == expected
        assert running_sessions(fake, row) == []
      end
    end

    test "a lost answer, a box away and a write that may have landed are no removal",
         %{fake: fake, ctx: ctx, row: row, thread: thread} do
      record = owed!(ctx, thread.id, row)

      task = Task.async(fn -> Brain.forget(record) end)
      _forget = once_driver!(fake, row)
      Scripted.end_sessions(fake, row.id)
      assert Task.await(task, 10_000) == {:error, :lost}

      Scripted.set(fake, :reset_send, true)
      task = Task.async(fn -> Brain.forget(record) end)
      assert_receive {:session, "open", _open, _fields}, 5_000
      first_read!()
      say(fake, row, hello())
      assert Task.await(task, 70_000) == {:error, :lost}

      Scripted.down(fake)
      assert {:error, _away} = Brain.forget(record)
      Scripted.up(fake)
    end

    test "cleanup acts only on a record still owed to the consumer",
         %{fake: fake, ctx: ctx, row: row, thread: thread} do
      # One the caller made up, never stored.
      made_up =
        Prima.OutboxRecord.brain_forget(%{
          athanor_id: ctx.athanor_id,
          thread_id: thread.id,
          agent: "aqua",
          row_id: row.id,
          session: @session,
          generation: 0
        })

      assert Brain.forget(made_up) == {:error, :not_owed}

      # A stored one whose copy names another session: the stored one is
      # what is forgotten.
      stored = owed!(ctx, thread.id, row)
      altered = put_in(stored.snapshot["session"], "2b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30")
      task = Task.async(fn -> Brain.forget(altered) end)
      assert %{"session" => @session, "id" => id} = once_driver!(fake, row)
      say(fake, row, %{"t" => "forgot", "id" => id, "session" => @session})
      assert Task.await(task, 10_000) == :forgot

      # One receipted is owed no more.
      {:ok, claim} = Arca.JobClaims.claim("brain_cleanup", ctx.athanor_id, "boot_test", 60_000)

      :ok =
        Arca.ConsumerReceipts.record(
          Sanctum.Context.actor(ctx),
          claim,
          :none,
          Map.merge(Prima.OutboxRecord.source(stored), %{
            consumer: "brain_cleanup",
            outcome: "applied"
          })
        )

      assert Brain.forget(stored) == {:error, :not_owed}
      refute_received {:session, "open", _open, _fields}
    end

    test "a thread holding the record's session again is a successor's, never removed",
         %{ctx: ctx, row: row, thread: thread} do
      record = owed!(ctx, thread.id, row)

      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^thread.id),
          set: [brain_session: @session, brain_generation: 1]
        )

      assert Brain.forget(record) == {:error, :successor}
      refute_received {:session, "open", _open, _fields}
    end

    test "a row gone, one that runs no driver, another program and a disabled row open nothing",
         %{ctx: ctx, row: row, thread: thread} do
      actor = Sanctum.Context.actor(ctx)
      bare = brain_row!(ctx, "claude-code-bare")

      {1, _} =
        Arca.Repo.update_all(from(r in Arca.Schemas.McpServer, where: r.id == ^bare.id),
          set: [
            config_json:
              Jason.encode!(%{
                "command" => "npx -y @anthropic-ai/claude-code@2.1.323",
                "env" => %{}
              })
          ]
        )

      scratch = brain_row!(ctx, "claude-code-scratch")

      {1, _} =
        Arca.Repo.update_all(from(r in Arca.Schemas.McpServer, where: r.id == ^scratch.id),
          set: [home: "scratch"]
        )

      off = brain_row!(ctx, "claude-code-off")

      {1, _} =
        Arca.Repo.update_all(from(r in Arca.Schemas.McpServer, where: r.id == ^off.id),
          set: [enabled: false]
        )

      gone = brain_row!(ctx, "claude-code-gone")
      {1, _} = Arca.Repo.delete_all(from(r in Arca.Schemas.McpServer, where: r.id == ^gone.id))

      for {target, expected} <- [
            {bare, {:error, :no_driver}},
            {scratch, {:error, :not_a_brain_row}},
            {off, {:error, :disabled}},
            {gone, {:error, :row_gone}}
          ] do
        record = owed!(ctx, "thr_#{target.name}", target)
        assert Brain.forget(record) == expected
      end

      refute_received {:session, "open", _open, _fields}
      assert {:ok, %{}} = Arca.McpServerStorage.get_by_id(actor, row.id)
      _ = thread
    end

    test "cleanup ends a holder of the record's generation first, and waits for a successor's",
         %{fake: fake, ctx: ctx, row: row, binding: binding, thread: thread} do
      {_pid, ref} = started!(fake, row, binding)
      [{old, %{running: true}}] = running_sessions(fake, row)
      record = owed!(ctx, thread.id, row, generation: binding.generation)
      flush_reads()
      task = Task.async(fn -> Brain.forget(record) end)

      # The old holder ends, and its session closes, before the cleanup's
      # own process of the driver opens under the same key.
      assert_receive {Brain, ^ref, {:ended, :forgotten}}, 5_000
      assert_receive {:session, "close", %{"session" => ^old}, _fields}, 5_000
      assert_receive {:session, "open", %{"key" => "brain-" <> _}, _fields}, 5_000
      refute Scripted.sessions(fake, row.id)[old].running
      first_read!()
      say(fake, row, hello())
      assert %{"t" => "forget", "id" => id} = sent()
      say(fake, row, %{"t" => "forgot", "id" => id, "session" => @session})
      assert Task.await(task, 10_000) == :forgot

      # A holder of a later generation is a successor's: it runs on, and
      # the removal waits.
      set_generation(thread, binding.generation + 1)
      {:ok, {pid, ref}} = Brain.open(%{binding | generation: binding.generation + 1})
      assert Brain.forget(record) == {:error, :busy}
      assert Process.alive?(pid)
      refute_received {Brain, ^ref, {:ended, _reason}}
    end

    test "a forgetting closes at once the holders of the sessions it owed, a successor's apart",
         %{fake: fake, ctx: ctx, row: row, binding: binding, thread: thread} do
      set_generation(thread, 1)
      binding = %{binding | generation: 1}
      {pid, ref} = started!(fake, row, binding, %{}, 1)
      older = %{thread_id: thread.id, agent: binding.agent, generation: 0}
      assert :ok = Brain.forgotten(ctx.athanor_id, [older])
      assert Process.alive?(pid)
      refute_received {Brain, ^ref, {:ended, _reason}}

      owed = %{thread_id: thread.id, agent: binding.agent, generation: 1}
      assert :ok = Brain.forgotten(ctx.athanor_id, [owed])
      assert_receive {Brain, ^ref, {:ended, :forgotten}}, 5_000
      assert_receive {:session, "close", _close, _fields}, 5_000
      refute Process.alive?(pid)
    end

    test "no binding writes a models or a forget, however its turn stands",
         %{fake: fake, row: row, binding: binding} do
      brain = opened!(fake, row, binding)

      for command <- [
            %{"t" => "models", "id" => "mdl_1"},
            %{"t" => "forget", "id" => "obx_1", "session" => @session}
          ] do
        assert Brain.write(brain, binding, command) == {:error, :not_a_delivery}
      end

      brain = started!(fake, row, binding)

      for command <- [
            %{"t" => "models", "id" => "mdl_2"},
            %{"t" => "forget", "id" => "obx_2", "session" => @session}
          ] do
        assert Brain.write(brain, binding, command) == {:error, :not_a_delivery}
      end

      refute_sent()
    end

    test "discovery lists the harness's models for a person at a screen",
         %{fake: fake, ctx: ctx, row: row} do
      task = Task.async(fn -> Brain.models(ctx, row.id) end)
      assert %{"t" => "models", "id" => "mdl_" <> _ = id} = models = once_driver!(fake, row)
      assert Map.keys(models) == ["id", "t"]

      say(fake, row, %{
        "t" => "models",
        "id" => id,
        "models" => [%{"id" => "opus", "name" => "Opus"}, %{"id" => "haiku", "name" => "Haiku"}],
        "efforts" => ["low", "high"]
      })

      assert Task.await(task, 10_000) ==
               {:ok,
                %{
                  models: [%{id: "opus", name: "Opus"}, %{id: "haiku", name: "Haiku"}],
                  efforts: ["low", "high"]
                }}

      assert running_sessions(fake, row) == []

      task = Task.async(fn -> Brain.models(ctx, row.id) end)
      %{"id" => id} = once_driver!(fake, row)
      say(fake, row, %{"t" => "refused", "id" => id, "reason" => "not listed"})
      assert Task.await(task, 10_000) == {:error, {:refused, "not listed"}}
    end

    test "discovery runs for no turn, no other athanor and no row but a brain's",
         %{ctx: ctx, row: row} do
      # A call in a turn's chain, as the gate hands a provider one.
      assert Brain.models(Sanctum.Context.enter_guest(ctx), row.id) == {:error, :not_interactive}

      {other, _user} = person!("brain-other")
      theirs = brain_row!(other, "claude-code-theirs")
      assert Brain.models(ctx, theirs.id) == {:error, :row_not_found}

      {1, _} =
        Arca.Repo.update_all(from(r in Arca.Schemas.McpServer, where: r.id == ^row.id),
          set: [
            config_json:
              Jason.encode!(%{
                "command" => "npx -y @anthropic-ai/claude-code@2.1.323",
                "env" => %{}
              })
          ]
        )

      assert Brain.models(ctx, row.id) == {:error, :no_driver}
      refute_received {:session, "open", _open, _fields}
    end
  end

  test "nothing the person posts, the program says or the grant holds shows in its status",
       %{fake: fake, row: row, binding: binding} do
    {pid, _ref} = brain = started!(fake, row, binding)
    secret = "SECRET-POST-WORDS"

    assert :ok =
             Brain.write(brain, binding, %{
               post(binding)
               | "content" => [%{"type" => "text", "text" => secret}]
             })

    _ = sent()
    status = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)
    refute status =~ secret

    {:ok, grant} =
      Opus.Programs.hold(%{
        athanor_id: binding.ctx.athanor_id,
        server_id: row.id,
        epoch: row.epoch
      })

    refute status =~ Base.encode16(grant.owner_key)
    refute status =~ inspect(grant.owner_key)
  end

  defp elsewhere_turn(ctx) do
    actor = Sanctum.Context.actor(ctx)
    {:ok, thread} = Arca.Test.Days.thread(actor)

    result =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "elsewhere"},
        turn: %{agent: "aqua", requested_by: ctx.user_id, origin: :interactive}
      })

    with {:ok, %{turn: turn}} <- result do
      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
          set: [status: "running"]
        )

      {:ok, %{turn: %{turn | status: "running"}}}
    end
  end
end
