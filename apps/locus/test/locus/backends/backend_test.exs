# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Backends.BackendTest do
  @moduledoc """
  One session over a launcher, end to end through the test environment's
  `Locus.DirectLauncher`: lines sent come back through `cat`; a `recv`
  waits for a line or its bound and is replayed by the same `after`; a
  closed session answers `running: false` at once and every later send
  `:ended`; an exit of its own with a status other than 0 is a crash and
  one with 0 is not; a line past its bound kills the process as a crash;
  an idle session ends; the owner's secrets are masked in lines and in
  the stderr tail; a session on a pseudo-terminal shows a prompt that
  waits for its answer. Against `Locus.Test.FakeKeeper` through
  `Locus.Keeper`: the spawn a session asks for is in the pool `backends`,
  with its argv, its environment and its memory bound.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Locus.Backends.Backend
  alias Locus.Test.FakeKeeper

  @token "tok-0123456789abcdef"
  @owner %{athanor: "athanor-1", server: "server-1", g: 1, e: 1}

  setup do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    {:ok, supervisor: supervisor}
  end

  defp start_session(supervisor, command, opts \\ []) do
    spec =
      Map.merge(
        %{
          argv: ["/bin/sh", "-c", command],
          env: %{"PROBE_TOKEN" => @token},
          pool: "backends",
          memory_bytes: Locus.Config.backends_memory_bytes()
        },
        Map.new(Keyword.get(opts, :spec, []))
      )

    opts =
      [
        owner: @owner,
        session: "ss_" <> String.duplicate("0", 32),
        program: "probe",
        spec: spec,
        secrets: [@token],
        launcher: Locus.DirectLauncher,
        notify: self(),
        stop_grace_ms: 500
      ]
      |> Keyword.merge(Keyword.delete(opts, :spec))

    {:ok, session} = DynamicSupervisor.start_child(supervisor, {Backend, opts})
    assert_receive {Backend, ^session, :started}, 10_000
    session
  end

  defp texts(%{lines: lines}), do: Enum.map(lines, & &1.text)

  # Every line past `after`, read until `n` have come.
  defp read(session, after_seq, n, seen \\ []) do
    if length(seen) >= n do
      seen
    else
      %{lines: lines} = Backend.recv(session, after_seq, 5_000)
      assert lines != [], "no line came"
      read(session, List.last(lines).seq, n, seen ++ Enum.map(lines, & &1.text))
    end
  end

  test "lines sent come back, and a recv is replayed by the same after", %{
    supervisor: supervisor
  } do
    session = start_session(supervisor, "exec cat")

    assert :running = Backend.send_lines(session, ["one", "two"])
    assert read(session, 0, 2) == ["one", "two"]

    # Asked again with the same after, the same lines; past them, none.
    assert texts(Backend.recv(session, 0, 0)) == ["one", "two"]
    assert %{lines: [], running: true} = Backend.recv(session, 2, 0)

    # A recv with nothing to read waits its bound and answers none.
    started = System.monotonic_time(:millisecond)
    assert %{lines: [], running: true} = Backend.recv(session, 2, 200)
    assert System.monotonic_time(:millisecond) - started >= 200

    # A waiting recv answers as soon as a line comes.
    task = Task.async(fn -> Backend.recv(session, 2, 10_000) end)
    Process.sleep(100)
    :running = Backend.send_lines(session, ["three"])
    assert texts(Task.await(task)) == ["three"]
  end

  test "a closed session answers running false at once, its sends ended, and is no crash", %{
    supervisor: supervisor
  } do
    session = start_session(supervisor, "exec cat")
    :running = Backend.send_lines(session, ["kept"])
    assert read(session, 0, 1) == ["kept"]

    assert :ok = Backend.close(session)
    assert %{running: false, lines: [%{text: "kept"}]} = Backend.recv(session, 0, 5_000)
    assert :ended = Backend.send_lines(session, ["late"])
    assert_receive {Backend, ^session, {:ended, %{crash: false}}}, 5_000
    assert_receive {Backend, ^session, :vacated}, 5_000
  end

  test "an exit of its own is a crash unless its status is 0, and its last lines stay readable",
       %{supervisor: supervisor} do
    crashed = start_session(supervisor, "echo last; exit 3")
    assert_receive {Backend, ^crashed, {:ended, %{crash: true, error: error}}}, 10_000
    assert error =~ "code=3"
    assert %{running: false, lines: [%{text: "last"}]} = Backend.recv(crashed, 0, 5_000)

    clean = start_session(supervisor, "echo done")
    assert_receive {Backend, ^clean, {:ended, %{crash: false, error: nil}}}, 10_000
    assert %{running: false} = Backend.recv(clean, 0, 0)
  end

  test "a line past its bound kills the process, as a crash", %{supervisor: supervisor} do
    session =
      start_session(supervisor, "exec cat", bounds: [max_line_bytes: 16])

    :running = Backend.send_lines(session, [String.duplicate("x", 32)])
    assert_receive {Backend, ^session, {:ended, %{crash: true, error: "line too long"}}}, 10_000
    assert_receive {Backend, ^session, :vacated}, 10_000
    assert %{running: false} = Backend.recv(session, 0, 0)
  end

  test "a session no send and no recv used within the idle period ends", %{
    supervisor: supervisor
  } do
    now = :counters.new(1, [])
    clock = fn -> :counters.get(now, 1) end
    session = start_session(supervisor, "exec cat", clock: clock)

    Backend.retire_if_idle(session, 1_000)
    assert %{running: true} = Backend.recv(session, 0, 0)

    :counters.add(now, 1, 1_000)
    Backend.retire_if_idle(session, 1_000)
    assert_receive {Backend, ^session, {:ended, %{crash: false}}}, 5_000
  end

  test "the owner's secrets are masked in its lines and its stderr tail", %{
    supervisor: supervisor
  } do
    session =
      start_session(
        supervisor,
        ~s(echo "token=$PROBE_TOKEN"; echo "err $PROBE_TOKEN" >&2; exec cat)
      )

    assert read(session, 0, 1) == ["token=[REDACTED]"]
    wait_until(fn -> Backend.status(session, 5_000).stderr_tail =~ "err" end, 10_000)
    tail = Backend.status(session, 5_000).stderr_tail
    assert tail =~ "err [REDACTED]"
    refute tail =~ @token
    refute inspect(:sys.get_status(session), limit: :infinity) =~ @token
  end

  test "on a pseudo-terminal a prompt that waits is read, and its answer goes in", %{
    supervisor: supervisor
  } do
    session =
      start_session(
        supervisor,
        ~s(printf 'Paste the code: '; read code; echo "got $code"),
        spec: [pty: true]
      )

    assert read(session, 0, 1) == ["Paste the code: "]
    :running = Backend.send_lines(session, ["abc"])
    wait_until(fn -> "got abc" in texts(Backend.recv(session, 1, 1_000)) end, 10_000)
  end

  test "a session stopped before its delayed spawn starts nothing", %{supervisor: supervisor} do
    opts = [
      owner: @owner,
      session: "ss_" <> String.duplicate("1", 32),
      program: "probe",
      spec: %{argv: ["/bin/sh", "-c", "exec cat"], env: %{}, pool: "backends", memory_bytes: 1},
      launcher: Locus.DirectLauncher,
      notify: self(),
      delay_ms: 300
    ]

    {:ok, session} = DynamicSupervisor.start_child(supervisor, {Backend, opts})
    assert :ok = Backend.stop(session, 0)
    assert_received {Backend, ^session, {:ended, %{crash: false}}}
    refute_received {Backend, ^session, :started}
  end

  describe "through the keeper's client" do
    setup do
      {fake, channel} = FakeKeeper.start()
      attach_dir = FakeKeeper.short_tmp_dir()
      {:ok, client} = Locus.Keeper.start_link(channel: channel, attach_dir: attach_dir, name: nil)

      Process.unlink(client)
      :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)

      on_exit(fn ->
        Process.exit(client, :kill)
        Process.exit(fake, :kill)
        File.rm_rf!(attach_dir)
      end)

      {:ok, fake: fake, keeper: client}
    end

    test "the spawn is in the pool backends, with its argv, its env block and its bound",
         %{supervisor: supervisor, fake: fake, keeper: keeper} do
      env = %{"PROBE_TOKEN" => @token, "NODE_ENV" => "test"}
      argv = ["/bin/sh", "-c", "exec cat \"$@\"", "sh", "--flag"]

      session =
        start_session(supervisor, "unused",
          spec: [argv: argv, env: env, memory_bytes: 268_435_456],
          launcher: Locus.Keeper,
          launcher_server: keeper
        )

      [spawn] = Enum.filter(FakeKeeper.requests(fake), &(&1["type"] == "spawn"))
      assert spawn["pool"] == "backends"
      assert spawn["argv"] == argv
      assert spawn["env"] == env
      assert spawn["memory_bytes"] == 268_435_456
      refute Map.has_key?(spawn, "control")

      assert :ok = Backend.stop(session, 0)

      wait_until(
        fn -> Enum.any?(FakeKeeper.requests(fake), &(&1["type"] == "release")) end,
        10_000
      )
    end
  end
end
