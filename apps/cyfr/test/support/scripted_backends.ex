# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Cyfr.Test.ScriptedBackends do
  @moduledoc """
  A Locus backends service whose programs answer from a script instead of
  running, as `Cyfr.Test.ScriptedBuilder` stands in for a builds service.
  Test-only; its users are `async: false`, since the box it answers is one
  named process.

  Everything but the programs is the wire's (`Prima.LocusBackends`). It is
  served by an HTTP listener of its own on a loopback port (`url`), at the
  wire's `control` and `session` routes; `down/1` and `up/1` stop and start
  it on the same port. A control message's `x-cyfr-auth` header is verified
  under the control key, its lifetime and its `(generation, seq)` against the
  high-water mark, and its body read strictly (`read_control/1`); a session
  message's header is verified under the key of the owner it names, its
  lifetime and owner version against what runs, and its body read strictly
  (`read_session/1`). Every answer carries `x-cyfr-boot`, and every refusal
  is `encode_refusal/1` at its code's status. Each accepted control message
  is reported to the test as `{:control, type, message, fields}`, the
  message as its JSON; each session message as `{:session, type, message,
  fields}`; and each JSON-RPC request a `send` carries as
  `{:invoke, method, fields}`.

  Each session is a scripted MCP program: it answers `initialize`,
  `tools/list` (the tools the test sets for its server, as full names
  `<backend>__<tool>`: `github__search` unless set) and `tools/call`
  (`found`), each answer a line in its buffer that `recv` reads past
  `after`, waiting up to its `max_wait_ms`; a method the test sets
  `:silent` is never answered. A session the script ends
  (`end_sessions/2`, a reset or retire of its home, or an idle period set
  with `set(fake, :idle_ms, ms)`: no `send` and no `recv` arriving within
  it, a waiting recv counting at its arrival alone) answers `running:
  false`, and the next `open` of its key starts it afresh (`resumed:
  false`). A session's key is Locus's: its program, home, key and mode.

  `set(fake, :reset_send, true)` resets the connection of the next `send`
  once it has arrived, before any answer. `hold/2` holds a control or a
  session message of its type.

  A `homes` message answers the kept homes the script holds (`homes`, a
  set: each an open names, until its retire; `set(fake, :homes, …)`).

  A status reports `stderr_bytes` of stderr per program (none unless set),
  as its tail for a scratch program and as its length for a kept one: the script does not bound its answers, so a test can see what the
  box makes of an unbounded one. `answer_version` is the protocol version
  its answers name (the wire's unless set).
  """

  import Plug.Conn

  alias Prima.LocusBackends

  @doc "Start the service for the calling test, reporting to `test` and keyed by `root`."
  def start(test, root) do
    agent =
      ExUnit.Callbacks.start_supervised!(
        {Agent,
         fn ->
           %{
             test: test,
             root: root,
             boot: "bb_first",
             hwm: {0, 0},
             owners: %{},
             programs: %{},
             sessions: %{},
             keys: %{},
             tools: %{},
             hold: MapSet.new(),
             pool: 32,
             stderr_bytes: 0,
             homes: MapSet.new(),
             idle_ms: nil,
             silent: [],
             answer_version: LocusBackends.version(),
             refuse: %{},
             reset_send: false
           }
         end},
        id: :scripted_backends
      )

    port = listen(agent, 0)
    %{agent: agent, port: port, url: "http://127.0.0.1:#{port}"}
  end

  # A plain listener, not Bypass: a request whose client goes away mid-way
  # (a reader the server kills while its recv waits, as it may) ends with
  # its connection, and no end-of-test check counts it as a failure.
  @listener :scripted_backends_listener

  defp listen(agent, port) do
    pid =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug: {__MODULE__.Router, agent},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: port,
           startup_log: false},
          id: @listener
        )
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  @doc "Stop the service's listener: every request is refused at connect, as a service that is down."
  def down(%{}), do: ExUnit.Callbacks.stop_supervised!(@listener)

  @doc "Start the service's listener again on its port."
  def up(%{agent: agent, port: port}) do
    ^port = listen(agent, port)
    :ok
  end

  defmodule Router do
    @moduledoc false
    import Plug.Conn

    def init(agent), do: agent

    def call(%{method: "POST", request_path: path} = conn, agent) do
      cond do
        path == LocusBackends.route(:control) ->
          serve(conn, &Cyfr.Test.ScriptedBackends.control_request(&1, agent))

        path == LocusBackends.route(:session) ->
          serve(conn, &Cyfr.Test.ScriptedBackends.session_request(&1, agent))

        true ->
          send_resp(conn, 404, "")
      end
    end

    def call(conn, _agent), do: send_resp(conn, 404, "")

    # A store the test already stopped answers a late request 503.
    defp serve(conn, handler) do
      handler.(conn)
    catch
      :exit, _reason -> send_resp(conn, 503, "")
    end
  end

  @doc false
  def control_request(conn, agent), do: control(conn, agent)

  @doc false
  def session_request(conn, agent), do: session(conn, agent)

  @doc "A new lifetime: every owner and session forgotten and the high-water mark reset, as a restarted service."
  def restart(%{agent: agent}, boot),
    do:
      Agent.update(
        agent,
        &%{&1 | boot: boot, hwm: {0, 0}, owners: %{}, sessions: %{}, keys: %{}}
      )

  @doc """
  Refuse the next message of `what` — a control type, a session type, or a
  JSON-RPC method a `send` carries — with `code`, at its status unless
  `status` names another.
  """
  def refuse_once(%{agent: agent}, what, code, status \\ nil) do
    status = status || LocusBackends.status(String.to_existing_atom(code))
    Agent.update(agent, &put_in(&1, [:refuse, what], {code, status}))
  end

  def set(%{agent: agent}, key, value), do: Agent.update(agent, &Map.put(&1, key, value))

  @doc """
  End every session of `server`'s owner, as an idle period or a crash
  would; with `exit_code`, as its process exiting with that status, which
  a `recv` of it answers.
  """
  def end_sessions(%{agent: agent}, server, exit_code \\ nil) do
    Agent.update(agent, fn st ->
      sessions =
        Map.new(st.sessions, fn {id, s} ->
          if elem(s.owner, 1) == server,
            do: {id, %{s | running: false, exit_code: exit_code}},
            else: {id, s}
        end)

      %{st | sessions: sessions}
    end)
  end

  @doc "The sessions of `server`'s owner, by id."
  def sessions(%{agent: agent}, server) do
    Agent.get(agent, fn st ->
      for {id, s} <- st.sessions, elem(s.owner, 1) == server, into: %{}, do: {id, s}
    end)
  end

  @doc "Write `line` into every running session of `server`, as its program would."
  def write(%{agent: agent}, server, line) do
    Agent.update(agent, fn st ->
      sessions =
        Map.new(st.sessions, fn {id, s} ->
          if elem(s.owner, 1) == server and s.running,
            do: {id, emit(s, line)},
            else: {id, s}
        end)

      %{st | sessions: sessions}
    end)
  end

  defmodule Teardown do
    @moduledoc false
    use GenServer

    def start_link(stop), do: GenServer.start_link(__MODULE__, stop)

    @impl true
    def init(stop) do
      Process.flag(:trap_exit, true)
      {:ok, stop}
    end

    @impl true
    def terminate(_reason, stop), do: stop.()
  end

  @doc """
  The local box of the programs controller (`Opus.Programs.Box`) under the
  calling test, started with `opts`, and stopped when the test ends as the
  application stops it: after the server processes and sign-in relays,
  which release their owners through it as they stop, and only once it has
  nothing left to send.
  """
  def supervise_controller(opts) do
    opts = Keyword.merge([box: Opus.Programs.local(), name: Opus.Programs.via("local")], opts)
    controller = ExUnit.Callbacks.start_supervised!({Opus.Programs.Box, opts})
    ExUnit.Callbacks.start_supervised!({Teardown, &quiesce/0}, shutdown: 10_000)
    controller
  end

  defp quiesce(deadline \\ System.monotonic_time(:millisecond) + 3_000) do
    for {_id, pid, _type, _modules} <-
          DynamicSupervisor.which_children(Emissary.External.ServerSupervisor) do
      DynamicSupervisor.terminate_child(Emissary.External.ServerSupervisor, pid)
    end

    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(Opus.Programs.Relays) do
      DynamicSupervisor.terminate_child(Opus.Programs.Relays, pid)
    end

    state = :sys.get_state(Opus.Programs.via("local"))

    settled =
      state.owners == %{} and state.releases == %{} and state.claims == %{} and
        state.releasing == %{} and state.inflight == nil and :queue.is_empty(state.urgent) and
        :queue.is_empty(state.queue)

    cond do
      settled ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk(
          "timed out waiting for the controller to run no owner, hold no claim and " <>
            "have nothing left to send"
        )

      true ->
        Process.sleep(10)
        quiesce(deadline)
    end
  end

  @doc "The tool names, `<backend>__<tool>`, the programs of `server` list."
  def tools(%{agent: agent}, server, names),
    do: Agent.update(agent, &put_in(&1, [:tools, server], names))

  @doc "Hold the next message of `type` until the test sends `:go` to the pid it reports."
  def hold(%{agent: agent}, type),
    do: Agent.update(agent, &%{&1 | hold: MapSet.put(&1.hold, type)})

  # ————— control —————

  defp control(conn, agent) do
    {:ok, body, conn} = read_body(conn)
    st = Agent.get(agent, & &1)
    header = get_req_header(conn, LocusBackends.auth_header())

    with [header] <- header,
         {:ok, fields} <-
           LocusBackends.verify(:control, st.root, header, body, System.os_time(:millisecond)) do
      case LocusBackends.read_control(body) do
        {:ok, %{type: type}} -> accepted(conn, agent, st, type, Jason.decode!(body), fields)
        {:error, error} -> refuse(conn, st, LocusBackends.refusal_for(error))
      end
    else
      _unauthenticated -> refuse(conn, st, :unauthorized)
    end
  end

  defp accepted(conn, agent, st, type, message, fields) do
    cond do
      fields.boot != if(type == :hello, do: "-", else: st.boot) ->
        refuse(conn, st, :stale_boot)

      {fields.generation, fields.seq} <= st.hwm ->
        refuse(conn, st, :stale_control)

      true ->
        Agent.update(agent, &%{&1 | hwm: {fields.generation, fields.seq}})
        send(st.test, {:control, message["type"], message, fields})
        held(agent, message["type"])

        case pop_refusal(agent, message["type"]) do
          nil -> handle(conn, agent, message, fields)
          {code, status} -> answer(conn, st, status, %{"version" => 2, "error" => code})
        end
    end
  end

  defp held(agent, type) do
    st = Agent.get(agent, & &1)

    if MapSet.member?(st.hold, type) do
      Agent.update(agent, &%{&1 | hold: MapSet.delete(&1.hold, type)})
      send(st.test, {:held, type, self()})

      receive do
        :go -> :ok
      after
        5_000 -> :ok
      end
    end
  end

  defp handle(conn, agent, %{"type" => "hello"}, _fields) do
    st = Agent.get(agent, & &1)

    control_answer(conn, st, %{
      "boot" => st.boot,
      "pool" => %{"size" => st.pool, "free" => st.pool}
    })
  end

  defp handle(conn, agent, %{"type" => "reconcile", "keep" => keep}, fields) do
    kept =
      for %{"athanor" => a, "server" => s, "e" => e} <- keep,
          do: {{a, s}, {fields.generation, e}}

    Agent.update(agent, fn st ->
      %{st | owners: Map.filter(st.owners, fn owner -> owner in kept end)}
    end)

    control_answer(conn, Agent.get(agent, & &1), %{"released" => []})
  end

  defp handle(conn, agent, %{"type" => "sync"} = message, fields) do
    st = Agent.get(agent, & &1)
    %{"owner" => %{"athanor" => athanor, "server" => server}, "e" => e} = message

    owner = %{athanor: athanor, server: server, generation: fields.generation, epoch: e}

    {:ok, plaintext} =
      LocusBackends.open(LocusBackends.seal_key(st.root), owner, st.boot, message["sealed"])

    send(st.test, {:sealed_env, server, Jason.decode!(plaintext)})

    Agent.update(agent, fn st ->
      st
      |> put_in([:owners, {athanor, server}], {fields.generation, e})
      |> put_in([:programs, {athanor, server}], message["programs"])
    end)

    programs = for p <- message["programs"], do: %{"name" => p["name"], "status" => "idle"}
    control_answer(conn, st, %{"status" => "running", "programs" => programs})
  end

  defp handle(conn, agent, %{"type" => "renew", "owners" => owners}, fields) do
    st = Agent.get(agent, & &1)

    {renewed, unknown} =
      Enum.split_with(owners, fn %{"athanor" => a, "server" => s, "e" => e} ->
        Map.get(st.owners, {a, s}) == {fields.generation, e}
      end)

    renewed = for owner <- renewed, do: Map.put(owner, "state", "running")
    control_answer(conn, st, %{"renewed" => renewed, "unknown" => unknown})
  end

  defp handle(conn, agent, %{"type" => "release", "owners" => owners}, fields) do
    released =
      for %{"athanor" => a, "server" => s, "e" => e} <- owners,
          version = Agent.get(agent, &Map.get(&1.owners, {a, s})),
          version != nil and version <= {fields.generation, e},
          do: %{"athanor" => a, "server" => s, "g" => elem(version, 0), "e" => elem(version, 1)}

    gone = MapSet.new(released, &{&1["athanor"], &1["server"]})

    Agent.update(agent, fn st ->
      sessions =
        Map.new(st.sessions, fn {id, s} ->
          if MapSet.member?(gone, s.owner), do: {id, %{s | running: false}}, else: {id, s}
        end)

      %{st | owners: Map.drop(st.owners, MapSet.to_list(gone)), sessions: sessions}
    end)

    control_answer(conn, Agent.get(agent, & &1), %{"released" => released})
  end

  defp handle(conn, agent, %{"type" => "status", "owners" => named}, _fields) do
    st = Agent.get(agent, & &1)

    owners =
      for owner <- named,
          {g, e} <- List.wrap(Map.get(st.owners, {owner["athanor"], owner["server"]})) do
        key = {owner["athanor"], owner["server"]}

        programs =
          for p <- Map.get(st.programs, key, [%{"name" => "github", "home" => "scratch"}]) do
            running =
              Enum.count(st.sessions, fn {_id, s} ->
                s.owner == key and s.program == p["name"] and s.running
              end)

            %{
              "name" => p["name"],
              "status" => if(running > 0, do: "running", else: "idle"),
              "restarts" => 0,
              "home" => p["home"] || "scratch",
              "over_cap" => false,
              "sessions" => running
            }
            |> Map.merge(
              if p["home"] == "kept",
                do: %{"stderr_bytes" => st.stderr_bytes},
                else: %{"stderr_tail" => String.duplicate("x", st.stderr_bytes)}
            )
          end

        Map.merge(owner, %{
          "g" => g,
          "e" => e,
          "state" => "running",
          "lease_ms_left" => 30_000,
          "programs" => programs
        })
      end

    control_answer(conn, st, %{"owners" => owners})
  end

  # As Locus does, a reset or a retire ends every session of the home among
  # the athanor's owners first.
  defp handle(
         conn,
         agent,
         %{"type" => "home", "op" => op, "athanor" => athanor, "home_id" => home_id},
         _fields
       ) do
    Agent.update(agent, fn st ->
      sessions =
        Map.new(st.sessions, fn {id, s} ->
          if s.home_id == home_id and elem(s.owner, 0) == athanor,
            do: {id, %{s | running: false}},
            else: {id, s}
        end)

      homes = if op == "retire", do: MapSet.delete(st.homes, home_id), else: st.homes
      %{st | sessions: sessions, homes: homes}
    end)

    st = Agent.get(agent, & &1)
    state = if op == "reset", do: "empty", else: "absent"
    control_answer(conn, st, %{"home_id" => home_id, "state" => state})
  end

  defp handle(conn, agent, %{"type" => "homes"}, _fields) do
    st = Agent.get(agent, & &1)
    control_answer(conn, st, %{"homes" => st.homes |> MapSet.to_list() |> Enum.sort()})
  end

  # ————— sessions —————

  defp session(conn, agent) do
    {:ok, body, conn} = read_body(conn)
    st = Agent.get(agent, & &1)
    header = get_req_header(conn, LocusBackends.auth_header())
    now = System.os_time(:millisecond)

    with [header] <- header,
         {:ok, fields} <- LocusBackends.verify(:invoke, st.root, header, body, now) do
      case LocusBackends.read_session(body) do
        {:ok, message} -> session_admitted(conn, agent, st, fields, message, Jason.decode!(body))
        {:error, error} -> refuse(conn, st, LocusBackends.refusal_for(error))
      end
    else
      _unauthenticated -> refuse(conn, st, :unauthorized)
    end
  end

  defp session_admitted(conn, agent, st, fields, message, wire) do
    running = Map.get(st.owners, {fields.athanor, fields.server})
    version = {fields.generation, fields.epoch}

    cond do
      fields.boot != st.boot ->
        refuse(conn, st, :stale_boot)

      running == nil ->
        refuse(conn, st, :unknown_owner)

      version < running ->
        refuse(conn, st, :stale_epoch)

      version > running ->
        refuse(conn, st, :epoch_ahead)

      message.owner != %{athanor: fields.athanor, server: fields.server} or
          message.e != fields.epoch ->
        refuse(conn, st, :bad_request)

      true ->
        expire_idle(agent)
        held(agent, wire["type"])
        send(st.test, {:session, wire["type"], wire, fields})

        case pop_refusal(agent, wire["type"]) || send_refusal(agent, message) do
          nil when message.type == :send and st.reset_send ->
            # The send arrived (the test was told), and the connection is
            # reset before any answer: what its sender cannot tell from a
            # send that never left.
            Agent.update(agent, &%{&1 | reset_send: false})
            Process.exit(self(), :kill)

          nil ->
            handle_session(conn, agent, fields, message)

          {code, status} ->
            answer(conn, Agent.get(agent, & &1), status, %{"version" => 2, "error" => code})
        end
    end
  end

  # A `send` carrying a JSON-RPC request whose method the test refuses.
  defp send_refusal(agent, %{type: :send, lines: lines}) do
    Enum.find_value(lines, fn line ->
      case Jason.decode(line) do
        {:ok, %{"method" => method}} -> pop_refusal(agent, method)
        _ -> nil
      end
    end)
  end

  defp send_refusal(_agent, _message), do: nil

  defp expire_idle(agent) do
    Agent.update(agent, fn
      %{idle_ms: nil} = st ->
        st

      st ->
        now = System.monotonic_time(:millisecond)

        sessions =
          Map.new(st.sessions, fn {id, s} ->
            if s.running and now - s.active >= st.idle_ms,
              do: {id, %{s | running: false}},
              else: {id, s}
          end)

        %{st | sessions: sessions}
    end)
  end

  defp handle_session(conn, agent, fields, %{type: :open} = message) do
    # A session's key is Locus's: its program, home, key and mode.
    key =
      {fields.athanor, fields.server, message.program, message.home_id, message.key, message.mode}

    answer =
      Agent.get_and_update(agent, fn st ->
        case st.keys[key] && st.sessions[st.keys[key]] do
          %{running: true} ->
            id = st.keys[key]

            {%{
               "status" => "running",
               "session" => id,
               "resumed" => true,
               "pty" => message.mode == :sign_in
             }, touch(st, id)}

          _none_or_ended ->
            id = "ss_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

            s = %{
              owner: {fields.athanor, fields.server},
              program: message.program,
              key: message.key,
              home_id: message.home_id,
              mode: message.mode,
              lines: [],
              seq: 0,
              running: true,
              exit_code: nil,
              active: System.monotonic_time(:millisecond)
            }

            st = %{st | sessions: Map.put(st.sessions, id, s), keys: Map.put(st.keys, key, id)}

            st =
              if message.home_id,
                do: %{st | homes: MapSet.put(st.homes, message.home_id)},
                else: st

            {%{
               "status" => "running",
               "session" => id,
               "resumed" => false,
               "pty" => message.mode == :sign_in
             }, st}
        end
      end)

    session_answer(conn, Agent.get(agent, & &1), answer)
  end

  defp handle_session(conn, agent, fields, %{type: :send, session: id, lines: lines}) do
    st = Agent.get(agent, & &1)

    case st.sessions[id] do
      nil ->
        refuse(conn, st, :unknown_session)

      %{running: false} ->
        session_answer(conn, st, %{"status" => "ended"})

      s ->
        for line <- lines,
            {:ok, %{"method" => method, "id" => _}} <- [Jason.decode(line)],
            do: send(st.test, {:invoke, method, fields})

        Agent.update(agent, fn st ->
          s = Enum.reduce(lines, s, &program_line(st, elem(s.owner, 1), &2, &1))
          %{touch(st, id) | sessions: Map.put(st.sessions, id, %{s | active: now()})}
        end)

        session_answer(conn, st, %{"status" => "running"})
    end
  end

  # A recv counts as the session's use when it arrives, as Locus counts it,
  # not while it waits: a session no line reaches is ended by its idle
  # period even with a recv waiting on it.
  defp handle_session(conn, agent, _fields, %{type: :recv} = message) do
    Agent.update(agent, &touch(&1, message.session))
    deadline = now() + message.max_wait_ms
    recv(conn, agent, message.session, message.after, deadline)
  end

  defp handle_session(conn, agent, _fields, %{type: :close, session: id}) do
    Agent.update(agent, fn st ->
      case st.sessions[id] do
        nil -> st
        s -> %{st | sessions: Map.put(st.sessions, id, %{s | running: false})}
      end
    end)

    session_answer(conn, Agent.get(agent, & &1), %{"status" => "closed"})
  end

  defp recv(conn, agent, id, after_seq, deadline) do
    st = Agent.get(agent, & &1)

    case st.sessions[id] do
      nil ->
        refuse(conn, st, :unknown_session)

      s ->
        lines =
          for {seq, text} <- Enum.reverse(s.lines),
              seq > after_seq,
              do: %{"seq" => seq, "text" => text}

        if lines != [] or not s.running or now() >= deadline do
          answer = %{"lines" => lines, "dropped" => 0, "running" => s.running}

          answer =
            if s.exit_code != nil and not s.running,
              do: Map.put(answer, "exit_code", s.exit_code),
              else: answer

          session_answer(conn, st, answer)
        else
          Process.sleep(10)
          expire_idle(agent)
          recv(conn, agent, id, after_seq, deadline)
        end
    end
  end

  defp touch(st, id) do
    case st.sessions[id] do
      nil -> st
      s -> %{st | sessions: Map.put(st.sessions, id, %{s | active: now()})}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # The scripted program: a JSON-RPC request is answered with a line, a
  # notification with nothing.
  defp program_line(st, server, s, line) do
    case Jason.decode(line) do
      {:ok, %{"method" => method, "id" => id}} when id != nil ->
        if method in st.silent do
          s
        else
          answer = %{"jsonrpc" => "2.0", "id" => id, "result" => result(st, server, s, method)}
          emit(s, Jason.encode!(answer))
        end

      _ ->
        s
    end
  end

  defp emit(s, text), do: %{s | seq: s.seq + 1, lines: [{s.seq + 1, text} | s.lines]}

  defp result(_st, _server, _s, "initialize"),
    do: %{
      "protocolVersion" => Prima.MCP.Protocol.legacy_version(),
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => %{"name" => "scripted", "version" => "1"}
    }

  defp result(st, server, s, "tools/list") do
    prefix = s.program <> "__"

    names =
      for name <- Map.get(st.tools, server, ["github__search"]),
          String.starts_with?(name, prefix),
          do: String.replace_prefix(name, prefix, "")

    %{
      "tools" => for(name <- names, do: %{"name" => name, "inputSchema" => %{"type" => "object"}})
    }
  end

  defp result(_st, _server, _s, "tools/call"),
    do: %{"content" => [%{"type" => "text", "text" => "found"}]}

  defp result(_st, _server, _s, _method), do: %{}

  defp pop_refusal(agent, what) do
    Agent.get_and_update(agent, fn st ->
      {Map.get(st.refuse, what), %{st | refuse: Map.delete(st.refuse, what)}}
    end)
  end

  defp refuse(conn, st, code),
    do: answer(conn, st, LocusBackends.status(code), LocusBackends.encode_refusal(code))

  defp control_answer(conn, st, body),
    do: answer(conn, st, 200, Map.put(body, "version", st.answer_version))

  defp session_answer(conn, st, body),
    do: answer(conn, st, 200, Map.put(body, "version", st.answer_version))

  defp answer(conn, st, status, body) when is_map(body),
    do: answer(conn, st, status, Jason.encode!(body))

  defp answer(conn, st, status, body) when is_binary(body) do
    conn
    |> put_resp_header(LocusBackends.boot_header(), st.boot)
    |> put_resp_content_type("application/json")
    |> resp(status, body)
  end
end
