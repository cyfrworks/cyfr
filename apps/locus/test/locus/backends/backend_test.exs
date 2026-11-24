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
  the stderr tail; on a pseudo-terminal, bytes going in and coming out
  as they are, and an owner's secret masked though the process writes it
  in two parts, or stops part way through it. Against `Locus.Test.FakeKeeper` through
  `Locus.Keeper`: the spawn a session asks for is in the pool `backends`,
  with its place, its argv, its environment and its memory bound, its
  use is read by its place, as the keeper last read it or unmeasured,
  and a measure the keeper holds delays none of the session's traffic,
  and what memory ended it reaches its owners before its settlement,
  also after a close was asked. Against counts of its own
  (`Locus.Output`): 32 sessions leaving 8 MiB each hold the unread count
  to its bound, those holding most dropping their oldest, counted, while a
  session read as it comes loses nothing, and the count passes its bound
  by no more than its stated increments; a session told to drop while it
  is held in a call owes one increment until it holds again, and its
  neighbours drop in its place meanwhile; an answer the answering count
  has no room for answers nothing by its deadline and is read later; and a
  holder that dies frees its answer.
  """

  use ExUnit.Case, async: false

  import Prima.Test.Wait

  alias Locus.Backends.Backend
  alias Locus.Test.FakeKeeper

  @token "tok-0123456789abcdef"
  @owner %{athanor: "athanor-1", server: "server-1", g: 1, e: 1}
  # The name of a test's own count (`Locus.Output`).
  @output Module.concat(__MODULE__, Output)

  # A flood's line: 992 bytes of text and its newline, charged 1,024 with
  # its framing, so 8,192 of them are a session's 8 MiB.
  @flood_text 992
  @flood_lines 8_192
  @line_charge @flood_text + 32
  # What one hold of a session writing such lines adds: a read of at most
  # 65,536 bytes (the keeper's frame, and a port's read) completes at most
  # 66 lines of 993 bytes, with the part line left before it.
  @increment 66 * @line_charge

  defmodule Scripted do
    @moduledoc false
    # A launcher that starts nothing. The test writes the session's stdout
    # as the keeper's events, on the ref the spawn tells it, and a write to
    # its stdin holds its caller inside that call until the test lets it
    # go. Its release is never reported.
    import Kernel, except: [send: 2]

    def spawn(test, _spec) do
      ref = make_ref()
      Kernel.send(test, {__MODULE__, :spawned, self(), ref})
      {:ok, %{ref: ref, server: test, spawn_id: nil, uid: nil, pid: nil}}
    end

    def send(%{server: test}, _data) do
      Kernel.send(test, {__MODULE__, :writing, self()})

      receive do
        {__MODULE__, :let_go} -> :ok
      end
    end

    def taken(_handle), do: :ok
    def signal(_handle, _sig), do: :ok
    def resize(_handle, _rows, _cols), do: :ok
    def release(_test, _handle, _grace_ms), do: :ok
  end

  setup do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    {:ok, supervisor: supervisor}
  end

  defp start_session(supervisor, command, opts \\ []) do
    place = "pl-" <> Integer.to_string(System.unique_integer([:positive]))

    # The keeper's client spawns only in a place it placed.
    if Keyword.get(opts, :launcher) == Locus.Keeper,
      do: :ok = Locus.Keeper.place(opts[:launcher_server], place, %{kind: "program"}, self())

    spec =
      Map.merge(
        %{
          place: place,
          argv: ["/bin/sh", "-c", command],
          env: %{"PROBE_TOKEN" => @token},
          pool: "backends",
          memory_bytes: Locus.Config.backends_memory_bytes(),
          cpu_quota: Locus.Config.backends_cpu_quota()
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

  # A terminal's chunks past `after`, read until `done?` holds of all of
  # them together: those bytes and the last chunk's number.
  defp output(session, after_seq, done?, seen \\ "") do
    if done?.(seen) do
      {seen, after_seq}
    else
      %{chunks: chunks} = Backend.recv(session, after_seq, 5_000)
      assert chunks != [], "no output came after #{inspect(seen)}"
      output(session, List.last(chunks).seq, done?, seen <> Enum.map_join(chunks, & &1.bytes))
    end
  end

  # What a session tells its owners from here to its settlement, in order.
  defp until_vacated(session, events \\ []) do
    receive do
      {Backend, ^session, :vacated} -> Enum.reverse([:vacated | events])
      {Backend, ^session, event} -> until_vacated(session, [event | events])
    after
      10_000 -> flunk("never vacated; told #{inspect(Enum.reverse(events))}")
    end
  end

  # Every byte a terminal session wrote past `after` once it has ended.
  defp rest(session, after_seq) do
    assert %{chunks: chunks, running: false} = Backend.recv(session, after_seq, 0)
    Enum.map_join(chunks, & &1.bytes)
  end

  defp terminal(supervisor, command, size \\ %{rows: 24, cols: 80}),
    do: start_session(supervisor, command, mode: :terminal, spec: [pty: size])

  # A count of the test's own, at `bounds`.
  defp output(bounds), do: start_supervised!({Locus.Output, name: @output, bounds: bounds})

  defp scripted(supervisor, output) do
    session =
      start_session(supervisor, "unused",
        launcher: Scripted,
        launcher_server: self(),
        output: output
      )

    assert_received {Scripted, :spawned, ^session, ref}
    {session, ref}
  end

  # `frames` keeper frames of 64 lines of 1,023 bytes each, 65,536 bytes a
  # frame, written to a scripted session and taken by it: the status asked
  # after them is answered only once the session has taken every one.
  defp frames({session, ref}, frames) do
    frame = :binary.copy(String.duplicate("x", 1_023) <> "\n", 64)
    for _ <- 1..frames, do: Kernel.send(session, {Scripted, ref, {:stdout, frame}})
    Backend.status(session, 5_000)
  end

  # Every line past `after` until `n` have come, each answer telling no
  # drop and its grant given back as its bytes are read.
  defp kept_up(session, after_seq, n, seen \\ []) do
    if length(seen) >= n do
      {seen, after_seq}
    else
      answer = Backend.recv(session, after_seq, 5_000)
      assert %{lines: [_ | _] = lines, dropped: 0} = answer, inspect(Map.delete(answer, :lines))
      :ok = Locus.Output.return(answer.grant)
      kept_up(session, List.last(lines).seq, n, seen ++ Enum.map(lines, & &1.text))
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

    # The line is sent only once the recv waits in the session. No caller
    # can see a recv that waits, so this reads the session's own state.
    wait_until(fn -> :sys.get_state(session).waiters != [] end, 5_000, "the recv to wait")
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

    assert %{running: false, lines: [%{text: "kept"}], exit_code: nil} =
             Backend.recv(session, 0, 5_000)

    assert :ended = Backend.send_lines(session, ["late"])
    assert_receive {Backend, ^session, {:ended, %{crash: false}}}, 5_000
    assert_receive {Backend, ^session, :vacated}, 5_000
  end

  # A person's Close of a terminal, and every close a holder makes, is
  # answered as soon as the process is asked to end: what waits for the
  # process to be gone is the next open of its key (`Locus.Backends.Owners`).
  test "a close answers at once, and again after its release bound, while its process runs", %{
    supervisor: supervisor
  } do
    session =
      start_session(supervisor, "echo up; exec cat", stop_grace_ms: 2_000, release_timeout_ms: 25)

    assert read(session, 0, 1) == ["up"]
    handle = :sys.get_state(session).handle

    on_exit(fn ->
      try do
        :sys.resume(handle.server)
      catch
        :exit, _ -> :ok
      end
    end)

    :sys.suspend(handle.server)
    :erlang.trace(session, true, [:receive])
    assert {elapsed, :ok} = :timer.tc(fn -> Backend.close(session) end, :millisecond)
    assert elapsed < 1_000
    assert_receive {:trace, ^session, :receive, :release_timeout}, 5_000
    :erlang.trace(session, false, [:receive])

    assert {elapsed, :ok} = :timer.tc(fn -> Backend.close(session) end, :millisecond)
    assert elapsed < 1_000
    assert File.exists?("/proc/#{handle.pid}")
    refute_received {Backend, ^session, :vacated}

    :sys.resume(handle.server)
    assert_receive {Backend, ^session, :vacated}, 5_000
  end

  test "an exit of its own is a crash unless its status is 0, its status is answered, and its last lines stay readable",
       %{supervisor: supervisor} do
    crashed = start_session(supervisor, "echo last; exit 3")
    assert_receive {Backend, ^crashed, {:ended, %{crash: true, error: error}}}, 10_000
    assert error =~ "code=3"

    assert %{running: false, lines: [%{text: "last"}], exit_code: 3} =
             Backend.recv(crashed, 0, 5_000)

    clean = start_session(supervisor, "echo done")
    assert_receive {Backend, ^clean, {:ended, %{crash: false, error: nil}}}, 10_000
    assert %{running: false, exit_code: 0} = Backend.recv(clean, 0, 0)

    signalled = start_session(supervisor, "kill -TERM $$")
    assert_receive {Backend, ^signalled, {:ended, %{crash: true}}}, 10_000
    assert %{running: false, exit_code: nil} = Backend.recv(signalled, 0, 0)
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
    # Its process gone before the test ends, so nothing of it outlives the run.
    assert_receive {Backend, ^session, :vacated}, 5_000
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

  test "a terminal's input reaches its process as it is, and its output comes as it is", %{
    supervisor: supervisor
  } do
    # Raw, the terminal neither echoes nor reads an interrupt in the input.
    session =
      terminal(
        supervisor,
        ~s(stty raw -echo; printf 'ready\\n'; head -c 4 | od -An -tx1; printf '\\377\\376\\n')
      )

    {"ready\n", seq} = output(session, 0, &String.ends_with?(&1, "\n"))
    assert :running = Backend.input(session, <<0x03, 0xFF, 0x80, ?a>>)
    assert_receive {Backend, ^session, {:ended, %{crash: false}}}, 10_000
    assert rest(session, seq) == " 03 ff 80 61\n" <> <<0xFF, 0xFE, ?\n>>
  end

  test "an owner's secret is masked though the terminal's process writes it in two parts, or stops in it",
       %{supervisor: supervisor} do
    {first, second} = String.split_at(@token, 10)

    session =
      terminal(
        supervisor,
        ~s(head="${PROBE_TOKEN%#{second}}"; tail="${PROBE_TOKEN#$head}"; ) <>
          ~s(printf 'one %s' "$head"; sleep 0.3; printf '%s two\\n' "$tail"; ) <>
          ~s(sleep 0.3; printf 'three %s' "$head")
      )

    # What the masker holds back of the first part is released with the
    # second, masked; the part it holds at the end is masked whole.
    {seen, seq} = output(session, 0, &String.contains?(&1, "two"))
    assert_receive {Backend, ^session, {:ended, %{crash: false}}}, 10_000
    whole = seen <> rest(session, seq)

    assert whole == "one [REDACTED] two\r\nthree [REDACTED]"
    refute whole =~ binary_part(first, 0, 4)
  end

  test "32 sessions leaving 8 MiB each hold the count to its bound, those holding most dropping their oldest, and one read as it comes loses nothing",
       %{supervisor: supervisor} do
    bounds = Locus.Output.bounds().backends
    output = output(bounds)
    reader = start_session(supervisor, "exec cat", output: output)

    flood = "yes \"$(printf '%0#{@flood_text}d' 0)\" | head -n #{@flood_lines}"
    floods = for _ <- 1..31, do: start_session(supervisor, flood, output: output)

    # The reader keeps up while the floods fill the count, and on after
    # they have all ended, each of its lines pushing the count past its
    # bound for the one holding most to drop.
    {read, written} = read_while(reader, MapSet.new(floods), 0, [], [])
    assert read == written

    # A flood told to drop by the reader's last lines may not have read it
    # yet: each one's mailbox is read through before the count is.
    wait_until(
      fn ->
        Enum.each(floods, &Backend.status(&1, 5_000))
        Locus.Output.held(output).owed == 0
      end,
      5_000,
      "every flood told to drop to have dropped"
    )

    held = Locus.Output.held(output)

    kept =
      for flood <- floods do
        answer = Backend.recv(flood, 0, 0)
        :ok = Locus.Output.return(answer.grant)
        %{lines: lines, dropped: dropped, running: false} = answer

        # What it kept is its newest, whole and in order; what it lost is
        # its oldest, every one of them counted.
        assert Enum.map(lines, & &1.seq) == Enum.to_list((dropped + 1)..@flood_lines//1)
        assert Enum.all?(lines, &(&1.text == String.duplicate("0", @flood_text)))
        {dropped, length(lines)}
      end

    # Those holding most dropped, and the one read as it comes, holding
    # least, none.
    assert Enum.all?(kept, fn {dropped, _kept} -> dropped > 0 end), inspect(kept)

    # The count names what the sessions buffer and the stderr they keep,
    # within its bound now that every session told to drop has dropped,
    # and never passed it by more than an increment for each session that
    # could be told at once.
    buffered =
      Enum.sum(for s <- [reader | floods], do: Locus.Backends.Relay.held(:sys.get_state(s).relay))

    assert held.unread == buffered
    assert held.owed == 0 and held.unread <= bounds.unread, inspect(held)
    assert held.unread_peak <= bounds.unread + 32 * @increment, inspect(held)
  end

  # The reader's rounds: 64 lines sent and read back, until every flood has
  # ended and once more after that.
  defp read_while(reader, running, after_seq, read, written) do
    running = vacated(running)
    round = div(length(written), 64) + 1
    batch = for i <- 1..64, do: String.pad_trailing("#{round}:#{i}:", @flood_text, "r")
    :running = Backend.send_lines(reader, batch)
    {lines, after_seq} = kept_up(reader, after_seq, 64)
    read = read ++ lines
    written = written ++ batch

    if MapSet.size(running) == 0 and length(written) > 64 * 8,
      do: {read, written},
      else: read_while(reader, running, after_seq, read, written)
  end

  defp vacated(running) do
    receive do
      {Backend, session, :vacated} -> vacated(MapSet.delete(running, session))
      {Backend, _session, _event} -> vacated(running)
    after
      0 -> running
    end
  end

  test "a session told to drop while it reads nothing owes one increment until it holds again, and its neighbours drop in its place",
       %{supervisor: supervisor} do
    # One frame of 64 lines of 1,023 bytes is charged 64 * (1,023 + 32).
    increment = 64 * 1_055
    bound = 3 * increment
    output = output(%{unread: bound, answering: 26 * 1_048_576})
    [held, second, third] = for _ <- 1..3, do: scripted(supervisor, output)
    {holder, _ref} = held

    frames(held, 3)
    assert %{unread: ^bound, owed: 0} = Locus.Output.held(output)

    # Held, it cannot read what the count tells it.
    :ok = :sys.suspend(holder)

    # The hold that passes the bound tells the one holding most: the held
    # session, which owes the excess, one increment.
    frames(second, 1)
    assert %{unread: unread, owed: ^increment} = Locus.Output.held(output)
    assert unread == bound + increment

    # Its neighbours go on writing and drop in its place, each within its
    # own hold: the count stays past its bound by the one it owes.
    for _ <- 1..4, session <- [second, third], do: frames(session, 1)
    counted = Locus.Output.held(output)
    assert %{unread: ^unread, owed: ^increment} = counted
    assert counted.unread_peak <= bound + 2 * increment, inspect(counted)

    for {session, _ref} <- [second, third] do
      answer = Backend.recv(session, 0, 0)
      if grant = answer[:grant], do: :ok = Locus.Output.return(grant)
      assert answer.dropped > 0
    end

    # Let go, it holds again, drops what it owed, and the count is back
    # within its bound.
    :ok = :sys.resume(holder)
    Backend.status(holder, 5_000)
    assert %{owed: 0, unread: unread} = Locus.Output.held(output)
    assert unread <= bound

    %{dropped: 64, grant: grant} = Backend.recv(holder, 0, 0)
    :ok = Locus.Output.return(grant)
  end

  test "the stderr a session keeps for its status is held in the role's count, and cut when it must drop with no line left",
       %{supervisor: supervisor} do
    kept = Prima.LocusBackends.stderr_tail_bytes() + Prima.LocusBackends.stderr_tail_slack_bytes()
    bound = kept + 1_024
    output = output(%{unread: bound, answering: 26 * 1_048_576})
    {session, ref} = scripted(supervisor, output)
    Kernel.send(session, {Scripted, ref, {:stderr, :binary.copy("e", 2 * kept)}})
    Backend.status(session, 5_000)
    assert %{unread: ^kept} = Locus.Output.held(output)

    # Another session's line passes the bound: the session holding most has
    # no line to drop, so it cuts the stderr it keeps.
    {other, other_ref} = scripted(supervisor, output)
    Kernel.send(other, {Scripted, other_ref, {:stdout, :binary.copy("x", 2_047) <> "\n"}})
    Backend.status(other, 5_000)
    Backend.status(session, 5_000)
    assert %{unread: ^bound, owed: 0} = Locus.Output.held(output)
  end

  test "a process that stops reading its input holds its caller, never its session, which goes on taking its output",
       %{supervisor: supervisor} do
    output = output(%{unread: 8 * 1_048_576, answering: 26 * 1_048_576})
    {session, _ref} = scripted = scripted(supervisor, output)

    # The write waits inside the launcher, in its caller's process.
    writing = Task.async(fn -> Backend.send_lines(session, ["held"]) end)
    assert_receive {Scripted, :writing, writer}, 5_000
    assert writer == writing.pid

    # The session still takes what its process writes, and answers.
    assert %{running: true} = frames(scripted, 3)
    assert %{unread: unread} = Locus.Output.held(output)
    assert unread == 3 * 64 * 1_055

    send(writer, {Scripted, :let_go})
    assert Task.await(writing) == :running
  end

  test "an answer the answering count has no room for answers no lines by its deadline, and the same after reads them later",
       %{supervisor: supervisor} do
    output = output(%{unread: 1_048_576, answering: 1_000})
    session = start_session(supervisor, "exec cat", output: output)
    :running = Backend.send_lines(session, ["one", "two"])

    wait_until(
      fn -> Locus.Output.held(output).unread == 2 * (3 + 32) end,
      5_000,
      "both lines to be buffered"
    )

    {:ok, room} = Locus.Output.reserve(output, 1_000, System.monotonic_time(:millisecond))
    started = System.monotonic_time(:millisecond)
    answer = Backend.recv(session, 0, 300)
    assert answer == %{lines: [], dropped: 0, running: true, exit_code: nil}
    assert System.monotonic_time(:millisecond) - started >= 300

    # The room given back, as the count has taken it, before the next ask.
    :ok = Locus.Output.return(room)
    assert Locus.Output.held(output).answering == 0
    assert %{lines: lines, dropped: 0, grant: grant} = Backend.recv(session, 0, 0)
    assert Enum.map(lines, & &1.text) == ["one", "two"]
    assert Locus.Output.held(output).answering == 2 * (byte_size(~s("one")) + 32)

    :ok = Locus.Output.return(grant)
    assert Locus.Output.held(output).answering == 0
  end

  test "an answer's bytes are the caller's, and a caller that dies holding them frees them", %{
    supervisor: supervisor
  } do
    output = output(%{unread: 1_048_576, answering: 1_048_576})
    session = start_session(supervisor, "exec cat", output: output)
    :running = Backend.send_lines(session, ["kept"])

    wait_until(
      fn -> Locus.Output.held(output).unread == 4 + 32 end,
      5_000,
      "the line to be buffered"
    )

    test = self()

    caller =
      spawn(fn ->
        send(test, {:answered, Backend.recv(session, 0, 0)})

        receive do
          :never -> :ok
        end
      end)

    assert_receive {:answered, %{lines: [%{text: "kept"}], grant: _grant}}, 5_000
    assert Locus.Output.held(output).answering == byte_size(~s("kept")) + 32

    Process.exit(caller, :kill)

    wait_until(
      fn -> Locus.Output.held(output).answering == 0 end,
      5_000,
      "the dead caller's answer to be freed"
    )
  end

  test "a launcher with no reading of a session's place leaves its use unmeasured, never zero",
       %{supervisor: supervisor} do
    session = start_session(supervisor, "exec cat")
    %{spec: %{place: place}} = :sys.get_state(session)
    assert Locus.DirectLauncher.measure([], place) == {:error, {:refused, "unmeasured"}}

    assert :ok = Backend.stop(session, 0)
    assert_receive {Backend, ^session, {:ended, ended}}, 10_000
    assert ended == %{crash: false, error: nil}
  end

  test "a session stopped before its delayed spawn starts nothing", %{supervisor: supervisor} do
    opts = [
      owner: @owner,
      session: "ss_" <> String.duplicate("1", 32),
      program: "probe",
      spec: %{
        place: "pl-delayed",
        argv: ["/bin/sh", "-c", "exec cat"],
        env: %{},
        pool: "backends",
        memory_bytes: 1
      },
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
      assert spawn["place"] == :sys.get_state(session).spec.place
      assert spawn["pool"] == "backends"
      assert spawn["argv"] == argv
      assert spawn["env"] == env
      assert spawn["memory_bytes"] == 268_435_456
      assert spawn["cpu_quota"] == Locus.Config.backends_cpu_quota()
      refute Map.has_key?(spawn, "control")

      assert :ok = Backend.stop(session, 0)

      wait_until(
        fn -> Enum.any?(FakeKeeper.requests(fake), &(&1["type"] == "release")) end,
        10_000
      )
    end

    test "it tells a kill at its cap from the machine's, from one not known and from any other",
         %{supervisor: supervisor, fake: fake, keeper: keeper} do
      for {spelled, told} <- [
            {"cap", [memory: :cap]},
            {"machine", [memory: :machine]},
            {"either", [memory: :either]},
            {nil, []}
          ] do
        :ok = FakeKeeper.mode(fake, {:exit, %{code: nil, signal: "SIGKILL", memory: spelled}})

        session =
          start_session(supervisor, "unused", launcher: Locus.Keeper, launcher_server: keeper)

        ended = %{crash: true, error: "exited code=null signal=SIGKILL", exit_code: nil}
        assert until_vacated(session) == told ++ [{:ended, ended}, :vacated]
      end
    end

    # The stdout bytes waiting in `session`'s mailbox.
    defp mailbox_bytes(session) do
      {:messages, messages} = Process.info(session, :messages)

      for {Locus.Keeper, _ref, {:stdout, bytes}} <- messages, reduce: 0 do
        acc -> acc + byte_size(bytes)
      end
    end

    @tag timeout: 60_000
    test "a session kept from its mailbox holds at most one read of its process's output there",
         %{supervisor: supervisor, keeper: keeper} do
      # 8 MiB of lines once told to go, then the process waits.
      command = ~s[read go && yes "$(printf '%01023d' 0)" | head -n 8192; exec sleep 30]

      session =
        start_session(supervisor, command, launcher: Locus.Keeper, launcher_server: keeper)

      assert :running = Backend.send_lines(session, ["go"])
      :ok = :sys.suspend(session)

      # However long it is kept, what waits for it is one read of the
      # relay's connection, at most: the rest waits outside this node.
      wait_until(fn -> mailbox_bytes(session) > 0 end, 10_000, "the first read to arrive")
      deadline = System.monotonic_time(:millisecond) + 1_500

      Stream.repeatedly(fn -> mailbox_bytes(session) end)
      |> Enum.find(fn bytes ->
        assert bytes <= Prima.KeeperProtocol.max_frame_bytes() + 5
        # sleep-ok: a window in which the mailbox must not grow, sampled.
        Process.sleep(50)
        System.monotonic_time(:millisecond) > deadline
      end)

      # Let go, it takes all of it, its oldest dropped and counted.
      :ok = :sys.resume(session)

      wait_until(
        fn ->
          answer = Backend.recv(session, 8_191, 0)
          if grant = answer[:grant], do: :ok = Locus.Output.return(grant)
          match?(%{lines: [%{seq: 8_192}]}, answer)
        end,
        20_000,
        "the last line taken"
      )

      assert %{dropped: dropped} = answer = Backend.recv(session, 0, 0)
      if grant = answer[:grant], do: :ok = Locus.Output.return(grant)
      assert dropped > 0

      assert :ok = Backend.stop(session, 0)
    end

    @tag timeout: 60_000
    test "a reader that never reads stalls nothing: the process writes to its end, its oldest dropped and counted",
         %{supervisor: supervisor, keeper: keeper} do
      bound = 256 * 1_024
      output = output(%{unread: bound, answering: 26 * 1_048_576})

      # 2 MiB of lines, eight times the bound, then a word on stderr.
      command = ~s[yes "$(printf '%01023d' 0)" | head -n 2048; echo done >&2; exec sleep 30]

      session =
        start_session(supervisor, command,
          launcher: Locus.Keeper,
          launcher_server: keeper,
          output: output
        )

      wait_until(
        fn -> Backend.status(session, 5_000).stderr_tail =~ "done" end,
        20_000,
        "the process to write to its end"
      )

      wait_until(fn -> Locus.Output.held(output).unread <= bound end, 5_000)
      %{dropped: dropped} = answer = Backend.recv(session, 0, 0)
      if grant = answer[:grant], do: :ok = Locus.Output.return(grant)
      assert dropped > 0
      assert :ok = Backend.stop(session, 0)
    end

    test "a measure the keeper holds delays none of the session's traffic",
         %{supervisor: supervisor, fake: fake, keeper: keeper} do
      session =
        start_session(supervisor, "exec cat", launcher: Locus.Keeper, launcher_server: keeper)

      %{spec: %{place: place}} = :sys.get_state(session)
      :ok = FakeKeeper.mode(fake, :measure_held)
      reading = Task.async(fn -> Locus.Keeper.measure(keeper, place) end)

      wait_until(
        fn -> Enum.any?(FakeKeeper.requests(fake), &(&1["type"] == "measure")) end,
        5_000,
        "the measurement to be pending"
      )

      assert :running = Backend.send_lines(session, ["held"])
      assert read(session, 0, 1) == ["held"]
      assert Task.yield(reading, 0) == nil

      Task.shutdown(reading, :brutal_kill)
      assert :ok = Backend.stop(session, 0)
    end

    test "a memory cause heard after a close was asked is kept for its settlement",
         %{supervisor: supervisor, fake: fake, keeper: keeper} do
      for {spelled, memory} <- [{"cap", :cap}, {"machine", :machine}] do
        killed = %{code: nil, signal: "SIGKILL", memory: spelled}
        :ok = FakeKeeper.mode(fake, {:exit_closed, killed})

        session =
          start_session(supervisor, "exec cat", launcher: Locus.Keeper, launcher_server: keeper)

        assert :ok = Backend.close(session)

        assert until_vacated(session) == [
                 {:ended, %{crash: false, error: nil}},
                 {:memory, memory},
                 :vacated
               ]
      end
    end

    test "its use is the keeper's reading of its place, and one not made is unmeasured, never zero",
         %{supervisor: supervisor, fake: fake, keeper: keeper} do
      session =
        start_session(supervisor, "exec cat", launcher: Locus.Keeper, launcher_server: keeper)

      %{spec: %{place: place}} = :sys.get_state(session)
      assert Locus.Keeper.measure(keeper, place) == {:error, {:refused, "unmeasured"}}

      for lesser <- [false, true] do
        reading = %{bytes: 268_435_456, lesser: lesser, age_ms: 300}
        :ok = FakeKeeper.mode(fake, {:measured, reading})

        assert Locus.Keeper.measure(keeper, place) ==
                 {:ok, Map.merge(reading, %{kind: "program", athanor: nil, subject: nil})}
      end

      assert :ok = Backend.stop(session, 0)
      assert_receive {Backend, ^session, :vacated}, 10_000
      assert Locus.Keeper.measure(keeper, place) == {:error, {:refused, "unmeasured"}}
    end
  end
end
