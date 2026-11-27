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
  that row and epoch, one closed denied or skipped, and a turn that is
  not running; a paused turn's
  proof writes a post or an answer of its own work and nothing else; a
  stale open ends no successor. A start writes the caller's configuration
  unchanged, the member's access among it, and a work is written to the
  process that started. A line that does not read, one past the bound, one lost
  unread, a read the box refuses, the row's change, the driver's end, a
  lost answer to a write and a take-over each end the session, its box
  session closed. A holder of one command ends as well on its caller's
  exit, shutdown and its deadline, and on each end its session is closed
  and its owner and claim are given back.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Prima.Test.Wait

  alias Arca.TurnStorage
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Opus.Brain
  alias Opus.Brain.Wire

  @root :crypto.strong_rand_bytes(32)

  @listing %{
    models: [
      %{id: "opus", name: "Opus", efforts: ["low", "high"]},
      %{id: "haiku", name: "Haiku", efforts: []}
    ],
    access: [%{id: "default", name: "Default mode"}]
  }

  setup tags do
    Cyfr.Test.Sandbox.setup!(Map.take(tags, [:ownership_timeout]))
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

    # Running, as a start leaves it (`TurnStorage.start/3`).
    set_turn(turn, status: "running")
    {:ok, turn} = TurnStorage.get(actor, turn.id)
    {:ok, thread} = Arca.ThreadStorage.get(actor, thread.id)
    {turn, thread}
  end

  # The step that admitted the program's start, as the loop records and
  # decides one: the model's `program.start` of `row` at its epoch, its
  # `tool_call` row and its step written as a response's call, and
  # dispatched, which the loop does only once it decided the call.
  defp start_step!(ctx, turn, row, opts \\ []) do
    actor = Sanctum.Context.actor(ctx)
    {:ok, model} = TurnStorage.put_step(actor, turn.id, %{kind: "model", fence: turn.fence})

    args =
      Keyword.get(opts, :args, %{"action" => "start", "program" => row.id, "epoch" => row.epoch})

    call_id = "call_#{System.unique_integer([:positive])}"

    {:ok, %{asks: [%{step: step}]}} =
      TurnStorage.commit_events(
        actor,
        %{thread: turn.thread_id, agent: turn.agent, turn: %{id: turn.id, fence: turn.fence}},
        %{
          events: [
            {:ask,
             %{
               kind: "tool",
               tool: "program",
               action: "start",
               idempotency_key: "call:#{turn.id}:#{model.id}:#{call_id}",
               call: %{
                 kind: "tool_call",
                 content: "program",
                 payload: %{
                   "tool_call_id" => call_id,
                   "name" => "program",
                   "tool" => "program",
                   "action" => "start",
                   "arguments" => args,
                   "step_id" => model.id
                 }
               }
             }}
          ],
          position: {:step, model.id}
        }
      )

    {:ok, step} = TurnStorage.dispatch_step(actor, step.id, %{fence: turn.fence})
    step
  end

  # The thread's turn over, and the next one addressed to `agent`.
  defp next_turn!(ctx, thread_id, turn, agent) do
    set_turn(turn, status: "completed")

    {:ok, %{turn: later}} =
      TurnStorage.accept_message(Sanctum.Context.actor(ctx), thread_id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "#{agent}, go on"},
        turn: %{agent: agent, requested_by: ctx.user_id, origin: :interactive}
      })

    later
  end

  # `turn` running with its `program.start` of `row` admitted: its binding.
  defp admitted!(ctx, binding, turn, row) do
    set_turn(turn, status: "running")
    {:ok, turn} = TurnStorage.get(Sanctum.Context.actor(ctx), turn.id)
    step = start_step!(ctx, turn, row)

    %{
      binding
      | agent: turn.agent,
        turn_id: turn.id,
        fence: turn.fence,
        step: step.id,
        row_id: row.id,
        epoch: row.epoch
    }
  end

  # The opens and closes the service saw so far, dropped.
  defp flush_opens_and_closes do
    receive do
      {:session, op, _wire, _fields} when op in ["open", "close"] -> flush_opens_and_closes()
    after
      0 -> :ok
    end
  end

  # The next `count` opens and closes the service saw, in its order.
  defp opens_and_closes(count) do
    for _ <- 1..count do
      receive do
        {:session, op, wire, _fields} when op in ["open", "close"] -> {op, wire}
      after
        5_000 -> flunk("the service saw no open or close")
      end
    end
  end

  # The driver accepts the command `id` just written, and the holder
  # reads it.
  defp accepted!(fake, row, brain, id, boot \\ "boot-one") do
    say(fake, row, %{"t" => "accepted", "id" => id})
    assert {^boot, [{seq, %{"t" => "accepted", "id" => ^id}}]} = batch(brain)
    :ok = Brain.read_on(brain, boot, seq)
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
    do: %{"t" => "hello", "v" => Wire.version(), "driver" => "cyfr-claude-code", "boot" => boot}

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
    harness_started!(fake, row, brain)
  end

  # The driver answers the start just written, and the holder reads it.
  defp harness_started!(fake, row, brain, boot \\ "boot-one", says \\ %{}) do
    started = %{
      "t" => "started",
      "session" => "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30",
      "fresh" => true,
      "held" => []
    }

    say(fake, row, Map.merge(started, says))

    assert {^boot, [{seq, %{"t" => "started"}}]} = batch(brain)
    :ok = Brain.read_on(brain, boot, seq)
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

    test "a holder handed a grant of a boot the service has left opens under the one it runs",
         %{fake: fake, row: row, binding: binding} do
      owner = %{athanor_id: row.athanor_id, server_id: row.id, epoch: row.epoch}
      # A live owner answers the brain's hold at once, with the boot it was synced under.
      assert {:ok, %{boot: "bb_first"}} = Opus.Programs.hold(owner)
      Scripted.restart(fake, "bb_second")

      assert {:ok, _brain} = Brain.open(binding)
      assert_receive {:session, "open", _open, %{boot: "bb_second"}}, 5_000
      assert [_one] = running_sessions(fake, row)
    end

    test "a driver whose hello names another version is ended before anything is written to it",
         %{fake: fake, row: row, binding: binding} do
      {:ok, {pid, ref} = brain} = Brain.open(binding)
      monitor = Process.monitor(pid)
      say(fake, row, %{hello() | "v" => Wire.version() - 1})
      assert_receive {Brain, ^ref, {:ended, :unreadable}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
      refute_received {Brain, ^ref, {:lines, _boot, _lines}}

      assert Brain.write(brain, binding, %{
               "t" => "start",
               "gen" => 0,
               "config" => %{"access" => "default"}
             }) ==
               {:error, :unavailable}

      refute_sent()
      assert running_sessions(fake, row) == []
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

    test "a post answered later is answered: an ask's answer is written straight after it",
         %{fake: fake, row: row, binding: binding} do
      brain = started!(fake, row, binding)
      assert :ok = Brain.write(brain, binding, post(binding))
      assert %{"t" => "post", "id" => "stp_post"} = sent()

      say(fake, row, %{
        "t" => "ask",
        "gen" => 0,
        "work" => binding.turn_id,
        "ask" => "ask-1",
        "name" => "files",
        "arguments" => %{}
      })

      assert {"boot-one", [{seq, %{"t" => "ask"}}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)
      say(fake, row, %{"t" => "later", "id" => "stp_post"})
      assert {"boot-one", [{seq, %{"t" => "later", "id" => "stp_post"}}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)

      answer = %{
        "t" => "answer",
        "id" => "stp_answer",
        "ask" => "ask-1",
        "content" => "done",
        "is_error" => false
      }

      assert :ok = Brain.write(brain, binding, answer)
      assert %{"t" => "answer", "id" => "stp_answer"} = sent()
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
  end

  describe "what is known of the account" do
    test "a start's account member sets and clears it, and a refused post's sets it",
         %{fake: fake, ctx: ctx, row: row, binding: binding} do
      known = fn -> Brain.known(ctx, row.id, row.epoch).account end
      brain = opened!(fake, row, binding)
      assert :ok = Brain.write(brain, binding, %{"t" => "start", "gen" => 0, "config" => %{}})
      assert %{"t" => "start"} = sent()
      harness_started!(fake, row, brain, "boot-one", %{"account" => "signed_in"})
      assert known.() == :signed_in

      assert :ok = Brain.write(brain, binding, post(binding))
      assert %{"t" => "post", "id" => id} = sent()

      say(fake, row, %{
        "t" => "refused",
        "id" => id,
        "reason" => "Sign it in.",
        "account" => "signed_out"
      })

      assert {"boot-one", [{seq, %{"t" => "refused"}}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)
      assert known.() == :signed_out
    end

    for before <- [nil, :signed_out, :signed_in] do
      @tag before: before
      test "an authentication error, an account read's failure, an idle after an error and a " <>
             "start that names no account neither set nor clear it, known #{inspect(before)}",
           %{fake: fake, ctx: ctx, row: row, binding: binding, before: before} do
        key = Arca.Cache.Keys.brain_known(Sanctum.Context.actor(ctx), row.id, row.epoch, :account)
        if before, do: :ok = Arca.Cache.put(key, before, :timer.hours(1))
        known = fn -> Brain.known(ctx, row.id, row.epoch).account end

        brain = started!(fake, row, binding)
        assert known.() == before

        assert :ok = Brain.write(brain, binding, post(binding))
        assert %{"t" => "post", "id" => id} = sent()
        work = %{"gen" => 0, "work" => binding.turn_id}

        for event <- [
              %{"t" => "refused", "id" => id, "reason" => "The account could not be read."},
              Map.merge(work, %{
                "t" => "error",
                "type" => "authentication",
                "message" => "Refused."
              }),
              Map.merge(work, %{"t" => "idle", "answered" => [], "stop" => "error"})
            ] do
          say(fake, row, event)
          type = event["t"]
          assert {"boot-one", [{seq, %{"t" => ^type}}]} = batch(brain)
          :ok = Brain.read_on(brain, "boot-one", seq)
          assert known.() == before
        end
      end
    end
  end

  describe "the configuration" do
    # What a caller names: the member's model and options, its access
    # among them, and the harness's own tools.
    @named %{
      "model" => "opus",
      "effort" => "high",
      "access" => "default",
      "harness_tools" => ["Read", "Grep"]
    }

    test "a start writes the caller's configuration unchanged, its access among it",
         %{fake: fake, row: row, binding: binding} do
      brain = opened!(fake, row, binding)
      start = %{"t" => "start", "gen" => 0, "config" => @named}
      assert :ok = Brain.write(brain, binding, start)
      assert sent() == start
      harness_started!(fake, row, brain)
      work = %{"t" => "work", "id" => "stp_work", "work" => binding.turn_id, "tools" => []}
      [{running, _}] = running_sessions(fake, row)
      assert :ok = Brain.write(brain, binding, work)
      assert sent() == work
      accepted!(fake, row, brain, work["id"], "boot-one")
      assert [{^running, %{running: true}}] = running_sessions(fake, row)
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

    test "a start closed denied or skipped writes nothing; one closed ok writes",
         %{brain: brain, binding: binding, ctx: ctx, turn: turn, row: row} do
      closed = fn outcome ->
        step = start_step!(ctx, turn, row)

        {:ok, _closed} =
          TurnStorage.close_step(Sanctum.Context.actor(ctx), step.id, outcome, %{
            fence: turn.fence
          })

        %{binding | step: step.id}
      end

      for outcome <- ["denied", "skipped"] do
        assert Brain.write(brain, closed.(outcome), post(binding)) ==
                 {:error, {:not_admitted, :not_allowed}}
      end

      refute_sent()

      assert :ok = Brain.write(brain, closed.("ok"), post(binding))
      assert %{"t" => "post", "id" => "stp_post"} = sent()
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
    # The launch pause, a turn's one wait on the person: the program's
    # start or work is refused while it holds, the same one written once
    # the turn runs again, so the pause alone refused it.
    test "on a launch pause, delivers a post or an answer of its own work, and neither starts nor works",
         %{fake: fake, row: row, binding: binding, turn: turn} do
      brain = opened!(fake, row, binding)
      set_turn(turn, status: "paused", paused_reason: "launch")

      start = %{"t" => "start", "gen" => 0, "config" => %{}}
      assert Brain.write(brain, binding, start) == {:error, {:not_admitted, :paused}}
      refute_sent()

      set_turn(turn, status: "running", paused_reason: nil)
      assert :ok = Brain.write(brain, binding, start)
      assert sent() == start
      harness_started!(fake, row, brain)

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
      set_turn(turn, status: "paused", paused_reason: "launch")

      work = %{"t" => "work", "id" => "stp_work", "work" => binding.turn_id, "tools" => []}
      assert Brain.write(brain, binding, work) == {:error, {:not_admitted, :paused}}
      refute_sent()

      assert :ok = Brain.write(brain, binding, post(binding))
      assert sent() == post(binding)
      accepted!(fake, row, brain, "stp_post")

      answer = %{
        "t" => "answer",
        "id" => "stp_answer",
        "ask" => "ask-1",
        "content" => "x",
        "is_error" => false
      }

      assert :ok = Brain.write(brain, binding, answer)
      assert sent() == answer
      accepted!(fake, row, brain, "stp_answer")

      set_turn(turn, status: "running", paused_reason: nil)
      assert :ok = Brain.write(brain, binding, work)
      assert sent() == work
    end

    test "opens nothing: a turn paused on a launch starts no driver", %{
      binding: binding,
      turn: turn
    } do
      set_turn(turn, status: "paused", paused_reason: "launch")
      assert Brain.open(binding) == {:error, {:not_admitted, :paused}}
      refute_received {:session, "open", _wire, _fields}
    end

    test "a take-over ends it", %{fake: fake, row: row, binding: binding, turn: turn} do
      brain = started!(fake, row, binding)
      set_turn(turn, status: "paused", paused_reason: "launch", fence: turn.fence + 1)
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
          {"a second hello", ~s({"t":"hello","v":#{Wire.version()},"driver":"d","boot":"b"})},
          {"a member beyond its message's", ~s({"t":"accepted","id":"p","thread":"thr_other"})}
        ] do
      test "#{name} ends it", %{fake: fake, row: row, brain: {_pid, ref}} do
        say(fake, row, unquote(line))
        assert_receive {Brain, ^ref, {:ended, :unreadable}}, 5_000
      end
    end

    test "a later that answers no post ends it, as an unknown answer does", %{
      fake: fake,
      row: row,
      binding: binding,
      brain: {_pid, ref} = brain
    } do
      work = %{"t" => "work", "id" => "stp_work", "work" => binding.turn_id, "tools" => []}
      assert :ok = Brain.write(brain, binding, work)
      assert %{"t" => "work"} = sent()
      say(fake, row, %{"t" => "later", "id" => "stp_work"})
      assert_receive {Brain, ^ref, {:ended, :unreadable}}, 5_000
    end

    test "a later while no command is out ends it", %{fake: fake, row: row, brain: {_pid, ref}} do
      say(fake, row, %{"t" => "later", "id" => "stp_post"})
      assert_receive {Brain, ^ref, {:ended, :unreadable}}, 5_000
    end

    test "a line lost unread ends it", %{fake: fake, row: row, brain: {_pid, ref}} do
      Scripted.set(fake, :dropped, 2)
      say(fake, row, %{"t" => "text", "gen" => 0, "message" => "m", "delta" => "x"})
      assert_receive {Brain, ^ref, {:ended, :dropped}}, 5_000
    end

    for {code, reason} <- [{"unknown_session", :exited}, {"bad_request", :unavailable}] do
      test "a read the box refuses #{code} ends it, its session closed", %{
        fake: fake,
        row: row,
        brain: {pid, ref} = brain
      } do
        # The reader waits on the holder once it handed a batch, so the
        # next read is the one refused.
        say(fake, row, %{"t" => "text", "gen" => 0, "message" => "m", "delta" => "x"})
        assert {"boot-one", [{seq, %{"t" => "text"}}]} = batch(brain)
        monitor = Process.monitor(pid)
        Scripted.refuse_once(fake, "recv", unquote(code))
        :ok = Brain.read_on(brain, "boot-one", seq)
        assert_receive {Brain, ^ref, {:ended, unquote(reason)}}, 5_000
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
        assert_receive {:session, "close", _wire, _fields}, 5_000
        assert running_sessions(fake, row) == []
      end
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

    test "a close says unanswered while the box still owes it, to its attendant too", %{
      fake: fake,
      brain: {_pid, ref} = brain
    } do
      Scripted.refuse_once(fake, "close", "unavailable")
      assert Brain.close(brain) == {:error, :unanswered}
      assert_receive {Brain, ^ref, {:ended, reason}}, 2_000
      assert reason == :unanswered
    end

    test "its attendant is told closed only once the close is confirmed", %{
      fake: fake,
      brain: {_pid, ref} = brain
    } do
      Scripted.hold(fake, "close")
      closing = Task.async(fn -> Brain.close(brain) end)
      assert_receive {:held, "close", service}, 5_000
      refute_receive {Brain, ^ref, {:ended, _reason}}, 200
      send(service, :go)
      assert Task.await(closing) == :ok
      assert_receive {Brain, ^ref, {:ended, :closed}}, 2_000
    end

    test "a close of a dead holder waits on a replacement box for what the holder left", %{
      fake: fake,
      brain: {pid, _ref} = brain
    } do
      box = GenServer.whereis(Opus.Programs.via("local"))
      Scripted.hold(fake, "close", 50_000)
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
      assert_receive {:held, "close", first}, 5_000
      on_exit(fn -> send(first, :go) end)

      Scripted.hold(fake, "close", 40_000)
      down = Process.monitor(box)
      Process.exit(box, :kill)
      assert_receive {:DOWN, ^down, :process, ^box, _reason}, 5_000
      wait_until(fn -> GenServer.whereis(Opus.Programs.via("local")) not in [nil, box] end, 5_000)
      replacement = GenServer.whereis(Opus.Programs.via("local"))
      wait_until(fn -> :sys.get_state(replacement).boot != nil end, 5_000)

      closing = Task.async(fn -> Brain.close(brain) end)
      assert Task.yield(closing, 500) == nil, "a close was answered from an empty record"
      assert_receive {:held, "close", second}, 5_000
      send(second, :go)
      assert Task.await(closing) == :ok
    end

    test "a close of a holder that ended first waits on the close it left", %{
      fake: fake,
      brain: {pid, _ref} = brain
    } do
      Scripted.hold(fake, "close")
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
      assert_receive {:held, "close", service}, 5_000

      closing = Task.async(fn -> Brain.close(brain) end)
      assert Task.yield(closing, 200) == nil
      send(service, :go)
      assert Task.await(closing) == :ok
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

  describe "a sync of its owner under the same boot" do
    test "ends no opening session: it goes on under the new grant, reading on",
         %{fake: fake, row: row, binding: binding} do
      {:ok, {holder, ref} = brain} = Brain.open(binding)
      controller = GenServer.whereis(Opus.Programs.via("local"))
      Cyfr.Test.Settings.put("athanor_program_memory_bytes", 2_147_483_648)
      send(controller, :tick)
      assert_receive {:control, "sync", %{"athanor_memory_bytes" => 2_147_483_648}, _}, 2_000

      wait_until(
        fn -> :sys.get_state(controller).inflight == nil end,
        2_000,
        "the sync to settle"
      )

      # What the sync told the holder is handled.
      :sys.get_state(holder)
      refute_received {Brain, ^ref, {:ended, _reason}}

      say(fake, row, hello())
      assert {"boot-one", [{1, %{"t" => "hello"}}]} = batch(brain)
      assert Process.alive?(holder)
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

    test "a send the service answers ended may follow its writing, so it is uncertain",
         %{fake: fake, row: row, binding: binding, brain: brain, answer: answer} do
      # The reader waits on the attendant once it handed a line, so the
      # send is the first to meet the ended process.
      say(fake, row, %{"t" => "text", "gen" => 0, "message" => "m", "delta" => "x"})
      assert {_boot, [{_seq, %{"t" => "text"}}]} = batch(brain)
      Scripted.end_sessions(fake, row.id)
      assert Brain.write(brain, binding, answer) == {:error, :uncertain}
    end

    test "a write whose holder died with the answer is uncertain",
         %{fake: fake, binding: binding, brain: {pid, _ref} = brain, answer: answer} do
      killer =
        Task.async(fn ->
          assert_receive {:held, "send", service}, 5_000
          Process.exit(pid, :kill)
          service
        end)

      # The attendant is blocked in the write when the service reports the hold.
      Scripted.set(fake, :test, killer.pid)
      Scripted.hold(fake, "send", 30_000)

      result = Brain.write(brain, binding, answer)
      send(Task.await(killer), :go)
      assert result == {:error, :uncertain}
    end

    test "a write whose answer outlasts the caller's wait is uncertain, never refused",
         %{binding: binding, brain: {pid, _ref} = brain, answer: answer} do
      # The holder is stopped with the write in its mailbox, past the
      # caller's own timeout, as one whose reply is late.
      true = :erlang.suspend_process(pid)

      try do
        assert Brain.write(brain, binding, answer) == {:error, :uncertain}
      after
        :erlang.resume_process(pid)
      end
    end

    test "the driver's death ends the session; nothing more is written",
         %{fake: fake, row: row, binding: binding, brain: {_pid, ref} = brain, answer: answer} do
      Scripted.end_sessions(fake, row.id)
      assert_receive {Brain, ^ref, {:ended, :exited}}, 5_000
      assert Brain.write(brain, binding, answer) == {:error, :unavailable}
      refute_sent()
    end

    test "a driver that says why it ends ends the session with that why, never its words",
         %{fake: fake, row: row, brain: {_pid, ref} = brain} do
      say(fake, row, %{"t" => "ending", "why" => "servers_unlisted"})
      {_boot, [{seq, %{"t" => "ending"}}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)
      Scripted.end_sessions(fake, row.id)
      assert_receive {Brain, ^ref, {:ended, {:exited, :servers_unlisted}}}, 5_000
    end

    test "a second ending, or any line after one, is read past and changes nothing",
         %{fake: fake, row: row, binding: binding, brain: {_pid, ref} = brain} do
      say(fake, row, %{"t" => "ending", "why" => "ended"})
      {_boot, [{seq, %{"t" => "ending"}}]} = batch(brain)
      :ok = Brain.read_on(brain, "boot-one", seq)
      say(fake, row, %{"t" => "ending", "why" => "outdated"})

      say(fake, row, %{
        "t" => "said",
        "gen" => 0,
        "work" => binding.turn_id,
        "message" => "msg_after",
        "text" => "after its end"
      })

      Scripted.end_sessions(fake, row.id)
      assert_receive {Brain, ^ref, {:ended, {:exited, :ended}}}, 5_000
      refute_received {Brain, ^ref, {:lines, _boot, _lines}}
    end

    test "an ending outside the wire's endings is a line that does not read",
         %{fake: fake, row: row, brain: {_pid, ref}} do
      say(fake, row, %{"t" => "ending", "why" => "ENOENT /home/person/.config"})
      assert_receive {Brain, ^ref, {:ended, :unreadable}}, 5_000
    end

    test "a service that started again ends the session as restarted, not as the driver's exit",
         %{fake: fake, brain: {_pid, ref}} do
      Scripted.restart(fake, "bb_again")
      assert_receive {Brain, ^ref, {:ended, :restarted}}, 5_000
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
      assert Brain.whereis(binding.ctx.athanor_id, binding.thread_id) == holder
      send(successor, :done)
    end

    test "a binding that goes stale while the driver's session opens opens nothing, its session closed",
         %{fake: fake, row: row, binding: binding, turn: turn} do
      Scripted.hold(fake, "opened")
      opening = Task.async(fn -> Brain.open(binding) end)
      assert_receive {:held, "opened", service}, 5_000
      holder = Brain.whereis(binding.ctx.athanor_id, binding.thread_id)
      monitor = Process.monitor(holder)

      set_turn(turn, fence: turn.fence + 1)
      send(service, :go)

      assert Task.await(opening, 10_000) == {:error, {:not_admitted, :superseded}}
      assert_receive {:DOWN, ^monitor, :process, ^holder, _reason}, 5_000
      assert running_sessions(fake, row) == []
    end

    test "another agent's work on the thread ends its holder first, so one driver process " <>
           "runs the thread's session",
         %{fake: fake, ctx: ctx, row: row, binding: binding, thread: thread, turn: turn} do
      actor = Sanctum.Context.actor(ctx)
      session = "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
      {aqua, aqua_ref} = started!(fake, row, binding)
      [{first, _}] = running_sessions(fake, row)
      keep_session!(actor, thread, row, turn.agent, session)
      later = next_turn!(ctx, thread.id, turn, "planner")
      planner = admitted!(ctx, binding, later, row)
      flush_opens_and_closes()

      assert {:ok, {holder, ref}} = Brain.open(planner)
      assert_receive {Brain, ^aqua_ref, {:ended, :replaced}}, 5_000
      refute Process.alive?(aqua)

      assert [{"close", %{"session" => ^first}}, {"open", %{"home_id" => home}}] =
               opens_and_closes(2)

      assert home == row.id
      assert [{second, %{running: true}}] = running_sessions(fake, row)
      assert Brain.whereis(ctx.athanor_id, thread.id) == holder

      # And back: Aqua's next turn ends the planner's holder the same way.
      aqua_again =
        admitted!(ctx, binding, next_turn!(ctx, thread.id, %{id: later.id}, "aqua"), row)

      assert {:ok, {again, _ref}} = Brain.open(aqua_again)
      assert_receive {Brain, ^ref, {:ended, :replaced}}, 5_000
      refute Process.alive?(holder)
      assert [{"close", %{"session" => ^second}}, {"open", _open}] = opens_and_closes(2)
      assert [{third, %{running: true}}] = running_sessions(fake, row)
      assert third not in [first, second]
      assert Brain.whereis(ctx.athanor_id, thread.id) == again
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

    # The write answered: the holder reads past the hello. Until then what
    # the service is told can still be the write's to answer.
    defp written_and_reading!,
      do: assert_receive({:session, "recv", %{"after" => 1}, _fields}, 5_000)

    # `opener` waits on the take-over it asked of `holder`, and `holder`
    # has handled the asking: the opener watches it twice then, for its
    # end and for the call, and the holder answers what came after.
    defp taking_over!(holder, opener) do
      wait_until(
        fn ->
          [status: status, monitors: monitors] = Process.info(opener, [:status, :monitors])
          status == :waiting and Enum.count(monitors, &(&1 == {:process, holder})) == 2
        end,
        5_000,
        "a take-over waiting on the holder"
      )

      :sys.get_state(holder)
    end

    # A discovery past its write, waiting on the driver's answer: the
    # process that asked, which tells the test what it was answered, the
    # holder and the command's id.
    defp discovering!(fake, ctx, row) do
      test = self()
      asker = spawn(fn -> send(test, {:asked, Brain.models(ctx, row.id)}) end)
      %{"t" => "models", "id" => id} = once_driver!(fake, row)
      written_and_reading!()
      holder = Brain.whereis(ctx.athanor_id, id)
      assert is_pid(holder)
      {asker, holder, id}
    end

    defp answered!(fake, row, id) do
      say(fake, row, %{
        "t" => "models",
        "id" => id,
        "models" => [],
        "access" => []
      })
    end

    defp ends_giving_back!(holder, reason, fake, ctx, row) do
      monitor = Process.monitor(holder)
      assert_receive {:DOWN, ^monitor, :process, ^holder, ^reason}, 1_000
      given_back!(fake, ctx, row)
    end

    # Nothing of the row's is left once the controller's job out has
    # settled: no session running at the service, no owner of the
    # controller's and no live claim.
    defp given_back!(fake, ctx, row) do
      wait_until(fn -> running_sessions(fake, row) == [] end, 2_000, "the session closed")
      key = {ctx.athanor_id, row.id}
      controller = Opus.Programs.via("local")

      wait_until(
        fn ->
          state = :sys.get_state(controller)

          state.inflight == nil and not is_map_key(state.owners, key) and
            not is_map_key(state.claims, key)
        end,
        2_000,
        "the owner and the claim given back"
      )

      # A claim given up is the row, its lease over.
      assert {:ok, claim} =
               Arca.JobClaims.read("mcp_backend", ctx.athanor_id <> ":" <> row.id)

      refute Arca.JobClaims.live?(claim)
    end

    # A one command brought to each of its ends, the caller telling the
    # test what it was answered.
    defp left_by!(:refused_read, fake, ctx, row) do
      test = self()
      spawn(fn -> send(test, {:asked, Brain.models(ctx, row.id)}) end)
      assert_receive {:session, "open", _open, _fields}, 5_000
      first_read!()
      Scripted.refuse_once(fake, "recv", "bad_request")
      say(fake, row, hello())
    end

    defp left_by!(:write_unanswered, fake, ctx, row) do
      test = self()
      spawn(fn -> send(test, {:asked, Brain.models(ctx, row.id)}) end)
      assert_receive {:session, "open", _open, _fields}, 5_000
      first_read!()
      Scripted.set(fake, :reset_send, true)
      say(fake, row, hello())
    end

    defp left_by!(:open_refused, fake, ctx, row) do
      test = self()
      Scripted.refuse_once(fake, "open", "capacity")
      spawn(fn -> send(test, {:asked, Brain.models(ctx, row.id)}) end)
    end

    defp left_by!(ending, fake, ctx, row) do
      {_asker, holder, id} = discovering!(fake, ctx, row)

      case ending do
        :answer ->
          answered!(fake, row, id)

        :unreadable ->
          say(fake, row, "not a line of the wire")

        :dropped ->
          Scripted.set(fake, :dropped, 1)
          answered!(fake, row, id)

        :row_ended ->
          :ok = Opus.Programs.end_mounts(ctx.athanor_id, row.id)

        :stand_down ->
          send(holder, {Opus.Programs, :stand_down, {ctx.athanor_id, row.id}})

        :shutdown ->
          spawn(fn -> DynamicSupervisor.terminate_child(Brain.Holders, holder) end)

        :driver_exit ->
          Scripted.end_sessions(fake, row.id)

        :reader_death ->
          Process.exit(:sys.get_state(holder).reader, :kill)

        :deadline ->
          send(holder, :once_over)
      end
    end

    # A discovery asked of a holder of its own by a deadline `ms` away,
    # where `Brain.models/2` gives a minute: the caller, which tells the
    # test what it was answered, and when that deadline is.
    defp due_in!(ctx, row, ms) do
      until = System.monotonic_time(:millisecond) + ms
      {holder, command} = one_command!(ctx, row, until)
      test = self()
      spawn(fn -> send(test, {:asked, GenServer.call(holder, command, 30_000)}) end)
      until
    end

    # A holder of its own and the discovery `until` is the deadline of.
    defp one_command!(ctx, row, until) do
      id = "mdl_#{System.unique_integer([:positive])}"
      {:ok, holder} = DynamicSupervisor.start_child(Brain.Holders, {Brain, {ctx.athanor_id, id}})
      owner = %{athanor_id: ctx.athanor_id, server_id: row.id, epoch: row.epoch}
      {holder, {:once, owner, %{"t" => "models", "id" => id}, until}}
    end

    # A discovery listed whole, its deadline `ms` away.
    defp listed_within!(fake, ctx, row, ms) do
      _until = due_in!(ctx, row, ms)
      %{"t" => "models", "id" => id} = once_driver!(fake, row)
      written_and_reading!()
      answered!(fake, row, id)
      assert_receive {:asked, {:ok, _listed}}, 2_000
      given_back!(fake, ctx, row)
      flush_reads()
    end

    # What is left until `until`, and a second for what follows it.
    defp by(until), do: max(until - System.monotonic_time(:millisecond), 0) + 1_000

    # The controller's ticks, which renew the owner's lease, until `until`.
    defp renewing_until(until) do
      left = until - System.monotonic_time(:millisecond)

      if left > 0 do
        send(GenServer.whereis(Opus.Programs.via("local")), :tick)
        # sleep-ok: the real minute passes under renewals, the fixture's lease being 30 s
        Process.sleep(min(left, 5_000))
        renewing_until(until)
      end
    end

    # `cause` brings Box to close `holder`'s lifetime while the holder hears
    # nothing. The holder is let run once that close is confirmed, and a
    # second one would be held past every wait of the test's.
    defp confirmed_unheard!(fake, holder, cause) do
      controller = GenServer.whereis(Opus.Programs.via("local"))
      :erlang.suspend_process(holder)

      try do
        caused = cause.()
        assert_receive {:session, "close", _first, _fields}, 3_000

        wait_until(
          fn -> :sys.get_state(controller).closing == %{} end,
          2_000,
          "the first close confirmed"
        )

        Scripted.hold(fake, "close", 30_000)
        caused
      after
        :erlang.resume_process(holder)
      end
    end

    # The reads an earlier holder made, told already.
    defp flush_reads do
      receive do
        {:session, "recv", _read, _fields} -> flush_reads()
      after
        0 -> :ok
      end
    end

    test "a successor that kept the session while the cleanup waited for the key is never removed",
         %{fake: fake, ctx: ctx, row: row, thread: thread, binding: binding} do
      # The session `started!/5` reports, so the successor keeps the one
      # the record names.
      session = "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30"
      record = owed!(ctx, thread.id, row, session: session)
      test = self()
      handler = "brain-cleanup-pause-#{System.unique_integer([:positive])}"

      # The cleanup is held at its read of the row: past its first read of
      # the record, before its holder takes the key.
      :ok =
        :telemetry.attach(
          handler,
          [:arca, :repo, :query],
          fn _event, _measures, meta, _config ->
            if Process.get(:cleanup_held) == true and meta[:source] == "mcp_servers" do
              Process.delete(:cleanup_held)
              send(test, {:row_read, self()})

              receive do
                :go_on -> :ok
              after
                15_000 -> raise "the cleanup was not let go on"
              end
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      task =
        Task.async(fn ->
          Process.put(:cleanup_held, true)
          Brain.forget(record)
        end)

      assert_receive {:row_read, cleanup}, 5_000

      # A successor opens under the key, keeps the session and ends.
      set_generation(thread, 1)
      brain = started!(fake, row, %{binding | generation: 1}, %{}, 1)
      assert_received {:session, "open", _successors, _fields}

      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Thread, where: t.id == ^thread.id),
          set: [brain_session: session]
        )

      assert :ok = Brain.close(brain)
      flush_reads()
      send(cleanup, :go_on)

      # A cleanup that decided before the key was its own opens, and is
      # answered forgot here, so the test fails on the answer.
      ref = task.ref

      answer =
        receive do
          {^ref, answer} ->
            answer

          {:session, "open", _open, _fields} ->
            first_read!()
            say(fake, row, hello())
            %{"t" => "forget", "id" => id, "session" => ^session} = sent()
            say(fake, row, %{"t" => "forgot", "id" => id, "session" => session})
            Task.await(task, 10_000)
        after
          5_000 -> flunk("the cleanup neither answered nor opened")
        end

      Process.demonitor(ref, [:flush])
      assert answer == {:error, :successor}
      refute_received {:session, "open", _open, _fields}
    end

    test "a successor that opens while the cleanup holds the key waits for its end",
         %{fake: fake, ctx: ctx, row: row, thread: thread, binding: binding} do
      record = owed!(ctx, thread.id, row)
      task = Task.async(fn -> Brain.forget(record) end)
      assert %{"t" => "forget", "id" => id, "session" => @session} = once_driver!(fake, row)
      cleanup = Brain.whereis(ctx.athanor_id, thread.id)
      assert is_pid(cleanup)

      # The forget is written; a successor's open waits on the cleanup's
      # holder, which takes it up only once its one answer is read.
      set_generation(thread, 1)
      opener = Task.async(fn -> Brain.open(%{binding | generation: 1}) end)
      taking_over!(cleanup, opener.pid)
      assert Task.yield(opener, 0) == nil
      refute_received {:session, "open", _open, _fields}

      say(fake, row, %{"t" => "forgot", "id" => id, "session" => @session})
      assert Task.await(task, 10_000) == :forgot
      assert {:ok, {successor, _ref}} = Task.await(opener, 20_000)
      assert successor != cleanup
      refute Process.alive?(cleanup)
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

    test "a row of either driver is a brain's", %{fake: fake, ctx: ctx, thread: thread} do
      codex = brain_row!(ctx, "openai-codex")

      {1, _} =
        Arca.Repo.update_all(from(r in Arca.Schemas.McpServer, where: r.id == ^codex.id),
          set: [
            config_json:
              Jason.encode!(%{"command" => "cyfr-codex npx -y @openai/codex", "env" => %{}})
          ]
        )

      record = owed!(ctx, thread.id, codex)
      task = Task.async(fn -> Brain.forget(record) end)
      assert %{"t" => "forget", "id" => id, "session" => @session} = once_driver!(fake, codex)
      say(fake, codex, %{"t" => "forgot", "id" => id, "session" => @session})
      assert Task.await(task, 10_000) == :forgot
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

    test "a removal owed on one row while the thread's holder runs on another stays owed, " <>
           "and is done once that holder ends",
         %{fake: fake, ctx: ctx, row: row, thread: thread, turn: turn, binding: binding} do
      # Another agent's work on the thread, on another row, at the
      # generation whose session the record names: its holder holds
      # nothing of the record's folder, and the cleanup waits for it.
      actor = Sanctum.Context.actor(ctx)
      other = brain_row!(ctx, "claude-code-other")
      planner = admitted!(ctx, binding, next_turn!(ctx, thread.id, turn, "planner"), other)
      {:ok, {pid, ref} = brain} = Brain.open(planner)
      record = owed!(ctx, thread.id, row, generation: binding.generation)
      flush_opens_and_closes()

      assert Task.await(draining(ctx), 10_000) == {:ok, %{"owed" => 1}}
      assert Process.alive?(pid)
      refute_received {Brain, ^ref, {:ended, _reason}}
      refute_received {:session, "open", _open, _fields}
      assert {:ok, [^record]} = Arca.Outbox.pending(actor, "brain_cleanup", "brain_forget")

      Brain.close(brain)
      flush_opens_and_closes()
      flush_reads()
      drain = draining(ctx)
      assert %{"t" => "forget", "id" => id, "session" => @session} = once_driver!(fake, row)
      say(fake, row, %{"t" => "forgot", "id" => id, "session" => @session})
      assert Task.await(drain, 10_000) == {:ok, %{"applied" => 1}}
      assert {:ok, []} = Arca.Outbox.pending(actor, "brain_cleanup", "brain_forget")
    end

    # A drain of the athanor's removals, run beside the test, which plays
    # the row's driver.
    defp draining(ctx), do: Task.async(fn -> Opus.Brain.Cleanup.drain(ctx.athanor_id) end)

    test "a deletion after a turn addressed another agent ends the session's holder and its " <>
           "driver process before the removal is sent",
         %{fake: fake, ctx: ctx, row: row, binding: binding, thread: thread, turn: turn} do
      actor = Sanctum.Context.actor(ctx)
      {pid, _ref} = started!(fake, row, binding)
      [{first, _}] = running_sessions(fake, row)
      keep_session!(actor, thread, row, turn.agent, "4b0c3b1e-2f43-4c5e-9d8a-1f6e2a7c9b30")
      later = next_turn!(ctx, thread.id, turn, "planner")
      set_turn(later, status: "completed")

      assert {:ok, %{cancelled: []}} = Aqua.Tape.delete_thread(ctx, thread.id)
      {:ok, [record]} = Arca.Outbox.pending(actor, "brain_cleanup", "brain_forget")
      flush_opens_and_closes()
      flush_reads()
      task = Task.async(fn -> Brain.forget(record) end)

      # Read as the cleanup's process opens, before its hello, which the
      # scripted service writes into every session of the row.
      assert_receive {:session, "open", %{"mode" => "run", "home_id" => home}, _fields}, 5_000
      at_the_open = {Scripted.sessions(fake, row.id)[first].running, Process.alive?(pid)}
      assert home == row.id
      first_read!()
      say(fake, row, hello())
      %{"t" => "forget", "id" => id, "session" => session} = sent()
      say(fake, row, %{"t" => "forgot", "id" => id, "session" => session})
      assert Task.await(task, 10_000) == :forgot
      assert at_the_open == {false, false}
    end

    test "cleanup ends a holder of the record's generation first, and waits for a successor's",
         %{fake: fake, ctx: ctx, row: row, binding: binding, thread: thread} do
      {_pid, ref} = started!(fake, row, binding)
      [{old, %{running: true}}] = running_sessions(fake, row)
      record = owed!(ctx, thread.id, row, generation: binding.generation)
      flush_reads()
      task = Task.async(fn -> Brain.forget(record) end)

      # The old holder ends, and the process that ran the session is
      # closed before the forget is written, on a process of the driver of
      # its own under the same key: a close the box still owes when the
      # cleanup opens is made first (`fresh/2`).
      assert_receive {Brain, ^ref, {:ended, :forgotten}}, 5_000
      assert_receive {:session, "close", %{"session" => ^old}, _fields}, 5_000
      assert_receive {:session, "open", %{"key" => "brain-" <> _}, _fields}, 5_000
      first_read!()
      say(fake, row, hello())
      assert %{"t" => "forget", "id" => id} = sent()
      refute Scripted.sessions(fake, row.id)[old].running
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
      older = %{thread_id: thread.id, generation: 0}
      assert :ok = Brain.forgotten(ctx.athanor_id, [older])
      assert Process.alive?(pid)
      refute_received {Brain, ^ref, {:ended, _reason}}

      owed = %{thread_id: thread.id, generation: 1}
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
        "models" => [
          %{"id" => "opus", "name" => "Opus", "efforts" => ["low", "high"]},
          %{"id" => "haiku", "name" => "Haiku", "efforts" => []}
        ],
        "access" => [%{"id" => "default", "name" => "Default mode"}]
      })

      assert Task.await(task, 10_000) == {:ok, @listing}
      assert running_sessions(fake, row) == []
      # What it listed is known, and an answer that names no account says
      # nothing of it.
      assert Brain.known(ctx, row.id, row.epoch) == %{account: nil, listing: @listing}

      task = Task.async(fn -> Brain.models(ctx, row.id) end)
      %{"id" => id} = once_driver!(fake, row)
      say(fake, row, %{"t" => "refused", "id" => id, "reason" => "not listed"})
      assert Task.await(task, 10_000) == {:error, {:refused, "not listed"}}
      assert Brain.known(ctx, row.id, row.epoch) == %{account: nil, listing: @listing}
    end

    test "a listing's account alone says signed out and signed in, for that row at that epoch",
         %{fake: fake, ctx: ctx, row: row} do
      ask = fn answer ->
        task = Task.async(fn -> Brain.models(ctx, row.id) end)
        %{"id" => id} = once_driver!(fake, row)
        say(fake, row, Map.put(answer, "id", id))
        Task.await(task, 10_000)
      end

      listed = %{
        "t" => "models",
        "models" => [
          %{"id" => "opus", "name" => "Opus", "efforts" => ["low", "high"]},
          %{"id" => "haiku", "name" => "Haiku", "efforts" => []}
        ],
        "access" => [%{"id" => "default", "name" => "Default mode"}]
      }

      refused = %{"t" => "refused", "reason" => "Sign it in."}

      assert ask.(Map.put(refused, "account", "signed_out")) ==
               {:error, {:signed_out, "Sign it in."}}

      assert Brain.known(ctx, row.id, row.epoch) == %{account: :signed_out, listing: nil}

      # A refusal and a listing that name no account clear nothing.
      assert ask.(refused) == {:error, {:refused, "Sign it in."}}
      assert Brain.known(ctx, row.id, row.epoch) == %{account: :signed_out, listing: nil}
      assert ask.(listed) == {:ok, @listing}
      assert Brain.known(ctx, row.id, row.epoch) == %{account: :signed_out, listing: @listing}

      assert ask.(Map.put(listed, "account", "signed_in")) == {:ok, @listing}
      assert Brain.known(ctx, row.id, row.epoch) == %{account: :signed_in, listing: @listing}

      # It is the athanor's, the row's and that epoch's, and nobody else's.
      {other, _user} = person!("brain-knows-nothing")
      nothing = %{account: nil, listing: nil}
      assert Brain.known(other, row.id, row.epoch) == nothing
      assert Brain.known(ctx, row.id, row.epoch + 1) == nothing
      assert Brain.known(ctx, "mcp_another", row.epoch) == nothing

      # Kept a day, as a restart of CYFR forgets it with the cache.
      key = Arca.Cache.Keys.brain_known(Sanctum.Context.actor(ctx), row.id, row.epoch, :account)
      [{^key, :signed_in, until}] = :ets.lookup(Arca.Cache.table_name(), key)
      day = :timer.hours(24)
      assert (until - System.monotonic_time(:millisecond)) in (day - 60_000)..day
      :ok = Arca.Cache.invalidate(key)
      assert Brain.known(ctx, row.id, row.epoch) == %{account: nil, listing: @listing}
    end

    test "a discovery whose caller dies ends, its session closed, its owner and claim given back",
         %{fake: fake, ctx: ctx, row: row} do
      {asker, holder, _id} = discovering!(fake, ctx, row)
      Process.exit(asker, :kill)
      ends_giving_back!(holder, :normal, fake, ctx, row)
    end

    test "a cleanup whose caller dies while its session opens writes nothing, all given back",
         %{fake: fake, ctx: ctx, row: row, thread: thread} do
      record = owed!(ctx, thread.id, row)
      Scripted.hold(fake, "opened")
      asker = spawn(fn -> Brain.forget(record) end)
      assert_receive {:held, "opened", service}, 5_000
      holder = Brain.whereis(ctx.athanor_id, thread.id)

      # The driver's hello stands before the open answers: what is read
      # first, the hello or the caller's death, decides the write.
      say(fake, row, hello())
      Process.exit(asker, :kill)
      send(service, :go)
      ends_giving_back!(holder, :normal, fake, ctx, row)
      refute_sent()
    end

    test "a discovery waiting on its driver ends on shutdown at once, all given back",
         %{fake: fake, ctx: ctx, row: row} do
      {_asker, holder, _id} = discovering!(fake, ctx, row)
      stopper = Task.async(fn -> DynamicSupervisor.terminate_child(Brain.Holders, holder) end)
      ends_giving_back!(holder, :shutdown, fake, ctx, row)
      assert Task.await(stopper) == :ok
      assert_receive {:asked, {:error, :lost}}, 1_000
    end

    test "a discovery ends on its row's end, its caller answered only once its close is",
         %{fake: fake, ctx: ctx, row: row} do
      {_asker, holder, _id} = discovering!(fake, ctx, row)
      Scripted.hold(fake, "close")
      :ok = Opus.Programs.end_mounts(ctx.athanor_id, row.id)
      assert_receive {:held, "close", closer}, 1_000
      refute_received {:asked, _answer}
      send(closer, :go)
      ends_giving_back!(holder, :normal, fake, ctx, row)
      assert_receive {:asked, {:error, :lost}}, 1_000
    end

    test "a discovery ends when the box tells it to stand down for its row's change",
         %{fake: fake, ctx: ctx, row: row} do
      {_asker, holder, _id} = discovering!(fake, ctx, row)

      {1, _} =
        Arca.Repo.update_all(from(r in Arca.Schemas.McpServer, where: r.id == ^row.id),
          set: [epoch: row.epoch + 1]
        )

      changed = %{athanor_id: ctx.athanor_id, server_id: row.id, epoch: row.epoch + 1}
      ended = Process.monitor(holder)
      reading = Process.monitor(:sys.get_state(holder).reader)

      # The replaced session's close and the successor's sync each end it at
      # the service, which the reader would hear: with both held there, only
      # the box's telling stops the reading.
      Scripted.hold(fake, "close")
      Scripted.hold(fake, "sync")

      successor =
        Task.async(fn ->
          with {:ok, _grant} <- Opus.Programs.hold(changed), do: Opus.Programs.release(changed)
        end)

      assert_receive {:held, "close", closer}, 1_000
      assert_receive {:held, "sync", syncing}, 1_000
      assert_receive {:DOWN, ^reading, :process, _reader, :killed}, 1_000
      send(closer, :go)
      send(syncing, :go)
      assert_receive {:DOWN, ^ended, :process, ^holder, :normal}, 1_000
      assert_receive {:asked, {:error, :lost}}, 1_000
      assert Task.await(successor) == :ok
      given_back!(fake, ctx, row)
    end

    test "a discovery ends when its driver exits, all given back",
         %{fake: fake, ctx: ctx, row: row} do
      {_asker, holder, _id} = discovering!(fake, ctx, row)
      Scripted.end_sessions(fake, row.id)
      ends_giving_back!(holder, :normal, fake, ctx, row)
      assert_receive {:asked, {:error, :lost}}, 1_000
    end

    test "a discovery ends when its reader dies, all given back",
         %{fake: fake, ctx: ctx, row: row} do
      {_asker, holder, _id} = discovering!(fake, ctx, row)
      Process.exit(:sys.get_state(holder, 1_000).reader, :kill)
      ends_giving_back!(holder, :normal, fake, ctx, row)
      assert_receive {:asked, {:error, :lost}}, 1_000
    end

    test "a discovery ends at the first read the box refuses, all given back",
         %{fake: fake, ctx: ctx, row: row} do
      Scripted.refuse_once(fake, "recv", "bad_request")
      test = self()
      spawn(fn -> send(test, {:asked, Brain.models(ctx, row.id)}) end)
      assert_receive {:asked, {:error, :lost}}, 3_000
      given_back!(fake, ctx, row)
    end

    test "a discovery sets its deadline, a minute, and ends when it comes, all given back",
         %{fake: fake, ctx: ctx, row: row} do
      # A trace session of the test's own: it reads the timer the holder
      # sets and delivers that timer's message, so no minute is waited out.
      session = :trace.session_create(:brain_deadline, self(), [])
      on_exit(fn -> :trace.session_destroy(session) end)
      :trace.process(session, :new_processes, true, [:call])
      :trace.function(session, {:erlang, :send_after, :_}, true, [])

      {_asker, holder, _id} = discovering!(fake, ctx, row)

      # The minute is the caller's, so the timer is what is left of it.
      assert_receive {:trace, ^holder, :call, {:erlang, :send_after, [ms, ^holder, due | _]}}
                     when ms in 55_000..60_000,
                     1_000

      send(holder, due)
      ends_giving_back!(holder, :normal, fake, ctx, row)
      assert_receive {:asked, {:error, :lost}}, 1_000
    end

    test "a sync of its owner under the same version does not end a discovery",
         %{fake: fake, ctx: ctx, row: row} do
      {_asker, holder, id} = discovering!(fake, ctx, row)
      controller = GenServer.whereis(Opus.Programs.via("local"))
      Cyfr.Test.Settings.put("athanor_program_memory_bytes", 2_147_483_648)
      send(controller, :tick)
      assert_receive {:control, "sync", %{"athanor_memory_bytes" => 2_147_483_648}, _}, 2_000
      # The sync settled, and what it told the holder is handled.
      wait_until(
        fn -> :sys.get_state(controller).inflight == nil end,
        2_000,
        "the sync to settle"
      )

      :sys.get_state(holder)

      answered!(fake, row, id)
      assert_receive {:asked, {:ok, %{models: []}}}, 5_000
    end

    test "a discovery takes the first line after the hello as its answer, whatever follows it",
         %{fake: fake, ctx: ctx, row: row} do
      task = Task.async(fn -> Brain.models(ctx, row.id) end)
      assert_receive {:session, "open", _open, _fields}, 5_000
      first_read!()
      # The read after the hello is held, so both lines come in its answer.
      Scripted.hold(fake, "recv")
      say(fake, row, hello())
      %{"t" => "models", "id" => id} = sent()
      assert_receive {:held, "recv", read}, 5_000
      answered!(fake, row, id)
      say(fake, row, "not a line of the wire")
      send(read, :go)
      assert {:ok, %{models: []}} = Task.await(task, 5_000)
    end

    test "a discovery whose driver's first line is no hello writes nothing and reads unreadable",
         %{fake: fake, ctx: ctx, row: row} do
      for first <- [
            %{"t" => "accepted", "id" => "stp_1"},
            Map.put(hello(), "v", Wire.version() + 1)
          ] do
        task = Task.async(fn -> Brain.models(ctx, row.id) end)
        assert_receive {:session, "open", _open, _fields}, 5_000
        first_read!()
        say(fake, row, first)
        assert Task.await(task, 5_000) == {:error, :unreadable}
        refute_sent()
      end
    end

    test "a holder of one command shows neither its command nor its grant's key in its status",
         %{fake: fake, ctx: ctx, row: row, thread: thread} do
      record = owed!(ctx, thread.id, row)
      task = Task.async(fn -> Brain.forget(record) end)
      assert %{"t" => "forget", "id" => id, "session" => @session} = once_driver!(fake, row)
      written_and_reading!()
      holder = Brain.whereis(ctx.athanor_id, thread.id)

      status =
        inspect(:sys.get_status(holder, 1_000), limit: :infinity, printable_limit: :infinity)

      refute status =~ @session
      refute status =~ id
      refute status =~ inspect(:sys.get_state(holder).grant.owner_key)

      say(fake, row, %{"t" => "forgot", "id" => id, "session" => @session})
      assert Task.await(task, 5_000) == :forgot
    end

    test "an open held to just before the deadline and then the write: the write is cut at it, " <>
           "and the caller answered after the close",
         %{fake: fake, ctx: ctx, row: row} do
      Scripted.hold(fake, "opened", 30_000)
      until = due_in!(ctx, row, 3_000)
      assert_receive {:held, "opened", opening}, 2_000
      # sleep-ok: the open is held until just before the deadline, which is the case itself
      Process.sleep(max(until - 1_500 - System.monotonic_time(:millisecond), 0))

      Scripted.hold(fake, "send", 30_000)
      Scripted.hold(fake, "close", 30_000)
      say(fake, row, hello())
      send(opening, :go)
      assert_receive {:held, "send", writing}, 1_500

      assert_receive {:held, "close", closing}, by(until)
      refute_received {:asked, _answer}
      send(closing, :go)
      assert_receive {:asked, {:error, :lost}}, 1_000
      given_back!(fake, ctx, row)
      send(writing, :go)
    end

    test "an open out at the deadline is cut at it, and the caller answered after its lifetime's close",
         %{fake: fake, ctx: ctx, row: row} do
      Scripted.hold(fake, "opened", 30_000)
      until = due_in!(ctx, row, 1_500)
      assert_receive {:held, "opened", opening}, 1_500
      Scripted.hold(fake, "close", 30_000)

      assert_receive {:held, "close", closing}, by(until)
      # Longer than a release waits: only the holder's own wait on the
      # close of the lifetime it minted keeps the answer back.
      refute_receive {:asked, _answer}, Opus.Programs.Box.release_timeout_ms() + 500
      # The fake holds both of two closes that come at once, so a second is
      # told as held or as let through.
      refute_received {:held, "close", _second}
      refute_received {:session, "close", _through, _fields}
      send(closing, :go)
      assert_receive {:asked, {:error, :deadline}}, 1_000
      assert_receive {:session, "close", %{"lifetime" => lifetime}, _fields}, 1_000
      given_back!(fake, ctx, row)
      refute_received {:session, "close", %{"lifetime" => ^lifetime}, _fields}
      send(opening, :go)
    end

    test "a refused open's close, confirmed before its holder hears of either, is the only one",
         %{fake: fake, ctx: ctx, row: row} do
      Scripted.refuse_once(fake, "open", "capacity")
      Scripted.hold(fake, "open", 15_000)
      until = System.monotonic_time(:millisecond) + 60_000
      {holder, command} = one_command!(ctx, row, until)
      asked = :gen_server.send_request(holder, command)
      assert_receive {:held, "open", opening}, 3_000

      confirmed_unheard!(fake, holder, fn -> send(opening, :go) end)

      assert {:reply, {:error, {:refused, :capacity, _boot}}} =
               :gen_server.wait_response(asked, 1_000)

      refute_received {:session, "close", _wire, _fields}
      given_back!(fake, ctx, row)
    end

    test "a replaced row's close, confirmed before its holder hears of it, is the only one",
         %{fake: fake, ctx: ctx, row: row} do
      {_asker, holder, _id} = discovering!(fake, ctx, row)

      {1, _} =
        Arca.Repo.update_all(from(r in Arca.Schemas.McpServer, where: r.id == ^row.id),
          set: [epoch: row.epoch + 1]
        )

      changed = %{athanor_id: ctx.athanor_id, server_id: row.id, epoch: row.epoch + 1}

      successor =
        confirmed_unheard!(fake, holder, fn ->
          Task.async(fn ->
            with {:ok, _grant} <- Opus.Programs.hold(changed), do: Opus.Programs.release(changed)
          end)
        end)

      assert_receive {:asked, {:error, :lost}}, 1_000
      refute_received {:session, "close", _wire, _fields}
      assert Task.await(successor) == :ok
      given_back!(fake, ctx, row)
    end

    test "a hold out at the deadline is cut at it, and nothing is opened",
         %{fake: fake, ctx: ctx, row: row} do
      Scripted.hold(fake, "sync", 30_000)
      until = due_in!(ctx, row, 1_500)
      assert_receive {:held, "sync", syncing}, 1_500

      assert_receive {:asked, {:error, :backends_unavailable}}, by(until)
      send(syncing, :go)
      given_back!(fake, ctx, row)
      refute_received {:session, "open", _open, _fields}
    end

    test "a hold cut at the deadline answers only once its holder is no owner's",
         %{fake: fake, ctx: ctx, row: row} do
      Scripted.hold(fake, "sync", 30_000)
      until = due_in!(ctx, row, 1_500)
      assert_receive {:held, "sync", syncing}, 1_500
      controller = GenServer.whereis(Opus.Programs.via("local"))
      :ok = :sys.suspend(controller)

      try do
        # Past the deadline and short of a release's wait: a Box that cannot
        # hear the release keeps the answer back.
        refute_receive {:asked, _answer}, by(until)
      after
        :ok = :sys.resume(controller)
      end

      assert_receive {:asked, {:error, :backends_unavailable}}, 1_000
      refute is_map_key(:sys.get_state(controller).owners, {ctx.athanor_id, row.id})
      send(syncing, :go)
      given_back!(fake, ctx, row)
    end

    test "a stale boot's second hold has only what is left of the deadline",
         %{fake: fake, ctx: ctx, row: row} do
      Scripted.hold(fake, "open", 30_000)
      Scripted.refuse_once(fake, "open", "stale_boot")
      until = due_in!(ctx, row, 3_000)
      assert_receive {:held, "open", opening}, 2_000
      Scripted.hold(fake, "sync", 30_000)
      send(opening, :go)
      assert_receive {:held, "sync", syncing}, 2_000

      # The way out's release waits behind the sync still out, its bound.
      assert_receive {:asked, {:error, :backends_unavailable}},
                     by(until) + Opus.Programs.Box.release_timeout_ms()

      send(syncing, :go)
      given_back!(fake, ctx, row)
    end

    test "opens with little time left share the connection pool of those with plenty",
         %{fake: fake, ctx: ctx, row: row} do
      pools = fn -> DynamicSupervisor.count_children(Req.FinchSupervisor).active end
      listed_within!(fake, ctx, row, 20_000)
      warm = pools.()

      # No run of the others gives these, so a pool of each would be new.
      for ms <- [1_700, 2_100, 2_600, 3_300] do
        listed_within!(fake, ctx, row, ms)
        assert pools.() == warm, "an open with #{ms} ms left made a connection pool"
      end
    end

    test "nothing is asked of the box for a command whose deadline has passed",
         %{ctx: ctx, row: row} do
      _until = due_in!(ctx, row, 0)
      assert_receive {:asked, {:error, :deadline}}, 1_000
      refute_received {:control, "sync", _sync, _fields}
      refute_received {:session, "open", _open, _fields}
    end

    for path <- [:models, :forget] do
      test "a #{path}'s caller waits its deadline, the way out's bound and a margin",
           %{fake: fake, ctx: ctx, row: row, thread: thread} do
        record = owed!(ctx, thread.id, row)
        session = :trace.session_create(:brain_caller, self(), [])
        on_exit(fn -> :trace.session_destroy(session) end)
        :trace.process(session, :new_processes, true, [:call])
        :trace.function(session, {GenServer, :call, 3}, true, [])

        asked = System.monotonic_time(:millisecond)

        task =
          case unquote(path) do
            :models -> Task.async(fn -> Brain.models(ctx, row.id) end)
            :forget -> Task.async(fn -> Brain.forget(record) end)
          end

        %{"id" => id} = once_driver!(fake, row)
        say(fake, row, %{"t" => "refused", "id" => id, "reason" => "no"})
        assert Task.await(task, 5_000) == {:error, {:refused, "no"}}

        asker = task.pid

        assert_receive {:trace, ^asker, :call, {GenServer, :call, [_holder, message, wait]}}
                       when elem(message, 0) in [:once, :forget],
                       1_000

        deadline = elem(message, tuple_size(message) - 1) - asked
        box = Opus.Programs.Box

        # Both are read from what the caller sent: neither moves alone.
        assert_in_delta wait,
                        deadline + box.close_timeout_ms() + box.release_timeout_ms() + 5_000,
                        500
      end
    end

    for exit <- [
          :answer,
          :unreadable,
          :dropped,
          :row_ended,
          :stand_down,
          :shutdown,
          :driver_exit,
          :reader_death,
          :deadline,
          :refused_read,
          :write_unanswered,
          :open_refused
        ] do
      test "the caller's answer comes after the close: #{exit}",
           %{fake: fake, ctx: ctx, row: row} do
        Scripted.hold(fake, "close", 30_000)
        left_by!(unquote(exit), fake, ctx, row)
        assert_receive {:held, "close", closing}, 2_000
        refute_receive {:asked, _answer}, 300
        send(closing, :go)
        assert_receive {:asked, _answer}, 2_000
      end
    end

    test "a one command whose write meets its session ended for memory answers lost, and its " <>
           "holder ends without a crash",
         %{fake: fake, ctx: ctx, row: row} do
      test = self()
      Scripted.hold(fake, "send", 30_000)
      spawn(fn -> send(test, {:asked, Brain.models(ctx, row.id)}) end)
      assert_receive {:session, "open", _open, _fields}, 5_000
      first_read!()
      say(fake, row, hello())
      assert_receive {:held, "send", writing}, 5_000
      Scripted.end_sessions_for_memory(fake, row.id, :cap)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(writing, :go)
          assert_receive {:asked, answer}, 10_000
          assert answer == {:error, :lost}
          # A crash report is logged before its process is gone: once no
          # holder is left, every line it would log has been logged.
          wait_until(
            fn -> Registry.count(Opus.Brain.Registry) == 0 end,
            5_000,
            "the holder to end"
          )

          Logger.flush()
        end)

      refute log =~ "CaseClauseError"
      refute log =~ "terminating"
    end

    @tag :long
    @tag timeout: 180_000
    @tag ownership_timeout: 180_000
    test "at the real minute, a write begun just before the deadline is cut at it and its " <>
           "caller answered with nothing of the holder's left",
         %{fake: fake, ctx: ctx, row: row} do
      Scripted.hold(fake, "opened", 90_000)
      began = System.monotonic_time(:millisecond)
      test = self()
      spawn(fn -> send(test, {:asked, Brain.models(ctx, row.id)}) end)
      assert_receive {:held, "opened", opening}, 5_000
      renewing_until(began + 58_000)

      Scripted.hold(fake, "send", 30_000)
      say(fake, row, hello())
      send(opening, :go)
      assert_receive {:held, "send", writing}, 2_000

      assert_receive {:asked, answer}, 10_000
      assert answer == {:error, :lost}
      assert System.monotonic_time(:millisecond) - began < 64_000
      assert running_sessions(fake, row) == []
      state = :sys.get_state(Opus.Programs.via("local"))
      refute is_map_key(state.owners, {ctx.athanor_id, row.id})
      send(writing, :go)
    end

    test "a line that answers another command says nothing of the account",
         %{fake: fake, ctx: ctx, row: row} do
      task = Task.async(fn -> Brain.models(ctx, row.id) end)
      once_driver!(fake, row)

      say(fake, row, %{
        "t" => "refused",
        "id" => "mdl_another",
        "reason" => "Sign it in.",
        "account" => "signed_out"
      })

      assert Task.await(task, 10_000) == {:error, :unreadable}
      assert Brain.known(ctx, row.id, row.epoch).account == nil
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

  describe "a thread's deletion" do
    # A held session of `agent` in `thread`, on a row of its own so that
    # one driver's hello reaches only its own session: a running turn
    # whose start admitted that row, its holder opened, and the session
    # kept on the thread; the turn then ends, as a session outlives it.
    defp held!(fake, ctx, binding, thread, agent, name) do
      actor = Sanctum.Context.actor(ctx)
      row = brain_row!(ctx, name)

      {:ok, %{turn: turn}} =
        TurnStorage.accept_message(actor, thread.id, %{
          message: %{author: ctx.user_id, sent_by: "person", content: "work on it"},
          turn: %{agent: agent, requested_by: ctx.user_id, origin: :interactive}
        })

      set_turn(turn, status: "running")
      {:ok, turn} = TurnStorage.get(actor, turn.id)
      step = start_step!(ctx, turn, row)

      bound = %{
        binding
        | thread_id: thread.id,
          agent: agent,
          turn_id: turn.id,
          origin: turn.origin,
          fence: turn.fence,
          step: step.id,
          row_id: row.id,
          epoch: row.epoch,
          generation: 0
      }

      brain = opened!(fake, row, bound)
      keep_session!(actor, thread, row, agent, "#{name}-0000-4968-8776-000000000001")
      {brain, turn}
    end

    # The session kept as the attendant keeps a driver's `started`, with
    # the row it is stored with (`TurnStorage.commit_events/3`).
    defp keep_session!(actor, thread, row, agent, session) do
      {:ok, %{seen: false}} =
        TurnStorage.commit_events(actor, %{thread: thread.id, agent: agent, turn: nil}, %{
          events: [],
          position:
            {:session,
             %{
               generation: 0,
               boot: "boot-one",
               hello: true,
               seq: 1,
               row_id: row.id,
               epoch: row.epoch,
               silence_ms: Opus.Brain.silence_ms(),
               session: session
             }}
        })
    end

    # The room, a crew member's thread under it and a thread that read it,
    # each with its session held.
    defp three_held!(fake, ctx, binding, thread) do
      actor = Sanctum.Context.actor(ctx)
      {:ok, child} = Arca.ThreadStorage.crew_thread(actor, thread.id, "planner")
      {:ok, reader} = Arca.Test.Days.thread(actor)
      room = held!(fake, ctx, binding, thread, "aqua", "6f1e2d3c")
      crew = held!(fake, ctx, binding, child, "planner", "7f1e2d3c")
      {_brain, reading} = read = held!(fake, ctx, binding, reader, "aqua", "8f1e2d3c")

      set_turn(reading, read_threads: Arca.ThreadStorage.threads_text([thread.id]))

      {room, crew, read}
    end

    test "ends at once the holders of its thread's session, its child's and its reader's",
         %{fake: fake, ctx: ctx, binding: binding, thread: thread, turn: setup_turn} do
      set_turn(setup_turn, status: "completed")
      held = three_held!(fake, ctx, binding, thread)
      {{room, room_turn}, {crew, crew_turn}, {read, read_turn}} = held
      for turn <- [room_turn, crew_turn, read_turn], do: set_turn(turn, status: "completed")

      assert {:ok, %{cancelled: []}} = Aqua.Tape.delete_thread(ctx, thread.id)

      # Told before the deletion answers: no consumer runs under the suite
      # (`:brain_cleanup_enabled`), so no tick ended them.
      for {pid, ref} <- [room, crew, read] do
        assert_received {Brain, ^ref, {:ended, :forgotten}}
        refute Process.alive?(pid)
      end
    end

    test "a refused deletion ends none", %{
      fake: fake,
      ctx: ctx,
      binding: binding,
      thread: thread,
      turn: setup_turn
    } do
      set_turn(setup_turn, status: "completed")

      {{room, room_turn}, {crew, crew_turn}, {read, read_turn}} =
        three_held!(fake, ctx, binding, thread)

      for turn <- [room_turn, read_turn], do: set_turn(turn, status: "completed")
      # A running child turn ends only under the stamp its root's attempt
      # stores, and the store holds none for this one.
      set_turn(crew_turn, status: "running", attempt: "att_planner")

      assert {:error, :missing_grant} = Aqua.Tape.delete_thread(ctx, thread.id)

      for {pid, ref} <- [room, crew, read] do
        refute_received {Brain, ^ref, {:ended, _reason}}
        assert Process.alive?(pid)
      end
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
