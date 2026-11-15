# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.TurnSessionTest do
  @moduledoc """
  A turn's own program sessions (`Opus.Programs` with a turn caller, the
  `program` tool's provider), against the scripted backends service: the
  turn is proved from the store from the gate's lineage, never from an
  argument; a turn reaches only the sessions it started, a person's
  screen only lists and closes them, and a turn never reaches a person's;
  what a session printed is read by offset, bounded and counted; a turn
  holds a few at once; a session ends with its turn, and one whose
  program exited answers its last output until then.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Arca.ThreadStorage, as: Threads
  alias Arca.TurnStorage
  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Opus.Programs
  alias Opus.Programs.Provider

  @root :crypto.strong_rand_bytes(32)

  setup do
    Cyfr.Test.Sandbox.setup!()
    Arca.Cache.init()
    fake = Scripted.start(self(), @root)
    controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "reconcile", _message, _fields}, 2_000

    {ctx, _user} = person!("turn-person")
    row = program_row(ctx, "gh")
    {turn, lineage} = turn!(ctx)

    :ok =
      Cyfr.Bus.subscribe(
        Sanctum.Context.actor(ctx),
        Cyfr.Bus.programs(Sanctum.Context.actor(ctx), ctx.user_id)
      )

    {:ok, fake: fake, controller: controller, ctx: ctx, row: row, turn: turn, lineage: lineage}
  end

  defp person!(key) do
    {:ok, user} = Sanctum.Test.People.linked(%{id: key, provider: "local", verified: true})
    athanor = Sanctum.Test.People.athanor!(user)

    ctx = %{
      Sanctum.TestContext.local()
      | user_id: user.id,
        athanor_id: athanor.id,
        permissions: MapSet.new([:*])
    }

    {ctx, user}
  end

  defp program_row(ctx, name, over \\ %{}) do
    {:ok, row} =
      Arca.McpServerStorage.insert(
        Sanctum.Context.actor(ctx),
        Map.merge(
          %{
            cap: 0,
            name: name,
            transport: "program",
            mark: "driven",
            url: nil,
            home: "kept",
            memory_bytes: 1_073_741_824,
            home_max_bytes: 2_147_483_648,
            config_json: Jason.encode!(%{"command" => name, "env" => %{}})
          },
          over
        )
      )

    row
  end

  # A running turn of a thread of the person's, its root execution set as
  # its start sets it, and the lineage the gate stamps on its own calls.
  defp turn!(ctx, opts \\ []) do
    actor = Sanctum.Context.actor(ctx)

    thread =
      Keyword.get_lazy(opts, :thread, fn ->
        {:ok, thread} = Threads.create(actor)
        thread
      end)

    {:ok, %{turn: turn}} =
      TurnStorage.accept_message(actor, thread.id, %{
        message: %{author: ctx.user_id, sent_by: "person", content: "run gh"},
        turn: %{
          agent: "aqua",
          requested_by: Keyword.get(opts, :requested_by, ctx.user_id),
          origin: :interactive
        }
      })

    root = "exe_turn_root_#{System.unique_integer([:positive])}"

    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [root_execution_id: root, status: "running"]
      )

    lineage = %{
      "thread_id" => thread.id,
      "root_execution_id" => root,
      "parent_execution_id" => root
    }

    {%{turn | root_execution_id: root, status: "running"}, lineage}
  end

  defp set_status(turn, status) do
    {1, _} =
      Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
        set: [status: status]
      )
  end

  # A root authority whose ingress edge grants exactly `program.<action>`.
  defp granting(action) do
    node = "formula:local.program-gate"

    graph = %{
      "canonical" => "jcs-1",
      "nodes" => %{
        node => %{
          "limits" => %{
            "timeout" => "1m",
            "max_memory_bytes" => 67_108_864,
            "max_request_size" => 1_048_576,
            "max_response_size" => 5_242_880,
            "rate_limit" => %{"requests" => 10_000, "window" => "1m"},
            "max_concurrent_tasks" => 10,
            "batch_timeout" => "1m"
          },
          "edges" => %{"@ingress" => %{"tools" => ["program.#{action}"]}}
        }
      }
    }

    {:ok, blob} = Prima.Authority.Blob.parse(graph)

    {:ok, authority} =
      Prima.Authority.root(
        %{
          profile_id: "prof-program-gate",
          consent_id: "consent-program-gate",
          source_ref: node,
          kind: :owner,
          invoke_mode: :open_inert,
          activation: %{node => "sha256:program-gate"}
        },
        blob,
        ceiling: Sanctum.Policy.Ceiling.platform_ceiling()
      )

    authority
  end

  defp guest(ctx), do: Sanctum.Context.enter_guest(ctx)
  defp turn_caller(ctx, lineage), do: Programs.turn(guest(ctx), lineage)

  defp call(ctx, lineage, action, args),
    do:
      Provider.handle("program", guest(ctx), Map.merge(args, Map.put(lineage, "action", action)))

  defp start!(ctx, lineage, row, args \\ %{}) do
    assert {:ok, %{session: id} = answer} =
             call(
               ctx,
               lineage,
               "start",
               Map.merge(%{"program" => row.id, "epoch" => row.epoch, "wait_ms" => 0}, args)
             )

    assert_receive {:session, "open", %{"key" => ^id} = open, _fields}, 2_000
    {id, Map.put(open, "session", backend_session(id)), answer}
  end

  # The backend's id of the session the box opened under `key`.
  defp backend_session(key) do
    Enum.find_value(:sys.get_state(Programs.via("local")).sessions, fn
      {{_a, _s, _h, ^key}, %{session: session}} -> session
      _other -> nil
    end)
  end

  defp terminal(id) do
    [{pid, _owner}] = Registry.lookup(Opus.Programs.Registry, {:terminal, id})
    pid
  end

  defp eventually(check, what, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    case check.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("timed out waiting for #{what}")

        Process.sleep(10)
        eventually(check, what, deadline)

      truthy ->
        truthy
    end
  end

  # A gate answer's body, keyed by strings as a wire reader reads it.
  defp jsonish({:ok, answer}), do: {:ok, answer |> Jason.encode!() |> Jason.decode!()}
  defp jsonish(other), do: other

  defp written(id, bytes),
    do: eventually(fn -> :sys.get_state(terminal(id)).written >= bytes end, "#{bytes} bytes")

  describe "the caller" do
    test "a turn's own call starts a session the turn owns, with its words, started by Aqua",
         %{ctx: ctx, row: row, turn: turn, lineage: lineage} do
      {id, open, answer} =
        start!(ctx, lineage, row, %{"terminal_args" => ["repo", "view", "cyfr/cyfr"]})

      assert open["argv"] == ["repo", "view", "cyfr/cyfr"]
      assert open["rows"] == 50 and open["cols"] == 200

      assert answer == %{
               session: id,
               program: "gh",
               output: "",
               next: 0,
               dropped: 0,
               running: true,
               ended: nil
             }

      assert [{_pid, {athanor, user, turn_id}}] =
               Registry.lookup(Opus.Programs.Registry, {:terminal, id})

      assert {athanor, user, turn_id} == {ctx.athanor_id, ctx.user_id, turn.id}

      # The person lists it, started by Aqua; the turn lists it too.
      assert {:ok, [%{session: ^id, by: :aqua, row_id: row_id}]} = Programs.running(ctx)
      assert row_id == row.id
      assert {:ok, [%{session: ^id}]} = Programs.running(turn_caller(ctx, lineage))
    end

    test "is a turn only as the store holds it: a lineage of no open turn of the person's reaches nothing",
         %{ctx: ctx, row: row, lineage: lineage} do
      {other_person, _user} = person!("other-person")
      {_their_turn, theirs} = turn!(other_person)
      {:ok, thread} = Threads.create(Sanctum.Context.actor(ctx))

      {_asked_by_another, asked_by_another} =
        turn!(ctx, thread: thread, requested_by: other_person.user_id)

      {ended_turn, ended} = turn!(ctx)

      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^ended_turn.id),
          set: [status: "completed"]
        )

      refused = [
        # A component the turn started calls with its own execution as parent.
        Map.put(lineage, "parent_execution_id", "exe_a_hand"),
        # No such root in that thread.
        Map.put(lineage, "root_execution_id", "exe_nobody"),
        # Another thread's id with this turn's root.
        Map.put(lineage, "thread_id", thread.id),
        # Another person's turn, named in this person's call.
        theirs,
        # A turn of this person's thread another person asked for.
        asked_by_another,
        # A turn that ended.
        ended,
        # No lineage at all.
        %{}
      ]

      for bad <- refused do
        args = %{"program" => row.id, "epoch" => row.epoch}

        assert {:error, {:not_found, _what, _that}} =
                 Provider.handle(
                   "program",
                   guest(ctx),
                   Map.merge(args, Map.put(bad, "action", "start"))
                 ),
               inspect(bad)

        assert {:error, :not_found} = Programs.rows(turn_caller(ctx, bad))
      end

      refute_received {:session, "open", _message, _fields}
    end

    test "a context outside a chain, or a key's chain, is no turn", %{
      ctx: ctx,
      row: row,
      lineage: lineage
    } do
      key = %{guest(ctx) | auth_method: :api_key, api_key_id: "key_1"}
      args = Map.merge(lineage, %{"action" => "start", "program" => row.id, "epoch" => row.epoch})

      # The person's screen context, handed a lineage, is not a turn's call.
      assert {:error, :not_found} =
               Programs.start({:turn, ctx, lineage}, row.id, %{rows: 2, cols: 2, args: []})

      assert {:error, {:not_found, _, _}} = Provider.handle("program", key, args)
      refute_received {:session, "open", _message, _fields}
    end

    test "the gate offers the tool in a chain alone", %{ctx: ctx} do
      assert {:error, %Prima.Refusal{stage: :admission}} =
               Sanctum.Gate.call_external("program", ctx, %{"action" => "list"})
    end

    test "list names the enabled programs by id, name, command and epoch, nothing else",
         %{ctx: ctx, row: row, lineage: lineage} do
      _off = program_row(ctx, "off", %{enabled: false})

      {:ok, _remote} =
        Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
          cap: 0,
          name: "remote",
          url: "https://mcp.example.test/mcp",
          config_json: ~s({"headers":{}})
        })

      assert {:ok, %{programs: [listed]}} = call(ctx, lineage, "list", %{})
      assert listed == %{id: row.id, name: "gh", command: "gh", epoch: row.epoch}
    end
  end

  describe "a turn that is not running" do
    test "keeps its sessions, printing, and neither reads nor types on them until it runs again",
         %{ctx: ctx, row: row, turn: turn, fake: fake} do
      ctx = %{ctx | origin: :interactive}
      lineage = Cyfr.Test.AttemptFixtures.lineage!(ctx, %{thread_id: turn.thread_id})

      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
          set: [root_execution_id: lineage.root_execution_id, attempt: lineage.attempt]
        )

      stamped = Map.new(lineage, fn {key, value} -> {Atom.to_string(key), value} end)
      {id, _open, _answer} = start!(ctx, stamped, row)

      {:ok, _paused} =
        TurnStorage.pause(Sanctum.Context.actor(ctx), turn.id, %{
          fence: turn.fence,
          reason: "approval"
        })

      gate = fn action, args ->
        Sanctum.Gate.call_in_chain(
          "program",
          guest(ctx),
          Map.merge(%{"action" => action, "session" => id}, args),
          granting(action),
          lineage: lineage
        )
      end

      assert {:error, _} = gate.("read", %{})
      assert {:error, _} = gate.("send", %{"terminal_input" => "execute\r"})
      # A stop is answered as a stranger's, and ends nothing.
      assert {:ok, %{stopped: :already_gone}} = gate.("stop", %{})
      assert {:error, _} = gate.("list", %{})
      refute_received {:session, "input", _message, _fields}

      # It goes on printing meanwhile, and its session stays.
      Scripted.write(fake, row.id, "while paused")
      written(id, 1)
      assert {:ok, [%{session: ^id}]} = Programs.running(ctx)

      set_status(turn, "running")
      assert {:ok, %{"output" => "while paused\n"}} = jsonish(gate.("read", %{}))
    end

    test "an accepted, paused or ended turn reaches nothing of its sessions",
         %{ctx: ctx, row: row, turn: turn, lineage: lineage} do
      {id, _open, _answer} = start!(ctx, lineage, row)

      for status <- ~w(accepted paused completed failed cancelled uncertain) do
        set_status(turn, status)

        assert {:error, {:not_found, _, _}} = call(ctx, lineage, "read", %{"session" => id}),
               status

        assert {:error, :not_found} = Programs.rows(turn_caller(ctx, lineage)), status
      end
    end
  end

  describe "who reaches a session" do
    test "a person's screen lists and closes the turn's session, and attaches to, types on and reads nothing of it",
         %{ctx: ctx, row: row, lineage: lineage} do
      {id, _open, _answer} = start!(ctx, lineage, row)

      assert {:error, :not_found} = Programs.attach(ctx, id)
      assert {:error, :not_found} = Programs.input(ctx, id, "y\r")
      assert {:error, :not_found} = Programs.read(ctx, id, 0)
      assert {:error, :not_found} = Programs.keep(ctx, id, true)
      assert {:error, :not_found} = Programs.resize(ctx, id, 10, 10)
      refute_received {:session, "input", _message, _fields}

      assert {:ok, :closed} = Programs.close(ctx, id)
      assert_receive {:session, "close", _message, _fields}, 2_000
      assert {:error, {:not_found, _, _}} = call(ctx, lineage, "read", %{"session" => id})
    end

    test "a turn reaches no session a person started, nor another turn's, nor another person's",
         %{ctx: ctx, row: row, lineage: lineage} do
      assert {:ok, person_session} = Programs.start(ctx, row.id, %{rows: 24, cols: 80, args: []})
      {_second_turn, second} = turn!(ctx)
      {theirs, _open, _answer} = start!(ctx, second, row)

      for id <- [person_session, theirs] do
        for {action, args} <- [
              {"read", %{}},
              {"wait", %{"ms" => 0}},
              {"send", %{"terminal_input" => "x"}}
            ] do
          assert {:error, {:not_found, _, _}} =
                   call(ctx, lineage, action, Map.put(args, "session", id)),
                 "#{action} #{id}"
        end

        assert {:ok, %{stopped: :already_gone}} = call(ctx, lineage, "stop", %{"session" => id})
      end

      assert {:ok, [%{session: ^theirs}]} = Programs.running(turn_caller(ctx, second))

      {stranger, _user} = person!("turn-stranger")
      assert {:ok, []} = Programs.running(stranger)
      assert {:ok, :already_gone} = Programs.close(stranger, theirs)
    end
  end

  describe "a start" do
    test "names the row's epoch: a row changed since is not started",
         %{ctx: ctx, row: row, lineage: lineage} do
      assert {:error, {:invalid_argument, message}} =
               call(ctx, lineage, "start", %{"program" => row.id, "epoch" => row.epoch + 1})

      assert message == "The program changed since it was shown; ask again"
      refute_received {:session, "open", _message, _fields}
    end

    test "a turn holds four sessions at once, ended ones it has not stopped among them",
         %{ctx: ctx, row: row, lineage: lineage, fake: fake} do
      sessions = for _ <- 1..4, do: elem(start!(ctx, lineage, row), 0)
      Scripted.end_sessions(fake, row.id, 0)

      eventually(
        fn -> Enum.all?(sessions, &(:sys.get_state(terminal(&1)).ended == :exited)) end,
        "the programs to exit"
      )

      assert {:error, {:invalid_argument, message}} =
               call(ctx, lineage, "start", %{"program" => row.id, "epoch" => row.epoch})

      assert message == "This turn already runs 4 programs; stop one first"

      assert {:ok, %{stopped: :already_gone}} =
               call(ctx, lineage, "stop", %{"session" => hd(sessions)})

      start!(ctx, lineage, row)
    end
  end

  describe "what a turn reads" do
    test "a start answers what its program printed once it paused, and a read reads on from next",
         %{ctx: ctx, row: row, lineage: lineage, fake: fake} do
      {id, _open, _answer} = start!(ctx, lineage, row)
      Scripted.write(fake, row.id, "\e[1mOwner\e[0m: cyfr")
      written(id, 1)

      assert {:ok, %{output: "Owner: cyfr\n", next: next, running: true}} =
               call(ctx, lineage, "wait", %{"session" => id, "after" => 0, "ms" => 5_000})

      Scripted.write(fake, row.id, "Stars: 3")

      assert {:ok, %{output: "Stars: 3\n", running: true}} =
               call(ctx, lineage, "wait", %{"session" => id, "after" => next, "ms" => 5_000})

      assert {:ok, %{output: "Owner: cyfr\nStars: 3\n"}} =
               call(ctx, lineage, "read", %{"session" => id})
    end

    test "a wait with nothing new answers when its time passes", %{
      ctx: ctx,
      row: row,
      lineage: lineage
    } do
      {id, _open, _answer} = start!(ctx, lineage, row)
      started = System.monotonic_time(:millisecond)

      assert {:ok, %{output: "", next: 0, running: true}} =
               call(ctx, lineage, "wait", %{"session" => id, "after" => 0, "ms" => 300})

      assert System.monotonic_time(:millisecond) - started >= 300
    end

    test "keeps the last 256 KiB counted from the first byte, and answers 64 KiB a read",
         %{ctx: ctx, row: row, lineage: lineage, fake: fake} do
      {id, _open, _answer} = start!(ctx, lineage, row)
      line = String.duplicate("x", 1022)

      # 300 lines of 1024 bytes each, with their line ends.
      for _ <- 1..300, do: Scripted.write(fake, row.id, line)
      written(id, 300 * 1024)
      kept = 256 * 1024
      first = 300 * 1024 - kept

      assert {:ok, %{from: ^first, next: next, dropped: ^first, output: output}} =
               Programs.read(turn_caller(ctx, lineage), id, 0)

      assert next == first + 64 * 1024
      assert byte_size(output.bytes) == 64 * 1024

      assert {:ok, %{from: ^next, dropped: 0}} =
               Programs.read(turn_caller(ctx, lineage), id, next)

      assert {:ok, %{next: last, output: %{bytes: ""}}} =
               Programs.read(turn_caller(ctx, lineage), id, 400 * 1024)

      assert last == 300 * 1024
    end

    test "a send types at most 64 KiB, with Enter when asked",
         %{ctx: ctx, row: row, lineage: lineage} do
      {id, open, _answer} = start!(ctx, lineage, row)
      session = open["session"]

      assert {:ok, %{sent: 2}} =
               call(ctx, lineage, "send", %{
                 "session" => id,
                 "terminal_input" => "y",
                 "enter" => true
               })

      encoded = Base.encode64("y\r")
      assert_receive {:session, "input", %{"session" => ^session, "bytes" => ^encoded}, _}, 2_000

      assert {:error, {:invalid_argument, "Too much to type at once"}} =
               call(ctx, lineage, "send", %{
                 "session" => id,
                 "terminal_input" => String.duplicate("a", 64 * 1024 + 1)
               })
    end

    test "the text has no escape sequences or controls, and its lines end in newlines" do
      assert Provider.text("\e]0;title\a\e[31mred\e[0m\r\nnext\rover\e(B\x07\x00 tab\tend") ==
               "red\nnext\nover tab\tend"

      assert Provider.text(<<"ok ", 0xFF, " done">>) == "ok � done"
    end

    test "an answer is an outside source named by its program" do
      assert [%Prima.Source{class: :outside, name: "gh"}] =
               Provider.answer_sources(nil, %{program: "gh", output: "x"})
    end
  end

  describe "its end" do
    test "a program that exits keeps its last output and its ending for its turn, and the turn's end ends it",
         %{ctx: ctx, row: row, lineage: lineage, fake: fake, turn: turn} do
      {id, open, _answer} = start!(ctx, lineage, row)
      session = open["session"]
      Scripted.write(fake, row.id, "done")
      written(id, 1)
      Scripted.end_sessions(fake, row.id, 0)

      assert_receive {:session, "close", %{"session" => ^session}, _}, 3_000

      assert {:ok, %{output: "done\n", running: false, ended: "exited"}} =
               call(ctx, lineage, "wait", %{"session" => id, "after" => 0, "ms" => 5_000})

      # It is no longer running for the person, and nothing types on it.
      assert {:ok, []} = Programs.running(ctx)

      assert {:error, {:invalid_argument, _}} =
               call(ctx, lineage, "send", %{"session" => id, "terminal_input" => "x"})

      pid = terminal(id)
      ref = Process.monitor(pid)
      :ok = Programs.end_turn(ctx.athanor_id, turn.id)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "the turn's end ends a running session, and leaves another turn's",
         %{ctx: ctx, row: row, lineage: lineage, turn: turn} do
      {id, open, _answer} = start!(ctx, lineage, row)
      {_second, second} = turn!(ctx)
      {other, _open, _answer} = start!(ctx, second, row)
      session = open["session"]

      :ok = Programs.end_turn(ctx.athanor_id, turn.id)
      assert_receive {:session, "close", %{"session" => ^session}, _}, 2_000
      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^id, reason: :standing}, 2_000
      assert {:ok, [%{session: ^other}]} = Programs.running(ctx)
    end

    test "a turn that ended without saying so ends its sessions at the next standing check",
         %{ctx: ctx, row: row, lineage: lineage, turn: turn} do
      {id, open, _answer} = start!(ctx, lineage, row)
      session = open["session"]
      send(terminal(id), :standing)
      assert {:ok, [_still]} = Programs.running(ctx)

      {1, _} =
        Arca.Repo.update_all(from(t in Arca.Schemas.Turn, where: t.id == ^turn.id),
          set: [status: "cancelled"]
        )

      send(terminal(id), :standing)
      assert_receive {:session, "close", %{"session" => ^session}, _}, 2_000
    end
  end
end
