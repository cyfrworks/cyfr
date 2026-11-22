# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Opus.Programs.TerminalTest do
  @moduledoc """
  A program's terminal session, owned by the server for one athanor and
  one person (`Opus.Programs.start/3` and the calls after it), against a
  scripted backends service (`Cyfr.Test.ScriptedBackends`) that speaks
  the wire: it runs the row's command with the starter's arguments on a
  terminal of the starter's size; any number of the person's processes
  attach and detach, and detaching ends nothing; a close names the
  session it was accepted for and is carried out whoever waits; a start
  past its deadline leaves its late answer to the box; a close answers
  closed, already gone or unanswered; it ends with its program, its row,
  its person's standing or a day unwatched; and no byte of its output
  reaches a status or an inspect.
  """
  use ExUnit.Case, async: false

  alias Cyfr.Test.ScriptedBackends, as: Scripted
  alias Emissary.External.Provider
  alias Opus.Programs

  @root :crypto.strong_rand_bytes(32)
  @size %{rows: 24, cols: 80}

  setup do
    Cyfr.Test.Sandbox.setup!()
    Arca.Cache.init()
    fake = Scripted.start(self(), @root)
    controller = Scripted.supervise_controller(url: fake.url, root: @root, tick_ms: 3_600_000)
    assert_receive {:control, "reconcile", _message, _fields}, 2_000

    {ctx, user} = person!("terminal-person")
    row = program_row(ctx, "claude")

    :ok =
      Cyfr.Bus.subscribe(
        Sanctum.Context.actor(ctx),
        Cyfr.Bus.programs(Sanctum.Context.actor(ctx), ctx.user_id)
      )

    {:ok, fake: fake, controller: controller, ctx: ctx, user: user, row: row}
  end

  # A person admitted as the product admits one, in an athanor of their own.
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
            config_json:
              Jason.encode!(%{"command" => "npx -y @anthropic-ai/claude-code", "env" => %{}})
          },
          over
        )
      )

    row
  end

  defp remote_row(ctx) do
    {:ok, row} =
      Arca.McpServerStorage.insert(Sanctum.Context.actor(ctx), %{
        cap: 0,
        name: "remote",
        url: "https://mcp.example.test/mcp",
        config_json: ~s({"headers":{}})
      })

    row
  end

  defp start!(ctx, row, opts \\ %{}) do
    assert {:ok, id} =
             Programs.start(
               ctx,
               row.id,
               Map.merge(%{args: []}, Map.merge(@size, opts))
             )

    assert_receive {:session, "open", %{"mode" => "terminal"}, _fields}, 2_000
    {id, backend_session(id)}
  end

  # The backend's id of the session the terminal `id` was given.
  defp backend_session(id), do: :sys.get_state(terminal(id)).session

  # The key the terminal `id` opened under: its one lifetime's.
  defp key_of(id), do: :sys.get_state(terminal(id)).lifetime.key

  defp terminal(id) do
    [{pid, _person}] = Registry.lookup(Opus.Programs.Registry, {:terminal, id})
    pid
  end

  defp eventually(check, what, deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    case check.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("timed out waiting for #{what}")

        # sleep-ok: poll interval of eventually's bounded wait (3 s)
        Process.sleep(10)
        eventually(check, what, deadline)

      value ->
        value
    end
  end

  defp flush_closes do
    receive do
      {:session, "close", _wire, _fields} -> flush_closes()
    after
      0 -> :ok
    end
  end

  # The id with one character of its proof changed.
  defp forged(id) do
    {named, <<first, rest::binary>>} = String.split_at(id, -43)
    named <> <<if(first == ?A, do: ?B, else: ?A)>> <> rest
  end

  defp gone?(id), do: Registry.lookup(Opus.Programs.Registry, {:terminal, id}) == []

  # CYFR stops and starts again: the box and the session's process die,
  # and nothing either held in memory is left.
  defp opus_restarted!(controller, id) do
    pid = terminal(id)
    Process.exit(controller, :kill)
    Process.exit(pid, :kill)

    eventually(
      fn ->
        box = GenServer.whereis(Programs.via("local"))
        box not in [nil, controller] and :sys.get_state(box).boot
      end,
      "a box in the killed one's place to greet the service"
    )
  end

  describe "a start" do
    test "runs the row's command with the starter's words on a terminal of their size, in the row's folder",
         %{ctx: ctx, row: row} do
      assert {:ok, id} =
               Programs.start(ctx, row.id, %{
                 rows: 30,
                 cols: 100,
                 args: ["auth", "login"]
               })

      home = row.id

      key = key_of(id)

      assert_receive {:session, "open",
                      %{
                        "mode" => "terminal",
                        "key" => ^key,
                        "lifetime" => ^key,
                        "home_id" => ^home,
                        "argv" => ["auth", "login"],
                        "rows" => 30,
                        "cols" => 100
                      }, _fields},
                     2_000

      assert {:ok,
              [
                %{
                  session: ^id,
                  row_id: ^home,
                  name: "claude",
                  kept: false,
                  attached: false,
                  by: :person
                }
              ]} =
               Programs.running(ctx)

      assert_receive %Cyfr.Bus.Program{kind: :started, session: ^id, name: "claude"}, 2_000
    end

    test "a scratch program runs in no folder", %{ctx: ctx} do
      row = program_row(ctx, "scratchy", %{home: "scratch", home_max_bytes: nil})
      assert {:ok, id} = Programs.start(ctx, row.id, Map.merge(@size, %{args: []}))
      key = key_of(id)
      assert_receive {:session, "open", %{"key" => ^key} = open, _fields}, 2_000
      refute Map.has_key?(open, "home_id")
    end

    test "is refused for what is not an enabled program of the caller's athanor, and for a bad size or bad words",
         %{ctx: ctx} do
      remote =
        remote_row(ctx)

      off = program_row(ctx, "off", %{enabled: false})
      {other_ctx, _user} = person!("someone-else")
      theirs = program_row(other_ctx, "theirs")
      start = &Programs.start(ctx, &1, Map.merge(%{args: []}, Map.merge(@size, &2)))

      assert {:error, :not_a_program} = start.(remote.id, %{})
      assert {:error, :disabled} = start.(off.id, %{})
      assert {:error, :not_found} = start.(theirs.id, %{})
      assert {:error, :invalid_size} = start.(off.id, %{rows: 0})
      assert {:error, :invalid_size} = start.(off.id, %{cols: 1001})
      assert {:error, :invalid_args} = start.(off.id, %{args: ["a\0b"]})
      assert {:error, :invalid_args} = start.(off.id, %{args: List.duplicate("x", 65)})
      refute_received {:session, "open", _message, _fields}
    end

    test "is refused to a caller who no longer stands", %{ctx: ctx, row: row} do
      denied = %{ctx | authenticated: false}

      assert {:error, :not_standing} =
               Programs.start(denied, row.id, Map.merge(@size, %{args: []}))

      refute_received {:session, "open", _message, _fields}
    end
  end

  describe "attaching" do
    test "answers what was printed before it and the size, then each write, and types and resizes",
         %{ctx: ctx, row: row, fake: fake} do
      {id, session} = start!(ctx, row)
      Scripted.write(fake, row.id, "Paste code here if prompted")

      eventually(
        fn -> :sys.get_state(terminal(id)).tail.bytes != "" end,
        "the first write to be read"
      )

      assert {:ok, %{tail: %Opus.Programs.Output{bytes: tail}, rows: 24, cols: 80, kept: false}} =
               Programs.attach(ctx, id)

      assert tail == "Paste code here if prompted\r\n"

      Scripted.write(fake, row.id, "second")

      assert_receive {Opus.Programs, ^id,
                      {:bytes, _delivery, %Opus.Programs.Output{bytes: "second\r\n"}}},
                     2_000

      assert :ok = Programs.input(ctx, id, "code-1234\r")
      encoded = Base.encode64("code-1234\r")
      assert_receive {:session, "input", %{"session" => ^session, "bytes" => ^encoded}, _}, 2_000

      assert :ok = Programs.resize(ctx, id, 50, 132)

      assert_receive {:session, "resize", %{"session" => ^session, "rows" => 50, "cols" => 132},
                      _},
                     2_000

      assert {:error, :invalid_size} = Programs.resize(ctx, id, 0, 132)

      # A second surface attaches to the same screen at its new size.
      other = Task.async(fn -> Programs.attach(ctx, id) end)
      assert {:ok, %{tail: %{bytes: both}, rows: 50, cols: 132}} = Task.await(other)
      assert both == "Paste code here if prompted\r\nsecond\r\n"
    end

    test "is the person's own: another person attaches to, types on and closes nothing",
         %{ctx: ctx, row: row} do
      {id, _session} = start!(ctx, row)
      {stranger, _user} = person!("stranger")
      same_athanor = %{ctx | user_id: stranger.user_id}

      for other <- [stranger, same_athanor] do
        assert {:error, :not_found} = Programs.attach(other, id)
        assert {:error, :not_found} = Programs.input(other, id, "x")
        assert {:error, :not_found} = Programs.resize(other, id, 10, 10)
        assert {:error, :not_found} = Programs.keep(other, id, true)
        assert {:ok, :already_gone} = Programs.close(other, id)
        assert {:ok, []} = Programs.running(other)
      end

      refute gone?(id)
      refute_received {:session, "close", _message, _fields}
    end

    # A key names its creator's athanor and person, and stands; it is no
    # person at a screen, so it reaches what a stranger reaches: nothing.
    # The sign-in relay's checks, and this owner's before, admitted it.
    test "a key carrying its creator's own ids finds none of their sessions",
         %{ctx: ctx, row: row} do
      {id, _session} = start!(ctx, row)

      {:ok, %{api_key: raw}} =
        Sanctum.TestContext.create_key(Sanctum.TestContext.issuer!(ctx), %{name: "terminal-key"})

      {:ok, key} = Sanctum.Caller.establish({:api_key, raw}, client_ip: "127.0.0.1")
      assert {key.athanor_id, key.user_id} == {ctx.athanor_id, ctx.user_id}

      assert {:error, :not_found} = Programs.attach(key, id)
      assert {:error, :not_found} = Programs.input(key, id, "x")
      assert {:error, :not_found} = Programs.resize(key, id, 10, 10)
      assert {:error, :not_found} = Programs.keep(key, id, true)
      assert :ok = Programs.detach(key, id)
      assert {:ok, :already_gone} = Programs.close(key, id)
      assert {:ok, []} = Programs.running(key)

      assert {:error, :not_found} =
               Programs.start(key, row.id, Map.merge(@size, %{args: []}))

      refute gone?(id)
      assert {:ok, [%{session: ^id, kept: false}]} = Programs.running(ctx)
      refute_received {:session, "close", _message, _fields}
      refute_received {:session, "input", _message, _fields}
    end

    # Whose a session is is read beside its name, before it is asked
    # anything: a stranger's answer is the same whether the session is
    # busy, here suspended, or missing. Asked of the process first, a
    # stranger's close of a busy session timed out as unanswered.
    test "a stranger's answer does not depend on the session's state", %{ctx: ctx, row: row} do
      {id, _session} = start!(ctx, row)
      {stranger, _user} = person!("stranger-busy")
      :ok = :sys.suspend(terminal(id))

      try do
        assert {:ok, :already_gone} = Programs.close(stranger, id)
        assert {:error, :not_found} = Programs.attach(stranger, id)
        assert {:error, :not_found} = Programs.keep(stranger, id, true)
        assert {:ok, :already_gone} = Programs.close(stranger, "trm_missing")
      after
        :sys.resume(terminal(id))
      end

      refute gone?(id)
    end

    test "a detach and an attached process's exit end nothing", %{ctx: ctx, row: row} do
      {id, _session} = start!(ctx, row)

      page =
        spawn(fn ->
          {:ok, _} = Programs.attach(ctx, id)
          Process.sleep(:infinity)
        end)

      eventually(fn -> :sys.get_state(terminal(id)).subscribers != %{} end, "the page to attach")
      Process.exit(page, :kill)

      eventually(
        fn -> :sys.get_state(terminal(id)).subscribers == %{} end,
        "the page's exit to be seen"
      )

      assert {:ok, _} = Programs.attach(ctx, id)
      assert :ok = Programs.detach(ctx, id)
      refute gone?(id)
      assert {:ok, [%{session: ^id, attached: false}]} = Programs.running(ctx)
    end
  end

  # The orderings a session held by a page got wrong: each case would fail
  # on the sign-in relay, whose one session per caller and row was keyed by
  # the caller's credential and lived only while its one subscriber did.
  describe "orderings" do
    # The relay's key was the caller's binding: a second start of the same
    # row by the same caller reached the same backend session, so the close
    # a page sent for the first ended the second.
    test "a close names the session it was accepted for, so an older page's close never ends a newer start",
         %{ctx: ctx, row: row} do
      {first, first_session} = start!(ctx, row)
      {second, second_session} = start!(ctx, row)
      assert first_session != second_session

      assert {:ok, :closed} = Programs.close(ctx, first)
      assert_receive {:session, "close", %{"session" => ^first_session}, _}, 2_000
      assert {:ok, :already_gone} = Programs.close(ctx, first)

      refute_received {:session, "close", %{"session" => ^second_session}, _}
      assert :ok = Programs.input(ctx, second, "still here\r")
      assert {:ok, [%{session: ^second}]} = Programs.running(ctx)
    end

    # The relay's attach answered whatever state it held, and its
    # unattended timer was all that ended a session no page held; here an
    # attach stops only the day's clock of an unwatched session, and one
    # that arrives while a close is being carried out finds nothing.
    test "an attach cancels only an unwatched session's cleanup, never an accepted close",
         %{ctx: ctx, row: row, fake: fake} do
      {id, session} = start!(ctx, row)
      pid = terminal(id)
      %{idle: {day, token}} = :sys.get_state(pid)

      # An attach stops the clock of a session no one watched.
      assert {:ok, _} = Programs.attach(ctx, id)
      assert %{idle: nil} = :sys.get_state(pid)
      assert Process.read_timer(day) == false
      # A message of that clock already sent ends nothing.
      send(pid, {:idle, token})
      assert :ok = Programs.detach(ctx, id)
      refute gone?(id)

      # An attach that reaches the session while its accepted close is
      # carried out finds it gone, and the close is carried out.
      Scripted.hold(fake, "close")
      closing = Task.async(fn -> Programs.close(ctx, id) end)
      assert_receive {:held, "close", backend}, 2_000

      attaching = Task.async(fn -> Programs.attach(ctx, id) end)

      eventually(
        fn ->
          {:messages, messages} = Process.info(pid, :messages)
          Enum.any?(messages, &match?({:"$gen_call", _from, {:attach, _person, _pid}}, &1))
        end,
        "the attach to reach the session during its close"
      )

      send(backend, :go)

      assert {:ok, :closed} = Task.await(closing)
      assert {:error, :not_found} = Task.await(attaching)
      assert_receive {:session, "close", %{"session" => ^session}, _}, 2_000
      eventually(fn -> gone?(id) end, "the session to end")
    end

    # The relay closed its session from the page's process or on the page's
    # exit; a close accepted from a page that is then gone is carried out
    # all the same, by the session's owner.
    test "an accepted close is carried out after the page is gone", %{
      ctx: ctx,
      row: row,
      fake: fake
    } do
      {id, session} = start!(ctx, row)
      Scripted.hold(fake, "close")
      test = self()

      page =
        spawn(fn ->
          send(test, {:closing, self()})
          Programs.close(ctx, id)
        end)

      assert_receive {:closing, ^page}
      assert_receive {:held, "close", backend}, 2_000
      Process.exit(page, :kill)
      refute Process.alive?(page)
      send(backend, :go)

      assert_receive {:session, "close", %{"session" => ^session}, _}, 2_000
      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^id, reason: :closed}, 2_000
      eventually(fn -> gone?(id) end, "the session to end")
      assert {:ok, []} = Programs.running(ctx)
    end

    # The relay's start held its open in the supervisor's start of the
    # relay, keyed by the caller: a late answer stood under the key a retry
    # would reach. Here the box settles the late answer and a new start is
    # a session of its own at once.
    test "a refused start leaves its late answer to the box, and a new start can be made at once",
         %{ctx: ctx, row: row, fake: fake} do
      Scripted.hold(fake, "opened")
      deadline = System.system_time(:millisecond) + 500
      opts = Map.merge(@size, %{args: []})

      late = Task.async(fn -> Programs.start(ctx, row.id, Map.put(opts, :deadline, deadline)) end)
      assert_receive {:held, "opened", answer}, 2_000
      assert {:error, :deadline} = Task.await(late, 3_000)

      assert {:ok, again} = Programs.start(ctx, row.id, opts)
      assert {:ok, [%{session: ^again}]} = Programs.running(ctx)

      send(answer, :go)

      kept = key_of(again)

      [late_session] =
        for {session, %{key: key}} <- Scripted.sessions(fake, row.id), key != kept, do: session

      assert_receive {:session, "close", %{"session" => ^late_session}, _}, 3_000
      assert {:ok, [%{session: ^again}]} = Programs.running(ctx)
    end

    # The box answers in time, the session's owner reads it late (paused
    # here), and its start has answered :deadline by then: the start is
    # refused, so the session is nobody's and ends, and the box closes
    # what it gave. The owner took any open it read, and the refused start
    # became a running session nobody saw start.
    test "a start refused for its deadline ends, though the box answered in time",
         %{ctx: ctx, row: row, fake: fake, controller: controller} do
      Scripted.hold(fake, "opened")
      deadline = System.system_time(:millisecond) + 1_500
      opts = Map.merge(@size, %{args: [], deadline: deadline})
      late = Task.async(fn -> Programs.start(ctx, row.id, opts) end)
      assert_receive {:held, "opened", answer}, 2_000

      [terminal] =
        Registry.select(Opus.Programs.Registry, [{{{:terminal, :_}, :"$1", :_}, [], [:"$1"]}])

      :ok = :sys.suspend(terminal)
      send(answer, :go)

      # The box gave the session to its holder inside the deadline.
      session =
        eventually(
          fn ->
            if :sys.get_state(controller).sessions != %{},
              do: fake |> Scripted.sessions(row.id) |> Map.keys() |> List.first()
          end,
          "the box to give the session"
        )

      assert {:error, :deadline} = Task.await(late, 5_000)
      :sys.resume(terminal)

      assert_receive {:session, "close", %{"session" => ^session}, _}, 3_000
      eventually(fn -> not Process.alive?(terminal) end, "the refused start to end")
      assert {:ok, []} = Programs.running(ctx)
    end

    # The service holds the close past the box's close window: the
    # transport times out, the close is unanswered and still owed, and the
    # session has ended all the same.
    @tag timeout: 60_000
    test "a close the service does not answer in time is unanswered, and ends the session",
         %{ctx: ctx, row: row, fake: fake, controller: controller} do
      {id, _session} = start!(ctx, row)
      key = key_of(id)
      Scripted.hold(fake, "close", 50_000)
      closing = Task.async(fn -> Programs.close(ctx, id) end)
      assert_receive {:held, "close", backend}, 2_000

      assert {:error, :unanswered} = Task.await(closing, 40_000)
      eventually(fn -> gone?(id) end, "the session to end")
      assert [%{key: ^key}] = Map.keys(:sys.get_state(controller).closing)
      send(backend, :go)
    end

    test "an unconfirmed close tells every tab unanswered, and a retry never says gone while it is owed",
         %{ctx: ctx, row: row, fake: fake} do
      {id, _session} = start!(ctx, row)
      {:ok, _} = Programs.attach(ctx, id)
      test = self()

      second =
        Task.async(fn ->
          {:ok, _} = Programs.attach(ctx, id)
          send(test, :second_attached)

          receive do
            {Opus.Programs, ^id, {:ended, reason}} -> reason
          after
            10_000 -> :not_told
          end
        end)

      assert_receive :second_attached, 2_000
      Scripted.refuse_once(fake, "close", "unavailable")
      assert {:error, :unanswered} = Programs.close(ctx, id)

      assert Task.await(second) == :unanswered
      assert_receive {Opus.Programs, ^id, {:ended, mine}}, 2_000
      assert mine == :unanswered
      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^id, reason: announced}, 2_000
      assert announced == :unanswered
      eventually(fn -> gone?(id) end, "the session to end")

      Scripted.refuse_once(fake, "close", "unavailable")
      assert {:error, :unanswered} = Programs.close(ctx, id)

      # Another person learns nothing of it, owed or not.
      {other, _user} = person!("owed-close-stranger")
      assert {:ok, :already_gone} = Programs.close(other, id)

      # Confirmed, it is gone.
      assert {:ok, :already_gone} = Programs.close(ctx, id)
    end

    test "a close of a killed session's process waits on what it left",
         %{ctx: ctx, row: row, fake: fake} do
      {id, _session} = start!(ctx, row)
      Scripted.hold(fake, "close")
      Process.exit(terminal(id), :kill)
      assert_receive {:held, "close", backend}, 2_000
      eventually(fn -> gone?(id) end, "the session's process to be gone")

      retry = Task.async(fn -> Programs.close(ctx, id) end)
      assert Task.yield(retry, 300) == nil, "already gone was said of a close still owed"
      send(backend, :go)
      assert Task.await(retry) == {:ok, :already_gone}
    end

    test "a browser's session whose holder went is closed only once the close is confirmed",
         %{ctx: ctx, fake: fake} do
      browser = browser_row(ctx)
      holder = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, id} = browser_start(ctx, browser.id, holder)
      key = key_of(id)
      assert_receive {:session, "open", %{"key" => ^key}, _fields}, 2_000

      Scripted.refuse_once(fake, "close", "unavailable")
      Process.exit(holder, :kill)

      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^id, reason: reason}, 5_000
      assert reason == :unanswered
    end

    test "after a restart of Opus its owner's close ends a live terminal by its id, and nobody else's does",
         %{ctx: ctx, row: row, fake: fake, controller: controller} do
      {id, session} = start!(ctx, row)
      {stranger, _user} = person!("terminal-stranger-after-restart")

      # Until the new box's reconcile lands, the terminal runs on.
      Scripted.hold(fake, "reconcile", 30_000)
      opus_restarted!(controller, id)
      assert_receive {:held, "reconcile", reconciling}, 3_000
      on_exit(fn -> send(reconciling, :go) end)
      flush_closes()

      assert {:ok, :already_gone} = Programs.close(stranger, id)

      # Another starter of the same person's, and an id changed by one byte.
      assert {:ok, :already_gone} =
               Programs.close(Programs.browser(ctx.athanor_id, ctx.user_id), id)

      assert {:ok, :already_gone} = Programs.close(ctx, forged(id))
      refute_received {:session, "close", _wire, _fields}
      assert %{^session => %{running: true}} = Scripted.sessions(fake, row.id)

      assert {:ok, :already_gone} = Programs.close(ctx, id)

      assert %{^session => %{running: false}} = Scripted.sessions(fake, row.id),
             "already gone was said of a terminal that still runs"

      send(reconciling, :go)
    end

    test "a close answers closed, already gone, or that the service did not answer",
         %{ctx: ctx, row: row, fake: fake, controller: controller} do
      {closed, _session} = start!(ctx, row)
      assert {:ok, :closed} = Programs.close(ctx, closed)
      assert {:ok, :already_gone} = Programs.close(ctx, closed)
      assert {:ok, :already_gone} = Programs.close(ctx, "trm_never")

      {unanswered, session} = start!(ctx, row)
      Scripted.refuse_once(fake, "close", "internal")
      assert {:error, :unanswered} = Programs.close(ctx, unanswered)
      assert_receive {:session, "close", %{"session" => ^session}, _}, 2_000
      eventually(fn -> gone?(unanswered) end, "the session to end")

      # The close stays owed until the service confirms it: with no holder
      # left the owner is released, and the next tick's close needs none.
      server = row.id

      assert_receive {:control, "release", %{"owners" => [%{"server" => ^server}]}, _}, 3_000

      eventually(
        fn ->
          send(controller, :tick)
          not Map.has_key?(:sys.get_state(controller).closing, session)
        end,
        "the owed close to settle on a tick"
      )
    end
  end

  describe "it ends" do
    test "when its program exits, telling whoever is attached", %{ctx: ctx, row: row, fake: fake} do
      {id, _session} = start!(ctx, row)
      {:ok, _} = Programs.attach(ctx, id)
      Scripted.end_sessions(fake, row.id, 0)
      assert_receive {Opus.Programs, ^id, {:ended, :exited}}, 3_000
      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^id, reason: :exited}, 2_000
    end

    # A reader that died left the session listed and unread for good.
    test "when nothing can read it any more, and is closed", %{ctx: ctx, row: row} do
      {id, session} = start!(ctx, row)
      {:ok, _} = Programs.attach(ctx, id)
      %{reader: reader} = :sys.get_state(terminal(id))
      Process.exit(reader, :kill)

      assert_receive {Opus.Programs, ^id, {:ended, :exited}}, 2_000
      assert_receive {:session, "close", %{"session" => ^session}, _}, 2_000
      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^id, reason: :exited}, 2_000
      eventually(fn -> gone?(id) end, "the session to end")
      assert {:ok, []} = Programs.running(ctx)
    end

    # A session's owner killed outright says nothing of its end; the box,
    # which closes what its holder left, announces it on the person's
    # topic, so no page or shelf shows a session that is gone.
    test "when its owner dies outright, announced by the box, and is closed",
         %{ctx: ctx, row: row} do
      {id, session} = start!(ctx, row)
      Process.exit(terminal(id), :kill)

      assert_receive {:session, "close", %{"session" => ^session}, _}, 2_000

      assert_receive %Cyfr.Bus.Program{
                       kind: :ended,
                       session: ^id,
                       row_id: row_id,
                       name: "claude",
                       reason: :exited
                     },
                     2_000

      assert row_id == row.id
      assert {:ok, []} = Programs.running(ctx)
    end

    test "when its row changes or goes", %{ctx: ctx, row: row} do
      {id, session} = start!(ctx, row)
      {:ok, _} = Programs.attach(ctx, id)
      :ok = Programs.end_mounts(ctx.athanor_id, row.id)
      assert_receive {Opus.Programs, ^id, {:ended, :row_changed}}, 2_000
      assert_receive {:session, "close", %{"session" => ^session}, _}, 2_000
    end

    # The real clock, at a short period: what a program prints starts it
    # again, the one before it cancelled, so one timer runs at a time; a
    # kept session has none. The clock's timer was never cancelled before,
    # every print leaving another running for a day.
    test "after its period with nothing attached and nothing printed, unless kept", %{
      ctx: ctx,
      row: row,
      fake: fake
    } do
      {kept, _} = start!(ctx, row)
      assert :ok = Programs.keep(ctx, kept, true)
      assert %{idle: nil, kept: true} = :sys.get_state(terminal(kept))
      assert_receive %Cyfr.Bus.Program{kind: :changed, session: ^kept, kept: true}, 2_000

      Prima.Test.Env.put_app_env(:cyfr, :program_idle_ms, 600)
      {id, session} = start!(ctx, row)
      %{idle: {first, _token}} = :sys.get_state(terminal(id))
      Scripted.write(fake, row.id, "printed")

      eventually(
        fn -> match?(%{idle: {timer, _}} when timer != first, :sys.get_state(terminal(id))) end,
        "the print to start the clock again"
      )

      assert Process.read_timer(first) == false
      assert_receive {:session, "close", %{"session" => ^session}, _}, 3_000
      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^id, reason: :idle}, 2_000
      assert {:ok, [%{session: ^kept}]} = Programs.running(ctx)
    end

    test "when its person no longer stands, and not when a browser signs out",
         %{ctx: ctx, row: row, user: user} do
      {id, _session} = start!(ctx, row)
      {:ok, _} = Programs.attach(ctx, id)

      Cyfr.Bus.broadcast_global(
        Cyfr.Bus.sessions(),
        %Cyfr.Bus.Session{kind: :revoked, user_id: user.id, reason: :signed_out}
      )

      send(terminal(id), :standing)
      # sleep-ok: 100 ms after the standing check in which a browser's sign-out must not end the
      # terminal
      Process.sleep(100)
      refute gone?(id)

      {:ok, _} = Sanctum.Tenancy.Users.deny(user)
      assert_receive {Opus.Programs, ^id, {:ended, :standing}}, 3_000
      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^id, reason: :standing}, 2_000
    end
  end

  describe "the gate's open" do
    test "starts the named program for the person with their words and size", %{
      ctx: ctx,
      row: row
    } do
      assert {:ok, %{session: id, program: "claude"}} =
               Provider.handle("mcp_servers", ctx, %{
                 "action" => "open",
                 "name" => "claude",
                 "terminal_args" => ["--version"],
                 "rows" => 40,
                 "cols" => 120
               })

      home = row.id

      key = key_of(id)

      assert_receive {:session, "open",
                      %{
                        "key" => ^key,
                        "argv" => ["--version"],
                        "rows" => 40,
                        "cols" => 120,
                        "home_id" => ^home
                      }, _},
                     2_000

      assert {:ok, [%{session: ^id}]} = Programs.running(ctx)
    end

    # The request log's record of an open is the catalogue's logged input,
    # sanitized (`Sanctum.Dispatch`, `Sanctum.RequestLog.opened/3`): who
    # opened which program at what size, never the words after its command.
    test "its request log record keeps the program and size, not the words" do
      canary = "review-private-password-8e59"

      input = %{
        "action" => "open",
        "name" => "installed-tool",
        "terminal_args" => ["login", "--password", canary],
        "rows" => 24,
        "cols" => 80
      }

      assert Sanctum.Catalog.logged_input("mcp_servers", input) |> Prima.Sanitizer.sanitize() ==
               %{
                 "action" => "open",
                 "name" => "installed-tool",
                 "terminal_args" => "[REDACTED]",
                 "rows" => 24,
                 "cols" => 80
               }
    end

    test "refuses a missing program, a tool server elsewhere and a bad size", %{ctx: ctx} do
      remote_row(ctx)

      open = &Provider.handle("mcp_servers", ctx, Map.merge(%{"action" => "open"}, &1))
      assert {:error, {:not_found, "Server", "nobody"}} = open.(%{"name" => "nobody"})
      assert {:error, {:invalid_argument, tool}} = open.(%{"name" => "remote"})
      assert tool =~ "tool server elsewhere"
      assert {:error, {:invalid_argument, size}} = open.(%{"name" => "claude", "rows" => 0})
      assert size =~ "rows and cols"
      refute_received {:session, "open", _message, _fields}
    end
  end

  # What a program prints crosses into the server only as fast as it is
  # taken: before, the reader asked for the next output as soon as it had
  # sent the last, and every attached process was handed every output.
  describe "what a program prints is bounded" do
    test "against a paused owner, one read is outstanding and nothing piles up",
         %{ctx: ctx, row: row, fake: fake} do
      {id, _session} = start!(ctx, row)
      pid = terminal(id)
      %{reader: reader} = :sys.get_state(pid)
      :ok = :sys.suspend(pid)

      for round <- 1..5 do
        for i <- 1..4, do: Scripted.write(fake, row.id, "round #{round} line #{i}")
        # sleep-ok: 150 ms a round for the program's writes to pile up at the paused owner, if
        # anything let them
        Process.sleep(150)
      end

      {:messages, messages} = Process.info(pid, :messages)
      assert Enum.count(messages, &match?({:read, _output, _running}, &1)) == 1
      assert {:message_queue_len, 0} = Process.info(reader, :message_queue_len)

      :sys.resume(pid)

      eventually(
        fn -> :sys.get_state(pid).tail.bytes =~ "round 5 line 4" end,
        "what waited in the service to be read once the owner took the first"
      )
    end

    test "a process that never says it took its output is handed nothing more, and " <>
           "at most the tail is kept for it; once it does, it gets the tail and goes on",
         %{ctx: ctx, row: row, fake: fake} do
      {id, _session} = start!(ctx, row)
      {:ok, _} = Programs.attach(ctx, id)
      Scripted.write(fake, row.id, "first")
      assert_receive {Opus.Programs, ^id, {:bytes, first, %{bytes: "first\r\n"}}}, 2_000

      line = String.duplicate("x", 10_000)
      for i <- 1..40, do: Scripted.write(fake, row.id, "#{i}:" <> line)
      eventually(fn -> :sys.get_state(terminal(id)).tail.bytes =~ "40:" end, "all to be read")
      refute_receive {Opus.Programs, ^id, {_kind, _delivery, _output}}, 300

      me = self()

      assert %{subscribers: %{^me => %{pending: pending, lost: true}}} =
               :sys.get_state(terminal(id))

      assert byte_size(pending.bytes) == 256 * 1024

      # It took the first: it is handed the tail, which replaces its screen.
      assert :ok = Programs.taken(ctx, id, first)
      assert_receive {Opus.Programs, ^id, {:tail, kept, %{bytes: tail}}}, 2_000
      assert byte_size(tail) == 256 * 1024
      assert String.ends_with?(tail, "40:" <> line <> "\r\n")

      # It took the tail too: what comes next is handed at once.
      assert :ok = Programs.taken(ctx, id, kept)
      Scripted.write(fake, row.id, "more")
      assert_receive {Opus.Programs, ^id, {:bytes, _delivery, %{bytes: "more\r\n"}}}, 2_000
    end

    # An acknowledgement that named nothing, and then one that named a
    # count, let a process that read nothing be handed output after output
    # by naming what it had not received: only the token of the delivery
    # outstanding for it counts, and that token is only in the delivery.
    test "only the token of the outstanding delivery counts; a guessed, repeated or " <>
           "never-sent one changes nothing",
         %{ctx: ctx, row: row, fake: fake} do
      {id, _session} = start!(ctx, row)
      {:ok, _} = Programs.attach(ctx, id)
      Scripted.write(fake, row.id, "first")
      assert_receive {Opus.Programs, ^id, {:bytes, first, %{bytes: "first\r\n"}}}, 2_000
      assert is_binary(first) and byte_size(first) >= 22

      line = String.duplicate("y", 10_000)

      for round <- 1..40 do
        Scripted.write(fake, row.id, "#{round}:" <> line)

        for guess <- ["1", "2", Integer.to_string(round + 1), "", first <> "x"],
            do: assert(:ok = Programs.taken(ctx, id, guess))
      end

      eventually(fn -> :sys.get_state(terminal(id)).tail.bytes =~ "40:" end, "all to be read")
      refute_receive {Opus.Programs, ^id, {_kind, _delivery, _output}}, 300

      me = self()

      assert %{subscribers: %{^me => %{outstanding: ^first, lost: true}}} =
               :sys.get_state(terminal(id))

      # The right token hands what was kept, once: repeated, it no longer
      # names the delivery outstanding, and hands nothing more.
      assert :ok = Programs.taken(ctx, id, first)
      assert_receive {Opus.Programs, ^id, {:tail, kept, _tail}}, 2_000
      assert kept != first
      assert :ok = Programs.taken(ctx, id, first)
      Scripted.write(fake, row.id, "after")
      eventually(fn -> :sys.get_state(terminal(id)).tail.bytes =~ "after" end, "it to be read")
      refute_receive {Opus.Programs, ^id, {_kind, _delivery, _output}}, 300

      # The right one again releases the next.
      assert :ok = Programs.taken(ctx, id, kept)
      assert_receive {Opus.Programs, ^id, {:bytes, _next, %{bytes: "after\r\n"}}}, 2_000
    end

    # The end used to be sent at once, and what was held for a process
    # that owed its acknowledgement was dropped with it.
    test "a process that owes its acknowledgement is handed the last output, then the end",
         %{ctx: ctx, row: row, fake: fake} do
      {id, _session} = start!(ctx, row)
      {:ok, _} = Programs.attach(ctx, id)
      Scripted.write(fake, row.id, "first")
      assert_receive {Opus.Programs, ^id, {:bytes, _first, %{bytes: "first\r\n"}}}, 2_000
      Scripted.write(fake, row.id, "the last line")
      Scripted.end_sessions(fake, row.id, 0)

      assert_receive {Opus.Programs, ^id, {kind, _last, %{bytes: last}}}, 3_000
      assert kind == :bytes
      assert last == "the last line\r\n"
      assert_receive {Opus.Programs, ^id, {:ended, :exited}}, 3_000
    end

    test "one input carries at most the wire's one input message",
         %{ctx: ctx, row: row} do
      {id, _session} = start!(ctx, row)
      max = Prima.LocusBackends.max_chunk_bytes()
      assert {:error, :too_large} = Programs.input(ctx, id, :binary.copy("a", max + 1))
      refute_received {:session, "input", _message, _fields}
      assert :ok = Programs.input(ctx, id, :binary.copy("a", max))
      assert_receive {:session, "input", _message, _fields}, 2_000
    end
  end

  # The words after a program's command were redacted only at the top of
  # the terminal's own state: its debug log kept them in every earlier
  # state, and the box held them in each open it had in flight.
  describe "the words a program starts with are printed nowhere" do
    @words_secret "review-private-argv-c840"

    test "a terminal's status with its debug log on, and its crash, print none of them",
         %{ctx: ctx, row: row} do
      {id, _session} = start!(ctx, row, %{args: ["login", "--password", @words_secret]})
      pid = terminal(id)
      :ok = :sys.log(pid, true)
      assert :ok = Programs.keep(ctx, id, true)

      status = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)
      refute status =~ @words_secret
      assert status =~ "#Opus.Programs.Words<3 words>"

      ref = Process.monitor(pid)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          # A cast no clause takes: the failed callback's frame carries the
          # state, which is where a crash report can print it.
          GenServer.cast(pid, :no_such_cast)

          assert_receive {:DOWN, ^ref, :process, _pid,
                          {:function_clause,
                           [
                             {Opus.Programs.Terminal, :handle_cast, [:no_such_cast, _state],
                              _where}
                             | _stack
                           ]}},
                         5_000
        end)

      assert log =~ "Opus.Programs.Terminal.handle_cast/2"
      refute log =~ @words_secret
    end

    test "the box's status and a crash of its callback, with the open in flight, print " <>
           "none of them",
         %{ctx: ctx, row: row, fake: fake} do
      box = GenServer.whereis(Programs.via("local"))
      :ok = :sys.log(box, true)
      Scripted.hold(fake, "opened", 5_000)

      start =
        Task.async(fn ->
          Programs.start(ctx, row.id, %{
            rows: 24,
            cols: 80,
            args: ["login", "--password", @words_secret]
          })
        end)

      assert_receive {:session, "open", %{"argv" => ["login", "--password", @words_secret]}, _},
                     2_000

      eventually(fn -> :sys.get_state(box).opens != %{} end, "the open to be in flight")
      state = :sys.get_state(box)
      [{ref, %{params: %{argv: %Opus.Programs.Words{}}}}] = Map.to_list(state.opens)

      status = inspect(:sys.get_status(box), limit: :infinity, printable_limit: :infinity)
      refute status =~ @words_secret
      assert status =~ "#Opus.Programs.Words<3 words>"

      # The callback that settles the open, raising on an answer it cannot
      # read, as a crash report would print it: its arguments carry the
      # state, the open's words in it.
      {_kind, _reason, stack} =
        try do
          apply(Opus.Programs.Box, :handle_info, [{:session_opened, ref, :unreadable}, state])
        catch
          kind, reason -> {kind, reason, __STACKTRACE__}
        end

      refute inspect(stack, limit: :infinity, printable_limit: :infinity) =~ @words_secret
      assert {:ok, "trm_" <> _} = Task.await(start, 10_000)
    end
  end

  describe "nothing it carries is printed" do
    test "its status and an inspect of its output show sizes, never bytes", %{
      ctx: ctx,
      row: row,
      fake: fake
    } do
      {id, _session} = start!(ctx, row)
      secret = "sk-ant-oat01-terminal-secret"
      Scripted.write(fake, row.id, secret)
      eventually(fn -> :sys.get_state(terminal(id)).tail.bytes != "" end, "the write to be read")

      status =
        inspect(:sys.get_status(terminal(id)), limit: :infinity, printable_limit: :infinity)

      refute status =~ secret
      assert status =~ "#Opus.Programs.Output<"

      assert {:ok, %{tail: tail}} = Programs.attach(ctx, id)
      assert inspect(tail) == "#Opus.Programs.Output<#{byte_size(secret) + 2} bytes>"
      assert inspect({Opus.Programs, id, {:bytes, "token", tail}}) =~ "#Opus.Programs.Output<"
    end

    # The debug log keeps every message the process handled and the state
    # after it; status wrapped only the state's tail and the message in
    # hand, so earlier states and messages printed the program's bytes.
    test "a debug log of its messages and states prints none of the output",
         %{ctx: ctx, row: row, fake: fake} do
      {id, _session} = start!(ctx, row)
      pid = terminal(id)
      :ok = :sys.log(pid, true)
      secret = "sk-ant-oat01-logged-secret"

      Scripted.write(fake, row.id, secret)
      eventually(fn -> :sys.get_state(pid).tail.bytes =~ secret end, "the write to be read")
      assert {:ok, _attached} = Programs.attach(ctx, id)
      Scripted.write(fake, row.id, secret <> "-again")
      assert_receive {Opus.Programs, ^id, {:bytes, _delivery, _output}}, 2_000

      {:ok, events} = :sys.log(pid, :get)
      assert events != []
      refute inspect(events, limit: :infinity, printable_limit: :infinity) =~ secret

      status = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)
      refute status =~ secret
      assert status =~ "#Opus.Programs.Output<"
    end

    # A process that dies prints its state, its last message and its log;
    # a callback that raises prints its arguments. Every one of them holds
    # output only as an `Output`.
    test "a crash of the process, or of a callback holding output, prints none of it",
         %{ctx: ctx, row: row, fake: fake} do
      {id, _session} = start!(ctx, row)
      pid = terminal(id)
      :ok = :sys.log(pid, true)
      secret = "sk-ant-oat01-crashed-secret"
      Scripted.write(fake, row.id, secret)
      eventually(fn -> :sys.get_state(pid).tail.bytes =~ secret end, "the write to be read")
      ref = Process.monitor(pid)

      log =
        ExUnit.CaptureLog.capture_log([level: :error], fn ->
          # A cast no clause takes: the failed callback's frame carries the
          # state, which is where a crash report can print it.
          GenServer.cast(pid, :no_such_cast)

          assert_receive {:DOWN, ^ref, :process, _pid,
                          {:function_clause,
                           [
                             {Opus.Programs.Terminal, :handle_cast, [:no_such_cast, _state],
                              _where}
                             | _stack
                           ]}},
                         5_000
        end)

      assert log =~ "Opus.Programs.Terminal.handle_cast/2"
      refute log =~ secret

      output = Opus.Programs.Output.new(secret)

      {_kind, reason, stack} =
        try do
          # A state missing what the callback reads, so it raises holding
          # the output; called through `apply/3`, as a process would.
          apply(Opus.Programs.Terminal, :handle_info, [{:read, output, true}, %{tail: output}])
        catch
          kind, reason -> {kind, reason, __STACKTRACE__}
        end

      refute inspect(reason, limit: :infinity, printable_limit: :infinity) =~ secret
      refute inspect(stack, limit: :infinity, printable_limit: :infinity) =~ secret
    end
  end

  defp browser_row(ctx, chrome \\ :person),
    do:
      program_row(ctx, Programs.Definition.browser_name(chrome), %{
        memory_bytes: 1_073_741_824,
        home_max_bytes: nil,
        config_json: Jason.encode!(%{"command" => "cyfr-browser", "env" => %{}})
      })

  defp browser_start(ctx, row_id, held_by \\ self()),
    do:
      Programs.start(
        Programs.browser(ctx.athanor_id, ctx.user_id),
        row_id,
        Map.merge(@size, %{args: [], held_by: held_by})
      )

  describe "the person's browser, a third owner" do
    test "starts the row of the browser's own definition alone, one at a time, and that row for no one else",
         %{ctx: ctx, row: row} do
      browser = browser_row(ctx)

      assert {:error, :not_browser} = browser_start(ctx, row.id)
      refute_received {:session, "open", _message, _fields}

      assert {:ok, id} = browser_start(ctx, browser.id)
      key = key_of(id)
      assert_receive {:session, "open", %{"key" => ^key}, _fields}, 2_000

      assert [{_pid, {athanor, user, :browser}}] =
               Registry.lookup(Opus.Programs.Registry, {:terminal, id})

      assert {athanor, user} == {ctx.athanor_id, ctx.user_id}

      assert {:error, :already_running} = browser_start(ctx, browser.id)

      # Not the person's own terminal: the row of the browser starts for
      # its owner alone.
      assert {:error, {:invalid_argument, sentence}} =
               Programs.start(ctx, browser.id, Map.merge(@size, %{args: []}))

      assert sentence =~ "Aqua's browser"

      refute_received {:session, "open", _message, _fields}
    end

    test "its second row, for work kept apart, starts a session of its own beside the first, one of each at a time",
         %{ctx: ctx} do
      browser = browser_row(ctx)
      apart = browser_row(ctx, :apart)

      # Each row's session runs in that row's own kept folder.
      assert {:ok, first} = browser_start(ctx, browser.id)
      first_key = key_of(first)
      assert_receive {:session, "open", %{"key" => ^first_key, "home_id" => first_home}, _}, 2_000
      assert {:ok, second} = browser_start(ctx, apart.id)
      second_key = key_of(second)

      assert_receive {:session, "open", %{"key" => ^second_key, "home_id" => second_home}, _},
                     2_000

      assert {first_home, second_home} == {browser.id, apart.id}

      assert {:error, :already_running} = browser_start(ctx, browser.id)
      assert {:error, :already_running} = browser_start(ctx, apart.id)

      {:ok, sessions} = Programs.running(Programs.browser(ctx.athanor_id, ctx.user_id))
      assert Enum.sort(Enum.map(sessions, & &1.row_id)) == Enum.sort([browser.id, apart.id])
      refute_received {:session, "open", _message, _fields}
    end

    test "it is held by one process from its start: one that names none starts nothing, and the session ends when it is gone, a person's own detaching as before",
         %{ctx: ctx, row: row} do
      browser = browser_row(ctx)

      assert {:error, :invalid_args} =
               Programs.start(
                 Programs.browser(ctx.athanor_id, ctx.user_id),
                 browser.id,
                 Map.merge(@size, %{args: []})
               )

      refute_received {:session, "open", _message, _fields}

      holder = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, id} = browser_start(ctx, browser.id, holder)
      key = key_of(id)
      assert_receive {:session, "open", %{"key" => ^key}, _fields}, 2_000
      Process.exit(holder, :kill)

      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^id, by: :browser, reason: :closed},
                     5_000

      # A person's own session outlives a process that attached to it.
      {mine, _session} = start!(ctx, row)
      test = self()

      watcher =
        spawn(fn ->
          send(test, {:attached, Programs.attach(ctx, mine)})
          Process.sleep(:infinity)
        end)

      assert_receive {:attached, {:ok, _tail}}, 2_000
      Process.exit(watcher, :kill)
      # sleep-ok: 100 ms after the watcher's kill in which the person's own session must not end
      Process.sleep(100)
      refute gone?(mine)
    end

    test "the person lists it as the browser's and closes it, and reaches nothing else of it",
         %{ctx: ctx} do
      browser = browser_row(ctx)
      {:ok, id} = browser_start(ctx, browser.id)
      key = key_of(id)
      assert_receive {:session, "open", %{"key" => ^key}, _fields}, 2_000

      assert {:ok, [%{session: ^id, by: :browser, name: "aqua-browser"}]} = Programs.running(ctx)
      assert {:error, :not_found} = Programs.attach(ctx, id)
      assert {:error, :not_found} = Programs.input(ctx, id, "typed")

      # Another person finds nothing of it.
      {other, _user} = person!("someone-else")
      assert {:ok, []} = Programs.running(other)
      assert {:ok, :already_gone} = Programs.close(other, id)

      assert {:ok, :closed} = Programs.close(ctx, id)

      assert_receive %Cyfr.Bus.Program{kind: :ended, session: ^id, by: :browser, reason: :closed},
                     2_000
    end

    test "its owner stands only while its person does", %{ctx: ctx, user: user} do
      browser = browser_row(ctx)
      owner = Programs.browser(ctx.athanor_id, ctx.user_id)
      assert {:ok, {athanor, user_id, :browser}} = Programs.caller(owner)
      assert {athanor, user_id} == {ctx.athanor_id, ctx.user_id}

      {:ok, id} = browser_start(ctx, browser.id)
      assert {:ok, _attached} = Programs.attach(owner, id)

      {:ok, _} = Sanctum.Tenancy.Users.deny(user)
      assert_receive {Opus.Programs, ^id, {:ended, :standing}}, 3_000
      assert {:error, :not_standing} = Programs.caller(owner)
    end
  end
end
