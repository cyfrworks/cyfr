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
  wire's `control`, `session` and `close` routes; `down/1` and `up/1` stop
  and start it on the same port. A control message's `x-cyfr-auth` header is verified
  under the control key, its lifetime and its `(generation, seq)` against the
  high-water mark, and its body read strictly (`read_control/1`); a session
  message's header is verified under the key of the owner it names, its
  lifetime and owner version against what runs, and its body read strictly
  (`read_session/1`). An owner holds a lease, set by its `sync` and
  extended by each `renew`; once it has run out the owner is lapsed, as
  Locus lapses one, and gone once its sessions have drained, which a
  scripted session does at once: the session message that finds the
  lease run out is refused `lapsed`, every later one `unknown_owner`, a
  renewal answers it unknown and a release or a status names it no more,
  until a sync admits it as a new owner, and a sync at another version or
  a reconcile that keeps none ends the sessions of the owner it replaces.
  An open answers the session running for its lifetime, waits while
  another lifetime's runs under its key, and is refused `lifetime_over`
  for a lifetime closed, ended or of another boot than the one it runs.
  A close is verified alike but asks for no owner: it ends the one
  lifetime it names, opened or not, and is answered `closed`, since a
  scripted session's place is back as soon as it ends; it is reported,
  held and refused as a session message of type `close`, with the
  `session` its lifetime opened beside its members, where one was. Every answer carries `x-cyfr-boot`, and every refusal
  is `encode_refusal/1` at its code's status. Each accepted control message
  is reported to the test as `{:control, type, message, fields}`, the
  message as its JSON; each session message as `{:session, type, message,
  fields}`; and each JSON-RPC request a `send` carries as
  `{:invoke, method, fields}`.

  Each session is a scripted MCP program, answering as a server over stdio
  does: `initialize`, declaring what the test sets for its server with
  `set(fake, :offers, %{server_id => offers})` (`["tools"]` unless set;
  `"resources"` and `"prompts"` beside it), `tools/list` (the tools the
  test sets for its server with `tools(fake, server_id, names)`: `search`
  unless set), paged one tool a page under `nextCursor` unless
  `set(fake, :page_size, n)`, `tools/call` (`found`) and `ping`; for a
  server offering them, `resources/list` (`file:///readme`),
  `resources/templates/list` (`file:///{path}`), `resources/read` of any
  uri (`read <uri>`), `prompts/list` (`greet`, taking `who`) and
  `prompts/get` (`<name> <who>`); a cursor it never issued, a call of a
  tool it does not list and any other method are answered with a
  JSON-RPC error.
  Each answer is a line in its buffer that `recv` reads past `after`,
  waiting up to its `max_wait_ms`; a method the test sets `:silent` is
  never answered. A `terminal` session runs no script: it takes `input`
  and `resize` (the test told of each, as of every message), and `output`
  reads the chunks `write/3` puts in its buffer, each line with a carriage
  return and a newline as a terminal ends it, and those `write_raw/3`
  puts as a program wrote them. `set(fake, :terminal, pid)` hands each
  terminal session's start to `pid` as `{:terminal_opened, fake,
  session}` and each input as `{:terminal_input, fake, session, bytes}`,
  in the order they arrive, so a scripted program answers on its
  terminal (`Cyfr.Test.ScriptedDriver`). A message of the other mode
  is refused `bad_request`. A session the script ends
  (`end_sessions/2`, a reset or retire of its home, or an idle period set
  with `set(fake, :idle_ms, ms)`: no `send` and no `recv` arriving within
  it, a waiting recv counting at its arrival alone) answers `running:
  false`, and the next lifetime of its key starts it afresh (`resumed:
  false`). A session's key is Locus's: its program, home, key and mode.

  `set(fake, :reset_send, true)` resets the connection of the next `send`
  once it has arrived, before any answer, and `set(fake, :lose_close,
  true)` that of the next close once it was carried out, so its answer is
  lost. `set(fake, :dropped, n)` makes
  the next answer that carries lines say `n` were lost before them. `hold/2` holds a control or a
  session message of its type, and `"opened"` holds an open's answer
  once its session stands.

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
             leases: %{},
             programs: %{},
             sessions: %{},
             spent: MapSet.new(),
             closed: MapSet.new(),
             tools: %{},
             offers: %{},
             hold: [],
             pool: 32,
             stderr_bytes: 0,
             homes: MapSet.new(),
             idle_ms: nil,
             silent: [],
             answer_version: LocusBackends.version(),
             refuse: %{},
             reset_send: false,
             lose_close: false
           }
         end},
        id: :scripted_backends
      )

    port = listen(agent, 0)
    %{agent: agent, port: port, url: "http://127.0.0.1:#{port}"}
  end

  # A plain listener, not `Cyfr.Test.HTTPStub`: a request whose client goes away mid-way
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

        path == LocusBackends.route(:close) ->
          serve(conn, &Cyfr.Test.ScriptedBackends.close_request(&1, agent))

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

  @doc false
  def close_request(conn, agent), do: close(conn, agent)

  @doc "A new lifetime: every owner and session forgotten and the high-water mark reset, as a restarted service."
  def restart(%{agent: agent}, boot),
    do:
      Agent.update(
        agent,
        &%{
          &1
          | boot: boot,
            hwm: {0, 0},
            owners: %{},
            leases: %{},
            sessions: %{},
            spent: MapSet.new()
        }
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

  @doc """
  Put `bytes` into the running terminal session `session`'s output as its
  program wrote them, in chunks of at most the wire's
  `Prima.LocusBackends.max_chunk_bytes/0`, as the service buffers them.
  """
  def write_raw(%{agent: agent}, session, bytes) when is_binary(bytes) do
    Agent.update(agent, fn st ->
      case st.sessions[session] do
        %{running: true} = s ->
          s = Enum.reduce(raw_chunks(bytes), s, &emit(&2, {:raw, &1}))
          %{st | sessions: Map.put(st.sessions, session, s)}

        _ended_or_gone ->
          st
      end
    end)
  end

  defp raw_chunks(bytes) do
    max = LocusBackends.max_chunk_bytes()

    if byte_size(bytes) <= max,
      do: [bytes],
      else: [
        binary_part(bytes, 0, max) | raw_chunks(binary_part(bytes, max, byte_size(bytes) - max))
      ]
  end

  @doc """
  The service's sweep: every owner whose lease has run out lapses, its
  sessions ended, with no message of any client's to find it.
  """
  def lapse(%{agent: agent}), do: lapse_expired(agent)

  @doc "Whether the service carried out a close of the box's `lifetime`, a refused one being none."
  def closed?(%{agent: agent}, lifetime) do
    named = %{
      owner: {lifetime.athanor, lifetime.server},
      version: {lifetime.generation, lifetime.epoch},
      key: {lifetime.program, lifetime.home_id, lifetime.key, lifetime.mode},
      lifetime: lifetime.id
    }

    Agent.get(agent, &MapSet.member?(&1.closed, named))
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

  @doc """
  Write `line` into every running session of `server` and end each with
  `exit_code` in one step, as a program that prints and exits: no `recv`
  is answered the line without the exit.
  """
  def write_and_exit(%{agent: agent}, server, line, exit_code) do
    Agent.update(agent, fn st ->
      sessions =
        Map.new(st.sessions, fn {id, s} ->
          if elem(s.owner, 1) == server and s.running,
            do: {id, %{emit(s, line) | running: false, exit_code: exit_code}},
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
    # The browser and brain holders close the sessions they hold through
    # the box as they stop, before the terminals go.
    for holders <- [Opus.Brain.Holders, Opus.Browser.Holders],
        Process.whereis(holders),
        {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(holders),
        do: DynamicSupervisor.terminate_child(holders, pid)

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
        state.releasing == %{} and state.inflight == nil and state.beside == %{} and
        :queue.is_empty(state.urgent) and :queue.is_empty(state.queue)

    cond do
      settled ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        ExUnit.Assertions.flunk(
          "timed out waiting for the controller to run no owner, hold no claim and " <>
            "have nothing left to send"
        )

      true ->
        # sleep-ok: poll interval of quiesce's deadline-bounded wait for the controller to settle
        Process.sleep(10)
        quiesce(deadline)
    end
  end

  @doc "The tool names the program of `server` lists."
  def tools(%{agent: agent}, server, names),
    do: Agent.update(agent, &put_in(&1, [:tools, server], names))

  @doc """
  Hold the next message of `type` until the test sends `:go` to the pid it
  reports, or 5 s pass; `hold(fake, type, ms)` holds it up to `ms`, past a
  caller's own timeout. Each call holds one more message: three calls hold
  the next three. A held control message is answered under the boot that
  took it, as a service answers what it took before it restarted.
  """
  def hold(fake, type, ms \\ 5_000)

  def hold(%{agent: agent}, type, ms),
    do: Agent.update(agent, &%{&1 | hold: &1.hold ++ [{type, ms}]})

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
        lapse_expired(agent)
        send(st.test, {:control, message["type"], message, fields})
        # Its answer names the boot that took it, however long it is held.
        conn = assign(conn, :boot, st.boot)
        held(agent, message["type"])

        case pop_refusal(agent, message["type"]) do
          nil ->
            handle(conn, agent, message, fields)

          {code, status} ->
            answer(conn, st, status, %{"version" => LocusBackends.version(), "error" => code})
        end
    end
  end

  defp held(agent, type) do
    {held, st} =
      Agent.get_and_update(agent, fn st ->
        case Enum.find(st.hold, &match?({^type, _ms}, &1)) do
          nil -> {{nil, st}, st}
          held -> {{held, st}, %{st | hold: List.delete(st.hold, held)}}
        end
      end)

    case held do
      nil ->
        :ok

      {^type, ms} ->
        send(st.test, {:held, type, self()})

        receive do
          :go -> :ok
        after
          ms -> :ok
        end
    end
  end

  defp handle(conn, agent, %{"type" => "hello"}, _fields) do
    st = Agent.get(agent, & &1)

    control_answer(conn, st, %{
      "boot" => st.boot,
      "pool" => %{"size" => st.pool, "free" => st.pool},
      "memory" => memory()
    })
  end

  defp handle(conn, agent, %{"type" => "reconcile", "keep" => keep}, fields) do
    kept =
      for %{"athanor" => a, "server" => s, "e" => e} <- keep,
          do: {{a, s}, {fields.generation, e}}

    Agent.update(agent, fn st ->
      {owners, gone} = Map.split_with(st.owners, fn owner -> owner in kept end)
      ended(%{st | owners: owners}, Map.keys(gone))
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
      version = {fields.generation, e}
      held = Map.get(st.owners, {athanor, server}, version)
      st = if held == version, do: st, else: ended(st, [{athanor, server}])

      st
      |> put_in([:owners, {athanor, server}], version)
      |> put_in([:leases, {athanor, server}], now() + message["lease_ms"])
      |> put_in([:programs, {athanor, server}], message["programs"])
    end)

    programs = for p <- message["programs"], do: %{"name" => p["name"], "status" => "idle"}
    control_answer(conn, st, %{"status" => "running", "programs" => programs})
  end

  # An owner is renewed, as Locus renews one, only while it runs at exactly
  # the message's `(g, e)` and its lease has not run out; a renewal extends
  # the lease from now by the message's `lease_ms`. Any other is unknown.
  defp handle(conn, agent, %{"type" => "renew", "owners" => owners} = message, fields) do
    now = now()

    {renewed, unknown} =
      Agent.get_and_update(agent, fn st ->
        {renewed, unknown} =
          Enum.split_with(owners, fn %{"athanor" => a, "server" => s, "e" => e} ->
            Map.get(st.owners, {a, s}) == {fields.generation, e} and
              Map.get(st.leases, {a, s}, now) > now
          end)

        leases =
          Enum.reduce(renewed, st.leases, fn %{"athanor" => a, "server" => s}, leases ->
            Map.put(leases, {a, s}, now + message["lease_ms"])
          end)

        {{renewed, unknown}, %{st | leases: leases}}
      end)

    renewed = for owner <- renewed, do: Map.put(owner, "state", "running")
    control_answer(conn, Agent.get(agent, & &1), %{"renewed" => renewed, "unknown" => unknown})
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

    control_answer(conn, st, %{"owners" => owners, "memory" => memory()})
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

  # A retired owner's sessions end, as Locus drains them.
  defp ended(st, owners) do
    sessions =
      Map.new(st.sessions, fn {id, s} ->
        if s.owner in owners, do: {id, %{s | running: false}}, else: {id, s}
      end)

    %{st | sessions: sessions}
  end

  # An owner whose lease ran out is lapsed, as Locus lapses one
  # (`Locus.Backends.Owners`): its sessions end and it leaves the owners.
  # Locus answers `lapsed` while a lapsed owner drains and `unknown_owner`
  # once it is gone; a scripted session ends at once, so the drain does
  # too, and only the message that finds the lease run out (Locus's own
  # admission lapses an owner there) is told `lapsed`. Answers the owners
  # this call lapsed. Done before each message is answered, so a renewal
  # answers such an owner unknown and a release or a status names it no
  # more.
  defp lapse_expired(agent) do
    now = now()

    Agent.get_and_update(agent, fn st ->
      case for {key, until} <- st.leases, until <= now, Map.has_key?(st.owners, key), do: key do
        [] ->
          {[], st}

        expired ->
          sessions =
            Map.new(st.sessions, fn {id, s} ->
              if s.owner in expired, do: {id, %{s | running: false}}, else: {id, s}
            end)

          {expired,
           %{
             st
             | owners: Map.drop(st.owners, expired),
               leases: Map.drop(st.leases, expired),
               sessions: sessions
           }}
      end
    end)
  end

  # ————— sessions —————

  defp session(conn, agent) do
    {:ok, body, conn} = read_body(conn)
    lapsed = lapse_expired(agent)
    st = Agent.get(agent, & &1)
    header = get_req_header(conn, LocusBackends.auth_header())
    now = System.os_time(:millisecond)

    with [header] <- header,
         {:ok, fields} <- LocusBackends.verify(:invoke, st.root, header, body, now) do
      case LocusBackends.read_session(body) do
        {:ok, message} ->
          session_admitted(conn, agent, st, fields, message, Jason.decode!(body), lapsed)

        {:error, error} ->
          refuse(conn, st, LocusBackends.refusal_for(error))
      end
    else
      _unauthenticated -> refuse(conn, st, :unauthorized)
    end
  end

  defp session_admitted(conn, agent, st, fields, message, wire, lapsed) do
    running = Map.get(st.owners, {fields.athanor, fields.server})
    version = {fields.generation, fields.epoch}

    cond do
      fields.boot != st.boot ->
        refuse(conn, st, :stale_boot)

      running == nil and {fields.athanor, fields.server} in lapsed ->
        refuse(conn, st, :lapsed)

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
            answer(conn, Agent.get(agent, & &1), status, %{
              "version" => LocusBackends.version(),
              "error" => code
            })
        end
    end
  end

  # A close asks nothing of the owner: its header is the proof, and it
  # ends only what that version opened.
  defp close(conn, agent) do
    {:ok, body, conn} = read_body(conn)
    lapse_expired(agent)
    st = Agent.get(agent, & &1)
    header = get_req_header(conn, LocusBackends.auth_header())
    now = System.os_time(:millisecond)

    with [header] <- header,
         {:ok, fields} <- LocusBackends.verify(:invoke, st.root, header, body, now) do
      case LocusBackends.read_close(body) do
        {:ok, message} -> close_admitted(conn, agent, st, fields, message, Jason.decode!(body))
        {:error, error} -> refuse(conn, st, LocusBackends.refusal_for(error))
      end
    else
      _unauthenticated -> refuse(conn, st, :unauthorized)
    end
  end

  defp close_admitted(conn, agent, st, fields, message, wire) do
    cond do
      fields.boot != st.boot ->
        refuse(conn, st, :stale_boot)

      message.owner != %{athanor: fields.athanor, server: fields.server} or
          message.e != fields.epoch ->
        refuse(conn, st, :bad_request)

      true ->
        held(agent, "close")
        named = lifetime(fields, message)
        send(st.test, {:session, "close", reported(agent, wire, named), fields})

        case pop_refusal(agent, "close") do
          nil ->
            if closed(agent, named), do: Process.exit(self(), :kill)
            session_answer(conn, Agent.get(agent, & &1), %{"status" => "closed"})

          {code, status} ->
            answer(conn, Agent.get(agent, & &1), status, %{
              "version" => LocusBackends.version(),
              "error" => code
            })
        end
    end
  end

  # One lifetime, as Locus identifies one.
  defp lifetime(fields, message) do
    %{
      owner: {fields.athanor, fields.server},
      version: {fields.generation, fields.epoch},
      key: {message.program, message.home_id, message.key, message.mode},
      lifetime: message.lifetime
    }
  end

  defp reported(agent, wire, named) do
    Agent.get(agent, fn st ->
      case Enum.find(st.sessions, fn {_id, s} -> s.named == named end) do
        {id, _s} -> Map.put(wire, "session", id)
        nil -> wire
      end
    end)
  end

  # The close carried out; answers whether its answer is to be lost.
  defp closed(agent, named) do
    Agent.get_and_update(agent, fn st ->
      sessions =
        Map.new(st.sessions, fn {id, s} ->
          if s.named == named, do: {id, %{s | running: false}}, else: {id, s}
        end)

      spent = MapSet.put(st.spent, named)
      closed = MapSet.put(st.closed, named)
      {st.lose_close, %{st | sessions: sessions, spent: spent, closed: closed, lose_close: false}}
    end)
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
    bound = now() + LocusBackends.close_wait_ms()
    opening(conn, agent, lifetime(fields, message), message, bound)
  end

  defp handle_session(conn, agent, fields, %{session: id} = message) do
    st = Agent.get(agent, & &1)

    case st.sessions[id] do
      nil ->
        refuse(conn, st, :unknown_session)

      s ->
        if message.type in LocusBackends.mode_types(s.mode),
          do: handle_mode(conn, agent, fields, message),
          else: refuse(conn, st, :bad_request)
    end
  end

  # An open asked as Locus asks one, again while it is held behind its key.
  defp opening(conn, agent, named, message, bound) do
    case Agent.get_and_update(agent, &admitted(&1, named, message)) do
      {:ok, answer} ->
        # The session stands; its answer may be held (`hold(fake, "opened")`).
        held(agent, "opened")
        session_answer(conn, Agent.get(agent, & &1), answer)

      :behind ->
        if now() >= bound do
          refuse(conn, Agent.get(agent, & &1), :unavailable)
        else
          # sleep-ok: the fake service's held open: it asks every 10 ms, until the wire's bound,
          # whether its key's last process has ended
          Process.sleep(10)
          opening(conn, agent, named, message, bound)
        end

      {:error, code} ->
        refuse(conn, Agent.get(agent, & &1), code)
    end
  end

  defp admitted(st, named, message) do
    running = for {id, %{running: true} = s} <- st.sessions, do: {id, s}
    own = Enum.find(running, fn {_id, s} -> s.named == named end)

    cond do
      own ->
        {id, _s} = own
        {{:ok, opened(id, true)}, touch(st, id)}

      Map.get(st.owners, named.owner) != named.version ->
        {{:error, :lapsed}, st}

      MapSet.member?(st.spent, named) or
          not LocusBackends.lifetime_of?(named.lifetime, st.boot) ->
        {{:error, :lifetime_over}, st}

      Enum.any?(running, fn {_id, %{named: other}} ->
        other.owner == named.owner and other.key == named.key
      end) ->
        {:behind, st}

      true ->
        start_session(st, named, message)
    end
  end

  defp opened(id, resumed?),
    do: %{"status" => "running", "session" => id, "resumed" => resumed?}

  defp start_session(st, named, message) do
    id = "ss_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    s = %{
      owner: named.owner,
      version: named.version,
      named: named,
      program: message.program,
      key: message.key,
      home_id: message.home_id,
      mode: message.mode,
      size: message.rows && {message.rows, message.cols},
      lines: [],
      seq: 0,
      running: true,
      exit_code: nil,
      active: System.monotonic_time(:millisecond)
    }

    st = %{st | sessions: Map.put(st.sessions, id, s), spent: MapSet.put(st.spent, named)}

    st =
      if message.home_id,
        do: %{st | homes: MapSet.put(st.homes, message.home_id)},
        else: st

    if message.mode == :terminal and is_pid(Map.get(st, :terminal)),
      do: send(st.terminal, {:terminal_opened, %{agent: self()}, id})

    {{:ok, opened(id, false)}, st}
  end

  defp handle_mode(conn, agent, fields, %{type: :send, session: id, lines: lines}) do
    status =
      Agent.get_and_update(agent, fn st ->
        case st.sessions[id] do
          %{running: false} ->
            {:ended, st}

          s ->
            for line <- lines,
                {:ok, %{"method" => method, "id" => _}} <- [Jason.decode(line)],
                do: send(st.test, {:invoke, method, fields})

            s = Enum.reduce(lines, s, &program_line(st, elem(s.owner, 1), &2, &1))
            {:running, %{st | sessions: Map.put(st.sessions, id, %{s | active: now()})}}
        end
      end)

    session_answer(conn, Agent.get(agent, & &1), %{"status" => Atom.to_string(status)})
  end

  defp handle_mode(conn, agent, _fields, %{type: type, session: id} = message)
       when type in [:input, :resize] do
    status =
      Agent.get_and_update(agent, fn st ->
        case st.sessions[id] do
          %{running: false} ->
            {:ended, st}

          s ->
            s = if type == :resize, do: %{s | size: {message.rows, message.cols}}, else: s

            if type == :input and is_pid(Map.get(st, :terminal)),
              do: send(st.terminal, {:terminal_input, %{agent: agent}, id, message.bytes})

            {:running, %{st | sessions: Map.put(st.sessions, id, %{s | active: now()})}}
        end
      end)

    session_answer(conn, Agent.get(agent, & &1), %{"status" => Atom.to_string(status)})
  end

  # A recv counts as the session's use when it arrives, as Locus counts it,
  # not while it waits: a session no line reaches is ended by its idle
  # period even with a recv waiting on it.
  defp handle_mode(conn, agent, _fields, %{type: type} = message)
       when type in [:recv, :output] do
    Agent.update(agent, &touch(&1, message.session))
    deadline = now() + message.max_wait_ms
    recv(conn, agent, message.session, message.after, deadline)
  end

  defp recv(conn, agent, id, after_seq, deadline) do
    st = Agent.get(agent, & &1)

    case st.sessions[id] do
      nil ->
        refuse(conn, st, :unknown_session)

      s ->
        lines =
          for {seq, text} <- Enum.reverse(s.lines), seq > after_seq do
            case {s.mode, text} do
              {:terminal, {:raw, bytes}} -> %{"seq" => seq, "bytes" => Base.encode64(bytes)}
              {:terminal, text} -> %{"seq" => seq, "bytes" => Base.encode64(text <> "\r\n")}
              {_run, text} -> %{"seq" => seq, "text" => text}
            end
          end

        if lines != [] or not s.running or now() >= deadline do
          member = if s.mode == :terminal, do: "chunks", else: "lines"
          dropped = if lines != [], do: take_dropped(agent), else: 0
          answer = %{member => lines, "dropped" => dropped, "running" => s.running}

          answer =
            if s.exit_code != nil and not s.running,
              do: Map.put(answer, "exit_code", s.exit_code),
              else: answer

          session_answer(conn, st, answer)
        else
          # sleep-ok: the fake service's long-poll recv: it looks every 10 ms for lines until its
          # deadline
          Process.sleep(10)
          expire_idle(agent)
          recv(conn, agent, id, after_seq, deadline)
        end
    end
  end

  # Lines the next answer that carries lines says were lost before it
  # (`set(fake, :dropped, n)`), once.
  defp take_dropped(agent),
    do: Agent.get_and_update(agent, &{Map.get(&1, :dropped, 0), Map.put(&1, :dropped, 0)})

  defp touch(st, id) do
    case st.sessions[id] do
      nil -> st
      s -> %{st | sessions: Map.put(st.sessions, id, %{s | active: now()})}
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  # The scripted program, answering as an MCP server over stdio does: a
  # JSON-RPC request is answered with a line, a notification with nothing.
  # `tools/list` pages its listing (`:page_size` tools a page, one unless
  # set) under an opaque `nextCursor`; a cursor it never issued, a call of
  # a tool it does not list and a method it does not serve are answered
  # with JSON-RPC errors (-32602, -32602, -32601), never an empty result.
  defp program_line(st, server, s, line) do
    case Jason.decode(line) do
      {:ok, %{"method" => method, "id" => id} = request} when id != nil ->
        if method in st.silent do
          s
        else
          answer =
            case reply(st, server, s, method, Map.get(request, "params") || %{}) do
              {:ok, result} -> %{"jsonrpc" => "2.0", "id" => id, "result" => result}
              {:error, error} -> %{"jsonrpc" => "2.0", "id" => id, "error" => error}
            end

          emit(s, Jason.encode!(answer))
        end

      _ ->
        s
    end
  end

  defp emit(s, text), do: %{s | seq: s.seq + 1, lines: [{s.seq + 1, text} | s.lines]}

  # A program set to refuse its `initialize` (`set(fake,
  # :refuse_initialize, %{row_id => words})`) answers it with a JSON-RPC
  # error of those words.
  defp reply(st, server, _s, "initialize", _params) do
    case Map.get(st, :refuse_initialize, %{}) do
      %{^server => words} ->
        {:error, %{"code" => -32_000, "message" => words}}

      _initialized ->
        {:ok,
         %{
           "protocolVersion" => Prima.MCP.Protocol.legacy_version(),
           "capabilities" => Map.new(offers(st, server), &{&1, %{}}),
           "serverInfo" => %{"name" => "scripted", "version" => "1"}
         }}
    end
  end

  defp reply(st, server, s, "resources/" <> _ = method, params),
    do: offered(st, server, s, "resources", method, params)

  defp reply(st, server, s, "prompts/" <> _ = method, params),
    do: offered(st, server, s, "prompts", method, params)

  defp reply(st, server, _s, "tools/list", params) do
    names = listed(st, server)
    size = Map.get(st, :page_size, 1)

    case page_start(params["cursor"], length(names)) do
      {:ok, start} ->
        tools =
          for name <- Enum.slice(names, start, size),
              do: %{"name" => name, "inputSchema" => %{"type" => "object"}}

        if start + size < length(names),
          do: {:ok, %{"tools" => tools, "nextCursor" => cursor(start + size)}},
          else: {:ok, %{"tools" => tools}}

      :error ->
        {:error, %{"code" => -32_602, "message" => "Invalid cursor"}}
    end
  end

  defp reply(st, server, _s, "tools/call", %{"name" => name}) do
    if name in listed(st, server),
      do: {:ok, %{"content" => [%{"type" => "text", "text" => "found"}]}},
      else: {:error, %{"code" => -32_602, "message" => "Unknown tool: #{name}"}}
  end

  defp reply(_st, _server, _s, "ping", _params), do: {:ok, %{}}

  defp reply(_st, _server, _s, method, _params),
    do: {:error, %{"code" => -32_601, "message" => "Method not found: #{method}"}}

  # The program's tool names: the test's for its server (`search` unless
  # set).
  defp listed(st, server), do: Map.get(st.tools, server, ["search"])

  # What the program declares: the test's for its server (its tools unless
  # set).
  defp offers(st, server), do: Map.get(st.offers, server, ["tools"])

  # A resources or prompts method, answered only by a program that
  # declares that offering.
  defp offered(st, server, _s, offering, method, params) do
    if offering in offers(st, server),
      do: offering_reply(method, params),
      else: {:error, %{"code" => -32_601, "message" => "Method not found: #{method}"}}
  end

  defp offering_reply("resources/list", _params),
    do: {:ok, %{"resources" => [%{"uri" => "file:///readme", "name" => "readme"}]}}

  defp offering_reply("resources/templates/list", _params),
    do: {:ok, %{"resourceTemplates" => [%{"uriTemplate" => "file:///{path}", "name" => "file"}]}}

  defp offering_reply("resources/read", %{"uri" => uri}),
    do:
      {:ok,
       %{"contents" => [%{"uri" => uri, "mimeType" => "text/plain", "text" => "read " <> uri}]}}

  defp offering_reply("prompts/list", _params),
    do: {:ok, %{"prompts" => [%{"name" => "greet", "arguments" => [%{"name" => "who"}]}]}}

  defp offering_reply("prompts/get", %{"name" => name} = params),
    do:
      {:ok,
       %{
         "messages" => [
           %{
             "role" => "user",
             "content" => %{"type" => "text", "text" => "#{name} #{params["arguments"]["who"]}"}
           }
         ]
       }}

  defp offering_reply(method, _params),
    do: {:error, %{"code" => -32_601, "message" => "Method not found: #{method}"}}

  defp cursor(start), do: Base.url_encode64("page:#{start}", padding: false)

  defp page_start(nil, _count), do: {:ok, 0}

  defp page_start(cursor, count) when is_binary(cursor) do
    with {:ok, "page:" <> digits} <- Base.url_decode64(cursor, padding: false),
         {start, ""} when start > 0 and start < count <- Integer.parse(digits) do
      {:ok, start}
    else
      _ -> :error
    end
  end

  defp page_start(_cursor, _count), do: :error

  defp pop_refusal(agent, what) do
    Agent.get_and_update(agent, fn st ->
      {Map.get(st.refuse, what), %{st | refuse: Map.delete(st.refuse, what)}}
    end)
  end

  defp refuse(conn, st, code),
    do: answer(conn, st, LocusBackends.status(code), LocusBackends.encode_refusal(code))

  # The box's memory as a hello and a status report it: the shipped budget,
  # nothing held.
  defp memory,
    do: %{
      "budget_bytes" => 1_879_048_192,
      "admission_limit_bytes" => 1_879_048_192,
      "held_bytes" => 0
    }

  defp control_answer(conn, st, body),
    do: answer(conn, st, 200, Map.put(body, "version", st.answer_version))

  defp session_answer(conn, st, body),
    do: answer(conn, st, 200, Map.put(body, "version", st.answer_version))

  defp answer(conn, st, status, body) when is_map(body),
    do: answer(conn, st, status, Jason.encode!(body))

  defp answer(conn, st, status, body) when is_binary(body) do
    conn
    |> put_resp_header(LocusBackends.boot_header(), conn.assigns[:boot] || st.boot)
    |> put_resp_content_type("application/json")
    |> resp(status, body)
  end
end
