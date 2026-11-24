# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CYFR Works Inc.

defmodule Emissary.External.Server do
  @moduledoc """
  GenServer managing a connection to a single external MCP server.

  One process per active connection, keyed by `{name, athanor_id}`.
  Connects lazily on first access. Discovered tool definitions are cached.

  ## HTTP transport

  Uses Streamable HTTP (JSON-RPC 2.0 over HTTP POST) as defined by the
  MCP spec. Each request gets a fresh HTTP request — no persistent
  connection. Connecting is a stateless `server/discover` probe under the
  current protocol revision, which states what the server offers, falling
  back to the legacy initialize → initialized handshake for third-party
  servers still on the older revision (see `connect/1`), whose `initialize`
  answer states it. A server is asked `tools/list` only when it declares
  tools, so one that offers only resources or prompts connects. Every
  request's timeout bounds its wall time, however the peer trickles its
  reply. A legacy peer that issues an `Mcp-Session-Id` at
  `initialize` gets it back on every later request until the next connect,
  and the id is kept and masked as the resolved credential headers are. A
  configured `mcp-session-id` header wins over an issued id, which is then
  not kept, and is masked as a credential header. An issued id that is not
  visible ASCII, or shorter than the 8 bytes masking needs, is not kept: the
  connect fails saying so.
  A paged `tools/list` is followed through its `nextCursor` to the last
  page, and a listing longer than 20 pages, or not finished within the
  handshake limit of its first request, fails the connect. A reply whose
  content type is `text/event-stream` is read as an event stream, its last
  event the answer; any other is read as JSON.

  A server's resources and prompts, when it declares them, are read as a
  tool is called (`offering/2`), in a detached task: `resources/list` with
  `resources/templates/list` and `prompts/list`, each paged and bounded as
  `tools/list` is, `resources/read` and `prompts/get`. An offering the
  server did not declare is never asked of it.

  A connect checks every `vault:` header template against this server's
  URL from the entries' metadata (`Sanctum.Vault.destination_matches?/3`)
  before it unseals any (`Sanctum.VaultReader.unseal_for/3`): an entry
  whose destination does not admit a `POST` there fails the connect
  `destination_mismatch` with nothing unsealed or sent. A failed connect
  answers its caller with the sentence it keeps as its status error, the
  injected credentials masked out of it.

  ## A program

  A program is one command the backends service runs, and this process is
  its MCP client. Connecting asks the programs controller for the row's
  owner (`Opus.Programs.hold/1`), which answers a grant, then opens the
  program's session through the controller, the only way to open one
  (`Opus.Programs.box_open/4`), under the key `"mcp"`, in the row's own
  home when it keeps one, as one lifetime per process of the command
  (`Opus.Programs.lifetime/2`): this process keeps it until that process
  ends and asks again for it, which the service answers while it runs,
  and opens another once the service says it is over, or runs another
  boot than the lifetime's, under a grant of that boot. A server process
  started again holds no lifetime, so it starts its program afresh. A
  program started
  afresh (`resumed: false`) is initialized at the legacy protocol revision
  (`Prima.MCP.Protocol.legacy_version/0`) and told
  `notifications/initialized`, its answer stating what it offers; then,
  when it declares tools, it is asked `tools/list`, every page
  of it as an HTTP listing is, and its tools are this server's by the names
  it lists, which the proxy offers as `<row name>:<tool>`. Every request is
  one JSON-RPC line `send` writes; a reader process waits on `recv` and
  hands this process the lines, each answer going to the call that awaits
  its id. The program's own request is answered `-32601`; its
  `notifications/tools/list_changed` lists its tools again.

  A session whose process ended — idle past the owner's idle period, a
  crash, a restart of the service — reads `running: false`: every call
  awaiting it fails, and the next call opens the session again,
  initializing the program afresh. The tools listed stay listed meanwhile.

  One member of the cell runs an owner; a member that does not hold its
  claim refuses the connection (`:claimed_elsewhere`). A call the service
  refuses before running it with `stale_boot`, `epoch_ahead`,
  `unknown_owner` or `lapsed` holds the owner again and is sent once more;
  `stale_epoch` re-reads the row, and a row whose epoch moved leaves this
  process in error until it is replaced. The controller's
  `{Opus.Programs, :owner, grant}` replaces the grant and drops the
  session, which the next call opens again; its
  `{Opus.Programs, :stand_down, _}` stops this process. Stopping the
  process releases its hold within 3 s.

  ## Vault revisions

  Before a connect resolves anything, the process reads the revision token
  of every vault entry its header and env templates name
  (`Sanctum.VaultReader.revisions/2`: the payload revision and the binding
  digest) and keeps them for as long as it serves with what it resolved
  (`vault_revisions/1`). The reconciler's periodic pass compares them with
  the store, so a rotation, rebind or revocation whose announcement never
  arrived still ends this process. Read before resolving, a change in
  between leaves a token older than the material, which the pass reads as
  moved: a spurious restart, never a missed one.
  """

  # Temporary: a server is started on demand (`ServerSupervisor.ensure_started/1`),
  # so one that stops is started again by its next use, with the stored
  # configuration. Restarted by its supervisor instead, a server that keeps
  # failing (a bad upstream, a crash) would spend the supervisor's restart
  # intensity, and the supervisor reaching it shuts down every server of
  # every athanor at once.
  use GenServer, restart: :temporary
  require Logger

  alias Prima.MCP.{Message, Protocol}
  alias Sanctum.Refusals

  @initialize_timeout_ms 15_000
  # How long a caller waits for a connect, which for a program includes
  # the service starting its program.
  @connect_call_timeout_ms 60_000
  @retried_refusals [:stale_boot, :epoch_ahead, :unknown_owner, :lapsed]
  # A reader's wait on one recv; the service answers sooner on a line.
  @recv_wait_ms 25_000
  # The key every program session of a row opens under.
  @session_key "mcp"
  # Client-side deadline for a call_tool round-trip. The upstream timeout is
  # operator-settable per server (config timeout_ms), so the caller's wait
  # must cover the largest upstream budget we allow — otherwise a slow-but-
  # legitimate call outlives its caller and replies to nobody. init/1 clamps
  # the configured timeout below this with slack for dispatch overhead.
  @call_timeout_ms 120_000
  @max_upstream_timeout_ms @call_timeout_ms - 10_000
  # Upstream calls run in detached tasks so one slow server never blocks the
  # GenServer; the cap keeps a stalled upstream from accumulating an unbounded
  # task pile (each carrying resolved credentials in its heap).
  @max_in_flight 8
  @registry Emissary.External.ServerRegistry

  # Matched in a pattern, so it has to be a compile-time literal — but it is
  # initialized from the one place the vocabulary is defined rather than written
  # out again here.
  @input_required Protocol.result_type(:input_required)

  @reinit_cooldown_ms 5_000
  # The most pages of a paged `tools/list` read before a connect fails
  # rather than keep a listing it knows is cut short: a consent baseline
  # missing tools would admit them unseen. The whole listing also runs
  # under one deadline, the handshake limit, so a slow pager cannot hold a
  # connect page after page.
  @max_listing_pages 20
  # The header a Streamable HTTP peer names its session in.
  @session_id_header "mcp-session-id"
  # The shortest credential value masked out of what a peer answers: a
  # shorter one would mangle unrelated text ("gzip").
  @min_masked_bytes 8
  # 10 MB
  @max_response_body_bytes 10_485_760

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(config) do
    name = config[:name]
    athanor_id = athanor_id!(config)

    # The Registry value is the digest of the config this process serves;
    # ServerSupervisor.ensure_started/1 compares it against the
    # stored row's digest to reconcile config changes by restart.
    GenServer.start_link(__MODULE__, config,
      name:
        {:via, Registry,
         {@registry, {name, athanor_id}, Emissary.External.ServerSupervisor.config_digest(config)}}
    )
  end

  @doc false
  # The athanor a server config belongs to. Required: a server row without
  # one has no vault to resolve headers from and no tenant to be listed in.
  def athanor_id!(config) do
    case config[:athanor_id] do
      id when is_binary(id) and id != "" ->
        id

      other ->
        raise ArgumentError,
              "Emissary.External.Server: config requires :athanor_id, got #{Prima.LoggerContext.shape(other)}"
    end
  end

  @doc """
  The revision token (`Sanctum.VaultReader.revisions/2`) of each vault
  entry the server process `pid` resolved its credentials against, or
  `:none` while it is not connected and serves with nothing resolved. A
  process that does not answer within 5 s answers `:none` too; the next
  pass asks again.
  """
  @spec vault_revisions(pid()) ::
          {:ok, %{String.t() => Sanctum.VaultReader.revision() | :inactive}} | :none
  def vault_revisions(pid) when is_pid(pid) do
    GenServer.call(pid, :vault_revisions, 5_000)
  catch
    :exit, _reason -> :none
  end

  @doc """
  Get cached tool definitions from the external server.
  Triggers initialization if not yet connected. A connect that fails
  answers `{:error, sentence}`: the sentence the process keeps as its
  status error, with the credentials it injected masked out.
  """
  @spec get_tools(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_tools(name, athanor_id) do
    case lookup(name, athanor_id) do
      {:ok, pid} -> call_server(pid, :get_tools, @connect_call_timeout_ms)
      {:error, _} = err -> err
    end
  end

  @doc """
  What the server offers, connecting it as `get_tools/2` does: its tools,
  and which of its resources and prompts it declares.
  """
  @spec offerings(String.t(), String.t()) ::
          {:ok, %{tools: [map()], declared: [:prompts | :resources]}} | {:error, term()}
  def offerings(name, athanor_id) do
    case lookup(name, athanor_id) do
      {:ok, pid} -> call_server(pid, :offerings, @connect_call_timeout_ms)
      {:error, _} = err -> err
    end
  end

  @doc "Call a tool on the server process a caller already holds."
  @spec call_tool(pid(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def call_tool(pid, tool_name, arguments) when is_pid(pid),
    do: call_server(pid, {:call, {:tool, tool_name, arguments}}, @call_timeout_ms)

  @typedoc "A read of a server's resources or prompts (`offering/2`)."
  @type offering ::
          {:resources, :list}
          | {:resources, :read, String.t()}
          | {:prompts, :list}
          | {:prompts, :get, String.t(), map()}

  @doc """
  Read the resources or prompts of the server process a caller already
  holds, as `call_tool/3` calls a tool: its resources and their templates
  (`resources/list` and `resources/templates/list`, each to its last page),
  one resource by its uri (`resources/read`), its prompts (`prompts/list`,
  to its last page) or one prompt with its arguments (`prompts/get`). The
  answer is the server's, its credentials masked out. A server that did not
  declare that offering is never asked it, and the read is refused saying
  so.
  """
  @spec offering(pid(), offering()) :: {:ok, map()} | {:error, term()}
  def offering(pid, asked) when is_pid(pid),
    do: call_server(pid, {:call, asked}, @call_timeout_ms)

  @doc """
  Get the connection status of the external server.
  """
  def status(name, athanor_id) do
    case lookup(name, athanor_id) do
      {:ok, pid} -> GenServer.call(pid, :status)
      {:error, :not_running} -> :disconnected
    end
  catch
    # A process busy connecting answers nothing until it is done.
    :exit, _ -> %{status: :connecting, tool_count: 0, server_info: nil}
  end

  @doc """
  Reinitialize the connection (e.g., after config change). A connect that
  fails answers as `get_tools/2` does: the masked sentence.
  """
  @spec reinitialize(String.t(), String.t()) :: {:ok, atom()} | {:error, term()}
  def reinitialize(name, athanor_id) do
    case lookup(name, athanor_id) do
      {:ok, pid} -> call_server(pid, :reinitialize, @connect_call_timeout_ms)
      {:error, _} = err -> err
    end
  end

  # Every call into a server process is answered, never carried out as an
  # exit of the caller. A server is stopped from outside it — a vault
  # revocation and an archived athanor stop it through
  # `Emissary.External.Reconciler`, a changed row through
  # `Emissary.External.ServerSupervisor.ensure_started/1`, and in a cell
  # a program whose claim moved through `Opus.Programs` — so a call
  # in flight when one of those lands sees its process go. The contract of
  # `get_tools/2`, `call_tool/3` and `reinitialize/2`, and of
  # `Emissary.External.Servers.ensure_started/2` above them, is a typed
  # error; an exit here would instead take down whoever asked, which for
  # `ensure_started/2` is a tool listing, a console read or a dispatch.
  defp call_server(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, reason -> {:error, {:server_exited, reason}}
  end

  defp lookup(name, athanor_id) do
    case Registry.lookup(@registry, {name, athanor_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_running}
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  defmodule State do
    @moduledoc false
    # `headers` holds RESOLVED credential values (vault references already
    # unsealed to plaintext) and the session id a legacy peer issued,
    # `raw_headers` may carry inline ones and
    # `grant` holds a program owner's key. OTP prints `inspect(state)` in
    # every GenServer crash/exit report, so all three are excluded from
    # Inspect — a crashed call must not write credentials into the log.
    @derive {Inspect, except: [:headers, :raw_headers, :grant]}
    defstruct [
      :name,
      :url,
      :timeout_ms,
      :athanor_id,
      :server_id,
      :epoch,
      # The grant `Opus.Programs.hold/1` answered (a program only).
      :grant,
      # This process, which a call's task hands its reply back through.
      :server,
      # A kept program's home: its row's id; nil for a scratch home.
      :home_id,
      :server_info,
      :error,
      # What a call is answered with while the server is in error: the
      # last failure, the server's own words tagged as its own
      # (`server_error/1`), masked as `error` is.
      :failure,
      :last_init_attempt,
      # Which era this peer speaks. Determined once per connection and
      # cached: it is a property of the server, not of a request, and
      # re-probing on every call would double the traffic to a legacy peer
      # forever.
      :era,
      transport: :http,
      raw_headers: %{},
      headers: %{},
      # Every vault entry the header and env templates name, and
      # the revision token of each as read before the last connect
      # resolved them; nil until then.
      vault_names: [],
      vault_revisions: nil,
      status: :disconnected,
      tools: [],
      # What the server declared it offers, sorted, among `:prompts`,
      # `:resources` and `:tools`: what it is asked for, and nothing else.
      # Each connect reads it again, but a program whose session resumes
      # is not initialized again, so it keeps what that program declared.
      offers: [],
      request_id: 0,
      # Detached upstream calls currently running:
      # %{task_pid => {monitor_ref, from, caller_ref}}.
      in_flight: %{},
      # What each running call asked, so a refused one can be sent again:
      # %{task_pid => {tool_name, arguments, attempt}}.
      calls: %{},
      # The lifetime of the program's process, kept until that ends.
      lifetime: nil,
      # A program's session and its reader:
      # %{session: id, reader: pid | nil, after: seq}, nil while none is open.
      session: nil,
      # The JSON-RPC ids a call's task awaits: %{id => task_pid}.
      pending: %{}
    ]
  end

  # Exits are trapped so a stop — a vault change, a deleted row, an archived
  # athanor — runs `terminate/2`, which ends every upstream call still in
  # flight with the credentials this process resolved, and releases a
  # program's owner on the service.
  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    state = %State{
      name: config[:name],
      url: config[:url],
      server: self(),
      home_id: config[:home_id],
      transport: config[:transport] || :http,
      server_id: config[:id],
      epoch: config[:epoch],
      raw_headers: config[:headers] || %{},
      vault_names: vault_names(config),
      timeout_ms:
        min(
          config[:timeout_ms] || Emissary.External.Servers.default_timeout_ms(),
          @max_upstream_timeout_ms
        ),
      athanor_id: athanor_id!(config)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(asked, _from, state) when asked in [:get_tools, :offerings] do
    case connected(state) do
      {:ok, state} -> {:reply, {:ok, offered(asked, state)}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:call, asked}, from, state) do
    dispatch_call(state, from, {asked, 0})
  end

  @impl true
  def handle_call(
        :vault_revisions,
        _from,
        %{status: :ready, vault_revisions: %{} = revs} = state
      ),
      do: {:reply, {:ok, revs}, state}

  def handle_call(:vault_revisions, _from, state), do: {:reply, :none, state}

  @impl true
  def handle_call(:status, _from, state) do
    info = %{
      name: state.name,
      url: state.url,
      status: state.status,
      tool_count: length(state.tools),
      server_info: state.server_info,
      error: state.error
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call(:reinitialize, _from, state) do
    state = %{
      drop_session(state, :reinitialized)
      | status: :disconnected,
        tools: [],
        server_info: nil,
        error: nil,
        headers: %{},
        grant: nil
    }

    case do_initialize(state) do
      {:ok, state} -> {:reply, {:ok, state.status}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  # The server connected, connecting it when it is not, or why not: once
  # disconnected, and again in error once the backoff allows.
  defp connected(%{status: :ready} = state), do: {:ok, state}
  defp connected(%{status: :disconnected} = state), do: do_initialize(state)

  defp connected(%{status: :error} = state) do
    if can_reinit?(state), do: do_initialize(state), else: {:error, state.error, state}
  end

  defp offered(:get_tools, state), do: state.tools
  defp offered(:offerings, state), do: %{tools: state.tools, declared: state.offers -- [:tools]}

  # Runs a call in a detached task, or answers why it cannot run: a tool's
  # (`{:tool, name, arguments}`) or a read of the server's resources or
  # prompts (`t:offering/0`), each only of a server that declared it.
  # `attempt` counts the times the service refused this call before
  # running it. What is checked is what the process the call is sent to
  # declared: a program's session the call itself opens may be a new
  # process of the program, initialized afresh, so the offering is checked
  # again once it is open, before anything is written to it.
  defp dispatch_call(state, from, {asked, _attempt} = call) do
    state = ensure_ready(state)
    offering = offering_of(asked)

    cond do
      state.status != :ready ->
        {:reply, {:error, not_ready(state)}, state}

      offering not in state.offers ->
        {:reply, undeclared(state, offering), state}

      map_size(state.in_flight) >= @max_in_flight ->
        {:reply,
         {:error,
          "Server #{state.name} is busy (#{@max_in_flight} calls in flight) — retry shortly"},
         state}

      state.transport == :program ->
        case ensure_session(state) do
          {:ok, state} ->
            start_program_call(state, from, call, offering)

          {:error, reason, state} ->
            {:reply, {:error, failure(reason, state)}, state}
        end

      true ->
        start_call(state, from, call)
    end
  end

  # Why a call is not run while the server is in error, in the server's
  # own words where its last failure was its (`server_error/1`).
  defp not_ready(%{failure: {:outside_error, words}} = state),
    do: {:outside_error, "Server #{state.name} is not ready: #{words}"}

  defp not_ready(state), do: "Server #{state.name} is not ready: #{state.error}"

  # A program's call starts on the session it opened only when the process
  # behind that session declared the call's offering.
  defp start_program_call(state, from, call, offering) do
    if offering in state.offers do
      case start_call(state, from, call) do
        {:noreply, state} -> {:noreply, start_reader(state)}
        reply -> reply
      end
    else
      {:reply, undeclared(state, offering), state}
    end
  end

  defp undeclared(state, offering),
    do: {:error, {:invalid_argument, "#{state.name} declares no #{offering}"}}

  defp offering_of({:tool, _name, _arguments}), do: :tools
  defp offering_of(asked), do: elem(asked, 0)

  # The most requests one call makes, each of its own id: a listing reads
  # up to its page bound, and a read of resources two listings.
  defp requests({:resources, :list}), do: 2 * @max_listing_pages
  defp requests({:prompts, :list}), do: @max_listing_pages
  defp requests(_one), do: 1

  # Runs one call's upstream round trip in a detached task. The ids its
  # requests carry are taken here, from this process's count, so no two
  # requests of the connection share one; a program call's task awaits
  # each answer by its id, which this process hands it from the program's
  # session.
  defp start_call(state, from, {asked, _attempt} = call) do
    first = state.request_id + 1
    ids = first..(state.request_id + requests(asked))
    state = %{state | request_id: ids.last}
    # The upstream HTTP round-trip runs OUTSIDE this process so one slow
    # server never head-of-line-blocks every other caller of the same
    # server for up to their full call timeout. The task gets a snapshot
    # of state (resolved headers, masking material, a program grant) and
    # replies directly; config (re)resolution stays serialized in the
    # GenServer above. The tool catalogue is dropped from the snapshot —
    # the call doesn't read it, and it would otherwise be copied into
    # every task heap.
    snapshot = %{
      state
      | tools: [],
        in_flight: %{},
        calls: %{},
        pending: %{},
        request_id: first - 1
    }

    server = self()

    logger_metadata = Prima.LoggerContext.capture()

    case Task.Supervisor.start_child(Emissary.TaskSupervisor, fn ->
           Prima.LoggerContext.restore(logger_metadata)

           reply =
             try do
               upstream_call(snapshot, asked)
             rescue
               e ->
                 # The exception can carry the upstream URL, a transport
                 # internal or what the upstream answered; the caller (a
                 # guest or the console) gets the call's subject only, the
                 # log the rest, the injected values masked.
                 Logger.warning(
                   "[Emissary.External.Server] call to #{subject(asked)} raised: " <>
                     log_reason(e, snapshot)
                 )

                 {:error, "External call failed for #{subject(asked)}"}
             end

           case reply do
             # Refused before it ran: the server decides what happens next.
             {:backends_refused, code, boot} ->
               send(server, {:backends_refused, self(), code, boot})

             reply ->
               GenServer.reply(from, reply)
           end
         end) do
      {:ok, task_pid} ->
        ref = Process.monitor(task_pid)
        # `from` rides along so an abnormal exit can still answer — see
        # the :DOWN clause; the caller is watched too, so a caller that
        # goes away mid-call takes its upstream round-trip with it.
        {caller, _tag} = from
        caller_ref = Process.monitor(caller)

        pending =
          if state.transport == :program,
            do: Map.merge(state.pending, Map.new(ids, &{&1, task_pid})),
            else: state.pending

        {:noreply,
         %{
           state
           | in_flight: Map.put(state.in_flight, task_pid, {ref, from, caller_ref}),
             calls: Map.put(state.calls, task_pid, call),
             pending: pending
         }}

      {:error, reason} ->
        {:reply, {:error, "External call failed to start: #{Refusals.render(reason)}"}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.get(state.in_flight, pid) do
      {_ref, from, caller_ref} ->
        # The task replies on its own way out, and its `rescue` covers a
        # raise — but not an exit: a supervisor shutdown or a kill leaves
        # `from` unanswered, and the caller then blocks for the whole
        # two-minute call timeout on a task that is already gone. Answer
        # for it.
        Process.demonitor(caller_ref, [:flush])

        if reason != :normal,
          do: GenServer.reply(from, {:error, {:uncertain, "External call did not complete"}})

        {:noreply, forget_call(state, pid)}

      nil ->
        # A caller gone mid-call: its upstream round-trip is nobody's now.
        case Enum.find(state.in_flight, fn {_task, {_r, _f, caller_ref}} -> caller_ref == ref end) do
          {task_pid, {task_ref, _from, _caller_ref}} ->
            Process.demonitor(task_ref, [:flush])
            Process.exit(task_pid, :kill)
            {:noreply, forget_call(state, task_pid)}

          nil ->
            {:noreply, state}
        end
    end
  end

  # The service refused a call before running it.
  def handle_info({:backends_refused, task_pid, code, boot}, state) do
    case Map.get(state.in_flight, task_pid) do
      {task_ref, from, caller_ref} ->
        Process.demonitor(task_ref, [:flush])
        Process.demonitor(caller_ref, [:flush])
        call = Map.fetch!(state.calls, task_pid)

        if code == :stale_boot and is_binary(boot), do: Opus.Programs.boot_seen(boot)

        after_refusal(forget_call(state, task_pid), from, call, code)

      nil ->
        {:noreply, state}
    end
  end

  # Lines the program's session wrote, from its reader, which waits to be
  # told whether to read on.
  def handle_info(
        {:session_lines, session, lines, last, running, reader},
        %State{session: %{session: session}} = state
      ) do
    {state, _awaited} = on_lines(state, lines, nil)
    {:noreply, after_read(state, last, running, reader, false)}
  end

  def handle_info({:session_lines, _session, _lines, _last, _running, reader}, state) do
    send(reader, :stop)
    {:noreply, state}
  end

  def handle_info(:relist, state), do: {:noreply, relist_tools(state)}

  def handle_info({:session_lost, session, reason}, %State{session: %{session: session}} = state),
    do: {:noreply, session_ended(state, reason)}

  def handle_info({:session_lost, _session, _reason}, state), do: {:noreply, state}

  # A reader ends after its session does, and says so first.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # The controller synced this server's owner again: the session ran on a
  # service, or under a version, the new grant does not name. It is opened
  # again by the next call.
  def handle_info({Opus.Programs, :owner, %{epoch: epoch} = grant}, %State{epoch: epoch} = state),
    do: {:noreply, %{drop_session(state, :owner_moved) | grant: grant}}

  def handle_info({Opus.Programs, :owner, _grant_for_another_epoch}, state),
    do: {:noreply, state}

  # The owner is not this process's to use any more: the claim moved, the
  # row changed or the service forgot it.
  def handle_info({Opus.Programs, :stand_down, _key}, state), do: {:stop, :normal, state}

  def handle_info(msg, state) do
    Prima.LoggerContext.unexpected(__MODULE__, msg)
    {:noreply, state}
  end

  defp forget_call(state, task_pid) do
    %{
      state
      | in_flight: Map.delete(state.in_flight, task_pid),
        calls: Map.delete(state.calls, task_pid),
        pending: Map.reject(state.pending, fn {_id, pid} -> pid == task_pid end)
    }
  end

  # A lifetime, generation or lease the grant no longer matches: sync again
  # and send the call once more.
  defp after_refusal(state, from, {asked, 0}, code) when code in @retried_refusals do
    state = %{
      drop_session(state, :refused)
      | status: :disconnected,
        grant: nil,
        last_init_attempt: nil
    }

    case dispatch_call(state, from, {asked, 1}) do
      {:reply, reply, state} ->
        GenServer.reply(from, reply)
        {:noreply, state}

      {:noreply, state} ->
        {:noreply, state}
    end
  end

  # The service runs a newer version of this owner. A row whose epoch moved
  # has been changed since this process started: it stays in error until
  # `Emissary.External.ServerSupervisor.ensure_started/1` replaces it.
  # The program's session ended before the call reached it (idle, a
  # crash): it is opened again, the program initialized afresh, and the
  # call sent once more.
  defp after_refusal(state, from, {asked, 0}, :session_ended) do
    state = drop_session(state, :ended)

    case dispatch_call(state, from, {asked, 1}) do
      {:reply, reply, state} ->
        GenServer.reply(from, reply)
        {:noreply, state}

      {:noreply, state} ->
        {:noreply, state}
    end
  end

  defp after_refusal(state, from, _call, :stale_epoch) do
    ctx = Sanctum.Context.internal(athanor_id: state.athanor_id, scope: :athanor)

    state =
      case Arca.McpServerStorage.get_by_id(Sanctum.Context.actor(ctx), state.server_id) do
        {:ok, %{epoch: epoch}} when epoch == state.epoch ->
          state

        _moved_or_gone ->
          %{
            state
            | status: :error,
              error: "the server's configuration changed",
              failure: nil,
              grant: nil
          }
      end

    GenServer.reply(
      from,
      {:error, "Server #{state.name} changed while the call was sent — retry"}
    )

    {:noreply, state}
  end

  defp after_refusal(state, from, _call, code) do
    GenServer.reply(
      from,
      {:error, "The backends service refused the call to #{state.name} (#{code})"}
    )

    {:noreply, state}
  end

  # A program that said its tools changed is listed again; a refused or
  # failed listing leaves the catalogue as it was.
  defp relist_tools(%State{transport: :program, status: :ready} = state) do
    case list_program_tools(state) do
      {:ok, tools, state} ->
        if tools != state.tools do
          Logger.info(
            "[Emissary.External.Server] #{state.name}: #{length(tools)} tools after a change"
          )

          tools_changed(state.athanor_id)
        end

        %{state | tools: tools}

      {:error, _reason, state} ->
        state
    end
  end

  defp relist_tools(state), do: state

  defp tools_changed(athanor_id) do
    Emissary.External.Proxy.invalidate_external_tools_cache(
      Sanctum.Context.internal(athanor_id: athanor_id, scope: :athanor)
    )

    actor = Prima.Actor.in_athanor(athanor_id)

    Cyfr.Bus.broadcast(
      actor,
      Cyfr.Bus.mcp_servers(actor),
      Cyfr.Bus.McpServers.new(actor, :changed)
    )
  end

  # Bring a not-yet-ready server up before dispatching, as a listing
  # does (`connected/1`).
  defp ensure_ready(state) do
    case connected(state) do
      {:ok, state} -> state
      {:error, _reason, state} -> state
    end
  end

  # Runs in a Task: performs the upstream round trips of one call against a
  # state SNAPSHOT, whose count starts at the ids taken for it, and never
  # mutates server state.
  defp upstream_call(state, {:tool, tool_name, arguments}) do
    {request_id, state} = next_request_id(state)

    body =
      Message.encode_request(request_id, "tools/call", %{
        "name" => tool_name,
        "arguments" => arguments || %{}
      })

    case answer(state, body) do
      {:ok, result} -> {:ok, mask_credentials(result, state)}
      {:error, reason} -> {:error, mask_credentials(reason, state)}
      {:backends_refused, _code, _boot} = refused -> refused
    end
  end

  defp upstream_call(state, asked) do
    case read_offering(state, asked) do
      {:ok, result} -> {:ok, mask_credentials(result, state)}
      {:backends_refused, _code, _boot} = refused -> refused
      {:error, reason} -> {:error, mask_credentials(reason, state)}
      {:error, reason, _state} -> {:error, mask_credentials(reason, state)}
    end
  end

  defp read_offering(state, {:resources, :list}) do
    listing = {state.name, "resources/templates/list", "resourceTemplates"}

    with {:ok, resources, state} <- read_listing(state, {"resources/list", "resources"}),
         {:ok, templates, _state} <- list_pages(state, listing, &templates_page/2),
         do: {:ok, %{"resources" => resources, "resourceTemplates" => templates}}
  end

  defp read_offering(state, {:prompts, :list}) do
    with {:ok, prompts, _state} <- read_listing(state, {"prompts/list", "prompts"}),
         do: {:ok, %{"prompts" => prompts}}
  end

  defp read_offering(state, {:resources, :read, uri}) do
    with {:ok, result, _state} <- read_request(state, "resources/read", %{"uri" => uri}),
         do: {:ok, result}
  end

  defp read_offering(state, {:prompts, :get, name, arguments}) do
    params = %{"name" => name, "arguments" => arguments}

    with {:ok, result, _state} <- read_request(state, "prompts/get", params),
         do: {:ok, result}
  end

  defp read_listing(state, {method, key}),
    do: list_pages(state, {state.name, method, key}, &read_request(&1, method, &2))

  # One request of a read, from its task: the server's answer, or why not.
  defp read_request(state, method, params) do
    {request_id, state} = next_request_id(state)
    body = Message.encode_request(request_id, method, params)

    case answered(state, body, upstream(state, body)) do
      {:ok, result} -> {:ok, result, state}
      refused -> refused
    end
  end

  # A page of a server's resource templates. A server that lists resources
  # and has no handler for their templates answers this one request as a
  # method it does not know (-32601): it has no templates, which takes
  # nothing from its resources.
  defp templates_page(state, params) do
    {request_id, state} = next_request_id(state)
    body = Message.encode_request(request_id, "resources/templates/list", params)

    case upstream(state, body) do
      {:ok, %Message{type: :error, error: %{"code" => -32_601}}} ->
        {:ok, %{"resourceTemplates" => []}, state}

      reply ->
        case answered(state, body, reply) do
          {:ok, result} -> {:ok, result, state}
          refused -> refused
        end
    end
  end

  # What a call is of, for a sentence: the tool, or the read's method.
  defp subject({:tool, tool_name, _arguments}), do: tool_name
  defp subject(asked), do: "#{elem(asked, 0)}/#{elem(asked, 1)}"

  # One request's round trip, from a call's task: the server's result, or
  # why not, as it answered.
  defp answer(state, body), do: answered(state, body, upstream(state, body))

  defp answered(state, body, reply) do
    case reply do
      # An upstream server asking for more input is refused, deliberately.
      #
      # `input_required` is how a server requests sampling, elicitation or
      # roots. Fulfilling one would mean an external server driving a model or
      # a user prompt from inside a running chain — under whatever authority
      # that chain holds. An upstream peer can already rewrite its tool
      # descriptions at will; letting it also originate requests would hand it
      # a channel into the caller rather than just influence over the text.
      #
      # Parsing it as a completed result would be worse than refusing: the
      # guest would receive an interim answer as though it were final.
      {:ok, %Message{type: :response, result: %{"resultType" => @input_required}}} ->
        Logger.warning(
          "[Emissary.External.Server] #{state.name} returned input_required for " <>
            "#{Protocol.named_subject(body) || body["method"]}; refused"
        )

        {:error, "#{state.name} asked for additional input, which external servers may not do."}

      {:ok, %Message{type: :response, result: result}} ->
        {:ok, result}

      {:ok, %Message{type: :error, error: error}} ->
        {:error, server_error(error)}

      {:legacy, _state} ->
        {:error, "#{state.name} changed protocol era mid-connection"}

      {:backends_refused, _code, _boot} = refused ->
        refused

      {:error, reason} ->
        {:error, reason}
    end
  end

  # OTP crash reports and :sys.get_status print the state, the last message
  # and the exit reason — which can hold resolved credential header values
  # and a program owner's key.
  @impl true
  def format_status(status), do: Opus.Programs.StatusRedaction.format_status(status)

  @impl true
  def terminate(reason, state) do
    Logger.info(
      "[Emissary.External.Server] #{state.name} shutting down: #{log_reason(reason, state)}"
    )

    for {task_pid, {task_ref, from, caller_ref}} <- state.in_flight do
      Process.demonitor(task_ref, [:flush])
      Process.demonitor(caller_ref, [:flush])
      Process.exit(task_pid, :kill)
      GenServer.reply(from, {:error, {:uncertain, "Server #{state.name} stopped mid-call"}})
    end

    if state.transport == :program do
      drop_session(state, :stopped)
      Opus.Programs.release(owner(state))
    end

    :ok
  end

  defp owner(state),
    do: %{athanor_id: state.athanor_id, server_id: state.server_id, epoch: state.epoch}

  # ============================================================================
  # MCP Handshake
  # ============================================================================

  # A program connects through the programs controller: its owner held,
  # then its session opened and its tools listed.
  defp do_initialize(%State{transport: :program} = state) do
    Logger.info(
      "[Emissary.External.Server] Connecting to #{state.name} through the backends service"
    )

    state = %{state | last_init_attempt: System.monotonic_time(:millisecond), era: :legacy}

    case record_revisions(state) do
      {:ok, state} -> program_connect(state, 0)
      {:error, reason, state} -> fail_initialize(state, reason)
    end
  end

  defp do_initialize(state) do
    Logger.info("[Emissary.External.Server] Connecting to #{state.name} at #{state.url}")
    state = %{state | last_init_attempt: System.monotonic_time(:millisecond)}

    case record_revisions(state) do
      {:ok, state} -> http_initialize(state)
      {:error, reason, state} -> fail_initialize(state, reason)
    end
  end

  # The revisions are read before anything is resolved (see the module
  # doc); a store that cannot answer fails the connect closed, as a
  # resolve against it would.
  defp record_revisions(%State{vault_names: []} = state),
    do: {:ok, %{state | vault_revisions: %{}}}

  defp record_revisions(state) do
    case Sanctum.VaultReader.revisions(state.athanor_id, state.vault_names) do
      {:ok, revisions} -> {:ok, %{state | vault_revisions: revisions}}
      {:error, _reason} -> {:error, {:unavailable, "Vault"}, state}
    end
  end

  defp vault_names(config) do
    headers =
      case config[:headers] do
        %{} = headers -> Prima.VaultRef.names(headers)
        _ -> []
      end

    Enum.uniq(headers ++ Opus.Programs.Definition.entry_names(%{"env" => config[:env] || %{}}))
  end

  defp http_initialize(state) do
    # The handshake runs inside handle_call while callers wait only
    # @initialize_timeout_ms — clamp the wire timeout to match, so a
    # stalling upstream cannot head-of-line-block the server process for
    # the full per-call budget. The operator's timeout applies to tool
    # calls, which run detached.
    handshake_timeout = min(state.timeout_ms, @initialize_timeout_ms)
    call_timeout = state.timeout_ms

    # Headers are resolved before the `with`, not inside it: `with` does not
    # export its bindings to `else`, and the failure arm must mask with the
    # resolved headers. The outer state's `headers` is the struct's empty
    # default (reset on every `:reinitialize`), which masks nothing, so an
    # upstream echoing the Authorization header into its error body would
    # carry it out whole through `state.error`.
    case resolve_headers(state.raw_headers, {state.athanor_id, state.url}) do
      {:error, reason} ->
        fail_initialize(state, reason)

      {:ok, resolved_headers} ->
        state = %{state | headers: resolved_headers, timeout_ms: handshake_timeout}

        # `connected` rather than rebinding `state`: the else arm below must
        # see the headers-resolved state, and a `with` pattern binding would
        # leave it looking at whatever the enclosing scope still holds.
        with :ok <- validate_server_url(state.url),
             {:ok, tools, server_info, connected} <- connect(state) do
          state = %{
            connected
            | timeout_ms: call_timeout,
              status: :ready,
              tools: tools,
              server_info: mask_credentials(server_info, connected),
              error: nil
          }

          Logger.info(
            "[Emissary.External.Server] Connected to #{state.name} (#{state.era}): " <>
              "#{length(tools)} tools discovered"
          )

          {:ok, state}
        else
          # A failure after `initialize` carries the state that holds the
          # peer's session, so the sentence is masked with it too.
          {:error, reason, failed} -> fail_initialize(failed, reason)
          {:error, reason} -> fail_initialize(state, reason)
        end
    end
  end

  defp program_connect(state, attempt) do
    with {:ok, grant} <- Opus.Programs.hold(owner(state)),
         {:ok, tools, listed} <- list_program_tools(%{state | grant: grant}) do
      Logger.info(
        "[Emissary.External.Server] Connected to #{listed.name}: #{length(tools)} tools discovered"
      )

      {:ok, %{listed | status: :ready, tools: tools, error: nil}}
    else
      {:error, {:refused, code, _boot}, state} when code in @retried_refusals and attempt == 0 ->
        program_connect(drop_session(%{state | grant: nil}, :refused), 1)

      {:error, reason, state} ->
        fail_initialize(drop_session(%{state | grant: nil}, :failed), backends_reason(reason))

      {:error, reason} ->
        fail_initialize(drop_session(%{state | grant: nil}, :failed), backends_reason(reason))
    end
  end

  # The program's session ended under a call: the call fails with that
  # sentence, and the session is dropped so the next call opens it again.
  defp program_ended(state),
    do: {:error, "#{state.name} ended", session_ended(state, :ended)}

  # ============================================================================
  # A program's session
  # ============================================================================

  # The program's session, asked for when it has none: of the process this
  # server already has, while that runs, or of a new one, which is
  # initialized before anything else is sent to it.
  defp ensure_session(%State{session: %{}} = state), do: {:ok, state}

  defp ensure_session(%State{grant: nil} = state) do
    case Opus.Programs.hold(owner(state)) do
      {:ok, grant} -> ensure_session(%{state | grant: grant})
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp ensure_session(%State{lifetime: nil} = state),
    do: open_program(with_lifetime(state))

  # Its process ended, or was closed: that place is asked back, and the
  # program starts afresh as another lifetime.
  defp ensure_session(state) do
    case open_program(state) do
      {:error, {:refused, :lifetime_over, _boot}, state} ->
        _ = Opus.Programs.box_close(state.lifetime)
        open_program(with_lifetime(state))

      # The service runs another boot than the lifetime's: holding again
      # answers a grant of that one, and the next is minted under it.
      {:error, {:refused, :stale_boot, _boot}, state} ->
        _ = Opus.Programs.box_close(state.lifetime)
        ensure_session(%{state | grant: nil, lifetime: nil})

      answer ->
        answer
    end
  end

  defp with_lifetime(state) do
    named = %{
      program: Opus.Programs.Definition.program_name(),
      key: @session_key,
      home_id: state.home_id,
      mode: :run
    }

    %{state | lifetime: Opus.Programs.lifetime(state.grant, named)}
  end

  defp open_deadline, do: System.system_time(:millisecond) + @connect_call_timeout_ms

  # A box that does not count this process a holder (one started in
  # another's place) is asked to once.
  defp open_program(state, held_again? \\ false) do
    case Opus.Programs.box_open(state.lifetime, self(), %{}, open_deadline()) do
      {:ok, %{session: session, resumed: resumed}} ->
        state = %{state | session: %{session: session, reader: nil, after: 0}}
        if resumed, do: {:ok, state}, else: initialize_program(state)

      {:error, :not_held} when not held_again? ->
        case Opus.Programs.hold(owner(state)) do
          {:ok, grant} -> open_program(%{state | grant: grant}, true)
          {:error, reason} -> {:error, reason, state}
        end

      {:error, {:refused, code, boot} = refused} ->
        if code == :stale_boot and is_binary(boot), do: Opus.Programs.boot_seen(boot)
        {:error, refused, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp initialize_program(state) do
    params = %{
      "protocolVersion" => Protocol.legacy_version(),
      "capabilities" => %{},
      "clientInfo" => %{"name" => "cyfr", "version" => Prima.Version.current()}
    }

    with {:ok, result, state} <- request(state, "initialize", params),
         {:ok, state} <- notify(state, "notifications/initialized") do
      {:ok, declared_anew(state, declared(result))}
    end
  end

  # What an initialize declares replaces all the process declared before:
  # what it does not declare is empty, so a replacement that offers no tools
  # leaves none of its predecessor's, in this process or in the athanor's
  # listing.
  defp declared_anew(state, offers) do
    if :tools in offers or state.tools == [] do
      %{state | offers: offers}
    else
      tools_changed(state.athanor_id)
      %{state | offers: offers, tools: []}
    end
  end

  # The program's tools, asked only of one whose `initialize` declared them.
  defp list_program_tools(state) do
    with {:ok, state} <- ensure_session(state) do
      listing = {state.name, "tools/list", "tools"}

      case :tools in state.offers && list_pages(state, listing, &request(&1, "tools/list", &2)) do
        false -> {:ok, [], state}
        {:ok, tools, state} -> {:ok, mask_credentials(tools, state), state}
        {:error, reason, state} -> {:error, reason, state}
      end
    end
  end

  # One request to the program, made from this process: its line sent, its
  # session read while the answer is outstanding, and this process's own
  # mailbox read for the reader's lines until the answer with its id
  # arrives, the session ends or the bound passes. Every other line read
  # meanwhile is handled as it would be outside. A session the service ended
  # meanwhile (idle, a crash) is opened again once, its program initialized
  # afresh.
  defp request(state, method, params, retried? \\ false) do
    {id, state} = next_request_id(state)
    %{session: session} = state.session
    line = Jason.encode!(Message.encode_request(id, method, params))
    deadline = System.monotonic_time(:millisecond) + min(state.timeout_ms, @initialize_timeout_ms)

    case Opus.Programs.Session.send(state.grant, session, [line]) do
      {:ok, :running} ->
        await(start_reader(state), session, id, deadline)

      {:ok, :ended} when not retried? ->
        reopen(state, &request(&1, method, params, true))

      {:error, {:refused, :unknown_session, _boot}} when not retried? ->
        reopen(state, &request(&1, method, params, true))

      {:ok, :ended} ->
        program_ended(state)

      {:error, reason} ->
        {:error, reason, session_ended(state, :refused)}
    end
  end

  defp reopen(state, again) do
    case ensure_session(session_ended(state, :ended)) do
      {:ok, state} -> again.(state)
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp await(state, session, id, deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:session_lines, ^session, lines, last, running, reader} ->
        {state, found} = on_lines(state, lines, id)
        state = after_read(state, last, running, reader, found == nil)

        case found do
          {:ok, %Message{type: :response, result: result}} ->
            {:ok, result, state}

          {:ok, %Message{type: :error, error: error}} ->
            {:error, server_error(error), state}

          nil when running ->
            await(state, session, id, deadline)

          nil ->
            {:error, "#{state.name} ended before it answered", state}
        end

      {:session_lost, ^session, reason} ->
        {:error, reason, session_ended(state, reason)}
    after
      wait -> {:error, "timeout: #{state.name} did not answer", stop_reader(state)}
    end
  end

  defp notify(state, method) do
    %{session: session} = state.session
    line = Jason.encode!(Message.encode_notification(method))

    case Opus.Programs.Session.send(state.grant, session, [line]) do
      {:ok, :running} -> {:ok, state}
      {:ok, :ended} -> program_ended(state)
      {:error, reason} -> {:error, reason, session_ended(state, :refused)}
    end
  end

  # What the program wrote: an answer a call's task awaits goes to it, the
  # one `awaited` id is answered back, the program's own request is
  # answered `-32601`, a tools-changed notification lists its tools again,
  # and anything else is dropped.
  defp on_lines(state, lines, awaited) do
    Enum.reduce(lines, {state, nil}, fn line, {state, found} ->
      case Message.decode_json(line) do
        {:ok, %Message{type: type, id: ^awaited} = message}
        when type in [:response, :error] and awaited != nil ->
          {state, {:ok, message}}

        {:ok, %Message{type: type, id: id} = message} when type in [:response, :error] ->
          case Map.pop(state.pending, id) do
            {task, pending} when is_pid(task) ->
              send(task, {:rpc_reply, id, message})
              {%{state | pending: pending}, found}

            _ ->
              {state, found}
          end

        {:ok, %Message{type: :notification, method: "notifications/tools/list_changed"}} ->
          send(self(), :relist)
          {state, found}

        {:ok, %Message{type: :request, id: id, method: method}} ->
          refuse_program_request(state, id, method)
          {state, found}

        _ ->
          {state, found}
      end
    end)
  end

  defp refuse_program_request(state, id, method) do
    with %{session: session} <- state.session do
      error = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32_601, "message" => "method not supported: #{method}"}
      }

      _ = Opus.Programs.Session.send(state.grant, session, [Jason.encode!(error)])
    end

    :ok
  end

  # The program's session ended: every call awaiting it fails, and the next
  # call opens it again.
  defp session_ended(state, reason) do
    for {id, task} <- state.pending, do: send(task, {:rpc_failed, id, reason})

    case state.session do
      %{reader: reader} when is_pid(reader) ->
        Process.unlink(reader)
        Process.exit(reader, :kill)

      _none_or_unread ->
        :ok
    end

    %{state | session: nil, pending: %{}}
  end

  defp drop_session(%State{session: nil} = state, _reason), do: state
  defp drop_session(state, reason), do: session_ended(state, reason)

  # The session is read only while an answer is outstanding on it: a recv
  # is activity to the service, which ends a session with none within its
  # idle period, so a reader polling an idle session would keep it running
  # for ever. Lines the program writes while no one reads wait in the
  # service's buffer and are read by the next reader, from `after`.
  defp after_read(state, last, running, reader, awaiting?) do
    case state.session do
      %{reader: ^reader} = session ->
        session = %{session | after: max(session.after, last)}

        cond do
          not running ->
            send(reader, :stop)
            session_ended(%{state | session: session}, :ended)

          awaiting? or state.pending != %{} ->
            send(reader, {:continue, session.after})
            %{state | session: session}

          true ->
            send(reader, :stop)
            Process.unlink(reader)
            %{state | session: %{session | reader: nil}}
        end

      _other ->
        send(reader, :stop)
        state
    end
  end

  defp start_reader(state) do
    case state.session do
      %{reader: nil, session: session, after: after_seq} = entry ->
        server = self()
        grant = state.grant
        reader = spawn_link(fn -> read(server, grant, session, after_seq) end)
        %{state | session: %{entry | reader: reader}}

      _running_or_gone ->
        state
    end
  end

  defp stop_reader(state) do
    case state.session do
      %{reader: reader} = entry when is_pid(reader) and state.pending == %{} ->
        Process.unlink(reader)
        Process.exit(reader, :kill)
        %{state | session: %{entry | reader: nil}}

      _ ->
        state
    end
  end

  # A reader: one recv at a time from `after`, each answer handed to the
  # server, which says whether to read on.
  defp read(server, grant, session, after_seq) do
    case Opus.Programs.Session.recv(grant, session, after_seq, @recv_wait_ms) do
      {:ok, %{lines: lines, running: running}} ->
        last = if lines == [], do: after_seq, else: List.last(lines).seq
        send(server, {:session_lines, session, Enum.map(lines, & &1.text), last, running, self()})

        receive do
          {:continue, from} -> read(server, grant, session, from)
          :stop -> :ok
        end

      {:error, reason} ->
        send(server, {:session_lost, session, reason})
    end
  end

  # A call's round trip, from its task: its line sent on the program's
  # session, then the answer this server hands back by its id.
  defp upstream(%State{transport: :program} = state, body) do
    %{session: session} = state.session
    id = body["id"]

    case Opus.Programs.Session.send(state.grant, session, [Jason.encode!(body)]) do
      {:ok, :running} ->
        receive do
          {:rpc_reply, ^id, message} ->
            {:ok, message}

          {:rpc_failed, ^id, _reason} ->
            {:error, "#{state.name} ended before it answered"}
        after
          state.timeout_ms -> {:error, {:uncertain, "timeout: #{body["method"]}"}}
        end

      {:ok, :ended} ->
        {:backends_refused, :session_ended, nil}

      {:error, {:refused, :unknown_session, _boot}} ->
        {:backends_refused, :session_ended, nil}

      {:error, {:refused, code, boot}} ->
        {:backends_refused, code, boot}

      {:error, reason} ->
        {:error, backends_reason(reason)}
    end
  end

  defp upstream(state, body), do: http_post(state, body)

  defp backends_reason({:refused, code, _boot}),
    do: "the backends service refused (#{code})"

  defp backends_reason({:unreadable, _error}),
    do: "the backends service answered something unreadable"

  defp backends_reason(:backends_not_configured), do: "no backends service is configured"
  defp backends_reason(:backends_unavailable), do: "the backends service is unavailable"

  defp backends_reason(:protocol_mismatch),
    do: "the backends service speaks another protocol version"

  defp backends_reason(:deadline), do: "the backends service did not answer in time"
  defp backends_reason(:control_plane_lost), do: "this server does not own its control plane"
  defp backends_reason(:capacity), do: "the backends service has no free program slots"

  defp backends_reason(:claimed_elsewhere),
    do: "another server of the cluster holds this server's program"

  defp backends_reason(:claim_unavailable),
    do: "which server holds this server's program could not be read"

  defp backends_reason({:pool_share, limit}),
    do: "this athanor already runs its share of the backends service (#{limit} programs)"

  defp backends_reason({:control_too_large, limit}),
    do: "this server's program and its env exceed what one sync may carry (#{limit} bytes)"

  defp backends_reason({:env_unresolved, name}),
    do: "env #{name} does not resolve to a single-field vault entry"

  defp backends_reason(reason), do: reason

  # `state.error` surfaces to callers and the status view — the same egress
  # rule as results: a sentence, never a term's spelling, with the
  # credentials this plane injected masked out of it before a transport
  # exception that echoed them can carry one out. The caller is answered
  # with that same masked sentence and never the reason itself, which can
  # be an upstream's own error message quoting a header it was sent. The
  # log gets the masked term (`log_reason/2`); the credential is never the
  # diagnostic part.
  defp fail_initialize(state, reason) do
    state = %{
      state
      | status: :error,
        error: mask_credentials(failure_sentence(reason), state),
        failure: failure(reason, state)
    }

    Logger.error(
      "[Emissary.External.Server] Failed to initialize #{state.name}: " <>
        log_reason(reason, state)
    )

    {:error, state.error, state}
  end

  defp failure_sentence({:outside_error, words}), do: words
  defp failure_sentence(reason) when is_binary(reason), do: reason
  defp failure_sentence(%{__exception__: true} = exception), do: Exception.message(exception)
  defp failure_sentence(reason), do: Refusals.render(reason)

  # What a caller is answered for a failure, masked as `state.error` is:
  # the server's own words still tagged as its own, any other reason its
  # sentence.
  defp failure({:outside_error, words}, state),
    do: {:outside_error, mask_credentials(words, state)}

  defp failure(reason, state), do: mask_credentials(failure_sentence(reason), state)

  # The one reading of a server's JSON-RPC error: its own words, tagged as
  # its own (`Prima.Refusal.outside?/1`), wherever it answered one, so a
  # model reads them as outside data. One without a message is named as
  # such rather than spelled. Nothing else makes a reason of a server's
  # message.
  defp server_error(%{"message" => message}) when is_binary(message),
    do: {:outside_error, message}

  defp server_error(_error), do: {:outside_error, "the server answered an error with no message"}

  # Try the current protocol first; fall back to the handshake only when the
  # answer says the peer cannot speak it.
  #
  # The fallback exists for third-party servers, which are on their own release
  # cadence and mostly still expect `initialize`. It is not a compatibility
  # shim for anything CYFR ships: the backends service speaks the current revision,
  # so the bundled deployment never takes this path. The specification
  # prescribes exactly this probe — attempt a modern request, and read the body
  # of a `400` before concluding the peer is legacy, because a modern server
  # also answers `400` for an unsupported version or a bad header.
  defp connect(state) do
    case discover(%{state | era: :modern}) do
      {:ok, offers, state} ->
        case listed(offers, state) do
          {:ok, tools, listed} ->
            {:ok, tools, nil, %{listed | offers: offers}}

          {:legacy, _state} ->
            {:error,
             {:failed, "#{state.name} answered its discovery and not its listing of tools"}}

          {:error, reason} ->
            {:error, reason}
        end

      {:legacy, state} ->
        Logger.info("[Emissary.External.Server] #{state.name} speaks a pre-2026-07-28 revision")
        legacy_connect(%{state | era: :legacy})

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The current revision's probe, `server/discover`, which states what the
  # server offers without a session. A peer that cannot speak the current
  # revision answers it as `refused_status/3` reads one, or as a method it
  # does not know (-32601).
  defp discover(state) do
    {request_id, state} = next_request_id(state)

    case http_post(state, Message.encode_request(request_id, "server/discover", %{})) do
      {:ok, %Message{type: :response, result: result}} -> {:ok, declared(result), state}
      {:ok, %Message{type: :error, error: %{"code" => -32_601}}} -> {:legacy, state}
      {:ok, %Message{type: :error, error: error}} -> {:error, server_error(error)}
      {:legacy, state} -> {:legacy, state}
      {:error, reason} -> {:error, reason}
    end
  end

  # What a server's discovery or `initialize` answer declares it offers,
  # sorted: what it is asked for, and nothing else.
  defp declared(%{"capabilities" => %{} = capabilities}) do
    for {name, offering} <- [{"prompts", :prompts}, {"resources", :resources}, {"tools", :tools}],
        is_map_key(capabilities, name),
        do: offering
  end

  defp declared(_answer), do: []

  # The tools a server lists, asked only of one that declares them.
  defp listed(offers, state),
    do: if(:tools in offers, do: send_tools_list(state), else: {:ok, [], state})

  defp legacy_connect(state) do
    case send_initialize(state) do
      {:ok, init_result, state} ->
        offers = declared(init_result)

        with :ok <- send_initialized_notification(state),
             {:ok, tools, listed} <- listed(offers, state) do
          {:ok, tools, server_info(init_result), %{listed | offers: offers}}
        else
          # `state` is the one `initialize` answered, which holds the peer's
          # session, so a failure after it is masked with that session.
          # A legacy peer has no fall-forward; a second `:legacy` here would
          # mean the handshake itself was refused, which is a failure rather
          # than an era.
          {:legacy, _state} -> {:error, "#{state.name} refused both protocol eras", state}
          {:error, reason} -> {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_initialize(state) do
    {request_id, state} = next_request_id(state)

    body =
      Message.encode_request(request_id, "initialize", %{
        "protocolVersion" => Protocol.legacy_version(),
        "capabilities" => %{},
        "clientInfo" => %{
          "name" => "cyfr",
          "version" => Prima.Version.current()
        }
      })

    case http_exchange(state, body) do
      {{:ok, %Message{type: :response, result: result}}, resp_headers} ->
        with {:ok, state} <- keep_session(state, resp_headers), do: {:ok, result, state}

      {{:ok, %Message{type: :error, error: error}}, _resp_headers} ->
        {:error, server_error(error)}

      {{:error, reason}, _resp_headers} ->
        {:error, reason}
    end
  end

  # The peer's session id is kept among the resolved headers, so it goes
  # out on every later request of this connection and is a secret wherever
  # they are: excluded from Inspect, redacted from the status, masked out
  # of what the peer answers and of the log. The next connect resolves the
  # headers afresh, without it. A configured `mcp-session-id` header wins
  # and an issued id is then not kept. An issued id is kept only when it can
  # be both sent and masked: visible ASCII (the specification's
  # `0x21`-`0x7E`), since it goes back out as a header value, and at least
  # @min_masked_bytes long, since a shorter one would not be masked; any
  # other fails the connect.
  defp keep_session(state, resp_headers) do
    case List.keyfind(resp_headers, @session_id_header, 0) do
      nil ->
        {:ok, state}

      {_name, id} ->
        cond do
          configured_session?(state) ->
            {:ok, state}

          not String.match?(id, ~r/^[\x21-\x7e]+$/) ->
            {:error, "#{state.name} issued a session id that is not visible ASCII"}

          byte_size(id) < @min_masked_bytes ->
            {:error, "#{state.name} issued a session id too short to keep"}

          true ->
            {:ok, %{state | headers: Map.put(state.headers, @session_id_header, id)}}
        end
    end
  end

  defp configured_session?(state),
    do: Enum.any?(Map.keys(state.raw_headers), &session_header?/1)

  defp session_header?(key), do: key |> to_string() |> String.downcase() == @session_id_header

  defp send_initialized_notification(state) do
    body = Message.encode_notification("notifications/initialized")

    case http_post(state, body) do
      # Notifications may return empty or accepted
      {:ok, _} -> :ok
      # Some servers don't respond to notifications
      {:error, :empty_response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The listing is the upstream's words as much as a result is, and is
  # stored, answered and drawn: it is masked as a tool call's result is.
  defp send_tools_list(state) do
    case list_pages(state, {state.name, "tools/list", "tools"}, &http_list_page/2) do
      {:ok, tools, state} -> {:ok, mask_credentials(tools, state), state}
      {:error, sentence, _state} -> {:error, {:failed, sentence}}
      {:legacy, state} -> {:legacy, state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp http_list_page(state, params) do
    {request_id, state} = next_request_id(state)

    case http_post(state, Message.encode_request(request_id, "tools/list", params)) do
      {:ok, %Message{type: :response, result: result}} -> {:ok, result, state}
      {:ok, %Message{type: :error, error: error}} -> {:error, server_error(error)}
      {:legacy, state} -> {:legacy, state}
      {:error, reason} -> {:error, reason}
    end
  end

  # Every item a paged listing holds, `{who, method, key}`: the items at
  # `key` of each page of `method` that `who` answers (`tools/list`'s
  # `tools`, `resources/list`'s `resources`, `resources/templates/list`'s
  # `resourceTemplates`, `prompts/list`'s `prompts`). `fetch` asks for one
  # page with the params given and answers `{:ok, result, state}` or what
  # the caller passes back as it is. Pages are read while the peer names a
  # next cursor, to @max_listing_pages, and all of them within the
  # handshake limit counted from the first request: each page waits only
  # for what is left of it, and a listing that runs out fails as one too
  # long does.
  defp list_pages(state, {who, method, key}, fetch) do
    limit = min(state.timeout_ms, @initialize_timeout_ms)
    deadline = System.monotonic_time(:millisecond) + limit
    list_pages(state, {{who, method, key}, fetch, deadline, limit}, %{}, [], 1)
  end

  defp list_pages(state, {what, fetch, deadline, limit} = listing, params, acc, page) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, out_of_time(what, limit), state}
    else
      %{state | timeout_ms: min(state.timeout_ms, remaining)}
      |> fetch.(params)
      |> keep_timeout(state.timeout_ms)
      |> listed_page(state, listing, acc, page)
    end
  end

  defp listed_page({:ok, result, state}, _before, {what, _, deadline, limit} = listing, acc, page) do
    {who, method, key} = what
    late? = System.monotonic_time(:millisecond) > deadline

    case {listed_items(result, key), next_cursor(result)} do
      _page when late? ->
        {:error, out_of_time(what, limit), state}

      {:error, _cursor} ->
        {:error, "#{who} answered #{method} without a list of #{words(key)}", state}

      {{:ok, items}, nil} ->
        {:ok, acc ++ items, state}

      {{:ok, _items}, _cursor} when page >= @max_listing_pages ->
        {:error, "#{who} listed more than #{@max_listing_pages} pages of #{words(key)}", state}

      {{:ok, items}, cursor} ->
        list_pages(state, listing, %{"cursor" => cursor}, acc ++ items, page + 1)
    end
  end

  # A page that failed because the deadline cut its wait short is the
  # listing running out of time, not the peer's failure.
  defp listed_page(failed, before, {what, _, deadline, limit}, _acc, _page)
       when elem(failed, 0) == :error do
    if System.monotonic_time(:millisecond) >= deadline do
      state =
        case failed do
          {:error, _reason, %State{} = state} -> state
          _failed -> before
        end

      {:error, out_of_time(what, limit), state}
    else
      failed
    end
  end

  defp listed_page(other, _before, _listing, _acc, _page), do: other

  defp out_of_time({who, _method, key}, limit),
    do: "#{who} did not finish listing its #{words(key)} within #{limit} ms"

  defp words("resourceTemplates"), do: "resource templates"
  defp words(key), do: key

  # A page is fetched with its wait cut to what is left of the deadline;
  # the state it hands back keeps the timeout it had before.
  defp keep_timeout(result, timeout_ms) do
    result
    |> Tuple.to_list()
    |> Enum.map(fn
      %State{} = state -> %{state | timeout_ms: timeout_ms}
      other -> other
    end)
    |> List.to_tuple()
  end

  defp next_cursor(%{"nextCursor" => cursor}) when is_binary(cursor) and cursor != "", do: cursor
  defp next_cursor(_result), do: nil

  # A listing is a list of objects at its key or, for some servers, with no
  # such key at all; anything else is no listing.
  defp listed_items(result, key) when is_map(result) do
    case result do
      %{^key => items} when is_list(items) ->
        if Enum.all?(items, &is_map/1), do: {:ok, items}, else: :error

      %{^key => _not_a_list} ->
        :error

      _none ->
        {:ok, []}
    end
  end

  defp listed_items(_result, _key), do: :error

  defp server_info(%{"serverInfo" => info}) when is_map(info), do: info
  defp server_info(_init_result), do: nil

  # ============================================================================
  # HTTP Transport
  # ============================================================================

  defp http_post(state, body) do
    {reply, _resp_headers} = http_exchange(state, body)
    reply
  end

  # The reply to `body` and the headers it came with (`[]` when no
  # response was read).
  defp http_exchange(state, body) do
    body = maybe_add_meta(body, state.era)

    headers =
      [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}]
      |> Enum.concat(protocol_headers(body, state.era, state.tools))
      |> merge_headers(state.headers)

    case Jason.encode(body) do
      {:ok, json_body} -> post_encoded(state, body, headers, json_body)
      {:error, _reason} -> {{:error, "Request encoding failed"}, []}
    end
  end

  defp post_encoded(state, body, headers, json_body) do
    # Pin to the validated IP on EVERY request (not just at init), with the
    # original hostname preserved for SNI/Host. This both blocks SSRF and
    # closes the DNS-rebinding gap that connecting by hostname would reopen.
    # A private server (locus-backends on the compose network) is reachable
    # only when the operator named it in the private-egress allowlist.
    opts = [
      receive_timeout: state.timeout_ms,
      private_policy: :operator,
      # Enforced while the body streams in — the transfer aborts at the
      # ceiling, so a hostile peer cannot make this node buffer an
      # arbitrarily large body before a post-hoc check.
      max_response_bytes: @max_response_body_bytes
    ]

    case bounded_request(state, headers, json_body, opts) do
      {:ok, status, resp_headers, resp_body} when status in 200..299 ->
        {read_reply(state, resp_headers, resp_body, body), resp_headers}

      {:ok, status, resp_headers, resp_body} ->
        {refused_status(state, status, resp_body), resp_headers}

      {:error, reason} ->
        {request_failed(state, reason), []}
    end
  end

  # A request's timeout bounds its wall time, not only the wait for each
  # chunk, which restarts on every chunk that arrives: a peer trickling
  # bytes would otherwise hold the request, and a handshake or listing
  # waiting on it, for as long as it kept trickling. A request cut off is
  # a transport failure, whether it reached the peer not known.
  defp bounded_request(state, headers, json_body, opts) do
    task =
      Task.async(fn ->
        Sanctum.Egress.pinned_request(:post, state.url, headers, json_body, opts)
      end)

    case Task.yield(task, state.timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  # A 4xx while speaking the current revision is how a peer says it cannot.
  # The specification is explicit that the body has to be read before
  # falling back: a modern server also answers 4xx for an unsupported
  # version or a bad header, and those mean "retry differently", not "you
  # are talking to an older server".
  #
  # The body is inspected, never reflected — it may carry internal
  # diagnostics or credentials echoed back at us.
  defp refused_status(state, status, resp_body) do
    cond do
      # An auth rejection is never an era signal: a legacy retry re-sends
      # the same refused credential, wastes a round-trip, and logs "speaks a
      # pre-2026 revision" about a server whose only complaint is the bearer
      # token. Say what it is.
      status in [401, 403] ->
        {:error,
         "HTTP #{status} — the server refused the configured " <>
           "credentials; check the registered Authorization header"}

      state.era == :modern and status in 400..499 and not modern_error?(resp_body) ->
        {:legacy, state}

      true ->
        {:error, "HTTP #{status}"}
    end
  end

  defp request_failed(_state, {:response_too_large, _size, _max}),
    do: {:error, "Response too large (max 10MB)"}

  # SSRF/DNS validation failures are safe, descriptive strings.
  defp request_failed(_state, {:refused, _type, reason}), do: {:error, reason}

  # Transport/connection failure — log detail internally, surface a generic
  # message to the caller. Whether the request reached the server is not
  # known from here.
  defp request_failed(state, reason) do
    Logger.debug(
      "[Emissary.External.Server] request to #{state.name} failed: " <> log_reason(reason, state)
    )

    {:error, {:uncertain, "Request failed"}}
  end

  # Per-request metadata. There is no handshake in this revision, so a request
  # that omits it is malformed rather than merely terse.
  defp maybe_add_meta(body, :modern) do
    params = Map.get(body, "params") || %{}

    meta = %{
      Protocol.meta_protocol_version_key() => Protocol.version(),
      Protocol.meta_client_info_key() => %{"name" => "cyfr", "version" => Prima.Version.current()},
      Protocol.meta_client_capabilities_key() => %{}
    }

    Map.put(body, "params", Map.put(params, "_meta", meta))
  end

  defp maybe_add_meta(body, _era), do: body

  # The routed fields, mirrored into headers so an intermediary can route without
  # parsing the body. A conforming peer refuses a header that disagrees with the
  # body, so both are derived from the same value.
  defp protocol_headers(_body, era, _tools) when era != :modern, do: []

  defp protocol_headers(body, :modern, tools) do
    method = body["method"]

    base = [
      {Protocol.protocol_version_header(), Protocol.version()},
      {Protocol.method_header(), method}
    ]

    case Protocol.named_subject(body) do
      nil -> base
      name -> [{Protocol.name_header(), Protocol.encode_header_value(name)} | base]
    end ++ param_headers(body, tools)
  end

  # `x-mcp-header` lets a server ask for specific tool arguments to be mirrored
  # into `Mcp-Param-*`. Supporting it is required of clients, and the value is
  # taken from the arguments actually being sent so it cannot disagree with them.
  defp param_headers(%{"method" => "tools/call", "params" => %{"name" => name} = params}, tools) do
    case Enum.find(tools, &(&1["name"] == name)) do
      %{"inputSchema" => %{} = schema} -> mirrored_params(schema, params["arguments"] || %{})
      _ -> []
    end
  end

  defp param_headers(_body, _tools), do: []

  defp mirrored_params(schema, arguments) do
    schema
    |> Map.get("properties", %{})
    |> Enum.flat_map(fn {property, spec} ->
      with header when is_binary(header) <- is_map(spec) && spec["x-mcp-header"],
           true <- Map.has_key?(arguments, property),
           value when not is_nil(value) <- arguments[property] do
        [
          {Protocol.param_header_prefix() <> String.downcase(header),
           Protocol.encode_header_value(to_header_value(value))}
        ]
      else
        _ -> []
      end
    end)
  end

  defp to_header_value(value) when is_binary(value), do: value
  defp to_header_value(true), do: "true"
  defp to_header_value(false), do: "false"
  defp to_header_value(value) when is_integer(value), do: Integer.to_string(value)
  defp to_header_value(value), do: to_string(value)

  # A modern server answers 4xx with a JSON-RPC error for an unsupported version,
  # a missing capability or a header mismatch. Seeing one means the peer is
  # current and the request was wrong — retry differently rather than fall back.
  defp modern_error?(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"code" => code}}} when is_integer(code) -> code <= -32020
      _ -> false
    end
  end

  # The reply to a request is one message, read through the codec: a
  # response or an error response carrying this request's id, and nothing
  # else. A message carrying `method` is the peer's own request or
  # notification, never this call's answer; one carrying both `result` and
  # `error`, or a null or missing id, is refused by the codec; a DIFFERENT
  # id — or an SSE stream whose last event was not the reply — is some
  # other request's answer and must not be folded into this call's result.
  # A notification expects no answer, so any JSON body is accepted. The
  # refusal names which of these it was in the log, never the body: that
  # may carry internal diagnostics.
  defp read_reply(_state, _resp_headers, "", _request), do: {:error, :empty_response}

  defp read_reply(state, resp_headers, resp_body, request) do
    case Message.decode_json(reply_json(resp_headers, resp_body)) do
      {:error, :parse_error, _} ->
        {:error, "Invalid JSON response"}

      _decoded when not is_map_key(request, "id") ->
        {:ok, :accepted}

      decoded ->
        case refused_reply(decoded, request["id"]) do
          nil ->
            decoded

          why ->
            Logger.debug("[Emissary.External.Server] #{state.name} reply refused: #{why}")
            {:error, "The server's reply is not the response to this request"}
        end
    end
  end

  defp refused_reply({:ok, %Message{type: type, id: id}}, id) when type in [:response, :error],
    do: nil

  defp refused_reply({:ok, %Message{type: type}}, _id) when type in [:response, :error],
    do: "it answers another request id"

  defp refused_reply({:ok, %Message{}}, _id), do: "it is a request of the server's own"
  defp refused_reply({:error, :invalid_request, _}, _id), do: "it is not a valid response"

  # A reply is an event stream when its content type says so, whatever
  # field or comment line the stream opens with; any other is JSON.
  defp reply_json(resp_headers, body) do
    if event_stream?(resp_headers), do: extract_sse_data(body), else: body
  end

  defp event_stream?(resp_headers) do
    Enum.any?(resp_headers, fn {name, value} ->
      name == "content-type" and
        value |> String.split(";") |> hd() |> String.trim() |> String.downcase() ==
          "text/event-stream"
    end)
  end

  # Extract the JSON-RPC response from the last SSE event.
  # Join consecutive data: lines within each event using newlines.
  defp extract_sse_data(sse_body) do
    sse_body
    # Normalize CRLF: the wire form is \r\n and the split below is on \n.
    |> String.replace("\r\n", "\n")
    |> String.split("\n\n")
    |> Enum.map(&event_data/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last() || ""
  end

  defp event_data(event) do
    event
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data:"))
    |> Enum.map_join("\n", fn line ->
      line |> String.trim_leading("data:") |> String.trim_leading(" ")
    end)
    |> String.trim()
  end

  # Operator-configured headers, merged over the ones this client sets.
  #
  # Two things are checked because the values do not all come from the
  # operator's own typing: a `vault:` reference resolves to whatever the
  # vault entry holds. A CR or LF in a name or value is a header-injection
  # primitive against the upstream — it would split one header into
  # several, or forge a body — and a name that is not a valid HTTP token
  # cannot be sent at all. Neither belongs on the wire, and dropping the
  # header is the only safe reading: there is no "escaped" form of a
  # newline in a header.
  defp merge_headers(base, extra) when is_map(extra) do
    Enum.reduce(extra, base, fn {k, v}, acc ->
      name = k |> to_string() |> String.downcase()
      value = to_string(v)

      if valid_header_name?(name) and not control_chars?(value) do
        # keystore, not cons: an operator's content-type REPLACES the
        # client's base header, so the request carries one value and the
        # upstream has no second one to choose.
        List.keystore(acc, name, 0, {name, value})
      else
        Logger.warning(
          "[Emissary.External.Server] refusing header #{inspect(name)}: a header name must be an HTTP " <>
            "token and neither name nor value may carry control characters"
        )

        acc
      end
    end)
  end

  defp merge_headers(base, _), do: base

  # RFC 9110 token: the characters a header field name may use.
  defp valid_header_name?(name) do
    name != "" and String.match?(name, ~r/^[!#$%&'*+\-.^_`|~0-9a-z]+$/)
  end

  defp control_chars?(value), do: String.match?(value, ~r/[\x00-\x1f\x7f]/)

  # ============================================================================
  # Secret Resolution
  # ============================================================================

  # `target` is the athanor the server belongs to and the URL it posts
  # to: a header's entry is read only for a URL its destination admits.
  # Every header is checked before any entry is unsealed.
  defp resolve_headers(headers, {_athanor_id, _url} = target) when is_map(headers) do
    with :ok <- check_headers(headers, target) do
      unseal_headers(headers, target)
    end
  end

  # From metadata alone (`Sanctum.Vault.destination_matches?/3`): a
  # reference this server does not resolve, or an entry missing, inactive
  # or bound elsewhere, refuses the whole set before any entry is
  # unsealed, so one covered header beside one that is not sends nothing
  # and records no use. The answers are the ones the unseal would give.
  defp check_headers(headers, {athanor_id, url}) do
    ctx = Sanctum.Context.internal(athanor_id: athanor_id, scope: :athanor)

    Enum.find_value(headers, :ok, fn {key, value} ->
      case Prima.VaultRef.classify(value) do
        {:vault, %{name: name}} ->
          cond do
            not is_binary(url) -> {:error, :destination_mismatch}
            Sanctum.Vault.destination_matches?(ctx, name, url) -> nil
            active?(athanor_id, name) -> {:error, :destination_mismatch}
            true -> unresolved(key)
          end

        :unresolved ->
          unresolved(key)

        :literal ->
          nil
      end
    end)
  end

  defp active?(athanor_id, name) do
    match?({:ok, %{^name => {_rev, _digest}}}, Sanctum.VaultReader.revisions(athanor_id, [name]))
  end

  # Report only the header name (caller-supplied config), never the
  # referenced secret name or the underlying error — that would let a
  # caller enumerate which secrets exist.
  defp unresolved(key), do: {:error, "Failed to resolve header '#{key}'"}

  defp unseal_headers(headers, target) do
    resolved =
      Enum.reduce_while(headers, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case resolve_value(value, target) do
          {:ok, resolved_value} ->
            {:cont, {:ok, Map.put(acc, key, resolved_value)}}

          # An entry rebound since the check: the reader refuses it
          # unsealed, in the check's own words.
          {:error, :destination_mismatch} ->
            {:halt, {:error, :destination_mismatch}}

          {:error, _reason} ->
            {:halt, unresolved(key)}
        end
      end)

    case resolved do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, reason}
    end
  end

  # A vault-backed header (`Prima.VaultRef.template/1`) resolves the
  # entry's single material field. Deliberately single-field — a header
  # carries one value, and picking silently from a bundle would smuggle the
  # wrong credential into the wrong header. Errors stay opaque outward, like
  # secrets.
  defp resolve_value(value, target) when is_binary(value) do
    case Prima.VaultRef.classify(value) do
      {:vault, template} -> resolve_template(template, target)
      :unresolved -> {:error, :unresolved_ref}
      :literal -> {:ok, value}
    end
  end

  # A server without a URL posts nowhere, so no destination covers it.
  defp resolve_template(_template, {_athanor_id, url}) when not is_binary(url),
    do: {:error, :destination_mismatch}

  defp resolve_template(%{name: entry_name} = template, {athanor_id, url}) do
    case Sanctum.VaultReader.unseal_for(athanor_id, entry_name, url) do
      {:ok, fields} ->
        case Map.values(fields) do
          [value] ->
            {:ok, Prima.VaultRef.render(template, value)}

          _ ->
            Logger.debug(
              "[Emissary.External.Server] vault header ref must name a single-field entry, " <>
                "got #{map_size(fields)} fields"
            )

            {:error, :vault_ref_ambiguous}
        end

      {:error, :destination_mismatch} ->
        {:error, :destination_mismatch}

      {:error, _} ->
        Logger.debug(
          "[Emissary.External.Server] vault header reference unresolved for athanor=#{athanor_id}"
        )

        {:error, :vault_ref_unavailable}
    end
  end

  # ============================================================================
  # Credential masking
  # ============================================================================

  # An upstream server can echo request headers back in its result (debug
  # endpoints, error bodies, proxies). External responses never pass through
  # the executor's SecretMasker, so what THIS plane sent is masked here:
  # every header value it stores of at least @min_masked_bytes, a resolved
  # `vault:` value and a literal alike, since a literal's name says nothing
  # of what it holds and the page that edits it never sees it, and the
  # session id the peer issued. A shorter value is not masked: masking is by
  # substring, and a short value replaced wherever its bytes occur marks its
  # own place and length, telling more than it hides.
  defp mask_credentials(term, state) do
    case sensitive_header_values(state) do
      [] -> term
      values -> mask_values(term, values)
    end
  end

  defp sensitive_header_values(state) do
    state.raw_headers
    |> Enum.flat_map(fn {key, raw} ->
      resolved = Map.get(state.headers, key)

      if is_binary(resolved) and is_binary(raw), do: with_bare_token(resolved), else: []
    end)
    |> Enum.concat(List.wrap(state.headers[@session_id_header]))
    |> Enum.filter(&(byte_size(&1) >= @min_masked_bytes))
    |> Enum.uniq()
  end

  # "Bearer sk-..." should also mask the bare token after the scheme prefix.
  defp with_bare_token(value) do
    case String.split(value, " ") do
      [_] -> [value]
      parts -> [value, List.last(parts)]
    end
  end

  defp mask_values(term, values) when is_binary(term) do
    Enum.reduce(values, term, &String.replace(&2, &1, "[REDACTED]"))
  end

  defp mask_values(term, values) when is_map(term) do
    Map.new(term, fn {k, v} -> {mask_values(k, values), mask_values(v, values)} end)
  end

  defp mask_values(term, values) when is_list(term) do
    Enum.map(term, &mask_values(&1, values))
  end

  defp mask_values(term, _values), do: term

  # A reason as the log prints it. The injected values are masked in the
  # term's own binaries, wherever it holds them, before
  # `Prima.LogFilter.inspect_reason/2` reduces its frames and calls to
  # their arity and renders it in any form (escaped, or as bytes when a
  # binary is not printable), cut to its usual bounds; the printed line is
  # masked once more for a value the term held as a charlist.
  defp log_reason(reason, state) do
    values = sensitive_header_values(state)

    reason
    |> mask_term(values)
    |> Prima.LogFilter.inspect_reason()
    |> mask_values(values)
  end

  defp mask_term(term, []), do: term
  defp mask_term(term, values) when is_binary(term), do: mask_values(term, values)
  # A struct keeps its type, so its own `Inspect` (the server state's
  # hides its headers and grant) still decides what is printed.
  defp mask_term(%_{} = struct, values),
    do: Map.merge(struct, struct |> Map.from_struct() |> mask_term(values))

  defp mask_term(term, values) when is_map(term),
    do: Map.new(term, fn {k, v} -> {mask_term(k, values), mask_term(v, values)} end)

  defp mask_term([head | tail], values), do: [mask_term(head, values) | mask_term(tail, values)]

  defp mask_term(term, values) when is_tuple(term),
    do: term |> Tuple.to_list() |> mask_term(values) |> List.to_tuple()

  defp mask_term(term, _values), do: term

  # ============================================================================
  # Helpers
  # ============================================================================

  defp validate_server_url(url) do
    Sanctum.Network.validate_redirect_url(url,
      private_policy: :operator
    )
  end

  defp can_reinit?(%{last_init_attempt: nil}), do: true

  defp can_reinit?(%{last_init_attempt: last}) do
    System.monotonic_time(:millisecond) - last >= @reinit_cooldown_ms
  end

  defp next_request_id(%{request_id: id} = state) do
    {id + 1, %{state | request_id: id + 1}}
  end
end
