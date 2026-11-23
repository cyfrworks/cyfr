# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Locus.Test.FakeKeeper do
  @moduledoc """
  The far end of a `Locus.Keeper` channel, standing in for cyfr-locus: it
  answers a spawn by running the command on this machine as the test's own
  user and acting as its relay — it dials the request's attach socket,
  presents the token, reads stdin frames, and sends the command's stderr as
  it arrives and its stdout at exit — then reports `exited` and `released`.
  A `release` kills the command. It isolates nothing; it exercises the
  client's side of the protocol.

  Modes, set with `mode/2`:
  - `:normal`
  - `:capacity` — every spawn is refused with `capacity`
  - `:memory_unavailable` — every spawn is refused with `memory_unavailable`,
    as a keeper whose cgroup is not writable refuses a bounded spawn
  - `{:exit, exited}` — the command is never run: the relay writes one log
    line and the leader is reported ended as `exited` says (`:code`,
    `:signal`, `:memory`), killed at its bound or the container's among
    them, in any pool
  - `{:measured, reading}`: a `measure` of a place a spawn named is
    answered with whose the place is and `reading` (`:bytes`, `:lesser`,
    `:age_ms`)
  - `:measure_held`: a `measure` is never answered
  - `{:exit_closed, exited}`: a long-lived command runs until it is ended,
    and its leader is then reported as `exited` says, as one the kernel
    killed while it was closing is
  - `{:report_first, reported?}` — a build's command runs before its relay
    dials, so on no input, and its `exited` and `released` are written to
    the channel; the relay waits until `reported?` (a function of no
    arguments) holds, the client having read them, then dials, presents
    the token, reads the stdin the client sends and drops it, and sends
    the command's output. In every other mode a build's relay dials first
    and the command reads the stdin the client sends.
  - `{:exec_failed, test}` — every spawn is refused with `exec_failed` under
    the spawn id the fake gave it, as cyfr-locus refuses one whose command
    it could not run after it made the spawn: the spawn's place stays the
    spawn's, `test` is told `{:exec_failed, spawn_id}`, and its `released`
    is reported only by `released/2`
  - `:pool_refused` — every `pool` request is refused with `unknown_pool`
  - `:home_over_cap` — every spawn is refused with `home_over_cap`, as a
    keeper refuses a kept spawn whose home holds its bound
  - `:hosts_unresolved`, `:guard_unavailable` — every spawn is refused so,
    as a keeper refuses one whose hosts resolve to nothing or whose egress
    its guard does not confirm
  - `:home_refused` — every home request is refused with `internal`
  - `{:home_make_held, test}`: a `home_make` is told to `test` as
    `{:home_make_held, request}` and answered only once released
    (`release_make/2`), having made nothing until then
  - `{:uid_busy, uids}` — a `home_make` on one of `uids` is refused with
    `uid_busy`, as cyfr-locus refuses a kept uid that is retiring,
    quarantined or live under another home

  A spawn in any pool but `build` is long-lived: its relay carries stdin
  frames to the command as they arrive and its stdout and stderr, apart,
  as the command writes them, until the command exits. A `signal` request
  signals its process group; a `release` with a grace sends it a term
  signal and the kill once the grace passes. A `pool` request is answered
  with a pool of four uids, three free and none quarantined. It keeps
  places as cyfr-locus does (`Prima.KeeperProtocol`, "Places"; `places/1`
  lists them): a `place` of a new id is `placed` and of a held one
  refused `bad_request`, a `drop` frees one no spawn named, an `assign`
  changes whose one is and is `assigned`, or refused `bad_request` for a
  place it does not hold, a spawn naming no held place or one another spawn
  named is refused `bad_request`, a spawn refused under its id alone frees
  its place and one refused under its spawn id keeps it, and a
  `released` frees its spawn's. A `measure` is refused `unmeasured`
  outside its mode, since nothing here has a group. A
  home request acts on its path as the test's own user: `home_make` makes
  the folder 0700, `home_measure` answers the bytes of the files under it, and
  `home_retire` removes it. A spawn's kept-home and `pty` members are
  recorded among the requests and run as any other spawn; a `resize` is
  recorded and changes nothing, since no spawn here runs on a terminal.
  """

  use GenServer

  @stream_stdin 0
  @stream_stdout 1
  @stream_stderr 2
  @stream_attach 3

  # Named by absolute path, as the direct launcher names its tools: a test
  # that moves this node's PATH must not lose a fifo. Signals go through
  # the direct launcher's group signal (`Locus.DirectLauncher.signal_group/2`).
  @mkfifo "/usr/bin/mkfifo"

  @doc "Starts a fake and answers `{fake, client_channel}`, the `:socket` to hand `Locus.Keeper`."
  def start do
    dir = short_tmp_dir()
    path = Path.join(dir, "channel.sock")
    {:ok, listener} = :socket.open(:local, :stream)
    :ok = :socket.bind(listener, %{family: :local, path: path})
    :ok = :socket.listen(listener)
    {:ok, client} = :socket.open(:local, :stream)
    :ok = :socket.connect(client, %{family: :local, path: path})
    {:ok, ours} = :socket.accept(listener)
    :socket.close(listener)
    File.rm_rf!(dir)
    {:ok, fake} = GenServer.start(__MODULE__, ours)
    :ok = :socket.setopt(ours, {:otp, :controlling_process}, fake)
    {fake, client}
  end

  @doc """
  A fake and a `Locus.Keeper` client on its channel, started with
  `keeper_opts` beside its channel and attach directory, both stopped and
  the client's attach directory removed when the calling test ends: answers
  `%{fake: fake, name: client, client: client}`, the client addressed
  by its pid.
  """
  def start_client!(keeper_opts \\ []) do
    {fake, channel} = start()
    attach_dir = short_tmp_dir()

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(fake, :kill)
      File.rm_rf!(attach_dir)
    end)

    {:ok, client} =
      Locus.Keeper.start_link(
        [channel: channel, attach_dir: attach_dir, name: nil] ++ keeper_opts
      )

    Process.unlink(client)
    ExUnit.Callbacks.on_exit(fn -> Process.exit(client, :kill) end)
    :ok = :socket.setopt(channel, {:otp, :controlling_process}, client)
    %{fake: fake, name: client, client: client}
  end

  @doc """
  A private directory short enough for a unix socket path, new to this
  call: its name carries this VM's OS pid, so another partition's is
  never the same one, and a directory an earlier run left behind under a
  reused pid is passed over.
  """
  def short_tmp_dir do
    dir = Path.join("/tmp", "lsp-#{System.pid()}-#{System.unique_integer([:positive])}")

    case File.mkdir(dir) do
      :ok ->
        File.chmod!(dir, 0o700)
        dir

      {:error, :eexist} ->
        short_tmp_dir()
    end
  end

  def mode(fake, mode), do: GenServer.call(fake, {:mode, mode})

  @doc "Carries out the `home_make` held in `{:home_make_held, test}`, and holds no later one."
  def release_make(fake, request), do: GenServer.call(fake, {:release_make, request})

  @doc "Every request received so far, decoded, oldest first."
  def requests(fake), do: GenServer.call(fake, :requests)

  @doc "The spawn ids whose exit the fake has reported, in order."
  def exits(fake), do: GenServer.call(fake, :exits)

  @doc """
  What the fake has done of every spawn's end, in the order it did it:
  `:exited` and `:released` once the report is written to the channel,
  `:dial` once the relay has connected and written its token.
  """
  def sent(fake), do: GenServer.call(fake, :sent)

  @doc "Every command directory the fake's relays made, oldest first; each is removed when its relay ends."
  def command_dirs(fake), do: GenServer.call(fake, :command_dirs)

  @doc "Every place the fake holds, by its id: `%{whose, spawn}`, `spawn` the spawn id that named it or nil."
  def places(fake), do: GenServer.call(fake, :places)

  @doc "The spawn ids whose command the fake runs or has run, as an OS process it can signal."
  def running(fake), do: GenServer.call(fake, :running)

  @doc "Reports `spawn_id` released, as cyfr-locus does once nothing of it is left, which frees its place."
  def released(fake, spawn_id),
    do: GenServer.call(fake, {:send, %{type: "released", spawn_id: spawn_id}})

  @doc "Closes the channel, as cyfr-locus exiting would."
  def close(fake), do: GenServer.call(fake, :close)

  @impl true
  def init(channel) do
    fake = self()
    spawn_link(fn -> read(channel, fake) end)

    {:ok,
     %{
       channel: channel,
       buffer: "",
       mode: :normal,
       requests: [],
       exits: [],
       sent: [],
       command_dirs: [],
       spawns: %{},
       places: %{},
       next: 0
     }}
  end

  defp read(channel, fake) do
    case :socket.recv(channel, 0, :infinity) do
      {:ok, data} ->
        send(fake, {:data, data})
        read(channel, fake)

      {:error, _} ->
        :ok
    end
  end

  @impl true
  def handle_call({:mode, mode}, _from, state), do: {:reply, :ok, %{state | mode: mode}}
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}
  def handle_call(:places, _from, state), do: {:reply, state.places, state}

  def handle_call({:release_make, request}, _from, state),
    do: {:reply, :ok, handle_request(request, %{state | mode: :normal})}

  def handle_call(:exits, _from, state), do: {:reply, Enum.reverse(state.exits), state}
  def handle_call(:sent, _from, state), do: {:reply, Enum.reverse(state.sent), state}

  def handle_call(:command_dirs, _from, state),
    do: {:reply, Enum.reverse(state.command_dirs), state}

  def handle_call(:running, _from, state),
    do: {:reply, for({spawn_id, os_pid} <- state.spawns, is_integer(os_pid), do: spawn_id), state}

  # A relay's report written before it answers, so what the relay does
  # next follows it on the channel.
  def handle_call({:send, message}, _from, state), do: {:reply, :ok, write(state, message)}
  def handle_call(:dialed, _from, state), do: {:reply, :ok, %{state | sent: [:dial | state.sent]}}

  def handle_call(:close, _from, state) do
    :socket.close(state.channel)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:data, data}, state) do
    [rest | lines] = (state.buffer <> data) |> String.split("\n") |> Enum.reverse()

    state =
      lines
      |> Enum.reverse()
      |> Enum.reduce(%{state | buffer: rest}, fn line, acc ->
        request = Jason.decode!(line)
        handle_request(request, %{acc | requests: [request | acc.requests]})
      end)

    {:noreply, state}
  end

  def handle_info({:send, message}, state), do: {:noreply, write(state, message)}

  def handle_info({:command_dir, dir}, state),
    do: {:noreply, %{state | command_dirs: [dir | state.command_dirs]}}

  # A signal asked for before the command's pid was known is sent now.
  def handle_info({:running, spawn_id, os_pid}, state) do
    with {:held, sigs} <- state.spawns[spawn_id],
         do: for(sig <- Enum.reverse(sigs), do: Locus.DirectLauncher.signal_group(os_pid, sig))

    {:noreply, put_in(state.spawns[spawn_id], os_pid)}
  end

  def handle_info({:kill_after, spawn_id}, state), do: {:noreply, signal(state, spawn_id, "KILL")}

  def handle_info(_message, state), do: {:noreply, state}

  # An exit the fake reports is recorded, so a test can tell a spawn the
  # keeper saw end from one it had to release; an exit and a release are
  # recorded only once the channel took them.
  defp write(state, message) do
    sent =
      :socket.send(state.channel, [
        Jason.encode!(Map.put(message, :v, Prima.KeeperProtocol.version())),
        ?\n
      ])

    case message do
      _message when sent != :ok ->
        state

      %{type: "exited", spawn_id: spawn_id} ->
        %{state | exits: [spawn_id | state.exits], sent: [:exited | state.sent]}

      %{type: "released", spawn_id: spawn_id} ->
        places = Map.reject(state.places, fn {_id, place} -> place.spawn == spawn_id end)
        %{state | sent: [:released | state.sent], places: places}

      _other ->
        state
    end
  end

  defp handle_request(%{"type" => "place", "id" => id}, state)
       when is_map_key(state.places, id) do
    send(self(), {:send, %{type: "error", id: id, code: "bad_request"}})
    state
  end

  defp handle_request(%{"type" => "place", "id" => id} = request, state) do
    send(self(), {:send, %{type: "placed", id: id}})
    %{state | places: Map.put(state.places, id, %{whose: whose(request), spawn: nil})}
  end

  defp handle_request(%{"type" => "drop", "place" => id}, state) do
    case state.places do
      %{^id => %{spawn: nil}} -> %{state | places: Map.delete(state.places, id)}
      _named_or_gone -> state
    end
  end

  defp handle_request(%{"type" => "assign", "id" => id, "place" => place} = request, state) do
    case state.places do
      %{^place => held} ->
        send(self(), {:send, %{type: "assigned", id: id}})
        %{state | places: Map.put(state.places, place, %{held | whose: whose(request)})}

      _gone ->
        send(self(), {:send, %{type: "error", id: id, code: "bad_request"}})
        state
    end
  end

  # A spawn names a place held and unnamed, or is refused with nothing done.
  defp handle_request(%{"type" => "spawn", "id" => id, "place" => place} = request, state) do
    case state.places do
      %{^place => %{spawn: nil}} ->
        spawn_in_place(request, state)

      _absent_or_named ->
        send(self(), {:send, %{type: "error", id: id, code: "bad_request"}})
        state
    end
  end

  defp handle_request(%{"type" => "home_" <> _, "id" => id}, %{mode: :home_refused} = state) do
    send(self(), {:send, %{type: "error", id: id, code: "internal"}})
    state
  end

  defp handle_request(
         %{"type" => "home_make", "id" => id, "uid" => uid},
         %{mode: {:uid_busy, uids}} = state
       )
       when is_map_key(uids, uid) do
    send(self(), {:send, %{type: "error", id: id, code: "uid_busy"}})
    state
  end

  defp handle_request(
         %{"type" => "home_make"} = request,
         %{mode: {:home_make_held, test}} = state
       ) do
    send(test, {:home_make_held, request})
    state
  end

  defp handle_request(%{"type" => "home_make", "id" => id, "path" => path}, state) do
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    send(self(), {:send, %{type: "home_made", id: id}})
    state
  end

  defp handle_request(%{"type" => "home_measure", "id" => id, "path" => path}, state) do
    send(self(), {:send, %{type: "home_measured", id: id, bytes: measured(path)}})
    state
  end

  defp handle_request(%{"type" => "home_retire", "id" => id, "path" => path}, state) do
    File.rm_rf!(path)
    send(self(), {:send, %{type: "home_retired", id: id}})
    state
  end

  defp handle_request(%{"type" => "measure"}, %{mode: :measure_held} = state), do: state

  # A place a spawn named has a reading in the `{:measured, reading}` mode;
  # any other is unmeasured.
  defp handle_request(%{"type" => "measure", "id" => id, "place" => place}, state) do
    reply =
      case {state.mode, state.places} do
        {{:measured, reading}, %{^place => %{spawn: spawn, whose: whose}}} when spawn != nil ->
          %{type: "measured", id: id} |> Map.merge(whose) |> Map.merge(reading)

        _unmeasured ->
          %{type: "error", id: id, code: "unmeasured"}
      end

    send(self(), {:send, reply})
    state
  end

  defp handle_request(%{"type" => "pool", "id" => id}, %{mode: :pool_refused} = state) do
    send(self(), {:send, %{type: "error", id: id, code: "unknown_pool"}})
    state
  end

  defp handle_request(%{"type" => "pool", "id" => id, "pool" => pool}, state) do
    send(
      self(),
      {:send, %{type: "pool", id: id, pool: pool, size: 4, free: 3, quarantined: 0}}
    )

    state
  end

  defp handle_request(
         %{"type" => "signal", "spawn_id" => spawn_id, "sig" => "SIG" <> sig},
         state
       ),
       do: signal(state, spawn_id, sig)

  defp handle_request(
         %{"type" => "release", "spawn_id" => spawn_id, "grace_ms" => grace_ms},
         state
       )
       when grace_ms > 0 do
    Process.send_after(self(), {:kill_after, spawn_id}, grace_ms)
    signal(state, spawn_id, "TERM")
  end

  defp handle_request(%{"type" => "release", "spawn_id" => spawn_id}, state),
    do: signal(state, spawn_id, "KILL")

  defp handle_request(_request, state), do: state

  defp spawn_in_place(%{"id" => id} = request, %{mode: mode} = state)
       when mode in [
              :capacity,
              :memory_unavailable,
              :home_over_cap,
              :hosts_unresolved,
              :guard_unavailable
            ] do
    send(self(), {:send, %{type: "error", id: id, code: Atom.to_string(mode)}})
    %{state | places: Map.delete(state.places, request["place"])}
  end

  defp spawn_in_place(%{"id" => id, "place" => place}, %{mode: {:exec_failed, test}} = state) do
    spawn_id = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    send(self(), {:send, %{type: "error", id: id, spawn_id: spawn_id, code: "exec_failed"}})
    send(test, {:exec_failed, spawn_id})
    %{state | places: Map.update!(state.places, place, &%{&1 | spawn: spawn_id})}
  end

  defp spawn_in_place(request, state) do
    spawn_id = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    send(
      self(),
      {:send, %{type: "spawned", id: request["id"], spawn_id: spawn_id, uid: 30_001, pid: 1}}
    )

    fake = self()
    mode = state.mode
    spawn(fn -> relay(fake, spawn_id, request, mode) end)
    place = request["place"]
    places = Map.update!(state.places, place, &%{&1 | spawn: spawn_id})
    %{state | spawns: Map.put(state.spawns, spawn_id, nil), places: places}
  end

  # Whose a place or an assign says the place is, as a measured reply names it.
  defp whose(request), do: Map.take(request, ["kind", "athanor", "subject"])

  defp measured(path) do
    path
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&File.lstat!/1)
    |> Enum.filter(&(&1.type == :regular))
    |> Enum.map(& &1.size)
    |> Enum.sum()
  end

  # A spawn whose command has not yet started holds the signal until it
  # does, as cyfr-locus signals a spawn it has answered whether or not its
  # command runs yet; an unknown spawn takes none.
  defp signal(state, spawn_id, sig) do
    case Map.fetch(state.spawns, spawn_id) do
      {:ok, os_pid} when is_integer(os_pid) ->
        Locus.DirectLauncher.signal_group(os_pid, sig)
        state

      {:ok, nil} ->
        put_in(state.spawns[spawn_id], {:held, [sig]})

      {:ok, {:held, sigs}} ->
        put_in(state.spawns[spawn_id], {:held, [sig | sigs]})

      :error ->
        state
    end
  end

  # A relay's command directory is recorded, and removed however the relay
  # ends: a client or channel gone mid-run ends it before its last frames.
  defp relay(fake, spawn_id, request, mode) do
    dir = short_tmp_dir()
    send(fake, {:command_dir, dir})

    try do
      relay(fake, spawn_id, request, mode, dir)
    after
      File.rm_rf!(dir)
    end
  end

  defp relay(fake, spawn_id, %{"pool" => "build"} = request, {:report_first, reported?}, dir) do
    input = Path.join(dir, "stdin")
    output = Path.join(dir, "stdout")
    File.write!(input, "")

    {exited, stdout, stderr} = run(fake, spawn_id, request, nil, {dir, input, output})
    :ok = GenServer.call(fake, {:send, exited})
    :ok = GenServer.call(fake, {:send, %{type: "released", spawn_id: spawn_id}})
    Prima.Test.Wait.wait_until(reported?, 5_000, "the client to read the release report")

    conn = dial(fake, request)
    _stdin = read_stdin(conn, [])
    finish(conn, [frames(@stream_stderr, stderr), frames(@stream_stdout, stdout)])
  end

  defp relay(fake, spawn_id, request, mode, dir) do
    input = Path.join(dir, "stdin")
    output = Path.join(dir, "stdout")
    conn = dial(fake, request)

    case {request["pool"], mode} do
      {"build", _mode} -> run_build(fake, spawn_id, request, mode, conn, {dir, input, output})
      {_pool, {:exit, exited}} -> exit_as(fake, spawn_id, conn, exited)
      {_pool, {:exit_closed, exited}} -> live(fake, spawn_id, request, conn, dir, exited)
      {_pool, _mode} -> live(fake, spawn_id, request, conn, dir, %{})
    end
  end

  defp dial(fake, request) do
    {:ok, conn} =
      :gen_tcp.connect({:local, request["attach"]["path"]}, 0, [
        :binary,
        active: false,
        packet: :raw
      ])

    :ok = :gen_tcp.send(conn, frame(@stream_attach, request["attach"]["token"]))
    :ok = GenServer.call(fake, :dialed)
    conn
  end

  defp run_build(fake, spawn_id, request, mode, conn, {dir, input, output}) do
    File.write!(input, read_stdin(conn, []))

    case mode do
      {:exit, exited} ->
        exit_as(fake, spawn_id, conn, exited)

      _mode ->
        {exited, stdout, ""} = run(fake, spawn_id, request, conn, {dir, input, output})
        finish(conn, [frames(@stream_stdout, stdout)])
        send(fake, {:send, exited})
        send(fake, {:send, %{type: "released", spawn_id: spawn_id}})
    end
  end

  defp exit_as(fake, spawn_id, conn, exited) do
    finish(conn, [frames(@stream_stderr, "the command's last words\n")])
    send(fake, {:send, Map.merge(%{type: "exited", spawn_id: spawn_id}, exited)})
    send(fake, {:send, %{type: "released", spawn_id: spawn_id}})
  end

  # The relay's last frames, then the end of both streams.
  defp finish(conn, frames) do
    :gen_tcp.send(conn, [frames, frame(@stream_stdout, ""), frame(@stream_stderr, "")])
    :gen_tcp.close(conn)
  end

  # The command's stderr goes to `conn` as it arrives, or is held for a
  # relay that has not dialled; its stdout is read at its exit.
  defp run(fake, spawn_id, request, conn, {dir, input, output}) do
    # A release may kill the shell before it opens its redirection.
    File.write!(output, "")
    env = Enum.map(request["env"], fn {k, v} -> "#{k}=#{v}" end)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        cd: dir,
        args:
          ["-c", ~s(exec 2>&1 >"$1" <"$2" && shift 2 && exec "$@"), "fake", output, input] ++
            ["/usr/bin/env", "-i", "HOME=#{dir}", "PATH=#{System.get_env("PATH")}" | env] ++
            request["argv"]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    send(fake, {:running, spawn_id, os_pid})
    {status, stderr} = pump(port, conn, [])

    exited = %{
      type: "exited",
      spawn_id: spawn_id,
      code: status,
      signal: nil,
      memory: nil
    }

    exited =
      if status == 137, do: %{exited | code: nil, signal: "SIGKILL"}, else: exited

    {exited, File.read!(output), stderr}
  end

  # A long-lived spawn: stdin frames reach the command as they arrive, its
  # stdout and its stderr (through a fifo `cat` relays) go back apart as
  # it writes them, and its exit ends the relay.
  defp live(fake, spawn_id, request, conn, dir, reported) do
    log = Path.join(dir, "stderr")
    {_, 0} = System.cmd(@mkfifo, ["-m", "600", log], env: Locus.Test.ProcessFamily.no_env())
    env = Enum.map(request["env"], fn {k, v} -> "#{k}=#{v}" end)

    port =
      Port.open({:spawn_executable, "/usr/bin/env"}, [
        :binary,
        :stream,
        :exit_status,
        :use_stdio,
        cd: dir,
        args:
          ["-i", "HOME=#{dir}", "PATH=#{System.get_env("PATH")}" | env] ++
            ["/bin/sh", "-c", ~s(exec "$@" 2>"$0"), log] ++ request["argv"]
      ])

    relay = Port.open({:spawn_executable, "/bin/cat"}, [:binary, :stream, :eof, args: [log]])

    # A command that has already exited has closed its port, which then
    # names no pid.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> os_pid
        nil -> nil
      end

    send(fake, {:running, spawn_id, os_pid})

    pump = self()
    reader = spawn_link(fn -> read_frames(conn, pump) end)
    status = pump_live(port, relay, conn)
    Process.unlink(reader)
    Process.exit(reader, :kill)

    # What is left of the group goes, and the stderr relay drains.
    Locus.DirectLauncher.signal_group(os_pid, "KILL")
    System.cmd("/bin/sh", ["-c", ~s(exec 3<>"$0"), log], env: Locus.Test.ProcessFamily.no_env())
    drain_relay(relay, conn)

    :gen_tcp.send(conn, [frame(@stream_stdout, ""), frame(@stream_stderr, "")])
    :gen_tcp.close(conn)

    exited =
      if status > 128,
        do: %{code: nil, signal: signal_name(status - 128)},
        else: %{code: status, signal: nil}

    report = Map.merge(%{type: "exited", spawn_id: spawn_id, memory: nil}, exited)
    send(fake, {:send, Map.merge(report, reported)})

    send(fake, {:send, %{type: "released", spawn_id: spawn_id}})
  end

  defp signal_name(9), do: "SIGKILL"
  defp signal_name(15), do: "SIGTERM"
  defp signal_name(2), do: "SIGINT"
  defp signal_name(n), do: "SIG#{n}"

  defp read_frames(conn, pump) do
    with {:ok, <<stream, length::32>>} <- :gen_tcp.recv(conn, 5),
         {:ok, payload} <- if(length == 0, do: {:ok, ""}, else: :gen_tcp.recv(conn, length)) do
      send(pump, {:frame, stream, payload})
      read_frames(conn, pump)
    end
  end

  defp pump_live(port, relay, conn) do
    receive do
      {:frame, @stream_stdin, ""} ->
        pump_live(port, relay, conn)

      {:frame, @stream_stdin, payload} ->
        Port.command(port, payload)
        pump_live(port, relay, conn)

      {^port, {:data, data}} ->
        :gen_tcp.send(conn, frames(@stream_stdout, data))
        pump_live(port, relay, conn)

      {^relay, {:data, data}} ->
        :gen_tcp.send(conn, frames(@stream_stderr, data))
        pump_live(port, relay, conn)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  defp drain_relay(relay, conn) do
    receive do
      {^relay, {:data, data}} ->
        :gen_tcp.send(conn, frames(@stream_stderr, data))
        drain_relay(relay, conn)

      {^relay, :eof} ->
        :ok
    after
      1_000 -> :ok
    end
  end

  defp read_stdin(conn, acc) do
    {:ok, <<@stream_stdin, length::32>>} = :gen_tcp.recv(conn, 5, 5_000)

    case length do
      0 ->
        Enum.reverse(acc)

      n ->
        {:ok, payload} = :gen_tcp.recv(conn, n, 5_000)
        read_stdin(conn, [payload | acc])
    end
  end

  defp pump(port, conn, held) do
    receive do
      {^port, {:data, data}} when conn == nil ->
        pump(port, conn, [held | data])

      {^port, {:data, data}} ->
        :gen_tcp.send(conn, frames(@stream_stderr, data))
        pump(port, conn, held)

      {^port, {:exit_status, status}} ->
        {status, IO.iodata_to_binary(held)}
    end
  end

  defp frames(stream, <<chunk::binary-size(65_536), rest::binary>>),
    do: [frame(stream, chunk) | frames(stream, rest)]

  defp frames(_stream, <<>>), do: []
  defp frames(stream, chunk), do: [frame(stream, chunk)]

  defp frame(stream, payload), do: [<<stream, byte_size(payload)::32>>, payload]
end
